import Foundation

// Floating panes: Window mode panes that float above the tiled panes (or above a Full Desktop
// pane), may overlap, can be tucked to any edge and turned back into panes.
//
// Everything here is receiver-local presentation. A float is an ordinary workspace tile with a
// frame and a place in a back-to-front order: the Mac composites it into the same single
// canvas and the same single stream, after the tiled panes, so moving, resizing, raising,
// tucking, flinging or docking one changes only the canvas. The real Mac window is never moved,
// resized, minimized, closed or activated by any of it, and none of it produces pointer input.
//
// Pure and deterministic (Foundation only), like WindowWorkspace.swift: every rule is unit
// tested in MacTests and can be ported to Android against the same expectations.

// MARK: - Model

/// Where a tucked float waits: on an edge of the picture, its handle centred at `offset` along
/// that edge (0 = its top or left end, 1 = its bottom or right end). Its frame is kept, so it
/// comes back exactly where it was.
struct WorkspaceFloatTuck: Equatable, Sendable {
    /// Any edge. The handles themselves stay clear of the system's edge gestures (the status bar,
    /// Notification Center and Dynamic Island band at the top, the Home indicator at the bottom):
    /// see `WorkspaceFloatGeometry.handleArea`.
    var edge: WorkspaceEdge
    var offset: Double
}

/// One floating pane: a tile of the layout drawn at `frame` (normalized to the canvas) above
/// the tree, or tucked to an edge.
struct WorkspaceFloat: Equatable, Sendable {
    var tile: String
    /// The window's content on the canvas (what the Mac draws). The receiver's title bar sits
    /// just above it, so the Mac window's own title bar and tabs stay reachable.
    var frame: WorkspaceRect
    /// Tucked: not shown, not sent (its capture stops), restored to `frame`.
    var tuck: WorkspaceFloatTuck?

    /// Kept on the canvas without knowing its size (decode, normalize): finite, inside, not empty.
    var sanitized: WorkspaceFloat {
        var copy = self
        func finite(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? v : fallback }
        let w = min(max(finite(frame.width, 0.4), 0.02), 1)
        let h = min(max(finite(frame.height, 0.4), 0.02), 1)
        let x = min(max(finite(frame.x, 0), 0), 1 - w)
        let y = min(max(finite(frame.y, 0), 0), 1 - h)
        copy.frame = WorkspaceRect(x: x, y: y, width: w, height: h)
        if var t = tuck {
            t.offset = min(max(finite(t.offset, 0.5), 0), 1)
            copy.tuck = t
        }
        return copy
    }
}

extension WorkspaceLayout {
    /// Floating panes, back to front.
    var floatIDs: [String] { floats.map(\.tile) }
    /// Every pane: the tree's in reading order, then the floats back to front.
    var allTileIDs: [String] { orderedTileIDs + floatIDs }
    /// Panes in the tree. Capacity, presets and "the last pane" count these; floats don't take
    /// the tree's room.
    var paneCount: Int { orderedTileIDs.count }
    /// Floats shown now, back to front (tucked ones aren't).
    var visibleFloatIDs: [String] { floats.filter { $0.tuck == nil }.map(\.tile) }

    func isFloat(_ id: String) -> Bool { floats.contains { $0.tile == id } }
    func float(_ id: String) -> WorkspaceFloat? { floats.first { $0.tile == id } }

    // MARK: Opening and converting

    /// A new floating pane in front of the others (Stage Peek's Open as Floating Window).
    func addingFloat(_ tile: WorkspaceTile, frame: WorkspaceRect) -> WorkspaceLayout {
        guard tiles[tile.id] == nil, tiles.count < Self.maximumTiles else { return self }
        var copy = self
        copy.tiles[tile.id] = tile
        copy.floats.append(WorkspaceFloat(tile: tile.id, frame: frame))
        copy.normalize()
        return copy
    }

    /// A pane of the tree floats (Float This Pane, or its title dragged out). It keeps its tile
    /// id, so the Mac keeps the same capture: only its rectangle changes. Its slot closes up and
    /// the neighbours take the room, as when a pane is removed.
    func floatingPane(_ id: String, frame: WorkspaceRect) -> WorkspaceLayout {
        guard tiles[id] != nil, orderedTileIDs.contains(id) else { return self }
        var copy = self
        copy.root = Self.removeSlot(root, tileID: id)
        copy.floats.append(WorkspaceFloat(tile: id, frame: frame))
        if copy.maximized == id { copy.maximized = nil }
        copy.normalize()
        return copy
    }

    /// One tab of a pane floats. The shown tab keeps the pane's id (its capture goes on) and
    /// the other tabs stay in the slot under `newID`; a background tab (not streaming) becomes
    /// a new floating pane `newID`. Nothing is closed or dropped.
    func floatingTab(of id: String, at index: Int, frame: WorkspaceRect, newID: String) -> WorkspaceLayout {
        guard let tile = tiles[id], orderedTileIDs.contains(id), tile.tabs.indices.contains(index),
              tiles[newID] == nil, tiles.count < Self.maximumTiles else { return self }
        let s = tile.tabs[index]
        var copy = self
        if s == tile.source {
            var rest = tile
            rest.id = newID
            rest.tabs.remove(at: index)
            rest.tabViews[s.tabKey] = nil
            rest.show(rest.tabs[min(index, rest.tabs.count - 1)], keepingCurrent: false)
            if rest.tabs.count <= 1 { rest.tabs = []; rest.tabViews = [:] }
            copy.tiles[newID] = rest
            copy.tiles[id] = WorkspaceTile(id: id, source: s, rotation: tile.rotation, fit: tile.fit, zoom: tile.zoom)
            copy.root = Self.mapSlots(root) { $0 == id ? newID : $0 }
            copy.floats.append(WorkspaceFloat(tile: id, frame: frame))
            if copy.maximized == id { copy.maximized = newID }
            copy.normalize()
            return copy
        }
        let view = tile.tabViews[s.tabKey] ?? WorkspaceTabView()
        copy = copy.removingTab(of: id, at: index)
        return copy.addingFloat(WorkspaceTile(id: newID, source: s, rotation: view.rotation, fit: view.fit, zoom: view.zoom), frame: frame)
    }

    /// A float goes back into the tree where it was dropped: beside a pane (`split`), into an
    /// empty slot, or into a pane as a tab (`tab`; `replace` is a tab too: docking never
    /// replaces or drops another window). It keeps its tile id where it can, so its capture goes on.
    func docking(_ id: String, to drop: WorkspaceWindowDrop) -> WorkspaceLayout {
        guard isFloat(id) else { return self }
        switch drop {
        case .split(let index, let edge, _):
            guard let occupant = Self.slotID(root, at: index) else { return self }
            var copy = self
            copy.floats.removeAll { $0.tile == id }
            if copy.maximized == id { copy.maximized = nil }
            copy.root = occupant == nil ? Self.setSlot(root, at: index, to: id) : Self.split(root, at: index, edge: edge, inserting: id)
            copy.normalize()
            return copy
        case .emptySlot(let index, _):
            guard Self.slotID(root, at: index) == .some(nil) else { return self }
            var copy = self
            copy.floats.removeAll { $0.tile == id }
            if copy.maximized == id { copy.maximized = nil }
            copy.root = Self.setSlot(root, at: index, to: id)
            copy.normalize()
            return copy
        case .tab(let target, _), .replace(let target, _):
            return dockingAsTab(id, into: target)
        }
    }

