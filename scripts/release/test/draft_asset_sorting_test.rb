# frozen_string_literal: true

require "minitest/autorun"
require "open3"

class DraftAssetSortingTest < Minitest::Test
  # The five assets produced by Mac packaging and expected in the release draft:
  ASSETS = %w[
    MeowDisplay.dmg
    MeowDisplayReceiver.dmg
    appcast.xml
    appcast-receiver.xml
    SHA256SUMS.txt
  ].freeze

  def test_lc_all_c_sort_matches_jq_byte_collation
    # jq 'sort' orders by Unicode code point / byte value:
    # 'M' (0x4D), 'S' (0x53) precede 'a' (0x61).
    jq_sorted = %w[
      MeowDisplay.dmg
      MeowDisplayReceiver.dmg
      SHA256SUMS.txt
      appcast-receiver.xml
      appcast.xml
    ]

    out, status = Open3.capture2({ "LC_ALL" => "C" }, "sort", stdin_data: ASSETS.join("\n") + "\n")
    assert status.success?
    c_sorted = out.lines.map(&:strip)

    assert_equal jq_sorted, c_sorted
  end

  def test_locale_sensitive_sort_divergence_is_documented
    # The runner's locale-dependent sort put lowercase 'appcast*' before 'MeowDisplay*'.
    # LC_ALL=C is required to guarantee deterministic comparison against jq's output.
    c_out, _ = Open3.capture2({ "LC_ALL" => "C" }, "sort", stdin_data: ASSETS.join("\n") + "\n")
    c_sorted = c_out.lines.map(&:strip)

    assert_equal "MeowDisplay.dmg", c_sorted.first
    assert_equal "appcast.xml", c_sorted.last
  end
end
