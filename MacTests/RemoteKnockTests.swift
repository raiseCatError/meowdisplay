import Network
import XCTest

/// How a Remote Access knock ends (Tailscale plan, Phase 0; Android: RemoteKnockTest).
final class RemoteKnockClassifierTests: XCTestCase {
    private let pin = Data([1, 2, 3])
    private let other = Data([9, 9, 9])

    func testTheFrameTakenAndTheMacClosingIsDelivered() {
        XCTAssertEqual(RemoteKnockClassifier.classify(.closedAfterFrame, frameSent: true, presented: pin, expected: pin), .delivered)
        XCTAssertEqual(RemoteKnockClassifier.classify(.deadline, frameSent: true, presented: pin, expected: pin), .delivered,
                       "the frame went out; the Mac just hadn't closed yet")
        XCTAssertEqual(RemoteKnockClassifier.classify(.posix(ECONNRESET), frameSent: true, presented: pin, expected: pin), .delivered)
    }

    func testThePinnedMacRefusingThisDeviceIsNotAccepted() {
        XCTAssertEqual(RemoteKnockClassifier.classify(.tls, frameSent: true, presented: pin, expected: pin), .notAccepted)
        XCTAssertEqual(RemoteKnockClassifier.classify(.tls, frameSent: false, presented: pin, expected: pin), .notAccepted)
        XCTAssertTrue(RemoteKnockResult.notAccepted.isSecurityFailure)
    }

    func testAnotherKeyIsADifferentMacWhateverElseHappened() {
        for ending: RemoteKnockClassifier.Ending in [.tls, .deadline, .closedAfterFrame, .posix(ECONNRESET), .other] {
            XCTAssertEqual(RemoteKnockClassifier.classify(ending, frameSent: false, presented: other, expected: pin,
                                                          otherPeer: { $0 == self.other ? "mac-B" : nil }),
                           .identityMismatch(otherPeerID: "mac-B"), "\(ending)")
        }
        XCTAssertTrue(RemoteKnockResult.identityMismatch(otherPeerID: nil).isSecurityFailure)
    }

    func testNetworkFailuresBeforeTheFrameAreRetryable() {
        XCTAssertEqual(RemoteKnockClassifier.classify(.posix(ECONNREFUSED), frameSent: false, presented: nil, expected: pin), .refused)
        XCTAssertEqual(RemoteKnockClassifier.classify(.posix(EHOSTUNREACH), frameSent: false, presented: nil, expected: pin), .unreachable)
        XCTAssertEqual(RemoteKnockClassifier.classify(.posix(ENETUNREACH), frameSent: false, presented: nil, expected: pin), .unreachable)
        XCTAssertEqual(RemoteKnockClassifier.classify(.posix(ETIMEDOUT), frameSent: false, presented: nil, expected: pin), .timedOut)
        XCTAssertEqual(RemoteKnockClassifier.classify(.deadline, frameSent: false, presented: nil, expected: pin), .timedOut)
        XCTAssertEqual(RemoteKnockClassifier.classify(.dns, frameSent: false, presented: nil, expected: pin), .dnsFailed)
        XCTAssertEqual(RemoteKnockClassifier.classify(.tls, frameSent: false, presented: nil, expected: pin), .failed)
        XCTAssertEqual(RemoteKnockClassifier.classify(.cancelled, frameSent: false, presented: nil, expected: pin), .cancelled)
        for result: RemoteKnockResult in [.refused, .unreachable, .timedOut, .dnsFailed, .failed, .cancelled, .delivered] {
            XCTAssertFalse(result.isSecurityFailure, "\(result)")
        }
    }
}

/// The same outcomes over real pinned mutual TLS on loopback, with throwaway identities.
final class RemoteKnockLoopbackTests: XCTestCase {
    private var keychain: TemporaryTestKeychain!
    private let queue = DispatchQueue(label: "remote-knock-tests")

    override func setUpWithError() throws {
        try super.setUpWithError()
        keychain = try TemporaryTestKeychain(prefix: "meowdisplay-knock-tests")
    }

