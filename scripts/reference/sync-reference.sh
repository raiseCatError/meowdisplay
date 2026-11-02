#!/usr/bin/env bash
# Moves reference/opendisplay to the external OpenDisplay project's main
# branch, read-only tracking for the reference-intake review. It only ever:
#  - creates reference/opendisplay, or fast-forwards it (never a force push);
#  - fetches exactly one external branch, without tags (external tags never
#    enter MeowDisplay's tag namespace);
#  - writes reference-sync.json describing what it did.
# If the external history was rewritten (the old head isn't an ancestor of
# the new one), reference/opendisplay is left as it is and the job fails
# for a person to decide; nothing is overwritten.
# It never merges, cherry-picks, tags, releases, or touches any other branch.
#
# Usage: sync-reference.sh <expected external sha>   (needs GH_TOKEN, GITHUB_REPOSITORY;
#        REFERENCE_REMOTE / ORIGIN_REMOTE override the URLs for tests)
set -euo pipefail
expected=${1:?usage: sync-reference.sh <expected external sha>}
[[ $expected =~ ^[0-9a-f]{40}$ ]] || { echo "::error::expected sha must be 40 hex digits"; exit 1; }
external=${REFERENCE_REMOTE:-https://github.com/peetzweg/opendisplay.git}
origin=${ORIGIN_REMOTE:-https://github.com/${GITHUB_REPOSITORY:?}.git}
target=refs/heads/reference/opendisplay
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/reference.XXXXXX")
trap 'rm -rf "$work"' EXIT

if [ -n "${ORIGIN_REMOTE:-}" ]; then
  git_() { git -C "$work" "$@"; }
else
  auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GH_TOKEN:?}" | base64 | tr -d '\n')"
  git_() { git -C "$work" -c "http.https://github.com/.extraheader=$auth" "$@"; }
fi
git init -q --bare "$work"
record() {
  jq -n --arg result "$1" --arg external "$external" --arg new "$expected" --arg old "${old:-}" \
        --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg detail "${2:-}" \
        '{externalRepository: $external, externalRef: "refs/heads/main", previous: $old, synchronized: $new,
          result: $result, detail: $detail, at: $at}' > "${SYNC_RECORD:-reference-sync.json}"
}

# The external branch, without tags, into a private namespace.
git_ fetch -q --no-tags "$external" "+refs/heads/main:refs/external/main"
new=$(git_ rev-parse refs/external/main)
if [ "$new" != "$expected" ]; then
  record mismatch "fetched $new, the API reported $expected"
  echo "::error::fetched $new but the external API reported $expected; not syncing"
  exit 1
fi

old=$(git_ ls-remote "$origin" "$target" | cut -f1)
if [ "$old" = "$new" ]; then
  record unchanged
  echo "reference/opendisplay is already at $new"
  exit 0
fi
if [ -n "$old" ]; then
  git_ fetch -q --no-tags "$origin" "+$target:refs/ours/reference"
  if ! git_ merge-base --is-ancestor refs/ours/reference refs/external/main; then
    record diverged "the external main no longer contains $old"
    echo "::error::the external history was rewritten ($old is not an ancestor of $new); reference/opendisplay is unchanged. Review it, then follow REFERENCE.md § Rewritten history."
    exit 1
  fi
fi
# Plain push: GitHub refuses it unless it creates the branch or
# fast-forwards it.
git_ push -q "$origin" "refs/external/main:$target"
if [ -n "$old" ]; then record fast-forwarded; else record created; fi
echo "reference/opendisplay: ${old:-<new>} -> $new"
