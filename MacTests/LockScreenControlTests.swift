import XCTest

/// Lock screen control (SECURITY.md "Lock screen control"): who may show and operate macOS's own
/// lock screen, which input reaches it, which frames leave, the per-device switch and the wire.
/// The sender's own enforcement, end to end, is in `MacSenderInputRevocationTests`.
final class LockScreenControlTests: XCTestCase {
    private func inputs(policy: PeerInputRequestPolicy = .alwaysAllow, granted: Bool = true,
                        privacy: MacScreenPrivacy = .locked, allowed: Bool = true,
                        windowView: Bool = false, extend: Bool = false, handoff: Bool = false) -> LockScreenEligibility.Inputs {
        LockScreenEligibility.Inputs(admitted: true, masterInput: true, onConsole: true, privacy: privacy,
                                     policy: policy, lockScreenControlAllowed: allowed,
                                     sessionGranted: granted, windowView: windowView, extend: extend,
                                     handoffPending: handoff)
    }

    // MARK: Who

    func testOnlyADeviceAlreadyTrustedWithInputQualifies() {
        XCTAssertNil(LockScreenEligibility.denial(inputs()), "Always Allow with this connection's grant")
        XCTAssertNil(LockScreenEligibility.denial(inputs(policy: .ask)), "Ask with control granted before the lock")
        XCTAssertEqual(LockScreenEligibility.denial(inputs(granted: false)), .needsControl)
        XCTAssertEqual(LockScreenEligibility.denial(inputs(policy: .ask, granted: false)), .controlBeforeLock,
                       "a view-only Ask device never gets control while locked")
        XCTAssertEqual(LockScreenEligibility.denial(inputs(policy: .neverAllow)), .neverAllow,
                       "Never Allow, even with a grant from before the policy changed")
        XCTAssertEqual(LockScreenEligibility.denial(inputs(allowed: false)), .turnedOff)
    }

    func testTheMacsOwnSwitchesComeFirst() {
        var i = inputs()
        i.admitted = false
        XCTAssertEqual(LockScreenEligibility.denial(i), .notAdmitted)
        i = inputs(); i.masterInput = false
        XCTAssertEqual(LockScreenEligibility.denial(i), .inputOff)
        i = inputs(); i.onConsole = false
        XCTAssertEqual(LockScreenEligibility.denial(i), .otherUser)
        XCTAssertEqual(LockScreenEligibility.denial(inputs(privacy: .switchedOut)), .otherUser, "Fast User Switching")
        for p in [MacScreenPrivacy.unlocked, .unknown] {
            XCTAssertEqual(LockScreenEligibility.denial(inputs(privacy: p)), .notLocked, "\(p)")
        }
    }

