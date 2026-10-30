#!/usr/bin/env ruby
# frozen_string_literal: true

# Fails if MeowDisplay's release, store and repository workflows stop being
# fail-closed. Runs in the Tests workflow (`release-tooling`); stdlib only.
# Each rule names the incident it prevents (RELEASE.md, BRANCHING.md):
#
#  Every workflow
#   - top-level `permissions: {}` or read-only; every job declares its own;
#   - every action pinned to a commit SHA (release-relevant workflows);
#   - no `${{ inputs.* }}` / `${{ github.event.* }}` expanded inside a script;
#   - no workflow changes the default branch, rulesets, environments or
#     secrets (unauthorized repository changes);
#   - no workflow fetches or pushes tags except the release's own (tag
#     namespace collisions), and none merges or cherry-picks the external
#     reference.
#  Secrets and environments
#   - secrets only in jobs bound to an environment, and that environment's
#     check-environment.sh runs before the first secret is used (a missing
#     environment silently becomes an unprotected one);
#   - a GitHub App token is minted only in such a job, after the check.
#  Release pipeline
#   - release-candidate.yml: push to release/** only, first step rejects any
#     other ref, records the candidate before building, never publishes;
#   - platform workflows (release-mac/ios/android.yml): workflow_call only,
#     never publish, never submit or release in a store; Mac checks the
#     Sparkle key and build-number ordering before signing, and keeps the
#     staged DMGs and feeds 30 days;
#   - release-publish.yml: dispatch only, guarded to release/<version> at the
#     candidate commit; tags, releases and assets are touched only by its
#     publish-mac job (release-publish environment, reviewer check unless both
#     auto switches are set), after the gate (`publish start`), as draft ->
#     byte check -> Latest -> live check with revert;
#   - a resume (`resume: true`) needs release-publish's approval
#     (authorize-resume) and live re-verification (verify-resume) before any
#     store version is released; verify-stores confirms approvals live;
#   - release-pr.yml: release-please only there, App token from the release-pr
#     environment, skip-github-release, targets the release branch it runs on;
#   - release-monitor.yml and the other scheduled workflows run on a schedule
#     only behind their enabling repository variable.
#  External reference
#   - reference-sync.yml: no secrets, `--no-tags`, only reference/opendisplay
#     is pushed (sync-reference.sh), never forced;
#   - reference-intake.yml: read-only.
# Usage: ruby check-release-workflows.rb [workflows dir]   (default: .github/workflows)
require "yaml"

DIR = ARGV[0] || File.expand_path("../../.github/workflows", __dir__)
SYNC_SCRIPT = ARGV[1] || File.expand_path("../reference/sync-reference.sh", __dir__)
@errors = []

def err(file, msg)
  @errors << "#{file}: #{msg}"
end

def load(name)
  path = File.join(DIR, name)
  return err(name, "missing") && nil unless File.exist?(path)

  YAML.safe_load(File.read(path), aliases: false)
end

def triggers(doc)
  on = doc["on"] || doc[true]
  on.is_a?(Hash) ? on : Array(on).map { |t| [t, nil] }.to_h
end

def steps(job)
  job["steps"] || []
end

def run_text(step)
  step["run"].to_s
end

def env_name(job)
  job["environment"].is_a?(Hash) ? job["environment"]["name"] : job["environment"]
end

def uses_secrets?(obj)
  obj.to_s.match?(/secrets\.(?!GITHUB_TOKEN\b)/)
end

def needs(job)
  Array(job["needs"])
end

def transitive_needs(jobs, id, seen = [])
  needs(jobs[id]).each do |n|
    next if seen.include?(n)

    seen << n
    transitive_needs(jobs, n, seen) if jobs[n]
  end
  seen
end

