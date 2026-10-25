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
        for label in ["Command", "Option", "Control", "Shift", "Escape", "Tab", "Toggle Dock", "Settings"] {
            XCTAssertTrue(app.buttons[label].firstMatch.exists, "\(label) is not exposed as a button")
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

        // Input off: the trays give way to the gear.
        let input = element("Allow Input (Demo)")
        XCTAssertTrue(input.exists)
        input.tap()
        sleep(1)
        element("Sample Mac desktop").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(1)
        snapshot("\(prefix)-04-input-off")
        XCTAssertTrue(element("Settings").exists, "Settings stays reachable with input off")
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
        // Explore Demo can sit below the fold in iPhone landscape.
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
