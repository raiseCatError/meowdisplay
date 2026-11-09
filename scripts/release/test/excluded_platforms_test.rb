# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

# A release that leaves Android out entirely (`excludedPlatforms`), such as
# a Mac + iPhone/iPad release while Android stays on an earlier testing
# release: nothing may build, upload, submit, follow, publish or list
# Android. Also the per-run iOS submission authorization that such a release
# uses instead of `ios.submitForReview`.
class ExcludedPlatformsTest < Minitest::Test
  include ReleaseTestHelpers
  include MeowRelease

  ROOT = File.expand_path("../../..", __dir__)
  CLI = File.expand_path("../meow-release", __dir__)
  PACKAGE = "com.raisecaterror.meowdisplay.android"

  # The shape of a Mac + iOS release config with Android excluded (2.1.0):
  # no Android tracks at all, and no automatic App Review submission.
  def mac_ios_config_raw(overrides = {})
    {
      "publishMode" => "manual-final-approval",
      "crossPlatformReady" => false,
      "requiredPlatforms" => %w[mac ios],
      "excludedPlatforms" => %w[android],
      "mac" => { "products" => %w[sender receiver] },
      "ios" => { "appId" => "6817552864", "bundleId" => "com.raisecaterror.meowdisplay.ios",
                 "submitForReview" => false, "storeUrl" => "https://apps.apple.com/app/id6817552864" },
      "android" => { "package" => PACKAGE,
                     "storeUrl" => "https://play.google.com/store/apps/details?id=#{PACKAGE}" },
    }.merge(overrides)
  end

  def mac_ios_config(overrides = {}, ios_submission_authorization: "")
    Config.new(mac_ios_config_raw(overrides), production_authorization: "",
                                              ios_submission_authorization: ios_submission_authorization)
  end

  # Mac approved and iOS uploaded for an excluded-Android candidate.
  def mac_ios_state(cfg)
    state = ReleaseState.fresh(version: "2.1.0", mode: cfg.mode, required_platforms: cfg.required_platforms,
                               excluded_platforms: cfg.excluded_platforms, now: NOW)
    state.begin_candidate(SHA_A, run_id: 1, now: NOW)
    %w[built signed uploaded approved].each { |s| state.advance("mac", s, sha: SHA_A, now: NOW, build: "2.1.0") }
    %w[built signed uploaded].each { |s| state.advance("ios", s, sha: SHA_A, now: NOW, build: 12) }
    state
  end

  # A Play client that fails the test on any call at all.
  class UntouchablePlay
    def method_missing(name, *_args, **_kwargs)
      raise Minitest::Assertion, "Google Play was called (#{name}) for a release that excludes Android"
    end

    def respond_to_missing?(*_args)
      true
    end
  end

  # MARK: - Config

  def test_android_excluded_is_neither_required_nor_built_nor_a_testing_release
    cfg = mac_ios_config({ "android" => { "package" => PACKAGE, "uploadTrack" => "internal", "reviewTrack" => "alpha" } })
    assert_equal %w[mac ios], cfg.required_platforms
    assert cfg.excluded?("android")
    refute cfg.builds?("android")
    assert cfg.builds?("mac")
    assert cfg.builds?("ios")
    refute cfg.android_testing_release?, "an excluded Android is not followed as a testing release, whatever its tracks"
    cfg.check_publishable!
  end

  def test_without_the_option_existing_behaviour_is_unchanged
    cfg = config("crossPlatformReady" => false,
                 "android" => { "package" => PACKAGE, "uploadTrack" => "internal", "reviewTrack" => "alpha" })
    assert_empty cfg.excluded_platforms
    assert cfg.builds?("android")
    assert cfg.android_testing_release?
    assert_equal %w[mac ios], cfg.required_platforms
    assert_equal %w[mac ios android], config.required_platforms
  end

  def test_ambiguous_or_impossible_exclusions_are_refused
    refusals = {
      { "excludedPlatforms" => %w[mac] } => "Mac and iOS are in every release",
      { "excludedPlatforms" => %w[ios] } => "Mac and iOS are in every release",
      { "excludedPlatforms" => %w[windows] } => "unknown platforms windows",
      { "excludedPlatforms" => "android" } => "must be a list",
      { "excludedPlatforms" => [nil] } => "must be a list",
      { "crossPlatformReady" => true } => "crossPlatformReady is true",
      { "requiredPlatforms" => %w[mac ios android] } => "requiredPlatforms lists it",
    }
    refusals.each do |overrides, message|
      error = assert_raises(Error, overrides.inspect) { mac_ios_config(overrides) }
      assert_includes error.message, message, overrides.inspect
    end
  end

  def test_the_repository_config_is_valid
    Config.load(File.join(ROOT, ".github/release-config.json"), production_authorization: "").check_publishable!
  end

  # MARK: - Monitor (release-monitor.yml)

  def test_the_monitor_never_calls_google_play_for_an_excluded_android
    # Even with Android tracks left in the config and a Play client present.
    cfg = mac_ios_config({ "android" => { "package" => PACKAGE, "uploadTrack" => "internal", "reviewTrack" => "alpha" } })
    state = mac_ios_state(cfg)
    apple = FakeAppStore.new(observe: [ios(build: 12)])
    actions = Coordinator.new(state: state, config: cfg, apple: apple, play: UntouchablePlay.new, now: NOW).tick
    assert(actions.any? { |a| a.include?("android: excluded from this release") }, actions.inspect)
    assert_equal "pending", state.stage("android")
    refute(actions.any? { |a| a.start_with?("android:") && !a.include?("excluded") }, actions.inspect)
  end

  def test_the_monitor_runs_without_play_credentials_and_still_follows_ios
    cfg = mac_ios_config
    state = mac_ios_state(cfg)
    apple = FakeAppStore.new(observe: [ios(build: 12)])
    Coordinator.new(state: state, config: cfg, apple: apple, play: nil, now: NOW).tick
    assert_equal "blocked", state.stage("ios"), "iOS is followed: ready, waiting for the submission"
    assert_equal 0, apple.count(:submit_for_review)
  end

  # MARK: - iOS submission needs a person (2.1.0 keeps submitForReview false)

  def test_a_processed_build_is_never_submitted_without_authorization
    cfg = mac_ios_config
    state = mac_ios_state(cfg)
    apple = FakeAppStore.new(observe: [ios(build: 12)], submit_for_review: [true], ensure_manual_release: [true])
    Coordinator.new(state: state, config: cfg, apple: apple, play: nil, now: NOW).tick
    assert_equal 0, apple.count(:submit_for_review)
    assert_equal 0, apple.count(:ensure_manual_release)
    assert_match(/submit_ios=2\.1\.0/, state.platform("ios")["blockers"].first)
  end

  def test_an_authorization_for_another_version_submits_nothing
    %w[2.1.1 2.0.0 2.1 true].each do |authorization|
      cfg = mac_ios_config(ios_submission_authorization: authorization)
      state = mac_ios_state(cfg)
      apple = FakeAppStore.new(observe: [ios(build: 12)], submit_for_review: [true], ensure_manual_release: [true])
      Coordinator.new(state: state, config: cfg, apple: apple, play: nil, now: NOW).tick
      assert_equal 0, apple.count(:submit_for_review), authorization
    end
  end

  def test_an_authorized_run_submits_once_under_manual_release
    cfg = mac_ios_config(ios_submission_authorization: "2.1.0")
    state = mac_ios_state(cfg)
    apple = FakeAppStore.new(observe: [ios(build: 12)], submit_for_review: [true], ensure_manual_release: [true])
    Coordinator.new(state: state, config: cfg, apple: apple, play: UntouchablePlay.new, now: NOW).tick
    assert_equal 1, apple.count(:submit_for_review)
    order = apple.calls.map(&:first)
    assert_operator order.index(:ensure_manual_release), :<, order.index(:submit_for_review)
    assert_equal "submitted", state.stage("ios")
  end

  # MARK: - Release state

  def test_nothing_can_be_recorded_for_an_excluded_platform
    cfg = mac_ios_config
    state = mac_ios_state(cfg)
    %w[built signed uploaded submitted approved published blocked failed].each do |stage|
      error = assert_raises(Error) { state.advance("android", stage, sha: SHA_A, now: NOW, versionCode: 2_010_001) }
      assert_includes error.message, "android is excluded from 2.1.0"
    end
    assert_equal "pending", state.stage("android")
  end

  def test_a_new_candidate_adopts_the_exclusion_and_a_platform_cant_be_both
    state = ReleaseState.fresh(version: "2.1.0", mode: "manual-final-approval", required_platforms: %w[mac ios], now: NOW)
    state.begin_candidate(SHA_A, run_id: 1, now: NOW, required_platforms: %w[mac ios], excluded_platforms: %w[android])
    assert_equal %w[android], state.excluded_platforms
    assert_raises(Error) do
      ReleaseState.fresh(version: "2.1.0", mode: "manual-final-approval", required_platforms: %w[mac ios android],
                         excluded_platforms: %w[android], now: NOW)
    end
  end

  def test_records_from_before_the_option_exclude_nothing
    data = JSON.parse(state_for.to_json)
    data.delete("excludedPlatforms")
    assert_empty ReleaseState.load(JSON.generate(data)).excluded_platforms
  end

  # MARK: - Publication and website

  def test_publication_and_the_website_ignore_an_excluded_android
    cfg = mac_ios_config
    state = mac_ios_state(cfg)
    %w[submitted in_review approved].each { |s| state.advance("ios", s, sha: SHA_A, now: NOW) }
    assert_empty state.publication_blockers(branch_head: SHA_A)

    publisher = Publisher.new(state: state, config: cfg, now: NOW)
    assert publisher.start!(branch_head: SHA_A)
    publisher.mac_published!(release_url: "https://github.com/raiseCatError/meowdisplay/releases/tag/v2.1.0")
    apple = FakeAppStore.new(observe: [ios(build: 12, version_state: "PENDING_DEVELOPER_RELEASE", attached: 12)],
                             release: [true])
    waiting = publisher.publish_stores!(Coordinator.new(state: state, config: cfg, apple: apple,
                                                        play: UntouchablePlay.new, now: NOW))
    assert_empty waiting
    manifest = publisher.website_manifest
    assert_equal %w[ios mac], manifest["platforms"].keys.sort
    refute manifest["platforms"].key?("android")
    assert_includes Summary.render(state, branch_head: SHA_A), "| Android | Excluded from this release |"
  end

  # MARK: - CLI, as release-candidate.yml and the dry run call it

  def run_cli(*args, ok: true)
    out, err, status = Open3.capture3({ "ANDROID_PRODUCTION_AUTHORIZED" => "", "IOS_SUBMISSION_AUTHORIZED" => "" },
                                      "ruby", CLI, *args)
    assert_equal ok, status.success?, "meow-release #{args.join(' ')}\n#{out}#{err}"
    [out, err]
  end

  def test_the_candidate_plan_skips_android_and_the_record_refuses_it
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, "release-config.json")
      File.write(cfg, JSON.generate(mac_ios_config_raw))
      state = File.join(dir, "2.1.0.json")
      sha = "c" * 40

      assert_equal "false\n", run_cli("builds", "android", "--config", cfg).first
      assert_equal "true\n", run_cli("builds", "mac", "--config", cfg).first
      assert_equal "true\n", run_cli("builds", "ios", "--config", cfg).first
      run_cli("builds", "windows", "--config", cfg, ok: false)

      run_cli("init", state, "--config", cfg, "--version", "2.1.0")
      run_cli("candidate", state, "--sha", sha, "--run-id", "7", "--config", cfg)
      _, err = run_cli("record", state, "--platform", "android", "--stage", "built", "--sha", sha, ok: false)
      assert_includes err, "android is excluded from 2.1.0"
      run_cli("record", state, "--platform", "ios", "--stage", "built", "--sha", sha, "--set", "build=12")

      out, = run_cli("summary", state, "--branch-head", sha)
      assert_includes out, "Excluded from this release (not built, uploaded, submitted or published): Android"
    end
  end

  def test_the_repository_config_builds_android_unless_it_excludes_it
    cfg = File.join(ROOT, ".github/release-config.json")
    excluded = Array(JSON.parse(File.read(cfg))["excludedPlatforms"]).include?("android")
    assert_equal (!excluded).to_s, run_cli("builds", "android", "--config", cfg).first.strip
  end

  # MARK: - Workflows can't drift away from the exclusion

  def check_workflows(file, from, to)
    Dir.mktmpdir do |dir|
      workflows = File.join(dir, "workflows")
      FileUtils.cp_r(File.join(ROOT, ".github/workflows"), workflows)
      sync = File.join(dir, "sync-reference.sh")
      FileUtils.cp(File.join(ROOT, "scripts/reference/sync-reference.sh"), sync)
      path = File.join(workflows, file)
      text = File.read(path)
      assert text.include?(from), "mutation target not found in #{file}: #{from}"
      File.write(path, text.sub(from, to))
      out, status = Open3.capture2e("ruby", File.join(ROOT, "scripts/release/check-release-workflows.rb"), workflows, sync)
      [status.success?, out]
    end
  end

  def assert_workflow_caught(message, file, from, to)
    ok, out = check_workflows(file, from, to)
    refute ok, "not caught: #{file} #{from.inspect}\n#{out}"
    assert_includes out, message
  end

  def test_the_android_candidate_job_must_stay_skippable
    msg = "the android job must be skipped when the release config excludes Android"
    assert_workflow_caught(msg, "release-candidate.yml", "    if: needs.plan.outputs.android == 'true'\n", "")
    assert_workflow_caught(msg, "release-candidate.yml", "needs.plan.outputs.android == 'true'", "always()")
    assert_workflow_caught("plan must export whether the release config builds Android", "release-candidate.yml",
                           "android=$(scripts/release/meow-release builds android --config .github/release-config.json)",
                           "android=true")
  end

  def test_release_android_refuses_an_excluded_release_first
    assert_workflow_caught("check must refuse a release that excludes Android before anything else", "release-android.yml",
                           "          if [ \"$(scripts/release/meow-release builds android --config .github/release-config.json)\" != true ]; then",
                           "          if false; then")
  end

  def test_the_dry_run_skips_android_credentials_of_an_excluded_release
    assert_workflow_caught("android-upload must be skipped when the release config excludes Android", "release-dry-run.yml",
                           "    if: needs.platforms.outputs.android == 'true'\n", "")
  end

  def test_a_scheduled_monitor_run_can_never_authorize_a_submission
    assert_workflow_caught("IOS_SUBMISSION_AUTHORIZED may come only from a dispatched run's submit_ios input",
                           "release-monitor.yml",
                           "${{ github.event_name == 'workflow_dispatch' && inputs.submit_ios || '' }}",
                           "${{ vars.IOS_SUBMIT }}")
  end
end
