#!/usr/bin/env bash
# Runs one meow-release command against the persistent release state, kept
# as releases/<version>.json on the `release-state` branch (an orphan branch
# holding nothing else), and pushes the result if it changed. A push that
# loses a race re-reads the branch and runs the command again, so two jobs
# never overwrite each other's record. Pushes made with GITHUB_TOKEN start
# no workflows. The literal word STATE in the command is replaced by the
# file's path.
#
# Usage: release-state.sh <version> <meow-release command and args...>
#   e.g. release-state.sh 2.0.0 record STATE --platform mac --stage built --sha "$GITHUB_SHA"
# Read-only commands (gate, summary) never push.
# Needs GH_TOKEN (contents: write) and GITHUB_REPOSITORY.
set -euo pipefail
version=${1:?usage: release-state.sh <version> <command> ...}
shift
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::bad version '$version'"; exit 1; }
cli="$(cd "$(dirname "$0")" && pwd)/meow-release"
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/release-state.XXXXXX")
trap 'rm -rf "$work"' EXIT
# RELEASE_STATE_REMOTE (a local path) is for tests only.
if [ -n "${RELEASE_STATE_REMOTE:-}" ]; then
  remote=$RELEASE_STATE_REMOTE
  git_() { git -C "$work/repo" "$@"; }
else
  auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GH_TOKEN:?GH_TOKEN is required}" | base64 | tr -d '\n')"
  remote="https://github.com/${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}.git"
  git_() { git -C "$work/repo" -c "http.https://github.com/.extraheader=$auth" "$@"; }
fi

for attempt in 1 2 3 4 5; do
  rm -rf "$work/repo"
  git init -q "$work/repo"
  git_ remote add origin "$remote"
  if git_ fetch -q --depth 1 origin refs/heads/release-state 2>/dev/null; then
    git_ checkout -q -B release-state FETCH_HEAD
  else
    git_ checkout -q --orphan release-state
  fi
  mkdir -p "$work/repo/releases"
  file="$work/repo/releases/$version.json"
  args=()
  for arg in "$@"; do [ "$arg" = STATE ] && args+=("$file") || args+=("$arg"); done
  "$cli" "${args[@]}"
  git_ add -A
  if git_ diff --cached --quiet; then
    exit 0
  fi
  git_ -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit -q -m "release-state: $version ${1:-update} (${GITHUB_RUN_ID:-local})"
  if git_ push -q origin HEAD:refs/heads/release-state 2>/dev/null; then
    exit 0
  fi
  echo "release-state: the branch moved; retrying ($attempt)"
  sleep $(( attempt * 3 ))
done
echo "::error::couldn't update release-state after 5 attempts"
exit 1
