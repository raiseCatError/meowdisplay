import CoreGraphics
import XCTest

/// A paired receiver's hello and input numbers, end to end through the real
/// `MacSender` control handler (the test plays the receiver; events go to a
/// recorder, never the HID tap). A hostile number must never trap the Mac: a
/// hello whose display no device has ends that session before anything uses
/// it, a hello that doesn't decode changes nothing, and huge input values are
/// bounded where they are converted.
final class MacSenderHostileHelloTests: XCTestCase {

    private var keychain: TemporaryTestKeychain?
    private var tls: TLSSessionConfig?
    private let events = RecordingEventSink()
    private static let peerID = "hostile-hello-test-phone"
    private static let malformedDisplayText = "display size it can't have"

    override func setUpWithError() throws {
        try super.setUpWithError()
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)   // master on (the default)
        LoginSessionConsole.shared.set(onConsole: true)
        let keychain = try TemporaryTestKeychain(prefix: "meowdisplay-hostile-hello-tests")
        self.keychain = keychain
        let identity = try keychain.makeIdentity()
        tls = TLSSessionConfig(identity: SendableSecIdentity(value: identity.identity),
                               pinnedPeerSPKI: identity.spki, peerID: Self.peerID)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        keychain?.delete()
        keychain = nil
        super.tearDown()
    }

    // MARK: - Decoding (type confusion)

    private static func hello(_ overrides: [String: Any] = [:], removing: [String] = []) -> [String: Any] {
        var hello: [String: Any] = ["type": "hello", "pixelsWide": 2532, "pixelsHigh": 1170, "scale": 3.0,
                                    "device": "iPhone", "id": peerID, "pv": WireProtocol.version]
        for (key, value) in overrides { hello[key] = value }
        for key in removing { hello[key] = nil }
        return hello
    }

    /// Raw JSON text, for numbers `JSONSerialization` wouldn't write. `field` replaces the
    /// default value (never a second copy of the key: with duplicate keys the decoder keeps one).
    private static func helloText(_ field: String, _ literal: String) -> Data {
        var fields: [(String, String)] = [("type", #""hello""#), ("pixelsWide", "2532"), ("pixelsHigh", "1170"),
                                          ("scale", "3.0"), ("device", #""iPhone""#), ("id", #""\#(peerID)""#)]
        if let i = fields.firstIndex(where: { $0.0 == field }) { fields[i].1 = literal } else { fields.append((field, literal)) }
        return Data(("{" + fields.map { #""\#($0.0)":\#($0.1)"# }.joined(separator: ",") + "}").utf8)
    }

    private static let undecodable: [(String, Data)] = [
        ("pixelsWide 1e300", helloText("pixelsWide", "1e300")),
        ("pixelsWide 1024.5", helloText("pixelsWide", "1024.5")),
        ("pixelsWide 2^63", helloText("pixelsWide", "9223372036854775808")),
        ("pixelsWide string", helloText("pixelsWide", #""1024""#)),
        ("pixelsWide bool", helloText("pixelsWide", "true")),
        ("pixelsWide null", helloText("pixelsWide", "null")),
        ("scale string", helloText("scale", #""NaN""#)),
        ("maxFPS 1e300", helloText("maxFPS", "1e300")),
        ("maxFPS 59.94", helloText("maxFPS", "59.94")),
        ("maxFPS string", helloText("maxFPS", #""x""#)),
        ("maxEncodeWide fractional", helloText("maxEncodeWide", "4096.5")),
        ("avSyncOffsetMs huge", helloText("avSyncOffsetMs", "1e19")),
        ("ws array", helloText("ws", "[2]")),
    ]

    /// A wrong JSON type, a fractional or an out-of-range integer fails
    /// `PhoneInfo` decoding: the hello handler's `try?` reads it as no hello.
    func testWrongTypesAndFractionsFailDecodingWithoutTrapping() throws {
        for (name, data) in Self.undecodable {
            XCTAssertThrowsError(try JSONDecoder().decode(PhoneInfo.self, from: data), name)
        }
        let missingScale = try JSONSerialization.data(withJSONObject: Self.hello(removing: ["scale"]))
        XCTAssertThrowsError(try JSONDecoder().decode(PhoneInfo.self, from: missingScale))
        // Whole numbers written as doubles decode; Int.max decodes and is then refused by the bounds.
        let whole = try JSONDecoder().decode(PhoneInfo.self, from: Self.helloText("pixelsWide", "2.532e3"))
        XCTAssertEqual(whole.pixelsWide, 2532)
        let huge = try JSONDecoder().decode(PhoneInfo.self, from: Self.helloText("pixelsWide", "9223372036854775807"))
        XCTAssertEqual(PeerDisplayBounds.violation(pixelsWide: huge.pixelsWide, pixelsHigh: huge.pixelsHigh, scale: huge.scale),
                       .pixelsWide)
        // An overflowing positive literal doesn't parse as a control message at all; an overflowing
        // negative one does, as -infinity (see `testNegativeInfinityFromAnOverflowingLiteralNeverTraps`),
        // but `PhoneInfo` refuses it.
        XCTAssertNil(try? JSONSerialization.jsonObject(with: Self.helloText("scale", "1e400")))
        XCTAssertThrowsError(try JSONDecoder().decode(PhoneInfo.self, from: Self.helloText("scale", "-1e400")))
    }

    /// The same hellos through the live handler: nothing changes, the session stays admitted.
    func testAHelloThatDoesNotDecodeChangesNothing() async throws {
        let sender = try makeSender()
        try await admit(sender)
        let failures = TrustFailures()
        await failures.install(on: sender)
        for (name, data) in Self.undecodable {
            try await sender.receiveControlForTesting(data)
            try await sender.settleForTesting()
            let state = try await sender.helloStateForTesting
            XCTAssertEqual(state?.pixelsWide, 2532, name)
            XCTAssertEqual(state?.pixelsHigh, 1170, name)
            XCTAssertEqual(state?.admitted, true, name)
        }
        try await Task.sleep(for: .milliseconds(100))
        let messages = failures.messages
        XCTAssertEqual(messages, [], "an undecodable hello stops nothing")
    }

    // MARK: - Geometry bounds

    private static var outOfRange: [(String, [String: Any])] { [
        ("pixelsWide Int.max", ["pixelsWide": Int.max]), ("pixelsWide Int.min", ["pixelsWide": Int.min]),
        ("pixelsWide -1", ["pixelsWide": -1]), ("pixelsWide 32769", ["pixelsWide": 32_769]),
        ("pixelsHigh Int.max", ["pixelsHigh": Int.max]), ("pixelsHigh -1", ["pixelsHigh": -1]),
        ("pixelsHigh 32769", ["pixelsHigh": 32_769]),
        ("scale 0", ["scale": 0.0]), ("scale -1", ["scale": -1.0]), ("scale 1e300", ["scale": 1e300]),
        ("scale 16.5", ["scale": 16.5]),
    ] }

    /// The A2 trigger and its neighbours: the hello is refused before identity
    /// or sizing sees it, the session ends with the malformed-display message,
    /// and the hello it had stays the one it knows.
    func testAHelloWithAnImpossibleDisplayEndsTheSessionWithoutTrapping() async throws {
        for (name, overrides) in Self.outOfRange {
            let sender = try makeSender()
            try await admit(sender)
            let failures = TrustFailures()
            await failures.install(on: sender)
            try await sender.receiveControlForTesting(JSONSerialization.data(withJSONObject: Self.hello(overrides)))
            try await sender.settleForTesting()
            let state = try await sender.helloStateForTesting
            XCTAssertEqual(state?.pixelsWide, 2532, "\(name): the refused hello is never used")
            XCTAssertEqual(state?.pixelsHigh, 1170, name)
            XCTAssertEqual(state?.admitted, false, "\(name): the session ends")
            let message = try await failures.first()
            XCTAssertTrue(message?.contains(Self.malformedDisplayText) == true, "\(name): \(message ?? "no message")")
        }
    }

    /// In-range hellos, including the largest real panel and an unmeasured
    /// one, pass the bounds and go on to the identity check (which, with no
    /// real connection here, refuses them with its own message).
    func testRealDisplaysPassTheBoundsCheck() async throws {
        for overrides in [["pixelsWide": 15_360, "pixelsHigh": 8_640, "scale": 2.0],
                          ["pixelsWide": 0, "pixelsHigh": 0], ["pixelsWide": 32_768, "pixelsHigh": 32_768, "scale": 16.0],
                          ["pixelsWide": 1170, "pixelsHigh": 2532], ["scale": 0.75]] as [[String: Any]] {
            let sender = try makeSender()
            try await admit(sender)
            let failures = TrustFailures()
            await failures.install(on: sender)
            try await sender.receiveControlForTesting(JSONSerialization.data(withJSONObject: Self.hello(overrides)))
            try await sender.settleForTesting()
            let message = try await failures.first()
            XCTAssertNotNil(message, "\(overrides): reached the identity check")
            XCTAssertFalse(message?.contains(Self.malformedDisplayText) ?? true, "\(overrides) must not be refused as malformed")
        }
    }

    // MARK: - Input numbers

    /// With input granted: huge scroll deltas, Pencil pressure, relative
    /// moves, coordinates and click counts are bounded where they become
    /// integers or points, and reach the Mac without trapping.
    func testHugeInputNumbersNeverTrap() async throws {
        let sender = try makeSender()
        let generation = try await admit(sender)
        sender.grantSessionInput(generation: generation)
        try await sender.settleForTesting()
        XCTAssertTrue(sender.hasInputGrantForTesting)
        _ = events.take()
        let huge = [1e300, -1e300, Double.greatestFiniteMagnitude, Double(Int.max), -Double(Int.max)]
        for value in huge {
            try await receive(sender, ["type": "scroll", "dx": value, "dy": -value])
            try await receive(sender, ["type": "pointer", "action": "moveRelative", "dx": value, "dy": value])
            try await receive(sender, ["type": "pointer", "action": "move", "x": value, "y": -value])
            try await receive(sender, ["type": "pencil", "phase": "down", "x": 0.3, "y": 0.3, "pressure": value,
                                       "azimuth": value, "altitude": value])
            try await receive(sender, ["type": "pencil", "phase": "move", "x": value, "y": 0.3, "pressure": value])
            try await receive(sender, ["type": "pencil", "phase": "up", "x": 0.3, "y": 0.3, "pressure": 0.0])
            try await receive(sender, ["type": "touch", "phase": "began", "x": value, "y": value])
            try await receive(sender, ["type": "touch", "phase": "ended", "x": value, "y": value, "t": value])
            try await receive(sender, ["type": "ping", "t": value])
        }
        for count in [Int.max, Int.min, -1, 0] {
            try await receive(sender, ["type": "pointer", "action": "down", "button": "left", "clickCount": count])
            try await receive(sender, ["type": "pointer", "action": "up", "button": "left", "clickCount": count])
        }
        try await sender.settleForTesting()
        let posted = events.take().map(\.type)
        XCTAssertTrue(posted.contains(.scrollWheel), "a huge scroll still scrolls, bounded")
        XCTAssertTrue(posted.contains(.leftMouseDown))
        XCTAssertTrue(posted.contains(.leftMouseUp))
    }

    /// `JSONSerialization` reads an overflowing negative literal (`-1e400`) as -infinity, so a
    /// control message CAN carry a non-finite number (`JSONSerialization.data` never writes one,
    /// hence raw text here). Every input sink takes it without trapping, and nothing ends the session.
    func testNegativeInfinityFromAnOverflowingLiteralNeverTraps() async throws {
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"dx":-1e400}"#.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["dx"] as? Double, -.infinity, "the platform behaviour this test is about")
        let sender = try makeSender()
        let generation = try await admit(sender)
        sender.grantSessionInput(generation: generation)
        try await sender.settleForTesting()
        XCTAssertTrue(sender.hasInputGrantForTesting)
        _ = events.take()
        let messages = [
            #"{"type":"hello","pixelsWide":2532,"pixelsHigh":1170,"scale":-1e400,"device":"iPhone","id":"\#(Self.peerID)"}"#,
            #"{"type":"scroll","dx":-1e400,"dy":-1e400}"#,
            #"{"type":"scroll","dx":3,"dy":-1e400}"#,
            #"{"type":"pointer","action":"moveRelative","dx":-1e400,"dy":-1e400}"#,
            #"{"type":"pointer","action":"move","x":-1e400,"y":-1e400}"#,
            #"{"type":"pencil","phase":"down","x":-1e400,"y":0.3,"pressure":-1e400,"azimuth":-1e400,"altitude":-1e400,"t":-1e400}"#,
            #"{"type":"pencil","phase":"move","x":0.3,"y":-1e400,"pressure":-1e400,"altitude":-1e400}"#,
            #"{"type":"pencil","phase":"up","x":0.3,"y":0.3}"#,
            #"{"type":"touch","phase":"began","x":-1e400,"y":-1e400,"t":-1e400}"#,
            #"{"type":"touch","phase":"ended","x":-1e400,"y":-1e400}"#,
            #"{"type":"proximity","entering":true,"x":-1e400,"y":-1e400}"#,
            #"{"type":"proximity","entering":false,"x":0.5,"y":0.5}"#,
            #"{"type":"ping","t":-1e400}"#,
        ]
        for text in messages {
            try await sender.receiveControlForTesting(Data(text.utf8))
        }
        try await sender.settleForTesting()
        let state = try await sender.helloStateForTesting
        XCTAssertEqual(state?.pixelsWide, 2532, "the -infinity hello does not decode and changes nothing")
        XCTAssertEqual(state?.admitted, true, "nothing above ends the session")
        XCTAssertTrue(events.take().map(\.type).contains(.scrollWheel), "an infinite scroll is bounded, not dropped")
    }

    // MARK: - Helpers

    private func makeSender() throws -> MacSender {
        let tls = try XCTUnwrap(tls)
        // Never dialed: the endpoint only satisfies the initializer.
        let sender = MacSender(transport: .tcp(.hostPort(host: "127.0.0.1", port: 9), tls: tls),
                               name: "Hostile Hello Test Phone", mode: .mirror)
        // Its own lock state: these tests never depend on whether this Mac's screen is locked.
        sender.privacyGate = MacPrivacyGate(.unlocked)
        return sender
    }

    @discardableResult
    private func admit(_ sender: MacSender) async throws -> UInt64 {
        try await sender.admitConnectionForTesting(
            helloJSON: try JSONSerialization.data(withJSONObject: Self.hello()),
            pinnedSPKI: Data([0x30, 0x59]), eventSink: events, sent: { _ in })
    }

    private func receive(_ sender: MacSender, _ message: [String: Any]) async throws {
        try await sender.receiveControlForTesting(try JSONSerialization.data(withJSONObject: message))
    }
}

/// What `onTrustFailure` (the session's stop-with-message path) was told.
private final class TrustFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var messages: [String] { lock.withLock { recorded } }

    func install(on sender: MacSender) async {
        await sender.observeTrustFailuresForTesting { [weak self] message in
            guard let self else { return }
            self.lock.withLock { self.recorded.append(message) }
        }
    }

    /// The first message, waiting up to a second for the main-actor hop.
    func first() async throws -> String? {
        for _ in 0..<100 where messages.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return messages.first
    }
}
