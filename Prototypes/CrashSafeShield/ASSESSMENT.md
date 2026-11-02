# Privacy Shield guardian: assessment (2026-10-31)

Status: assessment for the owner's decision. Nothing is installed, registered or shipped. The
prototype in this folder is isolated (not in `project.yml`) and stays that way until the owner
approves the work below.

## 1. The gap

The cover windows belong to the MeowDisplay process. A normal Quit, `kill` or `killall` locks the
Mac's screen first (SIGTERM handler, 2.0). A force quit (SIGKILL), a crash, a debugger detach or an
out-of-memory kill removes the windows at once: the Mac's own screens then show whatever the
remote user left open, and the Mac is logged in and unlocked. No code runs after SIGKILL, so this
can't be closed inside one process. SECURITY.md says so today.

## 2. Threat model

**Protects:** the Mac's screen contents from people physically near the Mac while a paired device
is in a Privacy Shield session, including after MeowDisplay dies unexpectedly.

**In scope:**
- The app crashing, hanging, being force-quit or killed while covering or while the cover is held.
- Someone at the Mac trying to get the cover off without the owner's Touch ID or password.
- A paired device, or a compromised MeowDisplay app, asking the guardian to uncover. It must not
  be able to: the guardian has no uncover message.
- Another local process impersonating the app to the guardian, or the guardian to the app.

**Out of scope (stated, not mitigated):**
- Anyone with the owner's macOS account: same-user processes can stop each other, and the remote
  controller acts as that user. The macOS lock screen is the boundary, not the shield.
- Root, a compromised macOS, physical attacks on the hardware, screen photography after unlock.
- Both the app and the guardian dying at the same moment before the guardian locks (the
  remaining limit; the lock on SIGTERM and the fail-closed marker narrow it).
- The system drawing above every app window (login window, some alerts): macOS guarantees nothing
  above the shielding window level.

## 3. Design (from the prototype, option B)

- `MeowDisplay Shield.app`, a small helper inside the main bundle
  (`Contents/Library/LoginItems`), registered as a **user** LaunchAgent with
  `SMAppService.agent(plistName:)`, `KeepAlive = true`. No root, no daemon, no system extension,
  no SIP change. It idles (no windows, no timers) until the app connects.
- XPC on a Mach service named in the agent plist. Each side requires the other's code signature
  (same team ID and bundle ID, `NSXPCConnection.setCodeSigningRequirement`).
- The app may only say *cover(displays)*, *session ended* and *quitting normally (nonce)*. There
  is no uncover message; unknown or forged messages are logged and ignored.
- While a shielded session runs both cover: the app's windows above, the guardian's own pooled
  windows below, all at the shielding level with `sharingType = .none`, the guardian's window IDs
  reported to the app so every capture leaves them out.
- The guardian watches the app (`DispatchSource.makeProcessSource(.exit)` plus XPC
  invalidation). If the app goes away without the quitting handshake while covering or held, it
  keeps covering and locks the screen.
- Uncovering happens only in the guardian: a click from this Mac's own input (event source PID 0)
  plus Touch ID or the login password, the same rules as the app's shield today.
- The app also keeps a fail-closed marker: at launch, if it was covering when it died, it covers
  and locks before anything else.

The prototype measured, on one display with a window-layer tracer (about 8 ms per sample): no
uncovered interval through an app `kill -9`, an app normal Quit or a guardian `kill -9`; a 315 ms
best-case gap for relaunch-only (option A); a hung guardian plus a dead app left the screen to
the lock after the 3 s watchdog.

## 4. Feasibility on macOS 14–27

