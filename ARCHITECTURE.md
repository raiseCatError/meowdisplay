# Architecture

A map of how MeowDisplay is put together: which app owns what, which way
data flows, and where to start reading for a given change. It is an
orientation guide, not a specification. The wire format lives in
[PROTOCOL.md](PROTOCOL.md), versioning rules in
[COMPATIBILITY.md](COMPATIBILITY.md), the security model in
[SECURITY.md](SECURITY.md), and platform background (virtual displays, sleep
and wake) in [TECHNICAL_NOTES.md](TECHNICAL_NOTES.md).

## System overview

MeowDisplay turns an iPhone or iPad into a display and touch controller for a
Mac. A second receiver app lets another Mac act as a display too.

```text
                 video (H.264/HEVC) + optional system audio (AAC)
                 + control messages, over pinned mutual TLS 1.3
 ┌────────────┐ ─────────────────────────────────────────────▶ ┌──────────────────────┐
 │ Mac Sender │                                                │ iPhone/iPad Receiver │
 │ (macOS)    │ ◀───────────────────────────────────────────── │ (iOS/iPadOS)         │
 └────────────┘   input: touch, pointer, scroll, gestures,     └──────────────────────┘
       │          keyboard, Pencil + receiver hello/panel info
       │
       │  video (+ optional audio) + control
       ▼
 ┌──────────────┐
 │ Mac Receiver │   display only: its keyboard/trackpad are NOT forwarded
 └──────────────┘
```

- The **Mac is always the sender**. Receivers listen (Bonjour-advertised TLS
  listener); the sender dials them.
- A receiver has **one active sender** at a time.
- Routes are USB (via `usbmuxd`), local network (Bonjour), and Remote Access
  (a private-network address such as a Tailscale endpoint). The route carries
  bytes only; trust always comes from the pinned TLS identity.

## Targets

Defined in `project.yml` (XcodeGen). The `.xcodeproj` is generated and not
tracked — edit `project.yml`, never the generated project.

| Target | Sources | Role |
| --- | --- | --- |
| `OpenSidecarMac` | `Mac/`, `Shared/` | Mac Sender app |
| `OpenSidecariOS` | `iOS/`, `Shared/` | iPhone/iPad Receiver app |
| `OpenSidecarMacReceiver` | `MacReceiver/`, `Shared/`, a few `Mac/` utilities | Mac Receiver app |
| `OpenSidecarMacTests` | `MacTests/` plus selected pure-logic files | Hostless unit tests (run by `.github/workflows/tests.yml`) |

The `OpenSidecar*` names are inherited from OpenDisplay and are kept for
compatibility; the product name is MeowDisplay. `src/`, `public/` and
`tools/` are the project website, not app code.

## Application roles

### Mac Sender (`Mac/`)

| Responsibility | Key types / files |
| --- | --- |
| Device discovery, per-device sessions, auto-connect, USB preference/failover | `SenderController`, `DeviceSession` in `Mac/OpenSidecarMacApp.swift`; `Mac/Usbmux.swift`, `Mac/RouteArbitration.swift`, `Mac/AutoConnectPolicy.swift`, `Mac/ReconnectPolicy.swift` |
| One streaming pipeline per session: dial, capture, encode, send, receive input | `MacSender` in `Mac/MacSender.swift` |
| Connection/route migration | `Mac/MacSenderTransportController.swift`, `Mac/SenderTransport.swift`, `Mac/USBTLSBridge.swift` |
| Capture (ScreenCaptureKit) and its lifecycle/recovery | `Mac/MacSender.swift`, `Mac/CaptureLifecycle.swift`, `Mac/MacSenderPipelineState.swift` |
| Virtual display for Extend (private `CGVirtualDisplay` SPI, isolated here) | `Mac/VirtualDisplay.swift`, `Mac/DisplayArrangement.swift` |
| Mirror source selection | `Mac/MirrorDisplaySelection.swift` |
| Video encode (VideoToolbox) | `Mac/MacSenderVideoEncoder.swift` |
| System audio capture + AAC encode | `Mac/AudioCaptureEncoder.swift` |
| Input injection and targeting | `Mac/InputInjector.swift`, `Mac/InputRouting.swift`, `Mac/SystemGestureInvoker.swift` |
| Per-receiver input consent ("Allow Input") | `Mac/InputControlConsent.swift`, `Mac/ReceiverInputAuthorizationStore.swift` |
| Smart Touch (Experimental) Accessibility target classification | `Mac/SmartTouchTargetClassifier.swift` |
| User-facing status | `Mac/CanonicalRuntimeStatus.swift`, `Mac/MacSenderStatusSink.swift` |
| Settings / menu bar UI | `Mac/*SettingsView.swift`, `Mac/MenuBarQuickView.swift` |

