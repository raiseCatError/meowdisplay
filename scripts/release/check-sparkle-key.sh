#!/usr/bin/env bash
# Sparkle-key continuity, without printing or storing the key. Proves that:
#  1. the published baseline apps (published-baseline.sh output) ship one key;
#  2. project.yml ships that same key, so the new build keeps trusting it;
#  3. the Sparkle private key on stdin belongs to it: sign_update signs random
#     bytes and CryptoKit verifies the signature against the PUBLISHED key.
# `sign_update --verify` can't do (3): it checks against the key it was given,
# so a wrong key still "verifies". Comparing with project.yml alone can't do
# (1): a change to both the secret and project.yml would pass and every
# installed copy would reject the feeds.
# Usage: printf '%s' "$SPARKLE_PRIVATE_KEY" | check-sparkle-key.sh <dir with sign_update> <baseline dir>
set -euo pipefail
sparkle_bin=${1:?usage: check-sparkle-key.sh <dir with sign_update> <baseline dir>}
baseline=${2:?usage: check-sparkle-key.sh <dir with sign_update> <baseline dir>}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
fail() { echo "::error::$1"; exit 1; }

published=$(sort -u "$baseline/sender.key" "$baseline/receiver.key")
[ "$(printf '%s\n' "$published" | grep -c .)" = 1 ] || fail "the published sender and receiver ship different SUPublicEDKeys"
project=$(sed -n 's/^ *SUPublicEDKey: *//p' "$root/project.yml" | sort -u)
[ "$(printf '%s\n' "$project" | grep -c .)" = 1 ] || fail "project.yml must declare exactly one SUPublicEDKey"
[ "$project" = "$published" ] || fail "project.yml's SUPublicEDKey ($project) is not the published key ($published); installed copies would reject this release's feeds"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
head -c 4096 /dev/urandom > "$work/probe"
signature=$("$sparkle_bin/sign_update" --ed-key-file - -p "$work/probe")
swift "$here/verify-ed25519.swift" "$published" "$work/probe" "$signature" ||
  fail "The Sparkle private key does NOT match the published SUPublicEDKey $published; installed apps would reject feeds signed with it"
echo "Sparkle key continuity ok: the secret, project.yml and the published apps all use $published"
