#!/usr/bin/env bash
# Fails unless a GitHub deployment environment is actually protected. A job
# that names a missing environment gets a NEW, unprotected one, so every
# release job calls this first and stops instead of running unguarded:
#  - deployments must be limited to custom branch policies, exactly the
#    expected comma-separated patterns (`release/*` by default; the store
#    credentials' environment also allows the default branch, where the
#    scheduled monitor runs);
#  - with --require-reviewers, a required-reviewers rule must exist (the
#    explicit human approval in front of production actions).
# Usage: check-environment.sh <environment> [--require-reviewers] [--branches <pattern>]
#   (needs GH_TOKEN, GITHUB_REPOSITORY)
set -euo pipefail
env_name=${1:?usage: check-environment.sh <environment> [--require-reviewers] [--branches <pattern>]}
shift
require_reviewers=false
expected="release/*"
while [ $# -gt 0 ]; do
  case "$1" in
    --require-reviewers) require_reviewers=true ;;
    --branches) expected=${2:?--branches needs a pattern}; shift ;;
    *) echo "::error::unknown option $1"; exit 1 ;;
  esac
  shift
done
fail() { echo "::error::environment '$env_name': $1"; exit 1; }
info=$(gh api "repos/$GITHUB_REPOSITORY/environments/$env_name") || fail "does not exist; create and protect it first (RELEASE.md)"
[ "$(jq -r '.deployment_branch_policy.custom_branch_policies // false' <<< "$info")" = true ] ||
  fail "must use a custom deployment branch policy limited to $expected"
branches=$(gh api "repos/$GITHUB_REPOSITORY/environments/$env_name/deployment-branch-policies" --jq '[.branch_policies[] | "\(.type // "branch"):\(.name)"] | sort | join(",")')
want=$(tr ',' '\n' <<< "$expected" | sed 's/^/branch:/' | sort | paste -sd, -)
[ "$branches" = "$want" ] || fail "deployment branches are '$branches', expected exactly $want"
if $require_reviewers; then
  jq -e '[.protection_rules[]?.type] | index("required_reviewers") != null' <<< "$info" >/dev/null ||
    fail "has no required reviewers; production release actions need an explicit approval"
fi
echo "environment '$env_name' is protected ($expected only$($require_reviewers && echo ', required reviewers'))"
