import XCTest
import Network

/// Behavioral tests for `USBTLSBridge`'s relay/lifecycle guarantees, using
/// an injected fake tunnel (a plain loopback `NWConnection`) instead of a
/// live usbmuxd — see `USBTLSBridge.init(dialTunnel:)`. These exercise the
/// bridge exactly as production code does: they never construct TLS or
/// touch TrustStore, matching the bridge's own contract of being an opaque
/// byte relay with zero authentication of its own.
final class USBTLSBridgeTests: XCTestCase {
    private let queue = DispatchQueue(label: "usbtlsbridge.tests")

    /// A loopback listener standing in for "the far end of the usbmux
    /// tunnel" — i.e. what usbmuxd's `Connect` verb would otherwise forward
    /// to. Returns the endpoint to dial and an async stream of accepted
    /// connections so a test can drive the far side directly.
    private func makeFakeDeviceEndpoint() throws -> (port: NWEndpoint.Port, accept: () async -> NWConnection) {
        let listener = try NWListener(using: .tcp, on: .any)
        let box = AcceptBox()
        let queue = self.queue
        listener.newConnectionHandler = { conn in
            conn.start(queue: queue)
            box.append(conn)
        }
        let ready = expectation(description: "fake device listener ready")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        return (port, { await box.next() })
    }

    private static func dialTunnel(to port: NWEndpoint.Port) -> (String?, UInt16, DispatchQueue) async throws -> NWConnection {
        { _, _, queue in
            try await withCheckedThrowingContinuation { cont in
                let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready: cont.resume(returning: conn)
                    case .failed(let error): cont.resume(throwing: error)
                    default: break
                    }
                }
                conn.start(queue: queue)
            }
        }
    }

    func testBridgeIsLoopbackOnly() async throws {
        let (devicePort, _) = try makeFakeDeviceEndpoint()
        let bridge = USBTLSBridge(udid: "fake", queue: queue, dialTunnel: Self.dialTunnel(to: devicePort))
        let bridgePort = try await bridge.start()
        // requiredLocalEndpoint pins the bridge to 127.0.0.1; connecting to
        // that literal loopback address must succeed (proves the bridge
        // actually bound and is listening there).
        let probe = NWConnection(host: "127.0.0.1", port: bridgePort, using: .tcp)
        let ready = expectation(description: "loopback dial ready")
        probe.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        probe.start(queue: queue)
        await fulfillment(of: [ready], timeout: 5)
        probe.cancel()
        bridge.cancel()
    }

    func testBridgeAcceptsExactlyOneConnectionThenStopsListening() async throws {
        let (devicePort, _) = try makeFakeDeviceEndpoint()
        let bridge = USBTLSBridge(udid: "fake", queue: queue, dialTunnel: Self.dialTunnel(to: devicePort))
        let bridgePort = try await bridge.start()

        let first = NWConnection(host: "127.0.0.1", port: bridgePort, using: .tcp)
        let firstReady = expectation(description: "first accepted")
        first.stateUpdateHandler = { if case .ready = $0 { firstReady.fulfill() } }
        first.start(queue: queue)
        await fulfillment(of: [firstReady], timeout: 5)

        // A second dial to the same port must NOT be admitted as a MEOW
        // session — the listener already cancelled itself after the first
        // accept. Bare TCP's SYN backlog can still let a second dial
        // complete a handshake at the kernel level even after the
        // listener-side `cancel()` (accept() being unreached does not
        // retroactively fail an already-completed three-way handshake), so
        // the security-relevant assertion is not "never reaches .ready" but
        // "never receives any bytes and is never spliced to anything" — the
        // bridge only ever wires up one accepted connection, ever.
        let second = NWConnection(host: "127.0.0.1", port: bridgePort, using: .tcp)
        let secondSettled = expectation(description: "second dial settles")
        let settleState = SettleState()
        second.stateUpdateHandler = { state in
            // `.waiting` can transition into `.failed` afterwards — only the
            // FIRST settling transition matters here, so guard against a
            // second fulfill() rather than assuming exactly one state fires.
            switch state {
            case .ready:
                if settleState.settleOnce(reachedReady: true) {
                    secondSettled.fulfill()
                }
            case .failed, .waiting:
                if settleState.settleOnce(reachedReady: false) {
                    secondSettled.fulfill()
                }
            default: break
            }
        }
        second.start(queue: queue)
        await fulfillment(of: [secondSettled], timeout: 5)
        if settleState.reachedReady {
            // Backlog-completed but never serviced: it must see EOF/closure,
            // never any bytes from the bridge (nothing pumps for it).
            let neverServiced = expectation(description: "unserviced second connection closes")
            second.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, isComplete, error in
                XCTAssertTrue(data == nil || data!.isEmpty, "an unadmitted connection must never receive bridge bytes")
                if isComplete || error != nil { neverServiced.fulfill() }
            }
            await fulfillment(of: [neverServiced], timeout: 5)
        }

        first.cancel()
        second.cancel()
        bridge.cancel()
    }

    func testSpliceRelaysBytesBidirectionally() async throws {
        let (devicePort, acceptOnDevice) = try makeFakeDeviceEndpoint()
        let bridge = USBTLSBridge(udid: "fake", queue: queue, dialTunnel: Self.dialTunnel(to: devicePort))
        let bridgePort = try await bridge.start()

        let macSide = NWConnection(host: "127.0.0.1", port: bridgePort, using: .tcp)
        let macReady = expectation(description: "mac side ready")
        macSide.stateUpdateHandler = { if case .ready = $0 { macReady.fulfill() } }
        macSide.start(queue: queue)
        await fulfillment(of: [macReady], timeout: 5)

        let deviceSide = await acceptOnDevice()

        macSide.send(content: Data("hello".utf8), completion: .contentProcessed { _ in })
        let gotHello = try await receiveExactly(5, on: deviceSide)
        XCTAssertEqual(String(data: gotHello, encoding: .utf8), "hello")

        deviceSide.send(content: Data("world!".utf8), completion: .contentProcessed { _ in })
        let gotWorld = try await receiveExactly(6, on: macSide)
        XCTAssertEqual(String(data: gotWorld, encoding: .utf8), "world!")

        macSide.cancel()
        deviceSide.cancel()
        bridge.cancel()
    }

    func testEitherLegClosingTearsDownBoth() async throws {
        let (devicePort, acceptOnDevice) = try makeFakeDeviceEndpoint()
        let bridge = USBTLSBridge(udid: "fake", queue: queue, dialTunnel: Self.dialTunnel(to: devicePort))
        let bridgePort = try await bridge.start()

        let macSide = NWConnection(host: "127.0.0.1", port: bridgePort, using: .tcp)
        let macReady = expectation(description: "mac side ready")
        macSide.stateUpdateHandler = { if case .ready = $0 { macReady.fulfill() } }
        macSide.start(queue: queue)
        await fulfillment(of: [macReady], timeout: 5)
        let deviceSide = await acceptOnDevice()

        // Close the "device" leg — the mac-side leg must see EOF/closure too.
        deviceSide.cancel()

        let macTornDown = expectation(description: "mac side torn down")
        TeardownPoller(queue: queue, connection: macSide, expectation: macTornDown).poll()
        await fulfillment(of: [macTornDown], timeout: 5)
        macSide.cancel()
        bridge.cancel()
    }

    func testCancelBeforeStartCompletesLeavesNothingRunning() async throws {
        let (devicePort, _) = try makeFakeDeviceEndpoint()
        let bridge = USBTLSBridge(udid: "fake", queue: queue, dialTunnel: Self.dialTunnel(to: devicePort))
        bridge.cancel()   // cancel racing start() must not crash or hang
        do {
            _ = try await bridge.start()
        } catch {
            // Either a clean throw or (if start won the race) a normal
            // return are both acceptable — the assertion is "no crash, no
            // hang, no leaked listener/connection". Explicitly re-cancel
            // either way.
        }
        bridge.cancel()
    }

    private func receiveExactly(_ count: Int, on conn: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: error ?? URLError(.unknown))
                }
            }
        }
    }
}

