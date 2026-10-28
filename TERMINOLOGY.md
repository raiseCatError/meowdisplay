# MeowDisplay terminology and copy guide

One vocabulary for the Mac app, Mac Receiver, iPhone/iPad and Android apps, the
website and the docs. Short, plain sentences that tell people what to do.

Tagline: **Mac Everywhere, On Whatever Display**. It appears under About and in
the README, never on a home screen.

Control and settings parity by platform: [RECEIVER_CONTROLS.md](RECEIVER_CONTROLS.md).

## Canonical names

Title Case in labels, buttons and headings; the lowercase form in running
sentences where one is shown. Where an app differs today, the
[inconsistencies](#inconsistencies-found-and-fixed) list says what changed.

### Basics

| Use | Meaning | Don't use |
| --- | --- | --- |
| **Mac app** | MeowDisplay on the Mac that sends its screen | host app, server, sender (fine in code and protocol docs) |
| **this iPhone / this iPad / this device** | the receiving device, in its own app | client, receiver (fine in code), "the display" |
| **Mac Receiver** | MeowDisplay on a Mac that shows another Mac. The app itself is named **MeowDisplay Receiver** (menus, window titles) | |
| **Pair** | the one-time trust step: both screens show the same code, you confirm | link, bond, trust (as a verb) |
| **Codes Match** | the confirm button while pairing | Confirm, OK |
| **Connect** | start a session with a Mac you've paired | stream, start streaming (as a button) |
| **Disconnect** | end the session; pairing stays | stop, close |
| **Forget This Mac** / **Forget This Device** | remove the pairing; pair again to use it. A row that already names the Mac may say just **Forget…** | unpair, remove trust |
| **Allow** / **Not Now** / **Always Allow** / **Block** | the Mac's answers | Accept, Deny (as labels) |
| **Wi-Fi**, **USB**, **Remote** (another network, e.g. Tailscale) | how devices connect | WiFi, wireless, LAN (in UI), tunnel |
| **Auto-Reconnect** | reconnect by itself after a lost connection | Automatic Reconnection |
| **Settings & Help** | the settings entry on a home screen. Inside a session the same screen is titled **Settings** | Preferences, Options |
| **Macs** · **How to Connect** · **This Device** | the home screen: one **Macs** card, then the links **How to Connect** · **Try the Demo** (iPhone/iPad) · **This Device**. This Device shows the name Macs list (and, on Android, the security key) | Your Macs, Nearby Devices, Device Details |
| **Demo** (**Try the Demo** on iPhone/iPad Home) | a sample session with no Mac | tutorial, preview mode |
| **paused** | the Mac paused the picture | frozen, suspended |

### Display and Window mode

| Use | Meaning | Don't use |
| --- | --- | --- |
| **Mirror** | show a Mac display as it is | duplicate, clone, "Mirroring a display" as a label |
| **Extend** | add a separate desktop for this device | second display (in UI), virtual display (in UI), "Extended desktop" as a label |
| **Display Mode** | the setting that holds Mirror and Extend; **Windows** joins them when the Mac offers it | Mode, Touch Mode, What This Device Shows |
| **Windows** | the display-mode label and control: show Mac windows you pick, side by side | app mode, window streaming |
| **Window view** | what you see in Windows: tiles instead of the whole screen. Use it in app copy ("Switch to Window view?") | Window mode (in app copy) |
| **Window mode** | the same thing in docs and prose. Not a button | |
| **Full Desktop** | the whole Mac screen, the way back from Window view. Stage Peek's top card and the overview's Mirror/Extend buttons both go there | Whole display, Desktop mode |
| **tile** | one window's place in Window view | pane, slot (code only) |
| **Stage Peek** | the default window switcher: hold a screen edge, slide to browse, tap a window | peek, flyout. (Stage Manager is the Mac's own feature; Stage Peek is not it) |
| **Rail** | the optional window switcher: a thin handle that opens a strip of windows. **Move Rail** moves it | dock, sidebar, tab bar |
| **Window Switcher** | the setting that chooses **Stage Peek** or **Rail** | Window Picker, Quick Switch |
| **Stage Peek Edge** | **Left** or **Right** | |
| **Hidden on this screen** | tiles that no longer fit | Stacked, Offscreen |
| **Arrange**, **Maximize**, **Restore Layout**, **Rotate**, **Fill Tile** / **Show Whole Window**, **Remove Tile** | tile actions | |
| **Close Window on Mac…** | closes the real Mac window (always confirmed) | close tile |
| **Typing paused** | a tile that is not receiving keys because another app is in front on the Mac | |
| **Switch to Window view?** | the one-time offer on the Full Desktop. **Yes** / **No**; it leaves by itself after 8 seconds | |

### Input and touch

| Use | Meaning | Don't use |
| --- | --- | --- |
| **Input Mode** | the setting: **Direct Touch** or **Trackpad**. "Input" names input-mode settings and the Input settings page only; asking the Mac for permission is "control" | Touch Mode, Pointer Mode |
| **Direct Touch** | touch where you want the pointer | absolute mode, touchscreen mode |
| **Trackpad** | the pointer moves relative to your finger, like a laptop trackpad. "trackpad" lowercase is the physical one | Mouse mode, Relative mode |
| **Touch Style** | the Direct Touch setting: **Natural Touch** (default) or **Classic**. Not shown in Trackpad | Touch Mode |
| **Natural Touch** | tap to click, swipe to scroll, press then move to drag, touch and hold to right-click | Natural (alone), macOS mode |
| **Classic** | the original Direct Touch: the finger is the pointer, tap then hold to drag | Legacy, Old |
| **Smart Touch** (Experimental) | Classic only. Scroll with one finger where the Mac says the area scrolls; hold a title bar to move its window. Brand name; never translated | Smart Scroll |
| **Request Control** | ask the Mac to let this device control it. The same label in Settings and on the screen, on iPhone, iPad, Android and Mac Receiver (title bar) | Request Input, Enable Input, ask for control |
| **Requesting Control…** | the request is waiting for the Mac | Requesting Input…, Requesting… |
| **Control Allowed** | the Mac said yes for this session | Input Allowed, Input Enabled, Allowed for this session |
| **Control Declined** | the Mac said no, or the prompt timed out | Input Declined, Not allowed |
| **Control Not Available** | the Mac doesn't accept control requests from this device. The sentence form is "This Mac isn't accepting control requests" | Input Not Available, Requests disabled by Mac |
| **Controlling** / **Paused** | the Mac Receiver's active states. Paused: control is paused here and a click resumes it | Control Paused |
| **Allow Input** | the Mac app's own master switch. Receivers can't change it. Its per-device policy on the Mac is **Input Requests** (Ask, Always Allow Requests, Never Allow Requests) | |
| **View Only** | the device shows the Mac but can't control it. Every session starts here | read-only, locked, view-only |
| **Request Control Automatically** | per Mac: a blocked touch asks by itself; the Mac still decides | Request Input Automatically |
| **Trackpad Sensitivity** | the speed slider for Trackpad | Trackpad Speed |
| **Local View Navigation** | pan, zoom and reset your own view; never sent to the Mac | |
| **Viewport** / **App** / **Disabled** | what pinch or rotate does | |

### Controls

| Use | Meaning | Don't use |
| --- | --- | --- |
| **control tray** (**Control Tray** in labels) | the tray of modifier and system keys: ⌘ ⌥ ⌃ ⇧ Esc Tab Dock Keyboard Settings | Main Tray, Main Controls (iPad Strip and Overlay layouts only), tool bar |
| **function tray** (**Function Tray**) | the second, independent tray of one-tap shortcuts: Zoom In, Zoom Out, Undo, Redo | shortcut bar, Fn tray |
| **Control Profile** / **Function Profile** | which saved setup each tray uses: Default, Profile 1, Profile 2 | |
| **chord** / **palette** | hold a modifier and a palette of matching shortcuts appears | |
| **Strip**, **Overlay**, **Custom** | iPad and tablet control layouts | |
| **Haptics** | vibration feedback; **Smart Touch Haptics** is the hold feedback | Vibration |
| **Picture in Picture** | a View Only floating window of the Mac while you use other apps | picture-in-picture, PiP (in UI) |
| **Performance Overlay** | live frame rate, bitrate and latency over the picture | Performance overlay, HUD, analytics |

## Tone and writing rules

- **Short, plain verbs.** Tap, hold, drag, choose, turn on, turn off. Not "utilize", "initiate", "toggle", "engage".
- **No jargon the user didn't ask for.** Say "the Mac says the area scrolls", not "the accessibility element is scrollable". Skip protocol, codec, transport and API words in app copy. Fine in PROTOCOL.md.
- Lead with the action: "Tap Pair, then check that both screens show the same code."
- Say who decides: "The Mac decides." "Your Mac confirms it."
- Errors say what happened and what to do next, in that order:
  "Macbook didn't connect. Check that MeowDisplay is open on it and that both are on the same Wi-Fi, then try again."
- Say plainly when something isn't available on a platform ("Not available on Android yet. Use Wi-Fi."). Don't hint at features that aren't there.
- No "simply", "just", "seamlessly", "effortlessly", "Oops", exclamation marks or marketing adjectives in the apps.
- Buttons are verbs in Title Case ("Choose Windows…", "Start Picture in Picture"); an ellipsis means another step follows.
- Toggles are nouns or noun phrases in Title Case ("Auto-Reconnect", "Picture in Picture"); notes under them are sentences.
- Menu items follow the same rule: "Fill Tile", not "Fill tile".
- Name a feature the same way on every screen. If a label and a note use different words for one thing, one of them is wrong.
- Name the Mac by its name when known ("Show Macbook here?"), otherwise "your Mac".
- Numbers keep units: "66 ms", "+250 ms".
- One apostrophe style per app: the straight `'` in the Apple apps and in Android (most strings already used it). Don't mix `'` and `’` in sibling strings.
- Paths in docs use arrows: Settings → Display → Choose Windows…. Keep each name exactly as the app shows it, including the ellipsis.

## Identifiers that must not change

These are in the protocol or in stored data. Change the words people read, never these:

- Wire values: display modes `mirror`, `extend`, `window`; message types such as `windowCatalogRequest`, `workspaceRequest`, `inputRequest`; transport tags compared in code (for example the iOS performance overlay's `"WiFi"` / `"USB"` route values).
- Stored keys: `avSyncOffsetMs`, `pictureInPictureEnabled`, `autoReconnectEnabled`, `showAnalytics`, `wifiRemembered`, `inputMode`, `touchStyle`, `windowSwitcher`, `stagePeekEdge`, `invertVerticalScroll`, the Android `workspace` and `diagnostics` preference files, Bonjour service type `_opensidecar._tcp` and TXT keys.
- Bundle and package identifiers, keychain service names, URL schemes.
- Accessibility identifiers the UI tests use, such as `windowSwitcherPicker`, `stagePeekEdgePicker`, `touchStylePicker`.

## Platform names

What each app calls the same thing today. A blank row is not an inconsistency.

| Concept | Mac app | iPhone / iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Settings entry | Settings… | Settings & Help | Settings & Help | Settings… |
| How to connect | Devices (empty state) | How to Connect | How to Connect | — |
| Window picker | — | Show Mac Windows… / Choose Windows… | Choose Windows… | Windows |
| Window switcher setting | — | Controls → Window Switcher | Display → Window Switcher | — |
| Picture in Picture | — | Picture in Picture | Picture in Picture | — |
| Performance numbers | — | Performance Overlay (Diagnostics) | Performance Overlay (Session) | Performance Overlay (System) |
| Ask for control | Input Requests (policy), Always Allow Requests | Request Control (Settings and on screen) | Request Control (Settings and on screen) | Request Control (title bar) |
| Display Mode setting | Display Mode | Display Mode | Display Mode | Display Mode |
| Help page | — | About | Help | — |


## Inconsistencies found and fixed

Found by reading the string literals in `iOS/`, `Shared/`, `MacReceiver/` and
`AndroidReceiver/` (2026-10-29), reviewed with the product owner, then applied
in code, tests and docs (2026-10-29). **Outcome** is one of: **Done** (applied
as proposed), **Changed** (applied, but the decision differs from the proposal),
**Kept** (the difference is deliberate) or **Already done** (fixed earlier).
Three rows changed on review: the permission to interact with the Mac is
**Request Control** everywhere, not Request Input (rows 1, 28, 30).

The "differs" column records the wording before the change; line numbers refer
to the code at that time. Bare Swift file names are under `iOS/`; bare Kotlin
files are under
`AndroidReceiver/app/src/main/kotlin/com/raisecaterror/meowdisplay/android/`
(`receiver/`, `ui/`, `receiver/workspace/`).

| # | Concept | Where it differed (file:line, text) | Canonical | Outcome |
| --- | --- | --- | --- | --- |
| 1 | Asking the Mac for control | `iOS/ReceiverSettings.swift:623` "Request Control"; `MacReceiver/ReceiverInputController.swift:270` "Request Control"; `MacReceiver/ReceiverInputForwarding.swift:429-434` "Requesting Control…", "Control Declined", "Control Not Available", "Control Allowed", "Control Paused"; `Shared/Protocol.swift:428-432` "Allowed for this session", "Not allowed", "Requests disabled by Mac"; vs `iOS/OpenSidecarPhoneApp.swift:4528` and `ReceiverScreen.kt:459` "Request Input" | **Request Control**, **Requesting Control…**, **Control Allowed**, **Control Declined**, **Control Not Available**. **Controlling** and **Paused** stay as the Mac Receiver's active states | Changed. The proposal was Request Input; the decision is Request Control. Also changed: the iOS and Android on-screen prompt (Enable Input and Request Input both read Request Control; Input Enabled reads Control Allowed), the accessibility hint, Request Control Automatically, the demo controls, Android's Input page status lines and the Mac Receiver's "Control Paused" (now Paused) |
| 2 | The setting for Direct Touch / Trackpad | `ReceiverSettings.kt:160` "Touch Mode"; iOS `ReceiverSettings.swift:645,670` "Input Mode" | **Input Mode** | Done |
| 3 | Trackpad speed | `ReceiverSettings.kt:163` "Trackpad Speed"; iOS "Trackpad Sensitivity" | **Trackpad Sensitivity** | Done |
| 4 | Scroll direction (same preference, on = natural) | iOS `ReceiverSettings.swift:697,699` "Invert Vertical Scrolling" / "Invert Horizontal Scrolling"; Android `ReceiverSettings.kt:188-189` "Natural Vertical Scrolling" / "Natural Horizontal Scrolling" | **Natural Vertical Scrolling** / **Natural Horizontal Scrolling** | Done. Checked first: `ScrollDirectionPolicy` is the same on both platforms (the gesture pipeline delivers natural deltas; on passes them through, off flips that axis) and both default to on, so on is natural scrolling on iOS too. The stored keys `invertVerticalScroll` and `invertHorizontalScroll` are unchanged |
| 5 | The main tray | iOS "Show Control Tray", "Collapse Control Tray", "Auto-hide Control Trays", header "Main Controls", note "Main Tray", editor section "Main Tray"; Android "Main Tray", "Show Controls", "Collapse to Settings Button", "Auto-hide" | **Control Tray** for the section and toggles; "Main Controls" stays only for the iPad Strip and Overlay edge pickers | Done |
| 6 | Keyboard button | iOS "Show Keyboard Button"; Android "Keyboard Button" | **Show Keyboard Button** | Done |
| 7 | Tray profile pickers | iOS "Active Profile", "Function Profile"; Android "Profile" (twice) | **Control Profile** and **Function Profile** | Done |
| 8 | Landscape side | iOS "Landscape Tray Side"; Android "Landscape Side" | **Landscape Tray Side** | Done |
| 9 | Function tray position | iOS "Function Tray Position"; Android "Position" | **Function Tray Position** | Done |
| 10 | Palette style | iOS "Palette Style"; Android "Palette" | **Palette Style** | Done |
| 11 | Control hints | iOS "Show Control Hints"; Android "Control Hints (Strip)" | **Show Control Hints**, with the note "Hints appear on the Strip layout only." on Android | Done |
| 12 | Surface grid | iOS "Show Surface Grid"; Android "Surface Grid When Video Is Off" | **Show Surface Grid**, note "Shown while Video is off." | Done |
| 13 | Local View Navigation | iOS "Allow Local View Navigation"; Android "Local View Navigation" | **Allow Local View Navigation** | Done |
| 14 | Pinch and rotate pickers | iOS "Pinch / Zoom", "Rotation"; Android "Pinch", "Rotate" | **Pinch / Zoom**, **Rotation** | Done |
| 15 | Mac audio toggle | iOS and Mac Receiver "Audio"; Android "Mac Audio" | **Audio** | Done |
| 16 | Notch / cutout | iOS "Avoid Notch"; Android "Avoid Cutouts" (same preference, `avoidNotch`) | Keep both: Android phones have punch-hole cameras, not notches | Kept |
| 17 | Performance overlay | iOS "Performance overlay", "Metal renderer (experimental)"; Android and Mac Receiver "Performance Overlay" | **Performance Overlay**, **Metal Renderer** with an Experimental badge (the same orange badge Smart Touch uses) | Done |
| 18 | Connection log | iOS "Connection log"; Android "Share Connection Log"; Mac Receiver "Reveal Log Files in Finder" | Name the object **Connection Log** everywhere; verbs may differ (Share, Reveal) | Done. iOS, its screen title and search entry; Mac Receiver button "Reveal Connection Log in Finder" and its search entry. The Mac app keeps its own "Reveal Log Files in Finder" |
| 19 | Display Mode setting | iOS "Display Mode"; Android "What This Device Shows"; Mac Receiver picker "Mode" | **Display Mode** | Done |
| 20 | Window view vs Window mode in app copy | iOS and Android "Used in Window mode."; "Switch to Window view?" | **Used in Window view.** "Window mode" stays in docs | Done |
| 21 | The whole-screen side of Window view | "Full Desktop" on the Stage Peek card; "Whole display:" on the overview | **Full Desktop:** as the overview label | Done |
| 22 | Tile menu casing | iOS Title Case; Android sentence case | Title Case, as iOS | Done (Android menu and the emulator smoke test that taps "Remove Tile") |
| 23 | View Only spelling | "view-only", "view only" in Picture in Picture notes and the Android home summary | **View Only**; Picture in Picture note: "It shows your Mac; control stays in MeowDisplay." | Done |
| 24 | Android home summary | "Mirroring a display", "Extended desktop", "Showing Mac windows" | **Mirror**, **Extend**, **Windows**, joined with **View Only** or **Controlling** ("Mirror · View Only") | Done |
| 25 | Picture in Picture | Android "picture-in-picture" | **Picture in Picture** | Done |
| 26 | Settings and Help names | Android page title "Help & About"; the Natural Touch hint said "Settings & Help > Input" | Android page **Help**; hint: "go to Settings → Input" on both platforms | Done |
| 27 | Touch help is out of date | `iOS/ReceiverSettings.swift` "Touch: tap to click, drag to drag, two-finger pan to scroll." | "Touch: tap to click, swipe to scroll, press and move to drag, hold to right-click." | Already done (commit c8d0132) |
| 28 | Mac Receiver says input isn't sent | `MacReceiver/ReceiverOverviewSettingsView.swift:140` "…there is no input permission to request."; the code comment in `ReceiverSettingsCategory.swift` said the same | "Use Request Control in the video window's title bar to control the other Mac with this Mac's keyboard and trackpad." The section is headed **Control** | Changed. The proposal said Request Input; the decision is Request Control. Caption and code comment fixed |
| 29 | "Window" means two things on Mac Receiver | `MacReceiver/ReceiverDisplaysSettingsView.swift:71` section "Window" | Section **Video Window** | Done |
| 30 | Apostrophes and wording | `iOS/OpenSidecarPhoneApp.swift:4531` "isn’t accepting input requests" (curly); `iOS/ReceiverSettings.swift:635` "isn't" (straight); Android "isn't accepting input requests" | One apostrophe style per app, straight `'` (it is what most Apple strings already use, so the curly ones in `iOS/` and `MacReceiver/` were straightened); "control requests" everywhere | Changed. The proposal said "input requests"; the decision is "control requests" |
| 31 | Connect with order | iOS Mirror, then Extend; Android Extend, then Mirror | Mirror, then Extend | Done |
| 32 | Mac app casing | Android "Get the Mac App"; iOS "Get the Mac app" | **Get the Mac app** | Done |
| 33 | Forget | iOS "Forget"; Mac Receiver "Forget…"; Android "Forget This Mac" | **Forget…** in a row that names the Mac (it opens a confirmation); **Forget This Mac** in a menu | Done (iOS row; the confirmation button stays "Forget") |
| 34 | Jargon in a note | Android "when the Mac says the element under it scrolls" | "Scroll with one finger where the Mac says the area scrolls. Hold a title bar, then drag, to move its window." | Done |

34 rows: 29 done, 3 changed on review (1, 28, 30), 1 kept (16), 1 already done
(27). Row 4 was done after checking that on means natural scrolling on both
platforms.

Left alone on purpose: the Mac app's own names **Allow Input** (the master
switch) and **Input Requests** (the per-device policy). They belong to the Mac
that answers requests, not to the receivers that make them. If they should read
"control" too, change them together with the Mac app's Settings search keywords.
The String Catalogs hold only English, so no translations moved; their keys were
renamed to match the new wording.
