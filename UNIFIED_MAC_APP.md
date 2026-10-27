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
- **Approval policy and peer data** (`RolePreferences`): each role keeps its own "Automatically Allow Connections", per-Mac Connection Requests overrides, Remote endpoint hints and Wake metadata. In this app the receiver role's keys are `receiver.`-prefixed (`receiver.incomingSessionAutomaticallyAllow`, `receiver.incomingSessionPeerPolicy.v1`, `receiver.remoteEndpointHints.v1`, `receiver.wakeMetadataHints.v1`, `receiver.inputAutoRequestPeers.v1`, `receiver.autoReconnectEnabled`).
  - Every call to those stores names its role, so the compiler catches a call site that doesn't.
  - The receiver role's automatic approval is **off by default**: a Mac connecting to this Mac as a display asks first, until the user turns it on for that role. The sender's stays on by default, as in 1.20.0.
  - Separate install ids weren't enough on their own: a peer chooses the id it pairs with, so one id can be pinned in both roles.
  - The sender, the iPhone/iPad app and the standalone receiver keep the original key names, so their saved choices are read exactly as before.
- **Other settings:** the receiver's remaining keys (`receiverName`, `installID`, `audioPreferred`, `avSyncOffsetMs`, `showAnalytics`, `receiverFullscreen`, `receiverControlPreferences.v1`) are used only by the receiver role. The sender's per-device keys (`extendShape.*`, `receiverMaxFPS.*`, `installIDByUDID`) are used only by the sender. Cat Mode is shared, and is cosmetic.
- **Settings page:** **This Mac as a Display** in MeowDisplay's Settings (and a link from Overview) holds the role's own settings, apart from the sender's pages:
  - the switch and status
  - name
  - paired sending Macs, with Automatically Allow Connections, each Mac's Connection Requests, Connect and Forget
  - audio and A/V Sync
  
  Its sections are the standalone receiver's own, shared between both apps. With the role off, paired Macs are still listed and can be forgotten, without putting this Mac on the network.
- **No self-discovery:** the sender ignores this app's receiver in its discovery and pairing browsers, and the receiver ignores this app's sender in its Mac-pairing browser (`SameAppPeerFilter`).
- **Not advertised as a sender while a display:** with the role on, the sender withdraws its `_opendisplay-mac-pair._tcp` advertisement, so other receivers' Nearby lists don't offer this Mac to share with them. It comes back when the role is turned off.
  - Receivers use that advertisement only for listing and starting pairing; reconnect doesn't depend on it.
  - Paired receivers still list this Mac from their pins. A Connect or Remote knock from them is refused by the role gate, as before.
- **Window and focus:** while the display window is up the app is a regular app (Dock, Command-Tab), so Command-Tab is always a way out. Changing the Dock/menu-bar setting meanwhile doesn't undo that. It returns to the user's presentation when the window goes away.
- **Mirror unavailable:** when the sending Mac is headless and Mirror was asked for, Settings opens with the standalone receiver's "Use Extend" offer.
- **Off and straight back on:** the new receiver starts only after the old one has released its listeners and network services. A stopped receiver is retired: a listener retry scheduled before the stop can't reopen a port.
- **Quit:** with the display role on, quitting sends the receiver's `closing` first, as the standalone receiver does.
- **Two receivers on one Mac** (`ReceiverOwnershipLock`): the display role and the standalone receiver both take one kernel `flock` on `~/Library/Application Support/MeowDisplay/receiver.lock` before opening any listener or advertising anything. Neither app is sandboxed, so both use the same file.
  - Whichever starts second, in either order, binds nothing. It shows what to quit, checks again every 2 seconds until it starts or is turned off (`stop()` cancels the check), and starts by itself once the other lets go.
  - The owner releases the lock only after its listeners have closed, and keeps the descriptor open the whole time it owns the ports. The kernel releases it if the owner quits or crashes, so a stale lock can't block anyone. Release never unlinks the file: a waiting receiver must keep locking the same file.
  - Already-released MeowDisplay Receiver builds predate the lock, so the display role also waits while any standalone receiver is running (bundle id).
  - Never needed for safety: a second bind on the same port fails with "address in use" rather than sharing it (measured). The lock makes that failure explicit and recoverable instead of a silent retry loop.
- **The lock file can't be planted or swapped.** A predictable name in the user's home isn't safe by itself, so:
  - The path is walked from the home directory (from the account database, not `$HOME`) one component at a time with `openat(O_DIRECTORY | O_NOFOLLOW)`. No component is ever followed through a symlink. Missing folders are created `0700`.
  - Every folder on the way (`~`, `Library`, `Application Support`, `MeowDisplay`) must be owned by this user and not group- or world-writable (`fstat` on the open descriptor). So nobody else can replace a component between the checks and the open.
  - The file is opened with `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC` and created `0600`. A planted FIFO can't hang the open. Then `fstat` requires a regular file owned by this user with one link. An older build's `0644` file is tightened to `0600`.
  - There's one location and no fallback. A second location would let two receivers lock different files.
