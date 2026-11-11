# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "json"

# The 2.1.0 Mac recovery's production paths, as the workflow runs them:
# scripts executed directly (their Git mode matters, run 43117186436), the
# real reconcile-mac-release.sh -> release-state.sh -> meow-release state
# machine and real git against local remotes seeded with the actual frozen
# candidate commit and the actual recorded state (publication failed, Mac
# approved, iOS published). Only the GitHub REST API (gh) and the website
# fetch (curl) are stubbed.
class RecoveryIntegrationTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  RELEASE_DIR = File.join(ROOT, "scripts/release")
  CANDIDATE = "94c796fc34fd699776764d67d2f26013909a308e"
  UPSTREAM = "https://github.com/raiseCatError/meowdisplay"
  SUMS = "279e22555e9a84a4fc59bd7d529f4efca6ccf2a8c986ac9fc939d627368bc1b7"
  FIXTURE_STATE = File.join(__dir__, "fixtures/release-state-2.1.0-failed.json")
  GIT_ID = ["-c", "user.name=test", "-c", "user.email=test@example.invalid"].freeze

  # MARK: - Executable modes, from Git

  def git_mode(path)
    out, status = Open3.capture2("git", "-C", ROOT, "ls-files", "-s", "--", path)
    assert status.success?, "git ls-files failed for #{path}"
    out.split(" ").first
  end

  def test_every_script_the_recovery_executes_is_tracked_executable
    workflow = File.read(File.join(ROOT, ".github/workflows/recover-mac-release.yml"))
    direct = workflow.scan(%r{^\s*(scripts/[A-Za-z0-9_./-]+)}).flatten.uniq
    assert_includes direct, "scripts/release/reconcile-mac-release.sh"
    assert_includes direct, "scripts/release/recover-mac-release.sh"
    called = %w[check-environment.sh release-state.sh meow-release published-baseline.sh check-build-number.sh
                verify-mac-artifact.sh verify-feed.sh].map { |f| "scripts/release/#{f}" }
    (direct + called).uniq.each do |path|
      assert_equal "100755", git_mode(path), "#{path} must be tracked as 100755 (git update-index --chmod=+x #{path})"
      assert File.executable?(File.join(ROOT, path)), "#{path} is not executable in this checkout"
    end
  end

  # MARK: - Real state machine against local remotes

  def setup_remotes(dir, state_json)
    origin = File.join(dir, "origin.git")
    system("git", "init", "-q", "--bare", origin, exception: true)
    # The real, immutable candidate commit (public repository; one commit).
    _, err, status = Open3.capture3("git", "-C", origin, "fetch", "-q", "--depth", "1", "--no-tags", UPSTREAM,
                                    "+refs/heads/release/2.1.0:refs/heads/release/2.1.0")
    unless status.success?
      flunk("cannot fetch the frozen candidate: #{err}") if ENV["CI"]
      skip("network unavailable for the frozen candidate fetch: #{err.lines.first}")
    end
    head, = Open3.capture2("git", "-C", origin, "rev-parse", "refs/heads/release/2.1.0")
    assert_equal CANDIDATE, head.strip, "release/2.1.0 moved off the frozen candidate"

    seed = File.join(dir, "seed")
    system("git", "init", "-q", seed, exception: true)
    system("git", "-C", seed, "checkout", "-q", "--orphan", "release-state", exception: true)
    FileUtils.mkdir_p(File.join(seed, "releases"))
    File.write(File.join(seed, "releases/2.1.0.json"), state_json)
    system("git", "-C", seed, "add", "-A", exception: true)
    system("git", "-C", seed, *GIT_ID, "commit", "-q", "-m", "seed", exception: true)
    system("git", "-C", seed, "push", "-q", origin, "HEAD:refs/heads/release-state", exception: true)

    # The workflow's checkout: the scripts, unchanged and with their modes,
    # in a repository whose origin is the local remote.
    # A shallow clone, like actions/checkout's default (fetch-depth 1, no
    # credential persisted); the local remote is itself shallow, so the clone
    # must already know its boundary commits.
    work = File.join(dir, "work")
    system("git", "clone", "-q", "--depth", "1", "--no-single-branch", "--no-checkout", "--no-tags",
           "file://#{origin}", work, exception: true)
    FileUtils.mkdir_p(File.join(work, "scripts"))
    FileUtils.cp_r(RELEASE_DIR, File.join(work, "scripts"), preserve: true)
    [origin, work]
  end

  def stub_bin(dir, release_json:, latest: "v2.1.0", site: '{"version":"2.1.0"}')
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    File.write(File.join(bin, "release.json.mock"), release_json)
    File.write(File.join(bin, "gh"), <<~SH)
      #!/usr/bin/env bash
      echo "gh $*" >> "#{bin}/gh.log"
      case "$*" in
        "api repos/raiseCatError/meowdisplay/releases/442117184") cat "#{bin}/release.json.mock" ;;
        "api repos/raiseCatError/meowdisplay/releases/latest --jq .tag_name") echo "#{latest}" ;;
        "api repos/raiseCatError/meowdisplay/commits/v2.1.0 --jq .sha") echo "#{CANDIDATE}" ;;
        *) echo "unexpected gh $*" >&2; exit 1 ;;
      esac
    SH
    File.write(File.join(bin, "curl"), "#!/usr/bin/env bash\necho '#{site}'\n")
    FileUtils.chmod(0o755, File.join(bin, "gh"))
    FileUtils.chmod(0o755, File.join(bin, "curl"))
    bin
  end

  def recorded
    @recorded ||= JSON.parse(File.read(FIXTURE_STATE))
  end

  def published_release(draft: false, tamper: nil)
    assets = recorded.dig("platforms", "mac", "artifacts").map { |a| [a["name"], a["sha256"]] }
    assets << ["SHA256SUMS.txt", SUMS]
    assets.map! { |n, h| [n, n == tamper ? "0" * 64 : h] }
    { "id" => 442_117_184, "tag_name" => "v2.1.0", "draft" => draft, "target_commitish" => CANDIDATE,
      "assets" => assets.map { |n, h| { "name" => n, "digest" => "sha256:#{h}" } } }.to_json
  end

  def reconcile(work, bin, origin, mode, extra = {})
    env = { "PATH" => "#{bin}:#{ENV['PATH']}", "RUNNER_TEMP" => File.dirname(bin), "GH_TOKEN" => "read-token",
            "RELEASE_STATE_TOKEN" => "app-token", "RELEASE_STATE_REMOTE" => "file://#{origin}",
            "GITHUB_REPOSITORY" => "raiseCatError/meowdisplay", "VERSION" => "2.1.0", "CANDIDATE_SHA" => CANDIDATE }
    # Executed directly, exactly as the workflow step does.
    Open3.capture3(env.merge(extra), File.join(work, "scripts/release/reconcile-mac-release.sh"), mode)
  end

  def remote_state(origin)
    JSON.parse(`git -C #{origin} show refs/heads/release-state:releases/2.1.0.json`)
  end

  def state_commits(origin)
    `git -C #{origin} rev-list --count refs/heads/release-state`.to_i
  end

  def with_fixture(release_json: published_release, **stub)
    Dir.mktmpdir("recovery-it-", scratch_base) do |dir|
      origin, work = setup_remotes(dir, File.read(FIXTURE_STATE))
      yield origin, work, stub_bin(dir, release_json: release_json, **stub)
    end
  end

  def scratch_base
    File.directory?("/Volumes/T7Tmp/ai-dev/tmp") ? "/Volumes/T7Tmp/ai-dev/tmp" : Dir.tmpdir
  end

  def test_fixture_is_the_recorded_failed_publication
    assert_equal "failed", recorded.dig("publication", "stage")
    assert_equal "approved", recorded.dig("platforms", "mac", "stage")
    assert_equal "published", recorded.dig("platforms", "ios", "stage")
    assert_equal %w[mac ios], recorded["requiredPlatforms"]
    assert_equal CANDIDATE, recorded.dig("candidate", "sha")
  end

  def test_preflight_runs_the_real_gate_on_the_frozen_candidate_and_writes_nothing
    with_fixture do |origin, work, bin|
      before = state_commits(origin)
      out, err, status = reconcile(work, bin, origin, "--preflight", "RELEASE_STATE_TOKEN" => "")
      assert status.success?, "#{out}\n#{err}"
      assert_includes out, "Approved candidate config verified: Mac + iOS; Android excluded"
      assert_includes out, "Read-only preflight passed"
      assert_equal before, state_commits(origin)
      refute File.exist?(File.join(bin, "gh.log")), "preflight must not call the GitHub API"
    end
  end

  def test_reconcile_moves_failed_to_in_progress_and_records_mac_then_is_idempotent
    with_fixture do |origin, work, bin|
      out, err, status = reconcile(work, bin, origin, "--execute")
      assert status.success?, "#{out}\n#{err}"
      state = remote_state(origin)
      assert_equal "in-progress", state.dig("publication", "stage")
      assert_equal "published", state.dig("platforms", "mac", "stage")
      assert_equal "https://github.com/raiseCatError/meowdisplay/releases/tag/v2.1.0", state.dig("platforms", "mac", "releaseUrl")
      assert_equal "published", state.dig("platforms", "ios", "stage")
      assert_equal "READY_FOR_DISTRIBUTION", state.dig("platforms", "ios", "storeState")
      assert_equal "pending", state.dig("platforms", "android", "stage"), "Android is excluded and untouched"
      assert_includes out, '"mac"'
      refute_includes out, '"android"'
      gh_calls = File.read(File.join(bin, "gh.log"))
      refute_match(/release (edit|create|upload|delete)|-X (POST|PATCH|PUT|DELETE)/, gh_calls)

      # A re-run (e.g. a retried job) changes nothing.
      commits = state_commits(origin)
      out, err, status = reconcile(work, bin, origin, "--execute")
      assert status.success?, "re-run: #{out}\n#{err}"
      assert_equal commits, state_commits(origin)
    end
  end

  def test_reconcile_writes_nothing_while_the_release_is_still_a_draft
    with_fixture(release_json: published_release(draft: true)) do |origin, work, bin|
      before = state_commits(origin)
      out, err, status = reconcile(work, bin, origin, "--execute")
      refute status.success?
      assert_includes out + err, "is still a draft: nothing was published"
      assert_equal before, state_commits(origin)
      assert_equal "failed", remote_state(origin).dig("publication", "stage")
    end
  end

  def test_reconcile_writes_nothing_when_a_live_asset_differs_from_the_record
    with_fixture(release_json: published_release(tamper: "MeowDisplay.dmg")) do |origin, work, bin|
      before = state_commits(origin)
      out, err, status = reconcile(work, bin, origin, "--execute")
      refute status.success?
      assert_includes out + err, "live assets of v2.1.0 are"
      assert_equal before, state_commits(origin)
    end
  end

  def test_reconcile_writes_nothing_when_another_release_is_latest
    with_fixture(latest: "v2.0.0") do |origin, work, bin|
      before = state_commits(origin)
      out, err, status = reconcile(work, bin, origin, "--execute")
      refute status.success?
      assert_includes out + err, "Latest release is 'v2.0.0', expected 'v2.1.0'"
      assert_equal before, state_commits(origin)
    end
  end

  def test_finish_needs_the_live_site_then_finishes_once
    with_fixture(site: '{"version":"2.0.0"}') do |origin, work, bin|
      _, _, status = reconcile(work, bin, origin, "--execute")
      assert status.success?
      before = state_commits(origin)
      out, err, status = reconcile(work, bin, origin, "--finish")
      refute status.success?
      assert_includes out + err, "serves version '2.0.0', not 2.1.0; deploy the website first (nothing recorded)"
      assert_equal before, state_commits(origin)

      File.write(File.join(bin, "curl"), "#!/usr/bin/env bash\necho '{\"version\":\"2.1.0\"}'\n")
      out, err, status = reconcile(work, bin, origin, "--finish", "PROMOTION_PR" => "250")
      assert status.success?, "#{out}\n#{err}"
      state = remote_state(origin)
      assert_equal "published", state.dig("publication", "stage")
      assert_equal 250, state.dig("publication", "promotionPr")
      assert_equal "published", state.dig("website", "stage")

      out, err, status = reconcile(work, bin, origin, "--finish")
      assert status.success?, "#{out}\n#{err}"
      assert_includes out, "already recorded as published"
    end
  end

  def test_finish_refuses_before_reconcile
    with_fixture do |origin, work, bin|
      out, err, status = reconcile(work, bin, origin, "--finish")
      refute status.success?
      assert_includes out + err, "finish needs publication in-progress with Mac published (run action=reconcile first)"
    end
  end
end
