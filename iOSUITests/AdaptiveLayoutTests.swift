import XCTest

/// Adaptive layouts on whatever device the run uses (CI runs it on the iPhone Duo simulator):
/// with the demo stream up, in portrait and in landscape, the controls stay inside the window
/// and usable, and Settings opens and closes. Screenshots of each state are kept for review.
final class AdaptiveLayoutTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testDemoStreamControlsStayInsideTheWindowInBothOrientations() {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        sleep(1)
        let explore = app.buttons["exploreDemo"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        for _ in 0..<4 where !explore.isHittable { app.swipeUp(velocity: .slow) }
        explore.tap()
        XCTAssertTrue(app.buttons["Exit Demo"].waitForExistence(timeout: 5))

        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            sleep(1)   // let the layout and the announced panel settle
            // The controls hide themselves after a few idle seconds; a touch brings them back.
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
            sleep(1)
            let window = app.windows.firstMatch.frame
            XCTAssertFalse(window.isEmpty)
            print("AdaptiveLayout: orientation \(orientation.rawValue) window \(window)")
            for name in ["Exit Demo", "Settings"] {
                let control = app.descendants(matching: .any)[name].firstMatch
                XCTAssertTrue(control.waitForExistence(timeout: 5), "\(name) in \(orientation.rawValue)")
                XCTAssertTrue(window.contains(control.frame), "\(name) lies inside the window in \(orientation.rawValue)")
                // The tray hides itself when idle, so only Exit Demo (always shown) must be
                // reachable at any moment; for the tray, its place in the window is what counts.
                if name == "Exit Demo" {
                    XCTAssertTrue(control.isHittable, "\(name) is reachable in \(orientation.rawValue)")
                }
            }
            keep(app, "demo-\(orientation.rawValue)")
        }

