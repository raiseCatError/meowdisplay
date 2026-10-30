# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

# check-release-workflows.rb against deliberately broken copies of the real
# workflows: every safety property must be caught when it regresses.
class WorkflowChecksTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  CHECKER = File.join(ROOT, "scripts/release/check-release-workflows.rb")

  def check(mutations = {})
    Dir.mktmpdir do |dir|
      workflows = File.join(dir, "workflows")
      FileUtils.cp_r(File.join(ROOT, ".github/workflows"), workflows)
      sync = File.join(dir, "sync-reference.sh")
      FileUtils.cp(File.join(ROOT, "scripts/reference/sync-reference.sh"), sync)
      mutations.each do |file, (from, to)|
        path = file == "sync-reference.sh" ? sync : File.join(workflows, file)
        text = File.read(path)
        assert text.include?(from), "mutation target not found in #{file}: #{from}"
        File.write(path, text.sub(from, to))
      end
      out, status = Open3.capture2e("ruby", CHECKER, workflows, sync)
      [status.success?, out]
    end
  end

  def assert_caught(message, mutations)
    ok, out = check(mutations)
    refute ok, "not caught: #{mutations.inspect}\n#{out}"
    assert_includes out, message
  end

  def test_the_real_workflows_pass
    ok, out = check
    assert ok, out
  end

  def test_a_release_from_the_wrong_branch_is_caught
    assert_caught("guard must reject any ref but release/<version>",
                  "release-publish.yml" => ['"refs/heads/release/$VERSION") ;;', 'refs/heads/*) ;;'])
    assert_caught("must run only on push to release/**",
                  "release-candidate.yml" => ["branches: ['release/**']", "branches: ['**']"])
    assert_caught("release-please must target the release branch it runs on",
                  "release-pr.yml" => ["target-branch: ${{ github.ref_name }}", "target-branch: main"])
  end

  def test_publishing_an_older_commit_is_caught
    assert_caught("guard must require the branch to be at the candidate commit",
                  "release-publish.yml" => ['[ "$GITHUB_SHA" = "$SHA" ] ||', "true ||"])
    assert_caught("plan must record the candidate SHA before anything builds",
                  "release-candidate.yml" => ['candidate STATE --sha "$GITHUB_SHA"', 'candidate STATE --sha "$OLD"'])
  end

  def test_an_incomplete_latest_release_is_caught
    assert_caught("publish-mac must create the release as a draft first",
                  "release-publish.yml" => ['--draft --target "$SHA"', '--target "$SHA"'])
    assert_caught("publish-mac must verify the draft's assets before Latest",
                  "release-publish.yml" => ['gh release download "v$VERSION"', 'echo download "v$VERSION"'])
    assert_caught("publish-mac must revert Latest when the live feeds don't verify",
                  "release-publish.yml" => ['--draft=true', '--draft=false-ish'])
    assert_caught("publish-mac must open the gate (publish start) before publishing",
                  "release-publish.yml" => ["publish start STATE", "summary STATE"])
    assert_caught("only publish-mac may touch tags, releases or assets",
                  "release-publish.yml" => ["out=$(scripts/release/release-state.sh", "gh release edit v0 --latest\n          out=$(scripts/release/release-state.sh"])
  end

  def test_unreviewed_publication_is_caught
    assert_caught("publish-mac must check release-publish's reviewers before the gate",
                  "release-publish.yml" => ["scripts/release/check-environment.sh release-publish --require-reviewers",
                                            "scripts/release/check-environment.sh release-publish"])
    assert_caught("may skip the reviewer check only when both auto-publish switches are set",
                  "release-publish.yml" => ['[ "$AUTO_SWITCH" = auto-publish-after-approval ]', "true"])
  end

  def test_an_older_sparkle_build_or_an_incompatible_key_is_caught
    assert_caught("key-continuity must check the build number against the live feeds",
                  "release-mac.yml" => ['scripts/release/check-build-number.sh "$VERSION" "$LIVE_FEED_BASE/$SENDER_FEED"', "true"])
    assert_caught("key-continuity must check the Sparkle key against the published apps",
                  "release-mac.yml" => ["scripts/release/check-sparkle-key.sh", "scripts/release/true.sh"])
    assert_caught("staged feeds must be kept 30 days",
                  "release-mac.yml" => ["          name: feeds\n          path: feeds/\n          retention-days: 30",
                                        "          name: feeds\n          path: feeds/\n          retention-days: 3"])
  end

  def test_secrets_outside_a_checked_environment_are_caught
    assert_caught("uses secrets outside an allowed environment",
                  "release-pr.yml" => ["    environment: release-pr\n", ""])
    assert_caught("must run check-environment.sh ios-upload before using secrets",
                  "release-ios.yml" => ["run: scripts/release/check-environment.sh ios-upload", "run: true"])
    assert_caught("must run check-environment.sh release-pr before using secrets",
                  "release-publish.yml" => ["run: scripts/release/check-environment.sh release-pr", "run: true"])
  end

  def test_secrets_used_after_a_failed_environment_check_are_caught
    assert_caught("uses secrets even when check-environment.sh failed",
                  "release-dry-run.yml" => ["if: ${{ !cancelled() && steps.protected.outcome == 'success' }}\n        env:\n          DEVELOPMENT_TEAM",
                                            "if: ${{ !cancelled() }}\n        env:\n          DEVELOPMENT_TEAM"])
    assert_caught("exposes secrets in job-level env",
                  "release-dry-run.yml" => ["    environment: release-build\n",
                                            "    environment: release-build\n    env:\n      KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}\n"])
  end

  def test_the_external_reference_never_merges_or_imports_tags
    assert_caught("merges or proposes the external reference into MeowDisplay",
                  "tests.yml" => ["      - name: Workflows stay fail-closed",
                                  "      - name: sneak\n        run: git merge origin/reference/opendisplay\n      - name: Workflows stay fail-closed"])
    assert_caught("every fetch must use --no-tags",
                  "sync-reference.sh" => ['git_ fetch -q --no-tags "$external"', 'git_ fetch -q "$external"'])
    assert_caught("must push only reference/opendisplay, without force",
                  "sync-reference.sh" => ['git_ push -q "$origin"', 'git_ push -q --force "$origin"'])
    assert_caught("publishes (git push origin --tags)",
                  "reference-sync.yml" => ['run: scripts/reference/sync-reference.sh "$EXPECTED"',
                                           "run: git push origin --tags"])
  end

  def test_repository_setting_changes_are_caught
    assert_caught("changes repository settings",
                  "repository-guard.yml" => ["run: scripts/release/check-repository.sh",
                                             "run: gh repo edit --default-branch dev"])
    assert_caught("changes repository settings",
                  "release-monitor.yml" => ["state monitor STATE",
                                            "gh api -X PUT repos/x/y/rulesets/1 --input r.json\n            state monitor STATE"])
  end

  def test_schedules_stay_off_until_enabled
    assert_caught("must run on schedule only while vars.RELEASE_AUTOMATION is enabled",
                  "release-monitor.yml" => ["|| vars.RELEASE_AUTOMATION == 'enabled'", "|| true"])
    assert_caught("must run on schedule only while vars.REFERENCE_SYNC is enabled",
                  "reference-sync.yml" => ["|| vars.REFERENCE_SYNC == 'enabled'", ""])
  end

  def test_supply_chain_and_injection_rules_are_caught
    assert_caught("is not pinned to a commit SHA",
                  "release-ios.yml" => ["actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6", "actions/checkout@v6"])
    assert_caught("pass inputs through env, not ${{ }} inside run",
                  "release-publish.yml" => ['run: gh release edit "v$VERSION"', 'run: gh release edit "v${{ inputs.version }}"'])
    assert_caught("release-please must set skip-github-release: true",
                  "release-pr.yml" => ["skip-github-release: true", "skip-github-release: false"])
  end

  # The release state is written by GitHub Actions, so publication trusts
  # only the stores, the candidate run's provenance and its own checks.
  def test_forged_release_state_cannot_publish_unverified_artifacts
    assert_caught("publish-mac must check the candidate run's provenance before using its artifacts",
                  "release-publish.yml" => ['.github/workflows/release-candidate.yml $SHA release/$VERSION push', "anything"])
    assert_caught("publish-mac must verify the DMGs and feeds again before the draft",
                  "release-publish.yml" => ['scripts/release/verify-mac-artifact.sh "dist/$DMG"', 'true "dist/$DMG"'])
    assert_caught("publish-mac must wait for verify-stores (live store approvals)",
                  "release-publish.yml" => ["needs: [guard, verify-stores]", "needs: [guard]"])
    assert_caught("verify-stores must observe the stores live and then pass the gate",
                  "release-publish.yml" => ['state gate STATE --branch-head "$SHA"', "true"])
    assert_caught("only release workflows may touch the release state",
                  "repository-guard.yml" => ["run: scripts/release/check-repository.sh",
                                             "run: scripts/release/release-state.sh 2.0.0 record STATE"])
  end

  def test_platform_workflows_never_publish_or_submit
    assert_caught("touches a store's review or release",
                  "release-ios.yml" => ["bundle exec fastlane ios upload_candidate", "bundle exec fastlane ios release && submit_for_review"])
    assert_caught("stores must wait for publish-mac (or a resume)",
                  "release-publish.yml" => ["(needs.publish-mac.result == 'success' || inputs.resume)", "(inputs.resume || true)"])
  end
end
