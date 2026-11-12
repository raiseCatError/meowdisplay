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
        if show, let view = sent.last(type: MacLockWire.type)?[LockScreenWire.viewKey] as? Int { shownView = view }
    }

    /// The lock screen view the Mac last announced (`macLockState` `lockScreenView`): what a
    /// receiver showing it tags its input with. 0 (no view) until one is shown.
    private var shownView = 0

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
        try await receive(sender, ["type": "pointer", "lockScreen": true, "lockScreenView": shownView, "action": "move", "x": 0.5, "y": 0.5])
        try await receive(sender, ["type": "pointer", "lockScreen": true, "lockScreenView": shownView, "action": "down", "button": "left", "clickCount": 1])
        try await receive(sender, ["type": "pointer", "lockScreen": true, "lockScreenView": shownView, "action": "up", "button": "left", "clickCount": 1])
        try await receive(sender, ["type": "keyboard", "lockScreen": true, "lockScreenView": shownView, "action": "press", "usage": HIDKeyUsage.keyP.rawValue, "modifiers": ["shift"]])
        try await receive(sender, ["type": "keyboard", "lockScreen": true, "lockScreenView": shownView, "action": "press", "usage": HIDKeyUsage.deleteOrBackspace.rawValue])
        try await receive(sender, ["type": "keyboard", "lockScreen": true, "lockScreenView": shownView, "action": "press", "usage": HIDKeyUsage.returnOrEnter.rawValue])
        let allowed = events.take()
        XCTAssertTrue(allowed.contains { $0.type == .leftMouseDown } && allowed.contains { $0.type == .leftMouseUp }, "\(allowed)")
        for usage in [HIDKeyUsage.keyP, .deleteOrBackspace, .returnOrEnter] {
            XCTAssertTrue(allowed.contains { $0.type == .keyDown && $0.keyCode == Int64(usage.keyCode) }, "\(usage)")
        }

        let refused: [[String: Any]] = [
            ["type": "keyboard", "lockScreen": true, "lockScreenView": shownView, "action": "press", "usage": HIDKeyUsage.keyQ.rawValue, "modifiers": ["command"]],
            ["type": "keyboard", "lockScreen": true, "lockScreenView": shownView, "action": "press", "usage": HIDKeyUsage.keyA.rawValue, "modifiers": ["control"]],
            ["type": "keyboard", "lockScreen": true, "lockScreenView": shownView, "action": "press", "usage": HIDKeyUsage.f1.rawValue],
            ["type": "keyboard", "lockScreen": true, "lockScreenView": shownView, "action": "modifierDown", "modifier": ControlModifier.command.rawValue],
            ["type": "pointer", "lockScreen": true, "lockScreenView": shownView, "action": "down", "button": "right", "clickCount": 1],
            ["type": "scroll", "dx": 0.0, "dy": 120.0],
            ["type": "pencil", "phase": "began", "x": 0.3, "y": 0.3, "pressure": 0.5],
            ["type": "keyboard", "lockScreen": true, "lockScreenView": shownView, "action": "text", "text": "a\nb"],
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

    private func typed(_ action: String, _ usage: HIDKeyUsage? = nil, text: String? = nil, tagged: Bool = true) -> [String: Any] {
        var m: [String: Any] = ["type": "keyboard", "action": action]
        if let usage { m["usage"] = usage.rawValue }
        if let text { m["text"] = text }
        if tagged { m[LockScreenWire.inputTag] = true; m[LockScreenWire.viewKey] = shownView }
        return m
    }

    private var refusals: [(count: Int, reason: String)] {
        sent.all(type: LockScreenWire.inputRefused).compactMap { m in
            (m["count"] as? Int).map { ($0, m["reason"] as? String ?? "") }
        }
    }

    private var refusedClicks: [(clicks: Int, reason: String)] {
        sent.all(type: LockScreenWire.inputRefused).compactMap { m in
            guard let clicks = m["clicks"] as? Int, clicks > 0 else { return nil }
            return (clicks, m["reason"] as? String ?? "")
        }
    }

    private func touch(_ phase: String, tagged: Bool = true) -> [String: Any] {
        var m: [String: Any] = ["type": "touch", "phase": phase, "x": 0.5, "y": 0.5]
        if tagged { m[LockScreenWire.inputTag] = true; m[LockScreenWire.viewKey] = shownView }
        return m
    }

    private func pointer(_ action: String, tagged: Bool = true) -> [String: Any] {
        var m: [String: Any] = ["type": "pointer", "action": action, "button": "left", "clickCount": 1, "x": 0.5, "y": 0.5]
        if tagged { m[LockScreenWire.inputTag] = true; m[LockScreenWire.viewKey] = shownView }
        return m
    }

    private let pressTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown]
    private let moveTypes: [CGEventType] = [.mouseMoved, .leftMouseDragged]

    /// Unlock race with clicks: a tagged press (touch or pointer) still in flight when the Mac
    /// unlocks is never posted to the desktop and is reported as a click; its release posts
    /// nothing (no press was posted); tagged moves after the view ended are dropped quietly.
    func testUnlockRaceRefusesTaggedPressesAndReportsClicks() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        try await showLockScreen(sender)
        privacyGate.set(.unlocked)
        sender.macPrivacyChanged(.unlocked)
        try await sender.settleForTesting()
        _ = events.take()
        sent.clear()
        try await receive(sender, touch("began"))
        try await receive(sender, touch("moved"))
        try await receive(sender, pointer("down"))
        try await receive(sender, pointer("move"))
        XCTAssertEqual(events.take().filter { pressTypes.contains($0.type) || moveTypes.contains($0.type) }, [],
                       "nothing pressed or moved on the desktop")
        XCTAssertEqual(refusedClicks.map(\.reason), ["unlocked", "unlocked"])
        XCTAssertEqual(refusedClicks.map(\.clicks).reduce(0, +), 2)
        XCTAssertEqual(sent.all(type: LockScreenWire.inputRefused).count, 2, "moves aren't reported")
        try await receive(sender, touch("ended"))
        try await receive(sender, pointer("up"))
        XCTAssertEqual(events.take().filter { $0.type == .leftMouseUp }, [], "no press was posted: its release posts nothing")
        // Ordinary (untagged) clicks after the unlock go at once.
        try await receive(sender, pointer("down", tagged: false))
        try await receive(sender, pointer("up", tagged: false))
        let after = events.take()
        XCTAssertTrue(after.contains { $0.type == .leftMouseDown } && after.contains { $0.type == .leftMouseUp }, "\(after)")
    }

    /// A press posted on the lock screen whose release arrives after the unlock: the button is
    /// never left held (released when the view ends, and the late release is safe).
    func testAPressPostedBeforeTheUnlockIsAlwaysReleased() async throws {
        for useTouch in [false, true] {
            setUpSender()
            let sender = try XCTUnwrap(sender)
            try await lockWithPermit(sender)
            try await showLockScreen(sender)
            try await receive(sender, useTouch ? touch("began") : pointer("down"))
            XCTAssertTrue(events.take().contains { $0.type == .leftMouseDown }, "pressed on the lock screen (touch \(useTouch))")
            privacyGate.set(.unlocked)
            sender.macPrivacyChanged(.unlocked)
            try await sender.settleForTesting()
            try await receive(sender, useTouch ? touch("ended") : pointer("up"))
            let released = events.take()
            XCTAssertEqual(released.filter { $0.type == .leftMouseUp }.count, 1, "released exactly once (touch \(useTouch)): \(released)")
            XCTAssertFalse(released.contains { pressTypes.contains($0.type) })
            XCTAssertTrue(refusedClicks.isEmpty, "a release is never refused")
        }
    }

    /// A tagged press from a connection that never showed the view (forged), and an untagged
    /// press while the view is shown: refused, never posted, reported.
    func testForgedAndUntaggedPressesAreRefusedAndReported() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        sent.clear()
        try await receive(sender, pointer("down"))
        try await receive(sender, touch("began"))
        XCTAssertEqual(events.take().filter { pressTypes.contains($0.type) }, [])
        XCTAssertEqual(refusedClicks.map(\.reason), ["notShown", "notShown"])

        try await showLockScreen(sender)
        sent.clear()
        try await receive(sender, pointer("down", tagged: false))
        try await receive(sender, touch("began", tagged: false))
        try await receive(sender, pointer("move", tagged: false))
        XCTAssertEqual(events.take().filter { pressTypes.contains($0.type) || moveTypes.contains($0.type) }, [],
                       "untagged while shown")
        XCTAssertEqual(refusedClicks.map(\.reason), ["untagged", "untagged"])
        try await receive(sender, pointer("down"))
        XCTAssertTrue(events.take().contains { $0.type == .leftMouseDown }, "tagged while shown")
        try await receive(sender, pointer("up"))
    }

    /// F3 / explicit tags: unlocked (at the Mac, Touch ID, Watch) while the receiver types into the
    /// view. Keys and text typed for the lock screen and still in flight never land in the app now
    /// in front; the receiver is told how many didn't go. Its ordinary (untagged) typing after the
    /// unlock is delivered at once: no hold.
    func testUnlockRaceRefusesTaggedTypingAndReportsItButNotOrdinaryTyping() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        try await showLockScreen(sender)
        try await receive(sender, typed("press", .keyA))
        XCTAssertTrue(events.take().contains { $0.type == .keyDown }, "typed on the lock screen")
        sent.clear()
        privacyGate.set(.unlocked)
        sender.macPrivacyChanged(.unlocked)
        try await sender.settleForTesting()
        XCTAssertTrue(sent.contains(type: WireMessage.inputReset), "the receiver resets its input")
        _ = events.take()
        try await receive(sender, typed("press", .keyB))
        try await receive(sender, typed("text", text: "fake-pass-123"))
        try await receive(sender, typed("down", .keyC))
        try await receive(sender, typed("press", .returnOrEnter))
        XCTAssertEqual(events.take().filter { $0.type != .keyUp && $0.type != .flagsChanged }, [],
                       "nothing typed for the lock screen reaches the app in front")
        XCTAssertEqual(refusals.map(\.reason), ["unlocked", "unlocked", "unlocked", "unlocked"])
        XCTAssertEqual(refusals.map(\.count).reduce(0, +), 1 + 13 + 1 + 1, "every keystroke counted")
        try await receive(sender, typed("up", .keyC))   // a release always goes
        sent.clear()
        try await receive(sender, typed("press", .keyD, tagged: false))
        XCTAssertTrue(events.take().contains { $0.type == .keyDown && $0.keyCode == Int64(HIDKeyUsage.keyD.keyCode) },
                      "untagged after the unlock: ordinary input, no hold")
        XCTAssertTrue(refusals.isEmpty)
    }

    /// Tagged typing while this connection doesn't show the lock screen (not asked, hidden, or a
    /// forged tag from a device that never had the view) is refused and reported; untagged typing
    /// while it is shown is refused and reported too.
    func testTagsAreHonouredOnlyWithALiveView() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        sent.clear()
        try await receive(sender, typed("text", text: "fake-pass-123"))
        try await receive(sender, typed("press", .keyA))
        XCTAssertEqual(events.take().filter { $0.type == .keyDown }, [], "locked, not shown")
        XCTAssertEqual(refusals.map(\.reason), ["notShown", "notShown"])

        try await showLockScreen(sender)
        sent.clear()
        try await receive(sender, typed("press", .keyA, tagged: false))
        try await receive(sender, typed("text", text: "x", tagged: false))
        XCTAssertEqual(events.take().filter { $0.type == .keyDown }, [], "untagged while shown")
        XCTAssertEqual(refusals.map(\.reason), ["untagged", "untagged"])
        try await receive(sender, typed("press", .keyA))
        XCTAssertTrue(events.take().contains { $0.type == .keyDown }, "tagged while shown")

        try await showLockScreen(sender, false)
        sent.clear()
        try await receive(sender, typed("press", .keyA))
        XCTAssertEqual(events.take().filter { $0.type == .keyDown }, [], "hidden")
        XCTAssertEqual(refusals.map(\.reason), ["notShown"])

        // Another device's connection, never shown the view, forging the tag: refused, reported.
        setUpSender()
        let forger = try XCTUnwrap(self.sender)
        try await lockWithPermit(forger, policy: .ask, grant: true)
        sent.clear()
        try await receive(forger, typed("press", .keyA))
        try await receive(forger, typed("text", text: "fake-pass-123"))
        XCTAssertEqual(events.take().filter { $0.type == .keyDown }, [])
        XCTAssertEqual(refusals.map(\.reason), ["notShown", "notShown"])
    }

    /// An Ask device's Mirror connection after this Mac's own switch: offered `needsControl` only
    /// while the app vouches for a pre-lock grant (the handoff); never otherwise.
    func testAnAskDeviceIsOfferedControlOnlyWithAHandoff() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender, policy: .ask, grant: false)
        XCTAssertEqual(sent.lastLockScreen, "controlBeforeLock")
        sender.setLockScreenPermit(policy: .ask, allowed: true, handoff: true)
        try await sender.settleForTesting()
        XCTAssertEqual(sent.lastLockScreen, "needsControl")
        try await showLockScreen(sender)
        XCTAssertNotEqual(sent.lastLockScreen, "active", "nothing before control")
        sender.setLockScreenPermit(policy: .ask, allowed: true, handoff: false)   // spent or expired
        try await sender.settleForTesting()
        XCTAssertEqual(sent.lastLockScreen, "controlBeforeLock")
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
            try await receive(sender, ["type": "pointer", "lockScreen": true, "lockScreenView": shownView, "action": "down", "button": "left", "clickCount": 1])
            try await receive(sender, ["type": "keyboard", "lockScreen": true, "lockScreenView": shownView, "action": "press", "usage": HIDKeyUsage.keyA.rawValue])
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

    /// #255: the view may drive capture recovery only while it is live, and only once capture
    /// was established for the session. Before that, Mirror startup (waiting for a display, or its
    /// Extend offer) owns the first start. Every way the view ends stops it at once.
    func testTheViewDrivesCaptureRecoveryOnlyWhileLiveAndAfterCaptureStarted() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        try await showLockScreen(sender)
        XCTAssertEqual(sent.lastLockScreen, "active")
        var needs = try await sender.lockScreenViewNeedsCaptureForTesting
        XCTAssertFalse(needs, "no capture established yet: startup's start, not the view's")

        // The main display, so the view's own move-to-main rebuild stays out of this test.
        try await sender.setCaptureDisplayForTesting(CGMainDisplayID())
        needs = try await sender.lockScreenViewNeedsCaptureForTesting
        XCTAssertTrue(needs)

        try await showLockScreen(sender, false)
        needs = try await sender.lockScreenViewNeedsCaptureForTesting
        XCTAssertFalse(needs, "hidden: recovery for it stops")

        try await sender.resetLockScreenShowLimitForTesting()
        try await showLockScreen(sender)
        needs = try await sender.lockScreenViewNeedsCaptureForTesting
        XCTAssertTrue(needs)
        try await sender.setLockScreenPermitWithoutReviewForTesting(policy: .neverAllow, allowed: false)
        sender.setLockScreenPermit(policy: .neverAllow, allowed: false)
        try await sender.settleForTesting()
        needs = try await sender.lockScreenViewNeedsCaptureForTesting
        XCTAssertFalse(needs, "revoked: recovery for it stops")

        sender.setLockScreenPermit(policy: .alwaysAllow, allowed: true)
        try await sender.resetLockScreenShowLimitForTesting()
        try await showLockScreen(sender)
        needs = try await sender.lockScreenViewNeedsCaptureForTesting
        XCTAssertTrue(needs)
        privacyGate.set(.switchedOut)
        sender.macPrivacyChanged(.switchedOut)
        try await sender.settleForTesting()
        needs = try await sender.lockScreenViewNeedsCaptureForTesting
        XCTAssertFalse(needs, "another user on the console: never")

        privacyGate.set(.locked)
        sender.macPrivacyChanged(.locked)
        try await sender.resetLockScreenShowLimitForTesting()
        try await showLockScreen(sender)
        try await sender.loseConnectionForTesting()
        needs = try await sender.lockScreenViewNeedsCaptureForTesting
        XCTAssertFalse(needs, "connection gone: never")
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
        try await receive(sender, ["type": "pointer", "lockScreen": true, "lockScreenView": shownView, "action": "down", "button": "left", "clickCount": 1])
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
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyC.rawValue, "modifiers": ["command"]])
        XCTAssertTrue(events.take().contains { $0.type == .keyDown && $0.keyCode == Int64(HIDKeyUsage.keyC.keyCode) },
                      "unlocked: normal input, shortcuts included")
    }

    // MARK: - Lock episodes (PROTOCOL.md 6.19): every input family, both sides of each boundary

    private func tagged(_ message: [String: Any], view: Int?) -> [String: Any] {
        var m = message
        m[LockScreenWire.inputTag] = true
        if let view { m[LockScreenWire.viewKey] = view }
        return m
    }

    private func unlock(_ sender: MacSender) async throws {
        privacyGate.set(.unlocked)
        sender.macPrivacyChanged(.unlocked)
        try await sender.settleForTesting()
    }

    private func key(_ action: String, _ usage: HIDKeyUsage) -> [String: Any] {
        ["type": "keyboard", "action": action, "usage": usage.rawValue]
    }

    private func modifier(_ down: Bool, _ name: ControlModifier) -> [String: Any] {
        ["type": "keyboard", "action": down ? "modifierDown" : "modifierUp", "modifier": name.rawValue]
    }

    /// Scroll, Pencil (with hover and its end), proximity in and out, a native gesture and a
    /// Smart Touch probe: never lock screen input. (`gesture` is checked by the same gate but
    /// not sent here: delivered by mistake, it would really run on this Mac.)
    private let otherFamilies: [[String: Any]] = [
        ["type": "scroll", "dx": 0.0, "dy": 120.0],
        ["type": "scroll", "dx": 30.0, "dy": 0.0],
        ["type": "pencil", "phase": "hover", "x": 0.3, "y": 0.3, "pressure": 0.0],
        ["type": "pencil", "phase": "down", "x": 0.3, "y": 0.3, "pressure": 0.5],
        ["type": "pencil", "phase": "move", "x": 0.35, "y": 0.35, "pressure": 0.5],
        ["type": "pencil", "phase": "up", "x": 0.35, "y": 0.35, "pressure": 0.0],
        ["type": "proximity", "entering": true, "x": 0.3, "y": 0.3],
        ["type": "proximity", "entering": false, "x": 0.3, "y": 0.3],
        ["type": WireMessage.nativeAppGesture, "kind": "magnify", "phase": "began", "delta": 0.1],
        ["type": WireMessage.nativeAppGesture, "kind": "magnify", "phase": "ended", "delta": 0.0],
    ]

    /// The moment of unlock, with input in flight on both sides of it. Before: scroll, Pencil,
    /// proximity and gestures never reach the lock screen, tagged or not. After: nothing made
    /// while the device saw the Mac locked (tagged with the view, or without one) acts on the
    /// desktop, whatever its family; presses and keystrokes are reported. Untagged input after
    /// the unlock is ordinary input at once (no hold).
    func testEveryInputFamilyInFlightAcrossTheUnlockStaysOnItsSide() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        try await showLockScreen(sender)
        let view = shownView
        XCTAssertGreaterThan(view, 1, "the view is numbered")
        _ = events.take()
        for message in otherFamilies {
            try await receive(sender, message)
            try await receive(sender, tagged(message, view: view))
        }
        try await receive(sender, tagged(["type": WireMessage.smartTouchProbe, "id": 9, "x": 0.5, "y": 0.5], view: view))
        XCTAssertEqual(events.take(), [], "nothing but touch, clicks and typing reaches the lock screen")
        XCTAssertEqual(sent.last(type: WireMessage.smartTouchProbeResult)?["scrollable"] as? Bool, false, "a probe is still answered")

        try await receive(sender, tagged(key("press", .keyA), view: view))
        XCTAssertTrue(events.take().contains { $0.type == .keyDown }, "the view's own typing goes")

        try await unlock(sender)
        _ = events.take()
        sent.clear()
        let lockScreenFamilies: [[String: Any]] = [
            touch("began", tagged: false), touch("moved", tagged: false),
            pointer("down", tagged: false), pointer("move", tagged: false),
            ["type": "pointer", "action": "moveRelative", "dx": 4.0, "dy": 4.0],
            key("press", .returnOrEnter), key("down", .keyB), ["type": "keyboard", "action": "text", "text": "fake-pass-123"],
            modifier(true, .shift),
        ]
        for message in otherFamilies + lockScreenFamilies {
            try await receive(sender, tagged(message, view: view))
            try await receive(sender, tagged(message, view: nil))   // typed while locked, not shown
        }
        XCTAssertEqual(events.take(), [], "nothing from the lock episode acts on the desktop")
        XCTAssertEqual(Set(refusals.map(\.reason)), ["unlocked"])
        XCTAssertEqual(refusals.map(\.count).reduce(0, +), 2 * (1 + 1 + 13), "every keystroke counted, both tags")
        XCTAssertEqual(refusedClicks.map(\.clicks).reduce(0, +), 2 * 2, "every press counted, both tags")

        try await receive(sender, ["type": "scroll", "dx": 0.0, "dy": 120.0])
        try await receive(sender, ["type": "pencil", "phase": "down", "x": 0.3, "y": 0.3, "pressure": 0.5])
        try await receive(sender, ["type": "pencil", "phase": "up", "x": 0.3, "y": 0.3, "pressure": 0.0])
        let ordinary = events.take()
        XCTAssertTrue(ordinary.contains { $0.type == .scrollWheel }, "untagged after the unlock: ordinary, no hold \(ordinary)")
        XCTAssertTrue(ordinary.contains { $0.type == .leftMouseDown }, "\(ordinary)")
    }

    /// A drag or a long press begun on the lock screen whose rest arrives after the unlock: the
    /// button is released exactly once (when the view ends, click count 0), and the rest of the
    /// gesture (moves, its release) does nothing on the desktop, never a drag or a click there.
    func testADragOrLongPressBegunOnTheLockScreenNeverContinuesOnTheDesktop() async throws {
        for (useTouch, moves) in [(true, false), (true, true), (false, true), (false, false)] {
            let label = "touch \(useTouch), moves \(moves)"
            setUpSender()
            let sender = try XCTUnwrap(sender)
            try await lockWithPermit(sender)
            try await showLockScreen(sender)
            let view = shownView
            _ = events.take()
            try await receive(sender, tagged(useTouch ? touch("began", tagged: false) : pointer("down", tagged: false), view: view))
            if moves { try await receive(sender, tagged(useTouch ? touch("moved", tagged: false) : pointer("move", tagged: false), view: view)) }
            XCTAssertTrue(events.take().contains { $0.type == .leftMouseDown }, label)
            try await unlock(sender)
            XCTAssertEqual(events.take().filter { $0.type == .leftMouseUp }.count, 1, "\(label): released when the view ended")
            for _ in 0..<3 {
                try await receive(sender, tagged(useTouch ? touch("moved", tagged: false) : pointer("move", tagged: false), view: view))
            }
            try await receive(sender, tagged(useTouch ? touch("ended", tagged: false) : pointer("up", tagged: false), view: view))
            XCTAssertEqual(events.take(), [], "\(label): the rest of the gesture does nothing on the desktop")
            // The device's next, untagged stream is its own: a hover moves the pointer, no drag.
            try await receive(sender, useTouch ? touch("moved", tagged: false) : pointer("move", tagged: false))
            let after = events.take()
            XCTAssertFalse(after.contains { [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains($0.type) }, "\(label): \(after)")
        }
    }

    /// Modifiers and keys held across a boundary, both ways. From the lock screen into the
    /// desktop: released at the unlock, a late release does nothing, and the next desktop key
    /// carries no leftover Shift. From the desktop into the lock screen (even when the view starts
    /// before the lock is announced): released when the view starts; the login window never sees
    /// a desktop Command.
    func testModifiersAndKeysHeldAcrossABoundaryNeverCarryOver() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        try await showLockScreen(sender)
        let view = shownView
        let shift = Int64(ControlModifier.shift.keyCode)
        _ = events.take()
        try await receive(sender, tagged(modifier(true, .shift), view: view))
        try await receive(sender, tagged(key("down", .keyA), view: view))
        XCTAssertTrue(events.take().contains { $0.keyCode == shift }, "Shift held on the lock screen")
        try await unlock(sender)
        let released = events.take()
        XCTAssertTrue(released.contains { $0.keyCode == shift } && released.contains { $0.type == .keyUp && $0.keyCode == Int64(HIDKeyUsage.keyA.keyCode) },
                      "released at the unlock: \(released)")
        XCTAssertFalse(released.contains { $0.type == .keyDown }, "\(released)")
        try await receive(sender, tagged(modifier(false, .shift), view: view))
        try await receive(sender, tagged(key("up", .keyA), view: view))
        XCTAssertEqual(events.take(), [], "a late release releases nothing twice")
        try await receive(sender, key("press", .keyB))
        let typed = events.take().filter { $0.type == .keyDown }
        XCTAssertEqual(typed.count, 1)
        XCTAssertFalse(typed.first?.flags.contains(.maskShift) ?? true, "no Shift left over on the desktop")

        // Desktop into the lock screen, the view starting before the lock is announced.
        setUpSender()
        let next = try XCTUnwrap(self.sender)
        try await admitAndGrant(next)
        try await receive(next, modifier(true, .command))
        try await receive(next, key("down", .keyC))
        let command = Int64(ControlModifier.command.keyCode)
        XCTAssertTrue(events.take().contains { $0.keyCode == command })
        next.setLockScreenPermit(policy: .alwaysAllow, allowed: true)
        privacyGate.set(.locked)   // `macPrivacyChanged` hasn't run yet
        try await next.settleForTesting()
        try await showLockScreen(next)
        XCTAssertEqual(sent.lastLockScreen, "active")
        let atStart = events.take()
        XCTAssertTrue(atStart.contains { $0.keyCode == command } && atStart.contains { $0.type == .keyUp && $0.keyCode == Int64(HIDKeyUsage.keyC.keyCode) },
                      "desktop keys released when the view starts: \(atStart)")
        try await receive(next, tagged(key("press", .keyA), view: shownView))
        let onLockScreen = events.take().filter { $0.type == .keyDown }
        XCTAssertEqual(onLockScreen.count, 1)
        XCTAssertFalse(onLockScreen.first?.flags.contains(.maskCommand) ?? true, "the login window never sees a desktop Command")
        try await receive(next, modifier(false, .command))
        try await receive(next, key("up", .keyC))
        XCTAssertEqual(events.take(), [], "the desktop's late releases do nothing on the lock screen")
    }

    /// Disconnect and reconnect mid-episode: the old connection's view is gone with it. Its input,
    /// still in flight or replayed on the new connection, is refused; a fresh view on the new
    /// connection gets a new number, and only that one goes.
    func testAReconnectMidEpisodeRefusesTheOldConnectionsView() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        try await showLockScreen(sender)
        let old = shownView
        try await receive(sender, tagged(key("down", .keyA), view: old))
        XCTAssertTrue(events.take().contains { $0.type == .keyDown })

        let generation = try await admit(sender)   // a new connection
        XCTAssertTrue(events.take().contains { $0.type == .keyUp }, "the held key is released with the connection")
        sender.grantSessionInput(generation: generation)
        sender.setLockScreenPermit(policy: .alwaysAllow, allowed: true)
        try await sender.settleForTesting()
        sent.clear()
        try await receive(sender, tagged(key("press", .keyB), view: old))
        try await receive(sender, tagged(touch("began", tagged: false), view: old))
        XCTAssertEqual(events.take(), [], "the old connection's view, on the new one")
        XCTAssertEqual(Set(refusals.map(\.reason)), ["notShown"])

        try await showLockScreen(sender)
        let fresh = shownView
        XCTAssertNotEqual(fresh, old)
        try await receive(sender, tagged(key("press", .keyB), view: old))
        try await receive(sender, tagged(key("up", .keyA), view: old))
        XCTAssertEqual(events.take(), [], "still refused once a new view is live")
        try await receive(sender, tagged(key("press", .keyB), view: fresh))
        XCTAssertTrue(events.take().contains { $0.type == .keyDown }, "the new view's own input")
    }

    /// Control revoked mid-episode: held input is released at once, nothing tagged for that view
    /// goes again, even after control comes back and a new view starts.
    func testRevocationMidEpisodeEndsTheViewForGood() async throws {
        let sender = try XCTUnwrap(sender)
        let generation = try await lockWithPermit(sender)
        try await showLockScreen(sender)
        let old = shownView
        try await receive(sender, tagged(modifier(true, .shift), view: old))
        try await receive(sender, tagged(touch("began", tagged: false), view: old))
        _ = events.take()
        sender.revokeSessionInput()
        try await sender.settleForTesting()
        let released = events.take()
        XCTAssertTrue(released.contains { $0.type == .leftMouseUp }, "\(released)")
        XCTAssertTrue(released.contains { $0.keyCode == Int64(ControlModifier.shift.keyCode) }, "\(released)")
        try await receive(sender, tagged(key("press", .keyA), view: old))
        XCTAssertEqual(events.take(), [])

        sender.grantSessionInput(generation: generation)
        try await sender.settleForTesting()
        try await sender.resetLockScreenShowLimitForTesting()
        try await showLockScreen(sender)
        XCTAssertNotEqual(shownView, old)
        sent.clear()
        try await receive(sender, tagged(key("press", .keyA), view: old))
        try await receive(sender, tagged(touch("ended", tagged: false), view: old))
        XCTAssertEqual(events.take(), [], "the revoked view's input, after control came back")
        XCTAssertEqual(refusals.map(\.reason), ["notShown"])
        try await receive(sender, tagged(key("press", .keyA), view: shownView))
        XCTAssertTrue(events.take().contains { $0.type == .keyDown })
    }

    /// Two devices, each showing the lock screen on its own connection: neither's tag works on
    /// the other's connection.
    func testTwoDevicesCantUseEachOthersView() async throws {
        guard let tls else { return XCTFail("no TLS") }
        let first = try XCTUnwrap(sender)
        try await lockWithPermit(first)
        try await showLockScreen(first)
        let firstView = shownView

        let otherEvents = RecordingEventSink()
        let otherSent = SentMessages()
        let second = MacSender(transport: .tcp(.hostPort(host: "127.0.0.1", port: 9), tls: tls),
                               name: "Second Phone", mode: .mirror)
        second.privacyGate = privacyGate
        let generation = try await admit(second, events: otherEvents, sent: otherSent)
        second.grantSessionInput(generation: generation)
        second.setLockScreenPermit(policy: .alwaysAllow, allowed: true)
        try await second.settleForTesting()
        try await receive(second, LockScreenWire.request(show: true))
        try await second.settleForTesting()
        let secondView = try XCTUnwrap(otherSent.last(type: MacLockWire.type)?[LockScreenWire.viewKey] as? Int)
        XCTAssertNotEqual(firstView, secondView)
        _ = events.take()
        _ = otherEvents.take()
        sent.clear()

        try await receive(second, tagged(key("press", .keyA), view: firstView))
        try await receive(second, tagged(touch("began", tagged: false), view: firstView))
        XCTAssertEqual(otherEvents.take(), [], "the first device's view on the second's connection")
        XCTAssertEqual(otherSent.all(type: LockScreenWire.inputRefused).compactMap { $0["reason"] as? String }, ["notShown", "notShown"])
        try await receive(first, tagged(key("press", .keyA), view: secondView))
        XCTAssertEqual(events.take(), [], "and the other way round")
        try await receive(first, tagged(key("press", .keyA), view: firstView))
        XCTAssertTrue(events.take().contains { $0.type == .keyDown })
        try await receive(second, tagged(key("press", .keyA), view: secondView))
        XCTAssertTrue(otherEvents.take().contains { $0.type == .keyDown })
    }

    /// Retransmitted or reordered input from an earlier view (hidden, then shown again on the same
    /// connection) is refused; bare and malformed tags (an older build's `"lockScreen":true`, a
    /// boolean or string view) never name a view; a release from an earlier view never releases
    /// what the live one holds.
    func testInputFromAnEarlierViewAndMalformedTagsAreRefused() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        try await showLockScreen(sender)
        let first = shownView
        try await showLockScreen(sender, false)
        try await sender.resetLockScreenShowLimitForTesting()
        try await showLockScreen(sender)
        let second = shownView
        XCTAssertNotEqual(first, second)
        _ = events.take()
        sent.clear()
        let press = key("press", .keyA)
        try await receive(sender, tagged(press, view: first))
        var bare = press
        bare[LockScreenWire.inputTag] = true
        try await receive(sender, bare)
        var boolView = press
        boolView[LockScreenWire.viewKey] = true
        try await receive(sender, boolView)
        var stringView = press
        stringView[LockScreenWire.viewKey] = "\(second)"
        try await receive(sender, stringView)
        var negative = press
        negative[LockScreenWire.viewKey] = -second
        try await receive(sender, negative)
        XCTAssertEqual(events.take(), [], "none of these names the live view")
        XCTAssertEqual(refusals.map(\.reason), Array(repeating: "notShown", count: 5))

        try await receive(sender, tagged(key("down", .keyC), view: second))
        _ = events.take()
        try await receive(sender, tagged(key("up", .keyC), view: first))
        XCTAssertEqual(events.take(), [], "an earlier view's release releases nothing of this one")
        try await receive(sender, tagged(key("up", .keyC), view: second))
        XCTAssertTrue(events.take().contains { $0.type == .keyUp })
    }

    /// The log says why input was refused, once per view and once between views: never how many
    /// keystrokes or clicks, or each one's moment.
    func testRefusalsAreLoggedOncePerViewWithoutCounts() async throws {
        let sender = try XCTUnwrap(sender)
        try await lockWithPermit(sender)
        let start = try await sender.lockScreenRefusalLogCountForTesting
        for _ in 0..<5 { try await receive(sender, typed("press", .keyA)) }
        var logged = try await sender.lockScreenRefusalLogCountForTesting
        XCTAssertEqual(logged - start, 1, "five refusals before any view: one line")
        try await showLockScreen(sender)
        for _ in 0..<5 { try await receive(sender, typed("press", .keyA, tagged: false)) }
        logged = try await sender.lockScreenRefusalLogCountForTesting
        XCTAssertEqual(logged - start, 2, "five during the view: one more")
        try await unlock(sender)
        for _ in 0..<5 { try await receive(sender, typed("text", text: "fake-pass-123")) }
        logged = try await sender.lockScreenRefusalLogCountForTesting
        XCTAssertEqual(logged - start, 3, "five after it ended: one more")
        XCTAssertEqual(refusals.count, 15, "the device is still told about each")
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
    private func admit(_ sender: MacSender, events: RecordingEventSink? = nil, sent: SentMessages? = nil) async throws -> UInt64 {
        let hello: [String: Any] = ["type": "hello", "pixelsWide": 2532, "pixelsHigh": 1170, "scale": 3.0,
                                    "device": "iPhone", "id": Self.peerID, "pv": WireProtocol.version]
        return try await sender.admitConnectionForTesting(
            helloJSON: try JSONSerialization.data(withJSONObject: hello),
            pinnedSPKI: Data([0x30, 0x59]), eventSink: events ?? self.events, sent: (sent ?? self.sent).record)
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

    func all(type: String) -> [[String: Any]] {
        lock.withLock { messages.filter { $0["type"] as? String == type } }
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
