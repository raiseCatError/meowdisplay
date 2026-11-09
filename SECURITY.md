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

## Unified Clipboard

Copying on the Mac and pasting on a connected device (and back) is off until
the Mac owner turns it on in Settings ▸ Clipboard **and** the person turns it
on in the device's own Settings ▸ Clipboard. Details: PROTOCOL.md 6.15.

- **Per-device permission.** Each paired device (by its authenticated install
  id, never its name, IP or Tailscale address) is *Ask* (the default: the Mac
  shows Not Now / Allow This Session / Always Allow), *Always Allow* or
  *Block*, with a direction (both ways, Mac to device, device to Mac).
  Clipboard permission is independent of remote input and of Remote Finder
  file access: none of them implies another.
- **Never broadcast.** A copy goes only to devices that are paired, connected,
  admitted, turned on and allowed in that direction; it never goes back to
  the device it came from. A device can only send copies in its own name.
- **Pause and revoke.** Pause stops every copy at once. Revoke, Block or
  Forget ends that device's grant and cancels its transfers at once. Clear in
  Settings ▸ Clipboard drops transfers in progress and files waiting there.
- **What is kept.** No clipboard history, on any platform. A copy from
  another device is held only until something replaces it; files received on
  the Mac are staged in a private temporary folder (with the quarantine
  attribute, so Gatekeeper checks them) and deleted when replaced, on Clear,
  and when the app quits or starts. Devices keep copies of the Mac's files
  only while you save or share them (a shared copy stays a short while so the
  receiving app can read it). Clipboard content is never logged or shown in
  notifications; the status shows only a summary such as "Text" or
  "2 files, 3 MB".
- **Private items.** The Mac skips items the copying app marks as concealed,
  transient or auto-generated (the nspasteboard.org markers that many
  password managers set); Android skips copies marked sensitive. This
  depends on the copying app: **passwords are not guaranteed to be
  recognized**. Turn the clipboard on only for devices and Macs you trust, and
  pause it when copying secrets.
- **Operating-system limits are respected, not bypassed.** macOS 15.4 and
  later may ask before MeowDisplay reads the pasteboard. iOS and Android let
  an app read the clipboard only while it is in front (iOS may ask each time;
  Android shows a notice), so copies made on a device reach the Mac when you
  return to MeowDisplay, not in the background. Writes stay on the device
  (not passed on to Universal Clipboard). No private APIs or background
  polling are used.
- **Files are validated on the Mac.** Names that could escape their folder
  are refused, sizes are capped at parse, every range is checked against its
  digest, and files copied on the Mac are read only when a device asks for
  them, through the same checks as when they were copied.

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
  On Android the saved address is stored per verified Mac, never trusted,
  and never replaces a pin: a different key at the address ends the attempt
  as "different Mac" and is not retried, and the same goes for a Mac that
  does not accept this device. Retries are bounded, run only while the app
  is in front, and never follow a security failure. The knock is a single
  frame inside the pinned connection and changes nothing on the Mac that a
  local request would not. The app creates no VPN and opens no relay or
  port mapping; "Remote · Tailscale" on screen is a label drawn from the
  phone's own network facts, not a security claim. Logs name only the kind of
  address (IPv4, IPv6, DNS or Tailscale range). The Mac reads Tailscale's
  status (`tailscale status --json`, bounded to 3 s; only a CLI whose code
  signature, after resolving links, belongs to Tailscale's team W5364U7YZB,
  so an unsigned or Homebrew-built command is never run) only when you press Check Tailscale or Find on Tailscale in Settings →
  Remote Access: it shows the Mac's own name and suggests tailnet peers for a
  paired device's address. A suggestion only fills the field; nothing is
  saved, trusted or changed in Tailscale without you. Android's Add Remote Mac
  says whether a tailnet VPN looks connected, from the phone's own network
  facts. Android 17 asks for a Local
  Network permission only from apps that target API 37; MeowDisplay targets
  36 today and must declare the permission when it moves.
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