        // Auto-hide fades the tray 9 s after the last touch, and the orientation checks above
        // can take longer than that on a slow simulator. A tray that is still showing can fade
        // between a hittability check and the tap (the tap then lands on the stream), so touch
        // the stream first, as a person would: that always reveals the tray and restarts the
        // countdown. Then tap Settings as soon as it can be reached.
        let settings = app.descendants(matching: .any)["Settings"].firstMatch
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 5), .completed, "Settings is reachable after a touch")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5)
                      || app.staticTexts["Settings"].waitForExistence(timeout: 5))
        keep(app, "settings")
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() } else { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(app.buttons["Exit Demo"].waitForExistence(timeout: 5), "back on the stream")
        app.buttons["Exit Demo"].tap()
        XCTAssertTrue(app.buttons["exploreDemo"].waitForExistence(timeout: 5))
    }

    /// Polls `condition` (no fixed sleep) until it holds or `timeout` passes.
    @MainActor @discardableResult
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    // MARK: - Stage Peek through a resize (DEBUG seam `MEOW_UITEST_STAGE_PEEK`)
    //
    // The real Stage Peek overlay over the three sample displays. The host narrows the canvas it
    // gives the overlay (a Split View / Stage Manager resize) about a second after the Display
    // Overview opens, and on the fixture's own Resize button. Its "Resizes: N" label counts them.

    @MainActor
    private func launchStagePeekFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEOW_UITEST_STAGE_PEEK"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["uitestStagePeekResize"].waitForExistence(timeout: 10),
                      "the Stage Peek fixture opens at launch (a Debug build)")
        return app
    }

    /// Holds just inside the left screen edge and pulls inward, as a person does.
    @MainActor
    private func openStagePeekFromTheEdge(_ app: XCUIApplication) {
        let close = app.buttons["stagePeekClose"]
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: end, withVelocity: 250, thenHoldForDuration: 0.4)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Stage Peek opens from its edge")
    }

    /// With the overview open and the canvas narrowed under it, Stage Peek stays open and the
    /// overview stays up; Done returns to the same Stage Peek gallery.
    @MainActor
    func testDisplayOverviewStaysOpenThroughAResize() {
        let app = launchStagePeekFixture()
        openStagePeekFromTheEdge(app)
        let expand = app.buttons["stagePeekExpand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3), "Stage Peek offers Expand")
        if expand.label != "Compact" { expand.tap() }
        XCTAssertTrue(waitUntil(5) { expand.label == "Compact" }, "the gallery expands")

        let open = app.buttons["displayOverviewButton"]
        for _ in 0..<6 where !(open.exists && open.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(open.exists && open.isHittable, "the Displays section offers Overview")
        open.tap()
        let done = app.buttons["displayOverviewDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the overview opens")
        keep(app, "stage-peek-overview-open")

        // The host narrows the canvas one second after the overview opened. Watch well past it: a
        // Stage Peek that closed on the width change would take the overview with it.
        let dismissed = waitUntil(4) { !done.exists }
        XCTAssertFalse(dismissed, "the overview stays open through the resize")
        done.tap()

        let resizes = app.staticTexts["uitestStagePeekResizes"]
        XCTAssertTrue(resizes.waitForExistence(timeout: 3))
        XCTAssertEqual(resizes.label, "Resizes: 1", "the host did resize while the overview was open")
        XCTAssertTrue(app.buttons["stagePeekClose"].waitForExistence(timeout: 3),
                      "Done returns to the Stage Peek gallery, which stayed open")
        XCTAssertEqual(app.buttons["stagePeekExpand"].label, "Compact", "it is still expanded")
        keep(app, "stage-peek-after-overview")
    }

    /// Without a screen opened from the gallery a width change still closes Stage Peek, as before.
    @MainActor
    func testStagePeekStillClosesOnAResizeWithoutTheOverview() {
        let app = launchStagePeekFixture()
        openStagePeekFromTheEdge(app)
        let close = app.buttons["stagePeekClose"]
        app.buttons["uitestStagePeekResize"].tap()
        XCTAssertTrue(waitUntil(5) { !close.exists }, "a width change closes Stage Peek")
        XCTAssertEqual(app.staticTexts["uitestStagePeekResizes"].label, "Resizes: 1")
    }

    // MARK: - Overview pane (DEBUG seam `MEOW_UITEST_STAGE_PEEK_PANES` on the Stage Peek fixture)
    //
    // Window view on a stand-in Mac that offers the Overview pane, the main display already in a
    // pane ("Full Desktop"), and the real pane chrome under Stage Peek. No video.

    @MainActor
    private func workspacePane(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "workspacePane")
            .matching(NSPredicate(format: "label == %@", "\(title) pane")).firstMatch
    }

    /// Stage Peek's Displays header adds the Overview as a pane, titled Overview; holding its title
    /// lists each display, and choosing one shows that display in a pane through the display path.
    @MainActor
    func testOverviewPaneIsAddedFromStagePeekAndItsMenuListsTheDisplays() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MEOW_UITEST_STAGE_PEEK"] = "1"
        app.launchEnvironment["MEOW_UITEST_STAGE_PEEK_PANES"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["uitestStagePeekResize"].waitForExistence(timeout: 10),
                      "the Stage Peek fixture opens at launch (a Debug build)")
        XCTAssertTrue(workspacePane(app, "Full Desktop").waitForExistence(timeout: 5), "the main display starts in a pane")
        XCTAssertFalse(workspacePane(app, "Overview").exists, "no Overview pane yet")

        openStagePeekFromTheEdge(app)
        let expand = app.buttons["stagePeekExpand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3), "Stage Peek offers Expand")
        if expand.label != "Compact" { expand.tap() }
        XCTAssertTrue(waitUntil(5) { expand.label == "Compact" }, "the gallery expands")
        let add = app.buttons["displayOverviewAddAsPane"]
        for _ in 0..<6 where !(add.exists && add.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(add.exists && add.isHittable, "the Displays section offers the Overview as a pane")
        keep(app, "overview-pane-offered")
        add.tap()

        let overview = workspacePane(app, "Overview")
        XCTAssertTrue(overview.waitForExistence(timeout: 5), "the Overview pane appears, titled Overview")
        XCTAssertTrue(waitUntil(5) { !app.buttons["stagePeekClose"].exists }, "Stage Peek closes")
        XCTAssertTrue(workspacePane(app, "Full Desktop").exists, "added beside the pane already there")
        keep(app, "overview-pane-added")

        try app.holdPaneTitle(.paneTitle("Overview"), in: overview)
        let displays = ["Built-in Display", "Wide Display", "Portrait Display"]
        for name in displays {
            XCTAssertTrue(app.buttons["Show \(name) in a Pane"].waitForExistence(timeout: 5), "the menu lists \(name)")
        }
        XCTAssertFalse(app.buttons["Rotate"].exists, "an Overview pane is never turned")
        XCTAssertFalse(app.buttons["Show Overview Here"].exists, "not offered in the Overview itself")
        keep(app, "overview-pane-menu")

        app.buttons["Show Wide Display in a Pane"].tap()
        XCTAssertTrue(workspacePane(app, "Wide Display").waitForExistence(timeout: 5),
                      "the display shows in a pane of its own")
        keep(app, "overview-pane-display-shown")
    }

    // MARK: - Multi-Display Overview fixture (DEBUG seam `MEOW_UITEST_OVERVIEW`)
    //
    // The overview needs a Mac's display catalog, which the demo has not got, so the app opens it
    // straight away with three sample displays: "Built-in Display" (main, 1512x982 at 0,0),
    // "Wide Display" (1920x1080 to its right) and "Portrait Display" (1080x1920 above-left).

    private static let leadingChrome = ["displayOverviewDone", "Previous Display", "Next Display",
                                        "displayOverviewShowInPane"]
    private static let trailingChrome = ["displayOverviewFitAll", "displayOverviewIdentify",
                                         "displayOverviewAddPane", "displayOverviewMoveCursor"]

    @MainActor
    private func launchOverviewFixture(fold: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEOW_UITEST_OVERVIEW"] = "1"
        if let fold { app.launchEnvironment["MEOW_UITEST_FOLD"] = fold }
        app.launch()
        XCTAssertTrue(app.buttons["displayOverviewDone"].waitForExistence(timeout: 10),
                      "the overview fixture opens at launch (a Debug build)")
        return app
    }

    @MainActor
    private func overviewTile(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'displayOverviewTile' AND label BEGINSWITH %@", name)).firstMatch
    }

    @MainActor
    private func overviewTileFrames(_ app: XCUIApplication) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for name in ["Built-in Display", "Wide Display", "Portrait Display"] {
            frames[name] = overviewTile(app, name).frame
        }
        return frames
    }

    /// The canvas lies between the toolbar and the action bar: below Done, above Show in Pane.
    @MainActor
    private func overviewCanvas(_ app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch.frame
        let top = app.buttons["displayOverviewDone"].frame.maxY
        let bottom = app.buttons["displayOverviewShowInPane"].frame.minY
        return CGRect(x: window.minX, y: top, width: window.width, height: max(0, bottom - top))
    }

    @MainActor
    private func tap(_ app: XCUIApplication, at point: CGPoint) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - app.windows.firstMatch.frame.minX,
                                 dy: point.y - app.windows.firstMatch.frame.minY))
            .tap()
    }

    @MainActor
    private func doubleTap(_ app: XCUIApplication, at point: CGPoint) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - app.windows.firstMatch.frame.minX,
                                 dy: point.y - app.windows.firstMatch.frame.minY))
            .doubleTap()
    }

    private func framesMatch(_ a: [String: CGRect], _ b: [String: CGRect], tolerance: CGFloat = 1.5) -> Bool {
        a.keys.sorted() == b.keys.sorted() && a.allSatisfy { name, frame in
            guard let other = b[name] else { return false }
            return abs(frame.minX - other.minX) <= tolerance && abs(frame.minY - other.minY) <= tolerance
                && abs(frame.width - other.width) <= tolerance && abs(frame.height - other.height) <= tolerance
        }
    }

    /// Without a fold the bars are as before: one line each, the toolbar's navigation ahead of its
    /// tools, everything inside the window. The fold seam is off, so there is no band.
    @MainActor
    func testOverviewChromeKeepsOneLineWithoutAFold() throws {
        let app = launchOverviewFixture()
        XCTAssertFalse(app.descendants(matching: .any)["uitestFoldBand"].exists, "no synthetic fold without the seam")
        let window = app.windows.firstMatch.frame
        let done = app.buttons["displayOverviewDone"]
        let fitAll = app.buttons["displayOverviewFitAll"]
        let show = app.buttons["displayOverviewShowInPane"]
        XCTAssertTrue(fitAll.waitForExistence(timeout: 5))
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        for name in Self.leadingChrome + Self.trailingChrome where app.buttons[name].exists {
            XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(app.buttons[name].frame),
                          "\(name) \(app.buttons[name].frame) is inside the window \(window)")
        }
        XCTAssertEqual(done.frame.midY, fitAll.frame.midY, accuracy: max(done.frame.height, fitAll.frame.height) / 2,
                       "Done and Fit All share the toolbar's line")
        XCTAssertLessThan(done.frame.maxX, fitAll.frame.minX, "the navigation comes before the tools")
        let add = app.buttons["displayOverviewAddPane"]
        if add.exists {
            XCTAssertEqual(show.frame.midY, add.frame.midY, accuracy: max(show.frame.height, add.frame.height) / 2,
                           "Show in Pane and Add as New Pane share the action bar's line")
            XCTAssertLessThan(show.frame.maxX, add.frame.minX, "Show in Pane comes first")
        }
        XCTAssertLessThan(done.frame.maxY, show.frame.minY, "the toolbar is above the action bar")
        keep(app, "overview-no-fold")
    }

    /// Selection, zoom, pan, Fit All and double-tap in the overview, and taps that land on the
    /// display under the finger after the camera moved.
    @MainActor
    func testOverviewSelectionZoomPanFitAllAndTapTargeting() throws {
        let app = launchOverviewFixture()
        let window = app.windows.firstMatch
        let tiles = app.descendants(matching: .any).matching(identifier: "displayOverviewTile")
        XCTAssertTrue(waitUntil { tiles.count == 3 }, "the three sample displays are drawn (found \(tiles.count))")
        let show = app.buttons["displayOverviewShowInPane"]
        XCTAssertTrue(show.waitForExistence(timeout: 5), "the main display is selected at open: Show in Pane is offered")
        let canvas = overviewCanvas(app)
        XCTAssertFalse(canvas.isEmpty, "the canvas lies between the bars")
        // Fit-all frames settle after the first layout.
        var fitAll = overviewTileFrames(app)
        waitUntil {
            let now = overviewTileFrames(app)
            defer { fitAll = now }
            return framesMatch(now, fitAll, tolerance: 0.5)
        }
        for (name, frame) in fitAll {
            XCTAssertTrue(canvas.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(name) \(frame) is in the canvas \(canvas) at open")
        }
        let main = overviewTile(app, "Built-in Display")
        let wide = overviewTile(app, "Wide Display")
        let portrait = overviewTile(app, "Portrait Display")
        XCTAssertTrue(main.isSelected, "the main display is selected at open")
        keep(app, "overview-open")

        // A single tap selects; the camera stays.
        tap(app, at: CGPoint(x: wide.frame.midX, y: wide.frame.midY))
        XCTAssertTrue(waitUntil { wide.isSelected && !main.isSelected }, "a tap selects Wide Display")
        XCTAssertTrue(app.staticTexts["Wide Display"].exists, "the toolbar names the selection")
        XCTAssertTrue(show.isEnabled, "Show in Pane is offered for the selection")
        XCTAssertTrue(framesMatch(overviewTileFrames(app), fitAll), "a single tap does not move the camera")

        // Pinch out about the middle: the displays grow.
        let wideHeight = wide.frame.height
        window.pinch(withScale: 1.6, velocity: 1.0)
        XCTAssertTrue(waitUntil { wide.frame.height > wideHeight * 1.3 },
                      "a pinch zooms in (Wide Display \(wideHeight) -> \(wide.frame.height) pt tall)")
        keep(app, "overview-pinched")

        // Drag: the arrangement follows the finger.
        let beforePan = overviewTileFrames(app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)))
        XCTAssertTrue(waitUntil {
            let now = overviewTileFrames(app)
            return beforePan.contains { name, frame in (now[name]?.maxX ?? frame.maxX) < frame.maxX - 20 }
        }, "a drag pans the arrangement to the left")
        keep(app, "overview-panned")

        // After the camera moved, a tap lands on the display under it.
        let target = CGRect(x: canvas.minX + 8, y: canvas.minY + 16, width: canvas.width - 16, height: canvas.height - 32)
        let frames = overviewTileFrames(app)
        let visible = frames.mapValues { $0.intersection(target) }.filter { !$0.value.isNull && $0.value.width > 30 && $0.value.height > 30 }
        let selectedName = frames.keys.first { overviewTile(app, $0).isSelected }
        if let pick = visible.first(where: { $0.key != selectedName }) ?? visible.first {
            let name = pick.key, area = pick.value
            tap(app, at: CGPoint(x: area.midX, y: area.midY))
            XCTAssertTrue(waitUntil {
                overviewTile(app, name).isSelected
                    && frames.keys.filter { $0 != name }.allSatisfy { !overviewTile(app, $0).isSelected }
            }, "after a pinch and a pan, a tap at \(area) selects \(name) and only it")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.exists,
                          "the toolbar names \(name)")
        } else {
            XCTFail("no display is left in view after the pinch and the pan to tap: \(frames) in \(target)")
        }

        // Fit All brings every display back, as at open.
        app.buttons["displayOverviewFitAll"].tap()
        XCTAssertTrue(waitUntil { framesMatch(overviewTileFrames(app), fitAll) },
                      "Fit All frames the whole arrangement again: \(overviewTileFrames(app)) vs \(fitAll)")
        for (name, frame) in overviewTileFrames(app) {
            XCTAssertTrue(canvas.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(name) \(frame) is back in the canvas")
        }
        keep(app, "overview-fit-all")

        // A double-tap on a display selects it and zooms to it.
        let portraitFit = portrait.frame
        doubleTap(app, at: CGPoint(x: portraitFit.midX, y: portraitFit.midY))
        XCTAssertTrue(waitUntil { portrait.isSelected && portrait.frame.height > portraitFit.height * 1.4 },
                      "a double-tap selects Portrait Display and zooms to it (\(portraitFit) -> \(portrait.frame))")
        keep(app, "overview-double-tap-display")

        // A double-tap on empty space is Fit All. Empty space: a point of the canvas no display covers.
        let covered = overviewTileFrames(app).values.map { $0.insetBy(dx: -8, dy: -8) }
        var empty: CGPoint?
        search: for row in 1..<12 {
            for column in 1..<12 {
                let point = CGPoint(x: target.minX + target.width * CGFloat(column) / 12,
                                    y: target.minY + target.height * CGFloat(row) / 12)
                if !covered.contains(where: { $0.contains(point) }) { empty = point; break search }
            }
        }
        if let empty {
            doubleTap(app, at: empty)
            XCTAssertTrue(waitUntil { framesMatch(overviewTileFrames(app), fitAll) },
                          "a double-tap on empty space at \(empty) fits all again")
        } else {
            print("AdaptiveLayout: the zoomed display covers the whole canvas; no empty space to double-tap")
            app.buttons["displayOverviewFitAll"].tap()
            XCTAssertTrue(waitUntil { framesMatch(overviewTileFrames(app), fitAll) })
        }
        XCTAssertTrue(portrait.isSelected, "fitting all keeps the selection")

        app.buttons["displayOverviewDone"].tap()
        XCTAssertTrue(waitUntil { !app.buttons["displayOverviewDone"].exists }, "Done closes the overview")
        XCTAssertTrue(app.buttons["uitestOpenOverview"].waitForExistence(timeout: 5))
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
