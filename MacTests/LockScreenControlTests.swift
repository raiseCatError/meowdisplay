import XCTest

/// Lock screen control (SECURITY.md "Lock screen control"): who may show and operate macOS's own
/// lock screen, which input reaches it, which frames leave, the per-device switch and the wire.
/// The sender's own enforcement, end to end, is in `MacSenderInputRevocationTests`.
final class LockScreenControlTests: XCTestCase {
    private func inputs(policy: PeerInputRequestPolicy = .alwaysAllow, granted: Bool = true,
                        privacy: MacScreenPrivacy = .locked, allowed: Bool = true,
                        windowView: Bool = false, extend: Bool = false) -> LockScreenEligibility.Inputs {
        LockScreenEligibility.Inputs(admitted: true, masterInput: true, onConsole: true, privacy: privacy,
                                     policy: policy, lockScreenControlAllowed: allowed,
                                     sessionGranted: granted, windowView: windowView, extend: extend)
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
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .ask, windowView: true), active: false), .unavailable("windowView"))
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
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .ask, extend: true), active: false), .unavailable("windowView"))
        XCTAssertEqual(LockScreenEligibility.offer(inputs(policy: .ask, granted: false, extend: true), active: false), .unavailable("windowView"))
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

    /// F3: right after an unlock from the view, keys and text in flight are dropped; releases go.
    func testUnlockHoldDropsTypingButNotReleases() {
        var hold = LockScreenUnlockHold()
        for a in ["text", "press", "down", "modifierDown", "up"] { XCTAssertTrue(hold.allows(action: a, now: 0), a) }
        hold.start(now: 10)
        for a in ["text", "press", "down", "modifierDown", "somethingNew"] {
            XCTAssertFalse(hold.allows(action: a, now: 10.1), a)
            XCTAssertFalse(hold.allows(action: a, now: 11.49), a)
        }
        for a in ["up", "modifierUp", "cancel"] { XCTAssertTrue(hold.allows(action: a, now: 10.1), a) }
        XCTAssertTrue(hold.allows(action: "text", now: 10 + LockScreenSessionPolicy.unlockKeyboardHold), "bounded")
        hold.start(now: 20)
        hold.clear()
        XCTAssertTrue(hold.allows(action: "text", now: 20.1))
    }

    // MARK: The receiver's keyboard (F1)

    func testTheKeyboardIsSecureWhileTheMacIsLocked() {
        let locked = RemoteKeyboardTraits.current(macLocked: true)
        XCTAssertEqual(locked, .lockScreen)
        XCTAssertTrue(locked.secureEntry)
        XCTAssertTrue(locked.passwordContentType)
        XCTAssertFalse(locked.autocorrection)
        XCTAssertFalse(locked.spellChecking)
        XCTAssertFalse(locked.autocapitalization)
        XCTAssertFalse(locked.smartPunctuation)
        XCTAssertFalse(locked.inlinePrediction)
        XCTAssertFalse(locked.echoesTypedText, "the strip never shows or reads out what is typed")
        let normal = RemoteKeyboardTraits.current(macLocked: false)
        XCTAssertEqual(normal, .normal)
        XCTAssertFalse(normal.secureEntry)
        XCTAssertTrue(normal.echoesTypedText)
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

    // MARK: The per-device switch

    private func isolatedDefaults() -> UserDefaults {
        let suite = "LockScreenControlTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// Remote unlock is opt-in: off for every device until the owner turns it on for it.
    func testTheSwitchIsOffByDefault() {
        let d = isolatedDefaults()
        XCTAssertFalse(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: "never-set", defaults: d), "off by default")
        // A device trusted with input (even Always Allow) still has it off until turned on.
        _ = ReceiverInputAuthorizationStore.setPolicy(.alwaysAllow, peerID: "always", anySessionHasEffectiveInput: false, defaults: d)
        XCTAssertFalse(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: "always", defaults: d))
        // What a device's stored value says stays as stored: an explicit off stays off, an explicit
        // on stays on.
        d.set(["off-before": false, "on-explicit": true], forKey: "receiverLockScreenControl.v1")
        XCTAssertFalse(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: "off-before", defaults: d))
        XCTAssertTrue(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: "on-explicit", defaults: d))
        XCTAssertFalse(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: "never-set", defaults: d))
    }

    func testTheSwitchOnlyNarrowsAndForgetClearsIt() {
        let d = isolatedDefaults()
        let id = "lock-screen-peer"
        XCTAssertTrue(ReceiverInputAuthorizationStore.setLockScreenControlAllowed(true, peerID: id, anySessionHasEffectiveInput: false, defaults: d),
                      "turned on by the owner")
        XCTAssertTrue(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: id, defaults: d))
        XCTAssertTrue(ReceiverInputAuthorizationStore.setLockScreenControlAllowed(false, peerID: id, anySessionHasEffectiveInput: true, defaults: d),
                      "turning it off always works")
        XCTAssertFalse(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: id, defaults: d))
        XCTAssertFalse(ReceiverInputAuthorizationStore.setLockScreenControlAllowed(true, peerID: id, anySessionHasEffectiveInput: true, defaults: d),
                       "turning it on is refused while a device controls this Mac")
        XCTAssertFalse(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: id, defaults: d))
        XCTAssertTrue(ReceiverInputAuthorizationStore.setLockScreenControlAllowed(true, peerID: id, anySessionHasEffectiveInput: false, defaults: d))
        XCTAssertTrue(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: id, defaults: d))
        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: id, defaults: d), .ask, "no input policy is written or widened")

        ReceiverInputAuthorizationStore.setLockScreenControlAllowed(false, peerID: id, anySessionHasEffectiveInput: false, defaults: d)
        ReceiverInputAuthorizationStore.removePolicy(peerID: id, defaults: d)
        XCTAssertFalse(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: id, defaults: d), "Forget leaves nothing behind: off")
        XCTAssertNil((d.dictionary(forKey: "receiverLockScreenControl.v1") as? [String: Bool])?[id])
        // Forget after it was turned on: back to the default, off.
        ReceiverInputAuthorizationStore.setLockScreenControlAllowed(true, peerID: id, anySessionHasEffectiveInput: false, defaults: d)
        ReceiverInputAuthorizationStore.removePolicy(peerID: id, defaults: d)
        XCTAssertFalse(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: id, defaults: d))
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
