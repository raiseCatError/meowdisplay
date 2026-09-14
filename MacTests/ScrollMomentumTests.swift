import CoreGraphics
import XCTest

/// Pure-logic coverage for remote-scroll momentum/inertia
/// (`Shared/ScrollMomentum.swift`). No UIKit/CADisplayLink plumbing is
/// exercised here (that lives in `iOS/OpenSidecarPhoneApp.swift`'s
/// `VideoView` and can't run outside a real app); this covers the release-
/// velocity estimate and the decay physics both the recognizer and the
/// real device rely on.
final class ScrollMomentumTests: XCTestCase {

    // MARK: - Release-velocity estimation

    func testSlowScrollReleaseProducesNoMomentum() {
        var tracker = ScrollVelocityTracker()
        // A slow drag: ~5pt every 20ms -> 250pt/s, but spread thin — still
        // well under minReleaseVelocity once averaged over the window.
        var t: TimeInterval = 0
        for _ in 0..<5 {
            tracker.record(dx: 1, dy: 0, at: t)
            t += 0.02
        }
        let velocity = tracker.releaseVelocity(at: t)
        XCTAssertNil(velocity)
    }

    func testFastScrollReleaseStartsMomentum() {
        var tracker = ScrollVelocityTracker()
        var t: TimeInterval = 0
        for _ in 0..<6 {
            tracker.record(dx: 40, dy: 0, at: t)   // 40pt every ~16.7ms ≈ 2400pt/s
            t += 1.0 / 60
        }
        let velocity = tracker.releaseVelocity(at: t)
        XCTAssertNotNil(velocity)
        XCTAssertGreaterThan(velocity!.dx, ScrollMomentumConfig.minReleaseVelocity)

        let session = ScrollMomentumSession(initialVelocity: velocity!, at: t)
        XCTAssertNotNil(session)
    }

    func testGreaterReleaseVelocityProducesGreaterInitialMomentum() {
        var slow = ScrollVelocityTracker()
        var fast = ScrollVelocityTracker()
        var t: TimeInterval = 0
        for _ in 0..<6 {
            slow.record(dx: 10, dy: 0, at: t)
            fast.record(dx: 40, dy: 0, at: t)
            t += 1.0 / 60
        }
        let slowVelocity = slow.releaseVelocity(at: t)
        let fastVelocity = fast.releaseVelocity(at: t)
        XCTAssertNotNil(slowVelocity)
        XCTAssertNotNil(fastVelocity)
        XCTAssertGreaterThan(fastVelocity!.dx, slowVelocity!.dx)

        let slowSession = ScrollMomentumSession(initialVelocity: slowVelocity!, at: t)!
        let fastSession = ScrollMomentumSession(initialVelocity: fastVelocity!, at: t)!
        let slowFirstTick = slowSession.tick(now: t + 1.0 / 60)
        let fastFirstTick = fastSession.tick(now: t + 1.0 / 60)
        XCTAssertGreaterThan(fastFirstTick.delta.dx, slowFirstTick.delta.dx)
    }

    func testReleaseVelocityUsesRecentWindowNotJustLastFrame() {
        var tracker = ScrollVelocityTracker()
        // A fast swipe, then the finger nearly stops right before lifting
        // (a single noisy/coalesced low-delta sample at release).
        var t: TimeInterval = 0
        for _ in 0..<8 {
            tracker.record(dx: 40, dy: 0, at: t)
            t += 1.0 / 60
        }
        tracker.record(dx: 0.1, dy: 0, at: t)
        let velocity = tracker.releaseVelocity(at: t)
        // Still reads as a fast release — one trailing near-zero sample
        // doesn't dominate the estimate.
        XCTAssertNotNil(velocity)
        XCTAssertGreaterThan(velocity!.dx, 1000)
    }

    func testReleaseVelocityIsCappedAtMaximum() {
        var tracker = ScrollVelocityTracker()
        var t: TimeInterval = 0
        for _ in 0..<6 {
            tracker.record(dx: 400, dy: 0, at: t)   // absurdly fast
            t += 1.0 / 60
        }
        let velocity = tracker.releaseVelocity(at: t)
        XCTAssertNotNil(velocity)
        XCTAssertLessThanOrEqual(hypot(velocity!.dx, velocity!.dy), ScrollMomentumConfig.maxReleaseVelocity + 0.01)
    }

    // MARK: - Decay physics

    func testMomentumDecaysMonotonically() {
        let session = ScrollMomentumSession(initialVelocity: CGVector(dx: 2000, dy: 0), at: 0)!
        var lastMagnitude = CGFloat.greatestFiniteMagnitude
        var t: TimeInterval = 0
        for _ in 0..<20 {
            t += 1.0 / 60
            _ = session.tick(now: t)
            let magnitude = hypot(session.velocity.dx, session.velocity.dy)
            XCTAssertLessThan(magnitude, lastMagnitude)
            lastMagnitude = magnitude
        }
    }

    func testMomentumEventuallyTerminates() {
        let session = ScrollMomentumSession(initialVelocity: CGVector(dx: 1000, dy: 0), at: 0)!
        var t: TimeInterval = 0
        var alive = true
        var ticks = 0
        while alive, ticks < 10_000 {
            t += 1.0 / 60
            alive = session.tick(now: t).alive
            ticks += 1
        }
        XCTAssertFalse(alive)
        XCTAssertLessThan(t, 5.0)   // terminates well within a few seconds
    }

    func testVariableFrameIntervalsProduceComparableTotalDisplacement() {
        // 60Hz ticking vs. one big jump covering the same wall-clock span
        // should land at nearly the same total displacement and end
        // velocity — the model integrates continuously, not per-frame.
        let steady = ScrollMomentumSession(initialVelocity: CGVector(dx: 1200, dy: 0), at: 0)!
        var steadyTotal: CGFloat = 0
        var t: TimeInterval = 0
        for _ in 0..<18 {   // 0.3s at 60Hz
            t += 1.0 / 60
            steadyTotal += steady.tick(now: t).delta.dx
        }

        let jumpy = ScrollMomentumSession(initialVelocity: CGVector(dx: 1200, dy: 0), at: 0)!
        let jumpyTick = jumpy.tick(now: 0.3)   // one single 0.3s jump

        XCTAssertEqual(steadyTotal, jumpyTick.delta.dx, accuracy: steadyTotal * 0.01)
        XCTAssertEqual(hypot(steady.velocity.dx, steady.velocity.dy),
                       hypot(jumpy.velocity.dx, jumpy.velocity.dy), accuracy: 1)
    }

    func testZeroOrNegativeElapsedTimeProducesNoDeltaAndNoCrash() {
        let session = ScrollMomentumSession(initialVelocity: CGVector(dx: 500, dy: 0), at: 1.0)!
        let same = session.tick(now: 1.0)
        XCTAssertEqual(same.delta, .zero)
        XCTAssertTrue(same.alive)
        let backwards = session.tick(now: 0.5)
        XCTAssertEqual(backwards.delta, .zero)
    }

    func testMomentumSessionRefusesToStartBelowMinimumVelocity() {
        let session = ScrollMomentumSession(initialVelocity: CGVector(dx: 5, dy: 0), at: 0)
        XCTAssertNil(session)
    }
}
