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

  # GitHub refuses (HTTP 422) its own Actions app (integration 15368) as a bypass actor on a
  # user-owned repository. Admin bypasses would defeat the protections, so the only role bypass
  # is admins creating release branches. A GitHub App the owner creates is accepted by GitHub and
  # may become the single bypass of release-state or the reference branch; nothing else may.
  APP_BYPASS_ALLOWED = %w[release-state reference-opendisplay].freeze

  def test_bypass_actors_are_supported_and_minimal
    rulesets.each do |name, set|
      set.fetch("bypass_actors", []).each do |actor|
        refute(actor["actor_type"] == "Integration" && actor["actor_id"] == 15_368,
               "#{name}: GitHub's Actions app can't be a bypass actor on this repository")
        case actor["actor_type"]
        when "RepositoryRole"
          assert_equal "release-branch-creation", name, "#{name}: no role bypass"
          assert_equal({ "actor_id" => 5, "actor_type" => "RepositoryRole", "bypass_mode" => "always" }, actor)
        when "Integration"
          assert_includes APP_BYPASS_ALLOWED, name, "#{name}: no app bypass"
          assert_equal 1, set["bypass_actors"].length, "#{name}: a dedicated App is the only bypass"
        else
          flunk "#{name}: unexpected bypass #{actor.inspect}"
        end
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

  # Release state is closed to every writer until a dedicated App is its only bypass: it is
  # never downgraded to "anyone with contents: write may update it".
  def test_release_state_fails_closed
    set = rulesets.fetch("release-state")
    assert_equal %w[creation deletion non_fast_forward update], set["rules"].map { |r| r["type"] }.sort
    assert(set["bypass_actors"].empty? || set["bypass_actors"].map { |a| a["actor_type"] } == ["Integration"])
  end

  # Temporary until the reference sync has a dedicated App: never deleted or rewritten.
  def test_reference_branch_is_never_rewritten_or_deleted
    set = rulesets.fetch("reference-opendisplay")
    types = set["rules"].map { |r| r["type"] }
    assert_includes types, "deletion"
    assert_includes types, "non_fast_forward"
  end

  def test_every_tag_is_protected
    tags = rulesets.fetch("tags")
    assert_equal "tag", tags["target"]
    assert_equal ["~ALL"], tags.dig("conditions", "ref_name", "include")
    assert_equal %w[deletion update], tags["rules"].map { |r| r["type"] }.sort
    assert_empty tags["bypass_actors"]
  end
end
