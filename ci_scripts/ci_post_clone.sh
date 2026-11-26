#!/bin/zsh
# Xcode Cloud: the Xcode project is generated from project.yml and isn't in the repository, so
# make it right after the clone, the way the GitHub ios-duo job does. It is signed for the team
# Xcode Cloud runs as (CI_TEAM_ID; Xcode Cloud manages the certificates), or for a
# DEVELOPMENT_TEAM the workflow sets. With neither, it fails here instead of producing an
# unsigned project.
# docs/ci/xcode-cloud-duo.md has the workflow this serves.
set -euo pipefail

DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-${CI_TEAM_ID:-}}"
: "${DEVELOPMENT_TEAM:?No team: neither DEVELOPMENT_TEAM nor CI_TEAM_ID is set}"
cd "${CI_PRIMARY_REPOSITORY_PATH:?not running in Xcode Cloud}"

# The developers use XcodeGen 2.46. Homebrew installs its current one; a different version is
# called out in the log, so a generator change is visible next to any project difference.
brew install xcodegen
xcodegen --version
xcodegen --version | grep -q '2\.46\.' || echo "warning: XcodeGen is not 2.46; check the generated project"

export DEVELOPMENT_TEAM
xcodegen generate --spec project.yml

# Xcode Cloud doesn't resolve packages on its own: it needs the resolved file inside the project.
# The generated project has none, so copy in the committed one. Its pins are project.yml's exact
# versions; refresh it (from a ./generate-local.sh project) whenever those change.
resolved=MeowDisplay.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
mkdir -p "$resolved"
cp ci_scripts/Package.resolved "$resolved/Package.resolved"
