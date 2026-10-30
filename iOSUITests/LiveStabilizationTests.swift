import XCTest

/// Physical device + the paired Mac (skips without one). Non-destructive: it never chooses a
/// Mac menu item, never clicks or types on the Mac, and puts back what it turns. The Mac's log
/// and the harness's power and Stage Manager samples are the oracle for what the Mac did.
///
/// Environment (pass as TEST_RUNNER_<NAME> to xcodebuild): IDLE_MINUTES (default 2),
/// STAGE_MANAGER_ACTIONS=1 to exercise Turn On / Turn Off in Settings ▸ Input.
final class LiveStabilizationTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    /// Apple's built-in accessibility audit on the home screen and the Demo session (no Mac
    /// involved). Every issue is printed as `AXAUDIT …` for the report; none fails the test.
    @MainActor
    func testAccessibilityAuditHomeAndDemo() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        sleep(2)
        try audit(app, "home")
        let explore = app.buttons["exploreDemo"]
        guard explore.waitForExistence(timeout: 5) else { return }
        let column = app.scrollViews.containing(.button, identifier: "exploreDemo").firstMatch
        for _ in 0..<4 where !explore.isHittable { (column.exists ? column : app).swipeUp(velocity: .slow) }
        sleep(1)
        explore.tap()
        guard app.buttons["Exit Demo"].waitForExistence(timeout: 8) else { return }
        sleep(2)
        try audit(app, "demo-session")
        app.descendants(matching: .any)["Settings"].firstMatch.tap()
        sleep(2)
        try audit(app, "demo-settings")
        let input = app.buttons["Input"].firstMatch
        if input.waitForExistence(timeout: 3) {
            input.tap()
            sleep(1)
            try audit(app, "demo-settings-input")
        }
    }

    @MainActor
    private func audit(_ app: XCUIApplication, _ screen: String) throws {
        snapshot(app, "audit-\(screen)")
        guard #available(iOS 17.0, *) else { print("AXAUDIT needs iOS 17"); return }
        var count = 0
        try app.performAccessibilityAudit(for: .all) { issue in
            count += 1
            let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)' id=\($0.identifier)" } ?? "-"
            print("AXAUDIT screen=\(screen) type=\(issue.auditType.rawValue) element=\(element) :: \(issue.compactDescription)")
            return true
        }
        print("AXAUDIT screen=\(screen) issues=\(count)")
    }

    /// Connect, time the first pane, menus, per-pane rotation, idle, Home and back, Stage Manager.
    @MainActor
    func testLiveWindowModeStabilization() throws {
        let app = XCUIApplication()
        app.launch()
        let reconnect = app.buttons["Reconnect"]
        let connect = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Connect to' OR label BEGINSWITH 'Wake and connect to' OR label BEGINSWITH 'Try again with'")).firstMatch
        let tapped = Date()
        let yes = app.buttons["windowModePromptYes"]
        let pane = app.descendants(matching: .any).matching(identifier: "workspacePane").firstMatch
        // The app reconnects by itself at launch when it was in a session; otherwise tap Connect.
        let started = Date().addingTimeInterval(12)
        var how = "auto-reconnect at launch"
        while Date() < started, !pane.exists {
            if reconnect.exists { reconnect.tap(); how = "Reconnect"; break }
            if connect.exists { connect.tap(); how = "Connect"; break }
            usleep(250_000)
        }
        print("LIVE session start by \(how), timed from launch \(Int(tapped.timeIntervalSince1970 * 1000))")

        let deadline = Date().addingTimeInterval(45)
        while !pane.exists, Date() < deadline {
            if yes.exists { yes.tap() }
            usleep(200_000)
        }
        guard pane.exists else { snapshot(app, "live-no-pane"); throw XCTSkip("no Window-mode pane") }
        print("LIVE first pane element after \(Int(Date().timeIntervalSince(tapped) * 1000)) ms")
        sleep(3)
        snapshot(app, "live-01-window-mode")
        let panes = app.descendants(matching: .any).matching(identifier: "workspacePane").allElementsBoundByIndex
        print("LIVE panes=\(panes.count) labels=\(panes.map(\.label))")

        // Pane menus open from the pane's title chip ("Full Desktop", "Google Chrome", …).
        let titles = panes.map { String($0.label.dropLast(" pane".count)) }
        func chip(_ title: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ AND identifier != 'workspacePane'", title)).firstMatch
        }
        let rotate = app.buttons["Rotate"]
        let firstChip = chip(titles[0])
        firstChip.press(forDuration: 0.7)
        XCTAssertTrue(rotate.waitForExistence(timeout: 5), "the pane menu opens")
        let rows = ["Rotate", "Reset View", "Arrange Panes", "Remove from Layout", "Fill Pane", "Show Whole Window", "Show Whole Desktop",
                    "Fullscreen on This Device", "View Full Screen", "Change Window…", "Show a Window Here…", "Remove This Tab"]
        print("LIVE pane menu '\(titles[0])' rows: \(rows.filter { app.buttons[$0].exists })")
        let firstWasTurned = app.buttons["Reset View"].exists
        snapshot(app, "live-02-pane-menu")
        dismissOverlay(app)
        XCTAssertFalse(rotate.exists, "a tap outside closes the pane menu")

        // App menus (the focused window's menu bar): open one title, read, close. Nothing chosen.
        let menus = app.descendants(matching: .any).matching(NSPredicate(format: "label ENDSWITH ' menus'")).firstMatch
        if menus.waitForExistence(timeout: 3) {
            let bar = menus.buttons.allElementsBoundByIndex
            print("LIVE app menus '\(menus.label)' titles=\(bar.map(\.label))")
            if bar.count > 1 {
                let before = Set(app.buttons.allElementsBoundByIndex.map(\.label))
                bar[1].tap()
                sleep(2)
                snapshot(app, "live-03-app-menu-open")
                let items = app.buttons.allElementsBoundByIndex.map(\.label).filter { !before.contains($0) }
                print("LIVE app menu '\(bar[1].label)' new items: \(items.prefix(30))")
                if let item = items.first { dismissOverlay(app, openIndicator: app.buttons[item]) }
            }
        } else {
            print("LIVE no app menus shown (no focused window with menus, or no control)")
        }

        // Rotation belongs to one pane. Turn a pane that isn't turned yet (the owner's own turned
        // panes are left alone), check the other pane didn't change, then put it back.
        if titles.count > 1 {
            let other = chip(titles[1])
            other.press(forDuration: 0.7)
            if rotate.waitForExistence(timeout: 5), !app.buttons["Reset View"].exists {
                rotate.tap()
                sleep(3)
                snapshot(app, "live-04-second-pane-rotated")
                other.press(forDuration: 0.7)
                XCTAssertTrue(app.buttons["Reset View"].waitForExistence(timeout: 5), "the rotated pane offers Reset View")
                dismissOverlay(app)
                firstChip.press(forDuration: 0.7)
                if rotate.waitForExistence(timeout: 5) {
                    XCTAssertEqual(app.buttons["Reset View"].exists, firstWasTurned, "the other pane is unchanged")
                    print("LIVE first pane Reset View before/after: \(firstWasTurned)/\(app.buttons["Reset View"].exists)")
                }
                dismissOverlay(app)
                other.press(forDuration: 0.7)
                if app.buttons["Reset View"].waitForExistence(timeout: 5) { app.buttons["Reset View"].tap() }
                sleep(2)
                snapshot(app, "live-04b-second-pane-reset")
            } else {
                print("LIVE second pane already turned or no menu: rotation check skipped")
                dismissOverlay(app)
            }
        }

        // Idle: no input at all; look for reconnect or stall banners once a minute.
        let minutes = Int(env["IDLE_MINUTES"] ?? "2") ?? 2
        print("LIVE idle start \(Int(Date().timeIntervalSince1970 * 1000)) for \(minutes) min")
        for minute in 1...max(1, minutes) {
            sleep(60)
            let trouble = app.staticTexts.matching(NSPredicate(format:
                "label CONTAINS[c] 'Reconnecting' OR label CONTAINS[c] 'stopped sending' OR label CONTAINS[c] 'Connection Lost' OR label CONTAINS[c] 'Closed on Mac'"))
            let labels = trouble.allElementsBoundByIndex.map(\.label)
            print("LIVE idle minute \(minute) at \(Int(Date().timeIntervalSince1970 * 1000)): panes=\(app.descendants(matching: .any).matching(identifier: "workspacePane").count) trouble=\(labels)")
            if minute == 1 || minute % 5 == 0 || !labels.isEmpty { snapshot(app, "live-idle-\(minute)") }
        }

        // Home and back: the session pauses and resumes.
        XCUIDevice.shared.press(.home)
        sleep(6)
        let back = Date()
        app.activate()
        let resumeDeadline = Date().addingTimeInterval(30)
        while !pane.exists, Date() < resumeDeadline { usleep(200_000) }
        print("LIVE resumed pane after \(Int(Date().timeIntervalSince(back) * 1000)) ms, exists=\(pane.exists)")
        sleep(4)
        snapshot(app, "live-05-after-home")

        if env["STAGE_MANAGER_ACTIONS"] == "1" { try stageManagerActions(app) }
        print("LIVE done \(Int(Date().timeIntervalSince1970 * 1000))")
    }

    /// One session in MODE (mirror, extend or window) held for HOLD_SECONDS, beside another
    /// device's session in a different mode. Gets into Window mode first (the app reconnects at
    /// launch), then switches inside the session: Full Desktop ▸ View Full Screen (Mirror) or
    /// Show a Window Here… ▸ Extend. Never touches the Mac picture. The Mac's log is the oracle.
    @MainActor
    func testLiveModeSession() throws {
        let mode = env["MODE"] ?? "mirror"
        let hold = UInt32(env["HOLD_SECONDS"] ?? "60") ?? 60
        let app = XCUIApplication()
        app.launch()
        let started = Date()
        let connect = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Connect to' OR label BEGINSWITH 'Wake and connect to' OR label BEGINSWITH 'Try again with'")).firstMatch
        let yes = app.buttons["windowModePromptYes"]
        let desktop = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Full Desktop' AND identifier != 'workspacePane'")).firstMatch
        let end = Date().addingTimeInterval(45)
        while Date() < end, !desktop.exists {
            if connect.exists { connect.tap() }
            if yes.exists { yes.tap() }
            usleep(300_000)
        }
        guard desktop.exists else { snapshot(app, "mode-no-window"); throw XCTSkip("couldn't reach Window mode") }
        print("LIVE MODE window up after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        let switched = Date()
        switch mode {
        case "mirror":
            desktop.press(forDuration: 0.7)
            let full = app.buttons["View Full Screen"]
            guard full.waitForExistence(timeout: 5) else { snapshot(app, "mode-no-fullscreen"); throw XCTSkip("no View Full Screen") }
            full.tap()
        case "extend":
            desktop.press(forDuration: 0.7)
            let show = app.buttons["Show a Window Here…"]
            guard show.waitForExistence(timeout: 5) else { snapshot(app, "mode-no-overview"); throw XCTSkip("no overview") }
            show.tap()
            let extend = app.buttons["Extend"]
            guard extend.waitForExistence(timeout: 8) else { snapshot(app, "mode-no-extend"); throw XCTSkip("no Extend button") }
            extend.tap()
        default:
            break
        }
        if mode != "window" {
            let gone = Date().addingTimeInterval(20)
            while Date() < gone, desktop.exists { usleep(250_000) }
            print("LIVE MODE switched to \(mode): Window panes gone after \(Int(Date().timeIntervalSince(switched) * 1000)) ms (gone=\(!desktop.exists))")
            if app.buttons["windowModePromptNo"].waitForExistence(timeout: 6) { app.buttons["windowModePromptNo"].tap() }
        }
        sleep(5)
        snapshot(app, "mode-\(mode)-start")
        sleep(max(5, hold - 5))
        let trouble = app.staticTexts.matching(NSPredicate(format:
            "label CONTAINS[c] 'Reconnecting' OR label CONTAINS[c] 'stopped sending' OR label CONTAINS[c] 'Connection Lost' OR label CONTAINS[c] 'Disconnected'"))
        print("LIVE MODE \(mode) end \(Int(Date().timeIntervalSince1970 * 1000)): trouble=\(trouble.allElementsBoundByIndex.map(\.label))")
        snapshot(app, "mode-\(mode)-end")
    }

    @MainActor
    private func stageManagerActions(_ app: XCUIApplication) throws {
        let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Settings'")).firstMatch
        guard settings.waitForExistence(timeout: 5) else { print("LIVE SM no settings button"); return }
        settings.tap()
        let input = app.buttons["Input"].firstMatch
        guard input.waitForExistence(timeout: 5) else { print("LIVE SM no Input category"); return }
        input.tap()
        let state = app.descendants(matching: .any)["stageManagerState"].firstMatch
        for _ in 0..<6 where !state.exists { app.swipeUp() }
        guard state.waitForExistence(timeout: 3) else { print("LIVE SM section not shown"); return }
        print("LIVE SM state before: \(state.label) \(state.value as? String ?? "")")
        snapshot(app, "live-06-sm-before")
        let on = app.buttons["stageManagerOn"], off = app.buttons["stageManagerOff"]
        func turnOff() -> Bool {
            guard off.exists, off.isEnabled else { return false }
            off.tap()
            let confirm = app.buttons["Turn Off"]
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
            let ok = on.waitForExistence(timeout: 10)
            print("LIVE SM Turn Off at \(Int(Date().timeIntervalSince1970 * 1000)): reported off=\(ok)")
            return ok
        }
        func turnOn() -> Bool {
            guard on.exists, on.isEnabled else { return false }
            on.tap()
            let ok = off.waitForExistence(timeout: 10)
            print("LIVE SM Turn On at \(Int(Date().timeIntervalSince1970 * 1000)): reported on=\(ok)")
            return ok
        }
        // Round trip, ending where it started. With Stage Manager off, panes of strip windows
        // should go live: watch for 20 s (the Mac log has the oracle).
        if off.exists {
            XCTAssertTrue(turnOff(), "the Mac reports Stage Manager off")
            snapshot(app, "live-07-sm-off")
            app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'Close'")).firstMatch.tap()
            sleep(20)
            snapshot(app, "live-07b-panes-with-sm-off")
            settings.tap(); if input.waitForExistence(timeout: 5) { input.tap() }
            for _ in 0..<6 where !on.exists { app.swipeUp() }
            XCTAssertTrue(turnOn(), "the Mac reports Stage Manager on again")
            snapshot(app, "live-08-sm-on-again")
        } else if on.exists {
            XCTAssertTrue(turnOn(), "the Mac reports Stage Manager on")
            snapshot(app, "live-07-sm-on")
            sleep(5)
            XCTAssertTrue(turnOff(), "the Mac reports Stage Manager off again")
            snapshot(app, "live-08-sm-off-again")
        } else {
            print("LIVE SM no buttons (needs control?)")
        }
    }

    @MainActor
    private func dismissOverlay(_ app: XCUIApplication, openIndicator: XCUIElement? = nil) {
        let indicator = openIndicator ?? app.buttons["Rotate"]
        guard indicator.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)).tap()
        sleep(1)
    }

    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
