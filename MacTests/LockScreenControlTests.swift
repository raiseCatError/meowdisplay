import XCTest

/// Lock screen control (SECURITY.md "Lock screen control"): who may show and operate macOS's own
/// lock screen, which input reaches it, which frames leave, the per-device switch and the wire.
/// The sender's own enforcement, end to end, is in `MacSenderInputRevocationTests`.
final class LockScreenControlTests: XCTestCase {
    private func inputs(policy: PeerInputRequestPolicy = .alwaysAllow, granted: Bool = true,
                        privacy: MacScreenPrivacy = .locked, allowed: Bool = true,
                        windowView: Bool = false) -> LockScreenEligibility.Inputs {
        LockScreenEligibility.Inputs(admitted: true, masterInput: true, onConsole: true, privacy: privacy,
                                     policy: policy, lockScreenControlAllowed: allowed,
                                     sessionGranted: granted, windowView: windowView)
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

    // MARK: Which input

    func testOnlyWhatTheLoginWindowNeeds() {
        let allowed: [LockScreenInputEvent] = [
            .touch, .pointerMove, .pointerButton(.left), .release,
            .key(.keyA, modifiers: []), .key(.keyZ, modifiers: ["shift"]), .key(.digit5, modifiers: ["option"]),
            .key(.returnOrEnter, modifiers: []), .key(.tab, modifiers: ["shift"]), .key(.deleteOrBackspace, modifiers: []),
            .key(.escape, modifiers: []), .key(.leftArrow, modifiers: []), .key(.spacebar, modifiers: ["capsLock"]),
            .key(.period, modifiers: []), .key(.keypad7, modifiers: []), .key(.nonUSBackslash, modifiers: ["option"]),
            .modifier("shift"), .modifier("option"),
            .text("p@ss wörd!"),
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

    func testTheSwitchOnlyNarrowsAndForgetClearsIt() {
        let d = isolatedDefaults()
        let id = "lock-screen-peer"
        XCTAssertTrue(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: id, defaults: d), "on by default")
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
        XCTAssertTrue(ReceiverInputAuthorizationStore.lockScreenControlAllowed(peerID: id, defaults: d), "Forget leaves nothing behind")
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
