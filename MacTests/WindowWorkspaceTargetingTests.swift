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

    func testRelativeMotionCrossesTilesFreely() {
        var t = twoTiles()
        _ = t.resolve(.down, at: .init(x: 0.25, y: 0.5))
        _ = t.resolve(.up, at: .init(x: 0.25, y: 0.5))
        for _ in 0..<10 { _ = t.resolveRelative(dx: 100, dy: 0) }
        XCTAssertEqual(t.pointer.x, 0.75, accuracy: 1e-9)
        XCTAssertEqual(t.hoveredTile, "b", "the workspace pointer is not trapped in the active tile")
        for _ in 0..<50 { _ = t.resolveRelative(dx: 100, dy: 0) }
        XCTAssertEqual(t.pointer.x, 1, accuracy: 1e-9, "clamped to the workspace")
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