    /// The float joins pane `target` as its shown tab; the pane's windows stay as tabs, each
    /// with its own view. The merged pane takes the float's tile id, so the docked window's
    /// capture goes on; the pane's previous window simply stops streaming as a background tab.
    func dockingAsTab(_ id: String, into target: String) -> WorkspaceLayout {
        guard id != target, let floating = tiles[id], isFloat(id), let source = floating.source,
              let pane = tiles[target], orderedTileIDs.contains(target) else { return self }
        guard let current = pane.source else {
            // An empty pane: the float simply takes its place.
            var copy = self
            copy.floats.removeAll { $0.tile == id }
            copy.tiles[target] = nil
            copy.root = Self.mapSlots(root) { $0 == target ? id : $0 }
            if copy.maximized == target || copy.maximized == id { copy.maximized = nil }
            copy.normalize()
            return copy
        }
        var merged = pane
        merged.id = id
        let kept = WorkspaceTabView(rotation: pane.rotation, fit: pane.fit, zoom: pane.zoom)
        merged.tabViews[current.tabKey] = kept.isDefault ? nil : kept
        var list = pane.windows
        list.removeAll { $0.host == source.host && $0.windowID == source.windowID }
        list.append(source)
        merged.tabs = list.count > 1 ? list : []
        merged.source = source
        merged.rotation = floating.rotation
        merged.fit = floating.fit
        merged.zoom = floating.zoom
        let keys = Set(merged.tabs.map(\.tabKey))
        merged.tabViews = merged.tabViews.filter { keys.contains($0.key) && $0.key != source.tabKey }
        var copy = self
        copy.floats.removeAll { $0.tile == id }
        copy.tiles[target] = nil
        copy.tiles[id] = merged
        copy.root = Self.mapSlots(root) { $0 == target ? id : $0 }
        if copy.maximized == target || copy.maximized == id { copy.maximized = nil }
        copy.normalize()
        return copy
    }

    /// Add to Layout: the float becomes a new pane (an empty slot, else beside the last pane).
    func dockingAsPane(_ id: String, landscape: Bool) -> WorkspaceLayout {
        guard let tile = tiles[id], isFloat(id) else { return self }
        var copy = self
        copy.floats.removeAll { $0.tile == id }
        copy.tiles[id] = nil
        if copy.maximized == id { copy.maximized = nil }
        copy.normalize()
        if copy.orderedTileIDs.isEmpty {
            copy.tiles[id] = tile
            copy.root = .slot(id)
            copy.normalize()
            return copy
        }
        return copy.adding(tile, landscape: landscape)
    }

    /// `tree`'s panes (a preset, a re-flow) with this layout's floats kept as they are.
    func replacingTree(with tree: WorkspaceLayout) -> WorkspaceLayout {
        guard !floats.isEmpty else { return tree }
        var copy = tree
        let inTree = Set(tree.orderedTileIDs)
        let kept = floats.filter { !inTree.contains($0.tile) && tiles[$0.tile] != nil }
        for f in kept { copy.tiles[f.tile] = tiles[f.tile] }
        copy.floats = kept
        copy.normalize()
        return copy
    }

    // MARK: Arranging

    func settingFloatFrame(_ id: String, _ frame: WorkspaceRect) -> WorkspaceLayout {
        guard let i = floats.firstIndex(where: { $0.tile == id }), floats[i].frame != frame else { return self }
        var copy = self
        copy.floats[i].frame = frame
        copy.normalize()
        return copy
    }

    /// In front of the other floats (touching it, focusing it). Floats always stay above the tree.
    func raisingFloat(_ id: String) -> WorkspaceLayout {
        guard let i = floats.firstIndex(where: { $0.tile == id }), i != floats.count - 1 else { return self }
        var copy = self
        copy.floats.append(copy.floats.remove(at: i))
        return copy
    }

    /// Hidden to an edge (any of the four): it keeps its frame and its place in the workspace;
    /// nothing happens to the Mac window. Its capture stops while it isn't sent.
    func tuckingFloat(_ id: String, edge: WorkspaceEdge, offset: Double) -> WorkspaceLayout {
        guard let i = floats.firstIndex(where: { $0.tile == id }) else { return self }
        var copy = self
        copy.floats[i].tuck = WorkspaceFloatTuck(edge: edge, offset: min(max(offset.isFinite ? offset : 0.5, 0), 1))
        if copy.maximized == id { copy.maximized = nil }
        return copy
    }

    /// Back from its edge, at the frame it had, in front.
    func untuckingFloat(_ id: String) -> WorkspaceLayout {
        guard let i = floats.firstIndex(where: { $0.tile == id }), floats[i].tuck != nil else { return raisingFloat(id) }
        var copy = self
        copy.floats[i].tuck = nil
        return copy.raisingFloat(id)
    }
}

// MARK: - Geometry

enum WorkspaceFloatGeometry {
    /// The receiver's title bar above a float's content, in points.
    static let barHeight = 30.0
    /// New floats step down and right from the last one by this much (points).
    static let cascade = 24.0
    /// Margin kept from the picture's edges when gliding (points); closer than `snap` lands flush.
    static let snap = 14.0

    /// Smallest float content in points: still a readable glance at the window with room for a
    /// 44 pt touch, never larger than the picture allows. (Its grips sit outside the content.)
    static func minimum(for size: WorkspaceSize) -> WorkspaceSize {
        let compact = WorkspaceSizeClass.of(size) == .compact
        let w = compact ? 120.0 : 160.0, h = compact ? 80.0 : 100.0
        return WorkspaceSize(width: min(w, size.width), height: min(h, max(size.height - barHeight, 1)))
    }

    /// `rect` kept usable on this picture: at least the minimum size, at most the picture, the
    /// whole content and the title bar on screen.
    static func clamped(_ rect: WorkspaceRect, in size: WorkspaceSize) -> WorkspaceRect {
        guard size.width > 0, size.height > 0 else { return WorkspaceFloat(tile: "", frame: rect).sanitized.frame }
        let bar = min(barHeight / size.height, 0.5)
        let m = minimum(for: size)
        let mw = min(m.width / size.width, 1), mh = min(m.height / size.height, 1 - bar)
        func finite(_ v: Double, _ d: Double) -> Double { v.isFinite ? v : d }
        let w = min(max(finite(rect.width, 0.4), mw), 1)
        let h = min(max(finite(rect.height, 0.4), mh), 1 - bar)
        let x = min(max(finite(rect.x, 0), 0), 1 - w)
        let y = min(max(finite(rect.y, bar), bar), 1 - h)
        return WorkspaceRect(x: x, y: y, width: w, height: h)
    }

