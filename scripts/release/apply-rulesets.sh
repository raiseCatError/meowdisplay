#!/usr/bin/env bash
# Brings the repository rulesets in line with .github/rulesets/:
#  - creates "Protect release branch" for release/app-store-rc if missing;
#  - sets the required status checks (Tests `mac`, PR title `conventional`,
#    from GitHub Actions) on every existing ruleset whose
#    required_status_checks rule is empty, leaving their other rules alone.
# Prints the planned changes and does nothing else unless given --apply.
# Changing rulesets needs repository admin rights; run it deliberately.
# Usage: apply-rulesets.sh [--apply]
set -euo pipefail
repo=raiseCatError/meowdisplay
here=$(cd "$(dirname "$0")" && pwd)
desired="$here/../../.github/rulesets/release-app-store-rc.json"
apply=false; [ "${1:-}" = "--apply" ] && apply=true
checks=$(jq -c '.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks' "$desired")

existing=$(gh api "repos/$repo/rulesets" --jq '.[] | "\(.id)\t\(.name)"')
if printf '%s\n' "$existing" | cut -f2 | grep -qx "$(jq -r .name "$desired")"; then
  echo "exists: $(jq -r .name "$desired")"
else
  echo "create: $(jq -r .name "$desired") for release/app-store-rc"
  $apply && gh api -X POST "repos/$repo/rulesets" --input "$desired" --jq '"created ruleset \(.id)"'
fi

while IFS=$'\t' read -r id name; do
  [ -n "$id" ] || continue
  current=$(gh api "repos/$repo/rulesets/$id")
  empty=$(jq '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks | length] | any(. == 0)' <<< "$current")
  if [ "$empty" != true ]; then echo "unchanged: $name ($id)"; continue; fi
  echo "update: $name ($id): required checks [] -> $checks"
  if $apply; then
    jq --argjson checks "$checks" '{name, target, enforcement, conditions, bypass_actors,
        rules: [.rules[] | if .type == "required_status_checks"
                 then .parameters.required_status_checks = $checks else . end]}' <<< "$current" |
      gh api -X PUT "repos/$repo/rulesets/$id" --input - --jq '"updated ruleset \(.id)"'
  fi
done <<< "$existing"
$apply || echo "(dry run: nothing changed; re-run with --apply)"
