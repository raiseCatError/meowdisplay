# Receiver feature parity

**MeowDisplay 2.0 is officially released on iPhone/iPad.** Mac 2.0 downloads
currently carry the public beta 1 artifact label; Android 2.0 is in closed
testing and requires Mac 2.0. Android requires Android 10+ and has no USB
transport. See [platform availability](README.md#platform-availability--november-2-2026).


What each receiving app can do today: iPhone/iPad (iOS), Android, and Mac Receiver.
Release availability and implementation rows reconciled on 2026-11-02 against
`dev` and the Mac 2.0 beta source. Physical-test notes below are the existing
2026-10-29 records; this documentation update did not repeat device QA. Words follow [TERMINOLOGY.md](TERMINOLOGY.md). Controls and where each setting lives: [RECEIVER_CONTROLS.md](RECEIVER_CONTROLS.md).

**Yes** works · **Partial** works with a gap noted · **No** not built yet · **—** not applicable.
"Verified" says where it was last seen working: physical device, simulator/emulator, or unit tests only.

## Connecting

| Feature | iOS | Android | Mac Receiver | Notes |
| --- | --- | --- | --- | --- |
| Pair with code check | Yes | Yes | Yes | Android verified on a Moto G5S Plus |
| Connect from the device (Mac dials in) | Yes | Yes | Yes | Android: Connect, Connect with Extend/Mirror |
| Same Wi-Fi discovery | Yes | Yes | Yes | |
| USB cable | Yes | No | — | Android has no USB transport yet; Help says so. Mac Receiver connects over the network |
| Remote (another network, e.g. Tailscale) | Yes | Yes | Yes | Android seen on a phone over LTE + Tailscale. Every platform uses a typed address (Tailscale IP or MagicDNS name); none lists tailnet peers by itself |
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
| Tiles: up to 9 on every receiver | Yes | Yes | Yes | Minimum pane size and available space decide what fits; existing 9-tile QA record is tests and the tablet emulator |
| Swap, drag to split, dividers, maximize, undo | Yes | Yes | Yes | Android verified physically (one drag = one undo step) |
| Per-tile rotation 0/90/180/270 | Yes | Yes | Yes | Android verified physically |
| Foldable hinge splits tiles | Yes | Yes | — | Android emulator; iPhone Duo simulator |
| Mirror Display picker, Extend Shape, Use Full Display | Yes | Yes | Yes | Android controls depend on the connected Mac's advertised capabilities; source-inspected |
| Video on/off, Streaming Profile, Priority, Maximum FPS, Resync | Yes | Yes | Yes | Android Display/Streaming controls and Audio Resync implemented; source-inspected, physical QA not added here |
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
| Edit Function Tray actions, sequences, names | Yes | Yes | — | Android editor implemented; source-inspected, physical QA not added here |
| Custom Layout editor (drag, corners, preview) | Yes | Yes | — | Android editor implemented; source-inspected, physical QA not added here |
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

Remaining gaps include Switched Out, a full Update Required screen, viewport
rotation/Snap Rotation, and USB transport. Android has no usbmux; an Android
Open Accessory transport is not implemented. Hardware keyboard, mouse and
stylus coverage remains incomplete on physical devices. Automatic tailnet
peer listing is not implemented on any platform.

Video/streaming controls, Audio Resync, Custom Layout, Function Tray, chord
palette and App Gesture Commands editors are implemented; the earlier
October 29 gap list predates those changes. Implementation is not a claim
that every control has passed physical-device QA.
