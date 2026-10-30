#!/usr/bin/env bash
# Read-only drift check of the repository settings the release system relies
# on. Fails (listing every problem) when:
#  - the default branch isn't the expected one (EXPECTED_DEFAULT_BRANCH);
#  - a ruleset from .github/rulesets/ is missing or differs;
#  - a release environment is missing, unprotected or limited to the wrong
#    branches (check-environment.sh);
#  - Actions' default token isn't read-only.
# It changes nothing. Run by repository-guard.yml, or locally by an admin.
# Usage: check-repository.sh   (needs GH_TOKEN or gh auth, GITHUB_REPOSITORY, EXPECTED_DEFAULT_BRANCH)
set -uo pipefail
repo=${GITHUB_REPOSITORY:?}
here="$(cd "$(dirname "$0")" && pwd)"
problems=()
note() { problems+=("$1"); echo "::error::$1"; }

default=$(gh api "repos/$repo" --jq .default_branch)
if [ -z "${EXPECTED_DEFAULT_BRANCH:-}" ]; then
  note "EXPECTED_DEFAULT_BRANCH is not set (repository variable); the default branch is $default"
elif [ "$default" != "$EXPECTED_DEFAULT_BRANCH" ]; then
  note "default branch is '$default', expected '$EXPECTED_DEFAULT_BRANCH'"
fi

normalize='{name, target, enforcement, include: .conditions.ref_name.include, bypass: [.bypass_actors[]? | {actor_id, actor_type, bypass_mode}],
            rules: [.rules[] | {type, parameters}] | sort_by(.type)}'
existing=$(gh api "repos/$repo/rulesets" --jq '.[] | "\(.id)\t\(.name)"') || note "can't read rulesets"
for file in "$here"/../../.github/rulesets/*.json; do
  name=$(jq -r .name "$file")
  id=$(printf '%s\n' "$existing" | awk -F'\t' -v n="$name" '$2 == n {print $1}')
  if [ -z "$id" ]; then note "ruleset missing: $name"; continue; fi
  [ "$(gh api "repos/$repo/rulesets/$id" | jq -S "$normalize")" = "$(jq -S "$normalize" "$file")" ] || note "ruleset differs from $(basename "$file"): $name"
done

check_env() { "$here/check-environment.sh" "$@" >/dev/null 2>&1 || note "environment $1 is missing or not protected as expected ($*)"; }
check_env release-build
check_env release-publish --require-reviewers
check_env release-pr
check_env ios-upload
check_env android-upload
check_env website-update
check_env release-stores --branches "$default,release/*"

perm=$(gh api "repos/$repo/actions/permissions/workflow" --jq .default_workflow_permissions 2>/dev/null || echo unknown)
[ "$perm" = read ] || note "Actions default token permission is '$perm', expected read"

if [ ${#problems[@]} -eq 0 ]; then
  echo "repository settings match the release system's expectations"
else
  echo "${#problems[@]} problem(s)"
  exit 1
fi
