import XCTest

/// `FrameAdmission`: the rate limit's trailing edge (#123). A frame the limit
/// turns away is held, and goes out one interval after the next deadline if
/// nothing newer went out first.
final class FrameAdmissionTests: XCTestCase {
    private let fps = 60
    private var interval: Double { 1.0 / Double(fps) }

    // MARK: - Decisions

    func testAFrameTurnedAwayIsHeldUntilAnIntervalAfterTheNextDeadline() {
        var admission = FrameAdmission(fps: fps)
        XCTAssertEqual(admission.offer(now: 0), .send)
        XCTAssertEqual(admission.offer(now: 0.008), .hold(retryAt: interval * 2))
        XCTAssertTrue(admission.isHolding)
    }

    func testOnlyTheFirstHeldFrameArmsARetry() {
        var admission = FrameAdmission(fps: fps)
        XCTAssertEqual(admission.offer(now: 0), .send)
        XCTAssertEqual(admission.offer(now: 0.004), .hold(retryAt: interval * 2))
        XCTAssertEqual(admission.offer(now: 0.008), .hold(retryAt: nil), "the newer frame replaces the held one")
    }

    func testANewerFrameGoingOutReleasesTheHold() {
        var admission = FrameAdmission(fps: fps)
        XCTAssertEqual(admission.offer(now: 0), .send)
        XCTAssertEqual(admission.offer(now: 0.008), .hold(retryAt: interval * 2))
        XCTAssertEqual(admission.offer(now: 0.017), .send)
        XCTAssertFalse(admission.isHolding)
        XCTAssertFalse(admission.retryFired(), "a retry that fires after a newer frame went out sends nothing")
    }

    func testTheRetrySendsTheHeldFrame() {
        var admission = FrameAdmission(fps: fps)
        XCTAssertEqual(admission.offer(now: 0), .send)
        guard case .hold(let retryAt?) = admission.offer(now: 0.008) else { return XCTFail("expected a retry") }
        XCTAssertTrue(admission.retryFired())
        XCTAssertEqual(admission.offer(now: retryAt), .send)
        XCTAssertFalse(admission.isHolding)
    }

    func testABusyEncoderHoldsAnAdmittedFrame() {
        var admission = FrameAdmission(fps: fps)
        XCTAssertEqual(admission.offer(now: 0), .send)
        XCTAssertEqual(admission.encoderBusy(now: 0), .hold(retryAt: interval * 2))
        XCTAssertTrue(admission.retryFired())
        XCTAssertEqual(admission.offer(now: interval * 2), .send)
    }

    func testClearingTheHoldDropsTheHeldFrame() {
        var admission = FrameAdmission(fps: fps)
        XCTAssertEqual(admission.offer(now: 0), .send)
        XCTAssertEqual(admission.offer(now: 0.008), .hold(retryAt: interval * 2))
        admission.clearHold()
        XCTAssertFalse(admission.retryFired())
    }

    func testARetryThatFiresEarlyHoldsTheFrameAgain() {
        var admission = FrameAdmission(fps: fps)
        XCTAssertEqual(admission.offer(now: 0), .send)
        XCTAssertEqual(admission.offer(now: 0.001), .hold(retryAt: interval * 2))
        XCTAssertTrue(admission.retryFired())
        // Still before the limit's deadline: held again, with a new retry.
        XCTAssertEqual(admission.offer(now: 0.002), .hold(retryAt: interval * 2))
    }

    // MARK: - Motion that stops

    func testTheLastFrameOfEveryMotionGoesOutWithinTwoIntervals() {
        for sourceHz in [120.0, 60.0] {
            let (arrivals, endings) = motions(sourceHz: sourceHz, seed: 7)
            let sends = simulate(arrivals, trailing: true)
            for ending in endings {
                let shown = sends.first { $0.content >= ending }
                XCTAssertNotNil(shown, "\(Int(sourceHz)) Hz: the frame at \(ending) never went out")
                if let shown {
                    XCTAssertLessThanOrEqual(shown.at - ending, interval * 2 + 1e-9,
                                             "\(Int(sourceHz)) Hz: the frame at \(ending) went out late")
                }
            }
        }
    }

