import XCTest

/// App Review path: launch, Explore Demo, every release Settings category,
/// Allow Input off and on, then Exit Demo back to the home screen.
final class DemoModeSmokeTests: XCTestCase {
    private let categories = ["General", "Display", "Input", "Gestures", "Controls", "Audio",
                              "Connections", "Paired Macs", "Remote Access", "Permissions",
                              "Diagnostics", "About"]

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testExploreDemoSettingsAndExitLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        testExploreDemoSettingsAndExit()
    }

    @MainActor
    func testExploreDemoSettingsAndExit() {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        // Let the onboarding sheet finish closing before the next tap.
        waitForNonExistence(app.buttons["Close"])
        sleep(1)

        let explore = app.buttons["Explore Demo"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        snapshot(app, "01-home")
        tapWhenSettled(explore, in: app)

        let exit = app.buttons["Exit Demo"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Demo Mode"].firstMatch.exists)
        snapshot(app, "02-demo-surface")

        let input = app.descendants(matching: .any)["Allow Input (Demo)"].firstMatch
        XCTAssertTrue(input.exists)
        input.tap()
        snapshot(app, "03-input-off")
        input.tap()

        app.descendants(matching: .any)["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5)
                      || app.staticTexts["Settings"].waitForExistence(timeout: 5))
        for category in categories {
            let cell = app.buttons[category].firstMatch
            if UIDevice.current.userInterfaceIdiom == .phone, !cell.isHittable { app.swipeUp() }
            XCTAssertTrue(cell.waitForExistence(timeout: 3), category)
            cell.tap()
            XCTAssertTrue(app.navigationBars[category].waitForExistence(timeout: 3), category)
            snapshot(app, "settings-\(category)")
            if category == "About" {
                XCTAssertTrue(app.descendants(matching: .any)["Privacy Policy"].firstMatch.exists,
                              "About links the privacy policy in Demo Mode")
            }
            if app.navigationBars[category].buttons.firstMatch.exists,
               UIDevice.current.userInterfaceIdiom == .phone {
                app.navigationBars[category].buttons.firstMatch.tap()
                XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3), category)
            }
        }
        XCTAssertFalse(app.buttons["Developer"].exists && !isDebug)
        app.buttons["Done"].firstMatch.tap()

        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        exit.tap()
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        XCTAssertFalse(exit.exists)
    }

    /// Explore Demo can sit below the fold of the home column in iPhone
    /// landscape. Scroll it in slowly and let the scroll settle first: a tap
    /// during scroll deceleration only stops the scroll.
    @MainActor
    private func tapWhenSettled(_ button: XCUIElement, in app: XCUIApplication) {
        let column = app.scrollViews.containing(.button, identifier: "exploreDemo").firstMatch
        for _ in 0..<4 where !button.isHittable {
            (column.exists ? column : app).swipeUp(velocity: .slow)
        }
        sleep(1)
        button.tap()
    }

    private func waitForNonExistence(_ element: XCUIElement) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: 5)
    }

    private var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// MARK: - Touch Style

extension DemoModeSmokeTests {
    @MainActor
    func testWindowSwitcherDefaultsToStagePeekAndRailPersists() {
        let app = XCUIApplication()
        app.launch()
        openControlsSettings(app)
        let stagePeek = app.buttons["Stage Peek"].firstMatch
        let rail = app.buttons["Rail"].firstMatch
        XCTAssertTrue(stagePeek.waitForExistence(timeout: 5))
        for _ in 0..<6 where !rail.isHittable { app.swipeUp() }
        // The default itself is unit-tested (StagePeekTests); a run that failed
        // mid-way may have left Rail selected, so start from Stage Peek.
        if !stagePeek.isSelected { stagePeek.tap() }
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: stagePeek)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(app.otherElements["stagePeekEdgePicker"].exists || app.buttons["stagePeekEdgePicker"].exists
                      || app.staticTexts["Stage Peek Edge"].exists, "the edge choice shows for Stage Peek")
        snapshot(app, "window-switcher-stage-peek")

