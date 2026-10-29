# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

# scripts/reference/sync-reference.sh against local repositories standing in
# for the external project and MeowDisplay's own.
class ReferenceSyncTest < Minitest::Test
  SCRIPT = File.expand_path("../../reference/sync-reference.sh", __dir__)

  def setup
    @dir = Dir.mktmpdir
    @external = File.join(@dir, "external")
    @origin = File.join(@dir, "origin.git")
    git("init", "-q", "-b", "main", @external)
    git("init", "-q", "--bare", @origin)
    # MeowDisplay's own branches and tags, which the sync must never touch.
    git("-C", @external, "commit", "-q", "--allow-empty", "-m", "ours")
    git("-C", @external, "push", "-q", @origin, "main:refs/heads/main")
    git("--git-dir", @origin, "tag", "v1.20.0", "main")
    @ours_main = rev(@origin, "refs/heads/main")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def git(*args)
    out, err, status = Open3.capture3("git", "-c", "user.name=t", "-c", "user.email=t@t", *args)
    raise "git #{args.join(' ')}: #{err}" unless status.success?

    out.strip
  end

  def rev(repo, ref)
    git("--git-dir", repo, "rev-parse", ref)
  end

  def commit(message)
    git("-C", @external, "commit", "-q", "--allow-empty", "-m", message)
    git("-C", @external, "rev-parse", "HEAD")
  end

  def sync(expected)
    env = { "REFERENCE_REMOTE" => @external, "ORIGIN_REMOTE" => @origin, "TMPDIR" => @dir,
            "SYNC_RECORD" => File.join(@dir, "record.json") }
    out, err, status = Open3.capture3(env, "bash", SCRIPT, expected)
    record = File.exist?(env["SYNC_RECORD"]) ? JSON.parse(File.read(env["SYNC_RECORD"])) : {}
    [status.success?, record, out + err]
  end

  def reference
    git("--git-dir", @origin, "for-each-ref", "--format=%(objectname)", "refs/heads/reference/opendisplay")
  end

  def test_creates_then_fast_forwards_and_never_imports_tags
    first = commit("upstream 1")
    git("-C", @external, "tag", "v1.28.0")
    ok, record, log = sync(first)
    assert ok, log
    assert_equal "created", record["result"]
    assert_equal first, reference

    ok, record, = sync(first)
    assert ok
    assert_equal "unchanged", record["result"]

    second = commit("upstream 2")
    ok, record, log = sync(second)
    assert ok, log
    assert_equal "fast-forwarded", record["result"]
    assert_equal first, record["previous"]
    assert_equal second, reference

    tags = git("--git-dir", @origin, "tag", "--list")
    assert_equal "v1.20.0", tags, "the external v1.28.0 tag never arrives"
    assert_equal @ours_main, rev(@origin, "refs/heads/main"), "MeowDisplay's branches are untouched"
  end

  def test_rewritten_external_history_is_left_for_a_person
    first = commit("upstream 1")
    sync(first)
    git("-C", @external, "reset", "-q", "--hard", "HEAD~1")
    rewritten = commit("rewritten")
    ok, record, log = sync(rewritten)
    refute ok
    assert_equal "diverged", record["result"]
    assert_match(/history was rewritten/, log)
    assert_equal first, reference, "nothing was overwritten"
  end

  def test_a_fetch_that_doesnt_match_the_api_stops
    commit("upstream 1")
    ok, record, = sync("0" * 40)
    refute ok
    assert_equal "mismatch", record["result"]
    assert_equal "", reference
  end
end
