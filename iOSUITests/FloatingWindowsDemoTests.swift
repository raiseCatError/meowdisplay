import XCTest

/// Floating windows in Demo Mode's Window view (sample Mac on the device, nothing sent):
/// float a pane, move it, fling it into the edge and back, resize it from a corner, check that
/// a touch where it overlaps a pane reaches the float only, and dock it back into the layout.
final class FloatingWindowsDemoTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFloatMoveTuckRestoreResizeAndDockInDemoWindowView() {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        let explore = app.buttons["exploreDemo"]
        XCTAssertTrue(explore.waitForExistence(timeout: 8))
        for _ in 0..<4 where !explore.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(waitUntil(explore, "isHittable == true"))
        explore.tap()

        let toggle = app.buttons["demoWindowViewToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.tap()
        let panes = app.descendants(matching: .any).matching(identifier: "workspacePane")
        XCTAssertTrue(waitUntil(panes.firstMatch, "exists == true"))
        XCTAssertGreaterThanOrEqual(panes.count, 2, "the demo starts with two panes")
        attach(app, "01-window-view")

        // Open the next sample window floating (the toolbar stands in for Stage Peek's menu item).
        app.buttons["demoOpenFloating"].tap()
        let float = app.descendants(matching: .any).matching(identifier: "workspaceFloat").firstMatch
        XCTAssertTrue(float.waitForExistence(timeout: 5))
        attach(app, "02-float-open")

        // A touch where the float overlaps a pane reaches the float's window (Terminal), not the pane's.
        let floatFrame = float.frame
        let picture = app.descendants(matching: .any)["demoWindowPicture"]
        XCTAssertTrue(picture.exists)
        XCTAssertTrue(waitFor { (picture.value as? String)?.hasPrefix("3 ") == true }, "the sample Mac draws the float: \(String(describing: picture.value))")
        let inside = CGVector(dx: (floatFrame.midX - picture.frame.minX) / picture.frame.width,
                              dy: (floatFrame.midY + floatFrame.height * 0.25 - picture.frame.minY) / picture.frame.height)
        picture.coordinate(withNormalizedOffset: inside).tap()
        XCTAssertTrue(waitUntil(app.staticTexts["demoLastTouched"], "label CONTAINS 'Terminal'"),
                      app.staticTexts["demoLastTouched"].label)

        // Move it by its title pill: a slow drag that stays where it's let go.
        let options = app.buttons["floatOptions"].firstMatch
        XCTAssertTrue(options.exists)
        let pill = options.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: -40, dy: 0))
        let before = float.frame
        pill.press(forDuration: 0.05, thenDragTo: pill.withOffset(CGVector(dx: -120, dy: 60)), withVelocity: 150, thenHoldForDuration: 0.3)
        XCTAssertTrue(waitFor { float.frame.minX < before.minX - 60 }, "moved left: \(float.frame) from \(before)")
        attach(app, "03-moved")

        // Fling it at the right edge: it tucks, leaving a handle; the handle brings it back.
        let pill2 = app.buttons["floatOptions"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: -40, dy: 0))
        let width = app.windows.firstMatch.frame.width
        pill2.press(forDuration: 0.05, thenDragTo: pill2.withOffset(CGVector(dx: width * 0.45, dy: 0)), withVelocity: 3000, thenHoldForDuration: 0)
        let handle = app.descendants(matching: .any).matching(identifier: "floatTuckHandle").firstMatch
        XCTAssertTrue(handle.waitForExistence(timeout: 5), "a tucked float leaves a handle on the edge")
        XCTAssertTrue(waitUntil(float, "exists == false"), "tucked: not shown")
        XCTAssertGreaterThan(handle.frame.midX, width * 0.8, "on the right edge")
        attach(app, "04-tucked")
        handle.tap()
        XCTAssertTrue(float.waitForExistence(timeout: 5), "restored")
        XCTAssertTrue(waitUntil(handle, "exists == false"))
        attach(app, "05-restored")

        // Resize from the lower-left grip: the float gets smaller and keeps the window's shape.
        let start = float.frame
        let corner = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: start.minX - 6, dy: start.maxY + 6))
        corner.press(forDuration: 0.05, thenDragTo: corner.withOffset(CGVector(dx: 90, dy: -56)), withVelocity: 300, thenHoldForDuration: 0.2)
        XCTAssertTrue(waitFor { float.frame.width < start.width - 40 }, "smaller: \(float.frame) from \(start)")
        let resized = float.frame
        XCTAssertEqual(resized.width / resized.height, start.width / start.height, accuracy: 0.05, "same shape")
        attach(app, "06-resized")

        // Options → Add to Layout: back into the arrangement as a pane; nothing floats.
        app.buttons["floatOptions"].firstMatch.tap()
        let add = app.buttons["Add to Layout"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(waitUntil(float, "exists == false"))
        XCTAssertTrue(waitUntil(panes.element(boundBy: 2), "exists == true"), "three panes now")
        attach(app, "07-docked")
    }

    /// A pane's own menu floats it (same window, the layout closes up); double-tapping the
    /// float's title shows it alone on the device, and Exit Fullscreen puts it back exactly.
    @MainActor
    func testFloatThisPaneAndLocalFullscreenRestoresItsFrame() {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        let explore = app.buttons["exploreDemo"]
        XCTAssertTrue(explore.waitForExistence(timeout: 8))
        for _ in 0..<4 where !explore.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(waitUntil(explore, "isHittable == true"))
        explore.tap()
        let toggle = app.buttons["demoWindowViewToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.tap()
        let panes = app.descendants(matching: .any).matching(identifier: "workspacePane")
        XCTAssertTrue(waitFor { panes.count == 2 })

        // Hold a pane's title (its first label, at the pane's top-left), release: its menu. Float This Pane.
        let first = (0..<panes.count).map { panes.element(boundBy: $0) }.min { $0.frame.minY + $0.frame.minX < $1.frame.minY + $1.frame.minX }!
        let title = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: first.frame.minX + 48, dy: first.frame.minY + 19))
        title.press(forDuration: 0.7)
        let floatRow = app.buttons["Float This Pane"]
        XCTAssertTrue(floatRow.waitForExistence(timeout: 5))
        attach(app, "11-pane-menu")
        floatRow.tap()
        let float = app.descendants(matching: .any).matching(identifier: "workspaceFloat").firstMatch
        XCTAssertTrue(float.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor { panes.count == 1 }, "the layout closed up around it")
        XCTAssertFalse(float.label.isEmpty)
        attach(app, "12-floated-pane")

        // Double-tap its title: Fullscreen on This Device; Exit Fullscreen brings back the same frame.
        let before = float.frame
        let pill = app.buttons["floatOptions"].firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: -40, dy: 0))
        pill.doubleTap()
        let strip = app.descendants(matching: .any)["fullscreenStrip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 5), "fullscreen")
        XCTAssertFalse(float.exists)
        attach(app, "13-fullscreen")
        app.buttons["Exit Fullscreen"].firstMatch.tap()
        XCTAssertTrue(float.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor { abs(float.frame.minX - before.minX) < 2 && abs(float.frame.width - before.width) < 2 },
                      "\(float.frame) vs \(before)")
        attach(app, "14-back-floating")
    }

    /// Polls a condition on the UI until it holds or `timeout` passes.
    @MainActor
    private func waitFor(timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return condition()
    }

    /// Waits for a predicate on an element (no fixed sleeps).
    @MainActor
    private func waitUntil(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 5) -> Bool {
        let done = expectation(for: NSPredicate(format: format), evaluatedWith: element)
        return XCTWaiter().wait(for: [done], timeout: timeout) == .completed
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
