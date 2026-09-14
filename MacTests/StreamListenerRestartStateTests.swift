import XCTest

final class StreamListenerRestartStateTests: XCTestCase {
    func testDuplicateStartIsRejectedWhileBindIsInFlight() {
        var state = StreamListenerRestartState()

        XCTAssertTrue(state.beginStarting())
        XCTAssertFalse(state.beginStarting())
        XCTAssertTrue(state.shouldDeferEnsureListening)
    }

    func testDuplicateRestartRequestsCollapse() throws {
        var state = StreamListenerRestartState()

        let first = try XCTUnwrap(state.scheduleRestart())
        XCTAssertNil(state.scheduleRestart())
        XCTAssertTrue(state.consume(first))
        XCTAssertFalse(state.restartPending)
    }

    func testStaleRestartCannotSupersedeNewerGeneration() throws {
        var state = StreamListenerRestartState()

        let stale = try XCTUnwrap(state.scheduleRestart())
        state.invalidate()
        let current = try XCTUnwrap(state.scheduleRestart())

        XCTAssertFalse(state.consume(stale))
        XCTAssertTrue(state.consume(current))
    }

    func testRetryBackoffDoublesAndCapsAtEightSeconds() throws {
        var state = StreamListenerRestartState()
        var delays: [TimeInterval] = []

        for _ in 0..<7 {
            let retry = try XCTUnwrap(state.scheduleRetry())
            delays.append(retry.delay)
            XCTAssertTrue(state.consume(retry))
        }

        XCTAssertEqual(delays, [0.5, 1, 2, 4, 8, 8, 8])
    }

    func testReadinessResetsRetryBackoff() throws {
        var state = StreamListenerRestartState()

        let first = try XCTUnwrap(state.scheduleRetry())
        XCTAssertTrue(state.consume(first))
        let second = try XCTUnwrap(state.scheduleRetry())
        XCTAssertEqual(second.delay, 1)
        XCTAssertTrue(state.consume(second))

        state.listenerReady()

        let reset = try XCTUnwrap(state.scheduleRetry())
        XCTAssertEqual(reset.delay, 0.5)
    }
}
