# Research: Companion-free macOS access via Apple Screen Sharing

**Status:** Exploratory research only — NOT IMPLEMENTED, NOT COMMITTED TO A RELEASE  
**Reviewed:** 2026-11-03  
**Owner decision:** Preserve the existing native MeowDisplay full-experience path. Objective A is to connect to a Mac **without installing MeowDisplay on that Mac**. App Store eligibility of the iOS receiver is a mandatory design constraint. Swift/Rust preferred; Go is a reference, not an assumed runtime dependency.

See [RESEARCH_APPLE_COMPLIANCE.md](RESEARCH_APPLE_COMPLIANCE.md) for legal/store gates, [RESEARCH_REMOTE_POWER.md](RESEARCH_REMOTE_POWER.md) for power and unattended access. Existing authoritative implementation references: [ARCHITECTURE.md](ARCHITECTURE.md), [PROTOCOL.md](PROTOCOL.md), [WINDOW_MODE.md](WINDOW_MODE.md), [PARITY.md](PARITY.md), [SECURITY.md](SECURITY.md), [REMOTE_WAKE_ON_LAN.md](REMOTE_WAKE_ON_LAN.md). These research notes do not supersede shipped behavior or product scope.

## Terminology — do not conflate

- **VNC / RFB:** Remote Framebuffer protocol, standardized basic framebuffer/pointer/keyboard model, optionally extended by vendor protocols. Not inherently audio-less in all implementations; standard RFB itself does not promise audio, file transfer, virtual displays or window metadata.
- **Built-in macOS Screen Sharing host:** Apple's system service; can serve compatible VNC viewers and Apple's own Screen Sharing client. User must explicitly enable it in General > Sharing, restrict authorized accounts, and configure a separate VNC password if choosing that legacy authentication path.
- **Apple Screen Sharing Standard / High Performance:** Apple client modes communicating with the built-in Mac host. High Performance adds Apple-specific protocol extensions/capabilities (video, stereo audio, virtual displays, etc.). Apple officially supports Apple silicon Mac-to-Mac conditions; third-party iPhone/Android clients are **interoperability research, not Apple-supported endpoints**. One HP session per host, bandwidth/network limitations, and potential blanking of physical screens matter.
- **Sidecar:** Separate macOS-to-iPad feature, integrated with Apple Account, display and iPad interaction. Public docs show mirroring/extending and moving a window *to a display*; they do **not** establish that Sidecar speaks the same RFB protocol as Screen Sharing or exposes arbitrary independent per-window streams. Treat reusing Sidecar's private transport/identity/entitlements as a NO-GO absent explicit Apple authorization.
- **MeowDisplay native:** Our pv22 authenticated TLS TCP/QUIC/USB sender/receiver protocol, Mac companion, virtual display, ScreenCaptureKit Window view, audio, input and file/clipboard permission layers. No changes to this protocol are authorized by this note.

## OpenDisplay upstream: what it does (verified)

Official upstream https://github.com/peetzweg/opendisplay — documented https://github.com/peetzweg/opendisplay/blob/main/PROTOCOL.md and https://opendisplay.app/.

- **Not Apple's VNC/Sidecar backend.** Its own wire protocol connects an installed sender to a receiver. macOS sender uses CGVirtualDisplay (private SPI), ScreenCaptureKit capture, VideoToolbox encode; receiver decodes/forwards controls. MeowDisplay began from this project and developed its own secured protocol and additional features; do not equate their wire versions or merge blindly.
- **Linux sender/receiver are a Rust implementation of OpenDisplay's protocol**, not a way to connect to built-in Mac Screen Sharing. Sender: Wayland compositor virtual outputs, PipeWire capture, FFmpeg encoding (Hyprland; Sway/KDE/GNOME experimental); receiver: GTK/GStreamer. Linux sender and receiver still require software. Docs: https://opendisplay.app/docs/linux/install/ , https://opendisplay.app/docs/linux/desktops/ , https://opendisplay.app/docs/linux/receiver/.
- Community Linux sender projects: https://github.com/cray2015/opendisplay-x11 and https://github.com/tixwho/opendisplay-linux (independent; upstream lists them as third party). See https://opendisplay.app/docs/third-party/linux/.
- Android receiver exists; official Windows sender/receiver was **not confirmed** in upstream's supported release platforms as of review. Windows indirect display driver is an implementation idea in upstream protocol notes, **not a released Windows port**. MeowDisplay Windows/Linux projects remain explicitly out of scope (#84, #85), though protocol learnings are relevant.
- MeowDisplay tracks upstream separately at [REFERENCE.md](REFERENCE.md) and read-only reference/opendisplay; do not alter that machinery to integrate Apple protocol research.

