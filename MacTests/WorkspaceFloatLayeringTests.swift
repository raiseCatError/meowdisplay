import XCTest

/// Receiver chrome layering (Shared/WorkspaceFloats.swift, `WorkspaceFloatLayering`): a float's
/// window is pixels in the video while every outline, title pill and handle is drawn above the
/// video, so the chrome behind a float must step aside where that float is. The cases mirror the
/// owner's iPad screenshots of 2026-11-05 (two overlapping floats over two panes).
final class WorkspaceFloatLayeringTests: XCTestCase {
    // iPad landscape picture in points, two panes split at x = 628.
    private let calendar = WorkspaceRect(x: 160, y: 440, width: 660, height: 438)    // front (IMG_1761)
    private let chrome = WorkspaceRect(x: 187, y: 222, width: 472, height: 256)      // behind it

    func testAFloatCoversItsWindowAndItsTitlePill() {
        let occluder = WorkspaceFloatLayering.occluder(calendar)
        XCTAssertEqual(occluder.y, calendar.y - WorkspaceFloatLayering.pillReach)
        XCTAssertEqual(occluder.maxY, calendar.maxY)
        let pill = WorkspaceFloatLayering.pillBounds(calendar)
        XCTAssertEqual(pill.midX, calendar.midX, accuracy: 1e-9)
        XCTAssertEqual(pill.midY, calendar.y, accuracy: 1e-9, "the pill straddles the top edge")
        XCTAssertLessThanOrEqual(pill.width, 280 + 34 + 1e-9, "never wider than the widest pill")
        // A very narrow float still has a pill wide enough for its icon, title and ⋯.
        XCTAssertGreaterThanOrEqual(WorkspaceFloatLayering.pillBounds(WorkspaceRect(x: 0, y: 40, width: 60, height: 60)).width, 90)
    }

    /// IMG_1761: the back float's lower grips and grabber sat over the Calendar float in front.
    func testTheBackFloatsHandlesAndPillHideUnderTheFrontFloat() {
        let covers = WorkspaceFloatLayering.covers(backToFront: [chrome, calendar])
        XCTAssertEqual(covers.count, 2)
        XCTAssertTrue(covers[1].isEmpty, "nothing covers the front float")
        // Its lower-left grip (44 pt around the corner) and grabber fall inside the Calendar float.
        let grip = WorkspaceRect(x: chrome.x - 28, y: chrome.maxY - 16, width: 44, height: 44)
        let grabber = WorkspaceRect(x: chrome.midX - 38, y: chrome.maxY - 4, width: 76, height: 28)
        XCTAssertTrue(WorkspaceFloatLayering.isCovered(grip, by: covers[0]))
        XCTAssertTrue(WorkspaceFloatLayering.isCovered(grabber, by: covers[0]))
        // Its title pill is above the Calendar float: it stays.
        XCTAssertFalse(WorkspaceFloatLayering.isCovered(WorkspaceFloatLayering.pillBounds(chrome), by: covers[0]))
    }

    /// IMG_1758: the back float's title pill drew over the front float.
    func testATitlePillUnderAFloatInFrontIsCovered() {
        let front = WorkspaceRect(x: 330, y: 52, width: 586, height: 390)
        let back = WorkspaceRect(x: 165, y: 194, width: 472, height: 258)
        let covers = WorkspaceFloatLayering.covers(backToFront: [back, front])
        XCTAssertTrue(WorkspaceFloatLayering.isCovered(WorkspaceFloatLayering.pillBounds(back), by: covers[0]))
        XCTAssertFalse(WorkspaceFloatLayering.isCovered(WorkspaceFloatLayering.pillBounds(front), by: covers[1]))
    }

    func testTouchingEdgesAndSliversDontCountAsCovered() {
        let a = WorkspaceRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertFalse(WorkspaceFloatLayering.isCovered(a, by: [WorkspaceRect(x: 100, y: 0, width: 50, height: 50)]), "only touching")
        XCTAssertFalse(WorkspaceFloatLayering.isCovered(a, by: [WorkspaceRect(x: 99.8, y: 0, width: 50, height: 50)]), "a sliver")
        XCTAssertTrue(WorkspaceFloatLayering.isCovered(a, by: [WorkspaceRect(x: 90, y: 90, width: 50, height: 50)]))
        XCTAssertFalse(WorkspaceFloatLayering.isCovered(a, by: []))
    }

    /// IMG_1761: the vertical divider between the panes ran through the Calendar float. Its touch
    /// strip keeps only the parts above and below the float (and the float's title band).
    func testADividerTakesTouchesOnlyWhereNoFloatCoversIt() {
        let strip = WorkspaceRect(x: 621, y: 0, width: 14, height: 1050)
        let parts = WorkspaceFloatLayering.uncovered(strip, alongX: false, by: [WorkspaceFloatLayering.occluder(calendar)])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].y, 0)
        XCTAssertEqual(parts[0].maxY, calendar.y - WorkspaceFloatLayering.pillReach, accuracy: 1e-9)
        XCTAssertEqual(parts[1].y, calendar.maxY, accuracy: 1e-9)
        XCTAssertEqual(parts[1].maxY, 1050, accuracy: 1e-9)
        XCTAssertTrue(parts.allSatisfy { $0.x == strip.x && $0.width == strip.width })

        // Floats that miss it change nothing; one that covers all of it leaves nothing.
        XCTAssertEqual(WorkspaceFloatLayering.uncovered(strip, alongX: false, by: [WorkspaceRect(x: 0, y: 0, width: 300, height: 300)]), [strip])
        XCTAssertTrue(WorkspaceFloatLayering.uncovered(strip, alongX: false, by: [WorkspaceRect(x: 600, y: -10, width: 60, height: 2000)]).isEmpty)
        // Leftovers too short to grab (under 24 pt) are dropped, not left as tiny traps.
        let tight = WorkspaceFloatLayering.uncovered(strip, alongX: false, by: [WorkspaceRect(x: 600, y: 10, width: 60, height: 1030)])
        XCTAssertTrue(tight.isEmpty, "\(tight)")
        // Along x (a horizontal divider), two floats leave three parts.
        let row = WorkspaceRect(x: 0, y: 500, width: 1000, height: 14)
        let three = WorkspaceFloatLayering.uncovered(row, alongX: true, by: [WorkspaceRect(x: 100, y: 400, width: 100, height: 300),
                                                                               WorkspaceRect(x: 500, y: 450, width: 200, height: 100)])
        XCTAssertEqual(three.map(\.x), [0, 200, 700])
        XCTAssertEqual(three.map(\.maxX), [100, 500, 1000])
    }

    /// Grips and the grabber clutter the picture (and take touches) on floats nobody is using.
    func testHandlesShowOnlyWhenTheFloatIsInUse() {
        XCTAssertTrue(WorkspaceFloatLayering.showsHandles(selected: true, hovered: false, manipulating: false))
        XCTAssertTrue(WorkspaceFloatLayering.showsHandles(selected: false, hovered: true, manipulating: false))
        XCTAssertTrue(WorkspaceFloatLayering.showsHandles(selected: false, hovered: false, manipulating: true))
        XCTAssertFalse(WorkspaceFloatLayering.showsHandles(selected: false, hovered: false, manipulating: false))
    }
}
