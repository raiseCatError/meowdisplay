# Release process

How MeowDisplay releases are built, reviewed and published, as implemented
in `.github/workflows/release-*.yml`, `scripts/release/` and
`fastlane/Fastfile`. Branches and the repository migration are in
[BRANCHING.md](BRANCHING.md); the OpenDisplay reference in
[REFERENCE.md](REFERENCE.md).

## One release branch, four products

`release/<version>` (for example `release/2.0.0`) is the single source of
every platform's release candidate:

| Product | Built by | Distributed through |
| --- | --- | --- |
| MeowDisplay for Mac (Sender and Receiver) | `release-mac.yml` | GitHub Release (DMG) + Sparkle `appcast.xml` |
| MeowDisplay Receiver for Mac (macOS 12+) | `release-mac.yml` | GitHub Release (DMG) + Sparkle `appcast-receiver.xml` |
| MeowDisplay for iPhone and iPad | `release-ios.yml` | App Store Connect → App Store |
| MeowDisplay for Android | `release-android.yml` | Google Play |

```
push to release/2.0.0 ──► release-candidate.yml ── candidate = that commit
                              ├─ release-mac.yml      build · sign · notarize · DMG · verify · signed feeds   (staged)
                              ├─ release-ios.yml      build · sign · upload to App Store Connect            (uploaded)
                              └─ release-android.yml  test · sign · upload to internal testing              (uploaded)
release-monitor.yml (every 30 min) ── submit processed builds · follow App Review and Play review
                                       └─ gate open? ── manual mode: waits for your approval
                                                        auto mode:   starts release-publish.yml
release-publish.yml ── [your approval] gate · Mac release (draft→verify→Latest→live, auto-revert)
                       ── stores: release iOS · Android (Play Console Publish click under managed publishing)
                       ── website: release.json on meowdisplay.app (only what is live)
                       ── PR of the released source into main
```

**Versions.** One marketing version for every product (`version.txt`, set
by the release PR). Build identifiers stay independent and only grow:

- **Mac:** `CFBundleVersion` = the marketing version (`2.0.0`). Sparkle compares it; 1.20.0 shipped as `1`, and the candidate refuses a build number not above every live feed's.
- **iOS:** one above every build App Store Connect has for this version (`fastlane ios upload_candidate`), so re-runs never collide.
- **Android:** `versionCode` = major×1,000,000 + minor×10,000 + patch×100 + build (1–99), above everything Google Play has (`meow-release next-build android`).

**Release state.** Every release has one record, `releases/<version>.json`
on the `release-state` branch, keyed by the candidate commit
(`scripts/release/lib/meow_release/state.rb`). Each platform moves through
**Built and tested → Signed → Uploaded → Submitted → Under review →
Approved / ready → Published**, or aside to **Blocked**, **Rejected** or
**Failed**. Only **Published** means users can install it. A newer push to
the release branch supersedes the candidate: everything recorded for the
older commit stops counting, and a publication can never use it. Every
release workflow ends with the readiness report (Actions job summary):
each platform's stage, build, source commit, checksums, store status,
blockers and what is waiting on a person.

## What is automatic and what needs you

| Step | Automatic | Needs a person |
| --- | --- | --- |
| Release PR (version.txt, CHANGELOG) | `release-pr.yml` opens/updates it | Merge it (that push builds the candidate) |
| Build, sign, notarize, package, verify all four products | ✔ on every push | — |
| Upload to App Store Connect / Google Play internal testing | ✔ | — |
| Submit iOS for review | ✔ once the build is processed and App Store Connect accepts the submission (`ios.submitForReview`) | Missing metadata or screenshots: App Store Connect's own message becomes a blocker |
| Send Android to review | ✔ to the review track (`android.reviewTrack`) | — |
| Follow review | ✔ App Store Connect `appStoreState`; Play `tracks.releases.list` lifecycle | Reply to App Review / Play policy questions |
| Rejection | Recorded with the store's reason; the gate stays closed | Fix, merge to the release branch (a new candidate) |
| Start publication | Auto mode only (both switches) | **Manual mode (default): approve `release-publish`** |
| Mac release, live feed check, revert | ✔ | — |
| Release iOS (manual release control) | ✔ | — |
| Publish Android under managed publishing | — | **Press Publish in Play Console** (no API exists); the monitor records it |
| Website (`release.json`) | ✔ through the website's own PR and deploy | — |
| Record the release in `main` | ✔ opens the PR (auto-merge if `RELEASE_AUTO_PROMOTE`) | Merge it otherwise |

