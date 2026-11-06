import AVFoundation
import CoreGraphics
import Network
import XCTest

/// Exact key modifiers (welcome feature `exactKeyModifiers`): the arrow
/// keypad's own ⇧ ⌥ ⌘ reach the Mac as exactly what the key names, never
/// mixed with the modifiers the tray holds down, while a key without the
/// field still carries every held modifier (the Mac Receiver relies on it).
///
/// The end-to-end cases drive a real `MacSender` through its own control
/// gate, grant and `InputInjector`, as `MacSenderInputRevocationTests` does:
/// only the network and the HID event tap are stood in for.
final class ExactKeyModifiersTests: XCTestCase {

    // MARK: - Flag composition

    func testWithoutExactTheHeldModifiersAreAdded() {
        XCTAssertEqual(KeyEventFlags.compose(named: ["shift"], held: .maskCommand, exact: false),
                       [.maskShift, .maskCommand])
        XCTAssertEqual(KeyEventFlags.compose(named: [], held: .maskCommand, exact: false), .maskCommand)
    }

    func testExactIsOnlyTheKeysOwnModifiers() {
        XCTAssertEqual(KeyEventFlags.compose(named: ["shift"], held: .maskCommand, exact: true), .maskShift)
        XCTAssertEqual(KeyEventFlags.compose(named: [], held: [.maskCommand, .maskAlternate], exact: true), [])
        XCTAssertEqual(KeyEventFlags.compose(named: ["command", "option", "shift"], held: .maskControl, exact: true),
                       [.maskCommand, .maskAlternate, .maskShift])
        // Unknown names from a newer peer are still ignored.
        XCTAssertEqual(KeyEventFlags.compose(named: ["hyper"], held: .maskCommand, exact: true), [])
    }

    // MARK: - Held keys keep their exact flags

    func testAnExactKeyKeepsItsFlagsUntilItGoesUp() {
        var tracker = HeldKeyTracker()
        XCTAssertTrue(tracker.down(.leftArrow, exactFlags: .maskShift))
        XCTAssertEqual(tracker.exactFlags(for: .leftArrow), .maskShift)
        // A duplicate down is ignored and can't change them.
        XCTAssertFalse(tracker.down(.leftArrow, exactFlags: .maskCommand))
        XCTAssertEqual(tracker.exactFlags(for: .leftArrow), .maskShift)
        XCTAssertTrue(tracker.up(.leftArrow))
        XCTAssertNil(tracker.exactFlags(for: .leftArrow))
    }

    func testAKeyWithoutExactFlagsFollowsTheHeldModifiers() {
        var tracker = HeldKeyTracker()
        tracker.down(.rightArrow)
        XCTAssertNil(tracker.exactFlags(for: .rightArrow))
    }

    func testReleaseAllClearsExactFlags() {
        var tracker = HeldKeyTracker()
        tracker.down(.upArrow, exactFlags: .maskAlternate)
        XCTAssertEqual(tracker.releaseAll(), [.upArrow])
        XCTAssertNil(tracker.exactFlags(for: .upArrow))
        XCTAssertTrue(tracker.exactFlags.isEmpty)
        // Pressed again without the field, it follows the held modifiers.
        tracker.down(.upArrow)
        XCTAssertNil(tracker.exactFlags(for: .upArrow))
    }

    // MARK: - Wire

    func testTheFieldIsSentOnlyWhenAsked() {
        let plain = ExactKeyModifiersWire.keyMessage(action: "down", usage: 80, modifiers: ["shift"], exactModifiers: false)
        XCTAssertNil(plain[ExactKeyModifiersWire.field])
        XCTAssertNil(plain["repeat"])
        XCTAssertEqual(plain["type"] as? String, "keyboard")
        XCTAssertEqual(plain["action"] as? String, "down")
        XCTAssertEqual(plain["usage"] as? Int, 80)
        XCTAssertEqual(plain["modifiers"] as? [String], ["shift"])
        XCTAssertFalse(ExactKeyModifiersWire.isExact(plain))

        let exact = ExactKeyModifiersWire.keyMessage(action: "down", usage: 80, modifiers: ["shift"], isRepeat: true,
                                                     exactModifiers: true)
        XCTAssertEqual(exact["exactModifiers"] as? Bool, true)
        XCTAssertEqual(exact["repeat"] as? Bool, true)
        XCTAssertTrue(ExactKeyModifiersWire.isExact(exact))
    }

