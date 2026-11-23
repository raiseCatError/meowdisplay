import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// The Apple receivers' window-workspace client (Shared/WorkspaceClient.swift).
@MainActor
final class WorkspaceClientTests: XCTestCase {
    private func catalog(_ windows: [(UInt32, UInt64, String)]) -> WorkspaceEvent {
        WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": windows.map { ["id": Int($0.0), "gen": Int($0.1), "bundle": $0.2, "app": $0.2, "title": "t\($0.0)", "w": 800, "h": 600, "state": "visible"] },
            "apps": [["bundle": "dev.zed.Zed", "name": "Zed", "windows": true]],
        ])!
    }

    private func model(sent: @escaping ([String: Any]) -> Void) -> WorkspaceModel {
        let defaults = UserDefaults(suiteName: "WorkspaceClientTests-\(UUID().uuidString)")!
        let m = WorkspaceModel(defaults: defaults)
        m.send = { sent($0); return true }
        m.inputAllowed = { true }
        return m
    }

    private func restoreCatalog(generation: Int? = 5, minimized: Bool = true) -> WorkspaceEvent {
        let windows: [[String: Any]] = generation.map {
            [["id": 10, "gen": $0, "bundle": "dev.zed.Zed", "app": "Zed",
              "title": "Original", "state": minimized ? "offscreen" : "visible"]]
        } ?? []
        return WorkspaceEvent.parse(type: WireMessage.windowCatalog,
                                    ["host": "mac-a", "windows": windows, "apps": []])!
    }

    func testShowMinimizedWindowRequestsControlAndRestoresOnceAfterMacApproval() throws {
        var sent: [[String: Any]] = []
        var requests = 0
        var control = SessionInputWireState.off
        let m = model { if $0["type"] as? String == WireMessage.windowAction { sent.append($0) } }
        m.controlState = { control }
        m.requestControlForWindowShow = { requests += 1; return true }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.restoreOffscreenFeature]))
        m.apply(restoreCatalog())
        let window = try XCTUnwrap(m.catalog?.windows.first)

        XCTAssertFalse(m.windowMode, "Stage Peek can restore directly from Mirror")
        XCTAssertEqual(m.minimizedWindowAction(window), .request)
        m.showMinimizedWindow(window)
        m.showMinimizedWindow(window)
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(sent.isEmpty)
        control = .requesting
        m.windowShowControlChanged(control)
        control = .allowed
        m.windowShowControlChanged(control)
        m.windowShowControlChanged(control)
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?["window"] as? Int, 10)
        XCTAssertEqual(sent.first?["gen"] as? Int, 5)
        XCTAssertEqual(sent.first?["ifOffscreen"] as? Bool, true)
        XCTAssertEqual(m.minimizedWindowAction(window), .show)
    }

    func testPendingShowRejectsDenialCancellationChangedTargetAndReconnection() throws {
        let interruptions: [(WorkspaceModel) -> Void] = [
            { $0.windowShowControlChanged(.notAllowed) },
            { $0.windowShowControlChanged(.off) },
            { $0.cancelWindowShow() },
            { $0.apply(self.restoreCatalog(generation: nil)) },
            { $0.apply(self.restoreCatalog(generation: 6)) },
            { $0.apply(self.restoreCatalog(minimized: false)) },
            { $0.apply(.mode(window: false)) },
            { $0.apply(.connected(peerID: "mac-a")) },
            { $0.apply(.disconnected) },
        ]
        for interrupt in interruptions {
            var activations = 0
            var control = SessionInputWireState.off
            let m = model { if $0["type"] as? String == WireMessage.windowAction { activations += 1 } }
            m.controlState = { control }
            m.apply(.connected(peerID: "mac-a"))
            m.apply(.features([WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.restoreOffscreenFeature]))
            m.apply(.mode(window: true))
            m.apply(restoreCatalog())
            m.requestControlForWindowShow = { true }
            XCTAssertFalse(m.windowShowPending)
            m.showMinimizedWindow(try XCTUnwrap(m.catalog?.windows.first))
            XCTAssertTrue(m.windowShowPending)
            control = .requesting
            m.windowShowControlChanged(control)
            interrupt(m)
            control = .allowed
            m.windowShowControlChanged(control)
            XCTAssertEqual(activations, 0)
            XCTAssertFalse(m.windowShowPending)
        }
    }

    func testMinimizedRestoreRequiresPromptForDeferredActionAndAllowsExplicitShowWithControl() throws {
        var activations = 0
        var control = SessionInputWireState.off
        let m = model { if $0["type"] as? String == WireMessage.windowAction { activations += 1 } }
        m.controlState = { control }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.restoreOffscreenFeature]))
        m.apply(.mode(window: true))
        m.apply(restoreCatalog())
        let window = try XCTUnwrap(m.catalog?.windows.first)
        m.requestControlForWindowShow = { true }
        m.showMinimizedWindow(window)
        control = .allowed
        m.windowShowControlChanged(control)
        XCTAssertEqual(activations, 0)
        m.showMinimizedWindow(window)
        XCTAssertEqual(activations, 1)
    }

    func testExpiredShowWithdrawsTheOutstandingControlRequest() throws {
        var now: TimeInterval = 1
        var control = SessionInputWireState.off
        var withdrawals = 0
        var activations = 0
        let m = model { if $0["type"] as? String == WireMessage.windowAction { activations += 1 } }
        m.clock = { now }
        m.controlState = { control }
        m.requestControlForWindowShow = { true }
        m.withdrawControlForWindowShow = { withdrawals += 1 }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.restoreOffscreenFeature]))
        m.apply(.mode(window: true))
        m.apply(restoreCatalog())
        m.showMinimizedWindow(try XCTUnwrap(m.catalog?.windows.first))
        control = .requesting
        m.windowShowControlChanged(control)
        now += 61
        control = .allowed
        m.windowShowControlChanged(control)
        XCTAssertEqual(withdrawals, 1)
        XCTAssertEqual(activations, 0)
        XCTAssertFalse(m.windowShowPending)
    }

    private func catalogWithDisplay(_ windows: [(UInt32, UInt64, String)]) -> WorkspaceEvent {
        WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": windows.map { ["id": Int($0.0), "gen": Int($0.1), "bundle": $0.2, "app": $0.2, "title": "t\($0.0)", "w": 800, "h": 600, "state": "visible"] },
            "apps": [], "displays": [["id": 1, "name": "Built-in Display", "w": 1512, "h": 982, "main": true]],
        ])!
    }

    /// No empty panes: a window leaving a pane closes it up; one window fills the picture.
    func testEmptyPanesCloseUpAndOneWindowFillsThePicture() {
        let tiles = (0..<3).map { WorkspaceTile(id: "t\($0)", source: WorkspaceSource(host: "mac-a", windowID: UInt32(10 + $0))) }
        let grid = WorkspaceLayout(preset: .grid2x2, tiles: tiles)
        XCTAssertEqual(grid.root.slotCount, 4, "a 2x2 preset with three windows has a hole")
        let compact = grid.compacted()
        XCTAssertEqual(compact.root.slotCount, 3)
        XCTAssertEqual(Set(compact.tiles.keys), ["t0", "t1", "t2"])
        let frames = WorkspaceGeometry.frames(for: compact, in: WorkspaceSize(width: 400, height: 800), hinge: nil)
        let area = frames.tiles.values.reduce(0) { $0 + $1.width * $1.height }
        XCTAssertEqual(area, 1, accuracy: 1e-9, "the rest grow to fill the picture")
        let one = compact.removing("t1").removing("t2").compacted()
        XCTAssertEqual(one.root, .slot("t0"), "one window fills everything")
        let emptyTile = WorkspaceLayout(preset: .sideBySide, tiles: [tiles[0], WorkspaceTile(id: "e")]).compacted()
        XCTAssertEqual(emptyTile.root, .slot("t0"), "a pane without a window is closed")
        XCTAssertEqual(WorkspaceLayout().compacted().root, .slot(nil), "nothing at all: the single empty pane stays")
    }

    /// Instant zoom: during a pinch the pane gets a local preview (the picture it had, moved about
    /// the fingers, uniformly) and asks the Mac for its whole source; the request carries the
    /// pane's zoom and a view epoch the Mac echoes; a two-finger double-tap puts the pane back to 1x Fit.
    func testPinchGivesAnInstantPreviewSendsTheViewAndDoubleTapResetsThePane() {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 5, "dev.zed.Zed")]))
        m.updateSpace(WorkspaceSize(width: 800, height: 600), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        guard let id = m.layout.orderedTileIDs.first else { return XCTFail("no pane") }
        XCTAssertEqual(m.layout.tiles[id]?.fit, .fit, "new panes are Fit")
        let c = WorkspacePoint(x: 0.5, y: 0.5)
        XCTAssertTrue(m.pinch(began: true, ended: false, isPinch: true, initial: c, current: c, scale: 1))
        XCTAssertTrue(sent.contains { $0["type"] as? String == WireMessage.workspaceBackdropRequest && $0["tile"] as? String == id },
                      "the whole source is asked for at once")
        XCTAssertTrue(m.pinch(began: false, ended: false, isPinch: true, initial: c, current: c, scale: 2))
        guard let p = m.zoomPreview else { return XCTFail("no preview") }
        XCTAssertEqual(p.tile, id)
        XCTAssertEqual(p.scaleX, 2, accuracy: 1e-6)
        XCTAssertEqual(p.scaleY, p.scaleX, accuracy: 1e-6, "zoom never stretches")
        let fixed = p.apply(c)
        XCTAssertEqual(fixed.x, 0.5, accuracy: 1e-6); XCTAssertEqual(fixed.y, 0.5, accuracy: 1e-6)
        // Zooming out below 1x is allowed (0.7x), smoothly through 1x.
        XCTAssertTrue(m.pinch(began: false, ended: false, isPinch: true, initial: c, current: c, scale: 0.5))
        XCTAssertEqual(m.layout.tiles[id]?.zoom?.scale ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertTrue(m.pinch(began: false, ended: true, isPinch: true, initial: c, current: WorkspacePoint(x: 0.6, y: 0.5), scale: 2))
        XCTAssertNotNil(m.zoomPreview, "kept until the Mac's frame with this view arrives")
        XCTAssertNotNil(m.layout.tiles[id]?.zoom)
        m.resetView(at: WorkspacePoint(x: 0.2, y: 0.8))
        XCTAssertNil(m.layout.tiles[id]?.zoom, "double-tap resets the pane")
        XCTAssertEqual(m.layout.tiles[id]?.fit, .fit)
    }

    func testTheMacEchoesTheViewItComposed() async throws {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 5, "dev.zed.Zed")]))
        m.updateSpace(WorkspaceSize(width: 800, height: 600), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        let id = try XCTUnwrap(m.layout.orderedTileIDs.first)
        // The request goes out after a short debounce. Wait for it to be sent rather than a
        // fixed time: on a busy CI runner the debounced task can run later than 200 ms.
        let deadline = Date().addingTimeInterval(5)
        while !sent.contains(where: { $0["type"] as? String == WireMessage.workspaceRequest }), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let request = try XCTUnwrap(sent.last { $0["type"] as? String == WireMessage.workspaceRequest })
        let tile = try XCTUnwrap((request["tiles"] as? [[String: Any]])?.first)
        let epoch = try XCTUnwrap(tile["view"] as? Int)
        XCTAssertNil(tile["crop"], "no capture crop is ever asked for")
        XCTAssertFalse(m.viewComposed(id))
        m.apply(.view([id: epoch]))
        XCTAssertTrue(m.viewComposed(id))
    }

    func testPausedStalledAndFailedPanesAreReportedAndRetried() {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        let state = WorkspaceEvent.parse(type: WireMessage.workspaceState, ["tiles": [
            ["id": "a", "window": 1, "gen": 1, "state": "paused", "strip": true, "app": "Zed"],
            ["id": "b", "window": 2, "gen": 1, "state": "retrying", "attempt": 3],
            ["id": "c", "window": 3, "gen": 1, "state": "nonsense"],
        ]])
        guard case .state(let s)? = state else { return XCTFail("not parsed") }
        XCTAssertEqual(s.tiles.map(\.status), [.paused, .retrying, .waiting])
        XCTAssertTrue(s.tiles[0].inStageStrip)
        XCTAssertEqual(s.tiles[1].attempt, 3)
        m.retryTile("b")
        XCTAssertEqual(sent.last?["type"] as? String, WireMessage.workspaceRetry)
        XCTAssertEqual(sent.last?["tile"] as? String, "b")
    }

    /// Undo, redo and a saved layout put back later (one undo step), kept per Mac.
    func testSavedLayoutsAndRedo() {
        let defaults = UserDefaults(suiteName: "WorkspaceClientTests-\(UUID().uuidString)")!
        func make() -> WorkspaceModel {
            let m = WorkspaceModel(defaults: defaults)
            m.send = { _ in true }
            m.inputAllowed = { true }
            m.apply(.connected(peerID: "mac-a"))
            m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
            m.apply(.mode(window: true))
            m.apply(catalog([(10, 5, "dev.zed.Zed"), (11, 6, "com.apple.Safari")]))
            m.updateSpace(WorkspaceSize(width: 844, height: 390), hinge: nil)
            return m
        }
        let m = make()
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.choose(m.catalog!.windows[1], asNewTile: true)
        let two = m.layout
        XCTAssertEqual(two.tiles.count, 2)
        m.saveLayout(named: "  Coding  ")
        XCTAssertEqual(m.savedLayouts.map(\.name), ["Coding"])
        m.removeTile(two.orderedTileIDs[1])
        XCTAssertEqual(m.layout.tiles.count, 1)
        m.undo()
        XCTAssertEqual(m.layout.tiles.count, 2)
        XCTAssertTrue(m.canRedo)
        m.redo()
        XCTAssertEqual(m.layout.tiles.count, 1)
        m.applySaved(m.savedLayouts[0].id)
        XCTAssertEqual(Set(m.layout.tiles.values.compactMap { $0.source?.windowID }), [10, 11])
        m.undo()
        XCTAssertEqual(m.layout.tiles.count, 1, "applying a saved layout is one undo step")
        // Kept for this Mac across sessions.
        let again = make()
        XCTAssertEqual(again.savedLayouts.map(\.name), ["Coding"])
        again.deleteSavedLayout(again.savedLayouts[0].id)
        XCTAssertTrue(make().savedLayouts.isEmpty)
    }

    /// The double tap on a pane label toggles Fullscreen on This Device: presentation only, the
    /// arrangement (order, sizes, every pane) comes back exactly; nothing is asked of the Mac's windows.
    func testDoubleTapFullscreenToggleRestoresTheExactLayout() {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 5, "dev.zed.Zed"), (11, 6, "com.apple.Safari")]))
        m.updateSpace(WorkspaceSize(width: 844, height: 390), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.choose(m.catalog!.windows[1], asNewTile: true)
        let before = m.layout
        let second = before.orderedTileIDs[1]
        sent.removeAll()
        m.toggleLocalFullscreen(second)
        XCTAssertEqual(m.localFullscreen, second)
        XCTAssertEqual(m.layout.maximized, second)
        m.toggleLocalFullscreen(second)
        XCTAssertNil(m.localFullscreen)
        XCTAssertEqual(m.layout, before, "the prior split, order and sizes come back")
        let types = sent.compactMap { $0["type"] as? String }
        XCTAssertFalse(types.contains(WireMessage.windowClose))
        XCTAssertFalse(types.contains(WireMessage.windowAction))
    }

    /// The zones sit 12 pt apart (HStack spacing) with 8 pt of touch slop
    /// each, so their margins overlap: there Cancel lights, the haptic says
    /// Cancel, and a release must not remove the pane.
    func testCancelWinsWhereTheCancelAndRemoveMarginsMeet() {
        let m = model { _ in }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 5, "dev.zed.Zed"), (11, 6, "com.apple.Safari")]))
        m.updateSpace(WorkspaceSize(width: 400, height: 800), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.choose(m.catalog!.windows[1], asNewTile: true)
        m.pictureGlobal = CGRect(x: 0, y: 0, width: 400, height: 800)
        m.cancelZoneGlobal = CGRect(x: 40, y: 720, width: 120, height: 44)    // ends at x 160
        m.removeZoneGlobal = CGRect(x: 172, y: 720, width: 160, height: 44)   // 12 pt later
        let before = m.layout
        let between = CGPoint(x: 166, y: 740)   // inside both 8 pt margins

        m.beginDrag(.pane(before.orderedTileIDs[0], tab: nil), at: CGPoint(x: 200, y: 20))
        m.moveDrag(to: between)
        XCTAssertTrue(m.overCancelZone(between))
        XCTAssertFalse(m.overRemoveZone(between), "only one zone lights at a time")
        XCTAssertFalse(m.endDrag())
        XCTAssertEqual(m.layout, before, "released between the zones: nothing removed")

        // Just past Cancel's margin, Remove still works.
        let onRemoveEdge = CGPoint(x: 170, y: 740)
        m.beginDrag(.pane(before.orderedTileIDs[0], tab: nil), at: CGPoint(x: 200, y: 20))
        m.moveDrag(to: onRemoveEdge)
        XCTAssertTrue(m.overRemoveZone(onRemoveEdge))
        XCTAssertTrue(m.endDrag())
        XCTAssertEqual(m.layout.tiles.count, 1)
    }

    /// Remove from Layout as a drop target: only for repositioning a whole pane already in the
    /// layout with another left; never for a Stage Peek window or app; Cancel changes nothing;
    /// removal is one undo step and never closes or minimizes the Mac window.
    func testDraggingAPaneToRemoveTakesItOutOfTheLayoutOnly() {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 5, "dev.zed.Zed"), (11, 6, "com.apple.Safari")]))
        m.updateSpace(WorkspaceSize(width: 400, height: 800), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.choose(m.catalog!.windows[1], asNewTile: true)
        m.pictureGlobal = CGRect(x: 0, y: 0, width: 400, height: 800)
        m.cancelZoneGlobal = CGRect(x: 40, y: 720, width: 120, height: 44)
        m.removeZoneGlobal = CGRect(x: 200, y: 720, width: 160, height: 44)
        let before = m.layout
        let pane = before.orderedTileIDs[0]
        let onRemove = CGPoint(x: 280, y: 740)

        // A Stage Peek window or app is never offered Remove, and a drop there removes nothing.
        m.beginDrag(.window(m.catalog!.windows[0]), at: CGPoint(x: 200, y: 400))
        XCTAssertFalse(m.canDropToRemove)
        m.moveDrag(to: onRemove)
        XCTAssertFalse(m.overRemoveZone(onRemove))
        m.cancelDrag()
        m.beginDrag(.app(MacAppItem(bundleID: "dev.zed.Zed", name: "Zed", running: true, windowCount: 1, lastUsed: nil)), at: CGPoint(x: 200, y: 400))
        XCTAssertFalse(m.canDropToRemove)
        m.cancelDrag()
        // A pane with one window has no real tab label to remove.
        m.beginDrag(.pane(pane, tab: 0), at: CGPoint(x: 200, y: 20))
        XCTAssertFalse(m.canDropToRemove)
        m.cancelDrag()
        XCTAssertEqual(m.layout, before)

        // A whole pane: Cancel leaves everything as it was.
        m.beginDrag(.pane(pane, tab: nil), at: CGPoint(x: 200, y: 20))
        XCTAssertTrue(m.canDropToRemove)
        m.moveDrag(to: CGPoint(x: 100, y: 740))
        XCTAssertFalse(m.endDrag())
        XCTAssertEqual(m.layout, before)

        // Dropped on Remove: gone from this layout only, undoable.
        sent.removeAll()
        m.beginDrag(.pane(pane, tab: nil), at: CGPoint(x: 200, y: 20))
        m.moveDrag(to: onRemove)
        XCTAssertNil(m.dropTarget(forGlobal: onRemove), "Remove is not also a pane drop")
        XCTAssertTrue(m.endDrag())
        XCTAssertEqual(m.layout.tiles.count, 1)
        XCTAssertNil(m.layout.tiles[pane])
        let types = sent.compactMap { $0["type"] as? String }
        XCTAssertFalse(types.contains(WireMessage.windowClose), "never closes the Mac window")
        XCTAssertFalse(types.contains(WireMessage.windowAction), "never minimizes it")
        m.undo()
        XCTAssertEqual(m.layout.tiles.count, 2)

        // The last pane: neither the drop zone nor its menu offers Remove (#120).
        XCTAssertTrue(m.canRemoveFromLayout(m.layout.orderedTileIDs[0]))
        m.removeTile(m.layout.orderedTileIDs[1])
        XCTAssertFalse(m.canRemoveFromLayout(m.layout.orderedTileIDs[0]))
        XCTAssertFalse(m.canRemoveFromLayout("no-such-pane"))
        m.beginDrag(.pane(m.layout.orderedTileIDs[0], tab: nil), at: CGPoint(x: 200, y: 20))
        XCTAssertFalse(m.canDropToRemove)
        m.moveDrag(to: onRemove)
        _ = m.endDrag()
        XCTAssertEqual(m.layout.tiles.count, 1)
    }

    func testDraggingAnExistingTabToRemovePreservesItsPaneAndOtherStreams() throws {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 5, "a"), (11, 6, "b"), (12, 7, "c")]))
        m.updateSpace(WorkspaceSize(width: 400, height: 800), hinge: nil)
        let windows = try XCTUnwrap(m.catalog?.windows)
        m.choose(windows[0], asNewTile: false)
        m.choose(windows[2], asNewTile: true)
        let pane = try XCTUnwrap(m.layout.orderedTileIDs.first)
        let whole = WorkspaceRect(x: 0, y: 0, width: 1, height: 1)
        m.drop(windows[1], on: .tab(tile: pane, preview: whole))
        XCTAssertEqual(m.layout.tiles[pane]?.tabs.map(\.windowID), [10, 11])
        m.pictureGlobal = CGRect(x: 0, y: 0, width: 400, height: 800)
        m.removeZoneGlobal = CGRect(x: 200, y: 720, width: 160, height: 44)
        m.floatZoneGlobal = m.removeZoneGlobal
        let onRemove = CGPoint(x: 280, y: 740)

        m.beginDrag(.pane(pane, tab: 1), at: CGPoint(x: 200, y: 20))
        XCTAssertTrue(m.canDropToRemove)
        m.moveDrag(to: onRemove)
        XCTAssertTrue(m.overRemoveZone(onRemove))
        XCTAssertFalse(m.overFloatZone(onRemove))
        XCTAssertTrue(m.endDrag())
        XCTAssertEqual(m.layout.tiles[pane]?.source?.windowID, 10)
        XCTAssertEqual(Set(m.layout.tiles.values.compactMap { $0.source?.windowID }), [10, 12])
        let types = sent.compactMap { $0["type"] as? String }
        XCTAssertFalse(types.contains(WireMessage.windowClose))
        XCTAssertFalse(types.contains(WireMessage.windowAction))
        m.undo()
        XCTAssertEqual(m.layout.tiles[pane]?.tabs.map(\.windowID), [10, 11])

        // The first tab disappears while the second is held. Its old index cannot remove another source.
        m.beginDrag(.pane(pane, tab: 1), at: CGPoint(x: 200, y: 20))
        m.removeTab(pane, at: 0)
        m.moveDrag(to: onRemove)
        XCTAssertFalse(m.canDropToRemove)
        XCTAssertFalse(m.endDrag())
        XCTAssertEqual(m.layout.tiles[pane]?.source?.windowID, 11)
    }

    /// An app dragged onto a pane: its one window goes there; several → the person picks; none →
    /// offered to open it (control), and its first new window then goes where it was dropped.
    /// Nothing opens because a drag began or ended.
    func testAnAppDroppedOnAPanePlacesItsWindowOrAsks() {
        var sent: [[String: Any]] = []
        var control = true
        let m = model { sent.append($0) }
        m.inputAllowed = { control }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 5, "dev.zed.Zed"), (11, 5, "com.apple.Safari"), (12, 5, "com.apple.Safari")]))
        m.updateSpace(WorkspaceSize(width: 400, height: 800), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.pictureGlobal = CGRect(x: 0, y: 0, width: 400, height: 800)
        let edge = CGPoint(x: 200, y: 780)   // the bottom edge: a new pane
        func app(_ b: String) -> MacAppItem { MacAppItem(bundleID: b, name: b, running: true, windowCount: 0, lastUsed: nil) }
        func shown() -> Set<UInt32> { Set(m.layout.tiles.values.compactMap { $0.source?.windowID }) }
        func launches() -> [String] { sent.filter { $0["type"] as? String == WireMessage.appLaunch }.compactMap { $0["bundle"] as? String } }

        // Several windows: nothing moves until one is picked.
        m.beginDrag(.app(app("com.apple.Safari")), at: CGPoint(x: 200, y: 400))
        m.moveDrag(to: edge)
        XCTAssertTrue(m.endDrag())
        guard let several = m.appDrop else { return XCTFail("expected a chooser") }
        XCTAssertEqual(several.windows.map(\.id), [11, 12])
        XCTAssertEqual(shown(), [10])
        m.completeAppDrop(several, with: several.windows[1])
        XCTAssertNil(m.appDrop)
        XCTAssertEqual(shown(), [10, 12])

        // None: offered to open it; dropping alone never opens anything.
        m.beginDrag(.app(app("com.apple.TextEdit")), at: CGPoint(x: 200, y: 400))
        m.moveDrag(to: edge)
        XCTAssertFalse(m.endDrag())
        guard let none = m.appDrop else { return XCTFail("expected the open offer") }
        XCTAssertTrue(none.windows.isEmpty)
        XCTAssertEqual(launches(), [])
        // Without control nothing launches: control is asked for first (Request Control & Open).
        var now: TimeInterval = 100
        m.clock = { now }
        control = false
        m.openAppForDrop(none, requestingControl: true)
        XCTAssertEqual(launches(), [])
        XCTAssertEqual(m.appOpening?.phase, .awaitingControl)
        control = true
        m.advanceAppOpening()
        XCTAssertEqual(launches(), ["com.apple.TextEdit"], "it opens once the Mac allows control")
        m.apply(catalog([(10, 5, "dev.zed.Zed"), (11, 5, "com.apple.Safari"), (12, 5, "com.apple.Safari"), (20, 1, "com.apple.TextEdit")]))
        XCTAssertFalse(shown().contains(20), "a moment for other windows opening with it")
        now += WorkspaceAppOpening.settle
        m.advanceAppOpening()
        XCTAssertTrue(shown().contains(20), "its new window goes where it was dropped")
        XCTAssertNil(m.appOpening)

        // One window: straight in, no question.
        let before = m.layout.tiles.count
        m.beginDrag(.app(app("com.apple.Safari")), at: CGPoint(x: 200, y: 400))
        m.moveDrag(to: CGPoint(x: 400, y: 1000))   // outside the picture: nothing
        XCTAssertFalse(m.endDrag())
        XCTAssertNil(m.appDrop)
        XCTAssertEqual(m.layout.tiles.count, before)
        m.apply(catalog([(10, 5, "dev.zed.Zed")]))
        m.beginDrag(.app(app("dev.zed.Zed")), at: CGPoint(x: 200, y: 400))
        m.moveDrag(to: edge)
        XCTAssertTrue(m.endDrag())
        XCTAssertNil(m.appDrop)
    }

    /// Mirror/Extend: a window dropped on the desktop's edge starts Window mode with the
    /// desktop and the window side by side; the desktop is sent as a display, never a window.
    func testAWindowDroppedOnTheDesktopStartsWindowModeBesideIt() {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(catalogWithDisplay([(10, 5, "dev.zed.Zed")]))
        var requested = false
        m.requestWindowMode = { requested = true; return true }
        m.desktopPictureGlobal = CGRect(x: 0, y: 0, width: 400, height: 800)
        m.cancelZoneGlobal = CGRect(x: 120, y: 700, width: 160, height: 44)
        let w = m.catalog!.windows[0]
        // Dropped on Cancel: nothing changes.
        m.beginDrag(.window(w), at: CGPoint(x: 200, y: 400))
        m.moveDrag(to: CGPoint(x: 200, y: 720))
        XCTAssertNil(m.dropTarget(forGlobal: CGPoint(x: 200, y: 720)))
        XCTAssertFalse(m.endDrag())
        XCTAssertFalse(requested)
        // Dropped on the bottom edge: desktop on top, the window below.
        m.beginDrag(.window(w), at: CGPoint(x: 200, y: 400))
        m.moveDrag(to: CGPoint(x: 200, y: 640))
        guard case .split = m.dropTarget(forGlobal: CGPoint(x: 200, y: 640)) else { return XCTFail("expected a split") }
        XCTAssertTrue(m.endDrag())
        XCTAssertTrue(requested, "Window mode starts")
        m.apply(.mode(window: true))
        m.updateSpace(WorkspaceSize(width: 400, height: 800), hinge: nil)
        m.apply(catalogWithDisplay([(10, 5, "dev.zed.Zed")]))
        XCTAssertEqual(m.layout.tiles.count, 2)
        let sources = m.layout.orderedTileIDs.compactMap { m.layout.tiles[$0]?.source }
        XCTAssertEqual(sources.map(\.isDisplay), [true, false])
        let exp = expectation(description: "send")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        let request = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }
        let tiles = request?["tiles"] as? [[String: Any]] ?? []
        XCTAssertEqual(tiles.count, 2)
        XCTAssertEqual(tiles.compactMap { $0["display"] as? Int }, [1])
        XCTAssertEqual(tiles.compactMap { $0["window"] as? Int }, [10], "the desktop is never sent as a window number")
        // 2x2 with two windows showing: open windows fill the grid, never an empty pane.
        m.apply(catalogWithDisplay([(10, 5, "dev.zed.Zed"), (11, 1, "a"), (12, 1, "b"), (13, 1, "c")]))
        m.apply(.grid2x2)
        XCTAssertEqual(m.layout.tiles.count, 4)
        XCTAssertEqual(m.layout.root.slotCount, 4)
        XCTAssertTrue(m.layout.tiles.values.allSatisfy { $0.source != nil })
    }

    func testStartingWindowModeIsNotAListingFailure() {
        // The Mac answers "starting" when a catalog request beats Window mode's engine.
        guard case .catalog(let starting)? = WorkspaceEvent.parse(type: WireMessage.windowCatalog,
                                                                 ["windows": [], "apps": [], "error": "starting"]) else { return XCTFail() }
        XCTAssertTrue(starting.starting)
        XCTAssertFalse(starting.unavailable, "the picker keeps asking instead of blaming Screen Recording")
        guard case .catalog(let failed)? = WorkspaceEvent.parse(type: WireMessage.windowCatalog,
                                                               ["windows": [], "apps": [], "error": "unavailable"]) else { return XCTFail() }
        XCTAssertTrue(failed.unavailable)
        XCTAssertFalse(failed.starting)
    }

    func testAWindowInStageManagersStripIsBadgedNotShownAsLive() {
        guard case .catalog(let c)? = WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "windows": [
                ["id": 1, "bundle": "dev.zed.Zed", "app": "Zed", "title": "a", "w": 800, "h": 600, "state": "visible"],
                ["id": 2, "bundle": "com.apple.Safari", "app": "Safari", "title": "b", "state": "offscreen"],
                ["id": 3, "bundle": "com.apple.Notes", "app": "Notes", "title": "c", "w": 560, "h": 412, "state": "visible", "strip": true],
            ], "apps": [],
        ]) else { return XCTFail("expected catalog") }
        XCTAssertEqual(c.windows.map(\.inStageStrip), [false, false, true])
        XCTAssertEqual(c.windows.map(\.pausedBadge), [nil, "Minimized", "In Strip"])
        XCTAssertEqual(c.windows[2].width, 560, "the real window's size, not the strip thumbnail's")
    }

    func testParsingIsBoundedAndDefensive() {
        let state = WorkspaceEvent.parse(type: WireMessage.workspaceState, [
            "tiles": [["id": "a", "window": 10, "gen": 2, "state": "live", "app": "Zed"], ["id": "b", "state": "bogus"], ["window": 3]],
            "active": "a", "hostFocus": "otherWindowFocused", "rejected": ["c": "unavailable", "d": 7],
        ])
        guard case .state(let s)? = state else { return XCTFail("expected state") }
        XCTAssertEqual(s.tiles.map(\.id), ["a", "b"])
        XCTAssertEqual(s.tiles[1].status, .waiting)
        XCTAssertTrue(s.hostFocus.isMismatch)
        XCTAssertEqual(s.rejected, ["c": "unavailable"])
        let huge = String(repeating: "A", count: WorkspaceEvent.maxBase64 + 4)
        guard case .thumbnail(_, _, let data, _)? = WorkspaceEvent.parse(type: WireMessage.windowThumbnail, ["id": 1, "jpeg": huge]) else {
            return XCTFail("expected thumbnail")
        }
        XCTAssertNil(data, "oversized stills are dropped before decoding")
        XCTAssertNil(WorkspaceEvent.parse(type: WireMessage.appIcon, ["bundle": "x", "png": huge]))
        XCTAssertNil(WorkspaceEvent.parse(type: "somethingElse", [:]))
    }

    func testChoosingAWindowSendsOnlyListedWindowsWithTheirGeneration() {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        XCTAssertTrue(m.available)
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 5, "dev.zed.Zed"), (11, 6, "com.apple.Safari")]))
        m.updateSpace(WorkspaceSize(width: 844, height: 390), hinge: nil)
        var requested = false
        m.requestWindowMode = { requested = true; return true }
        m.choose(m.catalog!.windows[0], asNewTile: false)
        XCTAssertFalse(requested, "already in Window mode")
        XCTAssertEqual(m.layout.tiles.count, 1)
        m.choose(m.catalog!.windows[1], asNewTile: true)
        XCTAssertEqual(m.layout.tiles.count, 2)
        let exp = expectation(description: "debounced send")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        let request = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }
        let tiles = request?["tiles"] as? [[String: Any]] ?? []
        XCTAssertEqual(tiles.compactMap { $0["window"] as? Int }.sorted(), [10, 11])
        XCTAssertEqual(tiles.first { $0["window"] as? Int == 10 }?["gen"] as? Int, 5)
        XCTAssertTrue(tiles.allSatisfy { $0["host"] as? String == "mac-a" })

        // Removing a tile never closes a Mac window; closing is its own message.
        sent.removeAll()
        let ids = m.layout.orderedTileIDs
        m.removeTile(ids[1])
        XCTAssertFalse(sent.contains { $0["type"] as? String == WireMessage.windowAction })
        m.closeRemoteWindow(ids[0])
        let close = sent.last { $0["type"] as? String == WireMessage.windowAction }
        XCTAssertEqual(close?["action"] as? String, "close")
        XCTAssertEqual(close?["gen"] as? Int, 5)
    }

    /// Stage Peek browsing (hold, scrub, expand, lift) only refreshes the
    /// catalog and thumbnails; the layout and the Mac's windows are untouched.
    /// A tap on a card replaces only the active tile's window.
    func testStagePeekBrowsingChangesNothingAndATapReplacesOnlyTheActiveTile() {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 1, "dev.qa.a"), (11, 1, "dev.qa.b"), (12, 1, "dev.qa.c")]))
        m.updateSpace(WorkspaceSize(width: 844, height: 390), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.choose(m.catalog!.windows[1], asNewTile: true)
        let ids = m.layout.orderedTileIDs
        XCTAssertEqual(ids.count, 2)
        let state = WorkspaceEvent.parse(type: WireMessage.workspaceState, [
            "tiles": [["id": ids[0], "window": 10, "gen": 1, "state": "live"], ["id": ids[1], "window": 11, "gen": 1, "state": "live"]],
            "active": ids[1]])!
        m.apply(state)
        XCTAssertEqual(m.currentWindowID, 11, "Stage Peek starts on the active tile's window")
        let settle = expectation(description: "debounced send")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)

        let before = m.layout
        sent.removeAll()
        m.stagePeekOpen = true
        m.stagePeekOpen = false
        let browse = expectation(description: "nothing else is sent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { browse.fulfill() }
        wait(for: [browse], timeout: 2)
        XCTAssertEqual(m.layout, before)
        XCTAssertFalse(sent.isEmpty, "opening refreshes the catalog")
        XCTAssertTrue(sent.allSatisfy {
            [WireMessage.windowCatalogRequest, WireMessage.windowThumbnailRequest, WireMessage.appCatalogRequest].contains($0["type"] as? String)
        }, "browsing sends only read-only catalog, app list and thumbnail requests: \(sent.map { $0["type"] ?? "?" })")
        XCTAssertFalse(sent.contains { [WireMessage.displayModeRequest, WireMessage.workspaceRequest, WireMessage.appLaunch,
                                         WireMessage.windowAction].contains($0["type"] as? String) },
                       "browsing never changes the mode, the tiles or the Mac")

        m.switchTo(m.catalog!.windows[2])
        XCTAssertEqual(m.layout.orderedTileIDs, ids, "no tile added or removed")
        XCTAssertEqual(m.layout.tiles[ids[0]]?.source?.windowID, 10, "the other tile keeps its window")
        XCTAssertEqual(m.layout.tiles[ids[1]]?.source?.windowID, 12)
    }

    /// Found on the Moto: with two tiles waiting for windows and none active,
    /// a Stage Peek tap added a third tile. It fills the first waiting one.
    func testStagePeekFillsAWaitingTileInsteadOfAddingOne() {
        let m = model { _ in }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature]))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 1, "dev.qa.a"), (11, 1, "dev.qa.b"), (12, 1, "dev.qa.c")]))
        m.updateSpace(WorkspaceSize(width: 390, height: 844), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.choose(m.catalog!.windows[1], asNewTile: true)
        let ids = m.layout.orderedTileIDs
        // Both windows close on the Mac; nothing is active.
        m.apply(catalog([(12, 1, "dev.qa.c")]))
        XCTAssertEqual(m.missing, Set(ids))
        XCTAssertNil(m.active)
        XCTAssertEqual(m.switchTarget, ids[0])
        m.switchTo(m.catalog!.windows[0])
        XCTAssertEqual(m.layout.orderedTileIDs, ids, "no tile added")
        XCTAssertEqual(m.layout.tiles[ids[0]]?.source?.windowID, 12)
        XCTAssertEqual(m.layout.tiles[ids[1]]?.source?.windowID, 11)
    }

    func testTheSameWindowNumberOnAnotherMacNeverReachesThisMacsTiles() {
        let m = model { _ in }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.mode(window: true))
        m.apply(catalog([(30, 1, "dev.zed.Zed")]))
        m.updateSpace(WorkspaceSize(width: 1366, height: 1024), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        XCTAssertEqual(m.layout.tiles.values.compactMap { $0.source?.windowID }, [30])
        // Another Mac, same window number and even the same app: its own (empty) arrangement.
        m.apply(.connected(peerID: "mac-other"))
        m.apply(.mode(window: true))
        m.apply(catalog([(30, 1, "dev.zed.Zed")]))
        XCTAssertTrue(m.layout.tiles.values.allSatisfy { $0.source == nil }, "nothing carried over from mac-a")
        // Back on the first Mac, its tile is still there.
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.mode(window: true))
        m.apply(catalog([(30, 1, "dev.zed.Zed")]))
        XCTAssertEqual(m.layout.tiles.values.compactMap { $0.source?.windowID }, [30])
    }

    func testAReconnectKeepsOnlyTheSameWindowOfTheSameApp() {
        let m = model { _ in }
        m.apply(.connected(peerID: "mac-b"))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 1, "dev.zed.Zed"), (11, 1, "com.apple.Safari")]))
        m.updateSpace(WorkspaceSize(width: 1366, height: 1024), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.choose(m.catalog!.windows[1], asNewTile: true)
        // New Mac session: window 10 now belongs to another app, 11 is the same Safari window.
        m.apply(catalog([(10, 1, "com.apple.Terminal"), (11, 1, "com.apple.Safari")]))
        let zedTile = m.layout.tiles.first { $0.value.source?.windowID == 10 }?.key
        XCTAssertNotNil(zedTile)
        XCTAssertTrue(m.missing.contains(zedTile!), "a reused id for another app is never retargeted")
        XCTAssertEqual(m.missing.count, 1)
    }

    func testChoosingAWindowForAClosedTileShowsAndSendsIt() {
        var sent: [[String: Any]] = []
        let m = model { sent.append($0) }
        m.apply(.connected(peerID: "mac-d"))
        m.apply(.mode(window: true))
        m.apply(catalog([(10, 1, "dev.qa.probe")]))
        m.updateSpace(WorkspaceSize(width: 390, height: 844), hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        let tile = m.layout.orderedTileIDs[0]
        // The window closes and the app opens a new one.
        m.apply(catalog([(12, 1, "dev.qa.probe")]))
        XCTAssertEqual(m.missing, [tile])
        m.openOverview(replacing: tile)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        XCTAssertTrue(m.missing.isEmpty, "the tile shows its new window, not \"Choose a window\"")
        let exp = expectation(description: "debounced send")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
        let request = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }
        XCTAssertEqual((request?["tiles"] as? [[String: Any]])?.compactMap { $0["window"] as? Int }, [12])
    }

    func testOneDividerDragIsOneUndoStepAndTracksTheFinger() {
        let m = model { _ in }
        m.apply(.connected(peerID: "mac-d"))
        m.apply(.mode(window: true))
        m.apply(catalog([(30, 1, "a"), (31, 1, "b")]))
        m.updateSpace(WorkspaceSize(width: 1366, height: 1024), hinge: nil)
        for w in m.catalog!.windows { m.choose(w, asNewTile: true) }
        let before = m.layout
        let divider = WorkspaceGeometry.frames(for: m.layout, in: WorkspaceSize(width: 1366, height: 1024)).dividers[0]
        for _ in 0..<20 { m.resize(divider, delta: 0.01) }   // one drag, many small steps
        m.endResize()
        let ratio = { (l: WorkspaceLayout) -> Double in
            if case .split(_, _, let ratios) = l.root { return ratios[0] }
            return .nan
        }
        XCTAssertEqual(ratio(m.layout), ratio(before) + 0.2, accuracy: 0.001, "every step of the drag applies")
        m.resize(divider, delta: -0.05)   // a second drag
        m.endResize()
        m.undo()
        XCTAssertEqual(ratio(m.layout), ratio(before) + 0.2, accuracy: 0.001, "undo reverts only the second drag")
        m.undo()
        XCTAssertEqual(m.layout, before, "a second undo reverts the whole first drag")
    }

    func testCompactSpaceStacksTilesAndKeepsThem() {
        let m = model { _ in }
        m.apply(.connected(peerID: "mac-c"))
        m.apply(.mode(window: true))
        m.apply(catalog((0..<9).map { (UInt32(20 + $0), 1, "app\($0)") }))
        m.updateSpace(WorkspaceSize(width: 1366, height: 1024), hinge: nil)
        for w in m.catalog!.windows { m.choose(w, asNewTile: true) }
        XCTAssertEqual(m.layout.tiles.count, 9)
        m.updateSpace(WorkspaceSize(width: 300, height: 500), hinge: nil)   // a small cover screen: 3x3 doesn't fit
        XCTAssertEqual(m.layout.tiles.count, 6)
        XCTAssertEqual(m.stacked.count, 3)
        m.updateSpace(WorkspaceSize(width: 1366, height: 1024), hinge: nil)
        XCTAssertEqual(m.layout.tiles.count, 9, "unfolding brings every tile back")
    }

    func testImagesAreDecodedBoundedOnly() throws {
        // A real 600x400 PNG decodes to at most the requested side.
        let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let image = try XCTUnwrap(WorkspaceImageDecoder.image(data as Data, maxSide: 128))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 128)
        XCTAssertNil(WorkspaceImageDecoder.image(Data("not an image".utf8), maxSide: 128))
    }

    /// Regression (2026-10-30 21:3x): in View Only the session is live but the Mac hasn't granted
    /// control; Stage Manager on/off looked available and the Mac silently dropped it.
    func testActionsTheMacCarriesOutNeedItsConfirmedControlNotJustALiveSession() {
        let m = model(sent: { _ in })
        m.inputAllowed = { true }
        for state: SessionInputWireState in [.off, .requesting, .notAllowed, .requestsDisabled] {
            m.controlState = { state }
            XCTAssertFalse(m.canControlMac, "\(state)")
        }
        m.controlState = { .allowed }
        XCTAssertTrue(m.canControlMac)
        m.inputAllowed = { false }
        XCTAssertFalse(m.canControlMac, "a session that isn't live controls nothing")
    }
}

