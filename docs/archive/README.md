# Archive

Historical documents kept for the record. Nothing listed here is maintained
or authoritative: each file starts with a note naming the document to use
instead.

A document is moved here only when it describes a finished release, a newer
document covers its subject, and no code, tooling, test or active
instruction depends on it at its old path. Moved files keep their history:
use `git log --follow`.

## 1.20.0 launch — [`1.20/`](1.20/)

Material for the first public release (October 25, 2026), superseded by
2.0.0 and 2.1.0.

| File | Was | What it records | Use instead |
| --- | --- | --- | --- |
| [RELEASE_ASSETS.md](1.20/RELEASE_ASSETS.md) | `RELEASE_ASSETS.md` | 1.20.0 screenshot and asset plan | [fastlane/APP_STORE_LISTING.md](../../fastlane/APP_STORE_LISTING.md), [tools/press-kit/README.md](../../tools/press-kit/README.md) |
| [APP_STORE_LAUNCH.md](1.20/APP_STORE_LAUNCH.md) | `launch/` | 1.20.0 launch announcement | [README.md](../../README.md), [CHANGELOG.md](../../CHANGELOG.md) |
| [SOCIAL_POSTS.md](1.20/SOCIAL_POSTS.md) | `launch/` | Unposted 1.20.0 social drafts | [README.md](../../README.md), [CHANGELOG.md](../../CHANGELOG.md) |

## 2.0 handoff — marked historical, not moved

Written at the end of local 2.0 development (2026-10-31). They stay at their
original paths because `Shared/AutomaticRemoteRoutes.swift` and the Android
`AutomaticRemoteRoutes.kt` cite `handoff-2.0/COMPLETION-MATRIX.md` as
evidence. Each file is marked historical at the top.

| File | What it records | Use instead |
| --- | --- | --- |
| [CLOUD-HANDOFF-2.0.md](../../CLOUD-HANDOFF-2.0.md) | Local-to-cloud handoff: state, QA done, release pipeline as found | [BRANCHING.md](../../BRANCHING.md), [RELEASE.md](../../RELEASE.md), [ARCHITECTURE.md](../../ARCHITECTURE.md) |
| [COMPLETION-MATRIX.md](../../handoff-2.0/COMPLETION-MATRIX.md) | 2.x requirement status, 2026-10-28 … 31 | [PARITY.md](../../PARITY.md), [CHANGELOG.md](../../CHANGELOG.md) |
| [BRANDING-AUDIT.md](../../handoff-2.0/BRANDING-AUDIT.md) | Where legacy OpenSidecar/OpenDisplay names remain, and why | [TERMINOLOGY.md](../../TERMINOLOGY.md) |
| [EXTEND-START-ALTTAB-FINDINGS.md](../../handoff-2.0/EXTEND-START-ALTTAB-FINDINGS.md) | Extend start latency caused by AltTab flooding replayd | [ARCHITECTURE.md](../../ARCHITECTURE.md), `Mac/ShareableContentBroker.swift` |
| [PRIVACY-SHIELD-CRASH-SAFE-DESIGN.md](../../handoff-2.0/PRIVACY-SHIELD-CRASH-SAFE-DESIGN.md) | Design note behind the crash-safe shield prototype | [SECURITY.md](../../SECURITY.md), [Prototypes/CrashSafeShield/ASSESSMENT.md](../../Prototypes/CrashSafeShield/ASSESSMENT.md) |
| [RELEASE-2.0.0-ANDROID-QA-WAIVER.md](../../handoff-2.0/RELEASE-2.0.0-ANDROID-QA-WAIVER.md) | Owner's Android QA waiver for 2.0.0 only | [RELEASE.md](../../RELEASE.md) |
| [STORE-ACCESSIBILITY.md](../../handoff-2.0/STORE-ACCESSIBILITY.md) | What was verified for the 2.0 store accessibility declarations | No maintained replacement; check the store consoles before submitting |

## Current documentation

Start at the [README](../../README.md#documentation), then
[ARCHITECTURE.md](../../ARCHITECTURE.md), [SETUP.md](../../SETUP.md),
[CONTRIBUTING.md](../../CONTRIBUTING.md) and [RELEASE.md](../../RELEASE.md).