**Publish modes** (`publishMode` in `.github/release-config.json`):
- `manual-final-approval` (default): the monitor reports "Ready to publish"; publication starts when you approve the `release-publish` environment's deployment.
- `auto-publish-after-approval` (future opt-in): needs **both** that config value on the release branch **and** the repository variable `RELEASE_PUBLISH_MODE=auto-publish-after-approval`; then the monitor starts publication once every required platform is approved for the branch head. Either switch alone keeps the approval.

**What the release requires** (`requiredPlatforms`, `crossPlatformReady`):
Mac and iOS always; Android once `crossPlatformReady` is `true`. Until then
an Android candidate is built, uploaded and reported, but doesn't hold the
release.

## The publication gate

`release-publish.yml` starts only when every required platform is
**Approved** for the exact commit the release branch points at. Then, in
the order that keeps every failure recoverable
(`scripts/release/lib/meow_release/publisher.rb`):

1. **Mac.** The verified DMGs and feeds of the candidate run (checksums re-checked) become a **draft** release with `SHA256SUMS.txt`; the draft's assets are downloaded back and compared byte for byte; then it becomes **Latest**; then both live feed URLs must serve the new feeds within 5 minutes, or Latest is reverted to the previous release automatically. Whatever release is Latest IS the live Sparkle feed (`meowdisplay.app/appcast*.xml` redirect to `releases/latest/download/…`), so no incomplete release is ever Latest. Nothing irreversible has happened before this step ends.
2. **Stores.** The approved iOS version is released (it waits in Pending Developer Release). Android: Play holds an approved release (`APPROVED_NOT_PUBLISHED`) until Publish is pressed in Play Console; the monitor sees `PUBLISHED`.
3. **Website.** `release.json` lists only platforms that are live, and is published through the website repository's own pull request and Cloudflare Pages deploy; the step waits until meowdisplay.app serves it.
4. **main.** A PR of `release/<version>` into `main` (merge commit, so main's tree equals the tag's).

A run that stops part way is resumed (`resume`, by the monitor) without
repeating finished steps; resuming never starts a publication. **A resume
needs the same final approval as the first run** (the `release-publish`
environment, always with its required reviewer: `authorize-resume`) and
then re-derives everything live before any store version is released
(`verify-resume`): the publication in progress is for this commit, the
GitHub Release `v<version>` is published, Latest, tagged at this commit and
carries exactly the recorded artifact hashes, a `publish-mac` job of this
workflow succeeded for this commit, and the stores confirm approval of the
recorded builds (`meow-release verify-live`).

**The release state is not evidence.** Without a dedicated writer, any
workflow holding `contents: write` could write the `release-state` branch
(its ruleset therefore stays closed until the owner's release App is its
only bypass; BRANCHING.md), so publication re-derives every fact
that matters from its source before anything becomes public:
`verify-stores` observes App Store Connect and Google Play live and
requires each store to confirm approval of exactly the recorded build
(`verify-live`; a recorded approval a store doesn't confirm fails); the Mac artifacts must come from the `release-candidate.yml`
run for exactly this commit on this branch, whose Mac verification
succeeded, and are verified again (signatures, notarization, identity,
feeds against the published key) before the draft is created.

## Stores

**App Store Connect.** The build uploads with `fastlane ios upload_candidate`
(no submission). The monitor attaches it to the App Store version and submits it through
`reviewSubmissions` once processing is `VALID`; processing finished is
never treated as approval. **Before every submission the version is set to
manual release** (`releaseType: MANUAL`, no earliest release date; created
that way if missing) and read back; if App Store Connect doesn't end up
manual, nothing is submitted and the platform is blocked. Approval =
`PENDING_DEVELOPER_RELEASE` (or `ACCEPTED` in `appVersionState`) **under
manual release with the candidate's build attached**; anything else
(automatic or scheduled release, another build) blocks the gate.
`PENDING_APPLE_RELEASE` is Apple's hold until the OS version a build needs
is released: reported as a hold, never as approval. Release = an
`appStoreVersionReleaseRequests` call from the publish workflow, which
checks the same conditions again. A newer
candidate's build replaces an older one still in review (the older
submission is cancelled first). Metadata and screenshots stay maintained in
App Store Connect ([`fastlane/APP_STORE_LISTING.md`](fastlane/APP_STORE_LISTING.md)).

