#!/usr/bin/env bash
# Brings the repository rulesets in line with .github/rulesets/*.json, one
# ruleset per file, matched by name:
#  - a missing ruleset is created;
#  - an existing one whose include patterns, bypass actors or rules differ is
#    replaced with the file's definition (shown as a diff first).
# Prints the plan and changes nothing unless given --apply. Rulesets that no
# file describes (for example the old branch names' rulesets) are listed,
# never deleted: retire them by hand after the migration (BRANCHING.md).
# Changing rulesets needs repository admin rights; run it deliberately.
# Usage: apply-rulesets.sh [--apply]
set -euo pipefail
repo=${REPOSITORY:-raiseCatError/meowdisplay}
dir="$(cd "$(dirname "$0")/../../.github/rulesets" && pwd)"
apply=false; [ "${1:-}" = "--apply" ] && apply=true
# Every file is checked before anything changes, so a bad file can't leave the rulesets half
# applied. GitHub accepts as bypass actors on this user-owned repository only repository
# roles, deploy keys and the owner's own GitHub Apps: its own Actions app (integration
# 15368) is refused with HTTP 422, so no file may name it.
for file in "$dir"/*.json; do
  jq -e 'type == "object" and (.name | type == "string") and (.rules | type == "array")' "$file" >/dev/null ||
    { echo "::error::$file is not a ruleset definition"; exit 1; }
  if jq -e '[.bypass_actors[]? | select(.actor_type == "Integration" and .actor_id == 15368)] | length > 0' "$file" >/dev/null; then
    echo "::error::$file names GitHub Actions (integration 15368) as a bypass actor, which GitHub refuses here"; exit 1
  fi
done
existing=$(gh api "repos/$repo/rulesets" --jq '.[] | "\(.id)\t\(.name)"')
normalize='{name, target, enforcement, include: .conditions.ref_name.include, bypass: [.bypass_actors[]? | {actor_id, actor_type, bypass_mode}],
            rules: [.rules[] | {type, parameters}] | sort_by(.type)}'
described=()
for file in "$dir"/*.json; do
  name=$(jq -r .name "$file")
  described+=("$name")
  id=$(printf '%s\n' "$existing" | awk -F'\t' -v n="$name" '$2 == n {print $1}')
  if [ -z "$id" ]; then
    echo "create: $name ($(jq -c .conditions.ref_name.include "$file"))"
    $apply && gh api -X POST "repos/$repo/rulesets" --input "$file" --jq '"created ruleset \(.id)"'
    continue
  fi
  current=$(gh api "repos/$repo/rulesets/$id" | jq -S "$normalize")
  wanted=$(jq -S "$normalize" "$file")
  if [ "$current" = "$wanted" ]; then
    echo "unchanged: $name ($id)"
    continue
  fi
  echo "update: $name ($id)"
  diff <(printf '%s\n' "$current") <(printf '%s\n' "$wanted") || true
  $apply && gh api -X PUT "repos/$repo/rulesets/$id" --input "$file" --jq '"updated ruleset \(.id)"'
done
while IFS=$'\t' read -r id name; do
  [ -n "$id" ] || continue
  printf '%s\n' "${described[@]}" | grep -qxF "$name" || echo "not described here (left alone): $name ($id)"
done <<< "$existing"
$apply || echo "(dry run: nothing changed; re-run with --apply)"
