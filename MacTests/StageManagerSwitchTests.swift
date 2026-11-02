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

    func testSetupFindsExactNamesAndNumberedCopiesOnly() {
        let list = "Morning\nMeowDisplay Stage Manager Off\nMeowDisplay Stage Manager Off 1\nMeowDisplay Stage Manager Onward\n"
        let found = StageManagerShortcutInstaller.inventory(listOutput: list)
        XCTAssertEqual(found.present, [StageManagerSwitch.offShortcut])
        XCTAssertEqual(found.copies, ["MeowDisplay Stage Manager Off 1"])
        XCTAssertEqual(StageManagerShortcutInstaller.missing(present: found.present), [StageManagerSwitch.onShortcut], "only the missing one is offered")
        XCTAssertEqual(StageManagerShortcutInstaller.missing(present: Set(StageManagerShortcutInstaller.names)), [])
    }

    func testEachShortcutFileHoldsTheSystemSetStageManagerAction() throws {
        for on in [false, true] {
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: StageManagerShortcutInstaller.unsignedFile(on: on), format: nil) as? [String: Any])
            let actions = try XCTUnwrap(plist["WFWorkflowActions"] as? [[String: Any]])
            XCTAssertEqual(actions.count, 1)
            XCTAssertEqual(actions[0]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.stagemanager.set")
            let params = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
            XCTAssertEqual(params["operation"] as? String, "set")
            XCTAssertEqual(params["state"] as? Bool, on)
        }
    }

    func testPrepareSignsEachMissingShortcutWithTheSupportedTool() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var calls: [[String]] = []
        StageManagerSwitch.runShortcuts = { args in
            calls.append(args)
            if let o = args.firstIndex(of: "--output") { FileManager.default.createFile(atPath: args[o + 1], contents: Data("AEA1".utf8)) }
            return (0, "")
        }
        let files = try StageManagerShortcutInstaller.prepare([StageManagerSwitch.onShortcut], in: folder).get()
        XCTAssertEqual(files.map(\.lastPathComponent), ["MeowDisplay Stage Manager On.shortcut"], "named so Shortcuts uses the exact name")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(Array(calls[0].prefix(3)), ["sign", "--mode", "anyone"])
        XCTAssertFalse(calls.contains { $0.first == "run" }, "setup never runs a shortcut")
        StageManagerSwitch.runShortcuts = { _ in (1, "") }
        XCTAssertEqual(StageManagerShortcutInstaller.prepare([StageManagerSwitch.offShortcut], in: folder), .failure(.sign(1)))
    }
}
