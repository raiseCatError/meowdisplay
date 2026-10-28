# Receiver controls and settings

What each receiver lets you set and do: iPhone, iPad (iOS app), Android, and the
Mac Receiver. [PARITY.md](PARITY.md) covers whole-app parity (pairing,
transports, diagnostics); this page covers **controls**: input, gestures, trays,
keyboard, Window mode, display modes, audio and where each setting lives.

Derived from the code on `feature/android-secure-core` (2026-10-29), not from
memory. Sources: `iOS/ReceiverSettings.swift`, `Shared/ControlProfile.swift`
(`ReceiverControlPreferences`), `Shared/PointerGestureEngine.swift`,
`Shared/StagePeek.swift`, `Shared/WorkspaceViews.swift`;
`AndroidReceiver/app/.../receiver/ReceiverSettings.kt`,
`AndroidReceiver/core/.../controls/*`; `MacReceiver/*`. Both mobile apps persist
the same `ReceiverControlPreferences` blob (schema 20). Names follow
[TERMINOLOGY.md](TERMINOLOGY.md); labels quoted below are what the
apps show today.

**Yes** works · **Partial** works with the gap noted · **No** not built ·
**n/a** doesn't apply to that device (not a gap). "Android" is one column: phone
and tablet differences are in the note.

## Where settings live

| Area | iPhone / iPad | Android | Mac Receiver |
| --- | --- | --- | --- |
| Open settings | Gear in the control tray; **Settings & Help** on Home | Gear in the control tray; **Settings & Help** on Home | **Settings…** (⌘,) |
| Pages | General · Display · Input · Gestures · Controls · Audio · Connections · Paired Macs · Remote Access · Permissions · Diagnostics · About | Input · Gestures · Controls · Tablet Layout · Display · Audio · Session · Help | Overview · Displays · Streaming · Devices · Remote Access · System |
| Settings search | Yes | No | Yes |
| Input mode, Touch Style, Smart Touch, scroll direction | Input | Input | n/a |
| Haptics | **General** | **Input** (under Scrolling) | n/a |
| Pinch, Rotation, Local View Navigation, App Gesture Commands | Gestures | Gestures | n/a (pinch and rotate are forwarded as Mac gestures) |
| Control tray, Function Tray | Controls | Controls | n/a |
| Strip / Overlay / Custom layouts | Controls (iPad only) | **Tablet Layout** | n/a |
| Window Switcher (Stage Peek / Rail) | **Controls** | **Display** | n/a (no switcher; Windows button) |
| Choose windows | Display: **Show Mac Windows…** (**Choose Windows…** in Window view) | Display: **Choose Windows…** | **Windows** button in the title bar, ⌃⌥W |
| Display Mode | Display | Display | Displays |
| Audio, A/V Sync | Audio | Audio | **Streaming** |
| Auto-Reconnect | **General** (also Home) | **Session** | **System** (also Overview) |
| Request Control | Input: **Request Control** button | Input: **Request Control** button | Title bar: **Request Control** |
| Request Control Automatically | Paired Macs | **Home**, in a Mac's ••• menu | No |
| Performance Overlay | Diagnostics | Session | System |
| Keyboard ⌘ from a hardware keyboard | Works as is | Input: **Control Key Types ⌘** | Works as is |

## Pointer input

| Control | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Input Mode: Direct Touch / Trackpad | Yes. Direct Touch default | Yes | Yes | n/a. Mac keyboard and trackpad drive the Mac after Request Control |
| Touch Style: Natural Touch (default) / Classic | Yes, Direct Touch only | Yes | Yes, Direct Touch only | n/a |
| Smart Touch (Experimental) | Yes, Classic only. Haptics toggle follows Haptics | Yes | Yes, Classic only | n/a |
| Trackpad Sensitivity (0.5 to 2.0×) | Yes, Trackpad only | Yes | Yes | n/a |
| Scroll direction per axis | Yes. **Natural** Vertical/Horizontal Scrolling (on = natural) | Yes | Yes. Same names, same preference | Follows this Mac's own setting |
| Natural Touch hint (once) | Yes | Yes | Yes | n/a |
| Precise Control (second finger fine-tunes) | Partial. Classic and Trackpad, not Natural | Partial | Partial. Same engine | n/a |
| Apple Pencil / stylus | n/a | Yes (hover, tilt) | Partial. Stylus is handled in code, not verified | n/a |
| Hardware mouse / trackpad | Partial. Hover, buttons and scroll handled; not verified on hardware | Partial | Partial. Absolute pointer, no capture; not verified | Yes |

### What each gesture does

Shared engine on iOS and Android (`PointerGestureEngine`). Multi-finger gestures
ignore Touch Style.

