import XCTest

// MARK: - Stage Peek's All Apps

/// In `DemoModeSmokeTests` so the hosted iPhone Duo job runs it.
extension DemoModeSmokeTests {
    /// Demo Window view with Stage Peek (`-demoStagePeek`: the sample Mac lists its apps; nothing
    /// is sent anywhere). All Apps, opened from the last icon of the apps bar's grid, takes the
    /// peek's place: the grid, the peek's search and buttons, the Window view toolbar and the
    /// receiver's controls are neither visible to accessibility nor hittable while it's open, and
    /// Close goes back to the peek as it was. Three times over.
    @MainActor
    func testStagePeekAllAppsFromTheGridsLastIconCoversThePeekAndGoesBack() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-demoStagePeek"]
        app.launch()
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        allAppsWaitUntilGone(app.buttons["Close"])
        sleep(1)
        let explore = app.buttons["exploreDemo"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        for _ in 0..<4 where !explore.isHittable { app.swipeUp(velocity: .slow) }
        sleep(1)
        explore.tap()
        let toggle = app.buttons["demoWindowViewToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8))
        toggle.tap()

        // The seam opens Stage Peek as VoiceOver's activate does (the hold on its strip is
        // timing-sensitive on a loaded CI simulator, and isn't what this test is about).
        let peekClose = app.buttons["stagePeekClose"]
        XCTAssertTrue(peekClose.waitForExistence(timeout: 10), "Stage Peek open over the demo's Window view")

        // Grow the apps bar into its grid, all rows, so All Apps is the grid's last icon.
        let handle = app.descendants(matching: .any)["stagePeekDockHandle"]
        XCTAssertTrue(handle.waitForExistence(timeout: 5))
        for _ in 0..<5 where handle.label != "Show One Row of Apps" {
            handle.tap()
            sleep(1)
        }
        let dockApps = app.descendants(matching: .any).matching(identifier: "stagePeekDockApp")
        XCTAssertTrue(dockApps.firstMatch.waitForExistence(timeout: 8), "the sample Mac's apps fill the bar")
        let lastIcon = app.buttons["stagePeekLaunchpad"]
        for _ in 0..<4 where !lastIcon.isHittable { dockApps.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertTrue(lastIcon.isHittable, "All Apps, the grid's last icon")
        allAppsSnapshot(app, "all-apps-0-grid")

        let allApps = app.descendants(matching: .any)["stagePeekAllApps"]
        let close = app.buttons["stagePeekAllAppsClose"]
        let underneath = ["stagePeekDockApp", "stagePeekDockHandle", "stagePeekLaunchpad", "stagePeekExpand", "stagePeekClose",
                          "stagePeekStrip", "galleryWindowCard", "demoShowDesktop", "demoOpenFloating", "demoAddPane"]
        for round in 1...3 {
            lastIcon.tap()
            XCTAssertTrue(allApps.waitForExistence(timeout: 5), "round \(round): All Apps opens")
            XCTAssertTrue(close.waitForExistence(timeout: 3) && close.isHittable, "round \(round): its Close")
            let items = app.buttons.matching(identifier: "stagePeekAllAppsItem")
            XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5), "round \(round): its own grid")
            XCTAssertGreaterThanOrEqual(app.buttons.matching(NSPredicate(format: "identifier == 'stagePeekAllAppsItem' AND label == 'Notes'")).count, 2,
                                        "two different apps called Notes both show")

            for id in underneath {
                let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
                XCTAssertFalse(element.exists && element.isHittable, "round \(round): \(id) is reachable under All Apps")
            }
            for label in ["Exit Demo", "Control (Demo)", "Settings"] {
                let control = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
                XCTAssertFalse(control.exists && control.isHittable, "round \(round): the receiver's \(label) is reachable under All Apps")
            }
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "stagePeekSearch").count, 1,
                           "round \(round): one search field, All Apps' own")
            if round == 1 { allAppsSnapshot(app, "all-apps-1-open") }

            close.tap()
            allAppsWaitUntilGone(allApps)
            XCTAssertFalse(allApps.exists, "round \(round): Close goes back")
            XCTAssertTrue(peekClose.waitForExistence(timeout: 3) && peekClose.isHittable, "round \(round): back on the peek")
            XCTAssertTrue(lastIcon.waitForExistence(timeout: 3) && lastIcon.isHittable, "round \(round): the grid as it was")
            XCTAssertEqual(handle.label, "Show One Row of Apps", "round \(round): still all rows")
        }
        allAppsSnapshot(app, "all-apps-2-back")
        peekClose.tap()
        allAppsWaitUntilGone(peekClose)
    }

    private func allAppsWaitUntilGone(_ element: XCUIElement) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: 5)
    }

    @MainActor
    private func allAppsSnapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
