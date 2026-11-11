#!/usr/bin/env bash
# reconcile-mac-release.sh: Reconcile release-state through the authorized release App
# after Mac 2.1.0 publication is live.
#
# Usage:
#   reconcile-mac-release.sh (--execute | --finish | --manifest-only | --preflight)
#
# Modes:
#   --execute        Mutate release-state: advance publication from 'failed' to
#                    'in-progress', record Mac platform as 'published', process
#                    stores, generate website manifest, and verify remote state.
#                    Requires RELEASE_STATE_TOKEN (App ID 5582030).
#   --manifest-only  Strictly read-only: generate website release.json manifest
#                    from recorded state without mutating release-state.
#   --finish         After the website serves release.json for this version:
#                    record website-updated and finish the publication. Same
#                    live-release checks and token as --execute.
#   --preflight      Read-only dry-run of publication start using frozen candidate config.
#
# --execute and --finish first prove, live, that GitHub release $DRAFT_ID is
# public, is Latest, is tagged at the candidate, and carries exactly the five
# recorded assets (GitHub's own sha256 digests). Only then is anything written.
# Both are safe to re-run: a step already recorded changes nothing.
#
# Requirements:
#   - Pinned to VERSION 2.1.0, CANDIDATE_SHA 94c796fc34fd699776764d67d2f26013909a308e.
#   - For --execute, Mac 2.1.0 must already be published live as Latest on GitHub.
#   - Respects scratch storage policy and verifies all transitions fail-closed.
set -euo pipefail

readonly PINNED_VERSION="2.1.0"
readonly PINNED_CANDIDATE_SHA="94c796fc34fd699776764d67d2f26013909a308e"
readonly PINNED_REPO="raiseCatError/meowdisplay"
readonly PINNED_RELEASE_ID="442117184"
readonly PINNED_SHA256SUMS_DIGEST="279e22555e9a84a4fc59bd7d529f4efca6ccf2a8c986ac9fc939d627368bc1b7"

VERSION="${VERSION:-$PINNED_VERSION}"
CANDIDATE_SHA="${CANDIDATE_SHA:-$PINNED_CANDIDATE_SHA}"
REPO="${GITHUB_REPOSITORY:-$PINNED_REPO}"
export GITHUB_REPOSITORY="$REPO"
export GH_TOKEN="${GH_TOKEN:-${RELEASE_STATE_TOKEN:-${GITHUB_TOKEN:-}}}"

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

mode=""
case "${1:-}" in
  --manifest-only)
    mode="manifest-only"
    ;;
  --preflight)
    mode="preflight"
    ;;
  --execute)
    mode="execute"
    ;;
  --finish)
    mode="finish"
    ;;
  *)
    echo "::error::usage: reconcile-mac-release.sh (--execute | --finish | --manifest-only | --preflight)"
    echo "  --execute:        Reconcile release-state with authorized release App token (mutating)"
    echo "  --finish:         Record the live website manifest and finish publication (mutating)"
    echo "  --manifest-only:  Generate website release.json from current recorded state (read-only)"
    echo "  --preflight:      Check frozen candidate config and state machine without publishing"
    exit 1
    ;;
esac

here="$(cd "$(dirname "$0")" && pwd)"

state_cmd="release-state.sh"
command -v "$state_cmd" >/dev/null 2>&1 || state_cmd="$here/release-state.sh"

# Scratch storage policy enforcement:
# In CI: $RUNNER_TEMP is required.
# In local runs: scratch storage must genuinely reside on the mounted external T7 volume (/Volumes/T7Tmp/ai-dev).
# Fake mount points, unmounted volumes, and arbitrary non-T7 paths are strictly rejected.
scratch_base=""
if [ -n "${RUNNER_TEMP:-}" ]; then
  scratch_base="$RUNNER_TEMP"
