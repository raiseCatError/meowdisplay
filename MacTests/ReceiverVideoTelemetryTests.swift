import XCTest

final class ReceiverVideoTelemetryTests: XCTestCase {

    func testInitialStateIsEmpty() {
        let telemetry = ReceiverVideoTelemetry()
        XCTAssertEqual(telemetry.snapshotDecodeDurationsMs(), [])
        XCTAssertEqual(telemetry.currentFlushCount(), 0)
    }

    func testRecordDecodeDurationAppendsSamplesInOrder() {
        let telemetry = ReceiverVideoTelemetry()
        telemetry.recordDecodeDuration(4.0)
        telemetry.recordDecodeDuration(6.0)
        telemetry.recordDecodeDuration(5.0)
        XCTAssertEqual(telemetry.snapshotDecodeDurationsMs(), [4.0, 6.0, 5.0])
    }

    func testIncrementFlushCountIsCumulative() {
        let telemetry = ReceiverVideoTelemetry()
        telemetry.incrementFlushCount()
        telemetry.incrementFlushCount()
        telemetry.incrementFlushCount()
        XCTAssertEqual(telemetry.currentFlushCount(), 3)
    }

    func testClearDecodeDurationWindowClearsSamplesButNotFlushCount() {
        let telemetry = ReceiverVideoTelemetry()
        telemetry.recordDecodeDuration(1.0)
        telemetry.recordDecodeDuration(2.0)
        telemetry.incrementFlushCount()
        telemetry.clearDecodeDurationWindow()
        XCTAssertEqual(telemetry.snapshotDecodeDurationsMs(), [])
        // The old code's own two independent fields — clearing the rolling
        // decode window (5s cadence) never touched the cumulative flush
        // counter (reset only by `reset()`/a new connection).
        XCTAssertEqual(telemetry.currentFlushCount(), 1)
    }

    func testResetClearsBothDurationsAndFlushCount() {
        let telemetry = ReceiverVideoTelemetry()
        telemetry.recordDecodeDuration(1.0)
        telemetry.incrementFlushCount()
        telemetry.incrementFlushCount()
        telemetry.reset()
        XCTAssertEqual(telemetry.snapshotDecodeDurationsMs(), [])
        XCTAssertEqual(telemetry.currentFlushCount(), 0)
        // Still usable afterward — a reset must not leave the owner inert.
        telemetry.recordDecodeDuration(9.0)
        telemetry.incrementFlushCount()
        XCTAssertEqual(telemetry.snapshotDecodeDurationsMs(), [9.0])
        XCTAssertEqual(telemetry.currentFlushCount(), 1)
    }

    func testSnapshotIsNonDestructive() {
        let telemetry = ReceiverVideoTelemetry()
        telemetry.recordDecodeDuration(3.0)
        _ = telemetry.snapshotDecodeDurationsMs()
        XCTAssertEqual(telemetry.snapshotDecodeDurationsMs(), [3.0],
                        "reading the window must not itself clear it — that's clearDecodeDurationWindow()'s job")
    }

    #if DEBUG
    func testDrainDebugPresentedCountIsAtomicReadThenReset() {
        let telemetry = ReceiverVideoTelemetry()
        telemetry.incrementDebugPresentedCount()
        telemetry.incrementDebugPresentedCount()
        telemetry.incrementDebugPresentedCount()
        XCTAssertEqual(telemetry.drainDebugPresentedCount(), 3)
        // Drained — the next read starts from zero, exactly like the old
        // inline "log it, then zero it" window reset.
        XCTAssertEqual(telemetry.drainDebugPresentedCount(), 0)
    }

    func testDrainDebugDecodedCountIsAtomicReadThenReset() {
        let telemetry = ReceiverVideoTelemetry()
        telemetry.incrementDebugDecodedCount()
        telemetry.incrementDebugDecodedCount()
        XCTAssertEqual(telemetry.drainDebugDecodedCount(), 2)
        XCTAssertEqual(telemetry.drainDebugDecodedCount(), 0)
    }

    /// The decoded and presented counters are independent — draining one
    /// must not disturb the other.
    func testDecodedAndPresentedCountsAreIndependent() {
        let telemetry = ReceiverVideoTelemetry()
        telemetry.incrementDebugDecodedCount()
        telemetry.incrementDebugPresentedCount()
        telemetry.incrementDebugPresentedCount()
        XCTAssertEqual(telemetry.drainDebugDecodedCount(), 1)
        XCTAssertEqual(telemetry.drainDebugPresentedCount(), 2)
    }
    #endif

    /// Deterministic concurrent stress test: many threads incrementing the
    /// cumulative flush counter must never lose an update — the whole point
    /// of the lock. Final count is deterministic (exactly the number of
    /// increments issued), so this isn't a flaky timing test.
    func testConcurrentFlushIncrementsAreNotLost() {
        let telemetry = ReceiverVideoTelemetry()
        let iterations = 2000
        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            telemetry.incrementFlushCount()
        }
        XCTAssertEqual(telemetry.currentFlushCount(), iterations)
    }

    /// Same determinism guarantee for the decode-duration array: every
    /// concurrent append must land, so the count of stored samples must
    /// exactly match the number of calls (values may interleave in any
    /// order — only the count is asserted, to stay non-flaky).
    func testConcurrentDecodeDurationRecordsAreNotLost() {
        let telemetry = ReceiverVideoTelemetry()
        let iterations = 2000
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            telemetry.recordDecodeDuration(Double(i))
        }
        XCTAssertEqual(telemetry.snapshotDecodeDurationsMs().count, iterations)
    }
}
