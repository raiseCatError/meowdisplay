import XCTest

/// Circling while holding switches a drag between Pane and Floating (Shared/WorkspaceFloats.swift,
/// `WorkspaceCircleGesture`). Round 3: ordinary curved drags must never switch (they did while the
/// recognizer only added up turning over the whole drag), and a new circle in the same hold must
/// switch again at once, without a pause or a timer, while circling on never switches back.
///
/// Every path here is synthetic, at 60 and 120 Hz with seeded touch jitter. XCUITest can't draw a
/// circle (only a straight press-and-drag), so the feel on a device stays the owner's call. The
/// comparison of detectors behind these rules, with its numbers, is in the round-3 PR notes.
final class WorkspaceCircleGestureTests: XCTestCase {
    typealias Point = (x: Double, y: Double)
    typealias Path = (Double) -> Point

    private static let rates = [60.0, 120.0]

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

    /// Feeds `path` at `hz` from `t0` for `seconds`, each sample off by up to `jitter` points
    /// either way (seeded), skipping `gaps` (a resting finger: iOS sends nothing). Returns when
    /// it switched (seconds into the path); `each` sees the gesture after every sample.
    @discardableResult
    private func run(_ g: inout WorkspaceCircleGesture, from t0: Double = 0, seconds: Double, hz: Double = 60,
                     jitter: Double = 0, seed: UInt64 = 1, gaps: [ClosedRange<Double>] = [],
                     each: ((Double, WorkspaceCircleGesture) -> Void)? = nil, _ path: Path) -> [Double] {
        var noise = Noise(seed)
        var fired: [Double] = []
        var i = 0
        while Double(i) / hz <= seconds + 1e-9 {
            let tau = Double(i) / hz
            i += 1
            if gaps.contains(where: { $0.contains(tau) }) { continue }
            let p = path(tau)
            if g.add(x: p.x + noise.next(jitter), y: p.y + noise.next(jitter), at: t0 + tau) { fired.append(tau) }
            each?(tau, g)
        }
        return fired
    }

    /// A fresh gesture over `path`, with half a point of jitter: when it switched.
    private func switches(seconds: Double, hz: Double, jitter: Double = 0.5, seed: UInt64 = 1, _ path: Path) -> [Double] {
        var g = WorkspaceCircleGesture()
        return run(&g, seconds: seconds, hz: hz, jitter: jitter, seed: seed, path)
    }

    // MARK: Paths

    /// Circling: `radius` is the long half-axis (the short one is radius / `aspect`, tilted by
    /// `tilt`), `loops` a second, clockwise on screen unless `ccw`, from angle `phase`; the centre
    /// drifts by `drift` points a second and the pace varies by `uneven` within each loop.
    private func circle(radius: Double, loops: Double, ccw: Bool = false, aspect: Double = 1, tilt: Double = 0,
                        phase: Double = 0, uneven: Double = 0, centre: Point = (300, 400), drift: Point = (0, 0)) -> Path {
        { t in
            let w = 2 * .pi * loops
            let a = phase + (ccw ? -1 : 1) * (w * t + uneven * sin(w * t))
            let ex = radius * cos(a), ey = radius / aspect * sin(a)
            return (centre.x + drift.x * t + ex * cos(tilt) - ey * sin(tilt),
                    centre.y + drift.y * t + ex * sin(tilt) + ey * cos(tilt))
        }
    }

    /// Which way `path` heads at `t` (radians), for joining paths smoothly.
    private func heading(_ path: Path, at t: Double) -> Double {
        let a = path(t - 0.001), b = path(t)
        return atan2(b.y - a.y, b.x - a.x)
    }

    /// The phase that starts a round `circle(...)` heading `direction`.
    private func phase(heading direction: Double, ccw: Bool) -> Double { direction + (ccw ? .pi / 2 : -.pi / 2) }

