# MeowDisplay setup guide

This covers building MeowDisplay from source, connecting your devices, and
day-to-day use. See the [README](README.md) for what the project is and its
current capabilities.

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

## Using MeowDisplay

### Mirror vs. Extend

In the Mac app's **Displays** settings, **Display Mode** is a segmented
control with two options:

- **Extend** creates a genuine additional display (a virtual display) that
  the receiving device shows — your Mac gains a real second screen, not a
  copy of an existing one. Requires video capture to be enabled.
- **Mirror** streams one of your Mac's actual physical displays as-is.
  Requires an active physical display — the option is unavailable
  (disabled) if none is present, e.g. a closed-clamshell Mac with no
  external monitor.

Switch modes at any time from that picker; when Mirror is selected, a second
**Mirror** section lets you pick which physical display to stream if you
have more than one.

### Audio

System audio streams from the Mac to the connected device automatically
once a session is active — there's no separate audio toggle to enable it.

### Input

Touch, mouse, and keyboard input from the receiving device is routed back
to the Mac and injected as real input events once connected, alongside
supported gestures (two-finger scroll, pinch/rotate, and system gestures
like Spotlight where implemented). This requires the Mac's Accessibility
permission — see [Required permissions](#required-permissions) above.

### Connecting and reconnecting

- **Connect** — tap/click Connect next to a paired device to start a
  session over whichever route (USB, LAN, or Remote Access) is currently
  reachable.
- **Wake & Connect** — if the Mac is asleep, this sends a Wake-on-LAN
  packet and requests interactive wake, then connects automatically once
  the Mac responds. Requires Wake for Network Access enabled on the Mac and
  Wake-on-LAN–capable hardware/firmware; currently local-network only (see
  the README's [Remote Access](README.md#remote-access) section for the
  Tailscale/remote-wake limitation).
- **Auto-Reconnect** (toggle in Mac Settings) keeps a previously connected
  device reconnecting automatically after a drop; turning it off only stops
  *automatic* connecting — Connect, Reconnect, and Wake & Connect still work
  manually, and an already-active session isn't affected.

### Forgetting and re-pairing a device

In the Mac app's Devices list, use **Forget Device** (or **Forget…**) on a
paired device to remove its stored trust. The next connection attempt from
that device will require pairing again, including a fresh SAS confirmation
— see [Pairing](#pairing) above.

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
- **An already-paired device shows "Pair" instead of Connect/Wake & Connect**:
  a known, intermittent issue — the underlying trust check
  (`TrustStore.hasPin(peerID:)` against the Bonjour-advertised peer ID) is
  correct by inspection and hasn't been reliably reproduced. If it happens:
  don't re-pair unnecessarily if you believe trust should still exist; quit
  and reopen the app on both sides first, and only forget/re-pair the device
  if it persists after that.
- **Connection fails generally**: confirm both devices are on the expected
  route (same WiFi network for LAN, a data-capable cable for USB, or a live
  Tailscale/remote endpoint for Remote Access — see below), and that Local
  Network permission is granted (see [Required permissions](#required-permissions)).
- **Display doesn't appear on the receiving device**: check macOS Screen
  Recording permission is granted to the Mac app (a missing grant is the
  most common cause of a black screen) — see
  [Required permissions](#required-permissions).
- **Extend doesn't create a virtual display**: Extend requires video capture
  to be enabled; the Display Mode picker disables Extend if it isn't. Switch
  to Extend from **Displays** settings (see
  [Mirror vs. Extend](#mirror-vs-extend)) and confirm video capture is on.
- **Input does nothing**: grant the Mac's Accessibility permission (see
  [Required permissions](#required-permissions)) — input injection silently
  does nothing without it.
- **No audio**: audio streams automatically once connected; if it's silent,
  confirm the session is actually connected (not just displaying a stale
  frame) and check the Mac's system output/volume isn't muted.
- **USB connection problems**: see USB device doesn't appear, above — a
  charge-only cable is the most common cause.
- **Remote Access doesn't connect**: confirm Tailscale (or your private
  network) is signed in and shows both devices as online, that the Mac's
  Tailscale address entered in the app's Remote Access settings is current,
  and that the Mac isn't asleep (Remote Access wake has the local-only
  limitation described in the README's
  [Remote Access](README.md#remote-access) section).
- **Wake & Connect doesn't work**: confirm Wake for Network Access is
  enabled on the Mac (System Settings → Energy) and that the Mac's
  hardware/firmware supports Wake-on-LAN; this currently only works over
  the local network, not through Remote Access — see the README's
  [Remote Access](README.md#remote-access) section.
