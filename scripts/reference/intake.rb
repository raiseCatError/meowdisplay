#!/usr/bin/env ruby
# frozen_string_literal: true

# Reference-change intake: which changes in the external OpenDisplay project
# (reference/opendisplay) since the last review could matter to MeowDisplay.
# Read-only: it reads git history and writes a Markdown report; it never
# cherry-picks, merges, opens issues or changes a branch. Each candidate gets
# a filled-in starting point for a person's review (REFERENCE.md):
#   source PR/commit, the problem it solves (its message), whether
#   MeowDisplay already has it, protocol and security notes, relevance to
#   Mac / iOS / Android, a suggested recommendation and the tests to run.
#
# Usage: intake.rb --since SHA [--reference REF] [--ours REF] [--out FILE]
#   --since      last reviewed reference commit (REFERENCE.md's ledger)
#   --reference  default origin/reference/opendisplay
#   --ours       default HEAD
require "open3"
require "optparse"
require "set"

module ReferenceIntake
  CATEGORIES = {
    "security" => /\b(security|vulnerab|cve|exploit|auth(entic|oriz)?|tls|certificate|pin(ning)?|pair(ing)?|sanitiz|inject|leak of|privacy|spoof|trust)/i,
    "reliability" => /\b(crash|hang|freeze|deadlock|race|leak|retry|reconnect|timeout|stuck|recover|stall|fix(es|ed)?)\b/i,
    "rendering" => /\b(decod|render|hevc|h\.?264|h\.?265|frame|metal|videotoolbox|colou?r|hdr|codec|cursor|scal(e|ing)|resolution)/i,
    "platform" => /\b(android|linux|windows|usb|adb|ipad|iphone|macos (1[2-9]|2\d)|ios (1[6-9]|2\d)|sdk|compat)/i,
    "regression" => /\b(regress|revert|broke|restore|again)\b/i,
  }.freeze
  PROTOCOL_PATHS = %r{\A(PROTOCOL\.md|COMPATIBILITY\.md|Shared/(Protocol|Pairing|TLSConfigurator|QUIC|StreamReceiver|TrustStore)|Mac/MacSender|Android/.*(Protocol|Wire|Tls|Pair))}.freeze
  AREAS = {
    "Mac" => %r{\A(Mac|MacReceiver)/}, "iOS" => %r{\AiOS/}, "Shared" => %r{\AShared/},
    "Android" => %r{\AAndroid/}, "Linux" => %r{\Alinux/}, "Release/CI" => %r{\A(\.github|fastlane|scripts)/},
  }.freeze

  module_function

  def git(*args)
    out, err, status = Open3.capture3("git", *args)
    raise "git #{args.join(' ')}: #{err}" unless status.success?

    out
  end

  def commits(since, reference)
    git("log", "--no-merges", "--format=%H%x1f%s%x1f%b%x1e", "#{since}..#{reference}").split("\x1e").map(&:strip).reject(&:empty?).map do |entry|
      sha, subject, body = entry.split("\x1f", 3)
      { sha: sha, subject: subject.to_s, body: body.to_s,
        files: git("show", "--format=", "--name-only", sha).lines.map(&:strip).reject(&:empty?) }
    end
  end

  # Patch-ids of everything on our side since the shared history: an
  # identical change already applied (cherry-pick, port) matches.
  def our_patch_ids(ours, reference)
    base = git("merge-base", ours, reference).strip
    out, = Open3.pipeline_r(["git", "log", "-p", "--no-merges", "#{base}..#{ours}"], ["git", "patch-id", "--stable"]) do |last, _|
      last.read
    end
    out.lines.map { |line| line.split.first }.compact.to_set
  rescue StandardError
    Set.new
  end

  def patch_id(sha)
    out, = Open3.pipeline_r(["git", "show", sha], ["git", "patch-id", "--stable"]) { |last, _| last.read }
    out.split.first
  end

  def pr_number(subject)
    subject[/\(#(\d+)\)\s*\z/, 1]
  end

  # How our history mentions an external PR: plain text, never `owner/repo#N`
  # (REFERENCE.md), e.g. "upstream OpenDisplay PR 392" / "OpenDisplay reference PR 392".
  def referenced_in_ours(number, ours)
    return false unless number

    !git("log", "--format=%H", "-i", "-E", "--grep", "(OpenDisplay( reference)?|upstream) (PR|pull request) #?#{number}\\b", ours).strip.empty?
  end

  def analyze(commit, ours:, our_ids:)
    text = "#{commit[:subject]}\n#{commit[:body]}"
    categories = CATEGORIES.select { |_, pattern| text.match?(pattern) }.keys
    areas = AREAS.select { |_, pattern| commit[:files].any? { |f| f.match?(pattern) } }.keys
    number = pr_number(commit[:subject])
    present = our_ids.include?(patch_id(commit[:sha]))
    referenced = referenced_in_ours(number, ours)
    protocol = commit[:files].any? { |f| f.match?(PROTOCOL_PATHS) }
    { commit: commit, categories: categories, areas: areas, pr: number, present: present,
      referenced: referenced, protocol: protocol, recommendation: recommend(categories, areas, present, referenced, protocol) }
  end

  def recommend(categories, areas, present, referenced, protocol)
    return "ignore — already in MeowDisplay (same patch)" if present
    return "investigate — referenced in our history; confirm it is fully covered" if referenced
    return "ignore — release tooling of the external project" if areas == ["Release/CI"]
    return "investigate first — security relevant" if categories.include?("security")
    return "investigate — touches the wire protocol; MeowDisplay's pv 22 is authoritative" if protocol
    return "investigate for the Android port only" if areas == ["Android"]
    return "ignore — Linux sender, not a MeowDisplay platform" if areas == ["Linux"]
    return "investigate" unless (categories & %w[reliability rendering platform regression]).empty?

    "ignore — no reliability, security, rendering, platform or regression signal"
  end

  def interesting?(item)
    !(item[:categories].empty? && !item[:protocol])
  end

  def report(items, since:, reference:, head:)
    lines = ["# OpenDisplay reference intake", "",
             "Range `#{since[0, 12]}..#{head[0, 12]}` (#{reference}). Generated by scripts/reference/intake.rb.",
             "Nothing here is applied: every row needs a person's decision (REFERENCE.md).", "",
             "| Source | Change | Signals | Areas | In MeowDisplay | Suggested |", "| --- | --- | --- | --- | --- | --- |"]
    items.each do |i|
      source = i[:pr] ? "PR #{i[:pr]} (`#{i[:commit][:sha][0, 9]}`)" : "`#{i[:commit][:sha][0, 9]}`"
      have = i[:present] ? "same patch" : (i[:referenced] ? "referenced" : "no")
      lines << "| #{source} | #{i[:commit][:subject].gsub('|', '\\|')} | #{(i[:categories] + (i[:protocol] ? ['protocol'] : [])).join(', ')} | #{i[:areas].join(', ')} | #{have} | #{i[:recommendation]} |"
    end
    lines << ""
    items.reject { |i| i[:recommendation].start_with?("ignore") }.each do |i|
      lines += ["## #{i[:commit][:subject]}", "",
                "- **Source:** #{i[:pr] ? "external PR #{i[:pr]}, " : ''}commit `#{i[:commit][:sha]}`",
                "- **Problem it solves:** #{i[:commit][:body].strip.lines.first&.strip || i[:commit][:subject]}",
                "- **Already in MeowDisplay?** #{i[:present] ? 'yes, same patch' : (i[:referenced] ? 'referenced in our history — confirm' : 'not found — check by hand')}",
                "- **Protocol:** #{i[:protocol] ? 'touches protocol/pairing/transport code: compare with PROTOCOL.md (pv 22, pinned mTLS, session invitations); never adopt plaintext or weaker pairing' : 'no protocol files'}",
                "- **Security:** #{i[:categories].include?('security') ? 'security signal: review first' : 'no security signal in the message (still review)'}",
                "- **Relevance:** #{i[:areas].empty? ? 'unclear' : i[:areas].join(', ')}",
                "- **Suggested:** #{i[:recommendation]} (ignore / investigate / adapt / port is a person's decision)",
                "- **Tests to run if adopted:** the affected suites (Mac `OpenSidecarMac` tests, iOS build and UI tests, Android `:core:test`), plus a physical check if it changes capture, input or transport",
                "- **Changed files:** #{i[:commit][:files].first(12).join(', ')}#{i[:commit][:files].length > 12 ? ', …' : ''}", ""]
    end
    lines.join("\n") + "\n"
  end
end

if $PROGRAM_NAME == __FILE__
  options = { reference: "origin/reference/opendisplay", ours: "HEAD" }
  OptionParser.new do |o|
    o.on("--since SHA") { |v| options[:since] = v }
    o.on("--reference REF") { |v| options[:reference] = v }
    o.on("--ours REF") { |v| options[:ours] = v }
    o.on("--out FILE") { |v| options[:out] = v }
  end.parse!
  abort "usage: intake.rb --since SHA [--reference REF] [--ours REF] [--out FILE]" unless options[:since]

  head = ReferenceIntake.git("rev-parse", options[:reference]).strip
  ours = ReferenceIntake.our_patch_ids(options[:ours], options[:reference])
  items = ReferenceIntake.commits(options[:since], options[:reference])
                         .map { |c| ReferenceIntake.analyze(c, ours: options[:ours], our_ids: ours) }
                         .select { |i| ReferenceIntake.interesting?(i) }
  since = ReferenceIntake.git("rev-parse", options[:since]).strip
  text = ReferenceIntake.report(items, since: since, reference: options[:reference], head: head)
  options[:out] ? File.write(options[:out], text) : puts(text)
end