### iPhone/iPad Receiver (`iOS/` + `Shared/`)

The iOS app is mostly a UIKit/SwiftUI shell around the shared
`StreamReceiver` core.

- App shell, scene lifecycle, and the `VideoView` touch surface:
  `iOS/OpenSidecarPhoneApp.swift`.
- Rendering: `AVSampleBufferDisplayLayer` by default (via
  `Shared/ReceiverVideoPresenter.swift`); `iOS/MetalVideoRenderer.swift` is
  an experimental alternative path.
- Control Tray / Function Tray and on-screen controls:
  `iOS/ReceiverControls.swift`, `Shared/ControlTrayGeometry.swift`,
  `Shared/ControlProfile.swift`, `Shared/ControlInteraction.swift`.
- Keyboard: `iOS/RemoteKeyboardInputView.swift`,
  `Shared/KeyboardEditPlanner.swift`.
- Viewport zoom/pan of the remote display: `Shared/RemoteViewport.swift`.
- Pairing and Remote Access UI: `iOS/PairingConfirmationSheet.swift`,
  `iOS/RemotePairingView.swift`, `iOS/RemoteAccessSettingsView.swift`.

### Mac Receiver (`MacReceiver/`)

An AppKit shell around the same `StreamReceiver` core: video window, cursor
drawing, keeping the Mac awake, and its own settings/pairing UI
(`MacReceiver/MacReceiver.swift`, `MacReceiver/ReceiverWindowLifecycle.swift`,
`MacReceiver/ReceiverPairingPanel.swift`). It advertises its own panel size
like an iPad does.

It is **display-only**: the receiving Mac's keyboard and trackpad are not
sent back to the sender.

## Shared code (`Shared/`)

`Shared/` holds everything more than one app needs, plus pure logic kept
platform-neutral so the hostless Mac test target can cover it.

| Area | Files |
| --- | --- |
| Receiver core (listener, arbitration, framing, control dispatch, input send) | `StreamReceiver.swift` |
| Receiver media pipeline | `ReceiverPipelineActor.swift`, `ReceiverFramePipeline.swift`, `ReceiverVideoDecoder.swift`, `ReceiverVideoPresenter.swift`, `ReceiverAudioDecoder.swift`, `ReceiverAudioPresenter.swift`, `PCMPlaybackEngine.swift` |
| Wire types and capabilities | `Protocol.swift`, `AudioMediaFrame.swift`, `CodecCapability.swift`, `EncoderCapability.swift`, `DecodeCeiling.swift`, `StreamingMode.swift`, `StreamingProfile.swift` |
| Trust and pairing | `TLSConfigurator.swift`, `TrustStore.swift`, `Pairing.swift`, `PairingSession.swift`, `PairingNetwork.swift`, `RemotePairing.swift`, `USBSecureTransportPolicy.swift` |
| Input interpretation (pure logic) | `PointerGestureEngine.swift`, `ScrollMomentum.swift`, `ReceiverGesture.swift`, `KeyboardEditPlanner.swift` |
| Remote Access / Wake & Connect | `RemoteEndpointStore.swift`, `RemoteEndpointValidation.swift`, `RemoteConnectRequestPolicy.swift`, `WakeConnectCoordinator.swift`, `WakeConnectAttempt.swift`, `WakeOnLAN.swift` |

