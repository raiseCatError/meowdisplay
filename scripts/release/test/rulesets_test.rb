# frozen_string_literal: true

require_relative "test_helper"
require "json"

# The ruleset definitions (.github/rulesets) as GitHub will accept and enforce them.
class RulesetFilesTest < Minitest::Test
  DIR = File.expand_path("../../../.github/rulesets", __dir__)

  def rulesets
    Dir[File.join(DIR, "*.json")].to_h { |f| [File.basename(f, ".json"), JSON.parse(File.read(f, encoding: "UTF-8"))] }
  end

  def checks(set)
    set["rules"].find { |r| r["type"] == "required_status_checks" }&.dig("parameters", "required_status_checks")
                &.map { |c| c["context"] } || []
  end

  # GitHub refuses (HTTP 422) its own Actions app as a bypass actor on a user-owned repository,
  # and admin bypasses would defeat the protections; only the release-branch creation rule
  # names one (admins create release branches).
  def test_bypass_actors_are_supported_and_minimal
    rulesets.each do |name, set|
      set.fetch("bypass_actors", []).each do |actor|
        refute(actor["actor_type"] == "Integration" && actor["actor_id"] == 15_368, "#{name}: GitHub Actions can't be a bypass actor here")
        assert_equal "release-branch-creation", name, "#{name}: unexpected bypass #{actor.inspect}"
        assert_equal({ "actor_id" => 5, "actor_type" => "RepositoryRole", "bypass_mode" => "always" }, actor)
      end
    end
    assert_equal %w[creation], rulesets["release-branch-creation"]["rules"].map { |r| r["type"] }, "the admin bypass covers creation only"
  end

  def test_protected_branches_require_every_check_and_keep_history
    %w[dev main release-branches].each do |name|
      assert_equal %w[android conventional mac release-tooling], checks(rulesets[name]).sort, name
      types = rulesets[name]["rules"].map { |r| r["type"] }
      assert_includes types, "deletion", name
      assert_includes types, "non_fast_forward", name
    end
    params = rulesets["release-branches"]["rules"].find { |r| r["type"] == "required_status_checks" }["parameters"]
    assert_equal true, params["do_not_enforce_on_create"], "a new release branch can't carry PR-only checks"
  end

  def test_state_and_reference_branches_are_never_rewritten_or_deleted
    %w[release-state reference-opendisplay].each do |name|
      assert_equal %w[deletion non_fast_forward], rulesets[name]["rules"].map { |r| r["type"] }.sort, name
      assert_empty rulesets[name]["bypass_actors"], name
    end
  end

  def test_every_tag_is_protected
    tags = rulesets.fetch("tags")
    assert_equal "tag", tags["target"]
    assert_equal ["~ALL"], tags.dig("conditions", "ref_name", "include")
    assert_equal %w[deletion update], tags["rules"].map { |r| r["type"] }.sort
    assert_empty tags["bypass_actors"]
  end
end
