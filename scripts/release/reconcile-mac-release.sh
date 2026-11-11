#!/usr/bin/env bash
# reconcile-mac-release.sh: Reconcile release-state through the authorized release App
# after Mac 2.1.0 publication is live.
#
# Usage:
#   reconcile-mac-release.sh [--manifest-only | --execute]
#
# Requirements:
#   - Pinned to VERSION 2.1.0, CANDIDATE_SHA 94c796fc34fd699776764d67d2f26013909a308e.
#   - Release must be published and live as Latest on GitHub before reconciliation.
#   - Requires RELEASE_STATE_TOKEN (minted via GitHub App meowdisplay-release).
#   - Respects scratch storage policy and verifies all transitions fail-closed.
set -euo pipefail

readonly PINNED_VERSION="2.1.0"
readonly PINNED_CANDIDATE_SHA="94c796fc34fd699776764d67d2f26013909a308e"
readonly PINNED_REPO="raiseCatError/meowdisplay"

VERSION="${VERSION:-$PINNED_VERSION}"
CANDIDATE_SHA="${CANDIDATE_SHA:-$PINNED_CANDIDATE_SHA}"
REPO="${GITHUB_REPOSITORY:-$PINNED_REPO}"

if [ "$VERSION" != "$PINNED_VERSION" ]; then
  echo "::error::VERSION must be '$PINNED_VERSION' (attempted override to '$VERSION' rejected)"
  exit 1
fi
if [ "$CANDIDATE_SHA" != "$PINNED_CANDIDATE_SHA" ]; then
  echo "::error::CANDIDATE_SHA must be '$PINNED_CANDIDATE_SHA' (attempted override to '$CANDIDATE_SHA' rejected)"
  exit 1
fi
if [ "$REPO" != "$PINNED_REPO" ]; then
  echo "::error::GITHUB_REPOSITORY must be '$PINNED_REPO' (attempted override to '$REPO' rejected)"
  exit 1
fi

mode="execute"
if [ "${1:-}" = "--manifest-only" ]; then
  mode="manifest-only"
elif [ -n "${1:-}" ] && [ "${1:-}" != "--execute" ]; then
  echo "::error::unknown option '${1:-}' (usage: reconcile-mac-release.sh [--manifest-only | --execute])"
  exit 1
fi

here="$(cd "$(dirname "$0")" && pwd)"

# Scratch storage policy
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
  echo "::error::No approved scratch location found. T7 scratch storage (/Volumes/T7Tmp/ai-dev) is required locally."
  exit 1
fi

work=$(mktemp -d "$scratch_base/meow-reconcile.XXXXXX")
trap 'rm -rf "$work"' EXIT

echo "=== MeowDisplay Release-State Reconciliation ==="
echo "Version:       $VERSION"
echo "Candidate SHA: $CANDIDATE_SHA"
echo "Repository:    $REPO"
echo "Mode:          $mode"
echo ""

# 1. Preflight check: Verify Mac 2.1.0 is published live on GitHub
echo "1. Checking live publication status on GitHub..."
if [ "${RECOVERY_TEST_MOCK_ENV:-false}" != "true" ]; then
  latest_tag=$(gh api "repos/$REPO/releases/latest" --jq .tag_name)
  [ "$latest_tag" = "v$VERSION" ] || { echo "::error::Latest release is '$latest_tag', expected 'v$VERSION'"; exit 1; }

  tag_sha=$(gh api "repos/$REPO/commits/v$VERSION" --jq .sha)
  [ "$tag_sha" = "$CANDIDATE_SHA" ] || { echo "::error::v$VERSION tag points to $tag_sha, expected candidate $CANDIDATE_SHA"; exit 1; }
  echo "✓ Live GitHub Release v$VERSION is Latest pointing to $CANDIDATE_SHA"
fi

# 2. Require release App token for state writes
echo "2. Checking release-state authorization..."
if [ -z "${RELEASE_STATE_TOKEN:-}" ] && [ "${RECOVERY_TEST_MOCK_ENV:-false}" != "true" ]; then
  echo "::error::RELEASE_STATE_TOKEN is required to mutate the protected release-state branch (Ruleset 26251855)."
  echo "The release App (App ID 5582030) token must be minted in a protected environment."
  exit 1
fi

# 3. Transition publication from 'failed' to 'in-progress'
echo "3. Restarting publication state from 'failed' to 'in-progress'..."
"$here/release-state.sh" "$VERSION" publish start STATE \
  --config "$here/../../.github/release-config.json" \
  --branch-head "$CANDIDATE_SHA"

# 4. Advance Mac platform to 'published'
echo "4. Recording Mac platform publication in release-state..."
"$here/release-state.sh" "$VERSION" publish mac-published STATE \
  --config "$here/../../.github/release-config.json" \
  --url "https://github.com/$REPO/releases/tag/v$VERSION"

# 5. Process stores (iOS is already published, Android is excluded)
echo "5. Verifying store distribution state..."
out_stores=$("$here/release-state.sh" "$VERSION" publish stores STATE \
  --config "$here/../../.github/release-config.json" \
  --stores live)
echo "$out_stores"

# 6. Generate accurate website manifest
echo "6. Generating website manifest release.json..."
manifest_out="$work/release.json"
"$here/release-state.sh" "$VERSION" publish website-manifest STATE \
  --config "$here/../../.github/release-config.json" \
  --out "$manifest_out"

cat "$manifest_out"
echo ""

# 7. Verify updated release-state on remote
echo "7. Verifying reconciled release-state..."
git -C "$here/../.." fetch -q origin release-state || {
  echo "::error::Failed to fetch origin/release-state after reconciliation"
  exit 1
}
new_state=$(git -C "$here/../.." show origin/release-state:releases/"$VERSION".json)
pub_stage=$(jq -r .publication.stage <<< "$new_state")
mac_stage=$(jq -r .platforms.mac.stage <<< "$new_state")
ios_stage=$(jq -r .platforms.ios.stage <<< "$new_state")

[ "$pub_stage" = "in-progress" ] || { echo "::error::publication stage is '$pub_stage', expected 'in-progress'"; exit 1; }
[ "$mac_stage" = "published" ] || { echo "::error::Mac stage is '$mac_stage', expected 'published'"; exit 1; }
[ "$ios_stage" = "published" ] || { echo "::error::iOS stage is '$ios_stage', expected 'published'"; exit 1; }

echo "✓ release-state successfully reconciled:"
echo "  - platforms.mac: published"
echo "  - platforms.ios: published"
echo "  - publication:   in-progress (ready for website deploy and source promotion)"
echo ""
echo "Next step: Deploy website manifest to MeowDisplayWebsite, then promote source commit to main."
