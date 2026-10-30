import Network
import XCTest

/// A peer that sends a commitment and then goes silent must free the responder within the
/// reveal deadline, not at the 65-second attempt backstop: the throttle's slot is held until
/// the responder gives up.
final class PairingRevealDeadlineTests: XCTestCase {
    private final class Held: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        func add(_ c: NWConnection) { lock.lock(); connections.append(c); lock.unlock() }
        func cancelAll() { lock.lock(); connections.forEach { $0.cancel() }; lock.unlock() }
    }

    func testASilentPeerEndsTheAttemptAtTheRevealDeadline() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let held = Held()
        let accepted = expectation(description: "accepted")
        listener.newConnectionHandler = { connection in
            held.add(connection)             // accept and never write anything
            connection.start(queue: .main)
            accepted.fulfill()
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)

        let client = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let connected = expectation(description: "connected")
        client.stateUpdateHandler = { if case .ready = $0 { connected.fulfill() } }
        client.start(queue: .global())
        await fulfillment(of: [connected, accepted], timeout: 5)

        let started = Date()
        do {
            _ = try await PairingNetwork.receiveWithDeadline(0.3, on: client)
            XCTFail("a silent peer never produces a frame")
        } catch {
            XCTAssertEqual(error as? PairingError, .malformedMessage)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "the attempt ends at the deadline")
        // The state change is published on the connection's own queue, shortly after the cancel.
        let closedBy = Date().addingTimeInterval(2)
        while Date() < closedBy, client.state != .cancelled { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(client.state, .cancelled, "the connection is closed")
        listener.cancel()
        held.cancelAll()
    }
}
