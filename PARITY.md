# Receiver feature parity

What each receiving app can do today: iPhone/iPad (iOS), Android, and Mac Receiver.
Implementation overview reconciled with the integrated `dev` branch and the 2026-10-31 follow-up PRs (#77, #81, #82 and #83). Physical-verification notes retain their original evidence unless explicitly updated. Words follow [TERMINOLOGY.md](TERMINOLOGY.md). Controls and settings: [RECEIVER_CONTROLS.md](RECEIVER_CONTROLS.md).

**Yes** works · **Partial** works with a gap noted · **No** not built yet · **—** not applicable.
"Verified" says where it was last seen working: physical device, simulator/emulator, or unit tests only.

## Verification and scope

- **Per-device Mirror/Extend with multiple receivers** is implemented
  and has been physically verified according to the maintainer
  ([#20](https://github.com/raiseCatError/meowdisplay/issues/20)).
  This does not establish that every edge case in `MULTI_DEVICE.md` was individually retested.
- **Mac-to-Mac keyboard/trackpad input** is implemented with automated
  coverage but **has not been physically verified with two Macs**
  ([#12](https://github.com/raiseCatError/meowdisplay/issues/12)).
- Android had earlier real-device testing, but **additional Android
  physical QA for the current 2.0 release was waived by the owner**.
  That decision is not evidence of a new Android hardware test.
- **No Windows or Linux receiver/sender is implemented or planned**
  ([Windows #84](https://github.com/raiseCatError/meowdisplay/issues/84),
  [Linux #85](https://github.com/raiseCatError/meowdisplay/issues/85)).
  Professional/commercial use is welcome, but an enterprise remote-desktop
  service or hosted account/relay infrastructure is not a current product
  target (#86, #87).

## Connecting

| Feature | iOS | Android | Mac Receiver | Notes |
| --- | --- | --- | --- | --- |
| Pair with code check | Yes | Yes | Yes | Android verified on a Moto G5S Plus |
| Connect from the device (Mac dials in) | Yes | Yes | Yes | Android: Connect, Connect with Extend/Mirror |
| Same Wi-Fi discovery | Yes | Yes | Yes | |
| USB cable | Yes | No | — | Android has no USB transport yet; Help says so. Mac Receiver connects over the network |
| Remote (another network, e.g. Tailscale) | Yes | Yes | Yes | Android physically tested over LTE + Tailscale. Typed addresses are supported. Automatic sharing of a paired peer's reported Tailscale address is implemented (#77/#82); **automatic dialing of reported addresses is currently enabled only for verified Android ↔ Mac IPv4 routes** (#81), not for every receiver or address family. No automatic tailnet-wide peer directory is implemented. |
| Add Remote Mac: Pair over Remote, and an address for a paired Mac | Yes | Yes | Yes | Android: one Address field; the Mac must have Pair over Remote open for new pairs |
| Remote Connect asks the Mac, then the Mac dials back | Yes | Yes | Yes | Android: Connect shows Contacting your Mac, Waiting for your Mac to connect, Needs approval on your Mac |
| Recovery after a lost Remote session | Yes | Yes | Yes | Android: automatic knocks, bounded, foreground only, never replaces a pin; seen working on a phone over LTE + Tailscale. A local Wi-Fi session that drops also falls back to Remote when the Mac has a saved address (knocks only once Bonjour no longer shows the Mac; unit-tested, not yet seen on a phone) |
| Route shown in the performance overlay | Yes | Yes | — | iOS shows its transport tag. Android shows Remote (Tailscale) on a remote session and nothing on a local one; it names Tailscale only when a VPN network covers the Mac's address |
| How to Connect on the home screen | Yes | Yes | — | |
| Settings & Help from the home screen | Yes | Yes | Yes | |
| Home while connected, return to the picture | Yes | Yes | — | |
| Auto-Reconnect switch | Yes | Yes | Yes | |
| Request Control Automatically (per Mac) | Yes | Yes | No | |
| Another Mac waits until its invitation is accepted (F2) | Yes | Yes | Yes | unit-tested both; two-Mac physical test blocked (one Mac) |
| Switched Out (same-Mac account switch) | Yes | No | Yes | |
| Try the Demo | Yes | Yes | No | Android: 213a0a5, checked offline on a Moto |
| Update Required screen | Yes | Partial | Yes | Android shows a text notice with the link |

## Display

| Feature | iOS | Android | Mac Receiver | Notes |
| --- | --- | --- | --- | --- |
| Mirror, Extend | Yes | Yes | Yes | |
| Windows (Window mode) | Yes | Yes | Yes | Android verified physically; iOS/Mac Receiver unit-tested and built |
| Tiles: 3 on phones, up to 9 on large screens | Yes | Yes | Yes | 9-tile layouts exercised in tests and the tablet emulator |
| Swap, drag to split, dividers, maximize, undo | Yes | Yes | Yes | Android verified physically (one drag = one undo step) |
| Per-tile rotation 0/90/180/270 | Yes | Yes | Yes | Android verified physically |
| Foldable hinge splits tiles | Yes | Yes | — | Android emulator; iPhone Duo simulator |
| Mirror Display picker, Extend Shape, Use Full Display | Yes | No | Yes | |
| Video on/off, Streaming Profile, Maximum FPS, Resync | Yes | No | Yes | Android handles the Mac's video state but has no switch; no Streaming Profile/Max FPS messages |
| Viewport rotation, Snap Rotation | Yes | No | — | Android draws on a SurfaceView, which can't rotate |
| Picture in Picture | Yes | Yes | — | Android verified physically |
| Performance overlay | Yes | Yes | Yes | Android shows fps, bitrate, decode, latency, rtt, drops. Mac Receiver: System → Performance Overlay |

## Audio

| Feature | iOS | Android | Mac Receiver | Notes |
| --- | --- | --- | --- | --- |
| Mac audio | Yes | Yes | Yes | |
| A/V Sync both ways (-1000..+1000 ms) | Yes | Yes | Yes | Android verified physically with the overlay |

## Input

| Feature | iOS | Android | Mac Receiver | Notes |
| --- | --- | --- | --- | --- |
| Touch, trackpad mode, Smart Touch, scrolling, haptics | Yes | Yes | — | |
| Control tray, Function Tray, profiles | Yes | Yes | — | |
| Edit Function Tray actions, sequences, names | Yes | No | — | Android: show/hide and order only |
| Custom Layout editor (drag, corners, preview) | Yes | No | — | Android: create, select, delete, share, import |
| Hardware keyboard | Partial | Partial | Yes | not verified with a real keyboard on iOS or Android |
| Hardware mouse/trackpad: click, drag, hover, right click, scroll | Partial | Partial | Yes | Android: absolute mouse, no pointer capture; not verified physically |
| Command shortcuts | Yes | Partial | Yes | Android needs Control Key Types ⌘ (Android keeps Meta for itself) |
| Typing goes only to the active tile's window | Yes | Yes | Yes | Mac checks focus; verified with Android |
| Typing strip above the keyboard; Zoom While Typing follows the Mac's text caret | Yes | Yes | — | Strip checked on both phones; caret follow needs Accessibility on the Mac and is unit-tested only |

## Files and clipboard

| Feature | iOS | Android | Mac Receiver | Notes |
| --- | --- | --- | --- | --- |
| Remote Finder: browse, previews, save and share copies | Yes | Yes | No | the Mac owner's Files permission per device; unit and loop tests, physical check pending |
| Remote Finder: upload, rename, move, copy, Trash | Yes | Yes | No | only with the matching capability granted on the Mac |
| Unified Clipboard: text, links, rich text, images both ways | Yes | Yes | No | off by default on both sides; Mac grants per device; unit and loop tests, physical check pending |
| Unified Clipboard: copied files and folders | Yes | Yes | No | listed at once, fetched on Save or Share; folders keep their structure |
| Copies made on the device reach the Mac | Partial | Partial | — | only when MeowDisplay is in front (OS rule); iOS may ask each time, Android shows a notice |
| Copies marked private are skipped | — | Yes | — | Mac skips nspasteboard concealed/transient items; Android skips EXTRA_IS_SENSITIVE; never guaranteed |

## Help and diagnostics

| Feature | iOS | Android | Mac Receiver | Notes |
| --- | --- | --- | --- | --- |
| Version, GitHub, Privacy Policy, tagline under About | Yes | Yes | Yes | |
| Open the system settings for MeowDisplay | Yes | Yes | — | |
| Share the connection log | Yes | Yes | Yes | Android shares its own log as text; Mac Receiver reveals the log files |
| Cat Mode | Yes | No | No | the Mac app has it too |
| Localization | English | English | English | |

## Not on Android yet, by size

Small: Switched Out, Video on/off, Resync, a full Update Required screen. Medium: Streaming Profile and
Maximum FPS, Mirror Display picker and Extend Shape, App Gesture Commands editing. Large: Custom Layout
editor, Function Tray editor (actions, chords, sequences, names), a USB transport (Android has no usbmux;
the planned design is Android Open Accessory, not started). Not planned: a tailnet-wide peer directory on any platform (it would
need separate Tailscale discovery integration; automatically exchanging
addresses with an **already-paired** device is a different, implemented
feature, constrained to the verified routes described above).
