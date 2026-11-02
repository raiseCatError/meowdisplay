# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "tmpdir"
load File.expand_path("../check-signing-config.rb", __dir__)

class SigningConfigTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)
  FILES = %w[project.yml fastlane/Fastfile fastlane/Matchfile scripts/release/baseline.env].freeze

  def with_copy(edits = {})
    Dir.mktmpdir do |dir|
      FILES.each do |f|
        FileUtils.mkdir_p(File.join(dir, File.dirname(f)))
        text = File.read(File.join(ROOT, f))
        (edits[f] || []).each { |from, to| text = text.sub(from, to) || text }
        File.write(File.join(dir, f), text)
      end
      yield dir
    end
  end

  def test_the_real_configuration_is_consistent
    assert_equal [], signing_problems(ROOT)
  end

  def test_a_bundle_id_missing_from_the_matchfile_is_caught
    with_copy("fastlane/Matchfile" => [[', "com.raisecaterror.meowdisplay.mac.receiver"', ""]]) do |dir|
      assert_match(/Matchfile bundle ids .* differ/, signing_problems(dir).join("\n"))
    end
  end

  def test_a_changed_sparkle_key_is_caught
    with_copy("project.yml" => [[/SUPublicEDKey: \S+/, "SUPublicEDKey: AAAA"]]) do |dir|
      assert_match(/SUPublicEDKey/, signing_problems(dir).join("\n"))
    end
  end
end
