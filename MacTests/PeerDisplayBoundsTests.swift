import XCTest

/// Numbers a paired receiver sends must never trap the Mac (a trap ends every
/// receiver's session with it). Covers the hello's geometry bounds
/// (`PeerDisplayBounds`), the sizing math it feeds, and the other sinks a
/// receiver's numbers reach: macroblock counting, the FPS policy, scroll
/// deltas, Pencil pressure and the Unified Clipboard's counters. Every real
/// device keeps exactly today's results (checked against the old formulas).
final class PeerDisplayBoundsTests: XCTestCase {

    // MARK: - Real devices (pixels, landscape; both orientations are checked)

    private static let realPanels: [(String, Int, Int)] = [
        ("iPhone SE", 1334, 750), ("iPhone 12", 2532, 1170), ("iPhone 13 mini", 2340, 1080),
        ("iPhone 16 Pro Max", 2868, 1320), ("iPad 10th gen", 2360, 1640), ("iPad mini 6", 2266, 1488),
        ("iPad Pro 12.9", 2732, 2048), ("iPad Pro 13 M4", 2752, 2064),
        ("Mac receiver, MacBook Air 13 below the notch", 2940, 1848), ("Mac receiver, 1080p at 2x", 3840, 2160),
        ("Mac receiver, Studio Display", 5120, 2880), ("Mac receiver, Pro Display XDR", 6016, 3384),
        ("Mac receiver, XDR More Space", 6720, 3780), ("Mac receiver, 8K", 7680, 4320),
        ("Mac receiver, 1x 8K announced at 2x", 15360, 8640),
        ("Galaxy Tab S9 Ultra", 2960, 1848), ("Pixel Tablet", 2560, 1600), ("Galaxy S24 Ultra", 3120, 1440),
        ("Pixel 9 Pro", 2856, 1280), ("Surface Duo 2 unfolded", 2754, 1892), ("Pixel Fold inner", 2208, 1840),
        ("Galaxy Z Fold 5 inner", 2176, 1812), ("Android TV", 3840, 2160), ("budget tablet", 1280, 800),
        ("not measured yet", 0, 0),
    ]
    private static let realScales: [Double] = [1, 2, 3, 0.75, 1.5, 2.625, 3.5, 4]
    private static let qualityScales: [Double] = [1.0, 0.75, 0.5]
    private static let realCeilings: [(Int?, Int?)] = [
        (nil, nil), (4096, 2304), (3840, 2160), (8192, 4320), (1920, 1080), (4096, nil),
    ]

    private static var bothOrientations: [(String, Int, Int)] {
        realPanels.flatMap { [($0.0, $0.1, $0.2), ($0.0 + " (portrait)", $0.2, $0.1)] }
    }

    func testEveryRealDeviceIsAccepted() {
        for (name, wide, high) in Self.bothOrientations {
            for scale in Self.realScales {
                XCTAssertNil(PeerDisplayBounds.violation(pixelsWide: wide, pixelsHigh: high, scale: scale),
                             "\(name) @\(scale)x must never be refused")
            }
        }
    }

    func testGeometryBoundsAreInclusiveAndEverythingElseIsRefused() {
        XCTAssertNil(PeerDisplayBounds.violation(pixelsWide: 32_768, pixelsHigh: 32_768, scale: 16))
        XCTAssertNil(PeerDisplayBounds.violation(pixelsWide: 0, pixelsHigh: 0, scale: 0.25))
        for bad in [-1, 32_769, Int.max, Int.min, 1 << 40] {
            XCTAssertEqual(PeerDisplayBounds.violation(pixelsWide: bad, pixelsHigh: 1170, scale: 3), .pixelsWide, "\(bad)")
            XCTAssertEqual(PeerDisplayBounds.violation(pixelsWide: 2532, pixelsHigh: bad, scale: 3), .pixelsHigh, "\(bad)")
        }
        for bad in [0, -1, 0.2, 16.01, 1e300, -1e300, .infinity, -.infinity, .nan, .greatestFiniteMagnitude] {
            XCTAssertEqual(PeerDisplayBounds.violation(pixelsWide: 2532, pixelsHigh: 1170, scale: bad), .scale, "\(bad)")
        }
    }

