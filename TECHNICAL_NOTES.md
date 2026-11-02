# Technical Notes

Platform research and architectural constraints behind MeowDisplay's
roadmap. This is not a marketing page — it's the working reference for *why*
certain roadmap items (headless support, cold boot, remote wake) are shaped
the way they are, and what external prior art informed that shape.

For the product-level overview, see [README.md](README.md). For the wire
protocol, see [PROTOCOL.md](PROTOCOL.md).

## macOS capture and display architecture

MeowDisplay's Mac sender captures with **ScreenCaptureKit**, Apple's modern,
public, supported screen-capture API, and hardware-encodes the result to
H.264 with **VideoToolbox**. Both are public APIs with normal App Review /
distribution status — there is nothing private about the capture or encode
path.

The part that *is* private is creating the virtual display in the first
place; see the next section.

## Virtual displays and `CGVirtualDisplay`

To offer a true **extended** display (not a mirror), the Mac sender needs to
create a display that doesn't physically exist. Apple has no public,
supported third-party API for that today. MeowDisplay uses the private
`CGVirtualDisplay` SPI to do it — the same technique used by other
virtual-display tools such as BetterDisplay and DeskPad.

This is used deliberately and knowingly, not accidentally:

- The private-API surface is **isolated to one place** in the codebase
  (`Mac/VirtualDisplay.swift`), rather than spread through the app, so it can
  be swapped without a wider rewrite.
