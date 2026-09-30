import XCTest

/// Captures App Store screenshots of the real receiver UI. Each screenshot is
/// kept as a named XCTest attachment in the result bundle; extract them with
/// `xcrun xcresulttool export attachments`.
///
/// Test methods run in name order on one simulator, so app state (the
/// dismissed Welcome sheet, the created Custom layout) carries over between
/// them. Every step tolerates either state so a single test can also run alone.
@MainActor
final class AppStoreScreenshotTests: XCTestCase {
    private let timeout: TimeInterval = 15
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    // MARK: - iPad (landscape)

    func testIPad01Home() throws {
        try launch(on: .pad, orientation: .landscapeLeft)
        capture("ipad-01-home")
    }

    func testIPad02Settings() throws {
        try launch(on: .pad, orientation: .landscapeLeft)
        openSettings()
        tapElement(labeled: "Input")
        waitForNavigationTitle("Input")
        capture("ipad-02-settings")
    }

    func testIPad03CustomKeymapping() throws {
        try launch(on: .pad, orientation: .landscapeLeft)
        openSettings()
        tapElement(labeled: "Controls")
        waitForNavigationTitle("Controls")

        let layoutRow = element(labeled: "Custom Layout 1")
        if !layoutRow.waitForExistence(timeout: 2) {
            // Control Layout is a segmented Picker: its segments (Strip,
            // Overlay, Custom) are buttons inside a segmented control.
            let custom = app.segmentedControls
                .containing(NSPredicate(format: "label == %@", "Strip"))
                .buttons["Custom"]
            XCTAssertTrue(custom.waitForExistence(timeout: timeout), "Control Layout Custom segment not found")
            scrollUntilHittable(custom)
            custom.tap()
            XCTAssertTrue(layoutRow.waitForExistence(timeout: timeout), "Custom Layout 1 not created")
        }
        scrollUntilHittable(layoutRow)
        layoutRow.tap()

        tapElement(labeled: "Edit Layout")
        let gotIt = app.buttons["Got It"]
        if gotIt.waitForExistence(timeout: 5) {
            gotIt.tap()
            XCTAssertTrue(gotIt.waitForNonExistence(timeout: timeout))
        }
        XCTAssertTrue(app.buttons["Add Control"].waitForExistence(timeout: timeout), "Layout editor did not open")
        settle()
        capture("ipad-03-custom-keymapping")
    }

    // MARK: - iPhone (portrait)

    func testIPhone01Home() throws {
        try launch(on: .phone, orientation: .portrait)
        capture("iphone-01-home")
    }

    func testIPhone02Settings() throws {
        try launch(on: .phone, orientation: .portrait)
        openSettings()
        tapElement(labeled: "Input")
        waitForNavigationTitle("Input")
        capture("iphone-02-settings")
    }

    // MARK: - Steps

    /// Skips on the other device family, so one run per destination
    /// captures only that family's screenshots.
    private func launch(on idiom: UIUserInterfaceIdiom, orientation: UIDeviceOrientation) throws {
        guard UIDevice.current.userInterfaceIdiom == idiom else {
            throw XCTSkip("Screenshot for another device family")
        }
        XCUIDevice.shared.orientation = orientation
        app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = orientation

        // First launch shows the real Welcome / "One more app to go" sheet.
        let close = app.buttons["Close"]
        if app.staticTexts["One more app to go"].waitForExistence(timeout: 5), close.exists {
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: timeout), "Welcome sheet did not dismiss")
        }
        XCTAssertTrue(app.buttons["Settings & Help"].waitForExistence(timeout: timeout), "Home screen not shown")
        settle()
    }

    private func openSettings() {
        app.buttons["Settings & Help"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: timeout), "Settings did not open")
    }

    // MARK: - Helpers

    private func element(labeled label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND (elementType == %d OR elementType == %d)",
                                  label, XCUIElement.ElementType.button.rawValue,
                                  XCUIElement.ElementType.cell.rawValue))
            .firstMatch
    }

    private func tapElement(labeled label: String) {
        let target = element(labeled: label)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "\(label) not found")
        scrollUntilHittable(target)
        target.tap()
    }

    private func waitForNavigationTitle(_ title: String) {
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: timeout), "\(title) page not shown")
        settle()
    }

    private func scrollUntilHittable(_ target: XCUIElement) {
        XCTAssertTrue(target.waitForExistence(timeout: timeout))
        var attempts = 0
        while !target.isHittable && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
    }

    /// Lets transitions, sheet animations and scroll indicators finish.
    private func settle() {
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 2)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
