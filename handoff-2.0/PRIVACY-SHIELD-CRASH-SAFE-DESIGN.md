<!-- Sanitized copy of the integration folder's DESIGN-2026-10-30-crash-safe-shield.md (2026-10-31). Local paths and personal names removed; the integration folder holds the original and evidence. -->

# Crash-safe Privacy Shield: design note (2026-10-30)

Status: design only. Nothing here is built. No privileged helper is proposed: covering screens
and locking the session need no root.

## The weakness

The cover windows belong to the MeowDisplay process. If it crashes, is force-quit or is killed
(`kill -9`, a debugger, an out-of-memory kill), the window server removes them at once. The
device's picture also stops, so nothing leaks to the device. But the Mac's own screens show
whatever the remote user left open, and the Mac is still logged in and unlocked. That is the
leak the shield exists to prevent, so the shield is **not crash-safe** today. A normal Quit is
already handled: it locks the screen before the windows go.

What can't be fixed inside one process: no code runs after SIGKILL, and a crash handler can't
safely draw windows or post events.

## Options

### A. Fail-closed marker plus relaunch on abnormal exit (small; no new process)

- While the cover is up or held, keep a marker (UserDefaults or a file in Application Support)
  saying "covering since T, held until local unlock". Clear it only on a local password unlock,
  the same moment `held` is cleared now.
- Register a user LaunchAgent for the app itself with `SMAppService.agent(plistName:)`
  (`KeepAlive = { SuccessfulExit = false }`), approved by the owner in Login Items. launchd
  relaunches the app after a crash or kill, not after a normal Quit.
- At launch, if the marker is set, cover every display and lock the screen before doing
  anything else (`MacScreenLock.lock`; it needs Accessibility, which the app already has).
- Exposure window: crash → relaunch → first cover. Probably 0.5–2 s. Measure it; don't assume.
- Downside: a deliberate Force Quit relaunches the app into a covered, locked state. That is
  the fail-closed choice, and the owner unlocks with the password.

### B. A separately maintained shield controller (the supervised design)

- A small helper app bundled in MeowDisplay (Contents/Library/LoginItems), registered as a
  user LaunchAgent (`SMAppService.agent`, `KeepAlive = true`). It runs as the user, not root.
- It owns its own pooled cover windows at the shielding level, with `sharingType = .none`.
  It reports their window IDs to the main app over XPC (`NSXPCConnection`, a Mach service named
  in the agent plist), so every capture leaves them out, the same as the app's own covers today.
- While a protected session runs, both processes cover: the app's covers (today's code) and
  the helper's. If either process dies, the other's covers stay up.
- The helper watches the main app with `DispatchSource.makeProcessSource(.exit)`. If the app
  exits while covering and the exit wasn't the normal-Quit handshake, the helper keeps covering
  and locks the screen. That needs its own Accessibility grant, or it asks the app to do it
  after the relaunch in A.
- Unlock happens only in the helper, from this Mac's own input plus the login password (the
  same rules as `PrivacyShieldPolicy.isPhysical` and `askForLoginPassword`). The main app can
  ask it to cover, never to uncover. A remote device therefore can't uncover the Mac even
  through a compromised main app.
- Costs: a second target and bundle, XPC, an install and approval step, a second Accessibility
  grant if it locks the screen itself, and tests for the handshake. About a day of work, plus
  physical checks.

## Recommendation

Do A first. It is small, closes the window from "until someone notices" to about a second,
and needs no new process. Then B if the owner wants protection that also holds while the app
itself misbehaves. Neither should claim "crash-safe" until a physical check passes.

## Verification (needs the owner's OK; disposable desktop)

1. A disposable test pattern on screen, the shield up, the WindowServer tracer running
   (evidence/privacy-shield-2026-10-30/), then `kill -9` the Dev app.
2. Measure the uncovered gap from the trace. Expect 0 for B, and the relaunch time for A.
3. Also watch the panel itself, with eyes or a camera. The trace is a window-layer check, not a
   physical-display check.
4. Repeat for: crash during an active session, crash while held after disconnect, a normal Quit
   (must lock as today) and Force Quit.

## Option B in detail: the Service Management helper (2026-10-30 evening)

Investigation only. Nothing is built or installed; installing it needs the owner's separate OK.