## Display / video pipeline

```text
Mac Sender                                              Receiver
──────────                                              ────────
Mirror: pick existing display                           StreamReceiver (TLS listener)
Extend: wait for receiver hello → create                        │
        virtual display sized to its panel                      ▼
        │                                               ReceiverPipelineActor
        ▼                                                       │
ScreenCaptureKit capture (MacSender)                            ▼
        │                                               ReceiverVideoDecoder (VideoToolbox)
        ▼                                                       │
MacSenderVideoEncoder (VideoToolbox)                            ▼
        │                                               ReceiverVideoPresenter
        ▼                                               (AVSampleBufferDisplayLayer;
framed media over the active route ───────────────────▶  Metal path experimental on iOS)
```

- **Mirror** captures a physical display and can start before the receiver
  has said hello.
- **Extend** needs the receiver's panel metadata first, then creates a
  virtual display through `Mac/VirtualDisplay.swift` — the only place the
  private `CGVirtualDisplay` SPI is used.
- Capture lifecycle and transport lifecycle are related but deliberately
  separate: a route change or reconnect should not have to rebuild capture.

## Input pipeline

Input flows the opposite way, and only from the iPhone/iPad Receiver.

```text
touch / trackpad pointer / Pencil / keyboard / tray buttons    (iOS VideoView, ReceiverControls)
        │
        ▼
receiver interpretation   PointerGestureEngine (clicks, drags, relative pointer)
                          ScrollMomentum (two-finger scroll inertia)
                          ReceiverGesture (semantic system gestures)
                          RemoteViewport (zoom/pan → normalized coordinates)
        │
        ▼
StreamReceiver.send*()    touch · pointer · scroll · gesture · pencil · keyboard messages
        │
        ▼
MacSender control handling → consent/pause gating → InputRouting (which display)
        │
        ▼
InputInjector (CGEvent) · SystemGestureInvoker · Smart Touch via Accessibility
```

- **Direct Touch** sends absolute positions on the remote display.
- **Trackpad** mode moves the pointer relatively; `PointerGestureEngine`
  decides clicks, drags and right-clicks.
- **Two-finger scroll** momentum is computed receiver-side in
  `ScrollMomentum.swift`.
- **Smart Touch (Experimental)** uses the Mac's Accessibility tree
  (`SmartTouchTargetClassifier`) to decide how a touch should act on the
  element under it.
- **Apple Pencil** sends its own `pencil` messages (position, pressure,
  tilt; hover on supported iPads). See the README for what is supported
  today.
- Input is only injected when the user has allowed input for that receiver
  and the session is not paused.

**Gesture ownership is subtle.** `PointerGestureEngine` gives each touch
sequence one committed owner (`mode`) and documents its ownership rules at
the top of the type. `VideoView` in `iOS/OpenSidecarPhoneApp.swift` routes
Direct Touch, Trackpad, multi-finger gestures and Pencil through one
`touchesBegan` path. Don't add a parallel recognizer or rewrite this
arbitration without a reproduced problem; `MacTests/PointerGestureEngineTests.swift`
covers it.

## Audio / A/V sync

- Direction: Mac Sender → Receiver only. The sender captures a copy of
  system audio (`Mac/AudioCaptureEncoder.swift`) and sends AAC frames
  alongside video. Audio is opt-in per receiver and requires protocol
  version 12 or later (PROTOCOL.md §5A).
- Synchronization is the **receiver's** job: `ReceiverAudioDecoder` decodes,
  `ReceiverAudioPresenter` schedules against the capture timeline, clock
  offset, measured video latency and the user's A/V sync offset
  (`AVSyncPreference` / `ControlProfile.avSyncOffsetMs`), and
  `PCMPlaybackEngine` plays it.

