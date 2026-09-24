# Release process

This documents how a MeowDisplay release actually gets built and published,
as implemented in `.github/workflows/release.yml`,
`.github/workflows/app-store-candidate.yml`, and `fastlane/Fastfile`.
It reflects what was verified while auditing the pipeline (see the
release-preparation GitHub issues) — not aspirational process.

## Versioning

- **Marketing version** (`CFBundleShortVersionString`, e.g. `1.20.0`) comes
  from [`release-please`](https://github.com/googleapis/release-please-action),
  which derives the next version from
  [Conventional Commits](https://www.conventionalcommits.org/) merged to
  `main` and opens a release PR. Merging that PR creates the `vX.Y.Z` tag
  that triggers the Mac build jobs.
- **Build number** (`CFBundleVersion`) is the GitHub Actions run number
  (`github.run_number`) of the workflow that built it — monotonically
  increasing within that workflow. iOS builds come only from
  `app-store-candidate.yml`, so App Store Connect builds stay distinct across
  re-runs.
- Both numbers are injected into `xcodebuild` via `xcargs` in
  `fastlane/Fastfile`'s `version_xcargs` helper; `project.yml` only defines
  placeholder defaults (`0.0.0` / `1`) for local, non-release builds.
- The Mac sender and Mac Receiver build from the **same tag and the same
  run**. The iOS app is built separately with the same marketing version
  (passed as the workflow input), so versions stay in lockstep; iOS build
  numbers differ from the Mac ones.
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
  refers to the *distribution* stage (optional TestFlight testing, or an
  unlisted GitHub Release) of an ordinary `vX.Y.Z` build, not a distinct
  version format.

## Fastlane lanes

| Lane | Purpose |
|---|---|
| `mac build_release` | Developer ID-signed, notarized Mac sender DMG |
| `mac build_receiver_release` | Same, for the standalone Mac Receiver |
| `ios release` | App Store release candidate: builds and uploads the binary to App Store Connect. Skips metadata and screenshots, does **not** submit for review, does **not** release |
| `ios beta` | **Optional** TestFlight upload for beta testing. Not required for a release |

App Store metadata and screenshots are maintained by hand in App Store
Connect; the stored copy and checklist live in
[`fastlane/APP_STORE_LISTING.md`](fastlane/APP_STORE_LISTING.md).

## Release checklist

The iOS build goes to App Review **before** the public Mac/GitHub release, so
the two can go live together.

1. Merge normal Conventional Commit PRs to `main` (`feat:`, `fix:`, etc.).
2. `release-please` opens/updates a release PR with the generated
   `CHANGELOG.md` entry. Its title gives the next version.
3. Run **iOS App Store candidate** (`app-store-candidate.yml`) from the
   Actions tab: select the release PR's branch, enter that version (e.g.
   `1.20.0`), destination `app-store`. This runs `fastlane ios release`.
   (Destination `testflight` runs the optional `ios beta` lane instead.)
4. In App Store Connect: wait for the build to process, inspect it, complete
   the fields in `APP_STORE_LISTING.md`'s checklist, choose **Manually release
   this version**, and submit for review by hand.
5. When Apple approves, the version waits in **Pending Developer Release**.
6. Merge the release PR. This creates the `vX.Y.Z` tag and runs
   `release.yml`'s `build-mac` job (guarded on `release_created == 'true'`):
   both Mac apps are built, signed, notarized, packaged as DMGs, and uploaded
   to the GitHub Release (`MeowDisplay.dmg`, `MeowDisplayReceiver.dmg`).
7. If `SPARKLE_PRIVATE_KEY` is configured, CI regenerates `appcast.xml` /
   `appcast-receiver.xml` from the new DMGs and commits them to `public/` on
   `main`, then dispatches `pages.yml` to redeploy. This is currently a
   no-op (see [Sparkle status](#sparkle-auto-update-status) below).
8. Verify the Mac release (see [Verification](#verification)), then release
   the iOS version manually in App Store Connect.

If App Review rejects the build, fix it on `main`, let release-please update
the PR, and upload a new candidate with the same version (a new run gives it
a higher build number).

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
- For iOS, confirm the build processes in App Store Connect and shows the
  expected version and build number before submitting it for review.

## Rollback / recovery

- A GitHub Release is just tagged, uploaded artifacts — a bad release can be
  marked as a pre-release/draft or deleted from the Releases page without
  affecting `main` or the tag history.
- Because Sparkle auto-update is currently disabled client-side (no
  `SUFeedURL`/`SUPublicEDKey` in `project.yml`), a bad DMG upload does not
  propagate to existing installs — there is nothing consuming the appcast
  yet. Once Sparkle is enabled, rollback will additionally require
  correcting or removing the bad entry from `public/appcast.xml`.
- An iOS version still in review can be withdrawn from App Store Connect.
  A released App Store version cannot be pulled back to an earlier build;
  ship a fixed version instead, or remove the app from sale if needed.
- A bad TestFlight build can be expired in App Store Connect.

## Sparkle auto-update status

Disabled intentionally: `project.yml` has `SUEnableAutomaticChecks: false`
and no feed URL/public key, because MeowDisplay does not yet have its own
hosted appcast domain or signing key pair (must not reuse upstream
OpenDisplay's). Re-enable by generating a fresh MeowDisplay-owned Sparkle
key pair, adding `SUFeedURL`/`SUPublicEDKey` to `project.yml`, and setting
the `SPARKLE_PRIVATE_KEY` CI secret.
