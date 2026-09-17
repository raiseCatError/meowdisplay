<div align="center">

<img src="assets/AppIcon-master.png" alt="MeowDisplay icon" width="128" height="128">

# MeowDisplay

**MEOW — Mac Everywhere, On Whatever Display**

*Mac, Every Other Way*

</div>

MeowDisplay turns an iPhone or iPad into a secure remote display and control
surface for your Mac — locally over USB or WiFi, or remotely through a
reachable private network such as Tailscale. It began as a fork of the
open-source [OpenDisplay](#meowdisplay-and-opendisplay) project and has grown
in a broader remote-access direction: secure pairing, remote connectivity,
audio, reconnect/wake workflows, and device control on top of OpenDisplay's
original display/capture/encoding foundation.

**Primary tested configuration: Mac host → iPhone receiver.** Other
combinations below may already work but aren't yet as thoroughly validated —
see [Platform status](#platform-status).

<p align="center">
<a href="#getting-started">Getting Started</a> ·
<a href="#features">Features</a> ·
<a href="#how-it-works">How it works</a> ·
<a href="#platform-status">Platform status</a> ·
<a href="#roadmap">Roadmap</a> ·
<a href="#want-to-contribute">Contributing</a> ·
<a href="#architecture--security-summary">Security</a>
</p>

---

## Why MeowDisplay?

Most "use your iPad as a second monitor" tools stop at mirroring a screen.
MeowDisplay's direction is broader: making a Mac genuinely *reachable and
usable* from another device — not just viewable. That means real input
(touch, mouse, keyboard, system gestures) routed back to the Mac, system
audio, secure paired sessions instead of an open port, and connectivity that
follows you from the same room to a different network entirely, without
requiring an account, a subscription, or a proprietary relay service.

The goal isn't to be "another second-monitor clone" — it's a Mac you can
reach from whatever display or device you have on hand, on your own network
terms.

## Features

### Display & media
- True extended display or mirrored output from the Mac, Retina-sharp,
  low-latency (hardware H.264 encode via VideoToolbox, capture via
  ScreenCaptureKit).
- Virtual display creation (`CGVirtualDisplay`) for extend mode, alongside
  physical-display mirror/capture modes.
- System audio streaming from the Mac to the receiving device.
- Display/mirror source selection on the receiving side.

### Input & control
- Touch, mouse, and keyboard input routed from the receiving device back to
  the Mac and injected as real input events.
- Two-finger scroll, configurable pinch/rotate and other gesture behavior.
- Application and system gestures (e.g. Spotlight) where implemented.

### Connectivity
- **USB** over macOS's built-in `usbmuxd` — no helper tools.
- **LAN/WiFi** with zero-config discovery via Bonjour, including automatic
  AWDL (peer-to-peer WiFi) route detection.
- **Remote Access** over a reachable private network such as Tailscale.
- **Auto-Reconnect**, configurable.

### Wake & reliability
- Local Wake-on-LAN groundwork (tested core logic) and a one-tap "Wake &
  Connect" flow with post-wake interactive promotion are in active
  development — currently available in Debug builds while this stabilizes
  for a general release (see [Roadmap](#roadmap)).
- Session/generation-guarded reconnect so a dropped route resumes cleanly.

### Experience
- Dock, Menu Bar, or Dock & Menu Bar operating modes.
- Start at Login.
- **MeowDisplay Receiver** — use a spare Mac itself as a display, where
  implemented.

### Security
- **Secure device pairing** — a short authentication code (SAS) confirmed on
  both ends before a session is trusted.
- **Pinned, encrypted transport** for wireless and remote sessions — no
  plaintext wireless fallback.
- A remote endpoint (like a Tailscale address) is a **routing hint, not an
  identity** — see [Architecture & security summary](#architecture--security-summary).

## How it works

```text
MAC HOST                                          RECEIVER (iPhone/iPad/Mac)
  display source (physical or CGVirtualDisplay)
       │
       ▼
  ScreenCaptureKit  ──capture──▶  VideoToolbox (H.264 hw encode)
       │
       ▼
  pinned, encrypted transport  ────────────────▶  decode + render
  (USB / LAN / AWDL / Remote)  ◀────────────────  touch · mouse · keyboard
       ▲                                               │
       │                                               ▼
  CGEvent / input injection  ◀──authenticated control──┘
```

- **Discovery** is local via **Bonjour**; USB is discovered separately over
  `usbmuxd`. Neither step grants trust by itself.
- **Route** (USB, LAN, AWDL, or Remote) is classified automatically once a
  connection is live — it changes how the bytes travel, not who's on the
  other end.
- **Trust** comes from the pinned, encrypted session established during
  pairing, regardless of which route carried the connection. A remote
  endpoint address (e.g. Tailscale) only gets you *to* a peer — it doesn't
  authenticate one.

The full wire protocol is specified in [PROTOCOL.md](PROTOCOL.md); how it
evolves across releases is in [COMPATIBILITY.md](COMPATIBILITY.md).

## Getting Started

**macOS** — build from source today (see below); signed/notarized direct
downloads are planned.

**iOS** — build and install through Xcode today; a TestFlight beta is
planned.

```sh
git clone <your fork URL>
cd MeowDisplay
echo "DEVELOPMENT_TEAM=YOURTEAMID" > .env
./generate-local.sh
```

Then open `MeowDisplay.xcodeproj` and run the `OpenSidecarMac` (Mac sender)
and `OpenSidecariOS` (iPhone/iPad receiver) schemes. Full instructions —
signing, permissions, USB/WiFi/Remote Access setup, pairing, and
troubleshooting — are in **[SETUP.md](SETUP.md)**.

## Platform status

**Primary tested:**
- Mac host → iPhone receiver

**Exists, needs broader validation:**
- iPad receiver
- MeowDisplay Receiver (spare Mac as a display)
- Multiple Macs, different Mac models/display combinations

**Planned / community roadmap:**
- Android and Linux clients
- Broader headless/clamshell validation
- Additional hardware/platform combinations
- Stylus/pen support

If code already exists for a configuration, we say "needs broader
validation," not "doesn't work" — see [Want to contribute?](#want-to-contribute)
if you can help test one.

## Remote Access

MeowDisplay can connect to a paired Mac through any reachable address, not
just the local network. [Tailscale](https://tailscale.com) (or an equivalent
private network) is the recommended way to get that reachability — install
and sign in on both devices, then add the Mac's Tailscale address as a
remote endpoint.

Tailscale is **not** MeowDisplay's authentication system. The endpoint
address is only routing information — a way to find the peer. Actual trust
still comes from the pinned, encrypted transport established during pairing,
the same as any other route.

One current honest limitation: MeowDisplay can't magically send a
local-network Wake-on-LAN packet through a sleeping Mac's Tailscale node —
WoL is a LAN broadcast, and a sleeping Mac's Tailscale link isn't reachable
to relay one in. Waking a Mac remotely over Tailscale isn't solved yet; see
[Roadmap](#roadmap).

## FAQ

**Why does macOS show the purple screen-recording indicator?**
macOS shows that indicator for any app capturing the screen — MeowDisplay
included. It's a system-level privacy signal, not something an app can
suppress.

**Why can't MeowDisplay see my iPhone over WiFi?**
Check Local Network permission on both the Mac and the device, confirm both
are on the same network, and keep the receiving app open. See
[SETUP.md](SETUP.md#troubleshooting).

**Does it work over USB?**
Yes — plug in with a data-capable cable, accept the Trust prompt, and it
connects without any network setup.

**Can I use it away from home?**
Yes, via [Remote Access](#remote-access) over a reachable private network
like Tailscale.

**Does it require Tailscale?**
No. Tailscale is only needed for Remote Access; USB and same-network WiFi
work without it.

**Can it wake a sleeping Mac?**
Local Wake-on-LAN groundwork exists and a one-tap wake/reconnect flow is in
active development (currently Debug-build only). Waking a Mac remotely over
Tailscale isn't solved yet — see [Remote Access](#remote-access).

**Does iPad work?**
The receiver runs on iPad, but it isn't the primary tested configuration
yet — see [Platform status](#platform-status).

**Can another Mac be the receiver?**
Yes, using the separate **MeowDisplay Receiver** app, where implemented —
see [Platform status](#platform-status).

**Why isn't the iOS app on TestFlight/the App Store yet?**
It's planned but not live yet — see [Getting Started](#getting-started)
and [Roadmap](#roadmap).

**Why does MeowDisplay use `CGVirtualDisplay`, a private API?**
It's the same technique used by other virtual-display tools (e.g.
BetterDisplay, DeskPad) to create a genuine extended display rather than a
mirror. There's no public API for this yet.

**Does closing the Settings window stop the app?**
No — the Mac app keeps running (Dock, Menu Bar, or both, depending on your
chosen operating mode).

**What happens to my pairing/security data?**
Pairing trust is stored locally on your own devices; see
[Architecture & security summary](#architecture--security-summary) for how
it's used, and [PROTOCOL.md](PROTOCOL.md) for the underlying handshake.

## Architecture & security summary

- Local discovery uses **Bonjour** — unchanged from upstream, for
  compatibility with any client speaking the same protocol.
- Remote endpoints (e.g. a Tailscale address) are **routing hints, not
  identity** — they get you to a peer, they don't authenticate it.
- Wireless and remote sessions authenticate using the existing **pinned,
  encrypted transport** established during pairing — the same trust model
  regardless of how the peer was reached.
- **Tailscale** (or an equivalent private network) is optional, recommended
  networking for Remote Access — not itself an authentication mechanism.
- There is **no plaintext wireless fallback**.

## Roadmap

Distinguishing **planned** work (intended, not merely an idea) from
**future** (longer-term direction). No dates are promised for either.

### Planned

- **Wake & Connect out of Debug** — take the current Debug-only one-tap
  wake/reconnect/interactive-promotion flow to a shipped, general-release
  feature.
- **Headless / display-topology support** — external-display configurations,
  built-in-only, true clamshell/headless, a deterministic MeowDisplay-owned
  virtual-display fallback where needed. The private `CGVirtualDisplay` path
  stays isolated until a public equivalent exists.
- **Release preparation** — final branding/assets, Sparkle/update
  validation, Developer ID signing/notarization, packaging, setup/permission
  polish.
- **Security/release review** — full code/security review, pairing/trust
  review, remote/session review, authenticated peer-identity hardening,
  protocol/versioning review.
- **iOS public distribution** — TestFlight planned as soon as possible;
  broader device/multi-Mac validation before wider release or App Store
  submission.
- **Broader platform/hardware validation** — multiple Macs, MeowDisplay
  Receiver, different display/network combinations.
- **Android support.**
- **Linux support.**

### Future

Longer-term direction, not required for the first public beta:

- Cold boot / fully logged-out LoginWindow remote access (**not** required
  for the first MeowDisplay public beta).
- Apple persistent remote-desktop capability work, where appropriate.
- A QUIC transport experiment plus a separate security review (**not** part
  of the current release plan).
- An integrated remote Wake-on-LAN relay/router solution (the Remote Access
  wake limitation above).
- Apple Pencil / stylus improvements, including Android/Linux pen-device
  support.
- Cat Mode and other later extras.

## Want to contribute?

MeowDisplay is actively developed, and community hardware testing is very
welcome — especially on hardware the maintainer can't currently test
reliably:

- iPad receiver behavior
- Android devices
- Linux
- Multiple-Mac environments
- MeowDisplay Receiver behavior
- Different Mac models
- Clamshell/headless configurations
- Unusual external-display combinations
- Different routers/networks
- Stylus/pen hardware

These are useful open-source contribution and testing opportunities, not
gaps to apologize for. Please open or claim an issue before starting any
large architecture work.

## MeowDisplay and OpenDisplay

MeowDisplay began as a fork of [OpenDisplay](https://github.com/peetzweg/opendisplay)
by Philip Poloczek — a free, open-source alternative to Apple Sidecar, Duet
Display, and Luna Display that turns spare Apple devices into second
monitors for a Mac. OpenDisplay provided the original display/capture/
encoding/receiver foundation this project is built on; OpenDisplay's own
website, TestFlight beta, and community client projects (Android/Linux
receivers and senders speaking the same wire protocol) are linked from its
repository.

MeowDisplay has since followed a broader remote-display/control direction,
expanding substantially in areas like secure pairing, remote connectivity,
system audio, wake/reconnect workflows, and device control. This isn't a
claim that one project is better than the other — they now serve
overlapping but different goals, and this fork keeps OpenDisplay's
[GPL-3.0](LICENSE) license and original copyright notice intact, per the
license's terms. See [PROTOCOL.md](PROTOCOL.md) and
[COMPATIBILITY.md](COMPATIBILITY.md) for the technical detail this fork
inherited and has extended.

## License

[GPL-3.0](LICENSE). Original work Copyright (c) 2026 Philip Poloczek; this
fork's changes are contributed under the same license. If you distribute a
modified version it must stay open source under the same license with
attribution intact.

---

<div align="center">

*MeowDisplay — Mac Everywhere, On Whatever Display.*

</div>
