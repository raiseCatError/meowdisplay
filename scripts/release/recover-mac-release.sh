#!/usr/bin/env bash
# recover-mac-release.sh: Safely verify and recover a Mac release from an immutable draft.
#
# Usage:
#   recover-mac-release.sh [--verify | --publish]
#
# Modes:
#   --verify   (default) Download draft assets, verify SHA-256 hashes against approved
#              release-state records, and verify Developer ID code signing, Gatekeeper
#              notarization, stapled tickets, designated requirements, and Sparkle feed
#              Ed25519 signatures against the published baseline public key.
#   --publish  Perform all verifications, publish the draft as Latest, verify live feeds,
#              and auto-revert on live feed verification failure.
#
# Security & Safety:
#   - Pinned to exact VERSION, CANDIDATE_SHA, and DRAFT_ID.
#   - Fail-closed: refuses to execute if any argument or live state deviates.
#   - Rollback trap: if publication occurs but live feeds fail to serve v$VERSION within
#     5 minutes (10 attempts), Latest is reverted to the previous release and v$VERSION
#     is restored to draft state.
#   - Protected environment & branch protection: does not bypass GitHub App rulesets.
#     Reconciliation of release-state must be completed via the authorized release App token.
set -euo pipefail

VERSION="${VERSION:-2.1.0}"
CANDIDATE_SHA="${CANDIDATE_SHA:-94c796fc34fd699776764d67d2f26013909a308e}"
DRAFT_ID="${DRAFT_ID:-442117184}"
REPO="${GITHUB_REPOSITORY:-raiseCatError/meowdisplay}"
EXPECTED_SHA256SUMS_DIGEST="279e22555e9a84a4fc59bd7d529f4efca6ccf2a8c986ac9fc939d627368bc1b7"

mode="verify"
if [ "${1:-}" = "--publish" ]; then
  mode="publish"
fi

echo "=== MeowDisplay Mac Release Recovery ==="
echo "Version:       $VERSION"
echo "Candidate SHA: $CANDIDATE_SHA"
echo "Draft ID:      $DRAFT_ID"
echo "Mode:          $mode"
echo "Repository:    $REPO"
echo ""

