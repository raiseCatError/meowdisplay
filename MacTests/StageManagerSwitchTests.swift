import XCTest

/// Stage Manager is switched only with the owner's two shortcuts (macOS's own "Set Stage Manager"
/// action). Writing the preference was measured to have no effect (macOS 27.0),
/// so nothing here may write it; a change macOS doesn't apply is reported, never assumed.
final class StageManagerSwitchTests: XCTestCase {
    private var commands: [[String]] = []
    private var stageManagerOn = true
    private var listOutput = "Morning\nMeowDisplay Stage Manager Off\nMeowDisplay Stage Manager On\n"
    private var applies = true
    private var saved: (read: () -> Bool, run: ([String]) -> (status: Int32, output: String), settle: TimeInterval)!
    private let keys = [StageManagerSwitch.turnedOffKey, StageManagerSwitch.offDuringWindowModeKey]
    private var savedDefaults: [String: Any] = [:]

    override func setUp() {
        saved = (StageManagerSwitch.readIsOn, StageManagerSwitch.runShortcuts, StageManagerSwitch.settleTimeout)
        for k in keys { savedDefaults[k] = UserDefaults.standard.object(forKey: k); UserDefaults.standard.removeObject(forKey: k) }
        StageManagerSwitch.readIsOn = { [unowned self] in stageManagerOn }
        StageManagerSwitch.runShortcuts = { [unowned self] args in
            commands.append(args)
            if args.first == "list" { return (0, listOutput) }
            if args.first == "run", applies { stageManagerOn = args.last == StageManagerSwitch.onShortcut }
            return (0, "")
        }
        StageManagerSwitch.settleTimeout = 0.3
    }

    override func tearDown() {
        (StageManagerSwitch.readIsOn, StageManagerSwitch.runShortcuts, StageManagerSwitch.settleTimeout) = saved
        for k in keys { UserDefaults.standard.set(savedDefaults[k], forKey: k) }
    }

    func testTurnsOffWithTheOwnersShortcutAndBackOnAfterwards() {
        XCTAssertTrue(StageManagerSwitch.shortcutsReady(refresh: true))
        XCTAssertTrue(StageManagerSwitch.turnOffForWindowMode())
        XCTAssertFalse(stageManagerOn)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: StageManagerSwitch.turnedOffKey), "owes turning it back on")
        StageManagerSwitch.restoreIfTurnedOffByUs()
        XCTAssertTrue(stageManagerOn)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: StageManagerSwitch.turnedOffKey))
        XCTAssertEqual(commands.filter { $0.first == "run" }, [["run", StageManagerSwitch.offShortcut], ["run", StageManagerSwitch.onShortcut]])
        XCTAssertTrue(commands.allSatisfy { ["list", "run"].contains($0.first) }, "only Shortcuts, never a preference write")
    }

    func testWithoutTheShortcutsNothingRunsAndItSaysSo() {
        listOutput = "Morning\nMeowDisplay Stage Manager Off\n"   // the On one is missing
        XCTAssertFalse(StageManagerSwitch.shortcutsReady(refresh: true))
        XCTAssertEqual(StageManagerSwitch.shortcutsReadyKnown, false)
        XCTAssertFalse(StageManagerSwitch.turnOffForWindowMode())
        XCTAssertTrue(stageManagerOn)
        XCTAssertFalse(commands.contains { $0.first == "run" })
        XCTAssertFalse(UserDefaults.standard.bool(forKey: StageManagerSwitch.turnedOffKey))
    }

    func testAChangeMacOSDidNotApplyIsReportedNotAssumed() {
        XCTAssertTrue(StageManagerSwitch.shortcutsReady(refresh: true))
        applies = false
        XCTAssertFalse(StageManagerSwitch.turnOffForWindowMode())
        XCTAssertFalse(UserDefaults.standard.bool(forKey: StageManagerSwitch.turnedOffKey), "nothing to turn back on")
    }

    func testRestoreOnlyUndoesItsOwnChange() {
        stageManagerOn = false   // the owner turned it off themselves
        StageManagerSwitch.restoreIfTurnedOffByUs()
        XCTAssertFalse(stageManagerOn)
        XCTAssertTrue(commands.isEmpty)
    }
}
