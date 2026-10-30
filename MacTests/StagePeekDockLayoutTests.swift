import XCTest

/// Stage Peek's apps bar on iPhone and iPad (owner, 2026-10-31): one row, then four rows with
/// names, then the whole screen; a swipe up puts it back.
final class StagePeekDockLayoutTests: XCTestCase {
    /// An iPad in landscape: 10 apps a row, room for 8 rows.
    private let ipad = (width: CGFloat(800), height: CGFloat(700))

    func testExpandingShowsFourRowsThenTheWholeScreen() {
        let l = StagePeekDockLayout(apps: 120, width: ipad.width, maxHeight: ipad.height)
        XCTAssertEqual(l.perRow, 10)
        XCTAssertEqual(l.maxRows, 8)
        XCTAssertEqual(l.stops, [1, 4, 8])
        XCTAssertEqual(l.nextStop(after: 1), 4, "the first expansion is four rows")
        XCTAssertEqual(l.nextStop(after: 4), 8, "then the whole screen")
        XCTAssertEqual(l.nextStop(after: 8), 1, "then back to one row")
        XCTAssertTrue(l.needsScroll(rows: 8), "more apps than fit: the grid scrolls")
    }

    func testPullingMovesOneStopOrTwo() {
        let l = StagePeekDockLayout(apps: 120, width: ipad.width, maxHeight: ipad.height)
        XCTAssertEqual(l.rows(from: 1, pulled: 30), 1, "a nudge does nothing")
        XCTAssertEqual(l.rows(from: 1, pulled: 120), 4)
        XCTAssertEqual(l.rows(from: 4, pulled: 120), 8, "pulling further takes the whole screen")
        XCTAssertEqual(l.rows(from: 1, pulled: 300), 8)
        XCTAssertEqual(l.rows(from: 8, pulled: -120), 4)
        XCTAssertEqual(l.rows(from: 8, pulled: 400), 8, "never past the screen")
    }

    func testAFewAppsNeverAddEmptyRows() {
        let l = StagePeekDockLayout(apps: 12, width: ipad.width, maxHeight: ipad.height)
        XCTAssertEqual(l.maxRows, 2)
        XCTAssertEqual(l.stops, [1, 2])
        let one = StagePeekDockLayout(apps: 3, width: ipad.width, maxHeight: ipad.height)
        XCTAssertEqual(one.stops, [1], "a search with three matches: one row")
        XCTAssertEqual(one.nextStop(after: 1), 1)
    }

    func testASmallPhoneStillFitsAtLeastOneRow() {
        let l = StagePeekDockLayout(apps: 40, width: 300, maxHeight: 60)
        XCTAssertGreaterThanOrEqual(l.perRow, 1)
        XCTAssertEqual(l.maxRows, 1)
        XCTAssertEqual(l.stops, [1])
    }

    func testASwipeUpCollapses() {
        XCTAssertTrue(StagePeekDockLayout.collapses(pulled: -40, predicted: -60, rows: 1))
        XCTAssertTrue(StagePeekDockLayout.collapses(pulled: -60, predicted: -400, rows: 8), "a flick up from the bottom edge")
        XCTAssertFalse(StagePeekDockLayout.collapses(pulled: -60, predicted: -100, rows: 4), "a slow push up drops a stop")
        XCTAssertFalse(StagePeekDockLayout.collapses(pulled: 120, predicted: 200, rows: 4))
    }
}
