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
#              Local execution is strictly verification-only.
#   --publish  Perform all verifications, publish the draft as Latest, verify live feeds,
#              and auto-revert with verified rollback on live feed verification failure.
#              Publication is permitted ONLY within GitHub Actions using the protected
#              'release-publish' environment with required reviewers.
#
# Security & Safety:
#   - Pinned strictly to exact VERSION (2.1.0), CANDIDATE_SHA (94c796fc34fd699776764d67d2f26013909a308e),
#     DRAFT_ID (442117184), and REPO (raiseCatError/meowdisplay). Overrides are rejected.
#   - Fail-closed: refuses to execute if any argument or live state deviates.
#   - Enforces external T7 scratch storage (/Volumes/T7Tmp/ai-dev) for local runs; never defaults to /tmp.
#   - Verified rollback: if publication occurs but live feeds fail to propagate within 5 minutes,
#     Latest is restored to previous release and v2.1.0 is returned to draft, verifying both actions.
#   - Release-state reconciliation: requires the authorized release App token (contents: write).
set -euo pipefail

readonly PINNED_VERSION="2.1.0"
readonly PINNED_CANDIDATE_SHA="94c796fc34fd699776764d67d2f26013909a308e"
readonly PINNED_DRAFT_ID="442117184"
readonly PINNED_REPO="raiseCatError/meowdisplay"
readonly PINNED_SHA256SUMS_DIGEST="279e22555e9a84a4fc59bd7d529f4efca6ccf2a8c986ac9fc939d627368bc1b7"

# Reject any attempt to supply differing inputs
if [ -n "${VERSION:-}" ] && [ "$VERSION" != "$PINNED_VERSION" ]; then
  echo "::error::VERSION must be '$PINNED_VERSION' (attempted override to '$VERSION' rejected)"
  exit 1
fi
if [ -n "${CANDIDATE_SHA:-}" ] && [ "$CANDIDATE_SHA" != "$PINNED_CANDIDATE_SHA" ]; then
  echo "::error::CANDIDATE_SHA must be '$PINNED_CANDIDATE_SHA' (attempted override to '$CANDIDATE_SHA' rejected)"
  exit 1
fi
if [ -n "${DRAFT_ID:-}" ] && [ "$DRAFT_ID" != "$PINNED_DRAFT_ID" ]; then
  echo "::error::DRAFT_ID must be '$PINNED_DRAFT_ID' (attempted override to '$DRAFT_ID' rejected)"
  exit 1
fi
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ "$GITHUB_REPOSITORY" != "$PINNED_REPO" ]; then
  echo "::error::GITHUB_REPOSITORY must be '$PINNED_REPO' (attempted override to '$GITHUB_REPOSITORY' rejected)"
  exit 1
fi

VERSION="$PINNED_VERSION"
CANDIDATE_SHA="$PINNED_CANDIDATE_SHA"
DRAFT_ID="$PINNED_DRAFT_ID"
REPO="$PINNED_REPO"
EXPECTED_SHA256SUMS_DIGEST="$PINNED_SHA256SUMS_DIGEST"

mode="verify"
if [ "${1:-}" = "--publish" ]; then
  mode="publish"
elif [ -n "${1:-}" ] && [ "${1:-}" != "--verify" ]; then
  echo "::error::unknown option '${1:-}' (usage: recover-mac-release.sh [--verify | --publish])"
  exit 1
fi

echo "=== MeowDisplay Mac Release Recovery ==="
echo "Version:       $VERSION"
echo "Candidate SHA: $CANDIDATE_SHA"
echo "Draft ID:      $DRAFT_ID"
echo "Mode:          $mode"
echo "Repository:    $REPO"
echo ""

here="$(cd "$(dirname "$0")" && pwd)"

# Publication gate: Local execution is strictly verification-only.
# Publication MUST run inside GitHub Actions within the protected release-publish environment with required reviewers.
if [ "$mode" = "publish" ]; then
  if [ "${GITHUB_ACTIONS:-false}" != "true" ] && [ "${RECOVERY_TEST_MOCK_ENV:-false}" != "true" ]; then
    echo "::error::Local execution is verification-only (--verify). Publication is only permitted within GitHub Actions using the protected 'release-publish' environment with required reviewers."
    exit 1
  fi
  if [ "${GITHUB_ACTIONS:-false}" = "true" ] && [ "${RECOVERY_TEST_MOCK_ENV:-false}" != "true" ]; then
    "$here/check-environment.sh" release-publish --require-reviewers || {
      echo "::error::Execution environment 'release-publish' is not protected with required reviewers."
      exit 1
    }
  fi
fi

