# Remote wake-on-LAN — design (not yet implemented)

This is a local design note for the Tailscale Remote milestone. It is
intentionally not an upstream project document. No code in this milestone
implements the relay described below; Remote connectivity to an
already-awake Mac ships independently of this.

## Why this is hard

Tailscale gives the iPhone routed IP connectivity to the Mac's tailnet
address, but that's an overlay-network path, not a LAN segment. Traditional
Wake-on-LAN is a Layer-2 broadcast (or unicast) magic packet delivered on
the Mac's *local* Ethernet/Wi-Fi segment. A tailnet peer cannot emit that
packet directly — it isn't on the same broadcast domain, and Tailscale
doesn't bridge Layer 2 by default.

## Model

```
iPhone
  → Tailscale (routed IP, already-authenticated tailnet peer)
  → an always-on relay device on the Mac's LAN (also on the tailnet)
  → ordinary Wake-on-LAN magic packet, sent locally
  → Mac wakes
  → MEOW's normal Remote reconnect takes over from here
```

The relay is any always-on device already on the Mac's home network and
enrolled in the same tailnet: a Raspberry Pi, a NAS, another Mac, or
possibly the router — but a router integration is deferred pending
investigation into whether the user's hardware (e.g. a TP-Link Archer
AX5400/AX73-class device) exposes a safe, stable, authenticated mechanism
for it. No such mechanism should be assumed without verification.

## Hard constraints for any future implementation

- The relay must only wake MEOW devices the user has explicitly enrolled
  (their own paired Mac's MAC address), never an arbitrary host supplied by
  the phone at request time.
- No public UDP WoL port. The relay only accepts wake requests from
  authenticated tailnet peers.
- No general remote-command execution surface — the relay's only exposed
  action is "send this one pre-configured magic packet."
- Waking is best-effort: sleep → wake is the supported case. Cold boot from
  a fully powered-off Mac is out of scope and must not be promised.

## Desired eventual UI states

```
Awake/reachable   → Connect
Asleep/wakeable   → Wake
Offline/no relay  → Offline
```

These states are not wired up in this milestone. `ConnectionRoute` and the
Remote candidate/connect path have no dependency on wake state; they simply
fail with a clear "peer unreachable" / "Mac asleep" diagnostic (see Phase 7
of the Remote milestone) when the Mac isn't reachable, exactly as they
would for any other unreachable route.

## Why nothing is implemented yet

Building the relay (protocol, enrollment, auth, and where it runs) is a
separate piece of always-on infrastructure with its own security surface.
Bundling it into the first Remote-connectivity milestone would risk
destabilizing the core "phone reaches an already-awake Mac over Tailscale"
path this milestone is actually validating. It's scoped out deliberately,
not overlooked.
