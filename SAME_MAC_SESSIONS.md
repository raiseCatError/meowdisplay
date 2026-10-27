# Several people on one Mac (Fast User Switching)

Several people can be logged in to one Mac at once, each running their own
MeowDisplay. This page records what macOS allows, what MeowDisplay does
about it, and what still needs two real logged-in accounts to confirm.

**Status:** implemented as an opt-in for discovery and labelling, plus a
security fix to the sender's input gate. Verified by unit tests and builds
only. Nothing here has run with two logged-in accounts: a single person
running two sessions on one Mac is **not** a test of two Macs, and the
checklist below is the only evidence that counts.

## What macOS allows (investigation)

| Question | Finding | Evidence |
| --- | --- | --- |
| Can several sender processes coexist across users? | Yes. Each login session runs its own MeowDisplay process with its own Keychain (identity, install id, pins), preferences and privacy (TCC) grants. | Per-user Keychain and defaults are how MeowDisplay already stores everything (`TrustStore`, `UserDefaults.standard`). |
| Do their listeners conflict? | The Mac-pairing advertisement (`_opendisplay-mac-pair._tcp`) uses a system-assigned port: no conflict. Media is always dialed out by the sender: no conflict. Two listeners use fixed ports: the Remote Access knock (TCP 9003) and Pair over Remote (TCP 9004). Only one session can hold each; the other session's knock listener keeps retrying and its Pair over Remote reports "Couldn't start". The display role (receiver, 9001/9002) is already one per Mac (`UNIFIED_MAC_APP.md`). | `startPairingListener` (no port), `startRemoteConnectRequestListener` (9003), `openRemotePairing` (9004); a second bind on a fixed port fails with "address in use" (measured for the receiver, `UNIFIED_MAC_APP.md`). |
| Are inactive sessions capturable? | No, by design. A switched-out session has nothing on screen; ScreenCaptureKit stops its stream (reported as `.userStopped`) and the existing recovery path waits, without spending its retry budget, until the session is in front again. MeowDisplay never tries to capture another session. | `MacSender.consoleIsInteractive` / `consoleCanCapture`. Hardware behaviour unverified. |
| Does authorized remote input reach the intended session? | Only the session on the console has a screen to type into. **Before this change the sender's input gate did not check this.** A receiver still holding control of a switched-out session could keep posting events while someone else used the Mac. The injector now refuses all input while its login session is not on the console, and held keys and buttons are released the moment it is switched out. | `LoginSessionConsole`, `InputInjector.inputIsAllowed`, `SenderController.loginSessionConsoleChanged`. Where macOS delivers events posted from a background session is not documented; the gate makes the answer irrelevant. |
| Do role ownership and permission checks stay isolated? | Yes. The display role's ownership lock is per user (by design, `UNIFIED_MAC_APP.md`); trust, approval policy and input grants are per process and keyed by pinned install ids. Nothing is shared between accounts. | Existing `RolePreferences`, `TrustStore`, `ReceiverOwnershipLock`. |
| Can one receiver choose between the sessions reliably? | Yes, as separate senders: each session has its own install id and pins, so it pairs and connects on its own. What was missing was telling them apart: every session advertised the Mac's name, so receivers saw "Family MacBook", "Family MacBook (2)". | mDNS renames duplicate instance names. |
| What happens on lock, sleep, logout and switching? | **Lock:** the session stays on the console; existing lock-screen behaviour is unchanged. **Sleep:** the whole Mac sleeps; every session behaves as today. **Logout:** that session's process quits and its advertisement disappears; the others stay listed. **Switch away:** input stops at once; an opted-in advertisement turns "switched out"; capture waits. **Switch back:** input and capture resume; the advertisement turns available. | Session notifications from `NSWorkspace`; TXT `ss`. |
| Can a standard (non-administrator) account take part? | It can run MeowDisplay and pair; its Keychain and preferences are its own. Granting Screen Recording and Accessibility, and installing Sparkle updates into `/Applications`, may need an administrator's credentials. **Unverified.** | Physical checklist row 9. |

## Identity, kept apart

| Layer | What it is | Used for |
| --- | --- | --- |
| Physical host grouping hint | TXT `hg`: a 16-hex-digit digest of the Mac's local host name (`SenderSessionAdvertisement.hostGroup`). Every session reads the same system-wide name, so they agree without sharing a file or a privileged helper. The host name is already public on the network (mDNS publishes it); the digest adds no hardware identifier. | Arranging the Nearby list only. |
| Login session | TXT `sl` (the label the user typed, never the account name) and `ss` (`a` on the console, `i` switched out). | Labels and availability only. |
| MeowDisplay installation | TXT `id` / `hello.id`: the per-user install id, unchanged. | Which sender a row is. |
| Trust | The pinned TLS key of that install, unchanged. | Pairing, admission, input. |

