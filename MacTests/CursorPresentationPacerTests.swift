import CoreGraphics
import XCTest

/// `Shared/CursorPresentationPacer.swift`: how the receiver draws the Mac-confirmed cursor on its
/// display refresh. The CADisplayLink plumbing lives in the iOS `VideoView` and needs a device;
/// this covers the policy, above all that the pointer is only ever drawn at a position the Mac
/// reported or on the straight segment between two consecutive ones.
final class CursorPresentationPacerTests: XCTestCase {
    private let refresh = 1.0 / 120

    private func point(_ x: Double, _ y: Double = 0.5) -> CGPoint { CGPoint(x: x, y: y) }

    /// Deterministic jitter in [-amplitude, amplitude].
    private struct Jitter {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next(_ amplitude: Double) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Double(state >> 11) / Double(1 << 53) * 2 - 1) * amplitude
        }
    }

    private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared)) : 0
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    // MARK: - Showing, hiding and jumps apply at once

    func testFirstReportIsDrawnAtOnce() {
        var pacer = CursorPresentationPacer()
        pacer.receive(point(0.3), visible: true, at: 1)
        XCTAssertTrue(pacer.isSettled)
        XCTAssertEqual(pacer.frame(at: 1), point(0.3))
        XCTAssertEqual(pacer.newest, point(0.3))
    }

    func testHiddenReportHidesAtOnceEvenMidMove() {
        var pacer = CursorPresentationPacer()
        pacer.receive(point(0.3), visible: true, at: 1)
        pacer.receive(point(0.31), visible: true, at: 1.008)
        XCTAssertFalse(pacer.isSettled)
        pacer.receive(.zero, visible: false, at: 1.009)
        XCTAssertNil(pacer.frame(at: 1.010))
        XCTAssertNil(pacer.newest)
        XCTAssertTrue(pacer.isSettled)
    }

    func testShowingAgainJumpsToTheReportInsteadOfSweepingFromWhereItWasHidden() {
        var pacer = CursorPresentationPacer()
        pacer.receive(point(0.1), visible: true, at: 1)
        pacer.receive(.zero, visible: false, at: 1.01)
        pacer.receive(point(0.12), visible: true, at: 1.02)
        XCTAssertTrue(pacer.isSettled)
        XCTAssertEqual(pacer.frame(at: 1.02), point(0.12))
    }

    func testLargeStepIsDrawnDirectly() {
        var pacer = CursorPresentationPacer()
        pacer.receive(point(0.1), visible: true, at: 1)
        pacer.receive(point(0.8), visible: true, at: 1.008)
        XCTAssertTrue(pacer.isSettled)
        XCTAssertEqual(pacer.frame(at: 1.008), point(0.8))
    }

    func testPaneChangeDrawsOnlyTheNextReportDirectly() {
        var pacer = CursorPresentationPacer()
        pacer.receive(point(0.1), visible: true, at: 1)
        pacer.jumpAtNextReport()
        pacer.receive(point(0.12), visible: true, at: 1.008)
        XCTAssertTrue(pacer.isSettled)
        XCTAssertEqual(pacer.frame(at: 1.008), point(0.12))
        pacer.receive(point(0.13), visible: true, at: 1.016)
        XCTAssertFalse(pacer.isSettled, "later reports in the same pane are paced again")
    }

    // MARK: - Mac authority

    /// The Mac cursor stops while the finger keeps going (display edge, input refused, sender
    /// stalled): the reports stop, and the pointer comes to rest exactly at the last confirmed
    /// position within the delay and never moves again, however long refreshes keep coming.
    func testComesToRestExactlyAtTheLastConfirmedPositionWhenReportsStop() {
        var pacer = CursorPresentationPacer()
        var time = 1.0
        var last = CGPoint.zero
        for step in 0...20 {
            last = point(0.2 + Double(step) * 0.002)
            pacer.receive(last, visible: true, at: time)
            time += 0.008
        }
        let lastReportAt = time - 0.008
        var frameTime = lastReportAt
        while frameTime < lastReportAt + 2 {
            let shown = try! XCTUnwrap(pacer.frame(at: frameTime))
            XCTAssertLessThanOrEqual(shown.x, last.x, "never past the newest confirmed position")
            if frameTime >= lastReportAt + CursorPresentationPacer.maximumDelay {
                XCTAssertEqual(shown, last)
                XCTAssertTrue(pacer.isSettled)
            }
            frameTime += refresh
        }
    }

    /// Jittered, bunched reports along a curve: every refresh draws a point on the segment
    /// between two consecutive reports that had already arrived, and never goes backwards.
    func testOnlyDrawsPointsOnTheConfirmedPathAndNeverGoesBack() {
        var pacer = CursorPresentationPacer()
        var jitter = Jitter()
        var received: [CGPoint] = []
        var arrivals: [(time: Double, point: CGPoint)] = []
        for step in 0..<300 {
            let x = 0.1 + Double(step) * 0.002
            let sent = 1 + Double(step) * 0.008
            // Mostly small jitter, every 25th report held back 30 ms (a Wi-Fi stall), so later
            // reports arrive in a bunch behind it.
            let delay = 0.004 + abs(jitter.next(0.003)) + (step % 25 == 0 ? 0.03 : 0)
            arrivals.append((max(arrivals.last?.time ?? 0, sent + delay), point(x, 0.5 + 0.1 * sin(x * 20))))
        }
        var next = 0
        var frameTime = 1.0
        var previousX = -Double.infinity
        while frameTime < 4 {
            while next < arrivals.count, arrivals[next].time <= frameTime {
                pacer.receive(arrivals[next].point, visible: true, at: arrivals[next].time)
                received.append(arrivals[next].point)
                next += 1
            }
            if let shown = pacer.frame(at: frameTime) {
                let onPath = received.count == 1 ? hypot(shown.x - received[0].x, shown.y - received[0].y)
                    : zip(received, received.dropFirst()).map { distance(from: shown, toSegment: $0, $1) }.min()!
                XCTAssertLessThan(onPath, 1e-9, "drawn off the confirmed path at \(frameTime)")
                XCTAssertGreaterThanOrEqual(Double(shown.x), previousX - 1e-12, "went backwards at \(frameTime)")
                XCTAssertLessThanOrEqual(shown.x, received.map(\.x).max()!, "past the newest report")
                previousX = Double(shown.x)
            }
            frameTime += refresh
        }
        XCTAssertEqual(pacer.frame(at: frameTime), arrivals.last?.point)
    }

    /// Reversing: the pointer follows the turn and never passes the furthest confirmed point.
    func testReversingMotionNeverPassesTheTurningPoint() {
        var pacer = CursorPresentationPacer()
        let xs = (0...10).map { 0.30 + Double($0) * 0.003 } + (1...10).map { 0.33 - Double($0) * 0.003 }
        var frameTime = 1.0
        var maxShown = -Double.infinity
        for (index, x) in xs.enumerated() {
            let arrival = 1 + Double(index) * 0.008
            pacer.receive(point(x), visible: true, at: arrival)
            while frameTime < arrival + 0.008 {
                if let shown = pacer.frame(at: frameTime) { maxShown = max(maxShown, Double(shown.x)) }
                frameTime += refresh
            }
        }
        XCTAssertLessThanOrEqual(maxShown, 0.33 + 1e-12)
        XCTAssertEqual(pacer.frame(at: frameTime + 1), point(xs.last!))
    }

    // MARK: - Smoothness and latency bounds

    /// 60 Hz reports with a little arrival jitter on a 120 Hz screen. Drawing each report on
    /// arrival holds the pointer on about every other refresh; pacing advances it on almost
    /// every refresh.
    func testAdvancesOnAlmostEveryRefreshWhereDrawingOnArrivalHoldsEveryOther() {
        var pacer = CursorPresentationPacer()
        var jitter = Jitter()
        let arrivals = (0..<240).map { step in
            (time: 1 + Double(step) / 60 + 0.005 + jitter.next(0.003), point: point(0.1 + Double(step) * 0.003))
        }
        var next = 0
        var latestArrived: CGPoint?
        var pacedPrevious: CGPoint?, arrivalPrevious: CGPoint?
        var pacedHeld = 0, arrivalHeld = 0, refreshes = 0
        var frameTime = 1.5
        while frameTime < 4.5 {
            while next < arrivals.count, arrivals[next].time <= frameTime {
                pacer.receive(arrivals[next].point, visible: true, at: arrivals[next].time)
                latestArrived = arrivals[next].point
                next += 1
            }
            let paced = pacer.frame(at: frameTime)
            if paced == pacedPrevious { pacedHeld += 1 }
            if latestArrived == arrivalPrevious { arrivalHeld += 1 }
            pacedPrevious = paced
            arrivalPrevious = latestArrived
            refreshes += 1
            frameTime += refresh
        }
        XCTAssertGreaterThan(Double(arrivalHeld) / Double(refreshes), 0.4)
        XCTAssertLessThan(Double(pacedHeld) / Double(refreshes), 0.05)
    }

    func testDelayFollowsTheReportIntervalWithinItsBounds() {
        func delay(afterReportsEvery gap: Double) -> Double {
            var pacer = CursorPresentationPacer()
            for step in 0..<60 { pacer.receive(point(0.1 + Double(step) * 0.001), visible: true, at: 1 + Double(step) * gap) }
            return pacer.delay
        }
        XCTAssertEqual(delay(afterReportsEvery: 0.008), 0.008, accuracy: 0.0005)
        XCTAssertEqual(delay(afterReportsEvery: 1.0 / 60), 1.0 / 60, accuracy: 0.0005)
        XCTAssertEqual(delay(afterReportsEvery: 0.05), CursorPresentationPacer.maximumDelay, accuracy: 1e-9)
        XCTAssertEqual(delay(afterReportsEvery: 0.0005), CursorPresentationPacer.minimumDelay, accuracy: 1e-9)
    }

    /// After a pause, a move starts on the next refresh rather than waiting out the pause.
    func testMoveAfterRestStartsAtOnceAndCompletesWithinTheDelay() {
        var pacer = CursorPresentationPacer()
        pacer.receive(point(0.40), visible: true, at: 1)
        pacer.receive(point(0.41), visible: true, at: 1.008)
        _ = pacer.frame(at: 1.1)
        XCTAssertTrue(pacer.isSettled)
        let resumedAt = 3.0
        pacer.receive(point(0.42), visible: true, at: resumedAt)
        XCTAssertFalse(pacer.isSettled)
        let halfway = try! XCTUnwrap(pacer.frame(at: resumedAt + pacer.delay / 2))
        XCTAssertGreaterThan(halfway.x, 0.41)
        XCTAssertLessThan(halfway.x, 0.42)
        XCTAssertEqual(pacer.frame(at: resumedAt + pacer.delay), point(0.42))
        XCTAssertTrue(pacer.isSettled)
    }

    func testSettleSkipsStraightToTheNewestReport() {
        var pacer = CursorPresentationPacer()
        pacer.receive(point(0.40), visible: true, at: 1)
        pacer.receive(point(0.41), visible: true, at: 1.008)
        XCTAssertFalse(pacer.isSettled)
        pacer.settle()
        XCTAssertTrue(pacer.isSettled)
        XCTAssertEqual(pacer.frame(at: 1.008), point(0.41))
    }
}
