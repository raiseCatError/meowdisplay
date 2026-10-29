# frozen_string_literal: true

require "json"
require_relative "state"

module MeowRelease
  # `.github/release-config.json` on the release branch: what this release
  # needs and how far automation may go. Android joins the required
  # platforms only once the release is declared cross-platform ready.
  class Config
    attr_reader :raw

    def self.load(path)
      new(JSON.parse(File.read(path)))
    end

    def initialize(raw)
      @raw = raw
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

    # Managed publishing (a Play Console setting) holds an approved release
    # in APPROVED_NOT_PUBLISHED until someone presses Publish in Play
    # Console; no API publishes it. Without it, Play publishes as soon as
    # review approves, so coordinated release timing isn't possible.
    def android_managed_publishing?
      android.fetch("managedPublishing", true) == true
    end

    def android_upload_track
      android.fetch("uploadTrack", "internal")
    end

    def android_review_track
      android.fetch("reviewTrack", "production")
    end

    def android_rollout
      android["rollout"]
    end
  end
end
