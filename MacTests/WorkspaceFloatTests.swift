import CoreGraphics
import XCTest

/// Floating panes (Shared/WorkspaceFloats.swift, the Mac's validator and input targeting, and
/// the receiver's model): receiver-local floats that overlap the tiled panes in one canvas.
final class WorkspaceFloatTests: XCTestCase {
    private let ipad = WorkspaceSize(width: 1180, height: 820)
    private let phone = WorkspaceSize(width: 390, height: 844)

    private func src(_ id: UInt32, host: String = "mac-a") -> WorkspaceSource { WorkspaceSource(host: host, windowID: id, bundleID: "app.\(id)") }
    private func tile(_ id: String, _ window: UInt32) -> WorkspaceTile { WorkspaceTile(id: id, source: src(window)) }
    private func threePanes() -> WorkspaceLayout {
        WorkspaceLayout(preset: .primaryPlusTwo, tiles: [tile("a", 10), tile("b", 11), tile("c", 12)])
    }
    private let box = WorkspaceRect(x: 0.3, y: 0.2, width: 0.4, height: 0.4)

    // MARK: Model

    /// A pane floats with its own tile id (the Mac keeps its capture), the tree closes up, and the
    /// float is drawn and hit above the panes; docking puts it back without dropping anything.
    func testAPaneFloatsAndDocksBackKeepingItsIdentity() {
        let start = threePanes()
        let floated = start.floatingPane("b", frame: box)
        XCTAssertEqual(floated.orderedTileIDs, ["a", "c"])
        XCTAssertEqual(floated.floatIDs, ["b"])
        XCTAssertEqual(floated.tiles["b"], start.tiles["b"], "same tile: source, view and id")
        XCTAssertEqual(floated.paneCount, 2)
        XCTAssertEqual(floated.tiles.count, 3)

        let frames = WorkspaceGeometry.frames(for: floated, in: ipad)
        XCTAssertEqual(frames.floats, ["b"])
        XCTAssertEqual(frames.tiles["b"], box)
        XCTAssertEqual(frames.hitTest(WorkspacePoint(x: 0.5, y: 0.4)), "b", "the float is on top")
        XCTAssertEqual(frames.hitTest(WorkspacePoint(x: 0.05, y: 0.9)), "a", "outside it, the pane underneath")
        XCTAssertEqual(frames.slots.count, 2, "floats never take a slot (drops land in the tree)")

        // Back beside pane c: the same id is in the tree again.
        let slotOfC = (0..<floated.slotCount).first { WorkspaceLayout.slotID(floated.root, at: $0) == .some("c") }!
        let docked = floated.docking("b", to: .split(index: slotOfC, edge: .bottom, preview: .unit))
        XCTAssertEqual(Set(docked.orderedTileIDs), ["a", "b", "c"])
        XCTAssertTrue(docked.floats.isEmpty)
        XCTAssertEqual(docked.tiles["b"], start.tiles["b"])

        // Docking onto a pane's middle ("replace") never replaces: it becomes a tab, both windows kept.
        let tabbed = floated.docking("b", to: .replace(tile: "a", preview: .unit))
        XCTAssertEqual(tabbed.orderedTileIDs.count, 2)
        let merged = tabbed.tiles["b"]!
        XCTAssertEqual(merged.source?.windowID, 11, "the docked window shows")
        XCTAssertEqual(merged.tabs.map(\.windowID), [10, 11], "the pane's window stays as a tab")
        XCTAssertNil(tabbed.tiles["a"], "the merged pane takes the float's id, so its capture goes on")
        XCTAssertTrue(tabbed.orderedTileIDs.contains("b"))

        // Add to Layout: a new pane.
        let added = floated.dockingAsPane("b", landscape: true)
        XCTAssertEqual(Set(added.orderedTileIDs), ["a", "b", "c"])
        XCTAssertTrue(added.floats.isEmpty)
    }

    /// A tab floats on its own: the shown tab keeps the pane's id, a background tab gets a new one.
    func testATabFloatsAloneAndNothingIsDropped() {
        var pane = WorkspaceTile(id: "a", source: src(10))
        pane.tabs = [src(10), src(20), src(30)]
        pane.tabViews[src(30).tabKey] = WorkspaceTabView(rotation: .quarter, fit: .fill, zoom: nil)
        let start = WorkspaceLayout(preset: .sideBySide, tiles: [pane, tile("b", 11)])

        let shown = start.floatingTab(of: "a", at: 0, frame: box, newID: "n")
        XCTAssertEqual(shown.floatIDs, ["a"], "the streaming window keeps its tile")
        XCTAssertEqual(shown.tiles["a"]?.source?.windowID, 10)
        XCTAssertTrue(shown.tiles["a"]?.tabs.isEmpty ?? false)
        XCTAssertEqual(shown.tiles["n"]?.tabs.map(\.windowID), [20, 30], "the other tabs stay in the slot")
        XCTAssertTrue(shown.orderedTileIDs.contains("n"))

        let background = start.floatingTab(of: "a", at: 2, frame: box, newID: "n")
        XCTAssertEqual(background.floatIDs, ["n"])
        XCTAssertEqual(background.tiles["n"]?.source?.windowID, 30)
        XCTAssertEqual(background.tiles["n"]?.rotation, .quarter, "the tab's own view comes with it")
        XCTAssertEqual(background.tiles["a"]?.tabs.map(\.windowID), [10, 20])
        let windows = Set(background.tiles.values.flatMap(\.windows).map(\.windowID))
        XCTAssertEqual(windows, [10, 11, 20, 30], "no window left the workspace")
    }