| Gesture | Natural Touch | Classic | Trackpad |
| --- | --- | --- | --- |
| Tap | Click at the finger, sent on lift | Click at the finger | Click at the pointer |
| Double / triple tap | Double / triple click (next tap within 0.4 s) | Double / triple click | Double / triple click |
| One-finger swipe | Scroll, with momentum | Move the pointer. Smart Touch scrolls where the Mac says the area scrolls | Move the pointer by the swipe, scaled by Trackpad Sensitivity |
| Rest, then move | Drag (after 0.25 s at rest) | Move the pointer | Move the pointer |
| Tap, then hold and move | Double-click drag | Left drag | Left drag |
| Touch and hold (0.5 s) | Right-click. Within the Mac display's left edge, parks the pointer there instead (Stage Manager) | Smart Touch: switch to plain Direct Touch, or arm a title bar window drag | n/a |
| Two-finger tap | Right-click | Right-click | Right-click |
| Two-finger tap, then hold and move | Right-button drag | Right-button drag | Right-button drag |
| Two-finger pan | Scroll | Scroll | Scroll |

## Multi-finger gestures and the view

| Control | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Pinch target: Viewport / App / Disabled | Yes. Default Viewport | Yes | Yes | n/a. Pinch goes to the Mac as a native gesture |
| Rotation target | Yes. Viewport / App / Disabled. Default Disabled | Yes | Partial. App / Disabled only (SurfaceView can't rotate) | n/a. Rotate goes to the Mac as a native gesture |
| Snap Rotation | Yes | Yes | No (kept in preferences, no control) | n/a |
| App Gesture Commands (Zoom In/Out, Rotate Left/Right) | Yes, editable | Yes | Partial. Shown with Reset to Defaults, not editable | n/a |
| Three-finger swipe: Mission Control, App Exposé, Spaces | Yes | Yes | Yes | No. macOS keeps these on this Mac |
| Three-finger tap: Spotlight | Yes | Yes | Yes | No |
| Four / five-finger pinch or spread: Launchpad, Show Desktop | Yes | Yes | Yes | No |
| Three-finger hold: open the window overview | Yes, when the Mac offers Window mode | Yes | Yes, same condition | n/a. Use the Windows button |
| Local View Navigation (pan, zoom, reset; two-finger double tap resets) | Yes | Yes | Yes. Zoom up to 8× | No |
| Move View (one finger moves the picture) | No | Yes | Yes, as a tablet layout control | n/a |
| Prefer MeowDisplay Gestures (edge swipes go to the Mac) | Yes | Yes | Partial. Toggle is saved; the app doesn't read it yet | n/a |

## Control tray, function tray, layouts

| Control | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Control tray (⌘ ⌥ ⌃ ⇧ esc tab Dock Keyboard Settings) | Yes. Shown only while input is allowed | Yes, as **Main Controls** | Yes. **Control Tray** | n/a |
| Show / collapse / auto-hide | Yes | Yes. The Strip never hides | Yes. **Show Control Tray**, **Collapse Control Tray**, **Auto-hide Control Trays** | n/a |
| Profiles (Default, Profile 1, Profile 2) and tray item order | Yes. Full editor | Yes | Partial. Show/hide and Up only | n/a |
| Chord palettes (hold a modifier for shortcuts) | Yes. Editable | Yes | Yes. Not editable | n/a |
| Function tray (Zoom In/Out, Undo, Redo by default) | Yes | Yes, as **Function Controls** | Yes | n/a |
| Function tray editor (add, rename, sequences, faces) | Yes | Yes | No. Show/hide and Up only | n/a |
| Landscape side, Same/Opposite Side, Avoid Notch | Yes | No (edges instead) | Yes. **Landscape Tray Side**, **Function Tray Position**, **Avoid Cutouts** | n/a |
| Layouts: Strip / Overlay / Custom | n/a | Yes | Yes on large windows (tablet, unfolded) | n/a |
| Edges, Palette Style (Keys / Wheel), Control Size, Control Hints, Standard Controls | n/a | Yes | Yes (Tablet Layout page) | n/a |
| Custom layout editor (up to 5, landscape and portrait, Two-Hand Assist) | n/a | Yes | No. **New Radial Layout** only | n/a |
| Custom layout share code | n/a | Yes | Yes. Copy and paste a code | n/a |
| Show Surface Grid while Video is off | Yes | Yes | Yes | No |

## Keyboard and haptics

| Control | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| On-screen keyboard (tray Keyboard button) | Yes. **Show Keyboard Button** | Yes | Yes. **Show Keyboard Button** | n/a |
| Zoom While Typing | Yes, setting | Yes | Partial. Always on, no setting | n/a |
| Hardware keyboard | Partial. Not verified with a real keyboard | Partial | Partial. Same | Yes, after Request Control |
| ⌘ shortcuts from a hardware keyboard | Yes | Yes | Partial. Needs **Control Key Types ⌘** | Yes |
| Pause forwarding | n/a | n/a | n/a | ⌃⌥⎋, or switch away |
| Haptics (master) | Yes | Yes | Yes | n/a |
| Smart Touch Haptics | Yes | Yes | Yes | n/a |

## Window mode

Details in [WINDOW_MODE.md](WINDOW_MODE.md).

| Control | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Windows as a display mode | Yes | Yes | Yes. A **Windows** chip beside Mirror and Extend | Yes, from the **Windows** button |
| Tiles | Yes. Up to 3 | Yes. Up to 9 | Yes. 3 on phones, 9 on large windows | Yes. Up to 9 |
| Window overview | Yes | Yes | Yes | Yes |
| Open the overview | Three-finger hold; Settings → Display | Same | Three-finger hold; Settings → Display; rail | **Windows** button, ⌃⌥W |
| Stage Peek (default quick switch) | Yes. Hold the left or right edge | Yes | Yes | No |
| Rail (optional quick switch) | Yes. Controls → Window Switcher | Yes | Yes. Display → Window Switcher | No |
| Stage Peek edge (Left / Right) | Yes | Yes | Yes | n/a |
| Stage Peek **Expand** and **Add as Tile** | Yes | Yes | Yes | n/a |
| **Full Desktop** card (back to the whole screen) | Yes, in Stage Peek | Yes | Yes | Partial. The overview's **Mirror** and **Extend** buttons |
| **Switch to Window view?** prompt (once per launch, leaves after 8 s) | Yes | Yes | Yes | No |
| Tile menu (Type Here, Change Window…, Rotate, Fill Tile, Maximize, Arrange Tiles, Remove Tile, Close Window on Mac…) | Yes | Yes | Yes | Yes (shared view) |
| Arrange (move, split, resize, layout presets, Undo) | Yes | Yes | Yes | Yes. **Arrange** toggle |
| Per-tile rotation | Yes | Yes | Yes | Yes |
| Hinge-aware tiles on foldables | Yes. Simulator only | n/a | Yes. Emulator only | n/a |
| **Hidden on this screen** when space shrinks | Yes | Yes | Yes | Yes |
| **Typing paused** when another app is in front on the Mac | Yes | Yes | Yes | Yes |

## Display modes

| Control | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Mirror / Extend | Yes. **Display Mode** picker | Yes | Yes. Chips under **Display Mode** | Yes. **Display Mode** control |
| Mirror Display (Auto or pick a display) | Yes | Yes | No | Yes |
| Extend Shape, Use Full Display | Yes | Yes | No | Yes |
| Video on / off | Yes | Yes | No | Yes |
| Streaming Profile, Priority, Maximum FPS | Yes (Display) | Yes | No | Yes (Streaming) |
| Picture in Picture | Yes | Yes | Yes | n/a |
| Viewport reset | Double-tap with two fingers | Same | **Reset View** button and the same gesture | n/a |
| Open in Full Screen | n/a | n/a | n/a | Yes. Displays → Video Window |

## Audio and connection

| Control | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Audio (Mac system audio; off by default) | Yes. **Audio** | Yes | Yes. **Audio** | Yes. **Audio** |
| A/V Sync (−1000 to +1000 ms, 25 ms steps) | Yes | Yes | Yes | Yes |
| Resync | Yes | Yes | No | Yes |
| Auto-Reconnect (default on) | Yes | Yes | Yes | Yes |
| Request Control (Mac decides; every session starts View Only) | Yes | Yes | Yes | Yes. Title bar shows View Only or Controlling |
| Request Control Automatically (per Mac) | Yes | Yes | Yes | No |

## Gaps

**Android compared with iOS**
- No Video on/off, Streaming Profile, Priority or Maximum FPS, Mirror Display picker, Extend Shape, or Resync.
- Rotation can't target the viewport, and there is no Snap Rotation control (the picture is on a SurfaceView).
- Function tray and control tray editors only show/hide and reorder. No add, rename, sequences or faces. No custom layout editor (only New Radial Layout, select, share, import, delete).
- App Gesture Commands are read-only.
- **Prefer MeowDisplay Gestures** is saved but nothing in the app reads it.
- Zoom While Typing is always on. The ⌘ key needs **Control Key Types ⌘** because Android keeps Meta for itself.
- Hardware keyboard, mouse and stylus input are written but not verified on a physical device (iOS keyboard and mouse are also unverified).
- No settings search; Haptics sits under Scrolling on the Input page.

**Mac Receiver compared with the mobile apps**
- No Stage Peek, Rail, Full Desktop card or **Switch to Window view?** prompt. Windows opens the overview.
- No Window Switcher setting, no Local View Navigation, no on-screen trays (its own keyboard and trackpad are the controls).
- No Request Control Automatically.

**iOS compared with Android**
- Windows is not in the Display Mode picker; it is a separate button.
- Settings are spread over twelve pages; Android has eight. Window Switcher is under Controls on iOS but Display on Android; Haptics under General on iOS but Input on Android; Auto-Reconnect under General on iOS but Session on Android.

**All receivers**
- Names for the same setting now match across apps ([TERMINOLOGY.md](TERMINOLOGY.md)). The one deliberate difference is Avoid Notch on iPhone and Avoid Cutouts on Android.
