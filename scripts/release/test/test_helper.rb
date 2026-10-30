# frozen_string_literal: true

require "minitest/autorun"

# Tool output and the files under test are UTF-8 whatever the locale says.
Encoding.default_external = Encoding::UTF_8
require "time"
require_relative "../lib/meow_release"

module ReleaseTestHelpers
  SHA_A = "a" * 40
  SHA_B = "b" * 40
  NOW = Time.utc(2026, 11, 2, 9, 0, 0)

  # The full publication flow, with Android production explicitly
  # authorized for 2.0.0 by both switches (release config and operator).
  # Tests of the refusals build their own configs.
  def config(overrides = {}, production_authorization = "2.0.0")
    MeowRelease::Config.new({
      "publishMode" => "manual-final-approval",
      "crossPlatformReady" => true,
      "requiredPlatforms" => %w[mac ios android],
      "ios" => { "appId" => "6817552864", "submitForReview" => true,
                 "storeUrl" => "https://apps.apple.com/app/id6817552864" },
      "android" => { "package" => "com.raisecaterror.meowdisplay.android", "uploadTrack" => "internal",
                     "reviewTrack" => "production", "productionRelease" => "2.0.0",
                     "storeUrl" => "https://play.google.com/store/apps/details?id=com.raisecaterror.meowdisplay.android" },
    }.merge(overrides), production_authorization: production_authorization)
  end

  def state_for(cfg = config, sha: SHA_A)
    state = MeowRelease::ReleaseState.fresh(version: "2.0.0", mode: cfg.mode,
                                            required_platforms: cfg.required_platforms, now: NOW)
    state.begin_candidate(sha, run_id: 1, now: NOW)
    state
  end

  # Mac and both stores at the point a candidate's binaries are in place.
  def uploaded_state(cfg = config, sha: SHA_A)
    state = state_for(cfg, sha: sha)
    %w[built signed uploaded approved].each do |stage|
      state.advance("mac", stage, sha: sha, now: NOW, build: "2.0.0",
                                  artifacts: [{ "name" => "MeowDisplay.dmg", "sha256" => "1" * 64 }])
    end
    %w[built signed uploaded].each { |stage| state.advance("ios", stage, sha: sha, now: NOW, build: 7) }
    %w[built signed uploaded].each { |stage| state.advance("android", stage, sha: sha, now: NOW, versionCode: 2_000_001) }
    state
  end

  def ios(build_state: "VALID", version_state: "PREPARE_FOR_SUBMISSION", attached: nil, blockers: [], build: 7,
          release_type: "MANUAL", earliest: nil)
    MeowRelease::IosObservation.new(build: build, build_state: build_state, version_state: version_state,
                                    attached_build: attached, blockers: blockers,
                                    release_type: release_type, earliest_release_date: earliest)
  end

  def play_release(state, code: 2_000_001, track: "production")
    { "track" => track, "versionCodes" => [code], "releaseLifecycleState" => "RELEASE_LIFECYCLE_STATE_#{state}" }
  end

  def play(*releases, codes: [2_000_001])
    MeowRelease::AndroidObservation.new(version_codes: codes, releases: releases, blockers: [])
  end

  # The store a test doesn't script stays neutral: an iOS build still
  # processing, an Android upload Play doesn't show yet.
  def coordinator(state, cfg, apple: {}, google: {})
    @apple = MeowRelease::FakeAppStore.new({ observe: [ios(build_state: "PROCESSING")],
                                             ensure_manual_release: [true] }.merge(apple))
    @play = MeowRelease::FakePlay.new({ observe: [play(codes: [])] }.merge(google))
    MeowRelease::Coordinator.new(state: state, config: cfg, apple: @apple, play: @play, now: NOW)
  end
end

# Records requests and answers from a table of [method, path regex] => [status, body].
class RecordingTransport
  attr_reader :requests

  def initialize(routes)
    @routes = routes
    @requests = []
  end

  def call(method, url, headers: {}, body: nil, raw_body: nil)
    @requests << { method: method, url: url, headers: headers, body: body, raw: raw_body && raw_body.read }
    route = @routes.find { |(m, pattern), _| m == method && url.match?(pattern) }
    raise "unrouted #{method} #{url}" unless route

    answer = route.last
    answer = answer.length > 1 ? answer.shift : answer.first if answer.first.is_a?(Array)
    status, payload = answer
    [status, payload.is_a?(String) ? payload : JSON.generate(payload)]
  end
end
