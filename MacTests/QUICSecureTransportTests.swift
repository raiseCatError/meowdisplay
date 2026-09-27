import XCTest
import Network
import Security
import CryptoKit
import X509
import SwiftASN1

/// Real loopback QUIC between two ISOLATED temporary identities, built with
/// the production `TLSConfigurator.pinnedQUICOptions` — never the
/// developer's MeowDisplay Keychain rows: every identity lives in a
/// throwaway file keychain created and deleted by this test case. Covers the
/// pinned-mutual-authentication matrix, ALPN, QUIC-metadata peer resolution
/// and stream multiplexing (an unread Video stream cannot block Control).
///
/// If the runner cannot create a temporary keychain identity the tests skip
/// with the Security status — they never fall back to real identities.
final class QUICSecureTransportTests: XCTestCase {

    private struct TestIdentity {
        let identity: SecIdentity
        let spki: Data
    }

    private var keychain: SecKeychain?
    private var keychainPath = ""
    private let queue = DispatchQueue(label: "quic.secure.transport.tests")

    override func setUpWithError() throws {
        try super.setUpWithError()
        keychainPath = NSTemporaryDirectory() + "meowdisplay-quic-tests-\(UUID().uuidString).keychain"
        let password = UUID().uuidString
        var created: SecKeychain?
        let status = SecKeychainCreate(keychainPath, UInt32(password.utf8.count), password, false, nil, &created)
        guard status == errSecSuccess, let created else {
            throw XCTSkip("temporary keychain unavailable on this runner (status \(status))")
        }
        keychain = created
    }

    override func tearDown() {
        if let keychain { SecKeychainDelete(keychain) }
        keychain = nil
        try? FileManager.default.removeItem(atPath: keychainPath)
        super.tearDown()
    }

