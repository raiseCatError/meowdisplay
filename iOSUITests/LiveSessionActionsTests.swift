import XCTest

/// Session Actions (touch and hold Settings) against a real paired Mac on a physical device.
/// Opt-in: skips unless MEOW_LIVE_SESSION_TESTS=1 (pass TEST_RUNNER_MEOW_LIVE_SESSION_TESTS=1 to
/// xcodebuild). It connects, opens the overlay and cancels, goes Back to Home and resumes, then
/// disconnects from the overlay and checks the session stays ended. Nothing is clicked or typed
/// on the Mac.
final class LiveSessionActionsTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    @MainActor
    func testHoldSettingsCancelHomeResumeAndDisconnect() throws {
        guard env["MEOW_LIVE_SESSION_TESTS"] == "1" else {
            throw XCTSkip("live session test: set MEOW_LIVE_SESSION_TESTS=1 with a paired Mac nearby")
        }
        let app = XCUIApplication()
        app.launch()
        let surface = app.descendants(matching: .any)["Mac screen"].firstMatch
        try connect(app, surface: surface)
        let overlay = app.descendants(matching: .any)["sessionActionsOverlay"].firstMatch
        let resume = app.buttons["resumeSession"]

        // Hold → overlay → Cancel: the same session, nothing else changes.
        try openSessionActions(app, overlay: overlay)
        XCTAssertTrue(app.buttons["sessionActionsDisconnect"].exists)
        XCTAssertTrue(app.buttons["sessionActionsHome"].exists)
        XCTAssertTrue(app.buttons["sessionActionsCancel"].exists)
        snapshot(app, "actions-01-open")
        app.buttons["sessionActionsCancel"].tap()
        XCTAssertTrue(waitUntil(3) { !overlay.exists }, "Cancel closes the overlay")
        XCTAssertTrue(surface.exists, "still in the session")
        XCTAssertFalse(resume.exists, "not on Home")
        XCTAssertFalse(app.buttons["Reconnect"].exists)
        snapshot(app, "actions-02-cancelled")

        // Hold → Back to Home → Resume.
        try openSessionActions(app, overlay: overlay)
        app.buttons["sessionActionsHome"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "Home shows the kept session's card")
        XCTAssertFalse(overlay.exists)
        snapshot(app, "actions-03-home")
        resume.tap()
        // Window view lays its panes over the surface, so check the card, not hit-testing.
        XCTAssertTrue(waitUntil(5) { !resume.exists && surface.exists }, "Resume returns to the session")
        XCTAssertFalse(app.buttons["Reconnect"].exists, "the same session, not a new connection")
        sleep(2)

        // Hold → Disconnect from Mac: the session ends and stays ended.
        try openSessionActions(app, overlay: overlay)
        app.buttons["sessionActionsDisconnect"].tap()
        XCTAssertTrue(waitUntil(8) { !overlay.exists && !surface.exists }, "the session ends")
        let until = Date().addingTimeInterval(10)
        while Date() < until {
            XCTAssertFalse(surface.exists, "a deliberate disconnect doesn't reconnect by itself")
            XCTAssertFalse(resume.exists)
            sleep(1)
        }
        snapshot(app, "actions-04-disconnected")
    }

    /// Lock Mac in Session Actions: opens its confirmation and cancels. Never confirms, so the
    /// Mac is never locked and no control request is sent. Skips when the Mac can't lock.
    @MainActor
    func testLockMacRowOpensConfirmationAndCancelsWithoutLocking() throws {
        guard env["MEOW_LIVE_SESSION_TESTS"] == "1" else {
            throw XCTSkip("live session test: set MEOW_LIVE_SESSION_TESTS=1 with a paired Mac nearby")
        }
        let app = XCUIApplication()
        app.launch()
        let surface = app.descendants(matching: .any)["Mac screen"].firstMatch
        try connect(app, surface: surface)
        let overlay = app.descendants(matching: .any)["sessionActionsOverlay"].firstMatch
        try openSessionActions(app, overlay: overlay)
        let lock = app.buttons["sessionActionsLockMac"]
        guard lock.waitForExistence(timeout: 3) else {
            app.buttons["sessionActionsCancel"].tap()
            throw XCTSkip("this Mac doesn't offer Lock This Mac")
        }
        XCTAssertTrue(app.buttons["sessionActionsDisconnect"].exists, "Disconnect stays")
        XCTAssertTrue(app.buttons["sessionActionsCancel"].exists, "Cancel stays")

        lock.tap()
        let confirm = app.buttons["lockMacConfirm"]
        let requestAndLock = app.buttons["lockMacRequestControlAndLock"]
        XCTAssertTrue(waitUntil(5) { confirm.exists || requestAndLock.exists },
                      "the confirmation shows over the overlay")
        snapshot(app, "actions-lock-confirmation")
        app.buttons["lockMacCancel"].tap()

        XCTAssertTrue(waitUntil(3) { !confirm.exists && !requestAndLock.exists }, "Cancel closes the confirmation")
        XCTAssertTrue(overlay.exists, "the overlay stays up")
        XCTAssertTrue(lock.isEnabled, "nothing is pending")
        XCTAssertFalse(app.staticTexts["lockMacStatus"].exists, "nothing was sent, so nothing to report")
        app.buttons["sessionActionsCancel"].tap()
        XCTAssertTrue(waitUntil(3) { !overlay.exists })
        XCTAssertTrue(surface.exists, "still in the session")
    }

    @MainActor
    private func openSessionActions(_ app: XCUIApplication, overlay: XCUIElement) throws {
        let settings = app.descendants(matching: .any)["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the Settings control is on screen")
        settings.press(forDuration: 1.0)
        XCTAssertTrue(overlay.waitForExistence(timeout: 3), "touch and hold Settings opens Session Actions")
        XCTAssertFalse(app.buttons["Connections"].exists, "the hold doesn't also open Settings")
    }

    @MainActor
    private func connect(_ app: XCUIApplication, surface: XCUIElement) throws {
        let connect = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Connect to' OR label BEGINSWITH 'Wake and connect to' OR label BEGINSWITH 'Try again with'"
        )).firstMatch
        let reconnect = app.buttons["Reconnect"]
        let tapUntil = Date().addingTimeInterval(12)
        while Date() < tapUntil, !surface.exists {
            if reconnect.exists { reconnect.tap(); break }
            if connect.exists { connect.tap(); break }
            usleep(250_000)
        }
        let deadline = Date().addingTimeInterval(45)
        while !surface.exists, Date() < deadline {
            if app.buttons["windowModePromptNo"].exists { app.buttons["windowModePromptNo"].tap() }
            usleep(250_000)
        }
        guard surface.exists else { snapshot(app, "actions-no-session"); throw XCTSkip("no session with a paired Mac") }
        if app.buttons["windowModePromptNo"].waitForExistence(timeout: 3) { app.buttons["windowModePromptNo"].tap() }
        sleep(2)
    }

    @MainActor
    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            usleep(200_000)
        }
        return condition()
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
