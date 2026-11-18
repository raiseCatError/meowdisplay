import XCTest

/// The overview's toolbar and action bar split around a vertical fold (OverviewChromeFold).
final class OverviewChromeFoldTests: XCTestCase {

    func testNoDivisionKeepsOneBar() {
        XCTAssertNil(OverviewChromeFold.split(containerWidth: 900, divisions: []))
    }

    func testACentredVerticalFoldSplitsWithClearance() {
        let fold = CGRect(x: 440, y: 0, width: 20, height: 700)
        XCTAssertEqual(OverviewChromeFold.split(containerWidth: 900, divisions: [fold]),
                       OverviewChromeFold.Split(leading: 432, gap: 36))
    }

    func testAHorizontalFoldDoesNotSplitTheBars() {
        // Tabletop: the bars sit above and below the fold already.
        XCTAssertNil(OverviewChromeFold.split(containerWidth: 900, divisions: [CGRect(x: 0, y: 340, width: 900, height: 20)]))
    }

    func testAFoldNearAnEdgeLeavesTheBarsAlone() {
        XCTAssertNil(OverviewChromeFold.split(containerWidth: 900, divisions: [CGRect(x: 60, y: 0, width: 20, height: 700)]))
        XCTAssertNil(OverviewChromeFold.split(containerWidth: 900, divisions: [CGRect(x: 830, y: 0, width: 20, height: 700)]))
    }

    func testAFoldOutsideTheContainerIsIgnored() {
        XCTAssertNil(OverviewChromeFold.split(containerWidth: 900, divisions: [CGRect(x: 950, y: 0, width: 20, height: 700)]))
    }

    func testTheFoldClosestToTheMiddleWins() {
        let near = CGRect(x: 300, y: 0, width: 10, height: 700)
        let middle = CGRect(x: 445, y: 0, width: 10, height: 700)
        XCTAssertEqual(OverviewChromeFold.split(containerWidth: 900, divisions: [near, middle])?.leading, 437)
    }

    func testDegenerateInputGivesNoSplit() {
        XCTAssertNil(OverviewChromeFold.split(containerWidth: 0, divisions: [CGRect(x: 0, y: 0, width: 1, height: 2)]))
        XCTAssertNil(OverviewChromeFold.split(containerWidth: .nan, divisions: [CGRect(x: 0, y: 0, width: 1, height: 2)]))
        XCTAssertNil(OverviewChromeFold.split(containerWidth: 900, divisions: [.null, .zero]))
    }
}