    func testZOrderRaiseSwapTuckAndTheNineTileLimit() {
        var l = threePanes().floatingPane("b", frame: box).addingFloat(tile("f", 40), frame: box)
        XCTAssertEqual(l.floatIDs, ["b", "f"])
        XCTAssertEqual(WorkspaceGeometry.frames(for: l, in: ipad).hitTest(WorkspacePoint(x: 0.5, y: 0.4)), "f")
        l = l.raisingFloat("b")
        XCTAssertEqual(l.floatIDs, ["f", "b"])
        XCTAssertEqual(WorkspaceGeometry.frames(for: l, in: ipad).hitTest(WorkspacePoint(x: 0.5, y: 0.4)), "b")

        // Tucked: not drawn, not hit, kept with its frame; untucked: in front again.
        let tucked = l.tuckingFloat("b", edge: .left, offset: 0.4)
        let tf = WorkspaceGeometry.frames(for: tucked, in: ipad)
        XCTAssertNil(tf.tiles["b"])
        XCTAssertEqual(tf.hitTest(WorkspacePoint(x: 0.5, y: 0.4)), "f")
        XCTAssertEqual(tucked.float("b")?.frame, box)
        XCTAssertEqual(tucked.tuckingFloat("b", edge: .top, offset: 0.4), tucked, "only the left and right edges")
        let back = tucked.raisingFloat("f").untuckingFloat("b")
        XCTAssertNil(back.float("b")?.tuck)
        XCTAssertEqual(back.floatIDs.last, "b")

        // A pane and a float swap places (a pane dropped on a float).
        let swapped = l.swapping("a", "f")
        XCTAssertTrue(swapped.isFloat("a"))
        XCTAssertTrue(swapped.orderedTileIDs.contains("f"))

        // Nine tiles in all, floats included.
        var full = threePanes()
        for i in 0..<6 { full = full.addingFloat(tile("x\(i)", UInt32(50 + i)), frame: box) }
        XCTAssertEqual(full.tiles.count, 9)
        XCTAssertEqual(full.addingFloat(tile("y", 99), frame: box), full)
        XCTAssertEqual(full.adding(tile("z", 98), landscape: true), full)
    }

    /// Local fullscreen of a float fills the picture alone; its float frame comes back after.
    /// Fullscreen of a pane hides the floats until it ends.
    func testLocalFullscreenOfAFloatAndOfAPaneRestoreTheFloatingArrangement() {
        let l = threePanes().floatingPane("b", frame: box)
        let full = WorkspaceGeometry.frames(for: l.maximizing("b"), in: ipad)
        XCTAssertEqual(full.tiles, ["b": .unit])
        XCTAssertTrue(full.slots.allSatisfy { $0.area == 0 }, "no pane slot shows behind it")
        XCTAssertEqual(l.maximizing("b").restoringMaximized().float("b")?.frame, box)
        let pane = WorkspaceGeometry.frames(for: l.maximizing("a"), in: ipad)
        XCTAssertEqual(Array(pane.tiles.keys), ["a"])
        XCTAssertTrue(pane.floats.isEmpty)
    }

    /// Floats survive presets and re-flows of the tree.
    func testPresetsKeepTheFloats() {
        let l = threePanes().floatingPane("b", frame: box)
        let tree = WorkspaceLayout(preset: .sideBySide, tiles: [tile("a", 10), tile("c", 12)])
        let kept = l.replacingTree(with: tree)
        XCTAssertEqual(kept.floatIDs, ["b"])
        XCTAssertEqual(kept.float("b")?.frame, box)
        XCTAssertEqual(l.applying(.single).layout.floatIDs, ["b"])
    }

    // MARK: Persistence and compatibility

