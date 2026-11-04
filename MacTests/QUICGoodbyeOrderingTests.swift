import XCTest
import Network

/// Issue #162: a receiver's deliberate Disconnect over QUIC must reach the
/// Mac as a goodbye (`closing`), never as a dropped link the Mac redials.
///
/// Real loopback QUIC: the production `MacSenderTransportController` dials
/// the production receiver edge (`QUICReceiverGroup`), and the receiver end
/// leaves exactly the way `StreamReceiver.disconnect()` does — `closing` on
/// the Control stream, then the whole connection closed from the send
/// completion. QUIC does not order data across streams, so the Video/Audio
/// stream ends can reach the Mac before the `closing` bytes do.
final class QUICGoodbyeOrderingTests: XCTestCase {

    private typealias TestIdentity = TemporaryTestKeychain.Identity

    private var keychain: TemporaryTestKeychain?
    private let queue = DispatchQueue(label: "quic.goodbye.tests.receiver")

    override func setUpWithError() throws {
        try super.setUpWithError()
        keychain = try TemporaryTestKeychain(prefix: "meowdisplay-quic-goodbye-tests")
    }

    override func tearDown() {
        keychain?.delete()
        keychain = nil
        super.tearDown()
    }

    private func makeIdentity() throws -> TestIdentity {
        guard let keychain else { throw securityTestUnavailable("no temporary keychain") }
        return try keychain.makeIdentity()
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// What the Mac saw, in order.
    private enum MacEvent: Equatable {
        case control(String)
        /// The Control read ended (EOF or error) — `MacSender.receiveControl`
        /// treats that as the link dying unless it was its own cancel.
        case controlEnded(String)
        case failure(String)
        /// The Mac ended the session itself (after `closing`).
        case macClosed
    }

    /// The Mac-side delegate: reads the Control stream exactly the way
    /// `MacSender.receiveControl` does (4-byte length, then the payload),
    /// re-arming the read right after `closing` as it does.
    private final class MacSide: MacSenderTransportDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let transport: SenderTransport
        private var _events: [MacEvent] = []
        private var _receiving = 0
        /// Runs when `closing` is read — `MacSender` ends the session then.
        var onClosing: (@Sendable () -> Void)?
        init(transport: SenderTransport) { self.transport = transport }

        func record(_ event: MacEvent) { lock.lock(); _events.append(event); lock.unlock() }
        var events: [MacEvent] { lock.lock(); defer { lock.unlock() }; return _events }
        var receiving: Int { lock.lock(); defer { lock.unlock() }; return _receiving }

        func transportSessionBecameReady(on connection: NWConnection) {}
        func transportShouldBeginReceiving(on connection: NWConnection) {
            lock.lock(); _receiving += 1; lock.unlock()
            read(connection)
        }
        private func read(_ conn: NWConnection) {
            conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [self] data, _, isComplete, error in
                guard error == nil, let data, data.count == 4 else {
                    self.record(.controlEnded(error.map { "\($0)" } ?? (isComplete ? "EOF" : "empty")))
                    return
                }
                let len = Int(UInt32(bigEndian: data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
                conn.receive(minimumIncompleteLength: len, maximumLength: len) { payload, _, _, error in
                    guard error == nil, let payload, payload.count == len else {
                        self.record(.controlEnded(error.map { "\($0)" } ?? "EOF in payload"))
                        return
                    }
                    let type = (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["type"] as? String
                    self.record(.control(type ?? "?"))
                    if type == WireMessage.closing { self.onClosing?() }
                    self.read(conn)
                }
            }
        }
        func transportPathChanged(_ route: ConnectionRoute?) {}
        func transportSessionInvalidated(reason: String) {}
        func transportLinkDied(_ detail: String) {}
        func transportCancelActiveInput() {}
        func transportPeerDeviceKind() -> String? { nil }
        func transportDialingContext() -> (transport: SenderTransport, peerAddrs: [String]) { (transport, []) }
        func transportQUICFailed(_ failure: QUICTransportFailure) { record(.failure(failure.detail)) }
    }

    private final class ReceiverSide: @unchecked Sendable {
        private let lock = NSLock()
        private var _control: NWConnection?
        private var _media = 0
        private var _owner: QUICReceiverGroup?
        func control(_ s: NWConnection) { lock.lock(); _control = s; lock.unlock() }
        func media() { lock.lock(); _media += 1; lock.unlock() }
        func owner(_ o: QUICReceiverGroup) { lock.lock(); _owner = o; lock.unlock() }
        var controlStream: NWConnection? { lock.lock(); defer { lock.unlock() }; return _control }
        var mediaCount: Int { lock.lock(); defer { lock.unlock() }; return _media }
        var group: QUICReceiverGroup? { lock.lock(); defer { lock.unlock() }; return _owner }
    }

    private func receiverOptions(_ identity: TestIdentity, pinning client: Data) throws -> NWProtocolQUIC.Options {
        let options = try XCTUnwrap(TLSConfigurator.pinnedQUICOptions(
            identity: identity.identity, pinnedSPKIs: { [client] }, isListener: true, queue: queue))
        QUICReceiverListener.configureStreamLimits(options)
        return options
    }

    private struct Run {
        let events: [MacEvent]
        /// Seconds from the goodbye's send completion until the receiver's
        /// QUIC connection was fully closed (nil: still open at the end).
        let receiverClosedAfter: TimeInterval?
        var readClosing: Bool { events.contains(.control(WireMessage.closing)) }
        var firstFailure: Int? { events.firstIndex { if case .failure = $0 { return true }; return false } }
        /// The Mac declared the link broken before it read the goodbye —
        /// the #162 redial.
        var failedBeforeGoodbye: Bool {
            guard let failure = firstFailure else { return false }
            guard let closing = events.firstIndex(of: .control(WireMessage.closing)) else { return true }
            return failure < closing
        }
        /// Anything `MacSender` would take for a dying link (a transport
        /// failure, or the Control read ending) before the Mac ended the
        /// session itself. Even after `closing` was read, that runs
        /// `linkDied` on the sender queue ahead of the main-actor goodbye
        /// handling: a "Connection lost" status, a queued redial and, under
        /// Auto, an early-loss QUIC cooldown.
        var sawDropBeforeOwnClose: Bool {
            let ownClose = events.firstIndex(of: .macClosed) ?? events.count
            return events[..<ownClose].contains {
                switch $0 {
                case .failure, .controlEnded: return true
                default: return false
                }
            }
        }
    }

    /// How the receiver end leaves the live session.
    private enum Leave {
        /// `StreamReceiver.disconnect()`: `closing`, then from the send
        /// completion the pipeline retires the Control stream after the
        /// goodbye (`QUICReceiverGroupRegistry.retireAfterGoodbye`).
        case disconnect(goodbyeTimeout: TimeInterval)
        /// The connection breaks with no goodbye at all (the app is killed,
        /// the network goes away): the receiver's connection just closes.
        case unexpectedFailure
    }

    /// One live session over real loopback QUIC that the receiver then
    /// leaves. `macEndsSessionOnClosing` models `MacSender`: on `closing`
    /// it ends the session (`onPeerClosed` → `end` → `stop`), which closes
    /// the QUIC connection.
    private func run(_ leave: Leave, macEndsSessionOnClosing: Bool = true,
                     server: TestIdentity, client: TestIdentity,
                     whileWaiting: ((QUICReceiverGroupRegistry, QUICReceiverGroup) -> Void)? = nil) throws -> Run {
        let listener = try NWListener(
            using: QUICReceiverListener.listenerParameters(quic: try receiverOptions(server, pinning: client.spki)),
            on: .any)
        let registry = QUICReceiverGroupRegistry()
        let receiver = ReceiverSide()
        let queue = self.queue
        listener.newConnectionGroupHandler = { group in
            let owner = registry.admit { id in
                QUICReceiverGroup(id: id, group: group, registry: registry, queue: queue,
                                  onControlStream: { receiver.control($0) },
                                  onMediaReady: { _ in receiver.media() })
            }
            guard let owner else { group.cancel(); return }
            receiver.owner(owner)
            owner.start()
        }
        listener.start(queue: queue)
        defer { listener.cancel(); registry.closeAll(error: nil) }
        waitUntil(5) { listener.port != nil && listener.state == .ready }
        guard listener.state == .ready, let port = listener.port else {
            throw securityTestUnavailable("loopback QUIC listener unavailable (\(listener.state))")
        }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: client.identity),
                                   pinnedPeerSPKI: server.spki, peerID: "quic-goodbye-test")
        let controllerQueue = DispatchQueue(label: "quic.goodbye.tests.mac")
        let controller = MacSenderTransportController(queue: controllerQueue, endpointName: "test",
                                                      statusSink: MacSenderStatusSink())
        let mac = MacSide(transport: .tcp(endpoint, tls: tls))
        if macEndsSessionOnClosing {
            // `publishPeerClosed` hops to the main actor, which then stops the sender.
            mac.onClosing = {
                // `publishPeerClosed` runs on the main actor, which can be
                // busy (SwiftUI, capture callbacks): model a slow hop, so
                // anything the receiver ends meanwhile reaches the sender
                // queue first, as it can on a real Mac.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    controllerQueue.async {
                        mac.record(.macClosed)
                        controller.cancelAndClearConnection()
                    }
                }
            }
        }
        controller.delegate = mac
        defer { controllerQueue.sync { controller.cancelAndClearConnection() } }
        XCTAssertTrue(controllerQueue.sync { controller.connectQUIC(to: endpoint, tls: tls) })

        waitUntil(6) { mac.receiving == 1 && receiver.controlStream != nil && receiver.mediaCount == 2 }
        guard let control = receiver.controlStream, let owner = receiver.group, receiver.mediaCount == 2 else {
            XCTFail("session never came up: \(mac.events)")
            return Run(events: mac.events, receiverClosedAfter: nil)
        }
        // The Mac accepted the receiver's hello: a LIVE session.
        controllerQueue.sync { controller.markQUICApplicationReady() }

        let sent = SentAt()
        switch leave {
        case .disconnect(let goodbyeTimeout):
            let payload = try JSONSerialization.data(withJSONObject: ["type": WireMessage.closing])
            var header = UInt32(payload.count).bigEndian
            var frame = Data(bytes: &header, count: 4)
            frame.append(payload)
            control.send(content: frame, completion: .contentProcessed { _ in
                queue.async {
                    sent.mark()
                    registry.retireAfterGoodbye(controlStream: control, timeout: goodbyeTimeout)
                }
            })
        case .unexpectedFailure:
            queue.async {
                sent.mark()
                owner.close(nil)
            }
        }

        waitUntil(4) { sent.at != nil && registry.liveCount == 0 }
        whileWaiting?(registry, owner)
        let closedAfter: TimeInterval? = registry.liveCount == 0 ? sent.at.map { Date().timeIntervalSince($0) } : nil
        // Let the Mac's last callbacks for this session land.
        waitUntil(0.3) { false }
        return Run(events: mac.events, receiverClosedAfter: closedAfter)
    }

    private final class SentAt: @unchecked Sendable {
        private let lock = NSLock()
        private var _at: Date?
        func mark() { lock.lock(); _at = Date(); lock.unlock() }
        var at: Date? { lock.lock(); defer { lock.unlock() }; return _at }
    }

    private var iterations: Int {
        Int(ProcessInfo.processInfo.environment["MEOW_QUIC_GOODBYE_ITERATIONS"] ?? "") ?? 20
    }

    // MARK: - Tests

    /// Repeated receiver Disconnects over real QUIC: the Mac reads the
    /// goodbye every time, before anything else ends, and closes the
    /// connection itself — the receiver never has to fall back to its
    /// timeout. With the old teardown (`close(nil)` straight from the send
    /// completion) this lost the goodbye in 26 of 40 loopback runs.
    func testReceiverDisconnectReachesTheMacAsAGoodbyeOverRealQUIC() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        var runs: [Run] = []
        for _ in 0..<iterations {
            runs.append(try run(.disconnect(goodbyeTimeout: QUICReceiverLimits.goodbyeDeliveryTimeout),
                                server: server, client: client))
        }
        let bad = runs.filter(\.failedBeforeGoodbye)
        let dropped = runs.filter(\.sawDropBeforeOwnClose)
        let missed = runs.filter { !$0.readClosing }
        let timedOut = runs.filter { ($0.receiverClosedAfter ?? .infinity) >= QUICReceiverLimits.goodbyeDeliveryTimeout }
        print("quicGoodbye: runs=\(runs.count) failedBeforeGoodbye=\(bad.count) closingNeverRead=\(missed.count)"
              + " dropBeforeOwnClose=\(dropped.count)"
              + " receiverTimedOut=\(timedOut.count)"
              + " maxCloseSeconds=\(runs.compactMap(\.receiverClosedAfter).max() ?? -1)")
        XCTAssertEqual(bad.count, 0, "the Mac took a deliberate Disconnect for a drop: \(bad.map(\.events))")
        XCTAssertEqual(missed.count, 0, "the goodbye was lost: \(missed.map(\.events))")
        XCTAssertEqual(dropped.count, 0, "the Mac saw the link die before it ended the session: \(dropped.map(\.events))")
        XCTAssertEqual(timedOut.count, 0, "the receiver had to give up waiting for the Mac's close")
    }

    /// A Mac that never closes after the goodbye (unresponsive, or gone):
    /// the receiver's wait is bounded and the connection closes by itself.
    func testReceiverClosesByItselfWhenTheMacNeverAnswersTheGoodbye() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let result = try run(.disconnect(goodbyeTimeout: 0.5), macEndsSessionOnClosing: false,
                             server: server, client: client)
        XCTAssertTrue(result.readClosing, "the goodbye still arrives first: \(result.events)")
        XCTAssertFalse(result.failedBeforeGoodbye, "\(result.events)")
        let closedAfter = try XCTUnwrap(result.receiverClosedAfter, "the receiver must not wait forever")
        XCTAssertGreaterThanOrEqual(closedAfter, 0.4)
        XCTAssertLessThan(closedAfter, 3)
    }

    /// Stop (`closeAll`) while the receiver still waits for the Mac: the
    /// connection closes at once.
    func testStoppingWhileWaitingForTheMacClosesAtOnce() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let probe = WaitProbe()
        _ = try run(.disconnect(goodbyeTimeout: 30), macEndsSessionOnClosing: false,
                    server: server, client: client, whileWaiting: { registry, owner in
            probe.wasWaiting = owner.isAwaitingGoodbyeDelivery
            registry.closeAll(error: nil)
            probe.closedImmediately = !owner.isAwaitingGoodbyeDelivery && registry.liveCount == 0
        })
        XCTAssertTrue(probe.wasWaiting, "still waiting for the Mac before the stop")
        XCTAssertTrue(probe.closedImmediately)
    }

    private final class WaitProbe: @unchecked Sendable {
        var wasWaiting = false
        var closedImmediately = false
    }

    /// A broken connection with no goodbye is still a failure the Mac
    /// reports at once (and recovers from) — nothing waits for a goodbye
    /// that was never sent.
    func testUnexpectedTransportFailureIsStillReportedAsAFailure() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        for _ in 0..<5 {
            let result = try run(.unexpectedFailure, server: server, client: client)
            XCTAssertFalse(result.readClosing, "\(result.events)")
            // Either signal is the link dying to `MacSender`: an abrupt close can
            // end the Control read (EOF) before the controller reports a failure.
            XCTAssertTrue(result.sawDropBeforeOwnClose, "the Mac must notice the broken link: \(result.events)")
        }
    }
}
