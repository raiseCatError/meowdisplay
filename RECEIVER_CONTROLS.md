# Receiver controls and settings

What each receiver lets you set and do: iPhone, iPad (iOS app), Android, and the
Mac Receiver. [PARITY.md](PARITY.md) covers whole-app parity (pairing,
transports, diagnostics); this page covers **controls**: input, gestures, trays,
keyboard, Window mode, display modes, audio and where each setting lives.

Implementation rows reconciled with `dev` on 2026-11-02. Existing device-test
notes remain the October 29 record; no physical QA was repeated for this
publication. Sources: `iOS/ReceiverSettings.swift`, `Shared/ControlProfile.swift`
(`ReceiverControlPreferences`), `Shared/PointerGestureEngine.swift`,
`Shared/StagePeek.swift`, `Shared/WorkspaceViews.swift`;
`AndroidReceiver/app/.../receiver/ReceiverSettings.kt`,
`AndroidReceiver/core/.../controls/*`; `MacReceiver/*`. Both mobile apps persist
the same `ReceiverControlPreferences` blob (schema 21). Names follow
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
| Auto-Reconnect | **General** | **Session** | **System** (also Overview) |
| Request Control | Input: **Request Control** button | Input: **Request Control** button | Title bar: **Request Control** |
| Request Control Automatically | Paired Macs | **Home**, in a Mac's ••• menu | No |
| Performance Overlay | Diagnostics | Session | System |
| Keyboard ⌘ from a hardware keyboard | Works as is | Input: **Control Key Types ⌘** | Works as is |

## Pointer input

| Control | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Input Mode: Direct Touch / Trackpad | Yes. Trackpad initially | Yes. Direct Touch initially | Yes. Phones Trackpad, tablets Direct Touch initially | n/a. Mac keyboard and trackpad drive the Mac after Request Control |
| Touch Style: Natural Touch / Classic (default) | Yes, Direct Touch only | Yes | Yes, Direct Touch only | n/a |
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
| App Gesture Commands (Zoom In/Out, Rotate Left/Right) | Yes, editable | Yes | Yes, editable | n/a |
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
| Profiles (Default, Profile 1, Profile 2) and tray item order | Yes. Full editor | Yes | Yes. Editor implemented | n/a |
| Chord palettes (hold a modifier for shortcuts) | Yes. Editable | Yes | Yes. Not editable | n/a |
| Function tray (Zoom In/Out, Undo, Redo by default) | Yes | Yes, as **Function Controls** | Yes | n/a |
| Function tray editor (add, rename, sequences, faces) | Yes | Yes | Yes | n/a |
| Calculator (on the device; never sent to the Mac; works in View Only) | Yes. Off by default; **Edit Function Tray** → Utilities. Upper-left corner | Yes. Same switch for Strip and Overlay (first on the Function edge); Custom: **Add Control** → Calculator | No | n/a |
| Landscape side, Same/Opposite Side, Avoid Notch | Yes | No (edges instead) | Yes. **Landscape Tray Side**, **Function Tray Position**, **Avoid Cutouts** | n/a |
| Layouts: Strip / Overlay / Custom | Yes on an unfolded iPhone Duo (see below) | Yes | Yes on large windows (tablet, unfolded) | n/a |
| Edges, Palette Style (Keys / Wheel), Control Size, Control Hints, Standard Controls | n/a | Yes | Yes (Tablet Layout page) | n/a |
| Custom layout editor (up to 5, landscape and portrait, Two-Hand Assist) | n/a | Yes | Yes | n/a |
| Custom layout share code | n/a | Yes | Yes. Copy and paste a code | n/a |
| Show Surface Grid while Video is off | Yes | Yes | Yes | No |

### iPhone Duo

The layout follows the window, never the device or its orientation. A window that is **regular in both directions** (width and height size classes) gets the iPad-style layouts: Strip, Overlay and Custom, Control Size, Standard Controls, Custom layouts, and the iPad first-run defaults (Direct Touch and the radial Custom layout, applied once to an install with nothing saved whose first window is roomy). That is an unfolded Duo. A compact window (the outer display, a half-open fold, a landscape phone) keeps the compact tray. One rule decides it, and Demo Mode follows it too. Settings opens as a sheet in a compact window and full screen in a roomy one, decided once when it opens, so folding with Settings open changes nothing about it.

Folding resizes the app mid-session, so every capability stays reachable in both layouts:

| Roomy standard control | In a compact window |
| --- | --- |
| Menu Bar, Show Desktop, Control Center | Function Tray actions of the same name (off by default; switch them on in **Edit Function Tray**) |
| Dock, Escape, Tab, Keyboard | The same Main Tray items |
| Arrow Keys | The arrow button |
| Move View | Not offered. Move View is a one-finger mode toggle with its own banner on the roomy rail; compact windows keep two-finger pan, pinch and rotate for the same view navigation |

On a fold (iPhone Duo) the roomy rails skip over the crease (a vertical crease across a top or bottom rail, a horizontal one across a side rail) and Custom controls placed on it move wholly onto one half, so no control straddles it. Controls stay inside the safe area, including the trailing system area. Geometry is unit-tested only; not yet run on a real Duo.

**Upside-down portrait is not available on iPhones without a Home button.** That is a system rule, not a setting here, and the app does not work around it with a transform. Use landscape either way.

### Default shortcut palettes (audit #131)

Holding or latching a modifier opens the palette for exactly that combination. Any mix of ⌘ ⌥ ⌃ ⇧ is a chord; three have defaults, the rest open an empty palette that says "No shortcuts for …" on purpose. Every default is an ordinary key press with its modifiers, so any Mac build accepts it.

| Chord | Default shortcuts |
| --- | --- |
| ⌘ | Copy, Paste, Cut, Undo, Select All, Close ⌘W, **New Tab ⌘T**, Spotlight |
| ⌘⌥ | Move Item Here, Force Quit ⌘⌥Esc, Toggle Dock, Hide Others, Close All Windows |
| ⌘⇧ | Redo, New Folder, Reopen Closed Tab ⇧⌘T, Screenshot, Screenshot Selection, Screenshot Controls |
| ⌥, ⌃, ⇧, ⌘⌃, ⌃⇧, ⌥⇧ and every other combination | None. Left empty on purpose: a palette is not filled for its own sake, and ⌃Tab, ⌃⌘Q and the like are one tap on the latched modifier plus the Tab key or the keyboard. |

**Added: ⌘T New Tab** (after Close, so Close keeps its place). It is universal: Safari, Chrome, Firefox, Terminal, Finder and most tabbed apps use it, it only opens something, and it pairs with Reopen Closed Tab and Close. That makes eight keys in the ⌘ palette, which is the most a phone shows on one line (portrait wraps to two rows above eight, landscape never wraps), so no further default goes in without something coming out.

**Existing profiles.** A saved profile is stored whole, so a new default never reaches it by itself. Schema 22 inserts New Tab after Close only in a Command palette that still equals the previous default exactly (same items, order, faces). A palette the user reordered, trimmed, extended, renamed or restyled is left alone, a New Tab deleted afterwards stays deleted (the schema number records that the step ran), and Reset Profile gives the new default. The Android receiver keeps its own copy of the defaults and is not changed here.

