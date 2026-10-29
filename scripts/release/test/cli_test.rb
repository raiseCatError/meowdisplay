# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

# The workflows' command sequence, run through the real CLI against fixture
# stores: a dry run of one release from push to publication.
class ReleaseCLITest < Minitest::Test
  CLI = File.expand_path("../meow-release", __dir__)
  SHA = "c" * 40

  def run_cli(*args, ok: true)
    out, err, status = Open3.capture3("ruby", CLI, *args)
    assert_equal ok, status.success?, "meow-release #{args.join(' ')}\n#{out}#{err}"
    [out, err]
  end

  def fixture(dir, name, apple:, play:)
    path = File.join(dir, name)
    File.write(path, JSON.generate("apple" => apple, "play" => play))
    "fixture:#{path}"
  end

  def ios(state, build_state: "VALID", attached: 7)
    { "build" => 7, "build_state" => build_state, "version_state" => state, "attached_build" => attached, "blockers" => [] }
  end

  def play(state)
    { "version_codes" => [2_000_001], "releases" => state ? [{ "track" => "production", "versionCodes" => [2_000_001],
                                                                "releaseLifecycleState" => "RELEASE_LIFECYCLE_STATE_#{state}" }] : [],
      "blockers" => [] }
  end

  def test_a_dry_run_release_from_push_to_publication
    Dir.mktmpdir do |dir|
      state = File.join(dir, "2.0.0.json")
      cfg = File.join(dir, "release-config.json")
      File.write(cfg, JSON.generate("publishMode" => "manual-final-approval", "crossPlatformReady" => true,
                                    "requiredPlatforms" => %w[mac ios android],
                                    "ios" => { "appId" => "6817552864", "storeUrl" => "https://apps.apple.com/app/id6817552864" },
                                    "android" => { "package" => "com.raisecaterror.meowdisplay.android" }))
      dmg = File.join(dir, "MeowDisplay.dmg")
      File.write(dmg, "not really a disk image")

      run_cli("init", state, "--config", cfg, "--version", "2.0.0")
      run_cli("candidate", state, "--sha", SHA, "--run-id", "41")
      %w[built signed uploaded approved].each do |stage|
        run_cli("record", state, "--platform", "mac", "--stage", stage, "--sha", SHA, "--set", "build=2.0.0", "--artifact", dmg)
      end
      %w[built signed uploaded].each { |s| run_cli("record", state, "--platform", "ios", "--stage", s, "--sha", SHA, "--set", "build=7") }
      %w[built signed uploaded].each { |s| run_cli("record", state, "--platform", "android", "--stage", s, "--sha", SHA, "--set", "versionCode=2000001") }
      run_cli("record", state, "--platform", "ios", "--stage", "built", "--sha", "d" * 40, ok: false)

      _, err = run_cli("gate", state, "--branch-head", SHA, ok: false)
      assert_match(/ios: uploaded/, err)

      stores = fixture(dir, "review.json", apple: { "observe" => [ios("PREPARE_FOR_SUBMISSION", attached: nil)] * 2, "submit_for_review" => [true] },
                                           play: { "observe" => [play(nil)], "submit" => [true] })
      out, = run_cli("monitor", state, "--config", cfg, "--stores", stores)
      assert_match(/submit build 7 for review/, out)
      assert_match(/send versionCode 2000001 to the production track/, out)

      stores = fixture(dir, "approved.json", apple: { "observe" => [ios("PENDING_DEVELOPER_RELEASE")] },
                                             play: { "observe" => [play("APPROVED_NOT_PUBLISHED")] })
      run_cli("monitor", state, "--config", cfg, "--stores", stores)
      run_cli("gate", state, "--branch-head", SHA)
      _, err = run_cli("gate", state, "--branch-head", "e" * 40, ok: false)
      assert_match(/release branch is at eeeeeeeeeeee/, err)

      out, = run_cli("summary", state, "--branch-head", SHA)
      assert_match(/Ready to publish\.\*\* Waiting for your approval/, out)

      run_cli("publish", "start", state, "--config", cfg, "--branch-head", SHA)
      run_cli("publish", "mac-published", state, "--config", cfg, "--url", "https://github.com/raiseCatError/meowdisplay/releases/tag/v2.0.0")
      stores = fixture(dir, "release.json", apple: { "observe" => [ios("PENDING_DEVELOPER_RELEASE")], "release" => [true] },
                                            play: { "observe" => [play("APPROVED_NOT_PUBLISHED")] })
      out, = run_cli("publish", "stores", state, "--config", cfg, "--stores", stores)
      assert_match(/waiting: android/, out)
      manifest = File.join(dir, "release.json")
      run_cli("publish", "website-manifest", state, "--config", cfg, "--out", manifest)
      site = JSON.parse(File.read(manifest))
      assert_equal %w[ios mac], site["platforms"].keys.sort, "Play isn't listed before it's live"
      assert_equal SHA, site["sourceCommit"]
      run_cli("publish", "website-updated", state, "--config", cfg, "--url", "https://meowdisplay.app/release.json", "--live-version", "2.0.0")
      out, = run_cli("publish", "finish", state, "--config", cfg)
      assert_match(/still pending: android/, out)

      stores = fixture(dir, "live.json", apple: { "observe" => [ios("READY_FOR_SALE")] }, play: { "observe" => [play("PUBLISHED")] })
      run_cli("monitor", state, "--config", cfg, "--stores", stores)
      out, = run_cli("publish", "finish", state, "--config", cfg)
      assert_equal "published\n", out
      assert_equal "published", JSON.parse(File.read(state)).dig("publication", "stage")
    end
  end

  def test_build_numbers_and_refusals
    out, = run_cli("next-build", "android", "--version", "2.0.0", "--latest", "2000003")
    assert_equal "2000004\n", out
    out, = run_cli("next-build", "ios", "--version", "2.0.0", "--latest", "")
    assert_equal "1\n", out
    _, err = run_cli("gate", "/nonexistent.json", "--branch-head", SHA, ok: false)
    assert_match(/no release state/, err)
  end

  def test_live_stores_without_credentials_fail_closed
    Dir.mktmpdir do |dir|
      state = File.join(dir, "s.json")
      cfg = File.join(dir, "c.json")
      File.write(cfg, JSON.generate("requiredPlatforms" => %w[mac ios], "ios" => { "appId" => "1" }))
      run_cli("init", state, "--config", cfg, "--version", "2.0.0")
      run_cli("candidate", state, "--sha", SHA, "--run-id", "1")
      env = ENV.to_h.reject { |k, _| k.start_with?("APP_STORE_CONNECT_", "PLAY_") }
      _, err, status = Open3.capture3(env, "ruby", CLI, "monitor", state, "--config", cfg, "--stores", "live")
      refute status.success?
      assert_match(/App Store Connect credentials are not configured/, err)
    end
  end
end
