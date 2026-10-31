#!/usr/bin/env bash
# Prints the UDID of a booted iPhone Duo simulator, creating it from the newest iOS runtime
# and the first device type whose name contains "Duo". Fails, listing what this Xcode has,
# when there is no such device type: a missing Duo must never pass as "tests skipped".
set -euo pipefail
types=$(xcrun simctl list devicetypes -j)
type_id=$(jq -r '[.devicetypes[] | select(.name | test("Duo"; "i"))][0].identifier // empty' <<< "$types")
if [ -z "$type_id" ]; then
  echo "::error::this Xcode has no iPhone Duo simulator device type" >&2
  jq -r '.devicetypes[].name' <<< "$types" | sed 's/^/  /' >&2
  exit 1
fi
runtime=$(xcrun simctl list runtimes -j |
  jq -r '[.runtimes[] | select(.isAvailable and .platform == "iOS")] | sort_by(.version | split(".") | map(tonumber)) | last.identifier // empty')
[ -n "$runtime" ] || { echo "::error::no available iOS simulator runtime" >&2; exit 1; }
echo "device type: $type_id; runtime: $runtime" >&2
udid=$(xcrun simctl create "CI iPhone Duo" "$type_id" "$runtime")
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >&2
echo "$udid"
