# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

class RecoverMacReleaseTest < Minitest::Test
  SCRIPT = File.expand_path("../recover-mac-release.sh", __dir__)
  RECONCILE_SCRIPT = File.expand_path("../reconcile-mac-release.sh", __dir__)
  VALID_SHA = "94c796fc34fd699776764d67d2f26013909a308e"
  VALID_DRAFT_ID = "442117184"
  EXPECTED_SUMS_HASH = "279e22555e9a84a4fc59bd7d529f4efca6ccf2a8c986ac9fc939d627368bc1b7"
  DMG1_HASH = "d02273969b8a00fc7269f69ab6440bae92028bcb55b9e5f4765cb5d925e8c316"
  DMG2_HASH = "4981863429e85dacf916287e466867ff1c38c838bc364c0ae483739b8d17eaf7"
  FEED1_HASH = "b97d8bdddec17083407dbc08bc23052b84d6d3f7440ddfd6e4443d78f50548d5"
  FEED2_HASH = "306cd1cbc1f415bf7668892be261907ea66f0a381a56b7f6921c3e6758f36609"

  def with_scratch_dir
    base = File.directory?("/Volumes/T7Tmp/ai-dev/tmp") ? "/Volumes/T7Tmp/ai-dev/tmp" : Dir.tmpdir
    Dir.mktmpdir("recover-test-", base) do |dir|
      yield dir
    end
  end

  def run_recovery(args = [], env = {})
    default_env = {
      "GH_TOKEN" => "mock-token",
      "FEED_POLL_SLEEP" => "0"
    }
    Open3.capture3(default_env.merge(env), "bash", SCRIPT, *args)
  end

  def run_reconcile(args = [], env = {})
    default_env = {
      "GH_TOKEN" => "mock-token"
    }
    Open3.capture3(default_env.merge(env), "bash", RECONCILE_SCRIPT, *args)
  end

  def test_input_pinning_rejects_differing_version_or_sha_or_draft_or_repo
    out, err, status = Open3.capture3({ "VERSION" => "2.2.0" }, "bash", SCRIPT)
    refute status.success?
    assert_includes err + out, "VERSION must be '2.1.0'"
    assert_includes err + out, "rejected"

    out, err, status = Open3.capture3({ "CANDIDATE_SHA" => "1111111111111111111111111111111111111111" }, "bash", SCRIPT)
    refute status.success?
    assert_includes err + out, "CANDIDATE_SHA must be '94c796fc34fd699776764d67d2f26013909a308e'"
    assert_includes err + out, "rejected"

    out, err, status = Open3.capture3({ "DRAFT_ID" => "99999999" }, "bash", SCRIPT)
    refute status.success?
    assert_includes err + out, "DRAFT_ID must be '442117184'"
    assert_includes err + out, "rejected"

    out, err, status = Open3.capture3({ "GITHUB_REPOSITORY" => "other/repo" }, "bash", SCRIPT)
    refute status.success?
    assert_includes err + out, "GITHUB_REPOSITORY must be 'raiseCatError/meowdisplay'"
    assert_includes err + out, "rejected"
  end

  def test_local_execution_refuses_publish_mode
    env = {
      "GITHUB_ACTIONS" => "false",
      "GITHUB_RUN_ID" => ""
    }
    out, err, status = Open3.capture3(env, "bash", SCRIPT, "--publish")
    refute status.success?
    assert_includes err + out, "Local execution is verification-only (--verify)"
    assert_includes err + out, "release-publish"
  end

  def test_unapproved_github_actions_run_refuses_publication
    with_scratch_dir do |bin_dir|
      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~'SH')
        #!/usr/bin/env bash
        case "$*" in
          *"check-environment"*)
            exit 0
            ;;
          *"deployment-branch-policies"*)
            if [[ "$*" == *"--jq"* ]]; then
              echo "branch:release/*"
            else
              echo '{"branch_policies":[{"name":"release/*","type":"branch"}]}'
            fi
            ;;
          *"environments/release-publish"*)
            echo '{"deployment_branch_policy":{"custom_branch_policies":true},"protection_rules":[{"type":"required_reviewers"}]}'
            ;;
          *"actions/runs/12345/approvals"*)
            echo '[]'
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      env = {
        "PATH" => "#{bin_dir}:#{ENV['PATH']}",
        "GITHUB_ACTIONS" => "true",
        "GITHUB_RUN_ID" => "12345",
        "RUNNER_TEMP" => bin_dir
      }
      out, err, status = Open3.capture3(env, "bash", SCRIPT, "--publish")
      refute status.success?
      assert_includes err + out, "Current GitHub Actions run 12345 has not received human approval for 'release-publish' from required reviewers"
    end
  end

  def test_stale_release_state_fetch_failure_halts_immediately
    with_scratch_dir do |bin_dir|
      mock_git = File.join(bin_dir, "git")
      File.write(mock_git, <<~'SH')
        #!/usr/bin/env bash
        if [[ "$*" == *"fetch"*"release-state"* ]]; then
          echo "fatal: unable to access network" >&2
          exit 1
        fi
        exec /usr/bin/git "$@"
      SH
      FileUtils.chmod(0o755, mock_git)

      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"releases/442117184")
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":true,"target_commitish":"#{VALID_SHA}"}'
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      out, err, status = run_recovery([], "PATH" => "#{bin_dir}:#{ENV['PATH']}", "RUNNER_TEMP" => bin_dir)
      refute status.success?
      assert_includes err + out, "Failed to fetch origin/release-state from remote"
      assert_includes err + out, "Relying on stale local state is prohibited"
    end
  end

  def test_scratch_volume_enforcement_locally
    # 1. Arbitrary T7_RUN_DIR outside /Volumes/T7Tmp/ai-dev is rejected
    with_scratch_dir do |bin_dir|
      mock_mount = File.join(bin_dir, "mount")
      File.write(mock_mount, <<~'SH')
        #!/usr/bin/env bash
        echo "/dev/disk8s1 on /Volumes/T7Tmp (apfs)"
      SH
      FileUtils.chmod(0o755, mock_mount)

      mock_df = File.join(bin_dir, "df")
      File.write(mock_df, <<~'SH')
        #!/usr/bin/env bash
        echo "Filesystem 512-blocks Used Available Capacity Mounted on"
        echo "/dev/disk8s1 1000 500 500 50% /Volumes/T7Tmp"
      SH
      FileUtils.chmod(0o755, mock_df)

      mock_t7run = File.join(bin_dir, "t7run")
      File.write(mock_t7run, <<~'SH')
        #!/usr/bin/env bash
        exit 0
      SH
      FileUtils.chmod(0o755, mock_t7run)

      out, err, status = Open3.capture3({ "PATH" => "#{bin_dir}:#{ENV['PATH']}", "RUNNER_TEMP" => "", "T7_RUN_DIR" => "/tmp/unapproved_scratch" }, "bash", SCRIPT)
      refute status.success?
      assert_includes err + out, "outside /Volumes/T7Tmp/ai-dev"
      assert_includes err + out, "Arbitrary scratch paths are rejected"

      # Reconcile script also rejects arbitrary T7_RUN_DIR
      out, err, status = Open3.capture3({ "PATH" => "#{bin_dir}:#{ENV['PATH']}", "RUNNER_TEMP" => "", "T7_RUN_DIR" => "/tmp/unapproved_scratch" }, "bash", RECONCILE_SCRIPT, "--manifest-only")
      refute status.success?
      assert_includes err + out, "outside /Volumes/T7Tmp/ai-dev"
      assert_includes err + out, "Arbitrary scratch paths are rejected"
    end

    # 2. Unmounted /Volumes/T7Tmp volume is rejected
    with_scratch_dir do |bin_dir|
      mock_mount = File.join(bin_dir, "mount")
      File.write(mock_mount, <<~'SH')
        #!/usr/bin/env bash
        echo "/dev/disk1s1 on / (apfs, local)"
      SH
      FileUtils.chmod(0o755, mock_mount)

      out, err, status = Open3.capture3({ "PATH" => "#{bin_dir}:#{ENV['PATH']}", "RUNNER_TEMP" => "" }, "bash", SCRIPT)
      refute status.success?
      assert_includes err + out, "External T7 scratch volume (/Volumes/T7Tmp) is not mounted"
    end

    # 3. Fake mount point directory on internal disk is rejected
    with_scratch_dir do |bin_dir|
      mock_mount = File.join(bin_dir, "mount")
      File.write(mock_mount, <<~'SH')
        #!/usr/bin/env bash
        echo "/dev/disk8s1 on /Volumes/T7Tmp (apfs)"
      SH
      FileUtils.chmod(0o755, mock_mount)

      mock_df = File.join(bin_dir, "df")
      File.write(mock_df, <<~'SH')
        #!/usr/bin/env bash
        echo "Filesystem 512-blocks Used Available Capacity Mounted on"
        echo "/dev/disk1s1 1000 500 500 50% /System/Volumes/Data"
      SH
      FileUtils.chmod(0o755, mock_df)

      out, err, status = Open3.capture3({ "PATH" => "#{bin_dir}:#{ENV['PATH']}", "RUNNER_TEMP" => "" }, "bash", SCRIPT)
      refute status.success?
      assert_includes err + out, "detected fake mount-point directory on internal disk"
    end
  end

  def test_failure_before_publication_when_target_commit_mismatches
    with_scratch_dir do |bin_dir|
      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~'SH')
        #!/usr/bin/env bash
        case "$*" in
          *"releases/442117184")
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":true,"target_commitish":"1111111111111111111111111111111111111111"}'
            ;;
          *) exit 1 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      out, err, status = run_recovery([], "PATH" => "#{bin_dir}:#{ENV['PATH']}", "RUNNER_TEMP" => bin_dir)
      refute status.success?
      assert_includes err + out, "target_commitish is '1111111111111111111111111111111111111111', expected '94c796fc34fd699776764d67d2f26013909a308e'"
    end
  end

  def test_failure_before_publication_when_release_is_not_draft
    with_scratch_dir do |bin_dir|
      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"releases/442117184")
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":false,"target_commitish":"#{VALID_SHA}"}'
            ;;
          *) exit 1 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      out, err, status = run_recovery([], "PATH" => "#{bin_dir}:#{ENV['PATH']}", "RUNNER_TEMP" => bin_dir)
      refute status.success?
      assert_includes err + out, "release 442117184 is not a draft"
    end
  end

  def test_failure_before_publication_when_asset_count_or_names_differ
    with_scratch_dir do |bin_dir|
      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"releases/442117184")
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":true,"target_commitish":"#{VALID_SHA}","assets":[{"name":"MeowDisplay.dmg"}]}'
            ;;
          *) exit 1 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      out, err, status = run_recovery([], "PATH" => "#{bin_dir}:#{ENV['PATH']}", "RUNNER_TEMP" => bin_dir)
      refute status.success?
      assert_includes err + out, "draft assets are 'MeowDisplay.dmg', expected 'MeowDisplay.dmg MeowDisplayReceiver.dmg SHA256SUMS.txt appcast-receiver.xml appcast.xml'"
    end
  end

  def test_failure_before_publication_when_sha256sums_digest_is_tampered
    with_scratch_dir do |bin_dir|
      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"releases/442117184")
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":true,"target_commitish":"#{VALID_SHA}","assets":[{"name":"MeowDisplay.dmg"},{"name":"MeowDisplayReceiver.dmg"},{"name":"SHA256SUMS.txt"},{"name":"appcast-receiver.xml"},{"name":"appcast.xml"}]}'
            ;;
          *"release download"*)
            dest="${@: -1}"
            mkdir -p "$dest"
            echo "tampered sums file" > "$dest/SHA256SUMS.txt"
            echo "d1" > "$dest/MeowDisplay.dmg"
            echo "d2" > "$dest/MeowDisplayReceiver.dmg"
            echo "f1" > "$dest/appcast.xml"
            echo "f2" > "$dest/appcast-receiver.xml"
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      mock_shasum = File.join(bin_dir, "shasum")
      File.write(mock_shasum, <<~SH)
        #!/usr/bin/env bash
        target="${@: -1}"
        case "$target" in
          *"MeowDisplay.dmg") echo "#{DMG1_HASH}  $target" ;;
          *"MeowDisplayReceiver.dmg") echo "#{DMG2_HASH}  $target" ;;
          *"appcast.xml") echo "#{FEED1_HASH}  $target" ;;
          *"appcast-receiver.xml") echo "#{FEED2_HASH}  $target" ;;
          *"SHA256SUMS.txt") echo "tampered_digest_000000000000000000000000000000000000000000000000  $target" ;;
          *) echo "0000000000000000000000000000000000000000000000000000000000000000  $target" ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_shasum)

      out, err, status = run_recovery([], "PATH" => "#{bin_dir}:#{ENV['PATH']}", "RUNNER_TEMP" => bin_dir)
      refute status.success?
      assert_includes err + out, "SHA256SUMS.txt hash is 'tampered_digest"
      assert_includes err + out, "expected pinned '#{EXPECTED_SUMS_HASH}'"
    end
  end

  def test_feed_verification_failure_halts_before_publication
    with_scratch_dir do |bin_dir|
      state_file = File.join(bin_dir, "published.txt")
      File.write(state_file, "false")

      sums_content = "#{DMG1_HASH}  MeowDisplay.dmg\n#{DMG2_HASH}  MeowDisplayReceiver.dmg\n#{FEED1_HASH}  appcast.xml\n#{FEED2_HASH}  appcast-receiver.xml\n"

      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"deployment-branch-policies"*)
            if [[ "$*" == *"--jq"* ]]; then
              echo "branch:release/*"
            else
              echo '{"branch_policies":[{"name":"release/*","type":"branch"}]}'
            fi
            ;;
          *"environments/release-publish"*)
            echo '{"deployment_branch_policy":{"custom_branch_policies":true},"protection_rules":[{"type":"required_reviewers"}]}'
            ;;
          *"actions/runs/12345/approvals"*)
            echo '[{"state":"approved","environments":[{"name":"release-publish"}]}]'
            ;;
          *"releases/442117184")
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":true,"target_commitish":"#{VALID_SHA}","assets":[{"name":"MeowDisplay.dmg"},{"name":"MeowDisplayReceiver.dmg"},{"name":"SHA256SUMS.txt"},{"name":"appcast-receiver.xml"},{"name":"appcast.xml"}]}'
            ;;
          *"release download"*)
            dest="${@: -1}"
            mkdir -p "$dest"
            printf "%s" "#{sums_content}" > "$dest/SHA256SUMS.txt"
            echo "mock-dmg1" > "$dest/MeowDisplay.dmg"
            echo "mock-dmg2" > "$dest/MeowDisplayReceiver.dmg"
            echo "mock-feed1" > "$dest/appcast.xml"
            echo "mock-feed2" > "$dest/appcast-receiver.xml"
            ;;
          *"release edit"*"--draft=false --latest"*)
            echo "true" > "#{state_file}"
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      mock_shasum = File.join(bin_dir, "shasum")
      File.write(mock_shasum, <<~SH)
        #!/usr/bin/env bash
        if [ "$1" = "-a" ] && [ "$2" = "256" ] && [ "$3" = "-c" ]; then exit 0; fi
        target="${@: -1}"
        case "$target" in
          *"MeowDisplay.dmg") echo "#{DMG1_HASH}  $target" ;;
          *"MeowDisplayReceiver.dmg") echo "#{DMG2_HASH}  $target" ;;
          *"appcast.xml") echo "#{FEED1_HASH}  $target" ;;
          *"appcast-receiver.xml") echo "#{FEED2_HASH}  $target" ;;
          *"SHA256SUMS.txt") echo "#{EXPECTED_SUMS_HASH}  $target" ;;
          *)
            content=$(cat)
            case "$content" in
              *"mock-feed1"*) echo "#{FEED1_HASH}  -" ;;
              *"mock-feed2"*) echo "#{FEED2_HASH}  -" ;;
              *) echo "0000000000000000000000000000000000000000000000000000000000000000  -" ;;
            esac
            ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_shasum)

      mock_feed = File.join(bin_dir, "verify-feed.sh")
      File.write(mock_feed, <<~'SH')
        #!/usr/bin/env bash
        echo "::error::mock feed verification failed: signature does not match Ed25519 key" >&2
        exit 1
      SH
      FileUtils.chmod(0o755, mock_feed)

      File.write(File.join(bin_dir, "verify-mac-artifact.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "verify-mac-artifact.sh"))
      File.write(File.join(bin_dir, "check-build-number.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "check-build-number.sh"))
      File.write(File.join(bin_dir, "published-baseline.sh"), "#!/usr/bin/env bash\nmkdir -p \"$1\"\necho k > \"$1/sender.key\"\necho k > \"$1/receiver.key\"\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "published-baseline.sh"))

      env = {
        "PATH" => "#{bin_dir}:#{ENV['PATH']}",
        "GITHUB_ACTIONS" => "true",
        "GITHUB_RUN_ID" => "12345",
        "RUNNER_TEMP" => bin_dir
      }
      out, err, status = run_recovery(["--publish"], env)
      refute status.success?
      assert_includes err + out, "mock feed verification failed"
      assert_equal "false", File.read(state_file), "Publication was attempted despite feed verification failure!"
    end
  end

  def test_successful_publication_end_to_end
    with_scratch_dir do |bin_dir|
      invocations_file = File.join(bin_dir, "gh_calls.txt")
      File.write(invocations_file, "")
      state_file = File.join(bin_dir, "gh_state.txt")
      File.write(state_file, "latest=v2.0.0\ndraft=true\n")

      sums_content = "#{DMG1_HASH}  MeowDisplay.dmg\n#{DMG2_HASH}  MeowDisplayReceiver.dmg\n#{FEED1_HASH}  appcast.xml\n#{FEED2_HASH}  appcast-receiver.xml\n"

      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        echo "gh $*" >> "#{invocations_file}"
        case "$*" in
          *"deployment-branch-policies"*)
            if [[ "$*" == *"--jq"* ]]; then
              echo "branch:release/*"
            else
              echo '{"branch_policies":[{"name":"release/*","type":"branch"}]}'
            fi
            ;;
          *"environments/release-publish"*)
            echo '{"deployment_branch_policy":{"custom_branch_policies":true},"protection_rules":[{"type":"required_reviewers"}]}'
            ;;
          *"actions/runs/12345/approvals"*)
            echo '[{"state":"approved","environments":[{"name":"release-publish"}]}]'
            ;;
          *"releases/442117184"*"--jq .draft"*)
            grep "^draft=" "#{state_file}" | cut -d= -f2
            ;;
          *"releases/442117184")
            draft_val=$(grep "^draft=" "#{state_file}" | cut -d= -f2)
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":'"$draft_val"',"target_commitish":"#{VALID_SHA}","assets":[{"name":"MeowDisplay.dmg"},{"name":"MeowDisplayReceiver.dmg"},{"name":"SHA256SUMS.txt"},{"name":"appcast-receiver.xml"},{"name":"appcast.xml"}]}'
            ;;
          *"releases/latest"*)
            grep "^latest=" "#{state_file}" | cut -d= -f2
            ;;
          *"release download v2.1.0"*)
            dest="${@: -1}"
            mkdir -p "$dest"
            printf "%s" "#{sums_content}" > "$dest/SHA256SUMS.txt"
            echo "mock-dmg1" > "$dest/MeowDisplay.dmg"
            echo "mock-dmg2" > "$dest/MeowDisplayReceiver.dmg"
            echo "mock-feed1" > "$dest/appcast.xml"
            echo "mock-feed2" > "$dest/appcast-receiver.xml"
            ;;
          *"release edit v2.1.0"*"--draft=false --latest"*)
            sed -i '' 's/^latest=.*/latest=v2.1.0/' "#{state_file}" 2>/dev/null || sed -i 's/^latest=.*/latest=v2.1.0/' "#{state_file}"
            sed -i '' 's/^draft=.*/draft=false/' "#{state_file}" 2>/dev/null || sed -i 's/^draft=.*/draft=false/' "#{state_file}"
            ;;
          *"commits/v2.1.0"*)
            echo "#{VALID_SHA}"
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      mock_shasum = File.join(bin_dir, "shasum")
      File.write(mock_shasum, <<~SH)
        #!/usr/bin/env bash
        if [ "$1" = "-a" ] && [ "$2" = "256" ] && [ "$3" = "-c" ]; then exit 0; fi
        target="${@: -1}"
        case "$target" in
          *"MeowDisplay.dmg") echo "#{DMG1_HASH}  $target" ;;
          *"MeowDisplayReceiver.dmg") echo "#{DMG2_HASH}  $target" ;;
          *"appcast.xml") echo "#{FEED1_HASH}  $target" ;;
          *"appcast-receiver.xml") echo "#{FEED2_HASH}  $target" ;;
          *"SHA256SUMS.txt") echo "#{EXPECTED_SUMS_HASH}  $target" ;;
          *)
            content=$(cat)
            case "$content" in
              *"mock-feed1"*) echo "#{FEED1_HASH}  -" ;;
              *"mock-feed2"*) echo "#{FEED2_HASH}  -" ;;
              *) echo "0000000000000000000000000000000000000000000000000000000000000000  -" ;;
            esac
            ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_shasum)

      File.write(File.join(bin_dir, "verify-feed.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "verify-feed.sh"))
      File.write(File.join(bin_dir, "verify-mac-artifact.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "verify-mac-artifact.sh"))
      File.write(File.join(bin_dir, "check-build-number.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "check-build-number.sh"))
      File.write(File.join(bin_dir, "published-baseline.sh"), "#!/usr/bin/env bash\nmkdir -p \"$1\"\necho k > \"$1/sender.key\"\necho k > \"$1/receiver.key\"\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "published-baseline.sh"))

      mock_curl = File.join(bin_dir, "curl")
      File.write(mock_curl, <<~SH)
        #!/usr/bin/env bash
        url="${@: -1}"
        case "$url" in
          *"appcast.xml"*) echo "mock-feed1" ;;
          *"appcast-receiver.xml"*) echo "mock-feed2" ;;
          *) exit 1 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_curl)

      env = {
        "PATH" => "#{bin_dir}:#{ENV['PATH']}",
        "GITHUB_ACTIONS" => "true",
        "GITHUB_RUN_ID" => "12345",
        "RUNNER_TEMP" => bin_dir
      }
      out, err, status = run_recovery(["--publish"], env)
      assert status.success?, "Publication failed: #{err}\n#{out}"
      assert_includes out, "SUCCESS: MeowDisplay Mac 2.1.0 is published and live!"
      assert_includes out, "Tag v2.1.0 is Latest pointing to #{VALID_SHA}"

      calls = File.read(invocations_file)
      # Assert publication used the exact tag name v2.1.0
      assert_includes calls, "gh release edit v2.1.0 --draft=false --latest -R raiseCatError/meowdisplay"
      # Assert rollback was never triggered
      refute_includes calls, "--draft=true"
      # Assert numeric draft ID was verified through API
      assert_includes calls, "gh api repos/raiseCatError/meowdisplay/releases/442117184"
    end
  end

  def test_rollback_behavior_when_live_feeds_fail_after_publish
    with_scratch_dir do |bin_dir|
      invocations_file = File.join(bin_dir, "gh_calls.txt")
      File.write(invocations_file, "")
      state_file = File.join(bin_dir, "gh_state.txt")
      File.write(state_file, "latest=v2.0.0\ndraft=true\n")

      sums_content = "#{DMG1_HASH}  MeowDisplay.dmg\n#{DMG2_HASH}  MeowDisplayReceiver.dmg\n#{FEED1_HASH}  appcast.xml\n#{FEED2_HASH}  appcast-receiver.xml\n"

      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        echo "gh $*" >> "#{invocations_file}"
        case "$*" in
          *"deployment-branch-policies"*)
            if [[ "$*" == *"--jq"* ]]; then
              echo "branch:release/*"
            else
              echo '{"branch_policies":[{"name":"release/*","type":"branch"}]}'
            fi
            ;;
          *"environments/release-publish"*)
            echo '{"deployment_branch_policy":{"custom_branch_policies":true},"protection_rules":[{"type":"required_reviewers"}]}'
            ;;
          *"actions/runs/12345/approvals"*)
            echo '[{"state":"approved","environments":[{"name":"release-publish"}]}]'
            ;;
          *"releases/442117184"*"--jq .draft"*)
            grep "^draft=" "#{state_file}" | cut -d= -f2
            ;;
          *"releases/442117184")
            draft_val=$(grep "^draft=" "#{state_file}" | cut -d= -f2)
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":'"$draft_val"',"target_commitish":"#{VALID_SHA}","assets":[{"name":"MeowDisplay.dmg"},{"name":"MeowDisplayReceiver.dmg"},{"name":"SHA256SUMS.txt"},{"name":"appcast-receiver.xml"},{"name":"appcast.xml"}]}'
            ;;
          *"releases/latest"*)
            grep "^latest=" "#{state_file}" | cut -d= -f2
            ;;
          *"release download v2.1.0"*)
            dest="${@: -1}"
            mkdir -p "$dest"
            printf "%s" "#{sums_content}" > "$dest/SHA256SUMS.txt"
            echo "mock-dmg1" > "$dest/MeowDisplay.dmg"
            echo "mock-dmg2" > "$dest/MeowDisplayReceiver.dmg"
            echo "mock-feed1" > "$dest/appcast.xml"
            echo "mock-feed2" > "$dest/appcast-receiver.xml"
            ;;
          *"release edit v2.1.0"*"--draft=false --latest"*)
            sed -i '' 's/^latest=.*/latest=v2.1.0/' "#{state_file}" 2>/dev/null || sed -i 's/^latest=.*/latest=v2.1.0/' "#{state_file}"
            sed -i '' 's/^draft=.*/draft=false/' "#{state_file}" 2>/dev/null || sed -i 's/^draft=.*/draft=false/' "#{state_file}"
            ;;
          *"release edit v2.0.0"*"--latest"*)
            sed -i '' 's/^latest=.*/latest=v2.0.0/' "#{state_file}" 2>/dev/null || sed -i 's/^latest=.*/latest=v2.0.0/' "#{state_file}"
            ;;
          *"release edit v2.1.0"*"--draft=true"*)
            sed -i '' 's/^draft=.*/draft=true/' "#{state_file}" 2>/dev/null || sed -i 's/^draft=.*/draft=true/' "#{state_file}"
            ;;
          *"commits/v2.1.0"*)
            echo "#{VALID_SHA}"
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      mock_shasum = File.join(bin_dir, "shasum")
      File.write(mock_shasum, <<~SH)
        #!/usr/bin/env bash
        if [ "$1" = "-a" ] && [ "$2" = "256" ] && [ "$3" = "-c" ]; then exit 0; fi
        target="${@: -1}"
        case "$target" in
          *"MeowDisplay.dmg") echo "#{DMG1_HASH}  $target" ;;
          *"MeowDisplayReceiver.dmg") echo "#{DMG2_HASH}  $target" ;;
          *"appcast.xml") echo "#{FEED1_HASH}  $target" ;;
          *"appcast-receiver.xml") echo "#{FEED2_HASH}  $target" ;;
          *"SHA256SUMS.txt") echo "#{EXPECTED_SUMS_HASH}  $target" ;;
          *)
            content=$(cat)
            case "$content" in
              *"mock-feed1"*) echo "#{FEED1_HASH}  -" ;;
              *"mock-feed2"*) echo "#{FEED2_HASH}  -" ;;
              *) echo "0000000000000000000000000000000000000000000000000000000000000000  -" ;;
            esac
            ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_shasum)

      File.write(File.join(bin_dir, "verify-feed.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "verify-feed.sh"))
      File.write(File.join(bin_dir, "verify-mac-artifact.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "verify-mac-artifact.sh"))
      File.write(File.join(bin_dir, "check-build-number.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "check-build-number.sh"))
      File.write(File.join(bin_dir, "published-baseline.sh"), "#!/usr/bin/env bash\nmkdir -p \"$1\"\necho k > \"$1/sender.key\"\necho k > \"$1/receiver.key\"\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "published-baseline.sh"))

      mock_curl = File.join(bin_dir, "curl")
      File.write(mock_curl, "#!/usr/bin/env bash\nexit 1\n")
      FileUtils.chmod(0o755, mock_curl)

      mock_sleep = File.join(bin_dir, "sleep")
      File.write(mock_sleep, "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, mock_sleep)

      env = {
        "PATH" => "#{bin_dir}:#{ENV['PATH']}",
        "GITHUB_ACTIONS" => "true",
        "GITHUB_RUN_ID" => "12345",
        "RUNNER_TEMP" => bin_dir
      }
      out, err, status = run_recovery(["--publish"], env)
      refute status.success?
      assert_includes err + out, "Live feeds did not serve v2.1.0 after 5 minutes"
      assert_includes err + out, "Rollback succeeded: v2.1.0 (ID 442117184) returned to draft; v2.0.0 restored as Latest"

      state = File.read(state_file)
      assert_includes state, "latest=v2.0.0"
      assert_includes state, "draft=true"

      calls = File.read(invocations_file)
      # Assert both rollback commands used the correct tag names
      assert_includes calls, "gh release edit v2.0.0 --latest -R raiseCatError/meowdisplay"
      assert_includes calls, "gh release edit v2.1.0 --draft=true -R raiseCatError/meowdisplay"
    end
  end

  def test_partial_rollback_failure_when_reverting_latest_fails
    with_scratch_dir do |bin_dir|
      state_file = File.join(bin_dir, "gh_state.txt")
      File.write(state_file, "latest=v2.0.0\ndraft=true\n")

      sums_content = "#{DMG1_HASH}  MeowDisplay.dmg\n#{DMG2_HASH}  MeowDisplayReceiver.dmg\n#{FEED1_HASH}  appcast.xml\n#{FEED2_HASH}  appcast-receiver.xml\n"

      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"deployment-branch-policies"*)
            if [[ "$*" == *"--jq"* ]]; then
              echo "branch:release/*"
            else
              echo '{"branch_policies":[{"name":"release/*","type":"branch"}]}'
            fi
            ;;
          *"environments/release-publish"*)
            echo '{"deployment_branch_policy":{"custom_branch_policies":true},"protection_rules":[{"type":"required_reviewers"}]}'
            ;;
          *"actions/runs/12345/approvals"*)
            echo '[{"state":"approved","environments":[{"name":"release-publish"}]}]'
            ;;
          *"releases/442117184"*"--jq .draft"*)
            grep "^draft=" "#{state_file}" | cut -d= -f2
            ;;
          *"releases/442117184")
            draft_val=$(grep "^draft=" "#{state_file}" | cut -d= -f2)
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":'"$draft_val"',"target_commitish":"#{VALID_SHA}","assets":[{"name":"MeowDisplay.dmg"},{"name":"MeowDisplayReceiver.dmg"},{"name":"SHA256SUMS.txt"},{"name":"appcast-receiver.xml"},{"name":"appcast.xml"}]}'
            ;;
          *"releases/latest"*)
            grep "^latest=" "#{state_file}" | cut -d= -f2
            ;;
          *"release download v2.1.0"*)
            dest="${@: -1}"
            mkdir -p "$dest"
            printf "%s" "#{sums_content}" > "$dest/SHA256SUMS.txt"
            echo "d1" > "$dest/MeowDisplay.dmg"
            echo "d2" > "$dest/MeowDisplayReceiver.dmg"
            echo "f1" > "$dest/appcast.xml"
            echo "f2" > "$dest/appcast-receiver.xml"
            ;;
          *"release edit v2.1.0"*"--draft=false --latest"*)
            sed -i '' 's/^latest=.*/latest=v2.1.0/' "#{state_file}" 2>/dev/null || sed -i 's/^latest=.*/latest=v2.1.0/' "#{state_file}"
            sed -i '' 's/^draft=.*/draft=false/' "#{state_file}" 2>/dev/null || sed -i 's/^draft=.*/draft=false/' "#{state_file}"
            ;;
          *"release edit v2.0.0"*"--latest"*)
            exit 1
            ;;
          *"release edit v2.1.0"*"--draft=true"*)
            sed -i '' 's/^draft=.*/draft=true/' "#{state_file}" 2>/dev/null || sed -i 's/^draft=.*/draft=true/' "#{state_file}"
            ;;
          *"commits/v2.1.0"*)
            echo "#{VALID_SHA}"
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      mock_shasum = File.join(bin_dir, "shasum")
      File.write(mock_shasum, <<~SH)
        #!/usr/bin/env bash
        if [ "$1" = "-a" ] && [ "$2" = "256" ] && [ "$3" = "-c" ]; then exit 0; fi
        target="${@: -1}"
        case "$target" in
          *"MeowDisplay.dmg") echo "#{DMG1_HASH}  $target" ;;
          *"MeowDisplayReceiver.dmg") echo "#{DMG2_HASH}  $target" ;;
          *"appcast.xml") echo "#{FEED1_HASH}  $target" ;;
          *"appcast-receiver.xml") echo "#{FEED2_HASH}  $target" ;;
          *"SHA256SUMS.txt") echo "#{EXPECTED_SUMS_HASH}  $target" ;;
          *)
            content=$(cat)
            case "$content" in
              *"mock-feed1"*) echo "#{FEED1_HASH}  -" ;;
              *"mock-feed2"*) echo "#{FEED2_HASH}  -" ;;
              *) echo "0000000000000000000000000000000000000000000000000000000000000000  -" ;;
            esac
            ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_shasum)

      File.write(File.join(bin_dir, "verify-feed.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "verify-feed.sh"))
      File.write(File.join(bin_dir, "verify-mac-artifact.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "verify-mac-artifact.sh"))
      File.write(File.join(bin_dir, "check-build-number.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "check-build-number.sh"))
      File.write(File.join(bin_dir, "published-baseline.sh"), "#!/usr/bin/env bash\nmkdir -p \"$1\"\necho k > \"$1/sender.key\"\necho k > \"$1/receiver.key\"\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "published-baseline.sh"))
      File.write(File.join(bin_dir, "curl"), "#!/usr/bin/env bash\nexit 1\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "curl"))
      File.write(File.join(bin_dir, "sleep"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "sleep"))

      env = {
        "PATH" => "#{bin_dir}:#{ENV['PATH']}",
        "GITHUB_ACTIONS" => "true",
        "GITHUB_RUN_ID" => "12345",
        "RUNNER_TEMP" => bin_dir
      }
      out, err, status = run_recovery(["--publish"], env)
      refute status.success?
      assert_includes err + out, "PARTIAL ROLLBACK FAILURE: revert_latest=false, revert_draft=true"
    end
  end

  def test_partial_rollback_failure_when_reverting_draft_fails
    with_scratch_dir do |bin_dir|
      state_file = File.join(bin_dir, "gh_state.txt")
      File.write(state_file, "latest=v2.0.0\ndraft=true\n")

      sums_content = "#{DMG1_HASH}  MeowDisplay.dmg\n#{DMG2_HASH}  MeowDisplayReceiver.dmg\n#{FEED1_HASH}  appcast.xml\n#{FEED2_HASH}  appcast-receiver.xml\n"

      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"deployment-branch-policies"*)
            if [[ "$*" == *"--jq"* ]]; then
              echo "branch:release/*"
            else
              echo '{"branch_policies":[{"name":"release/*","type":"branch"}]}'
            fi
            ;;
          *"environments/release-publish"*)
            echo '{"deployment_branch_policy":{"custom_branch_policies":true},"protection_rules":[{"type":"required_reviewers"}]}'
            ;;
          *"actions/runs/12345/approvals"*)
            echo '[{"state":"approved","environments":[{"name":"release-publish"}]}]'
            ;;
          *"releases/442117184"*"--jq .draft"*)
            grep "^draft=" "#{state_file}" | cut -d= -f2
            ;;
          *"releases/442117184")
            draft_val=$(grep "^draft=" "#{state_file}" | cut -d= -f2)
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":'"$draft_val"',"target_commitish":"#{VALID_SHA}","assets":[{"name":"MeowDisplay.dmg"},{"name":"MeowDisplayReceiver.dmg"},{"name":"SHA256SUMS.txt"},{"name":"appcast-receiver.xml"},{"name":"appcast.xml"}]}'
            ;;
          *"releases/latest"*)
            grep "^latest=" "#{state_file}" | cut -d= -f2
            ;;
          *"release download v2.1.0"*)
            dest="${@: -1}"
            mkdir -p "$dest"
            printf "%s" "#{sums_content}" > "$dest/SHA256SUMS.txt"
            echo "d1" > "$dest/MeowDisplay.dmg"
            echo "d2" > "$dest/MeowDisplayReceiver.dmg"
            echo "f1" > "$dest/appcast.xml"
            echo "f2" > "$dest/appcast-receiver.xml"
            ;;
          *"release edit v2.1.0"*"--draft=false --latest"*)
            sed -i '' 's/^latest=.*/latest=v2.1.0/' "#{state_file}" 2>/dev/null || sed -i 's/^latest=.*/latest=v2.1.0/' "#{state_file}"
            sed -i '' 's/^draft=.*/draft=false/' "#{state_file}" 2>/dev/null || sed -i 's/^draft=.*/draft=false/' "#{state_file}"
            ;;
          *"release edit v2.0.0"*"--latest"*)
            sed -i '' 's/^latest=.*/latest=v2.0.0/' "#{state_file}" 2>/dev/null || sed -i 's/^latest=.*/latest=v2.0.0/' "#{state_file}"
            ;;
          *"release edit v2.1.0"*"--draft=true"*)
            exit 1
            ;;
          *"commits/v2.1.0"*)
            echo "#{VALID_SHA}"
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      mock_shasum = File.join(bin_dir, "shasum")
      File.write(mock_shasum, <<~SH)
        #!/usr/bin/env bash
        if [ "$1" = "-a" ] && [ "$2" = "256" ] && [ "$3" = "-c" ]; then exit 0; fi
        target="${@: -1}"
        case "$target" in
          *"MeowDisplay.dmg") echo "#{DMG1_HASH}  $target" ;;
          *"MeowDisplayReceiver.dmg") echo "#{DMG2_HASH}  $target" ;;
          *"appcast.xml") echo "#{FEED1_HASH}  $target" ;;
          *"appcast-receiver.xml") echo "#{FEED2_HASH}  $target" ;;
          *"SHA256SUMS.txt") echo "#{EXPECTED_SUMS_HASH}  $target" ;;
          *)
            content=$(cat)
            case "$content" in
              *"mock-feed1"*) echo "#{FEED1_HASH}  -" ;;
              *"mock-feed2"*) echo "#{FEED2_HASH}  -" ;;
              *) echo "0000000000000000000000000000000000000000000000000000000000000000  -" ;;
            esac
            ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_shasum)

      File.write(File.join(bin_dir, "verify-feed.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "verify-feed.sh"))
      File.write(File.join(bin_dir, "verify-mac-artifact.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "verify-mac-artifact.sh"))
      File.write(File.join(bin_dir, "check-build-number.sh"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "check-build-number.sh"))
      File.write(File.join(bin_dir, "published-baseline.sh"), "#!/usr/bin/env bash\nmkdir -p \"$1\"\necho k > \"$1/sender.key\"\necho k > \"$1/receiver.key\"\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "published-baseline.sh"))
      File.write(File.join(bin_dir, "curl"), "#!/usr/bin/env bash\nexit 1\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "curl"))
      File.write(File.join(bin_dir, "sleep"), "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, File.join(bin_dir, "sleep"))

      env = {
        "PATH" => "#{bin_dir}:#{ENV['PATH']}",
        "GITHUB_ACTIONS" => "true",
        "GITHUB_RUN_ID" => "12345",
        "RUNNER_TEMP" => bin_dir
      }
      out, err, status = run_recovery(["--publish"], env)
      refute status.success?
      assert_includes err + out, "PARTIAL ROLLBACK FAILURE: revert_latest=true, revert_draft=false"
    end
  end

  def test_reconcile_script_requires_explicit_mode
    out, err, status = Open3.capture3({}, "bash", RECONCILE_SCRIPT)
    refute status.success?
    assert_includes err + out, "usage: reconcile-mac-release.sh (--execute | --manifest-only | --preflight)"
  end

  def test_reconcile_script_rejects_overrides
    out, err, status = Open3.capture3({ "VERSION" => "3.0.0" }, "bash", RECONCILE_SCRIPT, "--execute")
    refute status.success?
    assert_includes err + out, "VERSION must be '2.1.0'"
    assert_includes err + out, "rejected"
  end

  def test_reconcile_manifest_only_is_strictly_read_only
    with_scratch_dir do |bin_dir|
      invocations_file = File.join(bin_dir, "state_calls.txt")
      File.write(invocations_file, "")

      mock_state = File.join(bin_dir, "release-state.sh")
      File.write(mock_state, <<~SH)
        #!/usr/bin/env bash
        echo "state $*" >> "#{invocations_file}"
        case "$*" in
          *"publish website-manifest"*)
            out_file="${@: -1}"
            echo '{"version":"2.1.0","manifest":"ok"}' > "$out_file"
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_state)

      mock_git = File.join(bin_dir, "git")
      File.write(mock_git, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"fetch"*) exit 0 ;;
          *"rev-parse FETCH_HEAD"*) echo '#{VALID_SHA}' ;;
          *"show #{VALID_SHA}:.github/release-config.json"*)
            echo '{"requiredPlatforms":["mac","ios"],"excludedPlatforms":["android"],"ios":{"submitForReview":false}}'
            ;;
          *) exit 1 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_git)

      env = {
        "PATH" => "#{bin_dir}:#{ENV['PATH']}",
        "RUNNER_TEMP" => bin_dir
      }
      out, err, status = run_reconcile(["--manifest-only"], env)
      assert status.success?, "Manifest-only failed: #{err}\n#{out}"
      assert_includes out, "Manifest generated successfully (read-only mode; zero state mutations performed)"
      assert_includes out, '"version":"2.1.0"'

      calls = File.read(invocations_file)
      # Assert ONLY website-manifest was invoked
      assert_includes calls, "publish website-manifest"
      # Assert mutating subcommands were NEVER invoked
      refute_includes calls, "publish start"
      refute_includes calls, "publish mac-published"
      refute_includes calls, "publish stores"
    end
  end

  def test_reconcile_execute_requires_release_state_token
    with_scratch_dir do |bin_dir|
      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"releases/latest"*) echo 'v2.1.0' ;;
          *"commits/v2.1.0"*) echo '#{VALID_SHA}' ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      env = {
        "PATH" => "#{bin_dir}:#{ENV['PATH']}",
        "RELEASE_STATE_TOKEN" => "",
        "RUNNER_TEMP" => bin_dir
      }
      out, err, status = run_reconcile(["--execute"], env)
      refute status.success?
      assert_includes err + out, "RELEASE_STATE_TOKEN is required to mutate the protected release-state branch"
    end
  end

  def test_successful_reconciliation_end_to_end
    with_scratch_dir do |bin_dir|
      invocations_file = File.join(bin_dir, "reconcile_calls.txt")
      File.write(invocations_file, "")

      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"releases/latest"*) echo 'v2.1.0' ;;
          *"commits/v2.1.0"*) echo '#{VALID_SHA}' ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      mock_state = File.join(bin_dir, "release-state.sh")
      File.write(mock_state, <<~SH)
        #!/usr/bin/env bash
        echo "state $*" >> "#{invocations_file}"
        case "$*" in
          *"publish website-manifest"*)
            out_file="${@: -1}"
            echo '{"version":"2.1.0","manifest":"ok"}' > "$out_file"
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_state)

      mock_git = File.join(bin_dir, "git")
      File.write(mock_git, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"fetch"*) exit 0 ;;
          *"rev-parse FETCH_HEAD"*) echo '#{VALID_SHA}' ;;
          *"show #{VALID_SHA}:.github/release-config.json"*)
            echo '{"requiredPlatforms":["mac","ios"],"excludedPlatforms":["android"],"ios":{"submitForReview":false}}'
            ;;
          *"show origin/release-state"*)
            echo '{"publication":{"stage":"in-progress"},"platforms":{"mac":{"stage":"published"},"ios":{"stage":"published"}}}'
            ;;
          *) exec /usr/bin/git "$@" ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_git)

      env = {
        "PATH" => "#{bin_dir}:#{ENV['PATH']}",
        "RELEASE_STATE_TOKEN" => "app-token-xyz-123",
        "RUNNER_TEMP" => bin_dir
      }
      out, err, status = run_reconcile(["--execute"], env)
      assert status.success?, "Reconcile execute failed: #{err}\n#{out}"
      assert_includes out, "release-state successfully reconciled"
      assert_includes out, "platforms.mac: published"
      assert_includes out, "platforms.ios: published"
      assert_includes out, "publication:   in-progress"

      calls = File.read(invocations_file)
      # Assert state progression happened in exact order
      idx_start = calls.index("publish start STATE")
      idx_mac = calls.index("publish mac-published STATE")
      idx_manifest = calls.index("publish website-manifest STATE")

      assert idx_start, "publish start STATE was not called"
      assert idx_mac, "publish mac-published STATE was not called"
      assert idx_manifest, "publish website-manifest STATE was not called"
      assert idx_start < idx_mac, "publish start must precede mac-published"
      assert idx_mac < idx_manifest, "mac-published must precede website-manifest"
      assert_includes calls, "approved-release-config.json"
      refute_includes calls, "publish stores STATE"
      refute_includes calls, "/.github/release-config.json"
    end
  end

  def test_preflight_rejects_generic_android_required_config
    with_scratch_dir do |bin_dir|
      git = File.join(bin_dir, "git")
      File.write(git, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"fetch"*) exit 0 ;;
          *"rev-parse FETCH_HEAD"*) echo '#{VALID_SHA}' ;;
          *"show #{VALID_SHA}:.github/release-config.json"*)
            echo '{"requiredPlatforms":["mac","ios","android"],"excludedPlatforms":[],"ios":{"submitForReview":true}}'
            ;;
          *) exit 1 ;;
        esac
      SH
      FileUtils.chmod(0o755, git)
      out, err, status = run_reconcile(["--preflight"], "PATH" => "#{bin_dir}:#{ENV['PATH']}", "RUNNER_TEMP" => bin_dir)
      refute status.success?
      assert_includes err + out, "Frozen candidate config must require mac + ios, exclude android"
    end
  end

  def test_candidate_branch_movement_fails_closed
    with_scratch_dir do |bin_dir|
      git = File.join(bin_dir, "git")
      File.write(git, <<~'SH')
        #!/usr/bin/env bash
        case "$*" in
          *"fetch"*) exit 0 ;;
          *"rev-parse FETCH_HEAD"*) echo '1111111111111111111111111111111111111111' ;;
          *) exit 1 ;;
        esac
      SH
      FileUtils.chmod(0o755, git)
      out, err, status = run_reconcile(["--manifest-only"], "PATH" => "#{bin_dir}:#{ENV['PATH']}", "RUNNER_TEMP" => bin_dir)
      refute status.success?
      assert_includes err + out, "release/2.1.0 moved"
    end
  end
end
