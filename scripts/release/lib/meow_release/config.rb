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

    def self.load(path, production_authorization: ENV["ANDROID_PRODUCTION_AUTHORIZED"])
      new(JSON.parse(File.read(path, encoding: "UTF-8")), production_authorization: production_authorization)
    end

    # `production_authorization` is the operator's separate, per-release
    # switch for Android production (the ANDROID_PRODUCTION_AUTHORIZED
    # environment value, naming the exact version). No workflow sets it
    # today, so production can't be reached by configuration alone.
    def initialize(raw, production_authorization: ENV["ANDROID_PRODUCTION_AUTHORIZED"])
      @raw = raw
      @production_authorization = production_authorization.to_s.strip
      raise Error, "publishMode must be one of #{MODES}" unless MODES.include?(mode)
    end

    def mode
      raw.fetch("publishMode", "manual-final-approval")
    end

    def cross_platform_ready?
      raw.fetch("crossPlatformReady", false) == true
    end

    def required_platforms
      base = raw.fetch("requiredPlatforms", %w[mac ios])
      cross_platform_ready? ? (base | %w[android]) : base - %w[android]
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
  end
end
