import XCTest
import CoreGraphics
import Network

/// End to end on the Mac side: a real `MacSender` receives the receiver's
/// control messages through its own gate, its own `InputInjector` turns them
/// into synthetic events, and the real grant and revocation paths run. The
/// only stand-ins are the network (the test plays the receiver), the hello's
/// identity proof (see `SenderSessionAuthorizationTests`) and the HID event
/// tap: events go to a recorder, so these tests never move the pointer or
/// type anywhere.
///
/// Every revocation path must release whatever the receiver was holding (a
/// key, a modifier, a mouse drag, a touch) and must drop everything after it.
final class MacSenderInputRevocationTests: XCTestCase {

    private var keychain: TemporaryTestKeychain?
    private var sender: MacSender?
    private let events = RecordingEventSink()
    private let sent = SentMessages()

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)   // master on (the default)
        LoginSessionConsole.shared.set(onConsole: true)
        let keychain = try TemporaryTestKeychain(prefix: "meowdisplay-input-revocation-tests")
        self.keychain = keychain
        let identity = try keychain.makeIdentity()
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: identity.identity),
                                   pinnedPeerSPKI: identity.spki, peerID: Self.peerID)
        self.tls = tls
        setUpSender()
    }

    private var tls: TLSSessionConfig?

    /// A fresh sender (and lock state); the previous one, if any, is dropped.
    private func setUpSender() {
        guard let tls else { return }
        privacyGate.set(.unlocked)
        // Never dialed: the endpoint only satisfies the initializer.
        sender = MacSender(transport: .tcp(.hostPort(host: "127.0.0.1", port: 9), tls: tls),
                           name: "Revocation Test Phone", mode: .mirror)
        // Its own lock state: these tests never depend on whether this Mac's screen is locked.
        sender?.privacyGate = privacyGate
        sent.clear()
        _ = events.take()
    }

    private let privacyGate = MacPrivacyGate(.unlocked)

    // MARK: - Lock screen (SECURITY.md "When the Mac is locked")

    /// Locking while a granted receiver holds a key, a modifier and a drag: everything is released
    /// at once, nothing it sends reaches the Mac (the lock screen or a window behind it) while
    /// locked, the receiver is told (lock state, input reset, video off). The grant stays with the
    /// connection; input works again only after the unlock.
    func testLockReleasesHeldInputAndBlocksEveryInputUntilUnlock() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await holdKeyModifierAndDrag(sender)

        privacyGate.set(.locked)
        sender.macPrivacyChanged(.locked)
        try await sender.settleForTesting()

        assertReleasedKeyModifierAndDrag(events.take())
        XCTAssertTrue(sent.contains(type: MacLockWire.type))
        XCTAssertTrue(sent.contains(type: WireMessage.inputReset))
        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take(), [], "nothing may reach the Mac while it's locked")
        XCTAssertTrue(sender.hasInputGrantForTesting, "the grant stays with this connection; only input waits")

        for state in [MacScreenPrivacy.unknown, .switchedOut] {
            privacyGate.set(state)
            sender.macPrivacyChanged(state)
            try await sender.settleForTesting()
            try await sendEveryInputKind(sender)
            XCTAssertEqual(events.take(), [], "\(state): counted as locked")
        }

        privacyGate.set(.unlocked)
        sender.macPrivacyChanged(.unlocked)
        try await sender.settleForTesting()
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyC.rawValue])
        XCTAssertFalse(events.take().isEmpty, "input works again after the unlock")
    }

    /// Lock This Mac while already locked answers "locked" and posts nothing.
    func testLockMacWhileLockedAnswersLocked() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        privacyGate.set(.locked)
        sender.macPrivacyChanged(.locked)
        try await sender.settleForTesting()
        _ = events.take()
        try await receive(sender, ["type": LockMacWire.request, "req": 7])
        try await sender.settleForTesting()
        XCTAssertEqual(events.take(), [])
    }

    // MARK: - Lock screen control (SECURITY.md "Lock screen control")

    /// Locks the Mac for a granted receiver whose device policy and switch the app has pushed.
    @discardableResult
    private func lockWithPermit(_ sender: MacSender, policy: PeerInputRequestPolicy = .alwaysAllow,
                                allowed: Bool = true, grant: Bool = true) async throws -> UInt64 {
        let generation = grant ? try await admitAndGrant(sender) : try await admit(sender)
        sender.setLockScreenPermit(policy: policy, allowed: allowed)
        privacyGate.set(.locked)
        sender.macPrivacyChanged(.locked)
        try await sender.settleForTesting()
        _ = events.take()
        return generation
    }

    private func showLockScreen(_ sender: MacSender, _ show: Bool = true) async throws {
        try await receive(sender, LockScreenWire.request(show: show))
        try await sender.settleForTesting()
    }

    /// Shown: only what the login window needs reaches the Mac: clicks, character keys with
    /// Shift, Return, Delete. Command and Control, right-click, scroll, Pencil and the rest don't.
    func testTheLockScreenTakesOnlyWhatTheLoginWindowNeeds() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        XCTAssertEqual(sent.lastLockScreen, "available")
        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take(), [], "nothing before the receiver shows the lock screen")

        try await showLockScreen(sender)
        XCTAssertEqual(sent.lastLockScreen, "active")
        XCTAssertEqual(sent.last(type: WireMessage.videoState)?["enabled"] as? Bool, true, "the lock screen picture is on")
        try await receive(sender, ["type": "pointer", "action": "move", "x": 0.5, "y": 0.5])
        try await receive(sender, ["type": "pointer", "action": "down", "button": "left", "clickCount": 1])
        try await receive(sender, ["type": "pointer", "action": "up", "button": "left", "clickCount": 1])
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyP.rawValue, "modifiers": ["shift"]])
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.deleteOrBackspace.rawValue])
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.returnOrEnter.rawValue])
        let allowed = events.take()
        XCTAssertTrue(allowed.contains { $0.type == .leftMouseDown } && allowed.contains { $0.type == .leftMouseUp }, "\(allowed)")
        for usage in [HIDKeyUsage.keyP, .deleteOrBackspace, .returnOrEnter] {
            XCTAssertTrue(allowed.contains { $0.type == .keyDown && $0.keyCode == Int64(usage.keyCode) }, "\(usage)")
        }

        let refused: [[String: Any]] = [
            ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyQ.rawValue, "modifiers": ["command"]],
            ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyA.rawValue, "modifiers": ["control"]],
            ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.f1.rawValue],
            ["type": "keyboard", "action": "modifierDown", "modifier": ControlModifier.command.rawValue],
            ["type": "pointer", "action": "down", "button": "right", "clickCount": 1],
            ["type": "scroll", "dx": 0.0, "dy": 120.0],
            ["type": "pencil", "phase": "began", "x": 0.3, "y": 0.3, "pressure": 0.5],
            ["type": "keyboard", "action": "text", "text": "a\nb"],
        ]
        for message in refused { try await receive(sender, message) }
        let leaked = events.take().filter { [.keyDown, .rightMouseDown, .scrollWheel, .flagsChanged].contains($0.type) }
        XCTAssertEqual(leaked, [], "only the login window's input")

        // Hidden by the receiver: nothing reaches the Mac again, the picture stops.
        try await showLockScreen(sender, false)
        XCTAssertEqual(sent.lastLockScreen, "available")
        XCTAssertEqual(sent.last(type: WireMessage.videoState)?["enabled"] as? Bool, false)
        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take().filter { $0.type != .leftMouseUp && $0.type != .keyUp }, [])
    }

    /// The pointer (position and sprite) is screen content: locked, nothing of it goes out, and
    /// a drop doesn't count as sent. Showing the lock screen sends it again from the first poll,
    /// to this connection only, while the view lasts; hiding it stops it; unlocking resends it.
    func testTheCursorGoesOutOnlyWhileTheLockScreenIsShown() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        let position = "\"x\":0.5,\"y\":0.5,\"v\":1"
        let sprite = "{\"type\":\"cursorImg\",\"png\":\"\"}"
        func pointerSent() async throws -> (cursor: Bool, sprite: Bool) {
            sent.clear()
            try await sender.sendCursorForTesting(position)
            try await sender.sendCursorSpriteForTesting(sprite)
            return (sent.contains(type: "cursor"), sent.contains(type: "cursorImg"))
        }

        try await sender.markCursorSentForTesting()
        var out = try await pointerSent()
        XCTAssertFalse(out.cursor, "locked, not shown: no position")
        XCTAssertFalse(out.sprite, "locked, not shown: no sprite")

        try await showLockScreen(sender)
        XCTAssertEqual(sent.lastLockScreen, "active")
        let resendOnShow = try await sender.cursorEchoWillResendForTesting()
        XCTAssertTrue(resendOnShow, "the view starts: position and sprite go out again")
        out = try await pointerSent()
        XCTAssertTrue(out.cursor, "shown: the login window's pointer")
        XCTAssertTrue(out.sprite)

        try await sender.markCursorSentForTesting()
        try await showLockScreen(sender, false)
        let resendOnHide = try await sender.cursorEchoWillResendForTesting()
        XCTAssertTrue(resendOnHide)
        out = try await pointerSent()
        XCTAssertFalse(out.cursor, "hidden: nothing again")
        XCTAssertFalse(out.sprite)

        // Another user switching in ends the view: nothing, even though it was shown.
        try await sender.resetLockScreenShowLimitForTesting()
        try await showLockScreen(sender)
        privacyGate.set(.switchedOut)
        sender.macPrivacyChanged(.switchedOut)
        try await sender.settleForTesting()
        out = try await pointerSent()
        XCTAssertFalse(out.cursor, "another user on the console")
        XCTAssertFalse(out.sprite)

        try await sender.markCursorSentForTesting()
        privacyGate.set(.unlocked)
        sender.macPrivacyChanged(.unlocked)
        try await sender.settleForTesting()
        let resendOnUnlock = try await sender.cursorEchoWillResendForTesting()
        XCTAssertTrue(resendOnUnlock, "unlocked: sent again")
        out = try await pointerSent()
        XCTAssertTrue(out.cursor)
        XCTAssertTrue(out.sprite)
    }

    /// Extend's display never shows the login window: switch to Mirror first, never `available`.
    func testExtendIsSentToMirrorForTheLockScreen() async throws {
        guard let tls else { return XCTFail("no TLS") }
        privacyGate.set(.unlocked)
        sender = MacSender(transport: .tcp(.hostPort(host: "127.0.0.1", port: 9), tls: tls),
                           name: "Revocation Test Phone", mode: .extend)
        sender?.privacyGate = privacyGate
        sent.clear()
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        XCTAssertEqual(sent.lastLockScreen, "needsFullDesktop")
        try await showLockScreen(sender)
        XCTAssertNotEqual(sent.lastLockScreen, "active", "never shown in Extend")
        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take(), [], "nothing reaches the lock screen from Extend")
    }

    /// F2: the view belongs to the connection that asked. A new connection (the grant given back
    /// without a prompt or not) starts without it: not `active`, no frames, no input, until it
    /// sends a fresh `show:true` itself.
    func testTheViewNeverCarriesOverToANewConnection() async throws {
        for regrant in [false, true] {
            setUpSender()
            let sender = try XCTUnwrap(sender)
            try await lockWithPermit(sender)
            try await showLockScreen(sender)
            XCTAssertEqual(sent.lastLockScreen, "active")
            let framesBefore = try await sender.lockScreenFramesWouldSendForTesting()
            XCTAssertTrue(framesBefore, "shown: fresh frames go")

            let generation = try await admit(sender)   // the connection ended; a new one
            if regrant {
                sender.grantSessionInput(generation: generation)
                try await sender.settleForTesting()
            }
            sent.clear()
            sender.setLockScreenPermit(policy: .alwaysAllow, allowed: true)   // the app vouches again
            try await sender.settleForTesting()
            XCTAssertEqual(sent.lastLockScreen, regrant ? "available" : "needsControl", "regrant \(regrant)")
            let framesAfter = try await sender.lockScreenFramesWouldSendForTesting()
            XCTAssertFalse(framesAfter, "regrant \(regrant): no lock screen frames on the new connection")
            XCTAssertFalse(sent.contains(type: "cursor"))
            _ = events.take()
            try await sendEveryInputKind(sender)
            try await receive(sender, ["type": "keyboard", "action": "text", "text": "fake-pass-123"])
            XCTAssertEqual(events.take().filter { $0.type != .leftMouseUp && $0.type != .keyUp && $0.type != .rightMouseUp }, [],
                           "regrant \(regrant): nothing reaches the lock screen")
            if regrant {
                try await showLockScreen(sender)
                XCTAssertEqual(sent.lastLockScreen, "active", "a fresh show:true on the new connection")
            }
        }
    }

    /// F3: unlocked (at the Mac, Touch ID, Watch) while the receiver types into the view: the
    /// receiver is told to reset input, and keys and text still in flight don't land in the app now
    /// in front.
    func testUnlockFromTheViewDropsTypingInFlight() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        try await showLockScreen(sender)
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyA.rawValue])
        XCTAssertTrue(events.take().contains { $0.type == .keyDown }, "typed on the lock screen")
        sent.clear()
        privacyGate.set(.unlocked)
        sender.macPrivacyChanged(.unlocked)
        try await sender.settleForTesting()
        XCTAssertTrue(sent.contains(type: WireMessage.inputReset), "the receiver resets its input")
        _ = events.take()
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyB.rawValue])
        try await receive(sender, ["type": "keyboard", "action": "text", "text": "fake-pass-123"])
        try await receive(sender, ["type": "keyboard", "action": "down", "usage": HIDKeyUsage.keyC.rawValue])
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.returnOrEnter.rawValue])
        XCTAssertEqual(events.take().filter { $0.type != .keyUp && $0.type != .flagsChanged }, [],
                       "nothing in flight is typed into the app in front")
        try await receive(sender, ["type": "keyboard", "action": "up", "usage": HIDKeyUsage.keyC.rawValue])
        try await sender.endUnlockHoldForTesting()
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyD.rawValue])
        XCTAssertTrue(events.take().contains { $0.type == .keyDown && $0.keyCode == Int64(HIDKeyUsage.keyD.keyCode) },
                      "after the hold, normal input")
    }

    /// F5: every event re-checks the whole eligibility (policy, switch, console), not only the
    /// places that announce a change: a permit changed with no review is refused on the next event.
    func testEveryLockScreenEventRechecksEligibility() async throws {
        let narrowings: [(String, (MacSender) async throws -> Void, () -> Void)] = [
            ("neverAllow", { try await $0.setLockScreenPermitWithoutReviewForTesting(policy: .neverAllow, allowed: true) }, {}),
            ("turnedOff", { try await $0.setLockScreenPermitWithoutReviewForTesting(policy: .alwaysAllow, allowed: false) }, {}),
            ("otherUser", { _ in LoginSessionConsole.shared.set(onConsole: false) }, { LoginSessionConsole.shared.set(onConsole: true) }),
        ]
        for (reason, narrow, restore) in narrowings {
            setUpSender()
            let sender = try XCTUnwrap(sender)
            try await lockWithPermit(sender)
            try await showLockScreen(sender)
            XCTAssertEqual(sent.lastLockScreen, "active", reason)
            try await narrow(sender)
            _ = events.take()
            try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyA.rawValue])
            try await receive(sender, ["type": "pointer", "action": "down", "button": "left", "clickCount": 1])
            XCTAssertEqual(events.take().filter { $0.type == .keyDown || $0.type == .leftMouseDown }, [], reason)
            XCTAssertNotEqual(sent.lastLockScreen, "active", "\(reason): the view ended")
            restore()
        }
    }

    /// F7: a receiver toggling show:true/false can't keep waking the display: at most one view,
    /// and one wake, per 5 s on a connection.
    func testRepeatedShowWakesAtMostOnce() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        for _ in 0..<20 {
            try await receive(sender, LockScreenWire.request(show: true))
            try await receive(sender, LockScreenWire.request(show: false))
        }
        try await sender.settleForTesting()
        let wakes = try await sender.lockScreenWakeCountForTesting
        XCTAssertEqual(wakes, 1)
        try await showLockScreen(sender)
        XCTAssertEqual(sent.lastLockScreen, "available", "too soon: answered with the current state")
        let wakesAfter = try await sender.lockScreenWakeCountForTesting
        XCTAssertEqual(wakesAfter, 1)
    }

    /// A view-only Ask device (no control granted before the lock), a device set to Never Allow,
    /// one with the switch off, and one the app hasn't vouched for yet are never shown it.
    func testOnlyAPreAuthorizedDeviceIsShownTheLockScreen() async throws {
        let cases: [(PeerInputRequestPolicy?, Bool, Bool, String)] = [
            (.ask, true, false, "controlBeforeLock"),
            (.neverAllow, true, true, "neverAllow"),
            (.alwaysAllow, false, true, "turnedOff"),
            (nil, true, true, "unavailable"),
        ]
        for (policy, allowed, grant, reason) in cases {
            setUpSender()
            let sender = try XCTUnwrap(sender)
            if let policy {
                try await lockWithPermit(sender, policy: policy, allowed: allowed, grant: grant)
            } else {
                if grant { try await admitAndGrant(sender) } else { try await admit(sender) }
                privacyGate.set(.locked)
                sender.macPrivacyChanged(.locked)
                try await sender.settleForTesting()
                _ = events.take()
            }
            XCTAssertEqual(sent.lastLockScreen, reason, "\(reason): offer")
            XCTAssertEqual(sent.last(type: MacLockWire.type)?["remoteUnlock"] as? Bool, false, reason)
            try await showLockScreen(sender)
            XCTAssertNotEqual(sent.lastLockScreen, "active", reason)
            try await sendEveryInputKind(sender)
            XCTAssertEqual(events.take(), [], "\(reason): nothing reaches the lock screen")
        }
    }

    /// Turning the switch off, revoking control and unlocking each end the view at once; held
    /// input is released, and after a real unlock normal input works.
    func testTheViewEndsWhenItsReasonEnds() async throws {
        let sender = try XCTUnwrap(sender)
        let generation = try await lockWithPermit(sender)
        try await showLockScreen(sender)
        try await receive(sender, ["type": "pointer", "action": "down", "button": "left", "clickCount": 1])
        _ = events.take()
        sender.setLockScreenPermit(policy: .alwaysAllow, allowed: false)
        try await sender.settleForTesting()
        XCTAssertTrue(events.take().contains { $0.type == .leftMouseUp }, "the held click was released")
        XCTAssertEqual(sent.lastLockScreen, "turnedOff")
        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take().filter { $0.type != .leftMouseUp && $0.type != .keyUp }, [])

        sender.setLockScreenPermit(policy: .alwaysAllow, allowed: true)
        try await sender.resetLockScreenShowLimitForTesting()
        try await showLockScreen(sender)
        XCTAssertEqual(sent.lastLockScreen, "active")
        sender.revokeSessionInput()
        try await sender.settleForTesting()
        XCTAssertNotEqual(sent.lastLockScreen, "active", "revoked: the view ends")
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyA.rawValue])
        XCTAssertEqual(events.take().filter { $0.type == .keyDown }, [])

        // Granted again (Always Allow while locked), shown, then a real unlock: the view ends and
        // the session goes on as before.
        sender.grantSessionInput(generation: generation)
        try await sender.settleForTesting()
        try await sender.resetLockScreenShowLimitForTesting()
        try await showLockScreen(sender)
        XCTAssertEqual(sent.lastLockScreen, "active")
        privacyGate.set(.unlocked)
        sender.macPrivacyChanged(.unlocked)
        try await sender.settleForTesting()
        XCTAssertNil(sent.last(type: MacLockWire.type)?["lockScreen"], "unlocked: nothing to offer")
        try await sender.endUnlockHoldForTesting()   // the post-unlock hold has its own test
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyC.rawValue, "modifiers": ["command"]])
        XCTAssertTrue(events.take().contains { $0.type == .keyDown && $0.keyCode == Int64(HIDKeyUsage.keyC.keyCode) },
                      "unlocked: normal input, shortcuts included")
    }

    override func tearDown() {
        sender = nil
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        keychain?.delete()
        keychain = nil
        super.tearDown()
    }

    // MARK: - Revocation releases held input

    func testMacRevokeDuringHeldKeyAndDragReleasesEverythingAndDropsLaterInput() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await holdKeyModifierAndDrag(sender)

        sender.revokeSessionInput()   // Settings → device → Revoke Control
        try await sender.settleForTesting()

        assertReleasedKeyModifierAndDrag(events.take())
        XCTAssertFalse(sender.hasInputGrantForTesting)
        XCTAssertTrue(sent.contains(type: WireMessage.inputReset))
        XCTAssertEqual(sent.lastAllowInputState?.allowed, false)
        XCTAssertEqual(sent.lastAllowInputState?.state, SessionInputWireState.off.rawValue)

        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take(), [], "nothing may reach the Mac after Revoke")
    }

    func testMasterSwitchOffDuringHeldInputReleasesItAndBlocksEverySession() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await holdKeyModifierAndDrag(sender)

        // Exactly what `SenderController.allowInput`'s didSet does for each session.
        UserDefaults.standard.set(false, forKey: InputPolicy.defaultsKey)
        sender.resetReceiverInputState()
        sender.pushAllowInputState()
        try await sender.settleForTesting()

        assertReleasedKeyModifierAndDrag(events.take())
        XCTAssertTrue(sent.contains(type: WireMessage.inputReset))
        XCTAssertEqual(sent.lastAllowInputState?.allowed, false)

        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take(), [], "nothing may reach the Mac while Allow Input is off")
    }

    func testReceiverReleasingControlMidDragReleasesIt() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await holdKeyModifierAndDrag(sender)

        try await receive(sender, ["type": WireMessage.allowInputRequest, "allowed": false])
        try await sender.settleForTesting()

        assertReleasedKeyModifierAndDrag(events.take())
        XCTAssertFalse(sender.hasInputGrantForTesting)
        XCTAssertEqual(sent.lastAllowInputState?.allowed, false)
        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take(), [])
    }

    func testHeldTouchIsReleasedOnRevoke() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await receive(sender, ["type": "touch", "phase": "began", "x": 0.5, "y": 0.5])
        try await receive(sender, ["type": "touch", "phase": "moved", "x": 0.6, "y": 0.5])
        let held = events.take().map(\.type)
        XCTAssertEqual(held.first, .leftMouseDown)
        XCTAssertTrue(held.contains(.leftMouseDragged))

        sender.revokeSessionInput()
        try await sender.settleForTesting()
        XCTAssertEqual(events.take().map(\.type), [.leftMouseUp])

        // The finger lifting after Revoke releases nothing twice.
        try await receive(sender, ["type": "touch", "phase": "ended", "x": 0.6, "y": 0.5])
        XCTAssertEqual(events.take(), [])
    }

    // MARK: - Reconnect never inherits a grant

    func testLostConnectionReleasesHeldInputAndReconnectStartsWithoutControl() async throws {
        let sender = try XCTUnwrap(sender)
        let first = try await admitAndGrant(sender)
        try await holdKeyModifierAndDrag(sender)

        try await sender.loseConnectionForTesting()
        assertReleasedKeyModifierAndDrag(events.take())
        XCTAssertFalse(sender.hasInputGrantForTesting)

        // Same device, new connection: admitted, but control is off.
        let second = try await admit(sender)
        XCTAssertNotEqual(first, second)
        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take(), [], "a new connection must ask for control again")

        // A late Allow for the old connection grants nothing.
        sender.grantSessionInput(generation: first)
        try await sender.settleForTesting()
        XCTAssertFalse(sender.hasInputGrantForTesting)
        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take(), [])

        // Only a decision for this connection does.
        sender.grantSessionInput(generation: second)
        try await sender.settleForTesting()
        XCTAssertTrue(sender.hasInputGrantForTesting)
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyB.rawValue])
        XCTAssertEqual(events.take().compactMap(\.keyCode), [Int64(HIDKeyUsage.keyB.keyCode), Int64(HIDKeyUsage.keyB.keyCode)])
    }

    func testRedialWhileHoldingReleasesAndDropsTheGrant() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await holdKeyModifierAndDrag(sender)

        // A transport migration that replaces the connection without an EOF first.
        _ = try await admit(sender)
        assertReleasedKeyModifierAndDrag(events.take())
        XCTAssertFalse(sender.hasInputGrantForTesting)
        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take(), [])
    }

    // MARK: - No input without a grant

    func testAdmittedSessionWithoutAGrantPostsNothing() async throws {
        let sender = try XCTUnwrap(sender)
        _ = try await admit(sender)
        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take(), [])

        // Asking for control never grants it by itself: only the Mac decides.
        try await receive(sender, ["type": WireMessage.allowInputRequest, "allowed": true])
        try await sender.settleForTesting()
        XCTAssertFalse(sender.hasInputGrantForTesting)
        try await sendEveryInputKind(sender)
        XCTAssertEqual(events.take(), [])
    }

    func testAGrantIsIgnoredWhileTheLoginSessionIsSwitchedOut() async throws {
        let sender = try XCTUnwrap(sender)
        let generation = try await admit(sender)
        LoginSessionConsole.shared.set(onConsole: false)
        defer { LoginSessionConsole.shared.set(onConsole: true) }
        sender.grantSessionInput(generation: generation)
        try await sender.settleForTesting()
        XCTAssertFalse(sender.hasInputGrantForTesting)
        XCTAssertEqual(sent.lastAllowInputState?.state, SessionInputWireState.notAllowed.rawValue)
    }

    // MARK: - Helpers

    private static let peerID = "revocation-test-phone"

    @discardableResult
    private func admit(_ sender: MacSender) async throws -> UInt64 {
        let hello: [String: Any] = ["type": "hello", "pixelsWide": 2532, "pixelsHigh": 1170, "scale": 3.0,
                                    "device": "iPhone", "id": Self.peerID, "pv": WireProtocol.version]
        return try await sender.admitConnectionForTesting(
            helloJSON: try JSONSerialization.data(withJSONObject: hello),
            pinnedSPKI: Data([0x30, 0x59]), eventSink: events, sent: sent.record)
    }

    @discardableResult
    private func admitAndGrant(_ sender: MacSender) async throws -> UInt64 {
        let generation = try await admit(sender)
        sender.grantSessionInput(generation: generation)
        try await sender.settleForTesting()
        XCTAssertTrue(sender.hasInputGrantForTesting)
        XCTAssertEqual(sent.lastAllowInputState?.allowed, true)
        return generation
    }

    private func receive(_ sender: MacSender, _ message: [String: Any]) async throws {
        try await sender.receiveControlForTesting(try JSONSerialization.data(withJSONObject: message))
    }

    /// Shift held, A held, and a left-button drag in progress.
    private func holdKeyModifierAndDrag(_ sender: MacSender) async throws {
        try await receive(sender, ["type": "keyboard", "action": "modifierDown", "modifier": ControlModifier.shift.rawValue])
        try await receive(sender, ["type": "keyboard", "action": "down", "usage": HIDKeyUsage.keyA.rawValue])
        try await receive(sender, ["type": "pointer", "action": "move", "x": 0.4, "y": 0.4])
        try await receive(sender, ["type": "pointer", "action": "down", "button": "left", "clickCount": 1])
        try await receive(sender, ["type": "pointer", "action": "move", "x": 0.5, "y": 0.5])
        let held = events.take()
        XCTAssertEqual(held.filter { $0.type == .keyDown }.compactMap(\.keyCode), [Int64(HIDKeyUsage.keyA.keyCode)])
        XCTAssertTrue(held.contains { $0.keyCode == Int64(ControlModifier.shift.keyCode) }, "Shift was not pressed")
        XCTAssertTrue(held.contains { $0.type == .leftMouseDown })
        XCTAssertTrue(held.contains { $0.type == .leftMouseDragged })
    }

    private func assertReleasedKeyModifierAndDrag(_ released: [RecordingEventSink.Posted],
                                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(released.contains { $0.type == .leftMouseUp }, "the drag was not released: \(released)", file: file, line: line)
        XCTAssertTrue(released.contains { $0.type == .keyUp && $0.keyCode == Int64(HIDKeyUsage.keyA.keyCode) },
                      "A was not released: \(released)", file: file, line: line)
        XCTAssertTrue(released.contains { $0.keyCode == Int64(ControlModifier.shift.keyCode) },
                      "Shift was not released: \(released)", file: file, line: line)
        XCTAssertFalse(released.contains { [.keyDown, .leftMouseDown, .rightMouseDown, .leftMouseDragged, .scrollWheel].contains($0.type) },
                       "a release posted new input: \(released)", file: file, line: line)
    }

    /// One of every input message a receiver can send.
    private func sendEveryInputKind(_ sender: MacSender) async throws {
        let messages: [[String: Any]] = [
            ["type": "touch", "phase": "began", "x": 0.3, "y": 0.3],
            ["type": "touch", "phase": "ended", "x": 0.3, "y": 0.3],
            ["type": "scroll", "dx": 0.0, "dy": 120.0],
            ["type": "pointer", "action": "move", "x": 0.2, "y": 0.2],
            ["type": "pointer", "action": "moveRelative", "dx": 10.0, "dy": 10.0],
            ["type": "pointer", "action": "down", "button": "right", "clickCount": 1],
            ["type": "pointer", "action": "up", "button": "right", "clickCount": 1],
            ["type": "pointer", "action": "up", "button": "left", "clickCount": 1],
            ["type": "pencil", "phase": "began", "x": 0.3, "y": 0.3, "pressure": 0.5],
            ["type": "proximity", "entering": true, "x": 0.3, "y": 0.3],
            ["type": "keyboard", "action": "text", "text": "x"],
            ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.returnOrEnter.rawValue],
            ["type": "keyboard", "action": "down", "usage": HIDKeyUsage.keyC.rawValue],
            ["type": "keyboard", "action": "up", "usage": HIDKeyUsage.keyA.rawValue],
            ["type": "keyboard", "action": "modifierDown", "modifier": ControlModifier.command.rawValue],
        ]
        for message in messages { try await receive(sender, message) }
    }
}

