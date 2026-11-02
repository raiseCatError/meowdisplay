# MeowDisplay 2.0 branding audit

Scope: case-insensitive search for opensidecar, opendisplay, oldsidecar, "open sidecar" and "open display" across Swift, Kotlin, xcstrings, strings, Info.plists, project.yml, Android res, HTML/TSX site sources, scripts and docs.

## Result

No user-visible surface still shows an outdated product name, so no source change was needed. Replaced: 0 (Mac 0, iOS 0, Android 0). Because nothing changed, no rebuild or test run was triggered for this audit.

Surfaces already correct:
- Display names: BUNDLE_DISPLAY_NAME is MeowDisplay, MeowDisplay Dev, MeowDisplay Receiver, MeowDisplay Receiver Dev (project.yml); iOS CFBundleDisplayName is MeowDisplay.
- Permission text: NSLocalNetworkUsageDescription (Mac, Receiver, iOS) and NSFaceIDUsageDescription name MeowDisplay (project.yml).
- Android: app_name is MeowDisplay (res/values/strings.xml); no old names in any strings.xml.
- Mac/MacReceiver/iOS .xcstrings: only "Open Displays…" matches. It is an ordinary phrase (opens the Displays settings page), not a product name. Kept.
- Public site (index.html, public/privacy.html, src/App.tsx): MeowDisplay branding; the OpenDisplay mentions are GPL/upstream attribution (category 4).

## Retained legacy references

### (2) Internal symbol / file / target names (possible future cleanup)
- Xcode targets, schemes, test targets and Swift types: OpenSidecarMac, OpenSidecariOS, OpenSidecarMacReceiver, OpenSidecarMacTests, OpenSidecariOSUITests (project.yml, .github/workflows/tests.yml, run.sh).
- Source files: Mac/OpenSidecarMacApp.swift, iOS/OpenSidecarPhoneApp.swift, MacReceiver/OpenSidecarMacReceiverApp.swift, Mac/OpenSidecarMac-Bridging-Header.h, *.entitlements file names.
- Source comments naming these files/types (Shared/StreamReceiver.swift, Shared/RemoteViewport.swift, Shared/ScrollMomentum.swift, Shared/PointerGestureEngine.swift, Shared/ReceiverAudioDecoder.swift, Mac/*.swift, MacReceiver/MacReceiver.swift, iOS/ReceiverControls.swift, Android ReceiverSurfaceInput.kt and RemoteViewport.kt comments).
- MacTests that read source files by these paths (OwnerAuthTests, PairingSessionTests, PlaintextMediaRemovalTests, UnifiedMacAppTests, SparkleConfigurationTests, PrivacyManifestTests).
- Search keyword "sidecar" in Shared/MobileSettingsSearch.swift refers to Apple's Sidecar feature, not our old name.
- Risk of renaming: high-churn; breaks CI scheme names, tests that read paths, and release tooling. Do as one dedicated change, if ever.

### (3) Persisted / protocol / compatibility identifiers (preserve)
- Bonjour: _opensidecar._tcp, _opendisplay-pair._tcp, _opendisplay-mac-pair._tcp (Shared/StreamReceiver.swift, Mac/OpenSidecarMacApp.swift, MacReceiver/Info.plist, project.yml NSBonjourServices x3, Android discovery/Bonjour.kt and its test).
- Keychain labels/services: com.opendisplay.identity.v1, com.opendisplay.trust.v1; HKDF salt/info: "OpenDisplay-TLS-Pairing-v1", "OpenDisplay pairing v13", "OpenDisplay-Pairing-Transcript-v13" (Shared/Protocol.swift, Shared/Pairing.swift, Android Pairing.kt, PinnedTls.kt). Changing these breaks pairing and trust.
- Log names: Mac/Log.swift baseName "opendisplay"; iOS/Log.swift opensidecar-phone.log and "[opensidecar]" log tag (tooling depends on them).
- Scripts/CI: .github/, scripts/reference/ and reference/opendisplay branch names.

### (4) Historical / attribution (preserve)
CHANGELOG.md, REFERENCE.md, PROTOCOL.md, BRANCHING.md, ARCHITECTURE.md, COMPATIBILITY.md, SETUP.md, README.md, CONTRIBUTING.md, TERMINOLOGY.md, UNIFIED_MAC_APP.md, RELEASE.md, SAME_MAC_SESSIONS.md, MULTI_DEVICE.md, CLOUD-HANDOFF-2.0.md, launch/*.md, AndroidReceiver/RECEIVER_CONTROLS.md; GPL attribution in index.html, public/privacy.html, src/App.tsx; third-party compatibility links in src/App.tsx.

## Old URLs
- Upstream repository and issue links (peetzweg/opendisplay, third-party opendisplay-android/-linux repos): attribution/compat references, kept.
- opendisplay.app appears only in comments recording its removal (index.html, public/privacy.html, public/robots.txt), in COMPATIBILITY.md as history, and in SparkleConfigurationTests as a blocked upstream host. No user-visible link points at it.

## Optional future renames
1. Targets/schemes/types/files to MeowDisplay*: high risk, CI plus tests.
2. Bonjour types and keychain/HKDF labels: would break cross-version and cross-platform interop; only with a protocol version bump and migration.
3. Log file names: low risk but update tooling first.


## Follow-up check (main session, 2026-10-31)

- Mac apps: `CFBundleName` (menu bar, About) is already "MeowDisplay Dev" / "MeowDisplay Receiver Dev"
  (from PRODUCT_NAME); release builds use the release product names.
- iOS/iPadOS: `CFBundleName` was `$(PRODUCT_NAME)` = "OpenSidecariOS", shown by some system UI (for
  example the menu bar when the iPad app runs on a Mac). Now "MeowDisplay" in iOS/Info.plist. Not an
  identity key: the bundle ID, executable name (OpenSidecariOS), keychain, settings and pairing are
  unchanged; no code reads it on iOS.
- Shared diagnostics are already named "MeowDisplay-<device>-<time>.txt". The live iOS log
  (Documents/opensidecar-phone.log) isn't visible in Files (no file sharing) and stays as is.
