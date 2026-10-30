# frozen_string_literal: true

require_relative "coordinator"
require_relative "state"

module MeowRelease
  class GateClosed < Error; end

  # Publication, in the one order that keeps every failure recoverable:
  #
  #   1. Mac (GitHub Release draft -> byte check -> Latest -> live feeds,
  #      reverted automatically if the live feeds don't verify). It goes
  #      first because it is the only step that can be undone by itself.
  #   2. Stores, irreversible, only after the Mac is live: release the
  #      approved iOS version; Android is published (managed publishing:
  #      one Play Console click, then the monitor sees PUBLISHED).
  #   3. Website, listing only what is actually live.
  #   4. Promotion of the released source to `main` (a PR).
  #
  # Each step checks the state the previous one recorded, so the workflow
  # can run them as separate steps and a re-run resumes where it stopped.
  class Publisher
    def initialize(state:, config:, now: Time.now.utc)
      @state = state
      @config = config
      @now = now
    end

    def start!(branch_head:)
      if @state.publication_stage == "in-progress"
        raise GateClosed, "publication in progress for another candidate" if @state.publication["sha"] != @state.candidate_sha
        raise GateClosed, "release branch moved since publication started" if branch_head != @state.candidate_sha

        return false
      end
      blockers = @state.publication_blockers(branch_head: branch_head) + config_blockers
      raise GateClosed, "not ready: #{blockers.join('; ')}" unless blockers.empty?

      @state.set_publication("in-progress", now: @now, sha: @state.candidate_sha, startedAt: @now.iso8601)
      true
    end

    def mac_published!(release_url:)
      require_in_progress!
      @state.advance("mac", "published", sha: @state.candidate_sha, now: @now, releaseUrl: release_url)
    end

    # The Mac step failed. release.yml's own revert already put the previous
    # release back as Latest; nothing irreversible happened, so the
    # candidate stays approved and publication can be retried.
    def mac_failed!(reason:, reverted:)
      require_in_progress!
      @state.set_publication(reverted ? "rolled-back" : "failed", now: @now, reason: reason, reverted: reverted)
    end

    # Returns the platforms still waiting (an Android release held by
    # managed publishing until its Publish click).
    def publish_stores!(coordinator)
      require_in_progress!
      if @state.required_platforms.include?("mac") && @state.stage("mac") != "published"
        raise GateClosed, "the Mac release isn't live yet: stores wait for it"
      end

      coordinator.publish_ios if @state.required_platforms.include?("ios") && @state.stage("ios") != "published"
      waiting = []
      if @state.required_platforms.include?("android") && !coordinator.publish_android
        waiting << "android"
      end
      waiting
    end

    # What the website shows: only platforms whose distribution is live.
    def website_manifest
      live = PLATFORMS.select { |p| @state.stage(p) == "published" }
      manifest = { "version" => @state.version, "sourceCommit" => @state.candidate_sha,
                   "publishedAt" => @now.iso8601, "platforms" => {} }
      if live.include?("mac")
        base = "https://github.com/raiseCatError/meowdisplay/releases"
        manifest["platforms"]["mac"] = {
          "download" => "#{base}/latest/download/MeowDisplay.dmg",
          "receiverDownload" => "#{base}/latest/download/MeowDisplayReceiver.dmg",
          "releaseNotes" => "#{base}/tag/v#{@state.version}",
          "artifacts" => Array(@state.platform("mac")["artifacts"]).map { |a| a.slice("name", "sha256") },
        }
      end
      if live.include?("ios") && @config.ios["storeUrl"]
        manifest["platforms"]["ios"] = { "store" => @config.ios["storeUrl"] }
      end
      if live.include?("android") && @config.android["storeUrl"]
        manifest["platforms"]["android"] = { "store" => @config.android["storeUrl"] }
      end
      manifest
    end

    def website_updated!(url:, live_version:)
      require_in_progress!
      unless live_version == @state.version
        @state.set_website("failed", now: @now, url: url, blockers: ["the site serves #{live_version.inspect}, not #{@state.version}"])
        return false
      end
      @state.set_website("published", now: @now, url: url, blockers: [])
      true
    end

    # Published when every required platform is public and the website
    # shows it; otherwise partially published, with what is left.
    def finish!(promotion_pr: nil)
      require_in_progress!
      pending = @state.required_platforms.reject { |p| @state.stage(p) == "published" }
      pending << "website" unless @state.website["stage"] == "published"
      if pending.empty?
        @state.set_publication("published", now: @now, promotionPr: promotion_pr, finishedAt: @now.iso8601)
      else
        @state.publication["pending"] = pending
        @state.log("publication", now: @now, to: "partially-published", pending: pending)
      end
      pending
    end

    private

    # What the release config itself rules out: a candidate whose recorded
    # platforms differ from the config, or an Android release that would be
    # "published" from a testing track (testers only, never the public).
    def config_blockers
      blockers = []
      configured = @config.required_platforms.sort
      if configured != @state.required_platforms.sort
        blockers << "the release config requires #{configured.join(', ')}, the candidate records " \
                    "#{@state.required_platforms.sort.join(', ')}"
      end
      if @state.required_platforms.include?("android")
        begin
          track = @config.android_review_track!(version: @state.version)
          blockers << "android: #{track} is a testing track; a public release needs production authorization" unless track == "production"
        rescue Error => e
          blockers << "android: #{e.message}"
        end
      end
      blockers
    end

    def require_in_progress!
      return if @state.publication_stage == "in-progress"

      raise GateClosed, "publication is #{@state.publication_stage}, not in progress"
    end
  end
end
