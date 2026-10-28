import XCTest

/// Walks the Demo Mode features a reviewer would try and keeps a screenshot
/// of each: Extend and Mirror, Automatic 16:10 and Use Full Display,
/// Trackpad, Video Off and the key Settings pages.
final class DemoModeVisualTourTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testVisualTourPortrait() {
        XCUIDevice.shared.orientation = .portrait
        tour(prefix: "portrait")
    }

    @MainActor
    func testVisualTourLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        tour(prefix: "landscape")
    }

    @MainActor
    private func tour(prefix: String) {
        app = XCUIApplication()
        app.launch()
        sleep(2)   // let a launch-time rotation settle before any screenshot
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        waitForNonExistence(app.buttons["Close"])
        sleep(1)
        let explore = app.buttons["exploreDemo"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        snapshot("\(prefix)-00-home")
        tapWhenSettled(explore, in: app)
        XCTAssertTrue(app.buttons["Exit Demo"].waitForExistence(timeout: 5))
        sleep(1)
        snapshot("\(prefix)-01-extend-automatic-16x10")

        // Direct Touch: tap the middle of the desktop, then drag.
        let surface = app.descendants(matching: .any)["Sample Mac desktop"].firstMatch
        XCTAssertTrue(surface.exists)
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        snapshot("\(prefix)-02-direct-tap")

        // Use Full Display.
        openSettings("Display")
        let fullDisplay = app.switches["Use Full Display"].firstMatch
        reveal(fullDisplay)
        XCTAssertTrue(fullDisplay.waitForExistence(timeout: 3))
        snapshot("\(prefix)-03-settings-display-extend")
        tapSwitch(fullDisplay)
        closeSettings()
        sleep(1)
        snapshot("\(prefix)-04-extend-full-display")

        // Mirror.
        openSettings("Display")
        choose("Display Mode", option: "Mirror")
        snapshot("\(prefix)-05-settings-display-mirror")
        closeSettings()
        sleep(1)
        snapshot("\(prefix)-06-mirror")

        // Trackpad: move the pointer with one finger.
        openSettings("Input")
        app.buttons["Trackpad"].firstMatch.tap()
        snapshot("\(prefix)-07-settings-input")
        closeSettings()
        let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)))
        snapshot("\(prefix)-08-trackpad-moved")

        // Controls page, then Video Off.
        openSettings("Controls")
        snapshot("\(prefix)-09-settings-controls")
        selectCategory("Display")
        tapSwitch(app.switches["Video"].firstMatch)
        closeSettings()
        sleep(1)
        snapshot("\(prefix)-10-video-off-trackpad-preview")
        start.press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)))
        snapshot("\(prefix)-11-video-off-moved")
        XCTAssertTrue(app.buttons["Turn Video On"].exists)
        app.buttons["Turn Video On"].tap()

        app.buttons["Exit Demo"].tap()
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
    }

    // MARK: Helpers

    @MainActor
    private func openSettings(_ category: String) {
        let gear = app.descendants(matching: .any)["Settings"].firstMatch
        if !gear.isHittable {
            // Auto-hide faded the trays; any touch on the surface brings them back.
            app.descendants(matching: .any)["Sample Mac desktop"].firstMatch
                .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
            sleep(1)
        }
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        selectCategory(category)
    }

    @MainActor
    private func selectCategory(_ category: String) {
        if app.navigationBars[category].exists { return }
        if UIDevice.current.userInterfaceIdiom == .phone, !app.navigationBars["Settings"].exists {
            app.navigationBars.firstMatch.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        }
        let row = app.buttons[category].firstMatch
        reveal(row)
        XCTAssertTrue(row.waitForExistence(timeout: 3), category)
        row.tap()
        XCTAssertTrue(app.navigationBars[category].waitForExistence(timeout: 3), category)
    }

    @MainActor
    private func closeSettings() {
        if UIDevice.current.userInterfaceIdiom == .phone, !app.navigationBars["Settings"].exists {
            app.navigationBars.firstMatch.buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
        }
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Exit Demo"].waitForExistence(timeout: 5))
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

    /// Scrolls a Settings form until a row is on screen (forms build rows
    /// lazily). Short, slow drags that hold at the end, so there is no fling,
    /// and only ever upward: a downward drag at the top of a sheet dismisses it.
    /// A newly opened page starts at the top, so searching down is enough.
    @MainActor
    private func reveal(_ element: XCUIElement) {
        // The demo footer covers the bottom of Settings; a row under it is
        // not really tappable.
        let usableBottom = app.frame.maxY - 60
        func visible() -> Bool {
            element.exists && element.isHittable && element.frame.maxY < usableBottom
        }
        guard let form = app.collectionViews.allElementsBoundByIndex.last else { return }
        for _ in 0..<10 where !visible() {
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                .press(forDuration: 0.1,
                       thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)),
                       withVelocity: .slow,
                       thenHoldForDuration: 0.3)
        }
    }

    @MainActor
    private func choose(_ picker: String, option: String) {
        let control = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", picker)).firstMatch
        reveal(control)
        XCTAssertTrue(control.waitForExistence(timeout: 3), picker)
        control.tap()
        let item = app.buttons[option].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), option)
        item.tap()
    }

    @MainActor
    private func tapSwitch(_ toggle: XCUIElement) {
        reveal(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        // Tap the switch control itself, not the label (and not by screen
        // coordinates, which are unreliable in landscape).
        let control = toggle.switches.firstMatch
        let before = toggle.value as? String
        (control.exists ? control : toggle).tap()
        XCTAssertNotEqual(toggle.value as? String, before, "Toggle did not change")
    }

    private func waitForNonExistence(_ element: XCUIElement) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: 5)
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Landscape XCUITest captures come out rotated; an external
        // `simctl io screenshot` keyed on this marker gets the real frame.
        print("TOURSHOT \(name)")
        sleep(2)
    }
}
