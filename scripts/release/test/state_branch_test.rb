# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

# release-state.sh against a local bare repository: the first write creates
# the orphan branch, read-only commands never push, a refused command
# changes nothing, and a lost race re-runs the command on the newer state.
class ReleaseStateBranchTest < Minitest::Test
  SCRIPT = File.expand_path("../release-state.sh", __dir__)
  SHA = "f" * 40

  def setup
    @dir = Dir.mktmpdir
    @remote = File.join(@dir, "remote.git")
    system("git", "init", "-q", "--bare", @remote, exception: true)
    @config = File.join(@dir, "config.json")
    File.write(@config, JSON.generate("requiredPlatforms" => %w[mac ios], "ios" => { "appId" => "1" }))
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def state_cmd(*args)
    env = { "RELEASE_STATE_REMOTE" => @remote, "GITHUB_RUN_ID" => "7", "TMPDIR" => @dir }
    Open3.capture3(env, "bash", SCRIPT, "2.0.0", *args)
  end

  def remote_log
    out, = Open3.capture2("git", "--git-dir", @remote, "log", "--format=%s", "release-state")
    out.lines.map(&:strip)
  end

  def remote_state
    out, = Open3.capture2("git", "--git-dir", @remote, "show", "release-state:releases/2.0.0.json")
    JSON.parse(out)
  end

  def test_writes_land_on_the_orphan_branch_and_reads_never_push
    _, err, status = state_cmd("init", "STATE", "--config", @config, "--version", "2.0.0")
    assert status.success?, err
    state_cmd("candidate", "STATE", "--sha", SHA, "--run-id", "7")
    assert_equal 2, remote_log.length
    out, files_err, = Open3.capture3("git", "--git-dir", @remote, "ls-tree", "-r", "--name-only", "release-state")
    assert_equal ["releases/2.0.0.json"], out.lines.map(&:strip), files_err
    assert_equal SHA, remote_state.dig("candidate", "sha")

    _, _, gate = state_cmd("gate", "STATE", "--branch-head", SHA)
    refute gate.success?, "not approved yet"
    state_cmd("summary", "STATE", "--branch-head", SHA)
    state_cmd("candidate", "STATE", "--sha", SHA, "--run-id", "8")
    assert_equal 2, remote_log.length, "reads and no-op re-runs push nothing"

    _, err, refused = state_cmd("record", "STATE", "--platform", "mac", "--stage", "built", "--sha", "0" * 40)
    refute refused.success?
    assert_match(/candidate/, err)
    assert_equal 2, remote_log.length
  end
end
