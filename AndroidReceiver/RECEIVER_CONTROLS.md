# Android receiver controls (C3)

The Android receiver's controls, input and adaptive layout are a port of the
iOS/iPadOS receiver, not an Android remote-desktop UI. The iOS Swift is the
authority: `Shared/*.swift` logic is translated type for type into
`core/src/main/kotlin/.../core/controls/`, and the Mac tests that cover it are
ported with it. Only the UIKit/SwiftUI layer is rewritten (Compose, Android
views, MotionEvent, InputConnection, WindowManager).

## Where things live

| iOS | Android | Tests |
| --- | --- | --- |
| `Shared/ControlProfile.swift`, `ControlInteraction.swift`, `ReceiverGesture.swift`, `ReceiverInputPrompt.swift` | `core/controls/ControlProfile.kt`, `ReceiverControlPreferences.kt`, `ControlInteraction.kt`, `ReceiverGesture.kt`, `ReceiverInputPrompt.kt` | `ReceiverControlsTests`, `ReceiverUIPreferenceUpdateTests`, `ControlPreferencesJsonTest` |
| `Shared/ControlTrayGeometry.swift` | `ControlTrayGeometry.kt` | `ReceiverControlsTests` (geometry, notch, folds) |
| `Shared/PadControlLayout.swift`, `CustomControlLayout.swift`, `CustomLayoutSharing.swift` | `PadControlLayout.kt`, `CustomControlLayout.kt`, `CustomLayoutSharing.kt` | `PadControlLayoutTests`, `CustomLayoutRefinementTests`, `SecondQARefinementTests`, `LocalViewNavigationTests`, `ShareCodeHardeningTest` |
| `Shared/PointerGestureEngine.swift`, `ScrollMomentum.swift`, `KeyboardEditPlanner.swift` | `PointerGestureEngine.kt`, `ScrollMomentum.kt`, `KeyboardEditPlanner.kt` | `PointerGestureEngineTests`, `SmartTouchTests`, `ScrollMomentumTests`, `KeyboardEditPlannerTests` |
| `Shared/RemoteViewport.swift` | `RemoteViewport.kt` | `RemoteViewportTests`, `TwoFingerGestureClassifierTests`, `ViewportPanFreedomTests`, `ExtendViewportTests` |
| VideoView's recognizers (`iOS/OpenSidecarPhoneApp.swift`) | `ReceiverSurfaceInput.kt` (one dispatcher) + app `ReceiverInputView` | `ReceiverSurfaceInputTest` |
| `iOS/RemoteKeyboardInputView.swift` | `RemoteKeyboardBridge.kt` + `ReceiverInputView` (IME, KeyEvent) + `HidKeyMap` | `RemoteKeyboardBridgeTest` |
| `StreamReceiver` send functions | `core/session/ReceiverInputSender.kt` | `ReceiverInputSenderTest` |
| `PCMPlaybackEngine` scheduling | `core/wire/AudioPlaybackPlanner.kt` + app `AudioPlayer` | `AudioPlaybackPlannerTest` |
| `ReceiverControlOverlay`, `ReceiverControlStore` | app `receiver/overlay/*`, `controls/ReceiverControlStore` | `OverlayScenesTest`, `ChordGestureControllerTest`, `OverlayGlyphsTest` |
| `ReceiverScreen`, `ReceiverSettings` | app `receiver/ReceiverScreen`, `ReceiverController`, `ReceiverSettings` | emulator smoke test |

Geometry uses `Geometry.kt`'s `CGRect`/`CGPoint` with CoreGraphics semantics
measured on macOS. Distances are dp, the Android counterpart of iOS points,
so every ported threshold means the same physical distance.

## Input authorization

- Every input message goes through `ReceiverSession.sendInput`, which refuses
  unless the Mac granted input on the current admitted, unpaused connection.
  A sender older than the grant (pv < 8) gets no input from Android at all.
- `ReceiverInputSender` remembers every key, modifier, button, contact and
  gesture it put down. A pause releases them while the gate is open;
  revocation, `inputReset`, a withdrawn admission, a lost or replaced
  connection drop them (the Mac releases on its side). A reconnect starts View
  Only with nothing held.
- Locally the app releases (with `keyboard cancel`) on a tray, profile, input
  or pointer-model change, when Settings opens, and when the app leaves the
  foreground. Back on the live screen backgrounds the app; it never ends the
  session.

## Adaptive layout

