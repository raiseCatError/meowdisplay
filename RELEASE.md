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
- **Build number** (`CFBundleVersion`):
  - **Mac:** the marketing version itself (`1.20.0`). Sparkle decides
    whether an update is newer by comparing `CFBundleVersion`, so it must
    grow with every release. `release.yml`'s run number can't guarantee
    that, because it restarts at 1 on this fork and 1.20.0 was built by hand.
  - **iOS:** the run number (`github.run_number`) of
    `app-store-candidate.yml`, the only workflow that builds iOS, so App
    Store Connect builds stay distinct across re-runs.
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
7. The same job signs `appcast.xml` / `appcast-receiver.xml` for the new
   DMGs with `SPARKLE_PRIVATE_KEY`, verifies them with Sparkle's
   `sign_update`, and uploads them to the same GitHub Release. The feeds
   are live as soon as that release is GitHub's latest release (see
   [Sparkle auto-update](#sparkle-auto-update)).
8. Verify the Mac release (see [Verification](#verification)), then release
   the iOS version manually in App Store Connect.

If App Review rejects the build, fix it on `main`, let release-please update
the PR, and upload a new candidate with the same version (a new run gives it
a higher build number).

## First release without CI secrets (manual path)

Not all of the secrets below exist yet, so the first release can be built
locally instead of by the workflows:

- **Version.** The inherited tag sequence ends at `v1.19.0` and the open
  release-please PR proposes **1.20.0**, so the first release is 1.20.0.
  Build it with `MARKETING_VERSION=1.20.0` and a `CURRENT_PROJECT_VERSION`
  higher than any build already uploaded for that version.
- **iOS.** Generate the project with `DEVELOPMENT_TEAM` set, archive the
  `OpenSidecariOS` scheme in Release, then upload from Xcode Organizer →
  Distribute App → App Store Connect. A later `app-store-candidate.yml` run
  numbers its builds from its own run counter, so give a manual upload a
  build number above the run numbers that workflow will reach for the same
  version (or re-upload under a new version).
- **Mac.** Archive `OpenSidecarMac` and `OpenSidecarMacReceiver` in Release
  with `CURRENT_PROJECT_VERSION` set to the marketing version (`1.20.0`),
  export each with Developer ID, notarize (`xcrun notarytool submit …
  --wait`), staple, and package as `MeowDisplay.dmg` /
  `MeowDisplayReceiver.dmg` as `fastlane mac build_release` would. Then
  generate the feeds from the maintainer's Keychain key, one directory per
  app (see [Sparkle auto-update](#sparkle-auto-update)):

  ```sh
  generate_appcast --account meowdisplay \
    --download-url-prefix https://github.com/raiseCatError/meowdisplay/releases/download/v1.20.0/ \
    --link https://meowdisplay.app/ -o <dir>/appcast.xml <dir>
  ```

  Upload both DMGs and both feeds to the GitHub Release, just as CI does.

Values still to fill in before or at release:

- [x] `AppStore.iOSAppID` in `Shared/AppStore.swift` — `6817552864`, the
      app's Apple ID from App Store Connect.
- [ ] `ProjectLinks.koFiPage` in `Shared/ProjectLinks.swift` — the Ko-fi page
      URL, once it exists (deferred past 1.20.0). Until then no app shows a support link. Add the
      same URL to the README's Contributing section and `SUPPORT.md` then.

## Required secrets

Exact inventory (see the release-audit issue for the full table):
`DEVELOPMENT_TEAM`, `MATCH_GIT_URL`, `MATCH_DEPLOY_KEY`, `MATCH_PASSWORD`,
`APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`,
`APP_STORE_CONNECT_KEY_CONTENT`, and `SPARKLE_PRIVATE_KEY`. The Mac
release job fails without `SPARKLE_PRIVATE_KEY`, because unsigned feeds
would leave installed apps without the update.

Configured on this fork: `DEVELOPMENT_TEAM`, `MATCH_GIT_URL`,
`MATCH_DEPLOY_KEY`, `SPARKLE_PRIVATE_KEY`. Still missing: `MATCH_PASSWORD`
and the three `APP_STORE_CONNECT_*` secrets, so CI cannot yet build a
release by itself.

## Verification

Once a release build exists:

- `codesign --verify --deep --strict MeowDisplay.app`
- `spctl -a -vv MeowDisplay.dmg` (Gatekeeper assessment — should say "accepted")
- `sign_update --account meowdisplay --verify appcast.xml` (and
  `appcast-receiver.xml`): the feed's embedded signature is valid.
  `sign_update --account meowdisplay --verify MeowDisplay.dmg <edSignature>`
  with the enclosure's `sparkle:edSignature`: the DMG is the one the feed
  signed.
- Once the release is published: `https://meowdisplay.app/appcast.xml` and
  `/appcast-receiver.xml` serve those same files, and **Check for
  Updates…** in the previous version finds the new one.
- Mount the DMG and launch the app on a non-development Mac account.
- For iOS, confirm the build processes in App Store Connect and shows the
  expected version and build number before submitting it for review. The
  archive must contain `PrivacyInfo.xcprivacy` at the app bundle's root
  (Xcode Organizer → Generate Privacy Report lists it); App Store Connect
  does not accept a build that uses a required-reason API no manifest
  declares.

## Rollback / recovery

- A GitHub Release is just tagged, uploaded artifacts — a bad release can be
  marked as a pre-release/draft or deleted from the Releases page without
  affecting `main` or the tag history.
- A bad Mac release reaches existing installs through Sparkle. To stop it
  spreading, delete that release's `appcast.xml` / `appcast-receiver.xml`
  assets, or mark the release as a draft or pre-release so that
  `releases/latest` moves back to the previous release and its feeds.
  Sparkle never downgrades, so anyone already updated needs a fixed, higher
  version. Never hand-edit a published feed: it is signed, and the apps
  reject an edited copy. Regenerate it with `generate_appcast` instead.
- An iOS version still in review can be withdrawn from App Store Connect.
  A released App Store version cannot be pulled back to an earlier build;
  ship a fixed version instead, or remove the app from sale if needed.
- A bad TestFlight build can be expired in App Store Connect.

## Sparkle auto-update

Both direct-distribution Mac apps update through Sparkle, starting with
1.20.0. The iOS app does not include Sparkle. `SparkleConfigurationTests`
pins the configuration below.

**Configuration** (`project.yml`, Mac targets' `info.properties`):

| | MeowDisplay | MeowDisplay Receiver |
|---|---|---|
| `SUFeedURL` | `https://meowdisplay.app/appcast.xml` | `https://meowdisplay.app/appcast-receiver.xml` |
| `SUPublicEDKey` | `M9Je3RXE9GYGv7ZvVmJj2xK2FrpSR/rQvbuZFfYORcU=` | same key |

- `SUVerifyUpdateBeforeExtraction` and `SURequireSignedFeed` are on. Sparkle
  checks the DMG's EdDSA signature before extracting it, and ignores any
  feed or release notes not signed with the MeowDisplay key.
- `SUEnableAutomaticChecks` is left unset on purpose. Sparkle then asks on
  the second launch whether to check automatically, and nothing runs in the
  background until the user agrees. Automatic installation
  (`SUAutomaticallyUpdate`) stays off unless the user turns it on in that
  prompt. **Check for Updates…** (Settings → System → Updates, and the
  Receiver's app menu) always works.
- Never point either app at upstream OpenDisplay's feeds or key.

**Signing key.** An Ed25519 key made with Sparkle 2.10.0's `generate_keys`
for MeowDisplay only. It is not upstream OpenDisplay's key.

- The private key lives in the maintainer's login Keychain under
  `generate_keys`' `--account meowdisplay` (the Keychain item is "Private
  key for signing Sparkle updates"). The same key is stored in the
  `SPARKLE_PRIVATE_KEY` Actions secret. The private key is never committed
  or printed.
- GitHub secrets can't be read back, so keep an offline backup:
  `generate_keys --account meowdisplay -x <file>`, stored in a password
  manager, with the file deleted afterwards. On another Mac,
  `generate_keys --account meowdisplay -f <file>` imports it.
- To confirm which public key the Keychain holds:
  `generate_keys --account meowdisplay -p`.

**Feed hosting.** CI uploads each release's signed feeds as assets of the
GitHub Release. Their enclosures point at that tag's immutable
`releases/download/vX.Y.Z/*.dmg` URLs. On Cloudflare, meowdisplay.app
redirects (302) each feed to the latest release's copy:

- `/appcast.xml` → `https://github.com/raiseCatError/meowdisplay/releases/latest/download/appcast.xml`
- `/appcast-receiver.xml` → `https://github.com/raiseCatError/meowdisplay/releases/latest/download/appcast-receiver.xml`

So a feed goes live together with its release, and no website deploy is
involved. Sparkle follows HTTPS redirects, and the feed's own signature
protects it, not the hosting. A release without feed assets (drafts and
pre-releases are never "latest") makes the feeds 404 until the next full
release. Installed apps then find no update and do not break.

**Key rotation.** Change only when necessary, such as a lost or leaked key.
Because updates are Developer ID-signed DMGs, Sparkle accepts an update that
changes *either* the EdDSA key *or* the Developer ID certificate, but never
both at once. Ship an update signed with the old key whose app carries the
new `SUPublicEDKey`, then switch `SPARKLE_PRIVATE_KEY`. If the old private
key is lost, installed apps reject feeds signed with the new key until
`SUSignedFeedFailureExpirationInterval` (20 days by default) passes. After
that, Sparkle accepts the feed without signature validation but strips its
release notes and links.