**Packaging and approval (Apple's supported path, no root):**
- A second, small app target, `MeowDisplay Shield`, inside the main bundle at
  `Contents/Library/LoginItems/MeowDisplay Shield.app`, plus a launchd property list at
  `Contents/Library/LaunchAgents/<bundle id>.shield.plist` with `BundleProgram` pointing at it,
  `MachServices = { <bundle id>.shield = true }` and `KeepAlive = true`. Same team signature and
  hardened runtime as the main app; no entitlement beyond what a normal app has.
- Registration: `SMAppService.agent(plistName:).register()` from Settings ▸ Privacy Shield, only
  after the owner turns on "Keep the shield up if MeowDisplay quits unexpectedly". The status then
  reads `.requiresApproval` until the owner allows it in System Settings ▸ General ▸ Login Items
  (`SMAppService.openSystemSettingsLoginItems()` takes them there). The app already uses
  `SMAppService.mainApp` for Start at Login, so the same status handling applies.
- Removal: `unregister()` from the same setting, and it is listed in Login Items where the owner
  can turn it off at any time. Turning it off there must be honoured without nagging.

**Runtime model:**
- The helper runs as the logged-in user, starts at login, and idles (no windows, no timers)
  until the main app connects over XPC (`NSXPCConnection(machServiceName:)`). The app checks the
  helper's code signature on connect (same team ID), and the helper checks the app's.
- Messages, one direction only for safety: the app may say `cover(displays)` and
  `sessionEnded`; it can never say "uncover". The helper answers with its cover window IDs so
  every capture leaves them out, as it does for the app's own covers.
- While covering, the helper keeps its own pooled windows at the shielding level with
  `sharingType = .none`, under the app's covers. It watches the app with
  `DispatchSource.makeProcessSource(identifier:eventMask: .exit)`.
- If the app exits without the clean-quit handshake while covering, the helper stays up and keeps
  covering every display, and shows the same Unlock button. launchd relaunches the app if the
  owner chose that (option A), and the app reconnects and takes over again.
- If the helper itself dies, launchd restarts it (`KeepAlive`); the app's covers are still up,
  so one of the two always covers. Both dying at once leaves the Mac uncovered: that is the
  remaining limit, and Quit locking the screen still applies to a normal Quit.

**Unlock model (in the helper, never driven remotely):**
- Only physical input counts (`CGEvent` source PID 0, as `PrivacyShieldPolicy.isPhysical`), and
  only the login password unlocks: the same `AuthorizationCopyRights` with
  `kAuthorizationRuleAuthenticateAsSessionUser` the app uses now. No other unlock path, no
  "uncover" message, no timeout.
- Recovery if something goes wrong: the owner can always unlock with the password on the Mac;
  turning the helper off in Login Items stops it; logging out ends it. Nothing needs root.

**Tests before any claim:** unit tests for the XPC message rules (no uncover path), the
clean-quit handshake and window-ID exclusion; then, with the owner's OK and a disposable desktop,
`kill -9` of the app while covering, a crash during a session, a crash while held, a normal Quit,
a Force Quit and a helper kill, each watched on the panel and with the window-layer tracer.
Only after those pass may anything say "crash-safe".

## Prototype results and security model (2026-10-30, night)

Owner's decision: build and test an isolated prototype; no persistent helper installed or
registered. Done in `Prototypes/CrashSafeShield/` (commit e3c0297): a policy core with 9 unit
tests, the keeper (option B), a stand-in for the app, a window-layer tracer and five scenarios.
Nothing was registered with launchd, nothing is privileged, and SIP and macOS security settings
are untouched. Evidence: `evidence/crash-safe-prototype-2026-10-30/` (traces and logs).

### Measured (window-layer tracer, about 8 ms per sample, one display active)

| Scenario | Result | Uncovered |
|---|---|---|
| B1 app `kill -9` while covering | the keeper's cover stayed; it logged "locking" (not performed in the test) | **0** until the test release |
| B2 app normal Quit while covering | keeper held the cover, no lock | **0** |
| B3 keeper `kill -9` | the app's own cover stayed | **0** |
| A1 app `kill -9`, relaunched at once by the script, covers from its marker | | **315 ms**, best case: a tiny process, no launchd delay |
| B4 keeper main thread hung, then app `kill -9` | the frozen keeper windows still covered; the watchdog fired after 3.0 s, then the keeper exited | open: from then on only the screen lock protects |

What this means:
- **A (relaunch)** always leaves a gap. 315 ms is the floor. Add launchd's respawn time and the
  real app's launch before its first cover. launchd also throttles a job that ran under
  10 s (`ThrottleInterval`) by up to 10 s. On a crash, the Mac's own screen shows whatever was
  open for that long.
- **B (keeper)** kept the screens covered with no measurable gap through an app crash, a normal
  Quit and a keeper crash. Its weak point is a double failure: the keeper hung *and* the app
  gone. There the keeper must lock the screen before it lets go.
- Not yet measured: physical panels (eyes or camera), more than one display (only one was
  active), sleep/wake while covering, and a display change while covering (the keeper re-covers
  on screen-parameter changes; untested).

### Security model

**Who is protected from what.** The shield hides this Mac's screens from people *at the Mac*
while a paired device controls it. The remote controller runs as the same macOS user, so it is
not a security boundary against that person. Same-user processes can always stop each other.
The macOS lock screen is the boundary: the keeper locks whenever it can't vouch for its cover.

**Components (production design, nothing privileged):**
- `MeowDisplay Shield.app` (the keeper), inside the main bundle under
  `Contents/Library/LoginItems`. It is registered as a **user** LaunchAgent with
  `SMAppService.agent(plistName:)` and `KeepAlive`. The owner approves it in System Settings ▸
  General ▸ Login Items and can turn it off there. No root, no daemon, no system extension, no SIP change.
- Channel: XPC on a Mach service named in the agent plist. Both ends require the other's code
  signature (`NSXPCConnection.setCodeSigningRequirement`, same team ID and bundle identifier),
  so another process can't command the keeper or impersonate it. The prototype uses an inherited
  socket pair instead (only the parent holds the other end), because a Mach service needs the
  launchd registration that wasn't approved.

**Rules (enforced in `KeeperPolicy`, unit-tested):**
1. The app can only say *cover*, *session ended* and *quitting normally* (with the keeper's
   nonce). There is no uncover message. Unknown or forged messages are logged and ignored.
2. Uncovering happens only in the keeper. It needs a click from this Mac's own input (event
   source PID 0) plus the owner's confirmation. That means Touch ID when the Mac has it and the owner
   allows it (LocalAuthentication `.deviceOwnerAuthentication`, with "Use Password…" on the same
   sheet; owner request 2026-10-30), otherwise the login password (Authorization Services,
   `authenticate-session-owner`). There is no timeout and no remote path. The app's own shield
   does the same since that night (setting: Privacy Shield ▸ Remove With Touch ID, on by default).