/// The receiver's Overview pane (every Mac display as one pane): when it is offered, how it is
/// named and added, where each gesture on it goes, and its menu's display path.
@MainActor
final class OverviewPaneReceiverTests: XCTestCase {
    private func display(_ id: UInt32, _ name: String, main: Bool = false, x: CGFloat, meow: Bool = false,
                         mirrorOf: UInt32? = nil) -> CatalogDisplayItem {
        let frame = CGRect(x: x, y: 0, width: 1920, height: 1080)
        return CatalogDisplayItem(id: id, name: name, width: 1920, height: 1080, isMain: main, isVirtual: meow,
                                  overview: OverviewDisplay(id: id, name: name, frame: frame, isMain: main, isVirtual: meow,
                                                            isMeow: meow, mirrorOf: mirrorOf))
    }

    private var twoDisplays: [CatalogDisplayItem] {
        [display(1, "Built-in Display", main: true, x: 0), display(2, "Studio Display", x: 1920)]
    }

    private func model(displays: [CatalogDisplayItem], overviewFeature: Bool = true, inWindowMode: Bool = true,
                       defaults: UserDefaults? = nil, sent: @escaping ([String: Any]) -> Void = { _ in }) -> WorkspaceModel {
        let m = WorkspaceModel(defaults: defaults ?? UserDefaults(suiteName: "OverviewPaneReceiverTests-\(UUID().uuidString)")!)
        m.send = { sent($0); return true }
        m.inputAllowed = { true }
        m.apply(.connected(peerID: "mac-a"))
        var features: Set<String> = [WindowWorkspaceWire.welcomeFeature]
        if overviewFeature { features.insert(WindowWorkspaceWire.overviewPaneFeature) }
        m.apply(.features(features))
        m.apply(.mode(window: inWindowMode))
        m.apply(.catalog(WorkspaceCatalogMessage(host: "mac-a", windows: [], apps: [], installed: [], unavailable: false,
                                                 displays: displays)))
        m.updateSpace(WorkspaceSize(width: 1200, height: 800), hinge: nil)
        return m
    }

