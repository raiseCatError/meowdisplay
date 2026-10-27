# frozen_string_literal: true

require_relative "test_helper"

class IosMonitoringTest < Minitest::Test
  include ReleaseTestHelpers
  include MeowRelease

  def test_processing_is_not_approval_and_review_is_followed_to_approval
    state = uploaded_state
    c = coordinator(state, config, apple: { observe: [ios(build_state: "PROCESSING")] })
    c.tick
    assert_equal "uploaded", state.stage("ios"), "still processing: nothing to do"

    c = coordinator(state, config, apple: {
      observe: [ios, ios], submit_for_review: [true],
    })
    c.tick
    assert_equal "submitted", state.stage("ios"), "a VALID build is submitted, never treated as approved"
    assert_equal 1, @apple.count(:submit_for_review)

    { "WAITING_FOR_REVIEW" => "in_review", "IN_REVIEW" => "in_review",
      "PENDING_DEVELOPER_RELEASE" => "approved" }.each do |apple_state, stage|
      coordinator(state, config, apple: { observe: [ios(version_state: apple_state, attached: 7)] }).tick
      assert_equal stage, state.stage("ios"), apple_state
    end
    assert_equal "PENDING_DEVELOPER_RELEASE", state.platform("ios")["storeState"]
  end

  # A pass that submitted and then died before recording it must not
  # submit again: the next pass sees the submission and only records it.
  def test_a_crashed_pass_never_submits_twice
    state = uploaded_state
    coordinator(state, config, apple: { observe: [ios, ios(version_state: "WAITING_FOR_REVIEW", attached: 7)] }).tick
    assert_equal 0, @apple.count(:submit_for_review)
    assert_equal "in_review", state.stage("ios")
  end

  def test_rejections_and_missing_metadata_surface_as_blockers
    state = uploaded_state
    coordinator(state, config, apple: { observe: [ios(blockers: ["Missing screenshots for 6.9-inch display"])] }).tick
    assert_equal "blocked", state.stage("ios")
    assert_equal ["Missing screenshots for 6.9-inch display"], state.platform("ios")["blockers"]

    coordinator(state, config, apple: {
      observe: [ios, ios], submit_for_review: [Error.new("ENTITY_ERROR: export compliance is missing")],
    }).tick
    assert_equal "blocked", state.stage("ios")
    assert_match(/export compliance/, state.platform("ios")["blockers"].first)

    coordinator(state, config, apple: { observe: [ios, ios], submit_for_review: [true] }).tick
    coordinator(state, config, apple: { observe: [ios(version_state: "METADATA_REJECTED", attached: 7)] }).tick
    assert_equal "rejected", state.stage("ios")
    assert_equal ["App Review: METADATA_REJECTED"], state.platform("ios")["blockers"]
  end

  def test_an_invalid_binary_blocks
    state = uploaded_state
    coordinator(state, config, apple: { observe: [ios(build_state: "INVALID")] }).tick
    assert_equal "blocked", state.stage("ios")
  end

  def test_manual_submission_mode_never_submits
    cfg = config("ios" => { "submitForReview" => false })
    state = uploaded_state(cfg)
    coordinator(state, cfg, apple: { observe: [ios] }).tick
    assert_equal 0, @apple.count(:submit_for_review)
    assert_match(/submit it for review/, state.platform("ios")["blockers"].first)
  end

  def test_transient_errors_are_retried_and_then_give_up_without_changing_state
    state = uploaded_state
    flaky = [TransientError.new("HTTP 503"), TransientError.new("HTTP 429"), ios(version_state: "WAITING_FOR_REVIEW", attached: 7)]
    c = coordinator(state, config, apple: { observe: flaky })
    c.tick
    assert_equal "in_review", state.stage("ios")
    assert_equal 2, c.actions.count { |a| a.include?("retry") }

    before = state.to_json
    down = coordinator(state, config, apple: { observe: [TransientError.new("HTTP 503")] })
    assert_raises(TransientError) { down.tick }
    assert_equal before, state.to_json, "an outage records nothing"
  end

  # A newer push while the old build is in review: that submission is
  # withdrawn before the new build is submitted.
  def test_a_superseded_build_in_review_is_withdrawn_first
    state = uploaded_state(sha: SHA_A)
    state.begin_candidate(SHA_B, run_id: 2, now: NOW)
    %w[built signed uploaded].each { |s| state.advance("ios", s, sha: SHA_B, now: NOW, build: 8) }
    c = coordinator(state, config, apple: {
      observe: [ios(version_state: "WAITING_FOR_REVIEW", attached: 7, build: 8)], cancel_review: [true],
    })
    c.tick
    assert_equal 1, @apple.count(:cancel_review)
    assert_equal 0, @apple.count(:submit_for_review)
    coordinator(state, config, apple: { observe: [ios(build: 8), ios(build: 8)], submit_for_review: [true] }).tick
    assert_equal "submitted", state.stage("ios")
    assert_equal [:submit_for_review, "2.0.0", 8], @apple.calls.find { |call| call.first == :submit_for_review }
  end
