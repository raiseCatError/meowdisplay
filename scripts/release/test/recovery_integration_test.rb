# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "fileutils"
require "json"
require "digest"

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

  SITE = "raiseCatError/MeowDisplayWebsite"
  SITE_HEAD = "38426be3e61f4592cd2e3c313b606ea54f72c930"
  PROD = "https://meowdisplay.app"
  CHALLENGE_HEADERS = "HTTP/2 403\r\ncontent-type: text/html; charset=UTF-8\r\ncf-mitigated: challenge\r\nserver: cloudflare\r\n\r\n"

  # Only the network is stubbed: gh answers from fixture files, curl serves
  # status/headers/body per URL (query string ignored) and honours -f, -D, -o, -w.
  def stub_bin(dir, release_json:, latest: "v2.1.0")
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(File.join(bin, "site/files"))
    File.write(File.join(bin, "release.json.mock"), release_json)
    File.write(File.join(bin, "gh"), <<~SH)
      #!/usr/bin/env bash
      echo "gh $*" >> "#{bin}/gh.log"
      case "$*" in
        "api repos/raiseCatError/meowdisplay/releases/442117184") cat "#{bin}/release.json.mock" ;;
        "api repos/raiseCatError/meowdisplay/releases/latest --jq .tag_name") echo "#{latest}" ;;
        "api repos/raiseCatError/meowdisplay/commits/v2.1.0 --jq .sha") echo "#{CANDIDATE}" ;;
        "api repos/#{SITE}/commits/main --jq .sha") cat "#{bin}/site/head" ;;
        "api -H Accept: application/vnd.github.raw repos/#{SITE}/contents/"*)
          path=${4#repos/#{SITE}/contents/}; path=${path%%[?]ref=*}
          [ "${4##*[?]ref=}" = "$(cat "#{bin}/site/head")" ] || exit 1
          cat "#{bin}/site/files/$path" ;;
        *) echo "unexpected gh $*" >&2; exit 1 ;;
      esac
    SH
    File.write(File.join(bin, "curl"), <<~SH)
      #!/usr/bin/env bash
      echo "curl $*" >> "#{bin}/curl.log"
      hdr= out= fmt= url= fail=
      while [ $# -gt 0 ]; do
        case "$1" in
          -D) hdr=$2; shift ;; -o) out=$2; shift ;; -w) fmt=$2; shift ;; --max-time) shift ;;
          --*) ;; -*f*) fail=1 ;; -*) ;; *) url=$1 ;;
        esac
        shift
      done
      key=$(printf '%s' "${url%%[?]*}" | tr -c 'A-Za-z0-9._-' '_')
      d="#{bin}/www/$key"
      code=$(cat "$d/code" 2>/dev/null || echo 404)
      [ -z "$hdr" ] || cat "$d/headers" > "$hdr" 2>/dev/null || : > "$hdr"
      if [ -n "$out" ]; then cat "$d/body" > "$out" 2>/dev/null || : > "$out"; else cat "$d/body" 2>/dev/null; fi
      [ -z "$fmt" ] || printf '%s' "$code"
      [ -n "$fail" ] && [ "$code" -ge 400 ] && exit 22
      exit 0
    SH
    FileUtils.chmod(0o755, File.join(bin, "gh"))
    FileUtils.chmod(0o755, File.join(bin, "curl"))
    bin
  end

  def web(bin, url, body, code: 200, headers: "HTTP/2 #{code}\r\n\r\n")
    d = File.join(bin, "www", url.gsub(/[^A-Za-z0-9._-]/, "_"))
    FileUtils.mkdir_p(d)
    File.write(File.join(d, "code"), code.to_s)
    File.write(File.join(d, "headers"), headers)
    File.write(File.join(d, "body"), body)
  end

  # The website's main HEAD (the repository files the site-evidence job saves)
  # and the production origin, whose release.json Bot Fight Mode challenges
  # (as it does for GitHub runners) while llms.txt and site.js are served.
  def site(bin, manifest, prod_llms: "llms 2.1\n", prod_llms_code: 200, prod_manifest: :challenge)
    File.write(File.join(bin, "site/head"), "#{SITE_HEAD}\n")
    files = { "release.json" => manifest, "llms.txt" => "llms 2.1\n", "site.js" => "/* site 2.1 */\n" }
    files.each { |name, body| File.write(File.join(bin, "site/files", name), body) }
    web(bin, "#{PROD}/llms.txt", prod_llms, code: prod_llms_code)
    web(bin, "#{PROD}/site.js", files["site.js"])
    case prod_manifest
    when :challenge then web(bin, "#{PROD}/release.json", "<title>Just a moment...</title>", code: 403, headers: CHALLENGE_HEADERS)
    when :forbidden then web(bin, "#{PROD}/release.json", "forbidden", code: 403)
    else web(bin, "#{PROD}/release.json", prod_manifest)
    end
  end

  # The site-evidence job's step, run for real against the stubbed website API.
  def site_evidence(work, bin, origin)
    dir = File.join(File.dirname(bin), "site-evidence")
    out, err, status = reconcile(work, bin, origin, "--site-evidence", { "RELEASE_STATE_TOKEN" => "" }, dir)
    assert status.success?, "#{out}\n#{err}"
    dir
  end

  # The manifest release-state generates, through the real --manifest-only path.
  def generated_manifest(work, bin, origin)
    out, err, status = reconcile(work, bin, origin, "--manifest-only")
    assert status.success?, "#{out}\n#{err}"
    json = out[/^\{\n.*?^\}$/m]
    JSON.parse(json)
    json + "\n"
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

  def reconcile(work, bin, origin, mode, extra = {}, *args)
    env = { "PATH" => "#{bin}:#{ENV['PATH']}", "RUNNER_TEMP" => File.dirname(bin), "GH_TOKEN" => "read-token",
            "RELEASE_STATE_TOKEN" => "app-token", "RELEASE_STATE_REMOTE" => "file://#{origin}",
            "GITHUB_REPOSITORY" => "raiseCatError/meowdisplay", "VERSION" => "2.1.0", "CANDIDATE_SHA" => CANDIDATE }
    # Executed directly, exactly as the workflow step does.
    Open3.capture3(env.merge(extra), File.join(work, "scripts/release/reconcile-mac-release.sh"), mode, *args)
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
    with_fixture do |origin, work, bin|
      _, _, status = reconcile(work, bin, origin, "--execute")
      assert status.success?
      manifest = generated_manifest(work, bin, origin)
      site(bin, manifest, prod_manifest: '{"version":"2.0.0"}')
      before = state_commits(origin)
      out, err, status = reconcile(work, bin, origin, "--finish")
      refute status.success?
      assert_includes out + err, "serves version '2.0.0', not 2.1.0; deploy the website first (nothing recorded)"
      assert_equal before, state_commits(origin)

      web(bin, "#{PROD}/release.json", manifest)
      out, err, status = reconcile(work, bin, origin, "--finish", "PROMOTION_PR" => "250")
      assert status.success?, "#{out}\n#{err}"
      assert_includes out, "fetched directly (version 2.1.0)"
      refute_match(/check-runs/, File.read(File.join(bin, "gh.log")), "a direct fetch needs no deployment evidence")
      state = remote_state(origin)
      assert_equal "published", state.dig("publication", "stage")
      assert_equal 250, state.dig("publication", "promotionPr")
      assert_equal "published", state.dig("website", "stage")

      out, err, status = reconcile(work, bin, origin, "--finish")
      assert status.success?, "#{out}\n#{err}"
      assert_includes out, "already recorded as published"
    end
  end

  # Run 43125145760: Bot Fight Mode challenged the runner on release.json.
  def finish_through_challenge(sha: :site, manifest: nil, evidence: true, tamper: nil, **site_options)
    with_fixture do |origin, work, bin|
      _, _, status = reconcile(work, bin, origin, "--execute")
      assert status.success?
      manifest ||= generated_manifest(work, bin, origin)
      site(bin, manifest, **site_options)
      dir = evidence ? site_evidence(work, bin, origin) : ""
      tamper&.call(dir)
      sha = Digest::SHA256.hexdigest(manifest) if sha == :site
      before = state_commits(origin)
      out, err, status = reconcile(work, bin, origin, "--finish",
                                   "LIVE_RELEASE_SHA256" => sha.to_s, "SITE_EVIDENCE_DIR" => dir)
      yield out + err, status, origin, before
    end
  end

  def assert_refused(text, status, origin, before, message)
    refute status.success?, text
    assert_includes text, message
    assert_includes text, "nothing recorded"
    assert_equal before, state_commits(origin), "nothing may be written"
    assert_equal "pending", remote_state(origin).dig("website", "stage")
    assert_equal "in-progress", remote_state(origin).dig("publication", "stage")
  end

  def test_site_evidence_saves_the_website_head_files_and_writes_nothing
    with_fixture do |origin, work, bin|
      site(bin, "{}\n")
      before = state_commits(origin)
      dir = site_evidence(work, bin, origin)
      assert_equal SITE_HEAD, File.read(File.join(dir, "head")).strip
      assert_equal "{}\n", File.read(File.join(dir, "release.json"))
      assert_equal "llms 2.1\n", File.read(File.join(dir, "llms.txt"))
      assert_equal "/* site 2.1 */\n", File.read(File.join(dir, "site.js"))
      assert_equal before, state_commits(origin)
      refute_match(/releases\/442117184|release edit/, File.read(File.join(bin, "gh.log")))
    end
  end

  def test_finish_through_a_challenge_with_complete_production_evidence
    finish_through_challenge do |text, status, origin, _|
      assert status.success?, text
      assert_includes text, "answered this runner with a Cloudflare challenge"
      assert_includes text, "website evidence: #{SITE} main HEAD #{SITE_HEAD}"
      assert_includes text, "main's release.json = release-state's manifest"
      assert_includes text, "production https://meowdisplay.app/llms.txt = main@#{SITE_HEAD[0, 12]}"
      assert_includes text, "production https://meowdisplay.app/site.js = main@#{SITE_HEAD[0, 12]}"
      state = remote_state(origin)
      assert_equal "published", state.dig("publication", "stage")
      assert_equal "published", state.dig("website", "stage")
      assert_equal "https://meowdisplay.app/release.json", state.dig("website", "url")
    end
  end

  def test_challenge_without_the_approvers_production_hash_records_nothing
    finish_through_challenge(sha: "") do |text, status, origin, before|
      assert_refused(text, status, origin, before, "live_release_sha256 is required here")
    end
  end

  def test_challenge_with_a_different_production_hash_records_nothing
    finish_through_challenge(sha: "1" * 64) do |text, status, origin, before|
      assert_refused(text, status, origin, before, "is not main@")
    end
  end

  def test_challenge_without_website_evidence_records_nothing
    finish_through_challenge(evidence: false) do |text, status, origin, before|
      assert_refused(text, status, origin, before, "no website evidence (SITE_EVIDENCE_DIR)")
    end
    finish_through_challenge(tamper: ->(dir) { File.delete(File.join(dir, "site.js")) }) do |text, status, origin, before|
      assert_refused(text, status, origin, before, "website evidence lacks site.js")
    end
  end

  def test_challenge_with_a_manifest_unlike_release_state_records_nothing
    finish_through_challenge(manifest: "{\"version\":\"2.1.0\",\"platforms\":{\"android\":{}}}\n") do |text, status, origin, before|
      assert_refused(text, status, origin, before, "is not what release-state describes")
    end
  end

  def test_challenge_when_production_serves_another_build_records_nothing
    finish_through_challenge(prod_llms: "llms 2.0\n") do |text, status, origin, before|
      assert_refused(text, status, origin, before, "production https://meowdisplay.app/llms.txt is not main@")
    end
  end

  def test_challenge_when_production_is_unreachable_records_nothing
    finish_through_challenge(prod_llms_code: 403) do |text, status, origin, before|
      assert_refused(text, status, origin, before, "answered HTTP 403; production unverified")
    end
  end

  def test_a_403_that_is_not_a_cloudflare_challenge_gets_no_fallback
    finish_through_challenge(prod_manifest: :forbidden) do |text, status, origin, before|
      assert_refused(text, status, origin, before, "answered HTTP 403 without a Cloudflare challenge")
      refute_includes text, "website evidence:"
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