## Pairing and security

- Every session is mutually authenticated **TLS 1.3** with self-signed
  per-device **P-256** identities (`TLSConfigurator.swift`, `TrustStore.swift`).
- Trust is **SPKI pinning** per peer, not CA validation. Pins and the
  device identity live in the Keychain.
- First contact requires **pairing**: both screens show a short
  authentication string (SAS) the user confirms (`Pairing.swift`,
  `PairingSession.swift`; Remote Access pairing in `RemotePairing.swift`).
- Remote input additionally requires per-receiver consent on the Mac.

Details and threat-model limits: [SECURITY.md](SECURITY.md). Handshake:
[PROTOCOL.md](PROTOCOL.md).

## Session invitations

Either side may start a session, but **the session initiator is not the
stream sender**: the Mac Sender is always the video/audio source and the
dialer, whoever clicked Connect. And **connection approval is not input
approval**: every session still starts with input off, and only the Mac
Sender's per-session Allow Input consent turns it on.

- Pure model, policy and lifecycle: `Shared/SessionInvitation.swift`
  (`SessionInvitation`, `IncomingSessionPolicyStore`,
  `PendingSessionApprovals`, `SessionAdmissionGate`,
  `ReceiverSessionAdmission`). Wire format: PROTOCOL.md §6.9.
- Each endpoint that receives invitations applies its own policy:
  "Automatically Allow Connections" (default on) plus a per-peer
  Default / Always Allow / Block keyed by the pinned peer ID. Forget
  removes the per-peer entry. Background attempts never prompt.
