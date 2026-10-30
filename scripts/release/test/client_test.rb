# frozen_string_literal: true

require_relative "test_helper"
require "base64"
require "openssl"

class AppStoreConnectClientTest < Minitest::Test
  include MeowRelease

  KEY = OpenSSL::PKey::EC.generate("prime256v1")
  APP = "6817552864"

  def client(routes)
    @transport = RecordingTransport.new(routes)
    AppStoreConnect.new(key_id: "ABC123", issuer_id: "issuer-uuid", private_key_pem: KEY.to_pem,
                        app_id: APP, transport: @transport, clock: -> { Time.at(1_800_000_000) })
  end

  def test_the_token_is_an_es256_jwt_apple_accepts
    token = client({}).token
    header, payload, signature = token.split(".")
    assert_equal({ "alg" => "ES256", "kid" => "ABC123", "typ" => "JWT" }, JSON.parse(Base64.urlsafe_decode64(header)))
    claims = JSON.parse(Base64.urlsafe_decode64(payload))
    assert_equal "appstoreconnect-v1", claims["aud"]
    assert_equal 1200, claims["exp"] - claims["iat"], "Apple refuses tokens living over 20 minutes"
    raw = Base64.urlsafe_decode64(signature + "=" * (-signature.length % 4))
    assert_equal 64, raw.bytesize, "raw r||s, not DER"
    r, s = raw.unpack("a32a32").map { |half| OpenSSL::BN.new(half, 2) }
    der = OpenSSL::ASN1::Sequence.new([OpenSSL::ASN1::Integer.new(r), OpenSSL::ASN1::Integer.new(s)]).to_der
    assert KEY.verify(OpenSSL::Digest.new("SHA256"), der, "#{header}.#{payload}")
  end

  def test_observe_reads_build_processing_and_version_review_state
    c = client(
      [:get, %r{/v1/apps/#{APP}/appStoreVersions}] => [200, { data: [{ id: "v1", attributes: { appVersionState: "WAITING_FOR_REVIEW" } }] }],
      [:get, %r{/v1/appStoreVersions/v1/build}] => [200, { data: { id: "b7", attributes: { version: "7" } } }],
      [:get, %r{/v1/builds\?}] => [200, { data: [{ id: "b7", attributes: { version: "7", processingState: "VALID" } }] }],
      [:get, %r{/v1/reviewSubmissions}] => [200, { data: [{ id: "rs1" }] }],
      [:get, /itunes\.apple\.com/] => [200, { results: [{ version: "1.20.0" }] }]
    )
    obs = c.observe("2.0.0", build: 7)
    assert_equal "VALID", obs.build_state
    assert_equal "WAITING_FOR_REVIEW", obs.version_state
    assert_equal "7", obs.attached_build
    assert_equal "1.20.0", obs.listing_version
    assert(@transport.requests.select { |r| r[:url].include?("api.appstoreconnect") }
             .all? { |r| r[:headers]["Authorization"].start_with?("Bearer ") })
  end

  def test_submission_attaches_the_build_and_submits_one_review_submission
    c = client(
      [:get, %r{appStoreVersions\?}] => [200, { data: [{ id: "v1", attributes: { appVersionState: "PREPARE_FOR_SUBMISSION",
                                                                              releaseType: "MANUAL" } }] }],
      [:get, %r{/v1/builds\?}] => [200, { data: [{ id: "b8", attributes: { version: "8" } }] }],
      [:patch, %r{/v1/appStoreVersions/v1/relationships/build}] => [204, ""],
      [:get, %r{/v1/reviewSubmissions\?}] => [200, { data: [] }],
      [:post, %r{/v1/reviewSubmissions\z}] => [201, { data: { id: "rs9" } }],
      [:post, %r{/v1/reviewSubmissionItems}] => [201, { data: { id: "i1" } }],
      [:patch, %r{/v1/reviewSubmissions/rs9}] => [200, { data: { id: "rs9" } }]
    )
    c.submit_for_review("2.0.0", 8)
    calls = @transport.requests.map { |r| [r[:method], r[:url].sub(AppStoreConnect::BASE, "").split("?").first] }
    assert_includes calls, [:patch, "/v1/appStoreVersions/v1/relationships/build"]
    assert_equal({ data: { type: "builds", id: "b8" } }, @transport.requests.find { |r| r[:url].include?("relationships/build") }[:body])
    final = @transport.requests.last
    assert_equal [:patch, { data: { type: "reviewSubmissions", id: "rs9", attributes: { submitted: true } } }], [final[:method], final[:body]]
  end

  def test_server_errors_are_transient_and_refusals_are_permanent_with_apples_text
    c = client([:get, /appStoreVersions/] => [503, "busy"])
    assert_raises(TransientError) { c.release("2.0.0") }
    c = client([:get, /appStoreVersions/] => [409, { errors: [{ title: "ENTITY_ERROR", detail: "Missing privacy policy URL" }] }])
    error = assert_raises(Error) { c.release("2.0.0") }
    assert_match(/Missing privacy policy URL/, error.message)
    refute_match(/Bearer/, error.message, "never echoes credentials")
  end
end

class GooglePlayClientTest < Minitest::Test
  include MeowRelease

  KEY = OpenSSL::PKey::RSA.generate(2048)
  PKG = "com.raisecaterror.meowdisplay.android"

  def client(routes)
    @transport = RecordingTransport.new({ [:post, /oauth2/] => [200, { access_token: "ya29.test", expires_in: 3599 }] }.merge(routes))
    GooglePlay.new(service_account: { "client_email" => "release@meow.iam.gserviceaccount.com", "private_key" => KEY.to_pem },
                   transport: @transport, clock: -> { Time.at(1_800_000_000) })
  end

  def test_observe_reads_the_documented_release_lifecycle_and_leaves_no_edit_behind
    c = client(
      [:post, %r{/edits\z}] => [200, { id: "e1" }],
      [:get, %r{/edits/e1/tracks}] => [200, { tracks: [{ track: "internal", releases: [{ versionCodes: ["2000001"] }] }] }],
      [:delete, %r{/edits/e1}] => [204, ""],
      [:get, %r{/tracks/production/releases}] => [200, { releases: [{ releaseName: "2.0.0", track: "production",
                                                                      activeArtifacts: [{ versionCode: 2_000_001 }],
                                                                      releaseLifecycleState: "RELEASE_LIFECYCLE_STATE_IN_REVIEW" }] }],
      [:get, %r{/tracks/internal/releases}] => [200, {}]
    )
    obs = c.observe(PKG, tracks: %w[internal production])
    assert_equal [2_000_001], obs.version_codes
    assert_equal :in_review, PlayReview.classify(obs.releases.first["releaseLifecycleState"])
    assert(@transport.requests.any? { |r| r[:method] == :delete && r[:url].end_with?("/edits/e1") }, "the read-only edit is deleted")
    assert_includes @transport.requests.map { |r| r[:url] },
                    "#{GooglePlay::BASE}/applications/#{PKG}/tracks/production/releases"
  end

  def test_submission_commits_with_error_if_in_review_unless_replacing
    routes = {
      [:post, %r{/edits\z}] => [200, { id: "e2" }],
      [:put, %r{/edits/e2/tracks/production}] => [200, {}],
      [:post, %r{/edits/e2:commit}] => [200, { id: "e2" }],
    }
    client(routes).submit(PKG, 2_000_001, track: "production", status: "completed")
    commit = @transport.requests.find { |r| r[:url].include?(":commit") }
    assert_match(/changesInReviewBehavior=ERROR_IF_IN_REVIEW/, commit[:url])
    put = @transport.requests.find { |r| r[:method] == :put }
    assert_equal({ track: "production", releases: [{ versionCodes: ["2000001"], status: "completed" }] }, put[:body])

    client(routes).submit(PKG, 2_000_002, track: "production", status: "inProgress", user_fraction: 0.1, replace_in_review: true)
    assert_match(/CANCEL_IN_REVIEW_AND_SUBMIT/, @transport.requests.find { |r| r[:url].include?(":commit") }[:url])
    assert_equal 0.1, @transport.requests.find { |r| r[:method] == :put }[:body][:releases].first[:userFraction]
  end

  def test_a_failed_submission_deletes_its_edit_instead_of_committing
    c = client(
      [:post, %r{/edits\z}] => [200, { id: "e3" }],
      [:put, %r{/tracks/production}] => [403, { error: { message: "The caller does not have permission" } }],
      [:delete, %r{/edits/e3}] => [204, ""]
    )
    error = assert_raises(Error) { c.submit(PKG, 2_000_001, track: "production", status: "completed") }
    assert_match(/does not have permission/, error.message)
    refute(@transport.requests.any? { |r| r[:url].include?(":commit") })
    assert(@transport.requests.any? { |r| r[:method] == :delete })
  end

  def test_the_oauth_assertion_is_signed_by_the_service_account
    c = client({})
    assert_equal "ya29.test", c.token
    form = URI.decode_www_form(@transport.requests.first[:body]).to_h
    header, claims, signature = form.fetch("assertion").split(".")
    assert_equal "https://www.googleapis.com/auth/androidpublisher", JSON.parse(Base64.urlsafe_decode64(claims + "=" * (-claims.length % 4)))["scope"]
    assert KEY.verify(OpenSSL::Digest.new("SHA256"), Base64.urlsafe_decode64(signature + "=" * (-signature.length % 4)), "#{header}.#{claims}")
  end
end
