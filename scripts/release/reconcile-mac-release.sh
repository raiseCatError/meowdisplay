#!/usr/bin/env bash
# reconcile-mac-release.sh: Reconcile release-state through the authorized release App
# after Mac 2.1.0 publication is live.
#
# Usage:
#   reconcile-mac-release.sh (--execute | --finish | --manifest-only | --preflight | --site-evidence DIR)
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
#   --site-evidence DIR  Read-only: save the website repository's branch HEAD
#                    and the files --finish compares with production into DIR.
#                    GH_TOKEN must read that (private) repository.
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
  --site-evidence)
    mode="site-evidence"
    evidence_out=${2:?--site-evidence needs an output directory}
    ;;
  *)
    echo "::error::usage: reconcile-mac-release.sh (--execute | --finish | --manifest-only | --preflight | --site-evidence DIR)"
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

# Bot Fight Mode challenges GitHub-hosted runners on the site's HTML, JSON and
# XML (Cloudflare Security Events, run 43125145760); WAF skip rules cannot
# exempt a path from it. Only after such a challenge, production is proven by
# evidence the runner CAN observe. Every link is required:
#  1. The website repository's branch HEAD files (SITE_EVIDENCE_DIR, saved by
#     --site-evidence in the read-only site-evidence job: the repository is
#     private, and only the website App in website-update may read it).
#  2. That HEAD's manifest is exactly what release-state generates
#     (publishedAt aside).
#  3. The PRODUCTION origin serves files Bot Fight Mode does not challenge
#     (llms.txt, site.js) byte-identical to that HEAD: production serves this
#     build, not an older, failed or rolled-back deployment.
#  4. LIVE_RELEASE_SHA256: the approver's own fetch of the production manifest
#     (shasum -a 256) equals that HEAD's manifest byte for byte.
# Sets live_version. Anything missing or different stops before any write.
readonly PRODUCTION_PROBES="llms.txt site.js"
site_coordinates() {
  site_repo=$(jq -r .website.repository "$candidate_config")
  site_branch=$(jq -r '.website.branch // "main"' "$candidate_config")
  [[ $site_repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && $site_branch =~ ^[A-Za-z0-9._/-]+$ ]] || { echo "::error::bad website repository/branch"; exit 1; }
  live_url=$(jq -r .website.liveUrl "$candidate_config")
  [[ $live_url =~ ^(https://[A-Za-z0-9.-]+)/([A-Za-z0-9._/-]+\.json)$ ]] || { echo "::error::bad website.liveUrl '$live_url'"; exit 1; }
  live_origin=${BASH_REMATCH[1]}
  manifest_path=${BASH_REMATCH[2]}
}

verify_site_via_production_evidence() {
  local dir=${SITE_EVIDENCE_DIR:-} head want f got
  [[ ${LIVE_RELEASE_SHA256:-} =~ ^[0-9a-f]{64}$ ]] || {
    echo "::error::live_release_sha256 is required here: fetch $live_url yourself and pass its sha256 (curl -fsSL $live_url | shasum -a 256); nothing recorded"
    exit 1
  }
  [ -n "$dir" ] && [ -f "$dir/head" ] || { echo "::error::no website evidence (SITE_EVIDENCE_DIR); nothing recorded"; exit 1; }
  head=$(cat "$dir/head")
  [[ $head =~ ^[0-9a-f]{40}$ ]] || { echo "::error::bad website HEAD in the evidence; nothing recorded"; exit 1; }
  echo "   website evidence: $site_repo $site_branch HEAD $head"

  "$state_cmd" "$VERSION" publish website-manifest STATE --config "$candidate_config" --out "$work/expected-manifest.json" >/dev/null
  [ "$(jq -S 'del(.publishedAt)' "$dir/$manifest_path")" = "$(jq -S 'del(.publishedAt)' "$work/expected-manifest.json")" ] || {
    echo "::error::$site_repo@$head's $manifest_path is not what release-state describes; nothing recorded"
    exit 1
  }
  want=$(shasum -a 256 "$dir/$manifest_path" | cut -c1-64)
  [ "$want" = "$LIVE_RELEASE_SHA256" ] || {
    echo "::error::your production $manifest_path sha256 $LIVE_RELEASE_SHA256 is not $site_branch@${head:0:12}'s $want; nothing recorded"
    exit 1
  }
  echo "   ✓ $site_branch's $manifest_path = release-state's manifest; sha256 $want = your production fetch"

  for f in $PRODUCTION_PROBES; do
    [ -f "$dir/$f" ] || { echo "::error::website evidence lacks $f; nothing recorded"; exit 1; }
    got=$(curl -sS --max-time 30 -o "$work/prod-$f" -w '%{http_code}' "$live_origin/$f?ts=$(date +%s)") || got=000
    [ "$got" = 200 ] || { echo "::error::production $live_origin/$f answered HTTP $got; production unverified, nothing recorded"; exit 1; }
    cmp -s "$work/prod-$f" "$dir/$f" || {
      echo "::error::production $live_origin/$f is not $site_branch@${head:0:12}'s (production serves another build?); nothing recorded"
      exit 1
    }
    echo "   ✓ production $live_origin/$f = $site_branch@${head:0:12}"
  done
  live_version=$(jq -r .version "$dir/$manifest_path")
}

# Mode: site-evidence (read-only): what --finish compares production with.
if [ "$mode" = "site-evidence" ]; then
  site_coordinates
  mkdir -p "$evidence_out"
  head=$(gh api "repos/$site_repo/commits/$site_branch" --jq .sha)
  [[ $head =~ ^[0-9a-f]{40}$ ]] || { echo "::error::cannot resolve $site_repo $site_branch"; exit 1; }
  for f in "$manifest_path" $PRODUCTION_PROBES; do
    mkdir -p "$evidence_out/$(dirname "$f")"
    gh api -H "Accept: application/vnd.github.raw" "repos/$site_repo/contents/$f?ref=$head" > "$evidence_out/$f"
  done
  printf '%s\n' "$head" > "$evidence_out/head"
  echo "✓ saved $site_repo@$head ($site_branch HEAD): $manifest_path $PRODUCTION_PROBES"
  exit 0
fi

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
  site_coordinates
  code=$(curl -sS --max-time 30 -D "$work/live.headers" -o "$work/live.json" -w '%{http_code}' "$live_url?ts=$(date +%s)") || code=000
  if [ "$code" = 200 ]; then
    live_version=$(jq -r .version "$work/live.json" 2>/dev/null || echo none)
    echo "✓ $live_url fetched directly (version $live_version)"
  elif [ "$code" = 403 ] && grep -qiE '^cf-mitigated:[[:space:]]*challenge' "$work/live.headers"; then
    echo "$live_url answered this runner with a Cloudflare challenge (Bot Fight Mode cannot be skipped for it)."
    verify_site_via_production_evidence
  else
    echo "::error::$live_url answered HTTP $code without a Cloudflare challenge; nothing recorded"
    exit 1
  fi
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
