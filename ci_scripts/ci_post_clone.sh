#!/bin/zsh
# Xcode Cloud: the Xcode project is generated from project.yml and isn't in the repository, so
# make it right after the clone, the way the GitHub ios-duo job does. The workflow's
# DEVELOPMENT_TEAM environment variable signs it (Xcode Cloud manages the certificates); there is
# no fallback team, so a missing variable fails here instead of producing an unsigned project.
# docs/ci/xcode-cloud-duo.md has the workflow this serves.
set -euo pipefail

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM in the Xcode Cloud workflow's environment}"
cd "${CI_PRIMARY_REPOSITORY_PATH:?not running in Xcode Cloud}"

# The developers use XcodeGen 2.46. Homebrew installs its current one; a different version is
# called out in the log, so a generator change is visible next to any project difference.
brew install xcodegen
xcodegen --version
xcodegen --version | grep -q '2\.46\.' || echo "warning: XcodeGen is not 2.46; check the generated project"

export DEVELOPMENT_TEAM
xcodegen generate --spec project.yml
