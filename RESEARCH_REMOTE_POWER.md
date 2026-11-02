# Research: remote wake, full power-on, pre-login and FileVault recovery

**Research only — no claims that these flows work in MeowDisplay. Updated 2026-11-03.**
Existing design: [REMOTE_WAKE_ON_LAN.md](REMOTE_WAKE_ON_LAN.md), [TECHNICAL_NOTES.md](TECHNICAL_NOTES.md), [Shared/WakeOnLAN.swift](Shared/WakeOnLAN.swift), [Shared/WakeConnectCoordinator.swift](Shared/WakeConnectCoordinator.swift).

## Separate power states (do not conflate)

| State | Proposed mechanism | Status and limitations |
| --- | --- | --- |
| Screen off / Mac awake | Normal authorized connection + display activation | Existing native Mac session |
| Sleep / locked logged-in session | Local WoL magic packet, existing reconnect and wake orchestration | Implemented best effort, physical device/network constraints |
| Sleep, client outside LAN | Authenticated always-on LAN agent (router, Pi, NAS) sends WoL; then VPN/private network re-establishes | **Not implemented**. No direct broadcast over ordinary Tailscale overlay |
| Fully shut down / still powered | Cannot assume WoL will boot Apple silicon Mac; test exact model and supported firmware/feature | Hardware- and model-dependent; no universal Apple remote-boot API |
| Fully shut down, power restored | Desktop Macs: "Start up automatically after a power failure" (Energy settings, `pmset autorestart`); an authorized remotely controlled power switch *restores*, not interrupts, power. Not offered on Mac laptops (e.g. the MacBook Air M2); Apple silicon laptops may instead turn on when power is connected or the lid opens (configurable, verify per model and macOS version) | Conditional, requires specific Macs/software and hardware; never hard-cut an awake Mac |
| Fully shut down via physical button | Approved external actuator or controller physically operates power button | Hardware project; installation, safe state/authorization and reliability tests |
| Boots to FileVault preboot | Supported SSH-based preboot unlock mechanism on eligible Apple silicon/macOS 26 configurations | Independent auth/security research. VPN/normal daemon might not operate in preboot. No password bypass/storage by default |
| Boots to LoginWindow without user | Built-in macOS Screen Sharing may support login/session behavior; native sender would need dedicated pre-login daemon/agent/XPC design | Separate research; not solved by WoL or `persistent-content-capture` |

## Existing MeowDisplay architecture

Local WoL currently sends 6 FF bytes followed by 16 repeats of learned MAC to paired peer's broadcast address (UDP port 9); this is **not** an over-Internet wake mechanism. Followed by connect request / verified TLS identity and Promote Interactive Wake. A stored IP, Bonjour name or remote endpoint never grants trust.

The one-device relay design in [REMOTE_WAKE_ON_LAN.md](REMOTE_WAKE_ON_LAN.md) is already documented but unimplemented. Do not duplicate/deprecate it; this page adds cold boot and security questions.

## Prior art, provisional source register

- Apple Mac energy/automatic start docs: https://support.apple.com/ (find model-specific documentation for "Start up automatically after a power failure" and laptop power-on behavior, and confirm supported releases).
- Apple remote FileVault unlock instructions: https://support.apple.com/ (verify supported macOS/Apple silicon versions, Remote Login provisioning and network).
- Apple Developer Forums: https://developer.apple.com/forums/thread/814152 (ScreenCaptureKit LoginWindow sessions + launch daemon/agent).
- Apple's restricted persistent-content-capture entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture — host-side capture, not remote power-on.
- AnyDesk WoL support: https://support.anydesk.com/ (other online LAN endpoint relays WoL; verify Mac model support).
- RustDesk macOS pre-login service: https://github.com/rustdesk/rustdesk/discussions/7762 ; https://github.com/rustdesk/rustdesk/wiki/macOS-Auto%E2%80%90Start-Service-Setup-%28for-Remote---MDM-Deployment%29
- Third-party FileVault SSH research: https://github.com/shoon/fv-ssh-unlock and https://github.com/regulad/lime ; review safety/licensing/actual Apple documentation before reuse.

## Questions / test plan

1. Identify exact Mac models (MacBook Air M2 and any future desktop Mac); OS, power state, charger, lid, network interface, FileVault, and firmware. Never transfer capability claims across models.
2. Determine supported automatic start behavior with external power switch or actuator; safe guards against cutting power while running; assess security risks from remote hardware controls.
3. Experiment with authorized LAN WoL vs sleep, shutdown, reboot, power cycle and locked login, with physical console available.
4. Prototype authenticated single-purpose LAN relay without arbitrary MAC/command injection; no public UDP forwarding; consider Tailscale/pinned credentials.
5. For eligible hardware, test SSH FileVault recovery in lab with no stored credentials, replay protection, no exposed SSH port, no claim of global preboot VPN connectivity.
6. Define distinct diagnostics (asleep, powered off, wake sent, preboot auth required, Mac online, screen-sharing enabled, unavailable). No false "offline means asleep" inference.
7. Only after platform QA and compliance review, integrate opt-in recovery into the Apple Screen Sharing backend and/or native backend independently.

## Explicit non-goals / forbidden shortcuts

- Do not tell users Apple persistent-content-capture entitlement powers on a Mac.
- Do not promise wake-from-anywhere from local WoL.
- Do not bypass FileVault/authentication; don't store unlock passwords to make unattended startup look easy.
- Do not cut electricity to a Mac that may still be running.
- Do not weaken existing paired-device trust, connection consent or app-store compliance.

See [RESEARCH_APPLE_COMPLIANCE.md](RESEARCH_APPLE_COMPLIANCE.md).