## Privacy Shield

While a device is connected, the Mac can cover its own screens in black so
people near it don't see the session. It's on by default for remote
connections (Tailscale and other routed addresses) and off by default for
local ones (Wi-Fi, peer-to-peer, USB, hotspot); the owner sets each in
Settings ▸ System. Each connected device is told whether it's on.

- The cover is left out of MeowDisplay's own captures, so the device's
  picture and control are unchanged. MeowDisplay's virtual displays aren't
  covered (nobody can look at them).
- It covers every physical display, including ones attached while it's up,
  at the highest window level apps may use. Some system UI (the login
  window, some alerts) can appear above it, and macOS gives no guarantee
  beyond that.
- Clicks and keys pass through it, so someone at the Mac can still type or
  click without seeing. It's a viewing shield, not an input lock.
- Removing the cover needs a click from the Mac's own mouse or trackpad
  (clicks injected for a device are ignored) and the owner's confirmation,
  asked by macOS: Touch ID or the login password (macOS may also accept an
  unlocked, paired Apple Watch). MeowDisplay never sees the password. While
  macOS asks, nothing a device sends changes the Mac: MeowDisplay handles
  only liveness and connection messages and drops everything else (input,
  window actions, menus, app launches, Lock Mac, files, clipboard, window
  lists and thumbnails), and only lets go of keys or buttons a device was
  holding. Devices keep the last picture from before the prompt (no new
  frame is sent until it closes), so they don't see it.
  The cover stays above every app window meanwhile; if the prompt can't be
  seen above it, the Mac stays covered (it fails closed). It covers again
  after the chosen time (5 minutes by default) without physical input at the
  Mac; remote and synthetic input don't count. Only timestamps are kept,
  never what was typed.
- Devices never see the cover: its windows (and the Mac-side notice) exist
  and are left out of MeowDisplay's captures before they appear. If a
  capture doesn't confirm within 3 seconds, the Mac is covered anyway and
  that's logged.
- A device that connects after a reveal brings the cover back, so what each
  device is told on connecting is true.
- Turning either setting off asks for confirmation, and for Touch ID or the
  login password (at the Mac) while the cover is up. A setting changed
  outside MeowDisplay's Settings (for example with `defaults write`) can
  turn the shield on but doesn't remove a cover that is up.
- **What it doesn't survive.** The cover is drawn by the MeowDisplay app
  itself. A normal Quit, `kill` or `killall` locks this Mac's screen
  before MeowDisplay exits; a force quit (SIGKILL) or a crash removes the
  cover at once with no lock. A separate process that would keep the Mac
  covered in that case is a prototype under assessment, not shipped. The
  Privacy Shield is a viewing shield for people near the Mac, not a lock.

## When the Mac is locked

While macOS shows its lock screen, while another user is switched in, or whenever MeowDisplay
can't read the login session, no device gets anything of the Mac and nothing a device sends
reaches it. Unknown counts as locked, never as unlocked.

- **One gate.** The Mac reads its lock state from macOS's lock and unlock notifications, login
  session switches, display sleep and wake, and the window server's session dictionary (twice a
  second while a device is connected). A lock notice locks at once; unlocking needs a session read
  that says so (`Mac/MacLockPrivacy.swift`). Every media frame, content message, window capture
  and injected event checks the same gate.
- **Nothing leaves.** No picture, sound, window frames, cursor, window list or titles, stills,
  app icons, app list, Stage Peek or picker content, Remote Finder listings, pane menus, text
  caret or clipboard. Frames captured or queued just before the lock are dropped too. Devices are
  told the Mac is locked and that video is off, so even an older receiver drops its last
  picture. The receiver covers everything with an opaque "locked" screen and forgets the stills
  and window names it held; the layout is kept and restored after the unlock.