/// Records what `InputInjector` would have posted to the HID event tap.
final class RecordingEventSink: SyntheticEventSink, @unchecked Sendable {
    struct Posted: Equatable, CustomStringConvertible {
        /// The modifier flags a test can reason about (the event may also
        /// carry bookkeeping bits such as non-coalesced).
        static let modifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift]

        let type: CGEventType
        let keyCode: Int64?
        /// Shift, Control, Option, Command and Caps Lock, as posted.
        let flags: CGEventFlags
        /// A key-down posted as the key's own repeat.
        let isAutorepeat: Bool

        init(_ event: CGEvent) {
            type = event.type
            flags = event.flags.intersection(Self.modifierMask)
            switch event.type {
            case .keyDown, .keyUp, .flagsChanged:
                keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            default:
                keyCode = nil
                isAutorepeat = false
            }
        }

        var description: String {
            "\(type.rawValue)\(keyCode.map { ":\($0)" } ?? "")\(flags.isEmpty ? "" : " flags=\(flags.rawValue)")"
                + (isAutorepeat ? " repeat" : "")
        }
    }

    private let lock = NSLock()
    private var posted: [Posted] = []

    func post(_ event: CGEvent) {
        let entry = Posted(event)
        lock.withLock { posted.append(entry) }
    }

    /// Everything posted since the last call.
    func take() -> [Posted] {
        lock.withLock {
            defer { posted.removeAll() }
            return posted
        }
    }
}

/// Every control message the sender wrote, as parsed JSON.
private final class SentMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[String: Any]] = []

    var record: @Sendable (String) -> Void {
        { [weak self] json in
            guard let self, let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.lock.withLock { self.messages.append(object) }
        }
    }

    func contains(type: String) -> Bool {
        lock.withLock { messages.contains { $0["type"] as? String == type } }
    }

    func last(type: String) -> [String: Any]? {
        lock.withLock { messages.last { $0["type"] as? String == type } }
    }

    /// The lock screen offer in the latest `macLockState`.
    var lastLockScreen: String? { last(type: MacLockWire.type)?["lockScreen"] as? String }

    func clear() { lock.withLock { messages.removeAll() } }

    var lastAllowInputState: (allowed: Bool?, state: String?)? {
        lock.withLock {
            messages.last { $0["type"] as? String == WireMessage.allowInputState }
                .map { ($0["allowed"] as? Bool, $0["state"] as? String) }
        }
    }
}