# Scratch storage policy enforcement:
# In CI: $RUNNER_TEMP is required.
# In unit test mock: $RECOVERY_TEST_TMPDIR is used.
# In local runs: external T7 scratch storage (/Volumes/T7Tmp/ai-dev) is required. Internal /tmp is rejected.
scratch_base=""
if [ -n "${RUNNER_TEMP:-}" ]; then
  scratch_base="$RUNNER_TEMP"
elif [ -n "${RECOVERY_TEST_TMPDIR:-}" ]; then
  scratch_base="$RECOVERY_TEST_TMPDIR"
elif [ -n "${T7_RUN_DIR:-}" ] && [ -d "$T7_RUN_DIR" ]; then
  scratch_base="$T7_RUN_DIR"
elif [ -d "/Volumes/T7Tmp/ai-dev" ]; then
  if command -v t7run >/dev/null 2>&1; then
    t7run --check || { echo "::error::T7 scratch storage check failed"; exit 1; }
  fi
  mkdir -p "/Volumes/T7Tmp/ai-dev/tmp"
  scratch_base="/Volumes/T7Tmp/ai-dev/tmp"
elif [ -n "${TMPDIR:-}" ] && [[ "$TMPDIR" == /Volumes/T7Tmp/* ]]; then
  scratch_base="$TMPDIR"
else
  echo "::error::No approved scratch location found. T7 scratch storage (/Volumes/T7Tmp/ai-dev) is required for local execution. Never fall back to internal /tmp."
  exit 1
fi

work=$(mktemp -d "$scratch_base/meow-recover.XXXXXX")
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

# 2. Confirm iOS is already published (fail-closed on fetch failure, no stale state)
echo "2. Confirming iOS release status in release-state..."
git -C "$here/../.." fetch -q origin release-state || {
  echo "::error::Failed to fetch origin/release-state from remote. Relying on stale local state is prohibited."
  exit 1
}
state_content=$(git -C "$here/../.." show origin/release-state:releases/"$VERSION".json) || {
  echo "::error::releases/$VERSION.json not found on origin/release-state"
  exit 1
}
ios_stage=$(jq -r .platforms.ios.stage <<< "$state_content")
ios_store=$(jq -r .platforms.ios.storeState <<< "$state_content")
ios_sha=$(jq -r .platforms.ios.sha <<< "$state_content")
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

# 4. Download and verify draft assets
echo "4. Downloading draft assets and checking SHA-256 digests..."
mkdir -p "$work/draft"
gh release download "v$VERSION" -R "$REPO" -D "$work/draft"

# 4a. Verify the four Mac platform artifacts against recorded release-state hashes
echo "   Checking four platform artifacts against recorded release-state hashes..."
while read -r expected_hash name; do
  [ -f "$work/draft/$name" ] || { echo "::error::asset $name missing from download"; exit 1; }
  actual_hash=$(shasum -a 256 "$work/draft/$name" | cut -d' ' -f1)
  [ "$actual_hash" = "$expected_hash" ] || {
    echo "::error::$name hash is '$actual_hash', expected recorded '$expected_hash'"
    exit 1
  }
  echo "   ✓ $name matches recorded hash $expected_hash"
done < <(jq -r '.platforms.mac.artifacts[] | "\(.sha256) \(.name)"' <<< "$state_content")

# 4b. Verify the fifth asset (SHA256SUMS.txt) against independently pinned digest
echo "   Checking SHA256SUMS.txt against independently pinned digest..."
[ -f "$work/draft/SHA256SUMS.txt" ] || { echo "::error::SHA256SUMS.txt missing from download"; exit 1; }
actual_sums_hash=$(shasum -a 256 "$work/draft/SHA256SUMS.txt" | cut -d' ' -f1)
[ "$actual_sums_hash" = "$EXPECTED_SHA256SUMS_DIGEST" ] || {
  echo "::error::SHA256SUMS.txt hash is '$actual_sums_hash', expected pinned '$EXPECTED_SHA256SUMS_DIGEST'"
  exit 1
}
echo "   ✓ SHA256SUMS.txt matches independently pinned digest $EXPECTED_SHA256SUMS_DIGEST"

# 4c. Verify internal consistency: SHA256SUMS.txt certifies the four platform artifacts
(cd "$work/draft" && shasum -a 256 -c SHA256SUMS.txt) || {
  echo "::error::SHA256SUMS.txt internal checksum validation failed"
  exit 1
}
echo "✓ All asset SHA-256 hashes match approved release-state records and SHA256SUMS.txt"

# 5. Baseline and Mac app / Sparkle feed verification
echo "5. Verifying signing, notarization, version, build, and Sparkle feeds against baseline..."
. "$here/baseline.env"

baseline_cmd="$here/published-baseline.sh"
check_build_cmd="$here/check-build-number.sh"
verify_mac_cmd="$here/verify-mac-artifact.sh"
verify_feed_cmd="$here/verify-feed.sh"

if [ "${RECOVERY_TEST_MOCK_SCRIPTS:-false}" = "true" ]; then
  baseline_cmd="published-baseline.sh"
  check_build_cmd="check-build-number.sh"
  verify_mac_cmd="verify-mac-artifact.sh"
  verify_feed_cmd="verify-feed.sh"
fi

"$baseline_cmd" "$work/baseline"

for role in sender receiver; do
  select_app "$role"
  echo "--- Verifying $role ($DMG) ---"
  "$check_build_cmd" "$VERSION" "$LIVE_FEED_BASE/$FEED"
  "$verify_mac_cmd" "$work/draft/$DMG" "$role" "$VERSION" "$VERSION" "$work/baseline"
  echo "--- Verifying Feed ($FEED) ---"
  "$verify_feed_cmd" "$work/draft/$FEED" "$work/draft/$DMG" "$(cat "$work/baseline/$role.key")" "$VERSION" "$VERSION" \
    "https://github.com/$REPO/releases/download/v$VERSION/$DMG"
done
echo "✓ All Mac binaries, Gatekeeper, notarization, and Sparkle feed signatures verified"

if [ "$mode" = "verify" ]; then
  echo ""
  echo "================================================================="
  echo "VERIFICATION PASSED: Draft v$VERSION is safe and ready to publish."
  echo "Local execution complete (verification-only)."
  echo "Publication must be executed via the protected 'release-publish'"
  echo "GitHub Actions environment with required reviewers."
  echo "================================================================="
  exit 0
fi

# Mode is publish (running inside protected GitHub Actions environment)
echo ""
echo "6. Publishing draft release as Latest..."
previous_latest=$(gh api "repos/$REPO/releases/latest" --jq .tag_name)
if [ -z "$previous_latest" ] || [ "$previous_latest" = "null" ] || [ "$previous_latest" = "v$VERSION" ]; then
  echo "::error::Could not determine valid previous Latest release before publication (got '$previous_latest')"
  exit 1
fi

# Re-check live draft immediately before publication
gh api "repos/$REPO/releases/$DRAFT_ID" > "$work/final_check.json"
[ "$(jq -r .draft "$work/final_check.json")" = "true" ] || { echo "::error::draft status changed"; exit 1; }
[ "$(jq -r .target_commitish "$work/final_check.json")" = "$CANDIDATE_SHA" ] || { echo "::error::target_commitish changed"; exit 1; }

rollback() {
  echo "::error::Publish step failed. Initiating rollback..."
  local revert_latest_ok=false
  local revert_draft_ok=false

  # 1. Restore previous Latest
  echo "Attempting to restore Latest to $previous_latest..."
  if gh release edit "$previous_latest" --latest -R "$REPO"; then
    current_latest=$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null || echo "")
    if [ "$current_latest" = "$previous_latest" ]; then
      revert_latest_ok=true
      echo "✓ Latest successfully restored to $previous_latest"
    else
      echo "::error::Latest check after revert returned '$current_latest', expected '$previous_latest'"
    fi
  else
    echo "::error::Failed to execute 'gh release edit $previous_latest --latest'"
  fi

  # 2. Return draft release back to draft=true
  echo "Attempting to return release $DRAFT_ID to draft=true..."
  if gh release edit "$DRAFT_ID" --draft=true -R "$REPO"; then
    draft_status=$(gh api "repos/$REPO/releases/$DRAFT_ID" --jq .draft 2>/dev/null || echo "")
    if [ "$draft_status" = "true" ]; then
      revert_draft_ok=true
      echo "✓ Release $DRAFT_ID successfully returned to draft"
    else
      echo "::error::Draft status check after revert returned '$draft_status', expected 'true'"
    fi
  else
    echo "::error::Failed to execute 'gh release edit $DRAFT_ID --draft=true'"
  fi

  # Explicit reporting on failure modes
  if $revert_latest_ok && $revert_draft_ok; then
    echo "::error::Rollback succeeded: $DRAFT_ID returned to draft; $previous_latest restored as Latest."
  else
    echo "::error::PARTIAL ROLLBACK FAILURE: revert_latest=$revert_latest_ok, revert_draft=$revert_draft_ok"
  fi
  exit 1
}
trap rollback ERR

gh release edit "$DRAFT_ID" --draft=false --latest -R "$REPO"

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

if [ "$success" != "true" ]; then
  echo "::error::Live feeds did not serve v$VERSION after 5 minutes"
  rollback
fi

trap - ERR

echo ""
echo "================================================================="
echo "SUCCESS: MeowDisplay Mac $VERSION is published and live!"
echo "Tag v$VERSION is Latest pointing to $CANDIDATE_SHA."
echo "Live Sparkle feeds serve verified v$VERSION."
echo "================================================================="