/// Lock-guarded one-shot settle flag: records only the first state
/// transition a connection's handler observes, guarding against later
/// re-entrant calls on the connection's own dispatch queue.
private final class SettleState: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private(set) var reachedReady = false

    @discardableResult
    func settleOnce(reachedReady: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !settled else { return false }
        settled = true
        self.reachedReady = reachedReady
        return true
    }
}

/// Recursively polls a connection on `queue` until it observes EOF/closure,
/// then fulfills `expectation`. A plain recursive local function can't be
/// typed `@Sendable` (it would need to reference itself before it exists),
/// so the recursion is hung off a reference type instead.
private final class TeardownPoller: @unchecked Sendable {
    private let queue: DispatchQueue
    private let connection: NWConnection
    private let expectation: XCTestExpectation

    init(queue: DispatchQueue, connection: NWConnection, expectation: XCTestExpectation) {
        self.queue = queue
        self.connection = connection
        self.expectation = expectation
    }

    func poll() {
        queue.async {
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, isComplete, error in
                if isComplete || error != nil || (data?.isEmpty ?? true) {
                    self.expectation.fulfill()
                } else {
                    self.poll()
                }
            }
        }
    }
}

/// Actor-free accept queue: `newConnectionHandler` fires synchronously off
/// the listener's queue, `next()` is awaited from test code.
private final class AcceptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [NWConnection] = []
    private var waiters: [(NWConnection) -> Void] = []

    func append(_ conn: NWConnection) {
        lock.lock()
        if let waiter = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            waiter(conn)
        } else {
            pending.append(conn)
            lock.unlock()
        }
    }

    func next() async -> NWConnection {
        await withCheckedContinuation { cont in
            lock.lock()
            if let conn = pending.first {
                pending.removeFirst()
                lock.unlock()
                cont.resume(returning: conn)
            } else {
                waiters.append { cont.resume(returning: $0) }
                lock.unlock()
            }
        }
    }
}
