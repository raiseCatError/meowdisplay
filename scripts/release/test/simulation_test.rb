# frozen_string_literal: true

require_relative "test_helper"

# End-to-end dry runs of a whole release against mocked stores, a modelled
# GitHub Releases and website. Each scenario drives the same library calls
# the workflows make: candidate push -> build results -> monitor passes ->
# gate -> publication (Mac -> stores -> website -> finish).
class ReleaseSimulationTest < Minitest::Test
  include ReleaseTestHelpers
  include MeowRelease

  # GitHub Releases as the fail-closed Mac step uses it: a draft first, its
  # assets compared, then Latest, then the live feed check that reverts.
  class GitHubModel
    attr_reader :releases, :latest

    REQUIRED = %w[MeowDisplay.dmg MeowDisplayReceiver.dmg appcast.xml appcast-receiver.xml SHA256SUMS.txt].freeze

    def initialize
      @releases = { "v1.20.0" => { assets: REQUIRED.dup, draft: false } }
      @latest = "v1.20.0"
      @history = [@latest]
    end

    # Returns [published?, reverted?].
    def publish_mac(tag, assets:, feeds_live:)
      raise "tag #{tag} exists" if @releases.key?(tag) && !@releases[tag][:draft]

      @releases[tag] = { assets: assets, draft: true }
      return [false, false] unless (REQUIRED - assets).empty? # byte check failed: stays a draft

      previous = @latest
      @releases[tag][:draft] = false
      @latest = tag
      @history << tag
      return [true, false] if feeds_live

      @latest = previous
      @releases[tag][:draft] = true
      @history << previous
      [false, true]
    end

    def latest_complete?
      (REQUIRED - @releases[@latest][:assets]).empty? && !@releases[@latest][:draft]
    end

    def every_latest_was_complete?
      @history.all? { |tag| (REQUIRED - @releases[tag][:assets]).empty? }
    end
  end

  def setup
    @github = GitHubModel.new
    @site_version = "1.20.0"
  end

  def push(state, sha)
    state.begin_candidate(sha, run_id: sha[0].ord, now: NOW)
    # release-candidate.yml: three platform jobs report.
    %w[built signed uploaded approved].each do |s|
      state.advance("mac", s, sha: sha, now: NOW, build: "2.0.0",
                              artifacts: GitHubModel::REQUIRED.map { |n| { "name" => n, "sha256" => sha[0] * 64 } })
    end
    %w[built signed uploaded].each { |s| state.advance("ios", s, sha: sha, now: NOW, build: sha == SHA_A ? 7 : 8) }
    %w[built signed uploaded].each { |s| state.advance("android", s, sha: sha, now: NOW, versionCode: sha == SHA_A ? 2_000_001 : 2_000_002) }
  end

  def monitor(state, apple:, google:)
    c = coordinator(state, config, apple: apple, google: google)
    c.tick
    c
  end

  # The publish workflow's sequence, with the Mac step's outcome injected.
  def publish(state, branch_head:, feeds_live: true, assets: GitHubModel::REQUIRED, site_serves: nil, apple: {}, google: {})
    publisher = Publisher.new(state: state, config: config, now: NOW)
    publisher.start!(branch_head: branch_head)
    if state.stage("mac") != "published"
      published, reverted = @github.publish_mac("v#{state.version}", assets: assets, feeds_live: feeds_live)
      unless published
        publisher.mac_failed!(reason: reverted ? "live feeds didn't verify" : "draft assets incomplete", reverted: reverted)
        return :mac_failed
      end
      publisher.mac_published!(release_url: "https://github.com/raiseCatError/meowdisplay/releases/tag/v#{state.version}")
    end
    waiting = publisher.publish_stores!(coordinator(state, config, apple: apple, google: google))
    manifest = publisher.website_manifest
    @site_version = site_serves || manifest["version"]
    publisher.website_updated!(url: "https://meowdisplay.app/release.json", live_version: @site_version)
    pending = publisher.finish!(promotion_pr: 99)
    { waiting: waiting, pending: pending, manifest: manifest }
  end

  def approve_everything(state, ios_build: 7, code: 2_000_001)
    monitor(state, apple: { observe: [ios(build: ios_build), ios(build: ios_build)], submit_for_review: [true] },
                   google: { observe: [play(codes: [code])], submit: [true] })
    monitor(state, apple: { observe: [ios(version_state: "IN_REVIEW", attached: ios_build, build: ios_build)] },
                   google: { observe: [play(play_release("IN_REVIEW", code: code), codes: [code])] })
    monitor(state, apple: { observe: [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: ios_build, build: ios_build)] },
                   google: { observe: [play(play_release("APPROVED_NOT_PUBLISHED", code: code), codes: [code])] })
  end

  def test_success_through_managed_publishing_and_website
    state = state_for
    push(state, SHA_A)
    approve_everything(state)
    assert_empty state.publication_blockers(branch_head: SHA_A)
    assert_match(/Waiting for your approval/, Summary.render(state, branch_head: SHA_A))

    result = publish(state, branch_head: SHA_A,
                            apple: { observe: [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 7)], release: [true] },
                            google: { observe: [play(play_release("APPROVED_NOT_PUBLISHED"))] })
    assert_equal "v2.0.0", @github.latest
    assert_equal "published", state.stage("ios")
    assert_equal 1, @apple.count(:release)
    assert_equal ["android"], result[:waiting], "held by managed publishing until the Console click"
    refute result[:manifest]["platforms"].key?("android"), "the site never lists Play before it's live"
    assert_equal %w[android], result[:pending]

    # The Publish click happens in Play Console; the next monitor pass sees it.
    monitor(state, apple: { observe: [ios(version_state: "READY_FOR_SALE", attached: 7)] },
                   google: { observe: [play(play_release("PUBLISHED"))] })
    result = publish(state, branch_head: SHA_A, google: { observe: [play(play_release("PUBLISHED"))] })
    assert result[:manifest]["platforms"].key?("android")
    assert_empty result[:pending]
    assert_equal "published", state.publication_stage
    assert @github.every_latest_was_complete?
  end

  def test_rejection_holds_everything_until_a_fixed_candidate_is_approved
    state = state_for
    push(state, SHA_A)
    monitor(state, apple: { observe: [ios, ios], submit_for_review: [true] }, google: { observe: [play], submit: [true] })
    monitor(state, apple: { observe: [ios(version_state: "REJECTED", attached: 7)] },
                   google: { observe: [play(play_release("APPROVED_NOT_PUBLISHED"))] })
    assert_equal "rejected", state.stage("ios")
    assert_raises(GateClosed) { Publisher.new(state: state, config: config, now: NOW).start!(branch_head: SHA_A) }
    assert_equal "v1.20.0", @github.latest, "nothing public changed"
    assert_match(/fix it, then push a new candidate/, Summary.render(state, branch_head: SHA_A))

    push(state, SHA_B)
    approve_everything(state, ios_build: 8, code: 2_000_002)
    publish(state, branch_head: SHA_B,
                   apple: { observe: [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 8, build: 8)], release: [true] },
                   google: { observe: [play(play_release("PUBLISHED", code: 2_000_002), codes: [2_000_002])] })
    assert_equal "published", state.publication_stage
  end

  def test_a_store_outage_is_retried_and_records_nothing_when_it_persists
    state = state_for
    push(state, SHA_A)
    flaky = [TransientError.new("HTTP 503"), TransientError.new("HTTP 503"), play]
    monitor(state, apple: { observe: [ios(build_state: "PROCESSING")] }, google: { observe: flaky, submit: [true] })
    assert_equal "submitted", state.stage("android")

    before = state.to_json
    assert_raises(TransientError) do
      monitor(state, apple: { observe: [TransientError.new("timeout")] }, google: { observe: [play] })
    end
    assert_equal before, state.to_json
  end

  # The live feeds don't serve the new release: Latest goes back to 1.20.0,
  # no store is touched, and a later retry publishes.
  def test_a_mac_failure_rolls_back_before_anything_irreversible
    state = state_for
    push(state, SHA_A)
    approve_everything(state)
    assert_equal :mac_failed, publish(state, branch_head: SHA_A, feeds_live: false)
    assert_equal "v1.20.0", @github.latest
    assert_equal "rolled-back", state.publication_stage
    assert_equal "approved", state.stage("ios"), "the store releases never started"
    assert @github.every_latest_was_complete?

    # Incomplete assets never even become Latest.
    @github.releases.delete("v2.0.0")
    assert_equal :mac_failed, publish(state, branch_head: SHA_A, assets: %w[MeowDisplay.dmg appcast.xml])
    assert_equal "v1.20.0", @github.latest

    @github.releases.delete("v2.0.0")
    publish(state, branch_head: SHA_A,
                   apple: { observe: [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 7)], release: [true] },
                   google: { observe: [play(play_release("PUBLISHED"))] })
    assert_equal "published", state.publication_stage
  end

  def test_a_website_that_doesnt_show_the_release_keeps_publication_open
    state = state_for
    push(state, SHA_A)
    approve_everything(state)
    result = publish(state, branch_head: SHA_A, site_serves: "1.20.0",
                            apple: { observe: [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 7)], release: [true] },
                            google: { observe: [play(play_release("PUBLISHED"))] })
    assert_equal ["website"], result[:pending]
    assert_equal "failed", state.website["stage"]
    assert_equal "in-progress", state.publication_stage

    # Re-run: Mac and stores are already done and are not repeated.
    publish(state, branch_head: SHA_A, google: { observe: [play(play_release("PUBLISHED"))] },
                   apple: { observe: [ios(version_state: "READY_FOR_SALE", attached: 7)] })
    assert_equal 0, @apple.count(:release)
    assert_equal "published", state.publication_stage
  end

  # A crash after the Mac went live: the re-run resumes with the stores.
  def test_a_publication_interrupted_after_the_mac_step_resumes
    state = state_for
    push(state, SHA_A)
    approve_everything(state)
    publisher = Publisher.new(state: state, config: config, now: NOW)
    publisher.start!(branch_head: SHA_A)
    @github.publish_mac("v2.0.0", assets: GitHubModel::REQUIRED, feeds_live: true)
    publisher.mac_published!(release_url: "u")
    # ...runner lost here...
    resumed = Publisher.new(state: state, config: config, now: NOW)
    refute resumed.start!(branch_head: SHA_A), "already in progress: resume, don't restart"
    publish(state, branch_head: SHA_A,
                   apple: { observe: [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 7)], release: [true] },
                   google: { observe: [play(play_release("PUBLISHED"))] })
    assert_equal "published", state.publication_stage
    assert_equal 1, @github.releases.count { |tag, r| tag == "v2.0.0" && !r[:draft] }
  end

  # A push while candidate A is in review: A's approvals can't publish B,
  # A's iOS submission is withdrawn, and a publish attempt for the old head
  # is refused.
  def test_a_newer_push_never_publishes_older_artifacts
    state = state_for
    push(state, SHA_A)
    approve_everything(state)
    push(state, SHA_B)
    assert_raises(GateClosed) { Publisher.new(state: state, config: config, now: NOW).start!(branch_head: SHA_B) }
    assert_raises(GateClosed) { Publisher.new(state: state, config: config, now: NOW).start!(branch_head: SHA_A) }

    monitor(state, apple: { observe: [ios(version_state: "PENDING_DEVELOPER_RELEASE", attached: 7, build: 8)], cancel_review: [true] },
                   google: { observe: [play(play_release("APPROVED_NOT_PUBLISHED"), codes: [2_000_001, 2_000_002])],
                             submit: [true] })
    assert_equal 1, @apple.count(:cancel_review)
    assert_equal true, @play.calls.find { |x| x.first == :submit }.last, "Play replaces A's approved release"
    assert_equal "v1.20.0", @github.latest
  end

  def test_the_summary_tells_built_uploaded_approved_and_published_apart
    state = state_for
    push(state, SHA_A)
    text = Summary.render(state, branch_head: SHA_A)
    assert_match(/Approved \/ ready/, text)
    assert_match(/Uploaded to distribution service/, text)
    assert_match(/Only \*\*Published\*\* means users can install it/, text)
  end
end
