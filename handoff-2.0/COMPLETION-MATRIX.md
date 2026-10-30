<!-- Sanitized copy of the integration folder's COMPLETION-MATRIX.md (2026-10-31). Local paths and personal names removed; the integration folder holds the original and evidence. -->

# MeowDisplay 2.x requirement status (2026-10-28, completion pass)

> Android parity, USB and Tailscale rows are superseded by RECONCILIATION-2026-10-29.md (read from the code).

COMPLETE = built, tested, and seen working where the hardware exists · PARTIAL = works with a named gap ·
MISSING = not built · BLOCKED = needs hardware/OS we don't have or may not touch · NOT VERIFIED = built and unit-tested, never run end to end.
Evidence paths are relative to this folder. Commits on `feature/android-secure-core`.

| Requirement | Status | Evidence / gap |
| --- | --- | --- |
| Mirror, Extend, Window modes | COMPLETE (Android), NOT VERIFIED (iOS, Mac Receiver on hardware) | W10, W14 on the Moto; iOS by rule not run on devices |
| Per-receiver source independence | COMPLETE (unit + single receiver physical) | one engine per receiver; ReceiverOwnershipTests; two receivers at once not run physically |
| Up to 3 phone tiles | COMPLETE | Moto 3 tiles (W10/28), presets capped at 3 (W14 p1) |
| Up to 9 tablet tiles | PARTIAL | layouts + capacity tested (Swift/Kotlin vectors, tablet emulator); 9 live captures never run (no tablet hardware); budget prefers the active tile |
| Snapping, swapping, dragging, divider resizing | COMPLETE (Android physical), NOT VERIFIED (iOS UI) | W14 p1; fixed 28a1ed4 |
| Independent 0/90/180/270 tile rotation | COMPLETE | Moto clicks exact at 0 and 90 (W10 probe logs) |
| Unified cursor, hovered vs active vs Mac focus | COMPLETE (Android) | active border + pill, Typing paused when Mac focus differs (W10/25) |
| Safe per-window input routing | COMPLETE | raise-on-press, drag bound to its tile, keyboard gate (373ff6e, tests) |
| Physical keyboard/mouse/trackpad | PARTIAL / BLOCKED | code + tests on all; no Bluetooth/OTG peripheral attached to the Moto; iOS devices off-limits |
| Three-finger hold overview | COMPLETE (Android) | W10 |
| Movable collapsible window selector | COMPLETE (Android) | rail edges persisted; handle no longer covers tile pills (28a1ed4) |
| Headless Mac | PARTIAL | Window mode uses any existing display (incl. an Extend virtual display); with none it says to use Extend. No per-tile virtual displays by design. Not run headless (no such Mac) |
| Stage Manager and Spaces | PARTIAL / BLOCKED | covered windows, other-Space and off-screen windows capture (W1); Stage Manager is off here (`GloballyEnabled=0`) and was not toggled; full-screen Space not run (would move the user's screen) |
| Android and iPhone Duo foldable layouts | COMPLETE (Android emulator), NOT VERIFIED (iPhone Duo) | Android emulator hinge (6d23b19); iOS hinge logic unit-tested; Duo simulator check skipped at the user's request |
| Multiple sending Macs in a workspace | PARTIAL | per-Mac layouts and window identity (test W14); a single workspace mixing two Macs' tiles is not built; two-Mac physical BLOCKED |
| Multiple macOS user sessions | PARTIAL | each account is its own sender (SAME_MAC_SESSIONS.md); simultaneous capture of an inactive session is impossible on macOS |
| Unified and standalone Mac Receiver | NOT VERIFIED | builds; two-Mac QA BLOCKED |
| Android/iOS feature parity | PARTIAL | Android lacks the editors, USB and display/stream settings; Demo (213a0a5) and Remote (60bb1e4) are done |
| Connection instructions, terminology, onboarding | COMPLETE | TERMINOLOGY.md, Android Help & About, iOS How to Connect (2640788, 3b826f8) |
| Tailscale discovery, USB transports | PARTIAL | Remote (Tailscale/VPN) on all receivers incl. Android (manual address; no tailnet enumeration by design); USB still Apple-only |
| Security findings and regressions | COMPLETE | F1/F2/F3 + 9 review findings; suites green |
| Picture in Picture (Android) | COMPLETE | 0ae4cd8, Moto |
| Performance overlay (Android) | COMPLETE | a1d7a64, Moto; it found the decoder fallback fixed in 381adce |
| Negative A/V offset (Android) | COMPLETE | 37f43bd, Moto |
| Custom layout editor, Function Tray chord editor (Android) | MISSING | large UI features; iOS has them |
| iOS hardware keyboard/pointer | NOT VERIFIED | code in f6b9904; devices off-limits |
| iOS simulator UI tests | COMPLETE | 9/9 on iPhone 18 Pro sim (3 needed a rerun: timing under load) |
| iPhone/iPad physical QA | COMPLETE (2026-10-31) | iPhone since 2026-10-29; iPad (9th gen, iPadOS 27.0.1) hands-on by the owner on 2000053–2000058, see "iPad QA 2026-10-31" below |
| Two-Mac and physical foldable QA | BLOCKED (hardware) | not run |
| Natural Touch (Direct Touch default) | COMPLETE | Swift+Kotlin engine, fixtures, Window-mode tests, iOS UI 10/10, Moto ADB QA (REPORT: Natural Touch); human-finger feel not verified |
| Stage Peek window switcher (iOS + Android) | COMPLETE | both platforms built and tested; Moto ADB QA and an on-device iPhone XCUITest against a live Mac, View Only (evidence/SP). iPad verified by hand 2026-10-31 (drag from the peek, one Cancel zone, fixed toolbar, Spatial Overview). Not verified: right edge on a device, TalkBack/VoiceOver walkthroughs |
| Switching whole screen ↔ Window view | COMPLETE | Full Desktop card, "Switch to Window view?" prompt (auto-hides 8 s), Settings → Display Mirror/Extend/Windows; Moto sp14–sp18 |
| Terminology pass (34 reviewed fixes) | COMPLETE | ff854da, 3145db9, eb3caac; Request Control family; iPhone demo tests on the device; Moto 360 dp Settings pages, no clipping (evidence/TERM) |
| Minimal home (iPhone + Android) | COMPLETE | 307dfb1, 42f90cc, 89030f3, 36d8c1b, baf0f73; iPhone device shots + Moto incl. 360 dp |
| Android Remote devices | COMPLETE (Request Control granted over remote: awaiting your authorization) | knock + Mac dial-back, Pair over Remote, saved addresses, bounded recovery, honest route labels. Live over LTE + Tailscale: Mirror 44 fps, Window mode + Stage Peek 52 fps / 64 ms, audio flowing, Wi-Fi on/off mid-stream (kept / Mac redial in 1.3 s), Mac restart recovery, Disconnect stops recovery, Request Control declined correctly with input off. Granted control over remote, live Pair over Remote and Needs approval need Mac-side action |
| Typing strip on the keyboard | COMPLETE | iOS accessory bar (d3a7469, 45da72f), iPhone device UI test; Android bar (187681a), Moto on-device preview on the real keyboard (bd480c0). iPad floating keyboard not verified |
| Caret follow (Zoom While Typing) | PARTIAL (unit-tested) | Mac AX caret → `textCaret` message → receivers (d3a7469, 187681a); Swift + Kotlin tests and shared vectors; not run live on a Mac (would type into the user's apps) |
| Mac knock routing over tunnels | COMPLETE | 36a92fb + c104aa8: tunnel knocks dialed back at their source; 215 routing/remote tests + full suite |

## 2026-10-30 — briefs of today (branch `feature/v2-hotspot-parity`, local only, nothing pushed)

Same status words as above. "Unit" = Swift and/or Kotlin tests pass; installed = on the iPhone + iPad (build 2000032 = ca189eb) unless noted. Moto and Mac Dev app are at d379a5a (the Moto wasn't attached for the last install; the Mac sender has no changes since).

| Requirement (brief) | Status | Evidence / gap |
| --- | --- | --- |
| A. Free-canvas panning per pane (any edge or corner to the centre, 0.7x–8x, kept on lift) | PARTIAL | a88a3b5; WorkspaceFreePanTests 6/6 + shared workspace vectors (Swift + Kotlin). Gap: empty canvas isn't yet drawn differently from missing video; no physical check |
| B1. Drag windows and apps from Stage Peek onto panes | PARTIAL (unit) | Windows from the gallery, compact peek and Spatial Overview (75e5266, U3). Apps from the carousel and search results (b5bf4ba): one window goes in, several → chooser, none → offer to open it (control), its first new window lands where dropped; `testAnAppDroppedOnAPanePlacesItsWindowOrAsks`. Gap: Launchpad apps don't drag (the Launchpad covers the panes); no physical check |
| B2. Tab groups in a pane | PARTIAL (unit) | Add, switch (only the shown tab streams), drag out to split, merge, Remove This Tab vs Close Window on Mac existed. ca189eb adds per-tab rotation / Fit-Fill / zoom (saved with the layout, older records still load) and reorder by dragging along its own labels; `testEachTabKeepsItsOwnViewAndTabsReorder`, Kotlin `WorkspaceTabsTest`. Gap: Full Desktop as a tab not checked; no physical check |
| B3. Inline Request Control next to every needs-control action | NOT VERIFIED | 68cc73e (iOS), e53759f (Android), ccddbdf (strip/closed tiles, Remote Finder header); the app-drop dialog also offers it (b5bf4ba) |
| B4. Stage Peek resets temporary filters on every new opening | NOT VERIFIED | 1d10689 (iOS + Android) |
| B5. Browsing or starting a drag never switches Mirror/Extend to Window mode | COMPLETE (unit) | only a completed drop or a window choice requests Window mode; `testStagePeekBrowsingChangesNothing…`, `testAWindowDroppedOnTheDesktopStartsWindowModeBesideIt` |
| Stage Manager capture investigation (public + SkyLight lab) | COMPLETE (research) | RESEARCH-2026-10-30-stage-manager-capture-lab.md, evidence/SM-lab/. No method returns the real window from the strip on macOS 27.0; no private API in the app |
| Turn Off Stage Manager from a device | NOT VERIFIED (awaiting owner) | 8902a1b: runs the owner's two Shortcuts ("MeowDisplay Stage Manager Off/On"), waits for macOS, reports failure; StageManagerSwitchTests 4. Needs the two shortcuts created once |
| Strip window back on stage restarts sooner (2 s) | COMPLETE (unit) | 8902a1b, WindowCaptureHealthTests |
| Privacy Shield (remote on, local off by default; unlock with the login password from the Mac's own keyboard; never in the device's picture) | NOT VERIFIED (awaiting owner OK) | d060f8c, 3324ad5 (security fixes), 9965776; PrivacyShieldPolicyTests 7, Kotlin SessionProtocolTest. Not checked on screen: cover absent from the device's picture, apps not throttled under it, the password prompt visible above it |
| Spatial Overview + Settings ▸ Expanded Layout | PARTIAL (unit) | 5f8bf47 (shared packing, SpatialOverviewTests 5 + Kotlin vectors), d379a5a (iOS + Android views, setting). No physical check |
| Two windows per row in the phone gallery | NOT VERIFIED (device) | 5a5c562 (shared rule + vectors). The live-Mac iPhone UI test now opens Stage Peek by hold-then-pull (lifting after a hold closes it); its 15:25 run skipped because the iPhone didn't reach Window mode on the Mac within 30 s |
| Remote Finder Save / Share on iOS | NOT VERIFIED | 60dd727 |
| iPad smoke test | DONE (2026-10-31) | see "iPad QA 2026-10-31" below |

## 2026-10-30 evening — P0 connect, Privacy Shield flicker, Stage Manager setup, Window UI polish, cleanup, Lock Mac

Branch feature/v2-hotspot-parity (local, not pushed): ff74ca5, 673445b, 0fc5b2d, 103ed8b, b604745, 3a5b3c7.
Installed: Mac Dev app 103ed8b (~/Applications); iPad iOS 2000036; iPhone still 2000033 (installs refused: "usage assertion", phone locked?); Moto not attached.

| Item | Status | Verified | Not verified / blocked |
|---|---|---|---|
| P0 iPhone can't connect | Root cause found: macOS Local Network privacy blocks the Dev app's outgoing dials (nehelper re-caches per binary UUID; stale LaunchServices copies). Fixes: unique UUID (ebb37cf), run from ~/Applications, one LS registration (swap script), product detection + hint to devices (dc36bd2) | Connected and streamed at 15:57–16:08 (AWDL, ~13 ms; Window mode capture 2.0 s, first frame 2.4 s after admission) | Blocked again since 16:16 for each new build: owner must toggle MeowDisplay Dev off/on in System Settings ▸ Local Network. Mirror/Extend live + reconnect re-check after that |
| P0 Privacy Shield flicker | Cause proven from the Mac log: cover windows destroyed when the session set emptied, rebuilt after up to 3 s on the next welcome; exposures 0.1–13 s on reconnects. Fixed (ff74ca5): pooled persistent covers, held until local unlock (fail closed), lock screen before quitting while covering | PrivacyShieldPolicyTests 9/9 | **Security-unverified**: no physical-display observation yet (needs owner OK + disposable desktop); app crash/kill still uncovers (needs an independent cover process) |
| Install the two shortcuts | Files built (is.workflow.actions.stagemanager.set, operation set, state off/on), signed with `shortcuts sign --mode anyone`, opened in Shortcuts 16:46 | Signed (AEA1) | Waiting for the owner's Add Shortcut clicks; then `shortcuts list` check; contents verified only by the owner's import preview (no supported read API) |
| One-click setup in Mac Settings | Done (673445b): Set Up Automatically, only missing ones, polls → Ready, copies flagged, Open in Shortcuts | StageManagerSwitchTests 7/7 | Not clicked through in the app yet (shortcuts pending) |
| Receivers: Add to Current Stage / Turn Off / Setup Required | Done (103ed8b) on iPhone/iPad/Android; Mac uses WindowManager's AXAddToStage on the strip item whose AXWindowsIDs holds the window | StageStripAccessTests; AX read-only inspection shows AXAddToStage + AXWindowsIDs | Physical run on disposable strip windows needs owner OK |
| Lock Mac from phones | Done (ff74ca5): PROTOCOL 6.16, control required, real lock state | Unit tests (Mac, Kotlin); builds | Not run (it locks the owner's Mac) |
| Clean up old ids | Done for Mac Known Devices + iOS Paired Macs (0fc5b2d) | KnownDeviceCleanupTests 2/2 | Android: no pairing dates stored → follow-up |
| Full Desktop default Mirror | Done (ff74ca5): Mac fresh default + Android View Full Screen | Builds | Live check |
| Tab menu clipped | Fixed (b604745): measured, placed in safe area, scrolls; inline Request Control | iOS build | Device screenshot |
| Per-tab Rotate | Code path checked end to end (request rotation → Mac TileContentTransform) | — | Needs a live repro on the phone (blocked by Local Network) |
| Waiting/Reconnecting | Spinner + Reduce Motion on iOS/Android; startupStep timings on the Mac (dc36bd2) | Builds | Receiver first-displayed-frame timing not added yet |
| Stale "Choose a window" | Fixed (3a5b3c7) iOS + Android | Builds | Device check |
| Per-app menu bar following tabs | Not started | — | — |

### Physical checks 17:12–17:40 (owner OK'd; evidence/privacy-shield-2026-10-30/)
- Connection: after the owner's Local Network toggle the iPhone (2000036) connected 17:14:42 (QUIC); Window capture 5.0 s after admission (the 3.2 s gap was the process's first video encoder: 17:14:42.848 → 45.885; see below).
- Privacy Shield, **window-layer coverage check** (not physical-display verification): a WindowServer on-screen window trace (~105 Hz) with a disposable magenta test pattern under the cover found the cover window listed above the pattern with 0 gaps in 100 s across 3 iPhone app relaunches and a disconnect; cover held after the disconnect ("staying covered until unlocked"). Positive control: the trace reported the cover gone right after the owner's password unlock (17:35:07). Only macOS's own lock screen and password prompt were listed above it. What this proves: the window server kept the cover window ordered above everything else at every sample. What it does not prove: what the panel actually showed (a compositor frame between samples, a display reconfiguration, an external display or mirroring path). **Independent physical-display verification is still open**: eyes or a camera on the panel, or a capture device on an external display's cable, during the same transitions. An app crash still uncovers (see DESIGN-2026-10-30-crash-safe-shield.md).
- Shortcuts: both installed (`shortcuts list`); contents not readable without opening the editor.
- Lock Mac: Control-Command-Q post locked the Mac in 0.43 s, read back from the session's lock state.
- Add to Current Stage: NOT working. AXAddToStage on the strip item returned success 4 times (shield up and down, test pattern up and down; 'MeowDisplay RC Test', 'All Shortcuts') but the window never left the strip. The app reports 'failed' honestly. Needs another supported way, or drop the button.

### After 17:40 (local commits 41a3cbe … 28405df, not pushed)

Installed: iPhone and iPad iOS 2000040 (28405df). Mac Dev app still 103ed8b (new Mac code not swapped in: each new build can trip Local Network privacy again). Moto not attached.
Regression: Mac unit tests 2402, 3 failing, all in WorkspaceZoomTests (pan stops at source edges / underzoom centring). These predate today: they contradict the intended free-canvas panning of a88a3b5, and no commit today touches that code. Android core + app unit tests 976/976.

| Item | Done | Verified | Not verified |
|---|---|---|---|
| Add to Current Stage | Hidden in production (41a3cbe): the Mac reports `stageAddAvailable` only when `StageStripAccess.isAvailable`; research kept in RESEARCH-2026-10-30-add-to-stage.md | Builds; receivers hide the button without the flag | A further AXPress experiment needs the owner's OK and disposable windows |
| Show on Mac + Turn Off Stage Manager | Restored next to each other (41a3cbe) | Builds | Device check |
| Per-app menu bar follows the tab | The pane's expected app goes with each menu request; a top-level reply naming another app (the previous tab's) is asked again after 0.4 s, at most 3 times (a6d4523, 32d71a1 iOS/Mac; 5116572 Android) | AppMenuTests 2/2; AppMenuModelTest 3/3 | Tab switch watched on a device |
| Pane menu fits | Natural height, scrolls only when taller than the room (a6d4523) | iPhone screenshot (evidence/rotate/) | — |
| Per-tab Rotate | Reproduced and working on the iPhone: `testRotatesAPaneOnTheLiveMac` rotated the Full Desktop pane 90° and Reset View restored it | Live UI test on the iPhone (evidence/rotate/) | Android device (Moto not attached) |
| Window-mode startup pause | Cause: the first VideoToolbox encoder in a process costs 0.65–1.05 s standalone (3.0 s during the first start); later ones 0–4 ms, and one HEVC session warms H.264. Fix: a 64×64 encoder made and dropped 2 s after launch (fd0212d). Also fixed: a Full Desktop pane was restarted as "stalled" before its stream existed (start time read as 0), costing it ≥1 s every start | WindowCaptureHealthTests 8/8; standalone timing script | Timed on the next Dev-app swap. Remaining per-start cost: the audio carrier stream's `startCapture` 0.8–2.1 s, which panes don't wait for |
| Android old Mac entries | Pins now record when they were paired (same atomic write); Clean Up in the Macs card lists exactly what goes, with dates. No platform guesses among undated pairings: undated ones are older than any dated one; with no dates nothing is offered (8cbab2f, also Shared/KnownDeviceCleanup) | PairedMacCleanupTest 3/3; KnownDeviceCleanupTests 3/3 | On the Moto. Existing Android pins are undated, so Clean Up appears only after a Mac is paired again |
| OLED care for the Privacy Shield | The cover stays black; its message and Unlock button move to a different ninth of the screen every minute, dim after 1 min without local input, go dark after 5; local mouse or keys bring them back at once. On every display (macOS doesn't say which panels are OLED) (ad9be49) | PrivacyShieldPolicyTests 11/11; Mac app builds | On screen: needs a Dev-app swap and the shield turned on (owner OK) |
| Crash-safe shield | Design only: DESIGN-2026-10-30-crash-safe-shield.md | — | Not built; no privileged helper |

### After 18:30 (local commits 0ea6bc7 … b8b84fd, not pushed)

Installed: Mac Dev app = b8b84fd (19:40, ~/Applications; new binary UUID, so Local Network may need the owner's toggle again). iPhone = iOS 2000045 (da6b6ed); iPad = 2000044 (a8d12da; the 2000045 install was refused, iPad probably locked). Moto not attached.
Regression (19:40, b8b84fd): Mac unit tests 2414, 2 skipped, 5 failures, none in the new code: 4 were tests still expecting the old defaults (Natural touch, phones in Direct Touch) and 1 was real: the new iOS screen-awake timer used `systemUptime`, a required-reason API the privacy manifest doesn't declare (PrivacyManifestTests caught it). Both fixed in a8d12da (CACurrentMediaTime, as the rest of the iOS code); the five pass. Android core + app 983/983.

| Item | Done | Verified | Not verified |
|---|---|---|---|
| Privacy Shield crash | Two crashes at cover show (18:38:42, 18:39:03): the notice panel's SwiftUI host sized its own window, its height flipped 33/34 pt and AppKit threw after too many constraint passes. All shield windows now have fixed sizes; covers are plain AppKit with a placed message (a97e13b) | No crash in the supervised run 2; PrivacyShieldPolicyTests | Crash reports kept in evidence/privacy-shield-oled-2026-10-30/ |
| OLED care, supervised run 2 (18:52:09–18:58:11) | — | Cover on both displays; a scripted (non-physical) click on Unlock ignored; dim at +60.0 s; message moved every minute (spots 1–5); non-physical pointer moves at +90/+200/+330 s changed nothing; disconnect held the cover; reconnect in Mirror then Window kept it; dark at +300 s; bright at the owner's touch; unlocked with the password | 13,577 samples, one "gap" from 18:58:04.77 when the built-in display went off (clamshell closed at 18:58:04.136): the tracer used stale display rectangles, so the tracer couldn't check the BenQ during that re-arrangement. Owner (19:50): they closed the lid, and the BenQ "showed whatever the Mac showed". The tracer should re-read displays every sample |
| iOS screen awake | Matches Android: awake only while the Mac's picture is watched in the foreground (Mirror, Extend, Window), 30 s grace on reconnect; auto-lock back on Settings, home, background, failed connection. Settings ▸ General ▸ Keep Screen Awake While Streaming (185fa54) | ScreenAwakePolicyTests | Watched on a device |
| Zoom tests | Updated to the free-canvas spec (0ea6bc7); implementation unchanged | WorkspaceZoomTests pass | — |
| Input defaults | Direct Touch style Classic; phones start in Trackpad, iPads and tablets in Direct Touch; schema 21 applies it once to existing installs (e9bbfb0) | InputDefaultsTests, ControlPreferencesJsonTest | On devices |
| Trackpad cursor per pane | In Trackpad mode the cursor lives in the focused pane: always drawn there (the Mac sends the workspace pointer, not wherever its own cursor is), never slides into a neighbour, starts in the pane's middle the first time and comes back where it was per pane and per tab; kept on the same spot of the window through zoom, pan, turn and resize. Another pane gets it by being focused (its label, a touch) (d846d63) | WindowWorkspaceTargetingTests 27/27; live on the iPhone (19:52–19:56, evidence/twist-cursor-2026-10-30/): cursor drawn at the focused Full Desktop pane's middle; a touch on the Chrome pane focused it and the cursor jumped to that pane's middle; the twist focused Full Desktop again and its cursor was back, turned with the pane | Moving it by finger: this session had no control (Request Control showing), so relative motion wasn't applied. iPad, Moto |
| Free pane rotation | Two fingers turn a pane to any whole degree; the window point under the fingers stays under them; the size follows the spread only; an 8° twist starts it (a pinch's wobble never turns); with Snap Rotation a magnet at right angles (±5°); instant turned preview; the menu's Rotate steps to the next right angle. Wire and saved layouts stay whole numbers (c8923d1 Mac + iOS, b8b84fd Android) | WorkspaceFreeRotationTests 6/6 (Mac), WorkspaceFreeRotationTest 6/6 (Android); Android 983/983; live on the iPhone: a synthesized 50° two-finger twist turned the Full Desktop pane about 42° (8° start threshold), composed sharp by the Mac; Reset View put it back (testTwistTurnsAPaneAndTheTrackpadCursorShowsOnTheLiveMac) | A real hand on the glass (feel, magnet); iPad; Moto |

### After the owner's 20:05 feedback (local commits 86092d3 … 03f1a38, not pushed)

Installed 20:17: Mac Dev app = 03f1a38 (pid 64109). iPhone and iPad = iOS 2000046 (03f1a38). Moto not attached.
Later: iPad = iOS 2000047 (990375b, accessibility). iPhone unavailable at install time, still 2000046.

| Item | Done | Verified | Not verified |
|---|---|---|---|
| Panes "Reconnecting… (try 5)", "The Mac stopped sending … Tap Retry" | Cause from the Mac log: the Mac held its keep-display-awake assertion for only 60 s after a session started. On an idle Mac (here covered by the shield) the display slept at about 19:59, the window server stopped, and every capture (Chrome, Zed, then Full Desktop) delivered zero frames, retried and gave up. They came back at 20:01:00, when the owner touched the Mac. Fix: a display-sleep assertion held while a device watches (admitted, video on, not paused), released on pause, drop and teardown (c9af421). "Closed on Mac" on the Desktop pane was the built-in display going off with the lid | StreamingDisplayAwakeTests 2/2 | A long idle session on the devices |
| Preview skewed while turning or panning | Cause: the instant preview moved the snapshot of the pane's whole box; for a pane already at an odd angle, the box's empty corners (dark) were dragged over the backdrop, giving slanted dark shapes. The snapshot is now masked to the window's own four corners (CAShapeLayer on iOS, clipPath on Android) (86092d3) | WorkspaceFreeRotationTests (outline corners) | On the devices |
| Stage Manager in Settings | The Mac always reports Stage Manager on/off in Window mode; Settings ▸ Input shows it with Turn Off (confirmed; MeowDisplay turns it back on when Window mode ends) or Turn On (a device's Turn On clears that restore), control only; "setup" explains the Mac's one-time setup (03f1a38). Android the same | Mac tests, Android WorkspaceWireTest; iOS builds | On the devices |
| Trackpad in panes | Owner: works | Owner, 20:05 | — |
| Accessibility everywhere | iOS (990375b): Mac screen is one direct-touch element; announcements for connect, reconnect/lost, Request Control and Files; Voice Control names; adjustable pane divider; timed prompts stay under VoiceOver; Reduce Motion fades; headings. Android (45db122): TalkBack labels, roles, states, headings, announcements, 48 dp targets, wrapping text. Store guidance: STORE-ACCESSIBILITY-2026-10-30.md | Full Mac suite 2416/0 failures; iOS builds; Android 984/984 | VoiceOver, Voice Control and TalkBack on a device (owner's checklist in the doc) |

### Night of 2026-10-30 (owner's decisions after 21:00; commits 3c15edd … ef262ea, not pushed)

Installed: Mac Dev = 7f8a0f1 (+ later commits not yet swapped in: 009582f Touch ID, 6f7e313 log line).
iPhone and iPad = iOS 2000048. Moto = debug 7f8a0f1. Levels: **Impl** = code in; **Auto** = automated
tests; **Phys** = seen on real devices; **Release** = ready to ship.

| Item | Impl | Auto | Phys | Release |
|---|---|---|---|---|
| Display awake while watching: one assertion counted across viewers; released with the last viewer, on sender stop, Screen Recording revoked, switched out (3c15edd) | yes | 6 tests incl. a real IOKit assertion | yes: iPhone and Moto together held 1 assertion (21:48–21:51); released at the last viewer every time (21:51:15, 21:59:35, 22:02:18, 22:05:04); also across in-session mode switches | no: battery, Screen Recording revocation and Fast User Switching not tried physically |
| The 19:59 pane stalls | **cause corrected**: not display sleep (a `caffeinate -dis` held it off all along). Stalls followed Stage Manager turning off and a display topology change | — | reproduced in part: a strip window (Chrome) after Home/back goes paused, then "live again", then stalled (status 3) and retries (21:45:22–31) | no: the strip-window retry loop needs a fix |
| Keeping the display powered is unavoidable for capture | evidence: displays slept 18:41:58.215 and SCK stopped 60 ms later (-3815). This Mac locks immediately on display sleep | — | log evidence | — |
| VoiceOver/TalkBack can't click the Mac: picture takes no touches until Direct Touch; activating never clicks (7f8a0f1) | iOS + Android | 5 Mac + 4 Android policy tests | **no**: needs VoiceOver on a device (owner); the Moto has **no TalkBack** (LineageOS, no Google services) | no |
| iOS accessibility audit (XCUITest) | test in ef262ea | ran on the iPhone: home 6 issues (Dynamic Type partial, Mac name clipped); live session 1 (Stage Manager notice clipped) | iPhone only (iPad was locked) | Larger Text / Contrast stay undeclared |
| Long idle, Window mode (Full Desktop + Chrome in the strip) | — | live UI test | **yes**: 10 min with no input, 2 panes, no reconnect banners; Home and back resumed in 129–136 ms | — |
| First frame | — | — | Mirror 0.14 s (Moto), 3.1 s after a mode switch (iPhone); Window first pane frame 62–78 ms warm, 1.5–2.1 s cold; **Extend 37 s (Moto) and 61 s (iPhone)**: about 9–20 s before SCK lists the new virtual display, then 27–41 s inside SCStream start, and other devices' capture starts wait behind it | **no: Extend start is a blocker** |
| Mixed modes at once (physical, iPhone + Moto) | — | — | **yes**: A iPhone Mirror + Moto Extend; B iPhone Window + Moto Mirror; C iPhone Extend + Moto Mirror (Moto's plain Connect kept its last mode). In-session switches Window→Mirror (View Full Screen) and Window→Extend (overview) worked; no trouble banners | Extend latency above |
| Per-pane rotation | earlier commits | earlier tests | the owner's saved tilt and zoom on Full Desktop persisted across sessions; the test's own rotate-and-reset was skipped (it won't touch an already-turned pane) | — |
| Pane menu | — | live test | yes: 8 rows | — |
| App menus | — | live test | not shown: the session had no control | — |
| Stage Manager in Settings | 03f1a38 | — | the Turn Off request was **dropped by the Mac** (no control) while the device showed the button enabled. Stage Manager stayed On. Now logged (6f7e313) | no: the device must show it needs control |
| Touch ID for the shield unlock (owner request, 009582f) | yes, setting on by default when the Mac has Touch ID | 2 policy tests; full suite 2427/0 | **no**: needs the owner at the Mac | no |
| Crash-safe shield (isolated prototype, e3c0297) | prototype only | 9 policy tests; 5 window-layer scenarios (B: 0 gap; A: 315 ms floor) | no panel or camera check | **not installed; asks for approval** (design doc) |
| Same-named Macs: short ID per Mac (owner request 22:05; d25e4f3) | iOS home and Paired Macs, Android home, This Mac's ID in Mac Settings ▸ System | Mac 2 + Android 2 tests, shared vector "1764" | not yet looked at on the devices | Android Paired Macs page and the Mac user's name (needs an authenticated protocol field) still to do |

Installed at 22:2x: Mac Dev = d25e4f3 (pid 32262); iPhone = iOS 2000049 (d25e4f3); iPad still 2000048
(install refused, locked); Moto = debug d25e4f3. Mixed-mode evidence: `evidence/mixed-modes-2026-10-30/`
(timeline.txt, xcresults, Moto screenshots); helpers `tools/moto-mode-session.sh` and `tools/mac-session-summary.sh`.

## Late night 2026-10-30 (after the 22:30 brief)

| Item | Implemented | Automated tests | Physically verified | Release-ready |
|---|---|---|---|---|
| Extend start: shared ScreenCaptureKit request broker (e268f46, ed34d39, 0ea6ebf) + start traces | yes | 11 CoalescingFetchTests; Mac suite 2445/0 | yes: Moto cold 2.4 s / warm 0.7 s, iPhone 1.2 s (no AltTab); 19–21 s with AltTab 10.8 (cause: alt-tab-macos#5861) | after a soak |
| AltTab removed at the owner's request (app, prefs, caches, launch agent, its TCC entries) | done | n/a | dialogs gone (owner cleared; none on screen) | n/a |
| Stage Manager on/off in View Only asks for control in place (iOS Settings + pane, Android Settings) (c39f839) | yes | WorkspaceClientTests gate test | Android Settings in View Only shows Request Control + reason (screenshot); iOS installed 2000050, not yet looked at | after iOS check |
| Strip window pause: one fresh stream per window change, then honest Paused (40222cd) | yes | WindowCaptureHealthTests | not yet (needs the strip case live) | no |
| Paired-only Mac user name + Mac toggle (73580dc, ec6c4f7 bidi-safe) | yes | Mac 3 + Android 3 tests | Moto stored "<owner name>" from the authenticated welcome | after iOS look |
| caffeinate -dis | investigated (read-only) | n/a | started by hand in a Zed terminal tab (ttys005) Oct 28 22:49, runs forever; not MeowDisplay; left running | n/a |

Installed 23:2x: Mac Dev ec6c4f7; iPhone 2000050; Moto ec6c4f7. iPad still 2000048 (locked).
Evidence: evidence/extend-p0-2026-10-30/README.md, evidence/p1-2026-10-30/.
| Camera Mode / Microphone Mode (brief 2026-10-29) | **not built**; owner chose to skip for now (23:4x). Needs a CoreMediaIO camera system extension (app in /Applications, owner approval) and a Core Audio HAL plug-in (admin) | — | — | no |
| Stale rows above: "Per-app menu bar following tabs: Not started" is built (bed6359 iOS, a1d8ea9 Android, 5116572/a6d4523 fixes); "Custom layout editor, Function Tray chord editor (Android): MISSING" is built (35d3022, on this branch) | — | — | — | — |

AltTab dialogs, 23:4x: no AltTab process or file left; the 49 leftover alerts belonged to macOS's
UserNotificationCenter (running since Oct 28, holding AltTab's queued requests). Ended it with
SIGTERM at the owner's request (launchd restarts it on demand); all alert windows gone.

## After midnight 2026-10-31 (final local brief + addendum; commits 058bbe4 … 752f3c3, pushed with the branch)

| Item | Implemented | Automated | Physical | Release-ready |
|---|---|---|---|---|
| Window mode: View Only Request Control pill inside the selected pane (058bbe4 iOS, 2747368 Android) | yes | PaneRequestControlTests 5 (+64 related); Android suite | Moto: pill in pane (earlier run); iPhone not re-checked by hand | yes, pending owner glance on iPhone/iPad |
| Mission Control pauses panes, no restart loop; notice "Mission Control is open on your Mac. Video is paused."; one pane offers Exit Mission Control (control) or inline Request Control (0941f86, 752f3c3) | yes (Mac, iOS/iPadOS, Android) | MissionControlTests 8; Android WorkspaceWireTest; full Android 994/994 | Moto + iPhone, keyboard entry/exit: detect 0.7 s, all panes live again 0.1–0.3 s after close with 0 restarts; 3 rapid cycles clean; two receivers share one detection. Evidence: evidence/mission-control-2026-10-31/ | Exit with control and trackpad-gesture entry not tested by hand (need owner); Privacy Shield covering + Mission Control not tested; iPad not installed (unavailable) |
| Spatial Overview (owner asked) | already built: Shared/SpatialOverview.swift, iOS StagePeekGallery (iPhone + iPad), Android StagePeekOverlay; setting Expanded Layout ▸ Spatial Overview | existing tests | — | yes |

Installed 00:12: Mac Dev 0941f86; iPhone 2000052; Moto 752f3c3. iPad still 2000048 (unavailable).


## iPad QA 2026-10-31 (owner hands-on; commits cdeda71, b94abf6 and the names commit; pushed)

Device: iPad (9th generation, iPad12,1), iPadOS 27.0.1, Developer Mode on. Builds installed in place
(no uninstall; pairing kept: same device ID admitted after each update): 2000053 → 2000058.
Mac Dev = cdeda71 (Smart Touch depth fix). iPhone = 2000058. Moto = b94abf6 debug.

| Check | Result |
|---|---|
| Connect, Window mode, two panes (Finder, Chrome), pane selection | pass |
| Pinch zoom, pan, per-tab rotation, Reset View | pass |
| Spatial Overview / adaptive iPad layout, rotation portrait ↔ landscape | pass |
| View Only Request Control pill in the pane; approval on the Mac; typing and taps reach the Mac | pass |
| Mission Control: notice, panes paused without restarts, recovery; Exit Mission Control with control | pass (Mac log: 6 open/close cycles, 0 restarts) |
| iPad + Moto at the same time | pass (00:45) |
| Mirror and Extend from the home screen | pass |
| Scrolling | FAILED first (two-finger drag moved a zoomed pane; Smart Touch gave up at 12 AX levels in Chrome) → fixed cdeda71 → pass |
| Dragging an app from the peek | FAILED first (offset from the finger; two Drop Here to Cancel zones) → fixed cdeda71 → pass |
| Peek toolbar while the compact peek scrolls | FAILED first (jitter) → fixed b94abf6 (iOS + Android) → reported fixed |
| Share from the long-press menu, toolbar and preview | FAILED first (copies rejected by a /private path check, silent) → fixed b94abf6 → share sheet opens |
| Save to Device | FAILED first (same; then a crash: Photos block isolated to the main actor) → fixed b94abf6 → pass (photos to Photos, other files to Files ▸ MeowDisplay ▸ Downloads, message says where) |
| Expanded view: tap empty space closes it | built b94abf6 (owner asked) |
| Apps bar: widens on scroll, pull down for rows up to all apps with names, handle, swipe up to compact; All Apps closes with a swipe up | built b94abf6 + names commit (iPhone/iPad only; Android not built) |
| Android crash on session end (InterruptedException while closing) | found in the Moto's crash log, fixed b94abf6 with a test |

Not checked on the iPad: VoiceOver walkthrough, Larger Text, the Privacy Shield covering (the
owner's privacyShield.local is off). Automated live XCUITests on the iPad skip without a saved
Window layout (its layout was empty at first).
