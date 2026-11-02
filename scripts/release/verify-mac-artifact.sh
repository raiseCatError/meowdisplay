#!/usr/bin/env bash
# Verifies one release DMG before anything is published, against the
# published baseline (published-baseline.sh output). Needs no secrets.
#  - DMG: checksum-valid image; Developer ID-signed, notarized and stapled
#    (REQUIRE_SIGNED_DMG=0 accepts an unsigned container, as the manual path
#    ships);
#  - app: bundle id, version and build as planned; valid deep signature;
#    every Mach-O Developer ID (pinned team), hardened runtime, secure
#    timestamp, no get-task-allow; Gatekeeper "Notarized Developer ID";
#    stapled ticket;
#  - continuity: satisfies the published app's designated requirement (what
#    TCC, the Keychain and Sparkle evaluate) and has its exact entitlements;
#    ships the published SUPublicEDKey and the live feed URL; signed feeds
#    and pre-extraction verification stay required.
# Usage: verify-mac-artifact.sh <dmg> <sender|receiver> <version> <build> <baseline dir>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=baseline.env
. "$here/baseline.env"
dmg=${1:?usage: verify-mac-artifact.sh <dmg> <sender|receiver> <version> <build> <baseline dir>}
role=${2:?}; version=${3:?}; build=${4:?}; baseline=${5:?}
select_app "$role"
failures=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1: $2"; else echo "::error::$1: got '$2', expected '$3'"; failures=$((failures + 1)); fi; }
mount_point=
cleanup() { if [ -n "$mount_point" ]; then hdiutil detach "$mount_point" -quiet || true; fi; }
trap cleanup EXIT

echo "## $dmg ($role $version, build $build)"
hdiutil verify "$dmg" >/dev/null 2>&1 && echo "ok   DMG checksum valid" || { echo "::error::DMG checksum invalid"; failures=$((failures + 1)); }
if [ "${REQUIRE_SIGNED_DMG:-1}" != 0 ]; then
  dmg_info=$(codesign -dvvv "$dmg" 2>&1 || true)
  check "DMG team" "$(sed -n 's/^TeamIdentifier=//p' <<< "$dmg_info")" "$TEAM_ID"
  check "DMG Gatekeeper" "$(spctl -a -t open --context context:primary-signature -vv "$dmg" 2>&1 | sed -n 's/^source=//p')" "Notarized Developer ID"
  xcrun stapler validate "$dmg" >/dev/null 2>&1 && echo "ok   DMG ticket stapled" || { echo "::error::DMG has no stapled ticket"; failures=$((failures + 1)); }
fi

mount_point=$(hdiutil attach -readonly -nobrowse -noautoopen "$dmg" | awk -F'\t' '/\/Volumes\//{print $NF}')
app="$mount_point/$APP"
[ -d "$app" ] || { echo "::error::$APP not found in the DMG"; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist" 2>/dev/null || echo "<unset>"; }
check "bundle id" "$(plist CFBundleIdentifier)" "$BUNDLE_ID"
check "version" "$(plist CFBundleShortVersionString)" "$version"
check "build" "$(plist CFBundleVersion)" "$build"
check "SUPublicEDKey (published key)" "$(plist SUPublicEDKey)" "$(cat "$baseline/$role.key")"
check "SUFeedURL" "$(plist SUFeedURL)" "$LIVE_FEED_BASE/$FEED"
check "SURequireSignedFeed" "$(plist SURequireSignedFeed)" "true"
check "SUVerifyUpdateBeforeExtraction" "$(plist SUVerifyUpdateBeforeExtraction)" "true"

codesign --verify --deep --strict "$app" && echo "ok   codesign --verify --deep --strict" || { echo "::error::invalid code signature"; failures=$((failures + 1)); }
if codesign --verify --strict -R="$(cat "$baseline/$role.dr")" "$app" 2>/dev/null; then
  echo "ok   satisfies the published $BASELINE_TAG designated requirement"
else
  echo "::error::does not satisfy the published $BASELINE_TAG designated requirement (TCC, Keychain and Sparkle continuity)"; failures=$((failures + 1))
fi
entitlements=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - -)
if python3 -c 'import json,sys; sys.exit(json.loads(sys.argv[1]) != json.load(open(sys.argv[2])))' "$entitlements" "$baseline/$role.entitlements.json"; then
  echo "ok   entitlements identical to $BASELINE_TAG"
else
  echo "::error::entitlements differ from $BASELINE_TAG: $entitlements"; failures=$((failures + 1))
fi
check "Gatekeeper" "$(spctl -a -t exec -vv "$app" 2>&1 | sed -n 's/^source=//p')" "Notarized Developer ID"
xcrun stapler validate "$app" >/dev/null 2>&1 && echo "ok   app ticket stapled" || { echo "::error::app has no stapled ticket"; failures=$((failures + 1)); }

machos=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  machos=$((machos + 1)); rel=${f#"$app"/}; info=$(codesign -dvvv "$f" 2>&1)
  grep -q "^Authority=Developer ID Application: .*($TEAM_ID)\$" <<< "$info" || { echo "::error::$rel: not Developer ID $TEAM_ID"; failures=$((failures + 1)); }
  grep -q '^CodeDirectory .*flags=0x[0-9a-f]*(.*runtime' <<< "$info" || { echo "::error::$rel: no hardened runtime"; failures=$((failures + 1)); }
  grep -q '^Timestamp=' <<< "$info" || { echo "::error::$rel: no secure timestamp"; failures=$((failures + 1)); }
  if codesign -d --entitlements - --xml "$f" 2>/dev/null | grep -q get-task-allow; then echo "::error::$rel: get-task-allow"; failures=$((failures + 1)); fi
done < <(find "$app" -type f -print0)
echo "ok   checked $machos Mach-O files"
echo "sha256 $(shasum -a 256 "$dmg" | cut -c1-64)  $(basename "$dmg")"
[ "$failures" = 0 ] || { echo "::error::$failures check(s) failed for $dmg"; exit 1; }
echo "verify-mac-artifact: PASS"