- **Fails closed.** If the lock can't be used safely (symlink, wrong owner, writable by others, not a regular file, hard link, permission denied, any other error), the receiver **does not start**. It never runs as though it owned the ports. The status says what's wrong and where. It isn't retried by itself; **Try Again** (role settings, or the standalone receiver's settings) checks again after the user fixes it. Turning the role off clears it.
- **Ports taken by something else** (`ReceiverPortHealth`): the lock is per user, so it can't see a receiver in another login session or an unrelated app. There, the actual bind is the final word. When the media (9001) or pairing (9002) listener fails to bind, the status says which port is in use and what that means ("no Mac can connect", or "new Macs can't pair"). The existing 1-second listener retries continue and end when the receiver stops (a retired receiver never reopens a listener). The message clears itself once the listener is ready. QUIC (UDP 9001) failing alone isn't reported: TCP still carries the session.
- **Cross-user limitation (accepted):** two macOS accounts logged in at once don't coordinate through the lock. Whichever binds second shows the port-in-use status and waits for the port. MeowDisplay doesn't try to see, stop or work around another user's processes, and has no privileged helper for this.
  - The receiver's pairing listener now retries a failed bind like its media listener, so pairing comes back once the port frees.
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
- If both are installed on one Mac, only one is a display at a time. The other waits and says what to quit.

**Release:**
- **Versions:** one release tag versions both Mac apps, as `release.yml` builds them: the unified app and the standalone receiver ship together as 2.0.0. Each keeps its own bundle id and Sparkle feed (`appcast.xml`, `appcast-receiver.xml`). `CFBundleVersion` must sort above the shipped 1.20.0's `1` (for example `2.0.0`), or Sparkle offers no update.
- **Release workflow and Fastlane:** they build the same two targets as today. Nothing in `release.yml`, Fastlane or the feeds needs to change for the prototype. Release notes should point macOS 14+ receiver users to the unified app.

**Rollback:**
- Downgrading to 1.20.0 is safe. 1.20.0 ignores the receiver-role Keychain items and the `receiverModeEnabled`, `receiver.*` and `installID` settings, and its sender data was never modified.
- If the role misbehaves after release, ship a sender update with the switch hidden. The receiver-role data stays in its own namespace.

## Verified (automated, this branch)

- **macOS suite:** `xcodebuild test -scheme OpenSidecarMac` passes **2002 tests, 0 failures**. That's 1946 on #25's head plus 56 new:
  - `RolePreferencesIsolationTests` (14): the approval-policy leak in both directions, the receiver role's own default, original key names for existing installs, per-Mac overrides with the same peer id in both roles, role switching and relaunch, both authorization entry points, and per-role endpoint and Wake data. With the keys still shared, 12 of the 14 failed.
  - `UnifiedMacAppTests` (17):
    - role transitions, persistence and rapid toggling
    - the sender's original Keychain names
    - receiver-role separation, and receiver-only apps unchanged
    - role-scoped settings keys
    - same-app discovery filtering
    - standalone-receiver conflict
    - sender advertisement withdrawn exactly while a display, through rapid toggling
    - packaging (bundle id, floor, feed, excludes, standalone receiver at 12.0)
    - the Dock/Command-Tab rule
    - the settings page and its search
    - a guard that the receiver's settings code never uses the sender's trust store or keys
  - `ReceiverOwnershipTests` (25):
    - both launch orders, and a receiver without the lock
    - **a real second process** (`flock(2)` on the same file) in both orders: holding the lock, then exiting normally, being killed with `SIGKILL`, and release and reacquisition (the file is never unlinked)
    - an existing file reused and tightened to `0600`; a new folder `0700` and file `0600`
    - refused, without creating anything through it: a symlink at the lock path (dangling or not), a symlinked folder, a hard-linked file, a folder or FIFO at the file's name, a file where a folder belongs, a folder others can write to, an unwritable folder, a folder owned by root, and files and folders of another uid (`fstat` checks)
    - an unusable lock never lets the receiver start
    - the status messages for lock problems and taken ports
    - a port held by another process: the receivers' listener parameters fail with "address in use" and `ReceiverPortHealth` reports it until cleared (an ephemeral port, so a running MeowDisplay isn't disturbed)
    - retired listeners never reopening, the pairing listener's retry, and a real second bind failing with "address in use"
- **Builds:** `OpenSidecarMac`, `OpenSidecarMacReceiver` (macOS 12 target) and `OpenSidecariOS` (generic device) all build. The unified bundle has the sender's id, `LSMinimumSystemVersion` 14.0, `LSUIElement`, `MeowDisplayReceiverRoleTrust = separate`, and the receiver code linked in.
- **Not covered by automation:**
  - live Keychain isolation (the unsigned test bundle has no Keychain entitlement)
  - TCC
  - Bonjour on a network
  - window and activation-policy behavior
  - the receiver restart timing
  - the two real apps side by side (not launched here, to avoid a second sender next to the running MeowDisplay)
  - the SwiftUI pages themselves

## Physical checklist

