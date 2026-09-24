# Release process

This documents how a MeowDisplay release actually gets built and published,
as implemented in `.github/workflows/release.yml` and `fastlane/Fastfile`.
It reflects what was verified while auditing the pipeline (see the
release-preparation GitHub issues) — not aspirational process.

## Versioning

- **Marketing version** (`CFBundleShortVersionString`, e.g. `1.20.0`) comes
  from [`release-please`](https://github.com/googleapis/release-please-action),
  which derives the next version from
  [Conventional Commits](https://www.conventionalcommits.org/) merged to
  `main` and opens a release PR. Merging that PR creates the `vX.Y.Z` tag
  that triggers the build jobs.
- **Build number** (`CFBundleVersion`) is the GitHub Actions run number
  (`github.run_number`) — monotonically increasing, unique per CI run, which
  is what keeps TestFlight builds distinct even across re-runs of the same
  tag.
- Both numbers are injected into `xcodebuild` via `xcargs` in
  `fastlane/Fastfile`'s `version_xcargs` helper; `project.yml` only defines
  placeholder defaults (`0.0.0` / `1`) for local, non-release builds.
- The Mac sender, Mac Receiver, and iOS app all build from the **same tag and
  the same run**, so their marketing versions stay in lockstep. Build numbers
  are also identical across the three, since they share the run number.
- This repository is a fork of [OpenDisplay](https://github.com/peetzweg/opendisplay)
  and inherited its tag history (`v1.12.0`–`v1.19.0`) and `release-please`
  setup. There is no `release-please-config.json`/manifest file in this repo,
  so `release-please-action` runs on its defaults (`release-type: simple`)
  and infers the next version from the existing tag sequence. **Recommendation:**
  continue that sequence rather than resetting to `v1.0.0` — it's what the
  tooling already does with zero configuration, and a reset would make old
  and new tags ambiguous in a fork that shares commit ancestry with upstream.
- There is currently no separate beta/stable tag convention (no `-beta`
  pre-release suffixes). Until MeowDisplay has its own beta channel, "beta"
  refers to the *distribution* stage (TestFlight external testing, or an
  unlisted GitHub Release) of an ordinary `vX.Y.Z` build, not a distinct
  version format.

## Release checklist

1. Merge normal Conventional Commit PRs to `main` (`feat:`, `fix:`, etc.).
2. `release-please` opens/updates a release PR with the generated
   `CHANGELOG.md` entry.
3. Merge the release PR. This creates the `vX.Y.Z` tag and triggers
   `release.yml`'s `build-mac` and `build-ios` jobs (guarded on
   `release_created == 'true'`).
4. CI builds, signs, and notarizes both Mac apps (`build_release`,
   `build_receiver_release`), packages them as DMGs, and uploads
   `MeowDisplay.dmg` / `MeowDisplayReceiver.dmg` to the GitHub Release for
   that tag via `gh release upload`.
5. CI builds and uploads the iOS app to TestFlight (`fastlane ios beta`,
   `skip_waiting_for_build_processing: true`).
6. If `SPARKLE_PRIVATE_KEY` is configured, CI regenerates `appcast.xml` /
   `appcast-receiver.xml` from the new DMGs and commits them to `public/` on
   `main`, then dispatches `pages.yml` to redeploy. This is currently a
   no-op (see [Sparkle status](#sparkle-auto-update-status) below).
7. Manually verify the release (see [Verification](#verification)) before
   treating it as ready for wider distribution.

## Required secrets

None are currently configured on this fork. Exact inventory (see the
release-audit issue for the full table): `DEVELOPMENT_TEAM`,
`MATCH_GIT_URL`, `MATCH_DEPLOY_KEY`, `MATCH_PASSWORD`,
`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
`APP_STORE_CONNECT_KEY_CONTENT`, and optionally `SPARKLE_PRIVATE_KEY`.

## Verification

Once a release build exists:

- `codesign --verify --deep --strict MeowDisplay.app`
- `spctl -a -vv MeowDisplay.dmg` (Gatekeeper assessment — should say "accepted")
- Mount the DMG and launch the app on a non-development Mac account.
- For iOS, confirm the TestFlight build processes and installs without a
  manual profile.

## Rollback / recovery

- A GitHub Release is just tagged, uploaded artifacts — a bad release can be
  marked as a pre-release/draft or deleted from the Releases page without
  affecting `main` or the tag history.
- Because Sparkle auto-update is currently disabled client-side (no
  `SUFeedURL`/`SUPublicEDKey` in `project.yml`), a bad DMG upload does not
  propagate to existing installs — there is nothing consuming the appcast
  yet. Once Sparkle is enabled, rollback will additionally require
  correcting or removing the bad entry from `public/appcast.xml`.
- A bad TestFlight build can be expired/removed from App Store Connect;
  external testers already on it will stop receiving prompts for it once a
  newer build is available.

## Sparkle auto-update status

Disabled intentionally: `project.yml` has `SUEnableAutomaticChecks: false`
and no feed URL/public key, because MeowDisplay does not yet have its own
hosted appcast domain or signing key pair (must not reuse upstream
OpenDisplay's). Re-enable by generating a fresh MeowDisplay-owned Sparkle
key pair, adding `SUFeedURL`/`SUPublicEDKey` to `project.yml`, and setting
the `SPARKLE_PRIVATE_KEY` CI secret.