    func testOnlyALiteralTrueIsExact() {
        XCTAssertFalse(ExactKeyModifiersWire.isExact(["exactModifiers": false]))
        XCTAssertFalse(ExactKeyModifiersWire.isExact(["exactModifiers": "true"]))
        XCTAssertFalse(ExactKeyModifiersWire.isExact(["exactModifiers": 1]))
        XCTAssertTrue(ExactKeyModifiersWire.isExact(["exactModifiers": true]))
    }

    func testTheMacAdvertisesTheFeatureInEveryMode() {
        XCTAssertEqual(ExactKeyModifiersWire.welcomeFeature, "exactKeyModifiers")
        for windows in [false, true] {
            let features = MacSender.welcomeFeatures(windowStreamingAllowed: windows)
            XCTAssertTrue(features.contains(ExactKeyModifiersWire.welcomeFeature), "windows=\(windows)")
            // A receiver reads only the first 16 entries, each up to 32 characters.
            XCTAssertLessThanOrEqual(features.count, 16)
            XCTAssertTrue(features.allSatisfy { $0.count <= 32 })
            XCTAssertEqual(Set(features).count, features.count)
        }
        // Everything advertised before is still there.
        let windows = MacSender.welcomeFeatures(windowStreamingAllowed: true)
        for feature in [WindowWorkspaceWire.welcomeFeature, TextCaretWire.welcomeFeature, RemoteFilesWire.welcomeFeature,
                        ClipboardWire.welcomeFeature, LockMacWire.welcomeFeature, AppMenuWire.welcomeFeature,
                        WindowCloseWire.welcomeFeature, WindowWorkspaceWire.floatFeature,
                        RemoteEndpointsWire.welcomeFeature] {
            XCTAssertTrue(windows.contains(feature), feature)
        }
        XCTAssertFalse(MacSender.welcomeFeatures(windowStreamingAllowed: false).contains(WindowWorkspaceWire.welcomeFeature))
    }