else
  # 1. Verify /Volumes/T7Tmp is genuinely mounted and present in mount table
  if ! mount | grep -E -q '[[:space:]]on /Volumes/T7Tmp[[:space:]]'; then
    echo "::error::External T7 scratch volume (/Volumes/T7Tmp) is not mounted."
    exit 1
  fi
  # 2. Verify /Volumes/T7Tmp is an actual mount point, not a directory on internal root
  if [ "$(df -P /Volumes/T7Tmp 2>/dev/null | awk 'NR==2{print $6}')" != "/Volumes/T7Tmp" ]; then
    echo "::error::/Volumes/T7Tmp is not a mounted volume (detected fake mount-point directory on internal disk)."
    exit 1
  fi
  # 3. Verify external T7 health via t7run if available
  if command -v t7run >/dev/null 2>&1; then
    t7run --check || { echo "::error::T7 scratch storage verification (t7run --check) failed"; exit 1; }
  fi

  # 4. Resolve candidate scratch directory
  target_scratch=""
  if [ -n "${T7_RUN_DIR:-}" ]; then
    target_scratch="$T7_RUN_DIR"
  elif [ -n "${TMPDIR:-}" ] && [[ "$TMPDIR" == /Volumes/T7Tmp/* ]]; then
    target_scratch="$TMPDIR"
  else
    target_scratch="/Volumes/T7Tmp/ai-dev/tmp"
  fi

  # 5. Ensure candidate directory exists or can be created
  mkdir -p "$target_scratch" 2>/dev/null || {
    echo "::error::Failed to create or access scratch directory '$target_scratch'"
    exit 1
  }

  # 6. Verify canonical physical path (resolving symlinks) genuinely resides under /Volumes/T7Tmp/ai-dev
  canonical_scratch=$(cd "$target_scratch" && pwd -P)
  case "$canonical_scratch" in
    /Volumes/T7Tmp/ai-dev | /Volumes/T7Tmp/ai-dev/*)
      ;;
    *)
      echo "::error::Scratch path '$target_scratch' resolves to '$canonical_scratch', which is outside /Volumes/T7Tmp/ai-dev. Arbitrary scratch paths are rejected."
      exit 1
      ;;
  esac

  # 7. Verify the filesystem mount point of the canonical path is /Volumes/T7Tmp
  scratch_mount=$(df -P "$canonical_scratch" 2>/dev/null | awk 'NR==2{print $6}')
  if [ "$scratch_mount" != "/Volumes/T7Tmp" ]; then
    echo "::error::Scratch path '$canonical_scratch' is mounted on '$scratch_mount', expected '/Volumes/T7Tmp'."
    exit 1
  fi

  scratch_base="$canonical_scratch"
fi

work=$(mktemp -d "$scratch_base/meow-reconcile.XXXXXX")
trap 'rm -rf "$work"' EXIT

if { [ "$mode" = "execute" ] || [ "$mode" = "finish" ]; } && [ -z "${RELEASE_STATE_TOKEN:-}" ]; then
  echo "::error::RELEASE_STATE_TOKEN is required to mutate the protected release-state branch (Ruleset 26251855)."
  exit 1
fi

echo "=== MeowDisplay Release-State Reconciliation ==="
echo "Version:       $VERSION"
echo "Candidate SHA: $CANDIDATE_SHA"
echo "Repository:    $REPO"
echo "Mode:          $mode"
echo ""

root="$here/../.."
# An explicit refspec: the remote-tracking ref is updated whatever fetch
# refspec the checkout configured (actions/checkout, a shallow clone, a
# developer clone). The repository is public, so this read needs no
# credential; the checkout deliberately persists none.
fetch_release_state() {
  git -C "$root" fetch -q --no-tags origin "+refs/heads/release-state:refs/remotes/origin/release-state"
}

# Generic main config still requires Android; the frozen 2.1.0 candidate
# explicitly excludes Android. Always extract the config from that commit.
candidate_config="$work/approved-release-config.json"
git -C "$root" fetch -q --no-tags origin refs/heads/release/2.1.0 || {
  echo "::error::Cannot fetch frozen release/2.1.0"
  exit 1
}
candidate_head=$(git -C "$root" rev-parse FETCH_HEAD)
[ "$candidate_head" = "$CANDIDATE_SHA" ] || {
  echo "::error::release/2.1.0 moved to $candidate_head; expected $CANDIDATE_SHA"
  exit 1
}
git -C "$root" show "$CANDIDATE_SHA:.github/release-config.json" > "$candidate_config" || {
  echo "::error::Cannot read frozen candidate release config"
  exit 1
}
jq -e '(.requiredPlatforms | sort) == ["ios","mac"] and (.excludedPlatforms | sort) == ["android"] and .ios.submitForReview == false' "$candidate_config" >/dev/null || {
  echo "::error::Frozen candidate config must require mac + ios, exclude android, and disable iOS resubmission"
  exit 1
}
echo "✓ Approved candidate config verified: Mac + iOS; Android excluded"

# Preflight the REAL publication state machine on an expendable copy,
# preventing the original post-publication reconciliation failure.
if [ "$mode" = "preflight" ]; then
  fetch_release_state || {
    echo "::error::Cannot fetch fresh release-state for preflight"
    exit 1
  }
  git -C "$root" show "origin/release-state:releases/$VERSION.json" > "$work/state-for-preflight.json"
  "$here/meow-release" publish start "$work/state-for-preflight.json" \
    --config "$candidate_config" --branch-head "$CANDIDATE_SHA" || {
    echo "::error::Publication state machine refuses recovery"
    exit 1
  }
  echo "✓ Read-only preflight passed; scratch state only"
  exit 0
fi

# Mode: manifest-only (genuinely read-only)
if [ "$mode" = "manifest-only" ]; then
  echo "1. Generating website manifest from current recorded release-state (read-only)..."
  fetch_release_state || {
    echo "::error::Failed to fetch origin/release-state from remote. Relying on stale local state is prohibited."
    exit 1
  }
  manifest_out="$work/release.json"
  "$state_cmd" "$VERSION" publish website-manifest STATE \
    --config "$candidate_config" \
    --out "$manifest_out"

  cat "$manifest_out"
  echo ""
  echo "✓ Manifest generated successfully (read-only mode; zero state mutations performed)"
  exit 0
fi

# Proves the public release is exactly the approved one before any state write.
verify_live_release() {
  echo "1. Checking the live GitHub Release against the recorded artifacts..."
  local release latest_tag tag_sha names want_names recorded_state
  release=$(gh api "repos/$REPO/releases/$PINNED_RELEASE_ID")
  [ "$(jq -r .tag_name <<< "$release")" = "v$VERSION" ] || { echo "::error::release $PINNED_RELEASE_ID is not tagged v$VERSION"; exit 1; }
  [ "$(jq -r .draft <<< "$release")" = "false" ] || {
    echo "::error::release $PINNED_RELEASE_ID (v$VERSION) is still a draft: nothing was published, so nothing is reconciled"
    exit 1
  }
  latest_tag=$(gh api "repos/$REPO/releases/latest" --jq .tag_name)
  [ "$latest_tag" = "v$VERSION" ] || { echo "::error::Latest release is '$latest_tag', expected 'v$VERSION'"; exit 1; }
  tag_sha=$(gh api "repos/$REPO/commits/v$VERSION" --jq .sha)
  [ "$tag_sha" = "$CANDIDATE_SHA" ] || { echo "::error::v$VERSION tag points to $tag_sha, expected candidate $CANDIDATE_SHA"; exit 1; }

  fetch_release_state || { echo "::error::Failed to fetch origin/release-state"; exit 1; }
  recorded_state=$(git -C "$root" show "origin/release-state:releases/$VERSION.json")
  # GitHub computes each asset's sha256 itself ("digest"); compare all five,
  # by name, to the recorded Mac artifacts plus the pinned SHA256SUMS.txt.
  names=$(jq -r '[.assets[] | "\(.name) \(.digest)"] | sort | join(",")' <<< "$release")
  want_names=$(jq -r --arg sums "$PINNED_SHA256SUMS_DIGEST" \
    '[(.platforms.mac.artifacts[] | "\(.name) sha256:\(.sha256)"), "SHA256SUMS.txt sha256:\($sums)"] | sort | join(",")' <<< "$recorded_state")
  [ "$names" = "$want_names" ] || {
    echo "::error::live assets of v$VERSION are [$names], expected exactly [$want_names]"
    exit 1
  }
  echo "✓ v$VERSION is public and Latest at $CANDIDATE_SHA with exactly the five recorded assets"
}

# Mode: finish (mutating): the website serves this version's release.json.
if [ "$mode" = "finish" ]; then
  verify_live_release
  current=$(git -C "$root" show "origin/release-state:releases/$VERSION.json")
  if [ "$(jq -r .publication.stage <<< "$current")" = "published" ]; then
    echo "✓ publication of $VERSION is already recorded as published; nothing to do"
    exit 0
  fi
  [ "$(jq -r .publication.stage <<< "$current")" = "in-progress" ] && [ "$(jq -r .platforms.mac.stage <<< "$current")" = "published" ] || {
    echo "::error::finish needs publication in-progress with Mac published (run action=reconcile first); state is $(jq -c '{publication: .publication.stage, mac: .platforms.mac.stage}' <<< "$current")"
    exit 1
  }
  [[ ${PROMOTION_PR:-} =~ ^[0-9]*$ ]] || { echo "::error::PROMOTION_PR must be a pull request number"; exit 1; }
  live_url=$(jq -r .website.liveUrl "$candidate_config")
  [[ $live_url =~ ^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+\.json$ ]] || { echo "::error::bad website.liveUrl '$live_url'"; exit 1; }
  live_version=$(curl -fsSL --max-time 30 "$live_url?ts=$(date +%s)" | jq -r .version 2>/dev/null || echo none)
  [ "$live_version" = "$VERSION" ] || {
    echo "::error::$live_url serves version '$live_version', not $VERSION; deploy the website first (nothing recorded)"
    exit 1
  }
  echo "2. Recording the live website manifest..."
  "$state_cmd" "$VERSION" publish website-updated STATE \
    --config "$candidate_config" --url "$live_url" --live-version "$live_version"
  echo "3. Finishing the publication..."
  "$state_cmd" "$VERSION" publish finish STATE \
    --config "$candidate_config" ${PROMOTION_PR:+--pr "$PROMOTION_PR"}
  fetch_release_state || { echo "::error::Failed to fetch origin/release-state after finishing"; exit 1; }
  final=$(git -C "$root" show "origin/release-state:releases/$VERSION.json")
  echo "publication: $(jq -c .publication <<< "$final")"
  echo "website:     $(jq -c .website <<< "$final")"
  [ "$(jq -r .publication.stage <<< "$final")" = "published" ] || {
    echo "::error::publication is '$(jq -r .publication.stage <<< "$final")', not published"
    exit 1
  }
  echo "✓ MeowDisplay $VERSION publication finished"
  exit 0
fi

# Mode: execute (mutating)
verify_live_release

# 2. Require release App token for state writes
echo "2. Checking release-state authorization..."
if [ -z "${RELEASE_STATE_TOKEN:-}" ]; then
  echo "::error::RELEASE_STATE_TOKEN is required to mutate the protected release-state branch (Ruleset 26251855)."
  echo "The release App (App ID 5582030) token must be minted in a protected environment."
  exit 1
fi

# 3. Transition publication from 'failed' to 'in-progress'
echo "3. Restarting publication state from 'failed' to 'in-progress'..."
"$state_cmd" "$VERSION" publish start STATE \
  --config "$candidate_config" \
  --branch-head "$CANDIDATE_SHA"

# 4. Advance Mac platform to 'published'
echo "4. Recording Mac platform publication in release-state..."
"$state_cmd" "$VERSION" publish mac-published STATE \
  --config "$candidate_config" \
  --url "https://github.com/$REPO/releases/tag/v$VERSION"

# 5. iOS is already published, Android excluded. Do NOT invoke stores:
# that requires unnecessary App Store credentials and risks store actions.
echo "5. Keeping previously published iOS; no store operations"

# 6. Generate accurate website manifest
echo "6. Generating website manifest release.json..."
manifest_out="$work/release.json"
"$state_cmd" "$VERSION" publish website-manifest STATE \
  --config "$candidate_config" \
  --out "$manifest_out"

cat "$manifest_out"
echo ""

# 7. Verify updated release-state on remote
echo "7. Verifying reconciled release-state..."
fetch_release_state || {
  echo "::error::Failed to fetch origin/release-state after reconciliation"
  exit 1
}
new_state=$(git -C "$root" show origin/release-state:releases/"$VERSION".json)
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
echo "Next step: deploy release.json on the website, then run this workflow with action=finish."
