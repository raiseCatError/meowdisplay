# Receiver feature parity

What each receiving app can do today: iPhone/iPad (iOS), Android, and Mac Receiver.
Updated 2026-10-28 on `feature/android-secure-core`. Words follow [TERMINOLOGY.md](TERMINOLOGY.md). Controls and where each setting lives: [RECEIVER_CONTROLS.md](RECEIVER_CONTROLS.md).

**Yes** works · **Partial** works with a gap noted · **No** not built yet · **—** not applicable.
"Verified" says where it was last seen working: physical device, simulator/emulator, or unit tests only.

## Connecting

| Feature | iOS | Android | Mac Receiver | Notes |
| --- | --- | --- | --- | --- |
| Pair with code check | Yes | Yes | Yes | Android verified on a Moto G5S Plus |
| Connect from the device (Mac dials in) | Yes | Yes | Yes | Android: Connect, Connect with Extend/Mirror |
| Same Wi-Fi discovery | Yes | Yes | Yes | |
| USB cable | Yes | No | — | Android has no USB transport yet; Help says so. Mac Receiver connects over the network |
| Remote (another network, e.g. Tailscale) | Yes | No | Yes | Android: not built; Help says so |
| How to Connect on the home screen | Yes | Yes | — | |
| Settings & Help from the home screen | Yes | Yes | Yes | |
| Home while connected, return to the picture | Yes | Yes | — | |
| Auto-Reconnect switch | Yes | Yes | Yes | |
| Request Control Automatically (per Mac) | Yes | Yes | No | |
| Another Mac waits until its invitation is accepted (F2) | Yes | Yes | Yes | unit-tested both; two-Mac physical test blocked (one Mac) |
| Switched Out (same-Mac account switch) | Yes | No | Yes | |
| Try the Demo | Yes | No | No | |
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
| Video on/off, Streaming Profile, Maximum FPS, Resync | Yes | No | Yes | |
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

## Help and diagnostics

| Feature | iOS | Android | Mac Receiver | Notes |
| --- | --- | --- | --- | --- |
| Version, GitHub, Privacy Policy, tagline under About | Yes | Yes | Yes | |
| Open the system settings for MeowDisplay | Yes | Yes | — | |
| Share the connection log | Yes | Yes | Yes | Android shares its own log as text; Mac Receiver reveals the log files |
| Cat Mode | Yes | No | No | the Mac app has it too |
| Localization | English | English | English | |

## Not on Android yet, by size

Small: Switched Out, Video on/off, Resync. Medium: Streaming Profile and Maximum FPS, Mirror Display
picker and Extend Shape, Zoom While Typing. Large: Custom Layout editor, Function Tray editor, Explore
Demo, Remote pairing, a USB transport (Android has no usbmux; would need an accessory or adb-forward design).
