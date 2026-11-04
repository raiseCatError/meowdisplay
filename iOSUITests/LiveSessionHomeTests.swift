import XCTest

/// Back to Home — Keep Connected (#121) against a real paired Mac on a physical device. Opt-in:
/// skips unless MEOW_LIVE_SESSION_TESTS=1 (pass TEST_RUNNER_MEOW_LIVE_SESSION_TESTS=1 to
/// xcodebuild). It connects, goes Home keeping the session, waits, resumes the same session,
/// then goes Home again and disconnects. Nothing is clicked or typed on the Mac.
///
/// Environment: HOME_WAIT_SECONDS (default 20), how long to stay on Home before Resume.
final class LiveSessionHomeTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    @MainActor
    func testHomeKeepsTheSessionResumeReturnsAndDisconnectEndsIt() throws {
        guard env["MEOW_LIVE_SESSION_TESTS"] == "1" else {
            throw XCTSkip("live session test: set MEOW_LIVE_SESSION_TESTS=1 with a paired Mac nearby")
        }
        let app = XCUIApplication()
        app.launch()
        let surface = app.descendants(matching: .any)["Mac screen"].firstMatch
        try connect(app, surface: surface)
        snapshot(app, "home-01-session")

        // Settings ▸ Connections ▸ Back to Home — Keep Connected.
        try goHomeKeepingSession(app)
        let resume = app.buttons["resumeSession"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5), "Home shows the kept session's card")
        XCTAssertTrue(app.buttons["homeDisconnect"].exists)
        XCTAssertFalse(surface.exists && surface.isHittable, "the session surface is hidden under Home")
        XCTAssertFalse(app.buttons["exploreDemo"].exists, "no demo while a session is kept")
        snapshot(app, "home-02-kept")

        let wait = TimeInterval(env["HOME_WAIT_SECONDS"].flatMap(Double.init) ?? 20)
        let until = Date().addingTimeInterval(wait)
        while Date() < until {
            XCTAssertTrue(resume.exists, "the session stays kept while on Home")
            sleep(2)
        }
        snapshot(app, "home-03-after-wait")

        resume.tap()
        // Window view lays its panes over the surface, so "hittable" isn't a
        // reliable signal; the card going and the surface being exposed again is.
        XCTAssertTrue(waitUntil(5) { !resume.exists && surface.exists }, "Resume returns to the session")
        XCTAssertFalse(resume.exists)
        XCTAssertFalse(app.buttons["Reconnect"].exists, "the same session, not a new connection")
        XCTAssertFalse(app.staticTexts["Reconnecting…"].exists)
        sleep(3)
        snapshot(app, "home-04-resumed")

        // Home again, then Disconnect: the session ends and stays ended.
        try goHomeKeepingSession(app)
        let disconnect = app.buttons["homeDisconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        disconnect.tap()
        XCTAssertTrue(waitUntil(8) { !resume.exists }, "the card goes with the session")
        sleep(5)
        XCTAssertFalse(resume.exists, "a disconnected session doesn't come back by itself")
        XCTAssertFalse(surface.exists && surface.isHittable, "Home, not the session surface")
        snapshot(app, "home-05-disconnected")
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
        guard surface.exists else { snapshot(app, "home-no-session"); throw XCTSkip("no session with a paired Mac") }
        if app.buttons["windowModePromptNo"].waitForExistence(timeout: 3) { app.buttons["windowModePromptNo"].tap() }
        sleep(2)
    }

    @MainActor
    private func goHomeKeepingSession(_ app: XCUIApplication) throws {
        app.descendants(matching: .any)["Settings"].firstMatch.tap()
        let connections = app.buttons["Connections"].firstMatch
        XCTAssertTrue(connections.waitForExistence(timeout: 5), "Settings opens")
        connections.tap()
        let keep = app.buttons["homeKeepConnected"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5), "offered while a session is on screen")
        keep.tap()
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
