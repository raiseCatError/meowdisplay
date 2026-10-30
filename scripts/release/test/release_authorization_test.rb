# frozen_string_literal: true

require_relative "test_helper"

# Nothing becomes public without the publication gate: iOS only ever sits in
# review under manual release, approvals are confirmed by the stores for the
# exact build, Android stays on testing tracks unless production is
# authorized twice for the exact version, and a candidate's platforms can't
# drift from the release config.
class IosManualReleaseTest < Minitest::Test
  include ReleaseTestHelpers
  include MeowRelease

  def test_submission_first_enforces_manual_release
    state = uploaded_state
    coordinator(state, config, apple: { observe: [ios, ios], submit_for_review: [true] }).tick
    assert_equal %i[observe observe ensure_manual_release submit_for_review], @apple.calls.map(&:first)
    assert_equal "submitted", state.stage("ios")
  end

  def test_a_version_that_cant_be_made_manual_is_never_submitted
    state = uploaded_state
    coordinator(state, config, apple: {
      observe: [ios(release_type: "AFTER_APPROVAL"), ios(release_type: "AFTER_APPROVAL")],
      ensure_manual_release: [Error.new("App Store version 2.0.0 is not set to manual release (AFTER_APPROVAL)")],
    }).tick
    assert_equal 0, @apple.count(:submit_for_review)
    assert_equal "blocked", state.stage("ios")
    assert_match(/manual release/, state.platform("ios")["blockers"].first)
  end

  def test_a_missing_version_is_created_through_the_manual_submission_path
    state = uploaded_state
    coordinator(state, config, apple: { observe: [ios(version_state: nil, release_type: nil)] * 2,
                                        submit_for_review: [true] }).tick
    assert_equal 1, @apple.count(:ensure_manual_release)
    assert_equal 1, @apple.count(:submit_for_review)
  end

  def test_approval_counts_only_under_manual_release
    %w[AFTER_APPROVAL SCHEDULED].each do |type|
      state = uploaded_state
      state.advance("ios", "in_review", sha: SHA_A, now: NOW)
      coordinator(state, config, apple: { observe: [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 7,
                                                        release_type: type)] }).tick
      assert_equal "blocked", state.stage("ios"), type
      assert_match(/not manual/, state.platform("ios")["blockers"].first)
    end
    state = uploaded_state
    state.advance("ios", "in_review", sha: SHA_A, now: NOW)
    coordinator(state, config, apple: { observe: [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 7,
                                                      earliest: "2026-12-01T00:00:00Z")] }).tick
    assert_equal "blocked", state.stage("ios"), "an earliest release date is not manual release"
  end

  def test_pending_apple_release_is_a_hold_not_an_approval
    state = uploaded_state
    state.advance("ios", "in_review", sha: SHA_A, now: NOW)
    coordinator(state, config, apple: { observe: [ios(version_state: "PENDING_APPLE_RELEASE", attached: 7)] }).tick
    assert_equal "blocked", state.stage("ios")
    assert_match(/holds this version/, state.platform("ios")["blockers"].first)
    assert_equal :held, AppleReview.classify("PENDING_APPLE_RELEASE")
  end

  def test_release_refuses_a_version_that_isnt_manual_or_carries_another_build
    [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 7, release_type: "AFTER_APPROVAL"),
     ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 9)].each do |obs|
      state = uploaded_state
      error = assert_raises(Error) { coordinator(state, config, apple: { observe: [obs] }).publish_ios }
      assert_match(/not released/, error.message)
      assert_equal 0, @apple.count(:release)
    end
  end
end

