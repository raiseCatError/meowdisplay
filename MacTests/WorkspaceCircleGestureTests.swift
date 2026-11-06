import XCTest

/// Circling while holding switches a drag between Pane and Floating (Shared/WorkspaceFloats.swift,
/// `WorkspaceCircleGesture`). It replaces the shake, which fired on any quick back-and-forth.
final class WorkspaceCircleGestureTests: XCTestCase {
    /// Feeds samples at `hz` and returns the times it fired.
    private func run(_ g: inout WorkspaceCircleGesture, from t0: Double = 0, seconds: Double, hz: Double = 60,
                     _ path: (Double) -> (x: Double, y: Double)) -> [Double] {
        var fired: [Double] = []
        var t = t0
        while t <= t0 + seconds {
            let p = path(t - t0)
            if g.add(x: p.x, y: p.y, at: t) { fired.append(t) }
            t += 1 / hz
        }
        return fired
    }

    /// A circle of `radius` at `loopsPerSecond`, clockwise unless `ccw`.
    private func circle(radius: Double, loopsPerSecond: Double, ccw: Bool = false) -> (Double) -> (x: Double, y: Double) {
        { t in
            let a = 2 * .pi * loopsPerSecond * t * (ccw ? -1 : 1)
            return (300 + radius * cos(a), 400 + radius * sin(a))
        }
    }

    func testAboutTwoSecondsOfCirclingSwitchesOnce() {
        var g = WorkspaceCircleGesture()
        let fired = run(&g, seconds: 2.5, circle(radius: 50, loopsPerSecond: 1))
        XCTAssertEqual(fired.count, 1, "\(fired)")
        XCTAssertEqual(fired.first ?? 0, 1.75, accuracy: 0.15, "one and three-quarter loops at one a second")
        // Fast circling still needs its time; either way round, at 120 Hz too.
        var fast = WorkspaceCircleGesture()
        let quick = run(&fast, seconds: 2.5, hz: 120, circle(radius: 40, loopsPerSecond: 2.5, ccw: true))
        XCTAssertEqual(quick.count, 1)
        XCTAssertEqual(quick.first ?? 0, 1.5, accuracy: 0.1, "never before the minimum time")
    }

    func testProgressGrowsWhileCirclingForTheRing() {
        var g = WorkspaceCircleGesture()
        _ = run(&g, seconds: 0.9, circle(radius: 60, loopsPerSecond: 1))
        XCTAssertGreaterThan(g.progress, 0.4)
        XCTAssertLessThan(g.progress, 0.6)
        XCTAssertTrue(g.armed)
    }

    /// Circling on after it switched never switches back; a pause re-arms it.
    func testCirclingOnDoesntToggleAgainButAPauseRearms() {
        var g = WorkspaceCircleGesture()
        let path = circle(radius: 50, loopsPerSecond: 1)
        XCTAssertEqual(run(&g, seconds: 8, path).count, 1, "eight seconds of circling: one switch")
        XCTAssertFalse(g.armed)
        XCTAssertEqual(g.progress, 0, "no ring while it can't switch")
        // Holding still (no samples) for a moment, then circling again: a second switch.
        let again = run(&g, from: 8.6, seconds: 2.5, path)
        XCTAssertEqual(again.count, 1)
    }

    func testAShakeAZigZagOrAFigureEightNeverSwitches() {
        var shake = WorkspaceCircleGesture()
        XCTAssertTrue(run(&shake, seconds: 4) { t in (300 + 40 * sin(2 * .pi * 4 * t), 400) }.isEmpty, "side to side")
        var zigzag = WorkspaceCircleGesture()
        XCTAssertTrue(run(&zigzag, seconds: 4) { t in
            let phase = (t * 3).truncatingRemainder(dividingBy: 1)
            return (300 + 200 * t, 400 + (phase < 0.5 ? phase : 1 - phase) * 120)
        }.isEmpty)
        var eight = WorkspaceCircleGesture()
        XCTAssertTrue(run(&eight, seconds: 5) { t in
            let a = 2 * .pi * 0.8 * t
            return (300 + 80 * sin(a), 400 + 50 * sin(2 * a))
        }.isEmpty, "turns as much one way as the other")
        // A restless scribble: each step turns a random amount either way (seeded, so repeatable).
        var shaky = WorkspaceCircleGesture()
        var seed: UInt64 = 0x5EED
        func random() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
        var x = 300.0, y = 400.0, heading = 0.0
        var scribbled = 0
        for i in 0..<600 {
            heading += (random() * 2 - 1) * 1.2
            x += 8 * cos(heading); y += 8 * sin(heading)
            if shaky.add(x: x, y: y, at: Double(i) / 60) { scribbled += 1 }
        }
        XCTAssertEqual(scribbled, 0, "ten seconds of scribbling")
    }

    func testStraightMovesLongCurvesAndTinyWobblesDontCount() {
        var straight = WorkspaceCircleGesture()
        XCTAssertTrue(run(&straight, seconds: 3) { t in (100 + 300 * t, 200 + 120 * t) }.isEmpty)
        var curve = WorkspaceCircleGesture()
        XCTAssertTrue(run(&curve, seconds: 4, circle(radius: 600, loopsPerSecond: 0.3)).isEmpty, "a long sweep, not a loop")
        var wobble = WorkspaceCircleGesture()
        XCTAssertTrue(run(&wobble, seconds: 4, circle(radius: 4, loopsPerSecond: 3)).isEmpty, "finger jitter")
    }

    /// Changing direction mid-way, or stopping, starts over.
    func testReversingOrPausingStartsOver() {
        var g = WorkspaceCircleGesture()
        XCTAssertTrue(run(&g, seconds: 1.2, circle(radius: 50, loopsPerSecond: 1)).isEmpty)
        XCTAssertTrue(run(&g, from: 1.2, seconds: 1.2, circle(radius: 50, loopsPerSecond: 1, ccw: true)).isEmpty,
                      "the other way round: not enough on its own yet")
        var paused = WorkspaceCircleGesture()
        XCTAssertTrue(run(&paused, seconds: 1.2, circle(radius: 50, loopsPerSecond: 1)).isEmpty)
        let after = run(&paused, from: 2.0, seconds: 1.0, circle(radius: 50, loopsPerSecond: 1))
        XCTAssertTrue(after.isEmpty, "the pause threw away the first second")
        XCTAssertTrue(paused.isQuiet(at: 3.6))
    }

    func testResetStartsANewDragClean() {
        var g = WorkspaceCircleGesture()
        _ = run(&g, seconds: 2.2, circle(radius: 50, loopsPerSecond: 1))
        XCTAssertFalse(g.armed)
        g.reset()
        XCTAssertTrue(g.armed)
        XCTAssertEqual(g.progress, 0)
        XCTAssertEqual(run(&g, from: 3, seconds: 2.2, circle(radius: 50, loopsPerSecond: 1)).count, 1)
    }
}
