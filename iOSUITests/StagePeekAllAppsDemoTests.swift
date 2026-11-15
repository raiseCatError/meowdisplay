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
        // Every leftover under All Apps in one run, not one per run.
        continueAfterFailure = true
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
        // On a small screen even all rows scroll: swipe the grid itself (an icon scrolls away).
        // Reached = its centre inside the grid's visible frame; the tap below goes to that point,
        // so All Apps opening proves the touch got there.
        let grid = app.scrollViews.containing(.button, identifier: "stagePeekLaunchpad").firstMatch
        let reached = { () -> Bool in
            let f = lastIcon.frame, visible = grid.exists ? grid.frame : app.frame
            return lastIcon.exists && !f.isEmpty && visible.insetBy(dx: 0, dy: 4).contains(CGPoint(x: f.midX, y: f.midY))
        }
        let reach = { (round: Int) in
            for _ in 0..<6 where !reached() {
                if grid.exists { grid.swipeUp() } else { dockApps.allElementsBoundByIndex.last { $0.isHittable }?.swipeUp() }
                sleep(1)
            }
            print("ALLAPPS round \(round): last icon \(lastIcon.frame) grid \(grid.exists ? grid.frame : .null) handle '\(handle.label)'")
            XCTAssertTrue(reached(), "round \(round): All Apps, the grid's last icon, in view")
        }
        reach(0)
        allAppsSnapshot(app, "all-apps-0-grid")

        let allApps = app.descendants(matching: .any)["stagePeekAllApps"]
        let close = app.buttons["stagePeekAllAppsClose"]
        // The peek's own pieces: All Apps replaces them, so they're gone from the tree.
        let underneath = ["stagePeekDockApp", "stagePeekDockHandle", "stagePeekLaunchpad", "stagePeekExpand", "stagePeekClose",
                          "stagePeekStrip", "galleryWindowCard"]
        // The receiver's controls and the demo's toolbar stay mounted (they hold input state) and
        // step aside in place: not hittable. Whether VoiceOver skips them needs a device: runs
        // 43742243552 and 43745599194 still listed them in the tree.
        let steppedAside = ["demoShowDesktop", "demoOpenFloating", "demoAddPane"]
        let steppedAsideLabels = ["Exit Demo", "Control (Demo)", "Settings"]
        for round in 1...3 {
            if round > 1 { reach(round) }
            lastIcon.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(allApps.waitForExistence(timeout: 5), "round \(round): All Apps opens from the grid's last icon")
            XCTAssertTrue(close.waitForExistence(timeout: 3), "round \(round): its Close")
            let items = app.buttons.matching(identifier: "stagePeekAllAppsItem")
            XCTAssertTrue(items.firstMatch.waitForExistence(timeout: 5), "round \(round): its own grid")
            XCTAssertGreaterThanOrEqual(app.buttons.matching(NSPredicate(format: "identifier == 'stagePeekAllAppsItem' AND label == 'Notes'")).count, 2,
                                        "two different apps called Notes both show")

            // Underneath: gone from the accessibility tree (hidden, untouchable), not merely covered.
            // Anything of the peek's or the receiver's on screen under All Apps fails; anything left
            // off screen is printed (runs 43733403618, 43737338921 found the apps bar's cells).
            let screen = app.frame
            for id in underneath {
                let frames = app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex.map(\.frame)
                let onScreen = frames.filter { !$0.isEmpty && $0.intersects(screen) }
                if frames.count > onScreen.count { print("ALLAPPS round \(round): \(id) off screen, still in the tree: \(frames.filter { !$0.intersects(screen) })") }
                XCTAssertTrue(onScreen.isEmpty, "round \(round): \(id) on screen under All Apps: \(onScreen)")
            }
            for id in steppedAside {
                let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
                XCTAssertFalse(element.exists && element.isHittable, "round \(round): \(id) is hittable under All Apps")
            }
            for label in steppedAsideLabels {
                let control = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
                XCTAssertFalse(control.exists && control.isHittable, "round \(round): the receiver's \(label) is hittable under All Apps")
            }
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "stagePeekSearch").count, 1,
                           "round \(round): one search field, All Apps' own")
            if round == 1 { allAppsSnapshot(app, "all-apps-1-open") }

            close.tap()
            allAppsWaitUntilGone(allApps)
            XCTAssertFalse(allApps.exists, "round \(round): Close goes back")
            XCTAssertTrue(peekClose.waitForExistence(timeout: 3), "round \(round): back on the peek")
            XCTAssertTrue(lastIcon.waitForExistence(timeout: 3), "round \(round): the apps grid is back")
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
