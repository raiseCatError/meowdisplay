# frozen_string_literal: true

require_relative "version"

module MeowRelease
  # A failure worth retrying as-is (HTTP 429/5xx, timeouts). Everything else
  # is permanent: retrying it would only repeat the same refusal.
  class TransientError < Error; end

  # Retries a block on TransientError with exponential backoff. Only for
  # calls that are safe to repeat; anything that submits or publishes is
  # re-observed before it is attempted again (Coordinator).
  module Retry
    module_function

    def with_backoff(attempts: 4, base: 2.0, sleeper: ->(s) { sleep(s) }, on_retry: nil)
      tries = 0
      begin
        tries += 1
        yield
      rescue TransientError => e
        raise if tries >= attempts

        delay = base * (2**(tries - 1))
        on_retry&.call(tries, e, delay)
        sleeper.call(delay)
        retry
      end
    end
  end

  # App Store Connect's version states, as the API reports them
  # (`appStoreState`, or the newer `appVersionState`). A build finishing
  # processing (`VALID`) is NOT approval: only these version states are.
  #
  # PENDING_APPLE_RELEASE is not "approved and waiting for us": Apple holds
  # the version until the OS release it requires ships. It is reported as a
  # hold and never opens the publication gate. Approval alone also isn't
  # enough to count: the version must be set to manual release
  # (IosObservation#manual_release?), or Apple could release it on its own.
  module AppleReview
    IN_REVIEW = %w[WAITING_FOR_REVIEW IN_REVIEW READY_FOR_REVIEW WAITING_FOR_EXPORT_COMPLIANCE].freeze
    APPROVED = %w[PENDING_DEVELOPER_RELEASE ACCEPTED].freeze
    HELD = %w[PENDING_APPLE_RELEASE].freeze
    PUBLISHED = %w[READY_FOR_SALE READY_FOR_DISTRIBUTION PROCESSING_FOR_APP_STORE PROCESSING_FOR_DISTRIBUTION].freeze
    REJECTED = %w[REJECTED METADATA_REJECTED INVALID_BINARY].freeze
    NEEDS_DEVELOPER = %w[DEVELOPER_REJECTED PREPARE_FOR_SUBMISSION PENDING_CONTRACT].freeze
    MANUAL = "MANUAL"

    module_function

    def classify(state)
      return :missing if state.nil?
      return :in_review if IN_REVIEW.include?(state)
      return :approved if APPROVED.include?(state)
      return :held if HELD.include?(state)
      return :published if PUBLISHED.include?(state)
      return :rejected if REJECTED.include?(state)
      return :preparing if NEEDS_DEVELOPER.include?(state)

      :unknown
    end
  end

  # What one look at App Store Connect showed for this release's version.
  # `release_type` / `earliest_release_date` are the App Store version's own
  # release settings (nil when the version doesn't exist yet).
  IosObservation = Struct.new(:build, :build_state, :version_state, :attached_build, :submission_id,
                              :blockers, :listing_version, :release_type, :earliest_release_date,
                              keyword_init: true) do
    # Only a manually released version waits for our explicit release
    # request; AFTER_APPROVAL or SCHEDULED (or any earliest release date)
    # would let Apple make it public without the publication gate.
    def manual_release?
      release_type == AppleReview::MANUAL && earliest_release_date.nil?
    end

    def release_settings
      [release_type || "unset", earliest_release_date && "earliest #{earliest_release_date}"].compact.join(", ")
    end
  end

  # Google Play's release lifecycle, from
  # `GET applications/{package}/tracks/{track}/releases` (ReleaseSummary.
  # releaseLifecycleState). It reports review per track release:
  # APPROVED_NOT_PUBLISHED is the approved-but-held state managed publishing
  # creates, and only PUBLISHED means users can install it. The list skips
  # obsolete releases and returns at most 20.
  module PlayReview
    STATES = {
      "RELEASE_LIFECYCLE_STATE_DRAFT" => :draft,
      "RELEASE_LIFECYCLE_STATE_NOT_SENT_FOR_REVIEW" => :not_sent,
      "RELEASE_LIFECYCLE_STATE_IN_REVIEW" => :in_review,
      "RELEASE_LIFECYCLE_STATE_APPROVED_NOT_PUBLISHED" => :approved,
      "RELEASE_LIFECYCLE_STATE_NOT_APPROVED" => :rejected,
      "RELEASE_LIFECYCLE_STATE_PUBLISHED" => :published,
    }.freeze

    module_function

    def classify(state)
      STATES.fetch(state, :unknown)
    end

    # The release on `track` that carries `version_code`, if any.
    def release_for(releases, track:, version_code:)
      Array(releases).find do |release|
        release["track"] == track && Array(release["versionCodes"]).include?(version_code)
      end
    end
  end

  # What one look at Google Play showed: every versionCode Play knows (from
  # the edit's tracks) and the review lifecycle of each track's releases.
  AndroidObservation = Struct.new(:version_codes, :releases, :blockers, keyword_init: true)

  # Scripted stand-ins for App Store Connect and Google Play, used by the
  # simulations and tests: every call answers from a queue (the last answer
  # repeats), an answer may be an exception to raise, and every call is
  # recorded so a test can prove what was (and wasn't) submitted.
  class ScriptedClient
    attr_reader :calls

    def initialize(script)
      @script = script.transform_keys(&:to_sym)
      @calls = []
    end

    def respond(method, *args)
      @calls << [method, *args]
      queue = @script.fetch(method) { raise Error, "#{self.class.name}: unscripted call #{method}" }
      answer = queue.length > 1 ? queue.shift : queue.first
      answer = answer.call(*args) if answer.respond_to?(:call)
      raise answer if answer.is_a?(Exception)

      answer
    end

    def count(method)
      @calls.count { |call| call.first == method }
    end
  end

  class FakeAppStore < ScriptedClient
    def observe(version, build: nil)
      respond(:observe, version, build)
    end

    def latest_build_number(version)
      respond(:latest_build_number, version)
    end

    def ensure_manual_release(version)
      respond(:ensure_manual_release, version)
    end

    def submit_for_review(version, build)
      respond(:submit_for_review, version, build)
    end

    def cancel_review(version)
      respond(:cancel_review, version)
    end

    def release(version)
      respond(:release, version)
    end
  end

  class FakePlay < ScriptedClient
    def observe(package, tracks:)
      respond(:observe, package, tracks)
    end

    # `replace_in_review`: false commits with ERROR_IF_IN_REVIEW (a retry or
    # a second pass never cancels a review it didn't mean to); true commits
    # with CANCEL_IN_REVIEW_AND_SUBMIT, used only to replace a superseded
    # candidate's release.
    def submit(package, version_code, track:, status:, user_fraction: nil, replace_in_review: false)
      respond(:submit, package, version_code, track, status, user_fraction, replace_in_review)
    end

    def publish(package, version_code, track:, user_fraction: nil)
      respond(:publish, package, version_code, track, user_fraction)
    end
  end
end
