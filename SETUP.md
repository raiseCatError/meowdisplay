# MeowDisplay setup guide

This covers building MeowDisplay from source in this repository. See the
[README](README.md) for what the project is and its current capabilities.

## Requirements

- **Xcode 15+** (the Mac sender target's deployment target is macOS 14; the
  Mac Receiver target is macOS 12; the iOS target is iOS/iPadOS 16.4).
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`.
- A free or paid Apple Developer account, to sign the iOS build for your
  device (a free account is enough for local sideloading).

## Clone

```sh
git clone <your fork URL>
cd MeowDisplay
```

## Project generation

This project is generated with `xcodegen`, not committed as a `.xcodeproj`.
There are two YAML specs:

- `project.yml` — tracked, upstream-compatible. Uses upstream-style bundle
  IDs and no personal signing team.
- `project.local.yml` — **local-only**, ignored via `.git/info/exclude` in
  this checkout. Carries this fork's own bundle IDs
  (`com.raisecaterror.meowdisplay.*`) and reads your signing team from `.env`.

Create `.env` in the repo root with your Apple Developer Team ID:

```sh
echo "DEVELOPMENT_TEAM=YOURTEAMID" > .env
```

Your team ID is under **Membership** at
[developer.apple.com/account](https://developer.apple.com/account), or you
can pick your team directly in Xcode's Signing pane after opening the
project.

Generate the project:

```sh
./generate-local.sh
```

This loads `.env` and runs `xcodegen generate --spec project.local.yml`,
producing `MeowDisplay.xcodeproj`.

**Do not** run bare `xcodegen generate` or `./generate.sh` in this checkout —
they read the tracked `project.yml`, which carries upstream's bundle IDs and
no local signing team.

## Opening the project

Open `MeowDisplay.xcodeproj` in Xcode. Three schemes are relevant:

| Scheme | Builds | Platform |
|---|---|---|
| `OpenSidecarMac` | the Mac sender app (MeowDisplay) | macOS 14+ |
| `OpenSidecarMacReceiver` | the standalone receiver app (MeowDisplay Receiver — use a spare Mac as a display) | macOS 12+ |
| `OpenSidecariOS` | the iPhone/iPad receiver app | iOS/iPadOS 16.4+ |

(The scheme names are internal identifiers carried over from this project's
history — they don't appear in the built app's name or UI.)

## Signing

With `CODE_SIGN_STYLE: Automatic` and your team set via `.env`, Xcode
manages provisioning automatically the first time you build each target —
select your team in the target's Signing & Capabilities tab if Xcode asks.

## Building

### Mac sender

```sh
xcodebuild -project MeowDisplay.xcodeproj -scheme OpenSidecarMac \
  -configuration Debug -derivedDataPath build build
```

Or open the project in Xcode and hit Run on the `OpenSidecarMac` scheme.

Once built, `./run.sh` launches the Debug build directly (it also checks that
it's actually built and points you at the build command if not).

### Mac Receiver

```sh
xcodebuild -project MeowDisplay.xcodeproj -scheme OpenSidecarMacReceiver \
  -configuration Debug -derivedDataPath build build
```

### iOS receiver

```sh
xcodebuild -project MeowDisplay.xcodeproj -scheme OpenSidecariOS \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build -allowProvisioningUpdates build
```

For installing on a physical device, build and run the `OpenSidecariOS`
scheme directly from Xcode with your device selected and your Apple ID under
Signing — this handles on-device provisioning for you.

## Required permissions

| Where | Permission | Needed for | If missing |
|---|---|---|---|
| Mac | Screen Recording | capturing the display | black screen on the receiving device |
| Mac | Accessibility | touch/scroll/keyboard input | input does nothing |
| Mac | Local Network | WiFi discovery | no device in the Connection menu |
| iPhone/iPad | Local Network | WiFi discovery | Mac can't find the device |

All live under **Privacy & Security** (macOS) / **Settings** (iOS). The Local
Network permissions are only needed for WiFi mode — USB works without them.
If a prompt never appeared, toggle the entry manually or force-quit and
reopen the app.

## Pairing

On first connection between a Mac and a device, both sides display a short
authentication code (SAS). Confirm it matches on both ends before accepting
— this is what pins the encrypted session to that specific peer going
forward. See [PROTOCOL.md](PROTOCOL.md) for the underlying handshake.

## USB setup

Use a cable that supports data (a charge-only cable will not work). Plug in,
unlock the device, and accept the **Trust This Computer** prompt if it
appears. The Mac app talks to macOS's built-in `usbmuxd` directly — no
tunnel tools needed.

## LAN / WiFi setup

Both devices need Local Network permission (see above) and must be on the
same WiFi network. The receiving device advertises itself over Bonjour; pick
it from the Connection menu on the Mac.

## Remote Access / Tailscale setup

Remote Access lets you reach a paired Mac outside the local network through
a reachable private network address (e.g. a Tailscale endpoint). Install and
sign in to [Tailscale](https://tailscale.com) on both the Mac and the
receiving device, then add the Mac's Tailscale address as a remote endpoint
in the app's connection/endpoint settings. The endpoint address is only a
routing hint — the same pairing-derived encrypted session still authenticates
the connection; see [README.md § Architecture & security summary](README.md#architecture--security-summary).

## Start at Login

Toggle **Start at Login** in the Mac app's settings to have it launch
automatically after you log in.

## Troubleshooting

- **Device doesn't appear over WiFi**: check Local Network permission on
  both sides, confirm both are on the same network, and keep the receiving
  app open in the foreground.
- **USB device doesn't appear**: confirm the cable supports data, that you
  accepted the Trust prompt, and try a different port/cable if it still
  doesn't show up.
- **Logs for a bug report**: on the Mac, click **Logs** in the app panel
  (opens `~/Library/Logs/MeowDisplay` in Finder). On iOS, shake the device or
  open **Settings & Help** → **Connection log**.
- **Pairing fails / trust reset**: forget the device in the app's device
  list and pair again.
