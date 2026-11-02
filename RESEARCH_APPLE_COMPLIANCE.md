# Research: Apple compliance, protocol interoperability and software licenses

**Status: exploratory, NOT legal advice, NOT an App Review approval. Updated 2026-11-03.**
**Hard gate:** The iOS/iPadOS MeowDisplay receiver must remain eligible for the App Store. No copied proprietary Apple implementation, exploit, private iOS API, unauthorized entitlement or license-incompatible component may be included in a distributable build.

## Decision categories
- **Candidate / provisionally viable**: uses public OS APIs and authorized user-enabled Apple Screen Sharing service. Still requires testing and policy review.
- **Needs legal/App Review assessment**: undocumented Apple High Performance Screen Sharing extensions (including protocol derived from reverse engineering), especially use of source obtained by static analysis/instrumentation that might violate Apple agreements. Do not present interoperability exceptions as universal; jurisdiction, contract, acquisition method and provenance matter.
- **Not viable for App Store**: use of private iOS APIs, entitlement spoofing, OS exploits / sandbox bypass, disabling required platform protections, unauthorized Apple binaries/frameworks, circumventing Apple authentication / DRM, or downloading native executable code to bypass review. These are excluded even if a third-party repository implements them.
- **No evidence / not guaranteed**: a third-party app having been approved is not a ruling on our implementation; experimental protocol docs are not published Apple standards.

## Source register and legal use
| Source | Apparent license / notes | Intended use | Required action |
| --- | --- | --- | --- |
| https://github.com/peetzweg/opendisplay | GPL-3.0 upstream of MeowDisplay; own non-VNC protocol | Existing reference for sender/receiver architecture; Linux Rust example | Follow [REFERENCE.md](REFERENCE.md) and preserve upstream credit |
| https://github.com/nekohasekai/open-screen-sharing | GPL-3.0-or-later per project; Apple Screen Sharing protocol implementation in Go, Swift UI, includes iOS-specific restricted paths | Evaluate standard/enhanced protocol behaviors; no copy until complete dependency/code/provenance/license audit | Exclude documented private API or exploit portions from iOS build |
| https://github.com/renegadelink/iShareScreen | AGPL-3.0-or-later per project; experimental Apple HP reverse-engineered Python client and protocol notes | Research-only specification/test corpus | Review provenance and legal permissibility; AGPL 13 may matter if network-provided modified program; reuse requires legal assessment |
| https://github.com/lucid-fabrics/sharelinux | Derived from Open Screen Sharing; GPLv3 described | Secondary Linux reference only | Do not count as independent confirmation |
| Rust RFB clients | Not yet selected/verified | Standard VNC core candidate | Independently audit repo, license, auth support and maintenance |
| Apple's official Screen Sharing / Sidecar docs | Apple documentation, not open-source code | Authoritative published supported behavior | Do not treat docs as grant of private API access |

GPLv3/AGPLv3 compatibility can be possible under the applicable terms, but **translation into another language does not erase copyright**. A strictly independent reimplementation should document its input sources and reviewer findings. Check Open Screen Sharing's project-specific naming or trademark provisions; do not confuse these with baseline license grants.

## Apple-specific constraints

- Apple's App Review Guidelines §2.5.1 public API rule: https://developer.apple.com/app-store/review/guidelines/ . A pure Swift/Rust client using public sockets/crypto/VideoToolbox is **not automatically disallowed**, but App Review and other Apple contractual restrictions still apply to how proprietary extensions were obtained/implemented.
- Apple Developer Program License Agreement: https://developer.apple.com/support/terms/ . Investigate contractual reverse-engineering restrictions and lawful interoperability exceptions with counsel before HP extension release. Avoid asserting legality merely because the protocol is public on GitHub.
- Built-in macOS Screen Sharing works with compatible VNC viewers; enable and authorize on the Mac. Apple high-performance features are documented for compatible Mac clients, not a guarantee for third-party phones. https://support.apple.com/guide/mac-help/share-the-screen-of-another-mac-mh14066/mac and https://support.apple.com/guide/remote-desktop/use-high-performance-screen-sharing-apdf8e09f5a9/mac
- VNC authentication can be weaker than MeowDisplay's pinned mutual TLS; protect with authenticated encrypted network tunnels, host-key/pinning strategy where possible and clear user consent; **never auto-fallback to unsafe unauthenticated modes**.
- `com.apple.developer.persistent-content-capture` is a restricted entitlement for **host-side persistent capture**, not required just for viewing an enabled built-in Mac VNC server. Do not request it as a wake/boot mechanism. https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.persistent-content-capture and https://developer.apple.com/contact/request/persistent-content-capture/
- `com.apple.developer.networking.multicast` may require approval for broadcasting WoL from iOS. Confirm effective entitlements in signed App Store build; do not infer from local code. https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast
- Host Mac's CGVirtualDisplay private SPI already has compatibility/distribution considerations; it is not permission to use private **iOS** APIs. Keep distinct compliance tracks.
- Apple Sidecar is not documented as RFB; reverse-engineering Sidecar-specific identity and transport is **not a preferred or approved** implementation plan.

## Release checklist / outstanding legal questions

- [ ] Confirm current third-party repo licenses/NOTICE files and every transitive dependency at pinned commits.
- [ ] Record independent protocol evidence, capture methods and whether reverse-engineering involved Apple binaries, DRM, credential bypass, instrumentation or contract-prohibited steps.
- [ ] Obtain specific counsel opinion on use of undocumented HP protocol and source derivation, including relevant jurisdictions.
- [ ] Confirm with Apple Developer Technical Support/App Review as appropriate; responses are not blanket guarantees.
- [ ] Security-design review for authentication, credential storage, trust-on-first-use, clipboard/files, host consent and network downgrade.
- [ ] Verify iOS app entitlements (including multicast) on signed binaries; no runtime code download.
- [ ] Build non-shipping experiment/test matrix; distribution only after platform-specific QA and approval.

## Explicitly excluded ideas (no implementation, no redistribution)

Private iOS framework calls; OS exploits used to create a server on iOS; entitlement forgery; Mac auth or FileVault bypass; copying Apple's private Screen Sharing/Sidecar binaries; undocumented server injection; weakening user privacy consent; general network-service open port exposed to Internet as a shortcut; shipping a feature before proof that it's permissible.

See [RESEARCH_APPLE_SCREEN_SHARING.md](RESEARCH_APPLE_SCREEN_SHARING.md) and [RESEARCH_REMOTE_POWER.md](RESEARCH_REMOTE_POWER.md).
