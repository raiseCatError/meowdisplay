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
        // Never dialed: the endpoint only satisfies the initializer.
        sender = MacSender(transport: .tcp(.hostPort(host: "127.0.0.1", port: 9), tls: tls),
                           name: "Revocation Test Phone", mode: .mirror)
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
        let type: CGEventType
        let keyCode: Int64?

        init(_ event: CGEvent) {
            type = event.type
            switch event.type {
            case .keyDown, .keyUp, .flagsChanged:
                keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            default:
                keyCode = nil
            }
        }

        var description: String { "\(type.rawValue)\(keyCode.map { ":\($0)" } ?? "")" }
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

    var lastAllowInputState: (allowed: Bool?, state: String?)? {
        lock.withLock {
            messages.last { $0["type"] as? String == WireMessage.allowInputState }
                .map { ($0["allowed"] as? Bool, $0["state"] as? String) }
        }
    }
}
