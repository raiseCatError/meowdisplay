# frozen_string_literal: true

require "json"
require "time"
require_relative "version"

module MeowRelease
  # Every platform moves through the same ladder. Only `published` means the
  # public can install it: a build that succeeded, a candidate uploaded to a
  # store and a candidate a store approved are three different, earlier facts.
  module Stage
    LADDER = %w[pending built signed uploaded submitted in_review approved published].freeze
    SIDE = %w[blocked rejected failed superseded].freeze
    ALL = (LADDER + SIDE).freeze

    LABELS = {
      "pending" => "Not started",
      "built" => "Built and tested",
      "signed" => "Signed",
      "uploaded" => "Uploaded to distribution service",
      "submitted" => "Submitted for review",
      "in_review" => "Under review",
      "approved" => "Approved / ready",
      "published" => "Published",
      "blocked" => "Blocked",
      "rejected" => "Rejected",
      "failed" => "Failed (retryable)",
      "superseded" => "Superseded by a newer candidate",
    }.freeze

    module_function

    def rank(stage)
      LADDER.index(stage) || -1
    end

    def label(stage)
      LABELS.fetch(stage) { stage.to_s }
    end

    # Forward on the ladder (never backward except through a side state),
    # into any side state, and out of blocked/rejected/failed back onto the
    # ladder for a retry. `published` and `superseded` are final.
    def allowed?(from, to)
      return false unless ALL.include?(to)
      return false if %w[published superseded].include?(from)
      return true if SIDE.include?(to)
      return true if %w[blocked rejected failed].include?(from)

      rank(to) > rank(from)
    end
  end

  PLATFORMS = %w[mac ios android].freeze
  MODES = %w[manual-final-approval auto-publish-after-approval].freeze

  # The persistent record of one release, kept as JSON on the `release-state`
  # branch (releases/<version>.json) and rewritten only through this class.
  # Everything is keyed by the candidate's source SHA: a newer push
  # supersedes the old candidate and nothing recorded for the old SHA can
  # ever count toward publishing the new one.
  class ReleaseState
    SCHEMA = 1

    attr_reader :data

    def self.fresh(version:, mode:, required_platforms:, now: Time.now.utc)
      raise Error, "unknown mode #{mode}" unless MODES.include?(mode)

      unknown = required_platforms - PLATFORMS
      raise Error, "unknown platforms #{unknown}" unless unknown.empty?

      v = Version.parse(version)
      new(
        "schema" => SCHEMA,
        "version" => v.to_s,
        "branch" => v.branch,
        "mode" => mode,
        "requiredPlatforms" => required_platforms,
        "candidate" => nil,
        "superseded" => [],
        "platforms" => PLATFORMS.map { |p| [p, { "stage" => "pending" }] }.to_h,
        "website" => { "stage" => "pending" },
        "publication" => { "stage" => "not-started" },
        "events" => [{ "at" => now.iso8601, "event" => "created" }]
      )
    end

    def self.load(json)
      data = JSON.parse(json)
      raise Error, "unsupported release-state schema #{data['schema']}" unless data["schema"] == SCHEMA

      new(data)
    end

    def initialize(data)
      @data = data
    end

    def to_json(*_args)
      JSON.pretty_generate(@data) + "\n"
    end

    def version
      @data["version"]
    end

    def mode
      @data["mode"]
    end

    def required_platforms
      @data["requiredPlatforms"]
    end

    def candidate_sha
      @data.dig("candidate", "sha")
    end

    def platform(name)
      @data["platforms"].fetch(name)
    end

    def stage(name)
      platform(name)["stage"]
    end

    def website
      @data["website"]
    end

    def publication
      @data["publication"]
    end

    def publication_stage
      publication["stage"]
    end

    # A push to the release branch. The same SHA again (a re-run) keeps
    # everything; a different SHA supersedes all progress of the old one.
    def begin_candidate(sha, run_id:, now: Time.now.utc)
      raise Error, "candidate SHA must be 40 hex digits" unless sha.to_s.match?(/\A[0-9a-f]{40}\z/)
      return false if candidate_sha == sha
      raise Error, "#{version} is already published from #{candidate_sha}" if publication_stage == "published"
      raise Error, "#{version} is being published from #{candidate_sha}" if publication_stage == "in-progress"

      if candidate_sha
        @data["superseded"] << { "sha" => candidate_sha, "at" => now.iso8601,
                                 "platforms" => PLATFORMS.map { |p| [p, platform(p).dup] }.to_h }
      end
      @data["candidate"] = { "sha" => sha, "runId" => run_id, "createdAt" => now.iso8601 }
      PLATFORMS.each { |p| @data["platforms"][p] = { "stage" => "pending", "sha" => sha } }
      @data["website"] = { "stage" => "pending" }
      @data["publication"] = { "stage" => "not-started" }
      log("candidate", now: now, sha: sha, runId: run_id)
      true
    end

    # What the superseded candidate left in a store that the new one must
    # replace (an iOS build still in review, an Android track release).
    def superseded_submissions
      last = @data["superseded"].last
      return {} unless last

      last["platforms"].select { |_, record| %w[submitted in_review approved].include?(record["stage"]) }
    end

    # Moves one platform, refusing anything recorded for another SHA and any
    # step backwards. `details` are merged into the platform record (build
    # numbers, checksums, store ids, blockers).
    def advance(name, to, sha:, now: Time.now.utc, **details)
      raise Error, "unknown platform #{name}" unless PLATFORMS.include?(name)
      raise Error, "#{name}: result for #{sha.to_s[0, 12]} but the candidate is #{candidate_sha.to_s[0, 12]}" unless sha == candidate_sha

      from = stage(name)
      raise Error, "#{name}: #{from} -> #{to} is not allowed" unless from == to || Stage.allowed?(from, to)

      record = platform(name)
      # The same observation again (every monitoring pass) changes nothing,
      # so the stored record only changes when something happened.
      return false if from == to && details.all? { |key, value| record[key.to_s] == value }

      details.each { |key, value| record[key.to_s] = value }
      record["blockers"] = [] unless %w[blocked rejected failed].include?(to) || details.key?(:blockers)
      record["stage"] = to
      record["updatedAt"] = now.iso8601
      log("platform", now: now, platform: name, from: from, to: to) unless from == to
      true
    end

    def set_website(stage, now: Time.now.utc, **details)
      website.merge!(details.map { |k, v| [k.to_s, v] }.to_h)
      website["stage"] = stage
      website["updatedAt"] = now.iso8601
      log("website", now: now, to: stage)
    end

    def set_publication(stage, now: Time.now.utc, **details)
      publication.merge!(details.map { |k, v| [k.to_s, v] }.to_h)
      publication["stage"] = stage
      publication["updatedAt"] = now.iso8601
      log("publication", now: now, to: stage)
    end

    # Why publication can't start yet; empty when it may. Every required
    # platform must be approved for THIS candidate SHA, and the release
    # branch must still point at it (a newer push never publishes the older
    # artifacts it replaced).
    def publication_blockers(branch_head:)
      return ["no candidate"] unless candidate_sha

      blockers = []
      if branch_head != candidate_sha
        blockers << "release branch is at #{branch_head.to_s[0, 12]}, the candidate is #{candidate_sha[0, 12]}"
      end
      required_platforms.each do |name|
        record = platform(name)
        blockers << "#{name}: built from #{record['sha'].to_s[0, 12]}, not the candidate" if record["sha"] != candidate_sha
        unless %w[approved published].include?(record["stage"])
          blockers << "#{name}: #{Stage.label(record['stage']).downcase}"
        end
        Array(record["blockers"]).each { |b| blockers << "#{name}: #{b}" }
      end
      blockers << "publication is #{publication_stage}" if %w[in-progress published].include?(publication_stage)
      blockers
    end

    def log(event, now:, **fields)
      @data["events"] << { "at" => now.iso8601, "event" => event }.merge(fields.map { |k, v| [k.to_s, v] }.to_h)
    end
  end
end