# Strict guard on inputs
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::bad version '$VERSION'"; exit 1; }
[[ "$CANDIDATE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::bad candidate SHA '$CANDIDATE_SHA'"; exit 1; }
[[ "$DRAFT_ID" =~ ^[0-9]+$ ]] || { echo "::error::bad draft ID '$DRAFT_ID'"; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d "${TMPDIR:-/tmp}/meow-recover.XXXXXX")
trap 'rm -rf "$work"' EXIT

# 1. Inspect live draft release
echo "1. Checking draft release identity..."
gh api "repos/$REPO/releases/$DRAFT_ID" > "$work/draft.json"
tag_name=$(jq -r .tag_name "$work/draft.json")
is_draft=$(jq -r .draft "$work/draft.json")
target_commitish=$(jq -r .target_commitish "$work/draft.json")

[ "$tag_name" = "v$VERSION" ] || { echo "::error::draft tag is '$tag_name', expected 'v$VERSION'"; exit 1; }
[ "$is_draft" = "true" ] || { echo "::error::release $DRAFT_ID is not a draft (draft=$is_draft)"; exit 1; }
[ "$target_commitish" = "$CANDIDATE_SHA" ] || { echo "::error::target_commitish is '$target_commitish', expected '$CANDIDATE_SHA'"; exit 1; }
echo "✓ Draft $DRAFT_ID targets approved candidate $CANDIDATE_SHA"

# 2. Confirm iOS is already published
echo "2. Confirming iOS release status in release-state..."
git -C "$here/../.." fetch -q origin release-state 2>/dev/null || true
ios_stage=$(git -C "$here/../.." show origin/release-state:releases/"$VERSION".json | jq -r .platforms.ios.stage)
ios_store=$(git -C "$here/../.." show origin/release-state:releases/"$VERSION".json | jq -r .platforms.ios.storeState)
ios_sha=$(git -C "$here/../.." show origin/release-state:releases/"$VERSION".json | jq -r .platforms.ios.sha)
[ "$ios_stage" = "published" ] || { echo "::error::iOS is not published (stage=$ios_stage)"; exit 1; }
[ "$ios_store" = "READY_FOR_DISTRIBUTION" ] || { echo "::error::iOS storeState is '$ios_store', expected READY_FOR_DISTRIBUTION"; exit 1; }
[ "$ios_sha" = "$CANDIDATE_SHA" ] || { echo "::error::iOS sha '$ios_sha' does not match candidate '$CANDIDATE_SHA'"; exit 1; }
echo "✓ iOS $VERSION is published ($ios_store) against candidate $CANDIDATE_SHA"

# 3. Check exact 5 assets
echo "3. Checking draft assets list with deterministic ASCII collation..."
actual_names=$(jq -r '[.assets[].name] | sort | join(" ")' "$work/draft.json")
expected_names=$(printf '%s\n' MeowDisplay.dmg MeowDisplayReceiver.dmg SHA256SUMS.txt appcast.xml appcast-receiver.xml | LC_ALL=C sort | paste -sd' ' -)
[ "$actual_names" = "$expected_names" ] || { echo "::error::draft assets are '$actual_names', expected '$expected_names'"; exit 1; }
echo "✓ Draft contains exactly the 5 expected assets in byte-order"

# 4. Download and verify hashes
echo "4. Downloading draft assets and checking SHA-256 hashes..."
mkdir -p "$work/draft"
gh release download "v$VERSION" -R "$REPO" -D "$work/draft"

# 4a. Verify SHA256SUMS.txt itself
actual_sums_hash=$(shasum -a 256 "$work/draft/SHA256SUMS.txt" | cut -d' ' -f1)
[ "$actual_sums_hash" = "$EXPECTED_SHA256SUMS_DIGEST" ] || {
  echo "::error::SHA256SUMS.txt hash $actual_sums_hash != expected $EXPECTED_SHA256SUMS_DIGEST"
  exit 1
}
echo "✓ SHA256SUMS.txt digest verified independently ($actual_sums_hash)"

# 4b. Verify draft assets against release-state records
git -C "$here/../.." show origin/release-state:releases/"$VERSION".json > "$work/state.json"
jq -r '.platforms.mac.artifacts[] | "\(.sha256)  \(.name)"' "$work/state.json" > "$work/expected.sha256"
echo "$EXPECTED_SHA256SUMS_DIGEST  SHA256SUMS.txt" >> "$work/expected.sha256"

(cd "$work/draft" && shasum -a 256 -c "$work/expected.sha256")
(cd "$work/draft" && shasum -a 256 -c SHA256SUMS.txt)
echo "✓ All asset SHA-256 hashes match approved release-state records and SHA256SUMS.txt"

# 5. Baseline and Mac app / Sparkle feed verification
echo "5. Verifying signing, notarization, version, build, and Sparkle feeds against baseline..."
. "$here/baseline.env"
"$here/published-baseline.sh" "$work/baseline"

for role in sender receiver; do
  select_app "$role"
  echo "--- Verifying $role ($DMG) ---"
  "$here/check-build-number.sh" "$VERSION" "$LIVE_FEED_BASE/$FEED"
  "$here/verify-mac-artifact.sh" "$work/draft/$DMG" "$role" "$VERSION" "$VERSION" "$work/baseline"
  echo "--- Verifying Feed ($FEED) ---"
  "$here/verify-feed.sh" "$work/draft/$FEED" "$work/draft/$DMG" "$(cat "$work/baseline/$role.key")" "$VERSION" "$VERSION" \
    "https://github.com/$REPO/releases/download/v$VERSION/$DMG"
done
echo "✓ All Mac binaries, Gatekeeper, notarization, and Sparkle feed signatures verified"

if [ "$mode" = "verify" ]; then
  echo ""
  echo "================================================================="
  echo "VERIFICATION PASSED: Draft v$VERSION is safe and ready to publish."
  echo "To publish, re-run with: $0 --publish"
  echo "================================================================="
  exit 0
fi

# Mode is publish
echo ""
echo "6. Publishing draft release as Latest..."
previous=$(gh api "repos/$REPO/releases/latest" --jq .tag_name)
[ "$previous" != "v$VERSION" ] || { echo "::error::v$VERSION is already Latest; cannot publish again"; exit 1; }

# Re-check live draft immediately before publication
gh api "repos/$REPO/releases/$DRAFT_ID" > "$work/final_check.json"
[ "$(jq -r .draft "$work/final_check.json")" = "true" ] || { echo "::error::draft status changed"; exit 1; }
[ "$(jq -r .target_commitish "$work/final_check.json")" = "$CANDIDATE_SHA" ] || { echo "::error::target_commitish changed"; exit 1; }

rollback() {
  echo "::error::Publication failed live verification! Restoring Latest to $previous and returning v$VERSION to draft..."
  gh release edit "$previous" -R "$REPO" --latest || true
  gh release edit "v$VERSION" -R "$REPO" --draft=true || true
}
trap rollback ERR

gh release edit "v$VERSION" -R "$REPO" --draft=false --latest

echo "7. Verifying published tag and Latest status..."
tagged_sha=$(gh api "repos/$REPO/commits/v$VERSION" --jq .sha)
[ "$tagged_sha" = "$CANDIDATE_SHA" ] || { echo "::error::tag v$VERSION points to $tagged_sha, not $CANDIDATE_SHA"; exit 1; }

latest_tag=$(gh api "repos/$REPO/releases/latest" --jq .tag_name)
[ "$latest_tag" = "v$VERSION" ] || { echo "::error::Latest is $latest_tag, expected v$VERSION"; exit 1; }

echo "8. Verifying live feeds serve v$VERSION..."
live_ok() {
  for feed in "$SENDER_FEED" "$RECEIVER_FEED"; do
    want=$(shasum -a 256 "$work/draft/$feed" | cut -c1-64)
    for url in "https://github.com/$REPO/releases/latest/download/$feed" "$LIVE_FEED_BASE/$feed"; do
      got=$(curl -fsSL --max-time 30 "$url" | shasum -a 256 | cut -c1-64) || return 1
      [ "$got" = "$want" ] || return 1
    done
  done
}

success=false
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  echo "Checking live feeds (attempt $attempt/10)..."
  if live_ok; then success=true; echo "Live feeds serve v$VERSION!"; break; fi
  sleep 30
done

[ "$success" = "true" ] || { echo "::error::Live feeds did not serve v$VERSION after 5 minutes"; exit 1; }

trap - ERR

# 9. Release-state reconciliation
echo "9. Reconciling release-state..."
if [ -n "${RELEASE_STATE_TOKEN:-}" ]; then
  "$here/release-state.sh" "$VERSION" publish start STATE --config "$here/../../.github/release-config.json" --branch-head "$CANDIDATE_SHA" || true
  "$here/release-state.sh" "$VERSION" publish mac-published STATE --config "$here/../../.github/release-config.json" \
    --url "https://github.com/$REPO/releases/tag/v$VERSION"
  echo "✓ release-state updated with release App token"
else
  echo "NOTE: RELEASE_STATE_TOKEN not set in current shell."
  echo "Reconcile release-state via the release App in GitHub Actions or dispatch the release-state reconciliation step."
fi

echo ""
echo "================================================================="
echo "SUCCESS: MeowDisplay Mac $VERSION is published and live!"
echo "Tag v$VERSION is Latest pointing to $CANDIDATE_SHA."
echo "Live Sparkle feeds serve verified v$VERSION."
echo "================================================================="