**Google Play.** The bundle uploads to the internal track as its own
committed edit. The monitor puts the build on the review track
(`android.reviewTrack`: `internal` or a closed testing track such as
`alpha`; there is no default) and commits with `changesInReviewBehavior=ERROR_IF_IN_REVIEW`, so nothing in
review is ever cancelled by accident; replacing a superseded candidate's
release uses `CANCEL_IN_REVIEW_AND_SUBMIT` deliberately. Review is followed
through `GET applications/{package}/tracks/{track}/releases`
(`ReleaseSummary.releaseLifecycleState`):

| Play state | Release stage |
| --- | --- |
| `DRAFT`, `NOT_SENT_FOR_REVIEW` | Blocked (not sent for review) |
| `IN_REVIEW` | Under review |
| `APPROVED_NOT_PUBLISHED` | Approved / ready |
| `NOT_APPROVED` | Rejected |
| `PUBLISHED` | Published |

The list omits obsolete releases and returns at most 20 per track.

**Production is separately authorized.** The `production` track is refused
unless BOTH the release config names this exact version
(`android.productionRelease`) AND the operator's separate authorization
(`ANDROID_PRODUCTION_AUTHORIZED`, the same version) is present; no workflow
sets the latter today. A release on a testing track reaches testers only,
so it never counts as public: publication refuses Android on a testing
track. **Managed publishing is not a control here**: Google doesn't offer it
for an app's first publication, and the code never relies on it. For a
later production release it can still hold an approved release until
**Publish changes** in Play Console, which the monitor then records.

## Website

The release workflow never changes how meowdisplay.app is built. It writes
`release.json` (version, source commit, the stable `releases/latest/download`
URLs of both DMGs, store links of live platforms only) into the website
repository by pull request with auto-merge; the site's own checks and
Cloudflare Pages deploy run as always, and the step waits until
`https://meowdisplay.app/release.json` serves the new version.

**One-time website change (not made yet):** the website repository's
`scripts/package.py` must copy `release.json` into `dist/`, and its pages
should read version text and store links from it (the DMG links already
use the stable `latest/download` URLs, which switch with the GitHub
Release). Until that change lands, `update-website.sh` refuses and the
website step reports a blocker; nothing else is affected.

## Credentials

Every secret lives in one protected environment; jobs check the
environment's protection (`check-environment.sh`) before using a secret,
because a job naming a missing environment silently gets an unprotected one.
`Release dry run` reports what is missing, by name only.

`scripts/release/apply-environments.sh` creates and protects the seven
environments below (branch patterns, owner approval where marked, no admin
bypass) and then checks each one; it never touches secrets. It prints the plan
unless given `--apply`, and is safe to re-run.

