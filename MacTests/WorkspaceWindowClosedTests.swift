import XCTest

/// Windows closed on the Mac leave the receiver's layout (PROTOCOL.md 6.10 `watch` / `gone`):
/// a floating pane goes (tucked too), a tab goes and its pane shows the next, and a pane whose last
/// window closed stays empty with Choose Window and Remove Pane. Only on the Mac's proof, only for
/// the generation held here: a window missing from one listing, a reconnect or a reused id never
/// changes the layout.
@MainActor
final class WorkspaceWindowClosedTests: XCTestCase {
    private var sent: [[String: Any]] = []
    private let box = WorkspaceRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4)

    private func src(_ id: UInt32) -> WorkspaceSource { WorkspaceSource(host: "mac-a", windowID: id, bundleID: "app.\(id)") }

    /// Pane a: window 10. Pane b: tabs 11 and 12 (11 shown). Float f: 13. Float g: 14, tucked.
    private func savedLayout() -> WorkspaceLayout {
        var b = WorkspaceTile(id: "b", source: src(11))
        b.tabs = [src(11), src(12)]
        var l = WorkspaceLayout(preset: .sideBySide, tiles: [WorkspaceTile(id: "a", source: src(10)), b])
        l.tiles["f"] = WorkspaceTile(id: "f", source: src(13))
        l.tiles["g"] = WorkspaceTile(id: "g", source: src(14))
        l.floats = [WorkspaceFloat(tile: "f", frame: box, tuck: nil),
                    WorkspaceFloat(tile: "g", frame: box, tuck: WorkspaceFloatTuck(edge: .right, offset: 0.5))]
        return l
    }

    private func catalog(_ ids: [UInt32], gen: Int = 5) -> WorkspaceEvent {
        WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": ids.map { ["id": Int($0), "gen": gen, "bundle": "app.\($0)", "app": "App\($0)", "title": "t", "w": 1600, "h": 1000, "state": "visible"] },
            "apps": [],
        ])!
    }

    private func gone(_ windows: [(UInt32, Int)]) -> WorkspaceEvent {
        WorkspaceEvent.parse(type: WireMessage.workspaceState, [
            "type": WireMessage.workspaceState, "host": "mac-a", "tiles": [], "hostFocus": "deliver",
            "gone": windows.map { ["window": Int($0.0), "gen": $0.1] },
        ])!
    }

    private func model(defaults: UserDefaults? = nil, listed: [UInt32] = [10, 11, 12, 13, 14]) -> (WorkspaceModel, UserDefaults) {
        let d = defaults ?? UserDefaults(suiteName: "WorkspaceWindowClosedTests-\(UUID().uuidString)")!
        if defaults == nil { d.set(WorkspaceLayoutRecord(savedLayout()).encoded(), forKey: "workspace.layout.mac-a") }
        let m = WorkspaceModel(defaults: d)
        m.floatsDrawnHere = true
        m.send = { [unowned self] in self.sent.append($0); return true }
        m.inputAllowed = { true }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]))
        m.apply(.mode(window: true))
        m.updateSpace(WorkspaceSize(width: 1180, height: 820), hinge: nil)
        m.apply(catalog(listed))
        return (m, d)
    }

    private func settle() {
        let exp = expectation(description: "debounced send")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    private func windows(_ m: WorkspaceModel, _ tile: String) -> [UInt32]? { m.layout.tiles[tile]?.windows.map(\.windowID) }

    // MARK: Wire

    /// Every window held here is watched, shown or not (the other tab, the tucked float), with
    /// the generation it was listed under.
    func testEveryHeldWindowIsWatched() {
        let (m, _) = model()
        settle()
        let request = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }
        let watch = (request?["watch"] as? [[String: Any]] ?? []).compactMap { w -> String? in
            guard let id = w["window"] as? Int, let gen = w["gen"] as? Int else { return nil }
            return "\(id)/\(gen)"
        }
        XCTAssertEqual(Set(watch), ["10/5", "11/5", "12/5", "13/5", "14/5"])
        XCTAssertEqual(m.layout.floatIDs.sorted(), ["f", "g"])
    }

    /// The state's `gone` is read; older Macs never send it.
    func testGoneIsParsed() {
        guard case .state(let s) = gone([(10, 5), (11, 6)]) else { return XCTFail() }
        XCTAssertEqual(s.gone, [WorkspaceHeldWindow(window: 10, generation: 5), WorkspaceHeldWindow(window: 11, generation: 6)])
        guard case .state(let old) = WorkspaceEvent.parse(type: WireMessage.workspaceState, ["type": WireMessage.workspaceState, "tiles": []])! else { return XCTFail() }
        XCTAssertTrue(old.gone.isEmpty)
    }

    // MARK: Floats

    /// A floating pane whose window closed goes, tucked or not; the panes stay as they were.
    func testClosedFloatsGoTuckedToo() {
        let (m, d) = model()
        let panes = m.layout.orderedTileIDs
        m.apply(gone([(13, 5), (14, 5)]))
        XCTAssertTrue(m.layout.floatIDs.isEmpty)
        XCTAssertNil(m.layout.tiles["f"]); XCTAssertNil(m.layout.tiles["g"])
        XCTAssertEqual(m.layout.orderedTileIDs, panes)
        XCTAssertFalse(m.canUndo, "not an edit the person made")
        let stored = d.data(forKey: "workspace.layout.mac-a").flatMap(WorkspaceLayoutRecord.decode)
        XCTAssertEqual(stored?.floatIDs, [], "saved without them")
    }

    /// A float being moved when its window closes: the gesture ends with it, nothing left behind.
    func testClosingDuringAFloatGestureEndsIt() {
        let (m, _) = model()
        m.beginFloatGesture("f")
        XCTAssertEqual(m.floatGesture, "f")
        m.apply(gone([(13, 5)]))
        XCTAssertNil(m.floatGesture)
        XCTAssertNil(m.layout.tiles["f"])
        XCTAssertNil(m.drag)
    }

    // MARK: Tabs and panes

    /// A closed tab goes and its pane shows the one left; when that closes too, the pane stays
    /// empty where it was.
    func testClosedTabLeavesItsPaneThenTheLastOneEmptiesIt() {
        let (m, _) = model()
        m.apply(gone([(11, 5)]))
        XCTAssertEqual(windows(m, "b"), [12], "the surviving tab shows")
        XCTAssertEqual(m.layout.tiles["b"]?.source?.windowID, 12)
        XCTAssertEqual(m.layout.orderedTileIDs, ["a", "b"])
        m.apply(gone([(11, 5), (12, 5)]))
        XCTAssertEqual(m.layout.orderedTileIDs, ["a", "b"], "the pane keeps its place")
        XCTAssertNil(m.layout.tiles["b"]?.source)
        XCTAssertEqual(m.layout.tiles["b"]?.emptied, true)
    }

    /// The last window of a pane closed: the pane stays empty (saved that way), Remove Pane takes
    /// it out, and Choose Window fills it.
    func testEmptiedPaneSurvivesReloadAndCanBeRemovedOrFilled() {
        let (m, d) = model()
        m.apply(gone([(10, 5)]))
        XCTAssertEqual(m.layout.orderedTileIDs, ["a", "b"])
        XCTAssertEqual(m.layout.tiles["a"]?.emptied, true)
        XCTAssertNil(m.layout.tiles["a"]?.source)

        let (reloaded, _) = model(defaults: d)
        XCTAssertEqual(reloaded.layout.tiles["a"]?.emptied, true, "kept across launches")

        m.openOverview(replacing: "a")
        m.apply(catalog([11, 12, 13, 14, 20]))
        m.choose(m.catalog!.windows.first { $0.id == 20 }!, asNewTile: false)
        XCTAssertEqual(m.layout.tiles["a"]?.source?.windowID, 20)
        XCTAssertEqual(m.layout.tiles["a"]?.emptied, false)

        reloaded.removeTile("a")
        XCTAssertNil(reloaded.layout.tiles["a"])
        XCTAssertEqual(reloaded.layout.orderedTileIDs, ["b"])
    }

    /// Undo never brings back a window that closed on the Mac.
    func testUndoDoesNotBringAClosedWindowBack() {
        let (m, _) = model()
        m.removeTile("b")
        m.apply(gone([(10, 5)]))
        m.undo()
        XCTAssertNotNil(m.layout.tiles["b"], "the person's own edit is undone")
        XCTAssertNil(m.layout.tiles["a"]?.source, "the closed window stays out")
        XCTAssertEqual(m.layout.tiles["a"]?.emptied, true)
    }

    // MARK: Never without proof

    /// Missing from a listing (minimized, another Space, Stage Manager, Mission Control): the
    /// layout keeps it, shown as unavailable. Only `gone` removes.
    func testMissingFromAListingChangesNothing() {
        let (m, _) = model()
        let before = m.layout
        m.apply(catalog([11, 12]))
        XCTAssertEqual(m.layout, before)
        XCTAssertTrue(m.missing.contains("a"))
    }

    /// A `gone` for another generation (the id reused by another window) or for a window this
    /// connection never listed changes nothing; after a reconnect, the proof starts over.
    func testWrongGenerationOrUnlistedOrReconnectNeverRemoves() {
        let (m, _) = model()
        let before = m.layout
        m.apply(gone([(10, 4), (13, 6), (99, 5)]))
        XCTAssertEqual(m.layout, before, "another generation: someone else's window")

        m.apply(.disconnected)
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]))
        m.apply(.mode(window: true))
        m.apply(gone([(10, 5)]))
        XCTAssertEqual(m.layout.tiles["a"]?.source?.windowID, 10, "not listed on this connection yet")
        XCTAssertEqual(m.layout.floatIDs.sorted(), ["f", "g"])
    }

    // MARK: Layout

    /// Compaction keeps an emptied pane, and only that kind of empty pane; a drop on it shows the
    /// window there.
    func testCompactionKeepsEmptiedPanesAndDropsFillThem() {
        let result = savedLayout().removingClosedWindows { $0.windowID == 10 }
        XCTAssertEqual(result.emptied, ["a"])
        XCTAssertTrue(result.removed.isEmpty)
        let compacted = result.layout.compacted()
        XCTAssertEqual(compacted.orderedTileIDs, ["a", "b"])
        var plain = compacted
        plain.tiles["a"]?.emptied = false
        XCTAssertEqual(plain.compacted().orderedTileIDs, ["b"], "any other empty pane still closes up")

        let size = WorkspaceSize(width: 1180, height: 820)
        let frames = WorkspaceGeometry.frames(for: compacted, in: size)
        let slot = frames.slots[0]
        let drop = WorkspaceGeometry.windowDrop(at: WorkspacePoint(x: slot.x + slot.width / 2, y: slot.y + slot.height / 2),
                                              layout: compacted, frames: frames, size: size, labelHeight: 0.04, canSplit: true)
        guard case .replace(let tile, _)? = drop else { return XCTFail("\(String(describing: drop))") }
        XCTAssertEqual(tile, "a")
        let filled = compacted.replacingSource(of: "a", with: src(20))
        XCTAssertEqual(filled.tiles["a"]?.emptied, false)
    }

    /// Stored with `emptied` only on an emptied pane; older layouts read as before.
    func testRecordKeepsEmptiedOnly() throws {
        let emptied = savedLayout().removingClosedWindows { $0.windowID == 10 }.layout
        let data = try XCTUnwrap(WorkspaceLayoutRecord(emptied).encoded())
        XCTAssertEqual(WorkspaceLayoutRecord.decode(data)?.tiles["a"]?.emptied, true)
        let plain = try XCTUnwrap(WorkspaceLayoutRecord(savedLayout()).encoded())
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("emptied"))
    }
}
