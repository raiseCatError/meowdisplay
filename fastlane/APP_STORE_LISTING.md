# App Store Connect listing — reference

Canonical copy for the iOS app's App Store Connect text fields, kept in version
control so we know what's live and can edit deliberately. Metadata and
screenshots are entered by hand in App Store Connect for now — `fastlane ios
release` uploads the binary only (`skip_metadata`, `skip_screenshots`).

> **Privacy:** contact addresses, phone numbers, and the legal rights-holder
> are intentionally **not** stored here. Enter those directly in App Store
> Connect.

When you change a field in App Store Connect, update it here too.

Fields marked **[MAINTAINER INPUT]** need a decision or personal/legal detail
that is not recorded in this repository.

---

## App Information (applies to all versions)

**Name**
```
MeowDisplay
```

**Subtitle** _(max 30 chars)_
```
Second monitor for your Mac
```

**Primary category:** Utilities

**Copyright** _(year + rights holder; App Store Connect adds the © itself)_
```
[MAINTAINER INPUT — the legal rights-holder name for this App Store Connect
account. Upstream's "2026 Philip Poloczek" does not apply to MeowDisplay.]
```

**Content Rights** — does the app contain, show, or access third-party content?
> Draft answer: **No.** The app displays the user's own Mac screen over a
> direct connection and bundles or streams no third-party content.
> [MAINTAINER INPUT — confirm.]

---

## URLs

| Field | Value |
|---|---|
| Marketing URL | `https://meowdisplay.app` |
| Support URL | `https://meowdisplay.app/support.html` |
| Privacy Policy URL | `https://meowdisplay.app/privacy.html` |

Related public pages: features `https://meowdisplay.app/features.html`, setup
`https://meowdisplay.app/docs.html`, source
`https://github.com/raiseCatError/meowdisplay`.

---

## Version metadata (per release)

**Promotional Text** _(max 170 chars; editable without a new build)_
```
Mirror or extend your Mac onto the iPhone or iPad you already own, then control it with touch, trackpad gestures and a keyboard. Direct, private and open source.
```

**Description**
```
MeowDisplay puts your Mac on your iPhone or iPad — as a mirror of an existing screen, or as an extra display you can drag windows onto.

DISPLAY
• Mirror: show one of your Mac's displays on your device
• Extend: add a virtual display your Mac arranges like any other monitor
• Sharp, low-latency video with optional Mac system audio

CONTROL
• Direct Touch: tap exactly where you want on screen
• Trackpad: move a pointer with familiar gestures
• Click, double-click, drag, right-click and scroll
• Multi-finger gestures for Mission Control, Spaces, Spotlight and more
• A keyboard, a Main Control Tray for modifier keys, a customizable Function Tray, and Chords with shortcut palettes
• Controls can hide automatically while you work

CONNECT
• USB for the lowest latency, or local Wi-Fi
• Remote Access over a private network you control
• Auto-Reconnect after interruptions, and Wake & Connect for a sleeping Mac on its local network, where supported

PRIVATE BY DESIGN
Devices are paired, every session is encrypted, and your devices talk to each other directly. There is no MeowDisplay account, no MeowDisplay-hosted relay, and no analytics or tracking.

REQUIRES THE MAC APP
MeowDisplay needs the companion MeowDisplay app running on your Mac. Setup: https://meowdisplay.app/docs.html

MeowDisplay is open source under the GPL-3.0 license, built on the OpenDisplay project: https://github.com/raiseCatError/meowdisplay
```

**Keywords** _(max 100 chars; comma-separated, no spaces after commas)_
```
second monitor,external display,extend,mirror,screen,trackpad,touch,usb,wireless,ipad display
```

**What's New** — write per release from `CHANGELOG.md`. Not needed for the
first version.

---

## Manual App Store Connect checklist

Work through this before pressing **Submit for Review**.

