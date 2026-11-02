import XCTest
import Network

/// Minimal delegate stub — these tests exercise queue-confinement mechanics
/// and dial-generation/redial bookkeeping that don't require a live
/// Network.framework connection; none of the delegate hooks below are
/// expected to fire for the scenarios covered here.
private final class StubTransportDelegate: MacSenderTransportDelegate {
    func transportSessionBecameReady(on connection: NWConnection) {}
    func transportShouldBeginReceiving(on connection: NWConnection) {}
    func transportPathChanged(_ route: ConnectionRoute?) {}
    func transportSessionInvalidated(reason: String) {}
    func transportLinkDied(_ detail: String) {}
    func transportCancelActiveInput() {}
    func transportPeerDeviceKind() -> String? { nil }
    func transportDialingContext() -> (transport: SenderTransport, peerAddrs: [String]) {
        // None of the scenarios below dial or probe, so this is never
        // actually invoked — constructing a real `SenderTransport` needs a
        // live `SecIdentity`, which these unit tests have no business
        // faking.
        fatalError("transportDialingContext() not exercised by these tests")
    }
}

final class MacSenderTransportControllerTests: XCTestCase {
    private func makeController(queue: DispatchQueue) -> MacSenderTransportController {
        MacSenderTransportController(queue: queue, endpointName: "test", statusSink: MacSenderStatusSink())
    }

    // MARK: - Dial generation

    func testBumpDialGenerationIncrementsMonotonically() {
        let queue = DispatchQueue(label: "test.transport")
        let controller = makeController(queue: queue)
        let delegate = StubTransportDelegate()
        controller.delegate = delegate
        queue.sync {
            XCTAssertEqual(controller.currentDialGeneration, 0)
            XCTAssertEqual(controller.bumpDialGeneration(), 1)
            XCTAssertEqual(controller.bumpDialGeneration(), 2)
            XCTAssertEqual(controller.currentDialGeneration, 2)
        }
    }

    func testResetForRedialBumpsGenerationAndClearsDirectLink() {
        let queue = DispatchQueue(label: "test.transport")
        let controller = makeController(queue: queue)
        let delegate = StubTransportDelegate()
        controller.delegate = delegate
        queue.sync {
            let generation = controller.resetForRedial()
            XCTAssertEqual(generation, 1)
            XCTAssertEqual(controller.currentDialGeneration, 1)
            XCTAssertFalse(controller.isDirectLink)
            XCTAssertNil(controller.currentConnection)
        }
    }

    func testResetForTransportSwitchBumpsGenerationAndStopsProbing() {
        let queue = DispatchQueue(label: "test.transport")
        let controller = makeController(queue: queue)
        let delegate = StubTransportDelegate()
        controller.delegate = delegate
        queue.sync {
            controller.resetForTransportSwitch()
            XCTAssertEqual(controller.currentDialGeneration, 1)
            XCTAssertFalse(controller.isDirectLink)
            XCTAssertFalse(controller.isUpgradeProbingActive)
        }
    }

    // MARK: - STOP-B reentrancy

    func testStopCurrentConnectionSynchronouslyFromOffQueueBlocksUntilDone() {
        let queue = DispatchQueue(label: "test.transport")
        let controller = makeController(queue: queue)
        let delegate = StubTransportDelegate()
        controller.delegate = delegate
        // Called from the test's own thread (off `queue`) — must complete
        // synchronously via `queue.sync`, not merely enqueue and return.
        controller.stopCurrentConnectionSynchronously()
        // A second call must also complete synchronously without deadlocking
        // (idempotent stop).
        controller.stopCurrentConnectionSynchronously()
        queue.sync {
            XCTAssertNil(controller.currentConnection)
        }
    }

    func testStopCurrentConnectionSynchronouslyFromOnQueueRunsInlineWithoutDeadlock() {
        let queue = DispatchQueue(label: "test.transport")
        let controller = makeController(queue: queue)
        let delegate = StubTransportDelegate()
        controller.delegate = delegate
        let expectation = expectation(description: "inline stop completes")
        queue.async {
            // Already on `queue` — must run inline via the reentrancy token,
            // not call `queue.sync` on itself (which would deadlock).
            controller.stopCurrentConnectionSynchronously()
            XCTAssertNil(controller.currentConnection)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2.0)
    }
}
