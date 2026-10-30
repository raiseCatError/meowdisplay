#!/usr/bin/env bash
# Publishes a release's verified manifest (release.json: version, source
# commit, live download links, store links of LIVE platforms only) through
# meowdisplay.app's own pipeline: the website repository deploys its main
# branch to Cloudflare Pages, so this only proposes the file there and waits
# until the live site serves it. It changes nothing about how the site builds.
#
#  - website.publishMethod "pull-request" (default): a PR into the website's
#    branch with auto-merge, so the site's own checks still gate it;
#    "push": a direct commit, for a repository without checks.
#  - Fails closed if the site doesn't deploy the manifest yet (its
#    scripts/package.py must copy it into dist/), or if the live site
#    doesn't serve this version within 15 minutes.
#
# Usage: update-website.sh <release.json> <release-config.json> <version>   (needs SITE_TOKEN)
set -euo pipefail
manifest=${1:?usage}; config=${2:?usage}; version=${3:?usage}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::bad version"; exit 1; }
repo=$(jq -r .website.repository "$config")
branch=$(jq -r '.website.branch // "main"' "$config")
path=$(jq -r '.website.manifestPath // "release.json"' "$config")
live_url=$(jq -r .website.liveUrl "$config")
method=$(jq -r '.website.publishMethod // "pull-request"' "$config")
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "::error::bad website repository '$repo'"; exit 1; }
[[ $path =~ ^[A-Za-z0-9_./-]+\.json$ && $path != *..* ]] || { echo "::error::bad manifest path '$path'"; exit 1; }
[ "$(jq -r .version "$manifest")" = "$version" ] || { echo "::error::manifest is not for $version"; exit 1; }

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/website.XXXXXX")
trap 'rm -rf "$work"' EXIT
auth="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${SITE_TOKEN:?SITE_TOKEN is required}" | base64 | tr -d '\n')"
git_() { git -C "$work/site" -c "http.https://github.com/.extraheader=$auth" "$@"; }
git init -q "$work/site"
git_ remote add origin "https://github.com/$repo.git"
git_ fetch -q --depth 1 origin "refs/heads/$branch"
git_ checkout -q -B "$branch" FETCH_HEAD

if ! grep -q "$(basename "$path")" "$work/site/scripts/package.py" 2>/dev/null; then
  echo "::error::$repo doesn't deploy $path yet: its scripts/package.py must copy it into dist/ (one-time website change, RELEASE.md § Website)"
  exit 1
fi

mkdir -p "$work/site/$(dirname "$path")"
cp "$manifest" "$work/site/$path"
git_ add "$path"
if git_ diff --cached --quiet; then
  echo "$path already describes $version"
else
  author=(-c user.name="meowdisplay-release[bot]" -c user.email="meowdisplay-release[bot]@users.noreply.github.com")
  git_ "${author[@]}" commit -q -m "chore(release): MeowDisplay $version is live"
  if [ "$method" = push ]; then
    git_ push -q origin "HEAD:refs/heads/$branch"
  else
    # A new branch per run: nothing is ever force-pushed. An older open PR
    # for this version (an earlier, superseded run) is closed first.
    topic="release-site/$version/${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
    export GH_TOKEN=$SITE_TOKEN
    for old in $(gh pr list -R "$repo" --base "$branch" --state open --search "head:release-site/$version/" --json number --jq '.[].number'); do
      gh pr close "$old" -R "$repo" --delete-branch --comment "Superseded by a newer release run."
    done
    git_ push -q origin "HEAD:refs/heads/$topic"
    gh pr create -R "$repo" --head "$topic" --base "$branch" \
      --title "MeowDisplay $version is live" \
      --body "Updates $path from the published release's verified manifest. Merged automatically once the site's checks pass."
    pr=$(gh pr list -R "$repo" --head "$topic" --base "$branch" --state open --json number --jq '.[0].number')
    gh pr merge "$pr" -R "$repo" --squash --auto --delete-branch
  fi
fi

# The release counts as on the website only once the live site serves it.
for attempt in $(seq 1 30); do
  served=$(curl -fsSL --max-time 30 "$live_url?ts=$(date +%s)" | jq -r .version 2>/dev/null || echo none)
  if [ "$served" = "$version" ]; then echo "meowdisplay.app serves $version (attempt $attempt)"; exit 0; fi
  sleep 30
done
echo "::error::$live_url still serves '$served' after 15 minutes"
exit 1