# Creating or moving tags and releases; a read-only `git ls-remote --tags`
# (does the tag exist?) is not publishing.
PUBLISHING = %r{\bgh release (create|edit|upload|delete)\b|\bgit tag\b|\bgit (push|fetch)\b[^\n]*(refs/tags|--tags\b)}.freeze
STORE_ACTIONS = /\bpublish (stores|start)\b|submit_for_review|upload_to_app_store|appStoreVersionReleaseRequests/.freeze
REPO_ADMIN = %r{gh api[^\n]*-X\s*(PUT|PATCH|POST|DELETE)[^\n]*(rulesets|environments|secrets|default_branch)|gh (secret|variable) set|gh repo edit|default[_-]branch\s*=}i.freeze
REFERENCE_MERGE = %r{(git (merge|cherry-pick|rebase)[^\n]*reference)|(gh pr (create|merge)[^\n]*reference/opendisplay)}.freeze

RELEASE_WORKFLOWS = %w[release-candidate.yml release-mac.yml release-ios.yml release-android.yml release-publish.yml
                       release-pr.yml release-dry-run.yml release-monitor.yml].freeze
SCHEDULE_SWITCHES = { "release-monitor.yml" => "RELEASE_AUTOMATION", "reference-sync.yml" => "REFERENCE_SYNC",
                      "repository-guard.yml" => "REPOSITORY_GUARD" }.freeze

def read_only?(perms)
  perms.is_a?(Hash) && perms.values.all? { |v| %w[read none].include?(v) }
end

