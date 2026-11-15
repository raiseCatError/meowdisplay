import XCTest

/// Stage Peek's All Apps (opened from the last icon of the apps bar's grid): it takes the peek's
/// place, its background keeps text legible over any Mac picture, and the app list it shows keeps
/// apps apart by bundle id. The views themselves are checked by `StagePeekAllAppsDemoTests`
/// (iOS UI tests, hosted CI).
final class StagePeekAllAppsTests: XCTestCase {
    func testAllAppsTakesThePeeksPlaceAndTheControlsStepAside() {
        let open = StagePeekAllAppsLayering(open: true)
        XCTAssertFalse(open.peekShown, "the peek's grid, search, gallery and buttons don't show through")
        XCTAssertFalse(open.receiverControlsShown, "nor do the floating controls")
        let closed = StagePeekAllAppsLayering(open: false)
        XCTAssertTrue(closed.peekShown)
        XCTAssertTrue(closed.receiverControlsShown)
    }

    func testAllAppsBackgroundKeepsWhiteTextLegibleOverAWhiteWindow() {
        // Worst case: a pure white Mac window right behind All Apps (the frost only helps).
        let scrim = StagePeekAllAppsLayering.scrimOpacity
        let dense = StagePeekAllAppsLayering.denseScrimOpacity
        XCTAssertGreaterThanOrEqual(scrim, StagePeekLegibility.minimumScrimOpacity, "the old 0.5 dim was below the peek's own floor")
        XCTAssertGreaterThanOrEqual(StagePeekLegibility.whiteTextContrast(scrimOpacity: scrim), 7, "WCAG AAA for names and headers")
        XCTAssertGreaterThan(dense, scrim, "Reduce Transparency / Increase Contrast: denser still")
        XCTAssertGreaterThanOrEqual(StagePeekLegibility.whiteTextContrast(scrimOpacity: dense), 12)
        // Secondary text (section headers, white at 85 %) over the frost still clears AA.
        XCTAssertGreaterThanOrEqual(StagePeekLegibility.whiteTextContrast(scrimOpacity: scrim, backdropGray: 1) * 0.85, 4.5)
    }

    func testTwoAppsWithTheSameNameStayTwoInAllApps() throws {
        let list: [String: Any] = ["type": WireMessage.appCatalog, "rev": 3, "apps": [
            ["bundle": "com.apple.Notes", "name": "Notes", "running": true, "windows": 1],
            ["bundle": "com.example.notes", "name": "Notes"],
            ["bundle": "com.example.long", "name": String(repeating: "Long Name ", count: 12)],
        ]]
        guard case .appCatalog(_, let parsed)? = WorkspaceEvent.parse(type: WireMessage.appCatalog, list), let apps = parsed else {
            return XCTFail("not parsed")
        }
        XCTAssertEqual(apps.map(\.id), ["com.apple.Notes", "com.example.notes", "com.example.long"], "identified by bundle id")
        XCTAssertEqual(Set(apps.map(\.id)).count, apps.count, "no two cells share an id")
        XCTAssertEqual(apps.last?.name.count, 80, "a long name is cut on arrival; the cell truncates the rest")
        let found = WorkspaceSearch.search("notes", apps: apps, windows: []).apps.map(\.bundleID)
        XCTAssertEqual(Set(found), ["com.apple.Notes", "com.example.notes"], "search finds both")
    }
}