- Mac Sender: `MacSender.awaitSessionAdmission` holds capture until the
  receiver accepts (and, for a receiver's request that needs it, until the
  Mac's user approves in `SessionApprovalPromptModel`). `SenderController`
  applies the Mac's policy to receiver Connect requests and carries a
  session's invitation across `restartAll()` and wait-for-wake sessions.
- Receivers: `StreamReceiver` answers invitations on its control queue and
  presents no media until admitted; prompts are
  `Shared/SessionInvitationViews.swift` (iOS) and
  `MacReceiver/ReceiverSessionInvitationPanel.swift`.

## Connections, Remote Access, Wake & Connect

- The sender prefers USB when available and can move an active session
  between routes (`SenderController` failover/upgrade,
  `MacSenderTransportController`). There are two migration mechanisms —
  controller-driven `switchTransport` and the transport controller's
  internal `migrate(to:)` — so read both before changing transport code.
- **Remote Access** connects to a stored, validated private-network endpoint
  (`RemoteEndpointStore`, `RemoteEndpointValidation`). The address is a
  routing hint only; the pinned TLS session still authenticates.
- **Wake & Connect** (`WakeConnectCoordinator`, `WakeOnLAN`) asks a paired
  Mac's network to wake it and then connects. It depends on supported
  hardware, Wake for Network Access and network conditions, and targets a
  logged-in Mac that has gone to sleep; it is not a general "wake from
  anywhere" feature. See [Connections in the README](README.md#connections).

## Boundaries and invariants

- **Protocol changes are versioned.** New messages or fields follow
  [COMPATIBILITY.md](COMPATIBILITY.md); older peers must keep working or be
  gated by protocol version.
- **Don't bypass trust.** No plaintext fallback, no skipping SAS
  confirmation, no treating a route/address as identity.
- **Private API stays isolated** in `Mac/VirtualDisplay.swift`.
- **One gesture arbitration path** on iOS (see above).
- **Receiver-local presentation state stays receiver-local** (tray layout,
  viewport zoom, auto-hide); the sender only sees normalized input.
- **Keep capture lifecycle separate from transport recovery.**
- **Pure logic stays platform-neutral** in `Shared/` so it can be tested in
  `OpenSidecarMacTests` without a device.
- **`project.yml` is the source of truth** for targets; the `.xcodeproj` is
  generated.
- **Presentation strings are not APIs.** Behavior should key off typed state,
  with localization applied only when rendering. Known debt: the Devices
  settings row (`SessionRow` in `Mac/DevicesSettingsView.swift`) still picks
  its status color by matching English prefixes of `DeviceSession.status`
  such as `"Extending"` and `"Failed"`. Prefer the typed
  `CanonicalConnectionPhase` (`Mac/CanonicalRuntimeStatus.swift`) for new
  code rather than extending that pattern.

## Where should I start?

| If you are changing… | Start here |
| --- | --- |
| Device list, auto-connect, session lifetime | `Mac/OpenSidecarMacApp.swift` (`SenderController`, `DeviceSession`) |
| Capture, Mirror/Extend, capture recovery | `Mac/MacSender.swift`, `Mac/CaptureLifecycle.swift`, `Mac/VirtualDisplay.swift` |
| Video encoding / quality | `Mac/MacSenderVideoEncoder.swift`, `Shared/StreamingProfile.swift`, `Shared/EncoderCapability.swift` |
| Transport, USB, route switching | `Mac/MacSenderTransportController.swift`, `Mac/Usbmux.swift`, `Mac/RouteArbitration.swift` |
| Wire messages | `Shared/Protocol.swift`, [PROTOCOL.md](PROTOCOL.md) |
| Receiver connection, decode, render | `Shared/StreamReceiver.swift`, `Shared/ReceiverPipelineActor.swift`, `Shared/ReceiverVideoPresenter.swift` |
| iOS touch, Trackpad, keyboard, Pencil | `iOS/OpenSidecarPhoneApp.swift` (`VideoView`), `Shared/PointerGestureEngine.swift` |
| Shared scroll momentum | `Shared/ScrollMomentum.swift` |
| Control Tray / Function Tray | `iOS/ReceiverControls.swift`, `Shared/ControlProfile.swift`, `Shared/ControlTrayGeometry.swift` |
| Input injection on the Mac | `Mac/InputInjector.swift`, `Mac/InputRouting.swift`, `Mac/SystemGestureInvoker.swift` |
| Smart Touch | `Mac/SmartTouchTargetClassifier.swift` |
| Audio / A/V sync | `Mac/AudioCaptureEncoder.swift`, `Shared/ReceiverAudioPresenter.swift`, `Shared/PCMPlaybackEngine.swift` |
| Session invitations / connection approval | `Shared/SessionInvitation.swift`, `Mac/SessionApprovalPromptModel.swift` |
| Pairing, trust, TLS | `Shared/Pairing.swift`, `Shared/PairingSession.swift`, `Shared/TrustStore.swift`, `Shared/TLSConfigurator.swift` |
| Remote Access / Wake & Connect | `Shared/RemoteEndpointStore.swift`, `Shared/WakeConnectCoordinator.swift`, `Mac/RemoteAccessSettingsView.swift`, `iOS/RemoteAccessSettingsView.swift` |
| Mac Receiver | `MacReceiver/MacReceiver.swift` |
| Localization | `*/Localizable.xcstrings`, [CONTRIBUTING.md](CONTRIBUTING.md#translations) |
| Targets / build settings | `project.yml` |
| Tests | `MacTests/` (named `<Subject>Tests.swift`), `.github/workflows/tests.yml` |

## Related documents

- [README.md](README.md) — features and getting started
- [SETUP.md](SETUP.md) — building, signing, permissions
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to contribute, translations
- [PROTOCOL.md](PROTOCOL.md) / [COMPATIBILITY.md](COMPATIBILITY.md) — wire protocol and versioning
- [SECURITY.md](SECURITY.md) — security model and vulnerability reporting
- [SUPPORT.md](SUPPORT.md) — where to get help
- [TECHNICAL_NOTES.md](TECHNICAL_NOTES.md) — platform constraints behind the design
