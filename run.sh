#!/bin/zsh
# Start the Mac sender app. The phone app must be running (it listens on
# its pinned TLS port); USB connectivity goes through macOS's built-in usbmuxd — no tunnel
# tool needed. The Mac app retries until the device shows up.
set -e
cd "$(dirname "$0")"

# Resolve the Debug product from Xcode's own build settings (DerivedData location
# and product name vary by machine/config), so nothing is hard-coded.
SETTINGS=$(xcodebuild -project MeowDisplay.xcodeproj -scheme OpenSidecarMac -configuration Debug -showBuildSettings 2>/dev/null)
BUILD_DIR=$(print -r -- "$SETTINGS" | sed -n 's/^ *TARGET_BUILD_DIR = //p' | head -1)
PRODUCT=$(print -r -- "$SETTINGS" | sed -n 's/^ *FULL_PRODUCT_NAME = //p' | head -1)
APP="$BUILD_DIR/$PRODUCT"
if [[ -z $BUILD_DIR || -z $PRODUCT || ! -d $APP ]]; then
  echo "Mac app not built — run: ./generate-local.sh && xcodebuild -project MeowDisplay.xcodeproj -scheme OpenSidecarMac -configuration Debug build"
  exit 1
fi

open "$APP"
echo "MeowDisplay running — logs at ~/Library/Logs/MeowDisplay/."
