# Release process

## Platform availability — November 2, 2026

| Platform | Available version | Get it |
| --- | --- | --- |
| Mac app · macOS 14+ · share or receive | **2.0.0 stable** | [Download MeowDisplay](https://github.com/raiseCatError/meowdisplay/releases/download/v2.0.0/MeowDisplay.dmg) · [release notes](https://github.com/raiseCatError/meowdisplay/releases/tag/v2.0.0) |
| Receiver-only Mac app · macOS 12+ | **2.0.0 stable** | [Download MeowDisplay Receiver](https://github.com/raiseCatError/meowdisplay/releases/download/v2.0.0/MeowDisplayReceiver.dmg) |
| iPhone / iPad · iOS / iPadOS 16.4+ | **2.0.0 on the App Store** | [App Store](https://apps.apple.com/us/app/meowdisplay/id6817552864) |
| Android · Android 10+ | **2.0 closed beta** | [Request early access](https://meowdisplay.app/android/early-access) |

The main Mac app includes both sharing and receiving: share this Mac's display,
or use this Mac as another Mac's display. The separate Receiver-only app is
also available for Macs running macOS 12 or later. Android 2.0 requires the
Mac 2.0 app.


MeowDisplay 2.0 is the stable release. The main Mac app includes sender and
receiver roles; the separate Receiver-only app remains available. The
publication gate and historical release process are documented below.


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
Mac and iOS always; Android only when `crossPlatformReady` is `true`.
Otherwise an Android candidate is built, uploaded and reported, but doesn't
hold the release. A required platform must be able to go public. An Android
build on a testing track never counts as public (`verify-live` refuses it),
so `meow-release init`/`candidate` refuse to start a release that requires
Android on a testing track. 2.0.0's configuration did exactly that, and its
gate could never have opened.

| Release | `.github/release-config.json` on `release/<version>` | What happens |
| --- | --- | --- |
| Mac and iOS stable, Android testing (the default on `dev`) | `crossPlatformReady: false`, `android.reviewTrack: alpha` | Mac and iOS pass the gate and publish. The Android candidate is built, signed and uploaded to internal testing. The monitor sends it to the `alpha` (closed testing) review track and follows Play review. It never holds Mac/iOS publication and never appears on the website as public. Missing Play credentials or a Play error is reported and doesn't stop the pass. |
| Android production, released with Mac and iOS | `crossPlatformReady: true`, `android.reviewTrack: production`, `android.productionRelease: "<version>"`, plus the operator's `ANDROID_PRODUCTION_AUTHORIZED=<version>` | Android must be approved for the same commit before anything publishes. No workflow sets `ANDROID_PRODUCTION_AUTHORIZED` yet, so Android's first production release needs its own reviewed workflow change. |
| Android required on a testing track | `crossPlatformReady: true` with `internal`/`alpha`/`beta` | Refused when the release or candidate starts |

### Before the next release: what the pipeline still lacks

The CI pipeline has not completed a release yet. Every `release/2.0.0`
candidate stopped in `plan` with "couldn't update release-state after 5
attempts" ([run](https://github.com/raiseCatError/meowdisplay/actions/runs/41196833601)).
At that time the `release-state` ruleset was closed to every writer; the
release App now exists and is its only bypass (2026-11-02), but the signing and
store secrets are not yet in their environments. 2.0.0 was built
locally and published by two one-time workflows, `mac-stable-launch.yml` and
`mac-stable-finalize.yml`, which ran only on their own `release/mac-2.0.0-*`
branches and are now disabled in Actions. Before CI can release, the owner:

1. ~~Creates the [release GitHub App](#the-release-github-app) and makes it the
   only bypass actor of the `release-state` ruleset.~~ Done 2026-11-02; prove
   it with **Release state access check**.
2. Moves the signing and store secrets into their environments and deletes
   the repository-level copies ([Credentials](#credentials)).
3. Cuts `release/<version>` from `dev` and runs **Release dry run** on it
   (`gh workflow run release-dry-run.yml --ref release/<version>`). It names
   anything still missing without building or publishing.

Until all three are done, use the [manual path](#manual-path-without-ci-credentials).

**Scheduled workflows** (`release-monitor`, `repository-guard`, `reference-sync`)
run only from the default branch, `main`, and only while their repository
variable is `enabled` (`RELEASE_AUTOMATION`, `REPOSITORY_GUARD`,
`REFERENCE_SYNC`). GitHub registers a schedule when a commit that changes the
workflow file lands on the default branch. After the default branch changes,
the old schedules can stay unregistered until that happens: Actions then
shows no scheduled runs at all, not even skipped ones. Merging any change to
the workflow file into `main` registers it again. Running a workflow by hand
(`workflow_dispatch`) works at any time but does not register its schedule.

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

## Homebrew

Nothing in this repository updates Homebrew. The
[`raiseCatError/homebrew-tap`](https://github.com/raiseCatError/homebrew-tap)
`autobump.yml` runs daily (05:55 UTC), notices the new GitHub Release
through each cask's `livecheck`, and opens a PR bumping the `meowdisplay`
and `meowdisplay-receiver` casks (version and SHA-256). The two
repositories share no token or secret.

The tap's CI runs only style checks and an offline tap audit, so verify a
bump locally before merging it:

```sh
brew update
brew audit --cask --strict --online raiseCatError/tap/meowdisplay raiseCatError/tap/meowdisplay-receiver
brew upgrade --cask meowdisplay   # or a fresh: brew install --cask raiseCatError/tap/meowdisplay
spctl -a -vv /Applications/MeowDisplay.app   # "Notarized Developer ID"
```

Homebrew users get a release only after the bump PR is merged. To hold
back a bad release, close that PR, or revert the casks' `version` and
`sha256` in the tap.

## The release GitHub App

Only the release App writes the `release-state` branch. Its ruleset refuses
every other writer, `GITHUB_TOKEN` included, so a release job that changes the
state mints the App's token first. That token is limited to `contents: write`
on this repository (`state-token` steps; `check-release-workflows.rb` enforces
it) and is passed to `release-state.sh` as `RELEASE_STATE_TOKEN`. The release
PR and the `main` promotion PR use the same App with pull-request and issue
access as well.

| Setting | Value |
| --- | --- |
| Type | Private GitHub App `meowdisplay-release` (App ID 5582030, created 2026-11-02) owned by `raiseCatError`, installed on `meowdisplay` only ("Only select repositories") |
| Repository permissions | Contents: read & write · Pull requests: read & write · Issues: read & write (release-please labels) · Metadata: read. Nothing else |
| Webhook / events | Off / none |
| Repository variables | `RELEASE_APP_ID`, `RELEASE_APP_CLIENT_ID` (identifiers, not secrets) |
| Secret `RELEASE_APP_PRIVATE_KEY` | In `release-state`, `release-state-check`, `release-pr`, `release-stores`, `release-publish` and `website-update`, the environments whose jobs mint its token. Never at repository level |
| Rulesets | The only bypass actor of `release-state` (`.github/rulesets/release-state.json`). No bypass on `main`, `dev`, `release/*` or tags |

Create it with `scripts/release/create-release-app.sh`. `start` opens
GitHub's pre-filled "Create GitHub App" page. `finish <code>` stores the
variables and the key without printing or saving the key. Then install the App
from the link it prints. A token covers only what the job's `permission-*`
inputs ask for, so the state token can't open PRs even though the App can.

**Diagnosing "couldn't update release-state after 5 attempts":**
- "no RELEASE_STATE_TOKEN": the job didn't mint the App token. Look at the
  `Release state token` step: either `RELEASE_APP_CLIENT_ID`/`RELEASE_APP_PRIVATE_KEY`
  is missing, or the App isn't installed on the repository.
- Otherwise the push was refused: check that the App is the `release-state`
  ruleset's bypass actor (`gh api repos/raiseCatError/meowdisplay/rulesets`)
  and that its installation still has Contents: read & write.
- The branch itself: `git fetch origin release-state && git show FETCH_HEAD:releases/<version>.json`.
- **Release dry run**'s `release-state` job proves the setup without touching
  a release record. It checks three things: the App's token reaches this
  repository only, a `GITHUB_TOKEN` push is refused, and an App push is
  accepted. The App push updates `dry-run.json` at the branch root
  (`scripts/release/check-release-state-access.sh`).
- **Release state access check** (`release-state-access.yml`) runs the same
  script from `main`, on demand, without a `release/<version>` branch (pushing
  one starts a real candidate). Its own environment, `release-state-check`,
  allows `main` only and holds nothing but the App key. Run it after changing
  the App, its installation or the ruleset:
  `gh workflow run release-state-access.yml --ref main`.

## Credentials

Every secret lives in one protected environment; jobs check the
environment's protection (`check-environment.sh`) before using a secret,
because a job naming a missing environment silently gets an unprotected one.
`Release dry run` reports what is missing, by name only.

`scripts/release/release-secrets.rb status` lists, from the workflows themselves,
which secret and variable each environment needs and whether GitHub has it
(names only). The owner sets a secret with `release-secrets.rb set NAME`,
reading from a hidden prompt, stdin or `--file PATH`. The value goes into
exactly the environments whose jobs use it, through `gh`'s stdin; it's never
printed or put on a command line.

`scripts/release/apply-environments.sh` creates and protects the eight
environments below (branch patterns, owner approval where marked, no admin
bypass) and then checks each one; it never touches secrets. It prints the plan
unless given `--apply`, and is safe to re-run.

| Environment (branches) | Secrets | Variables | Who creates them |
| --- | --- | --- | --- |
| `release-build` (`release/*`) | `DEVELOPMENT_TEAM`, `MATCH_GIT_URL`, `MATCH_DEPLOY_KEY`, `MATCH_PASSWORD`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_CONTENT` (notarization; the .p8 base64-encoded, which `release-secrets.rb set` does for a raw key), `SPARKLE_PRIVATE_KEY` | — | Owner; the Developer ID identity imported into match (`match import`; Apple doesn't let an API key create Developer ID certificates), then `match developer_id` for the profiles |
| `ios-upload` (`release/*`) | `DEVELOPMENT_TEAM`, `MATCH_*`, `APP_STORE_CONNECT_*` | — | Owner (App Store Connect team API key, App Manager role, never Admin; `match appstore` made the Apple Distribution certificate with it) |
| `android-upload` (`release/*`) | `PLAY_SERVICE_ACCOUNT_JSON`, `ANDROID_UPLOAD_KEYSTORE_BASE64`, `ANDROID_UPLOAD_STORE_PASSWORD`, `ANDROID_UPLOAD_KEY_ALIAS`, `ANDROID_UPLOAD_KEY_PASSWORD` | `ANDROID_UPLOAD_CERT_SHA256` (the upload certificate registered with Play App Signing) | Owner (Play Console service account with release permissions; the upload key) |
| `release-stores` (`main`, `release/*`; owner approval) | `APP_STORE_CONNECT_*`, `PLAY_SERVICE_ACCOUNT_JSON`, `RELEASE_APP_PRIVATE_KEY` | — | Owner |
| `release-publish` (`release/*`; owner approval) | `RELEASE_APP_PRIVATE_KEY` only (the publish-mac job's state token) | — | Owner adds themselves as **required reviewer** |
| `release-pr` (`release/*`) | `RELEASE_APP_PRIVATE_KEY` | `RELEASE_APP_CLIENT_ID` (repository) | [The release App](#the-release-github-app) |
| `release-state` (`release/*`) | `RELEASE_APP_PRIVATE_KEY` | — | The release App. Jobs with no other environment that write the release state |
| `release-state-check` (`main`) | `RELEASE_APP_PRIVATE_KEY` | — | The release App. Only the release state access check |
| `website-update` (`release/*`) | `WEBSITE_APP_PRIVATE_KEY`, `RELEASE_APP_PRIVATE_KEY` | `WEBSITE_APP_CLIENT_ID` (repository) | Owner creates a GitHub App installed on `MeowDisplayWebsite` only (Contents, Pull requests: read & write) |

The release monitor asks for the `release-stores` approval only while a release
is unfinished (a candidate exists and isn't published): its read-only `pending`
job, with no environment or secret, checks the release state first, so a
scheduled run with nothing in flight ends without an approval request. While a
release is in flight every monitor run still needs the approval, because it can
submit to App Store review and move the Play release between tracks.

### Preflight from the default branch

`release-dry-run.yml` needs a `release/X.Y.Z` branch, and pushing one starts a
real candidate. `release-preflight.yml` (dispatch from the default branch) is
the check to run first. It holds **no credential**: no environment, no secret,
no App token, `contents: read` only, which `check-release-workflows.rb`
enforces. It checks the release tooling and workflow rules, that every release
environment is protected as its jobs expect, that bundle ids agree across
`project.yml`, Fastfile and Matchfile, and that the published baseline apps
and `project.yml` ship the same Sparkle public key.

| Check | Preflight (main) | Needs a release context |
| --- | --- | --- |
| Tooling, workflow rules, environment protection, signing config, Sparkle **public** key | yes | |
| release-state is App-only | `release-state-access.yml` | |
| match decrypt (`MATCH_PASSWORD`), Sparkle **private** key, App Store Connect, Google Play | | `release-dry-run.yml` on `release/*` |

Not done, on purpose. Any of these changes who can reach a credential and
needs a reviewed decision:

- *Adding `main` (or a new branch pattern) to `release-build`, `ios-upload` or
  `android-upload`.* Every default-branch workflow, and anyone able to change
  one through a merged PR, could then read the match password, which decrypts
  the signing keys, and the Sparkle private key.
- *A `release-preflight` environment holding copies of those secrets.* A second
  place to protect, rotate and audit the same keys; the reviewer gate would be
  the only barrier.
- *Separate read-only credentials* for such an environment (an App Store
  Connect key with a read-only role, a Play service account with view
  permission only) are the acceptable variant if API reachability must be
  proven before a candidate. They still can't prove the match password or the
  Sparkle private key, which only the release-branch dry run (or the candidate)
  can.

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
and never tags or releases. Release-please proposes the next version from
the Conventional Commit titles since `v2.0.0`. To force a version, set
`"release-as"` under `packages["."]` in `release-please-config.json` on the
release branch only, and remove it after that release. The `release-as:
2.0.0` used for 2.0.0 was removed afterwards. The repository inherited the OpenDisplay
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
  against the key the PUBLISHED baseline apps ship (`baseline.env`, `check-sparkle-key.sh`).

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
