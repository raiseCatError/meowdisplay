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

    // MARK: - Size-class dependent controls

    /// Roomy (the iPad-style layouts) is decided by the window's size classes, never by the
    /// device or its orientation: regular in both directions. An unfolded iPhone Duo can be
    /// roomy; the same app on a phone, or folded, is compact.
    @MainActor
    private func isRoomy(_ app: XCUIApplication) throws -> Bool {
        let window = app.windows.firstMatch
        try XCTSkipIf(window.horizontalSizeClass == .unspecified || window.verticalSizeClass == .unspecified,
                      "The window does not report its size classes")
        print("AdaptiveLayout: size classes \(window.horizontalSizeClass.rawValue)/\(window.verticalSizeClass.rawValue)")
        return window.horizontalSizeClass == .regular && window.verticalSizeClass == .regular
    }

    @MainActor
    private func launchIntoDemo() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        sleep(1)
        let explore = app.buttons["exploreDemo"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        for _ in 0..<4 where !explore.isHittable { app.swipeUp(velocity: .slow) }
        explore.tap()
        XCTAssertTrue(app.buttons["Exit Demo"].waitForExistence(timeout: 5))
        return app
    }

    /// Wakes the faded controls with a touch on the stream, then opens Settings.
    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let settings = app.descendants(matching: .any)["Settings"].firstMatch
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 5), .completed, "Settings is reachable after a touch")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5)
                      || app.staticTexts["Settings"].waitForExistence(timeout: 5))
    }

    /// Closes Settings by its own Done or Back, however far in it is.
    @MainActor
    private func leaveSettings(_ app: XCUIApplication) {
        for _ in 0..<4 where !app.buttons["Exit Demo"].isHittable {
            let done = app.buttons["Done"].firstMatch
            let back = app.buttons["BackButton"].firstMatch
            if done.exists && done.isHittable {
                done.tap()
            } else if back.exists {
                back.tap()
            } else if done.exists {
                done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                XCTFail("Neither Done nor Back is available to leave Settings")
                break
            }
            sleep(1)
        }
        XCTAssertTrue(app.buttons["Exit Demo"].waitForExistence(timeout: 5), "back on the stream")
    }

    @MainActor
    private func openControlsPage(_ app: XCUIApplication) {
        guard !app.navigationBars["Controls"].exists else { return }
        let controls = app.buttons["Controls"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        for _ in 0..<4 where !controls.isHittable && !app.collectionViews["Sidebar"].exists { app.swipeUp(velocity: .slow) }
        if controls.isHittable {
            controls.tap()
        } else {
            // A sidebar's rows never report hittable; tap where it is drawn.
            controls.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 5))
    }

    /// Whether the open Controls page has a setting, scrolling the whole page: rows below the
    /// fold are not in the accessibility tree until they are near the screen. Only scrolls up,
    /// so a sheet is never dragged away by it.
    @MainActor
    private func controlsPageHas(_ app: XCUIApplication, _ label: String) -> Bool {
        let target = app.descendants(matching: .any)[label].firstMatch
        for _ in 0..<10 {
            if target.exists { return true }
            app.swipeUp(velocity: .fast)
        }
        return target.exists
    }

    @MainActor
    func testControlsSettingsFollowTheWindowSizeClasses() throws {
        let app = launchIntoDemo()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            sleep(1)
            let roomy = try isRoomy(app)
            openSettings(app)
            openControlsPage(app)
            let hasLayout = controlsPageHas(app, "Control Layout")
            XCTAssertEqual(hasLayout, roomy, "Control Layout is offered exactly on a roomy window (\(orientation.rawValue))")
            // Back to the top of the page for the next row: reopen it.
            leaveSettings(app)
            openSettings(app)
            openControlsPage(app)
            let hasTraySide = controlsPageHas(app, "Landscape Tray Side")
            XCTAssertEqual(hasTraySide, !roomy, "Landscape Tray Side is offered exactly on a compact window (\(orientation.rawValue))")
            keep(app, "controls-settings-\(orientation.rawValue)-roomy-\(roomy)")
            leaveSettings(app)
        }
        app.buttons["Exit Demo"].tap()
        XCTAssertTrue(app.buttons["exploreDemo"].waitForExistence(timeout: 5))
    }

    /// A compact window presents Settings as a sheet (it can be dragged away); a roomy one
    /// presents it full screen (it cannot). Decided when Settings opens.
    @MainActor
    func testSettingsPresentationFollowsTheWindowSizeClasses() throws {
        let app = launchIntoDemo()
        let roomy = try isRoomy(app)
        openSettings(app)
        let bar = app.navigationBars["Settings"]
        if bar.exists {
            let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
            start.press(forDuration: 0.1, thenDragTo: end)
        } else {
            app.swipeDown(velocity: .fast)
        }
        sleep(1)
        let dismissed = app.buttons["Exit Demo"].waitForExistence(timeout: 3)
        XCTAssertEqual(dismissed, !roomy, roomy
            ? "a roomy window shows Settings full screen: a drag cannot dismiss it"
            : "a compact window shows Settings as a sheet: a drag dismisses it")
        keep(app, "settings-presentation-roomy-\(roomy)")
        if !dismissed { leaveSettings(app) }
        app.buttons["Exit Demo"].tap()
        XCTAssertTrue(app.buttons["exploreDemo"].waitForExistence(timeout: 5))
    }

    /// Upside-down portrait is not available on iPhones without a Home button (a system rule),
    /// and the app does not fight it: it tolerates either outcome, and in every orientation the
    /// controls stay inside the window.
    @MainActor
    func testControlsStayInsideTheWindowThroughEveryOrientationIncludingUpsideDown() {
        let app = launchIntoDemo()
        let orientations: [UIDeviceOrientation] = [.portrait, .portraitUpsideDown, .landscapeLeft,
                                                   .landscapeRight, .portraitUpsideDown, .portrait]
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            sleep(1)
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
            sleep(1)
            let window = app.windows.firstMatch.frame
            XCTAssertFalse(window.isEmpty)
            print("AdaptiveLayout: requested \(orientation.rawValue), window \(window)")
            for name in ["Exit Demo", "Settings"] {
                let control = app.descendants(matching: .any)[name].firstMatch
                XCTAssertTrue(control.waitForExistence(timeout: 5), "\(name) after requesting \(orientation.rawValue)")
                XCTAssertTrue(window.contains(control.frame),
                              "\(name) lies inside the window after requesting \(orientation.rawValue)")
            }
            keep(app, "orientation-\(orientation.rawValue)")
        }
        app.buttons["Exit Demo"].tap()
        XCTAssertTrue(app.buttons["exploreDemo"].waitForExistence(timeout: 5))
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
