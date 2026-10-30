# frozen_string_literal: true

require_relative "config"
require_relative "state"
require_relative "stores"

module MeowRelease
  # One monitoring pass over the stores (release-monitor.yml), and the store
  # half of publication (release-publish.yml). Every action re-observes the
  # store first, so a pass that crashed half way, a re-run, or two
  # overlapping passes never submit, cancel or release twice. Nothing here
  # touches the Mac release, the website or git.
  class Coordinator
    attr_reader :actions

    def initialize(state:, config:, apple:, play:, now: Time.now.utc, sleeper: ->(_s) {})
      @state = state
      @config = config
      @apple = apple
      @play = play
      @now = now
      @sleeper = sleeper
      @actions = []
      check_platforms!
    end

    def tick
      monitor_ios if @state.required_platforms.include?("ios")
      monitor_android if @state.required_platforms.include?("android")
      @actions
    end

    # MARK: - iOS (App Store Connect)

    def monitor_ios
      record = @state.platform("ios")
      stage = record["stage"]
      return if %w[pending built signed published superseded].include?(stage)

      obs = observe_ios
      build = record["build"]

      # The version is in review with another build (a superseded
      # candidate's): withdraw that submission so this candidate's build can
      # replace it.
      if build && obs.attached_build && obs.attached_build.to_s != build.to_s &&
         %i[in_review approved].include?(AppleReview.classify(obs.version_state))
        if @config.ios_submit_automatically?
          act("ios: cancel the review of superseded build #{obs.attached_build}") { @apple.cancel_review(@state.version) }
        else
          block("ios", "build #{obs.attached_build} of a superseded candidate is in review; cancel it in App Store Connect")
        end
        return
      end

      case obs.build_state
      when "INVALID", "FAILED"
        return block("ios", "App Store Connect refused build #{build} (#{obs.build_state})")
      when "PROCESSING", nil
        # Processing finished is not approval; still processing is neither.
        return note("ios: build #{build} is still processing") if %w[uploaded blocked].include?(stage)
      end

      case AppleReview.classify(obs.version_state)
      when :missing
        # No App Store version yet: submitting creates it, as a manually
        # released version, before anything is sent for review.
        return submit_ios(build) if %w[uploaded blocked].include?(stage)

        block("ios", "App Store Connect has no version #{@state.version}")
      when :preparing
        if Array(obs.blockers).any?
          block("ios", *obs.blockers)
        elsif %w[uploaded blocked].include?(stage)
          submit_ios(build)
        else
          # It was submitted, and is now back in preparation: withdrawn or
          # sent back without a review decision.
          block("ios", "App Store Connect shows #{obs.version_state}: the submission was withdrawn")
        end
      when :in_review
        advance("ios", "in_review", storeState: obs.version_state)
      when :approved
        if obs.manual_release?
          advance("ios", "approved", storeState: obs.version_state)
        else
          block("ios", "#{obs.version_state}, but the version's release setting is #{obs.release_settings}, " \
                       "not manual: set \"Manually release this version\" in App Store Connect")
        end
      when :held
        block("ios", "#{obs.version_state}: Apple holds this version until the OS release it requires; " \
                     "it is not approved for our release")
      when :published
        advance("ios", "published", storeState: obs.version_state, listingVersion: obs.listing_version)
      when :rejected
        reasons = Array(obs.blockers).empty? ? ["App Review: #{obs.version_state}"] : obs.blockers
        advance("ios", "rejected", storeState: obs.version_state, blockers: reasons)
      else
        note("ios: unrecognized App Store state #{obs.version_state.inspect}; nothing changed")
      end
    end

    def submit_ios(build)
      unless @config.ios_submit_automatically?
        return block("ios", "build #{build} is ready: submit it for review in App Store Connect")
      end

      # Look again right before submitting: a submission that went through
      # in an earlier pass whose result was never recorded must not be sent
      # twice.
      latest = observe_ios
      if %i[in_review approved published].include?(AppleReview.classify(latest.version_state))
        return advance("ios", "in_review", storeState: latest.version_state)
      end

      begin
        # Never submit under release settings that would let Apple publish
        # the version without the publication gate.
        act("ios: set #{@state.version} to manual release") { @apple.ensure_manual_release(@state.version) }
        act("ios: submit build #{build} for review") { @apple.submit_for_review(@state.version, build) }
      rescue TransientError
        raise
      rescue Error => e
        # What App Store Connect still needs (metadata, screenshots, export
        # compliance) is its own refusal text: show it, retry next pass.
        return block("ios", "App Store Connect didn't accept the submission: #{e.message}")
      end
      advance("ios", "submitted", submittedAt: @now.iso8601)
    end

    # MARK: - Android (Google Play)

    def monitor_android
      record = @state.platform("android")
      stage = record["stage"]
      return if %w[pending built signed published superseded].include?(stage)

      code = record["versionCode"]
      track = android_review_track!
      obs = observe_android
      unless Array(obs.version_codes).include?(code)
        return note("android: versionCode #{code} isn't visible on Google Play yet") if stage == "uploaded"

        return block("android", "Google Play has no versionCode #{code}")
      end

      release = PlayReview.release_for(obs.releases, track: track, version_code: code)
      if release.nil?
        return submit_android(code, obs) if %w[uploaded blocked].include?(stage)

        return block("android", "versionCode #{code} is no longer on the #{track} track")
      end

      apply_play_state(release, code)
    end

    def submit_android(code, obs)
      track = android_review_track!
      # Another release on the review track still in review or approved is
      # the superseded candidate's: this submission replaces it.
      replacing = Array(obs.releases).any? do |r|
        r["track"] == track && %i[in_review approved].include?(PlayReview.classify(r["releaseLifecycleState"]))
      end
      fraction = @config.android_rollout
      status = fraction ? "inProgress" : "completed"
      begin
        act("android: send versionCode #{code} to the #{track} track for review#{replacing ? ', replacing the superseded release' : ''}") do
          @play.submit(@config.android_package, code, track: track, status: status, user_fraction: fraction,
                                                      replace_in_review: replacing)
        end
      rescue TransientError
        raise
      rescue Error => e
        return block("android", "Google Play didn't accept the release: #{e.message}")
      end
      advance("android", "submitted", track: track, submittedAt: @now.iso8601)
    end

    def apply_play_state(release, code)
      state = release["releaseLifecycleState"]
      case PlayReview.classify(state)
      when :draft
        block("android", "versionCode #{code} is a draft on #{release['track']}: it was never sent for review")
      when :not_sent
        block("android", "versionCode #{code} is waiting to be sent for review in Play Console")
      when :in_review
        advance("android", "in_review", storeState: state)
      when :approved
        advance("android", "approved", storeState: state)
      when :rejected
        advance("android", "rejected", storeState: state, blockers: ["Google Play review didn't approve versionCode #{code}"])
      when :published
        advance("android", "published", storeState: state)
      else
        note("android: unrecognized Play state #{state.inspect}; nothing changed")
      end
    end

    # MARK: - Publication (stores)

    # Releases the approved iOS version (it waits in Pending Developer
    # Release under manual release control). An already-live version is
    # only recorded.
    def publish_ios
      obs = observe_ios
      case AppleReview.classify(obs.version_state)
      when :published
        advance("ios", "published", storeState: obs.version_state)
      when :approved
        problems = ios_approval_problems(obs)
        raise Error, "iOS #{@state.version} not released: #{problems.join('; ')}" unless problems.empty?

        act("ios: release #{@state.version} on the App Store") { @apple.release(@state.version) }
        advance("ios", "published", storeState: "RELEASE_REQUESTED", releasedAt: @now.iso8601)
      else
        raise Error, "iOS #{@state.version} is #{obs.version_state}, not approved: not released"
      end
    end

    # Managed publishing holds an approved release until someone presses
    # Publish in Play Console; there is no API for that click. The monitor
    # sees the result (PUBLISHED) on its next pass, so the click is the only
    # manual step. Returns whether Android is published now.
    def publish_android
      record = @state.platform("android")
      return true if record["stage"] == "published"

      code = record["versionCode"]
      track = android_review_track!
      unless track == "production"
        raise Error, "Android is configured for the #{track} testing track: a public release needs production authorization"
      end

      release = PlayReview.release_for(observe_android.releases, track: track, version_code: code)
      raise Error, "Android versionCode #{code} is not on the #{track} track" unless release

      apply_play_state(release, code)
      return true if @state.stage("android") == "published"

      if @state.stage("android") == "approved"
        note("android: approved and held by managed publishing: press Publish in Play Console; the monitor records it")
      end
      false
    end

    # The stores' own answer, not the recorded state, on whether every
    # required store platform is approved (or already public) for exactly
    # the recorded build. Empty when publication may proceed. Used before
    # publication starts and again before a resumed publication releases
    # anything, so a forged or stale release-state record can't stand in for
    # a store's decision.
    def live_approval_blockers
      blockers = []
      if @state.required_platforms.include?("ios")
        obs = observe_ios
        case AppleReview.classify(obs.version_state)
        when :approved then blockers.concat(ios_approval_problems(obs).map { |p| "ios: #{p}" })
        when :published then nil
        else blockers << "ios: App Store Connect shows #{obs.version_state.inspect}, not approved"
        end
      end
      if @state.required_platforms.include?("android")
        code = @state.platform("android")["versionCode"]
        track = android_review_track!
        release = PlayReview.release_for(observe_android.releases, track: track, version_code: code)
        lifecycle = release && PlayReview.classify(release["releaseLifecycleState"])
        unless %i[approved published].include?(lifecycle)
          blockers << "android: versionCode #{code} on #{track} is #{lifecycle || 'absent'}, not approved"
        end
        blockers << "android: the #{track} track is a testing track, not a public release" unless track == "production"
      end
      blockers
    end

    private

    def ios_approval_problems(obs)
      problems = []
      problems << "release setting is #{obs.release_settings}, not manual" unless obs.manual_release?
      build = @state.platform("ios")["build"]
      if build.nil? || obs.attached_build.to_s != build.to_s
        problems << "the approved version carries build #{obs.attached_build.inspect}, not the candidate's #{build.inspect}"
      end
      problems
    end

    # Android's review track, refusing production unless it is explicitly
    # authorized for this exact version (Config#android_review_track!).
    def android_review_track!
      @config.android_review_track!(version: @state.version)
    end

    def check_platforms!
      configured = @config.required_platforms.sort
      recorded = @state.required_platforms.sort
      return if configured == recorded

      raise Error, "the release config requires #{configured.join(', ')} but this candidate's state records " \
                   "#{recorded.join(', ')}: push a new candidate so the state follows the config"
    end

    def observe_ios
      build = @state.platform("ios")["build"]
      Retry.with_backoff(sleeper: @sleeper, on_retry: ->(n, e, _) { note("ios: retry #{n} after #{e.message}") }) do
        @apple.observe(@state.version, build: build)
      end
    end

    def observe_android
      tracks = [@config.android_upload_track, android_review_track!].uniq
      Retry.with_backoff(sleeper: @sleeper, on_retry: ->(n, e, _) { note("android: retry #{n} after #{e.message}") }) do
        @play.observe(@config.android_package, tracks: tracks)
      end
    end

    def act(description)
      result = yield
      @actions << description
      result
    end

    def note(text)
      @actions << "note: #{text}"
      nil
    end

    def advance(platform, stage, **details)
      @state.advance(platform, stage, sha: @state.candidate_sha, now: @now, **details)
    end

    def block(platform, *reasons)
      advance(platform, "blocked", blockers: reasons)
      note("#{platform}: blocked — #{reasons.join('; ')}")
    end
  end
end
