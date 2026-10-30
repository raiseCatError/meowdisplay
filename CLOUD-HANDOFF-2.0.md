# MeowDisplay 2.0 — cloud handoff

Written 2026-10-31 at the end of local development. Local work stops here; what remains runs in
the cloud through the repository's existing release process (no second pipeline).

## Repository and revision

- Repository: `raiseCatError/meowdisplay` (fork of OpenDisplay; GPL; keep the attribution and
  fork relationship — see README, REFERENCE.md and the `reference/opendisplay` branch).
- Branch: `feature/v2-hotspot-parity` (pushed for the cloud). The SHA is whatever this file was
  pushed at; the final report gives it. `release/2.0.0` was **not** pushed from local.
- Default branch on GitHub: still `dev/opendisplay-next`. Branch model and release rules:
  BRANCHING.md, RELEASE.md, RELEASE_ASSETS.md, REFERENCE.md.

## Architecture (read first)

ARCHITECTURE.md (overall), PROTOCOL.md (wire protocol; §6.10 addenda cover Window mode, Stage
Manager, Add to Stage, Mission Control), WINDOW_MODE.md, MULTI_DEVICE.md, RECEIVER_INPUT.md,
RECEIVER_CONTROLS.md, PARITY.md (Apple ↔ Android), COMPATIBILITY.md, SECURITY.md.

| Part | Folder | Target / module |
|---|---|---|
| Mac sender (also hosts the Mac receiver role) | `Mac/` | `OpenSidecarMac` (macOS 14+) |
| Mac receiver | `MacReceiver/` | `OpenSidecarMacReceiver` |
| iPhone and iPad receiver (one app) | `iOS/`, `Shared/` | `OpenSidecariOS` (iOS 16.4+) |
| Android receiver | `AndroidReceiver/` (`core`, `app`) | minSdk 29, targetSdk 36 |
| Tests | `MacTests/`, `iOSUITests/`, `AndroidReceiver/*/src/test` | `OpenSidecarMacTests`, `OpenSidecariOSUITests` |
| Prototype (not shipped) | `Prototypes/CrashSafeShield` | isolated; see Privacy Shield below |

The Xcode project is generated: edit `project.yml`, then run `./generate.sh`. The Mac test target
lists the `Mac/` and `Shared/` files it compiles one by one.

## Toolchain

Xcode 27.1 (27A9269), Swift 6 language mode, macOS 27 SDK. Android: AGP 9.4.1, Kotlin 2.4.21,
JDK 17. Sparkle (Mac updates), swift-certificates, swift-crypto via SwiftPM.

## Build and test

```sh
# Mac unit tests (covers Shared/ logic used by iOS too)
xcodebuild test -project MeowDisplay.xcodeproj -scheme OpenSidecarMac -destination 'platform=macOS' -only-testing:OpenSidecarMacTests
# iOS build (device)
xcodebuild build -project MeowDisplay.xcodeproj -scheme OpenSidecariOS -destination 'generic/platform=iOS'
# Android
cd AndroidReceiver && ./gradlew :core:test :app:testDebugUnitTest :app:assembleDebug
```

CI: `.github/workflows/tests.yml`; release workflows `release-*.yml`; reference sync
`reference-*.yml`; `repository-guard.yml`, `pr-title.yml`.

Results at handoff (2026-10-31, at 752f3c3): Mac unit tests 2458 run, 0 failures, 2 skipped;
Android 994/994; iOS device build succeeds. Live UI tests (`iOSUITests/LiveStabilizationTests`) need a paired Mac and a
device and don't run in CI.

## Features in 2.0 and their state

The completion matrix is the source of truth, with implemented / automated / physically checked /
release-ready kept apart: `handoff-2.0/COMPLETION-MATRIX.md` (sanitized copy; the original and
the evidence folders live in the owner's local integration folder). Highlights since the last
cloud review:

- Window mode on iPhone, iPad and Android (panes, tabs, free rotation, per-pane trackpad cursor,
  Stage Manager handling, Spatial Overview / Gallery as the Expanded Layout setting).
- View Only: selecting a pane, panning and zooming stay local; a touch meant for the Mac never
  leaves the device and shows Request Control inside the selected pane (existing request flow,
  no replay of the touch).
- Mission Control: panes pause without restarts; devices say "Mission Control is open on your
  Mac. Video is paused." and one pane offers Exit Mission Control (control only; the Mac
  re-checks before pressing Escape). Detection details: PROTOCOL.md §6.10 addendum.
- Capture broker (`Mac/CoalescingFetch.swift`, `Mac/ShareableContentBroker.swift`): one shared,
  bounded, cancellable ScreenCaptureKit content request per moment, with start traces.
- Paired-only Mac user name and short Mac ID to tell same-named Macs apart.
- Not built: Camera Mode / Microphone Mode (owner deferred). Clipboard is out of this release's
  checklist.

## Physical QA done (by the owner's devices, 2026-10-29 … 31)

Mac (macOS 27) with iPhone 14 Pro Max, iPad (9th gen) and a Moto G5S Plus (LineageOS, no Google
Play services): connect and video; Mirror, Extend and Window starts; two receivers at once in
mixed modes; Privacy Shield cover/remove and Touch ID removal; pane selection and inline Request
Control; Mission Control open/close (keyboard) with one and two receivers. Not done by hand:
TalkBack (the Moto has none), VoiceOver/Voice Control declarations, trackpad-gesture Mission
Control entry, Exit Mission Control with control granted, the iPad on the last two builds (it
was unavailable).

## Known limitations

