import XCTest

/// App Review path: launch, Try the Demo, every release Settings category,
/// Control off and on, then Exit Demo back to the home screen.
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

        let explore = app.buttons["exploreDemo"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        snapshot(app, "01-home")
        tapWhenSettled(explore, in: app)

        let exit = app.buttons["Exit Demo"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Demo Mode"].firstMatch.exists)
        snapshot(app, "02-demo-surface")

        let input = app.descendants(matching: .any)["Control (Demo)"].firstMatch
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

    /// The demo button can sit below the fold of the home column in iPhone
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

        // Open Stage Peek and keep it open: a hold on the strip shows it only while the finger is
        // down (lifting closes it), so hold, then pull inward slowly to expand it.
        let close = app.buttons["stagePeekClose"]
        let start = strip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let inward = app.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: inward, withVelocity: 250, thenHoldForDuration: 0.4)
        XCTAssertTrue(close.waitForExistence(timeout: 3), "Stage Peek opens from its strip")
        XCTAssertTrue(app.descendants(matching: .any)["Full Desktop"].exists, "Full Desktop is a card")
        snapshot(app, "device-stage-peek-open")

        app.buttons["stagePeekExpand"].tap()
        sleep(2)
        snapshot(app, "device-stage-peek-expanded")
        assertGalleryColumns(app, atLeast: 2, "portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        snapshot(app, "device-stage-peek-expanded-landscape")
        assertGalleryColumns(app, atLeast: 2, "landscape")
        XCUIDevice.shared.orientation = .portrait
        sleep(2)
        app.buttons["stagePeekExpand"].tap()   // Compact
        sleep(1)

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.12)).tap()   // outside the stack
        waitForNonExistence(close)
        XCTAssertFalse(close.exists, "a tap outside closes Stage Peek")
        snapshot(app, "device-stage-peek-dismissed")
    }

    /// The expanded gallery's first row holds at least `n` window cards (needs that many windows).
    @MainActor
    private func assertGalleryColumns(_ app: XCUIApplication, atLeast n: Int, _ label: String) {
        let cards = app.descendants(matching: .any).matching(identifier: "galleryWindowCard").allElementsBoundByIndex
            .map { $0.frame }.filter { !$0.isEmpty }
        guard cards.count >= n else { XCTFail("\(label): only \(cards.count) window cards on screen"); return }
        let top = cards.map(\.minY).min()!
        let firstRow = cards.filter { abs($0.minY - top) < 4 }
        print("GALLERY \(label): \(firstRow.count) per row, card width \(Int(firstRow.first?.width ?? 0)) pt, screen \(Int(app.frame.width)) pt")
        XCTAssertGreaterThanOrEqual(firstRow.count, n, "\(label): \(firstRow.count) window cards in the first row")
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
    func testTouchStyleDefaultsToNaturalAndClassicPersists() throws {
        let app = XCUIApplication()
        app.launch()
        openInputSettings(app)
        let natural = app.buttons["Natural Touch"].firstMatch
        let classic = app.buttons["Classic"].firstMatch
        // Touch Style belongs to Direct Touch; a device set to Trackpad is left as it is.
        if app.buttons["Trackpad"].firstMatch.waitForExistence(timeout: 3), app.buttons["Trackpad"].firstMatch.isSelected {
            throw XCTSkip("Input Mode is Trackpad on this device; not changing it")
        }
        // Lists load rows only as they scroll into view (the Input page grew).
        for _ in 0..<5 where !natural.waitForExistence(timeout: 1) { app.swipeUp() }
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
        for _ in 0..<5 where !app.buttons["Classic"].firstMatch.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(app.buttons["Classic"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Classic"].firstMatch.isSelected, "Classic is remembered")

        app.buttons["Natural Touch"].firstMatch.tap()   // leave the simulator on the default
        XCTAssertTrue(app.buttons["Natural Touch"].firstMatch.isSelected)
    }
}

// MARK: - Live Mac connection (physical iPhone)

extension DemoModeSmokeTests {
    /// Physical iPhone + the paired Mac on the same network (skipped otherwise): connects from the
    /// home screen (or the Reconnect button) and waits for the session to leave the home screen.
    /// The Mac's log is the oracle for what the device then shows; this only drives the button.
    @MainActor
    func testConnectsToThePairedMac() throws {
        let app = XCUIApplication()
        app.launch()
        let reconnect = app.buttons["Reconnect"]
        let connect = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Connect to' OR label BEGINSWITH 'Wake and connect to' OR label BEGINSWITH 'Try again with'")).firstMatch
        if reconnect.waitForExistence(timeout: 5) {
            reconnect.tap()
        } else if connect.waitForExistence(timeout: 10) {
            snapshot(app, "live-connect-home")
            connect.tap()
        } else {
            throw XCTSkip("no paired Mac on the home screen")
        }
        let left = NSPredicate(format: "exists == false")
        expectation(for: left, evaluatedWith: connect)
        waitForExpectations(timeout: 30)
        sleep(8)
        snapshot(app, "live-connect-session")
        XCTAssertFalse(app.staticTexts["Connection lost"].exists, "the session doesn't drop")
    }

    /// Live Mac (skips without one): Rotate from a pane's menu turns that pane's picture.
    @MainActor
    func testRotatesAPaneOnTheLiveMac() throws {
        let app = XCUIApplication()
        app.launch()
        let reconnect = app.buttons["Reconnect"]
        let connect = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Connect to' OR label BEGINSWITH 'Wake and connect to'")).firstMatch
        if reconnect.waitForExistence(timeout: 5) { reconnect.tap() }
        else if connect.waitForExistence(timeout: 10) { connect.tap() }
        sleep(10)
        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Full Desktop' OR label == 'Zed' OR label BEGINSWITH 'Zed,'")).firstMatch
        guard pane.waitForExistence(timeout: 20) else { snapshot(app, "rotate-no-pane"); throw XCTSkip("no Window-mode pane") }
        snapshot(app, "rotate-before")
        pane.press(forDuration: 0.7)
        let rotate = app.buttons["Rotate"]
        XCTAssertTrue(rotate.waitForExistence(timeout: 5), "the pane menu offers Rotate")
        snapshot(app, "rotate-menu")
        rotate.tap()
        sleep(4)
        snapshot(app, "rotate-after")
        // Leave the owner's layout as it was.
        pane.press(forDuration: 0.7)
        let reset = app.buttons["Reset View"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "a rotated pane offers Reset View")
        reset.tap()
        sleep(3)
        snapshot(app, "rotate-reset")
    }
}
