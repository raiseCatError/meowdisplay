import XCTest

/// The window-workspace layout engine and tile transform (Shared/WindowWorkspace.swift).
/// Property tests use a fixed-seed generator so failures reproduce.
final class WindowWorkspaceTests: XCTestCase {
    private struct SeededRandom: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    private func tiles(_ n: Int) -> [WorkspaceTile] {
        (0..<n).map { WorkspaceTile(id: "t\($0)", source: WorkspaceSource(host: "mac-a", windowID: UInt32(100 + $0))) }
    }

    private let sizes: [WorkspaceSize] = [
        .init(width: 390, height: 844), .init(width: 844, height: 390), .init(width: 360, height: 640),
        .init(width: 1024, height: 1366), .init(width: 1366, height: 1024), .init(width: 320, height: 1024),
        .init(width: 673, height: 841), .init(width: 1920, height: 1080), .init(width: 2560, height: 1080),
    ]

    private func assertTiling(_ frames: WorkspaceFrames, file: StaticString = #filePath, line: UInt = #line) {
        let rects = frames.slots
        let total = rects.reduce(0) { $0 + $1.area }
        XCTAssertEqual(total, 1, accuracy: 1e-9, "slots must cover the workspace exactly", file: file, line: line)
        for (i, a) in rects.enumerated() {
            XCTAssertGreaterThanOrEqual(a.width, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(a.height, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(a.x, -1e-9, file: file, line: line)
            XCTAssertLessThanOrEqual(a.maxX, 1 + 1e-9, file: file, line: line)
            for b in rects[(i + 1)...] {
                XCTAssertLessThan(a.intersection(b)?.area ?? 0, 1e-9, "slots overlap", file: file, line: line)
            }
        }
    }

    // MARK: Transform

    func testTransformRoundTripsForEveryRotationAndFit() {
        var rng = SeededRandom(state: 7)
        for _ in 0..<400 {
            let tile = WorkspaceRect(x: .random(in: 0...800, using: &rng), y: .random(in: 0...800, using: &rng),
                                     width: .random(in: 40...1200, using: &rng), height: .random(in: 40...1200, using: &rng))
            let source = WorkspaceSize(width: .random(in: 50...3000, using: &rng), height: .random(in: 50...3000, using: &rng))
            for rotation in WorkspaceRotation.allCases {
                for fit in [WorkspaceFit.fit, .fill] {
                    let t = TileContentTransform(tile: tile, source: source, rotation: rotation, fit: fit)
                    for _ in 0..<8 {
                        let p = WorkspacePoint(x: .random(in: 0..<source.width, using: &rng),
                                               y: .random(in: 0..<source.height, using: &rng))
                        let q = t.canvasPoint(fromSource: p)
                        guard t.visibleRect?.contains(q) == true else {
                            XCTAssertEqual(fit, .fill, "with fit, every window pixel is visible")
                            continue
                        }
                        let back = try! XCTUnwrap(t.sourcePoint(fromCanvas: q))
                        XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
                        XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
                    }
                    if fit == .fit {
                        XCTAssertLessThanOrEqual(t.contentRect.width, tile.width + 1e-6)
                        XCTAssertLessThanOrEqual(t.contentRect.height, tile.height + 1e-6)
                    } else {
                        XCTAssertGreaterThanOrEqual(t.contentRect.width, tile.width - 1e-6)
                        XCTAssertGreaterThanOrEqual(t.contentRect.height, tile.height - 1e-6)
                    }
                    // Never stretched: the aspect ratio of the drawn image is the window's (rotated).
                    let r = t.rotatedSourceSize
                    XCTAssertEqual(t.contentRect.width / t.contentRect.height, r.width / r.height, accuracy: 1e-6)
                }
            }
        }
    }

    func testQuarterTurnPutsTheWindowTopLeftAtTheTileTopRight() {
        let tile = WorkspaceRect(x: 0, y: 0, width: 100, height: 200)
        let t = TileContentTransform(tile: tile, source: .init(width: 200, height: 100), rotation: .quarter, fit: .fit)
        let q = t.canvasPoint(fromSource: .init(x: 0, y: 0))
        XCTAssertEqual(q.x, 100, accuracy: 1e-9)
        XCTAssertEqual(q.y, 0, accuracy: 1e-9)
        let t270 = TileContentTransform(tile: tile, source: .init(width: 200, height: 100), rotation: .threeQuarter, fit: .fit)
        let q2 = t270.canvasPoint(fromSource: .init(x: 0, y: 0))
        XCTAssertEqual(q2.x, 0, accuracy: 1e-9)
        XCTAssertEqual(q2.y, 200, accuracy: 1e-9)
        // A rightward swipe on a 90° tile scrolls the window "down" (its +y).
        let v = t.sourceVector(fromCanvas: .init(x: 10, y: 0))
        XCTAssertEqual(v.x, 0, accuracy: 1e-9)
        XCTAssertLessThan(v.y, 0)
        // Vector mapping agrees with point mapping.
        for rotation in WorkspaceRotation.allCases {
            let tr = TileContentTransform(tile: tile, source: .init(width: 200, height: 100), rotation: rotation, fit: .fit)
            let a = WorkspacePoint(x: 50, y: 100), d = WorkspacePoint(x: 7, y: -3)
            let pa = tr.sourcePoint(fromCanvas: a)!, pb = tr.sourcePoint(fromCanvas: .init(x: a.x + d.x, y: a.y + d.y))!
            let vd = tr.sourceVector(fromCanvas: d)
            XCTAssertEqual(pb.x - pa.x, vd.x, accuracy: 1e-9, "\(rotation)")
            XCTAssertEqual(pb.y - pa.y, vd.y, accuracy: 1e-9, "\(rotation)")
        }
    }

    func testLetterboxAndOutsideTheTileNeverMapToTheWindow() {
        let t = TileContentTransform(tile: .init(x: 0, y: 0, width: 400, height: 400),
                                     source: .init(width: 800, height: 400), rotation: .none, fit: .fit)
        XCTAssertNil(t.sourcePoint(fromCanvas: .init(x: 200, y: 50)), "top letterbox bar")
        XCTAssertNil(t.sourcePoint(fromCanvas: .init(x: 200, y: 399)), "bottom letterbox bar")
        XCTAssertNil(t.sourcePoint(fromCanvas: .init(x: 401, y: 200)), "outside the tile")
        XCTAssertNotNil(t.sourcePoint(fromCanvas: .init(x: 200, y: 200)))
        // A drag that wanders out is clamped onto the window's edge.
        let clamped = try! XCTUnwrap(t.clampedSourcePoint(fromCanvas: .init(x: 900, y: -50)))
        XCTAssertEqual(clamped.x, 800, accuracy: 1e-3)
        XCTAssertEqual(clamped.y, 0, accuracy: 1e-9)
        let fill = TileContentTransform(tile: .init(x: 0, y: 0, width: 400, height: 400),
                                        source: .init(width: 800, height: 400), rotation: .none, fit: .fill)
        XCTAssertNotNil(fill.sourcePoint(fromCanvas: .init(x: 0, y: 0)), "fill shows pixels to the tile edge")
        XCTAssertEqual(fill.sourcePoint(fromCanvas: .init(x: 0, y: 0))!.x, 200, accuracy: 1e-9, "cropped evenly")
    }

    // MARK: Presets and frames

    func testEveryPresetTilesTheWorkspaceExactlyOnEverySize() {
        for preset in WorkspacePreset.allCases {
            let layout = WorkspaceLayout(preset: preset, tiles: tiles(preset.slotCount))
            XCTAssertEqual(layout.slotCount, preset.slotCount, "\(preset)")
            XCTAssertEqual(layout.tiles.count, preset.slotCount)
            for size in sizes {
                let frames = WorkspaceGeometry.frames(for: layout, in: size)
                assertTiling(frames)
                XCTAssertEqual(frames.tiles.count, preset.slotCount)
            }
        }
    }

    func testCapacityFollowsTheUsableSpaceNotTheDevice() {
        XCTAssertEqual(WorkspaceGeometry.capacity(for: .init(width: 390, height: 844)), 9, "phone portrait: 3x3 fits")
        XCTAssertEqual(WorkspaceGeometry.capacity(for: .init(width: 844, height: 390)), 9, "phone landscape: 3x3 fits")
        XCTAssertEqual(WorkspaceGeometry.capacity(for: .init(width: 300, height: 500)), 6, "small cover screen")
        XCTAssertEqual(WorkspaceGeometry.capacity(for: .init(width: 1024, height: 1366)), 9, "iPad Pro")
        XCTAssertEqual(WorkspaceGeometry.capacity(for: .init(width: 744, height: 1133)), 9, "iPad mini")
        XCTAssertLessThanOrEqual(WorkspaceGeometry.capacity(for: .init(width: 320, height: 1024)), 6, "iPad Split View third")
        XCTAssertEqual(WorkspaceSizeClass.of(.init(width: 790, height: 820)), .expanded, "unfolded foldable inner display")
        XCTAssertEqual(WorkspaceSizeClass.of(.init(width: 360, height: 780)), .compact, "folded cover display")
        // Tiny windows still get one tile, never zero.
        XCTAssertEqual(WorkspaceGeometry.capacity(for: .init(width: 100, height: 80)), 1)
        // Every capacity it reports really fits at the minimum tile size.
        for size in sizes {
            let n = WorkspaceGeometry.capacity(for: size)
            let layout = WorkspaceLayout(preset: .natural(for: n, landscape: size.width >= size.height), tiles: tiles(n))
            for rect in WorkspaceGeometry.frames(for: layout, in: size).slots {
                XCTAssertGreaterThanOrEqual(rect.width * size.width, WorkspaceGeometry.minimumTile.width - 0.5)
                XCTAssertGreaterThanOrEqual(rect.height * size.height, WorkspaceGeometry.minimumTile.height - 0.5)
            }
        }
    }

    // MARK: Operations

    func testSwapMoveRemoveKeepIdentityAndCoverage() {
        let size = WorkspaceSize(width: 1366, height: 1024)
        var layout = WorkspaceLayout(preset: .grid2x2, tiles: tiles(4))
        let before = WorkspaceGeometry.frames(for: layout, in: size)
        layout = layout.swapping("t0", "t3")
        let after = WorkspaceGeometry.frames(for: layout, in: size)
        XCTAssertEqual(after.tiles["t0"], before.tiles["t3"])
        XCTAssertEqual(after.tiles["t3"], before.tiles["t0"])
        XCTAssertEqual(layout.tiles["t0"]?.source?.windowID, 100, "the source travels with its tile")

        // Split t1's slot on the left with t2: t2 leaves its slot, which closes.
        let t1Index = layout.orderedTileIDs.firstIndex(of: "t1")!
        let moved = layout.moving("t2", to: .split(index: t1Index, edge: .left, preview: .unit))
        XCTAssertEqual(Set(moved.orderedTileIDs), ["t0", "t1", "t2", "t3"])
        XCTAssertEqual(moved.slotCount, 4)
        let mf = WorkspaceGeometry.frames(for: moved, in: size)
        assertTiling(mf)
        XCTAssertLessThan(mf.tiles["t2"]!.x, mf.tiles["t1"]!.x, "inserted on the left")
        XCTAssertEqual(mf.tiles["t2"]!.y, mf.tiles["t1"]!.y, accuracy: 1e-9)

        let removed = moved.removing("t1")
        XCTAssertNil(removed.tiles["t1"])
        XCTAssertEqual(removed.tiles.count, 3)
        assertTiling(WorkspaceGeometry.frames(for: removed, in: size))

        // Dropping onto its own slot or an unknown slot changes nothing.
        let own = layout.orderedTileIDs.firstIndex(of: "t0")!
        XCTAssertEqual(layout.moving("t0", to: .split(index: own, edge: .top, preview: .unit)), layout)
        XCTAssertEqual(layout.moving("t0", to: .slot(index: 99, preview: .unit)), layout)
    }

    func testMovingIntoAnEmptySlotKeepsOtherEmptySlots() {
        let layout = WorkspaceLayout(preset: .grid2x2, tiles: tiles(2))   // two empty slots
        XCTAssertEqual(layout.slotCount, 4)
        let moved = layout.moving("t0", to: .slot(index: 3, preview: .unit))
        XCTAssertEqual(WorkspaceLayout.slotID(moved.root, at: 3), .some("t0"))
        XCTAssertEqual(WorkspaceLayout.slotID(moved.root, at: 0), .some(nil))
        XCTAssertEqual(moved.slotCount, 4)
        let split = layout.moving("t1", to: .split(index: 0, edge: .bottom, preview: .unit))
        XCTAssertEqual(split.tiles.count, 2)
        XCTAssertEqual(split.slotCount, 4, "t1's slot closed, t0's split, the other empty slot kept")
    }

    func testRandomOperationSequencesAlwaysProduceAValidWorkspace() {
        var rng = SeededRandom(state: 42)
        for _ in 0..<150 {
            let size = sizes.randomElement(using: &rng)!
            var layout = WorkspaceLayout(preset: WorkspacePreset.allCases.randomElement(using: &rng)!, tiles: tiles(9))
            var nextID = 20
            for _ in 0..<25 {
                let ids = layout.orderedTileIDs
                let frames = WorkspaceGeometry.frames(for: layout, in: size)
                switch Int.random(in: 0..<7, using: &rng) {
                case 0 where ids.count >= 2:
                    layout = layout.swapping(ids.randomElement(using: &rng)!, ids.randomElement(using: &rng)!)
                case 1 where !ids.isEmpty:
                    layout = layout.removing(ids.randomElement(using: &rng)!)
                case 2:
                    layout = layout.adding(WorkspaceTile(id: "n\(nextID)"), landscape: size.width > size.height)
                    nextID += 1
                case 3 where !ids.isEmpty:
                    let p = WorkspacePoint(x: .random(in: 0..<1, using: &rng), y: .random(in: 0..<1, using: &rng))
                    if let target = WorkspaceGeometry.dropTarget(at: p, frames: frames, size: size, canSplit: layout.tiles.count < 9) {
                        layout = layout.moving(ids.randomElement(using: &rng)!, to: target)
                    }
                case 4 where !frames.dividers.isEmpty:
                    layout = WorkspaceGeometry.resizing(layout, divider: frames.dividers.randomElement(using: &rng)!,
                                                        delta: .random(in: -0.8...0.8, using: &rng), in: size)
                case 5 where !ids.isEmpty:
                    layout = layout.rotating(ids.randomElement(using: &rng)!)
                default:
                    layout = layout.applying(.natural(for: max(ids.count, 1), landscape: size.width > size.height)).layout
                }
                XCTAssertLessThanOrEqual(layout.tiles.count, WorkspaceLayout.maximumTiles)
                XCTAssertEqual(Set(layout.orderedTileIDs), Set(layout.tiles.keys), "tree and table agree")
                XCTAssertEqual(layout.orderedTileIDs.count, Set(layout.orderedTileIDs).count, "no tile twice")
                assertTiling(WorkspaceGeometry.frames(for: layout, in: size))
            }
        }
    }

    func testDividerDragsClampAtTheMinimumTileSize() {
        let size = WorkspaceSize(width: 844, height: 390)
        var layout = WorkspaceLayout(preset: .sideBySide, tiles: tiles(2))
        let divider = WorkspaceGeometry.frames(for: layout, in: size).dividers[0]
        layout = WorkspaceGeometry.resizing(layout, divider: divider, delta: -5, in: size)
        let f = WorkspaceGeometry.frames(for: layout, in: size)
        XCTAssertEqual(f.tiles["t0"]!.width * size.width, WorkspaceGeometry.minimumTile.width, accuracy: 1e-6)
        layout = WorkspaceGeometry.resizing(layout, divider: divider, delta: 5, in: size)
        let g = WorkspaceGeometry.frames(for: layout, in: size)
        XCTAssertEqual(g.tiles["t1"]!.width * size.width, WorkspaceGeometry.minimumTile.width, accuracy: 1e-6)
        // A nested divider: the right column of primary + two.
        var p = WorkspaceLayout(preset: .primaryPlusTwo, tiles: tiles(3))
        let inner = WorkspaceGeometry.frames(for: p, in: size).dividers.first { $0.axis == .vertical }!
        p = WorkspaceGeometry.resizing(p, divider: inner, delta: 0.1, in: size)
        let h = WorkspaceGeometry.frames(for: p, in: size)
        assertTiling(h)
        XCTAssertGreaterThan(h.tiles["t1"]!.height, h.tiles["t2"]!.height)
        XCTAssertEqual(WorkspaceGeometry.resizing(p, divider: inner, delta: .nan, in: size), p)
    }

    func testMaximizeAndRestoreKeepTheArrangement() {
        let layout = WorkspaceLayout(preset: .grid3x3, tiles: tiles(9))
        let size = WorkspaceSize(width: 1366, height: 1024)
        let maxed = layout.maximizing("t4")
        let f = WorkspaceGeometry.frames(for: maxed, in: size)
        XCTAssertEqual(f.tiles, ["t4": .unit])
        XCTAssertEqual(maxed.restoringMaximized(), layout)
        XCTAssertNil(maxed.removing("t4").maximized, "removing the maximized tile restores the rest")
    }

    func testUndoRestoresPreviousArrangementsAndIsBounded() {
        var history = WorkspaceHistory()
        var layout = WorkspaceLayout(preset: .grid2x2, tiles: tiles(4))
        let original = layout
        history.record(layout)
        layout = layout.swapping("t0", "t1")
        XCTAssertEqual(history.undo(), original)
        for i in 0..<50 { history.record(layout.rotating("t\(i % 4)")); layout = layout.rotating("t\(i % 4)") }
        XCTAssertLessThanOrEqual(history.past.count, WorkspaceHistory.depth)
    }

    func testAGroupIsOneUndoStep() {
        var history = WorkspaceHistory()
        let a = WorkspaceLayout(preset: .grid2x2, tiles: tiles(4))
        let b = a.rotating("t0"), c = b.rotating("t1"), d = c.rotating("t2")
        history.record(a)
        history.beginGroup()
        history.record(b); history.record(c)   // a drag in progress
        history.beginGroup()                    // repeated begins stay in the same group
        history.record(d)
        history.endGroup()
        XCTAssertEqual(history.undo(), b)
        XCTAssertEqual(history.undo(), a)
        XCTAssertNil(history.undo())
    }

    func testRedoBringsBackWhatWasUndoneUntilANewChange() {
        var history = WorkspaceHistory()
        let a = WorkspaceLayout(preset: .grid2x2, tiles: tiles(4))
        let b = a.swapping("t0", "t1"), c = b.rotating("t2")
        history.record(a)          // a -> b
        history.record(b)          // b -> c
        XCTAssertEqual(history.undo(current: c), b)
        XCTAssertEqual(history.undo(current: b), a)
        XCTAssertTrue(history.canRedo)
        XCTAssertEqual(history.redo(current: a), b)
        XCTAssertEqual(history.redo(current: b), c)
        XCTAssertFalse(history.canRedo)
        XCTAssertEqual(history.undo(current: c), b)
        history.record(b)          // a new change from b
        XCTAssertFalse(history.canRedo, "a new change ends the redo chain")
    }

    func testASavedLayoutFindsTodaysWindowsOfTheSameApp() {
        let zed = WorkspaceSource(host: "mac-a", windowID: 10, bundleID: "dev.zed.Zed")
        let chrome = WorkspaceSource(host: "mac-a", windowID: 11, bundleID: "com.google.Chrome")
        let desktop = WorkspaceSource(host: "mac-a", windowID: WorkspaceSource.displayKey(1))
        let layout = WorkspaceLayout(preset: .threeColumns, tiles: [
            WorkspaceTile(id: "t0", source: zed), WorkspaceTile(id: "t1", source: chrome), WorkspaceTile(id: "t2", source: desktop),
        ])
        // Zed relaunched (new window id); Chrome's window is still open; Safari is unrelated.
        let today: [(id: UInt32, bundleID: String)] = [(40, "com.apple.Safari"), (41, "dev.zed.Zed"), (11, "com.google.Chrome")]
        let rebound = layout.rebinding(to: today)
        XCTAssertEqual(rebound.tiles["t0"]?.source?.windowID, 41)
        XCTAssertEqual(rebound.tiles["t1"]?.source?.windowID, 11)
        XCTAssertEqual(rebound.tiles["t2"]?.source, desktop, "desktop panes stay")
        // Nothing to match: the pane keeps its old window (and will ask for one).
        let none = layout.rebinding(to: [(40, "com.apple.Safari")])
        XCTAssertEqual(none.tiles["t0"]?.source?.windowID, 10)
        // A saved layout round-trips through storage.
        let saved = WorkspaceSavedLayout(id: "s1", name: "Coding", record: WorkspaceLayoutRecord(layout))
        let back = WorkspaceSavedLayout.decodeList(WorkspaceSavedLayout.encodeList([saved])!)
        XCTAssertEqual(back.first?.name, "Coding")
        XCTAssertEqual(back.first?.record.layout.tiles.count, 3)
    }

    // MARK: Hinge

    func testNoTileEverSitsInsideAHinge() {
        var rng = SeededRandom(state: 99)
        for _ in 0..<200 {
            let vertical = Bool.random(using: &rng)
            let pos = Double.random(in: 0.3...0.7, using: &rng), band = Double.random(in: 0.005...0.04, using: &rng)
            let hinge = WorkspaceHinge(rect: vertical ? .init(x: pos - band / 2, y: 0, width: band, height: 1)
                                                      : .init(x: 0, y: pos - band / 2, width: 1, height: band),
                                       orientation: vertical ? .vertical : .horizontal)
            let preset = WorkspacePreset.allCases.randomElement(using: &rng)!
            let layout = WorkspaceLayout(preset: preset, tiles: tiles(preset.slotCount))
            let size = WorkspaceSize(width: 1600, height: 1400)
            let frames = WorkspaceGeometry.frames(for: layout, in: size, hinge: hinge)
            for (id, rect) in frames.tiles {
                let overlap = rect.intersection(hinge.rect)?.area ?? 0
                XCTAssertLessThan(overlap, 1e-9, "\(preset) tile \(id) overlaps the hinge")
                if vertical {
                    XCTAssertTrue(rect.maxX <= hinge.rect.x + 1e-9 || rect.x >= hinge.rect.maxX - 1e-9, "tile straddles the fold")
                } else {
                    XCTAssertTrue(rect.maxY <= hinge.rect.y + 1e-9 || rect.y >= hinge.rect.maxY - 1e-9, "tile straddles the fold")
                }
            }
            XCTAssertNil(WorkspaceGeometry.dropTarget(at: .init(x: hinge.rect.midX, y: hinge.rect.midY), frames: frames,
                                                      size: size, hinge: hinge, canSplit: true), "no drop target in the hinge")
        }
    }

    func testTabletopPutsOneTileAboveTheFoldAndLeavesTheOtherSideAsATarget() {
        let hinge = WorkspaceHinge(rect: .init(x: 0, y: 0.49, width: 1, height: 0.02), orientation: .horizontal)
        let layout = WorkspaceLayout(preset: .single, tiles: tiles(1))
        let size = WorkspaceSize(width: 800, height: 1700)
        let frames = WorkspaceGeometry.frames(for: layout, in: size, hinge: hinge)
        XCTAssertEqual(frames.slots.count, 2)
        XCTAssertLessThanOrEqual(frames.tiles["t0"]!.maxY, 0.49 + 1e-9)
        // Drag the tile to the lower half: it becomes a real slot, then moves there.
        let target = WorkspaceGeometry.dropTarget(at: .init(x: 0.5, y: 0.8), frames: frames, size: size, hinge: hinge, canSplit: false)
        guard case .slot(let index, _)? = target else { return XCTFail("expected the lower region") }
        let moved = layout.materializing(hinge: hinge).moving("t0", to: .slot(index: index, preview: .unit))
        let after = WorkspaceGeometry.frames(for: moved, in: size, hinge: hinge)
        XCTAssertGreaterThanOrEqual(after.tiles["t0"]!.y, 0.51 - 1e-9)
    }

    // MARK: Adaptation (fold/unfold, rotation, Split View)

    func testCollapsingToACompactScreenStacksTilesAndExpandingRestoresThem() {
        let saved = WorkspaceLayout(preset: .grid3x3, tiles: tiles(9)).swapping("t0", "t8")
        let compact = WorkspaceAdaptation.adapt(saved, to: .init(width: 300, height: 500), active: "t5")
        XCTAssertEqual(compact.visible.tiles.count, 6)
        XCTAssertEqual(compact.stacked.count, 3)
        XCTAssertTrue(compact.visible.tiles.keys.contains("t5"), "the active tile stays visible")
        XCTAssertEqual(Set(compact.visible.orderedTileIDs).union(compact.stacked), Set(saved.orderedTileIDs), "nothing lost")
        XCTAssertEqual(compact.visible.tiles["t5"]?.source, saved.tiles["t5"]?.source, "sources kept")
        let expanded = WorkspaceAdaptation.adapt(saved, to: .init(width: 1366, height: 1024), active: "t5")
        XCTAssertEqual(expanded.visible, saved, "the saved arrangement comes back unchanged")
        XCTAssertTrue(expanded.stacked.isEmpty)
    }

    // MARK: Persistence

    func testLayoutsRoundTripAndMalformedRecordsRecoverValidParts() throws {
        var layout = WorkspaceLayout(preset: .primaryPlusTwo, tiles: tiles(3)).rotating("t1").settingFit(.fill, for: "t2")
        layout = layout.maximizing("t2")
        let data = try XCTUnwrap(WorkspaceLayoutRecord(layout).encoded())
        XCTAssertEqual(WorkspaceLayoutRecord.decode(data), layout)

        let malformed = """
        {"schema":1,"future":"ignored","maximized":"ghost",
         "root":{"axis":"horizontal","ratios":[-1,"x"],"children":[{"tile":"a"},{"tile":"a"},{"tile":"missing"},
           {"axis":"vertical","ratios":[0.5],"children":[{"tile":"b"},{"tile":null}]}]},
         "tiles":[{"id":"a","host":"mac-a","window":5,"rotation":45},{"id":"b","rotation":270,"fit":"stretch"},{"id":""}]}
        """
        // Ratios with a string inside fail strict JSON decoding of that array: decoding still has to succeed.
        let recovered = WorkspaceLayoutRecord.decode(Data(malformed.replacingOccurrences(of: "\"x\"", with: "0").utf8))
        let r = try XCTUnwrap(recovered)
        XCTAssertEqual(Set(r.orderedTileIDs), ["a", "b"], "duplicate and unknown tiles dropped")
        XCTAssertEqual(r.tiles["a"]?.rotation, WorkspaceRotation.none, "45° is not a tile rotation")
        XCTAssertEqual(r.tiles["b"]?.rotation, .threeQuarter)
        XCTAssertEqual(r.tiles["b"]?.fit, .fit, "unknown fit falls back to Fit")
        XCTAssertNil(r.tiles["b"]?.source, "a tile without host+window has no source")
        XCTAssertNil(r.maximized)
        assertTiling(WorkspaceGeometry.frames(for: r, in: .init(width: 1000, height: 800)))
        XCTAssertNil(WorkspaceLayoutRecord.decode(Data("not json".utf8)))
        XCTAssertNil(WorkspaceLayoutRecord.decode(Data(#"{"schema":0,"root":{},"tiles":[]}"#.utf8)))

        // Deep nesting is cut off rather than recursing without bound.
        var deep = #"{"tile":"a"}"#
        for _ in 0..<200 { deep = #"{"axis":"vertical","children":[\#(deep),{"tile":null}]}"# }
        let deepRecord = #"{"schema":1,"root":\#(deep),"tiles":[{"id":"a"}]}"#
        XCTAssertNotNil(WorkspaceLayoutRecord.decode(Data(deepRecord.utf8)))
    }

    // MARK: Fill, zoom shape, tabs, window drops

    func testPanesDefaultToFitAndKeepTheirZoomThroughASave() {
        XCTAssertEqual(WorkspaceTile(id: "a").fit, .fit, "new panes show the whole window")
        let t = TileContentTransform(tile: .init(x: 0, y: 0, width: 430, height: 300), source: .init(width: 1600, height: 1000), rotation: .none, fit: .auto)
        XCTAssertEqual(t.contentRect.width, 430, accuracy: 1e-9, "old \"auto\" panes are Fit: the whole window")
        XCTAssertLessThan(t.contentRect.height, 300)
        var l = WorkspaceLayout(preset: .single, tiles: [WorkspaceTile(id: "a", source: WorkspaceSource(host: "m", windowID: 1))])
        l = l.zooming("a", to: WorkspacePaneZoom(scale: 2.5, centerX: 0.3, centerY: 0.7))
        let back = WorkspaceLayoutRecord(l).encoded().flatMap(WorkspaceLayoutRecord.decode)
        XCTAssertEqual(back?.tiles["a"]?.zoom, WorkspacePaneZoom(scale: 2.5, centerX: 0.3, centerY: 0.7), "zoom survives a save and a reconnect")
        let old = #"{"schema":2,"root":{"tile":"a"},"tiles":[{"id":"a","host":"m","window":1,"fit":"auto"}]}"#
        XCTAssertEqual(WorkspaceLayoutRecord.decode(Data(old.utf8))?.tiles["a"]?.fit, .fit)
    }

    func testTabsAddSwitchRemoveAndOneWindowLivesInOnePane() {
        let a = WorkspaceSource(host: "m", windowID: 1), b = WorkspaceSource(host: "m", windowID: 2), c = WorkspaceSource(host: "m", windowID: 3)
        var l = WorkspaceLayout(preset: .single, tiles: [WorkspaceTile(id: "t", source: a)])
        l = l.addingTab(b, to: "t")
        XCTAssertEqual(l.tiles["t"]?.source, b)
        XCTAssertEqual(l.tiles["t"]?.tabs, [a, b])
        l = l.addingTab(c, to: "t").switchingTab(of: "t", to: 0)
        XCTAssertEqual(l.tiles["t"]?.source, a, "tab order is stable; switching only changes what shows")
        XCTAssertEqual(l.tiles["t"]?.tabs, [a, b, c])
        XCTAssertEqual(l.tile(holding: "m", windowID: 3), "t", "a background tab counts as shown")
        l = l.removingTab(of: "t", at: 0)
        XCTAssertEqual(l.tiles["t"]?.source, b)
        l = l.removingTab(of: "t", at: 1)
        XCTAssertEqual(l.tiles["t"]?.tabs, [], "one window left: a plain pane again")
        XCTAssertEqual(l.tiles["t"]?.source, b)
        let record = WorkspaceLayoutRecord(l.addingTab(c, to: "t")).encoded().flatMap(WorkspaceLayoutRecord.decode)
        XCTAssertEqual(record?.tiles["t"]?.tabs, [b, c], "tabs survive a save")
    }

    /// Each tab keeps its own rotation, Fit/Fill and zoom while another tab is shown, through a
    /// save; a new tab starts at the default view; reordering keeps what's shown.
    func testEachTabKeepsItsOwnViewAndTabsReorder() {
        let a = WorkspaceSource(host: "m", windowID: 1), b = WorkspaceSource(host: "m", windowID: 2), c = WorkspaceSource(host: "m", windowID: 3)
        let z = WorkspacePaneZoom(scale: 2, centerX: 0.25, centerY: 0.75)
        var l = WorkspaceLayout(preset: .single, tiles: [WorkspaceTile(id: "t", source: a)])
        l = l.rotating("t").settingFit(.fill, for: "t").zooming("t", to: z)
        l = l.addingTab(b, to: "t")
        XCTAssertEqual(l.tiles["t"]?.rotation, WorkspaceRotation.none, "a new tab starts at the default view")
        XCTAssertEqual(l.tiles["t"]?.fit, .fit)
        XCTAssertNil(l.tiles["t"]?.zoom)
        l = l.addingTab(c, to: "t").switchingTab(of: "t", to: 1)
        let saved = WorkspaceLayoutRecord(l).encoded().flatMap(WorkspaceLayoutRecord.decode)
        for layout in [l, saved].compactMap({ $0 }) {
            let back = layout.switchingTab(of: "t", to: 0)
            XCTAssertEqual(back.tiles["t"]?.rotation, .quarter, "the first tab's view comes back")
            XCTAssertEqual(back.tiles["t"]?.fit, .fill)
            XCTAssertEqual(back.tiles["t"]?.zoom, z)
            XCTAssertNil(back.switchingTab(of: "t", to: 1).tiles["t"]?.zoom, "the other tab kept its own (default) view")
        }
        // Reorder: the shown tab stays shown; a removed tab's view is forgotten.
        let moved = l.movingTab(of: "t", from: 0, to: 2)
        XCTAssertEqual(moved.tiles["t"]?.tabs, [b, c, a])
        XCTAssertEqual(moved.tiles["t"]?.source, b)
        XCTAssertEqual(moved.switchingTab(of: "t", to: 2).tiles["t"]?.rotation, .quarter)
        XCTAssertNil(l.removingTab(of: "t", at: 0).tiles["t"]?.tabViews[a.tabKey])
        // Where a dropped tab lands among labels centred at 50, 150, 250.
        XCTAssertEqual(WorkspaceTabOrder.index(from: 0, dropX: 200, labelMidXs: [50, 150, 250]), 1)
        XCTAssertEqual(WorkspaceTabOrder.index(from: 0, dropX: 300, labelMidXs: [50, 150, 250]), 2)
        XCTAssertEqual(WorkspaceTabOrder.index(from: 2, dropX: 10, labelMidXs: [50, 150, 250]), 0)
        XCTAssertEqual(WorkspaceTabOrder.index(from: 1, dropX: 160, labelMidXs: [50, 150, 250]), 1, "dropped on itself: unchanged")
    }

    func testWindowDropZonesLabelStripTabsEdgesSplitMiddleReplaces() {
        let l = WorkspaceLayout(preset: .single, tiles: [WorkspaceTile(id: "t", source: WorkspaceSource(host: "m", windowID: 1))])
        let size = WorkspaceSize(width: 1000, height: 800)
        let f = WorkspaceGeometry.frames(for: l, in: size)
        func drop(_ x: Double, _ y: Double) -> WorkspaceWindowDrop? {
            WorkspaceGeometry.windowDrop(at: .init(x: x, y: y), layout: l, frames: f, size: size, labelHeight: 0.05, canSplit: true)
        }
        if case .tab("t", _)? = drop(0.5, 0.03) {} else { XCTFail("label strip adds a tab") }
        if case .replace("t", _)? = drop(0.5, 0.5) {} else { XCTFail("middle replaces") }
        if case .split(0, .right, _)? = drop(0.95, 0.5) {} else { XCTFail("right edge splits") }
        let full = WorkspaceGeometry.windowDrop(at: .init(x: 0.95, y: 0.5), layout: l, frames: f, size: size, labelHeight: 0.05, canSplit: false)
        if case .replace("t", _)? = full {} else { XCTFail("no room for another pane: replace") }
    }
}