    func testDraggingASecondPhysicalDisplayFromMirrorStartsTwoLivePaneAssignments() throws {
        let m = model(displays: twoDisplays, inWindowMode: false)
        var switches = 0
        m.mirroring = { true }
        m.requestWindowMode = { switches += 1; return true }
        m.desktopPictureGlobal = CGRect(x: 0, y: 0, width: 400, height: 800)
        m.beginDrag(.window(m.displayWindow(twoDisplays[0])), at: CGPoint(x: 200, y: 400))
        XCTAssertNil(m.dropTarget(forGlobal: CGPoint(x: 200, y: 400)), "the already mirrored source cannot add itself")
        m.cancelDrag()
        m.beginDrag(.window(m.displayWindow(twoDisplays[1])), at: CGPoint(x: 200, y: 400))
        guard case .split = m.dropTarget(forGlobal: CGPoint(x: 200, y: 400)) else {
            return XCTFail("the second display should join the current desktop")
        }
        XCTAssertTrue(m.endDrag())
        XCTAssertEqual(switches, 1)
        m.apply(.mode(window: true))
        let assignments = WorkspaceRequests.workspace(m.layout, frames: m.frames, host: "mac-a", focus: nil,
                                                       generation: { _ in nil }, displayID: { m.display(for: $0)?.id })
        let tiles = try XCTUnwrap(assignments["tiles"] as? [[String: Any]])
        XCTAssertEqual(tiles.compactMap { $0["display"] as? Int }, [1, 2])
        XCTAssertTrue(tiles.allSatisfy { $0["window"] == nil })
    }