class AppStoreConnectManualReleaseTest < Minitest::Test
  include MeowRelease

  KEY = OpenSSL::PKey::EC.generate("prime256v1")
  APP = "6817552864"

  def client(routes)
    @transport = RecordingTransport.new(routes)
    AppStoreConnect.new(key_id: "K", issuer_id: "I", private_key_pem: KEY.to_pem, app_id: APP, transport: @transport)
  end

  def version(type, earliest = nil)
    [200, { data: [{ id: "v1", attributes: { appVersionState: "PREPARE_FOR_SUBMISSION", releaseType: type,
                                             earliestReleaseDate: earliest } }] }]
  end

  def test_an_automatic_or_scheduled_version_is_patched_to_manual_and_read_back
    [["AFTER_APPROVAL", nil], ["SCHEDULED", "2026-12-01T00:00:00Z"]].each do |type, earliest|
      c = client(
        [:get, %r{appStoreVersions\?}] => [version(type, earliest), version("MANUAL")],
        [:patch, %r{/v1/appStoreVersions/v1\z}] => [200, { data: { id: "v1" } }]
      )
      assert c.ensure_manual_release("2.0.0")
      patch = @transport.requests.find { |r| r[:method] == :patch }
      assert_equal({ releaseType: "MANUAL", earliestReleaseDate: nil }, patch[:body][:data][:attributes])
    end
  end

  def test_a_version_that_stays_automatic_stops_the_submission_before_anything_is_sent
    c = client(
      [:get, %r{appStoreVersions\?}] => [version("AFTER_APPROVAL")],
      [:patch, %r{/v1/appStoreVersions/v1\z}] => [200, { data: { id: "v1" } }]
    )
    error = assert_raises(Error) { c.submit_for_review("2.0.0", 8) }
    assert_match(/not set to manual release \(AFTER_APPROVAL\)/, error.message)
    refute(@transport.requests.any? { |r| r[:url].include?("reviewSubmission") }, "no review submission")
  end

  def test_observe_reports_the_release_settings
    c = client(
      [:get, %r{/v1/apps/#{APP}/appStoreVersions}] => [version("SCHEDULED", "2026-12-01T00:00:00Z")],
      [:get, %r{/v1/appStoreVersions/v1/build}] => [200, { data: nil }],
      [:get, %r{/v1/reviewSubmissions}] => [200, { data: [] }],
      [:get, /itunes\.apple\.com/] => [200, { results: [] }]
    )
    obs = c.observe("2.0.0")
    assert_equal "SCHEDULED", obs.release_type
    refute obs.manual_release?
  end
end

class LiveApprovalTest < Minitest::Test
  include ReleaseTestHelpers
  include MeowRelease

  def approved_state
    state = uploaded_state
    state.advance("ios", "approved", sha: SHA_A, now: NOW)
    state.advance("android", "approved", sha: SHA_A, now: NOW)
    state
  end

  def test_a_forged_recorded_approval_is_not_confirmed_by_the_stores
    [ios(version_state: "IN_REVIEW", attached: 7), ios(version_state: nil), ios(version_state: "SOMETHING_NEW", attached: 7)].each do |obs|
      blockers = coordinator(approved_state, config, apple: { observe: [obs] },
                                                     google: { observe: [play(play_release("APPROVED_NOT_PUBLISHED"))] })
                 .live_approval_blockers
      assert(blockers.any? { |b| b.start_with?("ios:") }, obs.version_state.inspect)
    end
  end

  def test_approval_must_be_for_the_recorded_build_and_manual
    blockers = coordinator(approved_state, config,
                           apple: { observe: [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 9)] },
                           google: { observe: [play(play_release("APPROVED_NOT_PUBLISHED"))] }).live_approval_blockers
    assert(blockers.any? { |b| b.include?("not the candidate's 7") })
  end

  def test_confirmed_approvals_clear_the_gate
    blockers = coordinator(approved_state, config,
                           apple: { observe: [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 7)] },
                           google: { observe: [play(play_release("APPROVED_NOT_PUBLISHED"))] }).live_approval_blockers
    assert_empty blockers
  end

  def test_android_absent_or_in_review_on_the_track_is_not_approval
    [play, play(play_release("IN_REVIEW"))].each do |obs|
      blockers = coordinator(approved_state, config,
                             apple: { observe: [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 7)] },
                             google: { observe: [obs] }).live_approval_blockers
      assert(blockers.any? { |b| b.start_with?("android:") })
    end
  end