- Private APIs carry real compatibility and distribution risk: Apple can
  change or remove them without notice, and their use is a factor in Mac App
  Store review (though not in notarized direct distribution, which is
  MeowDisplay's actual near-term target — see [README.md](README.md#getting-started)).
- If Apple ever exposes a supported public equivalent, MeowDisplay should
  and would switch to it.

**Context, not a workaround for it:** Apple's own [Screen Sharing feature](https://support.apple.com/en-in/guide/mac-help/-mh14066/mac)
lets a Mac view and control another Mac's screen over the network, including
a high-performance mode. That's real evidence Apple can do host-side virtual
display work internally — it is **not** evidence that a public third-party
API for equivalent host virtual-display creation exists or is coming. Do not
read one as implying the other.

## Sleep/lock vs. cold boot

This distinction matters and is easy to blur, so it's worth stating plainly.

**Current / near-term model:** MeowDisplay targets a Mac with an existing,
**logged-in Aqua user session** that sleeps or locks. Wake, reconnect,
capture recovery, and remote input are being built and validated around
*that* lifecycle — a session that already exists and is coming back, not one
being created from nothing.

**Future, different problem: cold boot / fully logged-out access.** Reaching
a Mac that is fully powered off, or sitting at the LoginWindow with nobody
signed in, is architecturally distinct — screen capture and input injection
both need a GUI session to operate in, and a machine in that state has none
yet. This is **not** required for MeowDisplay's first public beta.

An [Apple Developer Forums thread](https://developer.apple.com/forums/thread/814152)
(a developer asking how to capture the LoginWindow screen for a remote
support tool, answered directly by an Apple DTS engineer) is useful prior
art here. The documented shape, per that answer:

- A **machine-level LaunchDaemon** handles networking/orchestration in the
  global system session — daemons cannot do GUI work like screen capture.
- A **GUI-session LaunchAgent** (configurable via `LimitLoadToSessionType`
  to load in `Aqua` and/or `LoginWindow` sessions) does the actual
  ScreenCaptureKit capture and input injection, because that has to happen
  inside a GUI session, not a background daemon.
- The two communicate over **XPC**.
- Per that same thread, ScreenCaptureKit capture in the **LoginWindow**
  session specifically became possible starting **macOS 14.4** (earlier
  versions need legacy APIs like `CGDisplayStream` there instead).

This is recorded as the likely shape of a future cold-boot architecture, not
a commitment to build it on any particular timeline.

## Persistent remote capture / Apple's own capability

Apple has a restricted, approval-gated entitlement —
[`com.apple.developer.persistent-content-capture`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture) —
relevant to apps that need to keep capturing content (e.g. screen content)
persistently, including in scenarios an ordinary screen-recording permission
grant doesn't cover. Apple's own [request form](https://developer.apple.com/contact/request/persistent-content-capture/)
(sign-in gated, as Apple's developer request forms generally are) is where a
developer would apply for it.

**MeowDisplay does not currently hold, or claim to hold, approval for this
entitlement.** It's recorded here because it's directly relevant to any
future persistent/unattended remote-desktop work — one path worth knowing
about, not something in use today.

## Remote Desktop privacy model

A separate [Apple Developer Forums thread](https://developer.apple.com/forums/thread/841530)
covers a related, narrower question: whether an app can silently *check*
macOS's "Remote Desktop" TCC (privacy) permission status without itself
triggering a system consent prompt. Per the Apple DTS engineer's reply in
that thread (as of that post): no public API exposes that check today —
`CGPreflightScreenCaptureAccess()` only reflects the separate "Screen &
System Audio Recording" permission, and calling ScreenCaptureKit to find out
triggers the very consent alert you were trying to avoid. The engineer's
suggestion was to file an enhancement request (feedback number `FB24263354`
is attached to that specific thread).

Treat this as one forum thread's observation at one point in time, not a
documented, guaranteed platform behavior — Apple's own docs are the
authority if this ever needs to be relied on for real.

## Remote Wake-on-LAN

Wake-on-LAN is fundamentally **local-link-layer** behavior: a magic packet
broadcast on a LAN segment, received by a network interface that's still
listening even though the rest of the machine is asleep. A Tailscale (or
similar overlay-network) link on a *sleeping* Mac is not itself an always-on
listener in the way LAN hardware WoL is — the Mac has to already be awake
for its Tailscale node to be reachable at all. So "send a WoL packet over
Tailscale to a sleeping Mac" doesn't have a straightforward implementation:
there's no awake process on the target to receive and act on an overlay
packet.

The practical shape of remote wake today, where it works, generally needs an
**already-awake relay on the target's own LAN**: something else on that
network — a router feature, or another always-on device — sends the actual
link-layer WoL broadcast, the Mac wakes, and *then* its overlay network link
comes back and MeowDisplay can connect. [AnyDesk documents this same shape](https://support.anydesk.com/)
for its own Wake-on-LAN feature: it can use another online AnyDesk
client/device already on the target's LAN as the relay that sends the wake
packet. (AnyDesk's specific Wake-on-LAN help-center URL could not be
resolved to a stable page at the time of writing — this describes the
documented general mechanism, referenced conceptually, not a specific
quoted page.)

An integrated remote-WoL relay/router solution for MeowDisplay is **future**
work, not planned for the near term — see [README.md](README.md#roadmap).

## Reference implementations / related research

These are architectural references consulted for context — not
dependencies, and not claims that MeowDisplay copies their code or that they
endorse MeowDisplay.

### RustDesk

[RustDesk](https://github.com/rustdesk) is an open-source remote-desktop
project with real-world macOS unattended-access deployment experience.
Useful references:

- A [GitHub discussion](https://github.com/rustdesk/rustdesk/discussions/7762)
  on configuring the macOS client to start automatically at boot, including
  at the login screen, for unattended access — LaunchDaemon/LaunchAgent
  configuration and permission requirements.
- The [macOS platform source](https://github.com/rustdesk/rustdesk/blob/251e1a3487518f763e0bb2b7eafb505fbd75b56d/src/platform/macos.rs)
  (cursor handling, screen-recording permission checks, service
  install/uninstall, display-resolution control, privilege escalation).
- A [wiki page](https://github.com/rustdesk/rustdesk/wiki/macOS-Auto%E2%80%90Start-Service-Setup-%28for-Remote---MDM-Deployment%29)
  with a script-based approach to registering the service for
  remote/MDM deployment without user interaction.

Useful for locked-session/daemon-vs-GUI-agent thinking; MeowDisplay's own
architecture and code are independent of it.

### AnyDesk

[AnyDesk](https://anydesk.com) is a commercial remote-desktop product.
Referenced above for its Wake-on-LAN-via-LAN-relay approach — a useful
existence proof that "another online device on the same LAN relays the wake
packet" is a workable, shipped pattern, independent of MeowDisplay's own
future implementation.
