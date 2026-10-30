#!/usr/bin/env bash
# Downloads the PUBLISHED baseline Mac apps (baseline.env), proves they are the
# pinned, validly signed release, and records what installed copies trust:
#   <out>/<app>.key                SUPublicEDKey the published app ships
#   <out>/<app>.dr                 its designated requirement
#   <out>/<app>.entitlements.json  its entitlements
# for app = sender and receiver. Fails unless each DMG matches its pinned
# sha256, the app is Developer ID-signed by the pinned team with the pinned
# bundle id, and it ships the pinned key. macOS only (hdiutil, codesign).
# Usage: published-baseline.sh <out dir>
#   BASELINE_DMG_DIR=<dir> uses local copies instead of downloading (tests).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=baseline.env
. "$here/baseline.env"
out=${1:?usage: published-baseline.sh <out dir>}
mkdir -p "$out"
mount_point=
cleanup() { if [ -n "$mount_point" ]; then hdiutil detach "$mount_point" -quiet || true; fi; }
trap cleanup EXIT
fail() { echo "::error::$1"; exit 1; }

for role in sender receiver; do
  select_app "$role"
  file="$out/$DMG"
  if [ -n "${BASELINE_DMG_DIR:-}" ]; then cp "$BASELINE_DMG_DIR/$DMG" "$file"; else curl -fsSL -o "$file" "$BASELINE_URL/$DMG"; fi
  [ "$(shasum -a 256 "$file" | cut -c1-64)" = "$DMG_SHA256" ] || fail "$DMG does not match the pinned $BASELINE_TAG sha256"
  mount_point=$(hdiutil attach -readonly -nobrowse -noautoopen "$file" | awk -F'\t' '/\/Volumes\//{print $NF}')
  app="$mount_point/$APP"
  codesign --verify --deep --strict "$app" || fail "$BASELINE_TAG $APP: invalid code signature"
  info=$(codesign -dvvv "$app" 2>&1)
  grep -qx "Identifier=$BUNDLE_ID" <<< "$info" || fail "$BASELINE_TAG $APP: bundle id is not $BUNDLE_ID"
  grep -qx "TeamIdentifier=$TEAM_ID" <<< "$info" || fail "$BASELINE_TAG $APP: team is not $TEAM_ID"
  grep -q "^Authority=Developer ID Application: .*($TEAM_ID)\$" <<< "$info" || fail "$BASELINE_TAG $APP: not Developer ID"
  key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")
  [ "$key" = "$BASELINE_SUPUBLICEDKEY" ] || fail "$BASELINE_TAG $APP ships SUPublicEDKey $key, not the pinned $BASELINE_SUPUBLICEDKEY"
  printf '%s\n' "$key" > "$out/$role.key"
  codesign -d -r- "$app" 2>&1 | sed -n 's/^designated => //p' > "$out/$role.dr"
  [ -s "$out/$role.dr" ] || fail "$BASELINE_TAG $APP: no designated requirement"
  codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o "$out/$role.entitlements.json" -
  hdiutil detach "$mount_point" -quiet; mount_point=
  echo "$BASELINE_TAG $APP: sha256 ok, Developer ID $TEAM_ID, SUPublicEDKey $key"
done
