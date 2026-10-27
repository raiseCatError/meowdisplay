#!/usr/bin/env ruby
# Fails if the release workflows stop being fail-closed. Runs in the Tests
# workflow; stdlib only. Rules (RELEASE.md § "Release workflow"):
#  - release workflows run only by workflow_dispatch, with no default token
#    permissions, every action pinned to a commit SHA, and no ${{ inputs.* }}
#    or ${{ github.event.* }} expanded inside a shell script;
#  - release.yml: every job depends on `plan`, whose first step rejects any
#    ref but release/app-store-rc; one release at a time;
#  - secrets only in jobs bound to the release-build environment, after its
#    protection check; the verify jobs see no secrets;
#  - tags, releases and assets are touched only by `publish` (environment
#    release-publish, checked for required reviewers first), which needs both
#    verify jobs and goes draft -> byte-for-byte check -> Latest;
#  - release-please only in release-pr.yml: App token, fixed target branch,
#    skip-github-release.
# Usage: ruby check-release-workflows.rb [workflows dir]   (default: .github/workflows)
require "yaml"

DIR = ARGV[0] || File.expand_path("../../.github/workflows", __dir__)
RELEASE_BRANCH = "refs/heads/release/app-store-rc"
PUBLISHING = /\bgh release (create|edit|upload|delete)\b|\bgit (push|tag)\b/
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
  doc["on"] || doc[true]
end
def steps(job)
  job["steps"] || []
end
def run_text(step)
  step["run"].to_s
end
def uses_secrets?(obj)
  obj.to_s.match?(/secrets\.(?!GITHUB_TOKEN\b)/)
end

def common(name, doc)
  on = triggers(doc)
  keys = on.is_a?(Hash) ? on.keys : Array(on)
  err(name, "must run only on workflow_dispatch, has #{keys.inspect}") unless keys == ["workflow_dispatch"]
  err(name, "top-level permissions must be {}") unless doc["permissions"] == {}
  doc["jobs"].each do |id, job|
    err(name, "job #{id} must declare permissions") unless job.key?("permissions")
    steps(job).each do |s|
      if (u = s["uses"]) && u !~ /@[0-9a-f]{40}\z/
        err(name, "job #{id}: #{u} is not pinned to a commit SHA")
      end
      if run_text(s).match?(/\$\{\{\s*(inputs|github\.event)\./)
        err(name, "job #{id} step '#{s['name']}': pass inputs through env, not \${{ }} inside run")
      end
    end
  end
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

def env_check_index(job, env)
  steps(job).index { |s| run_text(s).include?("check-environment.sh #{env}") }
end

release = load("release.yml")
if release
  common("release.yml", release)
  jobs = release["jobs"]
  c = release["concurrency"]
  err("release.yml", "needs a concurrency group with cancel-in-progress: false") unless c.is_a?(Hash) && c["cancel-in-progress"] == false
  plan = jobs["plan"]
  if plan.nil?
    err("release.yml", "missing the plan job")
  else
    first = steps(plan).first || {}
    unless first["if"].to_s.include?("github.ref != '#{RELEASE_BRANCH}'") && run_text(first).include?("exit 1")
      err("release.yml", "plan's first step must fail unless github.ref is #{RELEASE_BRANCH}")
    end
    err("release.yml", "plan must not see secrets") if uses_secrets?(plan)
  end
  jobs.each do |id, job|
    next if id == "plan"
    err("release.yml", "job #{id} must depend on plan") unless transitive_needs(jobs, id).include?("plan")
    env = job["environment"].is_a?(Hash) ? job["environment"]["name"] : job["environment"]
    secret_step = steps(job).index { |s| uses_secrets?(s) }
    if uses_secrets?(job)
      err("release.yml", "job #{id} uses secrets outside the release-build environment") unless env == "release-build"
      check = env_check_index(job, "release-build")
      err("release.yml", "job #{id} must run check-environment.sh release-build before using secrets") unless check && secret_step && check < secret_step
    end
    publishes = steps(job).any? { |s| run_text(s).match?(PUBLISHING) }
    write = job["permissions"].is_a?(Hash) && job["permissions"]["contents"] == "write"
    next unless publishes || write || id == "publish"
    unless id == "publish"
      err("release.yml", "only the publish job may touch tags, releases or assets (#{id} does)")
      next
    end
    err("release.yml", "publish must use the release-publish environment") unless env == "release-publish"
    err("release.yml", "publish must not use secrets") if uses_secrets?(job)
    %w[verify-artifacts verify-feeds].each do |v|
      err("release.yml", "publish must depend on #{v}") unless transitive_needs(jobs, id).include?(v)
      err("release.yml", "#{v} must see no secrets and no environment") if jobs[v] && (uses_secrets?(jobs[v]) || jobs[v]["environment"])
    end
    s = steps(job)
    guard = s.index { |x| run_text(x).include?("check-environment.sh release-publish --require-reviewers") }
    first_publish = s.index { |x| run_text(x).match?(PUBLISHING) }
    draft = s.index { |x| run_text(x).match?(/gh release create\b.*--draft/m) }
    verify = s.index { |x| run_text(x).include?("gh release download") && run_text(x).include?("shasum -a 256 -c") }
    live = s.index { |x| run_text(x).include?("--draft=false") }
    err("release.yml", "publish must check release-publish's required reviewers before publishing") unless guard && first_publish && guard < first_publish
    err("release.yml", "publish must create the release as a draft first") unless draft && draft == first_publish
    err("release.yml", "publish must verify the draft's assets before making it Latest") unless draft && verify && live && draft < verify && verify < live
  end
end

pr = load("release-pr.yml")
if pr
  common("release-pr.yml", pr)
  rp = pr["jobs"].values.flat_map { |j| steps(j) }.select { |s| s["uses"].to_s.start_with?("googleapis/release-please-action@") }
  err("release-pr.yml", "must run release-please exactly once") unless rp.size == 1
  rp.each do |s|
    w = s["with"] || {}
    err("release-pr.yml", "release-please must set skip-github-release: true") unless w["skip-github-release"] == true
    err("release-pr.yml", "release-please target-branch must be release/app-store-rc") unless w["target-branch"] == "release/app-store-rc"
    err("release-pr.yml", "release-please must use the App token, not GITHUB_TOKEN") unless w["token"].to_s.include?("steps.app-token.outputs.token")
  end
end

dry = load("release-dry-run.yml")
common("release-dry-run.yml", dry) if dry

Dir[File.join(DIR, "*.yml")].each do |path|
  name = File.basename(path)
  next if name == "release-pr.yml"
  if File.read(path).include?("googleapis/release-please-action")
    err(name, "release-please runs only in release-pr.yml")
  end
end

if @errors.empty?
  puts "release workflows are fail-closed (#{DIR})"
else
  @errors.each { |e| puts "::error::#{e}" }
  exit 1
end