- **Nothing gets in.** Keys, buttons, touches and drags the device was holding are released at
  the lock; everything sent afterwards is dropped until the Mac unlocks, so nothing reaches the
  lock screen or a window behind it. A device set to Ask is refused without a prompt (nobody
  could answer one behind the lock screen); Never Allow stays refused; Always Allow keeps or gets
  its grant, but input still waits for the unlock. The one exception is below.
- **No password of MeowDisplay's own.** MeowDisplay never asks for, shows a field for, checks,
  stores or logs the Mac's login password, and doesn't imitate the macOS login screen. A trusted
  device can operate macOS's own lock screen (below); macOS does the authenticating.
- **Limits.** The state comes from public macOS signals and the session dictionary. If macOS
  reports the session unlocked while showing something else, MeowDisplay follows macOS. The
  Privacy Shield above is a separate viewing shield for people near the Mac.

## Lock screen control

A device this Mac already trusts with input can show macOS's own lock screen while the Mac is
locked and type the login password there, so the owner can unlock from the iPad. MeowDisplay
relays the picture and the keys; macOS's login window checks the password. Code:
`Mac/LockScreenControl.swift`, enforced in `MacSender` and again in `InputInjector`.

- **Who.** All of these, checked on the Mac at every step, not by the receiver: the session is
  admitted (paired, pinned key, current connection); Allow Input is on; this login session is on
  the console and macOS says it is locked (not another user switched in, not unknown); the
  device's input policy isn't Never Allow; its **Allow Lock Screen Control** switch isn't turned off; and
  this connection has control, either because the device is set to Always Allow Requests (its
  request is granted without a prompt, as in the section above) or because the owner granted
  control on this connection before the Mac locked. A device set to Ask without that grant is
  view-only and stays so: nothing is asked or granted behind the lock screen. All of it is checked
  again for every input event while the view is on, not only when a setting changes.
- **One connection.** The view belongs to the connection that asked for it. A reconnect or path
  change ends it; the new connection starts without it (even with its grant back) and must ask
  again. Its frames, pointer and input all require that connection, its grant and the lock.
- **The switch.** Device settings ▸ Input Authorization ▸ Allow Lock Screen Control, per device.
  It isn't a second grant: it follows the device's input policy and can only narrow it. **On with
  Always Allow Requests** (2.1 product decision): a device the owner already trusts with
  persistent control can also operate the real lock screen, with no extra step or prompt. That
  includes devices set to Always Allow before 2.1: the switch never shipped in a release, so they
  have nothing stored and follow their policy (no migration prompt, nothing rewritten, the input
  policy untouched). With Ask, only a grant a person gave before the lock carries over (see "Ask
  devices"); with Never Allow, or Allow Input off, never. Turning it off is stored as an explicit
  restriction for that device (also one recorded by a pre-release build) and overrides Always
  Allow until the owner turns it back on; turning it off ends a view at once; turning it back on
  is refused while any device controls the Mac, like Always Allow. Forget clears it with the
  device's trust, so a re-paired device starts at Ask with no control.
- **Only on request, only fresh.** Nothing is shown until the device asks (`lockScreenRequest`).
  A connection can start the view at most once every 5 seconds (a quicker request gets the
  current state), and each view wakes the display once. Then the Mac drops any frame it held,
  wakes the display, and sends only frames encoded after
  the request, starting with a keyframe, so no picture from before the lock can go out. Sound,
  windows, listings, Files, Clipboard, menus and the text caret stay off. The pointer's position
  and shape go only to the device showing it, only while it is shown. Window view and Extend
  can't show it (Mirror only: Extend's display has no login window); an Always Allow device, or
  an Ask device with a pre-lock grant (see "Ask devices"), is told to switch, any other Ask device
  isn't offered it. After the unlock, or a failed or refused attempt, it goes back to its view.
