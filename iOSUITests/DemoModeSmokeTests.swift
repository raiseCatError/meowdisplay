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

        let explore = app.buttons["Explore Demo"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        snapshot(app, "01-home")
        explore.tap()

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
            if app.navigationBars[category].buttons.firstMatch.exists,
               UIDevice.current.userInterfaceIdiom == .phone {
                app.navigationBars[category].buttons.firstMatch.tap()
            }
        }
        XCTAssertFalse(app.buttons["Developer"].exists && !isDebug)
        app.buttons["Done"].firstMatch.tap()

        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        exit.tap()
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        XCTAssertFalse(exit.exists)
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
