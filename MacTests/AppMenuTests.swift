import XCTest

/// Pane menus (PROTOCOL.md 6.13): what the Mac sends and what the receiver asks for and presses.
@MainActor
final class AppMenuTests: XCTestCase {
    func testShortcutsAndPaths() {
        XCTAssertEqual(AppMenuReader.shortcut(char: "s", modifiers: 0), "⌘S")
        XCTAssertEqual(AppMenuReader.shortcut(char: "Z", modifiers: 1), "⇧⌘Z")
        XCTAssertEqual(AppMenuReader.shortcut(char: "F", modifiers: 4 | 2), "⌃⌥⌘F")
        XCTAssertEqual(AppMenuReader.shortcut(char: "x", modifiers: 8 | 4), "⌃X", "no Command")
        XCTAssertNil(AppMenuReader.shortcut(char: "", modifiers: 0))
        XCTAssertTrue(AppMenuReader.isValidPath([1, 3], titles: ["File", "Save"]))
        XCTAssertFalse(AppMenuReader.isValidPath([0, 3], titles: ["Apple", "Restart…"]), "never the Apple menu")
        XCTAssertFalse(AppMenuReader.isValidPath([1, 3], titles: ["File"]), "a title for every step")
        XCTAssertFalse(AppMenuReader.isValidPath([], titles: []))
        XCTAssertFalse(AppMenuReader.isValidPath([1, 2, 3, 4, 5], titles: ["a", "b", "c", "d", "e"]), "bounded depth")
        XCTAssertEqual(AppMenuItem(index: 4, title: "Save", shortcut: "⌘S").wire["key"] as? String, "⌘S")
        XCTAssertEqual(AppMenuItem(index: 5, title: "", separator: true).wire["sep"] as? Bool, true)
    }

    func testBarFollowsTheFocusedPaneAndPressesWithTitles() {
        var sent: [[String: Any]] = []
        let defaults = UserDefaults(suiteName: "AppMenuTests-\(UUID().uuidString)")!
        let m = AppMenuModel(defaults: defaults)
        m.send = { sent.append($0); return true }
        m.setAvailable(true)
        XCTAssertTrue(m.barShown, "on by default")

        m.sync(tile: "w1", bundle: "dev.zed.Zed", enabled: false)
        XCTAssertTrue(sent.isEmpty, "no control: nothing is read")
        m.sync(tile: "w1", bundle: "dev.zed.Zed", enabled: true)
        XCTAssertEqual(sent.last?["type"] as? String, "menuRequest")
        XCTAssertEqual(sent.last?["path"] as? [Int], [])
        m.sync(tile: "w1", bundle: "dev.zed.Zed", enabled: true)
        XCTAssertEqual(sent.count, 1, "same pane, same app: no new request")
        let topReq = sent.last?["req"] as? Int
        m.apply(AppMenuReply.parse(["type": "menu", "tile": "w1", "path": [], "app": "Zed", "req": topReq!,
                                    "items": [["i": 1, "t": "Zed", "sub": true], ["i": 2, "t": "File", "sub": true]]])!)
        XCTAssertEqual(m.app, "Zed")
        XCTAssertEqual(m.top.map(\.title), ["Zed", "File"])

        m.openMenu(m.top[1])
        XCTAssertEqual(sent.last?["path"] as? [Int], [2])
        let fileReq = sent.last?["req"] as? Int
        m.apply(AppMenuReply.parse(["type": "menu", "tile": "w1", "path": [2], "req": fileReq!,
                                    "items": [["i": 0, "t": "New File", "key": "⌘N"], ["i": 1, "sep": true],
                                              ["i": 2, "t": "Open Recent", "sub": true], ["i": 3, "t": "Save", "on": false]]])!)
        XCTAssertEqual(m.open.last?.items.count, 4)
        XCTAssertEqual(m.open.last?.items[0].shortcut, "⌘N")
        XCTAssertTrue(m.open.last?.items[1].separator == true)

        // A disabled item is never pressed; a submenu opens; a leaf presses with every title on the way.
        let before = sent.count
        m.press(m.open.last!.items[3])
        XCTAssertEqual(sent.count, before)
        m.openSubmenu(m.open.last!.items[2])
        XCTAssertEqual(sent.last?["path"] as? [Int], [2, 2])
        m.apply(AppMenuReply.parse(["type": "menu", "tile": "w1", "path": [2, 2], "req": sent.last?["req"] as! Int,
                                    "items": [["i": 0, "t": "notes.md"]]])!)
        m.press(m.open.last!.items[0])
        XCTAssertEqual(sent.last?["type"] as? String, "menuPress")
        XCTAssertEqual(sent.last?["path"] as? [Int], [2, 2, 0])
        XCTAssertEqual(sent.last?["titles"] as? [String], ["File", "Open Recent", "notes.md"])
        XCTAssertTrue(m.open.isEmpty, "the drop-down closes")

        // Another pane's app: its own menus.
        m.sync(tile: "w2", bundle: "com.google.Chrome", enabled: true)
        XCTAssertTrue(m.top.isEmpty)
        XCTAssertEqual(sent.last?["tile"] as? String, "w2")
        // A late answer for the old pane is ignored.
        m.apply(AppMenuReply.parse(["type": "menu", "tile": "w1", "path": [], "app": "Zed", "items": [["i": 1, "t": "Zed"]]])!)
        XCTAssertTrue(m.top.isEmpty)
        m.setAvailable(false)
        XCTAssertNil(m.tile)
    }
}

/// Window mode audio (A1–A3): which apps a receiver hears.
final class WindowAudioSourcesTests: XCTestCase {
    private func tile(_ id: String, pid: Int32, display: UInt32? = nil) -> WorkspaceTileAssignment {
        var a = WorkspaceTileAssignment(tileID: id, rect: WorkspaceRect(x: 0, y: 0, width: 1, height: 1), windowID: 10, windowGeneration: 1,
                                        pid: pid, bundleID: "b", follow: .window, rotation: .none, fit: .auto, assignmentGeneration: 1)
        a.displayID = display
        return a
    }

    func testOnlyShownAppsAndNothingWithoutWindows() {
        XCTAssertEqual(WindowAudioSources.of([]), .apps([]), "no pane shows a window: silence")
        XCTAssertEqual(WindowAudioSources.of([tile("a", pid: 11), tile("b", pid: 12), tile("c", pid: 11)]), .apps([11, 12]))
        XCTAssertEqual(WindowAudioSources.of([tile("a", pid: 11), tile("d", pid: 0, display: 1)]), .everything, "a desktop pane: all sound")
    }
}
