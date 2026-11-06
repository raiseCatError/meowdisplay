import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
        let top = tucked.tuckingFloat("b", edge: .top, offset: 0.4)
        XCTAssertEqual(top.float("b")?.tuck, WorkspaceFloatTuck(edge: .top, offset: 0.4), "any edge: the top and bottom too")
        XCTAssertEqual(top.float("b")?.frame, box, "its frame is kept")
        XCTAssertEqual(tucked.tuckingFloat("b", edge: .bottom, offset: 7).float("b")?.tuck?.offset, 1, "kept on its edge")
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
        json["floats"] = [["tile": "b", "x": -5.0, "y": 9.0, "w": 40.0, "h": 0.5, "tuck": "sideways"],
                          ["tile": "nope", "x": 0.1, "y": 0.1, "w": 0.2, "h": 0.2],
                          ["tile": "a", "x": 0.1, "y": 0.1, "w": 0.2, "h": 0.2]]
        let hostile = try XCTUnwrap(WorkspaceLayoutRecord.decode(JSONSerialization.data(withJSONObject: json)))
        XCTAssertEqual(hostile.floatIDs, ["b"], "unknown tiles and tiles already in the tree are refused")
        let f = try XCTUnwrap(hostile.float("b"))
        XCTAssertTrue(f.frame.x >= 0 && f.frame.maxX <= 1 && f.frame.y >= 0 && f.frame.maxY <= 1)
        XCTAssertNil(f.tuck, "an edge it doesn't know: shown where it was, untucked (what a reader from before top and bottom tucks does with them)")

        // Every edge round-trips, the schema stays 4.
        for edge in [WorkspaceEdge.left, .right, .top, .bottom] {
            let t = l.tuckingFloat("b", edge: edge, offset: 0.25)
            let r = WorkspaceLayoutRecord(t)
            XCTAssertEqual(r.schema, 4)
            XCTAssertEqual(r.floats?.first { $0.tile == "b" }?.tuck, edge.rawValue)
            XCTAssertEqual(try XCTUnwrap(WorkspaceLayoutRecord.decode(try XCTUnwrap(r.encoded()))), t, "\(edge)")
        }
    }

    /// Rotation, a compact screen and a Mac without floats: floats are kept usable or tucked,
    /// never dropped; the saved arrangement is untouched. A phone shows every float, like an iPad.
    func testAdaptationKeepsEveryFloat() {
        let l = threePanes().floatingPane("b", frame: WorkspaceRect(x: 0.7, y: 0.6, width: 0.1, height: 0.1))
            .addingFloat(tile("f", 40), frame: box)
        let wide = WorkspaceAdaptation.adapt(l, to: ipad, active: nil)
        let b = try! XCTUnwrap(wide.visible.float("b"))
        XCTAssertGreaterThanOrEqual(b.frame.width * ipad.width, WorkspaceFloatGeometry.minimum(for: ipad).width - 1e-6, "grown to the minimum")
        XCTAssertLessThanOrEqual(b.frame.maxX, 1 + 1e-9)
        XCTAssertEqual(wide.visible.visibleFloatIDs.count, 2)

        let small = WorkspaceAdaptation.adapt(l, to: phone, active: "b")
        XCTAssertEqual(small.visible.visibleFloatIDs, ["b", "f"], "both show on a phone, in their order")
        XCTAssertNil(small.visible.float("f")?.tuck, "a small screen never tucks one")
        XCTAssertEqual(small.visible.floatIDs.count, 2)
        let landscape = WorkspaceAdaptation.adapt(l, to: WorkspaceSize(width: phone.height, height: phone.width), active: nil)
        XCTAssertEqual(landscape.visible.visibleFloatIDs, ["b", "f"])

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

    func testClampingDefaultsAndCornerResize() {
        let c = WorkspaceFloatGeometry.clamped(WorkspaceRect(x: 0.95, y: -0.2, width: 0.01, height: 2), in: ipad)
        XCTAssertGreaterThanOrEqual(c.width * ipad.width, 160 - 1e-6)
        XCTAssertLessThanOrEqual(c.maxX, 1 + 1e-9)
        XCTAssertGreaterThanOrEqual(c.y * ipad.height, WorkspaceFloatGeometry.barHeight - 1e-6, "the title bar stays on screen")
        XCTAssertLessThanOrEqual(c.maxY, 1 + 1e-9)

        let d = WorkspaceFloatGeometry.defaultFrame(aspect: 16.0 / 10, in: ipad)
        XCTAssertEqual(d.width * ipad.width / (d.height * ipad.height), 1.6, accuracy: 0.01, "opens at the window's shape")
        let cascaded = WorkspaceFloatGeometry.defaultFrame(aspect: 1.6, in: ipad, index: 1)
        XCTAssertEqual((cascaded.x - d.x) * ipad.width, WorkspaceFloatGeometry.cascade, accuracy: 0.5)
        // A phone opens a picture-in-picture, not a second screen (IMG_2266: nearly full width).
        let p = WorkspaceFloatGeometry.defaultFrame(aspect: 1.6, in: phone)
        XCTAssertEqual(p.width, 0.62, accuracy: 0.01)
        XCTAssertLessThanOrEqual(p.height * phone.height, phone.height * 0.32 + 1e-6)
        XCTAssertEqual(p.midX, 0.5, accuracy: 0.01, "centred")
        XCTAssertEqual(p.width * phone.width / (p.height * phone.height), 1.6, accuracy: 0.01, "at the window's shape")
        let tall = WorkspaceFloatGeometry.defaultFrame(aspect: 0.5, in: phone)
        XCTAssertLessThanOrEqual(tall.height * phone.height, phone.height * 0.32 + 1e-6, "a tall window opens no taller")
        XCTAssertEqual(tall.width * phone.width / (tall.height * phone.height), 0.5, accuracy: 0.01)
        let landscape = WorkspaceFloatGeometry.defaultFrame(aspect: 1.6, in: WorkspaceSize(width: 844, height: 390))
        XCTAssertLessThanOrEqual(landscape.width, 0.38 + 1e-6)

        let start = WorkspaceRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4 * ipad.width / ipad.height / 1.6)
        let bigger = WorkspaceFloatGeometry.resized(start, corner: .bottomTrailing, translation: (100, 10), aspect: 1.6, in: ipad)
        XCTAssertEqual(bigger.x, start.x)
        XCTAssertEqual(bigger.y, start.y)
        XCTAssertEqual(bigger.width * ipad.width / (bigger.height * ipad.height), 1.6, accuracy: 1e-6, "no bars, no distortion")
        XCTAssertEqual(bigger.width * ipad.width, start.width * ipad.width + 100, accuracy: 1e-6)
        let leading = WorkspaceFloatGeometry.resized(start, corner: .bottomLeading, translation: (-50, 0), aspect: 1.6, in: ipad)
        XCTAssertEqual(leading.maxX, start.maxX, accuracy: 1e-9, "the opposite corner stays put")
        let tiny = WorkspaceFloatGeometry.resized(start, corner: .bottomTrailing, translation: (-2000, -2000), aspect: 1.6, in: ipad)
        XCTAssertGreaterThanOrEqual(tiny.width * ipad.width, 160 - 1e-6)
        let huge = WorkspaceFloatGeometry.resized(start, corner: .bottomTrailing, translation: (5000, 5000), aspect: 1.6, in: ipad)
        XCTAssertLessThanOrEqual(huge.maxX, 1 + 1e-9)
        XCTAssertLessThanOrEqual(huge.maxY, 1 + 1e-9)

        // The grips resize freely (no aspect): width and height follow the finger on their own.
        let wide = WorkspaceFloatGeometry.resized(start, corner: .bottomTrailing, translation: (200, -40), aspect: nil, in: ipad)
        XCTAssertEqual(wide.width * ipad.width, start.width * ipad.width + 200, accuracy: 1e-6)
        XCTAssertEqual(wide.height * ipad.height, start.height * ipad.height - 40, accuracy: 1e-6)
        XCTAssertEqual(wide.y, start.y)
        let thin = WorkspaceFloatGeometry.resized(start, corner: .bottomLeading, translation: (300, 0), aspect: nil, in: ipad)
        XCTAssertEqual(thin.maxX, start.maxX, accuracy: 1e-9, "the opposite corner stays put")
        XCTAssertEqual(thin.height, start.height, accuracy: 1e-9, "only the width changed")
        let small = WorkspaceFloatGeometry.resized(start, corner: .bottomTrailing, translation: (-5000, -5000), aspect: nil, in: phone)
        XCTAssertEqual(small.width * phone.width, 120, accuracy: 1e-6, "down to the phone's minimum")
        XCTAssertEqual(small.height * phone.height, 80, accuracy: 1e-6)

        // Match Window: back to the window's shape, same area and centre, still on screen.
        let free = WorkspaceRect(x: 0.2, y: 0.3, width: 0.5, height: 0.2)
        let matched = WorkspaceFloatGeometry.matched(free, aspect: 1.0, in: ipad)
        XCTAssertEqual(matched.width * ipad.width, matched.height * ipad.height, accuracy: 1e-6)
        XCTAssertEqual(matched.width * ipad.width * matched.height * ipad.height,
                       free.width * ipad.width * free.height * ipad.height, accuracy: 1)
        XCTAssertEqual(matched.midX, free.midX, accuracy: 1e-9)
        XCTAssertEqual(matched.midY, free.midY, accuracy: 1e-9)
        let edge = WorkspaceFloatGeometry.matched(WorkspaceRect(x: 0, y: 0.04, width: 1, height: 0.9), aspect: 3, in: ipad)
        XCTAssertLessThanOrEqual(edge.maxX, 1 + 1e-9)
        XCTAssertEqual(edge.width * ipad.width / (edge.height * ipad.height), 3, accuracy: 0.01, "too big: shrunk, same shape")
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
        // A move across the middle that isn't a throw never hides the float, however far it goes.
        let left = WorkspaceRect(x: 0.1, y: 0.3, width: 0.3, height: 0.3)
        if case .tuck = WorkspaceFloatMotion.decide(release: left, velocity: (1000, 0), in: ipad) { XCTFail("a move across the middle must not tuck") }
        // A strong throw from the far side tucks at the edge it reaches (WorkspaceFloatTuckTests has the reach).
        XCTAssertEqual(WorkspaceFloatMotion.decide(release: left, velocity: (3500, 0), in: ipad), .tuck(edge: .right, offset: left.midY))
        // An intentional fling at the near edge tucks it, at the height it was heading for.
        let right = WorkspaceRect(x: 0.6, y: 0.3, width: 0.3, height: 0.3)
        XCTAssertEqual(WorkspaceFloatMotion.decide(release: right, velocity: (2600, 0), in: ipad),
                       .tuck(edge: .right, offset: right.midY))
        let leftSide = WorkspaceRect(x: 0.05, y: 0.4, width: 0.3, height: 0.3)
        guard case .tuck(.left, _) = WorkspaceFloatMotion.decide(release: leftSide, velocity: (-2600, -300), in: ipad) else { return XCTFail() }
        // Mostly downward: into the bottom edge, which its path crosses before the right one.
        guard case .tuck(.bottom, let along) = WorkspaceFloatMotion.decide(release: right, velocity: (1300, 2600), in: ipad) else { return XCTFail() }
        XCTAssertGreaterThan(along, right.midX, "where its path crosses the bottom")
        // Unless the bottom edge has no room for a handle: then the right edge it reaches next.
        guard case .tuck(.right, _) = WorkspaceFloatMotion.decide(release: right, velocity: (1300, 2600), in: ipad,
                                                                  edges: [.left, .right, .top]) else { return XCTFail() }
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

    /// While the receiver moves or resizes a float it draws it itself (`lift`): the Mac leaves it
    /// out of the picture and of input and lets the panes under it count as seen, but keeps its
    /// capture running, so letting go needs no restart.
    func testALiftedFloatIsLeftOutOfThePictureAndInputButKeepsItsCapture() {
        let catalog = Dictionary(uniqueKeysWithValues: [UInt32(10), 11, 12, 13].map { ($0, entry($0, pid: Int32($0))) })
        let canvas = CGSize(width: 2000, height: 1400)
        var next: UInt64 = 1
        let ok = WorkspaceRequestValidator.validate(tiles: floatRequest, catalog: catalog, hostID: "mac", canvasPixels: canvas,
                                                    previous: [:], nextGeneration: &next, allowFloats: true)
        XCTAssertFalse(ok.assignments.contains(where: \.isLifted))
        let previous = Dictionary(uniqueKeysWithValues: ok.assignments.map { ($0.tileID, $0) })
        var lifted = floatRequest
        lifted[2]["lift"] = true   // f2, the front float
        lifted[0]["lift"] = true   // a tiled pane: means nothing
        next = 100
        let r = WorkspaceRequestValidator.validate(tiles: lifted, catalog: catalog, hostID: "mac", canvasPixels: canvas,
                                                   previous: previous, nextGeneration: &next, allowFloats: true)
        XCTAssertTrue(r.rejected.isEmpty, "\(r.rejected)")
        let byID = Dictionary(uniqueKeysWithValues: r.assignments.map { ($0.tileID, $0) })
        XCTAssertEqual(byID["f2"]?.isLifted, true)
        XCTAssertEqual(byID["f2"]?.isOnCanvas, false, "not drawn")
        XCTAssertEqual(byID["f1"]?.isOnCanvas, true)
        XCTAssertEqual(byID["a"]?.isLifted, false, "only a float can be lifted")
        XCTAssertEqual(byID["f2"]?.assignmentGeneration, previous["f2"]?.assignmentGeneration, "its capture keeps running")
        XCTAssertEqual(next, 100, "nothing new was started")

        // A receiver that can't send floats can't lift anything either.
        next = 1
        let old = WorkspaceRequestValidator.validate(tiles: lifted, catalog: catalog, hostID: "mac", canvasPixels: canvas,
                                                     previous: [:], nextGeneration: &next)
        XCTAssertFalse(old.assignments.contains(where: \.isLifted))

        // Input: where the lifted float was, the float behind it (or the pane) takes the touch.
        var t = WorkspaceInputTargeting()
        t.canvas = canvas
        t.windowFrames = [10: CGRect(x: 0, y: 0, width: 800, height: 600), 11: CGRect(x: 1000, y: 0, width: 800, height: 600),
                          12: CGRect(x: 2000, y: 0, width: 800, height: 600), 13: CGRect(x: 3000, y: 0, width: 800, height: 600)]
        _ = t.update(assignments: r.assignments)
        XCTAssertEqual(t.tile(at: WorkspacePoint(x: 0.5, y: 0.4))?.tileID, "f1")
        XCTAssertEqual(t.tile(at: WorkspacePoint(x: 0.65, y: 0.5))?.tileID, "b")
        XCTAssertNotEqual(t.resolve(.down, at: WorkspacePoint(x: 0.65, y: 0.5))?.windowID, 13, "never the lifted float's window")

        // Capture budget: only the floats drawn hide pane b.
        let all = WorkspaceCaptureBudget.coverage(ok.assignments)["b"] ?? 0
        let some = WorkspaceCaptureBudget.coverage(r.assignments)["b"] ?? 0
        XCTAssertEqual(some, 0.08, accuracy: 0.01, "f1 alone: 0.1 x 0.4 of the 0.5 x 1 pane")
        XCTAssertLessThan(some, all)
    }

    // MARK: Receiver wire and safety

    @MainActor
    private func connectedModel(features: Set<String>, drawsFloats: Bool = true, window: Bool = true,
                                displays: [[String: Any]] = [], windows: [Int] = [10, 11, 12],
                                defaults suite: UserDefaults? = nil,
                                sent: @escaping ([String: Any]) -> Void) -> WorkspaceModel {
        let defaults = suite ?? UserDefaults(suiteName: "WorkspaceFloatTests-\(UUID().uuidString)")!
        let m = WorkspaceModel(defaults: defaults)
        m.floatsDrawnHere = drawsFloats   // the iPhone/iPad receiver (this test runs on the Mac)
        m.send = { sent($0); return true }
        m.inputAllowed = { true }
        m.apply(.connected(peerID: "mac-a"))
        m.apply(.features(features))
        m.apply(.mode(window: window))
        m.apply(WorkspaceEvent.parse(type: WireMessage.windowCatalog, [
            "type": WireMessage.windowCatalog, "host": "mac-a",
            "windows": windows.map { ["id": $0, "gen": 5, "bundle": "app.\($0)", "app": "App\($0)", "title": "t", "w": 1600, "h": 1000, "state": "visible"] },
            "apps": [], "displays": displays,
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

    /// Dragging: Pane placement keeps the existing drops; about two seconds of circling (or the
    /// control) switches to Floating, where a drop floats the window at the finger; Cancel
    /// changes nothing. The ring's progress shows only while it can switch.
    @MainActor
    func testCirclingSwitchesADragBetweenPaneAndFloatingPlacement() {
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]) { _ in }
        let w = m.catalog!.windows
        m.choose(w[0], asNewTile: false)
        m.choose(w[1], asNewTile: true)
        m.pictureGlobal = CGRect(x: 0, y: 0, width: ipad.width, height: ipad.height)
        m.cancelZoneGlobal = CGRect(x: 500, y: 760, width: 120, height: 44)
        let before = m.layout

        m.beginDrag(.window(w[2]), at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(m.drag?.placement, .pane, "Pane placement by default")
        // A shake no longer switches anything.
        var t = 0.0
        var switched = false
        for x in [300.0, 360, 300, 360, 300, 360, 300, 360] { t += 0.08; switched = m.moveDrag(to: CGPoint(x: x, y: 300), at: t) || switched }
        XCTAssertFalse(switched, "a shake isn't a circle")
        XCTAssertEqual(m.drag?.placement, .pane)
        // Circling: the ring fills, then it switches once.
        t += 1
        var progressSeen = 0.0
        for i in 0...150 {
            let a = Double(i) / 60 * 2 * .pi
            t += 1.0 / 60
            switched = m.moveDrag(to: CGPoint(x: 300 + 50 * cos(a), y: 300 + 50 * sin(a)), at: t) || switched
            if !switched { progressSeen = max(progressSeen, m.placementSwitchProgress) }
        }
        XCTAssertTrue(switched)
        XCTAssertGreaterThan(progressSeen, 0.8, "the ring filled before it switched")
        XCTAssertEqual(m.placementSwitchProgress, 0, "no ring right after the switch")
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

        // A float circled into Pane placement docks as a tab where it's dropped, never replacing.
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

    /// Without circling: the Float zone beside Cancel floats the dragged window. Default Window
    /// Placement applies to windows not in the layout yet; a window already floating comes back
    /// instead of opening twice. The circling tip shows once, ever.
    @MainActor
    func testFloatZoneDefaultPlacementAndTheOneTimeTip() {
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]) { _ in }
        let w = m.catalog!.windows
        m.choose(w[0], asNewTile: false)
        m.pictureGlobal = CGRect(x: 0, y: 0, width: ipad.width, height: ipad.height)
        m.cancelZoneGlobal = CGRect(x: 400, y: 760, width: 120, height: 44)
        m.floatZoneGlobal = CGRect(x: 540, y: 760, width: 120, height: 44)
        let before = m.layout.orderedTileIDs

        XCTAssertFalse(m.placementTipVisible)
        m.beginDrag(.window(w[1]), at: CGPoint(x: 300, y: 300))
        XCTAssertTrue(m.placementTipVisible, "the first drag that can float shows the tip")
        XCTAssertTrue(m.canDropToFloat)
        m.moveDrag(to: CGPoint(x: 600, y: 780), at: 1)
        XCTAssertTrue(m.overFloatZone(CGPoint(x: 600, y: 780)))
        XCTAssertNil(m.dropTarget(forGlobal: CGPoint(x: 600, y: 780)), "no pane drop under the Float zone")
        XCTAssertTrue(m.endDrag())
        XCTAssertEqual(m.layout.floatIDs.count, 1)
        XCTAssertEqual(m.layout.orderedTileIDs, before)
        m.dismissPlacementTip()
        m.beginDrag(.window(w[2]), at: CGPoint(x: 300, y: 300))
        XCTAssertFalse(m.placementTipVisible, "never repeated")
        m.cancelDrag()

        // Stage Peek's tap: a floating window comes back (untucked), never a second copy.
        let fid = m.layout.floatIDs[0]
        m.tuckFloat(fid, edge: .left, offset: 0.5)
        m.switchTo(w[1])
        XCTAssertNil(m.layout.float(fid)?.tuck)
        XCTAssertEqual(m.layout.tiles.count, 2)

        // Default Window Placement: Floating opens a new window as a float; Pane keeps today's behaviour.
        m.defaultPlacement = .float
        m.switchTo(w[2])
        XCTAssertEqual(m.layout.floatIDs.count, 2)
        XCTAssertEqual(m.layout.orderedTileIDs, before)
        m.defaultPlacement = .pane
        XCTAssertEqual(m.layout.floatIDs.count, 2, "changing the setting moves nothing already open")

        // A receiver without float chrome (the Mac Receiver) never floats, even when the Mac offers it.
        let mac = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature], drawsFloats: false) { _ in }
        XCTAssertFalse(mac.canFloat)
        mac.choose(mac.catalog!.windows[0], asNewTile: false)
        mac.openFloating(mac.catalog!.windows[1])
        XCTAssertTrue(mac.layout.floats.isEmpty)
    }

    // MARK: Over the whole-screen desktop

    private static var twoDisplays: [[String: Any]] {
        [["id": 1, "name": "Built-in Retina Display", "w": 1512, "h": 982, "main": true, "virtual": false],
         ["id": 2, "name": "LG UltraFine", "w": 2560, "h": 1440, "main": false, "virtual": false]]
    }

    private static func mirrorEntry(_ name: String, _ w: Int, _ h: Int, main: Bool) -> MirrorDisplayEntry {
        MirrorDisplayEntry(uuid: "uuid-\(name)-\(main)", name: name, isMain: main, logicalWidth: w, logicalHeight: h,
                           pixelWidth: w * 2, pixelHeight: h * 2, likelyVirtual: false)
    }

    private static let safeTypes: Set<String> = [WireMessage.workspaceRequest, WireMessage.workspaceFocus, WireMessage.workspaceBackdropRequest,
                                                 WireMessage.windowCatalogRequest, WireMessage.windowThumbnailRequest]

    /// From Mirror a float opens over the same desktop without asking: Window mode starts with the
    /// mirrored display as the pane underneath. Nothing it sends acts on a Mac window.
    @MainActor
    func testAFloatOpensOverTheMirroredDesktopWithoutAPrompt() {
        var sent: [[String: Any]] = []
        var windowModeRequests = 0
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature],
                               window: false, displays: Self.twoDisplays) { sent.append($0) }
        m.requestWindowMode = { windowModeRequests += 1 }
        m.mirroring = { true }
        m.mirrorChoice = { Self.mirrorEntry("LG UltraFine", 2560, 1440, main: false) }
        m.desktopPictureGlobal = CGRect(x: 0, y: 0, width: ipad.width, height: ipad.height)
        XCTAssertTrue(m.canOpenFloats)
        let w = m.catalog!.windows

        m.openFloating(w[0])
        XCTAssertEqual(windowModeRequests, 1, "Window mode starts at once; nothing asks first")
        XCTAssertEqual(m.layout.paneCount, 1)
        let pane = m.layout.orderedTileIDs[0]
        XCTAssertEqual(m.layout.tiles[pane]?.source?.windowID, WorkspaceSource.displayKey(2), "the desktop being mirrored, not the main display")
        XCTAssertEqual(m.layout.floatIDs.count, 1)
        XCTAssertEqual(m.layout.tiles[m.layout.floatIDs[0]]?.source?.windowID, 10)
        XCTAssertTrue(sent.allSatisfy { Self.safeTypes.contains($0["type"] as? String ?? "") },
                      "never a window action: \(sent.map { $0["type"] ?? "" })")
        m.undo()
        XCTAssertTrue(m.layout.floats.isEmpty, "one undo step")

        // Default Window Placement: Floating also floats a tapped window over the mirrored desktop.
        let tap = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature],
                                 window: false, displays: Self.twoDisplays) { _ in }
        tap.mirroring = { true }
        tap.defaultPlacement = .float
        tap.switchTo(tap.catalog!.windows[1])
        XCTAssertEqual(tap.layout.floatIDs.count, 1)
        XCTAssertEqual(tap.layout.tiles[tap.layout.orderedTileIDs[0]]?.source?.windowID, WorkspaceSource.displayKey(1),
                       "Automatic: the main display")
    }

    /// From Extend nothing floats, by menu, drag, circling or tap: leaving Extend removes this
    /// device's extended display, and macOS would move the windows on it.
    @MainActor
    func testNothingFloatsFromExtend() {
        var sent: [[String: Any]] = []
        var windowModeRequests = 0
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature],
                               window: false, displays: Self.twoDisplays) { sent.append($0) }
        m.requestWindowMode = { windowModeRequests += 1 }
        m.mirroring = { false }   // Extend (or a Mac that hasn't confirmed Mirror)
        m.desktopPictureGlobal = CGRect(x: 0, y: 0, width: ipad.width, height: ipad.height)
        let w = m.catalog!.windows
        XCTAssertTrue(m.canFloat, "the Mac offers floats")
        XCTAssertFalse(m.canOpenFloats)

        m.openFloating(w[0])
        XCTAssertTrue(m.layout.floats.isEmpty)
        XCTAssertEqual(windowModeRequests, 0, "Extend is left alone")
        XCTAssertTrue(sent.isEmpty)

        m.defaultPlacement = .float
        XCTAssertFalse(m.canPlace(.window(w[1]), .float))
        m.beginDrag(.window(w[1]), at: CGPoint(x: 300, y: 300))
        XCTAssertEqual(m.drag?.placement, .pane, "Floating placement isn't offered")
        XCTAssertFalse(m.toggleDragPlacement(), "circling can't switch to it")
        XCTAssertFalse(m.placementTipVisible)
        m.cancelDrag()
        m.switchTo(w[1])
        XCTAssertTrue(m.layout.floats.isEmpty, "a tap never floats either")

        // Once Window view is on, floats work as usual.
        m.apply(.mode(window: true))
        XCTAssertTrue(m.canOpenFloats)
    }

    /// A manual Mirror choice maps to the listed display by name and size; Automatic and an
    /// unmatched choice fall back to the main display.
    func testTheMirroredDisplayIsFoundByNameAndSize() {
        let list = [
            CatalogDisplayItem(id: 1, name: "Built-in Retina Display", width: 1512, height: 982, isMain: true, isVirtual: false),
            CatalogDisplayItem(id: 2, name: "Studio Display", width: 2560, height: 1440, isMain: false, isVirtual: false),
            CatalogDisplayItem(id: 3, name: "Studio Display", width: 2560, height: 1440, isMain: false, isVirtual: false),
            CatalogDisplayItem(id: 4, name: "LG UltraFine", width: 2560, height: 1440, isMain: false, isVirtual: false),
        ]
        XCTAssertNil(WorkspaceModel.mirroredDisplay(in: list, choice: nil), "Automatic")
        XCTAssertEqual(WorkspaceModel.mirroredDisplay(in: list, choice: Self.mirrorEntry("LG UltraFine", 2560, 1440, main: false))?.id, 4)
        XCTAssertNil(WorkspaceModel.mirroredDisplay(in: list, choice: Self.mirrorEntry("LG UltraFine", 1920, 1080, main: false)),
                     "a different size is a different display")
        XCTAssertNil(WorkspaceModel.mirroredDisplay(in: list, choice: Self.mirrorEntry("Studio Display", 2560, 1440, main: false)),
                     "two identical displays: no guess")
        let mainStudio = list.map { $0.id == 2 ? CatalogDisplayItem(id: 2, name: $0.name, width: $0.width, height: $0.height, isMain: true, isVirtual: false) : $0 }
        XCTAssertEqual(WorkspaceModel.mirroredDisplay(in: mainStudio, choice: Self.mirrorEntry("Studio Display", 2560, 1440, main: true))?.id, 2,
                       "the main flag tells identical displays apart")
    }

    // MARK: The Mac never undoes Minimize on Mac

    /// The Mac brings a minimized window back only when it was chosen for a tile while minimized,
    /// once; never after Minimize on Mac, and never when a tucked float shows again.
    func testTheMacRestoresAWindowOnlyWhenItWasChosenWhileMinimized() {
        var ledger = WorkspaceRestoreLedger()
        XCTAssertTrue(ledger.observe(tile: "w1", window: 10, generation: 5, offscreen: true, delivering: false), "chosen while minimized")
        XCTAssertFalse(ledger.observe(tile: "w1", window: 10, generation: 5, offscreen: true, delivering: false), "only once")

        XCTAssertFalse(ledger.observe(tile: "w2", window: 11, generation: 5, offscreen: false, delivering: true))
        XCTAssertFalse(ledger.observe(tile: "w2", window: 11, generation: 5, offscreen: true, delivering: false),
                       "minimized after it was shown (Minimize on Mac): it stays minimized")

        // Tucked, the float's tile isn't sent; its window is still listed, so the entry stays.
        ledger.prune { _ in true }
        XCTAssertFalse(ledger.observe(tile: "w2", window: 11, generation: 5, offscreen: true, delivering: false),
                       "un-tucking never restores a window")

        XCTAssertFalse(ledger.observe(tile: "w4", window: 12, generation: 5, offscreen: true, delivering: true),
                       "a hidden window that still delivers needs nothing")
        XCTAssertFalse(ledger.observe(tile: "w4", window: 12, generation: 5, offscreen: true, delivering: false))

        ledger.prune { $0.window != 11 }
        XCTAssertFalse(ledger.seen.contains { $0.window == 11 }, "a closed window is forgotten")
        XCTAssertTrue(ledger.observe(tile: "w5", window: 11, generation: 6, offscreen: true, delivering: false),
                      "a window chosen anew while minimized is restored")
    }

    // MARK: Arranging floats leaves the Mac's focus alone

    /// Every float arrangement (open, grab and move, tuck and the hand-back, un-tuck, fullscreen on
    /// the device, Add to Layout, Float This Pane, dock) sends focus with `raise: false`, so the Mac
    /// window, its app and Stage Manager stay as they are. An explicit focus still raises.
    @MainActor
    func testArrangingFloatsNeverBringsTheMacWindowForward() {
        var sent: [[String: Any]] = []
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]) { sent.append($0) }
        let w = m.catalog!.windows
        m.choose(w[0], asNewTile: false)
        m.choose(w[1], asNewTile: true)
        settle()
        sent.removeAll()

        m.openFloating(w[2])
        let fid = m.layout.floatIDs[0]
        m.beginFloatGesture(fid)
        m.updateFloatFrame(fid, WorkspaceRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))
        m.endFloatGesture(fid)
        m.tuckFloat(fid, edge: .right, offset: 0.5)
        m.untuckFloat(fid)
        m.enterLocalFullscreen(fid)
        m.exitLocalFullscreen()
        m.addFloatToLayout(fid)
        m.floatPane(fid)
        m.dockFloat(fid, to: .tab(tile: m.layout.orderedTileIDs[0], preview: .unit))
        settle()
        let focuses = sent.filter { $0["type"] as? String == WireMessage.workspaceFocus }
        XCTAssertGreaterThanOrEqual(focuses.count, 5)
        XCTAssertTrue(focuses.allSatisfy { $0["raise"] as? Bool == false },
                      "arranging never brings a Mac window forward: \(focuses)")
        XCTAssertTrue(sent.allSatisfy { Self.safeTypes.contains($0["type"] as? String ?? "") },
                      "and never acts on one: \(sent.map { $0["type"] ?? "" })")

        // Tap to resume, or a tap that picks a pane: the person asked for that window.
        sent.removeAll()
        m.focus(m.layout.orderedTileIDs[0])
        XCTAssertEqual(sent.last?["type"] as? String, WireMessage.workspaceFocus)
        XCTAssertNil(sent.last?["raise"], "an explicit focus keeps today's message, so the Mac raises the window")
    }

    /// On the Mac, a tile chosen by arranging the receiver's view comes forward once, at its first
    /// authorized key, and only when the Mac's focus is elsewhere. Until then the receiver isn't
    /// told typing is paused; afterwards a change on the Mac pauses typing as before.
    func testTheMacBringsALocallyChosenWindowForwardOnlyForItsFirstKey() {
        var d = WorkspaceDeferredRaise()
        d.focused("f1", raiseNow: false)
        XCTAssertEqual(d.reported(.hostFocusElsewhere, active: "f1"), .deliver, "no typing-paused notice while it waits")
        XCTAssertEqual(d.reported(.hostFocusElsewhere, active: "p1"), .hostFocusElsewhere)
        XCTAssertFalse(d.takeForKey(active: "p1", decision: .hostFocusElsewhere), "only for the tile that was chosen")
        XCTAssertTrue(d.takeForKey(active: "f1", decision: .otherWindowFocused), "the first key brings it forward")
        XCTAssertFalse(d.takeForKey(active: "f1", decision: .hostFocusElsewhere), "once")
        XCTAssertEqual(d.reported(.hostFocusElsewhere, active: "f1"), .hostFocusElsewhere, "then typing pauses as before")

        d.focused("f1", raiseNow: false)
        XCTAssertFalse(d.takeForKey(active: "f1", decision: .deliver), "already in front: nothing is raised")
        XCTAssertNil(d.tile)
        d.focused("f1", raiseNow: false)
        d.focused("p1", raiseNow: true)
        XCTAssertNil(d.tile, "an explicit focus raises at once instead")
        d.focused("f1", raiseNow: false)
        d.clear()
        XCTAssertNil(d.tile, "a press brought a window forward")

        XCTAssertEqual(WorkspaceRequests.focus("f1", raise: false)["raise"] as? Bool, false)
        XCTAssertNil(WorkspaceRequests.focus("f1")["raise"])
    }

    // MARK: Extend is never left by a gesture

    /// From Extend, a Stage Peek tap, Add as New Pane, an overview pick or a drop onto the desktop
    /// waits for confirmation (Window view would remove the extended display). Stay in Extend
    /// changes nothing; confirming runs the step once.
    @MainActor
    func testLeavingExtendAlwaysAsksFirst() {
        var sent: [[String: Any]] = []
        var windowModeRequests = 0
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature],
                               window: false, displays: Self.twoDisplays) { sent.append($0) }
        m.requestWindowMode = { windowModeRequests += 1 }
        m.extending = { true }
        let w = m.catalog!.windows
        let before = m.layout.orderedTileIDs

        m.switchTo(w[0])
        XCTAssertNotNil(m.leaveExtendRequest, "a Stage Peek tap asks")
        XCTAssertEqual(windowModeRequests, 0)
        XCTAssertEqual(m.layout.orderedTileIDs, before)
        m.cancelLeavingExtend()
        XCTAssertNil(m.leaveExtendRequest)
        XCTAssertEqual(windowModeRequests, 0, "Stay in Extend changes nothing")
        XCTAssertFalse(sent.contains { $0["type"] as? String == WireMessage.workspaceRequest })

        // A drop onto the desktop asks as well.
        m.desktopPictureGlobal = CGRect(x: 0, y: 0, width: ipad.width, height: ipad.height)
        m.beginDrag(.window(w[1]), at: CGPoint(x: 300, y: 300))
        m.moveDrag(to: CGPoint(x: 900, y: 400), at: 1)
        XCTAssertFalse(m.endDrag())
        XCTAssertNotNil(m.leaveExtendRequest)
        XCTAssertEqual(windowModeRequests, 0)
        m.cancelLeavingExtend()

        // Add as New Pane (or an overview pick), confirmed: Window view starts, once.
        m.choose(w[2], asNewTile: true)
        XCTAssertNotNil(m.leaveExtendRequest)
        m.confirmLeavingExtend()
        XCTAssertNil(m.leaveExtendRequest)
        XCTAssertEqual(windowModeRequests, 1)
        XCTAssertTrue(m.layout.tiles.values.contains { $0.source?.windowID == 12 })

        // A pending question is dropped when the mode changes underneath or the session ends.
        m.switchTo(w[1])
        XCTAssertNotNil(m.leaveExtendRequest)
        m.apply(.mode(window: true))
        XCTAssertNil(m.leaveExtendRequest)
    }

    /// Mirror and Window view never ask: nothing on the Mac moves when they start Window view.
    @MainActor
    func testMirrorAndWindowViewNeverAskToLeaveExtend() {
        var windowModeRequests = 0
        let mirror = connectedModel(features: [WindowWorkspaceWire.welcomeFeature], window: false, displays: Self.twoDisplays) { _ in }
        mirror.requestWindowMode = { windowModeRequests += 1 }
        mirror.mirroring = { true }
        mirror.switchTo(mirror.catalog!.windows[0])
        XCTAssertNil(mirror.leaveExtendRequest)
        XCTAssertEqual(windowModeRequests, 1)

        let window = connectedModel(features: [WindowWorkspaceWire.welcomeFeature]) { _ in }
        window.extending = { true }   // a stale Extend answer never matters inside Window view
        window.switchTo(window.catalog!.windows[0])
        XCTAssertNil(window.leaveExtendRequest)
        XCTAssertFalse(window.layout.orderedTileIDs.isEmpty)
    }

    // MARK: Lift (moving or resizing a float draws it here, once)

    private func png(width: Int = 160, height: Int = 100) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private func lastTile(_ sent: [[String: Any]], _ id: String) -> [String: Any]? {
        let tiles = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }?["tiles"] as? [[String: Any]] ?? []
        return tiles.first { $0["id"] as? String == id }
    }

    @MainActor
    private func wait(_ seconds: TimeInterval) {
        let exp = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exp.fulfill() }
        wait(for: [exp], timeout: seconds + 2)
    }

    /// Moving or resizing a float lifts it: sent with `lift` (only to a Mac with `floatLift`, only
    /// with a still to draw it from), drawn here in its own view, and still drawn here after it's
    /// let go until the Mac says its frame with the float where it landed is out.
    @MainActor
    func testAMovedFloatIsDrawnHereOnceUntilTheMacShowsItWhereItLanded() throws {
        var sent: [[String: Any]] = []
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature,
                                          WindowWorkspaceWire.floatLiftFeature]) { sent.append($0) }
        XCTAssertTrue(m.canLiftFloats)
        let w = m.catalog!.windows
        m.choose(w[0], asNewTile: false)
        let pane = m.layout.orderedTileIDs[0]
        m.openFloating(w[1])
        let fid = try XCTUnwrap(m.layout.floatIDs.first)
        settle()

        // Picked up before its still arrived: the Mac keeps drawing it; lifted once the still is in.
        m.beginFloatGesture(fid)
        m.liftFloat(fid)
        XCTAssertFalse(m.drawsFloatHere(fid))
        XCTAssertNil(lastTile(sent, fid)?["lift"])
        m.apply(.backdrop(tile: fid, windowID: 11, data: png(), stale: false))
        XCTAssertTrue(m.liftedFloats.contains(fid))
        XCTAssertTrue(m.drawsFloatHere(fid))
        XCTAssertEqual(lastTile(sent, fid)?["lift"] as? Bool, true, "sent at once")
        XCTAssertNil(lastTile(sent, pane)?["lift"], "a pane is never lifted")

        // Drawn here in its own view: the window's 1600x1000 at Fit in a 400x400 float, centred with bars.
        let view = try XCTUnwrap(m.floatContentTransform(fid, width: 400, height: 400))
        XCTAssertEqual(view.contentRect.width, 400, accuracy: 1e-6)
        XCTAssertEqual(view.contentRect.height, 250, accuracy: 1e-6)
        XCTAssertEqual(view.contentRect.y, 75, accuracy: 1e-6)

        for i in 1...5 { m.updateFloatFrame(fid, WorkspaceRect(x: 0.05 * Double(i), y: 0.2, width: 0.3, height: 0.3)) }
        XCTAssertTrue(m.liftedFloats.contains(fid), "lifted for the whole move")
        m.endFloatGesture(fid)
        XCTAssertFalse(m.liftedFloats.contains(fid))
        XCTAssertTrue(m.drawsFloatHere(fid), "let go: still drawn here until the Mac shows it")
        let landed = try XCTUnwrap(lastTile(sent, fid))
        XCTAssertNil(landed["lift"], "the Mac draws it again")
        XCTAssertEqual(landed["x"] as? Double ?? -1, 0.25, accuracy: 1e-9)
        let epoch = try XCTUnwrap(landed["view"] as? Int)

        // An older frame isn't enough; the frame with this view is (after a moment to arrive).
        m.apply(.view([fid: epoch - 1]))
        wait(0.25)
        XCTAssertTrue(m.drawsFloatHere(fid))
        m.apply(.view([fid: epoch]))
        XCTAssertTrue(m.drawsFloatHere(fid), "not the same instant: the frame is still on its way")
        wait(0.25)
        XCTAssertFalse(m.drawsFloatHere(fid))

        // Never composed (a frame lost): it's handed back to the Mac after `landingHold` anyway.
        m.beginFloatGesture(fid)
        m.liftFloat(fid)
        XCTAssertTrue(m.drawsFloatHere(fid))
        m.endFloatGesture(fid)
        wait(WorkspaceModel.landingHold + 0.2)
        XCTAssertFalse(m.drawsFloatHere(fid))

        // A tap (no movement) never lifts: the view only lifts what a finger moves.
        sent.removeAll()
        m.beginFloatGesture(fid)
        m.endFloatGesture(fid)
        XCTAssertFalse(sent.contains { ($0["tiles"] as? [[String: Any]])?.contains { $0["lift"] != nil } == true })

        // Disconnecting forgets it all.
        m.beginFloatGesture(fid)
        m.liftFloat(fid)
        m.apply(.disconnected)
        XCTAssertTrue(m.liftedFloats.isEmpty)
        XCTAssertFalse(m.canLiftFloats)
    }

    /// A Mac without `floatLift` keeps drawing the float: `lift` is never sent.
    @MainActor
    func testAMacWithoutLiftNeverGetsIt() throws {
        var sent: [[String: Any]] = []
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]) { sent.append($0) }
        XCTAssertTrue(m.canFloat)
        XCTAssertFalse(m.canLiftFloats)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.openFloating(m.catalog!.windows[1])
        let fid = try XCTUnwrap(m.layout.floatIDs.first)
        m.beginFloatGesture(fid)
        m.apply(.backdrop(tile: fid, windowID: 11, data: png(), stale: false))
        m.liftFloat(fid)
        m.updateFloatFrame(fid, WorkspaceRect(x: 0.1, y: 0.2, width: 0.3, height: 0.3))
        m.endFloatGesture(fid)
        settle()
        XCTAssertTrue(m.liftedFloats.isEmpty)
        XCTAssertFalse(m.drawsFloatHere(fid))
        XCTAssertFalse(sent.contains { ($0["tiles"] as? [[String: Any]])?.contains { $0["lift"] != nil } == true })
    }

    /// Size > Match Window gives a freely resized float the window's shape back (Fit: no bars).
    @MainActor
    func testMatchWindowGivesTheFloatTheWindowsShape() throws {
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]) { _ in }
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.openFloating(m.catalog!.windows[1])
        let fid = try XCTUnwrap(m.layout.floatIDs.first)
        m.beginFloatGesture(fid)
        m.updateFloatFrame(fid, WorkspaceRect(x: 0.2, y: 0.2, width: 0.5, height: 0.2))
        m.endFloatGesture(fid)
        XCTAssertEqual(try XCTUnwrap(m.windowAspect(fid)), 1.6, accuracy: 1e-9)
        m.matchWindowShape(fid)
        let f = try XCTUnwrap(m.layout.float(fid)?.frame)
        XCTAssertEqual(f.width * ipad.width / (f.height * ipad.height), 1.6, accuracy: 0.01)
        m.rotate(fid)
        XCTAssertEqual(try XCTUnwrap(m.windowAspect(fid)), 1 / 1.6, accuracy: 1e-9, "turned a quarter: the shape as drawn")
    }

    /// Rotating the phone keeps a float's size in points and its place (a share of the screen):
    /// its frame is a share of the picture, which alone would stretch it into a strip.
    @MainActor
    func testAFloatKeepsItsSizeInPointsWhenThePhoneRotates() throws {
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]) { _ in }
        m.updateSpace(phone, hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.openFloating(m.catalog!.windows[1])
        let fid = try XCTUnwrap(m.layout.floatIDs.first)
        let p = try XCTUnwrap(m.layout.float(fid)?.frame)
        let landscape = WorkspaceSize(width: phone.height, height: phone.width)
        m.updateSpace(landscape, hinge: nil)
        let l = try XCTUnwrap(m.layout.float(fid)?.frame)
        XCTAssertEqual(l.width * landscape.width, p.width * phone.width, accuracy: 1)
        XCTAssertEqual(l.height * landscape.height, p.height * phone.height, accuracy: 1)
        XCTAssertEqual(l.midX, p.midX, accuracy: 0.02, "same place across")
        m.updateSpace(phone, hinge: nil)
        let back = try XCTUnwrap(m.layout.float(fid)?.frame)
        XCTAssertEqual(back.width, p.width, accuracy: 0.005, "rotating back gives the same float")
        XCTAssertEqual(back.height, p.height, accuracy: 0.005)

        // Too big for the new screen: shrunk evenly (same shape), never squashed.
        let big = WorkspaceFloatGeometry.carried(WorkspaceRect(x: 0.05, y: 0.1, width: 0.9, height: 0.5), from: phone, to: landscape)
        XCTAssertEqual(big.width * landscape.width / (big.height * landscape.height), (0.9 * phone.width) / (0.5 * phone.height), accuracy: 0.01)
        XCTAssertLessThanOrEqual(big.maxY, 1 + 1e-9)
    }

    // MARK: Several floats on a phone

    private let iphone = WorkspaceSize(width: 430, height: 932)

    /// The cascade on a phone: each new float steps up and across from the bottom-centre one, never
    /// on top of the one before, always inside the picture; a moved-away float frees its place.
    func testNewFloatsOnAPhoneCascadeInsideThePicture() {
        for size in [iphone, phone, WorkspaceSize(width: iphone.height, height: iphone.width), ipad] {
            var shown: [WorkspaceRect] = []
            for n in 0..<8 {
                let f = WorkspaceFloatGeometry.openingFrame(aspect: 1.6, in: size, avoiding: shown)
                XCTAssertGreaterThanOrEqual(f.x, -1e-9, "\(size) #\(n)")
                XCTAssertLessThanOrEqual(f.maxX, 1 + 1e-9, "\(size) #\(n)")
                XCTAssertGreaterThanOrEqual(f.y * size.height, WorkspaceFloatGeometry.barHeight - 1e-6, "\(size) #\(n)")
                XCTAssertLessThanOrEqual(f.maxY, 1 + 1e-9, "\(size) #\(n)")
                for g in shown {
                    let apart = abs(f.x - g.x) * size.width >= WorkspaceFloatGeometry.cascade / 2
                        || abs(f.y - g.y) * size.height >= WorkspaceFloatGeometry.cascade / 2
                    XCTAssertTrue(apart, "\(size) #\(n) opens on top of \(g)")
                }
                if let last = shown.last {
                    XCTAssertGreaterThanOrEqual(max(abs(f.x - last.x) * size.width, abs(f.y - last.y) * size.height),
                                                WorkspaceFloatGeometry.cascade - 1e-6, "visibly offset from the one before")
                }
                shown.append(f)
            }
        }
        // Portrait: the first sits bottom-centre, the next one up and to the right.
        let first = WorkspaceFloatGeometry.openingFrame(aspect: 1.6, in: iphone, avoiding: [])
        XCTAssertEqual(first.midX, 0.5, accuracy: 1e-6)
        XCTAssertEqual((1 - first.maxY) * iphone.height, 24, accuracy: 1e-6)
        let second = WorkspaceFloatGeometry.openingFrame(aspect: 1.6, in: iphone, avoiding: [first])
        XCTAssertEqual((second.x - first.x) * iphone.width, WorkspaceFloatGeometry.cascade, accuracy: 1e-6)
        XCTAssertEqual((first.y - second.y) * iphone.height, WorkspaceFloatGeometry.cascade, accuracy: 1e-6)
        // The first one moved away: its place is free again.
        let moved = WorkspaceRect(x: 0.05, y: 0.1, width: first.width, height: first.height)
        XCTAssertEqual(WorkspaceFloatGeometry.openingFrame(aspect: 1.6, in: iphone, avoiding: [moved, second]), first)
    }

    /// A phone shows several floats at once, like an iPad: two, three, and as many as the tile
    /// budget holds (one pane and eight floats), each sent to the Mac. Raising one or bringing one
    /// back from an edge never tucks another; rotating and reconnecting keep which are shown and
    /// which wait tucked.
    @MainActor
    func testAPhoneShowsSeveralFloatsAtOnce() throws {
        let suite = UserDefaults(suiteName: "WorkspaceFloatTests-\(UUID().uuidString)")!
        let windows = Array(10...19)
        let features: Set<String> = [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]
        var sent: [[String: Any]] = []
        let m = connectedModel(features: features, windows: windows, defaults: suite) { sent.append($0) }
        m.updateSpace(iphone, hinge: nil)
        let w = m.catalog!.windows
        m.choose(w[0], asNewTile: false)
        for (n, item) in w[1...8].enumerated() {
            m.openFloating(item)
            XCTAssertEqual(m.layout.visibleFloatIDs.count, n + 1, "\(n + 1) floats shown at once")
            XCTAssertEqual(m.layout.visibleFloatIDs.last, m.layout.floatIDs.last, "the new one in front")
        }
        XCTAssertEqual(m.layout.tiles.count, WorkspaceLayout.maximumTiles)
        m.openFloating(w[9])
        XCTAssertEqual(m.layout.floatIDs.count, 8, "the tile budget is the only limit")
        let floats = m.layout.floatIDs
        let frames = m.layout.floats.map(\.frame)
        for (i, f) in frames.enumerated() {
            for g in frames[(i + 1)...] {
                XCTAssertFalse(abs(f.x - g.x) * iphone.width < 12 && abs(f.y - g.y) * iphone.height < 12, "never exactly on top of another")
            }
        }
        settle()
        let request = sent.last { $0["type"] as? String == WireMessage.workspaceRequest }?["tiles"] as? [[String: Any]] ?? []
        XCTAssertEqual(request.filter { $0["layer"] as? String == "float" }.count, 8, "every shown float is sent")

        // Raising one (a touch, a move) never tucks another.
        m.raiseFloat(floats[0])
        m.beginFloatGesture(floats[2])
        m.updateFloatFrame(floats[2], WorkspaceRect(x: 0.1, y: 0.3, width: frames[2].width, height: frames[2].height))
        m.endFloatGesture(floats[2])
        XCTAssertEqual(Set(m.layout.visibleFloatIDs), Set(floats))
        XCTAssertEqual(m.layout.floatIDs.last, floats[2])

        // Bringing one back from an edge never tucks another.
        m.tuckFloat(floats[1], edge: .left, offset: 0.5)
        m.tuckFloat(floats[4], edge: .right, offset: 0.5)
        XCTAssertEqual(m.layout.visibleFloatIDs.count, 6)
        m.untuckFloat(floats[1])
        XCTAssertEqual(m.layout.visibleFloatIDs.count, 7)
        XCTAssertNotNil(m.layout.float(floats[4])?.tuck, "the other tucked one stays tucked")
        m.beginRestoringFloat(floats[4])
        m.endFloatGesture(floats[4])
        XCTAssertEqual(Set(m.layout.visibleFloatIDs), Set(floats))

        // Rotating keeps the shown set and the tucked one.
        m.tuckFloat(floats[3], edge: .bottom, offset: 0.4)
        let shown = Set(m.layout.visibleFloatIDs)
        XCTAssertEqual(shown.count, 7)
        m.updateSpace(WorkspaceSize(width: iphone.height, height: iphone.width), hinge: nil)
        XCTAssertEqual(Set(m.layout.visibleFloatIDs), shown)
        XCTAssertEqual(m.layout.float(floats[3])?.tuck?.edge, .bottom)
        m.updateSpace(iphone, hinge: nil)
        XCTAssertEqual(Set(m.layout.visibleFloatIDs), shown)

        // Reconnecting brings back the same arrangement.
        let order = m.layout.floatIDs
        m.apply(.disconnected)
        let again = connectedModel(features: features, windows: windows, defaults: suite) { _ in }
        again.updateSpace(iphone, hinge: nil)
        XCTAssertEqual(Set(again.layout.visibleFloatIDs), shown)
        XCTAssertEqual(again.layout.float(floats[3])?.tuck?.edge, .bottom)
        XCTAssertEqual(again.layout.floatIDs, order, "the same order back to front")
    }

    /// A Mac that can't draw floats keeps all of them tucked here, on a phone as on an iPad, and an
    /// unrelated change doesn't save them tucked: they all show again on a Mac that can.
    @MainActor
    func testAMacThatCantDrawFloatsKeepsThemTuckedWithoutSavingThat() throws {
        let suite = UserDefaults(suiteName: "WorkspaceFloatTests-\(UUID().uuidString)")!
        let m = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature], defaults: suite) { _ in }
        m.updateSpace(iphone, hinge: nil)
        m.choose(m.catalog!.windows[0], asNewTile: false)
        m.openFloating(m.catalog!.windows[1])
        m.openFloating(m.catalog!.windows[2])
        let floats = m.layout.floatIDs
        XCTAssertEqual(m.layout.visibleFloatIDs, floats)
        m.apply(.disconnected)

        let old = connectedModel(features: [WindowWorkspaceWire.welcomeFeature], defaults: suite) { _ in }
        old.updateSpace(iphone, hinge: nil)
        XCTAssertTrue(old.layout.visibleFloatIDs.isEmpty, "all of them wait tucked")
        XCTAssertEqual(old.layout.floatIDs, floats, "none lost")
        old.rotate(old.layout.orderedTileIDs[0])   // an unrelated change
        XCTAssertTrue(old.layout.visibleFloatIDs.isEmpty)
        old.apply(.disconnected)

        let again = connectedModel(features: [WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature], defaults: suite) { _ in }
        again.updateSpace(iphone, hinge: nil)
        XCTAssertEqual(again.layout.visibleFloatIDs, floats, "shown again on a Mac that draws them")
    }
}
