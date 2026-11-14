#!/usr/bin/env bash
# Per-line coverage of the app's iOS/ and Shared/ sources from an xcresult,
# as JSON lines {"file": repo-relative path, "lines": [[line, count|null], ...]} (null = not executable).
# A line counts as run when it or any part of it (a subrange) ran.
set -euo pipefail
result=${1:?xcresult}; out=${2:?out}; root=$(pwd)
: > "$out"
xcrun xccov view --archive --file-list "$result" | while read -r path; do
  rel=${path#"$root"/}
  case "$rel" in iOS/*.swift|Shared/*.swift) ;; *) continue ;; esac
  xcrun xccov view --archive --file "$path" --json "$result" \
    | jq -c --arg f "$rel" '{file: $f, lines: [to_entries[0].value[]
        | [.line, (if .isExecutable then ([.executionCount] + [(.subranges // [])[].executionCount] | max) else null end)]]}' >> "$out"
done
echo "$(wc -l < "$out") files"
