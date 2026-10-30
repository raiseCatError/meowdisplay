import CoreGraphics
import XCTest

/// Window mode on the sender: which windows are listed, identity across id
/// reuse, what a receiver's workspace request may select, and where input lands.
final class WindowWorkspaceTargetingTests: XCTestCase {
    private func candidate(_ id: UInt32 = 10, pid: Int32 = 100, bundle: String? = "dev.zed.Zed", title: String? = "main.rs",
                           layer: Int = 0, frame: CGRect = CGRect(x: 100, y: 100, width: 800, height: 600),
                           onScreen: Bool = true, alpha: Double = 1, sharing: Int = 1) -> WindowCandidate {
        WindowCandidate(windowID: id, pid: pid, bundleID: bundle, appName: "Zed", title: title, layer: layer, frame: frame,
                        isOnScreen: onScreen, alpha: alpha, sharingState: sharing, isActive: false)
    }

    private func excluded(_ c: WindowCandidate) -> WindowCatalogPolicy.Exclusion? {
        WindowCatalogPolicy.exclusion(for: c, ownBundleIDs: ["com.raisecaterror.meowdisplay.mac"], ownPID: 1)
    }

    // MARK: Catalog

    func testCatalogListsRealWindowsAndDropsHelpersSeenOnMacOS27() {
        XCTAssertNil(excluded(candidate()))
        XCTAssertNil(excluded(candidate(onScreen: false)), "a titled window on another Space or minimized stays listed")
        XCTAssertNil(excluded(candidate(frame: CGRect(x: -3000, y: 200, width: 800, height: 600))), "off-screen geometry is fine")
        // Measured helper shapes (evidence W1-sck): every app's menu-bar strip, placeholders, agents.
        XCTAssertEqual(excluded(candidate(title: "", frame: CGRect(x: 0, y: 0, width: 1920, height: 30), onScreen: false)), .menuBarStrip)
        XCTAssertEqual(excluded(candidate(title: "", frame: CGRect(x: 0, y: -41, width: 1920, height: 41), onScreen: false)), .menuBarStrip)
        XCTAssertEqual(excluded(candidate(title: "", frame: CGRect(x: 0, y: 580, width: 500, height: 500), onScreen: false)), .untitledOffscreen)
        XCTAssertEqual(excluded(candidate(bundle: "com.apple.TextInputUI.xpc.CursorUIViewService", title: "")), .system)
        XCTAssertEqual(excluded(candidate(bundle: "com.apple.LocalAuthentication.UIAgent", title: "")), .system, "password prompts")
        XCTAssertEqual(excluded(candidate(bundle: "com.apple.WindowManager", title: "App Icon Window")), .system, "Stage Manager thumbnails")
        XCTAssertEqual(excluded(candidate(bundle: "com.apple.loginwindow")), .system)
        XCTAssertEqual(excluded(candidate(bundle: "com.apple.appkit.xpc.openAndSavePanelService")), .system)
        XCTAssertEqual(excluded(candidate(bundle: "pro.betterdisplay.BetterDisplay", title: "", frame: CGRect(x: 0, y: 1079, width: 1, height: 1), alpha: 0)), .transparent)
        XCTAssertEqual(excluded(candidate(bundle: nil)), .noBundle)
        XCTAssertEqual(excluded(candidate(layer: 3)), .notNormalLayer)
        XCTAssertEqual(excluded(candidate(sharing: 0)), .notShareable, "windows that opted out of capture")
        XCTAssertEqual(excluded(candidate(frame: CGRect(x: 0, y: 0, width: 64, height: 64))), .tooSmall)
        // MeowDisplay's own windows (pairing codes, approvals) are never offered.
        XCTAssertEqual(excluded(candidate(bundle: "com.raisecaterror.meowdisplay.mac", title: "Pair")), .ownApp)
        XCTAssertEqual(excluded(candidate(pid: 1, bundle: "anything")), .ownApp)
        // An untitled but visible app window (some apps never set a title) is listed.
        XCTAssertNil(excluded(candidate(title: "", onScreen: true)))
    }

    func testAReusedWindowIDIsANewIdentity() {
        var ledger = WindowIdentityLedger()
        let a = ledger.generation(windowID: 42, pid: 100)
        XCTAssertEqual(ledger.generation(windowID: 42, pid: 100), a, "stable while the same window lives")
        let b = ledger.generation(windowID: 42, pid: 200)
        XCTAssertNotEqual(a, b, "same id, other process: another window")
        XCTAssertEqual(ledger.current(windowID: 42)?.pid, 200)
        ledger.retain([42], now: 100)
        ledger.retain([], now: 102)
        XCTAssertEqual(ledger.current(windowID: 42)?.pid, 200, "missing from one listing: still the same window")
        XCTAssertTrue(ledger.knows(windowID: 42, generation: b))
        ledger.retain([], now: 100 + WindowIdentityLedger.absenceGrace + 1)
        XCTAssertNil(ledger.current(windowID: 42))
        XCTAssertNotEqual(ledger.generation(windowID: 42, pid: 100), a, "a window that came back after closing is new too")
    }

    // MARK: Request validation

    private func entry(_ id: UInt32, gen: UInt64 = 1, pid: Int32 = 100) -> WindowCatalogEntry {
        WindowCatalogEntry(windowID: id, generation: gen, pid: pid, bundleID: "dev.zed.Zed", appName: "Zed", title: "w\(id)",
                           frame: CGRect(x: 0, y: 0, width: 800, height: 600), availability: .visible, isActive: false)
    }