    /// Where a new float opens. `aspect`: the window's width / height when known. `index`: its
    /// place in the cascade: each one steps `cascade` points from the one before (up and across
    /// from the bottom on a phone, down and across on a larger screen), starting over on an axis
    /// before it would leave the picture. `center`: where it was dropped.
    static func defaultFrame(aspect: Double?, in size: WorkspaceSize, index: Int = 0, center: WorkspacePoint? = nil) -> WorkspaceRect {
        guard size.width > 0, size.height > 0 else { return WorkspaceRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4) }
        let a = (aspect ?? 1.5).isFinite && (aspect ?? 0) > 0 ? aspect! : 1.5
        let compact = WorkspaceSizeClass.of(size) == .compact
        let portrait = size.height > size.width
        var w: Double, h: Double
        // A phone opens a float as a picture-in-picture, not a second screen over the first.
        if compact && portrait {
            w = size.width * 0.62; h = min(w / a, size.height * 0.32)
        } else if compact {
            w = size.width * 0.38; h = min(w / a, size.height * 0.6)
        } else {
            w = size.width * 0.42; h = min(w / a, size.height * 0.62)
        }
        if h < w / a { w = h * a }   // keep the window's shape when the height ran out
        var x: Double, y: Double
        if let c = center {
            x = c.x * size.width - w / 2; y = c.y * size.height - h / 2
        } else {
            // Where the first one goes and which way the next ones step.
            let x0: Double, y0: Double, sx: Double, sy: Double
            if compact && portrait {
                x0 = (size.width - w) / 2; y0 = size.height - h - 24; sx = 1; sy = -1
            } else if compact {
                x0 = size.width - w - 24; y0 = size.height - h - 24; sx = -1; sy = -1
            } else {
                x0 = size.width * 0.5 - w / 2; y0 = size.height * 0.18; sx = 1; sy = 1
            }
            let roomX = sx > 0 ? size.width - w - x0 : x0
            let roomY = sy > 0 ? size.height - h - y0 : y0 - barHeight
            func steps(_ room: Double) -> Int { max(Int((max(room, 0) / cascade).rounded(.down)) + 1, 1) }
            let i = max(index, 0)
            x = x0 + sx * Double(i % steps(roomX)) * cascade
            y = y0 + sy * Double(i % steps(roomY)) * cascade
        }
        return clamped(WorkspaceRect(x: x / size.width, y: y / size.height, width: w / size.width, height: h / size.height), in: size)
    }

    /// Where a new float opens among the floats shown now (`shown`, picture shares): the first
    /// place in the cascade that isn't on top of one of them (within half a step of where one is),
    /// so a new float never hides the one before it exactly.
    static func openingFrame(aspect: Double?, in size: WorkspaceSize, avoiding shown: [WorkspaceRect]) -> WorkspaceRect {
        guard size.width > 0, size.height > 0 else { return defaultFrame(aspect: aspect, in: size) }
        let near = cascade / 2
        func taken(_ r: WorkspaceRect) -> Bool {
            shown.contains { abs(($0.x - r.x) * size.width) < near && abs(($0.y - r.y) * size.height) < near }
        }
        for i in 0..<(WorkspaceLayout.maximumTiles * 2) {
            let r = defaultFrame(aspect: aspect, in: size, index: i)
            if !taken(r) { return r }
        }
        return defaultFrame(aspect: aspect, in: size, index: shown.count)
    }

    /// The floats as shown in this space: each kept usable (clamped). A phone shows as many as an
    /// iPad (the tile budget, `WorkspaceLayout.maximumTiles`, is the only limit): a small screen
    /// never tucks, resizes or removes one. `shown` false (the Mac can't draw floats): all of
    /// them wait tucked, here only (`WorkspaceModel` doesn't save that).
    static func fitted(_ floats: [WorkspaceFloat], in size: WorkspaceSize, shown: Bool = true) -> [WorkspaceFloat] {
        var out = floats.map { f -> WorkspaceFloat in
            var c = f
            c.frame = clamped(f.frame, in: size)
            return c
        }
        guard !shown else { return out }
        for i in out.indices where out[i].tuck == nil {
            let count = out.filter { $0.tuck?.edge == .right }.count
            out[i].tuck = WorkspaceFloatTuck(edge: .right, offset: min(0.3 + Double(count) * 0.12, 0.85))
        }
        return out
    }

    /// Which lower corner a resize grip is on.
    enum Corner: Sendable { case bottomLeading, bottomTrailing }

    /// A float resized from a lower corner by `translation` (points) since the drag began at
    /// `start`: the opposite top corner stays put. Without `aspect` (what the grips do) width and
    /// height follow the finger freely: the float is a viewport, and its view (Fit with bars,
    /// Fill, zoom) scales with it, never stretched. With `aspect` the float keeps that shape; the
    /// larger of the two finger movements decides. Kept between the minimum and the picture.
    static func resized(_ start: WorkspaceRect, corner: Corner, translation: (x: Double, y: Double), aspect: Double?,
                        in size: WorkspaceSize) -> WorkspaceRect {
        guard size.width > 0, size.height > 0, translation.x.isFinite, translation.y.isFinite else { return start }
        let m = minimum(for: size)
        let sign = corner == .bottomTrailing ? 1.0 : -1.0
        var w = start.width * size.width + sign * translation.x
        var h = start.height * size.height + translation.y
        // Room from the fixed corner to the picture's edges.
        let maxW = corner == .bottomTrailing ? (1 - start.x) * size.width : start.maxX * size.width
        let maxH = (1 - start.y) * size.height
        let minW = min(m.width, maxW), minH = min(m.height, maxH)
        if let a = aspect, a.isFinite, a > 0 {
            // Follow whichever movement asks for the larger float, at the window's shape.
            let byW = max(w, minW), byH = max(h, minH)
            w = max(byW, byH * a); h = w / a
            if w > maxW { w = maxW; h = w / a }
            if h > maxH { h = maxH; w = h * a }
            if w < minW || h < minH { w = max(min(max(w, minW), maxW), 1); h = max(min(max(h, minH), maxH), 1) }
        } else {
            w = min(max(w, minW), maxW); h = min(max(h, minH), maxH)
        }
        let x = corner == .bottomTrailing ? start.x : start.maxX - w / size.width
        return WorkspaceRect(x: x, y: start.y, width: w / size.width, height: h / size.height)
    }

    /// A float carried to a new picture size (the device rotated, or its window was resized):
    /// same size in points and same centre (as a share of the picture), shrunk evenly only when
    /// it no longer fits, so it never turns into a strip. Kept usable.
    static func carried(_ r: WorkspaceRect, from old: WorkspaceSize, to new: WorkspaceSize) -> WorkspaceRect {
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0 else { return r }
        var w = r.width * old.width, h = r.height * old.height
        let room = WorkspaceSize(width: new.width, height: max(new.height - barHeight, 1))
        let shrink = min(1, room.width / max(w, 1), room.height / max(h, 1))
        w *= shrink; h *= shrink
        let cx = r.midX * new.width, cy = r.midY * new.height
        return clamped(WorkspaceRect(x: (cx - w / 2) / new.width, y: (cy - h / 2) / new.height,
                                     width: w / new.width, height: h / new.height), in: new)
    }

    /// The float reshaped to the window's own shape (`aspect`, width / height), keeping its area
    /// and centre: Fit then shows the whole window with no bars. Kept usable.
    static func matched(_ r: WorkspaceRect, aspect: Double, in size: WorkspaceSize) -> WorkspaceRect {
        guard aspect.isFinite, aspect > 0, size.width > 0, size.height > 0 else { return r }
        let area = r.width * size.width * r.height * size.height
        var w = (area * aspect).squareRoot(), h = w / aspect
        // Within the picture (below the title bar), still the window's shape.
        let maxW = size.width, maxH = max(size.height - barHeight, 1)
        if w > maxW { w = maxW; h = w / aspect }
        if h > maxH { h = maxH; w = h * aspect }
        let cx = r.midX * size.width, cy = r.midY * size.height
        return clamped(WorkspaceRect(x: (cx - w / 2) / size.width, y: (cy - h / 2) / size.height,
                                     width: w / size.width, height: h / size.height), in: size)
    }

    /// A float scaled about its centre (accessibility Make Larger / Smaller, size presets),
    /// keeping its shape, kept usable.
    static func scaled(_ r: WorkspaceRect, by factor: Double, in size: WorkspaceSize) -> WorkspaceRect {
        guard factor.isFinite, factor > 0 else { return r }
        let w = r.width * factor, h = r.height * factor
        return clamped(WorkspaceRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h), in: size)
    }

    // MARK: Tucked handles

    /// One handle on an edge: a single tucked float (drawn as a sliver of its window), or several
    /// collapsed into a stack.
    struct TuckTab: Equatable, Sendable {
        /// Back to front as tucked; more than one = a stack (opens a list).
        var ids: [String]
        /// The sliver as drawn, in points, in the picture's coordinates. Its touch area reaches
        /// `touchDepth` in from the edge.
        var rect: WorkspaceRect
        /// The edge it sits on.
        var edge: WorkspaceEdge
        var isStack: Bool { ids.count > 1 }
    }

    /// The sliver (points): `width` deep from its edge, `height` long along it (rotated on the
    /// top and bottom edges). Slim, but long enough to show a slice of the window and its icon.
    static let tabSize = WorkspaceSize(width: 28, height: 68)
    /// How far in from the edge a handle takes touches (points): a 44 pt target.
    static let touchDepth = 44.0
    static let tabSpacing = 8.0
    /// The ends of the left and right edges are left to the system (Control Center, the Home
    /// indicator, notification and app switching gestures): handles stay within the middle.
    static let tabBand = 0.12
    /// Kept clear of the screen's top and bottom (points), beyond the safe area: the system's own
    /// edge swipes start there (Notification Center, Control Center, the Home indicator, the Dock).
    static let systemEdgeClearance = 24.0
    /// More tucked floats than this on one edge share one stack handle.
    static let maximumTabsPerEdge = 4

    /// Where tuck handles may sit (points): the picture inside the safe area (clear of the notch,
    /// the Dynamic Island, the status bar and the Home indicator) and at least
    /// `systemEdgeClearance` from the screen's top and bottom, where the system's swipes start.
    /// `screen` nil: the safe area alone. nil when nothing is left.
    static func handleArea(picture: WorkspaceRect, safe: WorkspaceRect?, screen: WorkspaceRect?) -> WorkspaceRect? {
        guard [picture.x, picture.y, picture.width, picture.height].allSatisfy(\.isFinite) else { return nil }
        var area = picture
        if let safe {
            guard let a = area.intersection(safe) else { return nil }
            area = a
        }
        if let s = screen, s.width > 0, s.height > 0, s.y.isFinite, s.height.isFinite {
            let top = max(area.y, s.y + systemEdgeClearance), bottom = min(area.maxY, s.maxY - systemEdgeClearance)
            guard bottom > top else { return nil }
            area.y = top
            area.height = bottom - top
        }
        return area.width > 0 && area.height > 0 ? area : nil
    }

    /// Handles go along y on the left and right edges, along x on the top and bottom.
    private static func alongY(_ edge: WorkspaceEdge) -> Bool { edge.axis == .horizontal }

    /// The stretch of `edge` handles may use (points along it): the left and right edges' middle
    /// (`tabBand` kept at each end); the top and bottom edges clear of the corners, so they never
    /// meet the side handles. At least one handle long while the area is.
    static func run(_ edge: WorkspaceEdge, in area: WorkspaceRect) -> (lo: Double, hi: Double) {
        let start = alongY(edge) ? area.y : area.x, extent = alongY(edge) ? area.height : area.width
        let inset = alongY(edge) ? extent * tabBand : max(extent * tabBand, touchDepth + tabSpacing)
        var lo = start + inset, hi = start + extent - inset
        if hi - lo < tabSize.height {
            let mid = start + extent / 2
            lo = max(start, mid - tabSize.height / 2)
            hi = min(start + extent, mid + tabSize.height / 2)
        }
        return (lo, hi)
    }

    /// The edges a float may be tucked into here: those with room for a handle.
    static func tuckEdges(area: WorkspaceRect?) -> Set<WorkspaceEdge> {
        guard let area, area.width > 0, area.height > 0 else { return [] }
        return Set([WorkspaceEdge.left, .right, .top, .bottom].filter { e in
            let r = run(e, in: area)
            return r.hi - r.lo >= tabSize.height - 1e-9
                && (alongY(e) ? area.width : area.height) >= touchDepth
        })
    }

    /// The parts of `edge`'s run no reserved rect reaches (each at least one handle long). A rect
    /// counts when it comes within the handles' touch depth of the edge; a spacing is kept to it.
    static func freeRuns(_ edge: WorkspaceEdge, in area: WorkspaceRect, avoiding reserved: [WorkspaceRect]) -> [(lo: Double, hi: Double)] {
        let along = alongY(edge)
        let depth: (lo: Double, hi: Double) = {
            switch edge {
            case .left: return (area.x, area.x + touchDepth)
            case .right: return (area.maxX - touchDepth, area.maxX)
            case .top: return (area.y, area.y + touchDepth)
            case .bottom: return (area.maxY - touchDepth, area.maxY)
            }
        }()
        var free = [run(edge, in: area)]
        for r in reserved where r.width > 0 && r.height > 0 && [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite) {
            let (p0, p1) = along ? (r.x, r.maxX) : (r.y, r.maxY)
            guard p1 > depth.lo, p0 < depth.hi else { continue }
            let (a0, a1) = along ? (r.y - tabSpacing, r.maxY + tabSpacing) : (r.x - tabSpacing, r.maxX + tabSpacing)
            free = free.flatMap { seg -> [(lo: Double, hi: Double)] in
                guard a1 > seg.lo, a0 < seg.hi else { return [seg] }
                return [(seg.lo, min(a0, seg.hi)), (max(a1, seg.lo), seg.hi)].filter { $0.1 > $0.0 }
            }
        }
        return free.filter { $0.hi - $0.lo >= tabSize.height - 1e-9 }
    }

    /// The handles on one edge of `area` (points). `tucked`: (id, offset) in tuck order. One
    /// handle each, as near its offset as the free room allows (sliding along the edge past
    /// whatever `reserved` holds, never overlapping); when the edge has no room for each, or more
    /// than `maximumTabsPerEdge`, one stack where most of them want to be.
    static func tuckTabs(_ tucked: [(id: String, offset: Double)], edge: WorkspaceEdge, area: WorkspaceRect,
                         avoiding reserved: [WorkspaceRect] = []) -> [TuckTab] {
        guard !tucked.isEmpty, area.width > 0, area.height > 0 else { return [] }
        let length = tabSize.height, gap = tabSpacing
        let along = alongY(edge)
        let start = along ? area.y : area.x, extent = along ? area.height : area.width
        func rect(_ a: Double) -> WorkspaceRect {
            switch edge {
            case .left: return WorkspaceRect(x: area.x, y: a, width: tabSize.width, height: length)
            case .right: return WorkspaceRect(x: area.maxX - tabSize.width, y: a, width: tabSize.width, height: length)
            case .top: return WorkspaceRect(x: a, y: area.y, width: length, height: tabSize.width)
            case .bottom: return WorkspaceRect(x: a, y: area.maxY - tabSize.width, width: length, height: tabSize.width)
            }
        }
        /// Where a handle centred at `centre` starts, inside `lo…hi`.
        func place(_ centre: Double, _ lo: Double, _ hi: Double) -> Double { min(max(centre - length / 2, lo), max(hi - length, lo)) }
        func distance(_ c: Double, _ seg: (lo: Double, hi: Double)) -> Double { c < seg.lo ? seg.lo - c : (c > seg.hi ? c - seg.hi : 0) }
        let wanted = tucked.map { start + (($0.offset.isFinite ? min(max($0.offset, 0), 1) : 0.5) * extent) }
        // Along the edge, in tuck order where they want the same place.
        let order = tucked.indices.sorted { (wanted[$0], $0) < (wanted[$1], $1) }
        let runs = freeRuns(edge, in: area, avoiding: reserved)
        let capacity = runs.map { Int(((($0.hi - $0.lo) + gap) / (length + gap) + 1e-9).rounded(.down)) }

        if tucked.count > maximumTabsPerEdge || capacity.reduce(0, +) < tucked.count {
            let mid = wanted[order[order.count / 2]]
            let a: Double
            if let best = runs.min(by: { distance(mid, $0) < distance(mid, $1) }) {
                a = place(mid, best.lo, best.hi)
            } else {
                // Nothing on this edge is free: the stack stays reachable over whatever is there
                // (a window is never lost behind a control).
                let r = run(edge, in: area)
                a = place(mid, r.lo, r.hi)
            }
            return [TuckTab(ids: tucked.map(\.id), rect: rect(a), edge: edge)]
        }

        // Each handle (in order along the edge) to the free stretch nearest where it wants to be,
        // keeping enough room after it for the rest.
        var assigned = Array(repeating: [Int](), count: runs.count)
        var current = 0
        for (k, i) in order.enumerated() {
            let rest = order.count - k - 1
            var best: Int?
            for j in current..<runs.count where assigned[j].count < capacity[j] {
                let room = capacity[j] - assigned[j].count - 1 + capacity[(j + 1)...].reduce(0, +)
                guard room >= rest else { continue }
                if best.map({ distance(wanted[i], runs[j]) < distance(wanted[i], runs[$0]) }) ?? true { best = j }
            }
            let j = best ?? runs.count - 1
            assigned[j].append(i)
            current = j
        }
        // Inside each stretch: wanted places, pushed apart (forward, then back from its end).
        var out: [TuckTab] = []
        for (j, items) in assigned.enumerated() where !items.isEmpty {
            let lo = runs[j].lo, hi = runs[j].hi
            var starts = items.map { place(wanted[$0], lo, hi) }
            for n in starts.indices.dropFirst() where starts[n] < starts[n - 1] + length + gap { starts[n] = starts[n - 1] + length + gap }
            if let last = starts.last, last > hi - length {
                starts[starts.count - 1] = hi - length
                for n in starts.indices.dropLast().reversed() where starts[n] > starts[n + 1] - length - gap {
                    starts[n] = starts[n + 1] - length - gap
                }
            }
            for (i, a) in zip(items, starts) { out.append(TuckTab(ids: [tucked[i].id], rect: rect(a), edge: edge)) }
        }
        return out
    }

    /// Every tucked float's handle, on every edge (left, top, right, bottom; along each in order).
    ///
    /// Who gives way: the system's edge bands first (kept out of `area`: see `handleArea`), then
    /// the fixed controls in `reserved` (the control tray, the function tray, the shortcut column,
    /// Stage Peek's handle, folds), then the handles, which slide along their edge to the nearest
    /// free room and share one stack when their edge has no room for each. Handles on different
    /// edges never meet: the top and bottom ones stay clear of the corners.
    static func tuckHandles(_ floats: [WorkspaceFloat], area: WorkspaceRect, reserved: [WorkspaceRect] = []) -> [TuckTab] {
        [WorkspaceEdge.left, .top, .right, .bottom].flatMap { edge in
            tuckTabs(floats.compactMap { f in f.tuck.flatMap { $0.edge == edge ? (f.tile, $0.offset) : nil } },
                     edge: edge, area: area, avoiding: reserved)
        }
    }
}

