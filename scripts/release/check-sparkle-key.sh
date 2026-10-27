#!/usr/bin/env bash
# Proves that the Sparkle private key on stdin belongs to the SUPublicEDKey
# the Mac apps ship (project.yml), without printing or storing the key:
# sign_update signs random bytes, and CryptoKit verifies that signature
# against the shipped public key. `sign_update --verify` can't do this: it
# checks against the key it was given, so a wrong key still "verifies".
# Usage: printf '%s' "$SPARKLE_PRIVATE_KEY" | check-sparkle-key.sh <dir with sign_update>
set -euo pipefail
sparkle_bin=${1:?usage: check-sparkle-key.sh <dir with sign_update>}
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)

keys=$(sed -n 's/^ *SUPublicEDKey: *//p' "$root/project.yml" | sort -u)
if [ "$(printf '%s\n' "$keys" | grep -c .)" != 1 ]; then
  echo "::error::project.yml must declare exactly one SUPublicEDKey"
  exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
head -c 4096 /dev/urandom > "$work/probe"
signature=$("$sparkle_bin/sign_update" --ed-key-file - -p "$work/probe")

if swift "$here/verify-ed25519.swift" "$keys" "$work/probe" "$signature"; then
  echo "Sparkle key matches SUPublicEDKey $keys"
else
  echo "::error::The Sparkle private key does NOT match SUPublicEDKey $keys; installed apps would reject feeds signed with it"
  exit 1
fi