| Concern | Finding |
|---|---|
| Minimum OS | The sender targets macOS 14. `SMAppService` (13+) covers every supported version; the app already uses `SMAppService.mainApp` for Start at Login. |
| Registration and approval | `register()` succeeds into `.requiresApproval`; the owner allows it in System Settings ▸ General ▸ Login Items. It is listed there and can be turned off at any time; the setting must respect that without nagging. |
| Launch agent vs login item | A LaunchAgent (`SMAppService.agent`) is required: `KeepAlive` restarts a dead guardian and a Mach service gives authenticated XPC. A plain login item has neither. |
| TCC: covering | Drawing windows at the shielding level needs no permission. |
| TCC: capture exclusion | The guardian's windows must be left out of MeowDisplay's ScreenCaptureKit filters. `sharingType = .none` plus excluding the reported window IDs works across processes; no Screen Recording grant for the guardian. |
| TCC: locking the screen | The app locks via a synthesized key chord, which needs Accessibility. The guardian needs **its own** Accessibility grant to lock by itself. Without it, rule "dead app → lock" degrades to "dead app → keep covering until the owner's password". Open decision for the owner (§7). |
| TCC: Touch ID / password | LocalAuthentication and Authorization Services need no entitlement. |
| Signing | Same team, hardened runtime, notarized inside the main app. Sparkle updates replace the bundle; the agent plist points into it (`BundleProgram`), so an update swaps the guardian too. While the guardian runs during an update, launchd restarts it from the new bundle. |
| Sandbox | The Mac app isn't sandboxed (it needs Accessibility and usbmuxd); the guardian needn't be either. |
| macOS 26–27 | No change found in the `SMAppService` agent or window-level APIs used here; re-verify on each new macOS beta as part of the release checklist. |

## 5. Failure behaviour

| Situation | Behaviour |
|---|---|
| App crash, SIGKILL, Force Quit while covering or held | Guardian's cover stays; it locks (if granted Accessibility). Owner: password at the lock screen, then unlock the cover. |
| App hang | Both covers stay (frozen windows still draw). Unlock in the guardian; Force Quit the app. |
| Guardian crash | The app's covers stay; launchd restarts the guardian; the app re-sends *cover*. |
| Guardian hang while covering | The app's covers stay; its watchdog locks and exits; launchd restarts it. |
| Both gone | Locked if the guardian locked first; otherwise uncovered. Remaining limit. |
| Sleep and wake | Windows survive sleep. On wake the guardian re-covers on `didWakeNotification` and on screen-parameter changes. **Untested physically.** |
| Display attached / detached / mode change | Re-cover on `didChangeScreenParametersNotification`, as the app does. **Untested physically.** |
| Fast user switching / logout | The session ends; nothing to show. The agent stops with the session. |
| Unlock prompt fails | Fail closed: the cover stays. Logging out or restarting always works. |
| Owner disables the guardian in Login Items | The app's own shield works as today; the setting shows the guardian is off. |
| Update while covering | launchd restarts the guardian from the new bundle; the app's cover stays meanwhile. |

## 6. Maintenance cost

- About 600 lines added to the app (most from this prototype), a second target, an agent plist,
  an XPC protocol and its signing requirement, a Settings toggle (off by default) and its status.
- Release work: notarize and sign one more bundle; one more line in the release checklist.
- Ongoing: re-verify the physical checks on each major macOS, and whenever cover or capture code
  changes. Support load: owners who turn it off in Login Items, and the Accessibility grant.
- Risk of regression in the main shield: low if the guardian stays additive (the app's cover is
  unchanged and still the primary one).

## 7. Decisions for the owner

1. **Build it at all for 2.0?** Recommended: yes, as an opt-in setting off by default, or defer
   to 2.1 and keep SECURITY.md's current statement. It closes a real but local-only gap.
2. **Guardian locks the screen itself?** Needs its own Accessibility grant. Recommended: yes,
   requested only when the owner turns the setting on; without it the guardian still covers.
3. **Relaunch the app after a crash (option A's KeepAlive for the app)?** Recommended: no. The
   guardian already covers; relaunching into a locked state surprises people after a deliberate
   Force Quit.

## 8. Security review plan

Before anything ships, in order:
1. Unit tests (exist for the policy core): no uncover path; nonce-checked quit handshake; forged
   or unknown messages ignored; watchdog.
2. XPC tests: a client with the wrong signature is refused by the guardian, and the app refuses
   a guardian with the wrong signature.
3. Code review of the XPC surface and the unlock path by someone other than the author.
4. Physical checks with the owner's OK on a disposable desktop, watched on the panel (eyes or
   camera) and with the window-layer tracer: app `kill -9` while covering; while held after
   disconnect; Force Quit; normal Quit; guardian `kill -9`; guardian hang; two displays; sleep
   and wake while covering; display attach and detach while covering; a Sparkle update while
   covering.
5. Only after all pass may SECURITY.md describe the shield as surviving an app crash, and then
   only for the cases checked.
