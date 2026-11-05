#!/usr/bin/env bash
# Prints the UDID of a new, shut-down iPhone Duo simulator, created from the newest iOS runtime
# and the first device type whose name contains "Duo". Fails, listing what this Xcode has,
# when there is no such device type: a missing Duo must never pass as "tests skipped".
# `duo-simulator.sh boot UDID` then boots it and waits until it has finished booting. The
# ios-duo job boots it before building, so it has settled by the time the UI tests start.
set -euo pipefail
if [ "${1:-}" = boot ]; then
  xcrun simctl boot "${2:?usage: duo-simulator.sh boot UDID}"
  xcrun simctl bootstatus "$2" -b >&2
  exit 0
fi
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
xcrun simctl create "CI iPhone Duo" "$type_id" "$runtime"