| Environment (branches) | Secrets | Variables | Who creates them |
| --- | --- | --- | --- |
| `release-build` (`release/*`) | `DEVELOPMENT_TEAM`, `MATCH_GIT_URL`, `MATCH_DEPLOY_KEY`, `MATCH_PASSWORD`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_CONTENT` (notarization), `SPARKLE_PRIVATE_KEY` | — | Owner; a Developer ID certificate in match via `fastlane match developer_id` (Account Holder) |
| `ios-upload` (`release/*`) | `DEVELOPMENT_TEAM`, `MATCH_*`, `APP_STORE_CONNECT_*` | — | Owner (App Store Connect API key, App Manager role) |
| `android-upload` (`release/*`) | `PLAY_SERVICE_ACCOUNT_JSON`, `ANDROID_UPLOAD_KEYSTORE_BASE64`, `ANDROID_UPLOAD_STORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS`, `ANDROID_UPLOAD_KEY_PASSWORD` | `ANDROID_UPLOAD_CERT_SHA256` (the upload certificate registered with Play App Signing) | Owner (Play Console service account with release permissions; the upload key) |
| `release-stores` (default branch, `release/*`) | `APP_STORE_CONNECT_*`, `PLAY_SERVICE_ACCOUNT_JSON` | — | Owner |
| `release-publish` (`release/*`) | none | — | Owner adds themselves as **required reviewer** |
| `release-pr` (`release/*`) | `RELEASE_APP_PRIVATE_KEY` | `RELEASE_APP_CLIENT_ID` (repository) | Owner creates a GitHub App (Contents, Pull requests, Issues: read & write) installed on this repository only |
| `website-update` (`release/*`) | `WEBSITE_APP_PRIVATE_KEY` | `WEBSITE_APP_CLIENT_ID` (repository) | Owner creates a GitHub App installed on `MeowDisplayWebsite` only (Contents, Pull requests: read & write) |

Repository variables that switch automation on, each off until set:
`RELEASE_AUTOMATION=enabled` (monitor schedule), `RELEASE_PUBLISH_MODE`
(auto publication, with the config), `RELEASE_AUTO_PROMOTE=enabled` (merge
the main promotion PR automatically), `REFERENCE_SYNC=enabled`,
`REPOSITORY_GUARD=enabled`, `EXPECTED_DEFAULT_BRANCH`.

After moving the signing secrets into environments, delete the
repository-level copies (`DEVELOPMENT_TEAM`, `MATCH_DEPLOY_KEY`,
`MATCH_GIT_URL`, `SPARKLE_PRIVATE_KEY` exist there today), so no other
workflow or branch can read them. The Developer ID certificate that
signed 1.20.0 is cloud-managed and expires **2027-02-01**.

## Recovery: a partially completed launch

The release state shows exactly where a launch stopped. Re-running
`release-publish.yml` for the same candidate resumes; it never repeats a
finished step.

| Where it stopped | What users see | What to do |
| --- | --- | --- |
| Before or during the Mac step (draft not verified, feeds not live) | 1.x as before; Latest was reverted automatically | Read the job log, fix (assets, CDN), re-run publish. A leftover draft/tag `v<version>` must be removed by hand first (the gate refuses an existing tag). |
| After the Mac step, before stores | Mac users get the new version; phones keep the previous store version (compatible by protocol) | Re-run publish (resume): stores, website and promotion continue. |
| iOS release request failed | App Store still shows the previous version | Re-run publish, or press Release in App Store Connect; the monitor records it either way. |
| Android approved but not published | Play shows the previous version | Press **Publish changes** in Play Console; the monitor records it and resumes publication. |
| Website step failed | Site shows the previous version text; the stable DMG link already serves the new DMG | Fix the website PR or its checks; resume. |
| A store rejected the candidate | Nothing new is public (the gate never opened) | Fix on the release branch: the push is a new candidate; the old submission is replaced. |
| A bad version is live | — | Mac: make the previous release Latest (its feeds come back), then ship a fixed, higher version (Sparkle never downgrades). iOS: ship a fixed version (a release can't be pulled back; remove from sale if needed). Android: halt the rollout in Play Console, then ship a fixed versionCode. |

Never hand-edit a published feed: it is signed, and the apps reject an
edited copy.

## Release PR and versions

`release-pr.yml` (manual, from `release/<version>`) runs release-please
with the release App's token and `skip-github-release`: it opens or updates
the release PR (CHANGELOG, `version.txt`, `.release-please-manifest.json`)
and never tags or releases. `release-please-config.json`'s `release-as:
2.0.0` makes the next PR propose 2.0.0; delete it in the follow-up, or every
later PR proposes 2.0.0 again. The repository inherited the OpenDisplay
reference's old tags (`v0.1.0`–`v1.19.0`); MeowDisplay's own releases start
at `v1.20.0`, the candidate refuses a version whose tag exists, and the
reference sync never imports tags.

## Fastlane lanes

| Lane | Purpose |
|---|---|
| `mac sign_app app:<sender\|receiver>` | Stage 1: build and Developer ID-sign the .app |
| `mac notarize_app app:<sender\|receiver>` | Stage 2: notarize and staple that .app |
| `mac package_dmg app:<sender\|receiver>` | Stage 3: signed, notarized, stapled DMG |
| `mac build_release` / `build_receiver_release` | The three stages for one app, locally |
| `ios upload_candidate` | Release candidate: build number above every existing one for the version, App Store build uploaded, nothing submitted |
| `ios release` | Manual: upload a binary to App Store Connect without submitting |
| `ios beta` | Optional TestFlight upload for testers |

## Manual path (without CI credentials)

Until the environments above exist, a release can be built locally, in the
same fail-closed order. 1.20.0 was released this way.

- **iOS.** Generate the project with `DEVELOPMENT_TEAM` set, archive the
  `OpenSidecariOS` scheme in Release, then upload from Xcode Organizer →
  Distribute App → App Store Connect, with a build number above every build
  already uploaded for that version.
- **Mac.** Archive `OpenSidecarMac` and `OpenSidecarMacReceiver` in Release
  with `CURRENT_PROJECT_VERSION` set to the marketing version (1.20.0
  shipped with build `1`, so every later release must use its marketing
  version, e.g. `2.0.0`, or Sparkle offers it to nobody;
  `scripts/release/check-build-number.sh <build>
  https://meowdisplay.app/appcast.xml` checks this before you publish),
  export each with Developer ID, notarize (`xcrun notarytool submit …
  --wait`), staple, and package as `MeowDisplay.dmg` /
  `MeowDisplayReceiver.dmg` as `fastlane mac build_release` would. Then
  generate the feeds from the maintainer's Keychain key, one directory per
  app (see [Sparkle auto-update](#sparkle-auto-update)):

  ```sh
  generate_appcast --account meowdisplay \
    --download-url-prefix https://github.com/raiseCatError/meowdisplay/releases/download/v<version>/ \
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

- [x] `AppStore.iOSAppID` in `Shared/AppStore.swift` — `6817552864`.
- [ ] `AppStore.androidPlayPackage` — the Android application ID, once its
      Play listing is public.
- [ ] `ProjectLinks.koFiPage` in `Shared/ProjectLinks.swift` — the Ko-fi page
      URL, once it exists. Until then no app shows a support link.

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
  expected version and build number. The archive must contain
  `PrivacyInfo.xcprivacy` at the app bundle's root (Xcode Organizer →
  Generate Privacy Report lists it); App Store Connect does not accept a
  build that uses a required-reason API no manifest declares.
- For Android, `bundletool validate`, the upload certificate's fingerprint
  (`keytool -printcert -jarfile app-release.aab`), and the pre-launch report
  in Play Console.

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
- Never point either app at the OpenDisplay reference project's feeds or key.

**Signing key.** An Ed25519 key made with Sparkle 2.10.0's `generate_keys`
for MeowDisplay only.

- The private key lives in the maintainer's login Keychain under
  `generate_keys`' `--account meowdisplay` (the Keychain item is "Private
  key for signing Sparkle updates"). The same key is stored in the
  `SPARKLE_PRIVATE_KEY` secret. The private key is never committed or
  printed.
- GitHub secrets can't be read back, so keep an offline backup:
  `generate_keys --account meowdisplay -x <file>`, stored in a password
  manager, with the file deleted afterwards. On another Mac,
  `generate_keys --account meowdisplay -f <file>` imports it.
- To confirm which public key the Keychain holds:
  `generate_keys --account meowdisplay -p`. Every release checks the secret
  against the key the PUBLISHED v1.20.0 apps ship (`check-sparkle-key.sh`).

**Feed hosting.** Each release's signed feeds are assets of its GitHub
Release, with enclosures at that tag's immutable
`releases/download/vX.Y.Z/*.dmg` URLs. On Cloudflare, meowdisplay.app
redirects (302) each feed to the latest release's copy:

- `/appcast.xml` → `https://github.com/raiseCatError/meowdisplay/releases/latest/download/appcast.xml`
- `/appcast-receiver.xml` → `https://github.com/raiseCatError/meowdisplay/releases/latest/download/appcast-receiver.xml`

So a feed goes live together with its release, and no website deploy is
involved. A Latest release without feed assets would make the feeds 404,
which is why publication only ever makes a verified, complete release
Latest.

**Key rotation.** Change only when necessary, such as a lost or leaked key.
Because updates are Developer ID-signed DMGs, Sparkle accepts an update that
changes *either* the EdDSA key *or* the Developer ID certificate, but never
both at once. Ship an update signed with the old key whose app carries the
new `SUPublicEDKey`, then switch `SPARKLE_PRIVATE_KEY`. If the old private
key is lost, installed apps reject feeds signed with the new key until
`SUSignedFeedFailureExpirationInterval` (20 days by default) passes. After
that, Sparkle accepts the feed without signature validation but strips its
release notes and links.
