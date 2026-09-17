<div align="center">

# MeowDisplay

**MEOW — Mac Everywhere, On Whatever Display**

*Mac, Every Other Way*

</div>

---

## What is MeowDisplay?

MeowDisplay lets supported devices act as secure remote displays and control
surfaces for a Mac, locally or remotely. An iPhone or iPad becomes a true
extended (or mirrored) display for your Mac — with touch, mouse, and keyboard
input routed back — over USB, LAN/WiFi, or a private remote network.

MeowDisplay is a personal, actively-developed fork of the open-source
[OpenDisplay](#upstream--attribution) project. It keeps OpenDisplay's core
architecture (virtual display creation, hardware H.264 pipeline, USB/WiFi
transport) and builds further product work — remote connectivity, reconnect
and wake handling, pairing, and settings — on top of it.

## Current capabilities

- **Mac → iPhone/iPad display streaming** — true extended display or mirrored
  output, Retina-sharp, low latency (hardware H.264 encode/decode).
- **Touch, mouse, and keyboard input** routed from the receiving device back
  to the Mac.
- **System audio streaming** from the Mac to the receiving device.
- **Secure device pairing** with a short authentication code (SAS) confirmed
  on both ends before a session is trusted.
- **Pinned, encrypted wireless sessions** — no plaintext wireless fallback.
- **USB connectivity** over macOS's built-in `usbmuxd`, no helper tools.
- **LAN/WiFi connectivity** with zero-config discovery via Bonjour.
- **Remote Access** over a reachable private network such as Tailscale.
- **Auto-Reconnect**, configurable.
- **Wake & Connect** — local Wake-on-LAN where applicable, with post-wake
  interactive promotion once the Mac is reachable again.
- **Display/mirror source selection** on the receiving side.
- **Configurable gesture behavior**.
- **Dock, Menu Bar, or Dock & Menu Bar** operating modes.
- **Start at Login**.
- **MeowDisplay Receiver** — use a spare Mac itself as a display, where
  implemented.

**Primary tested configuration: Mac host → iPhone receiver.** Everything
above is validated on that pairing. Other hardware/platform combinations not
listed above have not been validated; see
[Want to contribute?](#want-to-contribute) if you can help test one.

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

The full wire protocol is specified in [PROTOCOL.md](PROTOCOL.md); how it
evolves across releases is in [COMPATIBILITY.md](COMPATIBILITY.md).

## Distribution status

**macOS** — source builds available now (see [SETUP.md](SETUP.md)).
Signed/notarized direct releases are planned.

**iOS** — source builds through Xcode during development. TestFlight/public
iOS distribution is planned.

## Setup

See [SETUP.md](SETUP.md) for cloning, project generation, signing,
building each target, permissions, pairing, and troubleshooting.

## Current Roadmap

Distinguishing **planned** work (intended, not merely an idea) from
**future** (longer-term direction).

### Planned

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

No dates are promised for any of the above.

### Future

Longer-term direction, not required for the first public beta:

- Cold boot / fully logged-out LoginWindow remote access (**not** required
  for the first MeowDisplay public beta).
- Apple persistent remote-desktop capability work, where appropriate.
- A QUIC transport experiment plus a separate security review (**not** part
  of the current release plan).
- An integrated remote Wake-on-LAN relay/router solution.
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

## Upstream & attribution

MeowDisplay is a fork of [OpenDisplay](https://github.com/peetzweg/opendisplay)
by Philip Poloczek — a free, open-source alternative to Apple Sidecar, Duet
Display, and Luna Display that turns spare Apple devices into second
monitors for a Mac. OpenDisplay's own website, TestFlight beta, and
community client projects (Android/Linux receivers and senders speaking the
same wire protocol) are linked from its repository.

This fork keeps OpenDisplay's [GPL-3.0](LICENSE) license and original
copyright notice intact, per the license's terms. See [PROTOCOL.md](PROTOCOL.md)
and [COMPATIBILITY.md](COMPATIBILITY.md) for the technical detail this fork
inherited and has extended.

## License

[GPL-3.0](LICENSE). Original work Copyright (c) 2026 Philip Poloczek; this
fork's changes are contributed under the same license. If you distribute a
modified version it must stay open source under the same license with
attribution intact.

---

*MeowDisplay — Mac Everywhere, On Whatever Display.*