// MARK: - Drag, fling and tuck

/// What happens when a float's title bar is let go: it stays, glides on with its momentum, or
/// is carried into the edge its throw reaches and tucked; and how a tucked float is pulled back
/// out. Only the receiver's presentation moves: nothing here is ever sent to the Mac as input.
enum WorkspaceFloatMotion {
    /// Deceleration per millisecond for a released float: between UIKit's `.fast` (0.99) and
    /// `.normal` (0.998), so a window carries on a little, like a thrown card, not a scroll view.
    static let decelerationRate = 0.995
    /// The deceleration a throw is projected with to see which edge it reaches: UIKit's
    /// `.normal`, what WWDC18's picture in picture uses to choose where a thrown window goes. A
    /// throw that reaches an edge this way tucks; one that doesn't glides (with the shorter
    /// carry above) and stays inside.
    static let reachDecelerationRate = 0.998
    /// Below this release speed (points/s) a float stays where it was let go.
    static let glideSpeed = 220.0
    /// A throw needs at least this release speed (points/s) to tuck: a slower move, across the
    /// middle or not, never tucks (unless the float was pulled past an edge on purpose)…
    static let flingSpeed = 1100.0
    /// …and its projected path must carry at least this share of the float past the edge (half:
    /// its centre crosses it). The same share pulled past an edge and let go tucks too.
    static let pastEdge = 0.5
    static let allEdges: Set<WorkspaceEdge> = [.left, .right, .top, .bottom]

