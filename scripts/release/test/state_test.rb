# frozen_string_literal: true

require_relative "test_helper"

class VersionAndBuildNumberTest < Minitest::Test
  include MeowRelease

  def test_versions_parse_and_compare
    assert_equal "2.0.0", Version.parse(" 2.0.0\n").to_s
    assert_operator Version.parse("2.0.0"), :>, Version.parse("1.20.0")
    assert_equal "release/2.0.0", Version.parse("2.0.0").branch
    %w[2.0 v2.0.0 2.0.0-beta.1 2.0.0.1 x].each { |bad| assert_raises(Error) { Version.parse(bad) } }
  end

  def test_build_numbers_only_grow
    assert_equal "2.0.0", BuildNumbers.mac("2.0.0")
    assert_equal 1, BuildNumbers.ios_next(nil)
    assert_equal 8, BuildNumbers.ios_next(7)
    assert_equal 2_000_001, BuildNumbers.android_version_code("2.0.0", 1)
    assert_equal 2_010_399, BuildNumbers.android_version_code("2.1.3", 99)
    assert_operator BuildNumbers.android_version_code("2.0.1", 1), :>, BuildNumbers.android_version_code("2.0.0", 99)
    assert_raises(Error) { BuildNumbers.android_version_code("2.0.0", 0) }
    assert_raises(Error) { BuildNumbers.android_version_code("2.100.0", 1) }
  end

  def test_android_retry_never_reuses_a_version_code
    assert_equal 1, BuildNumbers.android_next("2.0.0", nil)
    assert_equal 1, BuildNumbers.android_next("2.0.0", 1_200_099), "an older version's codes don't count"
    assert_equal 4, BuildNumbers.android_next("2.0.0", 2_000_003)
    assert_raises(Error) { BuildNumbers.android_next("2.0.0", 2_000_099) }
  end
end

class ReleaseStateTest < Minitest::Test
  include ReleaseTestHelpers
  include MeowRelease

  def test_a_platform_only_moves_forward_or_aside
    state = state_for
    assert state.advance("ios", "built", sha: SHA_A, now: NOW)
    assert_raises(Error) { state.advance("ios", "pending", sha: SHA_A, now: NOW) }
    state.advance("ios", "blocked", sha: SHA_A, now: NOW, blockers: ["x"])
    state.advance("ios", "uploaded", sha: SHA_A, now: NOW)
    assert_equal [], state.platform("ios")["blockers"], "moving on clears old blockers"
  end

  def test_results_for_another_commit_are_refused
    state = state_for
    error = assert_raises(Error) { state.advance("mac", "built", sha: SHA_B, now: NOW) }
    assert_match(/not.*candidate|candidate is/, error.message)
  end

  def test_the_same_observation_twice_changes_nothing
    state = state_for
    state.advance("ios", "built", sha: SHA_A, now: NOW, build: 7)
    events = state.data["events"].length
    refute state.advance("ios", "built", sha: SHA_A, now: NOW + 60, build: 7)
    assert_equal events, state.data["events"].length
  end

  def test_a_newer_push_supersedes_everything_of_the_old_candidate
    state = uploaded_state
    state.advance("ios", "in_review", sha: SHA_A, now: NOW)
    assert state.begin_candidate(SHA_B, run_id: 2, now: NOW)
    assert_equal SHA_B, state.candidate_sha
    PLATFORMS.each { |p| assert_equal "pending", state.stage(p) }
    assert_equal %w[ios mac], state.superseded_submissions.keys.sort
    refute state.begin_candidate(SHA_B, run_id: 3, now: NOW), "a re-run of the same commit keeps its progress"
  end

  def test_publication_needs_every_required_platform_approved_for_the_branch_head
    state = uploaded_state
    blockers = state.publication_blockers(branch_head: SHA_A)
    assert_includes blockers, "ios: uploaded to distribution service"
    assert_includes blockers, "android: uploaded to distribution service"
    state.advance("ios", "approved", sha: SHA_A, now: NOW)
    state.advance("android", "approved", sha: SHA_A, now: NOW)
    assert_empty state.publication_blockers(branch_head: SHA_A)
    moved = state.publication_blockers(branch_head: SHA_B)
    assert_equal 1, moved.length
    assert_match(/release branch is at bbbbbbbbbbbb, the candidate is aaaaaaaaaaaa/, moved.first)
  end

  def test_android_is_required_only_once_declared_cross_platform_ready
    refute_includes config("crossPlatformReady" => false).required_platforms, "android"
    assert_includes config("crossPlatformReady" => true).required_platforms, "android"
    state = state_for(config("crossPlatformReady" => false))
    %w[built signed uploaded approved].each { |s| state.advance("mac", s, sha: SHA_A, now: NOW) }
    %w[built signed uploaded approved].each { |s| state.advance("ios", s, sha: SHA_A, now: NOW) }
    assert_empty state.publication_blockers(branch_head: SHA_A), "an unfinished Android app doesn't hold the release"
  end

  def test_a_published_release_cannot_take_a_new_candidate
    state = state_for
    state.set_publication("published", now: NOW)
    assert_raises(Error) { state.begin_candidate(SHA_B, run_id: 2, now: NOW) }
  end

  def test_state_round_trips_through_json
    state = uploaded_state
    copy = ReleaseState.load(state.to_json)
    assert_equal state.data, copy.data
    assert_raises(Error) { ReleaseState.load(JSON.generate(state.data.merge("schema" => 99))) }
  end
end