    @MainActor
    func testTheReceiverRecordsTheFeatureUntilItDisconnects() {
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "Test",
                                      fallbackServiceName: "Test")
        XCTAssertFalse(receiver.macSupportsExactKeyModifiers, "an unknown Mac is assumed old")
        receiver.noteWorkspaceEvent(.features([TextCaretWire.welcomeFeature]))
        XCTAssertFalse(receiver.macSupportsExactKeyModifiers)
        receiver.noteWorkspaceEvent(.features([TextCaretWire.welcomeFeature, ExactKeyModifiersWire.welcomeFeature]))
        XCTAssertTrue(receiver.macSupportsExactKeyModifiers)
        receiver.noteWorkspaceEvent(.disconnected)
        XCTAssertFalse(receiver.macSupportsExactKeyModifiers)
        // A later welcome without it (an older Mac) turns it off again.
        receiver.noteWorkspaceEvent(.features([ExactKeyModifiersWire.welcomeFeature]))
        receiver.noteWorkspaceEvent(.features([]))
        XCTAssertFalse(receiver.macSupportsExactKeyModifiers)
    }

    // MARK: - End to end on the Mac

    private var keychain: TemporaryTestKeychain?
    private var sender: MacSender?
    private let events = RecordingEventSink()

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)   // master on (the default)
        LoginSessionConsole.shared.set(onConsole: true)
        let keychain = try TemporaryTestKeychain(prefix: "meowdisplay-exact-modifier-tests")
        self.keychain = keychain
        let identity = try keychain.makeIdentity()
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: identity.identity),
                                   pinnedPeerSPKI: identity.spki, peerID: Self.peerID)
        // Never dialed: the endpoint only satisfies the initializer.
        sender = MacSender(transport: .tcp(.hostPort(host: "127.0.0.1", port: 9), tls: tls),
                           name: "Exact Modifier Test Phone", mode: .mirror)
    }

    override func tearDown() {
        sender = nil
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        keychain?.delete()
        keychain = nil
        super.tearDown()
    }

    private static let peerID = "exact-modifier-test-phone"
    private static let left = Int64(HIDKeyUsage.leftArrow.keyCode)
    private static let right = Int64(HIDKeyUsage.rightArrow.keyCode)

    /// ⌘ latched on the tray, then the keypad's ⇧→ held, repeated and lifted:
    /// every event of the arrow carries exactly ⇧.
    func testAnExactArrowNeverPicksUpTheTrayLatch() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await receive(sender, modifier: .command, down: true)
        _ = events.take()

        try await receive(sender, key("down", .rightArrow, ["shift"], exact: true))
        try await receive(sender, key("down", .rightArrow, ["shift"], repeat: true, exact: true))
        try await receive(sender, key("up", .rightArrow, ["shift"], exact: true))
        let arrow = events.take().filter { $0.keyCode == Self.right }
        XCTAssertEqual(arrow.map(\.type), [.keyDown, .keyDown, .keyUp])
        XCTAssertEqual(arrow.map(\.flags), [.maskShift, .maskShift, .maskShift], "\(arrow)")
        XCTAssertEqual(arrow.map(\.isAutorepeat), [false, true, false])
    }

    /// The tray's latch keeps working for every other key.
    func testKeysWithoutTheFieldStillCarryTheTrayLatch() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await receive(sender, modifier: .command, down: true)
        _ = events.take()

        try await receive(sender, key("down", .rightArrow, ["shift"]))
        try await receive(sender, key("down", .rightArrow, ["shift"], repeat: true))
        try await receive(sender, key("up", .rightArrow, ["shift"]))
        try await receive(sender, ["type": "keyboard", "action": "press", "usage": HIDKeyUsage.keyC.rawValue])
        let posted = events.take()
        XCTAssertEqual(posted.filter { $0.keyCode == Self.right }.map(\.flags),
                       [[.maskShift, .maskCommand], [.maskShift, .maskCommand], [.maskShift, .maskCommand]])
        XCTAssertEqual(posted.filter { $0.keyCode == Int64(HIDKeyUsage.keyC.keyCode) }.map(\.flags),
                       [.maskCommand, .maskCommand], "⌘C from the tray still works")
    }

    /// The Mac Receiver forwards Shift as a held modifier and a key with none
    /// of its own: the union is what makes that a capital letter.
    func testTheMacReceiversHeldShiftStillReachesItsKeys() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await receive(sender, modifier: .shift, down: true)
        try await receive(sender, key("down", .keyA, []))
        try await receive(sender, key("up", .keyA, []))
        let keyA = events.take().filter { $0.keyCode == Int64(HIDKeyUsage.keyA.keyCode) }
        XCTAssertEqual(keyA.map(\.flags), [.maskShift, .maskShift])
    }

    /// Toggling a keypad modifier while the arrow is held: whatever later
    /// messages say, the key repeats and goes up with what it went down with.
    func testAnExactKeyKeepsItsDownFlagsForRepeatsAndUp() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await receive(sender, key("down", .leftArrow, ["option"], exact: true))
        try await receive(sender, modifier: .command, down: true)   // the tray latches ⌘ mid-hold
        try await receive(sender, key("down", .leftArrow, [], repeat: true, exact: true))
        try await receive(sender, key("down", .leftArrow, ["shift"], repeat: true))
        try await receive(sender, key("up", .leftArrow, []))
        let arrow = events.take().filter { $0.keyCode == Self.left }
        XCTAssertEqual(arrow.map(\.flags), [.maskAlternate, .maskAlternate, .maskAlternate, .maskAlternate], "\(arrow)")
    }

    func testAnExactPressCarriesOnlyItsOwnModifiers() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await receive(sender, modifier: .command, down: true)
        _ = events.take()
        try await receive(sender, key("press", .leftArrow, ["option", "shift"], exact: true))
        let arrow = events.take().filter { $0.keyCode == Self.left }
        XCTAssertEqual(arrow.map(\.type), [.keyDown, .keyUp])
        XCTAssertEqual(arrow.map(\.flags), [[.maskAlternate, .maskShift], [.maskAlternate, .maskShift]])
    }

    func testAnExactKeyWithNoModifiersIsPlain() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await receive(sender, modifier: .shift, down: true)
        try await receive(sender, modifier: .command, down: true)
        _ = events.take()
        try await receive(sender, key("down", .rightArrow, [], exact: true))
        try await receive(sender, key("up", .rightArrow, [], exact: true))
        XCTAssertEqual(events.take().filter { $0.keyCode == Self.right }.map(\.flags), [[], []])
    }

    /// Revoke Control mid-hold: the arrow goes up with its own flags, the
    /// tray's ⌘ is released too, and nothing gets through afterwards.
    func testRevokeReleasesAnExactArrowAndTheTrayModifier() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await receive(sender, modifier: .command, down: true)
        try await receive(sender, key("down", .rightArrow, ["shift"], exact: true))
        _ = events.take()

        sender.revokeSessionInput()
        try await sender.settleForTesting()
        let released = events.take()
        XCTAssertEqual(released.filter { $0.keyCode == Self.right }.map(\.type), [.keyUp])
        XCTAssertEqual(released.filter { $0.keyCode == Self.right }.map(\.flags), [.maskShift])
        XCTAssertTrue(released.contains { $0.keyCode == Int64(ControlModifier.command.keyCode) }, "⌘ was not released: \(released)")
        XCTAssertFalse(released.contains { $0.type == .keyDown }, "a release posted a key down: \(released)")

        // The finger lifting after Revoke releases nothing twice, and nothing new goes through.
        try await receive(sender, key("up", .rightArrow, ["shift"], exact: true))
        try await receive(sender, key("down", .rightArrow, ["shift"], exact: true))
        try await receive(sender, key("press", .leftArrow, ["shift"], exact: true))
        XCTAssertEqual(events.take(), [])
    }

    /// A lost connection releases an exact key like any other.
    func testLosingTheConnectionReleasesAnExactArrow() async throws {
        let sender = try XCTUnwrap(sender)
        try await admitAndGrant(sender)
        try await receive(sender, key("down", .leftArrow, ["command"], exact: true))
        _ = events.take()
        try await sender.loseConnectionForTesting()
        let released = events.take().filter { $0.keyCode == Self.left }
        XCTAssertEqual(released.map(\.type), [.keyUp])
        XCTAssertEqual(released.map(\.flags), [.maskCommand])
    }

    /// Exact modifiers change only flag composition: without control (View
    /// Only, or never granted) an exact key posts nothing.
    func testExactKeysStillNeedControl() async throws {
        let sender = try XCTUnwrap(sender)
        _ = try await admit(sender)
        try await receive(sender, key("down", .leftArrow, ["shift"], exact: true))
        try await receive(sender, key("press", .rightArrow, ["shift"], exact: true))
        XCTAssertEqual(events.take(), [])

        // The Mac's master switch off: still nothing.
        try await admitAndGrant(sender)
        UserDefaults.standard.set(false, forKey: InputPolicy.defaultsKey)
        sender.resetReceiverInputState()
        try await sender.settleForTesting()
        _ = events.take()
        try await receive(sender, key("down", .leftArrow, ["shift"], exact: true))
        XCTAssertEqual(events.take().filter { $0.type == .keyDown }, [])
    }

    // MARK: - Helpers

    private func key(_ action: String, _ usage: HIDKeyUsage, _ modifiers: [String], repeat isRepeat: Bool = false,
                     exact: Bool = false) -> [String: Any] {
        ExactKeyModifiersWire.keyMessage(action: action, usage: Int(usage.rawValue), modifiers: modifiers,
                                         isRepeat: isRepeat, exactModifiers: exact)
    }

    @discardableResult
    private func admit(_ sender: MacSender) async throws -> UInt64 {
        let hello: [String: Any] = ["type": "hello", "pixelsWide": 2532, "pixelsHigh": 1170, "scale": 3.0,
                                    "device": "iPhone", "id": Self.peerID, "pv": WireProtocol.version]
        return try await sender.admitConnectionForTesting(
            helloJSON: try JSONSerialization.data(withJSONObject: hello),
            pinnedSPKI: Data([0x30, 0x59]), eventSink: events, sent: { _ in })
    }

    private func admitAndGrant(_ sender: MacSender) async throws {
        let generation = try await admit(sender)
        sender.grantSessionInput(generation: generation)
        try await sender.settleForTesting()
        XCTAssertTrue(sender.hasInputGrantForTesting)
    }

    private func receive(_ sender: MacSender, modifier: ControlModifier, down: Bool) async throws {
        try await receive(sender, ["type": "keyboard", "action": down ? "modifierDown" : "modifierUp",
                                   "modifier": modifier.rawValue])
    }

    private func receive(_ sender: MacSender, _ message: [String: Any]) async throws {
        try await sender.receiveControlForTesting(try JSONSerialization.data(withJSONObject: message))
    }
}
