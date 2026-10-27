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
  `release/app-store-rc`. Two manual workflows, both run only from that
  branch: **Release PR** (`release-pr.yml`) opens or updates the release
  PR and never tags or releases; **Release** (`release.yml`), run after
  that PR is merged, builds, verifies and publishes (see
  [Release workflow](#release-workflow-fail-closed)).
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
  setup. `release-please-config.json` (`release-type: simple`) and
  `.release-please-manifest.json` pin the last release, `1.20.0`, so
  release-please no longer infers it from upstream's tags. The config's
  `release-as: 2.0.0` makes the next release PR propose 2.0.0 rather than
  1.21.0; **delete `release-as` in the release PR's follow-up**, or every
  later release PR proposes 2.0.0 again. The tag sequence continues from
  upstream's (no reset to `v1.0.0`), because a reset would make old and
  new tags ambiguous in a fork that shares commit ancestry with upstream.
- There is currently no separate beta/stable tag convention (no `-beta`
  pre-release suffixes). Until MeowDisplay has its own beta channel, "beta"
  refers to the *distribution* stage (optional TestFlight testing, or an
  unlisted GitHub Release) of an ordinary `vX.Y.Z` build, not a distinct
  version format.

## Fastlane lanes

| Lane | Purpose |
|---|---|
| `mac build_release` | Developer ID-signed, notarized Mac sender DMG (runs the three stages below) |
| `mac build_receiver_release` | Same, for the standalone Mac Receiver |
| `mac sign_app app:<sender\|receiver>` | Stage 1: build and Developer ID-sign the .app |
| `mac notarize_app app:<sender\|receiver>` | Stage 2: notarize and staple that .app |
| `mac package_dmg app:<sender\|receiver>` | Stage 3: signed, notarized, stapled DMG |
| `ios release` | App Store release candidate: builds and uploads the binary to App Store Connect. Skips metadata and screenshots, does **not** submit for review, does **not** release |
| `ios beta` | **Optional** TestFlight upload for beta testing. Not required for a release |

App Store metadata and screenshots are maintained by hand in App Store
Connect; the stored copy and checklist live in
[`fastlane/APP_STORE_LISTING.md`](fastlane/APP_STORE_LISTING.md).

## Release checklist

The iOS build goes to App Review **before** the public Mac/GitHub release, so
the two can go live together.

1. Merge normal Conventional Commit PRs to `release/app-store-rc` (`feat:`,
   `fix:`, etc.).
2. Run **Release dry run** (`release-dry-run.yml`) with the coming build
   number. It must pass: both release environments protected, secrets
   present, Sparkle-key continuity with the published v1.20.0 apps, build
   number above the live feeds, Developer ID certificate in match.
3. Run **Release PR** from `release/app-store-rc`. `release-please` opens or
   updates the release PR with the generated `CHANGELOG.md` entry; its title
   gives the next version. It runs with the release GitHub App's token, so
   the required `mac` and `conventional` checks run on that PR like on any
   other.
4. Run **iOS App Store candidate** (`app-store-candidate.yml`) from the
   Actions tab: select the release PR's branch, enter that version (e.g.
   `1.20.0`), destination `app-store`. This runs `fastlane ios release`.
   (Destination `testflight` runs the optional `ios beta` lane instead.)
5. In App Store Connect: wait for the build to process, inspect it, complete
   the fields in `APP_STORE_LISTING.md`'s checklist, choose **Manually release
   this version**, and submit for review by hand.
6. When Apple approves, the version waits in **Pending Developer Release**.
7. Merge the release PR, then run **Release** from `release/app-store-rc`
   with that version. It builds, signs, notarizes, packages and verifies
   both Mac apps and signs and verifies both feeds without touching any
   release. Then its `publish` job waits for **your approval**
   (`release-publish` environment), creates a draft, verifies it, and makes
   it Latest. See [Release workflow](#release-workflow-fail-closed).
8. Verify the Mac release (see [Verification](#verification)), then release
   the iOS version manually in App Store Connect.

If App Review rejects the build, fix it on `release/app-store-rc`, run
**Release PR** again so release-please updates the PR, and upload a new
candidate with the same version (a new run gives it a higher build number).

## Release workflow (fail-closed)

The apps' feed URLs (`https://meowdisplay.app/appcast.xml` and
`/appcast-receiver.xml`) are Cloudflare redirects to
`releases/latest/download/<feed>`. **Whatever GitHub Release is Latest is
the live update feed**, and a Latest release without its feeds breaks
updates for every installed copy. `release.yml` therefore runs one job per
stage and touches no release, tag or asset until the last one:

| Job | Does | Secrets |
| --- | --- | --- |
| `plan` | Refuses any branch but `release/app-store-rc`. Checks the version input against `version.txt`, the manifest and `CHANGELOG.md`, and that tag and release `v<version>` don't exist. Checks build-number ordering: the Mac build number (= the version) must be above every build the live feeds offer. Records the current Latest. | none |
| `key-continuity` | Downloads the **published v1.20.0 DMGs** (sha256 pinned in `scripts/release/baseline.env`) and reads the key the installed apps ship. Requires that `project.yml` ships the same key and that the secret signs for it (`check-sparkle-key.sh`). | release-build |
| `sign` → `notarize` → `package` | Fastlane stages `sign_app`, `notarize_app`, `package_dmg` per app, each a separate job with only the credentials it needs. | release-build |
| `verify-artifacts` | Each DMG checked against the published baseline (`verify-mac-artifact.sh`): signed, notarized and stapled DMG and app; Developer ID on every Mach-O; planned version and build; the published app's designated requirement and exact entitlements (TCC, Keychain and Sparkle continuity); published key; live feed URL. | none |
| `sign-feeds` | generate_appcast for the verified DMGs; key on stdin. | release-build |
| `verify-feeds` | Both feeds and DMGs verified against the **published** key, the way Sparkle 2.10.0 does (`verify-feed.sh`): exact enclosure URL, version, build, length, one item. | none |
| `publish` | After **approval**: re-checks that the downloaded files are byte-identical to the verified ones and that nothing was published meanwhile. Creates a **draft** with both DMGs, both feeds and `SHA256SUMS.txt`, downloads the draft's assets back and compares them byte for byte, then publishes as **Latest**. Then confirms both live feed URLs serve the new feeds. If they don't within 5 minutes, it makes the previous release Latest again and returns the new one to draft. Relabels the release PR `autorelease: tagged`. | none |

A failure anywhere before `publish` leaves the previous release live and
nothing behind except workflow artifacts (kept 3 days).
`scripts/release/check-release-workflows.rb` (run by **Tests**) fails if any
of these rules is broken.

**One-time setup** (all repository-admin actions; nothing here is applied by
the workflows):

- **GitHub App for release PRs.** This repository doesn't let Actions create
  pull requests, and PRs opened with `GITHUB_TOKEN` start no workflows, so
  the required checks would never report. Create a GitHub App owned by the
  repository owner with Contents, Pull requests and Issues set to
  read & write, and install it on this repository only. Store its client ID
  as the variable `RELEASE_APP_CLIENT_ID` and a private key as the secret
  `RELEASE_APP_PRIVATE_KEY`.
- **Environments**, each with a custom deployment-branch policy allowing only
  `release/app-store-rc`. Jobs check this at run time and stop if it's
  missing, because a job that names a missing environment gets a new,
  unprotected one:
  - `release-build`: holds `DEVELOPMENT_TEAM`, `MATCH_GIT_URL`,
    `MATCH_DEPLOY_KEY`, `MATCH_PASSWORD`, the three
    `APP_STORE_CONNECT_*` and `SPARKLE_PRIVATE_KEY`. Then delete the
    repository-level copies, so no other workflow or branch can read them.
  - `release-publish`: no secrets; **required reviewers** (you). This is
    the explicit approval in front of every production release action.
- **Default branch.** GitHub dispatches a workflow only if its file exists on
  the default branch (`dev/opendisplay-next`), and shows the "Run workflow"
  button only if that copy has `workflow_dispatch`. Land identical copies of
  `release-pr.yml`, `release.yml` and `release-dry-run.yml` there by PR. Their
  branch guard makes a run from the default branch fail immediately. Then
  dispatch with `gh workflow run <file> --ref release/app-store-rc`.
- **`main`** still carries upstream's push-triggered `release.yml` and
  `pages.yml`; replace them with these files or no-op stubs by PR.

Never mark a release Latest by hand before both DMGs and both signed feeds
are attached and verified. The manual path below follows the same order.

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
  with `CURRENT_PROJECT_VERSION` set to the marketing version (`1.20.0`;
  1.20.0 itself actually shipped with build `1`, so every later release
  must use its marketing version, e.g. `2.0.0`, or Sparkle offers it to
  nobody; `scripts/release/check-build-number.sh <build>
  https://meowdisplay.app/appcast.xml` checks this before you publish),
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

  Then publish in the same fail-closed order as CI:
  1. Verify each DMG with `scripts/release/verify-mac-artifact.sh` against
     `scripts/release/published-baseline.sh` output, and each feed with
     `scripts/release/verify-feed.sh` against the published key.
  2. `gh release create v<version> --draft` with both DMGs, both feeds and
     `SHA256SUMS.txt`.
  3. Download the draft's assets back and compare them byte for byte.
  4. `gh release edit v<version> --draft=false --latest`.
  5. Check that both `https://meowdisplay.app/` feed URLs serve the new
     feeds; if they don't, make the previous release Latest again.

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

Also missing before CI can release:

- **A Developer ID Application certificate in match.** The team's current
  Developer ID certificate is cloud-managed (it signed 1.20.0 through
  Xcode) and can't be exported. The Account Holder creates an exportable
  one with `fastlane match developer_id`. TCC permissions and Sparkle
  accept a new certificate from the same team, as long as the Sparkle key
  doesn't change in the same release. The cloud-managed certificate
  expires **2027-02-01**; after that, Xcode's manual path needs a new one
  too.
- **Proof that `SPARKLE_PRIVATE_KEY` is the shipped key.** Run **Release
  dry run** once (it must be on the default branch before GitHub can
  dispatch it). It signs a random probe with the secret and verifies it
  against the key in the published v1.20.0 apps, printing pass or fail only.
- **The release App and environments** described under
  [Release workflow](#release-workflow-fail-closed).
- **Branch protection.** `.github/rulesets/release-app-store-rc.json`
  protects `release/app-store-rc` (no deletion or force-push, PR required,
  Tests `mac` and PR title `conventional` must pass).
  `scripts/release/apply-rulesets.sh` shows what it would create and which
  existing rulesets' empty required-checks lists it would fill; it changes
  nothing until it's run with `--apply` by a repository admin.

## Verification

Once a release build exists:

- `codesign --verify --deep --strict MeowDisplay.app`
- `spctl -a -vv MeowDisplay.dmg` (Gatekeeper assessment — should say "accepted")
- `scripts/release/verify-feed.sh <feed> <dmg> <published key> <version>
  <build> <enclosure URL>` for each feed. It checks both signatures against
  the key the installed apps ship. (`sign_update --verify` checks against the
  key it is given, so a wrong key still "verifies".)
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
