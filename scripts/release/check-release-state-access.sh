#!/usr/bin/env bash
# Proves that the release-state branch admits the release App and nobody else, without
# touching any release record (Release dry run, release-state job):
#  1. the App's installation token reaches this repository only;
#  2. a push with the job's GITHUB_TOKEN (contents: write) is refused by the ruleset;
#  3. a push with the App's token is accepted: one commit that updates dry-run.json at
#     the branch root (meow-release reads only releases/<version>.json).
# Needs GITHUB_REPOSITORY, GH_TOKEN (the job's GITHUB_TOKEN) and RELEASE_STATE_TOKEN.
set -euo pipefail
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
: "${GH_TOKEN:?GH_TOKEN is required}" "${RELEASE_STATE_TOKEN:?RELEASE_STATE_TOKEN is required}"
fail() { echo "::error::$1"; exit 1; }

repos=$(GH_TOKEN=$RELEASE_STATE_TOKEN gh api installation/repositories --jq '[.repositories[].full_name] | join(",")')
[ "$repos" = "$repo" ] || fail "the release App's token reaches '$repos'; install the App on $repo only"
echo "the release App's token reaches $repo only"

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/state-access.XXXXXX")
trap 'rm -rf "$work"' EXIT
url="https://github.com/$repo.git"
auth() { printf 'http.https://github.com/.extraheader=AUTHORIZATION: basic %s' "$(printf 'x-access-token:%s' "$1" | base64 | tr -d '\n')"; }
git_() { git -C "$work/repo" "$@"; }

git init -q "$work/repo"
if git_ -c "$(auth "$RELEASE_STATE_TOKEN")" fetch -q --depth 1 "$url" refs/heads/release-state 2>/dev/null; then
  git_ checkout -q -B release-state FETCH_HEAD
else
  git_ checkout -q --orphan release-state
fi
jq -n --arg run "${GITHUB_RUN_ID:-local}" --arg ref "${GITHUB_REF:-}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{lastDryRun: {run: $run, ref: $ref, at: $at}}' > "$work/repo/dry-run.json"
git_ add dry-run.json
git_ -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
  commit -q -m "release-state: dry-run access check (${GITHUB_RUN_ID:-local})"

if git_ -c "$(auth "$GH_TOKEN")" push -q "$url" HEAD:refs/heads/release-state 2> "$work/refused"; then
  fail "GITHUB_TOKEN could write release-state: its ruleset must admit the release App only"
fi
echo "GITHUB_TOKEN is refused, as intended: $(grep -m1 -i -E 'rule|protect|refus|denied' "$work/refused" || head -n1 "$work/refused")"

git_ -c "$(auth "$RELEASE_STATE_TOKEN")" push -q "$url" HEAD:refs/heads/release-state ||
  fail "the release App's token was refused: make the App the release-state ruleset's only bypass (RELEASE.md)"
echo "release-state accepts the release App's token (updated dry-run.json)"