Every TXT field is unauthenticated. Grouping never grants trust, never
bypasses pairing and never merges two sessions' pins or settings. A row
that says "Alex" is a sender that *claims* the label "Alex"; pairing still
shows the code on that session's screen, and only that session's user can
confirm it.

## What was implemented

- **Sender, always on:** the input gate requires this login session to be on
  the console; switching out releases held input (`Mac/LoginSession.swift`,
  `InputInjector`, `SenderController.observeLoginSessionSwitching`).
- **Sender, opt-in per user:** Settings → System → **Other People on This
  Mac**: a session name and **List My Session Separately**. Off by default,
  so an ordinary install advertises exactly what it did before. When on:
  - the Mac-pairing advertisement is named "Family MacBook — Alex" and carries `hg`, `hn`, `sl`, `ss`;
  - new pairings use the same name, so a receiver's paired list tells the sessions apart (existing pairings keep the name they were made with);
  - switching out republishes `ss`.
- **Receivers** (`Shared/MacSessionDiscovery.swift`, pure and shared):
  - **iPhone/iPad:** Nearby Devices lists one Mac with its sessions under it; a switched-out session shows **Switched Out** instead of Pair/Connect.
  - **Mac receiver:** the row reads "Family MacBook — Alex"; Pair is disabled while that session is switched out.
  - **Android:** uses the same rules (port of `NearbyMacDirectory`).
- **Malformed hints** (bad digest, missing name or label, oversize label, no install id) drop all four fields: that sender is listed as an ordinary Mac. The same install seen twice is one row; duplicate labels get a suffix; same-named Macs with different host names are never merged.

Not done, by design:
- no automatic cross-account launch;
- no privileged helper;
- no capture or input across sessions;
- no change to the fixed Remote Access ports (one session per Mac can use Remote Access; documented above).

## Automated coverage

`MacTests/SameMacSessionTests.swift` (15 tests):
- synthetic sessions: three sessions, one switched out, next to an ordinary Mac;
- duplicate labels, the same sender seen twice, same-named Macs on different hosts;
- seven malformed advertisements and a hint without an install id;
- an unknown state value, and logout of one session;
- opt-in rules: off by default, never the account name, per-user defaults;
- Bonjour length limits, the host digest not containing the name;
- the console state's change reporting, and that this runner reads as on console (no change for Macs without Fast User Switching).

The pins, pairing and admission code are unchanged and stay covered by the
existing pairing, trust and revocation suites (revoked trust, conflicting
pins).

## Physical checklist (two accounts on one Mac, both with this build)

Use accounts **Alex** (administrator) and **Mom** (standard), Fast User
Switching on, one iPhone or iPad, and preferably a second Mac receiver.

1. **Default unchanged.** Neither account opts in. The iPhone lists the Mac as "Family MacBook" and "Family MacBook (2)", exactly as before this build.
2. **Opt in.** Both accounts set a name and turn on List My Session Separately. The iPhone shows **Family MacBook** with **Alex** and **Mom** under it; the Mac receiver shows "Family MacBook — Alex" and "Family MacBook — Mom".
3. **Pair each.** Pair the iPhone with Alex (code on Alex's screen), switch to Mom, pair with Mom (code on Mom's screen). Two paired Macs with distinct names; forgetting one leaves the other.
4. **Switch out.** With Alex streaming and in control, switch to Mom. Within a second: typing on the iPhone does nothing anywhere; Alex's row shows **Switched Out**; Mom's screen never receives a keystroke or click (try typing into TextEdit in Mom's session).
5. **Held keys.** In Alex's session hold Shift (latched modifier on the iPhone) mid-drag, switch to Mom, switch back: nothing is still held in Alex's session.
6. **Extend leak check.** With Alex extending to an iPad, switch to Mom. Mom's System Settings → Displays must show **no** MeowDisplay display. If it does, record it: Extend would need tearing down on switch-out.
7. **Ports.** Turn on Remote Access in both accounts: only the first holds TCP 9003 (`lsof -i :9003`); the other's knock fails closed. Pair over Remote in the second account reports "Couldn't start Pair over Remote".
8. **Logout.** Log Mom out: Mom's row disappears, Alex's stays.
9. **Standard account.** In Mom's (standard) account, grant Screen Recording and Accessibility; record whether macOS asks for administrator credentials. Check for updates: record whether Sparkle asks for an administrator, and whether Alex's running copy keeps working while the bundle is replaced.
10. **Lock and sleep.** Lock Alex's session (no switch): existing lock-screen behaviour. Sleep the Mac and wake it: each session's devices reconnect to their own session only.
