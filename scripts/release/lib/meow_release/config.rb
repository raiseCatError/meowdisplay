# frozen_string_literal: true

require "json"
require_relative "state"

module MeowRelease
  # `.github/release-config.json` on the release branch: what this release
  # needs and how far automation may go. Android joins the required
  # platforms only once the release is declared cross-platform ready.
  class Config
    attr_reader :raw

    # Google Play tracks a release may be reviewed on without any further
    # authorization: internal and closed testing reach only testers.
    TESTING_TRACKS = %w[internal alpha beta].freeze

    # Platforms a release may leave out entirely (`excludedPlatforms`). Mac
    # and iOS are in every release; only Android can sit a release out.
    EXCLUDABLE = %w[android].freeze

    def self.load(path, production_authorization: ENV["ANDROID_PRODUCTION_AUTHORIZED"],
                  ios_submission_authorization: ENV["IOS_SUBMISSION_AUTHORIZED"])
      new(JSON.parse(File.read(path, encoding: "UTF-8")), production_authorization: production_authorization,
                                                          ios_submission_authorization: ios_submission_authorization)
    end

    # `production_authorization` is the operator's separate, per-release
    # switch for Android production (the ANDROID_PRODUCTION_AUTHORIZED
    # environment value, naming the exact version). No workflow sets it
    # today, so production can't be reached by configuration alone.
    #
    # `ios_submission_authorization` is the operator's per-run switch for an
    # App Review submission when the release config keeps
    # `ios.submitForReview` false (the IOS_SUBMISSION_AUTHORIZED value of a
    # dispatched monitor run, naming the exact version).
    def initialize(raw, production_authorization: ENV["ANDROID_PRODUCTION_AUTHORIZED"],
                   ios_submission_authorization: ENV["IOS_SUBMISSION_AUTHORIZED"])
      @raw = raw
      @production_authorization = production_authorization.to_s.strip
      @ios_submission_authorization = ios_submission_authorization.to_s.strip
      raise Error, "publishMode must be one of #{MODES}" unless MODES.include?(mode)

      check_exclusions!
    end

    def mode
      raw.fetch("publishMode", "manual-final-approval")
    end

    def cross_platform_ready?
      raw.fetch("crossPlatformReady", false) == true
    end

    def required_platforms
      base = raw.fetch("requiredPlatforms", %w[mac ios])
      required = cross_platform_ready? ? (base | %w[android]) : base - %w[android]
      required - excluded_platforms
    end

    # Platforms this release leaves out entirely: no candidate build, no
    # store upload, no review submission, no monitoring, no publication and
    # no website listing. Validated in #check_exclusions!.
    def excluded_platforms
      raw.fetch("excludedPlatforms", [])
    end

    def excluded?(platform)
      excluded_platforms.include?(platform)
    end

    # Whether the release candidate builds and uploads this platform at all.
    def builds?(platform)
      raise Error, "unknown platform #{platform.inspect}" unless PLATFORMS.include?(platform)

      !excluded?(platform)
    end

    def ios
      raw.fetch("ios", {})
    end

    def android
      raw.fetch("android", {})
    end

    def website
      raw.fetch("website", {})
    end

    def ios_submit_automatically?
      ios.fetch("submitForReview", true) == true
    end

    # May this run submit `version` to App Review? Either the release config
    # allows it (`ios.submitForReview`), or the operator authorized exactly
    # this version for this run (IOS_SUBMISSION_AUTHORIZED).
    def ios_submission_allowed?(version:)
      ios_submit_automatically? || (!@ios_submission_authorization.empty? && @ios_submission_authorization == version)
    end

    def android_package
      android.fetch("package")
    end

    # Managed publishing (a Play Console setting) is not a control here: it
    # isn't available for an app's first publication, and the code never
    # relies on it. Production is gated by android_review_track! instead.

    def android_upload_track
      android.fetch("uploadTrack", "internal")
    end

    # The track the monitor sends Android builds to for review. Testing
    # tracks (internal, closed testing) are allowed; there is no default, so
    # a missing value stops instead of guessing. Production needs BOTH the
    # release config naming this exact version (`android.productionRelease`)
    # AND the operator's separate authorization for the same version; either
    # alone, a mismatch, or any other track refuses.
    def android_review_track!(version:)
      track = android["reviewTrack"]
      raise Error, "android.reviewTrack is not set (use internal or a closed testing track)" if track.to_s.empty?
      return track if TESTING_TRACKS.include?(track)

      unless track == "production"
        raise Error, "android.reviewTrack #{track.inspect} is not an allowed track (#{TESTING_TRACKS.join(', ')})"
      end

      config_ok = android["productionRelease"] == version
      operator_ok = @production_authorization == version
      return track if config_ok && operator_ok

      raise Error, "Android production for #{version} is not authorized (release config: #{config_ok ? 'yes' : 'no'}, " \
                   "separate operator authorization: #{operator_ok ? 'yes' : 'no'}); review stays on testing tracks"
    end

    def android_rollout
      android["rollout"]
    end

    # Android takes part as a testing release: its candidate is uploaded,
    # sent to its testing review track and followed, but never holds the
    # release and is never presented as public.
    def android_testing_release?
      !excluded?("android") && !required_platforms.include?("android") && TESTING_TRACKS.include?(android["reviewTrack"])
    end

    # A platform the release requires must be able to reach the public.
    # Android on a testing track reaches testers only, and publication
    # refuses it (Coordinator#live_approval_blockers), so requiring Android
    # there would hold the Mac and iOS releases forever. Refused when a
    # release or candidate starts, instead of after every store approved it.
    def check_publishable!
      track = android["reviewTrack"]
      return unless required_platforms.include?("android") && TESTING_TRACKS.include?(track)

      raise Error, "Android is required (crossPlatformReady) but is reviewed on the #{track} testing track, " \
                   "which never counts as public, so the release could not publish. For an Android testing " \
                   "release set crossPlatformReady to false; for Android production use reviewTrack production " \
                   "with its separate authorization (RELEASE.md)"
    end

    private

    # An exclusion must be unambiguous: a list of excludable platform names,
    # never a platform the same config also requires.
    def check_exclusions!
      list = raw.fetch("excludedPlatforms", [])
      unless list.is_a?(Array) && list.all? { |p| p.is_a?(String) }
        raise Error, "excludedPlatforms must be a list of platform names"
      end

      unknown = list - PLATFORMS
      raise Error, "excludedPlatforms names unknown platforms #{unknown.join(', ')}" unless unknown.empty?

      fixed = list - EXCLUDABLE
      raise Error, "excludedPlatforms can't exclude #{fixed.join(', ')}: Mac and iOS are in every release" unless fixed.empty?
      return unless list.include?("android")

      if cross_platform_ready?
        raise Error, "excludedPlatforms excludes android but crossPlatformReady is true: choose one"
      end
      return unless raw.fetch("requiredPlatforms", []).include?("android")

      raise Error, "excludedPlatforms excludes android but requiredPlatforms lists it: remove it from requiredPlatforms"
    end
  end
end
