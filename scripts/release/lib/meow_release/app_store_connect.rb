# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "uri"
require_relative "http"
require_relative "stores"

module MeowRelease
  # App Store Connect API (https://developer.apple.com/documentation/appstoreconnectapi)
  # for one app: read build processing and version review state, submit a
  # version for review (reviewSubmissions), cancel a submission, and release
  # an approved version (appStoreVersionReleaseRequests). Authenticates with
  # an API key (ES256 JWT, 20-minute lifetime). Uploading the binary stays
  # with fastlane/altool in the build workflow.
  class AppStoreConnect
    BASE = "https://api.appstoreconnect.apple.com"
    LOOKUP = "https://itunes.apple.com/lookup"
    OPEN_SUBMISSION_STATES = %w[READY_FOR_REVIEW WAITING_FOR_REVIEW IN_REVIEW UNRESOLVED_ISSUES].freeze

    def initialize(key_id:, issuer_id:, private_key_pem:, app_id:, transport: HTTPTransport.new, clock: -> { Time.now })
      @key_id = key_id
      @issuer_id = issuer_id
      @key = OpenSSL::PKey::EC.new(private_key_pem)
      @app_id = app_id
      @transport = transport
      @clock = clock
    end

    # From the release environment's secrets (the same names fastlane uses;
    # the key content is base64 of the .p8 file).
    def self.from_env(env = ENV, app_id:)
      new(key_id: env.fetch("APP_STORE_CONNECT_KEY_ID"), issuer_id: env.fetch("APP_STORE_CONNECT_ISSUER_ID"),
          private_key_pem: Base64.decode64(env.fetch("APP_STORE_CONNECT_KEY_CONTENT")), app_id: app_id)
    end

    # ES256 JWT as App Store Connect requires: header kid, payload iss/iat/
    # exp/aud, signature as raw r||s (not DER).
    def token
      now = @clock.call.to_i
      return @token if @token && now < @token_expiry - 60

      header = { alg: "ES256", kid: @key_id, typ: "JWT" }
      payload = { iss: @issuer_id, iat: now, exp: now + 1200, aud: "appstoreconnect-v1" }
      input = [header, payload].map { |part| b64url(JSON.generate(part)) }.join(".")
      der = @key.sign(OpenSSL::Digest.new("SHA256"), input)
      r, s = OpenSSL::ASN1.decode(der).value.map { |n| n.value.to_s(2).rjust(32, "\0")[-32, 32] }
      @token_expiry = now + 1200
      @token = "#{input}.#{b64url(r + s)}"
    end

    def latest_build_number(version)
      builds = get("/v1/builds", "filter[app]" => @app_id, "filter[preReleaseVersion.version]" => version,
                                 "limit" => "200", "fields[builds]" => "version")
      Array(builds["data"]).map { |b| b.dig("attributes", "version").to_i }.max
    end

    def observe(version, build: nil)
      store_version = version_record(version)
      attached = store_version && attached_build(store_version)
      build_data = build ? build_record(version, build) : nil
      IosObservation.new(
        build: build,
        build_state: build_data&.dig("attributes", "processingState"),
        version_state: store_version && (store_version.dig("attributes", "appVersionState") ||
                                         store_version.dig("attributes", "appStoreState")),
        attached_build: attached&.dig("attributes", "version"),
        submission_id: open_submission&.dig("id"),
        blockers: [],
        listing_version: listing_version,
        release_type: store_version&.dig("attributes", "releaseType"),
        earliest_release_date: store_version&.dig("attributes", "earliestReleaseDate")
      )
    end

    # Makes the version (creating it if missing) manually released, with no
    # earliest release date, and reads it back. Raises when App Store
    # Connect doesn't end up with exactly that, so nothing is ever submitted
    # under release settings that could publish it without the gate.
    def ensure_manual_release(version)
      enforce_manual!(version, version_record(version) || create_version(version))
      true
    end

    # Attaches `build` to the version (creating the version with manual
    # release control if it doesn't exist yet) and submits it for review.
    # Anything App Store Connect still needs (metadata, export compliance,
    # screenshots) comes back as its error text and becomes a blocker.
    def submit_for_review(version, build)
      store_version = enforce_manual!(version, version_record(version) || create_version(version))
      build_data = build_record(version, build) or raise Error, "build #{build} of #{version} isn't in App Store Connect"
      patch("/v1/appStoreVersions/#{store_version['id']}/relationships/build",
            data: { type: "builds", id: build_data["id"] })
      submission = open_submission || post("/v1/reviewSubmissions", data: {
        type: "reviewSubmissions", attributes: { platform: "IOS" },
        relationships: { app: { data: { type: "apps", id: @app_id } } }
      })["data"]
      post("/v1/reviewSubmissionItems", data: {
        type: "reviewSubmissionItems",
        relationships: { reviewSubmission: { data: { type: "reviewSubmissions", id: submission["id"] } },
                         appStoreVersion: { data: { type: "appStoreVersions", id: store_version["id"] } } }
      })
      patch("/v1/reviewSubmissions/#{submission['id']}",
            data: { type: "reviewSubmissions", id: submission["id"], attributes: { submitted: true } })
    end

    def cancel_review(_version)
      submission = open_submission or return
      patch("/v1/reviewSubmissions/#{submission['id']}",
            data: { type: "reviewSubmissions", id: submission["id"], attributes: { canceled: true } })
    end

    # Releases a version waiting in Pending Developer Release.
    def release(version)
      store_version = version_record(version) or raise Error, "no App Store version #{version}"
      post("/v1/appStoreVersionReleaseRequests", data: {
        type: "appStoreVersionReleaseRequests",
        relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: store_version["id"] } } }
      })
    end

    # The public App Store listing's version (iTunes Lookup, no credentials).
    def listing_version
      status, body = @transport.call(:get, "#{LOOKUP}?id=#{@app_id}&entity=software&t=#{@clock.call.to_i}")
      HTTPResult.parse(status, body, "App Store lookup").fetch("results", []).first&.dig("version")
    rescue Error
      nil
    end

    private

    def version_record(version)
      Array(get("/v1/apps/#{@app_id}/appStoreVersions",
                "filter[versionString]" => version, "filter[platform]" => "IOS")["data"]).first
    end

    def create_version(version)
      post("/v1/appStoreVersions", data: {
        type: "appStoreVersions", attributes: { platform: "IOS", versionString: version, releaseType: "MANUAL" },
        relationships: { app: { data: { type: "apps", id: @app_id } } }
      })["data"]
    end

    def manual?(store_version)
      attributes = store_version.fetch("attributes", {})
      attributes["releaseType"] == AppleReview::MANUAL && attributes["earliestReleaseDate"].nil?
    end

    def enforce_manual!(version, store_version)
      return store_version if manual?(store_version)

      patch("/v1/appStoreVersions/#{store_version['id']}", data: {
        type: "appStoreVersions", id: store_version["id"],
        attributes: { releaseType: AppleReview::MANUAL, earliestReleaseDate: nil }
      })
      reread = version_record(version)
      return reread if reread && manual?(reread)

      found = reread&.dig("attributes", "releaseType") || "missing"
      raise Error, "App Store version #{version} is not set to manual release (#{found}); refusing to continue"
    end

    def attached_build(store_version)
      get("/v1/appStoreVersions/#{store_version['id']}/build")["data"]
    rescue Error
      nil
    end

    def build_record(version, build)
      Array(get("/v1/builds", "filter[app]" => @app_id, "filter[preReleaseVersion.version]" => version,
                              "filter[version]" => build.to_s)["data"]).first
    end

    def open_submission
      Array(get("/v1/reviewSubmissions", "filter[app]" => @app_id, "filter[platform]" => "IOS",
                                         "filter[state]" => OPEN_SUBMISSION_STATES.join(","))["data"]).first
    end

    def get(path, query = {})
      request(:get, path + (query.empty? ? "" : "?#{URI.encode_www_form(query)}"))
    end

    def post(path, body)
      request(:post, path, body)
    end

    def patch(path, body)
      request(:patch, path, body)
    end

    def request(method, path, body = nil)
      status, response = @transport.call(method, BASE + path,
                                         headers: { "Authorization" => "Bearer #{token}" }, body: body)
      HTTPResult.parse(status, response, "App Store Connect #{method.upcase} #{path.split('?').first}")
    end

    def b64url(bytes)
      Base64.urlsafe_encode64(bytes, padding: false)
    end
  end
end