    /// A fresh P-256 identity whose private key is generated INSIDE the
    /// temporary keychain (file keychains refuse raw EC key imports). The
    /// certificate carries that key's SPKI; its signature comes from a
    /// throwaway key, which is irrelevant here exactly as in production:
    /// MeowDisplay pins the leaf SPKI and never evaluates the chain, while
    /// the TLS handshake itself proves possession of the keychain key.
    private func makeIdentity() throws -> TestIdentity {
        guard let keychain else { throw XCTSkip("no temporary keychain") }
        var cfError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecUseKeychain: keychain,
            kSecPrivateKeyAttrs: [kSecAttrIsPermanent: true],
        ] as CFDictionary, &cfError),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let x963 = SecKeyCopyExternalRepresentation(publicKey, &cfError) as Data?,
              let p256 = try? P256.Signing.PublicKey(x963Representation: x963) else {
            throw XCTSkip("temporary keychain key unavailable: \(String(describing: cfError?.takeRetainedValue()))")
        }
        let signer = Certificate.PrivateKey(P256.Signing.PrivateKey())
        let name = try DistinguishedName { CommonName("meowdisplay-quic-test-\(UUID().uuidString)") }
        let now = Date()
        let certificate = try Certificate(
            version: .v3, serialNumber: Certificate.SerialNumber(), publicKey: Certificate.PublicKey(p256),
            notValidBefore: now.addingTimeInterval(-3600), notValidAfter: now.addingTimeInterval(3600),
            issuer: name, subject: name, signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions { Critical(BasicConstraints.notCertificateAuthority) },
            issuerPrivateKey: signer)
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        guard let secCert = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData) else {
            throw XCTSkip("could not build test certificate")
        }
        var status = SecItemAdd([kSecClass: kSecClassCertificate, kSecValueRef: secCert,
                                 kSecUseKeychain: keychain] as CFDictionary, nil)
        guard status == errSecSuccess else { throw XCTSkip("temporary certificate import failed (status \(status))") }
        var identity: SecIdentity?
        status = SecIdentityCreateWithCertificate(keychain, secCert, &identity)
        guard status == errSecSuccess, let identity else {
            throw XCTSkip("temporary identity unavailable (status \(status))")
        }
        return TestIdentity(identity: identity, spki: p256.derRepresentation)
    }

    // MARK: - Harness

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var _prefaces: [TransportChannel] = []
        private var _serverPeerSPKI: Data?
        private var _clientError: NWError?
        private var _clientReady = false
        private var _controlPayload: Data?
        private var _serverStreams: [NWConnection] = []
        private var _peerRejected = false
        private var _peerAccepted = false
        func peerRejected() { lock.lock(); _peerRejected = true; lock.unlock() }
        func peerAccepted() { lock.lock(); _peerAccepted = true; lock.unlock() }
        var wasPeerAccepted: Bool { lock.lock(); defer { lock.unlock() }; return _peerAccepted }
        var wasPeerRejected: Bool { lock.lock(); defer { lock.unlock() }; return _peerRejected }
        func preface(_ c: TransportChannel) { lock.lock(); _prefaces.append(c); lock.unlock() }
        func serverPeer(_ d: Data?) { lock.lock(); _serverPeerSPKI = d; lock.unlock() }
        func clientError(_ e: NWError) { lock.lock(); if _clientError == nil { _clientError = e }; lock.unlock() }
        func clientReady() { lock.lock(); _clientReady = true; lock.unlock() }
        func control(_ d: Data) { lock.lock(); _controlPayload = d; lock.unlock() }
        func keep(_ s: NWConnection) { lock.lock(); _serverStreams.append(s); lock.unlock() }
        var prefaces: [TransportChannel] { lock.lock(); defer { lock.unlock() }; return _prefaces }
        var serverPeerSPKI: Data? { lock.lock(); defer { lock.unlock() }; return _serverPeerSPKI }
        var error: NWError? { lock.lock(); defer { lock.unlock() }; return _clientError }
        var isClientReady: Bool { lock.lock(); defer { lock.unlock() }; return _clientReady }
        var controlPayload: Data? { lock.lock(); defer { lock.unlock() }; return _controlPayload }
        func cancelServerStreams() {
            lock.lock(); let all = _serverStreams; lock.unlock()
            all.forEach { $0.cancel() }
        }
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Starts a receiver-shaped QUIC listener (production options, the same
    /// stream limits and the SAME listener parameters `QUICReceiverListener`
    /// uses — `listenerParameters(quic:)`). The server never reads
    /// the Video stream past its preface — so if Control only arrived behind
    /// Video, it would never arrive at all.
    private func startServer(identity: TestIdentity, pinned: [Data], outcome: Outcome) throws -> NWListener {
        let options = try XCTUnwrap(TLSConfigurator.pinnedQUICOptions(
            identity: identity.identity, pinnedSPKIs: { pinned }, isListener: true, queue: queue))
        QUICReceiverListener.configureStreamLimits(options)
        let listener = try NWListener(using: QUICReceiverListener.listenerParameters(quic: options), on: .any)
        let queue = self.queue
        listener.newConnectionGroupHandler = { group in
            group.newConnectionHandler = { stream in
                outcome.keep(stream)
                stream.start(queue: queue)
                stream.receive(minimumIncompleteLength: 8, maximumLength: 8) { data, _, _, _ in
                    guard let data, case .parsed(let preface, _) = QUICStreamPreface.parse(data) else { return }
                    outcome.preface(preface.channel)
                    if preface.channel == .control {
                        outcome.serverPeer(TLSConfigurator.authenticatedPeerSPKI(of: stream))
                        stream.receive(minimumIncompleteLength: 5, maximumLength: 64) { payload, _, _, _ in
                            if let payload { outcome.control(payload) }
                        }
                    }
                }
            }
            group.start(queue: queue)
        }
        listener.start(queue: queue)
        waitUntil(5) { listener.port != nil && listener.state == .ready }
        guard listener.state == .ready else { throw XCTSkip("loopback QUIC listener unavailable (\(listener.state))") }
        return listener
    }

    /// Dials like `MacSenderTransportController.connectQUIC`: opens Video
    /// first (a large write nobody reads), then Control with one message.
    private func dial(port: NWEndpoint.Port, options: NWProtocolQUIC.Options, outcome: Outcome) -> NWConnectionGroup {
        let group = NWConnectionGroup(with: NWMultiplexGroup(to: .hostPort(host: "127.0.0.1", port: port)),
                                      using: NWParameters(quic: options))
        let queue = self.queue
        group.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.clientReady()
                let video: NWConnection? = NWConnection(from: group)
                let control: NWConnection? = NWConnection(from: group)
                guard let video, let control else { return }
                video.start(queue: queue)
                video.send(content: QUICStreamPreface(channel: .video).encode()
                    + QUICFrameAssembler.frame(Data(repeating: 0x42, count: 8 << 20)),
                           completion: .contentProcessed { _ in })
                control.start(queue: queue)
                control.send(content: QUICStreamPreface(channel: .control).encode()
                    + QUICFrameAssembler.frame(Data(#"{"type":"hello"}"#.utf8)),
                             completion: .contentProcessed { _ in })
            case .failed(let error), .waiting(let error):
                outcome.clientError(error)
            default:
                break
            }
        }
        // Required by Network.framework before `start` (a group with neither
        // handler refuses to start); production sets the same rejecting
        // handler (`MacSenderTransportController.connectQUIC`).
        group.newConnectionHandler = { stream in stream.cancel() }
        group.start(queue: queue)
        return group
    }

    private func clientOptions(_ identity: TestIdentity?, pinning server: Data,
                               alpn: String = QUICTransport.alpn,
                               rejected: Outcome? = nil) throws -> NWProtocolQUIC.Options {
        if let identity {
            return try XCTUnwrap(TLSConfigurator.pinnedQUICOptions(
                identity: identity.identity, pinnedSPKIs: { [server] }, isListener: false, queue: queue, alpn: alpn,
                onPeerVerification: { accepted in
                    if accepted { rejected?.peerAccepted() } else { rejected?.peerRejected() }
                }))
        }
        // No client certificate at all, but otherwise the production pin check.
        let options = NWProtocolQUIC.Options(alpn: [alpn])
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            complete(chain?.first.flatMap(TLSConfigurator.spkiDER(of:)) == server)
        }, queue)
        return options
    }

    private func run(server: TestIdentity, serverPins: [Data], client: NWProtocolQUIC.Options,
                     outcome: Outcome = Outcome()) throws -> Outcome {
        let listener = try startServer(identity: server, pinned: serverPins, outcome: outcome)
        let group = dial(port: try XCTUnwrap(listener.port), options: client, outcome: outcome)
        waitUntil(6) { outcome.controlPayload != nil || outcome.error != nil || outcome.wasPeerRejected }
        // Give a rejected handshake a moment to surface on both sides.
        if outcome.controlPayload == nil { waitUntil(1) { false } }
        group.cancel()
        outcome.cancelServerStreams()
        listener.cancel()
        return outcome
    }

    // MARK: - Tests

    func testCorrectMutualPinsConnectAndMultiplex() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let outcome = try run(server: server, serverPins: [client.spki],
                              client: try clientOptions(client, pinning: server.spki))
        XCTAssertTrue(outcome.prefaces.contains(.control))
        XCTAssertTrue(outcome.prefaces.contains(.video))
        XCTAssertEqual(outcome.serverPeerSPKI, client.spki,
                       "QUIC metadata resolves the same pinned SPKI TLS does")
        // 8 MiB of Video was never read by the server, yet Control arrived:
        // the streams are independent, not one ordered byte stream.
        XCTAssertEqual(outcome.controlPayload, QUICFrameAssembler.frame(Data(#"{"type":"hello"}"#.utf8)))
    }

    func testWrongServerPinFailsAsSecurity() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let impostorPin = try makeIdentity().spki
        let outcome = Outcome()
        _ = try run(server: server, serverPins: [client.spki],
                    client: try clientOptions(client, pinning: impostorPin, rejected: outcome), outcome: outcome)
        XCTAssertTrue(outcome.prefaces.isEmpty, "no stream may reach an unpinned server")
        XCTAssertNil(outcome.controlPayload)
        // The client's own pin check refused the server and said so — which
        // `MacSenderTransportController` turns into a `.security` failure at
        // once (never a timeout that could read as "QUIC unreachable").
        XCTAssertTrue(outcome.wasPeerRejected, "the pin rejection must be reported to the dialer")
        if let error = outcome.error {
            XCTAssertNotEqual(QUICFailureClassifier.classify(error), .reachability,
                              "a pin mismatch must never look like a reachability failure (\(error))")
        }
    }

    func testWrongClientPinFails() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let otherPin = try makeIdentity().spki
        let outcome = Outcome()
        _ = try run(server: server, serverPins: [otherPin],
                    client: try clientOptions(client, pinning: server.spki, rejected: outcome), outcome: outcome)
        XCTAssertNil(outcome.controlPayload)
        XCTAssertNil(outcome.serverPeerSPKI)
        // The receiver refusing this Mac's certificate must not read as a
        // reachability failure on the dialing side (no silent TCP fallback).
        // The raw POSIX code is unreliable here (ENOTCONN / ENETDOWN were both
        // observed), which is why the dialer refines it with its own verdict
        // on the receiver's pin — exactly as `failQUIC` does.
        XCTAssertTrue(outcome.wasPeerAccepted, "the Mac did verify the receiver before being refused")
        if let error = outcome.error {
            let refined = QUICFailureClassifier.refine(QUICFailureClassifier.classify(error),
                                                       peerVerified: outcome.wasPeerAccepted)
            XCTAssertNotEqual(refined, .reachability, "\(error)")
        }
    }

    func testUnknownPinFails() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let outcome = try run(server: server, serverPins: [],
                              client: try clientOptions(client, pinning: server.spki))
        XCTAssertNil(outcome.controlPayload)
    }

    func testMissingClientCertificateFails() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let outcome = try run(server: server, serverPins: [client.spki],
                              client: try clientOptions(nil, pinning: server.spki))
        XCTAssertNil(outcome.controlPayload, "the listener requires a client certificate")
        XCTAssertNil(outcome.serverPeerSPKI)
    }

    func testALPNMismatchFails() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let outcome = try run(server: server, serverPins: [client.spki],
                              client: try clientOptions(client, pinning: server.spki, alpn: "not-meowdisplay/1"))
        XCTAssertNil(outcome.controlPayload)
        XCTAssertTrue(outcome.prefaces.isEmpty)
    }

    /// Transport authentication succeeds, but the pinned key belongs to a
    /// different device than the one this session was built for: the
    /// application hello check (`SenderSessionAuthorizationState`) rejects
    /// it — which stops the session, it never downgrades.
    func testAuthenticatedPeerIDMismatchIsRejected() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let outcome = try run(server: server, serverPins: [client.spki],
                              client: try clientOptions(client, pinning: server.spki))
        let authenticated = try XCTUnwrap(outcome.serverPeerSPKI)
        var state = SenderSessionAuthorizationState()
        state.transportBegan(generation: 1)
        let verdict = state.acceptHello(
            generation: 1, intendedPeerID: "device-A", claimedPeerID: "device-B",
            authenticatedSPKI: authenticated, currentPinnedSPKI: authenticated,
            receiverSupportsInvitations: true, needsSenderApproval: false)
        XCTAssertEqual(verdict, .rejected(.identityMismatch))
        let wrongKey = state.acceptHello(
            generation: 1, intendedPeerID: "device-A", claimedPeerID: "device-A",
            authenticatedSPKI: authenticated, currentPinnedSPKI: server.spki,
            receiverSupportsInvitations: true, needsSenderApproval: false)
        XCTAssertNotEqual(wrongKey, .firstConnection)
        XCTAssertFalse(state.isAdmitted)
    }

    // MARK: - Production receiver path (physical-iPhone regression)

    private func receiverOptions(_ identity: TestIdentity, pinning client: Data) throws -> NWProtocolQUIC.Options {
        let options = try XCTUnwrap(TLSConfigurator.pinnedQUICOptions(
            identity: identity.identity, pinnedSPKIs: { [client] }, isListener: true, queue: queue))
        QUICReceiverListener.configureStreamLimits(options)
        return options
    }

    private final class GroupEvents: @unchecked Sendable {
        private let lock = NSLock()
        private var _controls = 0
        private var _media = 0
        private var _owners: [QUICReceiverGroup] = []
        func control() { lock.lock(); _controls += 1; lock.unlock() }
        func media() { lock.lock(); _media += 1; lock.unlock() }
        func owner(_ o: QUICReceiverGroup) { lock.lock(); _owners.append(o); lock.unlock() }
        var controls: Int { lock.lock(); defer { lock.unlock() }; return _controls }
        var mediaCount: Int { lock.lock(); defer { lock.unlock() }; return _media }
        var owners: [QUICReceiverGroup] { lock.lock(); defer { lock.unlock() }; return _owners }
    }

    /// The real receiver edge — production listener parameters, stream limits
    /// and `QUICReceiverGroup` accept/preface handling — over real QUIC,
    /// dialed the way `MacSenderTransportController.openQUICStreams` does
    /// (three streams opened together, each preface sent right after
    /// `start`). The earlier loopback tests used ad-hoc stream handling and
    /// only two streams, so they missed both defects the physical iPhone hit:
    /// Network.framework's own extra (never-ready) object delivered to
    /// `newConnectionHandler` was treated as a MEOW stream, and a stream
    /// limit of 3 blocked the sender's third stream because stream 0 is
    /// Network.framework's.
    func testProductionReceiverGroupAcceptsAllThreeChannels() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let listener = try NWListener(
            using: QUICReceiverListener.listenerParameters(quic: try receiverOptions(server, pinning: client.spki)),
            on: .any)
        let registry = QUICReceiverGroupRegistry()
        let events = GroupEvents()
        let queue = self.queue
        listener.newConnectionGroupHandler = { group in
            let owner = registry.admit { id in
                QUICReceiverGroup(id: id, group: group, registry: registry, queue: queue,
                                  onControlStream: { _ in events.control() },
                                  onMediaReady: { _ in events.media() })
            }
            guard let owner else { group.cancel(); return }
            events.owner(owner)
            owner.start()
        }
        listener.start(queue: queue)
        waitUntil(5) { listener.port != nil && listener.state == .ready }
        guard listener.state == .ready, let port = listener.port else {
            listener.cancel()
            throw XCTSkip("loopback QUIC listener unavailable (\(listener.state))")
        }

        let group = NWConnectionGroup(with: NWMultiplexGroup(to: .hostPort(host: "127.0.0.1", port: port)),
                                      using: NWParameters(quic: try clientOptions(client, pinning: server.spki)))
        let streams = OutcomeStreams()
        let receiverOpened = GroupEvents()
        group.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            for channel in [TransportChannel.control, .video, .audio] {
                let created: NWConnection? = NWConnection(from: group)
                guard let stream = created else { return }
                streams.keep(stream)
                stream.start(queue: queue)
                stream.send(content: QUICStreamPreface(channel: channel).encode(), completion: .contentProcessed { _ in })
            }
        }
        // Production treats any stream arriving here as a protocol violation.
        group.newConnectionHandler = { stream in
            receiverOpened.control()
            stream.cancel()
        }
        group.start(queue: queue)

        waitUntil(8) { events.controls == 1 && events.mediaCount == 2 }
        XCTAssertEqual(events.controls, 1, "the Control stream reaches the session pipeline")
        XCTAssertEqual(events.mediaCount, 2, "Video and Audio are validated and parked")
        XCTAssertEqual(events.owners.count, 1, "all three streams ride one QUIC connection")
        XCTAssertFalse(events.owners.first?.isClosed ?? true, "a healthy connection is not closed")
        XCTAssertEqual(events.owners.first?.takePendingMedia().count, 2)
        // Past the preface timeout: nothing (e.g. Network.framework's own
        // never-ready object) may close the healthy connection later.
        waitUntil(QUICReceiverLimits.prefaceTimeout + 1) { false }
        XCTAssertFalse(events.owners.first?.isClosed ?? true, "still open after the preface timeout")
        XCTAssertEqual(receiverOpened.controls, 0, "the dialer never sees a receiver-opened stream")

        group.cancel()
        streams.cancelAll()
        registry.closeAll(error: nil)
        listener.cancel()
    }

    private final class ControllerEvents: MacSenderTransportDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let transport: SenderTransport
        private var _ready: [NWConnection] = []
        private var _receiving: [NWConnection] = []
        private var _failures: [QUICTransportFailure] = []
        init(transport: SenderTransport) { self.transport = transport }
        func transportSessionBecameReady(on connection: NWConnection) { lock.lock(); _ready.append(connection); lock.unlock() }
        func transportShouldBeginReceiving(on connection: NWConnection) { lock.lock(); _receiving.append(connection); lock.unlock() }
        func transportPathChanged(_ route: ConnectionRoute?) {}
        func transportSessionInvalidated(reason: String) {}
        func transportLinkDied(_ detail: String) {}
        func transportCancelActiveInput() {}
        func transportPeerDeviceKind() -> String? { nil }
        func transportDialingContext() -> (transport: SenderTransport, peerAddrs: [String]) { (transport, []) }
        func transportQUICFailed(_ failure: QUICTransportFailure) { lock.lock(); _failures.append(failure); lock.unlock() }
        var ready: [NWConnection] { lock.lock(); defer { lock.unlock() }; return _ready }
        var receiving: [NWConnection] { lock.lock(); defer { lock.unlock() }; return _receiving }
        var failures: [QUICTransportFailure] { lock.lock(); defer { lock.unlock() }; return _failures }
    }

    /// The production dialer end to end: `MacSenderTransportController.
    /// connectQUIC` against the production receiver group. Once the group is
    /// ready, the Control stream must be ADOPTED — `becomeReady` flips the
    /// controller ready and starts the control read loop — or the hello is
    /// never sent and the session dies at the handshake timeout. This fails
    /// if that adoption path is removed or the group state policy stops
    /// opening streams.
    func testProductionSenderControllerAdoptsControlStreamOnceReady() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let listener = try NWListener(
            using: QUICReceiverListener.listenerParameters(quic: try receiverOptions(server, pinning: client.spki)),
            on: .any)
        let registry = QUICReceiverGroupRegistry()
        let events = GroupEvents()
        let queue = self.queue
        listener.newConnectionGroupHandler = { group in
            let owner = registry.admit { id in
                QUICReceiverGroup(id: id, group: group, registry: registry, queue: queue,
                                  onControlStream: { _ in events.control() },
                                  onMediaReady: { _ in events.media() })
            }
            guard let owner else { group.cancel(); return }
            events.owner(owner)
            owner.start()
        }
        listener.start(queue: queue)
        waitUntil(5) { listener.port != nil && listener.state == .ready }
        guard listener.state == .ready, let port = listener.port else {
            listener.cancel()
            throw XCTSkip("loopback QUIC listener unavailable (\(listener.state))")
        }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: client.identity),
                                   pinnedPeerSPKI: server.spki, peerID: "quic-controller-test")
        let controllerQueue = DispatchQueue(label: "quic.secure.transport.tests.controller")
        let controller = MacSenderTransportController(queue: controllerQueue, endpointName: "test",
                                                      statusSink: MacSenderStatusSink())
        let delegate = ControllerEvents(transport: .tcp(endpoint, tls: tls))
        controller.delegate = delegate
        let dialed = controllerQueue.sync { controller.connectQUIC(to: endpoint, tls: tls) }
        XCTAssertTrue(dialed)

        waitUntil(6) { delegate.receiving.count == 1 && events.controls == 1 && events.mediaCount == 2 }
        XCTAssertEqual(delegate.ready.count, 1, "the Control stream was adopted (becomeReady)")
        XCTAssertEqual(delegate.receiving.count, 1, "the control read loop was started")
        controllerQueue.sync {
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.activeNetworkProtocol, .quic)
            XCTAssertTrue(controller.currentConnection === delegate.ready.first)
        }
        XCTAssertEqual(events.controls, 1)
        XCTAssertEqual(events.mediaCount, 2)
        XCTAssertTrue(delegate.failures.isEmpty, "no failure before the hello: \(delegate.failures)")

        controllerQueue.sync { controller.cancelAndClearConnection() }
        registry.closeAll(error: nil)
        listener.cancel()
    }

    private final class OutcomeStreams: @unchecked Sendable {
        private let lock = NSLock()
        private var streams: [NWConnection] = []
        func keep(_ s: NWConnection) { lock.lock(); streams.append(s); lock.unlock() }
        func cancelAll() { lock.lock(); let all = streams; lock.unlock(); all.forEach { $0.cancel() } }
    }
}
