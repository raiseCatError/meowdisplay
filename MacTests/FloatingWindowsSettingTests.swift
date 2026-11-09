import CoreGraphics
import XCTest

/// Settings ▸ Controls ▸ Window Switcher ▸ Enable Floating Windows (WorkspaceModel): on by
/// default, also for existing installs; off blocks every way to make or move a float and puts
/// the floats there are into the layout; back on changes nothing. This device only.
@MainActor
final class FloatingWindowsSettingTests: XCTestCase {
    private let ipad = WorkspaceSize(width: 1180, height: 820)
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private func freshDefaults() -> UserDefaults {
        let name = "FloatingWindowsSettingTests-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    private func connectedModel(_ defaults: UserDefaults, size: WorkspaceSize? = nil,
                                sent: @escaping ([String: Any]) -> Void = { _ in }) -> WorkspaceModel {
        let m = WorkspaceModel(defaults: defaults)
        m.floatsDrawnHere = true   // the iPhone/iPad receiver (this test runs on the Mac)
        m.send = { sent($0); return true }
        m.inputAllowed = { true }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]))
        m.apply(.mode(window: true))
        m.apply(WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": (10...29).map { ["id": $0, "gen": 5, "bundle": "app.\($0)", "app": "App\($0)", "title": "t", "w": 1600, "h": 1000, "state": "visible"] },
            "apps": [], "displays": [],
        ])!)
        m.updateSpace(size ?? ipad, hinge: nil)
        return m
    }

    private func settle() {
        let exp = expectation(description: "debounced send")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    /// Every Mac window the layout holds (panes, tabs, floats).
    private func windowIDs(_ l: WorkspaceLayout) -> Set<UInt32> {
        Set(l.tiles.values.flatMap { $0.windows.map(\.windowID) })
    }

    /// One pane, a float in front and a tucked float.
    private func paneAndTwoFloats(_ m: WorkspaceModel) -> (pane: String, floats: [String]) {
        let w = m.catalog!.windows
        m.choose(w[0], asNewTile: false)
        let pane = m.layout.orderedTileIDs[0]
        m.openFloating(w[1])
        m.openFloating(w[2])
        let floats = m.layout.floatIDs
        XCTAssertEqual(floats.count, 2)
        m.tuckFloat(floats[0], edge: .right, offset: 0.5)
        XCTAssertNotNil(m.layout.float(floats[0])?.tuck)
        return (pane, floats)
    }

    // MARK: Default and migration

    func testOnByDefaultAndForExistingInstalls() {
        XCTAssertTrue(WorkspaceModel.floatingWindowsEnabled(in: freshDefaults()))

        // An install from before the switch: floats saved, Floating chosen, no switch stored.
        let defaults = freshDefaults()
        let before = connectedModel(defaults)
        before.defaultPlacement = .float
        let (_, floats) = paneAndTwoFloats(before)
        defaults.removeObject(forKey: WorkspaceModel.floatingWindowsKey)

        let after = connectedModel(defaults)
        XCTAssertTrue(after.floatingWindowsEnabled)
        XCTAssertNil(defaults.object(forKey: WorkspaceModel.floatingWindowsKey), "nothing written for it on launch")
        XCTAssertEqual(after.layout.floatIDs, floats, "existing floats kept")
        XCTAssertEqual(after.defaultPlacement, .float)
        XCTAssertTrue(after.canOpenFloats)
    }

    // MARK: Turning it off

    /// The switch as Settings writes it (@AppStorage on the same defaults): every float, tucked or
    /// not, joins the layout with its tile, window and focus; nothing is lost, nothing is a Mac
    /// window action, and no float goes to the Mac any more.
    func testOffPutsEveryFloatIntoTheLayoutAndKeepsEveryWindow() {
        let defaults = freshDefaults()
        var sent: [[String: Any]] = []
        let m = connectedModel(defaults) { sent.append($0) }
        let (_, floats) = paneAndTwoFloats(m)
        m.focus(floats[1])
        let windowsBefore = windowIDs(m.layout)
        sent.removeAll()

        defaults.set(false, forKey: WorkspaceModel.floatingWindowsKey)

        XCTAssertFalse(m.floatingWindowsEnabled)
        XCTAssertTrue(m.layout.floats.isEmpty, "no float left, none tucked at an edge")
        XCTAssertEqual(windowIDs(m.layout), windowsBefore, "every window still in the layout")
        for id in floats { XCTAssertTrue(m.layout.orderedTileIDs.contains(id), "\(id) is a pane now, same tile") }
        XCTAssertTrue(m.canFloat, "the Mac's capability is unchanged")
        settle()
        let request = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }?["tiles"] as? [[String: Any]] ?? []
        XCTAssertEqual(request.count, 3)
        XCTAssertTrue(request.allSatisfy { $0["layer"] == nil }, "no float sent")
        let allowed: Set<String> = [WireMessage.workspaceRequest, WireMessage.workspaceFocus, WireMessage.workspaceBackdropRequest,
                                    WireMessage.windowCatalogRequest, WireMessage.windowThumbnailRequest]
        XCTAssertTrue(sent.allSatisfy { allowed.contains($0["type"] as? String ?? "") },
                      "never a Mac window action: \(sent.map { $0["type"] ?? "" })")

        // Saved that way: the next launch has the panes, not floats.
        let relaunched = connectedModel(defaults)
        XCTAssertTrue(relaunched.layout.floats.isEmpty)
        XCTAssertEqual(windowIDs(relaunched.layout), windowsBefore)
    }

    /// No room for another pane: floats become tabs of the focused pane, the front one shown.
    func testOffWithAFullLayoutMakesTabs() {
        let defaults = freshDefaults()
        let small = WorkspaceSize(width: 320, height: 240)   // a small Split View or Slide Over window
        let m = connectedModel(defaults, size: small)
        let w = m.catalog!.windows
        let room = WorkspaceGeometry.capacity(for: small)
        XCTAssertLessThan(room + 1, w.count, "enough windows to fill \(room) panes and float two")
        XCTAssertLessThan(room, WorkspaceLayout.maximumTiles - 1, "room left for two floats")
        m.choose(w[0], asNewTile: false)
        for i in 1..<room { m.choose(w[i], asNewTile: true) }
        XCTAssertEqual(m.layout.paneCount, room)
        m.openFloating(w[room])
        m.openFloating(w[room + 1])
        let front = m.layout.floatIDs.last!
        let windowsBefore = windowIDs(m.layout)

        m.floatingWindowsEnabled = false

        XCTAssertTrue(m.layout.floats.isEmpty)
        XCTAssertEqual(m.layout.paneCount, room, "no pane pushed out of view")
        XCTAssertEqual(windowIDs(m.layout), windowsBefore)
        XCTAssertEqual(m.layout.tiles[front]?.source?.windowID, UInt32(w[room + 1].id), "the front float is the shown tab")
    }

    /// Off: no Float action, Stage Peek floating, drop zone, placement switch or Floating default.
    /// The saved Default Window Placement stays and comes back with the switch.
    func testOffBlocksEveryWayToFloatAndKeepsTheSavedPlacement() {
        let defaults = freshDefaults()
        let m = connectedModel(defaults)
        let w = m.catalog!.windows
        m.choose(w[0], asNewTile: false)
        m.choose(w[1], asNewTile: true)
        let pane = m.layout.orderedTileIDs[0]
        m.defaultPlacement = .float

        m.floatingWindowsEnabled = false

        XCTAssertFalse(m.canFloatPanes)
        XCTAssertFalse(m.canOpenFloats)
        XCTAssertFalse(m.canFloat(pane: pane))
        XCTAssertFalse(m.canPlace(.window(w[2]), .float))
        XCTAssertFalse(m.canPlace(.pane(pane, tab: nil), .float))
        XCTAssertEqual(m.defaultPlacement, .pane, "Pane used while off")
        XCTAssertEqual(defaults.string(forKey: WorkspaceModel.defaultPlacementKey), WorkspacePlacement.float.rawValue, "the choice is kept")

        m.openFloating(w[2])
        m.floatPane(pane)
        XCTAssertTrue(m.layout.floats.isEmpty, "Float actions do nothing")

        m.beginDrag(.window(w[2]), at: .zero)
        XCTAssertEqual(m.drag?.placement, .pane, "a drag starts in Pane placement")
        XCTAssertFalse(m.toggleDragPlacement(), "no switch to Floating")
        XCTAssertFalse(m.canDropToFloat, "no Float drop zone")
        m.cancelDrag()

        m.floatingWindowsEnabled = true
        XCTAssertEqual(m.defaultPlacement, .float)
        XCTAssertTrue(m.canOpenFloats)
        XCTAssertTrue(m.canFloat(pane: pane))
    }

    // MARK: Turning it back on, and layouts that come back with floats

    func testOnAgainChangesNothingAndLayoutsWithFloatsSettleWhileOff() {
        let defaults = freshDefaults()
        let m = connectedModel(defaults)
        let (_, floats) = paneAndTwoFloats(m)
        m.saveLayout(named: "With floats")
        let savedID = m.savedLayouts[0].id

        m.floatingWindowsEnabled = false
        let docked = m.layout
        m.floatingWindowsEnabled = true
        XCTAssertEqual(m.layout, docked, "no float comes back by itself")

        m.floatingWindowsEnabled = false
        m.applySaved(savedID)
        XCTAssertTrue(m.layout.floats.isEmpty, "a saved layout with floats opens as panes")
        m.undo()
        XCTAssertTrue(m.layout.floats.isEmpty, "undo never brings a float back while off")
        for id in floats { XCTAssertNotNil(m.layout.tiles[id], "\(id) kept") }
        XCTAssertEqual(m.savedLayouts.count, 1, "saved layouts aren't rewritten")
        XCTAssertFalse(m.savedLayouts[0].record.layout.floats.isEmpty)
    }
}
