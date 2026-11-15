import CoreGraphics
import XCTest

/// Golden values below are `ceil(points / 4.5)` per axis, scaled up uniformly
/// when the 180 mm minimum width or the 20 000 mm² minimum area binds (and
/// scaled down uniformly first when the long edge exceeds 1200 mm).
final class ExtendPhysicalSizeTests: XCTestCase {

    private func size(_ wide: Int, _ high: Int) -> CGSize {
        ExtendPhysicalSize.millimetres(pointsWide: wide, pointsHigh: high)
    }

    private func assertSize(_ wide: Int, _ high: Int, _ expectedWidth: CGFloat, _ expectedHeight: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        let result = size(wide, high)
        XCTAssertEqual(result.width, expectedWidth, "width for \(wide)x\(high)pt", file: file, line: line)
        XCTAssertEqual(result.height, expectedHeight, "height for \(wide)x\(high)pt", file: file, line: line)
    }

    private func assertMeetsMinimums(_ result: CGSize, _ label: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.width.isFinite && result.height.isFinite, "finite for \(label)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(result.width, ExtendPhysicalSize.minimumWidth, "width for \(label)",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(result.width * result.height, ExtendPhysicalSize.minimumArea,
                                    "area for \(label)", file: file, line: line)
    }

    /// The Extend pipeline for a receiver hello and shape, as `MacSender.setupExtend` composes it.
    private func declared(helloWide: Int, helloHigh: Int, shape: ExtendDisplayShape,
                          useFullDisplay: Bool = false) -> (points: (Int, Int), mm: CGSize) {
        let preference = ExtendDisplayShapePreference(shape: shape, useFullDisplay: useFullDisplay)
        let aspect = preference.resolvedAspect(receiverPhysicalAspect: Double(helloWide) / Double(helloHigh))
        let points = ExtendDisplaySizing.pointSize(
            receiverPixelsWide: helloWide, receiverPixelsHigh: helloHigh, aspect: aspect)
        return ((points.wide, points.high), size(points.wide, points.high))
    }

    // MARK: - Policy constants

    func testPolicyConstants() {
        XCTAssertEqual(ExtendPhysicalSize.pointsPerMillimetre, 4.5)
        XCTAssertEqual(ExtendPhysicalSize.upperLongEdge, 1200)
        XCTAssertEqual(ExtendPhysicalSize.minimumWidth, 180)
        XCTAssertEqual(ExtendPhysicalSize.minimumArea, 20_000)
    }

    // MARK: - (a) iPhone 14 Pro Max, Full Display

    func testIPhone14ProMaxLandscapeIsRoundedUpIsotropicSize() {
        // 1398/4.5 = 310.67, 644/4.5 = 143.11
        assertSize(1398, 644, 311, 144)
    }

    func testIPhone14ProMaxPortraitKeepsTheHorizontalMinimumAndIsotropy() {
        // Width 143.11 mm is below 180, so everything scales by 180/143.11
        // and the height becomes 1398/644 * 180 = 390.7 -> 391.
        assertSize(644, 1398, 180, 391)
    }

    // MARK: - (b) iPhone 15 Pro

    func testIPhone15ProPortraitIsNotTheOldNarrowSize() {
        let portrait = size(588, 1278)
        // The regression: this used to be declared as a ~131 mm wide display.
        XCTAssertGreaterThanOrEqual(portrait.width, ExtendPhysicalSize.minimumWidth)
        // 1278/588 * 180 = 391.2 -> 392
        assertSize(588, 1278, 180, 392)
    }

    func testIPhone15ProLandscape() {
        // 1278/4.5 = 284, 588/4.5 = 130.67
        assertSize(1278, 588, 284, 131)
    }

    // MARK: - (c) iPhone SE

    func testIPhoneSEPortrait() {
        // 666/374 * 180 = 320.5 -> 321
        assertSize(374, 666, 180, 321)
    }

    func testIPhoneSELandscapeIsBoundByArea() {
        // 148 x 83.11 mm is only 12 300 mm²; the area minimum scales it by
        // sqrt(20000 / 12300.4) = 1.2751 -> 188.7 x 105.98.
        let result = size(666, 374)
        assertSize(666, 374, 189, 106)
        XCTAssertGreaterThanOrEqual(result.width * result.height, ExtendPhysicalSize.minimumArea)
    }

    // MARK: - (d) iPad

    func testIPadMini() {
        assertSize(1132, 744, 252, 166)   // 251.56 x 165.33
        assertSize(744, 1132, 180, 274)   // width-bound: 1132/744 * 180 = 273.9
    }

    func testIPadPro13() {
        assertSize(1376, 1032, 306, 230)  // 305.78 x 229.33
        assertSize(1032, 1376, 230, 306)  // 229.33 x 305.78, width already above 180
    }

    // MARK: - (e) custom shapes through the real sizing pipeline

    func testSmallIPhoneHelloAcrossCustomShapes() {
        let hello = (wide: 2340, high: 1080)

        let sixteenTen = declared(helloWide: hello.wide, helloHigh: hello.high, shape: .r16x10)
        XCTAssertTrue(sixteenTen.points == (1170, 730))
        XCTAssertEqual(sixteenTen.mm, CGSize(width: 260, height: 163))

        let square = declared(helloWide: hello.wide, helloHigh: hello.high, shape: .r1x1)
        XCTAssertTrue(square.points == (1170, 1170))
        XCTAssertEqual(square.mm, CGSize(width: 260, height: 260))

        let ultrawide = declared(helloWide: hello.wide, helloHigh: hello.high, shape: .r21x9)
        XCTAssertTrue(ultrawide.points == (1170, 500))
        XCTAssertEqual(ultrawide.mm, CGSize(width: 260, height: 112))

        // 260 x 72.89 mm is 18 951 mm², under the area minimum: the one
        // area-bound row. Scaled by 1.0273 -> 267.1 x 74.88.
        let superUltrawide = declared(helloWide: hello.wide, helloHigh: hello.high, shape: .r32x9)
        XCTAssertTrue(superUltrawide.points == (1170, 328))
        XCTAssertEqual(superUltrawide.mm, CGSize(width: 268, height: 75))
        assertMeetsMinimums(superUltrawide.mm, "32:9 on a small iPhone")
    }

    func testSixKMacReceiverHelloAcrossCustomShapes() {
        let hello = (wide: 6016, high: 3384)

        let sixteenTen = declared(helloWide: hello.wide, helloHigh: hello.high, shape: .r16x10)
        XCTAssertTrue(sixteenTen.points == (3008, 1880))
        XCTAssertEqual(sixteenTen.mm, CGSize(width: 669, height: 418))

        let square = declared(helloWide: hello.wide, helloHigh: hello.high, shape: .r1x1)
        XCTAssertTrue(square.points == (3008, 3008))
        XCTAssertEqual(square.mm, CGSize(width: 669, height: 669))

        let ultrawide = declared(helloWide: hello.wide, helloHigh: hello.high, shape: .r21x9)
        XCTAssertTrue(ultrawide.points == (3008, 1288))
        XCTAssertEqual(ultrawide.mm, CGSize(width: 669, height: 287))

        let superUltrawide = declared(helloWide: hello.wide, helloHigh: hello.high, shape: .r32x9)
        XCTAssertTrue(superUltrawide.points == (3008, 846))
        XCTAssertEqual(superUltrawide.mm, CGSize(width: 669, height: 188))
    }

    // MARK: - (f) Mac receivers and bounds

    func testMacReceiversAtFullDisplay() {
        let fiveK = declared(helloWide: 2560, helloHigh: 1440, shape: .automatic, useFullDisplay: true)
        XCTAssertTrue(fiveK.points == (1280, 720))
        XCTAssertEqual(fiveK.mm, CGSize(width: 285, height: 160))

        let sixK = declared(helloWide: 3008, helloHigh: 1692, shape: .automatic, useFullDisplay: true)
        XCTAssertTrue(sixK.points == (1504, 846))
        XCTAssertEqual(sixK.mm, CGSize(width: 335, height: 188))

        // 8K stays below the 1200 mm cap.
        let eightK = declared(helloWide: 3840, helloHigh: 2160, shape: .automatic, useFullDisplay: true)
        XCTAssertTrue(eightK.points == (1920, 1080))
        XCTAssertEqual(eightK.mm, CGSize(width: 427, height: 240))
    }

    func testOversizedDisplayIsCappedToTheUpperLongEdge() {
        // 6000/4.5 = 1333 mm is over the cap; both axes scale by 0.9.
        assertSize(6000, 3000, 1200, 600)
    }

    func testMinimumWidthWinsOverTheCapForAnExtremePortraitShape() {
        // 200 x 4000 pt is 44 x 889 mm. The width minimum scales it up by
        // 4.05, so the long edge (3600 mm) ends up over the 1200 mm cap:
        // minimums are applied last and always win.
        assertSize(200, 4000, 180, 3600)
    }

    // MARK: - (g) fallback and tiny inputs

    func testNonPositiveInputUsesTheFallbackPointSize() {
        let fallback = size(960, 600)
        XCTAssertEqual(fallback, CGSize(width: 214, height: 134))
        XCTAssertEqual(size(0, 0), fallback)
        XCTAssertEqual(size(-5, 10), fallback)
        XCTAssertEqual(size(10, -5), fallback)
        XCTAssertEqual(size(Int.min, Int.min), fallback)
    }

    func testTinyInputsAreFiniteAndMeetTheMinimums() {
        for edge in [1, 2] {
            let result = size(edge, edge)
            assertMeetsMinimums(result, "\(edge)x\(edge)")
            XCTAssertEqual(result.width, result.height, "square stays square for \(edge)x\(edge)")
        }
    }

    func testExtremeInputsStayFinitePositiveAndMeetTheMinimums() {
        let extremes: [(Int, Int)] = [
            (Int.max, Int.max), (Int.max, 1), (1, Int.max), (Int.max / 2, 2), (2, Int.max / 2),
            (Int.max, 960), (960, Int.max),
        ]
        for (wide, high) in extremes {
            let result = size(wide, high)
            assertMeetsMinimums(result, "\(wide)x\(high)")
            XCTAssertGreaterThan(result.height, 0, "height for \(wide)x\(high)")
        }
        XCTAssertEqual(size(Int.max, Int.max), CGSize(width: 1200, height: 1200))
    }

    // MARK: - (h) invariants over a sweep

    func testInvariantsHoldAcrossASweepOfPointSizes() {
        for wide in stride(from: 2, through: 4000, by: 97) {
            for high in stride(from: 2, through: 4000, by: 89) {
                let result = size(wide, high)
                let label = "\(wide)x\(high)"
                assertMeetsMinimums(result, label)
                XCTAssertEqual(result.width, result.width.rounded(), "whole mm width for \(label)")
                XCTAssertEqual(result.height, result.height.rounded(), "whole mm height for \(label)")

                // Every step (cap, minimums) scales both axes by the same
                // factor, so the millimetre aspect equals the point aspect
                // whether or not the cap and a minimum conflict. The only
                // deviation is rounding up to whole millimetres, which moves
                // an axis by under 1 mm — large relative to a short axis
                // that is only a few millimetres.
                let pointAspect = Double(wide) / Double(high)
                let millimetreAspect = Double(result.width) / Double(result.height)
                let shortEdge = Double(min(result.width, result.height))
                let tolerance = max(0.01, 2.0 / shortEdge)
                XCTAssertEqual(millimetreAspect / pointAspect, 1, accuracy: tolerance, "aspect for \(label)")
            }
        }
    }

    // MARK: - (i) density

    func testUnboundedRowsDeclareTheStandardDensity() {
        let rows: [(Int, Int)] = [
            (1398, 644), (1278, 588), (1132, 744), (1376, 1032), (1170, 730), (3008, 1880), (1920, 1080),
        ]
        for (wide, high) in rows {
            let result = size(wide, high)
            // Rounded up to whole millimetres: within 1 mm of the exact value.
            let exactWidth = Double(wide) / Double(ExtendPhysicalSize.pointsPerMillimetre)
            let exactHeight = Double(high) / Double(ExtendPhysicalSize.pointsPerMillimetre)
            XCTAssertEqual(Double(result.width), exactWidth, accuracy: 1, "width for \(wide)x\(high)")
            XCTAssertEqual(Double(result.height), exactHeight, accuracy: 1, "height for \(wide)x\(high)")
            XCTAssertEqual(Double(wide) / Double(result.width), 4.5, accuracy: 0.05, "density for \(wide)x\(high)")
        }
    }

    // MARK: - (j) call-site guard

    func testSenderUsesThePolicyInsteadOfAHardcodedSize() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sender = try String(contentsOf: root.appendingPathComponent("Mac/MacSender.swift"), encoding: .utf8)
        XCTAssertTrue(sender.contains("ExtendPhysicalSize.millimetres("))
        XCTAssertFalse(sender.contains("width: 147, height: 68"))
        XCTAssertFalse(sender.contains("width: 68, height: 147"))
    }
}
