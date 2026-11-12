import XCTest
import Network
import Security

/// Issue #219: the Mac app ended right after pairing approval on macOS 15.7.7
/// because the QUIC dial built `NWMultiplexGroup(to:)` from a Bonjour service
/// endpoint, which macOS 15 rejects ("Endpoint Bonjour is of invalid type for
/// multiplex group"). A service is now resolved to its address first and
/// nothing but a host and port ever reaches `NWMultiplexGroup`.
///
/// The real-network tests use loopback Bonjour with a test-only service type
/// (`_meowdisp-qtest._udp`) and throwaway keychain identities. They run on the
/// macOS version of the test Mac; macOS 15's rejection itself is not reproduced here.
final class QUICBonjourEndpointTests: XCTestCase {
    private typealias TestIdentity = TemporaryTestKeychain.Identity
    private static let testServiceType = "_meowdisp-qtest._udp"

    private var keychain: TemporaryTestKeychain?
    private let queue = DispatchQueue(label: "quic.bonjour.endpoint.tests")

    override func setUpWithError() throws {
        try super.setUpWithError()
        keychain = try? TemporaryTestKeychain(prefix: "meowdisplay-quic-bonjour-tests")
    }

    override func tearDown() {
        keychain?.delete()
        keychain = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeIdentity() throws -> TestIdentity {
        guard let keychain else { throw securityTestUnavailable("no temporary keychain") }
        return try keychain.makeIdentity()
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func uniqueName() -> String { "meow-219-\(UUID().uuidString.prefix(8))" }

    private func service(_ name: String) -> NWEndpoint {
        .service(name: name, type: Self.testServiceType, domain: "local.", interface: nil)
    }

    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [T] = []
        func append(_ value: T) { lock.lock(); _values.append(value); lock.unlock() }
        var values: [T] { lock.lock(); defer { lock.unlock() }; return _values }
    }

    private final class ControllerEvents: MacSenderTransportDelegate, @unchecked Sendable {
        private let transport: SenderTransport
        let ready = Box<NWConnection>()
        let receiving = Box<NWConnection>()
        let failures = Box<QUICTransportFailure>()
        init(transport: SenderTransport) { self.transport = transport }
        func transportSessionBecameReady(on connection: NWConnection) { ready.append(connection) }
        func transportShouldBeginReceiving(on connection: NWConnection) { receiving.append(connection) }
        func transportPathChanged(_ route: ConnectionRoute?) {}
        func transportSessionInvalidated(reason: String) {}
        func transportLinkDied(_ detail: String) {}
        func transportCancelActiveInput() {}
        func transportPeerDeviceKind() -> String? { nil }
        func transportDialingContext() -> (transport: SenderTransport, peerAddrs: [String]) { (transport, []) }
        func transportQUICFailed(_ failure: QUICTransportFailure) { failures.append(failure) }
    }

    /// A production receiver QUIC listener advertised over Bonjour as `name`.
    private func startAdvertisedReceiver(name: String, server: TestIdentity, client: TestIdentity,
                                         controls: Box<Int>) throws -> (NWListener, QUICReceiverGroupRegistry) {
        let options = try XCTUnwrap(TLSConfigurator.pinnedQUICOptions(
            identity: server.identity, pinnedSPKIs: { [client.spki] }, isListener: true, queue: queue))
        QUICReceiverListener.configureStreamLimits(options)
        let listener = try NWListener(using: QUICReceiverListener.listenerParameters(quic: options), on: .any)
        listener.service = NWListener.Service(name: name, type: Self.testServiceType, domain: "local.")
        let registry = QUICReceiverGroupRegistry()
        let queue = self.queue
        listener.newConnectionGroupHandler = { group in
            let owner = registry.admit { id in
                QUICReceiverGroup(id: id, group: group, registry: registry, queue: queue,
                                  onControlStream: { _ in controls.append(1) }, onMediaReady: { _ in })
            }
            guard let owner else { group.cancel(); return }
            owner.start()
        }
        let registered = Box<Bool>()
        listener.serviceRegistrationUpdateHandler = { change in
            if case .add = change { registered.append(true) }
        }
        listener.start(queue: queue)
        waitUntil(5) { listener.state == .ready && !registered.values.isEmpty }
        guard listener.state == .ready, !registered.values.isEmpty else {
            listener.cancel()
            throw XCTSkip("Bonjour advertising unavailable to the test runner (\(listener.state))")
        }
        return (listener, registry)
    }

    private func makeController(for endpoint: NWEndpoint, tls: TLSSessionConfig)
        -> (MacSenderTransportController, ControllerEvents, DispatchQueue) {
        let controllerQueue = DispatchQueue(label: "quic.bonjour.endpoint.tests.controller")
        let controller = MacSenderTransportController(queue: controllerQueue, endpointName: "test",
                                                      statusSink: MacSenderStatusSink())
        let events = ControllerEvents(transport: .tcp(endpoint, tls: tls))
        controller.delegate = events
        return (controller, events, controllerQueue)
    }

    // MARK: - Endpoint shapes (pure)

    func testOnlyAHostAndPortGoesToTheMultiplexGroup() {
        let address = NWEndpoint.hostPort(host: "192.168.1.20", port: 9001)
        let named = NWEndpoint.hostPort(host: "mac-mini.tailnet.ts.net", port: 9001)
        let bonjour = service("phone")
        XCTAssertEqual(QUICDialEndpoint(address), .direct(address))
        XCTAssertEqual(QUICDialEndpoint(named), .direct(named))
        XCTAssertEqual(QUICDialEndpoint(bonjour), .resolveService(bonjour))
        XCTAssertEqual(QUICDialEndpoint(.unix(path: "/tmp/x")), .unsupported)
        XCTAssertTrue(QUICDialEndpoint.isMultiplexable(address))
        XCTAssertTrue(QUICDialEndpoint.isMultiplexable(named))
        XCTAssertFalse(QUICDialEndpoint.isMultiplexable(bonjour), "#219: never a Bonjour service")
        XCTAssertFalse(QUICDialEndpoint.isMultiplexable(.unix(path: "/tmp/x")))
    }

    func testTheQUICEndpointKeepsTheRouteItCameFrom() throws {
        // Remote Access (Tailscale or a typed address): same host and port, over UDP.
        let remote = NWEndpoint.hostPort(host: "100.101.102.103", port: 9001)
        XCTAssertEqual(TransportProtocolInputsResolver.quicEndpoint(for: remote, peerID: "p", hints: QUICDiscoveryHintStore()),
                       remote)
        // Bonjour without a hint: the same instance, domain and interface, QUIC service type.
        let wifi = try XCTUnwrap(NWInterface.loopbackForTests())
        let tcp = NWEndpoint.service(name: "iPhone", type: "_meowdisp._tcp", domain: "local.", interface: wifi)
        let quic = TransportProtocolInputsResolver.quicEndpoint(for: tcp, peerID: "p", hints: QUICDiscoveryHintStore())
        XCTAssertEqual(quic, .service(name: "iPhone", type: QUICTransport.bonjourServiceType, domain: "local.", interface: wifi))
        // With a discovery hint: the hint's browse result (still a service, so it is resolved before dialing).
        let hints = QUICDiscoveryHintStore()
        let hinted = NWEndpoint.service(name: "iPhone", type: QUICTransport.bonjourServiceType, domain: "local.", interface: nil)
        hints.replaceAll([.init(hint: QUICDiscoveryHint(txt: ["id": "p", "qv": "\(QUICTransport.applicationVersion)"])!,
                                endpoint: hinted)])
        XCTAssertEqual(TransportProtocolInputsResolver.quicEndpoint(for: tcp, peerID: "p", hints: hints), hinted)
        XCTAssertEqual(QUICDialEndpoint(hinted), .resolveService(hinted))
        // A hint for another device is not used; an unknown endpoint kind gets no QUIC at all.
        XCTAssertEqual(TransportProtocolInputsResolver.quicEndpoint(for: tcp, peerID: "other", hints: hints), quic)
        XCTAssertNil(TransportProtocolInputsResolver.quicEndpoint(for: .unix(path: "/tmp/x"), peerID: "p",
                                                                  hints: QUICDiscoveryHintStore()))
    }

    // MARK: - Policy for a service that doesn't resolve

    func testAnUnresolvedServiceFollowsTheReachabilityPolicyAndNeverDowngradesOtherwise() {
        // Resolution failing in time is `.reachability`: Auto may use secure TCP...
        var auto = TransportProtocolSelector()
        XCTAssertEqual(auto.quicFailed(.reachability, preference: .auto), .fallbackToTCP)
        // ...explicit QUIC never does...
        var explicit = TransportProtocolSelector()
        XCTAssertEqual(explicit.quicFailed(.reachability, preference: .quic), .retryQUIC)
        // ...explicit TCP never dials QUIC in the first place...
        let tcpOnly = TransportProtocolSelector().decide(.init(
            preference: .tcp, localQUICAvailable: true, peerSupport: .authenticated, routeKind: .local, cooldownActive: false))
        XCTAssertEqual(tcpOnly, .tcp)
        // ...and security or protocol failures still stop, whatever the preference.
        for preference in [NetworkTransportPreference.auto, .quic] {
            var selector = TransportProtocolSelector()
            XCTAssertEqual(selector.quicFailed(.security, preference: preference), .stop(.security))
            XCTAssertEqual(selector.quicFailed(.protocolViolation, preference: preference), .stop(.protocolViolation))
        }
    }

    func testAutoTriesQUICOnAFreshHintAndTCPWithoutOne() {
        let selector = TransportProtocolSelector()
        func decide(_ support: PeerQUICSupport, _ route: NetworkRouteKind, _ preference: NetworkTransportPreference = .auto)
            -> TransportProtocolSelector.Decision {
            selector.decide(.init(preference: preference, localQUICAvailable: true, peerSupport: support,
                                  routeKind: route, cooldownActive: false))
        }
        XCTAssertEqual(decide(.discoveryHint, .local), .quic, "the #219 path: a fresh pairing with a QUIC hint")
        XCTAssertEqual(decide(.unknown, .local), .tcp, "no or stale hint: TCP")
        XCTAssertEqual(decide(.discoveryHint, .remote), .tcp, "a hint never opens QUIC on Remote")
        XCTAssertEqual(decide(.authenticated, .remote), .quic)
        if case .unavailable = decide(.unknown, .local, .quic) {} else { XCTFail("explicit QUIC without support is unavailable, not TCP") }
    }

    // MARK: - Real Network.framework

    func testABonjourQUICServiceResolvesToItsAddress() throws {
        let listener = try NWListener(using: .udp, on: .any)
        let name = uniqueName()
        listener.service = NWListener.Service(name: name, type: Self.testServiceType, domain: "local.")
        let registered = Box<Bool>()
        listener.serviceRegistrationUpdateHandler = { if case .add = $0 { registered.append(true) } }
        listener.newConnectionHandler = { $0.cancel() }
        listener.start(queue: queue)
        waitUntil(5) { listener.state == .ready && !registered.values.isEmpty }
        defer { listener.cancel() }
        guard listener.state == .ready, !registered.values.isEmpty, let port = listener.port else {
            throw XCTSkip("Bonjour advertising unavailable to the test runner (\(listener.state))")
        }

        let outcomes = Box<QUICServiceResolver.Outcome>()
        let resolver = QUICServiceResolver(service: service(name), queue: queue) { outcomes.append($0) }
        queue.sync { resolver.start() }
        waitUntil(6) { !outcomes.values.isEmpty }
        guard case .resolved(let resolved)? = outcomes.values.first else {
            return XCTFail("not resolved: \(String(describing: outcomes.values.first))")
        }
        guard case .hostPort(_, let resolvedPort) = resolved.endpoint else {
            return XCTFail("resolved to \(resolved.endpoint), not a host and port")
        }
        XCTAssertEqual(resolvedPort, port)
        XCTAssertTrue(QUICDialEndpoint.isMultiplexable(resolved.endpoint))
        XCTAssertNil(resolved.interface, "a service that named no interface gets none forced on it")
        XCTAssertEqual(outcomes.values.count, 1)
    }

    func testAServiceThatNeverAppearsFailsAsReachabilityInTime() {
        let outcomes = Box<QUICServiceResolver.Outcome>()
        let resolver = QUICServiceResolver(service: service(uniqueName()), queue: queue, timeout: 1) { outcomes.append($0) }
        queue.sync { resolver.start() }
        waitUntil(4) { !outcomes.values.isEmpty }
        guard case .failed(let failureClass, _, _)? = outcomes.values.first else {
            return XCTFail("expected a failure, got \(String(describing: outcomes.values.first))")
        }
        XCTAssertEqual(failureClass, .reachability)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(outcomes.values.count, 1, "reported once")
    }

    func testACancelledResolutionReportsNothing() {
        let outcomes = Box<QUICServiceResolver.Outcome>()
        let resolver = QUICServiceResolver(service: service(uniqueName()), queue: queue, timeout: 0.5) { outcomes.append($0) }
        queue.sync { resolver.start(); resolver.cancel() }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(outcomes.values.isEmpty)
    }

    /// The #219 path end to end: the production controller dials a Bonjour
    /// QUIC service (what Auto chooses right after pairing when the receiver
    /// advertises QUIC) with pinned mutual TLS and adopts the Control stream.
    func testTheControllerDialsABonjourQUICServiceAndAdoptsTheSession() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let controls = Box<Int>()
        let name = uniqueName()
        let (listener, registry) = try startAdvertisedReceiver(name: name, server: server, client: client, controls: controls)
        defer { registry.closeAll(error: nil); listener.cancel() }

        let endpoint = service(name)
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: client.identity),
                                   pinnedPeerSPKI: server.spki, peerID: "quic-219")
        let (controller, events, controllerQueue) = makeController(for: endpoint, tls: tls)
        XCTAssertTrue(controllerQueue.sync { controller.connectQUIC(to: endpoint, tls: tls) })

        waitUntil(10) { events.receiving.values.count == 1 && controls.values.count == 1 }
        XCTAssertEqual(events.ready.values.count, 1, "the Control stream was adopted")
        XCTAssertEqual(events.receiving.values.count, 1)
        XCTAssertTrue(events.failures.values.isEmpty, "\(events.failures.values.map(\.detail))")
        controllerQueue.sync {
            XCTAssertTrue(controller.isReady)
            XCTAssertEqual(controller.activeNetworkProtocol, .quic)
            controller.cancelAndClearConnection()
        }
    }

    /// The pin still decides: a Bonjour service answered by the wrong identity
    /// fails as security, never as something Auto would fall back from.
    func testAResolvedServiceWithTheWrongIdentityFailsAsSecurity() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let impostor = try makeIdentity()
        let controls = Box<Int>()
        let name = uniqueName()
        let (listener, registry) = try startAdvertisedReceiver(name: name, server: impostor, client: client, controls: controls)
        defer { registry.closeAll(error: nil); listener.cancel() }

        let endpoint = service(name)
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: client.identity),
                                   pinnedPeerSPKI: server.spki, peerID: "quic-219-pin")
        let (controller, events, controllerQueue) = makeController(for: endpoint, tls: tls)
        XCTAssertTrue(controllerQueue.sync { controller.connectQUIC(to: endpoint, tls: tls) })
        waitUntil(12) { !events.failures.values.isEmpty }
        XCTAssertEqual(events.failures.values.first?.failureClass, .security)
        XCTAssertTrue(events.ready.values.isEmpty)
        controllerQueue.sync { controller.cancelAndClearConnection() }
    }

    func testAnUnsupportedEndpointFailsGracefullyWithoutATunnel() throws {
        let identity = try makeIdentity()
        let endpoint = NWEndpoint.unix(path: "/nonexistent/meowdisplay-219")
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: identity.identity),
                                   pinnedPeerSPKI: identity.spki, peerID: "quic-219-unsupported")
        let (controller, events, controllerQueue) = makeController(for: endpoint, tls: tls)
        XCTAssertTrue(controllerQueue.sync { controller.connectQUIC(to: endpoint, tls: tls) })
        waitUntil(2) { !events.failures.values.isEmpty }
        XCTAssertEqual(events.failures.values.count, 1)
        XCTAssertEqual(events.failures.values.first?.failureClass, .reachability)
        XCTAssertEqual(events.failures.values.first?.established, false)
        controllerQueue.sync {
            XCTAssertFalse(controller.isReady)
            XCTAssertNil(controller.currentConnection)
        }
    }

    /// Redialing while a service is still resolving (reconnects, pairing
    /// approval followed by the first secure dial) leaves exactly one session
    /// and no failure from the superseded dials.
    func testRepeatedDialsWhileResolvingEndInOneSession() throws {
        let server = try makeIdentity()
        let client = try makeIdentity()
        let controls = Box<Int>()
        let name = uniqueName()
        let (listener, registry) = try startAdvertisedReceiver(name: name, server: server, client: client, controls: controls)
        defer { registry.closeAll(error: nil); listener.cancel() }

        let endpoint = service(name)
        let tls = TLSSessionConfig(identity: SendableSecIdentity(value: client.identity),
                                   pinnedPeerSPKI: server.spki, peerID: "quic-219-repeat")
        let (controller, events, controllerQueue) = makeController(for: endpoint, tls: tls)
        controllerQueue.sync {
            for _ in 0..<3 { XCTAssertTrue(controller.connectQUIC(to: endpoint, tls: tls)) }
            controller.cancelAndClearConnection()
            XCTAssertTrue(controller.connectQUIC(to: endpoint, tls: tls))
        }
        waitUntil(10) { events.receiving.values.count >= 1 && controls.values.count >= 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(events.ready.values.count, 1, "one session")
        XCTAssertEqual(controls.values.count, 1, "the receiver saw one tunnel's Control stream")
        XCTAssertTrue(events.failures.values.isEmpty, "\(events.failures.values.map(\.detail))")
        controllerQueue.sync { controller.cancelAndClearConnection() }
    }
}

private final class InterfaceHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: NWInterface?
    func set(_ value: NWInterface?) { lock.lock(); _value = value; lock.unlock() }
    var value: NWInterface? { lock.lock(); defer { lock.unlock() }; return _value }
}

private extension NWInterface {
    /// The loopback interface, for building an interface-scoped endpoint.
    static func loopbackForTests() -> NWInterface? {
        let monitor = NWPathMonitor(requiredInterfaceType: .loopback)
        let holder = InterfaceHolder()
        let done = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            holder.set(path.availableInterfaces.first)
            done.signal()
        }
        monitor.start(queue: DispatchQueue(label: "loopback.interface.lookup"))
        _ = done.wait(timeout: .now() + 2)
        monitor.cancel()
        return holder.value
    }
}
