#!/bin/zsh
# Start the Mac sender app. The phone app must be running (it listens on
# :9000); USB connectivity goes through macOS's built-in usbmuxd — no tunnel
# tool needed. The Mac app retries until the device shows up.
set -e
cd "$(dirname "$0")"

APP=build/Build/Products/Debug/MeowDisplay.app
if [[ ! -d $APP ]]; then
  echo "Mac app not built — run: ./generate-local.sh && xcodebuild -project MeowDisplay.xcodeproj -scheme OpenSidecarMac -configuration Debug -derivedDataPath build build"
  exit 1
fi

open "$APP"
echo "MeowDisplay running — logs at ~/Library/Logs/MeowDisplay/."
