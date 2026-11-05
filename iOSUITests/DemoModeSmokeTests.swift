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
            // Decided by what is on screen, not the device: a compact window pushes each page
            // over the list, a regular one (iPad, unfolded iPhone Duo) keeps the list beside it.
            if !cell.isHittable { app.swipeUp() }
            if !cell.waitForExistence(timeout: 3) { print(app.debugDescription) }
            XCTAssertTrue(cell.exists, category)
            cell.tap()
            XCTAssertTrue(app.navigationBars[category].waitForExistence(timeout: 3), category)
            snapshot(app, "settings-\(category)")
            if category == "About" {
                XCTAssertTrue(app.descendants(matching: .any)["Privacy Policy"].firstMatch.exists,
                              "About links the privacy policy in Demo Mode")
            }
            // Back to the list, when the page was pushed over it. The bar's back button is
            // titled after the list; its first button may be another control (Done).
            // Back to the list when the page was pushed over it. The system Back button is
            // found by its identifier: on current iOS it isn't a child of the bar's element,
            // and the bar's first button may be another control.
            let back = app.buttons["BackButton"].firstMatch
            if !(cell.exists && cell.isHittable), back.exists {
                back.tap()
                // The list's own bar, not a row: rows scrolled off a lazy list aren't in the tree.
                XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3),
                              "the list is reachable again from \(category)")
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
        // Lists load rows only as they scroll into view, and the Arrow Keys
        // rows in Control Tray push Window Switcher below the fold on a phone.
        for _ in 0..<5 where !stagePeek.waitForExistence(timeout: 1) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(stagePeek.waitForExistence(timeout: 5))
        for _ in 0..<6 where !rail.isHittable { app.swipeUp() }
        // The default itself is unit-tested (StagePeekTests); a run that failed
        // mid-way may have left Rail selected, so start from Stage Peek.
        select(stagePeek)
        XCTAssertTrue(app.otherElements["stagePeekEdgePicker"].exists || app.buttons["stagePeekEdgePicker"].exists
                      || app.staticTexts["Stage Peek Edge"].exists, "the edge choice shows for Stage Peek")
        snapshot(app, "window-switcher-stage-peek")

        select(rail)
        XCTAssertFalse(app.staticTexts["Stage Peek Edge"].exists, "no edge choice for the Rail")
        snapshot(app, "window-switcher-rail")

        app.terminate()
        app.launch()
        openControlsSettings(app)
        let railAfterRelaunch = app.buttons["Rail"].firstMatch
        for _ in 0..<5 where !railAfterRelaunch.waitForExistence(timeout: 1) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(railAfterRelaunch.waitForExistence(timeout: 5))
        for _ in 0..<6 where !railAfterRelaunch.isHittable { app.swipeUp() }
        XCTAssertTrue(becomesSelected(railAfterRelaunch, within: 10), "Rail is remembered")

        select(app.buttons["Stage Peek"].firstMatch)   // leave the simulator on the default
    }

    /// Taps a segment until it reads as selected. On a loaded CI simulator the selection
    /// can take more than 3 s to reach the accessibility tree, and a tap can land while
    /// the list is still settling after a scroll, so one retry is allowed.
    @MainActor
    private func select(_ segment: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for timeout: TimeInterval in [6, 10] {
            if segment.isSelected { return }
            segment.tap()
            if becomesSelected(segment, within: timeout) { return }
        }
        XCTFail("\(segment.label) never read as selected", file: file, line: line)
    }

    @MainActor
    private func becomesSelected(_ element: XCUIElement, within timeout: TimeInterval) -> Bool {
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: element)
        return XCTWaiter.wait(for: [selected], timeout: timeout) == .completed
    }

    /// Physical iPhone + a live Mac that offers Window mode (skipped otherwise).
    /// Run with the Mac in View Only for this device: nothing here moves the
    /// Mac's pointer or focuses a Mac window.
    @MainActor
    func testStagePeekOnALiveMac() throws {
        try skipWithoutLiveMac()
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

    /// Touch Style, with Direct Touch: Classic shows the Smart Touch rows and Natural Touch
    /// doesn't, a change is remembered across a relaunch, and the device's own choice is put
    /// back. Starts from whichever style the device has (Classic for new and upgraded installs
    /// since schema 21, which InputDefaultsTests checks), so it means the same on any device.
    @MainActor
    func testTouchStyleShowsSmartTouchForClassicAndIsRemembered() throws {
        let app = XCUIApplication()
        app.launch()
        openInputSettings(app)
        // Touch Style belongs to Direct Touch; a device set to Trackpad (phones start there) is left as it is.
        if app.buttons["Trackpad"].firstMatch.waitForExistence(timeout: 3), app.buttons["Trackpad"].firstMatch.isSelected {
            throw XCTSkip("Input Mode is Trackpad on this device; not changing it")
        }
        let natural = app.buttons["Natural Touch"].firstMatch
        let classic = app.buttons["Classic"].firstMatch
        // Lists load rows only as they scroll into view (the Input page grew).
        for _ in 0..<5 where !natural.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(natural.waitForExistence(timeout: 5))
        XCTAssertTrue(classic.exists)
        XCTAssertNotEqual(natural.isSelected, classic.isSelected, "exactly one Touch Style is chosen")
        let startedClassic = classic.isSelected
        let (own, other) = startedClassic ? ("Classic", "Natural Touch") : ("Natural Touch", "Classic")
        assertSmartTouch(app, shown: startedClassic)
        snapshot(app, "touch-style-start-\(own)")

        select(app.buttons[other].firstMatch)
        assertSmartTouch(app, shown: !startedClassic)
        snapshot(app, "touch-style-\(other)")

        app.terminate()
        app.launch()
        openInputSettings(app)
        let remembered = app.buttons[other].firstMatch
        for _ in 0..<5 where !remembered.waitForExistence(timeout: 1) { app.swipeUp() }
        XCTAssertTrue(remembered.waitForExistence(timeout: 5))
        XCTAssertTrue(remembered.isSelected, "\(other) is remembered")
        assertSmartTouch(app, shown: !startedClassic)

        select(app.buttons[own].firstMatch)   // the device's own choice back
        assertSmartTouch(app, shown: startedClassic)
    }

    /// The Smart Touch rows show with Classic only.
    @MainActor
    private func assertSmartTouch(_ app: XCUIApplication, shown: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.staticTexts["Smart Touch"]
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == %@", NSNumber(value: shown)), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 3), .completed,
                       shown ? "Classic shows Smart Touch" : "Smart Touch belongs to Classic", file: file, line: line)
    }
}

