# Security and privacy

How MeowDisplay actually secures a connection, and what it stores. This
describes the current implementation (`Shared/TLSConfigurator.swift`,
`Shared/TrustStore.swift`, `Shared/Pairing.swift`,
`Shared/PairingSession.swift`) — see [PROTOCOL.md](PROTOCOL.md) for the wire
handshake and the README's
[Architecture & security summary](README.md#architecture--security-summary)
for a shorter version.

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

## Reporting a security issue

If you find a security issue, please open a GitHub issue with as much detail
as you can share publicly, or contact the maintainer directly if the issue
involves sensitive exploit details you'd rather not post publicly first.