- **Stage Manager**: windows in its side strip are paused by macOS. Panes say so and offer Show
  on Mac / Turn Off Stage Manager (owner-made Shortcuts). Add to Current Stage is implemented but
  never offered: macOS 27 acknowledges the accessibility action without moving the window.
- **Mission Control**: macOS pauses window captures while it is open; there's no public API that
  reports it, so detection uses the public window list plus an Accessibility confirmation.
- **Extend start time / AltTab**: AltTab 10.x floods macOS's capture service (replayd) on macOS
  26/27 (alt-tab-macos#5861), which made Extend starts take 19–61 s. Without it: Mirror ~0.15 s,
  Extend 0.7–2.4 s, Window 1–4 s. The broker keeps MeowDisplay to at most two outstanding requests.
  Findings: `handoff-2.0/EXTEND-START-ALTTAB-FINDINGS.md`.

## Privacy Shield

Threat model: someone at the Mac while a device is connected must not see or use it; the owner
removes the shield with the login password or Touch ID. The shield excludes itself from capture
through the broker's content list. Quitting while it covers locks the Mac first.
Crash-safe design (an out-of-process guardian so a crash never leaves the Mac uncovered) is a
**prototype only** (`Prototypes/CrashSafeShield`, 9 tests; no persistent helper installed):
`handoff-2.0/PRIVACY-SHIELD-CRASH-SAFE-DESIGN.md`. Installing a helper needs the owner's
approval.

## Signing, notarization and stores

Signing and the release mechanics are owned by the existing pipeline: RELEASE.md,
RELEASE_ASSETS.md, `.github/release-config.json`, `scripts/release/`, `fastlane/` (Appfile,
Fastfile, Matchfile, APP_STORE_LISTING.md, APP_REVIEW.md, PLAY_STORE_LISTING.md). Accessibility
declarations: `handoff-2.0/STORE-ACCESSIBILITY.md` (declare only what was verified). The
read-only audit of what is actually configured on GitHub (environments, rulesets, secret names,
gaps) is summarized in the section below.

## Release pipeline as found (read-only audit, 2026-10-31)

The branch model in BRANCHING.md / RELEASE.md is **documented, not yet applied** on GitHub:

- Default branch is still `dev/opendisplay-next`. No remote `dev`, `reference/opendisplay` or
  `release-state` yet. The only release branch is `release/app-store-rc` (unprotected).
- `main` still holds the upstream project's tree with its inherited `release.yml`
  (release-please) and `pages.yml`. A `release-please--branches--main` branch exists. The
  default branch also has a legacy `app-store-candidate.yml`. Retire these; don't extend them.
- Applied rulesets: only the two old ones ("Protect Main Branch", "Protect development branch").
  The rulesets in `.github/rulesets/` are not applied.
- Environments: none. The release workflows expect release-build, ios-upload, android-upload,
  release-stores, release-publish, release-pr and website-update.
- Repo secrets present: DEVELOPMENT_TEAM, MATCH_DEPLOY_KEY, MATCH_GIT_URL, SPARKLE_PRIVATE_KEY.
  Missing:
  - MATCH_PASSWORD
  - the APP_STORE_CONNECT_* secrets
  - the ANDROID_UPLOAD_* secrets
  - PLAY_SERVICE_ACCOUNT_JSON
  - RELEASE_APP_PRIVATE_KEY
  - WEBSITE_APP_PRIVATE_KEY

  No repo variables are set.
- The release-*, reference-* and guard workflows aren't on the default branch yet, so they can't
  be dispatched.
- `.github/release-config.json` has `publishMode` "manual-final-approval" (line 2),
  `crossPlatformReady` false (line 3) and `android.reviewTrack` "production" (line 17; must
  become a beta track first).

Applying the documented model needs owner approval: default branch, rulesets, environments and
secrets. That is the existing pipeline being switched on, not a second one.

## Cloud assignment (corrected)

Work only through the existing branches, workflows and reviewed PRs. Never weaken a gate to get
something through; stop and report instead.

- **A. Read-only audit.** Re-verify this handoff against the repository: build, run every test
  suite, check entitlements, privacy manifests, required-reason APIs, licenses/attribution,
  secrets in history, and the release configuration. Produce findings; change nothing.
- **B. Fixes with tests.** Fix what A finds on `feature/v2-hotspot-parity` (or a branch from it),
  each fix with a test, through PRs into `dev` per BRANCHING.md.
- **C. `release/2.0.0`** created by the existing reviewed PR process (release-pr / candidate
  workflows), not by hand.
- **D. Store and distribution staging, nothing live:**
  - Apple: submit 2.0.0 for review with **manual release** (no automatic release).
  - Google Play: upload the AAB to an **internal or closed beta track** only. Fix
    `android.reviewTrack=production` in the release config to beta-first.
  - Mac: notarized DMGs, Sparkle signatures and checksums **staged**, not marked Latest and not
    live in the appcast.
  - Reconcile `publishMode=manual-final-approval` and `crossPlatformReady=false` with the above
    without weakening any gate.
- **E. README and website redesign** in a staging branch/preview only.
- **F. Stop before public publication.** The owner gives the final go-ahead for App Store
  release, Play production, the Mac Latest release and the website.

## Owner actions before or during the cloud run

- Unlock and connect the iPad, then install the current build (it missed the last builds).
- Glance at the iPhone/iPad for the Mission Control notice and the pane Request Control pill.
- Grant control once and try Exit Mission Control; open Mission Control with the trackpad.
- Approve or decline the crash-safe Privacy Shield helper (prototype only today).
- Provide or confirm the release secrets/environments the audit lists as missing.