// MARK: - Live Mac connection (physical iPhone)

extension DemoModeSmokeTests {
    /// Each live-Mac test otherwise finds out there's no Mac only by waiting out its connection
    /// timeouts (up to a minute each). A run that can never reach one says so with
    /// MEOW_NO_LIVE_MAC=1 (pass TEST_RUNNER_MEOW_NO_LIVE_MAC=1 to xcodebuild, as CI does),
    /// and the tests skip at once.
    private func skipWithoutLiveMac() throws {
        if ProcessInfo.processInfo.environment["MEOW_NO_LIVE_MAC"] == "1" {
            throw XCTSkip("no live Mac for this run (MEOW_NO_LIVE_MAC=1)")
        }
    }

    /// Physical iPhone + the paired Mac on the same network (skipped otherwise): connects from the
    /// home screen (or the Reconnect button) and waits for the session to leave the home screen.
    /// The Mac's log is the oracle for what the device then shows; this only drives the button.
    @MainActor
    func testConnectsToThePairedMac() throws {
        try skipWithoutLiveMac()
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

    /// Live Mac (skips without one): in Trackpad mode a one-finger drag moves the pane's cursor
    /// (screenshots show it), and a two-finger twist turns the pane freely; Reset View puts it back.
    /// The Mac's log is the oracle for the angle it drew.
    @MainActor
    func testTwistTurnsAPaneAndTheTrackpadCursorShowsOnTheLiveMac() throws {
        try skipWithoutLiveMac()
        let app = XCUIApplication()
        app.launch()
        let reconnect = app.buttons["Reconnect"]
        let connect = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Connect to' OR label BEGINSWITH 'Wake and connect to'")).firstMatch
        if reconnect.waitForExistence(timeout: 5) { reconnect.tap() }
        else if connect.waitForExistence(timeout: 10) { connect.tap() }
        sleep(10)
        let pane = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Full Desktop' OR label == 'Zed' OR label BEGINSWITH 'Zed,'")).firstMatch
        guard pane.waitForExistence(timeout: 20) else { snapshot(app, "twist-no-pane"); throw XCTSkip("no Window-mode pane") }
        snapshot(app, "cursor-before")
        // Trackpad: one finger moves the cursor (a drag, never a tap: no click on the Mac).
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        middle.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.65)),
                     withVelocity: .slow, thenHoldForDuration: 0.1)
        sleep(2)
        snapshot(app, "cursor-after-drag")
        // Two fingers twist about 50° over the Full Desktop pane (the first pane).
        let paneArea = app.descendants(matching: .any).matching(identifier: "workspacePane").firstMatch
        XCTAssertTrue(paneArea.waitForExistence(timeout: 5), "each pane is an element")
        paneArea.rotate(.pi * 50 / 180, withVelocity: 0.8)
        snapshot(app, "twist-lifted")
        sleep(4)
        snapshot(app, "twist-after")
        // Leave the owner's layout as it was.
        pane.press(forDuration: 0.7)
        let reset = app.buttons["Reset View"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5), "a turned pane offers Reset View")
        snapshot(app, "twist-menu")
        reset.tap()
        sleep(3)
        snapshot(app, "twist-reset")
    }

    /// Live Mac (skips without one): Rotate from a pane's menu turns that pane's picture.
    @MainActor
    func testRotatesAPaneOnTheLiveMac() throws {
        try skipWithoutLiveMac()
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
