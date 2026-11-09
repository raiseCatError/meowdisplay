import XCTest
import CoreGraphics

/// Fill Window on Mac / Restore Previous Size on Mac through a real `MacSender`'s control gate
/// (the harness from `MacSenderInputRevocationTests`): the device always gets an answer, never an
/// action, without control; and the re-check the Mac runs right before it acts has no side effects.
/// No window is touched: these sessions are never in Window mode.
final class MacSenderWindowFrameTests: XCTestCase {
    private var keychain: TemporaryTestKeychain?
    private var sender: MacSender?
    private let events = RecordingEventSink()
    private let sent = SentControl()

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)   // master on (the default)
        UserDefaults.standard.removeObject(forKey: WindowStreamingPolicy.defaultsKey)
        LoginSessionConsole.shared.set(onConsole: true)
        PrivacyShieldWindows.isUnlocking = false
        let keychain = try TemporaryTestKeychain(prefix: "meowdisplay-window-frame-tests")
        self.keychain = keychain
        let identity = try keychain.makeIdentity()
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: identity.identity),
                                   pinnedPeerSPKI: identity.spki, peerID: Self.peerID)
        // Never dialed: the endpoint only satisfies the initializer.
        sender = MacSender(transport: .tcp(.hostPort(host: "127.0.0.1", port: 9), tls: tls),
                           name: "Window Frame Test Phone", mode: .mirror)
    }

    override func tearDown() {
        sender = nil
        PrivacyShieldWindows.isUnlocking = false
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        keychain?.delete()
        keychain = nil
        super.tearDown()
    }

    func testWithoutControlTheMacAnswersControlAndDoesNothing() async throws {
        let sender = try XCTUnwrap(sender)
        _ = try await admit(sender)
        try await receive(sender, WindowFrameWire.requestMessage(.fill, window: 812, generation: 3, req: 4))
        try await sender.settleForTesting()
        let reply = try XCTUnwrap(sent.last(WindowFrameWire.result))
        XCTAssertEqual(reply["result"] as? String, WindowFrameResult.control.rawValue)
        XCTAssertEqual(reply["window"] as? Int, 812)
        XCTAssertEqual(reply["req"] as? Int, 4)
        XCTAssertEqual(reply["op"] as? String, "fill")
        XCTAssertEqual(events.take(), [], "nothing reaches the Mac")
    }

    func testWithControlOutsideWindowModeTheMacAnswersStale() async throws {
        let sender = try XCTUnwrap(sender)
        let generation = try await admit(sender)
        sender.grantSessionInput(generation: generation)
        try await sender.settleForTesting()
        try await receive(sender, WindowFrameWire.requestMessage(.restore, window: 812, generation: 3, req: 5))
        try await sender.settleForTesting()
        XCTAssertEqual(sent.last(WindowFrameWire.result)?["result"] as? String, WindowFrameResult.stale.rawValue,
                       "no pane shows a window outside Window mode")
        XCTAssertEqual(events.take(), [])
    }

    func testWhileThePrivacyShieldAsksForThePasswordItIsAnsweredNotActedOn() async throws {
        let sender = try XCTUnwrap(sender)
        let generation = try await admit(sender)
        sender.grantSessionInput(generation: generation)
        try await sender.settleForTesting()
        PrivacyShieldWindows.isUnlocking = true
        defer { PrivacyShieldWindows.isUnlocking = false }
        try await receive(sender, WindowFrameWire.requestMessage(.fill, window: 9, generation: 1, req: 6))
        try await sender.settleForTesting()
        XCTAssertEqual(sent.last(WindowFrameWire.result)?["result"] as? String, WindowFrameResult.privacyShield.rawValue)
        XCTAssertFalse(sender.controlStillAllowed(generation: generation), "the re-check refuses meanwhile")
    }

    func testAMalformedRequestAndAReceiverWithoutWindowModeGetNoAnswer() async throws {
        let sender = try XCTUnwrap(sender)
        _ = try await admit(sender)
        try await receive(sender, ["type": WindowFrameWire.request, "op": "maximize", "window": 1, "gen": 1])
        try await sender.settleForTesting()
        XCTAssertNil(sent.last(WindowFrameWire.result))

        // A receiver that never spoke Window mode was never offered it.
        let old = try XCTUnwrap(self.sender)
        _ = try await admit(old, ws: nil)
        try await receive(old, WindowFrameWire.requestMessage(.fill, window: 1, generation: 1, req: 1))
        try await old.settleForTesting()
        XCTAssertNil(sent.last(WindowFrameWire.result))
    }

    /// The check right before the first Accessibility write: true only for the connection that has
    /// the grant now, and it never releases anything itself (unlike the message gate).
    func testTheReCheckFollowsTheGrantAndHasNoSideEffects() async throws {
        let sender = try XCTUnwrap(sender)
        let first = try await admit(sender)
        XCTAssertFalse(sender.controlStillAllowed(generation: first), "admitted is not granted")
        sender.grantSessionInput(generation: first)
        try await sender.settleForTesting()
        XCTAssertTrue(sender.controlStillAllowed(generation: first))
        XCTAssertFalse(sender.controlStillAllowed(generation: first &+ 1), "another connection's request")

        // A key held down, then Allow Input turned off with nothing else run: the re-check says no
        // and releases nothing (the gate and the injector do that, not this check).
        try await receive(sender, ["type": "keyboard", "action": "down", "usage": HIDKeyUsage.keyA.rawValue])
        XCTAssertFalse(events.take().isEmpty)
        UserDefaults.standard.set(false, forKey: InputPolicy.defaultsKey)
        XCTAssertFalse(sender.controlStillAllowed(generation: first))
        XCTAssertEqual(events.take(), [], "no side effects")
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        XCTAssertTrue(sender.controlStillAllowed(generation: first))

        LoginSessionConsole.shared.set(onConsole: false)
        XCTAssertFalse(sender.controlStillAllowed(generation: first), "someone else is using the Mac")
        LoginSessionConsole.shared.set(onConsole: true)

        sender.revokeSessionInput()
        try await sender.settleForTesting()
        XCTAssertFalse(sender.controlStillAllowed(generation: first))

        // A new connection never inherits the old grant.
        let second = try await admit(sender)
        XCTAssertFalse(sender.controlStillAllowed(generation: second))
        XCTAssertFalse(sender.controlStillAllowed(generation: first))
    }

    // MARK: - Helpers

    private static let peerID = "window-frame-test-phone"

    @discardableResult
    private func admit(_ sender: MacSender, ws: Int? = WindowWorkspaceWire.floatVersion) async throws -> UInt64 {
        var hello: [String: Any] = ["type": "hello", "pixelsWide": 2532, "pixelsHigh": 1170, "scale": 3.0,
                                    "device": "iPhone", "id": Self.peerID, "pv": WireProtocol.version]
        if let ws { hello[WindowWorkspaceWire.helloField] = ws }
        return try await sender.admitConnectionForTesting(
            helloJSON: try JSONSerialization.data(withJSONObject: hello),
            pinnedSPKI: Data([0x30, 0x59]), eventSink: events, sent: sent.record)
    }

    private func receive(_ sender: MacSender, _ message: [String: Any]) async throws {
        try await sender.receiveControlForTesting(try JSONSerialization.data(withJSONObject: message))
    }
}

/// Every control message the sender wrote, as parsed JSON.
private final class SentControl: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [[String: Any]] = []

    var record: @Sendable (String) -> Void {
        { [weak self] json in
            guard let self, let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.lock.withLock { self.messages.append(object) }
        }
    }

    func last(_ type: String) -> [String: Any]? {
        lock.withLock { messages.last { $0["type"] as? String == type } }
    }
}