3. The last session ending keeps the cover up (held) until that unlock. This is the same as today.
4. The app vanishing without the handshake while covering or held: stay covered and lock the
   screen. A forged handshake (wrong nonce) counts as a crash.
5. A normal Quit while covering keeps the cover up, without a lock.
6. Nothing covered and the app gone: the keeper exits.
7. A hung keeper while covering: the watchdog locks the screen first, then exits.

### Failure and recovery

| Failure | What protects the screen | How the owner gets back in |
|---|---|---|
| App crash, `kill -9`, Force Quit | keeper cover, plus screen lock | password at the lock screen, then Unlock with the password |
| App hang | both covers stay (frozen app windows still draw) | Unlock in the keeper; Force Quit the app (the keeper keeps covering) |
| Keeper crash | the app's covers; launchd restarts the keeper; the app re-sends *cover* | none needed |
| Keeper hang | the app's covers; the watchdog locks and exits; launchd restarts it | password at the lock screen |
| Both gone | the lock, if the keeper locked first; otherwise **nothing** | — (remaining limit) |
| Normal Quit while covering | the keeper's held cover (the app also locks today) | Unlock with the password |
| Unlock prompt fails | cover stays (fail closed) | log out (⌥⇧⌘Q) or restart; both end the session safely |
| Owner turns the keeper off in Login Items | the app's covers while it runs | — (owner's choice) |
| Log out, restart, shut down | session ends, nothing to show | normal login |

**Orphaned covers.** A cover can only exist while the keeper also shows its Unlock control, or
while its frozen windows are counted down by the watchdog (3 s, then lock and exit). The keeper
exits by itself when nothing is covered and the app is gone, and after an unlock with no app.
Logging out or restarting always clears it. So a held cover is never left without a way out
except the password, which is the point.

**Open before production:**
- The keeper locking the screen needs its own "post events" permission (Accessibility).
  Without it the lock in rules 4 and 7 does nothing; the prototype logs this. The alternative
  is to make the cover the only protection and accept the double-failure limit.
- Re-covering on display changes and sleep/wake needs a physical test.
- XPC with code-signing requirements replaces the socket pair. Test a wrong-signature client.
- A physical check with eyes or a camera: `kill -9` of the real app while covering, Force Quit,
  a keeper kill, normal Quit, and two displays.

### Recommendation and what approval would cover

Use **B**, with the app also keeping today's lock-on-Quit and a fail-closed marker (A's
marker, not its relaunch) for the double-failure case. Approval would mean:
1. Adding the keeper target to the app (a few hundred lines, mostly from this prototype).
2. Registering it as a user LaunchAgent with `SMAppService.agent` from a Privacy Shield setting
   that is off by default. It would be listed in Login Items and removable by the owner.
3. The owner granting it Accessibility, only if it should lock the screen itself.

No step needs root, a privileged helper, a system extension or a SIP change. Until those
physical checks pass, nothing may say "crash-safe".
