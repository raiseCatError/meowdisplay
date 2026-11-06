import CoreGraphics
import XCTest

/// The receiver's side of Fill Window on Mac / Restore Previous Size on Mac (Shared/WorkspaceClient.swift):
/// asked only from the explicit items, only when the Mac offers them, only with control; everything
/// that arranges this device's own view never sends it.
@MainActor
final class WorkspaceWindowFrameClientTests: XCTestCase {
    private func connected(features: Set<String>, control: SessionInputWireState = .allowed,
                           sent: @escaping ([String: Any]) -> Void) -> (WorkspaceModel, String) {
        let m = WorkspaceModel(defaults: UserDefaults(suiteName: "WorkspaceWindowFrameClientTests-\(UUID().uuidString)")!)
        m.send = { sent($0); return true }
        m.inputAllowed = { true }
        m.controlState = { control }
        m.floatsDrawnHere = true
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features(features))
        m.apply(.mode(window: true))
        m.apply(WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": [10, 11, 12].map { ["id": $0, "gen": 5, "bundle": "dev.zed.Zed", "app": "Zed", "title": "t\($0)", "w": 800, "h": 600, "state": "visible"] },
            "apps": [], "displays": [["id": 1, "name": "Built-in Display", "w": 1512, "h": 982, "main": true]],
        ])!)
        m.updateSpace(WorkspaceSize(width: 1180, height: 820), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        return (m, m.layout.orderedTileIDs[0])
    }

    private func state(_ tile: String, window: Int = 10, restore: Bool) -> WorkspaceEvent {
        var t: [String: Any] = ["id": tile, "window": window, "gen": 5, "state": "live", "app": "Zed"]
        if restore { t[WindowFrameWire.tileRestorable] = true }
        return WorkspaceEvent.parse(type: WireMessage.workspaceState, ["tiles": [t]])!
    }

    private let all: Set<String> = [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature, WindowFrameWire.welcomeFeature]

    private func frameRequests(_ sent: [[String: Any]]) -> [[String: Any]] {
        sent.filter { $0["type"] as? String == WindowFrameWire.request }
    }

    func testFillIsSentOnlyWhenTheMacOffersItAndThisDeviceHasControl() {
        var sent: [[String: Any]] = []
        // A Mac without `windowFrame`: not offered, never sent.
        let (old, oldTile) = connected(features: [WindowWorkspaceWire.welcomeFeature]) { sent.append($0) }
        XCTAssertFalse(old.offersWindowFrameOnMac(oldTile))
        old.fillWindowOnMac(oldTile)
        XCTAssertTrue(frameRequests(sent).isEmpty)

        // Offered, but View Only (asked, not granted): explained here, nothing sent.
        sent.removeAll()
        let (viewOnly, tile) = connected(features: all, control: .requesting) { sent.append($0) }
        XCTAssertTrue(viewOnly.offersWindowFrameOnMac(tile))
        XCTAssertFalse(viewOnly.canControlMac)
        viewOnly.fillWindowOnMac(tile)
        XCTAssertTrue(frameRequests(sent).isEmpty)
        XCTAssertEqual(viewOnly.windowFrameNotice?.result, .control)
        XCTAssertEqual(viewOnly.windowFrameNotice?.tile, tile)

        // With control: one request for exactly that window and generation.
        sent.removeAll()
        let (m, id) = connected(features: all) { sent.append($0) }
        m.fillWindowOnMac(id)
        let request = try? XCTUnwrap(frameRequests(sent).first)
        XCTAssertEqual(frameRequests(sent).count, 1)
        XCTAssertEqual(request?["op"] as? String, "fill")
        XCTAssertEqual(request?["window"] as? Int, 10)
        XCTAssertEqual(request?["gen"] as? Int, 5)
        XCTAssertTrue(m.isResizingOnMac(id))
        m.fillWindowOnMac(id)
        XCTAssertEqual(frameRequests(sent).count, 1, "one at a time per pane")

        // The answer clears the wait and is shown on that pane.
        m.apply(.frameResult(WindowFrameReply(op: .fill, windowID: 10, req: request?["req"] as? Int, result: .limited, restorable: true)))
        XCTAssertFalse(m.isResizingOnMac(id))
        XCTAssertEqual(m.windowFrameNotice, WindowFrameNotice(tile: id, windowID: 10, op: .fill, result: .limited))
        XCTAssertFalse(m.windowFrameNotice?.isError ?? true)
        // An answer nobody asked for is ignored.
        m.apply(.frameResult(WindowFrameReply(op: .restore, windowID: 99, req: 1234, result: .restored, restorable: false)))
        XCTAssertEqual(m.windowFrameNotice?.result, .limited)
    }

    func testRestoreIsOfferedOnlyWhileTheMacSaysItCanPutTheWindowBack() {
        var sent: [[String: Any]] = []
        let (m, id) = connected(features: all) { sent.append($0) }
        XCTAssertFalse(m.canRestoreOnMac(id))
        m.apply(state(id, restore: true))
        XCTAssertTrue(m.canRestoreOnMac(id))
        m.restoreWindowOnMac(id)
        XCTAssertEqual(frameRequests(sent).last?["op"] as? String, "restore")
        let req = frameRequests(sent).last?["req"] as? Int
        m.apply(.frameResult(WindowFrameReply(op: .restore, windowID: 10, req: req, result: .changed, restorable: false)))
        XCTAssertEqual(m.windowFrameNotice?.result, .changed)
        XCTAssertTrue(m.windowFrameNotice?.isError ?? false)
        m.apply(state(id, restore: false))
        XCTAssertFalse(m.canRestoreOnMac(id), "the Mac forgot the old size")
        // The flag belongs to the window the pane shows, not to a pane id that now shows another one.
        m.apply(state(id, window: 11, restore: true))
        XCTAssertFalse(m.canRestoreOnMac(id))
    }

    func testNotOfferedForADesktopPaneOrOutsideWindowView() {
        let (m, id) = connected(features: all) { _ in }
        m.apply(.mode(window: false))
        XCTAssertFalse(m.offersWindowFrameOnMac(id))
        m.apply(.disconnected)
        XCTAssertFalse(m.canResizeWindowsOnMac)
        XCTAssertNil(m.windowFrameNotice)
        XCTAssertTrue(m.windowFramePending.isEmpty)
    }

    /// Local resizing never touches the Mac window: Fill/Show Whole Window, zoom, rotation, divider
    /// drags, Fullscreen on This Device, floating, moving, resizing, tucking and docking a float.
    func testArrangingThisDevicesViewNeverResizesTheMacWindow() {
        var sent: [[String: Any]] = []
        let (m, id) = connected(features: all) { sent.append($0) }
        m.choose(m.catalog!.windows[1], asNewTile: true)
        m.toggleFit(id)
        m.rotate(id)
        m.resetView(id)
        let c = WorkspacePoint(x: 0.3, y: 0.5)
        _ = m.pinch(began: true, ended: false, isPinch: true, initial: c, current: c, scale: 1)
        _ = m.pinch(began: false, ended: true, isPinch: true, initial: c, current: c, scale: 2.5)
        m.toggleLocalFullscreen(id)
        m.toggleLocalFullscreen(id)
        m.toggleMaximize(id)
        m.toggleMaximize(id)
        m.openFloating(m.catalog!.windows[2])
        if let f = m.layout.floatIDs.first {
            m.beginFloatGesture(f)
            m.updateFloatFrame(f, WorkspaceRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9))
            m.endFloatGesture(f)
            m.tuckFloat(f, edge: .left, offset: 0.4)
            m.untuckFloat(f)
            m.enterLocalFullscreen(f)
            m.exitLocalFullscreen()
            m.addFloatToLayout(f)
        } else {
            XCTFail("no float")
        }
        m.undo(); m.redo()
        XCTAssertTrue(frameRequests(sent).isEmpty, "\(sent.compactMap { $0["type"] as? String })")
        XCTAssertFalse(sent.contains { $0["type"] as? String == WireMessage.windowAction })
    }

    func testStateParsingKeepsTheRestoreFlagBounded() {
        guard case .state(let s)? = WorkspaceEvent.parse(type: WireMessage.workspaceState, ["tiles": [
            ["id": "a", "window": 1, "gen": 1, "state": "live", "restore": true],
            ["id": "b", "window": 2, "gen": 1, "state": "live", "restore": "yes"],
            ["id": "c", "window": 3, "gen": 1, "state": "live"],
        ]]) else { return XCTFail("not parsed") }
        XCTAssertEqual(s.tiles.map(\.restorable), [true, false, false])
    }

    func testEveryResultHasItsOwnWords() {
        let texts = WindowFrameResult.allCases.map { WindowFrameNotice(tile: "t", windowID: 1, op: .fill, result: $0).message }
            + [WindowFrameNotice(tile: "t", windowID: 1, op: .fill, result: nil).message,
               WindowFrameNotice(tile: "t", windowID: 1, op: .restore, result: .failed).message]
        XCTAssertEqual(Set(texts).count, texts.count, "no two outcomes read the same")
        XCTAssertTrue(texts.allSatisfy { !$0.isEmpty })
    }
}
