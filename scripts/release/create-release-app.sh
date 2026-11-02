#!/usr/bin/env bash
# Creates the release GitHub App from a manifest and stores its credentials where the
# release workflows read them. The owner runs it once, signed in to GitHub in the browser
# and with gh authenticated as the owner:
#
#   1. scripts/release/create-release-app.sh start
#        opens GitHub's "Create GitHub App" page, pre-filled from the manifest below
#        (private App: contents, pull requests and issues read & write; metadata read;
#        no webhook, no events).
#   2. In the browser: keep or change the name, press "Create GitHub App". GitHub then
#      opens RELEASE.md with ?code=…&state=… in the address bar. Copy the code value.
#   3. scripts/release/create-release-app.sh finish <code>
#        exchanges the one-time code (valid for one hour, usable once) for the App's
#        credentials; sets the repository variables RELEASE_APP_ID and
#        RELEASE_APP_CLIENT_ID, and RELEASE_APP_PRIVATE_KEY in every environment whose
#        jobs mint the App's token. The private key is never printed or written to disk.
#   4. Install the App on this repository only (finish prints the link).
#
# Then the release-state ruleset gets the App as its only bypass (RELEASE.md).
# The environments must exist first: scripts/release/apply-environments.sh --apply.
set -euo pipefail
repo=${REPOSITORY:-raiseCatError/meowdisplay}
# Every environment with a job that mints RELEASE_APP's token (check-release-workflows.rb).
envs=(release-pr release-state release-state-check release-stores release-publish website-update)

case "${1:-}" in
start)
  state=$(openssl rand -hex 16)
  page="${TMPDIR:-/tmp}/meowdisplay-release-app-$state.html"
  manifest=$(jq -nc --arg repo "$repo" '{
    name: "MeowDisplay Release",
    url: "https://github.com/\($repo)",
    description: "Writes MeowDisplay release state and opens release pull requests. No webhook.",
    hook_attributes: {url: "https://meowdisplay.app", active: false},
    redirect_url: "https://github.com/\($repo)/blob/main/RELEASE.md",
    public: false,
    default_permissions: {contents: "write", pull_requests: "write", issues: "write", metadata: "read"},
    default_events: []
  }')
  value=$(jq -rn --arg m "$manifest" '$m | @html')
  cat > "$page" <<HTML
<!DOCTYPE html>
<html><body>
<form id="f" method="post" action="https://github.com/settings/apps/new?state=$state">
<input type="hidden" name="manifest" value="$value">
<p>Opening GitHub's "Create GitHub App" page…</p>
<button type="submit">Continue to GitHub</button>
</form>
<script>document.getElementById("f").submit()</script>
</body></html>
HTML
  echo "Opening $page"
  echo "After pressing \"Create GitHub App\", copy the code from the address bar and run:"
  echo "  $0 finish <code>"
  open "$page" 2>/dev/null || echo "Open that file in a browser where you are signed in to GitHub."
  ;;
finish)
  code=${2:?usage: create-release-app.sh finish <code>}
  [[ $code =~ ^[A-Za-z0-9_-]+$ ]] || { echo "::error::that doesn't look like a manifest code"; exit 1; }
  for e in "${envs[@]}"; do
    gh api "repos/$repo/environments/$e" >/dev/null 2>&1 ||
      { echo "::error::environment $e is missing: run scripts/release/apply-environments.sh --apply first"; exit 1; }
  done
  # The response holds the private key: keep it in this variable only, never echo it.
  app=$(gh api -X POST "app-manifests/$code/conversions")
  id=$(jq -r .id <<< "$app")
  slug=$(jq -r .slug <<< "$app")
  client_id=$(jq -r .client_id <<< "$app")
  [[ $id =~ ^[0-9]+$ ]] && [ -n "$client_id" ] && [ "$client_id" != null ] ||
    { echo "::error::GitHub returned no App (code used or expired?)"; exit 1; }
  gh variable set RELEASE_APP_ID -R "$repo" --body "$id"
  gh variable set RELEASE_APP_CLIENT_ID -R "$repo" --body "$client_id"
  for e in "${envs[@]}"; do
    jq -r .pem <<< "$app" | gh secret set RELEASE_APP_PRIVATE_KEY -R "$repo" --env "$e"
  done
  app=
  echo "Created the GitHub App '$slug' (App ID $id); its key is stored in: ${envs[*]}"
  echo "Now install it on this repository only:"
  echo "  https://github.com/apps/$slug/installations/new"
  echo "  → Only select repositories → ${repo#*/} → Install"
  ;;
*)
  sed -n '2,20p' "$0"
  exit 1
  ;;
esac
