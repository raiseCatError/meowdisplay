import XCTest

final class FrameRateLimiterTests: XCTestCase {

    /// Simulates a source delivering frames at `sourceHz`, feeding each
    /// arrival's wall-clock time straight into `shouldAdmit`, and counts how
    /// many were admitted over `durationSeconds`.
    private func admittedCount(sourceHz: Double, limiterFPS: Int, durationSeconds: Double) -> Int {
        var limiter = FrameRateLimiter(fps: limiterFPS)
        var count = 0
        var t = 0.0
        let dt = 1.0 / sourceHz
        while t < durationSeconds {
            if limiter.shouldAdmit(now: t) { count += 1 }
            t += dt
        }
        return count
    }

    // MARK: - Long-window rate matches the target, not the source

    func test120HzSourceTarget60AdmitsApprox60PerSecond() {
        let count = admittedCount(sourceHz: 120, limiterFPS: 60, durationSeconds: 10)
        XCTAssertEqual(Double(count), 600, accuracy: 2)
    }

    func test120HzSourceArbitraryTarget118AdmitsApprox118PerSecond() {
        // The whole point of PART 1: an arbitrary non-tier integer target
        // (118) must be honored exactly, not rounded to a tier.
        let count = admittedCount(sourceHz: 120, limiterFPS: 118, durationSeconds: 10)
        XCTAssertEqual(Double(count), 1180, accuracy: 5)
    }

    func test60HzSourceTarget55AdmitsApprox55PerSecond() {
        let count = admittedCount(sourceHz: 60, limiterFPS: 55, durationSeconds: 10)
        XCTAssertEqual(Double(count), 550, accuracy: 5)
    }

    func testArbitraryTarget106NeverExceedsItsOwnRateEvenAtHighSourceHz() {
        let count = admittedCount(sourceHz: 240, limiterFPS: 106, durationSeconds: 10)
        XCTAssertEqual(Double(count), 1060, accuracy: 5)
    }

    // MARK: - Never exceeds the configured rate, at any window length

    func testNeverAdmitsFasterThanConfiguredRateInAnyOneSecondWindow() {
        var limiter = FrameRateLimiter(fps: 30)
        var admittedTimestamps: [Double] = []
        var t = 0.0
        let dt = 1.0 / 240.0   // a much faster source than the target
        while t < 3.0 {
            if limiter.shouldAdmit(now: t) { admittedTimestamps.append(t) }
            t += dt
        }
        // Slide a 1-second window; none should ever contain more than
        // fps + 1 admissions (+1 tolerates a boundary frame).
        for windowStart in stride(from: 0.0, through: 2.0, by: 0.1) {
            let inWindow = admittedTimestamps.filter { $0 >= windowStart && $0 < windowStart + 1.0 }
            XCTAssertLessThanOrEqual(inWindow.count, 31, "window starting at \(windowStart) over-admitted")
        }
    }

    // MARK: - Duplicate timestamps

    func testDuplicateTimestampIsNotAdmittedTwice() {
        var limiter = FrameRateLimiter(fps: 30)
        XCTAssertTrue(limiter.shouldAdmit(now: 1.0))
        XCTAssertFalse(limiter.shouldAdmit(now: 1.0))
        XCTAssertFalse(limiter.shouldAdmit(now: 1.0))
    }

    // MARK: - Idle gap does not produce a burst

    func testIdleGapDoesNotProduceABurst() {
        var limiter = FrameRateLimiter(fps: 30)
        XCTAssertTrue(limiter.shouldAdmit(now: 0))
        // 5 seconds of no calls at all (capture paused/idle), then resumes.
        let resumeTime = 5.0
        XCTAssertTrue(limiter.shouldAdmit(now: resumeTime))
        // Immediately after resuming, the very next frame must NOT be
        // admitted — a naive "deadline + N*interval catch-up" would instead
        // admit a burst of ~150 owed frames back-to-back.
        XCTAssertFalse(limiter.shouldAdmit(now: resumeTime + 0.001))
        XCTAssertFalse(limiter.shouldAdmit(now: resumeTime + (1.0 / 30.0) * 0.9))
        XCTAssertTrue(limiter.shouldAdmit(now: resumeTime + (1.0 / 30.0) * 1.1))
    }

    // MARK: - Reconfigure / reset

    func testReconfigureResyncsImmediatelyAtTheNewRate() {
        var limiter = FrameRateLimiter(fps: 30)
        XCTAssertTrue(limiter.shouldAdmit(now: 0))
        XCTAssertFalse(limiter.shouldAdmit(now: 0.001))
        limiter.reconfigure(fps: 60)
        // A rate change (e.g. `setupEncoder` ran at a new FPS) must not make
        // the next frame wait out a deadline computed under the OLD rate.
        XCTAssertTrue(limiter.shouldAdmit(now: 0.001))
    }

    func testResetForcesTheNextCallToAdmit() {
        var limiter = FrameRateLimiter(fps: 10)
        XCTAssertTrue(limiter.shouldAdmit(now: 0))
        XCTAssertFalse(limiter.shouldAdmit(now: 0.01))
        limiter.reset()
        XCTAssertTrue(limiter.shouldAdmit(now: 0.01))
    }

    // MARK: - Degenerate input fails safe

    func testZeroOrNegativeFPSClampsToOne() {
        var limiterZero = FrameRateLimiter(fps: 0)
        var limiterNegative = FrameRateLimiter(fps: -5)
        XCTAssertTrue(limiterZero.shouldAdmit(now: 0))
        XCTAssertFalse(limiterZero.shouldAdmit(now: 0.5))
        XCTAssertTrue(limiterZero.shouldAdmit(now: 1.0))
        XCTAssertTrue(limiterNegative.shouldAdmit(now: 0))
        XCTAssertFalse(limiterNegative.shouldAdmit(now: 0.5))
    }
}
