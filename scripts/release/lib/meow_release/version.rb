# frozen_string_literal: true

module MeowRelease
  class Error < StandardError; end

  # One marketing version for every platform (`version.txt`, e.g. 2.0.0).
  class Version
    include Comparable
    PATTERN = /\A(\d+)\.(\d+)\.(\d+)\z/.freeze

    attr_reader :major, :minor, :patch

    def self.parse(text)
      match = PATTERN.match(text.to_s.strip)
      raise Error, "version must be X.Y.Z, got #{text.inspect}" unless match

      new(*match.captures.map(&:to_i))
    end

    def initialize(major, minor, patch)
      @major = major
      @minor = minor
      @patch = patch
    end

    def <=>(other)
      to_a <=> other.to_a
    end

    def to_a
      [major, minor, patch]
    end

    def to_s
      to_a.join(".")
    end

    def branch
      "release/#{self}"
    end

    def tag
      "v#{self}"
    end
  end

  # Each platform's build identifier is independent and must only ever grow:
  # - Mac: CFBundleVersion = the marketing version, which Sparkle compares
  #   (1.20.0 shipped as build "1", so 2.0.0 sorts above it);
  # - iOS: an integer above every build App Store Connect already has for
  #   this version;
  # - Android: versionCode = major*1_000_000 + minor*10_000 + patch*100 +
  #   build (1-99), so a later version always outranks every build of an
  #   earlier one, and builds of one version count up.
  module BuildNumbers
    module_function

    def mac(version)
      Version.parse(version.to_s).to_s
    end

    def ios_next(latest_for_version)
      latest = latest_for_version.to_i
      raise Error, "iOS build number #{latest_for_version.inspect} is not a positive integer" if latest.negative?

      latest + 1
    end

    def android_version_code(version, build)
      v = Version.parse(version.to_s)
      build = Integer(build)
      raise Error, "Android build must be 1-99, got #{build}" unless (1..99).cover?(build)
      raise Error, "minor and patch must be 0-99 for versionCode (#{v})" unless v.minor <= 99 && v.patch <= 99
      raise Error, "major must be 1-2099 for versionCode (#{v})" unless (1..2099).cover?(v.major)

      v.major * 1_000_000 + v.minor * 10_000 + v.patch * 100 + build
    end

    # The first free Android build for `version` above everything Play
    # already has, so a retried upload never collides with a versionCode.
    def android_next(version, highest_existing_code)
      floor = android_version_code(version, 1)
      return 1 if highest_existing_code.nil? || highest_existing_code < floor

      next_build = highest_existing_code - (floor - 1) + 1
      raise Error, "no Android builds left for #{version} (highest #{highest_existing_code})" if next_build > 99

      next_build
    end
  end
end
