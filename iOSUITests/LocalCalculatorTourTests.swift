import XCTest

/// The local calculator in Demo Mode (the real control overlay over a sample
/// desktop): not shown until added from Edit Function Tray, then working in
/// View Only too, keeping its calculation while closed, and closing from its
/// own Close and from its button. Keeps a screenshot of each state for
/// review; run per device and orientation.
final class LocalCalculatorTourTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCalculatorTourPortrait() {
        XCUIDevice.shared.orientation = .portrait
        tour(prefix: "portrait")
    }

    @MainActor
    func testCalculatorTourLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        tour(prefix: "landscape")
    }

    @MainActor
    private func tour(prefix: String) {
        enterDemo()
        revealControls(element("Settings"))
        XCTAssertFalse(calculatorButton.exists, "not shown until added")
        snapshot("\(prefix)-01-not-added")

        addCalculatorFromFunctionTrayEditor()
        revealControls(calculatorButton)
        XCTAssertTrue(calculatorButton.waitForExistence(timeout: 5), "added from Edit Function Tray")
        snapshot("\(prefix)-02-button")

        calculatorButton.tap()
        let result = element("Result")
        XCTAssertTrue(result.waitForExistence(timeout: 3), "the panel opens")
        for label in ["Decimal Point", "1", "Plus", "Decimal Point", "2", "Equals"] { calculatorKey(label).tap() }
        XCTAssertEqual(result.value as? String, "0.3", "exact decimals")
        snapshot("\(prefix)-03-open-0.1+0.2")

        for label in ["All Clear", "2", "Plus", "3", "Multiply", "4", "Equals"] { calculatorKey(label).tap() }
        XCTAssertEqual(result.value as? String, "14", "precedence")
        calculatorKey("Copy Result").tap()
        snapshot("\(prefix)-04-copied")

        // View Only: the trays give way to the gear, the calculator stays.
        let input = element("Control (Demo)")
        XCTAssertTrue(input.exists)
        input.tap()
        sleep(1)
        XCTAssertEqual(input.value as? String, "Off")
        XCTAssertTrue(calculatorButton.exists, "independent of input grants")
        for label in ["All Clear", "5", "0", "Plus", "1", "0", "Percent", "Equals"] { calculatorKey(label).tap() }
        XCTAssertEqual(result.value as? String, "55", "percent, in View Only")
        snapshot("\(prefix)-05-view-only")
        input.tap()
        sleep(1)

        calculatorKey("Close Calculator").tap()
        XCTAssertFalse(result.waitForExistence(timeout: 1), "Close closes")
        // Closed, the button fades with Auto-hide like the trays.
        revealControls(calculatorButton)
        calculatorButton.tap()
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        XCTAssertEqual(result.value as? String, "55", "kept while closed")
        calculatorButton.tap()
        sleep(1)
        XCTAssertFalse(result.exists, "its button closes it again")
        snapshot("\(prefix)-06-closed")

        app.buttons["Exit Demo"].tap()
    }

    // MARK: Helpers

    @MainActor
    private var calculatorButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == 'Calculator'")).firstMatch
    }

    @MainActor
    private func calculatorKey(_ label: String) -> XCUIElement {
        app.buttons[label].firstMatch
    }

    /// Auto-hide (on by default) fades the controls; any touch on the
    /// surface brings them back.
    @MainActor
    private func revealControls(_ target: XCUIElement) {
        if target.exists && target.isHittable { return }
        element("Sample Mac desktop").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        _ = target.waitForExistence(timeout: 2)
        sleep(1)
    }

    @MainActor
    private func addCalculatorFromFunctionTrayEditor() {
        revealControls(element("Settings"))
        element("Settings").tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        if !app.navigationBars["Controls"].exists {
            let controls = app.buttons["Controls"].firstMatch
            reveal(controls)
            XCTAssertTrue(controls.waitForExistence(timeout: 5))
            controls.tap()
            XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 3))
        }
        let edit = app.buttons["Edit Function Tray"].firstMatch
        reveal(edit)
        XCTAssertTrue(edit.isHittable)
        edit.tap()
        let toggle = app.switches.matching(NSPredicate(format: "label BEGINSWITH 'Calculator'")).firstMatch
        reveal(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        snapshot("function-tray-editor-utilities")
        // The switch itself, not the label or a screen coordinate.
        let control = toggle.switches.firstMatch
        (control.exists ? control : toggle).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        // Back out of the pushed pages (Edit Function Tray, then Controls), then close Settings.
        // The system Back button is found by its identifier: on current iOS it isn't a child of
        // the navigation bar's element (see DemoModeSmokeTests).
        for _ in 0..<4 where !app.buttons["Exit Demo"].isHittable {
            let done = app.buttons["Done"].firstMatch
            let back = app.buttons["BackButton"].firstMatch
            if done.exists && done.isHittable {
                done.tap()
            } else if back.exists {
                back.tap()
            } else {
                XCTFail("Neither Done nor Back is available to leave Settings")
                break
            }
            sleep(1)
        }
        XCTAssertTrue(app.buttons["Exit Demo"].waitForExistence(timeout: 5), "back on the stream")
    }

    @MainActor
    private func enterDemo() {
        app = XCUIApplication()
        app.launch()
        sleep(2)
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        sleep(1)
        let explore = app.buttons["exploreDemo"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        let column = app.scrollViews.containing(.button, identifier: "exploreDemo").firstMatch
        for _ in 0..<4 where !explore.isHittable {
            (column.exists ? column : app).swipeUp(velocity: .slow)
        }
        sleep(1)
        explore.tap()
        XCTAssertTrue(app.buttons["Exit Demo"].waitForExistence(timeout: 5))
        sleep(1)
    }

    /// Scrolls a Settings form until a row is on screen, with short, slow
    /// upward drags (a downward drag at the top of a sheet dismisses it).
    @MainActor
    private func reveal(_ target: XCUIElement) {
        // The demo footer covers the bottom of Settings.
        let usableBottom = app.frame.maxY - 60
        func visible() -> Bool { target.exists && target.isHittable && target.frame.maxY < usableBottom }
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
    private func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any)[label].firstMatch
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        sleep(1)
    }
}
