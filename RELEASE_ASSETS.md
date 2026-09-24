# Release screenshots and assets checklist

What's already in place, and exactly what needs physical capture before a
public beta/release. No screenshots are fabricated here — this is a
checklist for the maintainer to work through with real hardware.

## Already exist

- App icons for Mac, Mac Receiver, and iOS (`Mac/Assets.xcassets`,
  `MacReceiver/Assets.xcassets`, `iOS/Assets.xcassets`) — complete size sets
  for each platform, including the Debug variant icon.
- Marketing site assets in `assets/`/`public/`: `Github Readme Icon.png`,
  `MeowDisplay-mark.png`, `logo.png`, `icon.png`/`icon-256.png`, `og.png`
  (social share preview).
- No in-app product screenshots exist yet anywhere in the repo — the README
  currently only shows the icon, no screen captures.

## Still needs physical capture

For each item: what to show, and what to avoid.

### README / GitHub

| Screenshot | Show | Avoid |
|---|---|---|
| Hero image | The Mac app actively connected to a device, with a clean desktop/wallpaper | Personal files, real usernames, real device names |
| Mac menu bar / overview | The Mac app's main overview panel with a connected device | Sensitive window content in the background |
| iPhone/iPad connected view | The receiving device showing the Mac's extended or mirrored display | Personal photos/notifications visible on the Mac's real screen |

### Feature explanation

| Screenshot | Show | Avoid |
|---|---|---|
| Mirror mode | Receiving device showing a mirrored physical display | — |
| Extend mode | Receiving device showing the virtual extended display in use (e.g. a window dragged onto it) | — |
| Remote Access | The Remote Access settings pane with a Tailscale endpoint configured | The actual Tailscale address/hostname — redact or use a placeholder |
| Pairing / SAS | The SAS confirmation screen on both devices | — |
| Settings overview | Devices, Displays, and Security settings panes | Any real paired-device names if they reveal personal info |

### TestFlight / App Store (only needed once Issue tracking iOS submission proceeds)

- Required iPhone screenshot sizes and iPad screenshot sizes (if the app is
  submitted as universal) must be checked against **current** App Store
  Connect requirements at submission time — sizes change between Apple's
  device generations and aren't hardcoded here to avoid going stale.
- `fastlane/APP_STORE_LISTING.md` already has the text fields drafted;
  screenshots are the remaining gap for that submission.

## Capture guidance

- Use a clean desktop/wallpaper and a throwaway or clearly-fake device name
  where the UI shows one.
- Prefer a realistic but unremarkable window/content on the "extended"
  display (a code editor, a document) rather than truly personal content.
- Device mockups/frames around screenshots are optional — plain captures
  are acceptable for README use; App Store screenshots may benefit from
  Apple's official device frame templates.
- Save originals at full resolution; downscale copies for README/web use to
  keep the repo lean.

## Not blocking

None of the above blocks any other release-preparation work — every doc in
this repository can and does describe MeowDisplay accurately without inline
screenshots. This checklist exists so the maintainer knows exactly what to
capture when ready, not to gate other progress on it.