## Existing third-party Apple Screen Sharing research

| Source | What it offers | Status / caution |
| --- | --- | --- |
| https://github.com/nekohasekai/open-screen-sharing | Swift Apple app + Go Apple VNC/Screen Sharing core; iOS client experiments; README says App Store variant excludes noncompliant iOS-server exploit and private-API file drag | **Research candidate**; do not integrate exploits/private APIs; GPL-3.0-or-later and attribution/name restrictions require review. A claimed App Store listing is NOT legal clearance for our app. |
| https://github.com/renegadelink/iShareScreen | Python independent High Performance client, HEVC/AAC/SRTP, Mac/Windows/Linux, protocol test/spec corpus | **Protocol research**; AGPL-3.0-or-later, no approval inferred; documented research includes static analysis/instrumentation, raising additional Apple contractual/legal review. |
| https://github.com/renegadelink/iShareScreen/blob/main/docs/apple_vnc_rfc.md | Explicitly experimental reverse-engineered RFB/Apple extensions, auth, encrypted controls, virtual-display and adaptive media | **Unverified independent protocol reference**, not an Apple standard. Legal review of provenance before implementing from it. |
| https://github.com/lucid-fabrics/sharelinux | Linux derivative/reference of Open Screen Sharing | **Secondary**; avoid mistaking derivative for independent validation. |
| https://github.com/rustvnc | Potential Rust standard VNC/RFB implementation building blocks | **Unassessed**: audit current license, security, iOS portability, maturity and codec/auth coverage first. |

## Proposed architecture (not adopted)

```
MeowDisplay receiver UI (iOS SwiftUI / Android Kotlin / Mac)
  -> Capability-driven session & input adapter
      -> Native MeowDisplay backend (existing): preferred when companion paired
      -> Apple Screen Sharing backend (research):
          A. Standard RFB / VNC compatibility (public networking APIs)
          B. Apple-enhanced HP extension (SEPARATE LEGAL/SECURITY GATE)
```

- Discovery is untrusted; do not silently authenticate by hostname/IP/Bonjour/Tailscale name. Preserve native pinned mutual TLS separately; Apple backend needs its *own* explicit identity/authentication and credential policy.
- Backend selection: default native when verified and reachable; explicitly offer Screen Sharing on a Mac whose built-in host is enabled. No protocol downgrade by ambiguous error, no silent insecure fallback, no sending credentials over unauthenticated legacy VNC on the public Internet. Tailscale/SSH tunnel alone provides network protection, not proof of host identity unless authenticated/bound.
- Shared receiver UI: touch/trackpad, view transforms, trays/chords, view-only PiP, local profiles; map to RFB pointer/keyboard events where expressible. Apple-specific gestures, special key codes, pressure/tilt and accessibility events are NOT assumed.
- Prefer **Swift** for iOS rendering, VideoToolbox/AVFoundation, UI and Keychain. Evaluate a **Rust static core** for shared byte parsing/handshake/state machine usable through Swift FFI and Android JNI, with explicit C ABI and no dynamic downloaded code. A pure Swift proof of concept may be faster. Porting Go to Rust/Swift does not automatically improve performance: benchmark, audit protocol behavior, and respect source licenses. Don't transliterate copyrighted source without reviewing derivative obligations.
- Do not copy the current MeowDisplay sender's security/permission claims into Apple mode: Screen Sharing owns its own trust/auth/authorization model and can provide broader Mac control.

## Feature feasibility (companion-free)

Labels: **Likely** = client side or standard capability; **Conditional** = Apple extension/prototype/OS limitations; **No equivalent established** = currently requires host-specific integration; **Separate** = power/network not provided by screen-sharing protocol. None below is a shipped claim.