- The presentation follows the usable window, never the device: both window
  sides at least 600 dp gives the iPad presentation (default: the radial
  Custom layout, `ReceiverControlPreferences.initial(isPad = true)`); anything
  smaller gives the iPhone tray. A tablet, an unfolded foldable and a large
  split-screen pane are expanded; a phone, a folded foldable and a narrow
  pane are compact.
- One preference set serves both: the compact tray never reads the iPad
  fields, so a user's Strip / Overlay / Custom choice applies whenever the
  window is large enough and survives every fold, rotation and resize.
- Folds and hinges (WindowManager `FoldingFeature`, separating or half
  opened) become `ControlReservedRegion.Division`s, cutouts set the notch
  side, the docked IME sets the keyboard rect, all fed to the ported geometry.
- `hello` announces the whole current display (maximum window metrics), so
  rotation and fold/unfold re-announce the panel while split-screen,
  freeform resizing and attached keyboards never rebuild the Mac's display,
  and an unchanged panel is never re-sent.

## Parity matrix

Legend: **Ported** = same behavior, tested. **Adapted** = same behavior by
other means, or a documented platform difference. **Gap** = not on Android yet.

| Area | Status | Notes |
| --- | --- | --- |
| Control profiles (3 slots), tray items, chord palettes, persistence in the iOS JSON format with schema 1–18 migrations | Ported | |
| iPhone Main Tray: chips, latch, 350 ms hold palette, slide-to-select, collapsed gear, HUD | Ported | Emulator-verified on phone and folded foldable |
| Function Tray clusters incl. Return, visibility and order | Ported | Order/visibility edited in Settings |
| Function Tray custom actions (shortcut recorder, sequences, faces, rename) | Gap | Model, validation and plan are ported; editor UI is not |
| Chord palette editor (add, remove, reorder palette actions) | Gap | Model ported; Settings edits tray items only |
| App Gesture Commands | Adapted | Shown and reset in Settings; per-key editor not built |
| Keyboard: committed text, IME composition never sent, chord typing (⌘ then C = ⌘C), Backspace/Return presses, held Esc/Tab/Delete-Forward/arrows, release on focus loss | Ported | Emulator-verified (typing, arrow) |
| Keyboard accessory bar | Ported | |
| Hardware keyboard | Adapted | Same forwarding rules; Android also forwards ⌘/Ctrl shortcuts as one press (iOS lets UIKit swallow them) |
| Zoom While Typing | Adapted | Keyboard-open viewport is used; the typing-focus anchor is not tracked yet |
| Direct Touch, Trackpad (sensitivity), clicks, double/triple, drag, right-click chord, two-finger scroll, momentum, per-axis direction | Ported | Emulator-verified click; rest unit-tested |
| Smart Touch (probe, scroll, title-bar window drag) | Ported | Title-bar build-up haptic is a single tick (no Core Haptics ramp) |
| Three-finger swipe/tap, four/five-finger pinch/spread | Ported | Unit-tested; multi-touch needs physical QA |
| Two-finger double tap reset/restore, local zoom to 8×, pan, Move View | Ported | |
| Viewport rotation | Gap | A SurfaceView can't rotate the picture; Rotate offers App or Disabled |
| Pinch/Rotate to App (key chords; `nativeAppGesture` unused, like iOS) | Ported | |
| Stylus: pencil down/move/up, pressure, tilt, hover, proximity | Adapted | Android tilt/orientation mapped to altitude/azimuth; needs physical QA |
| Mouse | Adapted | Clicks drive the pointer engine like iPad pointer input; wheel scrolls (Android addition) |
| iPad Strip, Overlay, Custom radial, wheel palette, Two-Hand Assist, hints, size, edges, standard controls | Ported | Radial default emulator-verified on tablet and unfolded foldable |
| Custom layouts: create, select, delete, share code export/import | Ported | Share codes interchangeable with iOS (verified against Swift) |
| Custom Layout editor (drag placements, corners, preview) | Gap | |
| Auto-hide (9 s), reveal on any touch | Ported | Emulator-verified |
| Input consent: View Only start, Request/Turn Off, on-surface prompt, blocked attempts | Ported | Emulator-verified grant and revoke |
| Per-Mac "Request Control Automatically" | Gap | Store and UI not ported |
| Prefer MeowDisplay Gestures (claim screen edges) | Gap | Stored; Android system-gesture exclusion not applied |
| Accessibility: TalkBack labels, roles, states; multi-finger gestures step aside for TalkBack; Remove animations = Reduce Motion | Adapted | Needs a TalkBack pass on hardware |
| Haptics | Adapted | Android feedback constants |
| Cursor sprite and position under zoom; video-off surface and grid | Ported | |
| Audio: AAC/PCM, iOS continuous scheduling, preroll, re-anchor, overflow, Delay Audio | Ported | Planner unit-tested; audible playback not verified (physical QA) |
| Negative A/V offset (delay video) | Gap | |
| Picture in Picture | Gap | |
| Display controls (Mirror/Extend request, video on/off, Mirror display, Extend shape, max FPS, streaming profile) | Gap | Not part of this milestone |
| Localization | Gap | English only |

