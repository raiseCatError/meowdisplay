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
# Every file is checked before anything changes. On this user-owned repository GitHub refuses
# (HTTP 422) its own Actions app, integration 15368, as a bypass actor; GitHub Apps the owner
# creates and installs, deploy keys and repository roles are accepted, so only 15368 is
# rejected here (rulesets_test.rb decides which bypasses each ruleset may have).
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
# Not atomic: GitHub can still refuse a definition that passed the checks above. On a refusal
# this stops, says exactly what this run already changed, and leaves everything else as it
# was; re-running is safe (rulesets are matched by name: existing ones are compared and
# updated, never duplicated).
applied=()
failed() {
  echo "::error::GitHub refused ruleset '$1'; nothing after it was attempted"
  if [ ${#applied[@]} -gt 0 ]; then printf 'changed by this run before the refusal: %s\n' "${applied[@]}"; else echo "this run changed nothing"; fi
  echo "fix the definition and re-run (safe to repeat)"
  exit 1
}
described=()
for file in "$dir"/*.json; do
  name=$(jq -r .name "$file")
  described+=("$name")
  id=$(printf '%s\n' "$existing" | awk -F'\t' -v n="$name" '$2 == n {print $1}')
  if [ -z "$id" ]; then
    echo "create: $name ($(jq -c .conditions.ref_name.include "$file"))"
    $apply && { gh api -X POST "repos/$repo/rulesets" --input "$file" --jq '"created ruleset \(.id)"' || failed "$name"; }
    $apply && applied+=("created: $name")
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
  $apply && { gh api -X PUT "repos/$repo/rulesets/$id" --input "$file" --jq '"updated ruleset \(.id)"' || failed "$name"; }
  $apply && applied+=("updated: $name ($id)")
done
while IFS=$'\t' read -r id name; do
  [ -n "$id" ] || continue
  printf '%s\n' "${described[@]}" | grep -qxF "$name" || echo "not described here (left alone): $name ($id)"
done <<< "$existing"
if $apply; then
  if [ ${#applied[@]} -gt 0 ]; then printf 'changed: %s\n' "${applied[@]}"; else echo "nothing needed changing"; fi
else
  echo "(dry run: nothing changed; re-run with --apply)"
fi
