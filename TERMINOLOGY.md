# MeowDisplay terminology and copy guide

One vocabulary for the Mac app, Mac Receiver, iPhone/iPad and Android apps, the
website and the docs. Short, plain sentences that tell people what to do.

Tagline: **Mac Everywhere, On Whatever Display**. It appears under About and in
the README, never on a home screen.

## Words we use

| Use | Meaning | Don't use |
| --- | --- | --- |
| **Mac app** | MeowDisplay on the Mac that sends its screen | host app, server, sender (fine in code and protocol docs) |
| **this iPhone / this iPad / this device** | the receiving device, in its own app | client, receiver (fine in code), "the display" |
| **Mac Receiver** | MeowDisplay on a Mac that shows another Mac | |
| **Pair** | the one-time trust step: both screens show the same code, you confirm | link, bond, trust (as a verb) |
| **Codes Match** | the confirm button while pairing | Confirm, OK |
| **Connect** | start a session with a Mac you've paired | stream, start streaming (as a button) |
| **Disconnect** | end the session; pairing stays | stop, close |
| **Forget This Mac** / **Forget This Device** | remove the pairing; pair again to use it | unpair, remove trust |
| **Mirror** | show a Mac display as it is | duplicate, clone |
| **Extend** | add a separate desktop for this device | second display (in UI), virtual display (in UI) |
| **Windows** (control), **Window mode** (prose) | show Mac windows you pick, side by side | app mode, window streaming |
| **tile** | one window's place in Window mode | pane, slot (code only) |
| **Arrange**, **Maximize**, **Restore Layout**, **Rotate**, **Remove Tile** | tile actions | |
| **Close Window on Mac…** | closes the real Mac window (always confirmed) | close tile |
| **Request Input** | ask the Mac to let this device control it | ask for control, enable input |
| **View Only** | the device shows the Mac but can't control it | read-only, locked |
| **Allow** / **Not Now** / **Always Allow** / **Block** | the Mac's answers | Accept, Deny (as labels) |
| **Wi-Fi**, **USB**, **Remote** (another network, e.g. Tailscale) | how devices connect | WiFi, wireless, LAN (in UI), tunnel |
| **Settings & Help** | the settings entry on a home screen | Preferences, Options |
| **Demo** (Explore Demo) | a sample session with no Mac | tutorial, preview mode |
| **paused** | the Mac paused the picture | frozen, suspended |

## Writing rules

- Lead with the action: "Tap Pair, then check that both screens show the same code."
- Say who decides: "The Mac decides." "Your Mac confirms it."
- Errors say what happened and what to do next, in that order:
  "Macbook didn't connect. Check that MeowDisplay is open on it and that both are on the same Wi-Fi, then try again."
- Say plainly when something isn't available on a platform ("Not available on Android yet. Use Wi-Fi."). Don't hint at features that aren't there.
- No "simply", "just", "seamlessly", "effortlessly", "Oops", exclamation marks or marketing adjectives in the apps.
- Buttons are verbs in Title Case ("Choose Windows…", "Start Picture in Picture"); an ellipsis means another step follows.
- Toggles are nouns or noun phrases in Title Case ("Auto-Reconnect", "Picture in Picture"); notes under them are sentences.
- Name the Mac by its name when known ("Show Macbook here?"), otherwise "your Mac".
- Numbers keep units: "66 ms", "+250 ms".

## Identifiers that must not change

These are in the protocol or in stored data. Change the words people read, never these:

- Wire values: display modes `mirror`, `extend`, `window`; message types such as `windowCatalogRequest`, `workspaceRequest`, `inputRequest`; transport tags compared in code (for example the iOS performance overlay's `"WiFi"` / `"USB"` route values).
- Stored keys: `avSyncOffsetMs`, `pictureInPictureEnabled`, `autoReconnectEnabled`, `showAnalytics`, `wifiRemembered`, the Android `workspace` and `diagnostics` preference files, Bonjour service type `_opensidecar._tcp` and TXT keys.
- Bundle and package identifiers, keychain service names, URL schemes.

## Platform names

| Concept | Mac app | iPhone / iPad | Android | Mac Receiver |
| --- | --- | --- | --- | --- |
| Settings entry | Settings… | Settings & Help | Settings & Help | Settings… |
| How to connect | Devices (empty state) | How to Connect | How to Connect | — |
| Window picker | — | Choose Windows… | Choose Windows… | Windows |
| Picture in Picture | — | Picture in Picture | Picture in Picture | — |
| Performance numbers | — | Performance overlay | Performance Overlay | — |