    func testTheStrictLimitAloneLeavesSomeMotionsEndingOnAStaleFrame() {
        // The case this fixes, reproduced: without the trailing edge, some
        // final frames are turned away and nothing newer follows.
        let (arrivals, endings) = motions(sourceHz: 120, seed: 7)
        let sends = simulate(arrivals, trailing: false)
        let stale = endings.filter { ending in !sends.contains { $0.content >= ending } }
        XCTAssertFalse(stale.isEmpty)
    }

    // MARK: - Continuous motion is unchanged

    /// While a new frame follows within an interval, the retry never comes
    /// due before it, so the same frames go out at the same times. (A source
    /// that pauses longer than that has stopped, and the held frame goes out.)
    func testContinuousMotionIsPacedExactlyAsBefore() {
        for sourceHz in [120.0, 90.0, 72.0] {
            let arrivals = jittered(start: 0, count: Int(sourceHz) * 5, sourceHz: sourceHz, seed: 11)
            let last = arrivals.last!
            let withTrailing = simulate(arrivals, trailing: true).filter { $0.at <= last }
            let strict = simulate(arrivals, trailing: false)
            XCTAssertEqual(withTrailing.map(\.at), strict.map(\.at), "\(Int(sourceHz)) Hz source")
        }
    }

    // MARK: - The rate limit still holds

    func testHeldFramesNeverPushTheRateOverTheLimit() {
        let (arrivals, _) = motions(sourceHz: 240, seed: 3)
        let times = simulate(arrivals, trailing: true).map(\.at)
        var first = 0
        for (index, time) in times.enumerated() {
            while time - times[first] >= 1 { first += 1 }
            XCTAssertLessThanOrEqual(index - first + 1, fps + 1, "too many frames in the second before \(time)")
        }
    }

    // MARK: - Helpers

    private struct Send { let at: Double; let content: Double }

    /// Drives `FrameAdmission` the way `MacSender` does: every arrival is
    /// offered; a held frame's retry fires at its time, before any later
    /// arrival, and offers the newest held frame again.
    private func simulate(_ arrivals: [Double], trailing: Bool) -> [Send] {
        var admission = FrameAdmission(fps: fps)
        var sends: [Send] = []
        var held: Double?
        var retryAt: Double?
        func fireRetries(before time: Double) {
            while let at = retryAt, at <= time {
                retryAt = nil
                guard admission.retryFired(), let frame = held else { continue }
                held = nil
                handle(admission.offer(now: at), content: frame, at: at)
            }
        }
        func handle(_ decision: FrameAdmission.Decision, content: Double, at: Double) {
            switch decision {
            case .send:
                sends.append(Send(at: at, content: content))
                held = nil
                retryAt = nil
            case .hold(let newRetry):
                held = content
                if let newRetry, trailing { retryAt = newRetry }
            }
        }
        for time in arrivals {
            fireRetries(before: time)
            handle(admission.offer(now: time), content: time, at: time)
        }
        fireRetries(before: .infinity)
        return sends
    }

    /// Bursts of motion at `sourceHz` (with up to ±15% jitter), each followed
    /// by a still screen. Returns every arrival and each burst's last one.
    private func motions(sourceHz: Double, seed: UInt64) -> (arrivals: [Double], endings: [Double]) {
        var arrivals: [Double] = []
        var endings: [Double] = []
        var start = 0.0
        var rng = seed
        for _ in 0..<60 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let count = 3 + Int(rng >> 59)   // 3…34 frames
            let burst = jittered(start: start, count: count, sourceHz: sourceHz, seed: rng)
            arrivals += burst
            endings.append(burst.last!)
            start = burst.last! + 0.4
        }
        return (arrivals, endings)
    }

    private func jittered(start: Double, count: Int, sourceHz: Double, seed: UInt64) -> [Double] {
        var rng = seed
        var time = start
        var out: [Double] = []
        for _ in 0..<count {
            out.append(time)
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(rng >> 11) / Double(1 << 53)   // 0..<1
            time += (1 / sourceHz) * (0.85 + 0.3 * unit)
        }
        return out
    }
}
