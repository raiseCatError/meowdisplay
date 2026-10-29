#!/usr/bin/env bash
# Builds the Play upload bundle on the maintainer's Mac, the same way
# release-android.yml does in CI, for uploads made before CI holds the
# Play secrets (the first upload of a new app must go through Play Console).
#
#   scripts/release/android-local-bundle.sh VERSION LATEST_PLAY_VERSION_CODE OUT_DIR
#
# LATEST_PLAY_VERSION_CODE is the highest versionCode Play already has for
# this app (0 before the first upload); the build number counts up from it.
# The upload keystore and its password never enter the repository:
#   MEOW_UPLOAD_STORE_FILE  (default /Volumes/T7Projects/Android/signing/meowdisplay-upload.jks)
#   password: login Keychain, service "MeowDisplay Android upload key"
#   EXPECTED_UPLOAD_CERT_SHA256 (default: the registered upload certificate below)
# Writes OUT_DIR/MeowDisplay-<version>-<code>.aab, its R8 mapping and SHA256SUMS.txt.
set -euo pipefail

version=${1:?version, e.g. 2.0.0}
latest=${2:?highest versionCode Play has (0 if none)}
out=${3:?output directory}
root=$(cd "$(dirname "$0")/../.." && pwd)

store=${MEOW_UPLOAD_STORE_FILE:-/Volumes/T7Projects/Android/signing/meowdisplay-upload.jks}
expected=${EXPECTED_UPLOAD_CERT_SHA256:-6a9ac078dc1359fe51da7764af7b309baef70877a0b236f1508f40f716338e94}
[ -f "$store" ] || { echo "error: upload keystore not found: $store" >&2; exit 1; }

code=$("$root/scripts/release/meow-release" next-build android --version "$version" --latest "$latest")
password=$(security find-generic-password -a meowdisplay-upload -s "MeowDisplay Android upload key" -w)

(
  cd "$root/AndroidReceiver"
  MEOW_UPLOAD_STORE_FILE="$store" MEOW_UPLOAD_STORE_PASSWORD="$password" \
  MEOW_UPLOAD_KEY_ALIAS=upload MEOW_UPLOAD_KEY_PASSWORD="$password" \
    ./gradlew --no-daemon --no-configuration-cache -q :app:bundleRelease \
      "-Pmeow.versionName=$version" "-Pmeow.versionCode=$code"
)
unset password

aab="$root/AndroidReceiver/app/build/outputs/bundle/release/app-release.aab"
# Not -strict: the upload certificate is self-signed, which -strict rejects.
verified=$(jarsigner -verify "$aab")
grep -q '^jar verified\.' <<< "$verified" || { echo "error: bundle signature does not verify" >&2; exit 1; }
if grep -qi 'unsigned entries' <<< "$verified"; then echo "error: bundle has unsigned entries" >&2; exit 1; fi
signer=$(keytool -printcert -jarfile "$aab" | awk '/SHA256:/ {print $2; exit}' | tr -d ':' | tr 'A-F' 'a-f')
[ "$signer" = "$expected" ] || { echo "error: bundle signed by $signer, expected $expected" >&2; exit 1; }

mkdir -p "$out"
name="MeowDisplay-$version-$code"
cp "$aab" "$out/$name.aab"
cp "$root/AndroidReceiver/app/build/outputs/mapping/release/mapping.txt" "$out/$name-mapping.txt"
(cd "$out" && shasum -a 256 "$name.aab" "$name-mapping.txt" > "$name-SHA256SUMS.txt")
echo "versionCode $code"
cat "$out/$name-SHA256SUMS.txt"
