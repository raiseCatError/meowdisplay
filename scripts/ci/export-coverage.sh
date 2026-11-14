#!/usr/bin/env bash
# Per-line coverage of the app's iOS/ and Shared/ sources from an xcresult,
# as JSON lines {"file": repo-relative path, "lines": [[line, count|null], ...]} (null = not executable).
set -euo pipefail
result=${1:?xcresult}; out=${2:?out}; root=$(pwd)
: > "$out"
xcrun xccov view --archive --file-list "$result" | while read -r path; do
  rel=${path#"$root"/}
  case "$rel" in iOS/*.swift|Shared/*.swift) ;; *) continue ;; esac
  xcrun xccov view --archive --file "$path" --json "$result" \
    | jq -c --arg f "$rel" '{file: $f, lines: [.[] | [.line, (if .isExecutable then .executionCount else null end)]]}' >> "$out"
done
echo "$(wc -l < "$out") files"