def common(name, doc, pin: true)
  perms = doc["permissions"]
  err(name, "top-level permissions must be {} or read-only") unless read_only?(perms)
  doc.fetch("jobs", {}).each do |id, job|
    # With `permissions: {}` at the top, every job states what it needs.
    err(name, "job #{id} must declare permissions") if perms == {} && !job.key?("permissions") && !job.key?("uses")
    steps(job).each do |s|
      if pin && (u = s["uses"]) && u !~ /@[0-9a-f]{40}\z/
        err(name, "job #{id}: #{u} is not pinned to a commit SHA")
      end
      text = run_text(s)
      err(name, "job #{id} step '#{s['name']}': pass inputs through env, not ${{ }} inside run") if text.match?(/\$\{\{\s*(inputs|github\.event)\./)
      err(name, "job #{id}: changes repository settings (#{text[REPO_ADMIN]})") if text.match?(REPO_ADMIN)
      err(name, "job #{id}: merges or proposes the external reference into MeowDisplay") if text.match?(REFERENCE_MERGE)
    end
  end
end

# Secrets only behind a checked environment; App tokens likewise.
def secrets_behind_environments(name, doc, allowed)
  doc.fetch("jobs", {}).each do |id, job|
    secret_idx = steps(job).index { |s| uses_secrets?(s) }
    token_idx = steps(job).index { |s| s["uses"].to_s.start_with?("actions/create-github-app-token@") }
    first = [secret_idx, token_idx].compact.min
    next unless first

    env = env_name(job)
    unless allowed.include?(env)
      err(name, "job #{id} uses secrets outside an allowed environment (#{env.inspect})")
      next
    end
    check = steps(job).index { |s| run_text(s).include?("check-environment.sh #{env}") }
    err(name, "job #{id} must run check-environment.sh #{env} before using secrets") unless check && check < first
  end
end

def no_publishing(name, doc)
  doc.fetch("jobs", {}).each do |id, job|
    steps(job).each do |s|
      text = run_text(s)
      err(name, "job #{id} publishes (#{text[PUBLISHING]}); only release-publish.yml may") if text.match?(PUBLISHING)
      err(name, "job #{id} touches a store's review or release; only the monitor and publish workflows may") if text.match?(STORE_ACTIONS)
    end
  end
end

def only_trigger(name, doc, *allowed)
  keys = triggers(doc).keys
  err(name, "must run only on #{allowed.join(' / ')}, has #{keys.inspect}") unless !keys.empty? && (keys - allowed).empty?
end

def release_ref_guard?(step, version_from_input:)
  text = run_text(step)
  return false unless text.include?("exit 1")

  if version_from_input
    text.include?('"refs/heads/release/$VERSION"')
  else
    text.include?("refs/heads/release/") && text.include?('[0-9]+\.[0-9]+\.[0-9]+')
  end
end

# MARK: - Release candidate

if (doc = load("release-candidate.yml"))
  name = "release-candidate.yml"
  common(name, doc)
  on = triggers(doc)
  err(name, "must run only on push to release/**") unless on.keys == ["push"] && on["push"] == { "branches" => ["release/**"] }
  plan = doc["jobs"]["plan"]
  if plan.nil?
    err(name, "missing the plan job")
  else
    err(name, "plan's first step must reject any ref but release/X.Y.Z") unless release_ref_guard?(steps(plan).first || {}, version_from_input: false)
    text = steps(plan).map { |s| run_text(s) }.join("\n")
    err(name, "plan must record the candidate SHA before anything builds") unless text.include?('candidate STATE --sha "$GITHUB_SHA"')
    err(name, "plan must refuse a version whose tag exists") unless text.include?("refs/tags/v$version")
  end
  %w[mac ios android].each do |p|
    job = doc["jobs"][p]
    err(name, "job #{p} must call release-#{p}.yml after plan") unless job && job["uses"] == "./.github/workflows/release-#{p}.yml" && needs(job).include?("plan")
  end
  err(name, "a newer push must cancel the older candidate's run") unless doc.dig("concurrency", "cancel-in-progress") == true
  no_publishing(name, doc)
end

{ "release-mac.yml" => %w[release-build], "release-ios.yml" => %w[ios-upload], "release-android.yml" => %w[android-upload] }.each do |name, envs|
  next unless (doc = load(name))

  common(name, doc)
  only_trigger(name, doc, "workflow_call")
  secrets_behind_environments(name, doc, envs)
  no_publishing(name, doc)
end

if (mac = load("release-mac.yml"))
  name = "release-mac.yml"
  jobs = mac["jobs"]
  err(name, "sign must come after key-continuity") unless transitive_needs(jobs, "sign").include?("key-continuity")
  kc = steps(jobs["key-continuity"] || {}).map { |s| run_text(s) }.join("\n")
  %w[SENDER_FEED RECEIVER_FEED].each do |feed|
    unless kc.include?(%(check-build-number.sh "$VERSION" "$LIVE_FEED_BASE/$#{feed}"))
      err(name, "key-continuity must check the build number against the live feeds (#{feed})")
    end
  end
  err(name, "key-continuity must check the Sparkle key against the published apps") unless kc.include?("check-sparkle-key.sh")
  %w[verify-artifacts verify-feeds].each do |v|
    err(name, "#{v} must see no secrets and no environment") if jobs[v] && (uses_secrets?(jobs[v]) || jobs[v]["environment"])
  end
  jobs.each do |id, job|
    steps(job).each do |s|
      next unless s["uses"].to_s.start_with?("actions/upload-artifact@")

      artifact = s.dig("with", "name").to_s
      if (artifact.start_with?("dmg-") || artifact == "feeds") && s.dig("with", "retention-days").to_i < 30
        err(name, "job #{id}: staged #{artifact} must be kept 30 days (store review takes days)")
      end
    end
  end
  err(name, "record must depend on verify-feeds") unless needs(jobs["record"] || {}).include?("verify-feeds")
end

# MARK: - Publication

if (doc = load("release-publish.yml"))
  name = "release-publish.yml"
  common(name, doc)
  only_trigger(name, doc, "workflow_dispatch")
  secrets_behind_environments(name, doc, %w[release-stores website-update release-pr])
  jobs = doc["jobs"]
  guard = jobs["guard"]
  if guard.nil?
    err(name, "missing the guard job")
  else
    err(name, "guard must reject any ref but release/<version>") unless release_ref_guard?(steps(guard).first || {}, version_from_input: true)
    err(name, "guard must require the branch to be at the candidate commit") unless run_text(steps(guard).first || {}).include?('"$GITHUB_SHA" = "$SHA"')
  end
  jobs.each do |id, job|
    next if id == "guard"

    err(name, "job #{id} must depend on guard") unless transitive_needs(jobs, id).include?("guard")
    next unless steps(job).any? { |s| run_text(s).match?(PUBLISHING) }

    err(name, "only publish-mac may touch tags, releases or assets (#{id} does)") unless id == "publish-mac"
  end
  pm = jobs["publish-mac"]
  if pm.nil?
    err(name, "missing the publish-mac job")
  else
    s = steps(pm)
    err(name, "publish-mac must use the release-publish environment") unless env_name(pm) == "release-publish"
    err(name, "publish-mac must not use secrets") if uses_secrets?(pm)
    check = s.index { |x| run_text(x).include?("check-environment.sh release-publish --require-reviewers") }
    gate = s.index { |x| run_text(x).include?("publish start STATE") }
    first_publish = s.index { |x| run_text(x).match?(PUBLISHING) }
    draft = s.index { |x| run_text(x).match?(/gh release create\b.*--draft/m) }
    verify = s.index { |x| run_text(x).include?("gh release download") && run_text(x).include?("shasum -a 256 -c") }
    live = s.index { |x| run_text(x).include?("--draft=false") }
    revert = s.index { |x| run_text(x).include?("--latest") && run_text(x).include?("--draft=true") }
    auto = s.find { |x| run_text(x).include?("check-environment.sh release-publish") }
    unless auto && run_text(auto).include?("auto-publish-after-approval") && run_text(auto).include?("AUTO_SWITCH")
      err(name, "publish-mac may skip the reviewer check only when both auto-publish switches are set")
    end
    err(name, "publish-mac must check release-publish's reviewers before the gate") unless check && gate && check < gate
    err(name, "publish-mac must open the gate (publish start) before publishing") unless gate && first_publish && gate < first_publish
    err(name, "publish-mac must create the release as a draft first") unless draft && draft == first_publish
    err(name, "publish-mac must verify the draft's assets before Latest") unless draft && verify && live && draft < verify && verify < live
    err(name, "publish-mac must revert Latest when the live feeds don't verify") unless live && revert && live < revert
  end
  # The release state is written by GitHub Actions and is not evidence by
  # itself: approvals are re-observed in the stores before the Mac step, and
  # the Mac artifacts' run and contents are verified again.
  vs = jobs["verify-stores"]
  if vs.nil? || !needs(pm || {}).include?("verify-stores")
    err(name, "publish-mac must wait for verify-stores (live store approvals)")
  else
    vtext = steps(vs).map { |x| run_text(x) }.join("\n")
    unless vtext.include?("monitor STATE") && vtext.include?("--stores live") && vtext.include?("gate STATE")
      err(name, "verify-stores must observe the stores live and then pass the gate")
    end
  end
  if pm
    ptext = steps(pm).map { |x| run_text(x) }
    prov = ptext.index { |t| t.include?("actions/runs/$run_id") && t.include?(".github/workflows/release-candidate.yml $SHA release/$VERSION push") }
    reverify = ptext.index { |t| t.include?("verify-mac-artifact.sh") && t.include?("verify-feed.sh") }
    draft_idx = steps(pm).index { |x| run_text(x).match?(/gh release create\b.*--draft/m) }
    err(name, "publish-mac must check the candidate run's provenance before using its artifacts") unless prov
    err(name, "publish-mac must verify the DMGs and feeds again before the draft") unless reverify && draft_idx && reverify < draft_idx
  end
  stores = jobs["stores"]
  unless stores && needs(stores).include?("publish-mac") && stores["if"].to_s.include?("needs.publish-mac.result == 'success'")
    err(name, "stores must wait for publish-mac (or a resume)")
  end
end

# MARK: - Release PR, dry run, monitor

if (doc = load("release-pr.yml"))
  name = "release-pr.yml"
  common(name, doc)
  only_trigger(name, doc, "workflow_dispatch")
  secrets_behind_environments(name, doc, %w[release-pr])
  no_publishing(name, doc)
  rp = doc["jobs"].values.flat_map { |j| steps(j) }.select { |s| s["uses"].to_s.start_with?("googleapis/release-please-action@") }
  err(name, "must run release-please exactly once") unless rp.size == 1
  rp.each do |s|
    w = s["with"] || {}
    err(name, "release-please must set skip-github-release: true") unless w["skip-github-release"] == true
    err(name, "release-please must target the release branch it runs on") unless w["target-branch"] == "${{ github.ref_name }}"
    err(name, "release-please must use the App token, not GITHUB_TOKEN") unless w["token"].to_s.include?("steps.app-token.outputs.token")
  end
  job = doc["jobs"].values.first || {}
  err(name, "its first step must reject any ref but release/X.Y.Z") unless release_ref_guard?(steps(job).first || {}, version_from_input: false)
end

if (doc = load("release-dry-run.yml"))
  name = "release-dry-run.yml"
  common(name, doc)
  only_trigger(name, doc, "workflow_dispatch")
  secrets_behind_environments(name, doc, %w[release-build release-pr ios-upload android-upload release-stores website-update])
  no_publishing(name, doc)
end

# Only release workflows may write the release state.
Dir[File.join(DIR, "*.yml")].sort.each do |path|
  name = File.basename(path)
  next if RELEASE_WORKFLOWS.include?(name)

  err(name, "only release workflows may touch the release state") if File.read(path).match?(/release-state\.sh|refs\/heads\/release-state/)
end

if (doc = load("release-monitor.yml"))
  common("release-monitor.yml", doc)
  secrets_behind_environments("release-monitor.yml", doc, %w[release-stores])
  doc["jobs"].each do |id, job|
    steps(job).each do |s|
      err("release-monitor.yml", "job #{id} publishes; the monitor only dispatches release-publish.yml") if run_text(s).match?(PUBLISHING)
    end
  end
end

# MARK: - Scheduled workflows stay off until enabled

Dir[File.join(DIR, "*.yml")].sort.each do |path|
  name = File.basename(path)
  doc = YAML.safe_load(File.read(path), aliases: false)
  next unless triggers(doc).key?("schedule")

  switch = SCHEDULE_SWITCHES[name]
  unless switch
    err(name, "scheduled, but has no enabling repository variable")
    next
  end
  doc["jobs"].each do |id, job|
    condition = job["if"].to_s
    unless condition.include?("vars.#{switch} == 'enabled'") && condition.include?("workflow_dispatch")
      err(name, "job #{id} must run on schedule only while vars.#{switch} is enabled")
    end
  end
end

# MARK: - External reference

if (doc = load("reference-sync.yml"))
  name = "reference-sync.yml"
  common(name, doc)
  err(name, "must not use secrets") if uses_secrets?(doc)
  no_publishing(name, doc)
  err(name, "must not run on push or pull requests") if (triggers(doc).keys & %w[push pull_request pull_request_target]).any?
  text = doc["jobs"].values.flat_map { |j| steps(j) }.map { |s| run_text(s) }.join("\n")
  err(name, "must verify the external repository's pinned identity") unless text.include?("R_kgDOS2SYLQ peetzweg/opendisplay main")
  err(name, "must sync through scripts/reference/sync-reference.sh") unless text.include?("scripts/reference/sync-reference.sh")
end
if File.exist?(SYNC_SCRIPT)
  script = File.read(SYNC_SCRIPT)
  pushes = script.lines.grep(/\bpush\b/).map(&:strip).reject { |l| l.start_with?("#") }
  unless pushes.size == 1 && pushes.first.include?(':$target"') && !pushes.first.match?(/--force|\+refs|\s-f\b/)
    err("sync-reference.sh", "must push only reference/opendisplay, without force")
  end
  err("sync-reference.sh", "target must be refs/heads/reference/opendisplay") unless script.include?("target=refs/heads/reference/opendisplay")
  fetches = script.lines.grep(/\bfetch\b/).reject { |l| l.strip.start_with?("#") }
  err("sync-reference.sh", "every fetch must use --no-tags") unless fetches.all? { |l| l.include?("--no-tags") }
  err("sync-reference.sh", "must never merge, cherry-pick or rebase") if script.match?(/git_? (merge(?! *-base)|cherry-pick|rebase)/)
else
  err("sync-reference.sh", "missing")
end

if (doc = load("reference-intake.yml"))
  common("reference-intake.yml", doc)
  writes = doc["jobs"].values.any? { |j| j["permissions"].is_a?(Hash) && j["permissions"].values.include?("write") }
  err("reference-intake.yml", "must be read-only") if writes || uses_secrets?(doc)
end

# MARK: - Every other workflow

Dir[File.join(DIR, "*.yml")].sort.each do |path|
  name = File.basename(path)
  next if RELEASE_WORKFLOWS.include?(name) || %w[reference-sync.yml reference-intake.yml].include?(name)

  doc = YAML.safe_load(File.read(path), aliases: false)
  common(name, doc, pin: false)
  no_publishing(name, doc)
  err(name, "release-please runs only in release-pr.yml") if File.read(path).include?("googleapis/release-please-action")
end

# Resumed publication (the monitor dispatches resume: true): no path may
# release a store version without the final release-publish approval, and a
# resume re-derives every fact live instead of trusting the release state.
if (doc = load("release-publish.yml"))
  name = "release-publish.yml"
  jobs = doc["jobs"]
  ar = jobs["authorize-resume"]
  vr = jobs["verify-resume"]
  vs = jobs["verify-stores"]
  if ar.nil? || env_name(ar) != "release-publish" ||
     steps(ar).none? { |x| run_text(x).include?("check-environment.sh release-publish --require-reviewers") }
    err(name, "authorize-resume must hold the release-publish approval (required reviewers) for every resume")
  end
  if vr.nil? || !transitive_needs(jobs, "verify-resume").include?("authorize-resume")
    err(name, "verify-resume must run only after authorize-resume")
  else
    text = steps(vr).map { |x| run_text(x) }.join("\n")
    err(name, "verify-resume must confirm store approvals live (verify-live)") unless text.include?("verify-live STATE")
    err(name, "verify-resume must confirm the Mac release is Latest") unless text.include?("releases/latest")
    err(name, "verify-resume must check the live artifacts against the recorded hashes") unless text.include?("sha256sum -c")
    err(name, "verify-resume must find a successful publish-mac job for this commit") unless text.include?('select(.name == "publish-mac" and .conclusion == "success")')
  end
  if vs.nil? || steps(vs).none? { |x| run_text(x).include?("verify-live STATE") }
    err(name, "verify-stores must confirm store approvals live (verify-live), not only the recorded state")
  end
  jobs.each do |id, job|
    next unless steps(job).any? { |x| run_text(x).include?("publish stores STATE") }

    deps = transitive_needs(jobs, id)
    unless %w[publish-mac authorize-resume verify-resume].all? { |d| deps.include?(d) }
      err(name, "job #{id} releases store versions without depending on publish-mac, authorize-resume and verify-resume")
    end
    unless job["if"].to_s.include?("inputs.resume && needs.verify-resume.result == 'success'") &&
           job["if"].to_s.include?("!inputs.resume && needs.publish-mac.result == 'success'")
      err(name, "job #{id} must run only after publish-mac, or on resume only after verify-resume succeeded")
    end
  end
end

if @errors.empty?
  puts "release, store and repository workflows are fail-closed (#{DIR})"
else
  @errors.each { |e| puts "::error::#{e}" }
  exit 1
end
