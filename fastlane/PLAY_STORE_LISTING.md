# Google Play listing — reference

Canonical copy for MeowDisplay for Android's Play Console fields, kept in
version control like [APP_STORE_LISTING.md](APP_STORE_LISTING.md). Entered by
hand in Play Console; the release workflow (`release-android.yml`) uploads
the bundle only. When a field changes in Play Console, change it here too.

> **Privacy:** the developer contact email, address and phone number are not
> stored here. Enter them in Play Console (Settings → Developer account and
> the store listing's contact details).

Only claim what the Android app does today. Check every feature line against
[PARITY.md](../PARITY.md) before each release.

---

## App identity

| Field | Value |
|---|---|
| App name | MeowDisplay |
| Package | `com.raisecaterror.meowdisplay.android` |
| Default language | English (United States) – en-US |
| App or game | App |
| Free or paid | Free |
| Category | Productivity |
| Website | `https://meowdisplay.app` |
| Privacy policy | `https://meowdisplay.app/privacy` |
| First version | 2.0.0 (versionCode 2000001) |
| Play App Signing | On (Google holds the app signing key; we hold the upload key) |
| Upload certificate SHA-256 | `6A:9A:C0:78:DC:13:59:FE:51:DA:77:64:AF:7B:30:9B:AE:F7:08:77:A0:B2:36:F1:50:8F:40:F7:16:33:8E:94` |

## Store listing

**App name** _(max 30)_
```
MeowDisplay
```

**Short description** _(max 80)_
```
Use your Android phone or tablet as a second display for your Mac.
```

**Full description** _(max 4000)_
```
MeowDisplay puts your Mac on your Android phone or tablet: as a mirror of one of its screens, as an extra display you can drag windows onto, or as just the Mac windows you pick, side by side.

DISPLAY
• Mirror: show one of your Mac's displays
• Extend: add a display your Mac arranges like any other monitor
• Windows: pick Mac windows and show them side by side; swap, resize and rotate each one
• Stage Peek: touch and hold the screen edge to flip through your Mac's windows
• Mac system audio, with A/V Sync to line sound up with the picture
• Picture in Picture keeps your Mac on screen while you use another app

CONTROL (when your Mac allows it)
• Natural Touch: tap to click, swipe to scroll, press then move to drag, touch and hold to right-click
• Trackpad mode with a pointer, and two-finger scrolling
• A keyboard with a typing strip that shows what you type, and Zoom While Typing that follows your Mac's text cursor
• The Control Tray for ⌘ ⌥ ⌃ ⇧, Escape and Tab, and a Function Tray of shortcuts
• Pinch to zoom and pan the picture on your device without sending anything to the Mac
• Every session starts View Only. Your Mac decides whether this device may control it, and can stop it at any time

CONNECT
• Same Wi-Fi: your Mac finds your device, or tap Connect
• Remote: reach a paired Mac on another network you control, such as Tailscale
• Auto-Reconnect after interruptions

TRY IT WITHOUT A MAC
Try the Demo opens a sample Mac on your device, offline, so you can explore the controls, Settings, Windows and Stage Peek first.

PRIVATE BY DESIGN
Devices are paired with a six-digit code, every session is encrypted and mutually authenticated, and your devices talk to each other directly. There is no MeowDisplay account, no MeowDisplay relay, and no analytics, ads or tracking.

REQUIRES THE MAC APP
Live sessions need the free MeowDisplay app on a Mac with macOS 14 or later: https://meowdisplay.app

MeowDisplay is open source under the GPL-3.0 license: https://github.com/raiseCatError/meowdisplay
```

**Graphics** _(files in the integration folder `play-listing/`)_

| Asset | Spec | File |
|---|---|---|
| App icon | 512 × 512 PNG | `icon-512.png` (from `assets/AppIcon-master.png`) |
| Feature graphic | 1024 × 500 PNG | `feature-graphic-1024x500.png` (Inter font, OFL) |
| Phone screenshots | 2–8, 9:16 or 16:9 | `phone-*.png` from Try the Demo on a Moto G5S Plus (no real Mac content) |
| Tablet screenshots | 7" and 10" | `tablet-*.png` from the tablet emulator, Try the Demo |

Screenshots come from Try the Demo, so they show no one's real windows, and
keep its DEMO label.

## App content (Policy → App content)

| Declaration | Answer |
|---|---|
| Privacy policy | `https://meowdisplay.app/privacy` (must mention Android: see the website's `privacy.html`) |
| Ads | No, the app contains no ads |
| App access | Some functionality is restricted: see Reviewer instructions |
| Content rating | IARC questionnaire, category "All other app types": no violence, sexuality, language, controlled substances, gambling; no user-generated content shared with others; no location sharing; no digital purchases. Expected: Everyone / PEGI 3 |
| Target audience | 18 and over (not designed for children) |
| News app | No |
| COVID-19 contact tracing / status | No |
| Data safety | See below |
| Government app | No |
| Financial features | None |
| Health | No health features |

### Data safety

- **Does your app collect or share any of the required user data types?** No.
  The app sends screen, audio and input only between the user's own paired
  devices, end-to-end encrypted, never to the developer or a third party.
  Google's definition of "collect" covers data transmitted off the device to
  the developer or third parties; a direct device-to-device session the user
  starts is not that. The connection log leaves the device only when the
  user shares it through the Android share sheet (user-initiated, to a
  destination they pick).
- **Is all user data encrypted in transit?** Yes (TLS 1.3, mutual
  authentication, pinned keys).
- **Can users request that data is deleted?** No data is collected; Forget
  This Mac and uninstalling remove everything on the device.

### Permissions in the manifest

| Permission | Why |
|---|---|
| `INTERNET` | Receive the session from the Mac (TCP 9001), pairing (9002), Remote knocks |
| `ACCESS_NETWORK_STATE` | Tell local Wi-Fi from a VPN or cellular route |
| `ACCESS_WIFI_STATE`, `CHANGE_WIFI_MULTICAST_STATE` | Bonjour discovery of Macs on the local network |

No sensitive or restricted permissions; no foreground service; no
background location; no accessibility service.

## Reviewer instructions (App access)

```
MeowDisplay is a receiver: it shows a Mac's screen sent by the free MeowDisplay app for macOS. No account or login exists.

To review without a Mac: on the home screen tap "Try the Demo". It opens a sample Mac drawn on the device, entirely offline, using the same controls as a real session:
- Tap, swipe and touch-and-hold on the sample desktop (Natural Touch); type into the Notes window with the keyboard button.
- The gear opens Settings; Settings → Display switches between Mirror, Extend and Windows.
- In Windows, touch and hold the left screen edge for Stage Peek.
- Tap Exit (or DEMO for the guide).

To test a live session: install MeowDisplay on a Mac with macOS 14 or later (https://meowdisplay.app), put both devices on the same Wi-Fi, open MeowDisplay on both, tap Pair next to the Mac on the phone and confirm the same six-digit code on both screens. Control of the Mac starts off; request it from the phone and allow it on the Mac.
```

## Testing track

The developer account is a personal account created after 13 November 2023:
production access needs a **closed test with at least 12 testers opted in
for 14 consecutive days**, then **Apply for production** on the Dashboard
(review usually 7 days or less). Internal testing doesn't count.

| Track | Use |
|---|---|
| Closed testing — "Closed testers" | The 14-day test. Testers join through a Google Group or an email list, then accept the opt-in link and install from Play |
| Internal testing | Quick checks of a build (up to 100 testers, no review) |
| Production | Only after production access is granted, and only with the maintainer's final approval |

## Release notes (closed test, en-US) _(max 500)_
```
MeowDisplay 2.0 for Android, for testing.
• Mirror, Extend, or Windows with Stage Peek
• Natural Touch, Control and Function Trays, typing strip
• Remote access, audio with A/V Sync, Picture in Picture
• Try the Demo works without a Mac
Please report problems through the Play Store's feedback or on GitHub.
```
