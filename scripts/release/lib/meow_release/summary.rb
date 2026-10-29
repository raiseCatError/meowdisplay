# frozen_string_literal: true

require_relative "state"

module MeowRelease
  # The release-readiness report: the GitHub Actions job summary of every
  # release workflow, rendered from the persistent release state. One row per
  # platform, in words that keep a passing build, an uploaded candidate, an
  # approved candidate and a public release apart.
  module Summary
    NAMES = { "mac" => "Mac (MeowDisplay + Receiver)", "ios" => "iPhone and iPad", "android" => "Android" }.freeze

    module_function

    def render(state, branch_head:)
      sha = state.candidate_sha
      lines = []
      lines << "## MeowDisplay #{state.version} release"
      lines << ""
      lines << (sha ? "Candidate `#{sha[0, 12]}` on `#{state.data['branch']}` · mode **#{state.mode}**" : "No candidate yet on `#{state.data['branch']}`")
      lines << "Required for publication: #{state.required_platforms.map { |p| NAMES.fetch(p) }.join(', ')}"
      lines << ""
      lines << "| Platform | Stage | Build | Source | Artifacts | Store status | Blockers |"
      lines << "| --- | --- | --- | --- | --- | --- | --- |"
      PLATFORMS.each do |name|
        record = state.platform(name)
        required = state.required_platforms.include?(name) ? "" : " (not required)"
        lines << [
          "#{NAMES.fetch(name)}#{required}",
          Stage.label(record["stage"]),
          build_of(name, record),
          source(record["sha"], sha),
          artifacts(record["artifacts"]),
          record["storeState"] || "—",
          Array(record["blockers"]).join("; ").then { |b| b.empty? ? "—" : b },
        ].join(" | ").then { |row| "| #{row} |" }
      end
      lines << "| Website | #{state.website['stage']} | — | — | — | #{state.website['url'] || '—'} | #{Array(state.website['blockers']).join('; ').then { |b| b.empty? ? '—' : b }} |"
      lines << ""
      blockers = state.publication_blockers(branch_head: branch_head)
      if state.publication_stage == "published"
        lines << "**Published.** #{state.publication['githubRelease'] || ''}"
      elsif blockers.empty?
        lines << if state.mode == "manual-final-approval"
                   "**Ready to publish.** Waiting for your approval of the `release-publish` environment."
                 else
                   "**Ready to publish.** Publication starts automatically (auto-publish-after-approval)."
                 end
      else
        lines << "**Publication gate: blocked**"
        blockers.each { |b| lines << "- #{b}" }
      end
      waiting = waiting_on_people(state)
      unless waiting.empty?
        lines << ""
        lines << "**Waiting on a person**"
        waiting.each { |w| lines << "- #{w}" }
      end
      lines << ""
      lines << "_Publication: #{state.publication_stage}. Only **Published** means users can install it._"
      lines.join("\n") + "\n"
    end

    def build_of(name, record)
      case name
      when "mac" then record["build"] || "—"
      when "ios" then record["build"] ? "build #{record['build']}" : "—"
      when "android" then record["versionCode"] ? "versionCode #{record['versionCode']}" : "—"
      end
    end

    def source(record_sha, candidate)
      return "—" unless record_sha
      return "`#{record_sha[0, 12]}` ✓" if record_sha == candidate

      "`#{record_sha[0, 12]}` ✗ not the candidate"
    end

    def artifacts(list)
      return "—" if list.nil? || list.empty?

      list.map { |a| "#{a['name']} `#{a['sha256'].to_s[0, 12]}`" }.join("<br>")
    end

    # Things only a person can do, in the order they come up.
    def waiting_on_people(state)
      list = []
      PLATFORMS.each do |name|
        record = state.platform(name)
        Array(record["blockers"]).each { |b| list << "#{NAMES.fetch(name)}: #{b}" } if record["stage"] == "blocked"
        list << "#{NAMES.fetch(name)}: #{record['blockers']&.first || 'rejected'} — fix it, then push a new candidate" if record["stage"] == "rejected"
      end
      list
    end
  end
end
