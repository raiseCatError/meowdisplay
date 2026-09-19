import XCTest

final class HiDPIEnforcementBackoffTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1000)

    private func failUntilBackoff(_ b: inout HiDPIEnforcementBackoff) -> Bool {
        var entered = false
        for _ in 0..<HiDPIEnforcementBackoff.failureThreshold { entered = b.recordFailure(at: t0) }
        return entered
    }

    func testFailuresBelowThresholdDoNotBackOff() {
        var b = HiDPIEnforcementBackoff()
        for _ in 0..<(HiDPIEnforcementBackoff.failureThreshold - 1) {
            XCTAssertFalse(b.recordFailure(at: t0))
            XCTAssertTrue(b.shouldAttempt(at: t0))
        }
    }

    func testBackoffBeginsAtThresholdAndSkipsWithinWindow() {
        var b = HiDPIEnforcementBackoff()
        XCTAssertTrue(failUntilBackoff(&b))
        XCTAssertFalse(b.shouldAttempt(at: t0.addingTimeInterval(HiDPIEnforcementBackoff.probeInterval - 1)))
    }

    func testRetryAllowedAfterIntervalAndFailedProbeRenewsQuietly() {
        var b = HiDPIEnforcementBackoff()
        _ = failUntilBackoff(&b)
        let probe = t0.addingTimeInterval(HiDPIEnforcementBackoff.probeInterval)
        XCTAssertTrue(b.shouldAttempt(at: probe))
        XCTAssertFalse(b.recordFailure(at: probe))
        XCTAssertFalse(b.shouldAttempt(at: probe.addingTimeInterval(1)))
    }

    func testResetClearsState() {
        var b = HiDPIEnforcementBackoff()
        _ = failUntilBackoff(&b)
        b.reset()
        XCTAssertTrue(b.shouldAttempt(at: t0))
        XCTAssertEqual(b.consecutiveFailures, 0)
        XCTAssertFalse(b.isBackingOff)
    }
}