    func testOnlyListedWindowsWithTheCurrentIdentityCanBeSelected() {
        let catalog: [UInt32: WindowCatalogEntry] = [10: entry(10, gen: 5), 11: entry(11, gen: 6)]
        var next: UInt64 = 1
        let tiles: [[String: Any]] = [
            ["id": "a", "x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0, "window": 10, "gen": 5],
            ["id": "b", "x": 0.5, "y": 0.0, "w": 0.5, "h": 0.5, "window": 11, "gen": 99],   // stale generation
            ["id": "c", "x": 0.5, "y": 0.5, "w": 0.5, "h": 0.5, "window": 77],              // never listed
            ["id": "d", "x": 0.2, "y": 0.2, "w": 0.5, "h": 0.5, "window": 10],              // overlaps a
            ["id": "a", "x": 0.5, "y": 0.5, "w": 0.5, "h": 0.5, "window": 11],              // duplicate id
            ["id": "e", "host": "other-mac", "x": 0.5, "y": 0.5, "w": 0.5, "h": 0.5, "window": 11],
            ["id": "bad id!", "x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0, "window": 10],
            ["id": "f", "x": 0.9, "y": 0.9, "w": 0.5, "h": 0.5, "window": 11],              // off canvas
            ["id": "g", "x": 0.0, "y": 0.0, "w": Double.nan, "h": 0.5, "window": 11],
        ]
        let r = WorkspaceRequestValidator.validate(tiles: tiles, catalog: catalog, hostID: "mac-a",
                                                   canvasPixels: CGSize(width: 2000, height: 1000), previous: [:], nextGeneration: &next)
        XCTAssertEqual(r.assignments.map(\.tileID), ["a"])
        XCTAssertEqual(r.rejected["b"], "unavailable")
        XCTAssertEqual(r.rejected["c"], "unavailable")
        let noGen = WorkspaceRequestValidator.validate(
            tiles: [["id": "n", "x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0, "window": 10]], catalog: catalog, hostID: "mac-a",
            canvasPixels: CGSize(width: 2000, height: 1000), previous: [:], nextGeneration: &next)
        XCTAssertEqual(noGen.rejected["n"], "unavailable", "a tile without the window's generation is refused")
        XCTAssertEqual(r.rejected["d"], "overlap")
        XCTAssertEqual(r.rejected["a"], "duplicate")
        XCTAssertNil(r.rejected["e"], "another host's tile is not this Mac's to judge")
        XCTAssertEqual(r.rejected["f"], "geometry")
        XCTAssertEqual(r.rejected["g"], "geometry")
        XCTAssertFalse(r.rejected.keys.contains("bad id!"))
        XCTAssertEqual(r.assignments[0].pid, 100, "owner comes from the Mac's catalog, not the request")
    }

    /// Full Desktop as a tile source: only a display this Mac listed, once, mixed with windows.
    /// Input to it lands on the display itself; keys go wherever the Mac's focus is.
    func testADisplayTileNeedsAListedDisplayAndMixesWithWindows() {
        let catalog: [UInt32: WindowCatalogEntry] = [10: entry(10, gen: 5)]
        let displays: [UInt32: CGRect] = [1: CGRect(x: 0, y: 0, width: 1512, height: 982)]
        var next: UInt64 = 1
        let r = WorkspaceRequestValidator.validate(tiles: [
            ["id": "d", "x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0, "display": 1],
            ["id": "w", "x": 0.5, "y": 0.0, "w": 0.5, "h": 0.5, "window": 10, "gen": 5],
            ["id": "x", "x": 0.5, "y": 0.5, "w": 0.5, "h": 0.5, "display": 7],   // never listed
        ], catalog: catalog, hostID: "mac-a", canvasPixels: CGSize(width: 2000, height: 1000), previous: [:],
           nextGeneration: &next, displays: displays)
        XCTAssertEqual(r.assignments.map(\.tileID), ["d", "w"])
        XCTAssertEqual(r.assignments[0].displayID, 1)
        XCTAssertEqual(r.assignments[0].windowID, WorkspaceSource.displayKey(1))
        XCTAssertEqual(r.rejected["x"], "unavailable")
        // The display's key is never accepted as a window number, and a display shows once.
        let sneaky = WorkspaceRequestValidator.validate(tiles: [
            ["id": "a", "x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0, "display": 1],
            ["id": "b", "x": 0.5, "y": 0.0, "w": 0.5, "h": 1.0, "display": 1],
            ["id": "c", "x": 0.0, "y": 0.0, "w": 0.1, "h": 0.1, "window": Int(WorkspaceSource.displayKey(1)), "gen": 0],
        ], catalog: catalog, hostID: "mac-a", canvasPixels: CGSize(width: 2000, height: 1000), previous: [:],
           nextGeneration: &next, displays: displays)
        XCTAssertEqual(sneaky.assignments.map(\.tileID), ["a"])
        XCTAssertEqual(sneaky.rejected["b"], "duplicateWindow")
        XCTAssertNotNil(sneaky.rejected["c"])
        // Without the display list (another session, or nothing listed): refused.
        let unlisted = WorkspaceRequestValidator.validate(tiles: [["id": "a", "x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0, "display": 1]],
            catalog: catalog, hostID: "mac-a", canvasPixels: CGSize(width: 2000, height: 1000), previous: [:], nextGeneration: &next)
        XCTAssertEqual(unlisted.rejected["a"], "unavailable")

        // Input: a press at the middle of the desktop tile lands at the middle of the display.
        var targeting = WorkspaceInputTargeting()
        targeting.canvas = CGSize(width: 2000, height: 1000)
        targeting.windowFrames = [r.assignments[0].windowID: displays[1]!, 10: CGRect(x: 0, y: 0, width: 800, height: 600)]
        _ = targeting.update(assignments: r.assignments)
        let hit = targeting.resolve(.down, at: WorkspacePoint(x: 0.25, y: 0.5))
        XCTAssertEqual(hit?.tileID, "d")
        XCTAssertEqual(hit?.point.x ?? 0, 756, accuracy: 1)
        XCTAssertEqual(hit?.point.y ?? 0, 491, accuracy: 1)
        XCTAssertEqual(WorkspaceKeyboardGate.decide(active: r.assignments[0], frontmostPID: 999, focusedWindowID: 0,
                                                    focusedWindowIsChild: false), .deliver)
    }

    func testOneWindowShowsInOneTileOnly() {
        let catalog: [UInt32: WindowCatalogEntry] = [10: entry(10, gen: 5)]
        var next: UInt64 = 1
        let r = WorkspaceRequestValidator.validate(tiles: [
            ["id": "a", "x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0, "window": 10, "gen": 5],
            ["id": "b", "x": 0.5, "y": 0.0, "w": 0.5, "h": 1.0, "window": 10, "gen": 5],
        ], catalog: catalog, hostID: "mac-a", canvasPixels: CGSize(width: 2000, height: 1000), previous: [:], nextGeneration: &next)
        XCTAssertEqual(r.assignments.map(\.tileID), ["a"])
        XCTAssertEqual(r.rejected["b"], "duplicateWindow")
    }

    func testTileLimitAndGenerationsAcrossRequests() {
        var catalog: [UInt32: WindowCatalogEntry] = [:]
        for i in 0..<12 { catalog[UInt32(i)] = entry(UInt32(i)) }
        var next: UInt64 = 1
        var tiles: [[String: Any]] = []
        for i in 0..<12 {
            let x: Double = Double(i % 4) / 4
            let y: Double = Double(i / 4) / 3
            let tile: [String: Any] = ["id": "t\(i)", "x": x, "y": y, "w": 0.25, "h": 1.0 / 3, "window": i, "gen": 1]
            tiles.append(tile)
        }
        let r = WorkspaceRequestValidator.validate(tiles: tiles, catalog: catalog, hostID: "m", canvasPixels: CGSize(width: 2732, height: 2048),
                                                   previous: [:], nextGeneration: &next)
        XCTAssertEqual(r.assignments.count, WorkspaceLayout.maximumTiles)
        XCTAssertEqual(r.rejected.values.filter { $0 == "limit" }.count, 3)
        // Same window again keeps its generation (no capture restart); a new window bumps it.
        let previous = Dictionary(uniqueKeysWithValues: r.assignments.map { ($0.tileID, $0) })
        let again = WorkspaceRequestValidator.validate(
            tiles: [["id": "t0", "x": 0.0, "y": 0.0, "w": 0.5, "h": 0.5, "window": 0, "gen": 1, "rotation": 90],
                    ["id": "t1", "x": 0.5, "y": 0.0, "w": 0.5, "h": 0.5, "window": 5, "gen": 1]],
            catalog: catalog, hostID: "m", canvasPixels: CGSize(width: 2732, height: 2048), previous: previous, nextGeneration: &next)
        XCTAssertEqual(again.assignments[0].assignmentGeneration, previous["t0"]!.assignmentGeneration)
        XCTAssertEqual(again.assignments[0].rotation, .quarter, "rotation changes don't restart the window")
        XCTAssertNotEqual(again.assignments[1].assignmentGeneration, previous["t1"]!.assignmentGeneration)
    }

    // MARK: Input targeting

    private func twoTiles() -> WorkspaceInputTargeting {
        var t = WorkspaceInputTargeting()
        t.canvas = CGSize(width: 2000, height: 1000)
        t.windowFrames = [10: CGRect(x: 0, y: 0, width: 1000, height: 1000), 11: CGRect(x: 3000, y: 100, width: 1000, height: 500)]
        _ = t.update(assignments: [
            WorkspaceTileAssignment(tileID: "a", rect: .init(x: 0, y: 0, width: 0.5, height: 1), windowID: 10, windowGeneration: 1,
                                    pid: 100, bundleID: "a", follow: .window, rotation: .none, fit: .fit, assignmentGeneration: 1),
            WorkspaceTileAssignment(tileID: "b", rect: .init(x: 0.5, y: 0, width: 0.5, height: 1), windowID: 11, windowGeneration: 1,
                                    pid: 200, bundleID: "b", follow: .window, rotation: .none, fit: .fit, assignmentGeneration: 2),
        ])
        return t
    }

    func testHoverDoesNotChangeFocusAndPressActivatesOnce() {
        var t = twoTiles()
        XCTAssertNil(t.keyboardTarget, "two tiles, none chosen: no keyboard target")
        XCTAssertNil(t.resolve(.move, at: .init(x: 0.25, y: 0.5)), "hovering an inactive tile sends nothing to the Mac")
        XCTAssertEqual(t.hoveredTile, "a")
        XCTAssertNil(t.activeTile, "hover never changes the active tile")
        let down = try! XCTUnwrap(t.resolve(.down, at: .init(x: 0.25, y: 0.5)))
        XCTAssertTrue(down.activates)
        XCTAssertEqual(down.point.x, 500, accuracy: 1e-6)
        XCTAssertEqual(down.point.y, 500, accuracy: 1e-6)
        _ = t.resolve(.up, at: .init(x: 0.25, y: 0.5))
        XCTAssertFalse(t.resolve(.down, at: .init(x: 0.3, y: 0.5))!.activates, "a second click doesn't re-activate")
        _ = t.resolve(.up, at: .init(x: 0.3, y: 0.5))
        XCTAssertNotNil(t.resolve(.move, at: .init(x: 0.3, y: 0.5)), "hover over the active tile reaches the Mac")
        XCTAssertNil(t.resolve(.move, at: .init(x: 0.75, y: 0.5)), "crossing into the other tile: local hover only")
        XCTAssertEqual(t.hoveredTile, "b")
        XCTAssertEqual(t.keyboardTarget?.tileID, "a", "keyboard stays with the clicked tile")
    }

    func testLocatingAPointChangesNothing() {
        // Smart Touch asks what is under a finger before the press: it must
        // land in the tile's window and leave hover, focus and bindings alone.
        let t = twoTiles()
        let p = try! XCTUnwrap(t.globalPoint(at: .init(x: 0.75, y: 0.5)))
        XCTAssertEqual(p.x, 3500, accuracy: 1e-6)
        XCTAssertEqual(p.y, 350, accuracy: 1e-6)
        XCTAssertNil(t.globalPoint(at: .init(x: 0.75, y: 0.1)), "letterbox: nothing under it")
        XCTAssertEqual(t, twoTiles())
    }

    func testTheCaretIsMappedThroughTheTileOfItsWindow() throws {
        let t = twoTiles()
        // No tile is active yet: the caret's own window decides.
        let inA = try XCTUnwrap(t.canvasCaretRect(forGlobal: CGRect(x: 500, y: 400, width: 2, height: 20)))
        XCTAssertEqual(inA.minX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(inA.minY, 0.4, accuracy: 1e-9)
        XCTAssertEqual(inA.width, 0.001, accuracy: 1e-9)
        XCTAssertEqual(inA.height, 0.02, accuracy: 1e-9)
        // Window b sits letterboxed inside its tile (content y 250...750).
        let inB = try XCTUnwrap(t.canvasCaretRect(forGlobal: CGRect(x: 3500, y: 350, width: 0, height: 20)))
        XCTAssertEqual(inB.minX, 0.75, accuracy: 1e-9)
        XCTAssertEqual(inB.minY, 0.5, accuracy: 1e-9)
    }

    func testTheCaretOutsideTheTypedWindowIsNotSent() {
        var t = twoTiles()
        _ = t.resolve(.down, at: .init(x: 0.25, y: 0.5))      // tile a becomes the keyboard target
        XCTAssertNotNil(t.canvasCaretRect(forGlobal: CGRect(x: 500, y: 400, width: 0, height: 20)))
        XCTAssertNil(t.canvasCaretRect(forGlobal: CGRect(x: 3500, y: 350, width: 0, height: 20)),
                     "a caret in a window the keyboard is not typing into")
        XCTAssertNil(t.canvasCaretRect(forGlobal: CGRect(x: 1500, y: 400, width: 0, height: 20)), "on the desktop, in no tile window")
        XCTAssertNil(WorkspaceInputTargeting().canvasCaretRect(forGlobal: CGRect(x: 1, y: 1, width: 0, height: 20)), "no canvas")
    }

    func testTheCaretIsFollowedThroughARotatedTile() throws {
        var t = WorkspaceInputTargeting()
        t.canvas = CGSize(width: 1000, height: 1000)
        t.windowFrames = [10: CGRect(x: 100, y: 100, width: 400, height: 200)]
        _ = t.update(assignments: [
            WorkspaceTileAssignment(tileID: "a", rect: .init(x: 0, y: 0, width: 1, height: 1), windowID: 10, windowGeneration: 1,
                                    pid: 100, bundleID: "a", follow: .window, rotation: .quarter, fit: .fit, assignmentGeneration: 1),
        ])
        // A quarter turn lays the window on its side: the caret's tall thin box becomes a wide flat one.
        let r = try XCTUnwrap(t.canvasCaretRect(forGlobal: CGRect(x: 200, y: 150, width: 2, height: 20)))
        XCTAssertGreaterThan(r.width, r.height)
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1, height: 1).contains(CGPoint(x: r.midX, y: r.midY)))
    }

    func testADragStaysInTheWindowItStartedIn() {
        var t = twoTiles()
        _ = t.resolve(.down, at: .init(x: 0.25, y: 0.5))
        let crossing = try! XCTUnwrap(t.resolve(.move, at: .init(x: 0.9, y: 0.5)))
        XCTAssertEqual(crossing.tileID, "a")
        XCTAssertLessThanOrEqual(crossing.point.x, 1000, "clamped to window a, never into b's window at x=3000")
        let up = try! XCTUnwrap(t.resolve(.up, at: .init(x: 0.9, y: 0.5)))
        XCTAssertEqual(up.tileID, "a")
        XCTAssertNil(t.boundTile)
    }

    func testLetterboxAndGapsSendNothing() {
        var t = twoTiles()
        // Tile b: 1000x1000 canvas tile, window 1000x500 -> letterboxed top and bottom.
        XCTAssertNil(t.resolve(.down, at: .init(x: 0.75, y: 0.1)))
        XCTAssertNotNil(t.resolve(.down, at: .init(x: 0.75, y: 0.5)))
    }

    func testRotatedTileMapsCornersToTheWindowsCorners() {
        var t = WorkspaceInputTargeting()
        t.canvas = CGSize(width: 1000, height: 2000)
        t.windowFrames = [10: CGRect(x: 100, y: 50, width: 2000, height: 1000)]
        for rotation in WorkspaceRotation.allCases {
            _ = t.update(assignments: [WorkspaceTileAssignment(
                tileID: "a", rect: .unit, windowID: 10, windowGeneration: 1, pid: 1, bundleID: "a", follow: .window,
                rotation: rotation, fit: .fit, assignmentGeneration: UInt64(rotation.rawValue + 1))])
            // Round trip: every Mac point inside the window maps to a canvas point and back.
            for g in [CGPoint(x: 101, y: 51), CGPoint(x: 2099, y: 1049), CGPoint(x: 1100, y: 550), CGPoint(x: 600, y: 900)] {
                let c = try! XCTUnwrap(t.canvasPoint(forGlobal: g), "\(rotation)")
                let back = try! XCTUnwrap(t.resolve(.scroll, at: c), "\(rotation)")
                XCTAssertEqual(back.point.x, g.x, accuracy: 1e-6, "\(rotation)")
                XCTAssertEqual(back.point.y, g.y, accuracy: 1e-6, "\(rotation)")
            }
        }
    }

    /// The cursor's size in a pane comes from that pane's own scale: equal in x and y in canvas
    /// pixels whatever the canvas shape (the old display-normalized size stretched it), and it
    /// follows Fit, zoom and rotation.
    func testCursorPlacementCarriesThePanesUniformScale() {
        var t = WorkspaceInputTargeting()
        t.canvas = CGSize(width: 1179, height: 2556)   // a portrait phone: nothing like the Mac display
        t.windowFrames = [10: CGRect(x: 0, y: 0, width: 1500, height: 1000)]
        func place(zoom: Double, rotation: WorkspaceRotation = .none) -> (x: Double, y: Double, kx: Double, ky: Double, rotation: Int) {
            _ = t.update(assignments: [WorkspaceTileAssignment(
                tileID: "a", rect: .unit, windowID: 10, windowGeneration: 1, pid: 1, bundleID: "a", follow: .window,
                rotation: rotation, fit: .fit, zoom: WorkspacePaneZoom(scale: zoom, centerX: 0.5, centerY: 0.5),
                assignmentGeneration: UInt64(zoom * 100) + UInt64(rotation.rawValue))])
            return try! XCTUnwrap(t.cursorPlacement(forGlobal: CGPoint(x: 750, y: 500)))
        }
        let one = place(zoom: 1)
        XCTAssertEqual(one.kx * 1179, one.ky * 2556, accuracy: 1e-9, "uniform in canvas pixels: the shape is kept")
        XCTAssertEqual(one.kx * 1179, 1179.0 / 1500, accuracy: 1e-9, "Fit: the window's width fills the pane")
        XCTAssertEqual(one.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(one.y, 0.5, accuracy: 1e-9)
        let three = place(zoom: 3)
        XCTAssertEqual(three.kx / one.kx, 3, accuracy: 1e-9, "zoom scales the cursor with the picture")
        let turned = place(zoom: 1, rotation: .quarter)
        XCTAssertEqual(turned.rotation, 90)
        XCTAssertEqual(turned.kx * 1179, 1179.0 / 1000, accuracy: 1e-9, "turned: the window's height now spans the width")
        XCTAssertNil(t.cursorPlacement(forGlobal: CGPoint(x: 2000, y: 500)), "off the window: hidden")
    }

    func testARefusedPressLeavesNothingBound() {
        var t = twoTiles()
        _ = t.resolve(.down, at: .init(x: 0.25, y: 0.5))
        XCTAssertEqual(t.boundTile, "a")
        t.cancelBinding()   // the engine refused it (covered window)
        XCTAssertNil(t.boundTile)
        let next = try! XCTUnwrap(t.resolve(.down, at: .init(x: 0.75, y: 0.5)))
        XCTAssertEqual(next.tileID, "b", "the next press goes where it lands, not into the refused tile")
    }

    func testReplacingTheBoundTilesWindowReleasesHeldInput() {
        var t = twoTiles()
        _ = t.resolve(.down, at: .init(x: 0.25, y: 0.5))
        var replaced = t.assignments
        replaced[0].windowID = 11
        replaced[0].assignmentGeneration = 9
        XCTAssertTrue(t.update(assignments: replaced), "source swapped under a held button: release")
        XCTAssertNil(t.boundTile)
        var t2 = twoTiles()
        _ = t2.resolve(.down, at: .init(x: 0.25, y: 0.5))
        var rotated = t2.assignments
        rotated[1].rotation = .half
        XCTAssertFalse(t2.update(assignments: rotated), "changing another tile keeps the drag")
        XCTAssertFalse(t2.update(assignments: Array(rotated.prefix(1))))
        XCTAssertTrue(t2.update(assignments: Array(rotated.suffix(1))), "removing the bound tile releases")
    }

    func testRelativeMotionMovesFreelyWhileNoPaneHasFocus() {
        var t = twoTiles()
        XCTAssertNil(t.activeTile)
        for _ in 0..<5 { _ = t.resolveRelative(dx: 100, dy: 0) }
        XCTAssertEqual(t.pointer.x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(t.hoveredTile, "b", "no pane in focus: the pointer crosses panes")
        for _ in 0..<50 { _ = t.resolveRelative(dx: 100, dy: 0) }
        XCTAssertEqual(t.pointer.x, 1, accuracy: 1e-9, "clamped to the workspace")
    }

    /// Trackpad mode: the cursor lives in the focused pane. It never slides into a neighbour;
    /// focusing a pane puts it in that pane's middle the first time and back where it was after.
    func testTrackpadCursorStaysInTheFocusedPaneAndEachPaneRemembersItsOwn() throws {
        var t = twoTiles()
        t.setActive("a")
        // Tile a is 1000x1000 canvas px showing a 1000x1000 window: its middle.
        XCTAssertEqual(t.pointer.x, 0.25, accuracy: 1e-9, "first focus: the pane's middle")
        XCTAssertEqual(t.pointer.y, 0.5, accuracy: 1e-9)
        for _ in 0..<20 { _ = t.resolveRelative(dx: 100, dy: 0) }
        XCTAssertEqual(t.pointer.x, 0.5, accuracy: 1e-5, "stopped at the pane's right edge")
        XCTAssertEqual(t.hoveredTile, "a", "never slides into the neighbour")
        let edge = try XCTUnwrap(t.resolveRelative(dx: 0, dy: -200))
        XCTAssertEqual(edge.tileID, "a")
        XCTAssertEqual(edge.point.x, 1000, accuracy: 0.1, "the window's right edge on the Mac")
        let leftA = t.pointer

        t.setActive("b")
        // Tile b: 1000x1000 px showing 1000x500, letterboxed: its picture is y 250...750.
        XCTAssertEqual(t.pointer.x, 0.75, accuracy: 1e-9, "the other pane's middle")
        XCTAssertEqual(t.pointer.y, 0.5, accuracy: 1e-9)
        for _ in 0..<10 { _ = t.resolveRelative(dx: 0, dy: -100) }
        XCTAssertEqual(t.pointer.y, 0.25, accuracy: 1e-5, "kept on the picture, not the letterbox bar")
        let leftB = t.pointer

        t.setActive("a")
        XCTAssertEqual(t.pointer.x, leftA.x, accuracy: 1e-5, "back where it was in this pane")
        XCTAssertEqual(t.pointer.y, leftA.y, accuracy: 1e-5)
        t.setActive("b")
        XCTAssertEqual(t.pointer.x, leftB.x, accuracy: 1e-5)
        XCTAssertEqual(t.pointer.y, leftB.y, accuracy: 1e-5)
        let shown = try XCTUnwrap(t.pointerPlacement(), "the cursor is drawn in the focused pane")
        XCTAssertEqual(shown.x, leftB.x, accuracy: 1e-9)
        XCTAssertEqual(shown.kx * 2000, 1, accuracy: 1e-9, "with that pane's scale (1 canvas px per Mac point)")
    }

    /// The cursor is kept per tab and on the window's own content: a tab switch brings that
    /// tab's cursor back, and zooming the pane keeps it on the same spot of the window.
    func testThePaneCursorFollowsTabsAndStaysOnTheContentWhenZoomed() throws {
        var t = twoTiles()
        t.windowFrames[12] = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        t.setActive("a")
        for _ in 0..<2 { _ = t.resolveRelative(dx: -100, dy: -100) }   // window point (300, 300)
        XCTAssertEqual(t.pointer.x, 0.15, accuracy: 1e-9)
        XCTAssertEqual(t.pointer.y, 0.3, accuracy: 1e-9)
        var tabbed = t.assignments
        tabbed[0].windowID = 12
        tabbed[0].assignmentGeneration = 7
        _ = t.update(assignments: tabbed)
        XCTAssertEqual(t.pointer.x, 0.25, accuracy: 1e-9, "a tab seen for the first time: its middle")
        XCTAssertEqual(t.pointer.y, 0.5, accuracy: 1e-9)
        _ = t.update(assignments: twoTiles().assignments.map { a in var a = a; if a.tileID == "a" { a.assignmentGeneration = 8 }; return a })
        XCTAssertEqual(t.pointer.x, 0.15, accuracy: 1e-9, "back on the first tab: where it was")
        XCTAssertEqual(t.pointer.y, 0.3, accuracy: 1e-9)
        var zoomed = t.assignments
        zoomed[0].zoom = WorkspacePaneZoom(scale: 2, centerX: 0.5, centerY: 0.5)
        _ = t.update(assignments: zoomed)
        // 2x around the middle: window (300, 300) is 200 px left of and above the middle at 2x.
        XCTAssertEqual(t.pointer.x, 0.05, accuracy: 1e-9, "still on the same spot of the window")
        XCTAssertEqual(t.pointer.y, 0.1, accuracy: 1e-9)
        let press = try XCTUnwrap(t.resolveAtPointer(.down))
        XCTAssertEqual(press.point.x, 300, accuracy: 1e-6)
        XCTAssertEqual(press.point.y, 300, accuracy: 1e-6)
    }

    // MARK: Keyboard arbitration

    func testKeysOnlyReachTheActiveTilesFocusedWindow() {
        let a = twoTiles().assignment("a")
        XCTAssertEqual(WorkspaceKeyboardGate.decide(active: nil, frontmostPID: 100, focusedWindowID: 10, focusedWindowIsChild: false), .noActiveTile)
        XCTAssertEqual(WorkspaceKeyboardGate.decide(active: a, frontmostPID: 300, focusedWindowID: nil, focusedWindowIsChild: false), .hostFocusElsewhere)
        XCTAssertEqual(WorkspaceKeyboardGate.decide(active: a, frontmostPID: 100, focusedWindowID: 10, focusedWindowIsChild: false), .deliver)
        XCTAssertEqual(WorkspaceKeyboardGate.decide(active: a, frontmostPID: 100, focusedWindowID: 55, focusedWindowIsChild: false), .otherWindowFocused)
        XCTAssertEqual(WorkspaceKeyboardGate.decide(active: a, frontmostPID: 100, focusedWindowID: 55, focusedWindowIsChild: true), .deliver,
                       "its own dialog or sheet")
        var following = a!
        following.follow = .app
        XCTAssertEqual(WorkspaceKeyboardGate.decide(active: following, frontmostPID: 100, focusedWindowID: 55, focusedWindowIsChild: false), .deliver)
    }

    // MARK: Budget

    func testTwoWindowsWithOneFrameStillTypeIntoTheActiveOne() {
        // Measured on the Moto: two windows stacked exactly on the Mac; the
        // focused one must resolve to the active tile's window, not its twin.
        let frame = CGRect(x: 300, y: 200, width: 800, height: 532)
        let frames: [UInt32: CGRect] = [7: frame, 9: frame, 11: CGRect(x: 0, y: 0, width: 400, height: 300)]
        let match = WindowWorkspaceEngine.framesMatch
        for active: UInt32 in [7, 9] {
            XCTAssertEqual(WorkspaceKeyboardGate.focusedTileWindow(active: active, focusedFrame: frame, isChild: false, frames: frames, matches: match), active)
        }
        XCTAssertEqual(WorkspaceKeyboardGate.focusedTileWindow(active: 7, focusedFrame: frames[11]!, isChild: false, frames: frames, matches: match), 11)
        XCTAssertEqual(WorkspaceKeyboardGate.focusedTileWindow(active: 7, focusedFrame: CGRect(x: 5, y: 5, width: 50, height: 50), isChild: false, frames: frames, matches: match), 0)
        XCTAssertNil(WorkspaceKeyboardGate.focusedTileWindow(active: 7, focusedFrame: CGRect(x: 5, y: 5, width: 50, height: 50), isChild: true, frames: frames, matches: match))
    }

    func testCaptureBudgetFavoursTheActiveTile() {
        XCTAssertEqual(WorkspaceCaptureBudget.fps(isActive: true, tileCount: 9, streamFPS: 60, available: true), 60)
        XCTAssertEqual(WorkspaceCaptureBudget.fps(isActive: false, tileCount: 3, streamFPS: 60, available: true), 30)
        XCTAssertEqual(WorkspaceCaptureBudget.fps(isActive: false, tileCount: 6, streamFPS: 60, available: true), 15)
        XCTAssertEqual(WorkspaceCaptureBudget.fps(isActive: false, tileCount: 9, streamFPS: 60, available: true), 10)
        XCTAssertEqual(WorkspaceCaptureBudget.fps(isActive: true, tileCount: 9, streamFPS: 60, available: false), 0, "minimized costs nothing")
        let size = WorkspaceCaptureBudget.captureSize(tilePixels: CGSize(width: 640, height: 360), window: CGSize(width: 1600, height: 1000),
                                                      backingScale: 2, rotation: .none)
        XCTAssertEqual(size.width, 576)
        XCTAssertEqual(size.height, 360)
        let rotated = WorkspaceCaptureBudget.captureSize(tilePixels: CGSize(width: 360, height: 640), window: CGSize(width: 1600, height: 1000),
                                                         backingScale: 2, rotation: .quarter)
        XCTAssertEqual(rotated, size, "a quarter-turned tile captures the window upright")
        let tiny = WorkspaceCaptureBudget.captureSize(tilePixels: CGSize(width: 4000, height: 4000), window: CGSize(width: 300, height: 200),
                                                      backingScale: 2, rotation: .none)
        XCTAssertEqual(tiny, CGSize(width: 600, height: 400), "never above the window's own pixels")
        let fill = WorkspaceCaptureBudget.captureSize(tilePixels: CGSize(width: 640, height: 360), window: CGSize(width: 1600, height: 1000),
                                                      backingScale: 2, rotation: .none, fit: .fill)
        XCTAssertEqual(fill.width, 640)
    }
}

// MARK: - Natural Touch in Window mode

/// Natural Touch commands from the real engine, mapped the way `InputInjector`
/// maps them in Window mode: moves resolve as hover/drag, buttons and scrolls
/// at the workspace pointer.
extension WindowWorkspaceTargetingTests {
    private func naturalTiles(rotationB: WorkspaceRotation = .none) -> WorkspaceInputTargeting {
        var t = WorkspaceInputTargeting()
        t.canvas = CGSize(width: 2000, height: 1000)
        t.windowFrames = [10: CGRect(x: 0, y: 0, width: 1000, height: 1000), 11: CGRect(x: 3000, y: 100, width: 1000, height: 1000)]
        _ = t.update(assignments: [
            WorkspaceTileAssignment(tileID: "a", rect: .init(x: 0, y: 0, width: 0.5, height: 1), windowID: 10, windowGeneration: 1,
                                    pid: 100, bundleID: "a", follow: .window, rotation: .none, fit: .fit, assignmentGeneration: 1),
            WorkspaceTileAssignment(tileID: "b", rect: .init(x: 0.5, y: 0, width: 0.5, height: 1), windowID: 11, windowGeneration: 1,
                                    pid: 200, bundleID: "b", follow: .window, rotation: rotationB, fit: .fit, assignmentGeneration: 2),
        ])
        return t
    }

    private enum Routed: Equatable { case hover(String?), down(String), up(String), scroll(String) }

    private func route(_ commands: [PointerCommand], _ t: inout WorkspaceInputTargeting) -> [Routed] {
        var out: [Routed] = []
        for c in commands {
            switch c {
            case .moveAbsolute(let x, let y): out.append(.hover(t.resolve(.move, at: .init(x: x, y: y))?.tileID))
            case .mouseDown: if let r = t.resolveAtPointer(.down) { out.append(.down(r.tileID)) }
            case .mouseUp: if let r = t.resolveAtPointer(.up) { out.append(.up(r.tileID)) }
            case .scroll: if let r = t.resolveAtPointer(.scroll) { out.append(.scroll(r.tileID)) }
            default: break
            }
        }
        return out
    }

    private func touch(_ e: PointerGestureEngine, _ phase: PointerTouchSample.Phase, _ x: Double, _ y: Double, _ time: Double) -> [PointerCommand] {
        // Canvas 2000x1000 shown 1:1 in view points.
        e.handle(PointerTouchSample(id: AnyHashable(1), phase: phase, viewPoint: CGPoint(x: x, y: y),
                                    normalized: CGPoint(x: x / 2000, y: y / 1000), time: time))
    }

    func testNaturalScrollStaysInTheTouchedTileEvenWhenInactiveAndTheFingerCrossesTiles() {
        var t = naturalTiles()
        _ = t.resolve(.down, at: .init(x: 0.25, y: 0.5)); _ = t.resolve(.up, at: .init(x: 0.25, y: 0.5))
        XCTAssertEqual(t.activeTile, "a")
        let e = PointerGestureEngine(); e.setTouchStyle(.natural)
        var commands = touch(e, .began, 1500, 500, 0)
        commands += touch(e, .moved, 1500, 540, 0.03)
        commands += touch(e, .moved, 900, 600, 0.06)   // the finger is now over tile a
        commands += touch(e, .ended, 900, 600, 0.08)
        let routed = route(commands, &t)
        XCTAssertEqual(routed.first, .hover(nil), "parking the pointer over an inactive tile moves nothing on the Mac")
        XCTAssertEqual(routed.filter { if case .scroll = $0 { return true }; return false }, [.scroll("b"), .scroll("b")],
                       "every scroll of the gesture goes to the tile it started in")
        XCTAssertEqual(t.activeTile, "a", "scrolling never changes the active tile or keyboard focus")
        XCTAssertNil(t.boundTile)
    }

    func testNaturalPressDragIsBoundToItsStartTileAndPressesAtTheTouchDownPoint() {
        var t = naturalTiles()
        let e = PointerGestureEngine(); e.setTouchStyle(.natural)
        var commands = touch(e, .began, 500, 500, 0)
        commands += touch(e, .moved, 1500, 500, 0.3)    // rested, then moved into tile b
        commands += touch(e, .ended, 1500, 500, 0.4)
        guard case .moveAbsolute(let px, _) = commands[0] else { return XCTFail("press point first") }
        XCTAssertEqual(px, 0.25, accuracy: 1e-9)
        var downPoint: CGPoint?
        var probe = t
        _ = probe.resolve(.move, at: .init(x: 0.25, y: 0.5)); downPoint = probe.resolveAtPointer(.down)?.point
        XCTAssertEqual(downPoint?.x ?? -1, 500, accuracy: 1e-6, "the press lands under the touch-down point")
        XCTAssertEqual(route(commands, &t), [.hover(nil), .down("a"), .hover("a"), .up("a")])
        XCTAssertNil(t.boundTile, "released on lift")
    }

    func testNaturalLongPressRightClicksInTheTouchedTileAndActivatesIt() {
        var t = naturalTiles()
        let e = PointerGestureEngine(); e.setTouchStyle(.natural)
        var commands = touch(e, .began, 1500, 500, 0)
        commands += e.poll(now: PointerGestureConfig.naturalLongPressDelay)
        commands += touch(e, .ended, 1500, 500, 1)
        XCTAssertEqual(route(commands, &t), [.hover(nil), .down("b"), .up("b")])
        XCTAssertEqual(t.activeTile, "b")
    }

    func testNaturalScrollInRotatedTilesFollowsTheWindowsAxes() {
        for rotation in WorkspaceRotation.allCases {
            var t = naturalTiles(rotationB: rotation)
            _ = t.resolve(.move, at: .init(x: 0.75, y: 0.5))   // pointer parked in tile b
            let v = t.sourceVector(dx: 0, dy: 40)               // a downward swipe on the canvas
            switch rotation {
            case .none: XCTAssertTrue(abs(v.dx) < 1e-6 && v.dy > 0, "\(rotation) \(v)")
            case .half: XCTAssertTrue(abs(v.dx) < 1e-6 && v.dy < 0, "\(rotation) \(v)")
            case .quarter, .threeQuarter: XCTAssertTrue(abs(v.dy) < 1e-6 && abs(v.dx) > 0, "\(rotation) \(v)")
            }
            XCTAssertEqual(t.resolveAtPointer(.scroll)?.tileID, "b", "\(rotation)")
        }
    }
}

/// Per-pane view: Fit by default, zoom 0.7x-8x around the fingers, navigable pan, exact input.
final class WorkspaceZoomTests: XCTestCase {
    private let window = WorkspaceSize(width: 1600, height: 1000)
    private let pane = WorkspaceSize(width: 800, height: 800)

    private func transform(_ z: WorkspacePaneZoom?, fit: WorkspaceFit = .fit, rotation: WorkspaceRotation = .none) -> TileContentTransform {
        TileContentTransform(tile: WorkspaceRect(x: 0, y: 0, width: pane.width, height: pane.height), source: window,
                             rotation: rotation, fit: fit, zoom: z ?? .identity)
    }

    func testZoomParsesAndClampsFromTheWire() {
        XCTAssertNil(WorkspacePaneZoom(wire: nil))
        XCTAssertNil(WorkspacePaneZoom(wire: [1, 2]))
        XCTAssertEqual(WorkspacePaneZoom(wire: [20.0, 0.5, 0.5])?.scale, 8, "8x at most")
        XCTAssertEqual(WorkspacePaneZoom(wire: [0.1, 0.5, 0.5])?.scale, 0.7, "0.7x at least")
        XCTAssertEqual(WorkspacePaneZoom(wire: [Double.nan, 0.5, 0.5])?.scale, 1)
        XCTAssertEqual(WorkspaceFit.resolved(.auto, tile: pane, source: window), .fit, "old \"auto\" panes show the whole window")
    }

    func testFitShowsTheWholeSourceCentredAndAResizedPaneNeverCrops() {
        let c = transform(nil).contentRect
        XCTAssertEqual(c.width, 800, accuracy: 1e-9); XCTAssertEqual(c.height, 500, accuracy: 1e-9)
        XCTAssertEqual(c.y, 150, accuracy: 1e-9, "centred, letterboxed")
        for w in [300.0, 1200, 1999] {
            let t = TileContentTransform(tile: WorkspaceRect(x: 0, y: 0, width: w, height: 600), source: window, rotation: .none, fit: .fit)
            XCTAssertLessThanOrEqual(t.contentRect.width, w + 1e-9); XCTAssertLessThanOrEqual(t.contentRect.height, 600 + 1e-9)
        }
        let fill = transform(nil, fit: .fill).contentRect
        XCTAssertEqual(fill.height, 800, accuracy: 1e-9, "Fill covers the pane")
        XCTAssertEqual(fill.width / fill.height, 1.6, accuracy: 1e-9, "never stretched")
    }

    func testUnderzoomShowsTheWholeSourceAt70PercentCentredAndInputOutsideItSendsNothing() {
        let t = transform(WorkspacePaneZoom(scale: 0.7, centerX: 0.5, centerY: 0.5))
        let c = t.contentRect
        XCTAssertEqual(c.width, 560, accuracy: 1e-9); XCTAssertEqual(c.height, 350, accuracy: 1e-9)
        XCTAssertEqual(c.midX, 400, accuracy: 1e-9); XCTAssertEqual(c.midY, 400, accuracy: 1e-9)
        XCTAssertNil(t.sourcePoint(fromCanvas: WorkspacePoint(x: 50, y: 400)), "empty pane space never clicks the Mac")
        let p = t.sourcePoint(fromCanvas: WorkspacePoint(x: 400, y: 400))
        XCTAssertEqual(p?.x ?? 0, 800, accuracy: 1e-9); XCTAssertEqual(p?.y ?? 0, 500, accuracy: 1e-9)
        // Moved by hand (free canvas): the source's left edge can come to the pane's centre and
        // no further, so the source still covers the centre and can't be lost.
        let movedT = transform(WorkspacePaneZoom(scale: 0.7, centerX: -3, centerY: 0.5))
        let moved = movedT.contentRect
        XCTAssertEqual(moved.x, 400, accuracy: 1e-9, "left edge at the pane's centre")
        XCTAssertEqual(moved.maxX, 960, accuracy: 1e-9, "the rest runs past the pane: intended empty canvas on the left")
        XCTAssertNil(movedT.sourcePoint(fromCanvas: WorkspacePoint(x: 100, y: 400)), "empty canvas never clicks the Mac")
        XCTAssertEqual(movedT.sourcePoint(fromCanvas: WorkspacePoint(x: 400.5, y: 400))?.x ?? -1, 0, accuracy: 2, "just right of centre is the source's left edge")
    }

    func testPinchKeepsTheSourcePointUnderTheFingersAndClampsCleanlyAt8xAnd07x() throws {
        let from = WorkspacePoint(x: 0.25, y: 0.5), to = WorkspacePoint(x: 0.25, y: 0.5)
        let z2 = try XCTUnwrap(WorkspaceZoom.pinched(nil, tile: pane, source: window, rotation: .none, fit: .fit, ratio: 2, from: from, to: to))
        XCTAssertEqual(z2.scale, 2, accuracy: 1e-9)
        let before = transform(nil).sourcePoint(fromCanvas: WorkspacePoint(x: 200, y: 400))!
        let after = transform(z2).sourcePoint(fromCanvas: WorkspacePoint(x: 200, y: 400))!
        XCTAssertEqual(after.x, before.x, accuracy: 1e-6, "the point under the fingers stays there")
        XCTAssertEqual(after.y, before.y, accuracy: 1e-6)
        let huge = try XCTUnwrap(WorkspaceZoom.pinched(z2, tile: pane, source: window, rotation: .none, fit: .fit, ratio: 100, from: from, to: to))
        XCTAssertEqual(huge.scale, 8, "clamped at 8x")
        let tiny = try XCTUnwrap(WorkspaceZoom.pinched(huge, tile: pane, source: window, rotation: .none, fit: .fit, ratio: 0.0001, from: from, to: to))
        XCTAssertEqual(tiny.scale, 0.7, "clamped at 0.7x, no overshoot")
        // Through 1x and back without drift: a pinch that ends where it started is the default view again.
        var z: WorkspacePaneZoom? = nil
        for r in [1.3, 2.1, 0.6, 1.7, 0.4, 1.0] {
            z = WorkspaceZoom.pinched(nil, tile: pane, source: window, rotation: .none, fit: .fit, ratio: r,
                                      from: WorkspacePoint(x: 0.5, y: 0.5), to: WorkspacePoint(x: 0.5, y: 0.5))
        }
        XCTAssertNil(z, "back at 1x, centred")
    }

    /// Free canvas (a88a3b5): a zoomed pane pans until the source's edge or corner reaches the
    /// pane's centre, leaves empty canvas beyond it on purpose, stays recoverable and maps input.
    func testPanningAZoomedPaneBringsAnEdgeOrCornerToTheCentreAndStaysRecoverable() throws {
        let start = WorkspacePaneZoom(scale: 3, centerX: 0.5, centerY: 0.5)
        let z = try XCTUnwrap(WorkspaceZoom.pinched(start, tile: pane, source: window, rotation: .none, fit: .fit, ratio: 1,
                                                    from: WorkspacePoint(x: 0.5, y: 0.5), to: WorkspacePoint(x: 30, y: 0.5)))
        let t = transform(z)
        XCTAssertEqual(t.contentRect.x, 400, accuracy: 1e-6, "dragged far right: the left edge stops at the pane's centre")
        XCTAssertNil(t.sourcePoint(fromCanvas: WorkspacePoint(x: 1, y: 400)), "empty canvas left of it, which sends nothing")
        let edge = try XCTUnwrap(t.sourcePoint(fromCanvas: WorkspacePoint(x: 401, y: 400)), "the source still covers the centre")
        XCTAssertEqual(edge.x, 0, accuracy: 1, "and it's the source's left edge")
        // Input maps both ways on the visible part.
        let src = WorkspacePoint(x: 40, y: 500)
        let back = try XCTUnwrap(t.sourcePoint(fromCanvas: t.canvasPoint(fromSource: src)))
        XCTAssertEqual(back.x, src.x, accuracy: 1e-6); XCTAssertEqual(back.y, src.y, accuracy: 1e-6)

        // A corner: top-left at the centre, empty canvas up and left.
        let corner = transform(WorkspacePaneZoom(scale: 3, centerX: -1, centerY: -1)).contentRect
        XCTAssertEqual(corner.x, 400, accuracy: 1e-6); XCTAssertEqual(corner.y, 400, accuracy: 1e-6)

        // Recoverable: dragging back the other way brings the source across the pane again.
        let back2 = try XCTUnwrap(WorkspaceZoom.pinched(z, tile: pane, source: window, rotation: .none, fit: .fit, ratio: 1,
                                                        from: WorkspacePoint(x: 0.5, y: 0.5), to: WorkspacePoint(x: -0.5, y: 0.5)))
        XCTAssertLessThan(transform(back2).contentRect.x, 0, "the source covers the pane again")
        XCTAssertNotNil(transform(back2).sourcePoint(fromCanvas: WorkspacePoint(x: 1, y: 400)))
    }

    func testZoomedAndRotatedPanesMapInputBothWays() {
        for rotation in WorkspaceRotation.allCases {
            for s in [0.7, 1, 3.5, 8] {
                let t = transform(WorkspacePaneZoom(scale: s, centerX: 0.3, centerY: 0.6), rotation: rotation)
                let src = WorkspacePoint(x: 700, y: 420)
                let q = t.canvasPoint(fromSource: src)
                guard let back = t.sourcePoint(fromCanvas: q) else { continue }   // may be outside the pane when zoomed in
                XCTAssertEqual(back.x, src.x, accuracy: 1e-6, "\(rotation) \(s)")
                XCTAssertEqual(back.y, src.y, accuracy: 1e-6, "\(rotation) \(s)")
            }
        }
    }

    func testChangingATilesWindowDropsItsZoom() {
        var layout = WorkspaceLayout(preset: .single, tiles: [WorkspaceTile(id: "a", source: WorkspaceSource(host: "h", windowID: 1))])
        layout = layout.zooming("a", to: WorkspacePaneZoom(scale: 2, centerX: 0.3, centerY: 0.3))
        XCTAssertNotNil(layout.tiles["a"]?.zoom)
        layout = layout.replacingSource(of: "a", with: WorkspaceSource(host: "h", windowID: 2))
        XCTAssertNil(layout.tiles["a"]?.zoom)
    }
}
