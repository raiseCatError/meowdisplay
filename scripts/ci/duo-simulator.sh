#!/usr/bin/env bash
# Prints the UDID of a new, shut-down iPhone Duo simulator, created from the newest iOS runtime
# this Xcode can create one with, and the first device type whose name contains "Duo". Fails,
# listing what this Xcode has, when there is no such device type or runtime: a missing Duo must
# never pass as "tests skipped".
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
# Newest first. A runner image can carry a runtime newer than the selected Xcode can create
# devices with (iOS 27.2 under Xcode 27.1 answered "Incompatible device"), so try older ones.
runtimes=$(xcrun simctl list runtimes -j |
  jq -r '[.runtimes[] | select(.isAvailable and .platform == "iOS")] | sort_by(.version | split(".") | map(tonumber)) | reverse | .[].identifier')
[ -n "$runtimes" ] || { echo "::error::no available iOS simulator runtime" >&2; exit 1; }
for runtime in $runtimes; do
  if udid=$(xcrun simctl create "CI iPhone Duo" "$type_id" "$runtime" 2>/dev/null) && [[ $udid =~ ^[0-9A-F-]{36}$ ]]; then
    echo "device type: $type_id; runtime: $runtime" >&2
    echo "$udid"
    exit 0
  fi
  echo "this Xcode can't create $type_id on $runtime; trying an older runtime" >&2
done
echo "::error::no installed iOS runtime can create $type_id with this Xcode" >&2
xcrun simctl list runtimes >&2
exit 1
