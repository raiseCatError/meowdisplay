#!/usr/bin/env ruby
# frozen_string_literal: true

# Static signing-configuration checks that need no credential, so the
# main-branch preflight can run them: every shipped bundle id is the same in
# project.yml, fastlane/Fastfile and fastlane/Matchfile (a mismatch makes
# match fetch the wrong profile, which surfaces only mid-release), and
# project.yml ships exactly the Sparkle public key the published baseline
# (baseline.env) trusts.
#
# Usage: check-signing-config.rb [repo root]   (exit 1 with every problem listed)

def shipped_bundle_ids(project_yml)
  project_yml.scan(/^\s*PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)/).flatten
             .reject { |id| id.end_with?(".debug", ".uitests", ".tests") }.uniq.sort
end

def fastfile_bundle_ids(fastfile)
  (fastfile.scan(/bundle_id:\s*"([^"]+)"/).flatten + fastfile.scan(/^IOS_BUNDLE_ID\s*=\s*"([^"]+)"/).flatten).uniq.sort
end

def matchfile_bundle_ids(matchfile)
  list = matchfile[/app_identifier\(\[(.*?)\]\)/m, 1].to_s
  list.scan(/"([^"]+)"/).flatten.uniq.sort
end

def signing_problems(root)
  read = ->(path) { File.read(File.join(root, path)) }
  problems = []
  project = read.("project.yml")
  ids = {
    "project.yml" => shipped_bundle_ids(project),
    "fastlane/Fastfile" => fastfile_bundle_ids(read.("fastlane/Fastfile")),
    "fastlane/Matchfile" => matchfile_bundle_ids(read.("fastlane/Matchfile"))
  }
  problems << "no shipped bundle ids found in project.yml" if ids["project.yml"].empty?
  ids.each do |file, found|
    next if found == ids["project.yml"]

    problems << "#{file} bundle ids #{found.inspect} differ from project.yml's #{ids['project.yml'].inspect}"
  end
  keys = project.scan(/^\s*SUPublicEDKey:\s*(\S+)/).flatten.uniq
  baseline = read.("scripts/release/baseline.env")[/^BASELINE_SUPUBLICEDKEY=(\S+)/, 1]
  if keys.size != 1
    problems << "project.yml must declare exactly one SUPublicEDKey (found #{keys.size})"
  elsif keys.first != baseline
    problems << "project.yml's SUPublicEDKey is not baseline.env's published key; installed copies would reject the feed"
  end
  problems
end

if $PROGRAM_NAME == __FILE__
  root = ARGV[0] || File.expand_path("../..", __dir__)
  problems = signing_problems(root)
  problems.each { |p| warn "::error::#{p}" }
  abort "signing configuration: #{problems.size} problem(s)" unless problems.empty?
  puts "signing configuration consistent: bundle ids, Matchfile, Fastfile and the Sparkle public key agree"
end
