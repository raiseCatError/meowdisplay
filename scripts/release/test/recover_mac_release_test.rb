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

  def run_recovery(args = [], env = {})
    default_env = {
      "RECOVERY_TEST_MOCK_ENV" => "true",
      "RECOVERY_TEST_TMPDIR" => Dir.tmpdir
    }
    Open3.capture3(default_env.merge(env), "bash", SCRIPT, *args)
  end

  def test_input_pinning_rejects_differing_version_or_sha_or_draft
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
      "RECOVERY_TEST_MOCK_ENV" => "false",
      "RECOVERY_TEST_TMPDIR" => Dir.tmpdir
    }
    out, err, status = Open3.capture3(env, "bash", SCRIPT, "--publish")
    refute status.success?
    assert_includes err + out, "Local execution is verification-only (--verify)"
    assert_includes err + out, "release-publish"
  end

  def test_stale_release_state_fetch_failure_halts_immediately
    Dir.mktmpdir do |bin_dir|
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
      File.write(mock_gh, <<~'SH')
        #!/usr/bin/env bash
        case "$*" in
          *"releases/442117184")
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":true,"target_commitish":"94c796fc34fd699776764d67d2f26013909a308e"}'
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      out, err, status = run_recovery([], "PATH" => "#{bin_dir}:#{ENV['PATH']}")
      refute status.success?
      assert_includes err + out, "Failed to fetch origin/release-state from remote"
      assert_includes err + out, "Relying on stale local state is prohibited"
    end
  end

  def test_scratch_volume_enforcement_locally
    Dir.mktmpdir do |bin_dir|
      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, mock_gh)

      out, err, status = Open3.capture3({}, "bash", "-c", <<~SH)
        export RUNNER_TEMP="" T7_RUN_DIR="" RECOVERY_TEST_TMPDIR="" TMPDIR="/private/tmp"
        if [ ! -d "/Volumes/T7Tmp/ai-dev" ]; then
          bash "#{SCRIPT}"
        else
          echo "::error::No approved scratch location found. T7 scratch storage (/Volumes/T7Tmp/ai-dev) is required for local execution. Never fall back to internal /tmp."
          exit 1
        fi
      SH
      refute status.success?
      assert_includes err + out, "No approved scratch location found"
    end
  end

  def test_failure_before_publication_when_target_commit_mismatches
    Dir.mktmpdir do |bin_dir|
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

      out, err, status = run_recovery([], "PATH" => "#{bin_dir}:#{ENV['PATH']}")
      refute status.success?
      assert_includes err + out, "target_commitish is '1111111111111111111111111111111111111111', expected '94c796fc34fd699776764d67d2f26013909a308e'"
    end
  end

  def test_failure_before_publication_when_release_is_not_draft
    Dir.mktmpdir do |bin_dir|
      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~'SH')
        #!/usr/bin/env bash
        case "$*" in
          *"releases/442117184")
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":false,"target_commitish":"94c796fc34fd699776764d67d2f26013909a308e"}'
            ;;
          *) exit 1 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      out, err, status = run_recovery([], "PATH" => "#{bin_dir}:#{ENV['PATH']}")
      refute status.success?
      assert_includes err + out, "release 442117184 is not a draft"
    end
  end

  def test_failure_before_publication_when_asset_count_or_names_differ
    Dir.mktmpdir do |bin_dir|
      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~'SH')
        #!/usr/bin/env bash
        case "$*" in
          *"releases/442117184")
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":true,"target_commitish":"94c796fc34fd699776764d67d2f26013909a308e","assets":[{"name":"MeowDisplay.dmg"}]}'
            ;;
          *) exit 1 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      out, err, status = run_recovery([], "PATH" => "#{bin_dir}:#{ENV['PATH']}")
      refute status.success?
      assert_includes err + out, "draft assets are"
    end
  end

  def test_failure_before_publication_when_sha256sums_digest_is_tampered
    Dir.mktmpdir do |bin_dir|
      dmg1_hash = "d02273969b8a00fc7269f69ab6440bae92028bcb55b9e5f4765cb5d925e8c316"
      dmg2_hash = "4981863429e85dacf916287e466867ff1c38c838bc364c0ae483739b8d17eaf7"
      feed1_hash = "b97d8bdddec17083407dbc08bc23052b84d6d3f7440ddfd6e4443d78f50548d5"
      feed2_hash = "306cd1cbc1f415bf7668892be261907ea66f0a381a56b7f6921c3e6758f36609"

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
          *"MeowDisplay.dmg") echo "#{dmg1_hash}  $target" ;;
          *"MeowDisplayReceiver.dmg") echo "#{dmg2_hash}  $target" ;;
          *"appcast.xml") echo "#{feed1_hash}  $target" ;;
          *"appcast-receiver.xml") echo "#{feed2_hash}  $target" ;;
          *"SHA256SUMS.txt") echo "tampered_digest_000000000000000000000000000000000000000000000000  $target" ;;
          *) echo "0000000000000000000000000000000000000000000000000000000000000000  $target" ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_shasum)

      out, err, status = run_recovery([], "PATH" => "#{bin_dir}:#{ENV['PATH']}")
      refute status.success?
      assert_includes err + out, "SHA256SUMS.txt hash is 'tampered_digest"
      assert_includes err + out, "expected pinned '#{EXPECTED_SUMS_HASH}'"
    end
  end

  def test_feed_verification_failure_executes_production_script_and_halts_before_publication
    Dir.mktmpdir do |bin_dir|
      state_file = File.join(bin_dir, "gh_state.txt")
      File.write(state_file, "published=false\n")

      dmg1_hash = "d02273969b8a00fc7269f69ab6440bae92028bcb55b9e5f4765cb5d925e8c316"
      dmg2_hash = "4981863429e85dacf916287e466867ff1c38c838bc364c0ae483739b8d17eaf7"
      feed1_hash = "b97d8bdddec17083407dbc08bc23052b84d6d3f7440ddfd6e4443d78f50548d5"
      feed2_hash = "306cd1cbc1f415bf7668892be261907ea66f0a381a56b7f6921c3e6758f36609"

      sums_content = "#{dmg1_hash}  MeowDisplay.dmg\n#{dmg2_hash}  MeowDisplayReceiver.dmg\n#{feed1_hash}  appcast.xml\n#{feed2_hash}  appcast-receiver.xml\n"

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
            printf "%s" "#{sums_content}" > "$dest/SHA256SUMS.txt"
            echo "mock-dmg1" > "$dest/MeowDisplay.dmg"
            echo "mock-dmg2" > "$dest/MeowDisplayReceiver.dmg"
            echo "mock-feed1" > "$dest/appcast.xml"
            echo "mock-feed2" > "$dest/appcast-receiver.xml"
            ;;
          *"release edit"*"--draft=false --latest"*)
            echo "published=true" > "#{state_file}"
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      mock_shasum = File.join(bin_dir, "shasum")
      File.write(mock_shasum, <<~SH)
        #!/usr/bin/env bash
        if [ "$1" = "-a" ] && [ "$2" = "256" ] && [ "$3" = "-c" ]; then
          exit 0
        fi
        target="${@: -1}"
        case "$target" in
          *"MeowDisplay.dmg") echo "#{dmg1_hash}  $target" ;;
          *"MeowDisplayReceiver.dmg") echo "#{dmg2_hash}  $target" ;;
          *"appcast.xml") echo "#{feed1_hash}  $target" ;;
          *"appcast-receiver.xml") echo "#{feed2_hash}  $target" ;;
          *"SHA256SUMS.txt") echo "#{EXPECTED_SUMS_HASH}  $target" ;;
          *) echo "0000000000000000000000000000000000000000000000000000000000000000  $target" ;;
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

      mock_mac = File.join(bin_dir, "verify-mac-artifact.sh")
      File.write(mock_mac, "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, mock_mac)

      mock_base = File.join(bin_dir, "published-baseline.sh")
      File.write(mock_base, "#!/usr/bin/env bash\nmkdir -p \"$1\"\necho k > \"$1/sender.key\"\necho k > \"$1/receiver.key\"\n")
      FileUtils.chmod(0o755, mock_base)

      mock_build = File.join(bin_dir, "check-build-number.sh")
      File.write(mock_build, "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, mock_build)

      env = {
        "PATH" => "#{bin_dir}:#{ENV['PATH']}",
        "RECOVERY_TEST_MOCK_SCRIPTS" => "true"
      }
      out, err, status = run_recovery(["--publish"], env)
      refute status.success?
      assert_includes err + out, "mock feed verification failed"
      assert_equal "published=false\n", File.read(state_file), "Publication was attempted despite feed failure!"
    end
  end

  def test_rollback_behavior_when_live_feeds_fail_after_publish
    Dir.mktmpdir do |bin_dir|
      state_file = File.join(bin_dir, "gh_state.txt")
      File.write(state_file, "latest=v2.0.0\ndraft=true\n")

      dmg1_hash = "d02273969b8a00fc7269f69ab6440bae92028bcb55b9e5f4765cb5d925e8c316"
      dmg2_hash = "4981863429e85dacf916287e466867ff1c38c838bc364c0ae483739b8d17eaf7"
      feed1_hash = "b97d8bdddec17083407dbc08bc23052b84d6d3f7440ddfd6e4443d78f50548d5"
      feed2_hash = "306cd1cbc1f415bf7668892be261907ea66f0a381a56b7f6921c3e6758f36609"

      sums_content = "#{dmg1_hash}  MeowDisplay.dmg\n#{dmg2_hash}  MeowDisplayReceiver.dmg\n#{feed1_hash}  appcast.xml\n#{feed2_hash}  appcast-receiver.xml\n"

      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
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
          *"release download"*)
            dest="${@: -1}"
            mkdir -p "$dest"
            printf "%s" "#{sums_content}" > "$dest/SHA256SUMS.txt"
            echo "mock-dmg1" > "$dest/MeowDisplay.dmg"
            echo "mock-dmg2" > "$dest/MeowDisplayReceiver.dmg"
            echo "mock-feed1" > "$dest/appcast.xml"
            echo "mock-feed2" > "$dest/appcast-receiver.xml"
            ;;
          *"release edit 442117184"*"--draft=false --latest"*)
            sed -i '' 's/^latest=.*/latest=v2.1.0/' "#{state_file}" 2>/dev/null || sed -i 's/^latest=.*/latest=v2.1.0/' "#{state_file}"
            sed -i '' 's/^draft=.*/draft=false/' "#{state_file}" 2>/dev/null || sed -i 's/^draft=.*/draft=false/' "#{state_file}"
            ;;
          *"release edit v2.0.0"*"--latest"*)
            sed -i '' 's/^latest=.*/latest=v2.0.0/' "#{state_file}" 2>/dev/null || sed -i 's/^latest=.*/latest=v2.0.0/' "#{state_file}"
            ;;
          *"release edit 442117184"*"--draft=true"*)
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
        if [ "$1" = "-a" ] && [ "$2" = "256" ] && [ "$3" = "-c" ]; then
          exit 0
        fi
        target="${@: -1}"
        case "$target" in
          *"MeowDisplay.dmg") echo "#{dmg1_hash}  $target" ;;
          *"MeowDisplayReceiver.dmg") echo "#{dmg2_hash}  $target" ;;
          *"appcast.xml") echo "#{feed1_hash}  $target" ;;
          *"appcast-receiver.xml") echo "#{feed2_hash}  $target" ;;
          *"SHA256SUMS.txt") echo "#{EXPECTED_SUMS_HASH}  $target" ;;
          *) echo "0000000000000000000000000000000000000000000000000000000000000000  $target" ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_shasum)

      mock_feed = File.join(bin_dir, "verify-feed.sh")
      File.write(mock_feed, "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, mock_feed)

      mock_mac = File.join(bin_dir, "verify-mac-artifact.sh")
      File.write(mock_mac, "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, mock_mac)

      mock_base = File.join(bin_dir, "published-baseline.sh")
      File.write(mock_base, "#!/usr/bin/env bash\nmkdir -p \"$1\"\necho k > \"$1/sender.key\"\necho k > \"$1/receiver.key\"\n")
      FileUtils.chmod(0o755, mock_base)

      mock_build = File.join(bin_dir, "check-build-number.sh")
      File.write(mock_build, "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, mock_build)

      mock_curl = File.join(bin_dir, "curl")
      File.write(mock_curl, "#!/usr/bin/env bash\nexit 1\n")
      FileUtils.chmod(0o755, mock_curl)

      mock_sleep = File.join(bin_dir, "sleep")
      File.write(mock_sleep, "#!/usr/bin/env bash\nexit 0\n")
      FileUtils.chmod(0o755, mock_sleep)

      env = {
        "PATH" => "#{bin_dir}:#{ENV['PATH']}",
        "RECOVERY_TEST_MOCK_SCRIPTS" => "true"
      }
      out, err, status = run_recovery(["--publish"], env)
      refute status.success?
      assert_includes err + out, "Live feeds did not serve v2.1.0 after 5 minutes"
      assert_includes err + out, "Rollback succeeded: 442117184 returned to draft; v2.0.0 restored as Latest"

      state = File.read(state_file)
      assert_includes state, "latest=v2.0.0"
      assert_includes state, "draft=true"
    end
  end

  def test_partial_rollback_failure_when_reverting_latest_fails
    Dir.mktmpdir do |bin_dir|
      state_file = File.join(bin_dir, "gh_state.txt")
      File.write(state_file, "latest=v2.0.0\ndraft=true\n")

      dmg1_hash = "d02273969b8a00fc7269f69ab6440bae92028bcb55b9e5f4765cb5d925e8c316"
      dmg2_hash = "4981863429e85dacf916287e466867ff1c38c838bc364c0ae483739b8d17eaf7"
      feed1_hash = "b97d8bdddec17083407dbc08bc23052b84d6d3f7440ddfd6e4443d78f50548d5"
      feed2_hash = "306cd1cbc1f415bf7668892be261907ea66f0a381a56b7f6921c3e6758f36609"

      sums_content = "#{dmg1_hash}  MeowDisplay.dmg\n#{dmg2_hash}  MeowDisplayReceiver.dmg\n#{feed1_hash}  appcast.xml\n#{feed2_hash}  appcast-receiver.xml\n"

      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
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
          *"release download"*)
            dest="${@: -1}"
            mkdir -p "$dest"
            printf "%s" "#{sums_content}" > "$dest/SHA256SUMS.txt"
            echo "d1" > "$dest/MeowDisplay.dmg"
            echo "d2" > "$dest/MeowDisplayReceiver.dmg"
            echo "f1" > "$dest/appcast.xml"
            echo "f2" > "$dest/appcast-receiver.xml"
            ;;
          *"release edit 442117184"*"--draft=false --latest"*)
            sed -i '' 's/^latest=.*/latest=v2.1.0/' "#{state_file}" 2>/dev/null || sed -i 's/^latest=.*/latest=v2.1.0/' "#{state_file}"
            sed -i '' 's/^draft=.*/draft=false/' "#{state_file}" 2>/dev/null || sed -i 's/^draft=.*/draft=false/' "#{state_file}"
            ;;
          *"release edit v2.0.0"*"--latest"*)
            exit 1
            ;;
          *"release edit 442117184"*"--draft=true"*)
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
          *"MeowDisplay.dmg") echo "#{dmg1_hash}  $target" ;;
          *"MeowDisplayReceiver.dmg") echo "#{dmg2_hash}  $target" ;;
          *"appcast.xml") echo "#{feed1_hash}  $target" ;;
          *"appcast-receiver.xml") echo "#{feed2_hash}  $target" ;;
          *"SHA256SUMS.txt") echo "#{EXPECTED_SUMS_HASH}  $target" ;;
          *) echo "0000000000000000000000000000000000000000000000000000000000000000  $target" ;;
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
        "RECOVERY_TEST_MOCK_SCRIPTS" => "true"
      }
      out, err, status = run_recovery(["--publish"], env)
      refute status.success?
      assert_includes err + out, "PARTIAL ROLLBACK FAILURE: revert_latest=false, revert_draft=true"
    end
  end

  def test_partial_rollback_failure_when_reverting_draft_fails
    Dir.mktmpdir do |bin_dir|
      state_file = File.join(bin_dir, "gh_state.txt")
      File.write(state_file, "latest=v2.0.0\ndraft=true\n")

      dmg1_hash = "d02273969b8a00fc7269f69ab6440bae92028bcb55b9e5f4765cb5d925e8c316"
      dmg2_hash = "4981863429e85dacf916287e466867ff1c38c838bc364c0ae483739b8d17eaf7"
      feed1_hash = "b97d8bdddec17083407dbc08bc23052b84d6d3f7440ddfd6e4443d78f50548d5"
      feed2_hash = "306cd1cbc1f415bf7668892be261907ea66f0a381a56b7f6921c3e6758f36609"

      sums_content = "#{dmg1_hash}  MeowDisplay.dmg\n#{dmg2_hash}  MeowDisplayReceiver.dmg\n#{feed1_hash}  appcast.xml\n#{feed2_hash}  appcast-receiver.xml\n"

      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
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
          *"release download"*)
            dest="${@: -1}"
            mkdir -p "$dest"
            printf "%s" "#{sums_content}" > "$dest/SHA256SUMS.txt"
            echo "d1" > "$dest/MeowDisplay.dmg"
            echo "d2" > "$dest/MeowDisplayReceiver.dmg"
            echo "f1" > "$dest/appcast.xml"
            echo "f2" > "$dest/appcast-receiver.xml"
            ;;
          *"release edit 442117184"*"--draft=false --latest"*)
            sed -i '' 's/^latest=.*/latest=v2.1.0/' "#{state_file}" 2>/dev/null || sed -i 's/^latest=.*/latest=v2.1.0/' "#{state_file}"
            sed -i '' 's/^draft=.*/draft=false/' "#{state_file}" 2>/dev/null || sed -i 's/^draft=.*/draft=false/' "#{state_file}"
            ;;
          *"release edit v2.0.0"*"--latest"*)
            sed -i '' 's/^latest=.*/latest=v2.0.0/' "#{state_file}" 2>/dev/null || sed -i 's/^latest=.*/latest=v2.0.0/' "#{state_file}"
            ;;
          *"release edit 442117184"*"--draft=true"*)
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
          *"MeowDisplay.dmg") echo "#{dmg1_hash}  $target" ;;
          *"MeowDisplayReceiver.dmg") echo "#{dmg2_hash}  $target" ;;
          *"appcast.xml") echo "#{feed1_hash}  $target" ;;
          *"appcast-receiver.xml") echo "#{feed2_hash}  $target" ;;
          *"SHA256SUMS.txt") echo "#{EXPECTED_SUMS_HASH}  $target" ;;
          *) echo "0000000000000000000000000000000000000000000000000000000000000000  $target" ;;
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
        "RECOVERY_TEST_MOCK_SCRIPTS" => "true"
      }
      out, err, status = run_recovery(["--publish"], env)
      refute status.success?
      assert_includes err + out, "PARTIAL ROLLBACK FAILURE: revert_latest=true, revert_draft=false"
    end
  end

  def test_reconcile_script_rejects_overrides
    out, err, status = Open3.capture3({ "VERSION" => "3.0.0" }, "bash", RECONCILE_SCRIPT)
    refute status.success?
    assert_includes err + out, "VERSION must be '2.1.0'"
    assert_includes err + out, "rejected"
  end

  def test_reconcile_script_requires_token_when_not_mocked
    env = {
      "RELEASE_STATE_TOKEN" => "",
      "RECOVERY_TEST_MOCK_ENV" => "false",
      "RECOVERY_TEST_TMPDIR" => Dir.tmpdir
    }
    Dir.mktmpdir do |bin_dir|
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

      out, err, status = Open3.capture3(env.merge("PATH" => "#{bin_dir}:#{ENV['PATH']}"), "bash", RECONCILE_SCRIPT)
      refute status.success?
      assert_includes err + out, "RELEASE_STATE_TOKEN is required"
    end
  end
end
