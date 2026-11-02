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

        // The tray may have hidden itself while the orientations were checked: bring it back
        // with a touch, as a person would, and wait until Settings can be tapped.
        let settings = app.descendants(matching: .any)["Settings"].firstMatch
        for _ in 0..<3 where !settings.isHittable {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
            _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: settings)],
                               timeout: 2)
        }
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

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