| MeowDisplay feature | Built-in Apple Screen Sharing path | Main caveat |
| --- | --- | --- |
| Mirror / full desktop / basic cursor and typing | Likely | Standard RFB; host enabled + credentials |
| Touch styles / Trackpad / zoom, pan, rotation / trays / shortcut palettes / PiP | Likely for client-local behavior | Translate/approximate unsupported events; test macOS gestures |
| System audio + A/V sync / efficient HEVC | Conditional | HP protocol implementation and platform decoding/UDP; not baseline VNC |
| Extend / virtual display | Conditional | HP virtual-display model differs from independent per-device MeowDisplay Extend; Apple silicon and HP limits |
| Standard clipboard text and images | Conditional | RFB clipboard + Apple extensions, platform consent; format and file parity unknown |
| File transfer | Conditional | Apple's Screen Sharing supports files, third-party interoperable implementation unverified |
| Remote Finder browse/preview/rename/Trash | No equivalent established | General remote filesystem API not exposed through basic display protocol |
| Individual off-screen/covered window capture & nine-tile compositor | No equivalent established | Current per-window ScreenCaptureKit sender architecture essential; cannot infer independent window capture from framebuffer |
| Stage Peek exact window identity/live previews | No equivalent established | Can prototype shortcut-driven approximations, NOT exact per-window experience |
| Smart Touch AX target classification / caret follow | No equivalent established | Requires Mac Accessibility metadata; can do local heuristic approximation only |
| Apple Pencil pressure/tilt/hover as native tablet events | Conditional/limited | Pointer fallback only until actual server support verified |
| Privacy Shield | Conditional/different | HP remote-session blanking differs from MeowDisplay's overlay; can displace local user |
| Multi-receiver independent workspaces | Substantially constrained | Apple HP documented one session per Mac; other modes tested separately |
| Mac-specific permission grants / pinned mutual TLS | No equivalent | Different Apple host auth; never imply same security |
| Remote connection via private routed network | Likely | Reachable route + authenticated tunnel; no public port-forward by default |
| USB to iPhone / Android | Unverified | Existing MeowDisplay sender-driven USB binding is not the built-in Apple VNC server |
| Wake, power-on, cold boot, FileVault | Separate | See [RESEARCH_REMOTE_POWER.md](RESEARCH_REMOTE_POWER.md) |

### Important technical tradeoffs

Apple's documented High Performance implementation may blank a physical Mac when authenticating as its active user and permits one HP session at a time. This is NOT a direct replacement for MeowDisplay's concurrent local Mac use and per-receiver Extend. It may be excellent for *remote access*, less so for *second-display* use. Do not promise feature parity just because HP includes "virtual display".

## Experiment phases and measurable go/no-go

1. **Inventory and baseline.** Record macOS version/model, iOS/Android versions, Apple Screen Sharing host settings, Tailscale, FileVault state; no production setting changes. Capture native MeowDisplay baseline FPS, end-to-end latency, input feel, audio latency, reconnect and battery/CPU.
2. **Read-only protocol survey.** Compare Apple official docs, Open Screen Sharing (Go/Swift), iShareScreen spec and tests, GPL/AGPL/copyright provenance. Produce message-state diagram, auth-method matrix, threat model, current live support matrix. No incorporation of questionable code until compliance review.
3. **Standard VNC Swift/Rust spike.** Same-LAN physical Apple silicon Mac with explicitly enabled built-in Screen Sharing; negotiate RFB, authenticate securely, show screen, mouse/keyboard, scaling, focus and reconnect. Require safe tunnel for insecure modes, no passwords logged. No native feature regressions.
4. **HP proof of concept: legal-review gate before distribution.** Independently test Apple authentication, TCP control + UDP media, HEVC/AAC decode, virtual displays, clipboard/files, screen privacy, lost packets, macOS-version compatibility, Android portability. Observe proprietary protocol, never private iOS APIs, exploits or undocumented entitlements.
5. **Receiver feature integration.** Adapter + capability UI; no misleading controls. Physical tests for touch, input grants, haptics, shortcuts, Pencil, Stage Peek approximations; benchmark both modes.
6. **Distribution gate.** License/source notices, Apple Developer Program and App Review, possible DTS communication, threat model and security audit, 14/26/27 host compatibility, no code-download machinery, physical TestFlight review. Do not ship solely because a different app was approved.

**Do not start implementation from this document alone.** The research issue and draft PR are a backlog of hypotheses. No external repo is automatically trusted code and no future Apple compatibility is guaranteed.

## Primary references

- Apple Screen Sharing and virtual displays: https://support.apple.com/en-in/guide/mac-help/mh14066/27/mac/27
- Apple Screen Sharing host / VNC option: https://support.apple.com/en-vn/guide/mac-help/-mh11848/mac
- Apple HP requirements: https://support.apple.com/or-in/guide/remote-desktop/apdf8e09f5a9/mac
- Apple Sidecar (distinct feature): https://support.apple.com/en-in/102597
- OpenDisplay's protocol: https://github.com/peetzweg/opendisplay/blob/main/PROTOCOL.md
- OpenDisplay Linux source / docs: https://github.com/peetzweg/opendisplay/tree/main/linux , https://opendisplay.app/docs/linux/desktops/
- Apple interoperability protocol studies: project links in table above.
