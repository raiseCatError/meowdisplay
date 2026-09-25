# Security and privacy

> **Do not report security vulnerabilities in public GitHub issues. Use GitHub’s private “Report a vulnerability” flow instead.**

To report privately: open the [MeowDisplay GitHub repository](https://github.com/raiseCatError/meowdisplay) → **Security** → **Report a vulnerability**. Don't include secrets, keys or personal data in public places — the private report is visible only to maintainers. See [Reporting a vulnerability](#reporting-a-vulnerability) below.

How MeowDisplay actually secures a connection, and what it stores. This
describes the current implementation (`Shared/TLSConfigurator.swift`,
`Shared/TrustStore.swift`, `Shared/Pairing.swift`,
`Shared/PairingSession.swift`) — see [PROTOCOL.md](PROTOCOL.md) for the wire
handshake and the README's
[Security](README.md#security) section for a shorter version, and
[ARCHITECTURE.md](ARCHITECTURE.md) for where these pieces sit in the app.

## Transport encryption

Every session — local or remote — is **TLS 1.3, and only TLS 1.3**: minimum
and maximum negotiated protocol version are both pinned to TLS 1.3
(`TLSConfigurator.swift`), so there is no downgrade path to an older TLS
version. There is no plaintext fallback for a pinned peer; if TLS setup
fails, the connection is refused rather than degraded.

Both ends present a certificate (mutual authentication) — the listener
explicitly requires a client certificate, so a one-way-authenticated
connection is never silently accepted.

## Identity pinning (not certificate-authority trust)

MeowDisplay does not use certificate-authority chain validation. Certificates
are self-signed per device, and trust is established entirely through
**SPKI (Subject Public Key Info) pinning**: during the TLS handshake, the
peer's public key is extracted from its certificate and compared
byte-for-byte against the set of SPKIs pinned for that specific peer.
`SecTrustEvaluateWithError` (normal CA-chain validation) is deliberately not
used — pinning *replaces* it rather than supplementing it.

This means trust in MeowDisplay is peer-specific, established once during
pairing, and does not depend on any certificate authority, MeowDisplay
account, or external validation service.

## Pairing (SAS)

The first time two devices connect, both display a short authentication
string (SAS — Short Authentication String) derived from the handshake. You
confirm it matches on both ends before the pairing is accepted. This is what
binds a specific device's public key to your trust store — an attacker
who can intercept traffic but doesn't also control what you see on both
screens cannot pass this check unnoticed. See
[PROTOCOL.md](PROTOCOL.md) for the exact handshake this derives from.

## What's stored, and where

- The device's own TLS identity (private key + self-signed certificate) and
  the SPKI pins for every paired peer are stored in the **Keychain**, using
  the data-protection keychain under a `WireCrypto.*` namespace
  (`TrustStore.swift`). This is local, per-device storage — not synced to
  iCloud or any MeowDisplay-hosted service.
- Forgetting a device (see [SETUP.md](SETUP.md#forgetting-and-re-pairing-a-device))
  removes its pin from the Keychain; the next connection attempt requires
  pairing again.
- No account, email, or personal identifier is required or collected to use
  MeowDisplay.

## Network paths and what leaves the local network

- **USB**: local only, over macOS's `usbmuxd`. Nothing leaves the device
  pair.
- **LAN/WiFi**: local only, discovered via Bonjour. Nothing leaves the local
  network.
- **Remote Access**: uses a reachable private network address (typically a
  [Tailscale](https://tailscale.com) endpoint) to locate the peer outside
  the local network. The remote endpoint address is a **routing hint, not
  an identity or a trust mechanism** — the same pinned mutual-TLS session
  described above still authenticates the connection regardless of which
  route carried it.
- **MeowDisplay does not operate its own relay, cloud service, or account
  system.** Media (video/audio/input) travels directly between your two
  devices over whichever route is active; MeowDisplay itself never sees or
  relays that traffic through infrastructure it controls. If you use
  Remote Access, your traffic does traverse whatever private network you've
  chosen (e.g. Tailscale's infrastructure, per Tailscale's own security
  model) — that's a property of the network you picked, not of MeowDisplay.

## What this doesn't claim

This document describes what's implemented, not a completed third-party
audit. A broader pre-release security review is tracked as part of the
release roadmap (see the README's [Roadmap](README.md#roadmap)). MeowDisplay
does not claim to be "unhackable," "perfectly secure," or immune to attacks
against your device itself (e.g. a compromised OS, a physically accessed
unlocked device, or a compromised Tailscale account) — the guarantees above
are specifically about the pairing and transport model.

## Reporting a vulnerability

Use GitHub Private Vulnerability Reporting: open the
[repository](https://github.com/raiseCatError/meowdisplay), go to the
**Security** tab (shown as **Security and quality** in some GitHub layouts)
and choose **Report a vulnerability**. The report is visible only to you and
the maintainers.

**Never** post vulnerability details in public issues, Discussions, pull
requests or elsewhere before a fix is available.

Helpful details to include:

- Affected MeowDisplay version or commit
- Affected platform(s): Mac model and macOS version, and/or iPhone/iPad model
  and iOS/iPadOS version
- A description of the vulnerability
- Steps to reproduce, or a proof of concept where it is safe to share
- The impact you believe it has, and whether exploiting it needs an
  already paired/trusted device or works from an unpaired one on the network
- Relevant logs, with secrets, private endpoints, identifiers and personal
  content removed
- A suggested mitigation, if you have one

Do not send passwords, private keys, pairing secrets, Keychain contents or
other credentials — they are never needed to investigate a report.

### In scope

Anything that could let someone see a stream, control a Mac, or be trusted
without the owner's consent: video/audio streaming, remote input, network
listeners and connection handling, pairing and the trust store, and Remote
Access / Wake & Connect. Reports against the current release or the current
default branch are the most useful.

### What to expect

This is a small, volunteer-maintained project. Reports are taken seriously
and handled as promptly as possible, but there is no guaranteed response time
and no bug bounty or reward programme. You'll be kept informed as the report
is investigated, and credited in the fix if you'd like.

Please allow reasonable time to investigate and ship a fix before disclosing
an unresolved vulnerability publicly. Good-faith research that avoids
privacy violations, data destruction and disruption to other people's
devices is welcome.

### Not a vulnerability?

Ordinary bugs that don't present a security or privacy risk — crashes,
connection failures, display glitches — should use the normal
**Bug report** issue form. See [SUPPORT.md](SUPPORT.md).
