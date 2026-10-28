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
| Does authorized remote input reach the intended session? | Only the session on the console has a screen to type into. **Before this change the sender's input gate did not check this.** A receiver still holding control of a switched-out session could keep posting events while someone else used the Mac. Now switching out **ends control**: every session's input grant is revoked (the receiver is told Control is off and resets its own held state), held keys, modifiers, mouse and pointer buttons, pen contact and proximity are released (native magnify/rotate are never injected, as macOS has no API for it; their bookkeeping is reset), a request still waiting on the owner is retired, and no request is granted until the session is back on the console, Always Allow included. The injector also refuses every event while switched out. | `LoginSessionConsole`, `InputInjector.inputIsAllowed`, `SenderController.loginSessionConsoleChanged`, `InputControlRequestRoute`, `MacSender.grantSessionInput`. The releases are posted when macOS reports the switch (`sessionDidResignActive`); whether events posted from a background session reach it is not documented, so checklist rows 4–5 are what confirms nothing stays held. |
| Do role ownership and permission checks stay isolated? | Yes. The display role's ownership lock is per user (by design, `UNIFIED_MAC_APP.md`); trust, approval policy and input grants are per process and keyed by pinned install ids. Nothing is shared between accounts. | Existing `RolePreferences`, `TrustStore`, `ReceiverOwnershipLock`. |
| Can one receiver choose between the sessions reliably? | Yes, as separate senders: each session has its own install id and pins, so it pairs and connects on its own. What was missing was telling them apart: every session advertised the Mac's name, so receivers saw "Family MacBook", "Family MacBook (2)". | mDNS renames duplicate instance names. |
| What happens on lock, sleep, logout and switching? | **Lock:** the session stays on the console; existing lock-screen behaviour is unchanged. **Sleep:** the whole Mac sleeps; every session behaves as today. **Logout:** that session's process quits and its advertisement disappears; the others stay listed. **Switch away:** control ends at once (grants revoked, held input released); an opted-in advertisement turns "switched out"; capture waits. **Switch back:** capture resumes and the advertisement turns available; control must be requested again (Always Allow devices get it on request, as on any new connection). | Session notifications from `NSWorkspace`; TXT `ss`. |
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

A spoofed advertisement on the same network is the residual risk, as it
already is for any nearby Mac name. Receivers group by the digest **and**
the Mac's name together, so copying a Mac's digest under another name only
creates a separate row; it can't rename the heading or join the group. A
perfect copy of both lands under the heading as an **unpaired** row (Pair,
not Connect), and can only become trusted through its own code comparison.
Paired rows are recognized by pinned install id, never by their place in a
group (`SameMacSessionTests.testACopiedDigestUnderAnotherNameIsItsOwnRow`).

## What was implemented

- **Sender, always on:** the input gate requires this login session to be on
  the console; switching out revokes every input grant, releases held input
  and retires pending control requests, and a switched-out session grants
  none (`Mac/LoginSession.swift`, `InputInjector`,
  `SenderController.observeLoginSessionSwitching`, `InputControlRequestRoute`).
- **Sender, opt-in per user:** Settings → System → **Other People on This
  Mac**: a session name and **List My Session Separately**. Off by default,
  so an ordinary install advertises exactly what it did before. When on:
  - the Mac-pairing advertisement is named "Family MacBook — Alex" and carries `hg`, `hn`, `sl`, `ss`;
  - new pairings use the same name, so a receiver's paired list tells the sessions apart (existing pairings keep the name they were made with);
  - switching out republishes `ss`.
- **Receivers** (`Shared/MacSessionDiscovery.swift`, pure and shared):
  - **iPhone/iPad:** the Macs card on Home lists each session as its own row ("Family MacBook — Alex"); a switched-out session shows **Switched Out** instead of Pair/Connect.
  - **Mac receiver:** the row reads "Family MacBook — Alex"; Pair is disabled while that session is switched out.
  - **Android:** uses the same rules (port of `NearbyMacDirectory`).
- **Malformed hints** (bad digest, missing name or label, oversize label, no install id) drop all four fields: that sender is listed as an ordinary Mac. The same install seen twice is one row; duplicate labels get a suffix; same-named Macs with different host names are never merged.

Not done, by design:
- no automatic cross-account launch;
- no privileged helper;
- no capture or input across sessions;
- no change to the fixed Remote Access ports (one session per Mac can use Remote Access; documented above).

## Automated coverage

