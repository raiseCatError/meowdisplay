import CoreGraphics
import XCTest

final class OffscreenCursorLocatorTests: XCTestCase {
    /// 400x300 content, centre (300, 250), half-diagonal 250.
    private let content = CGRect(x: 100, y: 100, width: 400, height: 300)
    /// Circumscribed radius 25.
    private let indicator = CGSize(width: 40, height: 30)
    private let indicatorRadius: CGFloat = 25

    private func place(
        _ cursor: CGPoint, in rect: CGRect? = nil, size: CGSize? = nil
    ) -> OffscreenCursorLocator.Placement? {
        OffscreenCursorLocator.placement(
            cursor: cursor, content: rect ?? content, indicatorSize: size ?? indicator
        )
    }

    /// Whole circle (at the placement's scale) lies within the rect.
    private func assertFullyInside(
        _ placement: OffscreenCursorLocator.Placement, _ rect: CGRect,
        size: CGSize? = nil, file: StaticString = #filePath, line: UInt = #line
    ) {
        let size = size ?? indicator
        let radius = hypot(size.width, size.height) / 2 * placement.scale
        let eps: CGFloat = 1e-6
        XCTAssertGreaterThanOrEqual(placement.center.x - radius, rect.minX - eps, file: file, line: line)
        XCTAssertLessThanOrEqual(placement.center.x + radius, rect.maxX + eps, file: file, line: line)
        XCTAssertGreaterThanOrEqual(placement.center.y - radius, rect.minY - eps, file: file, line: line)
        XCTAssertLessThanOrEqual(placement.center.y + radius, rect.maxY + eps, file: file, line: line)
    }

    // MARK: Inside

    func testCursorInsideContentReturnsNil() {
        XCTAssertNil(place(CGPoint(x: 300, y: 250)))
        XCTAssertNil(place(CGPoint(x: 101, y: 399)))
    }

