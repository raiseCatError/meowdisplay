#!/usr/bin/env bash
# Read-only: proves the Developer ID identity in match can be used to sign,
# not just that its certificate exists. Imports match (readonly) into a
# throwaway keychain and requires a valid "Developer ID Application" identity
# for DEVELOPMENT_TEAM there. A valid identity needs its private key, so a
# .p12 that macOS cannot import (for example "MAC verification failed") fails
# here instead of at signing time. fastlane only logs a failed key import as
# an error and carries on, so its exit status alone is not enough.
#
# Needs MATCH_GIT_URL, MATCH_PASSWORD, DEVELOPMENT_TEAM, and SSH access to the
# match repo. Prints no secret: the keychain password is random, masked, and
# passed to fastlane through MATCH_KEYCHAIN_PASSWORD (a sensitive option).
set -euo pipefail

: "${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM is not set}"
[[ $DEVELOPMENT_TEAM =~ ^[A-Z0-9]{10}$ ]] || { echo "::error::DEVELOPMENT_TEAM is not a team ID"; exit 1; }

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/developer-id-check.XXXXXX")"
keychain="$work/developer-id-check.keychain"
cleanup() {
  security delete-keychain "$keychain" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

MATCH_KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
[ -z "${GITHUB_ACTIONS:-}" ] || echo "::add-mask::$MATCH_KEYCHAIN_PASSWORD"
export MATCH_KEYCHAIN_PASSWORD
security create-keychain -p "$MATCH_KEYCHAIN_PASSWORD" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "$MATCH_KEYCHAIN_PASSWORD" "$keychain"
# macOS may store it as <name>-db; match needs the real file.
[ -f "$keychain" ] || keychain="$keychain-db"
export MATCH_KEYCHAIN_NAME="$keychain"

bundle exec fastlane run match type:developer_id readonly:true \
  app_identifier:com.raisecaterror.meowdisplay.mac,com.raisecaterror.meowdisplay.mac.receiver \
  team_id:"$DEVELOPMENT_TEAM" platform:macos

identities="$(security find-identity -v -p codesigning "$keychain")"
count="$(grep -cE "\"Developer ID Application: .+ \\($DEVELOPMENT_TEAM\\)\"" <<<"$identities" || true)"
if [ "$count" -lt 1 ]; then
  echo "::error::match has no usable Developer ID Application identity for $DEVELOPMENT_TEAM: its certificate is there but its private key did not import. Re-export the .p12 from a Mac keychain (security export -t identities -f pkcs12) and store that in match."
  exit 1
fi
echo "Developer ID identity with its private key: $count valid for $DEVELOPMENT_TEAM"