    /// How far a release at `velocity` (points/s) carries before it stops (WWDC18, "Designing
    /// Fluid Interfaces": the projection of a decelerating throw).
    static func projection(_ velocity: Double, rate: Double = decelerationRate) -> Double {
        guard velocity.isFinite, rate > 0, rate < 1 else { return 0 }
        return velocity / 1000 * rate / (1 - rate)
    }

    enum Outcome: Equatable, Sendable {
        /// Ends at `frame` (normalized, inside the picture). `glide`: it travels there (with its
        /// momentum, or pulled back inside); otherwise it stays exactly where it was let go.
        case settle(frame: WorkspaceRect, glide: Bool)
        /// Carried into `edge` and tucked; its handle waits at `offset` along that edge.
        case tuck(edge: WorkspaceEdge, offset: Double)
    }

    /// The share of `r` past `edge` (0 while inside).
    static func past(_ r: WorkspaceRect, _ edge: WorkspaceEdge) -> Double {
        switch edge {
        case .left: return max(0, -r.x) / max(r.width, 1e-9)
        case .right: return max(0, r.maxX - 1) / max(r.width, 1e-9)
        case .top: return max(0, -r.y) / max(r.height, 1e-9)
        case .bottom: return max(0, r.maxY - 1) / max(r.height, 1e-9)
        }
    }