end

class AndroidTrackSafetyTest < Minitest::Test
  include ReleaseTestHelpers
  include MeowRelease

  def android_config(track, production_release: nil, operator: nil)
    android = { "package" => "com.raisecaterror.meowdisplay.android", "reviewTrack" => track }
    android["productionRelease"] = production_release if production_release
    android.delete("reviewTrack") if track.nil?
    config({ "android" => android }, operator)
  end

  def test_testing_tracks_need_no_authorization
    %w[internal alpha beta].each { |t| assert_equal t, android_config(t).android_review_track!(version: "2.0.0") }
  end

  def test_production_needs_both_switches_for_this_exact_version
    [[nil, nil], ["2.0.0", nil], [nil, "2.0.0"], ["2.0.0", "2.0.1"], ["1.9.0", "2.0.0"]].each do |cfg, op|
      error = assert_raises(Error) do
        android_config("production", production_release: cfg, operator: op).android_review_track!(version: "2.0.0")
      end
      assert_match(/not authorized/, error.message, [cfg, op].inspect)
    end
    assert_equal "production",
                 android_config("production", production_release: "2.0.0", operator: "2.0.0").android_review_track!(version: "2.0.0")
  end

  def test_a_missing_or_unknown_track_is_refused
    assert_raises(Error) { android_config(nil).android_review_track!(version: "2.0.0") }
    assert_raises(Error) { android_config("open-testing").android_review_track!(version: "2.0.0") }
  end

  def test_unauthorized_production_submits_nothing
    cfg = android_config("production", production_release: "2.0.0")
    state = uploaded_state(cfg)
    assert_raises(Error) { coordinator(state, cfg, google: { observe: [play] }).tick }
    assert_equal 0, @play.count(:submit)
  end

  def test_a_testing_track_release_is_never_published_as_public
    cfg = android_config("alpha")
    state = uploaded_state(cfg)
    %w[submitted in_review approved].each { |s| state.advance("android", s, sha: SHA_A, now: NOW) }
    error = assert_raises(Error) { coordinator(state, cfg).publish_android }
    assert_match(/testing track/, error.message)

    %w[approved].each { |s| state.advance("ios", s, sha: SHA_A, now: NOW) }
    error = assert_raises(GateClosed) { Publisher.new(state: state, config: cfg, now: NOW).start!(branch_head: SHA_A) }
    assert_match(/alpha is a testing track/, error.message)
  end
end

class RequiredPlatformsDriftTest < Minitest::Test
  include ReleaseTestHelpers
  include MeowRelease

  def test_a_config_that_no_longer_matches_the_candidate_is_refused
    state = state_for(config("crossPlatformReady" => false))
    assert_equal %w[mac ios], state.required_platforms
    error = assert_raises(Error) { coordinator(state, config("crossPlatformReady" => true)) }
    assert_match(/push a new candidate/, error.message)
    error = assert_raises(GateClosed) do
      Publisher.new(state: state, config: config("crossPlatformReady" => true), now: NOW).start!(branch_head: SHA_A)
    end
    assert_match(/release config requires android, ios, mac/, error.message)
  end

  def test_a_new_candidate_adopts_the_configs_platforms_and_a_rerun_does_not
    state = state_for(config("crossPlatformReady" => false))
    refute state.begin_candidate(SHA_A, run_id: 2, now: NOW, required_platforms: %w[mac ios android])
    assert_equal %w[mac ios], state.required_platforms, "a re-run of the same candidate keeps its platforms"
    assert state.begin_candidate(SHA_B, run_id: 3, now: NOW, required_platforms: %w[mac ios android])
    assert_equal %w[mac ios android], state.required_platforms
  end
end