    func testWhatADeviceIsOffered() {
        XCTAssertEqual(LockScreenEligibility.offer(inputs(), active: false), .available)
        XCTAssertEqual(LockScreenEligibility.offer(inputs(), active: true), .active)
        XCTAssertEqual(LockScreenEligibility.offer(inputs(granted: false), active: false), .needsControl)
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .ask, granted: false), active: false), .unavailable("controlBeforeLock"))
        XCTAssertEqual(LockScreenEligibility.offer(inputs(allowed: false), active: false), .unavailable("turnedOff"))
        // Window view: Full Desktop is a new connection. Always Allow gets control back without a
        // prompt; an Ask device's grant doesn't carry over, so it isn't offered.
        XCTAssertEqual(LockScreenEligibility.offer(inputs(windowView: true), active: false), .needsFullDesktop)
        XCTAssertEqual(LockScreenEligibility.offer(inputs(granted: false, windowView: true), active: false), .needsFullDesktop)
        // Ask with control a person granted before the lock: Mirror first, the grant carried once.
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .ask, windowView: true), active: false), .needsFullDesktop)
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .ask, granted: false, windowView: true), active: false),
                       .unavailable("controlBeforeLock"), "no pre-lock grant: nothing to carry")
        XCTAssertEqual(LockScreenEligibility.offer(inputs(allowed: false, windowView: true), active: false), .unavailable("turnedOff"))
        XCTAssertEqual(LockScreenEligibility.denial(inputs(windowView: true)), .windowView, "never shown in Window view")
    }

    /// Extend's display shows wallpaper, never the login window (on the main display): never
    /// `available` there. Like Window view: Always Allow switches to Mirror first, an Ask device
    /// isn't offered it (its grant doesn't carry to the new connection). No consent changes.
    func testExtendIsNeverOfferedDirectlyOnlyViaMirror() {
        XCTAssertEqual(LockScreenEligibility.denial(inputs(extend: true)), .windowView, "never shown in Extend")
        XCTAssertEqual(LockScreenEligibility.offer(inputs(extend: true), active: false), .needsFullDesktop)
        XCTAssertEqual(LockScreenEligibility.offer(inputs(granted: false, extend: true), active: false), .needsFullDesktop)
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .ask, extend: true), active: false), .needsFullDesktop)
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .ask, granted: false, extend: true), active: false), .unavailable("controlBeforeLock"))
        XCTAssertEqual(LockScreenEligibility.offer(inputs(allowed: false, extend: true), active: false), .unavailable("turnedOff"))
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .neverAllow, extend: true), active: false), .unavailable("neverAllow"))
        XCTAssertEqual(LockScreenEligibility.offer(inputs(), active: false), .available, "Mirror: offered as before")
    }

    // MARK: The pointer

    /// Position and sprite: unlocked as always; locked only while this connection shows the lock
    /// screen and macOS says locked (the same rule as its frames). Never for another user or unknown.
    func testTheCursorGoesOutOnlyWithTheLockScreenView() {
        XCTAssertTrue(LockScreenCursorPolicy.allows(privacy: .unlocked, lockScreenActive: false))
        XCTAssertTrue(LockScreenCursorPolicy.allows(privacy: .unlocked, lockScreenActive: true))
        XCTAssertTrue(LockScreenCursorPolicy.allows(privacy: .locked, lockScreenActive: true))
        XCTAssertFalse(LockScreenCursorPolicy.allows(privacy: .locked, lockScreenActive: false), "locked, not shown here")
        for p in [MacScreenPrivacy.switchedOut, .unknown] {
            XCTAssertFalse(LockScreenCursorPolicy.allows(privacy: p, lockScreenActive: true), "\(p)")
            XCTAssertFalse(LockScreenCursorPolicy.allows(privacy: p, lockScreenActive: false), "\(p)")
        }
    }

    // MARK: Which input

    func testOnlyWhatTheLoginWindowNeeds() {
        let allowed: [LockScreenInputEvent] = [
            .touch, .pointerMove, .pointerButton(.left), .release,
            .key(.keyA, modifiers: []), .key(.keyZ, modifiers: ["shift"]), .key(.digit5, modifiers: ["option"]),
            .key(.returnOrEnter, modifiers: []), .key(.deleteOrBackspace, modifiers: []),
            .key(.spacebar, modifiers: ["capsLock"]), .key(.spacebar, modifiers: []),
            .key(.period, modifiers: []), .key(.keypad7, modifiers: []), .key(.nonUSBackslash, modifiers: ["option"]),
            .modifier("shift"), .modifier("option"),
            .text("fake-pass-123"), .text("f@ke wörd!"),
        ]
        for e in allowed { XCTAssertTrue(LockScreenInputFilter.allows(e), "\(e)") }
        let refused: [LockScreenInputEvent] = [
            .other, .pointerButton(.right),
            .key(.keyQ, modifiers: ["command"]), .key(.keyA, modifiers: ["control"]), .key(.tab, modifiers: ["command"]),
            .key(.keyA, modifiers: ["fn"]), .key(.f1, modifiers: []), .key(.home, modifiers: []), .key(.lang1, modifiers: []),
            .key(.keypadNumLockOrClear, modifiers: []),
            .modifier("command"), .modifier("control"), .modifier("fn"),
            .text(""), .text("a\nb"), .text("a\rb"), .text("\u{7f}"), .text("\u{1b}"),
            .text(String(repeating: "a", count: LockScreenInputFilter.maxTextLength + 1)),
        ]
        for e in refused { XCTAssertFalse(LockScreenInputFilter.allows(e), "\(e)") }
    }

    /// F6: Tab, the arrows, Escape and Forward Delete only move focus to the login window's other
    /// controls (Switch User, power, accessibility): never on the lock screen, with any modifier.
    func testFocusAndNavigationKeysAreRefused() {
        let removed: [HIDKeyUsage] = [.tab, .escape, .forwardDelete, .leftArrow, .rightArrow, .upArrow, .downArrow]
        for usage in removed {
            XCTAssertFalse(LockScreenInputFilter.allowedKeys.contains(usage), "\(usage)")
            for modifiers in [[], ["shift"], ["option"], ["capsLock"]] as [[String]] {
                XCTAssertFalse(LockScreenInputFilter.allows(.key(usage, modifiers: modifiers)), "\(usage) \(modifiers)")
            }
        }
        // What a password needs stays.
        for usage in [HIDKeyUsage.keyF, .digit1, .spacebar, .returnOrEnter, .deleteOrBackspace, .minus] {
            XCTAssertTrue(LockScreenInputFilter.allows(.key(usage, modifiers: [])), "\(usage)")
        }
        XCTAssertTrue(LockScreenInputFilter.allows(.pointerButton(.left)))
        XCTAssertFalse(LockScreenInputFilter.allows(.pointerButton(.right)))
    }

    // MARK: Rate and timing

    /// F7: show:true starts a view at most once per 5 s per connection.
    func testShowIsRateLimitedPerConnection() {
        var limit = LockScreenShowRateLimit()
        XCTAssertTrue(limit.admits(now: 100))
        for i in 1..<20 { XCTAssertFalse(limit.admits(now: 100 + Double(i) * 0.05), "\(i)") }
        XCTAssertFalse(limit.admits(now: 104.9))
        XCTAssertTrue(limit.admits(now: 105))
        XCTAssertFalse(limit.admits(now: 106))
        limit.reset()
        XCTAssertTrue(limit.admits(now: 106), "a new connection")
    }

    // MARK: Tagged lock screen typing

    func testTaggedTypingGoesOnlyToALiveViewAndEveryRefusalIsReported() {
        typealias T = LockScreenTaggedInput
        let view7 = LockScreenInputTag(view: 7)
        XCTAssertNil(T.refusal(action: "press", tag: view7, liveView: 7, unlocked: false))
        XCTAssertEqual(T.refusal(action: "press", tag: view7, liveView: nil, unlocked: true), .unlocked, "unlock race")
        XCTAssertEqual(T.refusal(action: "text", tag: view7, liveView: nil, unlocked: false), .notShown, "forged or late tag")
        XCTAssertEqual(T.refusal(action: "press", tag: view7, liveView: 8, unlocked: false), .notShown, "an earlier view's")
        XCTAssertEqual(T.refusal(action: "press", tag: LockScreenInputTag(view: nil), liveView: 7, unlocked: false), .notShown,
                       "typed while locked without the view")
        XCTAssertEqual(T.refusal(action: "down", tag: nil, liveView: 7, unlocked: false), .untagged)
        XCTAssertNil(T.refusal(action: "press", tag: nil, liveView: nil, unlocked: true), "ordinary input after unlock")
        XCTAssertNil(T.refusal(action: "press", tag: nil, liveView: nil, unlocked: false),
                     "locked without the view: the privacy gate drops it as before")
        for release in ["up", "modifierUp", "cancel"] {
            for (tag, live, unlocked) in [(view7, nil, true), (nil, 7, false), (view7, nil, false), (view7, 8, false)] as [(LockScreenInputTag?, Int?, Bool)] {
                XCTAssertNil(T.refusal(action: release, tag: tag, liveView: live, unlocked: unlocked), "releases always go")
            }
        }
        XCTAssertEqual(T.keystrokes(action: "press", text: nil), 1)
        XCTAssertEqual(T.keystrokes(action: "down", text: nil), 1)
        XCTAssertEqual(T.keystrokes(action: "text", text: "fake-pass-123"), 13)
        XCTAssertEqual(T.keystrokes(action: "modifierDown", text: nil), 0)
    }

    func testPressesFollowTheTagRuleMovesDropQuietlyReleasesAlwaysGo() {
        typealias T = LockScreenTaggedInput
        XCTAssertEqual(T.pointerKind(type: "touch", phaseOrAction: "began"), .press)
        XCTAssertEqual(T.pointerKind(type: "pointer", phaseOrAction: "down"), .press)
        XCTAssertEqual(T.pointerKind(type: "touch", phaseOrAction: "moved"), .move)
        XCTAssertEqual(T.pointerKind(type: "pointer", phaseOrAction: "move"), .move)
        XCTAssertEqual(T.pointerKind(type: "pointer", phaseOrAction: "moveRelative"), .move)
        for (type, value) in [("touch", "ended"), ("touch", "cancelled"), ("pointer", "up")] {
            XCTAssertEqual(T.pointerKind(type: type, phaseOrAction: value), .release)
        }
        XCTAssertEqual(T.pointerKind(type: "pointer", phaseOrAction: "teleport"), .other)
        let view7 = LockScreenInputTag(view: 7)
        // Presses.
        XCTAssertEqual(T.pointerDecision(.press, tag: view7, liveView: 7, unlocked: false), .deliver)
        XCTAssertEqual(T.pointerDecision(.press, tag: view7, liveView: nil, unlocked: true), .refuse(.unlocked))
        XCTAssertEqual(T.pointerDecision(.press, tag: view7, liveView: nil, unlocked: false), .refuse(.notShown))
        XCTAssertEqual(T.pointerDecision(.press, tag: view7, liveView: 8, unlocked: false), .refuse(.notShown))
        XCTAssertEqual(T.pointerDecision(.press, tag: nil, liveView: 7, unlocked: false), .refuse(.untagged))
        XCTAssertEqual(T.pointerDecision(.press, tag: nil, liveView: nil, unlocked: true), .deliver)
        // Moves (and an unknown action): quietly dropped when not for a live view.
        XCTAssertEqual(T.pointerDecision(.move, tag: view7, liveView: 7, unlocked: false), .deliver)
        XCTAssertEqual(T.pointerDecision(.move, tag: view7, liveView: nil, unlocked: true), .drop)
        XCTAssertEqual(T.pointerDecision(.move, tag: view7, liveView: 8, unlocked: false), .drop)
        XCTAssertEqual(T.pointerDecision(.move, tag: nil, liveView: 7, unlocked: false), .drop)
        XCTAssertEqual(T.pointerDecision(.move, tag: nil, liveView: nil, unlocked: true), .deliver)
        XCTAssertEqual(T.pointerDecision(.other, tag: view7, liveView: nil, unlocked: true), .drop)
        // Releases, always.
        for (tag, live, unlocked) in [(view7, nil, true), (nil, 7, false), (view7, nil, false), (nil, nil, true)] as [(LockScreenInputTag?, Int?, Bool)] {
            XCTAssertEqual(T.pointerDecision(.release, tag: tag, liveView: live, unlocked: unlocked), .deliver)
        }
    }

    func testTheRefusalNoticeIsPlainAndCounts() {
        let one = LockScreenInputRefusal(message: LockScreenWire.inputRefused(count: 1, reason: "unlocked"))
        XCTAssertEqual(one?.notice, "1 keystroke wasn’t sent: the Mac unlocked.")
        let two = one.map { $0.adding(LockScreenInputRefusal(count: 1, reason: "unlocked")) }
        XCTAssertEqual(two?.notice, "2 keystrokes weren’t sent: the Mac unlocked.")
        XCTAssertEqual(LockScreenInputRefusal(count: 3, reason: "untagged").notice,
                       "3 keystrokes weren’t sent: use the lock screen’s keyboard and touches.")
        XCTAssertEqual(LockScreenInputRefusal(count: 0, clicks: 1, reason: "unlocked").notice,
                       "1 click wasn’t sent: the Mac unlocked.")
        XCTAssertEqual(LockScreenInputRefusal(count: 2, clicks: 1, reason: "unlocked").notice,
                       "2 keystrokes and 1 click weren’t sent: the Mac unlocked.")
        XCTAssertEqual(LockScreenInputRefusal(count: 0, clicks: 1, reason: "unlocked")
                        .adding(LockScreenInputRefusal(count: 1, reason: "unlocked")).notice,
                       "1 keystroke and 1 click weren’t sent: the Mac unlocked.")
        let clicks = LockScreenInputRefusal(message: LockScreenWire.inputRefused(count: 0, clicks: 2, reason: "notShown"))
        XCTAssertEqual(clicks?.clicks, 2)
        XCTAssertEqual(clicks?.notice, "2 clicks weren’t sent: the lock screen isn’t shown.")
        XCTAssertNil(LockScreenInputRefusal(message: ["type": LockScreenWire.inputRefused, "count": 0, "clicks": 0, "reason": "unlocked"]))
        XCTAssertNil(LockScreenInputRefusal(message: ["type": LockScreenWire.inputRefused, "count": -1, "clicks": 2, "reason": "unlocked"]))
        XCTAssertEqual(LockScreenInputRefusal(count: 2, reason: "notShown").notice,
                       "2 keystrokes weren’t sent: the lock screen isn’t shown.")
        XCTAssertNil(LockScreenInputRefusal(message: ["type": LockScreenWire.inputRefused, "count": 0, "reason": "unlocked"]))
        XCTAssertNil(LockScreenInputRefusal(message: ["type": LockScreenWire.inputRefused, "reason": "unlocked"]))
    }

    // MARK: An Ask device's pre-lock control across the switch to Mirror

    private func check(peer: String = "ask-peer", key: Data? = Data([1, 2, 3]), episode: UInt64 = 7,
                       privacy: MacScreenPrivacy = .locked, onConsole: Bool = true, now: TimeInterval = 100) -> LockScreenGrantHandoffs.Check {
        LockScreenGrantHandoffs.Check(peerID: peer, pinnedKey: key, lockEpisode: episode, privacy: privacy, onConsole: onConsole, now: now)
    }

    func testAHandoffIsIssuedOnlyFromALivePreLockGrantOfAnAskDevice() {
        var h = LockScreenGrantHandoffs()
        XCTAssertFalse(h.issue(check(), policy: .ask, lockScreenControlAllowed: true, sessionGranted: false), "no grant: nothing to carry")
        XCTAssertFalse(h.issue(check(), policy: .alwaysAllow, lockScreenControlAllowed: true, sessionGranted: true), "Always Allow needs none")
        XCTAssertFalse(h.issue(check(), policy: .neverAllow, lockScreenControlAllowed: true, sessionGranted: true))
        XCTAssertFalse(h.issue(check(), policy: .ask, lockScreenControlAllowed: false, sessionGranted: true), "switch off")
        XCTAssertFalse(h.issue(check(privacy: .unlocked), policy: .ask, lockScreenControlAllowed: true, sessionGranted: true))
        XCTAssertFalse(h.issue(check(privacy: .switchedOut), policy: .ask, lockScreenControlAllowed: true, sessionGranted: true))
        XCTAssertFalse(h.issue(check(onConsole: false), policy: .ask, lockScreenControlAllowed: true, sessionGranted: true))
        XCTAssertFalse(h.issue(check(key: nil), policy: .ask, lockScreenControlAllowed: true, sessionGranted: true), "unpaired")
        XCTAssertTrue(h.tickets.isEmpty)
        XCTAssertTrue(h.issue(check(), policy: .ask, lockScreenControlAllowed: true, sessionGranted: true))
        XCTAssertTrue(h.isValid(check(now: 105)))
    }

    func testAHandoffIsSingleUseBoundAndShortLived() {
        func issued() -> LockScreenGrantHandoffs {
            var h = LockScreenGrantHandoffs()
            h.issue(check(), policy: .ask, lockScreenControlAllowed: true, sessionGranted: true)
            return h
        }
        var h = issued()
        XCTAssertTrue(h.redeem(check(now: 103)))
        XCTAssertFalse(h.redeem(check(now: 104)), "single use")
        // Every binding: expired, another key (re-paired), another lock episode (unlocked or
        // relocked in between), unlocked now, switched out, another device, a clock running back.
        let wrong: [(String, LockScreenGrantHandoffs.Check)] = [
            ("expired", check(now: 100 + LockScreenGrantHandoffs.lifetime + 0.01)),
            ("key", check(key: Data([9]))),
            ("no key", check(key: nil)),
            ("episode", check(episode: 8)),
            ("unlocked", check(privacy: .unlocked)),
            ("unknown", check(privacy: .unknown)),
            ("console", check(onConsole: false)),
            ("clock", check(now: 99)),
        ]
        for (name, c) in wrong {
            var h = issued()
            XCTAssertFalse(h.redeem(c), name)
            XCTAssertFalse(h.redeem(check(now: 101)), "\(name): a failed attempt spends it too")
        }
        var other = issued()
        XCTAssertFalse(other.redeem(check(peer: "someone-else")))
        XCTAssertTrue(other.redeem(check(now: 100 + LockScreenGrantHandoffs.lifetime)), "inside its lifetime")
        var revoked = issued()
        revoked.revoke(peerID: "ask-peer")
        XCTAssertFalse(revoked.redeem(check()))
        // Issuing again without a grant clears an older ticket.
        var replaced = issued()
        replaced.issue(check(), policy: .ask, lockScreenControlAllowed: true, sessionGranted: false)
        XCTAssertFalse(replaced.redeem(check()))
    }

    func testOnlyAValidHandoffGrantsAnAskRequestWhileLocked() {
        XCTAssertEqual(InputControlRequestRoute.route(masterEnabled: true, onConsole: true, screenLocked: true, policy: .ask),
                       .deny(.notAllowed), "never a prompt or a grant behind the lock")
        XCTAssertEqual(InputControlRequestRoute.route(masterEnabled: true, onConsole: true, screenLocked: true,
                                                      lockScreenHandoff: true, policy: .ask), .grant)
        XCTAssertEqual(InputControlRequestRoute.route(masterEnabled: true, onConsole: true, screenLocked: true,
                                                      lockScreenHandoff: true, policy: .neverAllow), .deny(.requestsDisabled))
        XCTAssertEqual(InputControlRequestRoute.route(masterEnabled: false, onConsole: true, screenLocked: true,
                                                      lockScreenHandoff: true, policy: .ask), .deny(.notAllowed))
        XCTAssertEqual(InputControlRequestRoute.route(masterEnabled: true, onConsole: false, screenLocked: true,
                                                      lockScreenHandoff: true, policy: .ask), .deny(.notAllowed))
        XCTAssertEqual(InputControlRequestRoute.route(masterEnabled: true, onConsole: true, screenLocked: false,
                                                      lockScreenHandoff: true, policy: .ask), .ask, "unlocked: the person decides")
        // The new connection is told `needsControl` only while the ticket is valid.
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .ask, granted: false, handoff: true), active: false), .needsControl)
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .ask, granted: false), active: false), .unavailable("controlBeforeLock"))
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .neverAllow, granted: false, handoff: true), active: false), .unavailable("neverAllow"))
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .ask, granted: false, allowed: false, handoff: true), active: false),
                       .unavailable("turnedOff"))
    }

    func testEveryNewLockIsANewEpisode() {
        let gate = MacPrivacyGate(.unlocked)
        let e0 = gate.lockEpisode
        gate.set(.locked)
        let e1 = gate.lockEpisode
        XCTAssertNotEqual(e0, e1)
        gate.set(.locked)
        XCTAssertEqual(gate.lockEpisode, e1, "no change, same episode")
        gate.set(.switchedOut)
        XCTAssertNotEqual(gate.lockEpisode, e1, "another user in between")
        let e2 = gate.lockEpisode
        gate.set(.unlocked)
        gate.set(.locked)
        XCTAssertNotEqual(gate.lockEpisode, e2, "relocked")
    }

    // MARK: The receiver's keyboard (F1)

    /// The lock screen's own responder: no document context (so no predictions, AutoFill or text
    /// replacement), secure entry, no content type, nothing corrected, capitalised or echoed.
    func testTheLockScreenKeyboardHasNoDocumentNoAutoFillAndNoEcho() {
        let t = LockScreenKeyInputTraits.lockScreen
        XCTAssertFalse(t.documentContext, "UIKeyInput only, never UITextInput")
        XCTAssertTrue(t.secureTextEntry)
        XCTAssertNil(t.contentType, "no content type: nothing for AutoFill to match")
        XCTAssertFalse(t.autocorrection)
        XCTAssertFalse(t.spellChecking)
        XCTAssertFalse(t.autocapitalization)
        XCTAssertFalse(t.smartPunctuation)
        XCTAssertFalse(t.echoesTypedText)
    }

    func testTheLockScreenKeyboardSendsTextReturnAndDeleteOnly() {
        typealias P = LockScreenKeyInputPlan
        XCTAssertEqual(P.plan(insertText: "fake-pass-123"), [.text("fake-pass-123")])
        XCTAssertEqual(P.plan(insertText: "\n"), [.returnKey])
        XCTAssertEqual(P.plan(insertText: "ab\ncd"), [.text("ab"), .returnKey, .text("cd")])
        XCTAssertEqual(P.plan(insertText: "\r\n"), [.returnKey])
        XCTAssertEqual(P.plan(insertText: "\t"), [], "Tab moves focus on the login window: never sent")
        XCTAssertEqual(P.plan(insertText: "a\u{1b}b"), [.text("ab")])
        XCTAssertEqual(P.plan(insertText: "f\u{e4}ke p\u{e4}ss"), [.text("fäke päss")], "Unicode characters stay")
        let long = String(repeating: "x", count: P.maxTextChunk * 2 + 3)
        XCTAssertEqual(P.plan(insertText: long).count, 3)
        XCTAssertEqual(P.deleteBackward, [.delete])
    }

    // MARK: Which frames

    func testOnlyFreshFramesKeyframeFirst() {
        var g = LockScreenFrameGate()
        XCTAssertFalse(g.accepts(encodedAtMs: 100, keyframe: true), "closed until the view starts")
        g.start(nowMs: 1_000)
        XCTAssertFalse(g.accepts(encodedAtMs: 999, keyframe: true), "encoded before the view began")
        XCTAssertFalse(g.accepts(encodedAtMs: 1_001, keyframe: false), "nothing before a keyframe")
        XCTAssertTrue(g.accepts(encodedAtMs: 1_002, keyframe: true))
        XCTAssertTrue(g.accepts(encodedAtMs: 1_003, keyframe: false))
        XCTAssertFalse(g.accepts(encodedAtMs: 998, keyframe: false), "a late frame from before stays out")
        g.stop()
        XCTAssertFalse(g.accepts(encodedAtMs: 2_000, keyframe: true))
        g.start(nowMs: 3_000)
        XCTAssertFalse(g.accepts(encodedAtMs: 3_001, keyframe: false), "a new view starts with a keyframe again")
    }

    // MARK: Capture for the view (#255)

    func testRecoveryRunsWhileLockedOnlyForALiveView() {
        typealias P = LockScreenCapturePolicy
        XCTAssertTrue(P.consoleCanCapture(interactive: true, lockScreenViewLive: false,
                                          mainDisplayAsleep: false, captureDisplayAwake: true))
        XCTAssertFalse(P.consoleCanCapture(interactive: false, lockScreenViewLive: false,
                                           mainDisplayAsleep: false, captureDisplayAwake: true),
                       "locked with nobody viewing the lock screen: still waits")
        XCTAssertTrue(P.consoleCanCapture(interactive: false, lockScreenViewLive: true,
                                          mainDisplayAsleep: false, captureDisplayAwake: true),
                      "a receiver showing the lock screen needs capture before any unlock")
        XCTAssertFalse(P.consoleCanCapture(interactive: false, lockScreenViewLive: true,
                                           mainDisplayAsleep: true, captureDisplayAwake: false),
                       "nothing awake to capture: still waits")
        XCTAssertTrue(P.consoleCanCapture(interactive: true, lockScreenViewLive: false,
                                          mainDisplayAsleep: true, captureDisplayAwake: true),
                      "a switched-off external main display doesn't block the awake captured one")
    }

    func testAViewWithoutAFreshPictureRecoversOrRebuildsCapture() {
        typealias P = LockScreenCapturePolicy
        XCTAssertEqual(P.freshFrameAction(viewStillLive: true, keyframeSent: false, captureLive: true, mirror: true),
                       .rebuildCapture, "a still login window sends nothing new: rebuild for a complete frame")
        XCTAssertEqual(P.freshFrameAction(viewStillLive: true, keyframeSent: false, captureLive: false, mirror: true),
                       .recoverCapture)
        XCTAssertEqual(P.freshFrameAction(viewStillLive: true, keyframeSent: true, captureLive: true, mirror: true), .none)
        XCTAssertEqual(P.freshFrameAction(viewStillLive: false, keyframeSent: false, captureLive: true, mirror: true),
                       .none, "a view that ended, or was replaced, rebuilds nothing")
        XCTAssertEqual(P.freshFrameAction(viewStillLive: true, keyframeSent: false, captureLive: true, mirror: false), .none)
        XCTAssertEqual(P.freshFrameChecks.count, 2, "bounded")
    }

    func testAutomaticMirrorShowsTheLoginWindowsMainDisplay() {
        typealias P = LockScreenCapturePolicy
        let builtIn = MirrorSourceCandidate(displayID: 1, persistentID: "built-in")
        let external = MirrorSourceCandidate(displayID: 2, persistentID: "external")
        let meow = MirrorSourceCandidate(displayID: 9, persistentID: "meow")
        XCTAssertEqual(P.automaticDisplay(in: [builtIn, external], excluding: [], main: 2), 2)
        XCTAssertEqual(P.automaticDisplay(in: [builtIn, external], excluding: [], main: 7), 1,
                       "main not capturable: the usual Automatic choice")
        XCTAssertEqual(P.automaticDisplay(in: [meow, builtIn], excluding: [9], main: 9), 1,
                       "never a MeowDisplay virtual display")
        XCTAssertTrue(P.shouldMoveToMain(selectedUUID: nil, captureDisplayID: 1, main: 2, mainUsable: true, meowDisplayIDs: []))
        XCTAssertFalse(P.shouldMoveToMain(selectedUUID: "built-in", captureDisplayID: 1, main: 2, mainUsable: true,
                                          meowDisplayIDs: []), "an explicit choice is kept")
        XCTAssertFalse(P.shouldMoveToMain(selectedUUID: nil, captureDisplayID: 2, main: 2, mainUsable: true, meowDisplayIDs: []))
        XCTAssertFalse(P.shouldMoveToMain(selectedUUID: nil, captureDisplayID: 1, main: 2, mainUsable: false, meowDisplayIDs: []),
                       "a sleeping or switched-off main display isn't a target")
        XCTAssertFalse(P.shouldMoveToMain(selectedUUID: nil, captureDisplayID: 1, main: 9, mainUsable: true, meowDisplayIDs: [9]))
        XCTAssertFalse(P.shouldMoveToMain(selectedUUID: nil, captureDisplayID: 0, main: 2, mainUsable: true, meowDisplayIDs: []))
    }

    // MARK: The per-device switch

    private func isolatedDefaults() -> UserDefaults {
        let suite = "LockScreenControlTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Effective permission as the Mac decides it: the store's switch through `LockScreenEligibility`,
    /// with this connection's grant and the lock, for one device's stored values.
    private func effective(_ id: String, _ d: UserDefaults, granted: Bool = true, masterInput: Bool = true,
                           handoff: Bool = false) -> LockScreenDenial? {
        var i = inputs(policy: ReceiverInputAuthorizationStore.policy(peerID: id, defaults: d), granted: granted,
                       allowed: ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: id, defaults: d),
                       handoff: handoff)
        i.masterInput = masterInput
        return LockScreenEligibility.denial(i)
    }

    /// 2.1: Always Allow carries lock screen control. Nothing stored follows the input policy.
    func testAlwaysAllowCarriesLockScreenControlWithNothingStored() {
        let d = isolatedDefaults()
        XCTAssertTrue(ReceiverInputAuthorizationStore.setPolicy(.alwaysAllow, peerID: "always",
                                                                anySessionHasEffectiveInput: false, defaults: d))
        XCTAssertTrue(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: "always", defaults: d))
        XCTAssertFalse(ReceiverInputAuthorizationStore.lockScreenControlRestricted(peerID: "always", defaults: d))
        XCTAssertNil(effective("always", d), "Always Allow with this connection's grant: allowed")
        XCTAssertEqual(effective("always", d, granted: false), .needsControl,
                       "Always Allow without a grant yet: granted on request without a prompt")
        XCTAssertNil(d.dictionary(forKey: "receiverLockScreenControl.v1"), "nothing is written to make it so")
    }

    /// Existing 2.0 devices: the input policy store as 2.0 left it, no lock screen key at all.
    func testExisting20AlwaysAllowDevicesMigrateSilently() {
        let d = isolatedDefaults()
        d.set(["paired-always": "alwaysAllow", "paired-never": "neverAllow"], forKey: "receiverInputAuthorization.v2")
        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: "paired-always", defaults: d), .alwaysAllow)
        XCTAssertNil(effective("paired-always", d), "Always Allow from 2.0: lock screen control with no new step")
        XCTAssertEqual(effective("paired-never", d), .neverAllow, "Never Allow from 2.0 stays denied")
        XCTAssertEqual(effective("paired-ask", d, granted: false), .controlBeforeLock,
                       "Ask (nothing stored) without a pre-lock grant: nothing while locked")
        XCTAssertEqual(effective("discovered-only", d, granted: false), .controlBeforeLock,
                       "a merely discovered or newly paired device gets no persistent control")
        // Reading migrates nothing and widens no input policy.
        XCTAssertNil(d.dictionary(forKey: "receiverLockScreenControl.v1"))
        XCTAssertEqual(d.dictionary(forKey: "receiverInputAuthorization.v2") as? [String: String],
                       ["paired-always": "alwaysAllow", "paired-never": "neverAllow"])
    }

    /// Pre-release QA builds stored the owner's own toggle: an explicit off stays a restriction.
    func testAnExplicitOffFromBeforeStaysAndOverridesAlwaysAllow() {
        let d = isolatedDefaults()
        d.set(["qa-off": "alwaysAllow", "qa-on": "alwaysAllow"], forKey: "receiverInputAuthorization.v2")
        d.set(["qa-off": false, "qa-on": true], forKey: "receiverLockScreenControl.v1")
        XCTAssertTrue(ReceiverInputAuthorizationStore.lockScreenControlRestricted(peerID: "qa-off", defaults: d))
        XCTAssertEqual(effective("qa-off", d), .turnedOff, "an identifiable explicit denial is kept")
        XCTAssertNil(effective("qa-on", d), "a stored on means the same as nothing stored")
    }

    func testAskAndNeverAllowAndAllowInputOff() {
        let d = isolatedDefaults()
        XCTAssertNil(effective("ask", d), "Ask with control granted on this connection before the lock")
        XCTAssertEqual(effective("ask", d, granted: false), .controlBeforeLock, "no control merely because it's locked")
        XCTAssertEqual(effective("ask", d, granted: false, handoff: true), .needsControl,
                       "Ask: the Mac's one-time handoff of a pre-lock grant")
        _ = ReceiverInputAuthorizationStore.setPolicy(.neverAllow, peerID: "never", anySessionHasEffectiveInput: false, defaults: d)
        XCTAssertEqual(effective("never", d), .neverAllow)
        XCTAssertEqual(effective("never", d, handoff: true), .neverAllow)
        _ = ReceiverInputAuthorizationStore.setPolicy(.alwaysAllow, peerID: "always", anySessionHasEffectiveInput: false, defaults: d)
        XCTAssertEqual(effective("always", d, masterInput: false), .inputOff, "Allow Input off: nothing, lock screen included")
    }

    func testTheSwitchOnlyNarrowsAndForgetClearsIt() {
        let d = isolatedDefaults()
        let id = "lock-screen-peer"
        _ = ReceiverInputAuthorizationStore.setPolicy(.alwaysAllow, peerID: id, anySessionHasEffectiveInput: false, defaults: d)
        XCTAssertTrue(ReceiverInputAuthorizationStore.setLockScreenControlAllowed(false, peerID: id, anySessionHasEffectiveInput: true, defaults: d),
                      "turning it off always works, also while a device controls this Mac")
        XCTAssertFalse(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: id, defaults: d))
        XCTAssertEqual(effective(id, d), .turnedOff, "the explicit restriction overrides Always Allow")
        XCTAssertFalse(ReceiverInputAuthorizationStore.setLockScreenControlAllowed(true, peerID: id, anySessionHasEffectiveInput: true, defaults: d),
                       "lifting it is refused while a device controls this Mac")
        XCTAssertFalse(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: id, defaults: d))
        XCTAssertTrue(ReceiverInputAuthorizationStore.setLockScreenControlAllowed(true, peerID: id, anySessionHasEffectiveInput: false, defaults: d))
        XCTAssertTrue(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: id, defaults: d))
        XCTAssertNil((d.dictionary(forKey: "receiverLockScreenControl.v1") as? [String: Bool])?[id], "on is not stored")
        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: id, defaults: d), .alwaysAllow, "no input policy is written or widened")

        // With no restriction, "on" changes nothing, even while a device controls this Mac.
        XCTAssertTrue(ReceiverInputAuthorizationStore.setLockScreenControlAllowed(true, peerID: "other", anySessionHasEffectiveInput: true, defaults: d))
        // A legacy explicit `true` is dropped on write.
        d.set([id: true], forKey: "receiverLockScreenControl.v1")
        XCTAssertTrue(ReceiverInputAuthorizationStore.setLockScreenControlAllowed(true, peerID: id, anySessionHasEffectiveInput: true, defaults: d))
        XCTAssertNil((d.dictionary(forKey: "receiverLockScreenControl.v1") as? [String: Bool])?[id])

        ReceiverInputAuthorizationStore.setLockScreenControlAllowed(false, peerID: id, anySessionHasEffectiveInput: false, defaults: d)
        ReceiverInputAuthorizationStore.removePolicy(peerID: id, defaults: d)
        XCTAssertNil((d.dictionary(forKey: "receiverLockScreenControl.v1") as? [String: Bool])?[id], "Forget leaves nothing behind")
        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: id, defaults: d), .ask)
        XCTAssertEqual(effective(id, d, granted: false), .controlBeforeLock, "a forgotten, re-paired device starts with no control")
    }

    // MARK: Wire

    func testWire() {
        let available = MacLockWire.message(.locked, lockScreen: .available)
        XCTAssertEqual(available["remoteUnlock"] as? Bool, true)
        XCTAssertEqual(available["lockScreen"] as? String, "available")
        XCTAssertEqual(MacLockNotice(message: available)?.lockScreen, .available)
        let refused = MacLockWire.message(.locked, lockScreen: .unavailable("turnedOff"))
        XCTAssertEqual(refused["remoteUnlock"] as? Bool, false)
        XCTAssertEqual(MacLockNotice(message: refused)?.lockScreen, .unavailable("turnedOff"))
        XCTAssertNil(MacLockWire.message(.unlocked, lockScreen: .available)["lockScreen"])
        for offer in [LockScreenOffer.active, .needsControl, .needsFullDesktop, .unavailable(nil), .unavailable("otherUser")] {
            XCTAssertEqual(MacLockNotice(message: MacLockWire.message(.locked, lockScreen: offer))?.lockScreen, offer)
        }
        // An older Mac: no lockScreen, remoteUnlock false. Contradictions are never an offer.
        XCTAssertEqual(MacLockNotice(message: ["type": MacLockWire.type, "state": "locked", "remoteUnlock": false])?.lockScreen, .unavailable(nil))
        XCTAssertEqual(MacLockNotice(message: ["type": MacLockWire.type, "state": "locked", "remoteUnlock": false, "lockScreen": "available"])?.lockScreen,
                       .unavailable(nil))
        XCTAssertEqual(MacLockNotice(message: ["type": MacLockWire.type, "state": "locked", "remoteUnlock": true, "lockScreen": "fromTheFuture"])?.lockScreen,
                       .unavailable("fromTheFuture"))
        XCTAssertEqual(LockScreenWire.request(show: true)["show"] as? Bool, true)
    }
}
