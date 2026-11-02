#!/usr/bin/env ruby
# frozen_string_literal: true

# Which secret and variable each release environment needs, derived from the
# workflows themselves (a job's `secrets.X` / `vars.X` under its `environment:`),
# and what GitHub has. Values are never printed, logged or put on a command line.
#
#   release-secrets.rb status
#       read-only: every environment's required names, set or missing, and any
#       repository-level secret a job could read without an environment.
#   release-secrets.rb set NAME [--file PATH]
#       the owner sets secret NAME in every environment whose jobs use it, from
#       PATH, from stdin, or from a hidden prompt. The value reaches gh on stdin.
#
# Needs gh authenticated as the owner (REPOSITORY overrides the repository).
require "io/console"
require "json"
require "open3"
require "yaml"

REPO = ENV.fetch("REPOSITORY", "raiseCatError/meowdisplay")
DIR = File.expand_path("../../.github/workflows", __dir__)
# Repository-level identifiers (not secrets) that stay outside environments.
REPO_VARIABLES = %w[RELEASE_APP_ID RELEASE_APP_CLIENT_ID WEBSITE_APP_CLIENT_ID].freeze
SWITCHES = %w[RELEASE_AUTOMATION RELEASE_PUBLISH_MODE RELEASE_AUTO_PROMOTE REFERENCE_SYNC REPOSITORY_GUARD
              EXPECTED_DEFAULT_BRANCH].freeze

def required
  need = Hash.new { |h, k| h[k] = { secrets: [], vars: [] } }
  Dir[File.join(DIR, "*.yml")].sort.each do |path|
    YAML.safe_load(File.read(path), aliases: false).fetch("jobs", {}).each_value do |job|
      env = job["environment"].is_a?(Hash) ? job["environment"]["name"] : job["environment"]
      text = job.to_s
      need[env][:secrets] |= text.scan(/secrets\.([A-Z0-9_]+)/).flatten - ["GITHUB_TOKEN"]
      need[env][:vars] |= text.scan(/vars\.([A-Z0-9_]+)/).flatten - REPO_VARIABLES - SWITCHES
    end
  end
  need
end

def gh(*args, stdin: nil)
  out, err, status = Open3.capture3("gh", *args, stdin_data: stdin)
  raise "gh #{args.first(3).join(' ')} failed: #{err.strip}" unless status.success?

  out
end

def names(path, key)
  JSON.parse(gh("api", path)).fetch(key).map { |x| x["name"] }
rescue RuntimeError
  []
end

case ARGV.shift
when "status"
  need = required
  repo_secrets = names("repos/#{REPO}/actions/secrets", "secrets")
  repo_vars = names("repos/#{REPO}/actions/variables", "variables")
  missing = 0
  need.keys.compact.sort.each do |env|
    have_s = names("repos/#{REPO}/environments/#{env}/secrets", "secrets")
    have_v = names("repos/#{REPO}/environments/#{env}/variables", "variables")
    puts "#{env}:"
    need[env][:secrets].sort.each do |s|
      state = if have_s.include?(s) then "set"
              elsif repo_secrets.include?(s) then "MISSING here (only a repository-level copy, readable by any workflow)"
              else "MISSING"
              end
      missing += 1 unless state == "set"
      puts "  secret   #{s.ljust(32)} #{state}"
    end
    need[env][:vars].sort.each do |v|
      state = have_v.include?(v) ? "set" : "MISSING"
      missing += 1 unless state == "set"
      puts "  variable #{v.ljust(32)} #{state}"
    end
  end
  puts "repository variables:"
  REPO_VARIABLES.each { |v| puts "  #{v.ljust(41)} #{repo_vars.include?(v) ? 'set' : 'MISSING'}" }
  unless repo_secrets.empty?
    puts "repository-level secrets (readable by every workflow on every branch; delete once each " \
         "environment copy is verified): #{repo_secrets.join(', ')}"
  end
  puts missing.zero? ? "every environment has what its jobs use" : "#{missing} missing"
when "set"
  name = ARGV.shift or abort "usage: release-secrets.rb set NAME [--file PATH]"
  abort "#{name}: not a secret name" unless name.match?(/\A[A-Z][A-Z0-9_]*\z/)
  envs = required.select { |env, n| env && n[:secrets].include?(name) }.keys.sort
  abort "#{name}: no release environment uses it (see `status`)" if envs.empty?
  value =
    if ARGV.first == "--file"
      File.binread(ARGV[1] || abort("--file needs a path"))
    elsif $stdin.tty?
      $stderr.print "#{name} (hidden): "
      $stdin.noecho(&:gets).to_s.chomp.tap { $stderr.puts }
    else
      $stdin.read
    end
  abort "#{name}: empty value, nothing set" if value.strip.empty?
  envs.each do |env|
    gh("secret", "set", name, "-R", REPO, "--env", env, stdin: value)
    puts "set #{name} in #{env}"
  end
else
  abort File.read(__FILE__).lines[3..15].join.gsub(/^# ?/, "")
end