`MacTests/SameMacSessionTests.swift` (18 tests):
- synthetic sessions: three sessions, one switched out, next to an ordinary Mac;
- duplicate labels, the same sender seen twice, same-named Macs on different hosts;
- seven malformed advertisements and a hint without an install id;
- an unknown state value, and logout of one session;
- opt-in rules: off by default, never the account name, per-user defaults;
- Bonjour length limits, the host digest not containing the name;
- the console state's change reporting, and that this runner reads as on console (no change for Macs without Fast User Switching);
- a switched-out session refuses every control request under every policy, and a request pending at switch-out can't grant afterwards and leaves no cooldown.

The controller wiring (`loginSessionConsoleChanged` calling
`revokeSessionInput`, which is the existing manual-revoke path with its
held-input release and `inputReset`) and the CGEvent releases themselves
are not reachable from the hostless test target; rows 4–5 below cover them.

### Spoofing and disclosure, verified

- **Trust:** grouping, labels and availability are read only by `NearbyMacDirectory`, which produces display rows. Pairing, admission and input read only the pinned install id and TLS key (`TrustStore`, `SenderSessionAuthorization`); none of them read `hg`, `hn`, `sl` or `ss`. A spoofed row is unpaired until its own code comparison succeeds. One reusing a paired install's id gets nothing either: Connect only publishes a token in the receiver's own advertisement, and every connection that follows (the Mac dialing in, the Remote Access knock) is mutual TLS pinned to that install's key (`StreamReceiver.requestConnect`, `requestRemoteConnect`, `TLSConfigurator`).
- **Grouping:** a copied digest under another name is its own row; malformed hints fall back to an ordinary row; whichever advertisement arrives first, the heading is the same (tests above).
- **Disclosure:** a session that hasn't opted in publishes exactly what it did before (no `hg`/`hn`/`sl`/`ss`), so nothing says which accounts exist; an opted-in one publishes only the label its user typed, never the account name. No session reads another account's data.

The pins, pairing and admission code are unchanged and stay covered by the
existing pairing, trust and revocation suites (revoked trust, conflicting
pins).

## Physical checklist (two accounts on one Mac, both with this build)

Use accounts **Alex** (administrator) and **Mom** (standard), Fast User
Switching on, one iPhone or iPad, and preferably a second Mac receiver.

1. **Default unchanged.** Neither account opts in. The iPhone lists the Mac as "Family MacBook" and "Family MacBook (2)", exactly as before this build.
2. **Opt in.** Both accounts set a name and turn on List My Session Separately. The iPhone shows **Family MacBook** with **Alex** and **Mom** under it; the Mac receiver shows "Family MacBook — Alex" and "Family MacBook — Mom".
3. **Pair each.** Pair the iPhone with Alex (code on Alex's screen), switch to Mom, pair with Mom (code on Mom's screen). Two paired Macs with distinct names; forgetting one leaves the other.
4. **Switch out.** With Alex streaming and in control, switch to Mom. Within a second: the iPhone shows Control off; typing on it does nothing anywhere; Alex's row shows **Switched Out**; Mom's screen never receives a keystroke or click (try typing into TextEdit in Mom's session). Asking for control from the iPhone now is refused, even with Always Allow.
5. **Held keys.** In Alex's session hold Shift (latched modifier on the iPhone) and a Command key mid-drag, switch to Mom: Mom's session has no stuck modifier or button (type and click in TextEdit). Switch back: nothing is held in Alex's session either, and control has to be asked for again. Repeat with a pencil drag on an iPad.
6. **Extend leak check.** With Alex extending to an iPad, switch to Mom. Mom's System Settings → Displays must show **no** MeowDisplay display. If it does, record it: Extend would need tearing down on switch-out.
7. **Ports.** Turn on Remote Access in both accounts: only the first holds TCP 9003 (`lsof -i :9003`); the other's knock fails closed. Pair over Remote in the second account reports "Couldn't start Pair over Remote".
8. **Logout.** Log Mom out: Mom's row disappears, Alex's stays.
9. **Standard account.** In Mom's (standard) account, grant Screen Recording and Accessibility; record whether macOS asks for administrator credentials. Check for updates: record whether Sparkle asks for an administrator, and whether Alex's running copy keeps working while the bundle is replaced.
10. **Lock and sleep.** Lock Alex's session (no switch): existing lock-screen behaviour. Sleep the Mac and wake it: each session's devices reconnect to their own session only.