| Item | Status / source |
|---|---|
| App name | Above |
| Subtitle | Above |
| Promotional text | Above |
| Description | Above |
| Keywords | Above |
| Primary category | Utilities |
| Copyright / legal rights-holder | **[MAINTAINER INPUT]** |
| Support URL | Above |
| Marketing URL | Above |
| Privacy Policy URL | Above |
| Pricing | **[MAINTAINER INPUT]** — price tier |
| Regions / availability | **[MAINTAINER INPUT]** |
| Content-rights declaration | Draft above — confirm |
| Age-rating questionnaire | **[MAINTAINER INPUT]** — the app shows only the user's own Mac screen; no built-in web browsing, user-generated content, or purchases |
| App Privacy questionnaire | See [App Privacy](#app-privacy) — confirm |
| Export-compliance questionnaire | See [Export compliance](#export-compliance) — **needs a maintainer/legal determination** |
| App Review contact (name, email, phone) | **[MAINTAINER INPUT]** — enter in App Store Connect only |
| App Review notes | See [App Review notes](#app-review-notes) |
| Sign-in required | No — there is no account |
| Screenshots | See [Screenshot plan](#screenshot-plan) — **not captured yet** |
| Build | Select the processed build uploaded by `fastlane ios release` |
| Version release | Choose **Manually release this version** |

### Before the first submission

- [ ] **Update `AppStore.iOSAppID`** in `Shared/AppStore.swift`. It still holds
      upstream OpenDisplay's App Store ID (`6780264891`), which the iOS update
      prompt and the Mac's `updateRequired` message link to. Replace it with
      this app's Apple ID from App Store Connect, then build the candidate.
- [ ] **Provide a Mac build App Review can install.** There is no public
      notarized Mac download yet. Publish one (for example an unlisted or
      pre-release GitHub Release asset) or attach a download link in the review
      notes, and fill in the link below.

---

## App Review notes

Paste into **App Review Information → Notes**, filling in the bracketed link.

```
MeowDisplay turns an iPhone or iPad into a display for a Mac. The iOS app does nothing on its own: it needs the companion MeowDisplay app running on a Mac.

No account or sign-in is needed. There is no MeowDisplay server; the devices connect to each other directly.

Mac app for review: [MAINTAINER INPUT — direct download link to the notarized Mac build]
Project and source: https://meowdisplay.app and https://github.com/raiseCatError/meowdisplay

How to test:
1. Install and open MeowDisplay on a Mac running macOS 14 or later. When prompted, grant Screen Recording (needed to capture the display). To control the Mac from the device, also grant Accessibility.
2. Open MeowDisplay on the iPhone or iPad and allow Local Network access.
3. Connect the device to the Mac with a USB cable, or put both on the same Wi-Fi network.
4. Pair: select the device in the Mac app and confirm the matching code on both screens. The iOS app asks for Face ID or the passcode to confirm trusting a new device.
5. Choose Mirror to show an existing Mac display, or Extend to add a new display that macOS lists in System Settings → Displays.
6. Touch the screen to control the Mac: Direct Touch taps where you touch; Trackpad moves a pointer. The keyboard button and control trays send keys and shortcuts.

Remote Access and Wake & Connect are optional and need extra network setup; they are not needed to review the core features.
```

---

## App Privacy

Draft for the App Privacy questionnaire, from an inspection of the iOS target
(`iOS/`, `Shared/`) and its dependencies. Not a legal conclusion.

### Verified from source

- **No third-party analytics, crash-reporting, or advertising SDKs.** The iOS
  target links only Apple frameworks plus `swift-certificates` (X509) and
  `swift-asn1` (`project.yml`). Sparkle is linked into the Mac apps only.
- **No accounts.** Pairing is device-to-device; there is no sign-in.
- **No tracking and no advertising.** No `AdSupport` /
  `AppTrackingTransparency` use, no `identifierForVendor` use, no ads.
- **No MeowDisplay-hosted servers.** Screen video, audio, and input travel
  directly between the paired devices over USB, the local network, or a
  private network the user configures (Remote Access). The app contains no
  code that uploads them anywhere else.
- **One dormant outbound request.** `iOS/VersionGate.swift` can fetch a static
  version-policy file, but `manifestURL` is `nil`, so no request is made in
  the current build. If it is ever re-enabled, it is an unauthenticated GET
  with no identifiers.
- **Stored on-device only:** device name, pairing trust records and the
  device's own certificate identity (Keychain), Remote Access endpoints, and
  control/display preferences (`UserDefaults`).
- The Performance overlay labelled "Analytics" in Settings is a local
  on-screen diagnostic; it sends nothing.

### Maintainer confirmation required

- Whether **"Data Not Collected"** is the right answer. Apple defines
  collection as data transmitted off the device in a way the developer or
  partners can access; the source supports that answer, but confirm it.
- Whether Apple's own crash/diagnostic sharing (opt-in, handled by Apple)
  changes anything for this listing.
- Re-check this section whenever a network service, SDK, or the version gate
  is added or re-enabled.

---

## Export compliance

From an inspection of `Shared/TLSConfigurator.swift`, `Shared/Pairing.swift`,
`Shared/TrustStore.swift`, `project.yml`, and `iOS/Info.plist`. The final
answer is a maintainer/legal decision — this section does not make it.

### Encryption actually used

- **TLS 1.3 (mutual, pinned)** on every stream connection, via Apple's
  Network framework (`NWProtocolTLS`, min = max = TLS 1.3). Both peers present
  a certificate and are checked against pinned keys from pairing.
- **Pairing:** ephemeral P-256 ECDH with HKDF-SHA256 and HMAC-SHA256
  confirmation (CryptoKit), plus a short authentication code the user compares.
- **Device identity:** P-256 signing keys and self-issued X.509 certificates
  (CryptoKit, `swift-certificates`, `swift-asn1`), stored in the Keychain.
- **Fingerprints:** HKDF-SHA256 over the public key.
- All primitives come from Apple's operating-system frameworks or Apple's
  open-source Swift packages; the app implements no cipher of its own.

### Current declarations

- `ITSAppUsesNonExemptEncryption` is **not set** in `project.yml` or
  `iOS/Info.plist`, so App Store Connect will ask the export-compliance
  questions for each uploaded build until it is answered.

### What App Store Connect is likely to ask

Whether the app uses encryption (it does), and whether that use qualifies for
an exemption — for example encryption limited to authentication, or standard
encryption provided by the operating system — or requires documentation.

### Maintainer determination needed

- Which answer applies. The encryption protects the user's own screen, audio,
  and input data in transit, not only authentication, so do not assume an
  exemption without checking Apple's current guidance and, if needed, legal
  advice.
- Only after that decision, optionally add `ITSAppUsesNonExemptEncryption`
  (with the matching value) to `project.yml` so future builds skip the prompt.

---

## Screenshot plan

Real captures from the running app only. No fake UI, no price wording
(Guideline 2.3.7), and no "Sidecar", "Duet", or "Luna" anywhere.

| # | Screen | Caption idea |
|---|---|---|
| 1 | Receiver showing a real Mac desktop | Your Mac, on iPhone and iPad |
| 2 | Mirror of a Mac display | Mirror any Mac display |
| 3 | Extend with windows dragged across | Extend with a second screen |
| 4 | Direct Touch or Trackpad in use, control tray visible | Touch or trackpad control |
| 5 | Function Tray / Chords shortcut palette open | Shortcuts at your fingertips |
| 6 | Connected devices / connection choice | USB, Wi-Fi or Remote Access |

Capture the same set on iPhone and iPad (the app is universal). Use a clean
desktop, neutral content, and no personal names, addresses, or notifications.

Exact required screenshot sizes are **not recorded here** — confirm them in
App Store Connect at upload time, since Apple's accepted sizes change between
device generations.

---

## TestFlight (optional)

Only used when a build goes to testers via `fastlane ios beta`.

**Beta App Description**
```
MeowDisplay puts your Mac on your iPhone or iPad, as a mirror or an extra display, with touch, trackpad and keyboard control.

You also need the companion MeowDisplay app for Mac. Setup: https://meowdisplay.app/docs.html

Please report connection drops, latency, image sharpness, rotation, or input accuracy: https://meowdisplay.app/support.html
```

**Feedback email** — _managed in App Store Connect; not stored here._

---

## Notes for future edits

- **Fork:** MeowDisplay is a fork of the upstream OpenDisplay project with its
  own bundle IDs (`com.raisecaterror.meowdisplay.*`, set in `project.yml`) and
  its own App Store Connect app — a separate listing from upstream's.
- **App name history:** Apple rejected upstream's earlier name "OpenSidecar"
  under Guideline 5.2.5 as confusingly similar to Apple's Sidecar. The
  on-device name lives in `project.yml` (iOS `CFBundleDisplayName`) and needs a
  new build to change; the store **Name** is set in App Store Connect.
- **Trademark caution:** keep "Sidecar" and competitor brands ("Duet", "Luna")
  **out of every field** and every screenshot.
- **No price references (Guideline 2.3.7):** keep "free" / "no cost" /
  "discounted" out of the subtitle, promotional text, keywords, and
  screenshots.
- **Wake & Connect:** describe it as local-network Wake-on-LAN "where
  supported". It does not wake a Mac from arbitrary internet locations.
- **Apple Pencil:** not advertised until its public readiness is confirmed.
- The Description states the **Mac-app requirement** on purpose; App Review
  needs to know the app is non-functional without the companion.
- Field limits: Subtitle ≤ 30, Promotional Text ≤ 170, Keywords ≤ 100 (whole
  string, commas included), Description ≤ 4000.
