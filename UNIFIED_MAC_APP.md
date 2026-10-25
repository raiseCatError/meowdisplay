# One Mac app: Share This Mac and Use This Mac as a Display

MeowDisplay.app shares this Mac to iPhones, iPads and other Macs, as it
always has. It can now also be the display: **Use This Mac as a Display**
(Overview, or the menu bar) turns on the Mac Receiver role inside the same
app, with the receiving keyboard and trackpad control from
[RECEIVER_INPUT.md](RECEIVER_INPUT.md). The standalone **MeowDisplay
Receiver** keeps shipping for Macs on macOS 12–13.

Distribution stays signed, notarized direct download with Sparkle. Mac App
Store distribution is out of scope.

## Why there were two Mac apps

| Reason | Fundamental? |
| --- | --- |
| The sender needs macOS 14 (ScreenCaptureKit, SMAppService, SwiftUI APIs), while the receiver runs on macOS 12 so old Macs can be displays. | **Yes**, for one bundle covering macOS 12–13 (see below). |
| The sender is a menu-bar (`LSUIElement`) app; the receiver is a windowed app. | No. An accessory app can switch to a regular one while a window is up. |
| Each app keeps its pairing identity in a Keychain access group named after its own bundle id. | No for new installs. It does mean a receiver's existing pairings can't simply carry over (see Migration). |
| Separate bundle ids, Sparkle feeds and release jobs. | No. Historical: the receiver started as a separate target (#145, upstream). |
| Two `@main` entry points and `AppDelegate`s. | No. These are the only symbol clashes between `Mac/` and `MacReceiver/`. |
| Both roles in one process share `TrustStore.shared` and one settings domain. | No, but it needed real work: see Trust. |

## Options

**1. Unified macOS 14+ app + standalone receiver for macOS 12–13 (chosen).**
- **Approach:** the sender target also compiles `MacReceiver/` (minus its app entry point and resources).
- **Complexity:** no availability gating, because receiver code written for 12 compiles unchanged at 14. The only side effect is a handful of deprecation warnings (`onChange(of:perform:)`).
- **Builds and tests:** everything in this repository's CI already exercises both targets.

**2. One macOS 12+ bundle with the sender gated to macOS 14.** Rejected, on
measured evidence. Compiling the current sender at
`MACOSX_DEPLOYMENT_TARGET=12.0` fails with **127 distinct availability errors
across 16 files**, and Swift stops after the first wave, so the real count is
higher:

| APIs | Errors |
| --- | --- |
| macOS 13 (grouped `Form` style, `SMAppService`, newer SwiftUI) | 85 |
| macOS 14 | 16 |
| ScreenCaptureKit 12.3 | 3 |
| Existing macOS 26/27 paths whose `#available` checks assume a 14 floor | 23 |

Making it work would mean:
- gating nearly every sender type and view with `@available(macOS 14, *)`
- a launch path that branches between two apps' worth of UI
- a sender whose every future change has to stay gated

None of the macOS 12–13 paths can be tested here. The receiver users on those
Macs gain nothing over the standalone receiver they already have.

## How the prototype works

- **One bundle:** `com.raisecaterror.meowdisplay.mac`, macOS 14, still `LSUIElement`, with the sender's feed and entitlements. `project.yml` adds `MacReceiver/` to the sender target, excluding `OpenSidecarMacReceiverApp.swift`, `Info.plist`, the entitlements, string catalogs and asset catalog.
- **Roles** (`Mac/MacAppRole.swift`):
  - Exactly one role has live sessions.
  - Turning the display role on ends the sender's sessions without suppressing reconnect, then starts the receiver.
  - While it's on, `startSession` refuses. Every auto-connect, Connect, receiver connect request and Remote knock goes through that gate.
  - Turning it off stops the receiver and lets devices reconnect.
  - This rules out a Mac streaming to itself, two Macs streaming into each other, and input looping between them, without tearing down the sender's listeners or pairing. Simultaneous roles were judged not worth those risks.
- **Off by default:** an existing install never starts advertising a receiver. The choice is remembered across launches.
- **Trust** (`TrustStore.Namespace`, `ReceiverRoleConfiguration`): the receiver role has its own identity and pins under `com.opendisplay.identity.v1.receiver` / `com.opendisplay.trust.v1.receiver`. That's the same separation the two apps had:
  - Pairing a Mac as this Mac's display never makes it a trusted sender here, and the reverse.
  - The sender's Keychain names are unchanged and pinned by a test.
  - The iPhone/iPad app and the standalone receiver don't declare `MeowDisplayReceiverRoleTrust`, so for them `TrustStore.receiverRole` is `TrustStore.shared` and nothing changes.
- **Settings:** the only key both roles used, `autoReconnectEnabled`, is `receiver.autoReconnectEnabled` for the receiver role in this app. The receiver's other keys (`receiverName`, `installID`, `audioPreferred`, `avSyncOffsetMs`, `showAnalytics`) don't collide with the sender's.
- **No self-discovery:** the sender ignores this app's receiver in its discovery and pairing browsers, and the receiver ignores this app's sender in its Mac-pairing browser (`SameAppPeerFilter`).
- **Window and focus:** while the display window is up the app is a regular app (Dock, Command-Tab), so Command-Tab is always a way out. It returns to the user's presentation when the window goes away.
- **Quit:** with the display role on, quitting sends the receiver's `closing` first, as the standalone receiver does.
- **Standalone receiver running:** the role refuses to start (and says why), because both would race for ports 9001/9002 and the same Bonjour services.
- **Unchanged:** pairing, TLS 1.3, pinning, per-session input authorization and the wire protocol.

## Existing users and migration

**Sender (MeowDisplay 1.20.0) users: no migration.** The update arrives
through the existing `appcast.xml` feed.
- **Same bundle id and signing team:** existing Screen Recording/Accessibility grants still apply, because TCC keys them to the bundle id and designated requirement. The Keychain group, identity, pins and settings are untouched.
- **New receiver identity:** the receiver role creates its own identity only the first time the user turns it on.

**Standalone receiver users:**
- Nothing is replaced or removed. The receiver's own feed (`appcast-receiver.xml`) keeps updating it, and macOS 12–13 Macs keep using it.
- On macOS 14+, the unified app's display role is a fresh install of the receiver role: **each sending Mac pairs with it once**. Its identity and pins live in the standalone receiver's Keychain group (`…mac.receiver`). macOS doesn't let another bundle id read that group, and the unified app does not try to.
- A later, optional migration could add a shared access group to both apps. An updated standalone receiver would then hand its identity over once. That copies a private key between apps, so it needs its own security review; the prototype doesn't do it.
- Receiver settings are cosmetic and re-set in seconds. They are not imported: they live in the other app's preferences domain.
- If both are installed on one Mac, the unified app's display role won't start while the standalone receiver runs. Users pick one.

**Release:**
- **Versions:** the unified app continues the sender's version line (1.21.0 onward); the standalone receiver continues its own.
- **Release workflow and Fastlane:** they build the same two targets as today. Nothing in `release.yml`, Fastlane or the feeds needs to change for the prototype. Release notes should point macOS 14+ receiver users to the unified app.

**Rollback:**
- Downgrading to 1.20.0 is safe. 1.20.0 ignores the receiver-role Keychain items and the `receiverModeEnabled`, `receiver.autoReconnectEnabled` and `installID` settings, and its sender data was never modified.
- If the role misbehaves after release, ship a sender update with the switch hidden. The receiver-role data stays in its own namespace.

## Verified (automated, this branch)

- **macOS suite:** `xcodebuild test -scheme OpenSidecarMac` passes **1960 tests, 0 failures**. That's 1946 on #25's head plus 14 new in `UnifiedMacAppTests`:
  - role transitions, persistence and rapid toggling
  - the sender's original Keychain names
  - receiver-role separation, and receiver-only apps unchanged
  - the role-scoped settings key
  - same-app discovery filtering
  - standalone-receiver conflict
  - packaging (bundle id, floor, feed, excludes, standalone receiver at 12.0)
- **Builds:** `OpenSidecarMacReceiver` (macOS 12 target) and `OpenSidecariOS` (generic device) both build. The unified bundle has the sender's id, `LSMinimumSystemVersion` 14.0, `LSUIElement`, `appcast.xml`, `MeowDisplayReceiverRoleTrust = separate`, and the receiver code linked in.
- **Not covered by automation:** live Keychain isolation (the unsigned test bundle has no Keychain entitlement), TCC, Bonjour on a network, and the window and activation-policy behavior.

## Physical checklist

Needs two signed builds of this branch (Developer ID or team-signed Debug), on
Mac A (sender) and Mac B (macOS 14+, to be the display).

1. **Upgrade in place.** On a Mac running 1.20.0 with paired iPhones, install this build: devices reconnect without re-pairing, and Screen Recording/Accessibility stay granted.
2. **Off by default.** Mac B shows nothing on the network until Use This Mac as a Display is on. Mac A's Devices list never shows Mac A itself.
3. **Pair and stream.** On Mac A, pair with Mac B's display role (one code confirmation), connect, Extend, then Mirror. The window goes full screen, Command-Tab works, and #25's control flow works.
4. **Roles exclusive.** With Mac B's display role on, Mac B's own iPhone doesn't connect to Mac B as a sender. Turning the role off brings the iPhone back without re-pairing.
5. **Trust separate.** A Mac paired only with Mac B's sender can't stream to Mac B's display role without pairing to it.
6. **Quit.** Quit Mac B mid-stream: Mac A ends the session rather than redialing.
7. **Standalone receiver.** With MeowDisplay Receiver running on Mac B, the switch refuses with its message.
8. **Rollback.** Reinstall 1.20.0 on Mac A: everything works as before.

## Remaining work before release

- **Receiver settings:** the display role's own settings (name, paired senders and Forget, audio, A/V sync) aren't in the unified Settings yet. The prototype uses defaults; pairing prompts and session approvals do appear.
- **Mirror-unavailable offer:** the "Use Extend" alert for a headless sending Mac isn't shown in the unified app yet. That Mirror attempt still fails cleanly when the offer times out.
- **Localization:** the receiver's strings aren't in MeowDisplay's string catalog yet. They're English-only today anyway.
- **Optional migration:** the shared-access-group migration for standalone receiver users, if wanted.
