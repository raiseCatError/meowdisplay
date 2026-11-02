import XCTest

final class EncoderCapabilityTests: XCTestCase {

    // MARK: - Regression matrix (the real-hardware Extend black-screen bug)
    //
    // `codecSafeFPS` is the INTERNAL, arbitrary-integer ceiling — never
    // quantized to a picker tier. 2796x1572/2796x1748 must land near their
    // real theoretical throughput (118/106), NOT be floored to the next
    // lower tier (60).

    func test2796x1196AllowsAtLeast120() {
        XCTAssertGreaterThanOrEqual(EncoderCapability.codecSafeFPS(width: 2796, height: 1196), 120)
    }

    func test2796x1572IsApproximately118NotFlooredTo60() {
        let value = EncoderCapability.codecSafeFPS(width: 2796, height: 1572)
        XCTAssertEqual(value, 118)
        XCTAssertNotEqual(value, 60)
    }

    func test2796x1748IsApproximately106NotFlooredTo60() {
        let value = EncoderCapability.codecSafeFPS(width: 2796, height: 1748)
        XCTAssertEqual(value, 106)
        XCTAssertNotEqual(value, 60)
    }

    // MARK: - Macroblock math

    func testMacroblockCountRoundsUpToWholeMacroblocks() {
        // 2796 -> ceil(2796/16) = 175, 1196 -> ceil(1196/16) = 75.
        XCTAssertEqual(EncoderCapability.macroblockCount(width: 2796, height: 1196), 175 * 75)
    }

    func testMacroblockCountForDegenerateSizeIsZero() {
        XCTAssertEqual(EncoderCapability.macroblockCount(width: 0, height: 1000), 0)
        XCTAssertEqual(EncoderCapability.macroblockCount(width: 1000, height: -1), 0)
    }

    // MARK: - Nominal-minus-one-frame-of-headroom math

    func testCodecSafeFPSIsNominalMinusOneFrame() {
        // 175 * 99 = 17325 macroblocks. nominal = 2,073,600 / 17325 = 119
        // (integer floor). One frame of headroom below that is 118.
        let mb = EncoderCapability.macroblockCount(width: 2796, height: 1572)
        let nominal = EncoderCapability.maxMacroblocksPerSecond / mb
        XCTAssertEqual(nominal, 119)
        XCTAssertEqual(EncoderCapability.codecSafeFPS(width: 2796, height: 1572), nominal - 1)
    }

    func testCodecSafeFPSNeverExceedsTheNominalBoundary() {
        for size in [(640, 480), (1920, 1080), (2796, 1196), (2796, 1572), (2796, 1748), (3840, 2160)] {
            let fps = EncoderCapability.codecSafeFPS(width: size.0, height: size.1)
            let mbps = EncoderCapability.macroblockCount(width: size.0, height: size.1) * fps
            XCTAssertLessThanOrEqual(mbps, EncoderCapability.maxMacroblocksPerSecond,
                                     "\(size.0)x\(size.1)@\(fps) exceeds the macroblock-rate ceiling")
        }
    }

    // MARK: - Small resolutions retain (comfortably exceed) 120

    func testSmallResolutionsComfortablyExceed120() {
        for (width, height) in [(1280, 720), (1920, 1080), (1512, 982)] {
            XCTAssertGreaterThan(EncoderCapability.codecSafeFPS(width: width, height: height), 120,
                                 "\(width)x\(height) should comfortably clear 120")
        }
    }

    // MARK: - Aspect ratio alone never decides the answer

    func testAspectRatioAloneDoesNotDetermineSafety() {
        // Two 16:9 sizes: a small one safely clears 120, a big one doesn't
        // — proves the model depends on actual pixels, not the ratio label.
        let small = EncoderCapability.codecSafeFPS(width: 1920, height: 1080)
        let big = EncoderCapability.codecSafeFPS(width: 2796, height: 1572)
        XCTAssertGreaterThan(small, 120)
        XCTAssertLessThan(big, 120)
    }

    // MARK: - Invalid/zero dimensions fail safe

    func testInvalidDimensionsFailSafe() {
        XCTAssertEqual(EncoderCapability.codecSafeFPS(width: 0, height: 0), 1)
        XCTAssertEqual(EncoderCapability.codecSafeFPS(width: -1, height: 1000), 1)
        XCTAssertEqual(EncoderCapability.codecSafeFPS(width: 1000, height: -1), 1)
    }

    // MARK: - 4:3 / 1:1 sanity (DoD regression list)

    func test4x3And1x1ProduceARealPositiveFPS() {
        for (width, height) in [(2796, 2097), (1748, 1748)] {
            let value = EncoderCapability.codecSafeFPS(width: width, height: height)
            XCTAssertGreaterThan(value, 0)
        }
    }

    // MARK: - User-facing picker tier (PART 1: separate from the internal ceiling)

    func testSafeMaxFPSTierHides120WhenInternalCeilingIsBelowIt() {
        // Internal ceiling ~118 — the picker's highest EXPLICIT tier must
        // stay at 60, never 120, but the internal stream still runs at 118.
        XCTAssertEqual(EncoderCapability.safeMaxFPSTier(width: 2796, height: 1572), 60)
    }

    func testSafeMaxFPSTierAllows120WhenInternalCeilingClearsIt() {
        XCTAssertEqual(EncoderCapability.safeMaxFPSTier(width: 2796, height: 1196), 120)
    }

    func testSafeMaxFPSTierNeverExceedsTheInternalCeiling() {
        for size in [(640, 480), (1920, 1080), (2796, 1196), (2796, 1572), (2796, 1748)] {
            let tier = EncoderCapability.safeMaxFPSTier(width: size.0, height: size.1)
            let internalCeiling = EncoderCapability.codecSafeFPS(width: size.0, height: size.1)
            XCTAssertLessThanOrEqual(tier, internalCeiling)
            XCTAssertTrue(EncoderCapability.supportedFPSTiers.contains(tier))
        }
    }

    func testSafeMaxFPSTierFailsSafeOnInvalidDimensions() {
        XCTAssertEqual(EncoderCapability.safeMaxFPSTier(width: 0, height: 0), EncoderCapability.supportedFPSTiers.first)
    }
}