| Considered | Decision | Reason |
| --- | --- | --- |
| ⌘T New Tab | Added | Universal, harmless, frequent. |
| ⇧⌘T Reopen Closed Tab | Already there | In ⌘⇧; not repeated in ⌘. |
| ⌘N New Window | Not added | Universal but means New Document, New Window or nothing by app; the ⌘ palette is full. |
| ⌘F Find | Not added | Universal and safe, but the ⌘ palette is full and ⌘ latched plus F on the keyboard is one more tap. Users can add it in the editor. |
| ⌘S Save | Not added | Universal; opens a sheet in untitled documents, and has no use in browsers or Finder. |
| ⌘R Reload, ⌘L Location Bar | Not added | Browser-specific. |
| ⌃Tab, ⇧⌃Tab, ⇧⌘] / ⇧⌘[ Switch Tabs | Not added | ⌃ has no palette and stays that way. Tab keys differ by app (Chrome and Safari accept ⌃Tab, Terminal and Finder use ⇧⌘] / ⇧⌘[). The tray Tab key with ⌃ latched sends ⌃Tab. |
| ⌘` Cycle Windows | Not added | Covered by the window switcher and Window mode. |
| ⌘[ / ⌘] Back / Forward | Not added | App-specific. They are also the default Rotate Left / Right App Gesture Commands, so one key would mean two things. |
| ⌘M Minimise | Not added | Universal, but the window leaves the screen and a touch user can't easily bring it back. |
| ⌘H Hide | Not added | Universal, but hides the foreground app. ⌘⌥H Hide Others is already there. |
| ⌘Q Quit | Rejected | Can lose unsaved work from one small key. Force Quit ⌘⌥Esc is already there and only opens the Force Quit window. |
| ⌘, Settings | Not added | Only for apps with settings, rarely used, and easily mistaken for the tray's gear, which opens MeowDisplay's own settings. |

Already in the palettes and unchanged: Close ⌘W and Close All Windows ⌘⌥W are the most surprising defaults (an app may show a Save sheet, or close several windows at once), and Move Item Here, New Folder and Reopen Closed Tab only mean something in Finder or a browser.

## Keyboard and haptics

| Control | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| On-screen keyboard (tray Keyboard button) | Yes. **Show Keyboard Button** | Yes | Yes. **Show Keyboard Button** | n/a |
| Zoom While Typing (follows the Mac's text caret, see Typing) | Yes, setting | Yes | Yes, setting | n/a |
| Hardware keyboard | Partial. Not verified with a real keyboard | Partial | Partial. Same | Yes, after Request Control |
| ⌘ shortcuts from a hardware keyboard | Yes | Yes | Partial. Needs **Control Key Types ⌘** | Yes |
| Pause forwarding | n/a | n/a | n/a | ⌃⌥⎋, or switch away |
| Hold Response (how long ⌘ ⌥ ⌃ ⇧ are touched before their shortcuts appear: Fast 0.18 s, Standard 0.25 s, Deliberate 0.4 s) | Yes | Yes | No (fixed) | n/a |
| Arrow keys (button, ↑ ← ↓ → keypad and its own ⇧ ⌥ ⌘) | Yes. **Show Arrow Keys**, **Arrow Keys Side** | Yes. Compact windows keep the button; roomy layouts have an **Arrow Keys** standard control (Strip, Overlay) and Custom item, one tap for the same keypad. **Show Arrow Keys** applies to both | No | n/a |
| Haptics (master) | Yes | Yes | Yes | n/a |
| Smart Touch Haptics | Yes | Yes | Yes | n/a |

### Hold gestures (#131)

Each touch-and-hold on the iPhone and iPad receiver means something different, so each keeps its own
delay. Only the first can be changed (**Hold Response**), because a lift before it is only a latching
tap. The rest send input to the Mac, end a session or move windows, so a shorter hold would make them
easier to trigger by accident. The delays live in `ReceiverHoldGestures` (`Shared/ControlInteraction.swift`)
and a test pins them. The system's own gestures and Touch Accommodations are never changed.

| Hold | Delay | Adjustable | What it does |
| --- | --- | --- | --- |
| ⌘ ⌥ ⌃ ⇧ in the control tray | 0.18 / **0.25** / 0.4 s (Hold Response) | Yes | Opens the key's shortcuts. A lift before it latches the key; sliding away opens them at once and never latches |
| Stage Peek edge | 0.3 s | No | Opens Stage Peek |
| Stage Peek card | 0.35 s | No | Starts dragging an app or window onto a pane |
| Settings control | 0.5 s | No | Opens Session Actions (Back to Home, Disconnect). A tap opens Settings |
| Window view pane label | 0.4 s | No | Lifts the pane to move it; a release in place opens its menu |
| Window view divider | 0.35 s | No | Drags the divider |
| Touch hold after a tap | 0.15 s | No | Commits a held touch to a drag (Direct Touch, Trackpad) |
| Natural Touch rest, then drag | 0.25 s | No | Drags instead of scrolling |
| Natural Touch hold | 0.5 s | No | Right-click |
| Smart Touch hold | 0.4 s | No | Falls back to plain Direct Touch for that touch |
| Smart Touch title bar | 0.5 s | No | Arms a window drag |

The shortcut keys show on the touch-down chip at once (a pressed state, never a key sent), and the
haptic plays only when they open (and only with Haptics on), so an iPad without a haptic engine still
sees the same state change. A touch the system takes (Control Center, an alert) or a rotation under
the finger sends nothing and leaves nothing latched. Android keeps its fixed 0.35 s.

### Arrow keys (#179)

**Roomy layouts** (an iPad, an unfolded iPhone Duo) have the same keypad behind an **Arrow Keys** control on the Strip and Overlay rail (a standard control, shown by default and switchable under **Standard Controls**) and as a Custom layout item (**Add Control** → Keys & Utilities; the starter radial layout does not include it). A tap opens or closes the keypad beside the control, toward the middle of the screen and clear of the other controls and of a fold. The swipe is the compact button's alone. **Show Arrow Keys** turns it off everywhere; **Arrow Keys Side** is for the compact button. The keyboard bar's Arrow Keys item now shows in roomy windows too.

One small button gives the arrow keys. **Tap** it to open an inverted-T keypad (↑ above ← ↓ →) and tap it again to close it. **Swipe** it in a direction to send one arrow without opening anything. A touch that is neither a tap nor a clear swipe (a diagonal, a short drag, a touch the system cancelled) sends nothing.

On the keypad a touch is a real key press: key down, then the Mac's own autorepeat after 0.4 s at 12.5 a second while the finger stays, then key up on lift. Sliding to another key releases the first; sliding off the keypad releases it too. The receiver times the repeats, because the Mac never repeats a key it was sent. A late timer sends one repeat, never a catch-up burst. Haptics: one tick when a key goes down, none per repeat, the usual open/close tap for the keypad and a tap when a keypad modifier turns on or off, all under **Haptics**.

**Keypad modifiers.** The open keypad has its own **⇧ ⌥ ⌘**, each the size of an arrow key (46 pt touch areas). Over or under the T they form one segmented capsule; beside it, rounded-square keys. Either way they never read as the round tray modifiers. They are plain toggles: a touch turns one on at touch-down (it lights up and shows a dot) and the next touch turns it off. Nothing waits for the finger to lift, and nothing another finger does changes it, so any number can be on together and the next arrow carries exactly those. There is no hold mode any more: in 2.1 a modifier held while an arrow went down stopped latching, so a quick two-thumb ⇧ then → could silently leave ⇧ off. Touches inside the keypad's block that miss every key (the T's empty corners, the gaps) do nothing, instead of going to the Mac and closing the keypad. Keypad arrows carry only the keypad's modifiers, never the tray's, so ⇧ on the keypad and → selects, while ⌘ latched on the tray still gives ⌘C from the keyboard and leaves the keypad's → a plain →. A key keeps the modifiers it went down with until it goes up, so a modifier toggled mid-hold never changes it. Latches last while the keypad is open; closing it, and everything that closes it (a disconnect, Allow Input off, View Only, leaving the app, a profile change), clears them. They are never held down on the Mac, only named on each arrow, so nothing can stay stuck. The button's swipe and its named actions still carry the tray's modifiers, as before. Keeping the two apart needs a Mac with this update (it tells the device it posts keys with exactly their own modifiers). With an older Mac the keypad's modifiers work only while the tray holds none: otherwise they are dimmed and dropped, and the arrows carry the tray's modifiers as they always did.

The keypad stays open while you use Return, modifiers, the Function Tray and shortcuts. It closes when you tap the button, touch the Mac's picture (the touch still goes to the Mac), open or close the keyboard, open Settings, or when input stops reaching the Mac: Allow Input off, a disconnect, paused capture, a view change, leaving the app. Each of those also sends key up for a held key. The button follows the keyboard's gates: Allow Input, a Mac that understands keyboard messages, and its own switch.

**With the keyboard up**, the companion bar gains one **Arrow Keys** item between Return and Hide Keyboard. It is the same button: a tap opens the same keypad, a swipe sends one arrow. The keypad and its modifiers open above the item, above an open shortcut palette, or beside the bar when the keyboard leaves no room above it. In iPhone landscape with the keyboard up, about 121 pt is left beside the bar, so the whole keypad there shrinks just enough to fit (37 pt keys, 41 pt touch areas) rather than overlapping the safe area. They never cover the keyboard, and Stage Peek keeps clear of them as it does of the bar. Nine keys tighten the bar's gaps from 8 to 6 pt, so a 375 pt iPhone keeps 32 pt keys. Turning **Show Arrow Keys** off brings back the eight-key bar.

**Key preview.** A small label above the open keypad, in the same capsule as the shortcut palettes' preview, shows what the arrows send. While modifiers are on and no arrow is down it is subdued, with a dashed edge and an open slot (**⇧ ⌘ ·**): the next arrow will carry these. When an arrow goes down it turns solid (**⇧ ⌘ ↓**) and stays for 0.7 s after the key goes up, so a quick tap is still readable. Repeats of a held key never change it. It reports what MEOW sent; the keyboard protocol has no acknowledgement from the Mac, so it never claims the Mac acted. VoiceOver reads it as, for example, "Shift Command Down Arrow".

**Where it sits.** On iPhone in landscape it sits on the bottom edge on the chosen side (Right by default), stepping inward past whatever already holds that corner. With the default trays the Main Tray is on the right and Return is bottom-left, so on the right the button sits just inside the Main Tray, and on the left it sits beside Return. Return is never on the right by default, so "right side, next to Return" can't both hold. In portrait it sits at the chosen end of the row above the Main Tray. The keypad opens above the button and moves inward or up to clear the other controls and system-reserved areas. Its modifiers sit in a row over the T, as wide as it, making a 134×134 pt block: they are set before an arrow, the arrows stay nearest the thumb, and the row never borders the button. Where there is no height for that, they become a 2×2 grid (⇧ ⌥ over ⌘) beside the T on the side with room (toward the middle of the screen), a block as high as the T; failing that, a row under the T. The T and the modifiers move as one, so the modifiers clear everything the T clears: the trays, the calculator, the palette, the notch and reserved areas. The button never moves when the keypad opens. A shortcut palette can push both aside while it is open. They are not tray items, so tray chips keep their size, and saved profiles, Function Tray layouts and share codes are unchanged. Older builds ignore the two new preferences.

**Accessibility.** The button is **Arrow Keys** (Shown/Hidden), with **Up Arrow**, **Down Arrow**, **Left Arrow** and **Right Arrow** as named actions, so VoiceOver, Voice Control and Switch Control can send arrows without a swipe. Each keypad key is a button of the same name; its value names the keypad modifiers it adds, and activating it sends the arrow with those. The keypad's modifiers are **Shift for Arrows**, **Option for Arrows** and **Command for Arrows** (Voice Control also answers to **Arrow Shift** and so on), On or Off (selected while on), with the hint "Only the arrow keys use it."; activating one turns it on or off. With an older Mac and a tray modifier on, they read Unavailable and say why. Reduce Motion turns the keypad's scale into a fade.

### Text size and narrow windows (#121)

The receiver adapts to the window and the text size, never to a device model.

- **Main Tray chips** shrink from 40 pt only as far as the screen edge needs (9 chips are 33 pt on a 360 pt phone, 30 pt at the smallest, 320 pt). Hiding a chip you don't use gives the rest more room.
- **Stage Peek's buttons** (Expand / Compact, Add as Tile, Close) show their titles while the row fits the window, and drop to icons when it would not (accessibility text sizes, a 320 pt Slide Over, a long translation). Each button keeps its name for VoiceOver and Voice Control.
- **Video is off** puts **Turn Video On** under the words when they don't fit side by side.
- **Settings** pickers that are segmented become menus at the accessibility text sizes, so no choice is cut off.
- **Session Actions**, the Mac lock banner and Home's rows already wrap or scroll at large text.

Not yet adapted, because it needs a device to judge: the Main Tray's chip size (it is a fixed 30 to 40 pt, not Dynamic Type), pane labels' reserved height at accessibility sizes, and Android.

## Typing

Two things keep what you type visible. Both work only after the Mac has granted this device **Request Control**.

**The typing strip.** When the on-screen keyboard is up, a slim strip sits on top of it. It shows the end of what you have typed in this keyboard session on one right-aligned line, with **Done** at the trailing edge. It mirrors what the Mac received: deletes and autocorrect replacements show as they land, and the word you are still composing is underlined (it is not sent until it is finished). Empty, it reads "Typing to" and your Mac's name. The strip clears when the keyboard closes, and when an arrow, Tab, Escape or a shortcut makes the position unknown. It is a mirror of the keys sent, so text pasted or changed on the Mac by other means never appears. Taps on the strip never reach the Mac.

**Caret follow.** With the keyboard up, the picture follows the text caret on the Mac instead of your last touch, so the line you are typing into stays above the keyboard wherever the display is focused. With **Zoom While Typing** on (also configurable on Android) it uses the usual keyboard zoom and also pans sideways; with it off, it only pans. It moves only when the caret leaves the middle of the visible area, so it does not shake while you type along a line. If the Mac reports no caret, the last touch steers as before.

| | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Typing strip | Yes | Yes | Yes | n/a |
| Caret follow | Yes | Yes | Yes | n/a |

**On the Mac.** Reading the caret needs MeowDisplay to have Accessibility permission (System Settings > Privacy & Security > Accessibility). Without it, caret follow is quietly off. The Mac reads only the caret's rectangle: never the text, how long it is, or the field's name. Password fields are skipped. It reads at most ten times a second, only while the keyboard is up and only for the device that has control. In Window mode it follows the caret in the window being typed into. Apps that do not expose a text caret to Accessibility give no caret and the picture falls back to your last touch: Terminal-style apps that draw their own text, many Electron and Chromium apps, games. Some apps answer only after VoiceOver or another assistive tool is on. A Mac that predates caret follow is never sent the keyboard message, and an older receiver ignores the caret message (PROTOCOL.md 6.11).

## Window mode

Details in [WINDOW_MODE.md](WINDOW_MODE.md).

On iPhone/iPad, **tap** a pane/tab title to focus it or switch tabs. **Press and hold** the title (about 0.4 seconds), then release without dragging, to open its options menu; keep holding and drag to rearrange (drop on **Cancel** to change nothing, or, when moving a whole pane with others left, on **Remove from Layout**). **Double-tap** the title to toggle Fullscreen on This Device. The **Fullscreen on This Device** action only changes the receiver's view, while **Remove from Layout** doesn't close the Mac window. These gestures should not be confused with the separate **Close Window on Mac…** action.

| Control | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Windows as a display mode | Yes | Yes | Yes. A **Windows** chip beside Mirror and Extend | Yes, from the **Windows** button |
| Tiles | Yes. Up to 9 | Yes. Up to 9 | Yes. Up to 9 | Yes. Up to 9 |
| Window overview | Yes | Yes | Yes | Yes |
| Open the overview | Three-finger hold; Settings → Display | Same | Three-finger hold; Settings → Display; rail | **Windows** button, ⌃⌥W |
| Stage Peek (default quick switch) | Yes. Hold the left or right edge | Yes | Yes | No |
| Rail (optional quick switch) | Yes. Controls → Window Switcher | Yes | Yes. Display → Window Switcher | No |
| Stage Peek edge (Left / Right) | Yes | Yes | Yes | n/a |
| Stage Peek **Dock** (Normal / Compact). **Normal** is the default for new installs; a saved choice, Compact included, is kept. On a short screen such as a phone in landscape, Compact's band is short, so its fade and its cards shrink with it: the highlighted card stays clear of the fade and a neighbour shows on each side, and a card is tappable exactly where it is drawn at least half shown. Android: Normal is the default; its Compact band is unchanged | Yes. Settings → Controls → Window Switcher → Dock | Yes | Normal default only | n/a |
| Stage Peek **Expand** and **Add as Tile** | Yes | Yes | Yes | n/a |
| **Full Desktop** card (back to the whole screen) | Yes, in Stage Peek | Yes | Yes | Partial. The overview's **Mirror** and **Extend** buttons |
| **Switch to Window view?** prompt (once per launch, leaves after 8 s) | Yes | Yes | Yes | No |
| Pane options (Fullscreen on This Device, Fit/Fill, Change Window…, Rotate, Arrange Panes, Remove from Layout, Close Window on Mac…) | Yes. Hold title, then release | Yes | Yes | Yes (shared view) |
| **Fill Window on Mac** / **Restore Previous Size on Mac** (pane menu, control only) | Yes | Yes | Not yet | Yes (shared view) |
| Arrange (move, split, resize, layout presets, Undo) | Yes | Yes | Yes | Yes. **Arrange** toggle |
| Per-tile rotation | Yes | Yes | Yes | Yes |
| Hinge-aware tiles on foldables | Yes. Geometry unit-tested only; not yet run on a half-open iPhone Duo or a posed simulator | n/a | Yes. Emulator only | n/a |
| Fold-aware prompts and keyboard bar (iPhone Duo) | Yes. Centred prompts and hints move wholly onto one half; the keyboard bar splits around a book fold and sits above a laptop fold; Demo Mode uses the same regions. Geometry unit-tested only | n/a | No | n/a |
| **Hidden on this screen** when space shrinks | Yes | Yes | Yes | Yes |
| **Typing paused** when another app is in front on the Mac | Yes | Yes | Yes | Yes |

## Display modes

| Control | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Mirror / Extend | Yes. **Display Mode** picker | Yes | Yes. Chips under **Display Mode** | Yes. **Display Mode** control |
| Mirror Display (Auto or pick a display) | Yes | Yes | Yes | Yes |
| Extend Shape, Use Full Display | Yes | Yes | Yes | Yes |
| Video on / off | Yes | Yes | Yes | Yes |
| Streaming Profile, Priority, Maximum FPS | Yes (Display) | Yes | Yes (Display) | Yes (Streaming) |
| Use Less Data (Automatic / On / Off) | Yes (Display) | Yes | Yes (Display ▸ Data Usage). No mobile-data question and no On Mobile Data answer: Automatic saves on Data Saver only. Not yet run on a device | No setting: not sent, never data-saving |
| Picture in Picture | Yes | Yes | Yes | n/a |
| Viewport reset | Double-tap with two fingers | Same | **Reset View** button and the same gesture | n/a |
| Open in Full Screen | n/a | n/a | n/a | Yes. Displays → Video Window |

Streaming Profile and Priority are the Mac's settings and apply to every
connected device. While the Mac's Streaming Mode is **Automatic**, every
receiver shows them read-only with a note to switch the Mac to Custom. In
Custom, each receiver shows the Mac's own Custom frame rate, so picking the
Custom profile doesn't overwrite it. With a Mac too old to report its mode,
the pickers stay editable as before. The Mac declines a request it can't
apply, without restarting any stream. No
receiver can change the Mac's Streaming Mode (Automatic/Custom); that is set
on the Mac only.

**Use Less Data** (Settings ▸ Display, also found by searching "mobile data" or
"Low Data Mode") lowers resolution, bitrate and frame rate on this device's
stream only, while the Mac's Streaming Mode is Automatic. It never stops a
stream, and Custom on the Mac is never overridden.
- **Automatic** (default): saves data when this device or the Mac is in Low
  Data Mode, or on mobile data once you agree. The first time the connection reliably
  looks like mobile data while video plays, the app asks once: "This
  connection may use mobile data. Save data automatically?" The answer is
  remembered and can be changed under **On Mobile Data** (Ask / Save Data /
  Full Quality). Full Quality covers mobile data only: Low Data Mode still
  saves data. A VPN such as Tailscale is not treated as mobile data.
- **On**: always saves data. **Off**: never does, not even in Low Data Mode.
The Mac Receiver has no setting and sends none: the Mac streams to it as
before (no data saving).

On Android the setting is under Display ▸ Data Usage, **Automatic** by default.
Android's equivalent of Low Data Mode is **Data Saver**: Automatic saves data
when Data Saver is on and the connection is metered (or hidden behind a VPN). It
does not ask about mobile data and has no On Mobile Data answer, so a metered
connection alone (cellular, a phone hotspot) keeps full quality. A VPN such as
Tailscale is never treated as mobile data. A change to the setting, the network
or Data Saver reaches the Mac on the live connection. Android sends the setting
and a network cost class only (no SSID, address or carrier), and none of the
adaptive telemetry. Not yet run on a device with a SIM, Data Saver or a VPN.
What the Mac does is in PROTOCOL.md 6.20. Thresholds and the real data saved
are not measured yet (PENDING HARDWARE).

## Audio and connection

| Control | iPhone | iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Audio (Mac system audio; off by default) | Yes. **Audio** | Yes | Yes. **Audio** | Yes. **Audio** |
| A/V Sync (−1000 to +1000 ms, 25 ms steps) | Yes | Yes | Yes | Yes |
| Resync | Yes | Yes | Yes (Audio) | Yes |
| Auto-Reconnect (default on) | Yes | Yes | Yes | Yes |
| Request Control (Mac decides; every session starts View Only) | Yes | Yes | Yes | Yes. Title bar shows View Only or Controlling |
| Request Control Automatically (per Mac) | Yes | Yes | Yes | No |
| Disconnect | **Settings → Connections**, or **Session Actions** → **Disconnect from Mac** | Same | Settings | Overview |
| Back to Home — Keep Connected | Yes. Settings → Connections, **Session Actions**, or the picture's **Back to Home** VoiceOver action | Yes | No | n/a |

**Session Actions** (iPhone and iPad): touch and hold the Settings control (a
haptic confirms) to blur and dim the session under a modal with **Back to Home —
Keep Connected**, **Disconnect from Mac** and **Cancel**. A tap on Settings still
opens Settings. VoiceOver and Voice Control: the Settings control's **Session
Actions** action; the escape gesture, Esc or a tap outside cancels. On iOS 26 and
later a thin red outline follows the screen's corners; earlier versions show no
outline. While it is up nothing reaches the Mac (touch, pointer, scroll, either
keyboard) and anything held is released, so latched modifiers drop; Cancel brings
back the keyboard if it was open and changes nothing else. It is offered only
while connected with the session on screen, and not while a modifier's palette
is open or while Auto-hide has faded the control that holds Settings.

Disconnect from Mac there is the same as Settings → Connections → Disconnect.
It tells the Mac the goodbye is deliberate, so neither side reconnects
automatically (the Mac waits until the device leaves and returns, or someone
presses Connect). The pairing and the Mac app are untouched; the next session
starts View Only, like every session.

**Back to Home — Keep Connected** (iPhone and iPad) shows Home while the session stays up: the
Mac keeps its display and arrangement, and the picture's zoom, Move View, panes and Stage Peek
are as you left them. Home's pinned card offers **Resume** (the same session, no reconnect) and
**Disconnect**; only the session's Mac shows **Connected**, and other Macs can't be connected
or paired until you disconnect. While on Home nothing reaches the Mac (touch, pointer, scroll,
either keyboard; anything held is released first), this device stops drawing the picture and
playing Mac audio (the Mac keeps sending; Resume asks for a fresh frame), and rotating doesn't
reshape the Mac's display until Resume. **Unified Clipboard** keeps working on Home while
MeowDisplay is open: copies from the Mac still arrive, and what you copy elsewhere is offered or
sent as usual. Leaving the app from Home never starts Picture in
Picture; a window already showing keeps playing. **Keep Screen Awake While Streaming** also
covers Home with a kept session, because a device lock ends the session: that costs battery
while you sit on Home, so turn it off or disconnect if you won't be back soon. The interruption
card's **Back to Home** (Connection Lost, Mac Disconnected, Can't Connect) still gives up and
disconnects.

**When input stops** (iPhone and iPad). Input stops in these cases:
- Home covers a kept session.
- Session Actions is open.
- The picture is in Picture in Picture, which is view-only.
- The app isn't active, for example in the background or under Control Center.
- Allow Input is off, or the Mac takes control back.
- The session pauses, ends, reconnects or becomes another Mac's.

Then nothing new reaches the Mac: touch, pointer, scroll, Pencil, gestures, the keyboards and
the tray's keys. Anything held is released: keys, latched modifiers, mouse buttons and drags.
A Window view right-click still waiting for a second tap is dropped. A one-tap sequence that
is still running stops for good, and its remaining steps are never sent, even if input comes
back before the next step. A step's keys always go out together, so stopping never leaves a
key down.

## Gaps

**Android compared with iOS**
- No Back to Home — Keep Connected.
- No Session Actions (touch and hold Settings); Disconnect is in Settings and the Overview.
- Rotation can't target the viewport, and there is no Snap Rotation control (the picture is on a SurfaceView).
- **Prefer MeowDisplay Gestures** is saved but nothing in the app reads it.
- The ⌘ key needs **Control Key Types ⌘** because Android keeps Meta for itself.
- Hardware keyboard, mouse and stylus input are written but not verified on a physical device (iOS keyboard and mouse are also unverified).
- No settings search; Haptics sits under Scrolling on the Input page.
- **Use Less Data** has no mobile-data suggestion or On Mobile Data answer; Automatic follows Data Saver only. Android sends no effective-refresh or adaptive telemetry keys (PROTOCOL.md 6.20), so the Mac keeps its fixed Automatic policy and never runs the adaptive controller for it.

**Mac Receiver compared with the mobile apps**
- No Stage Peek, Rail, Full Desktop card or **Switch to Window view?** prompt. Windows opens the overview.
- No Window Switcher setting, no Local View Navigation, no on-screen trays (its own keyboard and trackpad are the controls).
- No Request Control Automatically.

**iOS compared with Android**
- Windows is not in the Display Mode picker; it is a separate button.
- Settings are spread over twelve pages; Android has eight. Window Switcher is under Controls on iOS but Display on Android; Haptics under General on iOS but Input on Android; Auto-Reconnect under General on iOS but Session on Android.

**All receivers**
- Names for the same setting now match across apps ([TERMINOLOGY.md](TERMINOLOGY.md)). The one deliberate difference is Avoid Notch on iPhone and Avoid Cutouts on Android.
