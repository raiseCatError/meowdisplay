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
    func testReceiverChromeFramesStayStableInPortrait() {
        checkReceiverChromeFrames(in: .portrait)
    }

    @MainActor
    func testReceiverChromeFramesStayStableInLandscapeLeft() {
        checkReceiverChromeFrames(in: .landscapeLeft)
    }

    @MainActor
    func testReceiverChromeFramesStayStableInLandscapeRight() {
        checkReceiverChromeFrames(in: .landscapeRight)
    }

    @MainActor
    func testNaturalTouchClicksWithForegroundRailsAndTrackpadTab() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["MEOW_UITEST_RECEIVER_CHROME"] = "1"
        app.launchEnvironment["MEOW_UITEST_POINTER_BUTTONS"] = "1"
        app.launch()
        defer { app.terminate() }
        let fixture = app.buttons["receiverChromeFixtureMenu"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 10))
        let window = app.receiverWindow
        let surface = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
        let buttons = app.staticTexts["receiverChromeFixturePointerButtons"]
        let leftClick = "down left 1;up left 1"

        surface.tap()
        XCTAssertTrue(waitUntil { buttons.value as? String == leftClick }, "\(buttons.value ?? "")")

        fixture.tap()
        app.buttons["Controls"].tap()
        app.buttons["Set Rail Right"].tap()
        let rail = app.descendants(matching: .any)["edgeScrollVertical"].firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 5))
        fixture.tap()
        app.buttons["Panes"].tap()
        app.buttons["Add Trackpad Tab"].tap()
        fixture.tap()
        app.buttons["Panes"].tap()
        app.buttons["Show Full Desktop"].tap()

        let beforeDoubleTap = buttons.value as? String ?? ""
        XCTAssertEqual(beforeDoubleTap, leftClick, "Local fixture controls must not click the Mac")
        surface.doubleTap()
        let doubleTap = leftClick + ";" + leftClick + ";down left 2;up left 2"
        XCTAssertTrue(waitUntil { buttons.value as? String == doubleTap }, "\(buttons.value ?? "")")

        surface.press(forDuration: 0.7)
        let afterHold = doubleTap + ";down right 1;up right 1"
        XCTAssertTrue(waitUntil { buttons.value as? String == afterHold }, "\(buttons.value ?? "")")

        let dragEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.54))
        surface.press(forDuration: 0.32, thenDragTo: dragEnd)
        let afterDrag = afterHold + ";down left 1;up left 0"
        XCTAssertTrue(waitUntil { buttons.value as? String == afterDrag }, "\(buttons.value ?? "")")

        fixture.tap()
        app.buttons["Controls"].tap()
        app.buttons["Revoke Control"].tap()
        XCTAssertTrue(waitUntil { !rail.exists })
        surface.tap()
        XCTAssertEqual(buttons.value as? String, afterDrag, "Revoked touches must stay local")
    }

    @MainActor
    func testAppMenuBarCanCollapseAndFollowsControlInactivity() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["MEOW_UITEST_RECEIVER_CHROME"] = "1"
        app.launchEnvironment["MEOW_UITEST_POINTER_BUTTONS"] = "1"
        app.launch()
        defer { app.terminate() }
        let fixture = app.buttons["receiverChromeFixtureMenu"]
        XCTAssertTrue(fixture.waitForExistence(timeout: 10))
        fixture.tap()
        app.buttons["Panes"].tap()
        app.buttons["Add Google Chrome Pane"].tap()

        let toggle = app.buttons["paneMenuBarToggle"]
        let file = app.buttons["File"]
        let settings = app.descendants(matching: .any)["Settings"].firstMatch
        let chromePane = app.descendants(matching: .any).matching(identifier: "workspacePane").matching(
            NSPredicate(format: "label CONTAINS %@", "Google Chrome")).firstMatch
        let chromeSurface = chromePane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let buttons = app.staticTexts["receiverChromeFixturePointerButtons"]
        let leftClick = "down left 1;up left 1"
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        chromeSurface.tap()
        XCTAssertTrue(waitUntil { buttons.value as? String == leftClick }, "\(buttons.value ?? "")")
        keep(app, "app-menu-bar-expanded")
        XCTAssertEqual(toggle.label, "Hide App Menu Bar")
        let menuAnchor = toggle.frame.maxX
        XCTAssertGreaterThanOrEqual(toggle.frame.width, 44)
        XCTAssertGreaterThanOrEqual(toggle.frame.height, 44)
        XCTAssertEqual(file.frame.minY, toggle.frame.minY, accuracy: 10)
        XCTAssertLessThanOrEqual(file.frame.midX, toggle.frame.minX, "The menus open to the chevron's left")
        // The right end of the pane's title row: that row stops short of the edge-scroll rails and
        // the controls, so on some layouts (the Duo's portrait rail) the chevron ends left of the
        // pane's own edge.
        XCTAssertGreaterThan(toggle.frame.midX, chromePane.frame.midX, "The chevron sits on the pane's right side")
        XCTAssertLessThanOrEqual(toggle.frame.maxX, chromePane.frame.maxX + 1)
        toggle.tap()
        XCTAssertFalse(file.exists)
        XCTAssertEqual(toggle.label, "Show App Menu Bar")
        XCTAssertEqual(toggle.frame.maxX, menuAnchor, accuracy: 1,
                       "Collapsing the menu keeps the chevron on the pane's right edge")
        XCTAssertLessThan(toggle.frame.width, chromePane.frame.width / 2,
                          "The collapsed button uses only its own compact hit area")
        keep(app, "app-menu-bar-manually-collapsed")
        chromeSurface.tap()
        XCTAssertFalse(file.exists, "A manual collapse survives activity on the Mac surface")
        let afterManualCollapse = leftClick + ";" + leftClick
        XCTAssertTrue(waitUntil { buttons.value as? String == afterManualCollapse }, "\(buttons.value ?? "")")
        toggle.tap()
        XCTAssertTrue(file.waitForExistence(timeout: 5))

        fixture.tap()
        app.buttons["Controls"].tap()
        app.buttons["Enable Auto-hide"].tap()
        file.tap()
        let submenu = app.buttons["New Window"]
        XCTAssertTrue(submenu.waitForExistence(timeout: 5))
        let openMenuDisappeared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                            object: submenu)
        XCTAssertEqual(XCTWaiter.wait(for: [openMenuDisappeared], timeout: 10), .timedOut)
        submenu.tap()
        // Report the reveal checks below even when the hide check fails.
        continueAfterFailure = true
        let autoHid = waitUntil(15) { !file.exists && !settings.isHittable }
        keep(app, "app-menu-bar-after-inactivity")
        XCTAssertTrue(autoHid, "After inactivity: File exists=\(file.exists), Settings hittable=\(settings.isHittable) "
                      + "\(settings.exists ? "\(settings.frame) \(settings.elementType.rawValue) \(settings.identifier)" : "")")
        // The folded chevron fades with the controls tray (owner's QA of 9000083); only the tabs stay.
        XCTAssertFalse(toggle.isHittable, "The folded chevron fades with the controls tray")
        keep(app, "app-menu-bar-auto-hidden")
        XCTAssertEqual(buttons.value as? String, afterManualCollapse, "Local menus must not click the Mac")

        chromeSurface.tap()
        let revealed = waitUntil { file.isHittable && settings.isHittable }
        keep(app, "app-menu-bar-revealed")
        XCTAssertTrue(revealed, "After the reveal: File exists=\(file.exists) hittable=\(file.isHittable) "
                      + "\(file.exists ? "\(file.frame)" : ""), Settings hittable=\(settings.isHittable)")
        XCTAssertEqual(buttons.value as? String, afterManualCollapse + ";" + leftClick,
                       "The touch that reveals the menu must reach the Mac")
        XCTAssertEqual(toggle.label, "Hide App Menu Bar")

        // The revealed gear takes a real touch where it is drawn.
        let gear = settings.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: gear.midX, dy: gear.midY)).tap()
        XCTAssertTrue(app.buttons["Input"].firstMatch.waitForExistence(timeout: 5), "Settings opens from the revealed gear")
        keep(app, "app-menu-bar-settings-after-reveal")
        XCTAssertEqual(buttons.value as? String, afterManualCollapse + ";" + leftClick, "Settings must not click the Mac")
    }

    @MainActor
    func testRoomyPhoneUsesTheIPhoneTrayAcrossTheFullCanvas() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPad offers a docked Strip")
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["MEOW_UITEST_RECEIVER_CHROME"] = "1"
        app.launchEnvironment["MEOW_UITEST_RECEIVER_ROOMY"] = "1"
        app.launch()
        defer { app.terminate() }
        let menu = app.buttons["receiverChromeFixtureMenu"]
        let picture = app.descendants(matching: .any)["Mac screen"].firstMatch
        let window = app.receiverWindow
        let settings = app.descendants(matching: .any)["Settings"].firstMatch
        let command = app.descendants(matching: .any)["Command"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertTrue(picture.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.exists)
        XCTAssertTrue(command.exists)
        keep(app, "roomy-phone-window-right-edge")
        XCTAssertEqual(picture.frame.maxX, window.frame.maxX, accuracy: 1)
        XCTAssertEqual(picture.frame.minX, window.frame.minX, accuracy: 1)
        XCTAssertEqual(settings.frame.midY, command.frame.midY, accuracy: 1,
                       "The unfolded phone keeps Settings and modifiers in the iPhone tray")
        XCTAssertGreaterThan(settings.frame.midY, window.frame.midY)

        menu.tap()
        app.buttons["Panes"].tap()
        app.buttons["Add Trackpad Tab"].tap()
        let trackpad = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "workspacePane", "Trackpad")).firstMatch
        XCTAssertTrue(trackpad.waitForExistence(timeout: 5))
        keep(app, "roomy-phone-trackpad-tab-full-canvas")
        if trackpad.frame.isNull || trackpad.frame.isEmpty {
            // Diagnostics for Xcode Cloud runs, which keep the log but show no screenshots.
            print("ROOMY-TRACKPAD frame=\(trackpad.frame) panes:")
            let panes = app.descendants(matching: .any).matching(identifier: "workspacePane")
            for i in 0..<panes.count { print("  \(panes.element(boundBy: i).label) \(panes.element(boundBy: i).frame)") }
            print(app.debugDescription)
        }
        XCTAssertEqual(trackpad.frame.minX, window.frame.minX, accuracy: 1)
        XCTAssertEqual(trackpad.frame.maxX, window.frame.maxX, accuracy: 1)
        XCTAssertEqual(trackpad.frame.minY, window.frame.minY, accuracy: 1)
        XCTAssertEqual(trackpad.frame.maxY, window.frame.maxY, accuracy: 1)

        menu.tap()
        app.buttons["Toggle Video"].tap()
        keep(app, "roomy-phone-trackpad-right-edge")
        XCTAssertEqual(picture.frame.maxX, window.frame.maxX, accuracy: 1)
        XCTAssertEqual(picture.frame.minX, window.frame.minX, accuracy: 1)
    }

    @MainActor
    func testDividedReceiverCanvasReachesBothWindowEdges() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["MEOW_UITEST_RECEIVER_CHROME"] = "1"
        app.launchEnvironment["MEOW_UITEST_FOLD"] = "vertical"
        app.launch()
        defer { app.terminate() }
        let picture = app.descendants(matching: .any)["Mac screen"].firstMatch
        let fold = app.descendants(matching: .any)["uitestFoldBand"].firstMatch
        let menu = app.buttons["receiverChromeFixtureMenu"]
        let window = app.receiverWindow
        XCTAssertTrue(picture.waitForExistence(timeout: 10))
        XCTAssertTrue(fold.waitForExistence(timeout: 3))

        menu.tap()
        app.buttons["Controls"].tap()
        app.buttons["Set Rail Right"].tap()

        for mode in ["window", "video-off"] {
            XCTAssertEqual(picture.frame.minX, window.frame.minX, accuracy: 1)
            XCTAssertEqual(picture.frame.maxX, window.frame.maxX, accuracy: 1)
            keep(app, "receiver-chrome-fold-\(mode)")
            let vertical = app.descendants(matching: .any)["edgeScrollVertical"].firstMatch
            XCTAssertTrue(vertical.waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertGreaterThanOrEqual(vertical.frame.minX, fold.frame.maxX)
            let horizontal = app.descendants(matching: .any)["edgeScrollHorizontal"].firstMatch
            XCTAssertTrue(horizontal.exists)
            XCTAssertFalse(horizontal.frame.intersects(fold.frame))
            if mode == "window" {
                menu.tap()
                app.buttons["Toggle Video"].tap()
            }
        }
    }

    @MainActor
    private func checkReceiverChromeFrames(in orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchEnvironment["MEOW_UITEST_RECEIVER_CHROME"] = "1"
        app.launch()
        defer { app.terminate() }
        let menu = app.buttons["receiverChromeFixtureMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = orientation
        let window = app.receiverWindow
        let picture = app.descendants(matching: .any)["Mac screen"].firstMatch
        #if targetEnvironment(simulator)
        if orientation.isLandscape, !waitUntil(2, { window.frame.width > window.frame.height }) {
            app.terminate()
            app.launchEnvironment["MEOW_UITEST_RECEIVER_LANDSCAPE"] =
                orientation == .landscapeLeft ? "leading" : "trailing"
            app.launch()
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
        }
        #endif
        XCTAssertTrue(picture.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntil {
            let bounds = picture.frame
            return !bounds.isEmpty && (bounds.width > bounds.height) == orientation.isLandscape
        }, "The receiver did not lay out in orientation \(orientation.rawValue)")
        let receiverBounds = window.frame

        func perform(_ action: String, in group: String? = nil) {
            menu.tap()
            if let group {
                app.buttons[group].tap()
                // A fixture menu rebuilt while a new float settles closes its open submenu.
                if !app.buttons[action].waitForExistence(timeout: 2) {
                    if !app.buttons[group].exists { menu.tap() }
                    app.buttons[group].tap()
                }
            }
            app.buttons[action].tap()
        }

        func frames() -> [String: CGRect] {
            let controls = ["Settings", "Command", "Option", "Keyboard", "Arrow Keys", "Zoom In", "Zoom Out", "Redo", "Return"]
            return Dictionary(uniqueKeysWithValues: controls.map {
                let element = app.descendants(matching: .any)[$0].firstMatch
                XCTAssertTrue(element.exists, "Missing \($0) in \(orientation.rawValue)")
                let frame = element.frame
                XCTAssertFalse(frame.isEmpty, "\($0) must have a rendered frame")
                XCTAssertTrue(receiverBounds.contains(frame), "\($0) must stay inside the window: \(frame)")
                return ($0, frame)
            })
        }

        let prefix = "receiver-chrome-\(orientation.rawValue)"
        let original = frames()
        for control in ["Zoom In", "Zoom Out", "Redo", "Return", "Arrow Keys"] {
            guard let frame = original[control] else { continue }
            XCTAssertGreaterThanOrEqual(frame.width, 44, "\(control) needs a full touch target")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "\(control) needs a full touch target")
        }
        if let redo = original["Redo"], let returnKey = original["Return"] {
            XCTAssertTrue(redo.intersection(returnKey).isEmpty, "Redo and Return must have separate hit targets")
        }
        let canvas = picture.frame
        var moved: [String] = []
        var hiddenRails: [String] = []
        var changedRails: [String] = []
        var defaultRails: [String: CGRect]?
        let vertical = app.descendants(matching: .any)["edgeScrollVertical"].firstMatch
        let horizontal = app.descendants(matching: .any)["edgeScrollHorizontal"].firstMatch
        let pane = app.descendants(matching: .any).matching(identifier: "workspacePane")
        func check(_ stage: String, railExpected: Bool = true) {
            let current = frames()
            if !framesMatch(original, current) || picture.frame != canvas {
                moved.append("\(stage): controls \(current), canvas \(picture.frame)")
            }
            if railExpected {
                if vertical.waitForExistence(timeout: 2), horizontal.exists {
                    let currentRails = ["vertical": vertical.frame, "horizontal": horizontal.frame]
                    if let defaultRails {
                        if !framesMatch(defaultRails, currentRails) {
                            changedRails.append("\(stage): \(currentRails)")
                        }
                    } else {
                        defaultRails = currentRails
                    }
                } else {
                    hiddenRails.append(stage)
                }
            }
            let railFrame = vertical.exists ? vertical.frame : .zero
            print("Receiver chrome \(prefix)-\(stage): \(current), canvas \(picture.frame), rail \(railFrame)")
            keep(app, "\(prefix)-\(stage)")
        }

        check("full-desktop-rail-off", railExpected: false)
        perform("Set Rail Right", in: "Controls")
        check("full-desktop-right")
        if vertical.exists { XCTAssertGreaterThan(vertical.frame.midX, app.receiverWindow.frame.midX) }
        if orientation == .portrait, UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertEqual(vertical.frame.maxX, window.frame.maxX - 8, accuracy: 1,
                           "A corner camera must not inset the whole right rail")
            XCTAssertGreaterThanOrEqual(horizontal.frame.width, window.frame.width * 0.6,
                                        "Keep the horizontal rail usable beside the control rows")
        }
        perform("Add Trackpad Tab", in: "Panes")
        perform("Show Full Desktop", in: "Panes")
        check("trackpad-added")
        perform("Show Trackpad Tab", in: "Panes")
        check("trackpad-selected")
        XCTAssertTrue(pane.matching(NSPredicate(format: "label CONTAINS %@", "Trackpad")).firstMatch.exists)
        if orientation.isLandscape {
            let desktopTab = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", "Full Desktop, tab")).firstMatch
            XCTAssertTrue(desktopTab.exists)
            if let zoom = original["Zoom In"] {
                XCTAssertFalse(desktopTab.frame.intersects(zoom), "The pane tab and the Zoom In control must be distinct")
            }
        }
        if vertical.exists, horizontal.exists {
            for (rail, a, b) in [
                (vertical, CGVector(dx: 0.5, dy: 0.75), CGVector(dx: 0.5, dy: 0.25)),
                (horizontal, CGVector(dx: 0.75, dy: 0.5), CGVector(dx: 0.25, dy: 0.5)),
            ] {
                let start = rail.coordinate(withNormalizedOffset: a)
                let end = rail.coordinate(withNormalizedOffset: b)
                start.press(forDuration: 0.2, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
                XCTAssertEqual(rail.value as? String, "Expanded", "the Trackpad pane must pass scroll touches to the rail")
                keep(app, "\(prefix)-\(rail.identifier)-expanded")
                // Accessibility snapshots can pause while the simulator is busy.
                // The unit test pins the one-second hold from momentum end.
                XCTAssertTrue(waitUntil(12) { rail.exists && rail.value as? String != "Expanded" },
                              "\(rail.identifier) stayed expanded")
            }
        } else {
            hiddenRails.append("trackpad: drag both axes")
        }
        perform("Show Full Desktop", in: "Panes")
        check("back-to-desktop")
        perform("Add Google Chrome Pane", in: "Panes")
        XCTAssertEqual(pane.count, 2)
        let chrome = pane.matching(NSPredicate(format: "label CONTAINS %@", "Google Chrome")).firstMatch
        XCTAssertTrue(chrome.exists)
        XCTAssertTrue(chrome.isSelected, "Chrome is the selected pane")
        check("two-panes")
        perform("Show Trackpad Tab", in: "Panes")
        check("trackpad-after-chrome")
        perform("Show Full Desktop", in: "Panes")
        check("desktop-after-chrome")
        perform("Float Display Pane", in: "Panes")
        XCTAssertTrue(app.descendants(matching: .any)["workspaceFloat"].firstMatch.waitForExistence(timeout: 3))
        check("floating-pane")
        let floatOptions = app.descendants(matching: .any)["floatOptions"].firstMatch
        XCTAssertTrue(floatOptions.exists)
        let floatFrame = app.descendants(matching: .any)["workspaceFloat"].firstMatch.frame
        for rail in [vertical, horizontal] where rail.exists {
            XCTAssertFalse(rail.frame.intersects(floatOptions.frame),
                           "The rail \(rail.frame) covers the floating pane menu \(floatOptions.frame) (float \(floatFrame))")
        }
        // With a float up, the fixture's Panes submenu doesn't open on a device; choose the tab
        // the way a person does, on its own label.
        let trackpadTab = app.buttons["Trackpad, tab"].firstMatch
        XCTAssertTrue(trackpadTab.waitForExistence(timeout: 3))
        trackpadTab.tap()
        XCTAssertTrue(waitUntil { pane.matching(NSPredicate(format: "label CONTAINS %@", "Trackpad")).firstMatch.exists })
        check("trackpad-with-float")
        perform("Set Rail Left", in: "Controls")
        defaultRails = nil
        check("trackpad-left")
        if vertical.exists { XCTAssertLessThan(vertical.frame.midX, app.receiverWindow.frame.midX) }
        perform("Toggle Controls", in: "Controls")
        keep(app, "\(prefix)-controls-hidden")
        perform("Toggle Controls", in: "Controls")
        check("controls-restored")

        perform("Toggle Video")
        if !vertical.waitForExistence(timeout: 2) { hiddenRails.append("video-off") }
        keep(app, "\(prefix)-video-off")

        // Report every stage even on the baseline where the old layout moves.
        continueAfterFailure = true
        XCTAssertTrue(moved.isEmpty, "\(prefix) unrailed controls \(original), canvas \(canvas). Moved: \(moved)")
        XCTAssertTrue(changedRails.isEmpty, "\(prefix) workspace changes moved receiver rails: \(changedRails)")
        XCTAssertTrue(hiddenRails.isEmpty, "\(prefix) rails covered or unreachable: \(hiddenRails)\n\(app.debugDescription)")
        continueAfterFailure = false
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
            app.receiverWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
            sleep(1)
            let window = app.receiverWindow.frame
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

        // Auto-hide fades the tray 9 s after the last touch, and the orientation checks above
        // can take longer than that on a slow simulator. A tray that is still showing can fade
        // between a hittability check and the tap (the tap then lands on the stream), so touch
        // the stream first, as a person would: that always reveals the tray and restarts the
        // countdown. Then tap Settings as soon as it can be reached.
        let settings = app.descendants(matching: .any)["Settings"].firstMatch
        app.receiverWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: settings)
        XCTAssertEqual(XCTWaiter.wait(for: [reachable], timeout: 5), .completed, "Settings is reachable after a touch")
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

    // MARK: - Size-class dependent controls

    /// iPad uses its own controls when the window is regular in both directions.
    @MainActor
    private func isRoomy(_ app: XCUIApplication) throws -> Bool {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return false }
        let window = app.receiverWindow
        try XCTSkipIf(window.horizontalSizeClass == .unspecified || window.verticalSizeClass == .unspecified,
                      "The window does not report its size classes")
        print("AdaptiveLayout: size classes \(window.horizontalSizeClass.rawValue)/\(window.verticalSizeClass.rawValue)")
        return window.horizontalSizeClass == .regular && window.verticalSizeClass == .regular
    }

    @MainActor
    private func launchIntoDemo(environment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launch()
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        sleep(1)
        let explore = app.buttons["exploreDemo"]
        XCTAssertTrue(explore.waitForExistence(timeout: 5))
        for _ in 0..<4 where !explore.isHittable { app.swipeUp(velocity: .slow) }
        explore.tap()
        XCTAssertTrue(app.buttons["Exit Demo"].waitForExistence(timeout: 5))
        return app
    }

    /// Wakes the faded controls with a touch on the stream, then opens Settings.
    @MainActor
    private func openSettings(_ app: XCUIApplication) {
        let settings = app.descendants(matching: .any)["Settings"].firstMatch
        wakeControls(app)
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: settings)
        let woke = XCTWaiter.wait(for: [reachable], timeout: 5)
        if woke != .completed { reportReachableControls(app, "settings-not-reachable") }
        XCTAssertEqual(woke, .completed, "Settings is reachable after a touch")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5)
                      || app.staticTexts["Settings"].waitForExistence(timeout: 5))
    }

    /// Closes Settings by its own Done or Back, however far in it is.
    @MainActor
    private func leaveSettings(_ app: XCUIApplication) {
        for _ in 0..<4 where !app.buttons["Exit Demo"].isHittable {
            let done = app.buttons["Done"].firstMatch
            let back = app.buttons["BackButton"].firstMatch
            if done.exists && done.isHittable {
                done.tap()
            } else if back.exists {
                back.tap()
            } else if done.exists {
                done.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            } else {
                XCTFail("Neither Done nor Back is available to leave Settings")
                break
            }
            sleep(1)
        }
        XCTAssertTrue(app.buttons["Exit Demo"].waitForExistence(timeout: 5), "back on the stream")
    }

    @MainActor
    private func openControlsPage(_ app: XCUIApplication) {
        guard !app.navigationBars["Controls"].exists else { return }
        let controls = app.buttons["Controls"].firstMatch
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        for _ in 0..<4 where !controls.isHittable && !app.collectionViews["Sidebar"].exists { app.swipeUp(velocity: .slow) }
        if controls.isHittable {
            controls.tap()
        } else {
            // A sidebar's rows never report hittable; tap where it is drawn.
            controls.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(app.navigationBars["Controls"].waitForExistence(timeout: 5))
    }

    /// Whether the open Controls page has a setting (by accessibility identifier or label),
    /// scrolling the whole page: rows below the fold are not in the accessibility tree until
    /// they are near the screen. Segmented pickers show no label, so they are found by their
    /// identifier. Only scrolls up, so a sheet is never dragged away by it.
    @MainActor
    private func controlsPageHas(_ app: XCUIApplication, _ label: String) -> Bool {
        let target = app.descendants(matching: .any)[label].firstMatch
        for _ in 0..<10 {
            if target.exists { return true }
            app.swipeUp(velocity: .fast)
        }
        return target.exists
    }

    @MainActor
    func testControlsSettingsFollowTheWindowSizeClasses() throws {
        let app = launchIntoDemo()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            sleep(1)
            let roomy = try isRoomy(app)
            openSettings(app)
            openControlsPage(app)
            let hasLayout = controlsPageHas(app, "controlLayoutPicker")
            XCTAssertEqual(hasLayout, roomy, "Control Layout is offered on roomy iPad windows (\(orientation.rawValue))")
            // Back to the top of the page for the next row: reopen it.
            leaveSettings(app)
            openSettings(app)
            openControlsPage(app)
            let hasTraySide = controlsPageHas(app, "landscapeTraySidePicker")
            XCTAssertEqual(hasTraySide, !roomy, "Landscape Tray Side is offered exactly on a compact window (\(orientation.rawValue))")
            keep(app, "controls-settings-\(orientation.rawValue)-roomy-\(roomy)")
            leaveSettings(app)
        }
        app.buttons["Exit Demo"].tap()
        XCTAssertTrue(app.buttons["exploreDemo"].waitForExistence(timeout: 5))
    }

    /// A compact window presents Settings as a sheet (it can be dragged away); a roomy one
    /// presents it full screen (it cannot). Decided when Settings opens.
    @MainActor
    func testSettingsPresentationFollowsTheWindowSizeClasses() throws {
        let app = launchIntoDemo()
        let roomy = try isRoomy(app)
        openSettings(app)
        let bar = app.navigationBars["Settings"]
        if bar.exists {
            let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let end = app.receiverWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
            start.press(forDuration: 0.1, thenDragTo: end)
        } else {
            app.swipeDown(velocity: .fast)
        }
        sleep(1)
        let dismissed = app.buttons["Exit Demo"].waitForExistence(timeout: 3)
        XCTAssertEqual(dismissed, !roomy, roomy
            ? "a roomy window shows Settings full screen: a drag cannot dismiss it"
            : "a compact window shows Settings as a sheet: a drag dismisses it")
        keep(app, "settings-presentation-roomy-\(roomy)")
        if !dismissed { leaveSettings(app) }
        app.buttons["Exit Demo"].tap()
        XCTAssertTrue(app.buttons["exploreDemo"].waitForExistence(timeout: 5))
    }

    /// The Duo outer display follows ordinary iPhone rules. The inner display supports
    /// all four orientations. A requested device pose alone does not establish the scene
    /// orientation; this test checks control reachability in the resulting window.
    @MainActor
    func testControlsStayInsideTheWindowThroughEveryOrientationIncludingUpsideDown() {
        let app = launchIntoDemo()
        let orientations: [UIDeviceOrientation] = [.portrait, .portraitUpsideDown, .landscapeLeft,
                                                   .landscapeRight, .portraitUpsideDown, .portrait]
        for orientation in orientations {
            XCUIDevice.shared.orientation = orientation
            sleep(1)
            app.receiverWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).tap()
            sleep(1)
            let window = app.receiverWindow.frame
            XCTAssertFalse(window.isEmpty)
            print("AdaptiveLayout: requested \(orientation.rawValue), window \(window)")
            for name in ["Exit Demo", "Settings"] {
                let control = app.descendants(matching: .any)[name].firstMatch
                XCTAssertTrue(control.waitForExistence(timeout: 5), "\(name) after requesting \(orientation.rawValue)")
                XCTAssertTrue(window.contains(control.frame),
                              "\(name) lies inside the window after requesting \(orientation.rawValue)")
            }
            keep(app, "orientation-\(orientation.rawValue)")
        }
        app.buttons["Exit Demo"].tap()
        XCTAssertTrue(app.buttons["exploreDemo"].waitForExistence(timeout: 5))
    }

    // MARK: - Synthetic fold (DEBUG seam `MEOW_UITEST_FOLD`, iOS/UITestFoldSeam.swift)
    //
    // The hosted job does not change the Duo pose in Device Hub. These tests ask the app for a
    // synthetic one: a 24 pt `.division` band at the window's centre, vertical (a book) or
    // horizontal (tabletop), fed through the same `ControlReservedRegion.active(in:)` as a real
    // hinge. The app exposes the band as the element `uitestFoldBand`.

    /// The controls of the trays and rails, by label (Main Tray items, the rail's Settings, the
    /// keyboard's own keys, Move View, Arrow Keys) and by identifier (the arrow keypad), plus
    /// Exit Demo. The demo's own banner chips are reported, not asserted (`demoChrome`): they are
    /// demo-only chrome centred over the picture, outside the fold-aware controls.
    private static let controlLabels = ["Exit Demo", "Settings", "Command", "Option", "Control", "Shift",
                                        "Escape", "Tab", "Toggle Dock", "Keyboard", "Hide Keyboard",
                                        "Move View", "Arrow Keys"]
    private static let demoChrome = ["Control (Demo)", "Demo Options", "demoWindowViewToggle"]

    @MainActor
    private func foldBand(_ app: XCUIApplication, vertical: Bool) -> CGRect {
        let element = app.descendants(matching: .any)["uitestFoldBand"].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "the synthetic fold seam is on (a Debug build)")
        let band = element.frame
        let window = app.receiverWindow.frame
        print("AdaptiveLayout: fold band \(band) in window \(window)")
        XCTAssertTrue(window.intersects(band), "the fold band crosses the window")
        if vertical {
            XCTAssertGreaterThan(band.height, band.width, "a book fold is a vertical band")
            XCTAssertEqual(band.midX, window.midX, accuracy: 1, "the fold is at the window's horizontal centre")
        } else {
            XCTAssertGreaterThan(band.width, band.height, "a tabletop fold is a horizontal band")
            XCTAssertEqual(band.midY, window.midY, accuracy: 1, "the fold is at the window's vertical centre")
        }
        return band
    }

    /// Touches the stream to bring the faded controls back, as a person would: on the picture,
    /// never on the synthetic fold band (the layout leaves that strip to the fold, so a touch
    /// there is not a touch on the stream). Without a band it is the usual spot below the middle.
    @MainActor
    private func wakeControls(_ app: XCUIApplication) {
        let window = app.receiverWindow
        let frame = window.frame
        var offset = CGVector(dx: 0.5, dy: 0.6)
        let bandElement = app.descendants(matching: .any)["uitestFoldBand"].firstMatch
        if bandElement.exists, !frame.isEmpty {
            let band = bandElement.frame
            let wakeY = frame.minY + frame.height * 0.6
            if band.height > band.width {   // book: the middle of the wider side
                let leftWidth = band.minX - frame.minX, rightWidth = frame.maxX - band.maxX
                let x = leftWidth >= rightWidth ? frame.minX + leftWidth / 2 : band.maxX + rightWidth / 2
                offset.dx = (x - frame.minX) / frame.width
            } else if band.minY <= wakeY, wakeY <= band.maxY {   // tabletop: below the band
                offset.dy = (band.maxY + (frame.maxY - band.maxY) / 2 - frame.minY) / frame.height
            }
        }
        window.coordinate(withNormalizedOffset: offset).tap()
    }

    /// On a failure to reach Settings: which controls can be reached, and a kept screenshot.
    @MainActor
    private func reportReachableControls(_ app: XCUIApplication, _ name: String) {
        let hittable = app.buttons.allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable }
            .map { "\($0.label)@\(Int($0.frame.midX)),\(Int($0.frame.midY))" }
        print("AdaptiveLayout: \(name): reachable buttons \(hittable)")
        // Where Settings and Keyboard are, and why they can't be reached (frame, hittable, type).
        for line in app.debugDescription.split(separator: "\n")
        where line.contains("'Settings'") || line.contains("'Keyboard'") || line.contains("Gear") {
            print("AdaptiveLayout: \(name): tree \(line.trimmingCharacters(in: .whitespaces))")
        }
        keep(app, name)
    }

    /// Polls `condition` (no fixed sleep) until it holds or `timeout` passes.
    @MainActor @discardableResult
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    /// Wakes the controls with a touch on the stream, then checks every reachable control: inside
    /// the window and off the fold band. Exit Demo and Settings must be among them, so a tray
    /// that faded before the check can never pass by checking nothing.
    @MainActor
    private func assertControlsAvoidFold(_ app: XCUIApplication, band: CGRect, _ context: String) {
        let settings = app.descendants(matching: .any)["Settings"].firstMatch
        wakeControls(app)
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: settings)
        let woke = XCTWaiter.wait(for: [reachable], timeout: 5)
        if woke != .completed { reportReachableControls(app, "settings-not-reachable-\(context)") }
        XCTAssertEqual(woke, .completed, "Settings is reachable (\(context))")
        let window = app.receiverWindow.frame
        // Half a point of rounding either way: frames come back in fractional points.
        let fold = band.insetBy(dx: 0.5, dy: 0.5)
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "label IN %@ OR identifier BEGINSWITH %@", Self.controlLabels, "arrowKey"))
        var checked = Set<String>()
        for control in query.allElementsBoundByIndex where control.exists && control.isHittable {
            let frame = control.frame
            guard !frame.isEmpty else { continue }
            let name = control.identifier.isEmpty ? control.label : control.identifier
            XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                          "\(name) \(frame) lies inside the window \(window) (\(context))")
            XCTAssertFalse(frame.intersects(fold), "\(name) \(frame) keeps off the fold \(band) (\(context))")
            checked.insert(control.label)
        }
        print("AdaptiveLayout: \(context): checked \(checked.sorted())")
        XCTAssertTrue(checked.contains("Settings"), "Settings was reachable and checked (\(context))")
        XCTAssertTrue(checked.contains("Exit Demo"), "Exit Demo was reachable and checked (\(context))")
        for name in Self.demoChrome {
            let chip = app.descendants(matching: .any)[name].firstMatch
            if chip.exists, chip.frame.intersects(fold) {
                print("AdaptiveLayout: NOTE demo chrome \(name) \(chip.frame) crosses the fold \(band) (\(context))")
            }
        }
    }

    /// Picks `option` in Settings ▸ Controls ▸ Control Layout and returns to the stream.
    @MainActor
    private func chooseControlLayout(_ app: XCUIApplication, _ option: String) {
        openSettings(app)
        openControlsPage(app)
        XCTAssertTrue(controlsPageHas(app, "controlLayoutPicker"))
        let segment = app.descendants(matching: .any)["controlLayoutPicker"].firstMatch.buttons[option]
        XCTAssertTrue(segment.waitForExistence(timeout: 5), "Control Layout offers \(option)")
        segment.tap()
        XCTAssertTrue(waitUntil { segment.isSelected }, "\(option) is selected")
        leaveSettings(app)
    }

    /// Every Control Layout this window offers (Strip, Overlay, Custom on a roomy window), each
    /// checked against the fold; a compact window has no Control Layout, so its one layout (the
    /// phone tray) is checked. The layout chosen before the test is restored.
    @MainActor
    private func checkControlsAvoidFold(vertical: Bool) throws {
        let axis = vertical ? "vertical" : "horizontal"
        let app = launchIntoDemo(environment: ["MEOW_UITEST_FOLD": axis])
        let band = foldBand(app, vertical: vertical)
        if try isRoomy(app) {
            openSettings(app)
            openControlsPage(app)
            XCTAssertTrue(controlsPageHas(app, "controlLayoutPicker"), "a roomy window offers Control Layout")
            let segments = app.descendants(matching: .any)["controlLayoutPicker"].firstMatch.buttons.allElementsBoundByIndex
            let options = segments.map(\.label)
            let original = segments.first { $0.isSelected }?.label
            leaveSettings(app)
            XCTAssertFalse(options.isEmpty, "Control Layout has options")
            for option in options {
                chooseControlLayout(app, option)
                assertControlsAvoidFold(app, band: band, "\(axis) fold, \(option)")
                keep(app, "fold-\(axis)-\(option)")
            }
            if let original, original != options.last { chooseControlLayout(app, original) }
        } else {
            print("AdaptiveLayout: compact window: no Control Layout here; checking the phone tray")
            assertControlsAvoidFold(app, band: band, "\(axis) fold, phone tray")
            keep(app, "fold-\(axis)-phone-tray")
        }
        app.buttons["Exit Demo"].tap()
        XCTAssertTrue(app.buttons["exploreDemo"].waitForExistence(timeout: 5))
    }

    /// An iPhone Duo held like a book: no control sits on the fold, in every Control Layout.
    @MainActor
    func testControlsKeepOffAVerticalFoldInEveryLayout() throws {
        try checkControlsAvoidFold(vertical: true)
    }

    /// An iPhone Duo on a table, half open: no control sits on the fold, in every Control Layout.
    @MainActor
    func testControlsKeepOffAHorizontalFoldInEveryLayout() throws {
        try checkControlsAvoidFold(vertical: false)
    }

    /// Settings open while the window changes (a rotation where the window rotates; nothing where
    /// it does not, like the Duo's cover screen): Settings stays up through it, and once it is
    /// closed the controls are back, inside the window and off the fold, which follows the window.
    @MainActor
    func testSettingsThroughARotationWithAFoldThenControlsKeepOffIt() throws {
        let app = launchIntoDemo(environment: ["MEOW_UITEST_FOLD": "vertical"])
        _ = foldBand(app, vertical: true)
        openSettings(app)
        keep(app, "fold-settings-before-rotation")
        let before = app.receiverWindow.frame
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = waitUntil(3) { app.receiverWindow.frame.size != before.size }
        print("AdaptiveLayout: window \(before) -> \(app.receiverWindow.frame) (rotated: \(rotated))")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5)
                      || app.staticTexts["Settings"].waitForExistence(timeout: 5),
                      "Settings stays open through the window change")
        keep(app, "fold-settings-after-rotation-\(rotated)")
        leaveSettings(app)
        let band = foldBand(app, vertical: true)
        assertControlsAvoidFold(app, band: band, "after Settings and rotation (rotated: \(rotated))")
        keep(app, "fold-controls-after-settings-rotated-\(rotated)")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Exit Demo"].tap()
        XCTAssertTrue(app.buttons["exploreDemo"].waitForExistence(timeout: 5))
    }

    // MARK: - Stage Peek through a resize (DEBUG seam `MEOW_UITEST_STAGE_PEEK`)
    //
    // The real Stage Peek overlay over the three sample displays. The host narrows the canvas it
    // gives the overlay (a Split View / Stage Manager resize) about a second after the Display
    // Overview opens, and on the fixture's own Resize button. Its "Resizes: N" label counts them.

    @MainActor
    private func launchStagePeekFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEOW_UITEST_STAGE_PEEK"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["uitestStagePeekResize"].waitForExistence(timeout: 10),
                      "the Stage Peek fixture opens at launch (a Debug build)")
        return app
    }

    /// Holds just inside the left screen edge and pulls inward, as a person does.
    @MainActor
    private func openStagePeekFromTheEdge(_ app: XCUIApplication) {
        let close = app.buttons["stagePeekClose"]
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        start.press(forDuration: 0.7, thenDragTo: end, withVelocity: 250, thenHoldForDuration: 0.4)
        XCTAssertTrue(close.waitForExistence(timeout: 5), "Stage Peek opens from its edge")
    }

    /// With the overview open and the canvas narrowed under it, Stage Peek stays open and the
    /// overview stays up; Done returns to the same Stage Peek gallery.
    @MainActor
    func testDisplayOverviewStaysOpenThroughAResize() {
        let app = launchStagePeekFixture()
        openStagePeekFromTheEdge(app)
        let expand = app.buttons["stagePeekExpand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3), "Stage Peek offers Expand")
        if expand.label != "Compact" { expand.tap() }
        XCTAssertTrue(waitUntil(5) { expand.label == "Compact" }, "the gallery expands")

        let open = app.buttons["displayOverviewButton"]
        for _ in 0..<6 where !(open.exists && open.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(open.exists && open.isHittable, "the Displays section offers Overview")
        open.tap()
        let done = app.buttons["displayOverviewDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "the overview opens")
        keep(app, "stage-peek-overview-open")

        // The host narrows the canvas one second after the overview opened. Watch well past it: a
        // Stage Peek that closed on the width change would take the overview with it.
        let dismissed = waitUntil(4) { !done.exists }
        XCTAssertFalse(dismissed, "the overview stays open through the resize")
        done.tap()

        let resizes = app.staticTexts["uitestStagePeekResizes"]
        XCTAssertTrue(resizes.waitForExistence(timeout: 3))
        XCTAssertEqual(resizes.label, "Resizes: 1", "the host did resize while the overview was open")
        XCTAssertTrue(app.buttons["stagePeekClose"].waitForExistence(timeout: 3),
                      "Done returns to the Stage Peek gallery, which stayed open")
        XCTAssertEqual(app.buttons["stagePeekExpand"].label, "Compact", "it is still expanded")
        keep(app, "stage-peek-after-overview")
    }

    /// Without a screen opened from the gallery a width change still closes Stage Peek, as before.
    @MainActor
    func testStagePeekStillClosesOnAResizeWithoutTheOverview() {
        let app = launchStagePeekFixture()
        openStagePeekFromTheEdge(app)
        let close = app.buttons["stagePeekClose"]
        app.buttons["uitestStagePeekResize"].tap()
        XCTAssertTrue(waitUntil(5) { !close.exists }, "a width change closes Stage Peek")
        XCTAssertEqual(app.staticTexts["uitestStagePeekResizes"].label, "Resizes: 1")
    }

    // MARK: - Overview pane (DEBUG seam `MEOW_UITEST_STAGE_PEEK_PANES` on the Stage Peek fixture)
    //
    // Window view on a stand-in Mac that offers the Overview pane, the main display already in a
    // pane ("Full Desktop"), and the real pane chrome under Stage Peek. No video.

    @MainActor
    private func workspacePane(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "workspacePane")
            .matching(NSPredicate(format: "label == %@", "\(title) pane")).firstMatch
    }

    /// Stage Peek's Displays header adds the Overview as a pane, titled Overview; holding its title
    /// lists each display, and choosing one shows that display in a pane through the display path.
    @MainActor
    func testOverviewPaneIsAddedFromStagePeekAndItsMenuListsTheDisplays() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MEOW_UITEST_STAGE_PEEK"] = "1"
        app.launchEnvironment["MEOW_UITEST_STAGE_PEEK_PANES"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["uitestStagePeekResize"].waitForExistence(timeout: 10),
                      "the Stage Peek fixture opens at launch (a Debug build)")
        XCTAssertTrue(workspacePane(app, "Full Desktop").waitForExistence(timeout: 5), "the main display starts in a pane")
        XCTAssertFalse(workspacePane(app, "Overview").exists, "no Overview pane yet")

        openStagePeekFromTheEdge(app)
        let expand = app.buttons["stagePeekExpand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3), "Stage Peek offers Expand")
        if expand.label != "Compact" { expand.tap() }
        XCTAssertTrue(waitUntil(5) { expand.label == "Compact" }, "the gallery expands")
        let add = app.buttons["displayOverviewAddAsPane"]
        for _ in 0..<6 where !(add.exists && add.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(add.exists && add.isHittable, "the Displays section offers the Overview as a pane")
        keep(app, "overview-pane-offered")
        add.tap()

        let overview = workspacePane(app, "Overview")
        XCTAssertTrue(overview.waitForExistence(timeout: 5), "the Overview pane appears, titled Overview")
        XCTAssertTrue(waitUntil(5) { !app.buttons["stagePeekClose"].exists }, "Stage Peek closes")
        XCTAssertTrue(workspacePane(app, "Full Desktop").exists, "added beside the pane already there")
        keep(app, "overview-pane-added")

        try app.holdPaneTitle(.paneTitle("Overview"), in: overview)
        let displays = ["Built-in Display", "Wide Display", "Portrait Display"]
        for name in displays {
            XCTAssertTrue(app.buttons["Show \(name) in a Pane"].waitForExistence(timeout: 5), "the menu lists \(name)")
        }
        XCTAssertFalse(app.buttons["Rotate"].exists, "an Overview pane is never turned")
        XCTAssertFalse(app.buttons["Show Overview Here"].exists, "not offered in the Overview itself")
        keep(app, "overview-pane-menu")

        app.buttons["Show Wide Display in a Pane"].tap()
        XCTAssertTrue(workspacePane(app, "Wide Display").waitForExistence(timeout: 5),
                      "the display shows in a pane of its own")
        keep(app, "overview-pane-display-shown")
    }

    @MainActor
    func testLiveOverviewTabOpensDirectlyFromDisplays() {
        let app = XCUIApplication()
        app.launchEnvironment["MEOW_UITEST_STAGE_PEEK"] = "1"
        app.launchEnvironment["MEOW_UITEST_STAGE_PEEK_PANES"] = "1"
        app.launch()
        XCTAssertTrue(workspacePane(app, "Full Desktop").waitForExistence(timeout: 10))

        openStagePeekFromTheEdge(app)
        let expand = app.buttons["stagePeekExpand"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        if expand.label != "Compact" { expand.tap() }
        XCTAssertTrue(waitUntil(5) { expand.label == "Compact" })
        let add = app.buttons["displayOverviewAddAsTab"]
        for _ in 0..<6 where !(add.exists && add.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(add.exists && add.isHittable)
        add.tap()
        XCTAssertTrue(workspacePane(app, "Overview").waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(5) { !app.buttons["stagePeekClose"].exists })
        keep(app, "overview-tab-from-displays")
    }

    // MARK: - Multi-Display Overview fixture (DEBUG seam `MEOW_UITEST_OVERVIEW`)
    //
    // The overview needs a Mac's display catalog, which the demo has not got, so the app opens it
    // straight away with three sample displays: "Built-in Display" (main, 1512x982 at 0,0),
    // "Wide Display" (1920x1080 to its right) and "Portrait Display" (1080x1920 above-left).

    private static let leadingChrome = ["displayOverviewDone", "Previous Display", "Next Display",
                                        "displayOverviewShowInPane"]
    private static let trailingChrome = ["displayOverviewFitAll", "displayOverviewIdentify",
                                         "displayOverviewAddPane"]

    @MainActor
    private func launchOverviewFixture(fold: String? = nil, controlGranted: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MEOW_UITEST_OVERVIEW"] = "1"
        if controlGranted { app.launchEnvironment["MEOW_UITEST_OVERVIEW_CONTROL"] = "1" }
        if let fold { app.launchEnvironment["MEOW_UITEST_FOLD"] = fold }
        app.launch()
        XCTAssertTrue(app.buttons["displayOverviewDone"].waitForExistence(timeout: 10),
                      "the overview fixture opens at launch (a Debug build)")
        return app
    }

    @MainActor
    private func overviewTile(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == 'displayOverviewTile' AND label BEGINSWITH %@", name)).firstMatch
    }

    @MainActor
    private func overviewTileFrames(_ app: XCUIApplication) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        for name in ["Built-in Display", "Wide Display", "Portrait Display"] {
            frames[name] = overviewTile(app, name).frame
        }
        return frames
    }

    /// The canvas lies between the toolbar and the action bar: below Done, above Show in Pane.
    @MainActor
    private func overviewCanvas(_ app: XCUIApplication) -> CGRect {
        let window = app.receiverWindow.frame
        let top = app.buttons["displayOverviewDone"].frame.maxY
        let bottom = app.buttons["displayOverviewShowInPane"].frame.minY
        return CGRect(x: window.minX, y: top, width: window.width, height: max(0, bottom - top))
    }

    @MainActor
    private func tap(_ app: XCUIApplication, at point: CGPoint) {
        app.receiverWindow.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - app.receiverWindow.frame.minX,
                                 dy: point.y - app.receiverWindow.frame.minY))
            .tap()
    }

    @MainActor
    private func doubleTap(_ app: XCUIApplication, at point: CGPoint) {
        app.receiverWindow.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - app.receiverWindow.frame.minX,
                                 dy: point.y - app.receiverWindow.frame.minY))
            .doubleTap()
    }

    private func framesMatch(_ a: [String: CGRect], _ b: [String: CGRect], tolerance: CGFloat = 1.5) -> Bool {
        a.keys.sorted() == b.keys.sorted() && a.allSatisfy { name, frame in
            guard let other = b[name] else { return false }
            return abs(frame.minX - other.minX) <= tolerance && abs(frame.minY - other.minY) <= tolerance
                && abs(frame.width - other.width) <= tolerance && abs(frame.height - other.height) <= tolerance
        }
    }

    /// With a book fold, the toolbar and the action bar split around it: navigation and Show in
    /// Pane before it, the tools and the other actions after it (`OverviewChromeFold` and
    /// `FoldAwareBar`), all inside the window and none on the fold.
    @MainActor
    func testOverviewChromeSplitsAroundAVerticalFold() throws {
        let app = launchOverviewFixture(fold: "vertical")
        let band = foldBand(app, vertical: true)
        let window = app.receiverWindow.frame
        let fold = band.insetBy(dx: 0.5, dy: 0.5)
        for required in ["displayOverviewDone", "displayOverviewFitAll", "displayOverviewShowInPane"] {
            XCTAssertTrue(app.buttons[required].waitForExistence(timeout: 5), "\(required) is shown")
        }
        for (names, leading) in [(Self.leadingChrome, true), (Self.trailingChrome, false)] {
            for name in names {
                let button = app.buttons[name].firstMatch
                guard button.exists else {
                    print("AdaptiveLayout: overview \(name) not shown in the fixture")
                    continue
                }
                let frame = button.frame
                XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(name) \(frame) is inside the window \(window)")
                XCTAssertFalse(frame.intersects(fold), "\(name) \(frame) keeps off the fold \(band)")
                if leading {
                    XCTAssertLessThanOrEqual(frame.maxX, band.minX + 0.5, "\(name) is before the fold")
                } else {
                    XCTAssertGreaterThanOrEqual(frame.minX, band.maxX - 0.5, "\(name) is after the fold")
                }
            }
        }
        keep(app, "overview-vertical-fold")
        app.buttons["displayOverviewDone"].tap()
        XCTAssertTrue(waitUntil { !app.buttons["displayOverviewDone"].exists }, "Done closes the overview")
    }

    /// Without a fold the bars are as before: one line each, the toolbar's navigation ahead of its
    /// tools, everything inside the window. The fold seam is off, so there is no band.
    @MainActor
    func testOverviewChromeKeepsOneLineWithoutAFold() throws {
        let app = launchOverviewFixture()
        XCTAssertFalse(app.descendants(matching: .any)["uitestFoldBand"].exists, "no synthetic fold without the seam")
        let window = app.receiverWindow.frame
        let done = app.buttons["displayOverviewDone"]
        let fitAll = app.buttons["displayOverviewFitAll"]
        let show = app.buttons["displayOverviewShowInPane"]
        XCTAssertTrue(fitAll.waitForExistence(timeout: 5))
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(show.frame.height, 44, "the primary action has a comfortable tap target")
        XCTAssertLessThan(show.frame.width, window.width / 2, "the primary action stays compact")
        for name in Self.leadingChrome + Self.trailingChrome where app.buttons[name].exists {
            XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(app.buttons[name].frame),
                          "\(name) \(app.buttons[name].frame) is inside the window \(window)")
        }
        XCTAssertEqual(done.frame.midY, fitAll.frame.midY, accuracy: max(done.frame.height, fitAll.frame.height) / 2,
                       "Done and Fit All share the toolbar's line")
        XCTAssertLessThan(done.frame.maxX, fitAll.frame.minX, "the navigation comes before the tools")
        let add = app.buttons["displayOverviewAddPane"]
        if add.exists {
            XCTAssertEqual(show.frame.midY, add.frame.midY, accuracy: max(show.frame.height, add.frame.height) / 2,
                           "Show in Pane and Add as New Pane share the action bar's line")
            XCTAssertLessThan(show.frame.maxX, add.frame.minX, "Show in Pane comes first")
        }
        XCTAssertLessThan(done.frame.maxY, show.frame.minY, "the toolbar is above the action bar")
        keep(app, "overview-no-fold")
    }

    @MainActor
    func testOverviewWithControlKeepsTwoPaneActions() {
        let app = launchOverviewFixture(controlGranted: true)
        let show = app.buttons["displayOverviewShowInPane"]
        let add = app.buttons["displayOverviewAddPane"]
        XCTAssertTrue(show.waitForExistence(timeout: 5))
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertEqual(add.label, "Add as New Pane")
        XCTAssertFalse(app.buttons["displayOverviewMoveCursor"].exists)
        XCTAssertLessThan(show.frame.maxX, add.frame.minX)
        keep(app, "overview-control-actions")
    }

    /// Selection, zoom, pan, Fit All and double-tap in the overview, and taps that land on the
    /// display under the finger after the camera moved.
    @MainActor
    func testOverviewSelectionZoomPanFitAllAndTapTargeting() throws {
        let app = launchOverviewFixture()
        let window = app.receiverWindow
        let tiles = app.descendants(matching: .any).matching(identifier: "displayOverviewTile")
        XCTAssertTrue(waitUntil { tiles.count == 3 }, "the three sample displays are drawn (found \(tiles.count))")
        let show = app.buttons["displayOverviewShowInPane"]
        XCTAssertTrue(show.waitForExistence(timeout: 5), "the main display is selected at open: Show in Pane is offered")
        let canvas = overviewCanvas(app)
        XCTAssertFalse(canvas.isEmpty, "the canvas lies between the bars")
        // Fit-all frames settle after the first layout.
        var fitAll = overviewTileFrames(app)
        waitUntil {
            let now = overviewTileFrames(app)
            defer { fitAll = now }
            return framesMatch(now, fitAll, tolerance: 0.5)
        }
        for (name, frame) in fitAll {
            XCTAssertTrue(canvas.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(name) \(frame) is in the canvas \(canvas) at open")
        }
        let main = overviewTile(app, "Built-in Display")
        let wide = overviewTile(app, "Wide Display")
        let portrait = overviewTile(app, "Portrait Display")
        XCTAssertTrue(main.isSelected, "the main display is selected at open")
        keep(app, "overview-open")

        // A single tap selects; the camera stays.
        tap(app, at: CGPoint(x: wide.frame.midX, y: wide.frame.midY))
        XCTAssertTrue(waitUntil { wide.isSelected && !main.isSelected }, "a tap selects Wide Display")
        XCTAssertEqual(app.staticTexts["displayOverviewSelectionTitle"].label, "Wide Display (Beta)", "the toolbar names the selection and marks Beta")
        XCTAssertTrue(show.isEnabled, "Show in Pane is offered for the selection")
        XCTAssertTrue(framesMatch(overviewTileFrames(app), fitAll), "a single tap does not move the camera")

        // Pinch out about the middle: the displays grow.
        let wideHeight = wide.frame.height
        window.pinch(withScale: 1.6, velocity: 1.0)
        XCTAssertTrue(waitUntil { wide.frame.height > wideHeight * 1.3 },
                      "a pinch zooms in (Wide Display \(wideHeight) -> \(wide.frame.height) pt tall)")
        keep(app, "overview-pinched")

        // Drag: the arrangement follows the finger.
        let beforePan = overviewTileFrames(app)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5)))
        XCTAssertTrue(waitUntil {
            let now = overviewTileFrames(app)
            return beforePan.contains { name, frame in (now[name]?.maxX ?? frame.maxX) < frame.maxX - 20 }
        }, "a drag pans the arrangement to the left")
        keep(app, "overview-panned")

        // After the camera moved, a tap lands on the display under it.
        let target = CGRect(x: canvas.minX + 8, y: canvas.minY + 16, width: canvas.width - 16, height: canvas.height - 32)
        let frames = overviewTileFrames(app)
        let visible = frames.mapValues { $0.intersection(target) }.filter { !$0.value.isNull && $0.value.width > 30 && $0.value.height > 30 }
        let selectedName = frames.keys.first { overviewTile(app, $0).isSelected }
        if let pick = visible.first(where: { $0.key != selectedName }) ?? visible.first {
            let name = pick.key, area = pick.value
            tap(app, at: CGPoint(x: area.midX, y: area.midY))
            XCTAssertTrue(waitUntil {
                overviewTile(app, name).isSelected
                    && frames.keys.filter { $0 != name }.allSatisfy { !overviewTile(app, $0).isSelected }
            }, "after a pinch and a pan, a tap at \(area) selects \(name) and only it")
            XCTAssertTrue(app.staticTexts["displayOverviewSelectionTitle"].label.hasPrefix(name)
                              && app.staticTexts["displayOverviewSelectionTitle"].label.hasSuffix(" (Beta)"),
                          "the toolbar names \(name) and marks Beta")
        } else {
            XCTFail("no display is left in view after the pinch and the pan to tap: \(frames) in \(target)")
        }

        // Fit All brings every display back, as at open.
        app.buttons["displayOverviewFitAll"].tap()
        XCTAssertTrue(waitUntil { framesMatch(overviewTileFrames(app), fitAll) },
                      "Fit All frames the whole arrangement again: \(overviewTileFrames(app)) vs \(fitAll)")
        for (name, frame) in overviewTileFrames(app) {
            XCTAssertTrue(canvas.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(name) \(frame) is back in the canvas")
        }
        keep(app, "overview-fit-all")

        // A double-tap on a display selects it and zooms to it.
        let portraitFit = portrait.frame
        doubleTap(app, at: CGPoint(x: portraitFit.midX, y: portraitFit.midY))
        XCTAssertTrue(waitUntil { portrait.isSelected && portrait.frame.height > portraitFit.height * 1.4 },
                      "a double-tap selects Portrait Display and zooms to it (\(portraitFit) -> \(portrait.frame))")
        keep(app, "overview-double-tap-display")

        // A double-tap on empty space is Fit All. Empty space: a point of the canvas no display covers.
        let covered = overviewTileFrames(app).values.map { $0.insetBy(dx: -8, dy: -8) }
        var empty: CGPoint?
        search: for row in 1..<12 {
            for column in 1..<12 {
                let point = CGPoint(x: target.minX + target.width * CGFloat(column) / 12,
                                    y: target.minY + target.height * CGFloat(row) / 12)
                if !covered.contains(where: { $0.contains(point) }) { empty = point; break search }
            }
        }
        if let empty {
            doubleTap(app, at: empty)
            XCTAssertTrue(waitUntil { framesMatch(overviewTileFrames(app), fitAll) },
                          "a double-tap on empty space at \(empty) fits all again")
        } else {
            print("AdaptiveLayout: the zoomed display covers the whole canvas; no empty space to double-tap")
            app.buttons["displayOverviewFitAll"].tap()
            XCTAssertTrue(waitUntil { framesMatch(overviewTileFrames(app), fitAll) })
        }
        XCTAssertTrue(portrait.isSelected, "fitting all keeps the selection")

        app.buttons["displayOverviewDone"].tap()
        XCTAssertTrue(waitUntil { !app.buttons["displayOverviewDone"].exists }, "Done closes the overview")
        XCTAssertTrue(app.buttons["uitestOpenOverview"].waitForExistence(timeout: 5))
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