    func testCursorOnEdgesAndCornersCountsAsInside() {
        for point in [
            CGPoint(x: 100, y: 250), CGPoint(x: 500, y: 250),
            CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 400),
            CGPoint(x: 100, y: 100), CGPoint(x: 500, y: 400),
        ] {
            XCTAssertNil(place(point), "\(point)")
        }
    }

    func testJustPastTheEdgeReturnsPlacementWithMinimumScale() throws {
        let placement = try XCTUnwrap(place(CGPoint(x: 500.001, y: 250)))
        XCTAssertEqual(placement.edge, .right)
        XCTAssertEqual(placement.scale, 0.85, accuracy: 1e-3)
        XCTAssertEqual(placement.distance, 0.001, accuracy: 1e-9)
    }

    // MARK: Sides

    func testCursorToTheRight() throws {
        let placement = try XCTUnwrap(place(CGPoint(x: 700, y: 250)))
        XCTAssertEqual(placement.edge, .right)
        XCTAssertEqual(placement.distance, 200, accuracy: 1e-9)
        XCTAssertEqual(placement.center.x, 500 - indicatorRadius * placement.scale, accuracy: 1e-9)
        XCTAssertEqual(placement.center.y, 250, accuracy: 1e-9)
        XCTAssertEqual(placement.angle, 0, accuracy: 1e-9)
        assertFullyInside(placement, content)
    }

    func testCursorToTheLeft() throws {
        let placement = try XCTUnwrap(place(CGPoint(x: -100, y: 250)))
        XCTAssertEqual(placement.edge, .left)
        XCTAssertEqual(placement.distance, 200, accuracy: 1e-9)
        XCTAssertEqual(placement.center.x, 100 + indicatorRadius * placement.scale, accuracy: 1e-9)
        XCTAssertEqual(placement.center.y, 250, accuracy: 1e-9)
        XCTAssertEqual(abs(placement.angle), .pi, accuracy: 1e-9)
        assertFullyInside(placement, content)
    }

    func testCursorAbove() throws {
        let placement = try XCTUnwrap(place(CGPoint(x: 300, y: -100)))
        XCTAssertEqual(placement.edge, .top)
        XCTAssertEqual(placement.distance, 200, accuracy: 1e-9)
        XCTAssertEqual(placement.center.x, 300, accuracy: 1e-9)
        XCTAssertEqual(placement.center.y, 100 + indicatorRadius * placement.scale, accuracy: 1e-9)
        XCTAssertEqual(placement.angle, -.pi / 2, accuracy: 1e-9, "y grows downward: up is negative")
        assertFullyInside(placement, content)
    }

    func testCursorBelow() throws {
        let placement = try XCTUnwrap(place(CGPoint(x: 300, y: 600)))
        XCTAssertEqual(placement.edge, .bottom)
        XCTAssertEqual(placement.distance, 200, accuracy: 1e-9)
        XCTAssertEqual(placement.center.x, 300, accuracy: 1e-9)
        XCTAssertEqual(placement.center.y, 400 - indicatorRadius * placement.scale, accuracy: 1e-9)
        XCTAssertEqual(placement.angle, .pi / 2, accuracy: 1e-9)
        assertFullyInside(placement, content)
    }

    func testOffCentreCursorFollowsTheRayNotTheEdgeMidpoint() throws {
        // Right of the content, in its upper half: the marker is on the right edge but above
        // the middle, in line with the cursor as seen from the centre.
        let placement = try XCTUnwrap(place(CGPoint(x: 900, y: 150)))
        XCTAssertEqual(placement.edge, .right)
        XCTAssertLessThan(placement.center.y, 250)
        // Ray from (300, 250) to (900, 150) meets x = 500 at y = 250 - 100 * 200 / 600.
        XCTAssertEqual(placement.center.y, 250 - 100.0 * 200 / 600, accuracy: 1e-9)
    }

    // MARK: Corners

    func testEachCornerLandsAtTheInnerCorner() throws {
        // Directions along the content's own diagonal cross exactly at its corners.
        let cases: [(CGPoint, OffscreenCursorLocator.Edge, CGFloat, CGFloat)] = [
            (CGPoint(x: 300 + 1000, y: 250 + 750), [.right, .bottom], 1, 1),
            (CGPoint(x: 300 - 1000, y: 250 + 750), [.left, .bottom], -1, 1),
            (CGPoint(x: 300 + 1000, y: 250 - 750), [.right, .top], 1, -1),
            (CGPoint(x: 300 - 1000, y: 250 - 750), [.left, .top], -1, -1),
        ]
        for (cursor, edge, signX, signY) in cases {
            let placement = try XCTUnwrap(place(cursor), "\(cursor)")
            XCTAssertEqual(placement.edge, edge)
            let radius = indicatorRadius * placement.scale
            XCTAssertEqual(placement.center.x, 300 + signX * (200 - radius), accuracy: 1e-9)
            XCTAssertEqual(placement.center.y, 250 + signY * (150 - radius), accuracy: 1e-9)
            assertFullyInside(placement, content)
        }
    }

    func testDiagonalCursorPointsAtItFromTheCorner() throws {
        let cursor = CGPoint(x: 1300, y: 1000)
        let placement = try XCTUnwrap(place(cursor))
        let expected = atan2(cursor.y - placement.center.y, cursor.x - placement.center.x)
        XCTAssertEqual(placement.angle, expected, accuracy: 1e-12)
        XCTAssertGreaterThan(placement.angle, 0)
        XCTAssertLessThan(placement.angle, .pi / 2)
    }

    func testSteepDiagonalStaysOnTheBottomEdgeNearTheMiddle() throws {
        let cursor = CGPoint(x: 320, y: 5000)
        let placement = try XCTUnwrap(place(cursor))
        XCTAssertEqual(placement.edge, .bottom)
        // Ray from (300, 250) to (320, 5000) meets y = 400 at x = 300 + 20 * 150 / 4750.
        XCTAssertEqual(placement.center.x, 300 + 20.0 * 150 / 4750, accuracy: 1e-9)
        XCTAssertEqual(placement.center.y, 400 - indicatorRadius * placement.scale, accuracy: 1e-9)
        XCTAssertEqual(placement.angle, .pi / 2, accuracy: 0.01)
        XCTAssertLessThan(placement.angle, .pi / 2, "the cursor is slightly to the right")
        assertFullyInside(placement, content)
    }

    func testCursorBeyondOneSideAndWithinTheOtherSpanIsASingleEdge() throws {
        let placement = try XCTUnwrap(place(CGPoint(x: 450, y: 900)))
        XCTAssertEqual(placement.edge, .bottom)
        XCTAssertEqual(placement.distance, 500, accuracy: 1e-9)
    }

    func testDistanceToACornerIsEuclidean() throws {
        let placement = try XCTUnwrap(place(CGPoint(x: 800, y: 800)))
        XCTAssertEqual(placement.edge, [.right, .bottom])
        XCTAssertEqual(placement.distance, hypot(300, 400), accuracy: 1e-9)
    }

    // MARK: Sweeps

    func testIndicatorStaysFullyInsideForEveryDirectionAndDistance() throws {
        let centre = CGPoint(x: content.midX, y: content.midY)
        // Measured from the centre; every reach exceeds the 250 half-diagonal, so the cursor
        // is outside in every direction.
        for step in 0 ..< 72 {
            let direction = Double(step) * 2 * .pi / 72
            for reach: CGFloat in [260, 400, 1000, 12345, 1e5, 1e7] {
                let cursor = CGPoint(
                    x: centre.x + reach * CGFloat(cos(direction)),
                    y: centre.y + reach * CGFloat(sin(direction))
                )
                guard let placement = place(cursor) else {
                    XCTFail("direction \(step) reach \(reach) returned nil")
                    continue
                }
                assertFullyInside(placement, content)
                let toCursor = atan2(cursor.y - placement.center.y, cursor.x - placement.center.x)
                XCTAssertEqual(placement.angle, toCursor, accuracy: 1e-9)
                XCTAssertFalse(placement.edge.isEmpty)
            }
        }
    }

    func testIndicatorStaysInsideWhenLargeRelativeToContent() throws {
        let rect = CGRect(x: 0, y: 0, width: 120, height: 90)
        let size = CGSize(width: 60, height: 40)
        for step in 0 ..< 72 {
            let direction = Double(step) * 2 * .pi / 72
            for reach: CGFloat in [100, 500, 1e4] {
                let cursor = CGPoint(
                    x: 60 + reach * CGFloat(cos(direction)),
                    y: 45 + reach * CGFloat(sin(direction))
                )
                let placement = try XCTUnwrap(place(cursor, in: rect, size: size))
                assertFullyInside(placement, rect, size: size)
            }
        }
    }

    // MARK: Scale

    func testScaleNeverDecreasesWithDistanceAndStaysInRange() throws {
        var previous: CGFloat = 0
        let distances: [CGFloat] = [0.001, 1, 10, 50, 100, 250, 500, 750, 1000, 1499, 1500, 2000, 1e4, 1e7]
        for distance in distances {
            let placement = try XCTUnwrap(place(CGPoint(x: 500 + distance, y: 250)))
            XCTAssertGreaterThanOrEqual(placement.scale, previous, "distance \(distance)")
            XCTAssertGreaterThanOrEqual(placement.scale, 0.85)
            XCTAssertLessThanOrEqual(placement.scale, 1.25)
            previous = placement.scale
        }
        XCTAssertEqual(previous, 1.25, accuracy: 1e-12, "far away saturates at the maximum")
    }

    func testScaleReachesMaximumAtAboutThreeContentDiagonals() throws {
        // Content diagonal is 500.
        let atThree = try XCTUnwrap(place(CGPoint(x: 500 + 1500, y: 250)))
        XCTAssertEqual(atThree.scale, 1.25, accuracy: 1e-12)
        let atOne = try XCTUnwrap(place(CGPoint(x: 500 + 500, y: 250)))
        XCTAssertGreaterThan(atOne.scale, 0.85)
        XCTAssertLessThan(atOne.scale, 1.25)
        let atHalfDiagonal = try XCTUnwrap(place(CGPoint(x: 500 + 250, y: 250)))
        let nearEdge = try XCTUnwrap(place(CGPoint(x: 500 + 25, y: 250)))
        // Nonlinear: the first stretch gains more than a linear ramp would.
        XCTAssertGreaterThan(atHalfDiagonal.scale - 0.85, (1.25 - 0.85) * 250 / 1500)
        XCTAssertGreaterThan(atHalfDiagonal.scale, nearEdge.scale)
    }

    func testCustomScaleRangeIsRespected() throws {
        let near = try XCTUnwrap(OffscreenCursorLocator.placement(
            cursor: CGPoint(x: 500.0001, y: 250), content: content, indicatorSize: indicator,
            minimumScale: 1, maximumScale: 2
        ))
        let far = try XCTUnwrap(OffscreenCursorLocator.placement(
            cursor: CGPoint(x: 1e7, y: 250), content: content, indicatorSize: indicator,
            minimumScale: 1, maximumScale: 2
        ))
        XCTAssertEqual(near.scale, 1, accuracy: 1e-3)
        XCTAssertEqual(far.scale, 2, accuracy: 1e-12)
    }

    func testReversedScaleRangeNeverLeavesTheRange() throws {
        let placement = try XCTUnwrap(OffscreenCursorLocator.placement(
            cursor: CGPoint(x: 900, y: 250), content: content, indicatorSize: indicator,
            minimumScale: 1.2, maximumScale: 0.9
        ))
        XCTAssertEqual(placement.scale, 1.2, accuracy: 1e-12)
    }

    // MARK: Coordinates and extremes

    func testNegativeOriginContent() throws {
        let rect = CGRect(x: -500, y: -400, width: 300, height: 200) // x -500...-200, y -400...-200
        XCTAssertNil(place(CGPoint(x: -350, y: -300), in: rect))
        XCTAssertNil(place(CGPoint(x: -200, y: -400), in: rect), "corner is inside")

        let right = try XCTUnwrap(place(CGPoint(x: 0, y: -300), in: rect))
        XCTAssertEqual(right.edge, .right)
        XCTAssertEqual(right.distance, 200, accuracy: 1e-9)
        XCTAssertEqual(right.center.x, -200 - indicatorRadius * right.scale, accuracy: 1e-9)
        XCTAssertEqual(right.center.y, -300, accuracy: 1e-9)
        assertFullyInside(right, rect)

        let upperLeft = try XCTUnwrap(place(CGPoint(x: -5000, y: -4000), in: rect))
        XCTAssertEqual(upperLeft.edge, [.left, .top])
        XCTAssertLessThan(upperLeft.center.x, -350)
        XCTAssertLessThan(upperLeft.center.y, -300)
        assertFullyInside(upperLeft, rect)
    }

    func testVeryLargeDistancesAndNegativeCursors() throws {
        for cursor in [
            CGPoint(x: 1e7, y: 1e7), CGPoint(x: -1e7, y: 1e7),
            CGPoint(x: 1e7, y: -1e7), CGPoint(x: -1e7, y: -1e7),
            CGPoint(x: 1e7, y: 250), CGPoint(x: 300, y: -1e7),
        ] {
            let placement = try XCTUnwrap(place(cursor), "\(cursor)")
            assertFullyInside(placement, content)
            XCTAssertEqual(placement.scale, 1.25, accuracy: 1e-12)
            XCTAssertTrue(placement.distance.isFinite)
            XCTAssertGreaterThan(placement.distance, 9.9e6)
        }
    }

    func testTinyContentWithTinyIndicator() throws {
        let rect = CGRect(x: -0.5, y: -0.5, width: 0.001, height: 0.001)
        let size = CGSize(width: 0.0001, height: 0.0001)
        let placement = try XCTUnwrap(place(CGPoint(x: 10, y: -0.5), in: rect, size: size))
        XCTAssertEqual(placement.edge, .right)
        assertFullyInside(placement, rect, size: size)
        XCTAssertEqual(placement.scale, 1.25, accuracy: 1e-12)
    }

    // MARK: Invalid input

    func testNonFiniteCursorReturnsNil() {
        XCTAssertNil(place(CGPoint(x: CGFloat.nan, y: 250)))
        XCTAssertNil(place(CGPoint(x: 700, y: CGFloat.nan)))
        XCTAssertNil(place(CGPoint(x: CGFloat.infinity, y: 250)))
        XCTAssertNil(place(CGPoint(x: 300, y: -CGFloat.infinity)))
    }

    func testNonFiniteContentReturnsNil() {
        let cursor = CGPoint(x: 700, y: 250)
        XCTAssertNil(place(cursor, in: CGRect(x: CGFloat.nan, y: 0, width: 400, height: 300)))
        XCTAssertNil(place(cursor, in: CGRect(x: 0, y: CGFloat.infinity, width: 400, height: 300)))
        XCTAssertNil(place(cursor, in: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 300)))
        XCTAssertNil(place(cursor, in: CGRect(x: 0, y: 0, width: 400, height: CGFloat.nan)))
    }

    func testNonFiniteIndicatorOrScaleReturnsNil() {
        let cursor = CGPoint(x: 700, y: 250)
        XCTAssertNil(place(cursor, size: CGSize(width: CGFloat.nan, height: 30)))
        XCTAssertNil(place(cursor, size: CGSize(width: 40, height: CGFloat.infinity)))
        XCTAssertNil(OffscreenCursorLocator.placement(
            cursor: cursor, content: content, indicatorSize: indicator, minimumScale: CGFloat.nan
        ))
        XCTAssertNil(OffscreenCursorLocator.placement(
            cursor: cursor, content: content, indicatorSize: indicator, maximumScale: CGFloat.infinity
        ))
    }

    func testEmptyContentReturnsNil() {
        let cursor = CGPoint(x: 700, y: 250)
        XCTAssertNil(place(cursor, in: .zero))
        XCTAssertNil(place(cursor, in: CGRect(x: 0, y: 0, width: 0, height: 300)))
        XCTAssertNil(place(cursor, in: CGRect(x: 0, y: 0, width: 400, height: 0)))
        XCTAssertNil(place(cursor, in: CGRect(x: 0, y: 0, width: -400, height: 300)))
    }

    // MARK: Content smaller than the indicator

    func testContentSmallerThanIndicatorCentresTheIndicator() throws {
        let rect = CGRect(x: 50, y: 70, width: 10, height: 10)
        for cursor in [
            CGPoint(x: 1000, y: 75), CGPoint(x: -1000, y: -1000),
            CGPoint(x: 55, y: 9e6), CGPoint(x: 61, y: 81),
        ] {
            let placement = try XCTUnwrap(place(cursor, in: rect), "\(cursor)")
            XCTAssertEqual(placement.center.x, 55, accuracy: 1e-9)
            XCTAssertEqual(placement.center.y, 75, accuracy: 1e-9)
            XCTAssertTrue(placement.angle.isFinite)
        }
    }

    func testContentNarrowerThanIndicatorCentresOnThatAxisOnly() throws {
        // Tall enough for the indicator, too narrow horizontally.
        let rect = CGRect(x: 0, y: 0, width: 10, height: 400)
        let placement = try XCTUnwrap(place(CGPoint(x: 5, y: 2000), in: rect))
        XCTAssertEqual(placement.edge, .bottom)
        XCTAssertEqual(placement.center.x, 5, accuracy: 1e-9)
        XCTAssertEqual(placement.center.y, 400 - indicatorRadius * placement.scale, accuracy: 1e-9)
    }

    func testAngleStillPointsAtTheCursorWhenIndicatorIsCentred() throws {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        let placement = try XCTUnwrap(place(CGPoint(x: 5, y: 1005), in: rect))
        XCTAssertEqual(placement.angle, .pi / 2, accuracy: 1e-9)
    }
}