    func testMirrorDisplayTabsPersistAndReconnectByPhysicalIdentity() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PhysicalDisplayTabs-\(UUID().uuidString)"))
        var original = twoDisplays
        original[0].displayUUID = UUID().uuidString
        original[1].displayUUID = UUID().uuidString
        let m = model(displays: original, inWindowMode: false, defaults: defaults)
        m.mirroring = { true }
        m.requestWindowMode = { true }
        XCTAssertTrue(m.addDisplayFromMirror(original[1], asTab: true))
        m.apply(.mode(window: true))
        let pane = try XCTUnwrap(m.layout.orderedTileIDs.first)
        XCTAssertEqual(m.layout.tiles[pane]?.tabs.map(\.displayUUID), original.map(\.displayUUID))

        // A different monitor now owns the old live ID. The saved tab must wait for its UUID.
        let impostor = display(original[1].id, original[1].name, x: 1920)
        let reloaded = model(displays: [original[0], impostor], defaults: defaults)
        let external = try XCTUnwrap(reloaded.layout.tiles[pane]?.source)
        XCTAssertNil(reloaded.display(for: external))
        XCTAssertTrue(reloaded.missing.contains(pane))

        var replugged = display(85, original[1].name, x: 1920)
        replugged.displayUUID = original[1].displayUUID
        reloaded.apply(.catalog(WorkspaceCatalogMessage(host: "mac-a", windows: [], apps: [], installed: [],
                                                        unavailable: false, displays: [original[0], impostor, replugged])))
        XCTAssertEqual(reloaded.display(for: external)?.id, 85)
        XCTAssertFalse(reloaded.missing.contains(pane))
        reloaded.choose(reloaded.displayWindow(replugged), asNewTile: true)
        XCTAssertEqual(reloaded.layout.orderedTileIDs, [pane], "the rebound display still has one saved view")
        reloaded.switchTab(pane, to: 0)
        XCTAssertEqual(reloaded.layout.tiles[pane]?.source.flatMap { reloaded.display(for: $0) }?.id, 1)
    }

    func testOverviewTabKeepsTheCurrentLayoutAndRestoresFromDisk() throws {
        let defaults = UserDefaults(suiteName: "OverviewTab-\(UUID().uuidString)")!
        let m = model(displays: twoDisplays, defaults: defaults)
        m.choose(m.displayWindow(twoDisplays[0]), asNewTile: false)
        let pane = try XCTUnwrap(m.layout.orderedTileIDs.first)
        let first = try XCTUnwrap(m.layout.tiles[pane]?.source)
        m.choose(m.displayWindow(twoDisplays[1]), asNewTile: true)
        let otherPane = try XCTUnwrap(m.layout.orderedTileIDs.first { $0 != pane })
        let other = m.layout.tiles[otherPane]
        let root = m.layout.root
        m.addOverviewTab(to: pane)
        XCTAssertEqual(m.layout.root, root)
        XCTAssertEqual(m.layout.tiles[otherPane], other)
        XCTAssertEqual(m.layout.tiles[pane]?.windows.map(\.kind), [.display, .overview])
        XCTAssertEqual(m.layout.tiles[pane]?.source?.kind, .overview)

        m.switchTab(pane, to: 0)
        XCTAssertEqual(m.layout.tiles[pane]?.source, first)
        m.addOverviewTab(to: otherPane)
        XCTAssertEqual(m.layout.tiles[pane]?.source?.kind, .overview)
        XCTAssertEqual(m.layout.tiles[otherPane], other)
        XCTAssertEqual(m.layout.tiles.values.flatMap(\.windows).filter(\.isOverview).count, 1)

        let reloaded = model(displays: twoDisplays, defaults: defaults)
        XCTAssertEqual(reloaded.layout.tiles[pane]?.source?.kind, .overview)
        reloaded.removeTab(pane, at: 1)
        XCTAssertEqual(reloaded.layout.tiles[pane]?.source, first)
        XCTAssertEqual(reloaded.layout.tiles[otherPane], other)
        XCTAssertEqual(reloaded.layout.root, root)
    }

    func testDisplaysActionTurnsAStandaloneOverviewIntoATab() throws {
        let m = model(displays: twoDisplays)
        m.choose(m.displayWindow(twoDisplays[0]), asNewTile: false)
        let target = try XCTUnwrap(m.overviewTabTarget)
        m.choose(m.overviewWindow, asNewTile: true)
        XCTAssertEqual(m.layout.tiles.count, 2)

        XCTAssertEqual(m.overviewTabTarget, target)
        m.addOverviewTab(to: target)
        XCTAssertEqual(m.layout.tiles.count, 1)
        XCTAssertEqual(m.layout.tiles[target]?.windows.map(\.kind), [.display, .overview])
        XCTAssertEqual(m.layout.tiles[target]?.source?.kind, .overview)
    }

    /// The pure table: in an Overview pane one finger is a trackpad whatever the setting, two
    /// fingers scroll over the displays with control, and pan the view when local navigation owns the gesture.
    func testEachGestureRoutesInAnOverviewPaneAndInOtherPanes() {
        func route(_ g: OverviewPaneInput.Gesture, _ kind: WorkspaceSource.Kind, _ preferred: PointerInputMode = .direct,
                   input: Bool = true, moveView: Bool = false) -> OverviewPaneInput.Route {
            OverviewPaneInput.route(g, kind: kind, preferred: preferred, inputReachesMac: input, moveViewActive: moveView)
        }
        XCTAssertEqual(route(.oneFinger, .overview, .direct), .pointer(.trackpad), "a trackpad even with Direct Touch chosen")
        XCTAssertEqual(route(.oneFinger, .overview, .trackpad), .pointer(.trackpad))
        XCTAssertEqual(route(.twoFingerDrag, .overview), .scrollMac)
        XCTAssertEqual(route(.twoFingerDrag, .overview, input: false), .movePane)
        XCTAssertEqual(route(.twoFingerDrag, .overview, moveView: true), .movePane)
        XCTAssertEqual(route(.pinch, .overview), .zoomPane)
        for kind in [WorkspaceSource.Kind.window, .display] {
            XCTAssertEqual(route(.oneFinger, kind, .direct), .pointer(.direct), "\(kind) keeps the person's pointer model")
            XCTAssertEqual(route(.oneFinger, kind, .trackpad), .pointer(.trackpad))
            XCTAssertEqual(route(.twoFingerDrag, kind), .scrollMac)
            XCTAssertEqual(route(.twoFingerDrag, kind, input: false), .movePane, "View Only pans the pane locally, as before")
            XCTAssertEqual(route(.twoFingerDrag, kind, moveView: true), .movePane)
            XCTAssertEqual(route(.pinch, kind), .zoomPane)
        }
        XCTAssertEqual(OverviewPaneInput.pointerMode(preferred: .direct, kind: .overview), .trackpad)
        XCTAssertEqual(OverviewPaneInput.pointerMode(preferred: .direct, kind: .display), .direct)
        XCTAssertEqual(OverviewPaneInput.pointerMode(preferred: .direct, kind: nil), .direct, "outside every pane")
    }

    /// Offered only with the Mac's `overviewPane` and two or more displays it would show (never
    /// MeowDisplay's own screens; a mirror set counts once).
    func testOfferedOnlyWithTheFeatureAndTwoDisplaysToShow() {
        XCTAssertTrue(OverviewPaneInput.offered(macOffers: true, displays: twoDisplays))
        XCTAssertFalse(OverviewPaneInput.offered(macOffers: false, displays: twoDisplays), "an older Mac")
        XCTAssertFalse(OverviewPaneInput.offered(macOffers: true, displays: [twoDisplays[0]]), "one display")
        let meow = [twoDisplays[0], display(3, "MeowDisplay", x: 1920, meow: true)]
        XCTAssertFalse(OverviewPaneInput.offered(macOffers: true, displays: meow), "this device's own screen isn't shown")
        let mirrored = [twoDisplays[0], display(4, "Projector", x: 0, mirrorOf: 1)]
        XCTAssertFalse(OverviewPaneInput.offered(macOffers: true, displays: mirrored), "a mirror repeats its display")
        XCTAssertEqual(OverviewPaneInput.shownDisplays(twoDisplays + [display(3, "MeowDisplay", x: 3840, meow: true)]).map(\.id), [1, 2])

        XCTAssertTrue(model(displays: twoDisplays).offersOverviewPane)
        XCTAssertFalse(model(displays: twoDisplays, overviewFeature: false).offersOverviewPane)
        XCTAssertFalse(model(displays: [twoDisplays[0]]).offersOverviewPane)
    }

    /// Added like any pane, titled Overview, sent as `overview: true`, once per layout.
    func testAddedOncePerLayoutTitledOverviewAndSentAsTheOverview() async throws {
        var sent: [[String: Any]] = []
        let m = model(displays: twoDisplays) { sent.append($0) }
        m.choose(m.displayWindow(twoDisplays[0]), asNewTile: false)
        m.choose(m.overviewWindow, asNewTile: true)
        m.choose(m.overviewWindow, asNewTile: true)
        let sources = m.layout.orderedTileIDs.compactMap { m.layout.tiles[$0]?.source }
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources.filter(\.isOverview).count, 1, "one Overview pane, beside the display")
        let id = try XCTUnwrap(m.layout.orderedTileIDs.first { m.layout.tiles[$0]?.source?.isOverview == true })
        XCTAssertEqual(m.windowItem(WorkspaceSource.overview(host: "mac-a"))?.title, "Overview", "the Mac sends no title for it")
        XCTAssertFalse(m.canFloat(pane: id), "it stays a tiled pane")
        XCTAssertFalse(m.activeIsOverview)
        m.apply(try XCTUnwrap(WorkspaceEvent.parse(type: WireMessage.workspaceState, ["tiles": [[String: Any]](), "active": id])))
        XCTAssertTrue(m.activeIsOverview, "the Mac focused it: its cursor is drawn there")
        let deadline = Date().addingTimeInterval(5)
        func overviewTile() -> [String: Any]? {
            sent.last { $0["type"] as? String == WireMessage.workspaceRequest }
                .flatMap { $0["tiles"] as? [[String: Any]] }?.first { $0["overview"] as? Bool == true }
        }
        while overviewTile() == nil, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let tile = try XCTUnwrap(overviewTile())
        XCTAssertNil(tile["window"])
        XCTAssertNil(tile["display"])
    }

    func testOverviewPanAndZoomPersistPerTabAndRestoreFromDisk() throws {
        let defaults = UserDefaults(suiteName: "OverviewViewport-\(UUID().uuidString)")!
        var sent: [[String: Any]] = []
        let m = model(displays: twoDisplays, defaults: defaults) { sent.append($0) }
        m.choose(m.displayWindow(twoDisplays[0]), asNewTile: false)
        let id = try XCTUnwrap(m.layout.orderedTileIDs.first)
        m.addOverviewTab(to: id)
        m.choose(m.displayWindow(twoDisplays[1]), asNewTile: true)
        let other = try XCTUnwrap(m.layout.orderedTileIDs.first { $0 != id })
        let untouched = m.layout.tiles[other]
        for space in [WorkspaceSize(width: 1200, height: 800), WorkspaceSize(width: 450, height: 800)] {
            m.updateSpace(space, hinge: nil)
            m.resetView(id)
            let frame = try XCTUnwrap(m.frames.tiles[id])
            let c = WorkspacePoint(x: frame.midX, y: frame.midY)
            let moved = WorkspacePoint(x: c.x + frame.width * 0.18, y: c.y + frame.height * 0.2)
            XCTAssertTrue(m.pinch(began: true, ended: true, isPinch: true, initial: c, current: c, scale: 0.4, turn: 40))
            XCTAssertEqual(m.layout.tiles[id]?.zoom?.scale, 0.7)
            XCTAssertEqual(m.layout.tiles[id]?.rotation, WorkspaceRotation.none)
            XCTAssertFalse(m.pinch(began: true, ended: true, isPinch: false, initial: c, current: moved, scale: 1),
                           "a two-finger drag over a live display still scrolls with control")
            m.inputAllowed = { false }
            XCTAssertTrue(m.pinch(began: true, ended: true, isPinch: false, initial: c, current: moved, scale: 1))
            XCTAssertLessThan(try XCTUnwrap(m.layout.tiles[id]?.zoom?.centerX), 0.5)
            XCTAssertLessThan(try XCTUnwrap(m.layout.tiles[id]?.zoom?.centerY), 0.5)
            m.inputAllowed = { true }
            let blank = WorkspacePoint(x: frame.maxX - frame.width * 0.01, y: frame.y + frame.height * 0.01)
            let dragFromBlank = WorkspacePoint(x: blank.x - frame.width * 0.06, y: blank.y + frame.height * 0.05)
            XCTAssertTrue(m.pinch(began: true, ended: true, isPinch: false, initial: blank, current: dragFromBlank, scale: 1),
                          "the empty canvas pans even while control is granted")
            XCTAssertEqual(m.layout.tiles[other], untouched)
        }
        let viewport = try XCTUnwrap(m.layout.tiles[id]?.zoom)
        m.switchTab(id, to: 0)
        XCTAssertNil(m.layout.tiles[id]?.zoom)
        m.switchTab(id, to: 1)
        XCTAssertEqual(m.layout.tiles[id]?.zoom, viewport)
        m.apply(.disconnected)
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features([WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.overviewPaneFeature]))
        m.apply(.mode(window: true))
        m.apply(.catalog(WorkspaceCatalogMessage(host: "mac-a", windows: [], apps: [], installed: [],
                                                 unavailable: false, displays: twoDisplays)))
        XCTAssertEqual(m.layout.tiles[id]?.zoom, viewport)
        let reloaded = model(displays: twoDisplays, defaults: defaults)
        XCTAssertEqual(reloaded.layout.tiles[id]?.zoom, viewport)
        reloaded.toggleFit(id)
        XCTAssertEqual(reloaded.layout.tiles[id]?.fit, .fill)
        reloaded.resetView(id)
        XCTAssertEqual(reloaded.layout.tiles[id]?.fit, .fit)
        XCTAssertNil(reloaded.layout.tiles[id]?.zoom)
        m.requestBackdrop(id, refresh: true)
        XCTAssertFalse(sent.contains { $0["type"] as? String == WireMessage.workspaceBackdropRequest })
    }

    /// Its menu's "Show <display> in a Pane": the display pane source, in a new pane when there's
    /// room; a display already shown gets no second pane. A display pane's menu offers the Overview.
    func testShowDisplayInPaneUsesTheDisplayPanePath() throws {
        let m = model(displays: twoDisplays)
        m.choose(m.overviewWindow, asNewTile: false)
        let overview = try XCTUnwrap(m.layout.orderedTileIDs.first)
        XCTAssertEqual(m.overviewPaneDisplays.map(\.name), ["Built-in Display", "Studio Display"])
        m.showDisplayInPane(twoDisplays[1], from: overview)
        let sources = m.layout.orderedTileIDs.compactMap { m.layout.tiles[$0]?.source }
        XCTAssertEqual(sources.count, 2, "a new pane beside the Overview")
        XCTAssertTrue(sources.contains { $0.isOverview })
        XCTAssertTrue(sources.contains { $0.kind == .display && $0.windowID == WorkspaceSource.displayKey(2) },
                      "the display pane source")
        m.showDisplayInPane(twoDisplays[1], from: overview)
        XCTAssertEqual(m.layout.tiles.count, 2, "already shown: no second pane")

        let other = model(displays: twoDisplays)
        other.choose(other.displayWindow(twoDisplays[0]), asNewTile: false)
        let pane = try XCTUnwrap(other.layout.orderedTileIDs.first)
        other.showOverviewPane(in: pane)
        XCTAssertEqual(other.layout.tiles[pane]?.source?.kind, .overview)
        XCTAssertEqual(other.layout.tiles.count, 1)
    }

    /// A tap made before the pointer model changes (a sequence starting in another pane) still clicks.
    func testChangingThePointerModelBetweenSequencesKeepsABufferedTap() {
        let engine = PointerGestureEngine()
        engine.setInputMode(.trackpad)
        _ = engine.handle(PointerTouchSample(id: AnyHashable(1), phase: .began, viewPoint: CGPoint(x: 10, y: 10),
                                             normalized: CGPoint(x: 0.3, y: 0.3), time: 0))
        _ = engine.handle(PointerTouchSample(id: AnyHashable(1), phase: .ended, viewPoint: CGPoint(x: 11, y: 10),
                                             normalized: CGPoint(x: 0.31, y: 0.3), time: 0.02))
        XCTAssertEqual(engine.mode, .tapBuffered)
        XCTAssertEqual(engine.setInputModeKeepingTap(.direct),
                       [.mouseDown(button: .left, clickCount: 1), .mouseUp(button: .left, clickCount: 1)])
        XCTAssertEqual(engine.inputMode, .direct)
        XCTAssertEqual(engine.mode, .idle)
        XCTAssertEqual(engine.setInputModeKeepingTap(.direct), [], "no change, nothing sent")
    }

    /// The Mac's cursor in an Overview pane is drawn at least a real pointer's size.
    func testTheCursorInAnOverviewPaneHasALargerMinimumSize() {
        let tiny = CGSize(width: 3, height: 4)
        XCTAssertEqual(PaneCursorSizing.bounded(tiny).height, PaneCursorSizing.minLongestSide, accuracy: 1e-9)
        let inOverview = PaneCursorSizing.bounded(tiny, inOverview: true)
        XCTAssertEqual(inOverview.height, PaneCursorSizing.overviewMinLongestSide, accuracy: 1e-9)
        XCTAssertEqual(inOverview.width / inOverview.height, 0.75, accuracy: 1e-9, "its shape is kept")
        XCTAssertEqual(PaneCursorSizing.bounded(CGSize(width: 30, height: 40), inOverview: true), CGSize(width: 30, height: 40))
    }
}