    /// A layout without floats is the same schema 3 record as before (the shared vectors are
    /// unchanged); floats make it schema 4, and a reader that ignores `floats` keeps the tree.
    func testRecordsAreSchema3WithoutFloatsAndSchema4WithThem() throws {
        let plain = WorkspaceLayoutRecord(threePanes())
        XCTAssertEqual(plain.schema, 3)
        let plainJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: plain.encoded()!) as? [String: Any])
        XCTAssertNil(plainJSON["floats"], "no new key without floats")

        let l = threePanes().floatingPane("b", frame: box).addingFloat(tile("f", 40), frame: box).tuckingFloat("f", edge: .right, offset: 0.7)
        let record = WorkspaceLayoutRecord(l)
        XCTAssertEqual(record.schema, 4)
        let data = try XCTUnwrap(record.encoded())
        let back = try XCTUnwrap(WorkspaceLayoutRecord.decode(data))
        XCTAssertEqual(back, l, "floats, order and tuck round-trip")

        // What an older reader sees: the tree, with the float tiles dropped (it has no slot for them).
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["floats"] = nil
        let old = try XCTUnwrap(WorkspaceLayoutRecord.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(old.orderedTileIDs, l.orderedTileIDs)
        XCTAssertTrue(old.floats.isEmpty)
        XCTAssertEqual(Set(old.tiles.keys), ["a", "c"])

        // Hostile values are kept on the canvas or dropped, never trusted.
        json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["floats"] = [["tile": "b", "x": -5.0, "y": 9.0, "w": 40.0, "h": 0.5, "tuck": "top"],
                          ["tile": "nope", "x": 0.1, "y": 0.1, "w": 0.2, "h": 0.2],
                          ["tile": "a", "x": 0.1, "y": 0.1, "w": 0.2, "h": 0.2]]
        let hostile = try XCTUnwrap(WorkspaceLayoutRecord.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(hostile.floatIDs, ["b"], "unknown tiles and tiles already in the tree are refused")
        let f = try XCTUnwrap(hostile.float("b"))
        XCTAssertTrue(f.frame.x >= 0 && f.frame.maxX <= 1 && f.frame.y >= 0 && f.frame.maxY <= 1)
        XCTAssertNil(f.tuck, "only left and right tucks")
    }

    /// Rotation, a compact screen and a Mac without floats: floats are kept usable or tucked,
    /// never dropped; the saved arrangement is untouched.
    func testAdaptationKeepsEveryFloat() {
        let l = threePanes().floatingPane("b", frame: WorkspaceRect(x: 0.7, y: 0.6, width: 0.1, height: 0.1))
            .addingFloat(tile("f", 40), frame: box)
        let wide = WorkspaceAdaptation.adapt(l, to: ipad, active: nil)
        let b = try! XCTUnwrap(wide.visible.float("b"))
        XCTAssertGreaterThanOrEqual(b.frame.width * ipad.width, 200 - 1e-6, "grown to the touch minimum")
        XCTAssertLessThanOrEqual(b.frame.maxX, 1 + 1e-9)
        XCTAssertEqual(wide.visible.visibleFloatIDs.count, 2)

        let small = WorkspaceAdaptation.adapt(l, to: phone, active: "b")
        XCTAssertEqual(small.visible.visibleFloatIDs, ["b"], "one float shows on a phone: the active one")
        XCTAssertNotNil(small.visible.float("f")?.tuck, "the other waits tucked")
        XCTAssertEqual(small.visible.floatIDs.count, 2)

        let old = WorkspaceAdaptation.adapt(l, to: ipad, active: nil, floatsShown: false)
        XCTAssertTrue(old.visible.visibleFloatIDs.isEmpty)
        XCTAssertEqual(old.visible.floatIDs.count, 2)

        // Overflowing panes go to the stack; floats stay.
        var many = WorkspaceLayout(preset: .grid3x3, tiles: (0..<8).map { tile("t\($0)", UInt32(10 + $0)) })
        many = many.addingFloat(tile("f", 40), frame: box)
        let tiny = WorkspaceAdaptation.adapt(many, to: WorkspaceSize(width: 300, height: 260), active: nil)
        XCTAssertFalse(tiny.stacked.isEmpty)
        XCTAssertEqual(tiny.visible.floatIDs, ["f"])
        XCTAssertNotNil(tiny.visible.tiles["f"])
    }

    // MARK: Geometry

    func testClampingDefaultsAndCornerResizeKeepTheWindowsShape() {
        let c = WorkspaceFloatGeometry.clamped(WorkspaceRect(x: 0.95, y: -0.2, width: 0.01, height: 2), in: ipad)
        XCTAssertGreaterThanOrEqual(c.width * ipad.width, 200 - 1e-6)
        XCTAssertLessThanOrEqual(c.maxX, 1 + 1e-9)
        XCTAssertGreaterThanOrEqual(c.y * ipad.height, WorkspaceFloatGeometry.barHeight - 1e-6, "the title bar stays on screen")
        XCTAssertLessThanOrEqual(c.maxY, 1 + 1e-9)

        let d = WorkspaceFloatGeometry.defaultFrame(aspect: 16.0 / 10, in: ipad)
        XCTAssertEqual(d.width * ipad.width / (d.height * ipad.height), 1.6, accuracy: 0.01, "opens at the window's shape")
        let cascaded = WorkspaceFloatGeometry.defaultFrame(aspect: 1.6, in: ipad, index: 1)
        XCTAssertEqual((cascaded.x - d.x) * ipad.width, WorkspaceFloatGeometry.cascade, accuracy: 0.5)
        let p = WorkspaceFloatGeometry.defaultFrame(aspect: 1.6, in: phone)
        XCTAssertGreaterThan(p.width, 0.8, "a phone in portrait: nearly full width")

        let start = WorkspaceRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4 * ipad.width / ipad.height / 1.6)
        let bigger = WorkspaceFloatGeometry.resized(start, corner: .bottomTrailing, translation: (100, 10), aspect: 1.6, in: ipad)
        XCTAssertEqual(bigger.x, start.x)
        XCTAssertEqual(bigger.y, start.y)
        XCTAssertEqual(bigger.width * ipad.width / (bigger.height * ipad.height), 1.6, accuracy: 1e-6, "no bars, no distortion")
        XCTAssertEqual(bigger.width * ipad.width, start.width * ipad.width + 100, accuracy: 1e-6)
        let leading = WorkspaceFloatGeometry.resized(start, corner: .bottomLeading, translation: (-50, 0), aspect: 1.6, in: ipad)
        XCTAssertEqual(leading.maxX, start.maxX, accuracy: 1e-9, "the opposite corner stays put")
        let tiny = WorkspaceFloatGeometry.resized(start, corner: .bottomTrailing, translation: (-2000, -2000), aspect: 1.6, in: ipad)
        XCTAssertGreaterThanOrEqual(tiny.width * ipad.width, 200 - 1e-6)
        let huge = WorkspaceFloatGeometry.resized(start, corner: .bottomTrailing, translation: (5000, 5000), aspect: 1.6, in: ipad)
        XCTAssertLessThanOrEqual(huge.maxX, 1 + 1e-9)
        XCTAssertLessThanOrEqual(huge.maxY, 1 + 1e-9)
    }

    /// Several tucked floats on one edge: tabs that never overlap, kept out of the system's
    /// top and bottom bands; too many collapse into one stack.
    func testTuckedTabsStackWithoutOverlapping() {
        let area = WorkspaceRect(x: 0, y: 0, width: 1180, height: 820)
        let three = WorkspaceFloatGeometry.tuckTabs([("a", 0.5), ("b", 0.5), ("c", 0.52)], edge: .right, area: area)
        XCTAssertEqual(three.count, 3)
        for (i, t) in three.enumerated() {
            XCTAssertEqual(t.rect.maxX, area.maxX, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(t.rect.y, area.height * WorkspaceFloatGeometry.tabBand - 1e-9)
            XCTAssertLessThanOrEqual(t.rect.maxY, area.height * (1 - WorkspaceFloatGeometry.tabBand) + 1e-9)
            for other in three[(i + 1)...] { XCTAssertNil(t.rect.intersection(other.rect), "tabs never overlap") }
        }
        let low = WorkspaceFloatGeometry.tuckTabs([("a", 0.99), ("b", 0.99)], edge: .left, area: area)
        XCTAssertTrue(low.allSatisfy { $0.rect.maxY <= area.height * 0.88 + 1e-9 && $0.rect.x == 0 })
        let phoneEdge = WorkspaceRect(x: 0, y: 0, width: 844, height: 300)
        let crowded = WorkspaceFloatGeometry.tuckTabs((0..<5).map { ("f\($0)", 0.5) }, edge: .right, area: phoneEdge)
        XCTAssertEqual(crowded.count, 1)
        XCTAssertEqual(crowded[0].ids.count, 5)
        XCTAssertTrue(crowded[0].isStack)
    }

    // MARK: Fling

    func testReleaseVelocityDecidesStayGlideOrTuck() {
        let mid = WorkspaceRect(x: 0.35, y: 0.3, width: 0.3, height: 0.3)
        // A slow release stays exactly where it is.
        XCTAssertEqual(WorkspaceFloatMotion.decide(release: mid, velocity: (80, 40), in: ipad), .settle(frame: mid, glide: false))
        // A faster release glides on, stays inside, and never hides.
        guard case .settle(let glided, true) = WorkspaceFloatMotion.decide(release: mid, velocity: (700, 0), in: ipad) else { return XCTFail() }
        XCTAssertGreaterThan(glided.x, mid.x)
        XCTAssertEqual(glided.y, mid.y)
        XCTAssertLessThanOrEqual(glided.maxX, 1 + 1e-9)
        // A fast throw across the middle (let go on the far side) never hides the float.
        let left = WorkspaceRect(x: 0.1, y: 0.3, width: 0.3, height: 0.3)
        if case .tuck = WorkspaceFloatMotion.decide(release: left, velocity: (3500, 0), in: ipad) { XCTFail("crossing the middle must not tuck") }
        // An intentional fling at the near edge tucks it, at the height it was heading for.
        let right = WorkspaceRect(x: 0.6, y: 0.3, width: 0.3, height: 0.3)
        XCTAssertEqual(WorkspaceFloatMotion.decide(release: right, velocity: (2600, 0), in: ipad),
                       .tuck(edge: .right, offset: right.midY))
        let leftSide = WorkspaceRect(x: 0.05, y: 0.4, width: 0.3, height: 0.3)
        guard case .tuck(.left, _) = WorkspaceFloatMotion.decide(release: leftSide, velocity: (-2600, -300), in: ipad) else { return XCTFail() }
        // Mostly downward: no tuck (the top and bottom are the system's).
        if case .tuck = WorkspaceFloatMotion.decide(release: right, velocity: (1300, 2600), in: ipad) { XCTFail("a steep fling must not tuck") }
        // Slow, but pulled more than halfway past the edge on purpose: tucks.
        let pulled = WorkspaceRect(x: 0.88, y: 0.3, width: 0.3, height: 0.3)
        XCTAssertEqual(WorkspaceFloatMotion.decide(release: pulled, velocity: (0, 0), in: ipad), .tuck(edge: .right, offset: pulled.midY))
        // Thrown back inward from there: it comes back in.
        guard case .settle(let backIn, true) = WorkspaceFloatMotion.decide(release: pulled, velocity: (-2400, 0), in: ipad) else { return XCTFail() }
        XCTAssertLessThanOrEqual(backIn.maxX, 1 + 1e-9)
        // Hanging a little past the edge, let go slowly: pulled back inside.
        let hanging = WorkspaceRect(x: 0.8, y: 0.3, width: 0.3, height: 0.3)
        guard case .settle(let inside, true) = WorkspaceFloatMotion.decide(release: hanging, velocity: (0, 0), in: ipad) else { return XCTFail() }
        XCTAssertEqual(inside.maxX, 1, accuracy: 1e-9)
        // Not allowed to tuck: never tucks.
        if case .tuck = WorkspaceFloatMotion.decide(release: pulled, velocity: (2600, 0), in: ipad, canTuck: false) { XCTFail() }
    }

    func testTheSpringCarriesTheReleaseVelocityAndSettles() {
        let start = WorkspaceFloatMotion.spring(from: 0, to: 300, velocity: 1500, t: 1e-6)
        XCTAssertEqual(start.value, 0, accuracy: 0.01)
        XCTAssertEqual(start.velocity, 1500, accuracy: 1, "continuous with the finger")
        let end = WorkspaceFloatMotion.spring(from: 0, to: 300, velocity: 1500, t: 1.2)
        XCTAssertEqual(end.value, 300, accuracy: 0.5)
        XCTAssertEqual(end.velocity, 0, accuracy: 5)
        XCTAssertEqual(WorkspaceFloatMotion.projection(1000), 199, accuracy: 0.5)
    }

    // MARK: Shake to switch placement

    func testAShakeSwitchesPlacementButDragCorrectionsDoNot() {
        var s = WorkspaceShakeDetector()
        // An ordinary drag with one overshoot and a correction.
        var t = 0.0
        for x in stride(from: 0.0, through: 300, by: 10) { t += 0.016; XCTAssertFalse(s.add(x: x, y: 100, at: t)) }
        for x in stride(from: 300.0, through: 260, by: -10) { t += 0.016; XCTAssertFalse(s.add(x: x, y: 100, at: t)) }
        // A small wobble (under the amplitude) never counts.
        s.reset(); t = 0
        for i in 0..<60 { t += 0.016; XCTAssertFalse(s.add(x: 200 + (i % 2 == 0 ? 8 : -8), y: 100, at: t)) }
        // Slow back-and-forth (one swing a second) isn't a shake.
        s.reset(); t = 0
        for x in [0.0, 60, 0, 60, 0] { t += 1.0; XCTAssertFalse(s.add(x: x, y: 0, at: t)) }
        // A real shake: four quick swings.
        s.reset(); t = 0
        var fired = 0
        for x in [0.0, 50, 0, 50, 0, 50, 0] { t += 0.09; if s.add(x: x, y: 0, at: t) { fired += 1 } }
        XCTAssertEqual(fired, 1, "once per shake, then a cooldown")
        // After the cooldown another shake counts again (switching back).
        t += 1
        for x in [0.0, 50, 0, 50, 0] { t += 0.09; if s.add(x: x, y: 0, at: t) { fired += 1 } }
        XCTAssertEqual(fired, 2)
    }

    func testOcclusionLowersTheCoveredPanesRate() {
        XCTAssertEqual(WorkspaceOcclusion.coveredFraction(of: .unit, by: [WorkspaceRect(x: 0, y: 0, width: 0.5, height: 1)]), 0.5, accuracy: 0.01)
        XCTAssertEqual(WorkspaceOcclusion.coveredFraction(of: .unit, by: []), 0)
        XCTAssertEqual(WorkspaceCaptureBudget.fps(isActive: false, tileCount: 3, streamFPS: 60, available: true, covered: 0.95), 2)
        XCTAssertEqual(WorkspaceCaptureBudget.fps(isActive: true, tileCount: 3, streamFPS: 60, available: true, covered: 0.95), 60,
                       "the pane being typed into keeps its rate")
        XCTAssertEqual(WorkspaceCaptureBudget.fps(isActive: false, tileCount: 8, streamFPS: 60, available: true, isFloat: true), 15)
        XCTAssertEqual(WorkspaceCaptureBudget.fps(isActive: false, tileCount: 3, streamFPS: 60, available: true), 30, "unchanged without floats")
    }

    // MARK: Mac validation and input targeting

    private func entry(_ id: UInt32, gen: UInt64 = 1, pid: Int32 = 100) -> WindowCatalogEntry {
        WindowCatalogEntry(windowID: id, generation: gen, pid: pid, bundleID: "app.\(id)", appName: "App", title: "w\(id)",
                           frame: CGRect(x: 0, y: 0, width: 800, height: 600), availability: .visible, isActive: false)
    }

    private var floatRequest: [[String: Any]] {
        [["id": "a", "x": 0.0, "y": 0.0, "w": 0.5, "h": 1.0, "window": 10, "gen": 1],
         ["id": "b", "x": 0.5, "y": 0.0, "w": 0.5, "h": 1.0, "window": 11, "gen": 1],
         ["id": "f2", "x": 0.3, "y": 0.2, "w": 0.4, "h": 0.4, "window": 13, "gen": 1, "layer": "float", "z": 1],
         ["id": "f1", "x": 0.2, "y": 0.1, "w": 0.4, "h": 0.4, "window": 12, "gen": 1, "layer": "float", "z": 0]]
    }

    func testTheMacAcceptsOverlappingFloatsOnlyFromAFloatReceiverAndOrdersThemOnTop() {
        let catalog = Dictionary(uniqueKeysWithValues: [UInt32(10), 11, 12, 13].map { ($0, entry($0)) })
        var next: UInt64 = 1
        let ok = WorkspaceRequestValidator.validate(tiles: floatRequest, catalog: catalog, hostID: "mac", canvasPixels: CGSize(width: 2000, height: 1400),
                                                    previous: [:], nextGeneration: &next, allowFloats: true)
        XCTAssertTrue(ok.rejected.isEmpty, "\(ok.rejected)")
        XCTAssertEqual(ok.assignments.map(\.tileID), ["a", "b", "f1", "f2"], "panes, then floats back to front: the paint order")
        XCTAssertEqual(ok.assignments.map(\.isFloat), [false, false, true, true])

        // A ws 1 receiver (Android 2.0) can't send floats: `layer` is ignored, overlap refused as before.
        next = 1
        let old = WorkspaceRequestValidator.validate(tiles: floatRequest, catalog: catalog, hostID: "mac", canvasPixels: CGSize(width: 2000, height: 1400),
                                                     previous: [:], nextGeneration: &next)
        XCTAssertEqual(old.assignments.map(\.tileID), ["a", "b"])
        XCTAssertEqual(old.rejected, ["f2": "overlap", "f1": "overlap"])
        XCTAssertFalse(old.assignments.contains(where: \.isFloat))

        // Tiled panes still may not overlap, floats or not.
        var bad = floatRequest
        bad[1]["x"] = 0.4
        next = 1
        let overlap = WorkspaceRequestValidator.validate(tiles: bad, catalog: catalog, hostID: "mac", canvasPixels: CGSize(width: 2000, height: 1400),
                                                         previous: [:], nextGeneration: &next, allowFloats: true)
        XCTAssertEqual(overlap.rejected["b"], "overlap")

        // Moving, raising or docking a float keeps its capture (same assignment generation).
        let previous = Dictionary(uniqueKeysWithValues: ok.assignments.map { ($0.tileID, $0) })
        var moved = floatRequest
        moved[2]["x"] = 0.1; moved[2]["z"] = 0; moved[3]["z"] = 1
        moved[3]["layer"] = nil; moved[3]["x"] = 0.5; moved[3]["y"] = 0.0; moved[3]["w"] = 0.5; moved[3]["h"] = 0.5   // f1 docked
        moved[1]["h"] = 0.5; moved[1]["y"] = 0.5
        next = 100
        let again = WorkspaceRequestValidator.validate(tiles: moved, catalog: catalog, hostID: "mac", canvasPixels: CGSize(width: 2000, height: 1400),
                                                       previous: previous, nextGeneration: &next, allowFloats: true)
        XCTAssertTrue(again.rejected.isEmpty, "\(again.rejected)")
        for a in again.assignments { XCTAssertEqual(Optional(a.assignmentGeneration), previous[a.tileID]?.assignmentGeneration, a.tileID) }
        XCTAssertEqual(next, 100, "nothing new was started")
    }

    private func floatTargeting() -> WorkspaceInputTargeting {
        let catalog = Dictionary(uniqueKeysWithValues: [UInt32(10), 11, 12, 13].map { ($0, entry($0, pid: Int32($0))) })
        var next: UInt64 = 1
        let r = WorkspaceRequestValidator.validate(tiles: floatRequest, catalog: catalog, hostID: "mac", canvasPixels: CGSize(width: 2000, height: 1400),
                                                   previous: [:], nextGeneration: &next, allowFloats: true)
        var t = WorkspaceInputTargeting()
        t.canvas = CGSize(width: 2000, height: 1400)
        t.windowFrames = [10: CGRect(x: 0, y: 0, width: 800, height: 600), 11: CGRect(x: 1000, y: 0, width: 800, height: 600),
                          12: CGRect(x: 2000, y: 0, width: 800, height: 600), 13: CGRect(x: 3000, y: 0, width: 800, height: 600)]
        _ = t.update(assignments: r.assignments)
        return t
    }

    /// Input reaches only the window drawn on top: never the pane a float covers.
    func testInputGoesToTheTopmostWindowOnly() {
        var t = floatTargeting()
        XCTAssertEqual(t.tile(at: WorkspacePoint(x: 0.5, y: 0.4))?.tileID, "f2", "both floats and pane b are here: the front float")
        XCTAssertEqual(t.tile(at: WorkspacePoint(x: 0.25, y: 0.15))?.tileID, "f1", "only the back float here")
        XCTAssertEqual(t.tile(at: WorkspacePoint(x: 0.1, y: 0.9))?.tileID, "a", "no float here")
        let down = try! XCTUnwrap(t.resolve(.down, at: WorkspacePoint(x: 0.5, y: 0.4)))
        XCTAssertEqual(down.windowID, 13)
        XCTAssertTrue(down.activates)
        // A drag bound to the float stays in that window even over the pane beside it.
        let drag = try! XCTUnwrap(t.resolve(.move, at: WorkspacePoint(x: 0.9, y: 0.9)))
        XCTAssertEqual(drag.windowID, 13)
        _ = t.resolve(.up, at: WorkspacePoint(x: 0.9, y: 0.9))
        // Hover over the covered part of pane b reaches nothing (the float is in front there).
        XCTAssertEqual(t.resolve(.move, at: WorkspacePoint(x: 0.6, y: 0.4))?.windowID, 13, "hover over the active float")
        XCTAssertNil(t.resolve(.move, at: WorkspacePoint(x: 0.8, y: 0.8)), "pane b isn't active: hover stays local")
        XCTAssertEqual(t.globalPoint(at: WorkspacePoint(x: 0.5, y: 0.4)).map { $0.x >= 3000 }, true, "locate maps through the float")

        // The Mac's cursor over pane b's window, where the float covers it, isn't drawn on the float.
        let coveredInB = CGPoint(x: 1000 + 400 * 0.4 / 0.5 * 1, y: 300)   // window 11, canvas x ~0.6
        if let c = t.cursorPlacement(forGlobal: coveredInB) {
            XCTAssertEqual(t.tile(at: WorkspacePoint(x: c.x, y: c.y))?.windowID, 11, "only drawn where pane b shows")
        }
        let onFloat = CGPoint(x: 3400, y: 300)
        let c = try! XCTUnwrap(t.cursorPlacement(forGlobal: onFloat))
        XCTAssertEqual(t.tile(at: WorkspacePoint(x: c.x, y: c.y))?.tileID, "f2")
    }

    // MARK: Receiver wire and safety

    @MainActor
    private func connectedModel(features: Set<String>, sent: @escaping ([String: Any]) -> Void) -> WorkspaceModel {
        let defaults = UserDefaults(suiteName: "WorkspaceFloatTests-\(UUID().uuidString)")!
        let m = WorkspaceModel(defaults: defaults)
        m.send = { sent($0); return true }
        m.inputAllowed = { true }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features(features))
        m.apply(.mode(window: true))
        m.apply(WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": [10, 11, 12].map { ["id": $0, "gen": 5, "bundle": "app.\($0)", "app": "App\($0)", "title": "t", "w": 1600, "h": 1000, "state": "visible"] },
            "apps": [],
        ])!)
        m.updateSpace(ipad, hinge: nil)
        return m
    }

    @MainActor
    private func settle() {
        let exp = expectation(description: "debounced send")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    /// Floats go out after the panes with `layer`/`z` only to a Mac that offers them; a layout
    /// without floats is sent exactly as before; nothing a float does is ever a window action
    /// or pointer input.
    @MainActor
    func testFloatsAreSentOnlyToAFloatMacAndNeverMoveTheMacWindow() {
        var sent: [[String: Any]] = []
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]) { sent.append($0) }
        XCTAssertTrue(m.canFloat)
        let w = m.catalog!.windows
        m.choose(w[0], asNewTile: false)
        m.choose(w[1], asNewTile: true)
        settle()
        let plain = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }?["tiles"] as? [[String: Any]] ?? []
        XCTAssertEqual(plain.count, 2)
        XCTAssertTrue(plain.allSatisfy { $0["layer"] == nil && $0["z"] == nil }, "no new keys without floats")

        sent.removeAll()
        m.openFloating(w[2])
        XCTAssertEqual(m.layout.floatIDs.count, 1)
        let fid = m.layout.floatIDs[0]
        m.beginFloatGesture(fid)
        m.updateFloatFrame(fid, WorkspaceRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3))
        m.endFloatGesture(fid)
        m.tuckFloat(fid, edge: .right, offset: 0.5)
        m.untuckFloat(fid)
        m.enterLocalFullscreen(fid)
        m.exitLocalFullscreen()
        settle()
        let request = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }?["tiles"] as? [[String: Any]] ?? []
        XCTAssertEqual(request.count, 3)
        XCTAssertEqual(request.last?["layer"] as? String, "float")
        XCTAssertEqual(request.last?["z"] as? Int, 0)
        XCTAssertEqual(request.last?["window"] as? Int, 12)
        XCTAssertEqual(request.last?["x"] as? Double ?? -1, 0.1, accuracy: 1e-9, "the frame the finger left")
        let allowed: Set<String> = [WireMessage.workspaceRequest, WireMessage.workspaceFocus, WireMessage.workspaceBackdropRequest,
                                    WireMessage.windowCatalogRequest, WireMessage.windowThumbnailRequest]
        XCTAssertTrue(sent.allSatisfy { allowed.contains($0["type"] as? String ?? "") },
                      "floating, moving, tucking and fullscreen never act on the Mac window: \(sent.map { $0["type"] ?? "" })")
        m.addFloatToLayout(fid)
        m.floatPane(fid)
        m.dockFloat(fid, to: .tab(tile: m.layout.orderedTileIDs[0], preview: .unit))
        m.undo(); m.undo()
        XCTAssertTrue(sent.allSatisfy { allowed.contains($0["type"] as? String ?? "") })

        // A Mac without `windowFloat`: floats wait tucked and are never sent.
        var oldSent: [[String: Any]] = []
        let old = connectedModel(features: [WindowWorkspaceWire.welcomeFeature]) { oldSent.append($0) }
        old.choose(old.catalog!.windows[0], asNewTile: false)
        XCTAssertFalse(old.canFloat)
        old.openFloating(old.catalog!.windows[1])
        XCTAssertTrue(old.layout.floats.isEmpty, "can't float without the Mac's support")
        settle()
        let oldTiles = oldSent.last { $0["type"] as? String == WireMessage.workspaceRequest }?["tiles"] as? [[String: Any]] ?? []
        XCTAssertTrue(oldTiles.allSatisfy { $0["layer"] == nil })
    }

    /// A touch on a float's content selects and raises it (sent at once), never the pane below;
    /// tucking or removing the focused float hands typing back; a float move is one undo step.
    @MainActor
    func testTouchRaisesTheFloatAndHidingItHandsFocusBack() {
        var sent: [[String: Any]] = []
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]) { sent.append($0) }
        let w = m.catalog!.windows
        m.choose(w[0], asNewTile: false)
        let pane = m.layout.orderedTileIDs[0]
        m.focus(pane)
        m.openFloating(w[1], at: WorkspacePoint(x: 0.5, y: 0.5))
        m.openFloating(w[2], at: WorkspacePoint(x: 0.55, y: 0.55))
        let (back, front) = (m.layout.floatIDs[0], m.layout.floatIDs[1])
        sent.removeAll()
        let bf = m.layout.float(back)!.frame, ff = m.layout.float(front)!.frame
        let onlyBack = WorkspacePoint(x: bf.x + 0.01, y: bf.y + 0.01)
        XCTAssertFalse(ff.contains(onlyBack), "the front float is offset from the back one")
        XCTAssertEqual(m.frames.hitTest(onlyBack), back, "only the back float reaches there")
        _ = m.selectTile(at: onlyBack)
        XCTAssertEqual(m.layout.floatIDs.last, back, "touched: in front")
        XCTAssertTrue(sent.contains { $0["type"] as? String == WireMessage.workspaceRequest }, "the new order goes at once")
        XCTAssertEqual(sent.last { $0["type"] as? String == WireMessage.workspaceFocus }?["tile"] as? String, back)

        // Tucking the focused float focuses the other float; removing that one, the pane.
        m.apply(.state(WorkspaceStateMessage(host: "mac-a", tiles: [], active: back, hostFocus: .deliver, rejected: [:])))
        m.tuckFloat(back, edge: .left, offset: 0.5)
        XCTAssertEqual(sent.last { $0["type"] as? String == WireMessage.workspaceFocus }?["tile"] as? String, front)
        m.apply(.state(WorkspaceStateMessage(host: "mac-a", tiles: [], active: front, hostFocus: .deliver, rejected: [:])))
        m.removeFloat(front)
        XCTAssertEqual(sent.last { $0["type"] as? String == WireMessage.workspaceFocus }?["tile"] as? String, pane)
        XCTAssertNotNil(m.layout.float(back), "the tucked float is kept")
        m.undo()
        XCTAssertNotNil(m.layout.float(front), "Undo brings a removed float back")

        // One gesture, many steps: one undo step.
        let before = m.layout
        m.beginFloatGesture(front)
        for i in 1...10 { m.updateFloatFrame(front, WorkspaceRect(x: 0.05 * Double(i), y: 0.2, width: 0.3, height: 0.3)) }
        m.endFloatGesture(front)
        XCTAssertNotEqual(m.layout.float(front)?.frame, before.float(front)?.frame)
        m.undo()
        XCTAssertEqual(m.layout.float(front)?.frame, before.float(front)?.frame)
    }

    /// Dragging: Pane placement keeps the existing drops; a shake (or the control) switches to
    /// Floating, where a drop floats the window at the finger; Cancel changes nothing.
    @MainActor
    func testShakeSwitchesADragBetweenPaneAndFloatingPlacement() {
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]) { _ in }
        let w = m.catalog!.windows
        m.choose(w[0], asNewTile: false)
        m.choose(w[1], asNewTile: true)
        m.pictureGlobal = CGRect(x: 0, y: 0, width: ipad.width, height: ipad.height)
        m.cancelZoneGlobal = CGRect(x: 500, y: 760, width: 120, height: 44)
        let before = m.layout

        m.beginDrag(.window(w[2]), at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(m.drag?.placement, .pane, "Pane placement by default")
        var t = 0.0
        var switched = false
        for x in [300.0, 360, 300, 360, 300, 360] { t += 0.08; switched = m.moveDrag(to: CGPoint(x: x, y: 300), at: t) || switched }
        XCTAssertTrue(switched)
        XCTAssertEqual(m.drag?.placement, .float)
        XCTAssertNil(m.dropTarget(forGlobal: CGPoint(x: 360, y: 300)), "no pane targets while floating")
        XCTAssertNotNil(m.floatDropPreview(forGlobal: CGPoint(x: 360, y: 300)))
        // Cancel: nothing changes.
        m.moveDrag(to: CGPoint(x: 560, y: 780), at: t + 2)
        XCTAssertFalse(m.endDrag())
        XCTAssertEqual(m.layout, before)

        // The control switches too; a drop floats the window where the finger is.
        m.beginDrag(.window(w[2]), at: CGPoint(x: 300, y: 300))
        XCTAssertTrue(m.toggleDragPlacement())
        m.moveDrag(to: CGPoint(x: 590, y: 410), at: 100)
        XCTAssertTrue(m.endDrag())
        XCTAssertEqual(m.layout.floatIDs.count, 1)
        let f = m.layout.float(m.layout.floatIDs[0])!
        XCTAssertEqual(f.frame.midX, 0.5, accuracy: 0.02)
        XCTAssertEqual(before.orderedTileIDs, m.layout.orderedTileIDs, "the panes are untouched")

        // A float shaken into Pane placement docks as a tab where it's dropped, never replacing.
        let fid = m.layout.floatIDs[0]
        m.beginDrag(.float(fid), at: CGPoint(x: 200, y: 400))
        XCTAssertEqual(m.drag?.placement, .pane)
        XCTAssertFalse(m.toggleDragPlacement(), "a float being docked has no Floating placement here (its title drag moves it)")
        m.moveDrag(to: CGPoint(x: 200, y: 500), at: 200)
        guard case .tab? = m.dropTarget(forGlobal: CGPoint(x: 200, y: 500)) else { return XCTFail("the middle of a pane is a tab, not a replace") }
        XCTAssertTrue(m.endDrag())
        XCTAssertTrue(m.layout.floats.isEmpty)
        XCTAssertEqual(Set(m.layout.tiles.values.flatMap(\.windows).map(\.windowID)), [10, 11, 12], "every window still here")
    }
}
