# frozen_string_literal: true

require "base64"
require "json"
require "openssl"
require "uri"
require_relative "http"
require_relative "stores"

module MeowRelease
  # Google Play Developer API v3 (androidpublisher) for one app, through a
  # service account (OAuth 2.0 JWT bearer, scope androidpublisher):
  # - uploads go through an edit: insert, upload the bundle, set the track
  #   release, commit;
  # - review state comes from `tracks/{track}/releases` (ReleaseSummary.
  #   releaseLifecycleState: IN_REVIEW, APPROVED_NOT_PUBLISHED,
  #   NOT_APPROVED, PUBLISHED, ...). It skips obsolete releases and returns
  #   at most 20 per track;
  # - commits default to ERROR_IF_IN_REVIEW, so nothing in review is
  #   cancelled unless replacing a superseded candidate was asked for.
  # Publishing a release held by managed publishing has no API: Play
  # Console's Publish button, after which this client sees PUBLISHED.
  class GooglePlay
    BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3"
    UPLOAD = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3"
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    SCOPE = "https://www.googleapis.com/auth/androidpublisher"

    def initialize(service_account:, transport: HTTPTransport.new, clock: -> { Time.now })
      @email = service_account.fetch("client_email")
      @key = OpenSSL::PKey::RSA.new(service_account.fetch("private_key"))
      @transport = transport
      @clock = clock
    end

    def self.from_env(env = ENV)
      new(service_account: JSON.parse(env.fetch("PLAY_SERVICE_ACCOUNT_JSON")))
    end

    def token
      now = @clock.call.to_i
      return @token if @token && now < @token_expiry - 60

      header = { alg: "RS256", typ: "JWT" }
      claims = { iss: @email, scope: SCOPE, aud: TOKEN_URL, iat: now, exp: now + 3600 }
      input = [header, claims].map { |part| b64url(JSON.generate(part)) }.join(".")
      assertion = "#{input}.#{b64url(@key.sign(OpenSSL::Digest.new('SHA256'), input))}"
      status, body = @transport.call(:post, TOKEN_URL,
                                     headers: { "Content-Type" => "application/x-www-form-urlencoded" },
                                     body: URI.encode_www_form(grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
                                                               assertion: assertion))
      response = HTTPResult.parse(status, body, "Google OAuth token")
      @token_expiry = now + response.fetch("expires_in", 3600).to_i
      @token = response.fetch("access_token")
    end

    # Every versionCode on any track (the edit's view), and the review
    # lifecycle of the releases on `tracks`.
    def observe(package, tracks:)
      codes = with_edit(package, commit: false) do |edit|
        Array(get("/applications/#{package}/edits/#{edit}/tracks")["tracks"]).flat_map do |track|
          Array(track["releases"]).flat_map { |r| Array(r["versionCodes"]).map(&:to_i) }
        end
      end
      releases = tracks.flat_map do |track|
        Array(get("/applications/#{package}/tracks/#{track}/releases")["releases"]).map do |summary|
          { "track" => summary["track"] || track, "name" => summary["releaseName"],
            "versionCodes" => Array(summary["activeArtifacts"]).map { |a| a["versionCode"].to_i },
            "releaseLifecycleState" => summary["releaseLifecycleState"] }
        end
      end
      AndroidObservation.new(version_codes: codes.uniq, releases: releases, blockers: [])
    end

    def highest_version_code(package)
      with_edit(package, commit: false) do |edit|
        bundles = Array(get("/applications/#{package}/edits/#{edit}/bundles")["bundles"]).map { |b| b["versionCode"].to_i }
        tracks = Array(get("/applications/#{package}/edits/#{edit}/tracks")["tracks"]).flat_map do |t|
          Array(t["releases"]).flat_map { |r| Array(r["versionCodes"]).map(&:to_i) }
        end
        (bundles + tracks).max
      end
    end

    # The build workflow's upload: the AAB onto `track` (internal testing by
    # default), as its own committed edit. Returns the versionCode Play read
    # from the bundle.
    def upload(package, aab_path, track:, release_name:, status: "completed")
      with_edit(package) do |edit|
        code = File.open(aab_path, "rb") do |file|
          upload_bundle(package, edit, file)
        end
        put("/applications/#{package}/edits/#{edit}/tracks/#{track}",
            track: track, releases: [{ name: release_name, versionCodes: [code.to_s], status: status }])
        code
      end
    end

    def submit(package, version_code, track:, status:, user_fraction: nil, replace_in_review: false)
      release = { versionCodes: [version_code.to_s], status: status }
      release[:userFraction] = user_fraction if user_fraction
      with_edit(package, replace_in_review: replace_in_review) do |edit|
        put("/applications/#{package}/edits/#{edit}/tracks/#{track}", track: track, releases: [release])
      end
    end

    private

    def upload_bundle(package, edit, file)
      url = "#{UPLOAD}/applications/#{package}/edits/#{edit}/bundles?uploadType=media"
      status, body = @transport.call(:post, url, headers: { "Authorization" => "Bearer #{token}",
                                                            "Content-Type" => "application/octet-stream" },
                                                 raw_body: file)
      HTTPResult.parse(status, body, "Google Play bundle upload").fetch("versionCode").to_i
    end

    # Runs `block` inside a fresh edit. Committed with the chosen in-review
    # behaviour, or deleted (never left behind) when nothing is to be
    # committed or the block fails.
    def with_edit(package, commit: true, replace_in_review: false)
      edit = post("/applications/#{package}/edits", {}).fetch("id")
      committed = false
      result = yield edit
      if commit
        behavior = replace_in_review ? "CANCEL_IN_REVIEW_AND_SUBMIT" : "ERROR_IF_IN_REVIEW"
        post("/applications/#{package}/edits/#{edit}:commit?changesInReviewBehavior=#{behavior}", nil)
        committed = true
      end
      result
    ensure
      if edit && !committed
        begin
          request(:delete, "/applications/#{package}/edits/#{edit}")
        rescue Error
          nil # an abandoned edit expires on its own
        end
      end
    end

    def get(path)
      request(:get, path)
    end

    def post(path, body)
      request(:post, path, body)
    end

    def put(path, body)
      request(:put, path, body)
    end

    def request(method, path, body = nil)
      status, response = @transport.call(method, BASE + path, headers: { "Authorization" => "Bearer #{token}" },
                                                               body: body)
      HTTPResult.parse(status, response, "Google Play #{method.upcase} #{path.split('?').first}")
    end

    def b64url(bytes)
      Base64.urlsafe_encode64(bytes, padding: false)
    end
  end
end
