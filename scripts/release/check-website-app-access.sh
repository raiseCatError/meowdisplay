#!/usr/bin/env bash
# Proves, read-only, that the website App is set up for update-website.sh (Release dry
# run, website-update job). It writes nothing: no branch, commit, pull request or
# manifest.
#  1. SITE_TOKEN was minted exactly as release-publish.yml mints it: Contents and Pull
#     requests write, the website repository only. GitHub refuses to mint a token with
#     permissions the installation lacks, so its existence proves both grants; the
#     writes themselves (push, PR, auto-merge) are not tried.
#  2. The App's installation reaches the website repository only
#     (INSTALLATION_SCOPE_TOKEN: minted for the whole installation, metadata only).
#  3. SITE_TOKEN reads the repository, its publish branch and its pull requests.
#  4. The website deploys release.json (update-website.sh's own precondition).
# Usage: check-website-app-access.sh <release-config.json>
#   (needs SITE_TOKEN, INSTALLATION_SCOPE_TOKEN; APP_SLUG is reported if set)
set -euo pipefail
config=${1:?usage: check-website-app-access.sh <release-config.json>}
: "${SITE_TOKEN:?SITE_TOKEN is required}" "${INSTALLATION_SCOPE_TOKEN:?INSTALLATION_SCOPE_TOKEN is required}"
fail() { echo "::error::$1"; exit 1; }

repo=$(jq -r .website.repository "$config")
branch=$(jq -r '.website.branch // "main"' "$config")
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "bad website repository '$repo'"
[[ $branch =~ ^[A-Za-z0-9_./-]+$ && $branch != *..* ]] || fail "bad website branch '$branch'"
echo "website App: ${APP_SLUG:-unknown}; token minted with contents: write, pull_requests: write for $repo"

site() { GH_TOKEN=$SITE_TOKEN gh api "$@"; }

repos=$(GH_TOKEN=$INSTALLATION_SCOPE_TOKEN gh api --paginate installation/repositories --jq '.repositories[].full_name' | sort | paste -sd, -) ||
  fail "the installation token can't list its repositories"
[ "$repos" = "$repo" ] || fail "the website App's installation reaches '$repos'; install it on $repo only"
echo "the website App's installation reaches $repo only"

name=$(site "repos/$repo" --jq .full_name) || fail "the website token can't read $repo"
[ "$name" = "$repo" ] || fail "the website token reads '$name', not $repo"
site "repos/$repo/branches/$branch" --jq .name > /dev/null || fail "the website token can't read $repo's $branch branch"
site "repos/$repo/pulls?state=all&per_page=1" --jq length > /dev/null || fail "the website token can't read $repo's pull requests"
echo "the website token reads $repo, its $branch branch and its pull requests"

package=$(site "repos/$repo/contents/scripts/package.py?ref=$branch" --jq .content | tr -d '\n' | base64 -d) ||
  fail "the website token can't read scripts/package.py on $branch"
grep -q 'release\.json' <<< "$package" || fail "$repo doesn't deploy release.json yet: its scripts/package.py must copy it into dist/"
echo "$repo deploys release.json"
echo "Not exercised: pushing a branch, opening the PR, auto-merge and the deploy (only a release does that)."
