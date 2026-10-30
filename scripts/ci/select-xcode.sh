#!/usr/bin/env bash
# Selects the Xcode named in .xcode-version (e.g. "27.1") on a GitHub macOS runner, so CI and
# the release builds use the toolchain the apps are developed and tested with, not whatever the
# runner image defaults to (an older compiler rejected valid Swift 6 concurrency code). Fails,
# listing what the runner has, when that Xcode isn't installed.
set -euo pipefail
want=$(tr -d '[:space:]' < "$(dirname "$0")/../../.xcode-version")
[[ $want =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { echo "::error::.xcode-version must be a version like 27.1"; exit 1; }
echo "Installed Xcodes:"; ls -d /Applications/Xcode*.app 2>/dev/null | sed 's/^/  /'
app=""
for candidate in "/Applications/Xcode_$want.app" /Applications/Xcode_"$want".*.app; do
  [ -d "$candidate" ] && { app=$candidate; break; }
done
if [ -z "$app" ]; then
  echo "::error::Xcode $want is not installed on this runner (see the list above); update .xcode-version or the runner image"
  exit 1
fi
sudo xcode-select -s "$app/Contents/Developer"
xcodebuild -version