    // MARK: - Sizing: unchanged for every real device

    /// The Extend capture and Window canvas for every real panel, quality,
    /// shape and decode ceiling are exactly what the old formulas gave.
    func testSizingIsUnchangedForEveryRealDevice() {
        var checked = 0
        for (name, wide, high) in Self.bothOrientations {
            let physical = high > 0 ? Double(wide) / Double(high) : .nan
            var aspects = ExtendDisplayShape.allCases.compactMap(\.explicitAspect) + [ExtendDisplayShape.defaultAutomaticAspect]
            if physical.isFinite { aspects.append(physical) }
            for quality in Self.qualityScales {
                for (maxWide, maxHigh) in Self.realCeilings {
                    let canvas = PeerDisplayBounds.windowCanvas(pixelsWide: wide, pixelsHigh: high, scale: quality,
                                                                maxWide: maxWide, maxHigh: maxHigh)
                    let old = Self.oldWindowCanvas(pixelsWide: wide, pixelsHigh: high, scale: quality,
                                                   maxWide: maxWide, maxHigh: maxHigh)
                    XCTAssertTrue(canvas == old, "\(name) window canvas q\(quality): \(canvas) vs \(old)")
                    for aspect in aspects {
                        let points = ExtendDisplaySizing.pointSize(receiverPixelsWide: wide, receiverPixelsHigh: high, aspect: aspect)
                        let new = PeerDisplayBounds.extendCapture(pointsWide: points.wide, pointsHigh: points.high,
                                                                  scale: quality, maxWide: maxWide, maxHigh: maxHigh)
                        let old = Self.oldExtendCapture(pointsWide: points.wide, pointsHigh: points.high, scale: quality,
                                                        maxWide: maxWide, maxHigh: maxHigh)
                        XCTAssertTrue(new.native == old.native && new.capture == old.capture,
                                      "\(name) extend aspect \(aspect) q\(quality): \(new) vs \(old)")
                        let fps = EncoderCapability.codecSafeFPS(width: new.capture.width, height: new.capture.height)
                        XCTAssertEqual(fps, Self.oldCodecSafeFPS(width: old.capture.width, height: old.capture.height))
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 5_000)
    }

    func testDecodeCeilingIsUnchangedForRealSizesAndTotalForAnyCeiling() {
        var random = HostileNumbers(seed: 0xDEC0DE)
        for _ in 0..<50_000 {
            let w = Int(random.next() % 40_000) + 1, h = Int(random.next() % 40_000) + 1
            let mw = Int(random.next() % 9_000) + 1, mh = Int(random.next() % 9_000) + 1
            let new = DecodeCeiling.clamp(width: w, height: h, maxWide: mw, maxHigh: mh)
            XCTAssertTrue(new == Self.oldClamp(width: w, height: h, maxWide: mw, maxHigh: mh), "\(w)x\(h) in \(mw)x\(mh)")
        }
        // A ceiling just under Int.max is 2^63 as a Double: the old math trapped converting it back.
        let edge = DecodeCeiling.clamp(width: Int.max, height: 1, maxWide: Int.max - 1, maxHigh: Int.max)
        XCTAssertEqual(edge.width, (Int.max - 1) & ~1)
        XCTAssertEqual(edge.height, 2)
        for (w, h, mw, mh) in [(Int.max, Int.max, Int.max - 1, Int.max - 1), (Int.max, 2, 1, Int.max), (3, Int.max, Int.max, 1)] {
            let r = DecodeCeiling.clamp(width: w, height: h, maxWide: mw, maxHigh: mh)
            XCTAssertTrue(r.width <= max(mw, 2) && r.height <= max(mh, 2) && r.width >= 2 && r.height >= 2)
        }
    }

    func testMacroblockCountIsUnchangedForRealSizesAndTotalForAnyOther() {
        for w in stride(from: 1, through: 16_400, by: 7) {
            for h in [1, 15, 16, 17, 720, 1080, 1170, 2160, 2304, 4320, 8640, 16_384] {
                XCTAssertEqual(EncoderCapability.macroblockCount(width: w, height: h), Self.oldMacroblockCount(w, h))
            }
        }
        for (w, h) in [(Int.max, Int.max), (Int.max, 1), (1, Int.max), (Int.max - 1, 3), (1 << 40, 1 << 40)] {
            XCTAssertEqual(EncoderCapability.macroblockCount(width: w, height: h) > 0, true)
            XCTAssertEqual(EncoderCapability.codecSafeFPS(width: w, height: h), 1, "too big fails safe to 1 fps")
        }
        XCTAssertEqual(EncoderCapability.macroblockCount(width: Int.max, height: Int.max), Int.max)
        XCTAssertEqual(EncoderCapability.macroblockCount(width: Int.max, height: 16), Int.max / 16 + 1)
        for (w, h) in [(0, 10), (-1, 10), (Int.min, Int.min), (10, Int.min)] {
            XCTAssertEqual(EncoderCapability.macroblockCount(width: w, height: h), 0)
            XCTAssertEqual(EncoderCapability.codecSafeFPS(width: w, height: h), 1)
        }
    }

    // MARK: - Sizing: total for any input (fixed seed)

    func testSizingMathNeverTrapsOnRandomSixtyFourBitValues() {
        var random = HostileNumbers(seed: 0x5EED_4E11_0B0D_5ABE)
        let shapes = ExtendDisplayShape.allCases.compactMap(\.explicitAspect) + [ExtendDisplayShape.defaultAutomaticAspect]
        for _ in 0..<20_000 {
            let a = random.int(), b = random.int()
            let ceiling: (Int?, Int?) = random.bool() ? (nil, nil) : (random.int(), random.int())
            let quality = Self.qualityScales[Int(random.next() % 3)]
            // Whatever the hello said, the sizing functions never trap.
            let points = ExtendDisplaySizing.pointSize(receiverPixelsWide: a, receiverPixelsHigh: b,
                                                       aspect: shapes[Int(random.next() % UInt64(shapes.count))])
            let extend = PeerDisplayBounds.extendCapture(pointsWide: random.bool() ? points.wide : a,
                                                         pointsHigh: random.bool() ? points.high : b,
                                                         scale: quality, maxWide: ceiling.0, maxHigh: ceiling.1)
            XCTAssertEqual(extend.native.width & 1, 0)
            XCTAssertLessThanOrEqual(abs(extend.native.width), 1 << 30)
            XCTAssertLessThanOrEqual(abs(extend.native.height), 1 << 30)
            _ = EncoderCapability.codecSafeFPS(width: extend.capture.width, height: extend.capture.height)
            let canvas = PeerDisplayBounds.windowCanvas(pixelsWide: a, pixelsHigh: b, scale: quality,
                                                        maxWide: ceiling.0, maxHigh: ceiling.1)
            XCTAssertGreaterThanOrEqual(canvas.width, 64)
            XCTAssertGreaterThanOrEqual(canvas.height, 64)
            XCTAssertEqual(canvas.width & 1, 0)
            _ = DecodeCeiling.clamp(width: a, height: b, maxWide: ceiling.0, maxHigh: ceiling.1)
            _ = EncoderCapability.macroblockCount(width: a, height: b)
            _ = EncoderCapability.safeMaxFPSTier(width: a, height: b)
            // Any bit pattern, NaN and the infinities included.
            let even = PeerDisplayBounds.evenPixels(Double(bitPattern: random.next()))
            XCTAssertEqual(even & 1, 0)
            XCTAssertLessThanOrEqual(abs(even), 1 << 30)
        }
    }

    func testEvenPixelsMatchesThePlainConversionForRealSizes() {
        for value in stride(from: -40_000.0, through: 40_000.0, by: 0.75) {
            XCTAssertEqual(PeerDisplayBounds.evenPixels(value), Int(value) & ~1)
        }
        XCTAssertEqual(PeerDisplayBounds.evenPixels(.nan), 0)
        XCTAssertEqual(PeerDisplayBounds.evenPixels(.infinity), 1 << 30)
        XCTAssertEqual(PeerDisplayBounds.evenPixels(-.infinity), -(1 << 30))
        XCTAssertEqual(PeerDisplayBounds.evenPixels(Double(Int.max) * 2), 1 << 30)
    }

    /// The A2 trigger: `pixelsWide` Int.max reaches neither sizing function
    /// (the hello is refused), and if it did, nothing would trap.
    func testTheReportedTriggerNoLongerTraps() {
        XCTAssertEqual(PeerDisplayBounds.violation(pixelsWide: Int.max, pixelsHigh: 1170, scale: 3), .pixelsWide)
        let points = ExtendDisplaySizing.pointSize(receiverPixelsWide: Int.max, receiverPixelsHigh: 1170,
                                                   aspect: ExtendDisplayShape.defaultAutomaticAspect)
        let extend = PeerDisplayBounds.extendCapture(pointsWide: points.wide, pointsHigh: points.high, scale: 1,
                                                     maxWide: nil, maxHigh: nil)
        XCTAssertEqual(extend.native.width, 1 << 30)
        XCTAssertEqual(EncoderCapability.codecSafeFPS(width: extend.capture.width, height: extend.capture.height), 1)
        let canvas = PeerDisplayBounds.windowCanvas(pixelsWide: Int.max, pixelsHigh: Int.min, scale: 1,
                                                    maxWide: nil, maxHigh: nil)
        XCTAssertEqual(canvas.width, 1 << 30)
        XCTAssertEqual(canvas.height, 64)
    }

    // MARK: - FPS hints

    func testReceiverFPSHintsStayInsideTheCapsWhateverTheyAre() {
        let values: [Int?] = [Int.max, Int.min, -1, 0, 1, 59, 60, 61, 120, 121, 240, 1 << 40, nil]
        for profile in StreamingProfile.allCases {
            for receiver in values {
                for user in values {
                    let common = StreamingFPSPolicy.commonTargetFPS(profile: profile, requestedFPS: nil,
                                                                    receiverMaxFPS: receiver, userMaxFPS: user)
                    XCTAssertTrue((1...StreamingFPSPolicy.hardCapFPS).contains(common.fps), "\(receiver as Any) \(user as Any)")
                    for safe in [Int.min, 0, 1, 63, 118, Int.max] {
                        let fps = StreamingFPSPolicy.effectiveFPS(profile: profile, requestedFPS: nil, receiverMaxFPS: receiver,
                                                                  userMaxFPS: user, encoderSafeFPS: safe).fps
                        XCTAssertTrue((1...StreamingFPSPolicy.hardCapFPS).contains(fps))
                        _ = StreamingFPSPolicy.availableUserCeilingTiers(receiverMaxFPS: receiver, encoderSafeFPS: safe)
                    }
                }
            }
        }
    }

    // MARK: - Scroll deltas and Pencil pressure

    func testScrollDeltasOfAnySizeNeverTrap() {
        for huge in [1e300, -1e300, Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
                     Double(Int.max), Double(Int32.max) + 10, .infinity, -.infinity, .nan] {
            var remainder = ScrollRemainder()
            let whole = remainder.take(dxPoints: huge, dyPoints: -huge)
            if huge.isNaN {
                XCTAssertEqual(whole.dx, 0)
            } else {
                XCTAssertEqual(whole.dx, huge > 0 ? Int32.max : Int32.min)
                XCTAssertEqual(whole.dy, huge > 0 ? Int32.min : Int32.max)
            }
            XCTAssertTrue(remainder.x.isFinite && remainder.y.isFinite, "the carried remainder stays finite")
            // The next ordinary delta is unaffected.
            XCTAssertEqual(remainder.take(dxPoints: 3, dyPoints: -2).dx, 3)
        }
    }

    func testOrdinaryScrollDeltasComeOutExactlyAsBefore() {
        var random = HostileNumbers(seed: 0x5C2011)
        var new = ScrollRemainder(), old = OldScrollRemainder()
        for _ in 0..<20_000 {
            let dx = (Double(random.next() % 200_001) - 100_000) / 37, dy = (Double(random.next() % 2_001) - 1_000) / 3
            let a = new.take(dxPoints: dx, dyPoints: dy), b = old.take(dxPoints: dx, dyPoints: dy)
            XCTAssertEqual(a.dx, b.dx)
            XCTAssertEqual(a.dy, b.dy)
        }
    }

    func testPencilPressureIsClampedToTheTabletFieldAndUnchangedInRange() {
        for step in 0...1_000 {
            let pressure = Double(step) / 1_000
            XCTAssertEqual(TabletPressure.pointPressure(pressure), Int64((pressure * 65535.0).rounded()))
        }
        XCTAssertEqual(TabletPressure.pointPressure(1e300), 65_535)
        XCTAssertEqual(TabletPressure.pointPressure(1.2), 65_535)
        XCTAssertEqual(TabletPressure.pointPressure(-1e300), 0)
        XCTAssertEqual(TabletPressure.pointPressure(.greatestFiniteMagnitude), 65_535)
        XCTAssertEqual(TabletPressure.pointPressure(.nan), 0)
        XCTAssertEqual(TabletPressure.pointPressure(.infinity), 65_535)
    }

    // MARK: - Unified Clipboard counters

    func testClipboardEventCountersAboveTheBoundAreDropped() {
        func event(s: Int = 1, lc: Int = 1, vv: [String: Int] = [:]) -> [String: Any] {
            ["type": "clip", "op": "event", "o": "phone", "s": s, "lc": lc, "vv": vv, "ch": "c",
             "items": [["reps": [["t": "text", "n": 1, "h": "0123456789abcdef", "d": "YQ=="]]]]]
        }
        XCTAssertNotNil(ClipEvent.parse(event()))
        XCTAssertNotNil(ClipEvent.parse(event(s: ClipboardWire.maxCounter, lc: ClipboardWire.maxCounter,
                                              vv: ["mac": ClipboardWire.maxCounter])))
        for bad in [ClipboardWire.maxCounter + 1, Int.max] {
            XCTAssertNil(ClipEvent.parse(event(lc: bad)), "lc \(bad)")
            XCTAssertNil(ClipEvent.parse(event(s: bad)), "s \(bad)")
            XCTAssertNil(ClipEvent.parse(event(vv: ["mac": bad])), "vv \(bad)")
        }
    }

    /// A device's `lc` at the bound is adopted; the Mac's next copies still
    /// convert to `Int` (they used to trap at `Int.max`). A counter stored
    /// before the bound existed is brought back under it.
    func testTheMacsOwnCopiesNeverOverflowAfterAHugeCounter() throws {
        var sync = ClipboardSync(origin: "mac")
        let header = try XCTUnwrap(ClipEvent.parse([
            "o": "phone", "s": 1, "lc": ClipboardWire.maxCounter, "ch": "c",
            "items": [["reps": [["t": "text", "n": 1, "h": "0123456789abcdef", "d": "YQ=="]]]],
        ])).header
        XCTAssertEqual(sync.receive(header), .apply)
        for n in 0..<3 {
            let copy = try XCTUnwrap(sync.localCopy(contentHash: "mine-\(n)"))
            XCTAssertEqual(Int(copy.lamport), ClipboardWire.maxCounter + n + 1)
        }
        var stored = ClipboardSync(origin: "mac", seq: 4, lamport: UInt64(Int.max))
        XCTAssertEqual(stored.lamport, UInt64(ClipboardWire.maxCounter))
        let copy = try XCTUnwrap(stored.localCopy(contentHash: "after-restore"))
        XCTAssertEqual(Int(copy.lamport), ClipboardWire.maxCounter + 1)
        XCTAssertEqual(ClipboardSync(origin: "mac", seq: 4, lamport: 40).lamport, 40, "real counters are unchanged")
    }

    // MARK: - Old formulas (before this change), the reference for real devices

    private static func oldExtendCapture(pointsWide: Int, pointsHigh: Int, scale: Double, maxWide: Int?, maxHigh: Int?)
        -> (native: (width: Int, height: Int), capture: (width: Int, height: Int)) {
        let nativeW = (Int(Double(pointsWide * 2) * scale)) & ~1
        let nativeH = (Int(Double(pointsHigh * 2) * scale)) & ~1
        return ((nativeW, nativeH), oldClamp(width: nativeW, height: nativeH, maxWide: maxWide, maxHigh: maxHigh))
    }

    private static func oldWindowCanvas(pixelsWide: Int, pixelsHigh: Int, scale: Double, maxWide: Int?, maxHigh: Int?)
        -> (width: Int, height: Int) {
        let wide = Int(Double(pixelsWide) * scale) & ~1
        let high = Int(Double(pixelsHigh) * scale) & ~1
        let (w, h) = oldClamp(width: wide, height: high, maxWide: maxWide, maxHigh: maxHigh)
        return (max(w & ~1, 64), max(h & ~1, 64))
    }

    private static func oldClamp(width: Int, height: Int, maxWide: Int?, maxHigh: Int?) -> (width: Int, height: Int) {
        guard let maxWide, let maxHigh, maxWide > 0, maxHigh > 0, width > 0, height > 0,
              width > maxWide || height > maxHigh else { return (width, height) }
        let scale = min(Double(maxWide) / Double(width), Double(maxHigh) / Double(height))
        return (max((Int(Double(width) * scale)) & ~1, 2), max((Int(Double(height) * scale)) & ~1, 2))
    }

    private static func oldMacroblockCount(_ width: Int, _ height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        return ((width + 15) / 16) * ((height + 15) / 16)
    }

    private static func oldCodecSafeFPS(width: Int, height: Int) -> Int {
        let mbCount = oldMacroblockCount(width, height)
        guard mbCount > 0 else { return 1 }
        let nominal = EncoderCapability.maxMacroblocksPerSecond / mbCount
        return nominal > 1 ? nominal - 1 : 1
    }

    private struct OldScrollRemainder {
        var x = 0.0, y = 0.0
        mutating func take(dxPoints: Double, dyPoints: Double) -> (dx: Int32, dy: Int32) {
            let totalX = x + dxPoints, totalY = y + dyPoints
            let wholeX = totalX.rounded(), wholeY = totalY.rounded()
            x = totalX - wholeX
            y = totalY - wholeY
            return (Int32(clamping: Int(wholeX)), Int32(clamping: Int(wholeY)))
        }
    }
}

/// SplitMix64 with a fixed seed: the same "random" values on every run.
struct HostileNumbers {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Any 64-bit value, with the edges (0, ±1, Int.max, Int.min) far more often than chance.
    mutating func int() -> Int {
        let edges = [0, 1, -1, Int.max, Int.min, Int.max - 1, 32_768, 32_769, 1 << 32, -(1 << 32)]
        if next() % 8 == 0 { return edges[Int(next() % UInt64(edges.count))] }
        return Int(truncatingIfNeeded: next())
    }
    mutating func bool() -> Bool { next() & 1 == 1 }
}