## Verification

- `./gradlew :core:test` 630 tests (1 emulator test skipped on the host),
  `:app:testDebugUnitTest` 28, `:app:lintRelease` (only the deliberate
  `OldTargetApi` and one style warning in the overlay), `:app:bundleRelease`,
  `:app:assembleDebug`.
- `EmulatorSmokeTest` against the installed debug app (`MEOW_EMULATOR_SERIAL`,
  `MEOW_EMULATOR_PROFILE` = `phone` | `tablet` | `foldable`,
  `MEOW_SMOKE_SHOTS` for screenshots), on API 36 AVDs (Pixel 7, medium
  tablet, Pixel 9 Pro Fold) with `-gpu host`: pairing, pinned TLS session,
  first-keyframe decode, no input before the grant, click mapping, tray
  modifier latch, Function Tray Undo, typing, held arrow, auto-hide, revoke,
  rotation, HEVC, reconnect, fold/unfold. SwiftShader gives stale
  screenshots and SwangleShader is too slow for the 9 s auto-hide window.
- Not verified: anything physical (real latency, multi-finger feel, stylus
  angles, audio output, haptics, TalkBack, OEM foldables), and a real Mac.

## Physical QA checklist (Android)

Mac sender from this branch; one Android phone, one tablet, one foldable if
available; same Wi-Fi.

1. **Pair and connect.** Pair from the phone, connect from the Mac: video
   appears, the controls show View Only behavior (no tray), touches do
   nothing on the Mac and the Request Control prompt appears.
2. **Grant.** Request Control → allow on the Mac: the tray appears (phone) or
   the radial clusters (tablet). Revoke on the Mac: input stops at once,
   nothing stays held (type on the Mac: lower case).
3. **Direct Touch.** Tap, double-tap a word, drag a window, two-finger tap
   for right-click, two-finger scroll fast and slow (momentum), natural
   direction per axis in Settings.
4. **Trackpad.** Switch mode: relative cursor, sensitivity slider, tap-hold
   drag; the cursor never jumps to the finger.
5. **Smart Touch.** One-finger swipe in Safari scrolls; hold a title bar
   (tick) then drag the window.
6. **System gestures.** Three-finger swipes (Mission Control, Exposé,
   Spaces), three-finger tap (Spotlight), four/five-finger pinch/spread.
7. **Local view.** Pinch to 8×, pan, two-finger double tap reset/restore;
   check the cursor and clicks land on the right place while zoomed.
8. **Chords.** Tap ⌘ (latch, palette), tap Copy; hold ⌥ and slide onto a
   key; ⌘ latched + software keyboard C → ⌘C. Function Tray: zoom, Undo,
   Redo, Return.
9. **Keyboard.** Software keyboard text, accents, emoji, Backspace hold,
   Return; physical keyboard: arrows, Esc, Tab, ⌘C/⌘V, Ctrl shortcuts.
10. **Stylus** (if available): strokes with pressure in a drawing app, hover.
11. **Never stuck.** Hold a modifier or drag, then: background the app,
    rotate, fold, open Settings, lose Wi-Fi. Nothing stays held on the Mac.
    Back on the live screen backgrounds the app and the session resumes.
12. **Adaptive.** Rotate both ways; split-screen and resize (the Mac display
    must NOT rebuild); fold/unfold (compact ↔ radial, display rebuilt once).
13. **Tablet layouts.** Strip, Overlay, Custom; edges, size, hints, Wheel;
    share a layout to an iPad and import one from it.
14. **Auto-hide.** Controls retreat after 9 s idle and return on touch.
15. **Audio.** Audio on: clean sound, no robotic artefacts; Delay Audio
    shifts it; audio off/on and a network blip recover.
16. **Accessibility.** TalkBack reads every control with its state; with
    TalkBack on, multi-finger gestures don't fire.
17. **Reconnect.** Kill and relaunch the app: View Only again, no grant
    carried over.
