import XCTest

/// Stage Manager is switched only with the owner's two shortcuts (macOS's own "Set Stage Manager"
/// action). Writing the preference was measured to have no effect (macOS 27.0), so nothing here
/// may write it. The shortcuts carry the owner's Dock settings so running them leaves the Dock
/// alone. Switching itself (counting, grace, owed restores, limits) is in StageManagerControllerTests.
final class StageManagerSwitchTests: XCTestCase {
    func testSetupFindsExactNamesAndNumberedCopiesOnly() {
        let list = "Morning\nMeowDisplay Stage Manager Off\nMeowDisplay Stage Manager Off 1\nMeowDisplay Stage Manager Onward\n"
        let found = StageManagerShortcutInstaller.inventory(listOutput: list)
        XCTAssertEqual(found.present, [StageManagerSwitch.offShortcut])
        XCTAssertEqual(found.copies, ["MeowDisplay Stage Manager Off 1"])
        XCTAssertEqual(StageManagerShortcutInstaller.missing(present: found.present), [StageManagerSwitch.onShortcut], "only the missing one is offered")
        XCTAssertEqual(StageManagerShortcutInstaller.missing(present: Set(StageManagerShortcutInstaller.names)), [])
    }

    func testEachShortcutFileSetsStageManagerAndLeavesTheDockAsTheOwnerHasIt() throws {
        for settings in [DockSettings(showDock: false, showRecentApps: true), DockSettings(showDock: true, showRecentApps: false)] {
            for on in [false, true] {
                let file = StageManagerShortcutInstaller.unsignedFile(on: on, settings: settings)
                let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: file, format: nil) as? [String: Any])
                let actions = try XCTUnwrap(plist["WFWorkflowActions"] as? [[String: Any]])
                XCTAssertEqual(actions.count, 1)
                XCTAssertEqual(actions[0]["WFWorkflowActionIdentifier"] as? String, "is.workflow.actions.stagemanager.set")
                let params = try XCTUnwrap(actions[0]["WFWorkflowActionParameters"] as? [String: Any])
                XCTAssertEqual(params["operation"] as? String, "set")
                XCTAssertEqual(params["state"] as? Bool, on)
                // Unset, the action turns both on (Dock hiding off) on every run, On or Off.
                XCTAssertEqual(params["showDock"] as? Bool, settings.showDock, "explicit, never the action's default")
                XCTAssertEqual(params["showRecentApps"] as? Bool, settings.showRecentApps)
            }
        }
        XCTAssertEqual(StageManagerShortcutInstaller.formatVersion, 2)
    }

    func testPrepareSignsEachMissingShortcutWithTheSupportedTool() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var calls: [[String]] = []
        let settings = DockSettings(showDock: false, showRecentApps: true)
        let files = try StageManagerShortcutInstaller.prepare([StageManagerSwitch.onShortcut], settings: settings, in: folder) { args in
            calls.append(args)
            if let o = args.firstIndex(of: "--output") { FileManager.default.createFile(atPath: args[o + 1], contents: Data("AEA1".utf8)) }
            return ToolRun(status: 0, output: "")
        }.get()
        XCTAssertEqual(files.map(\.lastPathComponent), ["MeowDisplay Stage Manager On.shortcut"], "named so Shortcuts uses the exact name")
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(Array(calls[0].prefix(3)), ["sign", "--mode", "anyone"])
        XCTAssertFalse(calls.contains { $0.first == "run" }, "setup never runs a shortcut")
        let unsigned = try Data(contentsOf: folder.appendingPathComponent("unsigned/MeowDisplay Stage Manager On.shortcut"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: unsigned, format: nil) as? [String: Any])
        let params = try XCTUnwrap((plist["WFWorkflowActions"] as? [[String: Any]])?.first?["WFWorkflowActionParameters"] as? [String: Any])
        XCTAssertEqual(params["state"] as? Bool, true)
        XCTAssertEqual(params["showDock"] as? Bool, false, "made with the settings it was given")
        XCTAssertEqual(params["showRecentApps"] as? Bool, true)
        XCTAssertEqual(StageManagerShortcutInstaller.prepare([StageManagerSwitch.offShortcut], settings: settings, in: folder) { _ in ToolRun(status: 1, output: "") },
                       .failure(.sign(1)))
    }

    // MARK: Running a tool (a harmless shell, never `shortcuts`)

    func testTheRunnerReadsLargeOutputWhileTheToolRuns() {
        // Far more than a pipe's buffer on both streams: read only after exit, the tool would wait forever.
        let script = #"head -c 300000 /dev/zero | tr '\0' o; head -c 200000 /dev/zero | tr '\0' e >&2; printf 'Error: done\n' >&2; exit 3"#
        let started = Date()
        let r = ToolRunner.run("/bin/sh", ["-c", script], timeout: 20)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(r.output.count, 300_000)
        XCTAssertEqual(r.errorOutput.count, 200_000 + "Error: done\n".count)
        XCTAssertEqual(r.errorSummary?.count, 160, "a long stderr line is shortened")
    }

    func testTheRunnerStopsAToolThatHangsAndSaysWhenOneCannotStart() {
        let started = Date()
        let r = ToolRunner.run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertEqual(r.status, -2)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(ToolRunner.run("/nonexistent/tool", [], timeout: 1).status, -1)
        XCTAssertEqual(ToolRun(status: 1, output: "", errorOutput: "\n  Error: first  \nsecond").errorSummary, "Error: first")
    }
}