    /// Where along `edge` a float at `r` is (its centre, a share of that edge).
    static func along(_ r: WorkspaceRect, _ edge: WorkspaceEdge) -> Double {
        min(max(edge.axis == .horizontal ? r.midY : r.midX, 0), 1)
    }

    /// The edge `r` hangs at least `pastEdge` past (an armed tuck: letting go slowly tucks it).
    static func pulledEdge(_ r: WorkspaceRect, edges: Set<WorkspaceEdge> = allEdges) -> WorkspaceEdge? {
        [WorkspaceEdge.left, .right, .top, .bottom].first { edges.contains($0) && past(r, $0) >= pastEdge }
    }

    /// The first edge a float at `r` moving by (`dx`, `dy`) (picture shares) is carried
    /// `pastEdge` past, and where along that edge it crosses; nil when it reaches none.
    static func firstEdge(_ r: WorkspaceRect, dx: Double, dy: Double, edges: Set<WorkspaceEdge>) -> (edge: WorkspaceEdge, offset: Double)? {
        var best: (edge: WorkspaceEdge, t: Double)?
        func consider(_ edge: WorkspaceEdge, _ t: Double) {
            guard edges.contains(edge), t.isFinite, t >= 0, t <= 1, best.map({ t < $0.t }) ?? true else { return }
            best = (edge, t)
        }
        let p = pastEdge
        if dx < 0 { consider(.left, (-p * r.width - r.x) / dx) }
        if dx > 0 { consider(.right, (1 - (1 - p) * r.width - r.x) / dx) }
        if dy < 0 { consider(.top, (-p * r.height - r.y) / dy) }
        if dy > 0 { consider(.bottom, (1 - (1 - p) * r.height - r.y) / dy) }
        guard let best else { return nil }
        var at = r
        at.x += dx * best.t
        at.y += dy * best.t
        return (best.edge, along(at, best.edge))
    }

    /// `frame`: where the float is when let go (normalized; while dragging it may hang past an
    /// edge). `velocity`: its release velocity in points per second. `canTuck`: false while the
    /// float can't be tucked (it isn't a float of a live workspace). `edges`: where it may tuck
    /// (those with room for a handle, `WorkspaceFloatGeometry.tuckEdges`).
    static func decide(release frame: WorkspaceRect, velocity: (x: Double, y: Double), in size: WorkspaceSize,
                       canTuck: Bool = true, edges: Set<WorkspaceEdge> = allEdges) -> Outcome {
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0,
              [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite) else {
            return .settle(frame: WorkspaceFloatGeometry.clamped(frame, in: size), glide: false)
        }
        let vx = velocity.x.isFinite ? velocity.x : 0, vy = velocity.y.isFinite ? velocity.y : 0
        let speed = (vx * vx + vy * vy).squareRoot()
        if canTuck, !edges.isEmpty {
            // Pulled more than halfway past an edge on purpose and let go there (slowly or not,
            // as long as it isn't being thrown back in).
            for edge in [WorkspaceEdge.left, .right, .top, .bottom] where edges.contains(edge) && past(frame, edge) >= pastEdge {
                let inward: Double
                switch edge {
                case .left: inward = vx
                case .right: inward = -vx
                case .top: inward = vy
                case .bottom: inward = -vy
                }
                if inward < flingSpeed { return .tuck(edge: edge, offset: along(frame, edge)) }
            }
            // Thrown: fast enough, and its projected path carries it past an edge (from the
            // middle or from the far side alike): tucked into the first edge that path crosses,
            // where it crosses it. A corner throw takes whichever edge it meets first.
            if speed >= flingSpeed,
               let hit = firstEdge(frame, dx: projection(vx, rate: reachDecelerationRate) / size.width,
                                   dy: projection(vy, rate: reachDecelerationRate) / size.height, edges: edges) {
                return .tuck(edge: hit.edge, offset: hit.offset)
            }
        }
        let held = WorkspaceFloatGeometry.clamped(frame, in: size)
        guard speed >= glideSpeed else { return .settle(frame: snapped(held, in: size), glide: snapped(held, in: size) != frame) }
        var target = frame
        target.x += projection(vx) / size.width
        target.y += projection(vy) / size.height
        let landed = snapped(WorkspaceFloatGeometry.clamped(target, in: size), in: size)
        return .settle(frame: landed, glide: landed != frame)
    }

    /// Close to an edge of the picture (within `WorkspaceFloatGeometry.snap` points): flush with it.
    static func snapped(_ r: WorkspaceRect, in size: WorkspaceSize) -> WorkspaceRect {
        guard size.width > 0, size.height > 0 else { return r }
        var c = r
        let sx = WorkspaceFloatGeometry.snap / size.width, sy = WorkspaceFloatGeometry.snap / size.height
        let bar = min(WorkspaceFloatGeometry.barHeight / size.height, 0.5)
        if c.x > 0, c.x < sx { c.x = 0 }
        if c.maxX < 1, 1 - c.maxX < sx { c.x = 1 - c.width }
        if c.y > bar, c.y - bar < sy { c.y = bar }
        if c.maxY < 1, 1 - c.maxY < sy { c.y = 1 - c.height }
        return c
    }

