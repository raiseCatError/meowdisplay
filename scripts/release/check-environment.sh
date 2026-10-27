#!/usr/bin/env bash
# Fails unless a GitHub deployment environment is actually protected. A job
# that names a missing environment gets a NEW, unprotected one, so release
# jobs call this first and stop instead of running unguarded:
#  - deployments must be limited to the custom branch policy
#    "release/app-store-rc" (and nothing else);
#  - with --require-reviewers, a required-reviewers rule must exist (the
#    explicit human approval in front of production actions).
# Usage: check-environment.sh <environment> [--require-reviewers]   (needs GH_TOKEN, GITHUB_REPOSITORY)
set -euo pipefail
env_name=${1:?usage: check-environment.sh <environment> [--require-reviewers]}
fail() { echo "::error::environment '$env_name': $1"; exit 1; }
info=$(gh api "repos/$GITHUB_REPOSITORY/environments/$env_name") || fail "does not exist; create and protect it first (RELEASE.md)"
[ "$(jq -r '.deployment_branch_policy.custom_branch_policies // false' <<< "$info")" = true ] ||
  fail "must use a custom deployment branch policy limited to release/app-store-rc"
branches=$(gh api "repos/$GITHUB_REPOSITORY/environments/$env_name/deployment-branch-policies" --jq '[.branch_policies[] | "\(.type // "branch"):\(.name)"] | sort | join(",")')
[ "$branches" = "branch:release/app-store-rc" ] || fail "deployment branches are '$branches', expected only branch:release/app-store-rc"
if [ "${2:-}" = --require-reviewers ]; then
  jq -e '[.protection_rules[]?.type] | index("required_reviewers") != null' <<< "$info" >/dev/null ||
    fail "has no required reviewers; production release actions need an explicit approval"
fi
echo "environment '$env_name' is protected (release/app-store-rc only${2:+, required reviewers})"
