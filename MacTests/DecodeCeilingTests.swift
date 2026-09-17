import XCTest

final class DecodeCeilingTests: XCTestCase {

    func testNoCapabilityLeavesSizeUnchanged() {
        let result = DecodeCeiling.clamp(width: 5120, height: 2880, maxWide: nil, maxHigh: nil)
        XCTAssertEqual(result.width, 5120)
        XCTAssertEqual(result.height, 2880)
    }

    func testStreamAlreadyBelowCeilingIsUnchanged() {
        let result = DecodeCeiling.clamp(width: 1920, height: 1200, maxWide: 4096, maxHigh: 2304)
        XCTAssertEqual(result.width, 1920)
        XCTAssertEqual(result.height, 1200)
    }

    func testStreamAboveCeilingIsProportionallyDownscaled() {
        let result = DecodeCeiling.clamp(width: 5120, height: 3200, maxWide: 4096, maxHigh: 2304)
        XCTAssertLessThanOrEqual(result.width, 4096)
        XCTAssertLessThanOrEqual(result.height, 2304)
        let originalAspect = 5120.0 / 3200.0
        let resultAspect = Double(result.width) / Double(result.height)
        XCTAssertEqual(originalAspect, resultAspect, accuracy: 0.01)
    }

    func testNeverUpscales() {
        let result = DecodeCeiling.clamp(width: 800, height: 500, maxWide: 4096, maxHigh: 2304)
        XCTAssertEqual(result.width, 800)
        XCTAssertEqual(result.height, 500)
    }

    func testResultDimensionsAreEven() {
        let result = DecodeCeiling.clamp(width: 5121, height: 3201, maxWide: 4095, maxHigh: 2303)
        XCTAssertEqual(result.width % 2, 0)
        XCTAssertEqual(result.height % 2, 0)
    }

    func testDegenerateCeilingIsIgnored() {
        let result = DecodeCeiling.clamp(width: 5120, height: 2880, maxWide: 0, maxHigh: 0)
        XCTAssertEqual(result.width, 5120)
        XCTAssertEqual(result.height, 2880)
    }

    func testOnlyOneAxisOverCeilingStillClampsBoth() {
        // Width fits, height doesn't — the scale factor must still apply to
        // both axes together (aspect-preserving), not clamp height alone.
        let result = DecodeCeiling.clamp(width: 2000, height: 3000, maxWide: 4096, maxHigh: 2000)
        XCTAssertLessThanOrEqual(result.height, 2000)
        XCTAssertLessThan(result.width, 2000)
    }
}