        rail.tap()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: rail)
        waitForExpectations(timeout: 3)
        XCTAssertFalse(app.staticTexts["Stage Peek Edge"].exists, "no edge choice for the Rail")
        snapshot(app, "window-switcher-rail")

        app.terminate()
        app.launch()
        openControlsSettings(app)
        XCTAssertTrue(app.buttons["Rail"].firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<6 where !app.buttons["Rail"].firstMatch.isHittable { app.swipeUp() }
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.buttons["Rail"].firstMatch)
        waitForExpectations(timeout: 3)   // Rail is remembered

        app.buttons["Stage Peek"].firstMatch.tap()   // leave the simulator on the default
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.buttons["Stage Peek"].firstMatch)
        waitForExpectations(timeout: 3)
    }

    /// Physical iPhone + a live Mac that offers Window mode (skipped otherwise).
    /// Run with the Mac in View Only for this device: nothing here moves the
    /// Mac's pointer or focuses a Mac window.
    @MainActor
    func testStagePeekOnALiveMac() throws {
        let app = XCUIApplication()
        app.launch()
        let yes = app.buttons["windowModePromptYes"]
        let strip = app.descendants(matching: .any)["stagePeekStrip"]
        if yes.waitForExistence(timeout: 30) {
            snapshot(app, "device-switch-to-window-prompt")
            yes.tap()
        }
        guard strip.waitForExistence(timeout: 30) else { throw XCTSkip("no live Mac in Window mode") }
        sleep(2)
        snapshot(app, "device-window-mode")

        strip.press(forDuration: 0.7)
        let close = app.buttons["stagePeekClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 3), "Stage Peek stays open after the hold")
        XCTAssertTrue(app.descendants(matching: .any)["Full Desktop"].exists, "Full Desktop is a card")
        snapshot(app, "device-stage-peek-open")

        app.buttons["stagePeekExpand"].tap()
        sleep(1)
        snapshot(app, "device-stage-peek-expanded")
        app.buttons["stagePeekExpand"].tap()   // Compact
        sleep(1)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.12)).tap()   // outside the stack
        waitForNonExistence(close)
        XCTAssertFalse(close.exists, "a tap outside closes Stage Peek")
        snapshot(app, "device-stage-peek-dismissed")
    }

    private func openControlsSettings(_ app: XCUIApplication) {
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        waitForNonExistence(app.buttons["Close"])
        sleep(1)
        let settings = app.buttons["Settings & Help"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let controls = app.buttons["Controls"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        controls.tap()
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 5))
    }

    private func openInputSettings(_ app: XCUIApplication) {
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        waitForNonExistence(app.buttons["Close"])
        sleep(1)
        let settings = app.buttons["Settings & Help"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let input = app.buttons["Input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.navigationBars["Input"].waitForExistence(timeout: 5))
    }

    /// Natural Touch is the default; Classic stays available, shows Smart
    /// Touch, and is remembered across a relaunch.
    @MainActor
    func testTouchStyleDefaultsToNaturalAndClassicPersists() {
        let app = XCUIApplication()
        app.launch()
        openInputSettings(app)
        let natural = app.buttons["Natural Touch"].firstMatch
        let classic = app.buttons["Classic"].firstMatch
        XCTAssertTrue(natural.waitForExistence(timeout: 5))
        XCTAssertTrue(natural.isSelected, "Natural Touch is the default")
        XCTAssertFalse(app.staticTexts["Smart Touch"].exists, "Smart Touch belongs to Classic")
        snapshot(app, "touch-style-natural")

        classic.tap()
        XCTAssertTrue(classic.isSelected)
        XCTAssertTrue(app.staticTexts["Smart Touch"].waitForExistence(timeout: 3), "Classic shows Smart Touch")
        snapshot(app, "touch-style-classic")

        app.terminate()
        app.launch()
        openInputSettings(app)
        XCTAssertTrue(app.buttons["Classic"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Classic"].firstMatch.isSelected, "Classic is remembered")

        app.buttons["Natural Touch"].firstMatch.tap()   // leave the simulator on the default
        XCTAssertTrue(app.buttons["Natural Touch"].firstMatch.isSelected)
    }
}
