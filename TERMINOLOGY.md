# MeowDisplay terminology and copy guide

One vocabulary for the Mac app, Mac Receiver, iPhone/iPad and Android apps, the
website and the docs. Short, plain sentences that tell people what to do.

Tagline: **Mac Everywhere, On Whatever Display**. It appears under About and in
the README, never on a home screen.

Control and settings parity by platform: [RECEIVER_CONTROLS.md](RECEIVER_CONTROLS.md).

## Canonical names

Title Case in labels, buttons and headings; the lowercase form in running
sentences where one is shown. Where an app differs today, the
[inconsistencies](#inconsistencies-found-proposals-only) list says where.

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
| **Demo** (Explore Demo) | a sample session with no Mac | tutorial, preview mode |
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
| **Input Mode** | the setting: **Direct Touch** or **Trackpad** | Touch Mode, Pointer Mode |
| **Direct Touch** | touch where you want the pointer | absolute mode, touchscreen mode |
| **Trackpad** | the pointer moves relative to your finger, like a laptop trackpad. "trackpad" lowercase is the physical one | Mouse mode, Relative mode |
| **Touch Style** | the Direct Touch setting: **Natural Touch** (default) or **Classic**. Not shown in Trackpad | Touch Mode |
| **Natural Touch** | tap to click, swipe to scroll, press then move to drag, touch and hold to right-click | Natural (alone), macOS mode |
| **Classic** | the original Direct Touch: the finger is the pointer, tap then hold to drag | Legacy, Old |
| **Smart Touch** (Experimental) | Classic only. Scroll with one finger where the Mac says the area scrolls; hold a title bar to move its window. Brand name; never translated | Smart Scroll |
| **Request Input** | ask the Mac to let this device control it | Request Control, ask for control, enable input |
| **Allow Input** | the Mac's own master switch. Receivers can't change it | |
| **View Only** | the device shows the Mac but can't control it. Every session starts here | read-only, locked, view-only |
| **Input Allowed** | the Mac said yes for this session | Allowed for this session |
| **Request Input Automatically** | per Mac: a blocked touch asks by itself; the Mac still decides | |
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
| **Picture in Picture** | a view-only floating window of the Mac while you use other apps | picture-in-picture, PiP (in UI) |
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
- Use the typographic apostrophe consistently within an app; don't mix `'` and `’` in sibling strings.
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
| Performance numbers | — | Performance overlay (Diagnostics) | Performance Overlay (Session) | Performance Overlay (System) |
| Ask for control | Input Requests (policy), Always Allow Requests | Request Control (Settings), Request Input (on screen) | Request Input | Request Control |
| Display Mode setting | Display Mode | Display Mode | What This Device Shows | Mode, under Display Mode |

## Inconsistencies found (proposals only)

Found by reading the string literals in `iOS/`, `Shared/`, `MacReceiver/` and
`AndroidReceiver/` (2026-10-29). **Fix** means the proposal should become the
canonical wording; **Keep** means the difference is deliberate. Nothing here has
been changed in code; UI tests depend on exact strings, so change string and
test together.

File paths: a bare `ReceiverSettings.swift` is `iOS/ReceiverSettings.swift`.
Bare Kotlin files are under
`AndroidReceiver/app/src/main/kotlin/com/raisecaterror/meowdisplay/android/`
(`receiver/`, `ui/`, `receiver/workspace/`).

| # | Concept | Where it differs (file:line, text) | Proposed canonical | Verdict |
| --- | --- | --- | --- | --- |
| 1 | Asking the Mac for control | `iOS/ReceiverSettings.swift:623` "Request Control"; `MacReceiver/ReceiverInputController.swift:270` "Request Control"; `MacReceiver/ReceiverInputForwarding.swift:429-434` "Requesting Control…", "Control Declined", "Control Not Available", "Control Allowed", "Control Paused"; `Shared/Protocol.swift:428-432` "Allowed for this session", "Not allowed", "Requests disabled by Mac"; vs `iOS/OpenSidecarPhoneApp.swift:4528` and `AndroidReceiver/.../ReceiverScreen.kt:459` "Request Input" | **Request Input**, **Requesting Input…**, **Input Allowed**, **Input Declined**, **Input Not Available**; **Controlling** may stay as the Mac Receiver's active state, with **Paused** | Fix |
| 2 | The setting for Direct Touch / Trackpad | `AndroidReceiver/.../ReceiverSettings.kt:160` "Touch Mode"; iOS `ReceiverSettings.swift:645,670` "Input Mode" | **Input Mode** | Fix |
| 3 | Trackpad speed | `ReceiverSettings.kt:163` "Trackpad Speed"; iOS `ReceiverSettings.swift:674,685` "Trackpad Sensitivity" | **Trackpad Sensitivity** | Fix |
| 4 | Scroll direction (same preference, on = natural) | iOS `ReceiverSettings.swift:697,699` "Invert Vertical Scrolling" / "Invert Horizontal Scrolling"; Android `ReceiverSettings.kt:188-189` "Natural Vertical Scrolling" / "Natural Horizontal Scrolling" | **Natural Vertical Scrolling** / **Natural Horizontal Scrolling** (on is the default; "Invert" reads backwards) | Fix |
| 5 | The main tray | iOS `ReceiverSettings.swift:849,853,854` "Show Control Tray", "Collapse Control Tray", "Auto-hide Control Trays", header `:869` "Main Controls", note `:943` "Main Tray"; Android `ReceiverSettings.kt:211-213` "Main Tray", "Show Controls", "Collapse to Settings Button" | **Control Tray** for the section and toggles; keep "Main Controls" only for the iPad Strip and Overlay edge pickers | Fix |
| 6 | Keyboard button | iOS `ReceiverSettings.swift:852` "Show Keyboard Button"; Android `ReceiverSettings.kt:214` "Keyboard Button" | **Show Keyboard Button** | Fix |
| 7 | Tray profile pickers | iOS `ReceiverSettings.swift:895,925` "Active Profile", "Function Profile"; Android `ReceiverSettings.kt:215,220` "Profile" (twice, for different trays) | **Control Profile** and **Function Profile** | Fix |
| 8 | Landscape side | iOS `ReceiverSettings.swift:857` "Landscape Tray Side"; Android `ReceiverSettings.kt:216` "Landscape Side" | **Landscape Tray Side** | Fix |
| 9 | Function tray position | iOS `ReceiverSettings.swift:920` "Function Tray Position"; Android `ReceiverSettings.kt:221` "Position" | **Function Tray Position** | Fix |
| 10 | Palette style | iOS `ReceiverSettings.swift:1019` "Palette Style"; Android `ReceiverSettings.kt:232` "Palette" | **Palette Style** | Fix |
| 11 | Control hints | iOS `ReceiverSettings.swift:1025` "Show Control Hints"; Android `ReceiverSettings.kt:236` "Control Hints (Strip)" | **Show Control Hints**, with the Strip-only note below | Fix |
| 12 | Surface grid | iOS `ReceiverSettings.swift:330` "Show Surface Grid"; Android `ReceiverSettings.kt:263` "Surface Grid When Video Is Off" | **Show Surface Grid**, note "Shown while Video is off." | Fix |
| 13 | Local View Navigation | iOS `ReceiverSettings.swift:782` "Allow Local View Navigation"; Android `ReceiverSettings.kt:199` "Local View Navigation" | **Allow Local View Navigation** | Fix |
| 14 | Pinch and rotate pickers | iOS `ReceiverSettings.swift:759,761` "Pinch / Zoom", "Rotation"; Android `ReceiverSettings.kt:194,198` "Pinch", "Rotate" | **Pinch / Zoom**, **Rotation** | Fix |
| 15 | Mac audio toggle | iOS `ReceiverSettings.swift:1078` and Mac Receiver `ReceiverStreamingSettingsView.swift:139` "Audio"; Android `ReceiverSettings.kt:288` "Mac Audio" | **Audio** | Fix |
| 16 | Notch / cutout | iOS `ReceiverSettings.swift:863` "Avoid Notch"; Android `ReceiverSettings.kt:225` "Avoid Cutouts" (same preference, `avoidNotch`) | Keep both: Android phones have punch-hole cameras, not notches | Keep |
| 17 | Performance overlay | iOS `ReceiverSettings.swift:1299` "Performance overlay", `:1301` "Metal renderer (experimental)"; Android `ReceiverSettings.kt:320` and Mac Receiver `ReceiverSystemSettingsView.swift:49` "Performance Overlay" | **Performance Overlay**, **Metal Renderer** with an Experimental badge | Fix |
| 18 | Connection log | iOS `ReceiverSettings.swift:1293` "Connection log"; Android `HelpPage.kt:72` "Share Connection Log"; Mac Receiver `ReceiverSystemSettingsView.swift:64` "Reveal Log Files in Finder" | Name the object **Connection Log** everywhere; verbs may differ (Share, Reveal) | Fix |
| 19 | Display Mode setting | iOS `ReceiverSettings.swift:372` "Display Mode"; Android `ReceiverSettings.kt:247` "What This Device Shows"; Mac Receiver `ReceiverDisplaysSettingsView.swift:87` picker "Mode" under header `:119` "Display Mode" | **Display Mode** | Fix |
| 20 | Window view vs Window mode in app copy | `iOS/ReceiverSettings.swift:892` and `ReceiverSettings.kt:284` "Used in Window mode."; vs `iOS/OpenSidecarPhoneApp.swift:4467` and `StagePeekOverlay.kt:706` "Switch to Window view?" | **Used in Window view.** Keep "Window mode" for docs | Fix |
| 21 | The whole-screen side of Window view | `iOS/StagePeekView.swift:136` and `StagePeekOverlay.kt:347` "Full Desktop"; `Shared/WorkspaceViews.swift:356` and `WorkspaceOverlay.kt:409` "Whole display:"; subtitle "Show the whole Mac screen" | **Full Desktop:** as the overview label | Fix |
| 22 | Tile menu casing | iOS `Shared/WorkspaceViews.swift:152-159` Title Case ("Arrange Tiles", "Remove Tile", "Show Whole Window"); Android `WorkspaceOverlay.kt:202-210` sentence case ("Arrange tiles", "Remove tile", "Show whole window", "Type here") | Title Case, as iOS | Fix |
| 23 | View Only spelling | `ReceiverInputForwarding.swift:428` and Android `ReceiverSettings.kt:158,417` "View Only"; `iOS/ReceiverSettings.swift:336` and `DemoMode.swift:295` "view-only"; Android `ReceiverSettings.kt:268` and `ReceiverHome.kt:247` "view only" | **View Only**; reword the Picture in Picture note: "It shows your Mac; control stays in MeowDisplay." | Fix |
| 24 | Android home summary | `AndroidReceiver/.../ReceiverHome.kt:242-244` "Mirroring a display", "Extended desktop", "Showing Mac windows" | **Mirror**, **Extend**, **Windows** (for example "Mirror · View Only") | Fix |
| 25 | Picture in Picture | iOS `ReceiverSettings.swift:335` "Picture in Picture"; Android `ReceiverSettings.kt:267` "picture-in-picture" | **Picture in Picture** | Fix |
| 26 | Settings and Help names | `ReceiverHome.kt:102` and `iOS/OpenSidecarPhoneApp.swift:1522` "Settings & Help"; Android page title `ReceiverSettings.kt:81` "Help & About" (words reversed; iOS calls it "About"); the Natural Touch hint (`OpenSidecarPhoneApp.swift:4559`, `ReceiverScreen.kt:385`) says "Settings & Help > Input" but the in-session screen is titled "Settings" (`iOS/ReceiverSettings.swift:57`, `ReceiverSettings.kt:104`) | Android page **Help**; hint: "go to Settings → Input" | Fix |
| 27 | Touch help is out of date | `iOS/ReceiverSettings.swift:1160` "Touch: tap to click, drag to drag, two-finger pan to scroll." describes Classic; Natural Touch is the default | "Touch: tap to click, swipe to scroll, press then move to drag." | Fix |
| 28 | Mac Receiver says input isn't sent | `MacReceiver/ReceiverOverviewSettingsView.swift:140` "This Mac only displays the stream. Its keyboard and trackpad are not sent to the other Mac, so there is no input permission to request." but `ReceiverInputController.swift:270` offers **Request Control** (see RECEIVER_INPUT.md). Code comment `ReceiverSettingsCategory.swift:7-8` says the same | "Use Request Input in the video window's title bar to control the other Mac with this Mac's keyboard and trackpad." | Fix |
| 29 | "Window" means two things on Mac Receiver | `MacReceiver/ReceiverDisplaysSettingsView.swift:71` section "Window" holds Open in Full Screen and Show Window; Window mode is also in this app (Windows button) | Section **Video Window** | Fix |
| 30 | Apostrophes and wording | `iOS/OpenSidecarPhoneApp.swift:4531` "isn’t accepting input requests" (curly); `iOS/ReceiverSettings.swift:635` "isn't accepting control requests" (straight); Android `ReceiverScreen.kt:462`, `ReceiverSettings.kt:416` "isn't accepting input requests" | One apostrophe style per app; "input requests" everywhere | Fix |
| 31 | Connect with order | iOS `OpenSidecarPhoneApp.swift:1578-1579` Mirror, then Extend; Android `ReceiverHome.kt:141-142` Extend, then Mirror | Mirror, then Extend, as in every other list | Fix |
| 32 | Mac app casing | Android `HelpPage.kt:62` "Get the Mac App"; iOS `ReceiverSettings.swift:1378` "Get the Mac app" | **Get the Mac app** | Fix |
| 33 | Forget | iOS `ReceiverSettings.swift:1190` "Forget"; Mac Receiver `ReceiverDevicesSettingsView.swift:78` "Forget…"; Android `ReceiverHome.kt:148` "Forget This Mac" | **Forget…** in a row that names the Mac (it opens a confirmation); **Forget This Mac** in a menu | Fix |
| 34 | Jargon in a note | Android `ReceiverSettings.kt:181` "when the Mac says the element under it scrolls"; iOS `ReceiverSettings.swift:730` is plainer | "Scroll with one finger where the Mac says the area scrolls. Hold a title bar, then drag, to move its window." | Fix |

34 differences: 33 to fix, 1 to keep (#16). Items 27 and 28 are stale copy that
contradicts the product. Docs that follow the old wording today: README.md and SETUP.md say
"Request Control" (matches iOS Settings), and RECEIVER_INPUT.md says "Request
Control" and "Controlling". Update them with items 1 and 28, not before.