end

class AndroidMonitoringTest < Minitest::Test
  include ReleaseTestHelpers
  include MeowRelease

  def test_every_play_lifecycle_state_maps_to_one_release_stage
    {
      "IN_REVIEW" => "in_review",
      "APPROVED_NOT_PUBLISHED" => "approved",
      "NOT_APPROVED" => "rejected",
      "PUBLISHED" => "published",
      "DRAFT" => "blocked",
      "NOT_SENT_FOR_REVIEW" => "blocked",
    }.each do |play_state, stage|
      state = uploaded_state
      state.advance("android", "submitted", sha: SHA_A, now: NOW)
      coordinator(state, config, google: { observe: [play(play_release(play_state))] }).tick
      assert_equal stage, state.stage("android"), play_state
    end
  end

  def test_an_upload_is_sent_for_review_once_without_cancelling_anything
    state = uploaded_state
    c = coordinator(state, config, google: { observe: [play(play_release("PUBLISHED", track: "internal"))], submit: [true] })
    c.tick
    assert_equal "submitted", state.stage("android")
    call = @play.calls.find { |x| x.first == :submit }
    assert_equal [:submit, "com.raisecaterror.meowdisplay.android", 2_000_001, "production", "completed", nil, false], call

    # The next pass sees it in review: no second submission.
    coordinator(state, config, google: { observe: [play(play_release("IN_REVIEW"))] }).tick
    assert_equal 0, @play.count(:submit)
    assert_equal "in_review", state.stage("android")
  end

  def test_replacing_a_superseded_release_in_review_is_explicit
    state = uploaded_state
    old = play_release("IN_REVIEW", code: 1_200_005)
    coordinator(state, config, google: { observe: [play(old, codes: [1_200_005, 2_000_001])], submit: [true] }).tick
    assert_equal true, @play.calls.find { |x| x.first == :submit }.last, "CANCEL_IN_REVIEW_AND_SUBMIT only here"
  end

  def test_staged_rollout_is_requested_as_in_progress_with_a_fraction
    cfg = config("android" => config.android.merge("rollout" => 0.1))
    state = uploaded_state(cfg)
    coordinator(state, cfg, google: { observe: [play], submit: [true] }).tick
    assert_equal ["inProgress", 0.1], @play.calls.find { |x| x.first == :submit }[4, 2]
  end

  def test_an_upload_play_cant_see_yet_waits_and_a_lost_one_blocks
    state = uploaded_state
    coordinator(state, config, google: { observe: [play(codes: [])] }).tick
    assert_equal "uploaded", state.stage("android")
    state.advance("android", "submitted", sha: SHA_A, now: NOW)
    coordinator(state, config, google: { observe: [play(codes: [])] }).tick
    assert_equal "blocked", state.stage("android")
  end

  def test_play_refusing_the_release_is_a_blocker_not_a_crash
    state = uploaded_state
    coordinator(state, config, google: { observe: [play], submit: [Error.new("Changes are in review")] }).tick
    assert_equal "blocked", state.stage("android")
    assert_match(/Changes are in review/, state.platform("android")["blockers"].first)
  end

  # Managed publishing holds an approved release until Play Console's
  # Publish click, which no API performs; the monitor then sees PUBLISHED.
  def test_managed_publishing_waits_for_the_console_click_and_then_records_it
    state = uploaded_state
    state.advance("android", "approved", sha: SHA_A, now: NOW)
    c = coordinator(state, config, google: { observe: [play(play_release("APPROVED_NOT_PUBLISHED"))] })
    refute c.publish_android
    assert_equal "approved", state.stage("android")
    assert(c.actions.any? { |a| a.include?("press Publish in Play Console") })
    c = coordinator(state, config, google: { observe: [play(play_release("PUBLISHED"))] })
    assert c.publish_android
    assert_equal "published", state.stage("android")
  end
end
