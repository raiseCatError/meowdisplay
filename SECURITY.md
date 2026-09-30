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

### QUIC (optional, same trust)

On network routes a session may instead use QUIC, whose TLS 1.3 is built
into the protocol. It is configured by the same code as TCP/TLS
(`TLSConfigurator.pinnedQUICOptions`): the same per-device identity, the
same required client certificate, the same SPKI pin check — there is no
separate QUIC key, pin or trust store and no unencrypted form. It adds a
fixed ALPN (`meowdisplay-quic/1`) and disables session tickets and
resumption, so no 0-RTT early data exists and no click, key, drag, setting
or session command can be replayed ahead of a full handshake. Above the
transport nothing changes: the `hello` identity check, per-connection
admission and the per-connection input grant apply exactly as on TCP.

**No silent downgrade.** In Auto, the Mac falls back from QUIC to TCP only
after an ordinary reachability failure (UDP blocked, nothing listening,
unreachable path, no answer in time) — and TCP is itself the same pinned
mutual TLS. A pin mismatch, certificate or client-certificate failure, ALPN
mismatch, identity mismatch or protocol violation ends the attempt with an
error instead of retrying over TCP. A device explicitly set to QUIC never
uses TCP. The `_meowdisp-q._udp` Bonjour record is a hint only: a spoofed
one can at most cause a QUIC dial that pinning then rejects.

**Resource limits.** A receiver accepts only a small number of live QUIC
connections, three sender-opened streams per connection (one per channel),
bounded frame sizes checked before buffering, and time limits for the stream
preface and the first Control stream; media is refused until the session is
admitted, and Forget/Block closes QUIC connections that have not yet
presented a session.

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

## Sessions, input and revocation

A pinned, authenticated connection proves which paired device is on the
other end. It does not by itself admit a session:

- **Admission is per connection.** Before the Mac sends any video, audio or
  cursor data, creates a virtual display, or acts on a receiver's input or
  settings requests, the receiver must have accepted the session on that
  exact connection, and a receiver-initiated request that needs the Mac
  owner's approval must have it. After a reconnect or a route change the new
  connection is admitted again before anything flows
  (`Mac/SenderSessionAuthorization.swift`).
- **Every connection re-proves identity, on every route.** The receiver's
  announced ID must be the device the Mac dialed, and its key must be that
  device's *current* pin — USB is held to exactly the same rule as the
  network.
- **Connection approval never grants input.** Remote input needs the Mac's
  Allow Input master switch, an admitted session, and a grant for the
  current connection. Grants never carry over to a new connection; the
  receiver asks again.
- **Forget and Block revoke.** They withdraw approval prompts still waiting
  for that device, end connections that are waiting to take over the
  session, and drop remembered acceptances; answering a prompt afterwards
  does nothing. Forget also removes the pin, so a stale in-memory copy of the
  trust store can't bring it back.
- **Automatic reconnection never becomes a user request.** Remote Access
  recovery tells the Mac it is automatic, so it can never raise an approval
  prompt; only an explicit Connect can. Discovery metadata (Bonjour names
  and IDs) is never used to put a trusted-looking prompt on screen before
  the connection is authenticated.

## Network paths and what leaves the local network

- **USB**: local only, over macOS's `usbmuxd`. Nothing leaves the device
  pair.
- **LAN/WiFi**: local only, discovered via Bonjour. Nothing leaves the local
  network.
- **QUIC** (when used): the same local or Remote route over UDP port 9001
  instead of TCP port 9001; same pinned identities, same destinations.
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
- **Update checks (Mac apps only)**: Sparkle fetches
  `https://meowdisplay.app/appcast.xml` (the Receiver fetches
  `appcast-receiver.xml`). That URL redirects to the feed on the project's
  GitHub Releases page. Checks happen only after the user allows automatic
  checks (Sparkle asks), or when the user chooses **Check for Updates…**.
  No system profile is sent. Both the feed and the downloaded update must
  carry a valid signature from MeowDisplay's EdDSA key, and macOS code
  signing still applies to the updated app. The iOS app makes no
  update-check request.

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