    /// Just past `edge`, so none of it (nor its title pill) shows: where a tucked float slides to
    /// while it hides and comes back from. `along`: centred there along the edge (a share of
    /// it, where its handle is or where its throw crossed); nil: where it is.
    static func hiddenFrame(_ frame: WorkspaceRect, edge: WorkspaceEdge, along: Double? = nil) -> WorkspaceRect {
        var r = frame
        switch edge {
        case .left: r.x = -r.width - 0.02
        case .right: r.x = 1.02
        case .top: r.y = -r.height - 0.06
        case .bottom: r.y = 1.04
        }
        if let a = along, a.isFinite {
            if edge.axis == .horizontal { r.y = a - r.height / 2 } else { r.x = a - r.width / 2 }
        }
        return r
    }

    // MARK: Pulling a tucked float back out

    /// Share of the way out (from hidden to where it was) past which letting go of a pull brings
    /// the float back; short of it, it slides back into its edge.
    static let restoreProgress = 0.4

    /// How far out a tucked float is (0 hidden … 1 back where it was) while a finger pulls it
    /// from its handle, its inner edge under the finger: `finger` is the finger's place across
    /// the edge (a share of the picture's width for the left and right edges, of its height for
    /// the top and bottom). Not clamped above 1.
    static func pullProgress(finger: Double, frame: WorkspaceRect, edge: WorkspaceEdge) -> Double {
        guard finger.isFinite else { return 0 }
        let hidden = hiddenFrame(frame, edge: edge)
        let (inner0, inner1): (Double, Double)
        switch edge {
        case .left: (inner0, inner1) = (hidden.maxX, frame.maxX)
        case .right: (inner0, inner1) = (hidden.x, frame.x)
        case .top: (inner0, inner1) = (hidden.maxY, frame.maxY)
        case .bottom: (inner0, inner1) = (hidden.y, frame.y)
        }
        let travel = inner1 - inner0
        guard abs(travel) > 1e-9 else { return 1 }
        return max(0, (finger - inner0) / travel)
    }

    /// Points a pulled float travels from hidden to where it was.
    static func pullTravel(_ frame: WorkspaceRect, edge: WorkspaceEdge, in size: WorkspaceSize) -> Double {
        let hidden = hiddenFrame(frame, edge: edge)
        return edge.axis == .horizontal ? abs(frame.x - hidden.x) * size.width : abs(frame.y - hidden.y) * size.height
    }

    /// Where a tucked float is drawn `progress` of the way out of its edge: from hidden at its
    /// handle (`handle`, a share along the edge) to its own frame, in a straight line.
    static func pulledFrame(_ frame: WorkspaceRect, edge: WorkspaceEdge, handle: Double, progress: Double) -> WorkspaceRect {
        let from = hiddenFrame(frame, edge: edge, along: handle)
        let t = progress.isFinite ? min(max(progress, 0), 1) : 0
        return WorkspaceRect(x: from.x * (1 - t) + frame.x * t, y: from.y * (1 - t) + frame.y * t,
                             width: frame.width, height: frame.height)
    }

    /// A pull let go `progress` of the way out at `inwardVelocity` (points/s, positive away from
    /// the edge), with `travel` points from hidden to its frame: true brings it back (projected
    /// like a throw, so a flick outward restores it early); false slides it back in. Pushed back
    /// toward the edge, it always goes back.
    static func pullRestores(progress: Double, inwardVelocity: Double, travel: Double) -> Bool {
        guard progress.isFinite, travel.isFinite, travel > 0 else { return false }
        let v = inwardVelocity.isFinite ? inwardVelocity : 0
        if v <= -glideSpeed { return false }
        return progress + max(0, projection(v)) / travel >= restoreProgress
    }

    /// A critically damped spring from `from` toward `to`, starting at `velocity` (units/s):
    /// its value and velocity after `t` seconds. Continuous with the finger's release velocity,
    /// so the motion carries on from the gesture instead of starting a canned slide; it can be
    /// caught at any moment (the value at "now" is where a new drag starts).
    static func spring(from: Double, to: Double, velocity: Double, t: Double, response: Double = 0.42) -> (value: Double, velocity: Double) {
        guard t > 0, response > 0, from.isFinite, to.isFinite, velocity.isFinite else { return (from, velocity) }
        let w = 2 * Double.pi / response
        let x0 = from - to
        let c = velocity + w * x0
        let e = exp(-w * t)
        return (to + (x0 + c * t) * e, (velocity - w * c * t) * e)
    }
}

// MARK: - Chrome layering (receiver)

/// The receiver draws every outline, title pill and handle in one layer above the video, while
/// each float's window is pixels inside the video. So the chrome of anything behind a float must
/// step aside where that float is, or it shows through it: a pane's outline through a float, a
/// back float's grips and title over the front one. All rects here are picture points.
enum WorkspaceFloatLayering {
    /// The title pill straddles the float's top edge (half above it): what a float covers reaches
    /// this far above its content, so the pill hides what's behind it too.
    static let pillReach = 16.0
    /// Height of the title pill's touch area.
    static let pillHeight = 30.0

    /// What a shown float hides behind it: its content and the band its title pill sits in.
    static func occluder(_ content: WorkspaceRect) -> WorkspaceRect {
        WorkspaceRect(x: content.x, y: content.y - pillReach, width: content.width, height: content.height + pillReach)
    }

    /// The title pill's largest extent for a float of `content` (it is never wider than this).
    static func pillBounds(_ content: WorkspaceRect) -> WorkspaceRect {
        let w = max(min(content.width - 28, 280), 90) + 34
        return WorkspaceRect(x: content.midX - w / 2, y: content.y - pillHeight / 2, width: w, height: pillHeight)
    }

    /// For each float (back to front), what the floats in front of it cover.
    static func covers(backToFront floats: [WorkspaceRect]) -> [[WorkspaceRect]] {
        floats.indices.map { i in floats[(i + 1)...].map(occluder) }
    }

    /// Whether `r` meets any of `covers` by more than a sliver (`tolerance` points each way).
    static func isCovered(_ r: WorkspaceRect, by covers: [WorkspaceRect], tolerance: Double = 0.5) -> Bool {
        covers.contains { c in
            guard let i = r.intersection(c) else { return false }
            return i.width > tolerance && i.height > tolerance
        }
    }

