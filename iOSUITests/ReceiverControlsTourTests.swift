import XCTest

/// Walks the receiver's touch controls in Demo Mode (the real control
/// overlay over a sample desktop) and keeps a screenshot of each state:
/// the trays, a held ⌘ palette, the keyboard bar, input off and video off.
/// Run per device and orientation to review layout; it asserts only what
/// must hold everywhere.
final class ReceiverControlsTourTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testControlsTourPortrait() {
        XCUIDevice.shared.orientation = .portrait
        tour(prefix: "portrait")
    }

    @MainActor
    func testControlsTourLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        tour(prefix: "landscape")
    }

    /// The tray is drawn and driven by one gesture, but each control must
    /// still be a real button to VoiceOver, Voice Control and Switch Control.
    @MainActor
    func testTrayControlsAreAccessibilityButtons() {
        XCUIDevice.shared.orientation = .portrait
        enterDemo()
        for label in ["Command", "Option", "Control", "Shift", "Escape", "Tab", "Toggle Dock", "Settings", "Return"] {
            XCTAssertTrue(app.buttons[label].firstMatch.exists, "\(label) is not exposed as a button")
        }
        app.buttons["Exit Demo"].tap()
    }

    /// Local pinch-zoom to the 8× cap, then a twist, over the sample
    /// desktop: captured for review, and the controls must stay usable.
    @MainActor
    func testHighMagnificationTour() {
        XCUIDevice.shared.orientation = .portrait
        enterDemo()
        let desktop = element("Sample Mac desktop")
        XCTAssertTrue(desktop.waitForExistence(timeout: 3))
        for _ in 0..<3 {
            desktop.pinch(withScale: 2.2, velocity: 2)
            sleep(1)
        }
        snapshot("zoom-01-eight-times")
        desktop.rotate(.pi / 7, withVelocity: 1)
        sleep(1)
        snapshot("zoom-02-eight-times-rotated")
        // One finger pans only under Move View (the iPad radial layout's).
        let moveView = element("Move View")
        if moveView.exists, moveView.isHittable {
            moveView.tap()
            for _ in 0..<4 { desktop.swipeLeft(velocity: .fast); desktop.swipeUp(velocity: .fast) }
            sleep(1)
            snapshot("zoom-03-extreme-pan")
            moveView.tap()
        }
        XCTAssertTrue(element("Settings").exists, "Settings stays reachable while zoomed")
        app.buttons["Exit Demo"].tap()
    }

    /// Return reaches the (sample) Mac from the Function Tray with the
    /// keyboard closed, and from the keyboard bar with it open.
    @MainActor
    func testReturnSendsAPressWithKeyboardClosedAndOpen() {
        XCUIDevice.shared.orientation = .portrait
        enterDemo()
        let sent = NSPredicate(format: "label BEGINSWITH 'Return' OR label == 'New line'")
        let trayReturn = app.buttons["Return"].firstMatch
        XCTAssertTrue(trayReturn.waitForExistence(timeout: 3))
        revealControls(trayReturn)
        trayReturn.tap()
        XCTAssertTrue(app.staticTexts.matching(sent).firstMatch.waitForExistence(timeout: 3),
                      "Function Tray Return sent nothing")

        let keyboard = element("Keyboard")
        if keyboard.exists {
            revealControls(keyboard)
            keyboard.tap()
            sleep(2)
            if app.buttons["Continue"].exists { app.buttons["Continue"].tap(); sleep(1) }
            // Not the software keyboard's own return key.
            let keys = app.keyboards.firstMatch.frame
            let barReturn = app.buttons.matching(identifier: "Return").allElementsBoundByIndex
                .first { !keys.intersects($0.frame) }
            XCTAssertNotNil(barReturn, "keyboard bar has no Return")
            barReturn?.tap()
            XCTAssertTrue(app.staticTexts["New line"].firstMatch.waitForExistence(timeout: 3),
                          "keyboard bar Return sent nothing")
            let hide = element("Hide Keyboard")
            if hide.waitForExistence(timeout: 3) { hide.tap() }
        }
        app.buttons["Exit Demo"].tap()
    }

    @MainActor
    private func tour(prefix: String) {
        enterDemo()
        snapshot("\(prefix)-01-surface")

        // Hold ⌘ until its palette opens, capture, then slide off and lift.
        let command = element("Command")
        XCTAssertTrue(command.waitForExistence(timeout: 3))
        revealControls(command)
        let start = command.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 1.2)
        // A press that became a hold leaves nothing latched.
        XCTAssertEqual(command.value as? String, "Off")

        // Tap ⌘ to latch it: the palette stays up for browsing.
        command.tap()
        XCTAssertEqual(command.value as? String, "On")
        sleep(1)
        snapshot("\(prefix)-02-command-latched-palette")
        command.tap()
        XCTAssertEqual(command.value as? String, "Off")

        // Keyboard bar.
        let keyboard = element("Keyboard")
        if keyboard.exists {
            revealControls(keyboard)
            keyboard.tap()
            sleep(2)
            // A fresh simulator shows the one-time slide-to-type intro.
            if app.buttons["Continue"].exists { app.buttons["Continue"].tap(); sleep(1) }
            snapshot("\(prefix)-03-keyboard-bar")
            let hide = element("Hide Keyboard")
            if hide.waitForExistence(timeout: 3) { hide.tap() }
            sleep(1)
        }

        // View Only: the trays give way to the gear.
        let input = element("Control (Demo)")
        XCTAssertTrue(input.exists)
        input.tap()
        sleep(1)
        element("Sample Mac desktop").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        snapshot("\(prefix)-04-input-off")
        XCTAssertTrue(element("Settings").exists, "Settings stays reachable in View Only")
        input.tap()
        sleep(1)

        app.buttons["Exit Demo"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["exploreDemo"].firstMatch.waitForExistence(timeout: 5))
    }

    // MARK: Helpers

    @MainActor
    private func enterDemo() {
        app = XCUIApplication()
        app.launch()
        sleep(2)
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        sleep(1)
        let explore = app.descendants(matching: .any)["exploreDemo"].firstMatch
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        // The demo button can sit below the fold in iPhone landscape.
        for _ in 0..<4 where !explore.isHittable {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        sleep(1)
        explore.tap()
        XCTAssertTrue(app.buttons["Exit Demo"].waitForExistence(timeout: 5))
        sleep(1)
    }

    private func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any)[label].firstMatch
    }

    /// Auto-hide fades the trays after a while; a touch on the desktop
    /// brings them back.
    @MainActor
    private func revealControls(_ control: XCUIElement) {
        guard !control.isHittable else { return }
        element("Sample Mac desktop").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).tap()
        sleep(1)
    }

    @MainActor
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        // Landscape XCUITest captures come out rotated; the tour script
        // takes a `simctl io screenshot` when it sees this marker.
        print("TOURSHOT \(name)")
        sleep(3)
    }
}