    override func tearDown() {
        keychain?.delete()
        keychain = nil
        super.tearDown()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: RemoteKnockResult?
        func set(_ r: RemoteKnockResult) { lock.lock(); stored = r; lock.unlock() }
        var value: RemoteKnockResult? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    private final class Frames: @unchecked Sendable {
        private let lock = NSLock()
        private var received: [Data] = []
        func add(_ d: Data) { lock.lock(); received.append(d); lock.unlock() }
        var all: [Data] { lock.lock(); defer { lock.unlock() }; return received }
    }

    /// A Mac's connect-request listener: pinned mutual TLS, reads one frame, closes.
    private func mac(_ identity: TemporaryTestKeychain.Identity, trusting: [Data], frames: Frames) throws -> NWListener {
        let tls = try XCTUnwrap(TLSConfigurator.mutualTLSOptions(identity: identity.identity, pinnedSPKIs: { trusting },
                                                                 isListener: true, queue: queue))
        let listener = try NWListener(using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()), on: .any)
        let queue = self.queue
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, _ in
                        if let data { frames.add(data) }
                        connection.cancel()
                    }
                }
            }
            connection.start(queue: queue)
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        return listener
    }

    private func knock(port: UInt16, phone: TemporaryTestKeychain.Identity, expecting pin: Data,
                       otherPeer: @escaping @Sendable (Data) -> String? = { _ in nil }) -> RemoteKnockResult {
        let done = expectation(description: "knock finished")
        let result = ResultBox()
        let queue = self.queue
        RemoteKnock.start(
            host: "127.0.0.1", port: port, frame: Data(#"{"intent":"manual"}"#.utf8), expected: pin,
            makeTLS: { onPeerKey in
                TLSConfigurator.mutualTLSOptions(identity: phone.identity, pinnedSPKIs: { [pin] },
                                                 isListener: false, queue: queue, onPeerKey: onPeerKey)
            },
            queue: queue, deadline: 5, otherPeer: otherPeer,
            completion: { result.set($0); done.fulfill() })
        wait(for: [done], timeout: 10)
        return result.value ?? .failed
    }

    func testThePinnedMacTakesTheFrame() throws {
        let phone = try keychain.makeIdentity(), macA = try keychain.makeIdentity()
        let frames = Frames()
        let listener = try mac(macA, trusting: [phone.spki], frames: frames)
        defer { listener.cancel() }
        XCTAssertEqual(knock(port: try XCTUnwrap(listener.port?.rawValue), phone: phone, expecting: macA.spki), .delivered)
        XCTAssertEqual(frames.all.count, 1)
    }

    func testAMacThatNoLongerTrustsThisDeviceIsNotAccepted() throws {
        let phone = try keychain.makeIdentity(), macA = try keychain.makeIdentity()
        let frames = Frames()
        let listener = try mac(macA, trusting: [], frames: frames)
        defer { listener.cancel() }
        XCTAssertEqual(knock(port: try XCTUnwrap(listener.port?.rawValue), phone: phone, expecting: macA.spki), .notAccepted)
        XCTAssertTrue(frames.all.isEmpty, "nothing reaches a Mac that refused this device")
    }

    func testAnotherMacAtTheAddressIsAMismatchThatNamesIt() throws {
        let phone = try keychain.makeIdentity(), macA = try keychain.makeIdentity(), macB = try keychain.makeIdentity()
        let frames = Frames()
        let listener = try mac(macB, trusting: [phone.spki], frames: frames)
        defer { listener.cancel() }
        let b = macB.spki
        let result = knock(port: try XCTUnwrap(listener.port?.rawValue), phone: phone, expecting: macA.spki,
                           otherPeer: { $0 == b ? "mac-B" : nil })
        XCTAssertEqual(result, .identityMismatch(otherPeerID: "mac-B"))
        XCTAssertTrue(frames.all.isEmpty, "the frame never goes to the wrong Mac")
    }

    func testNothingListeningIsRefused() throws {
        let phone = try keychain.makeIdentity(), macA = try keychain.makeIdentity()
        // A port that was just free.
        let probe = try NWListener(using: .tcp, on: .any)
        let ready = expectation(description: "probe")
        probe.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        probe.start(queue: queue)
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(probe.port?.rawValue)
        probe.cancel()
        let result = knock(port: port, phone: phone, expecting: macA.spki)
        XCTAssertTrue(result == .refused || result == .unreachable, "\(result)")
        XCTAssertFalse(result.isSecurityFailure)
    }
}
