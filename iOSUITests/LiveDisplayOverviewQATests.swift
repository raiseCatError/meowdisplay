import XCTest

/// The Multi-Display Overview and Show in Pane against a real paired Mac on a physical device.
/// Opt-in, like the other live tests: skips unless MEOW_LIVE_SESSION_TESTS=1 (pass
/// TEST_RUNNER_MEOW_LIVE_SESSION_TESTS=1 to xcodebuild). It never types, clicks or scrolls on the
/// Mac. Steps that act on the Mac need an extra switch each:
///   MEOW_LIVE_OVERVIEW_MULTI=1      the Mac shows two or more displays (a second monitor, or a
///                                   virtual display the owner approved); without it the test
///                                   checks the single-display fallback instead.
///   MEOW_LIVE_ALLOW_IDENTIFY=1      Identify Displays (numbers drawn on the Mac's displays).
///   MEOW_LIVE_ALLOW_CURSOR_MOVE=1   Move Cursor Here (moves the Mac pointer once).
/// The Mac arrangement is never edited here.
final class LiveDisplayOverviewQATests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private func on(_ key: String) -> Bool { env[key] == "1" }

    /// Window mode ▸ Stage Peek ▸ Displays. With one Mac display the section is the card grid and
    /// there is no Overview button; with several it is the arrangement map with Overview.
    @MainActor
    func testDisplaysSectionMatchesTheMacsDisplays() throws {
        guard on("MEOW_LIVE_SESSION_TESTS") else {
            throw XCTSkip("live session test: set MEOW_LIVE_SESSION_TESTS=1 with a paired Mac nearby")
        }
        let app = XCUIApplication()
        app.launch()
        try openStagePeekInWindowMode(app)
        let overview = app.buttons["displayOverviewButton"]
        let shown = scrollTo(overview, in: app)
        snapshot(app, "overview-01-displays-section")
        if on("MEOW_LIVE_OVERVIEW_MULTI") {
            XCTAssertTrue(shown, "two or more Mac displays: the map offers Overview")
        } else {
            XCTAssertFalse(shown, "one Mac display: the card grid, no Overview button")
        }
        app.buttons["stagePeekClose"].tap()
    }

    /// Overview on a Mac with several displays: select, zoom, pan, Fit All, tap targeting, Show in Pane.
    @MainActor
    func testOverviewNavigationAndShowInPane() throws {
        let app = try launchIntoOverview()
        let done = app.buttons["displayOverviewDone"]
        let tiles = overviewTiles(app)

        // Select the second display, then zoom and pan the camera.
        let targetLabel = tiles[1].label
        tiles[1].tap()
        let showInPane = app.buttons["displayOverviewShowInPane"]
        XCTAssertTrue(showInPane.waitForExistence(timeout: 3), "a selected display offers Show in Pane")
        zoomAndPan(app)
        snapshot(app, "overview-03-zoomed-panned")

        // Fit All brings every display back into view.
        tapFitAll(app)
        let window = mainWindow(app).frame
        for tile in overviewTiles(app) {
            XCTAssertTrue(window.intersects(tile.frame), "\(tile.label) is back in view after Fit All")
        }

        // A tap after those viewport changes still hits the display drawn there.
        let again = overviewTiles(app).first { $0.label == targetLabel }
        XCTAssertNotNil(again, "the selected display is still drawn")
        again?.tap()
        XCTAssertTrue(showInPane.waitForExistence(timeout: 3))

        if on("MEOW_LIVE_ALLOW_IDENTIFY") {
            app.buttons["displayOverviewIdentify"].tap()
            sleep(2)
            snapshot(app, "overview-05-identify")
        }
        if on("MEOW_LIVE_ALLOW_CURSOR_MOVE") {
            let move = app.buttons["displayOverviewMoveCursor"]
            if move.waitForExistence(timeout: 3) {
                move.tap()
                sleep(2)
                snapshot(app, "overview-06-cursor-moved")
            } else {
                XCTFail("Move Cursor Here is missing although control was expected")
            }
        }

        // Show in Pane closes the overview and streams that display in a pane.
        showInPane.tap()
        XCTAssertTrue(waitUntil(8) { !done.exists }, "Show in Pane closes the overview")
        snapshot(app, "overview-07-shown-in-pane")
    }

    /// Rotating the iPad with the overview open keeps it open; Fit All then frames every display
    /// in the new orientation.
    @MainActor
    func testOverviewStaysOpenThroughARotation() throws {
        let app = try launchIntoOverview()
        let done = app.buttons["displayOverviewDone"]
        zoomAndPan(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        snapshot(app, "overview-04-landscape")
        XCTAssertTrue(done.waitForExistence(timeout: 3), "the overview is still open after rotating")
        tapFitAll(app)
        let rotated = mainWindow(app).frame
        for tile in overviewTiles(app) {
            XCTAssertTrue(rotated.intersects(tile.frame), "\(tile.label) is in view after Fit All in landscape")
        }
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        XCTAssertTrue(done.waitForExistence(timeout: 3), "the overview is still open after rotating back")
        done.tap()
    }

    // MARK: - Helpers

    /// Window mode, Stage Peek, Overview; checks every Mac display is drawn and in view.
    @MainActor
    private func launchIntoOverview() throws -> XCUIApplication {
        guard on("MEOW_LIVE_SESSION_TESTS") else {
            throw XCTSkip("live session test: set MEOW_LIVE_SESSION_TESTS=1 with a paired Mac nearby")
        }
        guard on("MEOW_LIVE_OVERVIEW_MULTI") else {
            throw XCTSkip("needs two or more Mac displays: set MEOW_LIVE_OVERVIEW_MULTI=1 once they exist")
        }
        let app = XCUIApplication()
        app.launch()
        try openStagePeekInWindowMode(app)
        let open = app.buttons["displayOverviewButton"]
        XCTAssertTrue(scrollTo(open, in: app), "Overview is offered")
        open.tap()
        XCTAssertTrue(app.buttons["displayOverviewDone"].waitForExistence(timeout: 5), "the overview opens")
        let window = mainWindow(app).frame
        let tiles = overviewTiles(app)
        XCTAssertGreaterThanOrEqual(tiles.count, 2, "every Mac display is drawn")
        for tile in tiles { XCTAssertTrue(window.intersects(tile.frame), "\(tile.label) is in view after opening") }
        snapshot(app, "overview-02-fit")
        return app
    }

    @MainActor
    private func zoomAndPan(_ app: XCUIApplication) {
        let canvas = mainWindow(app)
        canvas.pinch(withScale: 2.5, velocity: 2)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
    }

    @MainActor
    private func tapFitAll(_ app: XCUIApplication) {
        let fit = app.buttons["displayOverviewFitAll"].firstMatch
        XCTAssertTrue(fit.waitForExistence(timeout: 3), "the overview offers Fit All")
        fit.tap()
        sleep(1)
    }

    @MainActor
    private func openStagePeekInWindowMode(_ app: XCUIApplication) throws {
        let yes = app.buttons["windowModePromptYes"]
        let strip = app.descendants(matching: .any)["stagePeekStrip"]
        let connect = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Connect to' OR label BEGINSWITH 'Wake and connect to' OR label BEGINSWITH 'Try again with'"
        )).firstMatch
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, !strip.exists {
            if yes.exists { yes.tap() }
            if connect.exists, connect.isHittable { connect.tap() }
            usleep(250_000)
        }
        guard strip.exists else {
            snapshot(app, "overview-no-window-mode")
            throw XCTSkip("no live Mac session in Window mode")
        }
        sleep(2)
        // The strip's accessibility frame can cover the whole screen (it does on iPad), so hold
        // just inside the screen edge it sits on and pull inward, as a person does. Stage Peek
        // Edge is Left by default and can be Right: try the left edge first, then the right.
        let close = app.buttons["stagePeekClose"]
        for (edge, inward) in [(0.01, 0.35), (0.99, 0.65)] where !close.exists {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: edge, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: inward, dy: 0.5))
            start.press(forDuration: 0.7, thenDragTo: end, withVelocity: 250, thenHoldForDuration: 0.4)
            _ = close.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(close.exists, "Stage Peek opens from its strip")
        // The Displays section (map, Overview) is part of the expanded gallery, not the compact
        // stack: expand, and wait until the button offers Compact again.
        let expand = app.buttons["stagePeekExpand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3), "Stage Peek offers Expand")
        if expand.label != "Compact" { expand.tap() }
        XCTAssertTrue(waitUntil(5) { expand.label == "Compact" }, "the gallery expands")
        snapshot(app, "overview-00-expanded")
    }

    /// The app's main window. On iPad the first window in the tree can be an empty, zero-size one,
    /// so the largest window is the one showing the app.
    @MainActor
    private func mainWindow(_ app: XCUIApplication) -> XCUIElement {
        app.windows.allElementsBoundByIndex
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? app.windows.firstMatch
    }

    /// Scrolls the gallery until `element` can be tapped. False when it never appears.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<6 {
            if element.exists, element.isHittable { return true }
            app.swipeUp(velocity: .slow)
        }
        return element.exists && element.isHittable
    }

    /// The overview's display tiles (identifier set by the overview's tiles).
    @MainActor
    private func overviewTiles(_ app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any).matching(identifier: "displayOverviewTile").allElementsBoundByIndex
            .filter { $0.exists }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    @MainActor
    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
