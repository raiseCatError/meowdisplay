import XCTest

/// "Choose a window for this tile" ▸ an app that isn't open, against a real paired Mac on a
/// physical device: the owner's round-3 flow end to end. Opt-in: skips unless
/// MEOW_LIVE_SESSION_TESTS=1 (pass TEST_RUNNER_MEOW_LIVE_SESSION_TESTS=1 to xcodebuild).
///
/// Needs: the Mac in Window view for this device with at least one pane, control already allowed
/// for this session (the test never drives the Mac's approval prompt), and Calculator installed
/// and not showing a window. It opens Calculator on the Mac (without bringing it forward) and
/// checks its window lands in the pane the picker was opened for while the other panes and the
/// floats stay as they were. Nothing on the Mac is closed or quit: quit Calculator afterwards.
final class LivePickerOpenAppQATests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private static let appName = "Calculator"
    private static let bundleID = "com.apple.calculator"

    @MainActor
    func testPickerOpensCalculatorIntoThePaneItWasOpenedFor() throws {
        guard env["MEOW_LIVE_SESSION_TESTS"] == "1" else {
            throw XCTSkip("live session test: set MEOW_LIVE_SESSION_TESTS=1 with a paired Mac nearby")
        }
        let app = XCUIApplication()
        app.launch()
        try connectInWindowView(app)
        sleep(3)
        snapshot(app, "picker-01-window-view")

        // 1. The pane to open the picker for, and what everything else shows.
        let panes = paneStates(app)
        guard !panes.isEmpty else { throw XCTSkip("no Window-view pane") }
        if panes.contains(where: { $0.title == Self.appName }) {
            throw XCTSkip("\(Self.appName) already shows in a pane: not the \"not running\" case. Quit it on the Mac and run again.")
        }
        let paneElements = app.descendants(matching: .any).matching(identifier: "workspacePane").allElementsBoundByIndex
        guard let target = panes.indices.first(where: { i in
            panes[i].title != "Empty" && app.paneTitleFrame(.paneTitle(panes[i].title), in: paneElements[i]) != nil
        }) else {
            snapshot(app, "picker-no-title-chip")
            throw XCTSkip("no pane with a title-sized title chip at its top; not holding a pane")
        }
        let others = panes.enumerated().filter { $0.offset != target }.map(\.element)
        let floatsBefore = floatLabels(app)
        print("LIVE picker target pane \(target) '\(panes[target].title)' at \(panes[target].frame); others=\(others.map(\.title)) floats=\(floatsBefore)")

        // 2. Its Change Window… (Show a Window Here… for a desktop pane), then search.
        try app.holdPaneTitle(.paneTitle(panes[target].title), in: paneElements[target])
        let change = app.buttons.matching(NSPredicate(format: "label == 'Change Window…' OR label == 'Show a Window Here…'")).firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 5), "the pane menu offers Change Window…")
        snapshot(app, "picker-02-pane-menu")
        change.tap()
        let search = app.textFields["windowPickerSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the picker opens")
        XCTAssertTrue(app.staticTexts["Choose a window for this tile"].exists, "opened for this tile")
        search.tap()
        search.typeText(Self.appName + "\n")   // Return ends editing: the keyboard leaves the rows uncovered
        sleep(2)
        snapshot(app, "picker-03-search")

        let windowCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(Self.appName):")).firstMatch
        if windowCard.exists {
            closePicker(app)
            throw XCTSkip("\(Self.appName) already has a window on the Mac: not the \"not running\" case. Quit it on the Mac and run again.")
        }
        let row = app.buttons["pickerOpenApp.\(Self.bundleID)"]
        guard row.waitForExistence(timeout: 10) else {
            snapshot(app, "picker-no-app-row")
            closePicker(app)
            throw XCTSkip("\(Self.appName) isn't listed under Apps to Open (not installed, or the Mac's app list didn't arrive)")
        }

        // 3. Tap it, then confirm. Control must already be allowed.
        row.tap()
        let open = app.buttons["Open \(Self.appName)"]
        let requestControl = app.buttons["Request Control and Open"]
        XCTAssertTrue(waitUntil(5) { open.exists || requestControl.exists }, "opening is confirmed first")
        snapshot(app, "picker-04-confirm")
        if !open.exists {
            app.buttons["Cancel"].firstMatch.tap()
            closePicker(app)
            throw XCTSkip("this session has no control of the Mac (the confirm offers Request Control and Open); allow control first")
        }
        open.tap()
        snapshot(app, "picker-05-opening")

        // 4. The same pane shows Calculator within 30 s; nothing else changed.
        let failure = app.alerts.firstMatch
        let choice = app.staticTexts["Which \(Self.appName) window?"]
        var placed = false
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if paneStates(app).contains(where: { $0.title == Self.appName && Self.samePlace($0.frame, panes[target].frame) }) {
                placed = true
                break
            }
            if failure.exists {
                snapshot(app, "picker-failed")
                XCTFail("the picker reported a problem: \(failure.label)")
                return
            }
            if choice.exists {
                // Several new windows: the person picks (here, the first offered).
                snapshot(app, "picker-06-choice")
                let options = app.sheets.firstMatch.buttons.allElementsBoundByIndex.filter { $0.label != "Cancel" }
                guard let first = options.first else { XCTFail("a choice with no windows"); return }
                first.tap()
            }
            usleep(250_000)
        }
        sleep(1)
        snapshot(app, "picker-07-result")
        XCTAssertTrue(placed, "\(Self.appName)'s window shows in the pane the picker was opened for")
        XCTAssertFalse(search.exists, "the picker closed")
        let after = paneStates(app)
        XCTAssertEqual(after.count, panes.count, "no pane added or removed")
        for other in others {
            XCTAssertTrue(after.contains { Self.samePlace($0.frame, other.frame) && $0.title == other.title },
                          "the pane '\(other.title)' at \(other.frame) is unchanged: \(after)")
        }
        XCTAssertEqual(floatLabels(app), floatsBefore, "the floats are unchanged")
    }

    // MARK: Helpers

    private struct PaneState: CustomStringConvertible {
        var title: String
        var frame: CGRect
        var description: String { "\(title)@\(Int(frame.minX)),\(Int(frame.minY))" }
    }

    /// Every Window-view pane: its title (the label without " pane") and where it is.
    @MainActor
    private func paneStates(_ app: XCUIApplication) -> [PaneState] {
        app.descendants(matching: .any).matching(identifier: "workspacePane").allElementsBoundByIndex.map {
            PaneState(title: $0.label.hasSuffix(" pane") ? String($0.label.dropLast(" pane".count)) : $0.label, frame: $0.frame)
        }
    }

    @MainActor
    private func floatLabels(_ app: XCUIApplication) -> [String] {
        app.descendants(matching: .any).matching(identifier: "workspaceFloat").allElementsBoundByIndex.map(\.label).sorted()
    }

    /// The same pane slot (a window changing in a pane doesn't move it).
    private static func samePlace(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.midX - b.midX) < 4 && abs(a.midY - b.midY) < 4
    }

    @MainActor
    private func closePicker(_ app: XCUIApplication) {
        let done = app.buttons["Done"]
        if done.exists { done.tap() }
    }

    @MainActor
    private func connectInWindowView(_ app: XCUIApplication) throws {
        let reconnect = app.buttons["Reconnect"]
        let connect = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH 'Connect to' OR label BEGINSWITH 'Wake and connect to' OR label BEGINSWITH 'Try again with'"
        )).firstMatch
        let pane = app.descendants(matching: .any).matching(identifier: "workspacePane").firstMatch
        let yes = app.buttons["windowModePromptYes"]
        let tapUntil = Date().addingTimeInterval(12)
        while Date() < tapUntil, !pane.exists {
            if reconnect.exists { reconnect.tap(); break }
            if connect.exists { connect.tap(); break }
            usleep(250_000)
        }
        let deadline = Date().addingTimeInterval(45)
        while !pane.exists, Date() < deadline {
            if yes.exists { yes.tap() }
            usleep(250_000)
        }
        guard pane.exists else { snapshot(app, "picker-no-session"); throw XCTSkip("no Window-view session with a paired Mac") }
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