    /// The parts of a straight strip (a divider's touch area) that no float covers, each at least
    /// `minLength` long: a divider stays draggable where it's visible and never takes a touch
    /// meant for a float drawn over it.
    static func uncovered(_ strip: WorkspaceRect, alongX: Bool, by covers: [WorkspaceRect], minLength: Double = 24) -> [WorkspaceRect] {
        var free: [(Double, Double)] = [alongX ? (strip.x, strip.maxX) : (strip.y, strip.maxY)]
        for c in covers {
            guard strip.intersection(c) != nil else { continue }
            let lo = alongX ? c.x : c.y, hi = alongX ? c.maxX : c.maxY
            free = free.flatMap { seg -> [(Double, Double)] in
                guard hi > seg.0, lo < seg.1 else { return [seg] }
                return [(seg.0, min(lo, seg.1)), (max(hi, seg.0), seg.1)].filter { $0.1 > $0.0 }
            }
        }
        return free.filter { $0.1 - $0.0 >= minLength }.map { seg in
            alongX ? WorkspaceRect(x: seg.0, y: strip.y, width: seg.1 - seg.0, height: strip.height)
                   : WorkspaceRect(x: strip.x, y: seg.0, width: strip.width, height: seg.1 - seg.0)
        }
    }

    /// Resize grips and the bottom grabber show only while they're useful: on the selected float,
    /// under the pointer, or while a finger moves or resizes it. Elsewhere they would clutter the
    /// picture and take touches meant for the windows around them.
    static func showsHandles(selected: Bool, hovered: Bool, manipulating: Bool) -> Bool {
        selected || hovered || manipulating
    }
}

// MARK: - Occlusion (Mac capture budget)

enum WorkspaceOcclusion {
    /// The share of `rect` that `covers` hide, sampled on a 16 x 16 grid: exact enough to lower
    /// the frame rate of a pane that floats hide almost entirely.
    static func coveredFraction(of rect: WorkspaceRect, by covers: [WorkspaceRect]) -> Double {
        guard rect.width > 0, rect.height > 0, !covers.isEmpty else { return 0 }
        let n = 16
        var hidden = 0
        for i in 0..<n {
            for j in 0..<n {
                let p = WorkspacePoint(x: rect.x + (Double(i) + 0.5) / Double(n) * rect.width,
                                       y: rect.y + (Double(j) + 0.5) / Double(n) * rect.height)
                if covers.contains(where: { $0.contains(p) }) { hidden += 1 }
            }
        }
        return Double(hidden) / Double(n * n)
    }
}

// MARK: - Circling while holding (switch a drag between Pane and Floating)

/// Switches a drag between Pane and Floating placement: about two seconds of drawing circles
/// while holding (like winding a dial), so it never happens by accident. Replaces the shake,
/// which fired on any quick back-and-forth.
///
/// It follows the direction the finger (or pointer) travels: a loop turns that direction by a
/// full turn, always the same way round. It counts only steps that curve, all one way, around
/// loops of a plausible size; a sharp reversal (a shake, a zig-zag), a turn the other way, a
/// straight move or a pause starts over. After it fires it stays quiet until the circling stops
/// (a pause, or a straight move), so circling on never switches back and forth. `progress`
/// (0...1) is for the ring drawn at the finger. Pure: the same samples always decide the same.
struct WorkspaceCircleGesture: Equatable, Sendable {
    /// Net turning that makes the gesture: one and three-quarter loops.
    var requiredTurn = 1.75 * 2 * Double.pi
    /// And at least this long circling (seconds): about two seconds in all at an easy pace.
    var minimumDuration = 1.5
    /// Loop radius (points) that counts: smaller is a wobble, larger is a long curve.
    var minRadius = 12.0
    var maxRadius = 240.0
    /// Samples closer than this to the last one count together (touch jitter).
    var minStep = 3.0
    /// One step turning more than this (about 100°) is a reversal: starts over.
    var maxStepTurn = 1.75
    /// This long without a curving step (a pause or a straight move) starts over and, after a
    /// switch, lets the next one count.
    var quiet = 0.4
    /// Share of the turning that must go one way round.
    var consistency = 0.8

    private var lastX: Double?
    private var lastY: Double?
    private var heading: Double?
    /// This run: signed and total turning, path length, when it began, its last curving step.
    private var net = 0.0
    private var total = 0.0
    private var length = 0.0
    private var started: Double?
    private var lastCurve = -Double.infinity
    /// False from a switch until the circling stops.
    private(set) var armed = true
    /// How far along the current circling is (0...1); 0 while it doesn't count.
    private(set) var progress = 0.0

    init() {}

    /// Starts over (a new drag).
    mutating func reset() { self = WorkspaceCircleGesture(tuning: self) }

    private init(tuning t: WorkspaceCircleGesture) {
        requiredTurn = t.requiredTurn; minimumDuration = t.minimumDuration
        minRadius = t.minRadius; maxRadius = t.maxRadius; minStep = t.minStep
        maxStepTurn = t.maxStepTurn; quiet = t.quiet; consistency = t.consistency
    }

    private mutating func endRun() {
        net = 0; total = 0; length = 0; started = nil; progress = 0
    }

    /// Whether the circling has gone quiet at `t` (for fading the ring when no samples come).
    func isQuiet(at t: Double) -> Bool { t - lastCurve > quiet }

    /// One finger position (points) at time `t` (seconds). True once per gesture.
    mutating func add(x: Double, y: Double, at t: Double) -> Bool {
        guard x.isFinite, y.isFinite, t.isFinite else { return false }
        if isQuiet(at: t) {
            if started != nil { endRun() }
            armed = true
        }
        guard let lx = lastX, let ly = lastY else { lastX = x; lastY = y; return false }
        let dx = x - lx, dy = y - ly
        let d = (dx * dx + dy * dy).squareRoot()
        guard d >= minStep else { return false }
        lastX = x; lastY = y
        let h = atan2(dy, dx)
        defer { heading = h }
        guard let h0 = heading else { return false }
        var turn = h - h0
        if turn > .pi { turn -= 2 * .pi } else if turn <= -.pi { turn += 2 * .pi }
        if abs(turn) > maxStepTurn {
            endRun()
            return false
        }
        // A step curves when it turns at least as tightly as the largest loop that counts.
        if abs(turn) / d >= 1 / maxRadius {
            if started == nil { started = t }
            lastCurve = t
        }
        guard let begin = started else { return false }
        net += turn
        total += abs(turn)
        length += d
        let consistent = total > 0 && abs(net) / total >= consistency
        if !consistent, total > .pi {
            // Turning both ways round (a figure eight, a wiggle): not a circle.
            endRun()
            return false
        }
        let radius = length / max(abs(net), 1e-9)
        let plausible = abs(net) < .pi || (radius >= minRadius && radius <= maxRadius)
        guard armed, consistent, plausible else { progress = 0; return false }
        progress = min(abs(net) / requiredTurn, (t - begin) / minimumDuration, 1)
        guard progress >= 1 else { return false }
        armed = false
        endRun()
        return true
    }
}
