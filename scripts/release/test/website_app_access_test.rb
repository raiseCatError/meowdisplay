# frozen_string_literal: true

require_relative "test_helper"
require "base64"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

# check-website-app-access.sh against a stand-in `gh`: it passes only when the website
# App's installation and token look right, reads only, and never prints a token.
class WebsiteAppAccessTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  SCRIPT = File.join(ROOT, "scripts/release/check-website-app-access.sh")
  SITE = "site-token-#{'s' * 20}"
  SCOPE = "scope-token-#{'m' * 20}"
  REPO = "raiseCatError/MeowDisplayWebsite"

  # Answers like `gh api ... --jq ...` for the requests the script makes, logs every call,
  # and refuses the wrong token for each request.
  GH = <<~'SH'
    #!/usr/bin/env bash
    echo "$*" >> "$STUB_LOG"
    [ "$1" = api ] || exit 9
    case "$*" in
      *installation/repositories*) [ "$GH_TOKEN" = "$STUB_SCOPE" ] || exit 4; printf '%s\n' $STUB_REPOS ;;
      *"/contents/scripts/package.py?ref=main"*) [ "$GH_TOKEN" = "$STUB_SITE" ] || exit 4; printf '%s' "$STUB_PACKAGE" | base64 | fold -w 60 ;;
      *"/branches/main"*) [ "$GH_TOKEN" = "$STUB_SITE" ] || exit 4; echo main ;;
      *"/pulls?state=all&per_page=1"*) [ "$GH_TOKEN" = "$STUB_SITE" ] || exit 4; echo 0 ;;
      "api repos/$STUB_REPO --jq .full_name") [ "$GH_TOKEN" = "$STUB_SITE" ] || exit 4; echo "$STUB_NAME" ;;
      *) exit 7 ;;
    esac
    [ "${STUB_FAIL:-}" = "" ] || ! grep -q -- "$STUB_FAIL" <<< "$*" || exit 1
  SH

  def run_check(repos: REPO, name: REPO, package: "copy release.json into dist", fail: nil, config: nil)
    Dir.mktmpdir do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      File.write(File.join(bin, "gh"), GH)
      File.chmod(0o755, File.join(bin, "gh"))
      cfg = File.join(dir, "release-config.json")
      File.write(cfg, JSON.generate(config || { "website" => { "repository" => REPO, "branch" => "main" } }))
      log = File.join(dir, "gh.log")
      env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "SITE_TOKEN" => SITE, "INSTALLATION_SCOPE_TOKEN" => SCOPE,
              "APP_SLUG" => "meowdisplay-website", "STUB_LOG" => log, "STUB_SITE" => SITE, "STUB_SCOPE" => SCOPE,
              "STUB_REPO" => REPO, "STUB_REPOS" => repos, "STUB_NAME" => name, "STUB_PACKAGE" => package,
              "STUB_FAIL" => fail.to_s }
      out, status = Open3.capture2e(env, "bash", SCRIPT, cfg)
      [status.success?, out, File.exist?(log) ? File.read(log) : ""]
    end
  end

  def test_a_correct_installation_passes
    ok, out, = run_check
    assert ok, out
    assert_includes out, "website App: meowdisplay-website"
    assert_includes out, "installation reaches #{REPO} only"
    assert_includes out, "#{REPO} deploys release.json"
    assert_includes out, "Not exercised"
  end

  def test_it_only_reads_and_never_prints_a_token
    ok, out, log = run_check
    assert ok, out
    refute_match(/-X|--method|-f |-F |--field|--input|POST|PUT|PATCH|DELETE/, log)
    [SITE, SCOPE].each { |token| refute_includes out, token }
    _, out, = run_check(repos: "#{REPO} raiseCatError/meowdisplay")
    [SITE, SCOPE].each { |token| refute_includes out, token }
  end

  def test_an_installation_on_other_repositories_fails
    ok, out, = run_check(repos: "#{REPO} raiseCatError/meowdisplay")
    refute ok
    assert_includes out, "install it on #{REPO} only"
    ok, out, = run_check(repos: "raiseCatError/meowdisplay")
    refute ok
    assert_includes out, "install it on #{REPO} only"
  end

  def test_unreadable_site_fails
    { "/branches/main" => "can't read #{REPO}'s main branch",
      "/pulls" => "can't read #{REPO}'s pull requests",
      "package.py" => "can't read scripts/package.py" }.each do |request, message|
      ok, out, = run_check(fail: request)
      refute ok, request
      assert_includes out, message
    end
    ok, out, = run_check(name: "someone/else")
    refute ok
    assert_includes out, "reads 'someone/else'"
  end

  def test_a_site_that_does_not_deploy_the_manifest_fails
    ok, out, = run_check(package: "copy pages into dist")
    refute ok
    assert_includes out, "doesn't deploy release.json yet"
  end

  def test_missing_tokens_or_a_bad_config_fail
    Dir.mktmpdir do |dir|
      cfg = File.join(dir, "c.json")
      File.write(cfg, JSON.generate("website" => { "repository" => REPO }))
      _, status = Open3.capture2e({ "SITE_TOKEN" => "", "INSTALLATION_SCOPE_TOKEN" => SCOPE }, "bash", SCRIPT, cfg)
      refute status.success?
    end
    ok, out, = run_check(config: { "website" => { "repository" => "not a repo" } })
    refute ok
    assert_includes out, "bad website repository"
  end
end