Needs two signed builds of this branch (Developer ID or team-signed Debug),
on Mac A (sender) and Mac B (macOS 14+, to be the display). Test #24's
per-device Mirror/Extend and #25's input on the same builds.

1. **Upgrade in place.** On a Mac running 1.20.0 with paired iPhones, install this build:
   - devices reconnect without re-pairing
   - Screen Recording/Accessibility stay granted
   - "Automatically Allow Connections" and per-device choices are unchanged
2. **Off by default.** Mac B shows nothing on the network until Use This Mac as a Display is on. Mac A's Devices list never shows Mac A itself, and Mac B's Nearby Macs never shows Mac B.
   - With Mac B's role on, an iPhone's (or Mac A's receiver) Nearby list no longer shows Mac B as a Mac to share from.
   - Turn the role off: Mac B appears again, and its paired devices reconnect.
3. **Pair and stream.** On Mac A, pair with Mac B's display role (one code confirmation), connect, Extend, then Mirror. The window goes full screen, Command-Tab works, and #25's control flow works.
4. **Approval is per role.** With Mac B's sender "Automatically Allow Connections" on (the default), Mac A's automatic connection to Mac B's display role is **not** admitted silently: Mac B asks, or declines a background attempt. Turn it on in **This Mac as a Display**: Mac A connects without asking, and Mac B's sender setting is unchanged.
5. **Per-Mac choices are per role.** Block Mac A on the display page. Mac B's sender settings for its devices don't change. Forget Mac A there with the role off, then turn the role on: Mac A must pair again.
6. **Settings page.**
   - Rename the display: Mac A's list updates.
   - Audio on: sound plays on Mac B, and A/V Sync and Resync work.
   - Reopen Settings after relaunch: all of it is remembered.
7. **Roles exclusive.** With Mac B's display role on, Mac B's own iPhone doesn't connect to Mac B as a sender. Turning the role off brings the iPhone back without re-pairing.
8. **Trust separate.** A Mac paired only with Mac B's sender can't stream to Mac B's display role without pairing to it.
9. **Rapid switching.** Turn the role off and on three times quickly, then connect from Mac A: it pairs or connects normally, with no "address in use" in the log.
10. **Mirror unavailable.** Close Mac A's lid (on power, with Mac A's display role off), ask for Mirror from Mac B: Settings opens on Mac B with "Use Extend", and Use Extend works.
11. **Dock and Command-Tab.** In menu-bar-only mode, stream to Mac B: the Dock icon appears and Command-Tab leaves the window. Switch presentation in Settings meanwhile: Command-Tab still works. End the stream: the Dock icon goes away.
12. **Quit.** Quit Mac B mid-stream: Mac A ends the session rather than redialing.
13. **Standalone receiver, both orders.**
    - **Standalone first:** with MeowDisplay Receiver (this branch's build) running on Mac B, turn the role on. It shows "MeowDisplay Receiver is already using this Mac as a display…" and binds nothing (`lsof -i :9001` shows only the standalone receiver). Quit the standalone receiver: within a few seconds the role starts, and Mac A can pair and connect.
    - **Display role first:** with the role on, open the standalone receiver. Its status says MeowDisplay is using this Mac as a display; Mac A keeps streaming to the role. Turn the role off: the standalone receiver starts by itself and is pairable.
    - Repeat the first order with an already-released MeowDisplay Receiver: the role waits the same way.
    - Relaunch MeowDisplay while the standalone receiver runs: the switch stays on and waiting.
    - **Unsafe lock:** quit both, replace `~/Library/Application Support/MeowDisplay/receiver.lock` with a symlink (`ln -sf /tmp/x …`), turn the role on: it doesn't start, says the file is a symbolic link, and binds nothing. Remove the link, click Try Again: it starts.
    - **Port taken:** with the standalone receiver running in a second macOS account (fast user switching), turn the role on in the first: the status says port 9001 is in use. Quit the other account's receiver: the role comes up by itself.
14. **Rollback.** Reinstall 1.20.0 on Mac A: everything works as before.

## Remaining work before release

- **Hardware QA** of the checklist above, with #24 and #25.
- **String catalog:** the receiver's strings and the new page's strings aren't in MeowDisplay's catalog yet. Xcode adds them on the next IDE build. The catalogs are English-only, so nothing user-visible changes meanwhile.
- **An already-released MeowDisplay Receiver opened second:** it predates the lock and can't be changed. Its own binds fail, so it doesn't disturb the running display role, and it shows no explanation itself. MeowDisplay notices it opening while the role owns the ports and says so under the role's status ("MeowDisplay Receiver was opened, but this Mac is already a display here…", `StandaloneReceiverConflict.noticeWhileDisplay`), until it quits or the role is turned off. When the role turns off, its media listener takes the ports, while its pairing listener (unlike this branch's) doesn't retry. Updating the standalone receiver to this branch's version fixes both.
- **Another account or app on ports 9001/9002:** shown as "port in use" and retried every second while the receiver is on. The lock doesn't coordinate accounts (by design, see above).
- **Optional migration:** the shared-access-group migration for standalone receiver users, if wanted.
