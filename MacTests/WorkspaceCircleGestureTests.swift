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

    /// A circle of `radius` at `loopsPerSecond`, clockwise unless `ccw`. `jitter`: each sample
    /// off by up to that many points either way (seeded, so repeatable), like a real finger.
    private func circle(radius: Double, loopsPerSecond: Double, ccw: Bool = false,
                        jitter: Double = 0, seed: UInt64 = 1) -> (Double) -> (x: Double, y: Double) {
        var noise = Noise(seed)
        return { t in
            let a = 2 * .pi * loopsPerSecond * t * (ccw ? -1 : 1)
            return (300 + radius * cos(a) + noise.next(jitter), 400 + radius * sin(a) + noise.next(jitter))
        }
    }

    /// A small seeded generator (an LCG), so the noisy paths are the same on every run.
    private struct Noise {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func next(_ amount: Double) -> Double { amount == 0 ? 0 : (unit() * 2 - 1) * amount }
    }

    func testACircleAndABitSwitchesOnce() {
        var g = WorkspaceCircleGesture()
        let fired = run(&g, seconds: 2.5, circle(radius: 50, loopsPerSecond: 1))
        XCTAssertEqual(fired.count, 1, "\(fired)")
        XCTAssertEqual(fired.first ?? 0, 1.3, accuracy: 0.08, "one and a quarter loops at one a second")
        // Fast circling still needs its time; either way round, at 120 Hz too.
        var fast = WorkspaceCircleGesture()
        let quick = run(&fast, seconds: 2.5, hz: 120, circle(radius: 40, loopsPerSecond: 2.5, ccw: true))
        XCTAssertEqual(quick.count, 1)
        XCTAssertEqual(quick.first ?? 0, 1.0, accuracy: 0.08, "never before the minimum time")
    }

    /// The tuning (1.25 loops, at least 1 s, 8 pt steps): a deliberate circle (40-60 pt radius,
    /// one loop a second or a little faster) switches in 1.0-1.3 s at 60 and 120 Hz, either way
    /// round. The old tuning (1.75 loops, 1.5 s) took 1.52-1.78 s for the same circles.
    func testATypicalDeliberateCircleSwitchesInAboutASecond() {
        for hz in [60.0, 120.0] {
            for radius in [40.0, 50.0, 60.0] {
                for speed in [1.0, 1.1, 1.25] {
                    for ccw in [false, true] {
                        var g = WorkspaceCircleGesture()
                        let fired = run(&g, seconds: 3, hz: hz, circle(radius: radius, loopsPerSecond: speed, ccw: ccw))
                        let label = "\(Int(hz)) Hz, radius \(radius), \(speed) loops/s\(ccw ? ", ccw" : "")"
                        XCTAssertEqual(fired.count, 1, label)
                        XCTAssertGreaterThanOrEqual(fired.first ?? 0, 1.0, label)
                        XCTAssertLessThanOrEqual(fired.first ?? 9, 1.32, label)   // 1.3 s and a sample
                    }
                }
            }
        }
    }

    /// A real finger's samples wobble a little. Measured in 8 pt steps the circle still counts; in
    /// the old 3 pt steps a point of jitter made every one of these circles start over and over.
    func testTouchJitterDoesntStopACircle() {
        var oldSteps = 0
        for hz in [60.0, 120.0] {
            for seed in UInt64(1)...12 {
                var g = WorkspaceCircleGesture()
                let fired = run(&g, seconds: 3, hz: hz, circle(radius: 50, loopsPerSecond: 1, jitter: 1, seed: seed))
                XCTAssertEqual(fired.count, 1, "\(Int(hz)) Hz, seed \(seed)")
                XCTAssertLessThanOrEqual(fired.first ?? 9, 1.8, "\(Int(hz)) Hz, seed \(seed)")
                var old = WorkspaceCircleGesture()
                old.minStep = 3
                old.reset()
                if !run(&old, seconds: 3, hz: hz, circle(radius: 50, loopsPerSecond: 1, jitter: 1, seed: seed)).isEmpty { oldSteps += 1 }
            }
        }
        XCTAssertLessThanOrEqual(oldSteps, 4, "why the steps are 8 pt: in 3 pt steps jitter breaks the circle")
    }

    func testProgressGrowsWhileCirclingForTheRing() {
        var g = WorkspaceCircleGesture()
        _ = run(&g, seconds: 0.6, circle(radius: 60, loopsPerSecond: 1))
        XCTAssertGreaterThan(g.progress, 0.35)
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
        // Shakes of any size, speed and slant, at 60 and 120 Hz.
        for amplitude in [10.0, 20, 40, 80] {
            for hz in [3.0, 5, 7] {
                for slant in [0.0, 0.5, 1.2] {
                    for rate in [60.0, 120.0] {
                        var g = WorkspaceCircleGesture()
                        XCTAssertTrue(run(&g, seconds: 3, hz: rate) { t in
                            (300 + amplitude * cos(slant) * sin(2 * .pi * hz * t), 400 + amplitude * sin(slant) * sin(2 * .pi * hz * t))
                        }.isEmpty, "shake \(amplitude) pt at \(hz) Hz, slant \(slant), \(rate) Hz samples")
                    }
                }
            }
        }
        // A sloppy shake (a little up and down as it goes side to side), and a rounded zig-zag.
        var sloppy = WorkspaceCircleGesture()
        XCTAssertTrue(run(&sloppy, seconds: 4) { t in (300 + 50 * sin(2 * .pi * 3 * t), 400 + 8 * sin(2 * .pi * 6 * t)) }.isEmpty)
        var wave = WorkspaceCircleGesture()
        XCTAssertTrue(run(&wave, seconds: 4) { t in (100 + 120 * t, 400 + 60 * sin(2 * .pi * 1.5 * t)) }.isEmpty)
        var zigzag = WorkspaceCircleGesture()
        XCTAssertTrue(run(&zigzag, seconds: 4) { t in
            let phase = (t * 3).truncatingRemainder(dividingBy: 1)
            return (300 + 200 * t, 400 + (phase < 0.5 ? phase : 1 - phase) * 120)
        }.isEmpty)
        // Figure eights turn as much one way as the other: any size and pace.
        for (w, h) in [(30.0, 20.0), (80, 50), (140, 70)] {
            for pace in [0.4, 0.8, 1.5] {
                for rate in [60.0, 120.0] {
                    var eight = WorkspaceCircleGesture()
                    XCTAssertTrue(run(&eight, seconds: 5, hz: rate) { t in
                        let a = 2 * .pi * pace * t
                        return (300 + w * sin(a), 400 + h * sin(2 * a))
                    }.isEmpty, "figure eight \(w) x \(h) at \(pace)/s, \(rate) Hz")
                }
            }
        }
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
        // Many more scribbles, wild and gentle, each ten seconds.
        for seed in UInt64(1)...150 {
            for (spread, step) in [(1.2, 8.0), (0.6, 8.0), (0.35, 6.0)] {
                var g = WorkspaceCircleGesture()
                var noise = Noise(seed &* 7919)
                var x = 300.0, y = 400.0, heading = 0.0
                for i in 0..<600 {
                    heading += noise.next(spread)
                    x += step * cos(heading); y += step * sin(heading)
                    XCTAssertFalse(g.add(x: x, y: y, at: Double(i) / 60), "scribble \(seed), spread \(spread)")
                }
            }
        }
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
        XCTAssertTrue(run(&g, seconds: 1.0, circle(radius: 50, loopsPerSecond: 1)).isEmpty)
        XCTAssertTrue(run(&g, from: 1.0, seconds: 1.0, circle(radius: 50, loopsPerSecond: 1, ccw: true)).isEmpty,
                      "the other way round: not enough on its own yet")
        var paused = WorkspaceCircleGesture()
        XCTAssertTrue(run(&paused, seconds: 1.0, circle(radius: 50, loopsPerSecond: 1)).isEmpty)
        let after = run(&paused, from: 1.8, seconds: 0.9, circle(radius: 50, loopsPerSecond: 1))
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