    /// At constant speed along a polyline: the path and how long it takes.
    private func along(_ points: [Point], speed: Double) -> (path: Path, seconds: Double) {
        var ends: [Double] = [0]
        for i in 1..<points.count { ends.append(ends[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
        let total = ends.last ?? 0
        let path: Path = { t in
            let s = min(max(t * speed, 0), total)
            var i = 1
            while i < points.count - 1, ends[i] < s { i += 1 }
            let span = ends[i] - ends[i - 1]
            let u = span > 0 ? (s - ends[i - 1]) / span : 0
            return (points[i - 1].x + (points[i].x - points[i - 1].x) * u, points[i - 1].y + (points[i].y - points[i - 1].y) * u)
        }
        return (path, total / speed)
    }

    private func arc(_ c: Point, _ r: Double, from a0: Double, sweep: Double) -> [Point] {
        let n = max(Int(abs(sweep) * r / 2), 8)
        return (0...n).map { i in
            let a = a0 + sweep * Double(i) / Double(n)
            return (c.x + r * cos(a), c.y + r * sin(a))
        }
    }

    /// `length` points on from `p`, heading `direction`.
    private func straight(_ p: Point, _ direction: Double, _ length: Double) -> Point {
        (p.x + length * cos(direction), p.y + length * sin(direction))
    }

    /// Paths end to end, each moved to start where the one before ended.
    private func then(_ parts: [(path: Path, seconds: Double)]) -> (path: Path, seconds: Double) {
        var offsets: [Point] = []
        var end: Point?
        for part in parts {
            let start = part.path(0)
            let off: Point = end.map { ($0.x - start.x, $0.y - start.y) } ?? (0, 0)
            offsets.append(off)
            let e = part.path(part.seconds)
            end = (e.x + off.x, e.y + off.y)
        }
        let path: Path = { t in
            var t = t
            for (i, part) in parts.enumerated() {
                if t <= part.seconds || i == parts.count - 1 {
                    let p = part.path(min(t, part.seconds))
                    return (p.x + offsets[i].x, p.y + offsets[i].y)
                }
                t -= part.seconds
            }
            return (0, 0)
        }
        return (path, parts.reduce(0) { $0 + $1.seconds })
    }

    /// Round the outside of a `w` x `h` window (rounded by `corner`) from the middle of its
    /// bottom side, `quarters` corners' worth, clockwise on screen unless `ccw`, then on a bit.
    private func aroundWindow(w: Double, h: Double, corner: Double, quarters: Int, ccw: Bool = false) -> [Point] {
        let cx = 300.0, cy = 400.0, hw = w / 2 - corner, hh = h / 2 - corner
        // Clockwise on screen (y down) from the bottom middle: bottom-left, top-left, top-right, bottom-right.
        let corners: [(Point, Double)] = [((cx - hw, cy + hh), .pi / 2), ((cx - hw, cy - hh), .pi),
                                          ((cx + hw, cy - hh), 1.5 * .pi), ((cx + hw, cy + hh), 0)]
        var points: [Point] = [(cx, cy + h / 2)]
        for q in 0..<quarters {
            let (c, a0) = corners[q % 4]
            points += arc(c, corner, from: a0, sweep: .pi / 2)
        }
        points.append(straight(points[points.count - 1], Double(quarters % 4) * .pi / 2 + .pi, min(w, h) / 2))
        return ccw ? points.map { (600 - $0.x, $0.y) } : points
    }

    /// Back and forth past a spot, `strokes` lengths of `length` points, the ends rounded (radius
    /// `end`) and both turning the same way: a stretched loop.
    private func backAndForth(length: Double, end: Double, strokes: Int, ccw: Bool = false) -> [Point] {
        var points: [Point] = []
        for s in 0..<strokes {
            let right = s % 2 == 0
            points.append((right ? 300 - length / 2 : 300 + length / 2, right ? 400 - end : 400 + end))
            points.append((right ? 300 + length / 2 : 300 - length / 2, right ? 400 - end : 400 + end))
            points += arc((right ? 300 + length / 2 : 300 - length / 2, 400), end, from: right ? -.pi / 2 : .pi / 2, sweep: .pi)
        }
        return ccw ? points.map { ($0.x, 800 - $0.y) } : points
    }

    // MARK: Deliberate circles switch, once

    /// A deliberate circle (25-70 pt radius, 0.8-1.5 loops a second, the pace a little uneven)
    /// switches once, after one and a quarter loops and at least a second, at 60 and 120 Hz,
    /// either way round.
    func testADeliberateCircleSwitchesOnceAfterALoopAndABit() {
        for hz in Self.rates {
            for radius in [25.0, 40, 55, 70] {
                for loops in [0.8, 1.0, 1.25, 1.5] {
                    for ccw in [false, true] {
                        let label = "\(Int(hz)) Hz, radius \(radius), \(loops) loops/s\(ccw ? ", ccw" : "")"
                        let fired = switches(seconds: 2.4 / loops, hz: hz, seed: UInt64(radius),
                                             circle(radius: radius, loops: loops, ccw: ccw, phase: radius, uneven: 0.2))
                        XCTAssertEqual(fired.count, 1, label)
                        XCTAssertGreaterThanOrEqual(fired.first ?? 0, 1.0, label)
                        XCTAssertLessThanOrEqual(fired.first ?? 9, max(1.25 / loops, 1.0) + 0.2, label)
                    }
                }
            }
        }
    }

    /// Fast circles still take their second; slow and large ones, ellipses up to about 2:1, a
    /// circle that drifts a little and one that begins after a straight drag all switch once.
    func testFastSlowLargeEllipticalAndDriftingCirclesSwitch() {
        for hz in Self.rates {
            for (radius, loops) in [(20.0, 3.0), (35, 2.5), (50, 2.0)] {
                let fired = switches(seconds: 2.5, hz: hz, circle(radius: radius, loops: loops, ccw: radius > 30))
                XCTAssertEqual(fired.count, 1, "fast, radius \(radius) at \(loops)/s, \(Int(hz)) Hz")
                XCTAssertEqual(fired.first ?? 0, 1.0, accuracy: 0.06, "never before a second")
            }
            for (radius, loops) in [(40.0, 0.5), (70, 0.6), (110, 0.6), (140, 0.5)] {
                let fired = switches(seconds: 3.5 / loops, hz: hz, circle(radius: radius, loops: loops))
                XCTAssertEqual(fired.count, 1, "slow or large, radius \(radius) at \(loops)/s, \(Int(hz)) Hz")
                XCTAssertLessThanOrEqual(fired.first ?? 99, 1.25 / loops + 0.3)
            }
            for aspect in [1.4, 1.8, 2.2] {
                for tilt in [0.0, 0.7] {
                    let fired = switches(seconds: 2.5, hz: hz, circle(radius: 60, loops: 1, aspect: aspect, tilt: tilt, uneven: 0.15))
                    XCTAssertEqual(fired.count, 1, "ellipse \(aspect):1 tilted \(tilt), \(Int(hz)) Hz")
                }
            }
            let drifting = switches(seconds: 2.5, hz: hz, circle(radius: 40, loops: 1, drift: (12, -8)))
            XCTAssertEqual(drifting.count, 1, "drifting about 15 pt a loop, \(Int(hz)) Hz")
            let lead = 0.4
            let afterDrag = then([(path: { t in (100 + 300 * t, 300 + 40 * t) }, seconds: lead),
                                  (path: circle(radius: 45, loops: 1, phase: phase(heading: atan2(40, 300), ccw: false)), seconds: 3)])
            let fired = switches(seconds: afterDrag.seconds, hz: hz, afterDrag.path)
            XCTAssertEqual(fired.count, 1, "a drag, then circling, \(Int(hz)) Hz")
            XCTAssertLessThanOrEqual((fired.first ?? 9) - lead, 1.45, "timed from the circling, not the drag")
        }
    }

    /// A real finger's samples wobble. Measured in 8 pt chords a circle still counts with up to a
    /// point of jitter on every sample.
    func testTouchJitterDoesntStopACircle() {
        for hz in Self.rates {
            for seed in UInt64(1)...12 {
                let fired = switches(seconds: 3, hz: hz, jitter: 1, seed: seed, circle(radius: 50, loops: 1))
                XCTAssertEqual(fired.count, 1, "\(Int(hz)) Hz, seed \(seed)")
                XCTAssertLessThanOrEqual(fired.first ?? 9, 1.45, "\(Int(hz)) Hz, seed \(seed)")
            }
        }
    }

    // MARK: The ring

    /// The ring shows only while the motion plausibly is a circle (from five eighths of a loop),
    /// fills as it goes, and is gone from the switch on while the circling goes on.
    func testTheRingShowsOnlyWhileCircling() {
        for hz in Self.rates {
            var g = WorkspaceCircleGesture()
            var early = 0.0, before = 0.0, after = 0.0
            let fired = run(&g, seconds: 4, hz: hz, jitter: 0.5, each: { t, g in
                if t < 0.55 { early = max(early, g.progress) }
                if g.latched == nil { before = max(before, g.progress) } else { after = max(after, g.progress) }
            }, circle(radius: 50, loops: 1))
            XCTAssertEqual(fired.count, 1)
            XCTAssertEqual(early, 0, "no ring for the first half loop, \(Int(hz)) Hz")
            XCTAssertGreaterThan(before, 0.8, "it filled before switching, \(Int(hz)) Hz")
            XCTAssertEqual(after, 0, "circling on after the switch: no ring, \(Int(hz)) Hz")
            XCTAssertEqual(g.latched, .clockwise)
        }
    }

    /// Ordinary drags show no ring: S-curves, zig-zags, straight moves, nudging back and forth,
    /// going round a window's corner.
    func testOrdinaryDragsShowNoRing() {
        for hz in Self.rates {
            var paths: [(String, Path, Double)] = [
                ("S-curve", { t in (100 + 300 * t, 400 + 80 * sin(2 * .pi * t)) }, 3),
                ("zig-zag", { t in let ph = (t * 2).truncatingRemainder(dividingBy: 1); return (100 + 150 * t, 400 + (ph < 0.5 ? ph : 1 - ph) * 200) }, 3),
                ("straight", { t in (100 + 300 * t, 200 + 120 * t) }, 2),
            ]
            let nudge = along(backAndForth(length: 160, end: 15, strokes: 5), speed: 300)
            paths.append(("back and forth", nudge.path, nudge.seconds))
            let corner = along(aroundWindow(w: 300, h: 320, corner: 30, quarters: 1), speed: 350)
            paths.append(("round a window's corner", corner.path, corner.seconds))
            for (name, path, seconds) in paths {
                var g = WorkspaceCircleGesture()
                var ring = 0.0
                run(&g, seconds: seconds, hz: hz, jitter: 0.5, each: { _, g in ring = max(ring, g.progress) }, path)
                XCTAssertEqual(ring, 0, "\(name), \(Int(hz)) Hz")
            }
        }
    }

    // MARK: Ordinary drags never switch (false positives)

    /// Arcs of any size up to most of a loop, either way, with a straight drag in and out;
    /// S-curves; arcs this way and that, one after another.
    func testArcsAndSCurvesNeverSwitch() {
        for hz in Self.rates {
            for radius in [40.0, 80, 150, 300] {
                for degrees in [90.0, 180, 270, 330] {
                    for ccw in [false, true] {
                        let way = ccw ? -1.0 : 1.0
                        let sweep = degrees * .pi / 180 * way
                        var points = arc((300, 400), radius, from: 0.3, sweep: sweep)
                        points.insert(straight(points[0], 0.3 - way * .pi / 2, 120), at: 0)
                        points.append(straight(points[points.count - 1], 0.3 + sweep + way * .pi / 2, 120))
                        for speed in [200.0, 500] {
                            let p = along(points, speed: speed)
                            XCTAssertTrue(switches(seconds: p.seconds, hz: hz, p.path).isEmpty,
                                          "arc \(degrees)°, radius \(radius), at \(speed)\(ccw ? ", ccw" : ""), \(Int(hz)) Hz")
                        }
                    }
                }
            }
            for amplitude in [40.0, 100, 150] {
                for wavelength in [150.0, 300, 500] {
                    XCTAssertTrue(switches(seconds: 3, hz: hz) { t in (50 + 300 * t, 400 + amplitude * sin(2 * .pi * 300 * t / wavelength)) }.isEmpty,
                                  "S-curve \(amplitude) x \(wavelength), \(Int(hz)) Hz")
                }
            }
            var points: [Point] = [(100, 300)]
            var direction = 0.2, way = 1.0
            for (radius, degrees) in [(80.0, 160.0), (140, 120), (60, 200), (120, 150), (90, 180)] {
                let c = straight(points[points.count - 1], direction + way * .pi / 2, radius)
                let a0 = atan2(points[points.count - 1].y - c.y, points[points.count - 1].x - c.x)
                points += arc(c, radius, from: a0, sweep: way * degrees * .pi / 180).dropFirst()
                direction += way * degrees * .pi / 180
                way = -way
            }
            let chained = along(points, speed: 350)
            XCTAssertTrue(switches(seconds: chained.seconds, hz: hz, chained.path).isEmpty, "arcs this way and that, \(Int(hz)) Hz")
        }
    }

    /// Moving a window round another one: half way, three quarters, or all the way round it.
    func testMovingRoundAnotherWindowNeverSwitches() {
        for hz in Self.rates {
            for (w, h) in [(220.0, 240.0), (300, 360), (420, 480)] {
                for quarters in [2, 3, 4] {
                    for ccw in [false, true] {
                        for speed in [250.0, 450] {
                            let p = along(aroundWindow(w: w, h: h, corner: 30, quarters: quarters, ccw: ccw), speed: speed)
                            XCTAssertTrue(switches(seconds: p.seconds + 0.2, hz: hz, p.path).isEmpty,
                                          "round a \(w) x \(h) window, \(quarters) corners\(ccw ? ", ccw" : ""), at \(speed), \(Int(hz)) Hz")
                        }
                    }
                }
            }
        }
    }

    /// Long sweeping drags that turn more than a loop in all, over a large area: a big loop (more
    /// than a loop and a quarter of it), laps of the screen, a drag that keeps bending one way.
    func testLongSweepingDragsNeverSwitch() {
        for hz in Self.rates {
            for radius in [170.0, 220, 280] {
                for loops in [1.3, 1.6] {
                    let rate = 400 / (2 * .pi * radius)
                    XCTAssertTrue(switches(seconds: loops / rate, hz: hz, circle(radius: radius, loops: rate, centre: (215, 466), drift: (20, 30))).isEmpty,
                                  "a big loop, radius \(radius), \(loops) loops, \(Int(hz)) Hz")
                }
            }
            // Round an iPhone's whole screen (430 x 932 pt), twice.
            var laps: [Point] = []
            for _ in 0..<2 { laps += aroundWindow(w: 360, h: 800, corner: 60, quarters: 4) }
            let tour = along(laps, speed: 600)
            XCTAssertTrue(switches(seconds: tour.seconds, hz: hz, tour.path).isEmpty, "laps of the screen, \(Int(hz)) Hz")
            // A drag that keeps bending one way, a loop and a half in all over 2000 pt (about a
            // 230 pt radius on average), unevenly (seeded).
            for seed in UInt64(1)...10 {
                var noise = Noise(seed)
                var points: [Point] = [(215, 466)]
                var direction = 0.0
                for _ in 0..<260 {
                    direction += 0.035 + noise.next(0.1)
                    points.append(straight(points[points.count - 1], direction, 8 + noise.next(4)))
                }
                let bend = along(points, speed: 300 + 30 * Double(seed))
                XCTAssertTrue(switches(seconds: bend.seconds, hz: hz, bend.path).isEmpty, "a bending sweep, seed \(seed), \(Int(hz)) Hz")
            }
        }
    }

    /// Repositioning a window: aimed moves with overshoot and correction, a little tremor, short
    /// stops; nudging it back and forth past its spot (stretched loops, both ends turning the same
    /// way); loops that travel across the screen; wandering round a spot while deciding.
    func testRepositioningAndNudgingNeverSwitch() {
        for hz in Self.rates {
            for seed in UInt64(1)...20 {
                var noise = Noise(seed &* 31)
                var stops: [(start: Double, from: Point, to: Point, seconds: Double, bow: Double)] = []
                var at: Point = (215, 466), t = 0.0
                for _ in 0..<6 {
                    let distance = 30 + 90 * (1 + noise.next(1)), direction = noise.next(.pi)
                    let to = straight(at, direction, distance)
                    let seconds = 0.45 + noise.next(0.2)
                    stops.append((t, at, to, seconds, noise.next(0.25) * distance))
                    at = to
                    t += seconds + 0.2 + abs(noise.next(0.15))
                }
                let move: Path = { tau in
                    var p = stops[0].from
                    for s in stops where tau >= s.start {
                        let u = min((tau - s.start) / s.seconds, 1.4)
                        let k = min(u, 1)
                        let eased = k * k * k * (10 - 15 * k + 6 * k * k) + 0.12 * sin(.pi * min(max(u - 0.6, 0) / 0.8, 1))
                        let side = s.bow * sin(.pi * k)
                        let d = atan2(s.to.y - s.from.y, s.to.x - s.from.x)
                        p = (s.from.x + (s.to.x - s.from.x) * eased - side * sin(d) + 1.5 * sin(2 * .pi * 9 * tau),
                             s.from.y + (s.to.y - s.from.y) * eased + side * cos(d) + 1.5 * sin(2 * .pi * 8 * tau))
                    }
                    return p
                }
                XCTAssertTrue(switches(seconds: t + 0.3, hz: hz, seed: seed, move).isEmpty, "repositioning, seed \(seed), \(Int(hz)) Hz")
            }
            for (length, end) in [(80.0, 10.0), (120, 15), (160, 25), (200, 20), (140, 40)] {
                for ccw in [false, true] {
                    let nudge = along(backAndForth(length: length, end: end, strokes: 6, ccw: ccw), speed: 300)
                    XCTAssertTrue(switches(seconds: nudge.seconds, hz: hz, nudge.path).isEmpty,
                                  "back and forth \(length) pt, ends \(end)\(ccw ? ", ccw" : ""), \(Int(hz)) Hz")
                }
            }
            for (radius, travel) in [(30.0, 1.0), (45, 1.2), (60, 1.5), (40, 2.0)] {
                XCTAssertTrue(switches(seconds: 2.5, hz: hz, circle(radius: radius, loops: 1.2, drift: (radius * travel * 1.2, 0))).isEmpty,
                              "loops travelling \(travel) radii each, \(Int(hz)) Hz")
            }
            for seed in UInt64(1)...10 {
                // Wandering round a spot: a smooth random velocity pulled back toward it.
                var noise = Noise(seed &* 977)
                var points: [Point] = []
                var x = 0.0, y = 0.0, vx = 0.0, vy = 0.0
                let dt = 1.0 / 240
                for _ in 0..<(4 * 240) {
                    vx += (-6 * x - 3.5 * vx + 600 * noise.next(1)) * dt
                    vy += (-6 * y - 3.5 * vy + 600 * noise.next(1)) * dt
                    x += vx * dt; y += vy * dt
                    points.append((215 + x, 466 + y))
                }
                let wander: Path = { t in points[min(Int(t * 240), points.count - 1)] }
                XCTAssertTrue(switches(seconds: 4, hz: hz, wander).isEmpty, "wandering round a spot, seed \(seed), \(Int(hz)) Hz")
            }
        }
    }

    /// Shakes of any size, speed and slant, sloppy ones, zig-zags, figure eights, tiny wobbles,
    /// long gentle curves and straight moves never switch.
    func testShakesZigZagsAndFigureEightsNeverSwitch() {
        for rate in Self.rates {
            for amplitude in [10.0, 20, 40, 80] {
                for hz in [3.0, 5, 7] {
                    for slant in [0.0, 0.5, 1.2] {
                        XCTAssertTrue(switches(seconds: 3, hz: rate) { t in
                            (300 + amplitude * cos(slant) * sin(2 * .pi * hz * t), 400 + amplitude * sin(slant) * sin(2 * .pi * hz * t))
                        }.isEmpty, "shake \(amplitude) pt at \(hz) Hz, slant \(slant), \(rate) Hz samples")
                    }
                }
            }
            // A sloppy shake (a little up and down as it goes side to side), an oval one, a wave, a zig-zag.
            XCTAssertTrue(switches(seconds: 4, hz: rate) { t in (300 + 50 * sin(2 * .pi * 3 * t), 400 + 8 * sin(2 * .pi * 6 * t)) }.isEmpty)
            XCTAssertTrue(switches(seconds: 4, hz: rate) { t in (300 + 60 * sin(2 * .pi * 4 * t), 400 + 12 * sin(2 * .pi * 4 * t + 1)) }.isEmpty)
            XCTAssertTrue(switches(seconds: 4, hz: rate) { t in (100 + 120 * t, 400 + 60 * sin(2 * .pi * 1.5 * t)) }.isEmpty)
            XCTAssertTrue(switches(seconds: 4, hz: rate) { t in
                let phase = (t * 3).truncatingRemainder(dividingBy: 1)
                return (300 + 200 * t, 400 + (phase < 0.5 ? phase : 1 - phase) * 120)
            }.isEmpty)
            // Figure eights turn as much one way as the other: any size and pace.
            for (w, h) in [(30.0, 20.0), (80, 50), (140, 70)] {
                for pace in [0.4, 0.8, 1.5] {
                    XCTAssertTrue(switches(seconds: 5, hz: rate) { t in
                        let a = 2 * .pi * pace * t
                        return (300 + w * sin(a), 400 + h * sin(2 * a))
                    }.isEmpty, "figure eight \(w) x \(h) at \(pace)/s, \(rate) Hz")
                }
            }
            XCTAssertTrue(switches(seconds: 4, hz: rate, circle(radius: 4, loops: 3)).isEmpty, "finger jitter")
            XCTAssertTrue(switches(seconds: 4, hz: rate, circle(radius: 600, loops: 0.3)).isEmpty, "a long curve")
            XCTAssertTrue(switches(seconds: 3, hz: rate) { t in (100 + 300 * t, 200 + 120 * t) }.isEmpty, "straight")
        }
    }

    /// Restless scribbles: every 8 pt step turns a random amount either way (seeded, ten seconds
    /// each, far more jagged than a finger). They don't turn steadily one way, so they don't
    /// switch, except where a scribble happens to draw a real loop: round, closed, steady, about
    /// a second. Of these 450, three do; none of the wildest or the gentlest.
    func testScribblesSwitchOnlyWhereTheyDrawARealLoop() {
        var looped: [String] = []
        for seed in UInt64(1)...150 {
            for (spread, step) in [(1.2, 8.0), (0.6, 8.0), (0.35, 6.0)] {
                var g = WorkspaceCircleGesture()
                var noise = Noise(seed &* 7919)
                var x = 300.0, y = 400.0, heading = 0.0
                for i in 0..<600 {
                    heading += noise.next(spread)
                    x += step * cos(heading); y += step * sin(heading)
                    if g.add(x: x, y: y, at: Double(i) / 60) { looped.append("\(seed)/\(spread)"); break }
                }
            }
        }
        XCTAssertEqual(looped, ["17/0.6", "62/0.6", "136/0.6"])
    }

    // MARK: Repeated switches in one hold

    /// Circling on after it switched never switches back, however long and however it drifts:
    /// one switch for one motion, and no timer rearms it.
    func testCirclingOnSwitchesOnceNeverBackAndForth() {
        for hz in Self.rates {
            for (radius, loops, drift) in [(30.0, 1.4, 0.0), (50, 1.0, 10), (70, 0.9, 15), (45, 1.2, 0)] {
                for ccw in [false, true] {
                    var g = WorkspaceCircleGesture()
                    let fired = run(&g, seconds: 8, hz: hz, jitter: 0.5,
                                    circle(radius: radius, loops: loops, ccw: ccw, aspect: 1.2, uneven: 0.2, drift: (drift, -drift / 2)))
                    XCTAssertEqual(fired.count, 1, "eight seconds circling, radius \(radius)\(ccw ? ", ccw" : ""), \(Int(hz)) Hz")
                    XCTAssertEqual(g.latched, ccw ? .counterclockwise : .clockwise)
                    XCTAssertFalse(g.armed)
                }
            }
        }
    }

    /// A circle, then straight on into a circle the other way round (an S, or turning back where
    /// it is): it switches again as soon as that circle is complete, built only from motion after
    /// the first switch; no pause and no fixed delay. Pane → Floating → Pane → Floating works
    /// the same way.
    func testACircleTheOtherWaySwitchesAgainAtOnce() {
        for hz in Self.rates {
            for (radius, loops) in [(35.0, 1.3), (50, 1.0), (65, 0.9)] {
                for turnBack in [false, true] {
                    let first = circle(radius: radius, loops: loops)
                    let firstSeconds = 1.25 / loops + 0.3   // the switch, and a moment more
                    let out = heading(first, at: firstSeconds)
                    let second = circle(radius: radius, loops: loops, ccw: true, phase: phase(heading: out + (turnBack ? .pi : 0), ccw: true))
                    let both = then([(first, firstSeconds), (second, 1.25 / loops + 1)])
                    let fired = switches(seconds: both.seconds, hz: hz, both.path)
                    let label = "radius \(radius), \(turnBack ? "turning back" : "an S"), \(Int(hz)) Hz"
                    XCTAssertEqual(fired.count, 2, "\(label): \(fired)")
                    guard fired.count == 2 else { continue }
                    // Built only from motion after the first switch: its own loop and a quarter, its own second.
                    XCTAssertGreaterThanOrEqual(fired[1] - fired[0], 1.2, label)
                    let latency = fired[1] - firstSeconds   // from turning the other way
                    XCTAssertGreaterThanOrEqual(latency, 0.95, "\(label): its own circle")
                    XCTAssertLessThanOrEqual(latency, max(1.25 / loops, 1.0) + 0.2, "\(label): as soon as it's complete")
                }
            }
            var parts: [(path: Path, seconds: Double)] = []
            var ccw = false
            var direction = 0.0
            for i in 0..<3 {
                let c = circle(radius: 45, loops: 1.1, ccw: ccw, phase: i == 0 ? 0 : phase(heading: direction, ccw: ccw))
                let seconds = 1.25 / 1.1 + (i < 2 ? 0.35 : 1)
                parts.append((c, seconds))
                direction = heading(c, at: seconds)
                ccw.toggle()
            }
            let three = then(parts)
            XCTAssertEqual(switches(seconds: three.seconds, hz: hz, three.path).count, 3, "three circles, alternating, \(Int(hz)) Hz")
            // Most of a circle the other way isn't a circle: no second switch.
            let first = circle(radius: 50, loops: 1)
            let back = circle(radius: 50, loops: 1, ccw: true, phase: phase(heading: heading(first, at: 1.55), ccw: true))
            let short = then([(first, 1.55), (back, 0.9)])
            XCTAssertEqual(switches(seconds: short.seconds, hz: hz, short.path).count, 1, "not a whole circle back, \(Int(hz)) Hz")
        }
    }

    /// The same way round again in the same hold, once that circling has stopped: after a short
    /// rest (nothing sent, or a resting finger's jitter), after moving on elsewhere, or after
    /// turning the other way for a moment.
    func testANewCircleAfterARestAMoveOrATurnSwitchesAgain() {
        for hz in Self.rates {
            for radius in [35.0, 55] {
                let first = circle(radius: radius, loops: 1.1)
                let firstSeconds = 1.25 / 1.1 + 0.3
                let next = circle(radius: radius, loops: 1.1)
                for rest in [0.35, 0.6] {
                    let again = then([(first, firstSeconds), ({ _ in (0, 0) }, rest), (next, 2.2)])
                    var g = WorkspaceCircleGesture()
                    let fired = run(&g, seconds: again.seconds, hz: hz, jitter: 0.5,
                                    gaps: [(firstSeconds + 0.01)...(firstSeconds + rest)], again.path)
                    XCTAssertEqual(fired.count, 2, "radius \(radius), a \(rest) s rest, \(Int(hz)) Hz")
                }
                let resting = then([(first, firstSeconds), ({ _ in (0, 0) }, 0.45), (next, 2.2)])
                XCTAssertEqual(switches(seconds: resting.seconds, hz: hz, jitter: 1, resting.path).count, 2,
                               "radius \(radius), resting with jitter, \(Int(hz)) Hz")
                let out = heading(first, at: firstSeconds)
                for (length, bend) in [(120.0, 0.3), (200, -0.4)] {
                    let move: Path = { t in
                        let s = 300 * t, k = bend / length
                        return ((sin(out + k * s) - sin(out)) / k, (cos(out) - cos(out + k * s)) / k)
                    }
                    let there = circle(radius: radius, loops: 1.1, phase: phase(heading: out + bend, ccw: false))
                    let moved = then([(first, firstSeconds), (move, length / 300), (there, 2.2)])
                    XCTAssertEqual(switches(seconds: moved.seconds, hz: hz, moved.path).count, 2,
                                   "radius \(radius), moved on \(length) pt, \(Int(hz)) Hz")
                }
                let bendBack = circle(radius: radius, loops: 1.1, ccw: true, phase: phase(heading: out, ccw: true))
                let onAgain = circle(radius: radius, loops: 1.1, phase: phase(heading: heading(bendBack, at: 0.45), ccw: false))
                let wiggled = then([(first, firstSeconds), (bendBack, 0.45), (onAgain, 2.2)])
                XCTAssertEqual(switches(seconds: wiggled.seconds, hz: hz, wiggled.path).count, 2,
                               "radius \(radius), an S-bend, \(Int(hz)) Hz")
            }
        }
    }

    // MARK: Starting over

    /// A sharp turn or a rest throws away the circling so far.
    func testASharpTurnOrARestStartsOver() {
        var g = WorkspaceCircleGesture()
        XCTAssertTrue(run(&g, seconds: 1.0, circle(radius: 50, loops: 1)).isEmpty)
        XCTAssertTrue(run(&g, from: 1.0, seconds: 1.0, circle(radius: 50, loops: 1, ccw: true)).isEmpty,
                      "turned back: not enough on its own yet")
        var paused = WorkspaceCircleGesture()
        XCTAssertTrue(run(&paused, seconds: 1.0, circle(radius: 50, loops: 1)).isEmpty)
        XCTAssertTrue(run(&paused, from: 1.8, seconds: 0.9, circle(radius: 50, loops: 1)).isEmpty, "the rest threw away the first second")
        XCTAssertTrue(paused.isQuiet(at: 3.6))
        XCTAssertFalse(paused.isQuiet(at: 2.75))
    }

    func testResetStartsANewDragClean() {
        var g = WorkspaceCircleGesture()
        XCTAssertEqual(run(&g, seconds: 2.2, circle(radius: 50, loops: 1)).count, 1)
        XCTAssertFalse(g.armed)
        g.reset()
        XCTAssertTrue(g.armed)
        XCTAssertNil(g.latched)
        XCTAssertEqual(g.progress, 0)
        XCTAssertEqual(run(&g, from: 3, seconds: 2.2, circle(radius: 50, loops: 1)).count, 1)
    }
}
