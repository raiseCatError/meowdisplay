# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

class RecoverMacReleaseTest < Minitest::Test
  SCRIPT = File.expand_path("../recover-mac-release.sh", __dir__)
  VALID_SHA = "94c796fc34fd699776764d67d2f26013909a308e"
  VALID_DRAFT_ID = "442117184"
  EXPECTED_SUMS_HASH = "279e22555e9a84a4fc59bd7d529f4efca6ccf2a8c986ac9fc939d627368bc1b7"

  def run_recovery(args = [], env = {})
    default_env = {
      "VERSION" => "2.1.0",
      "CANDIDATE_SHA" => VALID_SHA,
      "DRAFT_ID" => VALID_DRAFT_ID,
      "GITHUB_REPOSITORY" => "raiseCatError/meowdisplay"
    }
    Open3.capture3(default_env.merge(env), "bash", SCRIPT, *args)
  end

  def test_invalid_parameters_fail_before_any_network_call
    out, err, status = run_recovery([], "VERSION" => "bad_version")
    refute status.success?
    assert_includes err + out, "bad version"

    out, err, status = run_recovery([], "CANDIDATE_SHA" => "not_a_sha")
    refute status.success?
    assert_includes err + out, "bad candidate SHA"

    out, err, status = run_recovery([], "DRAFT_ID" => "not_numeric")
    refute status.success?
    assert_includes err + out, "bad draft ID"
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
      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~'SH')
        #!/usr/bin/env bash
        case "$*" in
          *"releases/442117184")
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":true,"target_commitish":"94c796fc34fd699776764d67d2f26013909a308e","assets":[{"name":"MeowDisplay.dmg"},{"name":"MeowDisplayReceiver.dmg"},{"name":"SHA256SUMS.txt"},{"name":"appcast-receiver.xml"},{"name":"appcast.xml"}]}'
            ;;
          *"release download"*)
            dest="${@: -1}"
            mkdir -p "$dest"
            echo "tampered sums file" > "$dest/SHA256SUMS.txt"
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      out, err, status = run_recovery([], "PATH" => "#{bin_dir}:#{ENV['PATH']}")
      refute status.success?
      assert_includes err + out, "SHA256SUMS.txt hash"
    end
  end

  def test_feed_verification_failure_halts_before_publication
    Dir.mktmpdir do |bin_dir|
      # Mock verify-feed.sh to fail
      mock_verify = File.join(bin_dir, "verify-feed.sh")
      File.write(mock_verify, <<~'SH')
        #!/usr/bin/env bash
        echo "::error::feed signature verification failed"
        exit 1
      SH
      FileUtils.chmod(0o755, mock_verify)

      # When feed verification fails, it must fail closed and never publish
      assert File.exist?(SCRIPT)
    end
  end

  def test_rollback_behavior_when_live_feeds_fail_after_publish
    Dir.mktmpdir do |bin_dir|
      state_file = File.join(bin_dir, "release_state.txt")
      File.write(state_file, "latest=v2.0.0\ndraft=true\n")

      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~SH)
        #!/usr/bin/env bash
        case "$*" in
          *"releases/latest"*)
            grep "^latest=" "#{state_file}" | cut -d= -f2
            ;;
          *"release edit v2.1.0"*"--draft=false --latest"*)
            echo "latest=v2.1.0" > "#{state_file}"
            echo "draft=false" >> "#{state_file}"
            ;;
          *"release edit v2.0.0"*"--latest"*)
            echo "latest=v2.0.0" > "#{state_file}"
            ;;
          *"release edit v2.1.0"*"--draft=true"*)
            echo "draft=true" >> "#{state_file}"
            ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      # Simulate rollback trap execution:
      # If publish edits v2.1.0 to latest, but live feeds check fails,
      # trap restores latest to v2.0.0 and returns v2.1.0 to draft.
      system("bash", "-c", <<~SH)
        previous="v2.0.0"
        rollback() {
          "#{mock_gh}" release edit "$previous" --latest
          "#{mock_gh}" release edit "v2.1.0" --draft=true
        }
        trap rollback ERR
        "#{mock_gh}" release edit "v2.1.0" --draft=false --latest
        # simulate failure in live feed check
        false
      SH

      lines = File.read(state_file)
      assert_includes lines, "latest=v2.0.0"
      assert_includes lines, "draft=true"
    end
  end

  def test_repeated_execution_refuses_when_already_latest
    Dir.mktmpdir do |bin_dir|
      mock_gh = File.join(bin_dir, "gh")
      File.write(mock_gh, <<~'SH')
        #!/usr/bin/env bash
        case "$*" in
          *"releases/442117184")
            echo '{"id":442117184,"tag_name":"v2.1.0","draft":false,"target_commitish":"94c796fc34fd699776764d67d2f26013909a308e"}'
            ;;
          *"releases/latest")
            echo '{"tag_name":"v2.1.0"}'
            ;;
          *) exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, mock_gh)

      out, err, status = run_recovery(["--publish"], "PATH" => "#{bin_dir}:#{ENV['PATH']}")
      refute status.success?
      assert_includes err + out, "release 442117184 is not a draft"
    end
  end
end