- **Only what a password needs.** Pointer moves, left clicks and touches; character keys with
  Shift or Option (Caps Lock rides along); Space, Return and Delete; printable text up to 128
  characters. Never Tab, the arrows, Escape or Forward Delete (they only move focus to the login
  window's other controls), Command or Control, function, media, navigation or input-source keys,
  right-click, scrolling, Pencil, gestures, shortcuts, menus, macros or window actions. Releases
  always go through so nothing stays held. A left click can still press the login window's own
  buttons (Switch User, Sleep, Restart, Shut Down, accessibility): macOS handles those as at its
  own screen; at worst that puts the Mac to sleep or shuts it down (a denial of service), and
  another account's login switches users, which ends the view.
- **On the iPad.** The lock screen has its own keyboard: a bare key input (iOS `UIKeyInput`, not
  a text document), so iOS has nothing to predict from, fill or replace: no QuickType bar, no
  AutoFill (no password suggestions), no text replacement, no learning. It also asks for secure
  entry (no dictation, nothing cached) and no autocorrect, spelling, capitals or smart
  punctuation. It keeps no text, and its strip shows a fixed label, never the characters or how
  many (also not to VoiceOver). It closes when the view ends; the ordinary keyboard isn't used
  on the lock screen. A hardware keyboard types directly (its keys are tagged the same way).
- **Ask devices.** An Ask device can use the lock screen only with control a person granted it
  before the Mac locked. In Window view or Extend that grant is on a connection that can't show
  the lock screen; switching to Mirror makes a new one, so the Mac (only the Mac, never the
  device) keeps a one-time ticket: issued only from that live grant, bound to the device's pinned
  key, this lock (any unlock, user switch or relock voids it) and this login session on the
  console, valid 10 seconds, spent by the first control request on the new connection. It never
  makes a grant that didn't exist, never applies to Never Allow, and never changes the device's
  setting. Without a pre-lock grant, nothing is asked or granted behind the lock: the device says
  to unlock at the Mac.
- **Meant for the lock screen, or not at all.** Each view gets a number the Mac never reuses.
  While the device sees the Mac locked it tags every input message (keys, touches, clicks,
  scrolls, Pencil, gestures, window and menu actions, a hardware keyboard or pointer), with the
  view's number while it shows one. The Mac delivers tagged input only to the live view it names,
  on that connection, and only touches, clicks and the login window's keys; untagged input only
  when no view is live. So input still in flight when the Mac unlocks (or after a hide, a new
  view, a reconnect, a revoke, or from another device) is refused, never typed, clicked or
  scrolled into the app in front, and desktop input never reaches the lock screen. Scroll, Pencil,
  proximity and gestures never act while a view is live or when tagged, so one begun on the lock
  screen can't continue on the desktop. Every refused keystroke and click is reported to that
  device by count and reason (never content), and it says so; refused moves are just dropped.
- **Held input stays in its episode.** Keys, modifiers and buttons belong to the episode (the
  desktop, or one view) that pressed them. The Mac releases them when the view starts or ends and,
  under the injector's own lock, before anything of another episode acts, so a modifier or drag
  never carries across an unlock or into the lock screen; a release from another episode releases
  nothing. The device ends every touch, drag, scroll and its momentum, Pencil stroke and gesture
  in progress, and stops delayed actions, whenever its tag changes. Ordinary input after an
  unlock isn't held back.
- **Ends by itself.** On unlock (normal input and content resume for that session; the receiver
  is told to reset its input), on another
  user switching in or the state turning unknown, on revoke, Never Allow, the switch off, Allow
  Input off, a disconnect, or two minutes without input. Held keys and buttons are released.
- **Nothing kept.** Typed characters are passed to macOS and not logged, stored or inspected
  beyond the key filter above; debug logging of keys is off while locked (on the Mac, and on the
  device whenever it sees the Mac locked). The Mac logs that input was refused and why at most
  once per view (and once between views), never how many keys or clicks, or when.
- **Limits.** The Mac can't tell what macOS draws on its lock screen; it relies on macOS's own
  lock state and the login window. Anyone holding a trusted device that has control can try
  passwords on the lock screen, under macOS's own rate limits, as they could at the Mac's
  keyboard. Turn the switch off for devices that shouldn't.

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
