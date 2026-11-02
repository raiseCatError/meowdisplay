#!/usr/bin/env bash
# Brings the release deployment environments in line with the table in RELEASE.md, the same
# way apply-rulesets.sh does for rulesets:
#  - a missing environment is created; an existing one is set to the definition below;
#  - deployments are limited to exactly the listed branch patterns (extra patterns are
#    removed, missing ones added);
#  - the environments that guard production actions require the owner's approval, and
#    administrators can't bypass any of them.
# No secrets are read, added or removed. Prints the plan and changes nothing unless given
# --apply; then checks every environment with check-environment.sh. Safe to re-run.
# Changing environments needs repository admin rights; run it deliberately.
# Usage: apply-environments.sh [--apply]   (needs gh authenticated as the owner)
set -euo pipefail
repo=${REPOSITORY:-raiseCatError/meowdisplay}
owner_id=${OWNER_ID:-315733358}   # raiseCatError, verified 2026-10-30
here="$(cd "$(dirname "$0")" && pwd)"
apply=false; [ "${1:-}" = "--apply" ] && apply=true
# name | deployment branches | owner approval required
environments=(
  "release-build|release/*|no"
  "ios-upload|release/*|no"
  "android-upload|release/*|no"
  "release-stores|dev,release/*|yes"
  "release-publish|release/*|yes"
  "release-pr|release/*|no"
  "website-update|release/*|no"
)
for entry in "${environments[@]}"; do
  IFS='|' read -r name branches approval <<< "$entry"
  reviewers=null
  [ "$approval" = yes ] && reviewers="[{\"type\":\"User\",\"id\":$owner_id}]"
  echo "environment $name: branches $branches; owner approval: $approval; admin bypass: off"
  $apply || continue
  jq -n --argjson reviewers "$reviewers" \
    '{wait_timer: 0, prevent_self_review: false, can_admins_bypass: false, reviewers: $reviewers,
      deployment_branch_policy: {protected_branches: false, custom_branch_policies: true}}' |
    gh api -X PUT "repos/$repo/environments/$name" --input - >/dev/null
  have=$(gh api "repos/$repo/environments/$name/deployment-branch-policies" \
    --jq '.branch_policies[] | "\(.id)\t\(.type // "branch")\t\(.name)"')
  IFS=',' read -ra wanted <<< "$branches"
  while IFS=$'\t' read -r id type pattern; do
    [ -n "$id" ] || continue
    keep=false
    for w in "${wanted[@]}"; do [ "$type" = branch ] && [ "$pattern" = "$w" ] && keep=true; done
    $keep || { gh api -X DELETE "repos/$repo/environments/$name/deployment-branch-policies/$id" >/dev/null
               echo "  removed $type pattern $pattern"; }
  done <<< "$have"
  for w in "${wanted[@]}"; do
    printf '%s\n' "$have" | awk -F'\t' -v p="$w" '$2 == "branch" && $3 == p {found=1} END {exit !found}' ||
      { gh api -X POST "repos/$repo/environments/$name/deployment-branch-policies" -f name="$w" -f type=branch >/dev/null
        echo "  added branch pattern $w"; }
  done
done
$apply || { echo "dry run: nothing changed (re-run with --apply)"; exit 0; }
status=0
for entry in "${environments[@]}"; do
  IFS='|' read -r name branches approval <<< "$entry"
  args=(--branches "$branches"); [ "$approval" = yes ] && args+=(--require-reviewers)
  GITHUB_REPOSITORY=$repo "$here/check-environment.sh" "$name" "${args[@]}" || status=1
done
exit $status
