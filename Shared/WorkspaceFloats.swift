import Foundation

// Floating panes: Window mode panes that float above the tiled panes (or above a Full Desktop
// pane), may overlap, can be tucked to the left or right edge and turned back into panes.
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

/// Where a tucked float waits: on the left or right edge, its tab centred at `offset` (0 = top
/// of the picture, 1 = bottom). Its frame is kept, so it comes back exactly where it was.
struct WorkspaceFloatTuck: Equatable, Sendable {
    /// `.left` or `.right` only (the top and bottom edges belong to the system's own gestures).
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
            if t.edge.axis != .horizontal { t.edge = .right }
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

    /// Hidden to an edge: it keeps its frame and its place in the workspace; nothing happens to
    /// the Mac window. Its capture stops while it isn't sent.
    func tuckingFloat(_ id: String, edge: WorkspaceEdge, offset: Double) -> WorkspaceLayout {
        guard edge.axis == .horizontal, let i = floats.firstIndex(where: { $0.tile == id }) else { return self }
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

    /// Visible floats at a time: one on a compact screen (a phone, or an iPad in a narrow
    /// window), as many as the workspace holds otherwise. More are kept tucked, never closed.
    static func visibleLimit(for size: WorkspaceSize) -> Int {
        WorkspaceSizeClass.of(size) == .compact ? 1 : WorkspaceLayout.maximumTiles
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

    /// Where a new float opens. `aspect`: the window's width / height when known. `index`: how
    /// many floats are already shown (each new one cascades). `center`: where it was dropped.
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
        let step = Double(index) * cascade
        var x: Double, y: Double
        if let c = center {
            x = c.x * size.width - w / 2; y = c.y * size.height - h / 2
        } else if compact && portrait {
            x = (size.width - w) / 2; y = size.height - h - 24 - step
        } else if compact {
            x = size.width - w - 24 - step; y = size.height - h - 24 - step
        } else {
            x = size.width * 0.5 - w / 2 + step; y = size.height * 0.18 + step
        }
        return clamped(WorkspaceRect(x: x / size.width, y: y / size.height, width: w / size.width, height: h / size.height), in: size)
    }

    /// The floats as shown in this space: each kept usable (clamped), and on a compact screen
    /// only one shown (the active one if it floats, else the frontmost): the rest wait tucked.
    /// `shown` false (the Mac can't draw floats): all of them wait tucked.
    static func fitted(_ floats: [WorkspaceFloat], in size: WorkspaceSize, active: String?, shown: Bool = true) -> [WorkspaceFloat] {
        var out = floats.map { f -> WorkspaceFloat in
            var c = f
            c.frame = clamped(f.frame, in: size)
            return c
        }
        func tuck(_ i: Int) {
            guard out[i].tuck == nil else { return }
            let count = out.filter { $0.tuck?.edge == .right }.count
            out[i].tuck = WorkspaceFloatTuck(edge: .right, offset: min(0.3 + Double(count) * 0.12, 0.85))
        }
        guard shown else {
            for i in out.indices { tuck(i) }
            return out
        }
        let limit = visibleLimit(for: size)
        let visible = out.indices.filter { out[$0].tuck == nil }
        guard visible.count > limit else { return out }
        var keep = Array(visible.suffix(limit))
        if let active, let a = visible.first(where: { out[$0].tile == active }), !keep.contains(a) {
            keep[keep.count - 1] = a
        }
        for i in visible where !keep.contains(i) { tuck(i) }
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

    // MARK: Tucked tabs

    /// One handle on an edge: a single tucked float, or several collapsed into a stack.
    struct TuckTab: Equatable, Sendable {
        /// Back to front as tucked; more than one = a stack (opens a list).
        var ids: [String]
        /// In points, in the picture's coordinates.
        var rect: WorkspaceRect
        var isStack: Bool { ids.count > 1 }
    }

    /// Tab size (points): narrow, tall enough for a thumb, 44 pt along the edge at least.
    static let tabSize = WorkspaceSize(width: 30, height: 60)
    static let tabSpacing = 8.0
    /// The top and bottom of an edge are left to the system (Control Center, the Home indicator,
    /// notification and app switching gestures): tabs stay within the middle of it.
    static let tabBand = 0.12

    /// The handles on one edge of `area` (points). `tucked`: (id, offset) in tuck order. One tab
    /// each, near its offset without overlapping, while they fit; otherwise one stack.
    static func tuckTabs(_ tucked: [(id: String, offset: Double)], edge: WorkspaceEdge, area: WorkspaceRect) -> [TuckTab] {
        guard !tucked.isEmpty, area.width > 0, area.height > 0 else { return [] }
        let top = area.y + area.height * tabBand, bottom = area.maxY - area.height * tabBand
        let band = max(bottom - top, tabSize.height)
        let x = edge == .left ? area.x : area.maxX - tabSize.width
        let h = tabSize.height, gap = tabSpacing
        let needed = Double(tucked.count) * h + Double(tucked.count - 1) * gap
        func rect(_ y: Double) -> WorkspaceRect { WorkspaceRect(x: x, y: y, width: tabSize.width, height: h) }
        if needed > band || tucked.count > 4 {
            let mid = tucked.map(\.offset).sorted()[tucked.count / 2]
            let y = min(max(area.y + mid * area.height - h / 2, top), top + band - h)
            return [TuckTab(ids: tucked.map(\.id), rect: rect(y))]
        }
        // Wanted places, top to bottom; then pushed apart (down, then back up from the bottom).
        let order = tucked.enumerated().sorted { ($0.element.offset, $0.offset) < ($1.element.offset, $1.offset) }
        var ys = order.map { min(max(area.y + $0.element.offset * area.height - h / 2, top), top + band - h) }
        for i in ys.indices.dropFirst() where ys[i] < ys[i - 1] + h + gap { ys[i] = ys[i - 1] + h + gap }
        if let last = ys.last, last > top + band - h {
            ys[ys.count - 1] = top + band - h
            for i in ys.indices.dropLast().reversed() where ys[i] > ys[i + 1] - h - gap { ys[i] = ys[i + 1] - h - gap }
        }
        return zip(order, ys).map { TuckTab(ids: [$0.element.id], rect: rect($1)) }
    }
}

// MARK: - Drag, fling and tuck

/// What happens when a float's title bar is let go: it stays, glides on with its momentum, or
/// is carried into the edge it was flung at and tucked. Only the receiver's presentation moves:
/// nothing here is ever sent to the Mac as input.
enum WorkspaceFloatMotion {
    /// Deceleration per millisecond for a released float: between UIKit's `.fast` (0.99) and
    /// `.normal` (0.998), so a window carries on a little, like a thrown card, not a scroll view.
    static let decelerationRate = 0.995
    /// Below this release speed (points/s) a float stays where it was let go.
    static let glideSpeed = 220.0
    /// A fling toward an edge needs at least this speed (points/s)…
    static let flingSpeed = 1100.0
    /// …mostly sideways (the cosine of its angle to the edge's normal)…
    static let flingCosine = 0.8
    /// …must carry at least this share of the float past the edge…
    static let pastEdge = 0.5
    /// …and be let go on that edge's side of the picture (its centre past this share of the
    /// width from the far side), so a fast move across the middle never hides a float.
    static let releaseSide = 0.55

    /// How far a release at `velocity` (points/s) carries before it stops (WWDC18, "Designing
    /// Fluid Interfaces": the projection of a decelerating throw).
    static func projection(_ velocity: Double) -> Double {
        guard velocity.isFinite else { return 0 }
        return velocity / 1000 * decelerationRate / (1 - decelerationRate)
    }

    enum Outcome: Equatable, Sendable {
        /// Ends at `frame` (normalized, inside the picture). `glide`: it travels there (with its
        /// momentum, or pulled back inside); otherwise it stays exactly where it was let go.
        case settle(frame: WorkspaceRect, glide: Bool)
        /// Carried into `edge` and tucked; its tab waits at `offset`.
        case tuck(edge: WorkspaceEdge, offset: Double)
    }

    /// `frame`: where the float is when let go (normalized; while dragging it may hang past an
    /// edge). `velocity`: its release velocity in points per second. `canTuck`: false while the
    /// float can't be tucked (it isn't a float of a live workspace).
    static func decide(release frame: WorkspaceRect, velocity: (x: Double, y: Double), in size: WorkspaceSize,
                       canTuck: Bool = true) -> Outcome {
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0,
              [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite) else {
            return .settle(frame: WorkspaceFloatGeometry.clamped(frame, in: size), glide: false)
        }
        let vx = velocity.x.isFinite ? velocity.x : 0, vy = velocity.y.isFinite ? velocity.y : 0
        let offset = min(max(frame.midY, 0), 1)
        func past(_ r: WorkspaceRect, _ edge: WorkspaceEdge) -> Double {
            (edge == .left ? max(0, -r.x) : max(0, r.maxX - 1)) / r.width
        }
        if canTuck {
            // Pulled more than halfway past an edge on purpose and let go there (slowly or not,
            // as long as it isn't being thrown back in).
            for edge in [WorkspaceEdge.left, .right] where past(frame, edge) >= pastEdge {
                let inward = edge == .left ? vx : -vx
                if inward < flingSpeed { return .tuck(edge: edge, offset: offset) }
            }
            // Flung at an edge: fast, mostly sideways, let go on that side, carried past it.
            let speed = (vx * vx + vy * vy).squareRoot()
            if speed >= flingSpeed, abs(vx) / speed >= flingCosine {
                let edge: WorkspaceEdge = vx < 0 ? .left : .right
                let onSide = edge == .left ? frame.midX <= 1 - releaseSide : frame.midX >= releaseSide
                var projected = frame
                projected.x += projection(vx) / size.width
                projected.y += projection(vy) / size.height
                if onSide, past(projected, edge) >= pastEdge {
                    return .tuck(edge: edge, offset: min(max(projected.midY, 0), 1))
                }
            }
        }
        let held = WorkspaceFloatGeometry.clamped(frame, in: size)
        let speed = (vx * vx + vy * vy).squareRoot()
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

    /// Where a tucked float slides to while it hides: just past its edge, at its height.
    static func hiddenFrame(_ frame: WorkspaceRect, edge: WorkspaceEdge) -> WorkspaceRect {
        var r = frame
        r.x = edge == .left ? -r.width - 0.02 : 1.02
        return r
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

/// Switches a drag between Pane and Floating placement: drawing a circle and a bit while holding
/// (like winding a dial), about a second at an easy pace. Recognising a circle and rearming after
/// a switch are separate rules, and neither is a timer. Pure: the same samples always decide the
/// same. Works the same with a pointer.
///
/// The path is measured in 8 pt chords (`minStep`), so touch jitter doesn't count. The stretch it
/// judges is the shortest recent one whose heading turned one and a quarter loops one way round
/// (`requiredTurn`), never reaching back past a turn the other way of more than 90°.
///
/// Recognising. It switches only when that stretch is a deliberate loop, all of:
/// - a least-squares circle through its points has a radius of 12-150 pt (`minRadius`,
///   `maxRadius`) and they stay close to it (RMS off it at most 25 % of the radius, `fitTolerance`);
/// - they go round that centre the same way (at least 85 % of the heading's turning, at most
///   10 % of the steps backwards), and the heading keeps turning that way: measured over 16 pt,
///   at least 80 % of its turning is one way round (`steadiness`; a scribble's isn't);
/// - the path is at most 1.35 times as long as the circle it winds round (`compactness`): no
///   straight runs or detours;
/// - it closes: where the heading was the same one loop back, the finger was within half the
///   radius + 4 pt of where it is now (`closeTolerance`), so loops that travel across the screen
///   don't count;
/// - its last loop is round: 4πA/L² at least 0.6 (`roundness`; a 2:1 ellipse is 0.84, a stretched
///   4:1 oval 0.54);
/// - and it has been plausibly circling for at least `minimumDuration` (1 s).
/// A step turning more than about 100° (`maxStepTurn`: a shake, a zig-zag's corner) or a rest
/// (no 8 pt of travel for `quiet`, 0.3 s) starts the path over.
///
/// `progress` (0...1, the ring at the finger) is above 0 only while the stretch is plausibly a
/// circle (the first three rules, once it has turned `showTurn`, five eighths of a loop) and that
/// way round can switch; it fills to 1 at the switch.
///
/// Rearming. A switch starts the path over from that point, so the next circle is built only from
/// motion after it, and the way round that switched (`latched`) can't switch again until that
/// circling stops: the finger rests or turns sharply, turns the other way by 90°, goes 1.5 radii
/// + 16 pt from the circle's centre, or travels three radii without going a quarter of the way
/// round it (`stallRadii`). While it goes on circling, the circle it follows may drift (the same
/// size, nearby). So circling on never switches back and forth; a circle the other way round
/// switches as soon as it's complete; the same way round, once the finger has stopped, moved on
/// or turned away.
struct WorkspaceCircleGesture: Equatable, Sendable {
    /// Which way round, on screen (y down).
    enum Turn: Equatable, Sendable { case clockwise, counterclockwise }

    /// Heading turned one way round by the stretch judged: one and a quarter loops.
    var requiredTurn = 1.25 * 2 * Double.pi
    /// And at least this long plausibly circling (seconds): about a second at an easy pace.
    var minimumDuration = 1.0
    /// Loop radius (points) that counts: smaller is a wobble, larger is a long curve.
    var minRadius = 12.0
    var maxRadius = 150.0
    /// The path is measured in chords this long, so a fraction of a point of touch jitter can't
    /// turn a circle into a zig-zag.
    var minStep = 8.0
    /// One step turning more than this (about 100°) is a sharp turn: starts over.
    var maxStepTurn = 1.75
    /// This long without 8 pt of travel is a rest: starts over (and rearms either way round).
    var quiet = 0.3
    /// RMS distance off the fitted circle, as a share of its radius.
    var fitTolerance = 0.25
    /// Path length at most this many times the turning times the radius.
    var compactness = 1.35
    /// How far from closing one loop back, as a share of the radius (+ 4 pt).
    var closeTolerance = 0.5
    /// The last loop's 4πA/L² (1 for a circle).
    var roundness = 0.6
    /// Share of the heading's turning, over 16 pt steps, that goes the one way round.
    var steadiness = 0.8
    /// Turning before the ring shows (five eighths of a loop).
    var showTurn = 1.25 * Double.pi
    /// Rearming the way round that switched: this many radii (+ 16 pt) from its centre, or this
    /// many radii of travel without a quarter of the way round it.
    var leaveRadii = 1.5
    var stallRadii = 3.0

    private struct Point: Equatable, Sendable {
        var x, y, t: Double
        /// Unwrapped heading of the chord that ends here (unused for the first point).
        var heading: Double
        /// Path length up to here.
        var length: Double
    }
    private struct Circle: Equatable, Sendable { var x, y, r: Double }

    /// The path since it last started over, in chords (at most `capacity` of them).
    private var path: [Point] = []
    private static let capacity = 180
    /// When the current plausible circling began.
    private var since: Double?
    /// The way round that switched last, the circle it follows, and that circle's radius then.
    private(set) var latched: Turn?
    private var latchedCircle: Circle?
    private var latchedRadius = 0.0
    /// How far along the current circling is (0...1); 0 while it doesn't count.
    private(set) var progress = 0.0

    /// Whether a circle either way round can switch now (nothing latched).
    var armed: Bool { latched == nil }

    init() {}

    /// Starts over (a new drag).
    mutating func reset() { self = WorkspaceCircleGesture(tuning: self) }

    private init(tuning t: WorkspaceCircleGesture) {
        requiredTurn = t.requiredTurn; minimumDuration = t.minimumDuration
        minRadius = t.minRadius; maxRadius = t.maxRadius; minStep = t.minStep
        maxStepTurn = t.maxStepTurn; quiet = t.quiet; fitTolerance = t.fitTolerance
        compactness = t.compactness; closeTolerance = t.closeTolerance; roundness = t.roundness; steadiness = t.steadiness
        showTurn = t.showTurn; leaveRadii = t.leaveRadii; stallRadii = t.stallRadii
    }

    /// Whether the finger has rested at `t` (no 8 pt of travel for `quiet`), for fading the ring
    /// when no samples come.
    func isQuiet(at t: Double) -> Bool { t - (path.last?.t ?? -.infinity) > quiet }

    /// One finger position (points) at time `t` (seconds). True once per switch.
    mutating func add(x: Double, y: Double, at t: Double) -> Bool {
        guard x.isFinite, y.isFinite, t.isFinite else { return false }
        guard let last = path.last else {
            path = [Point(x: x, y: y, t: t, heading: 0, length: 0)]
            return false
        }
        let dx = x - last.x, dy = y - last.y
        let d = (dx * dx + dy * dy).squareRoot()
        guard d >= minStep else {
            if t - last.t >= quiet { progress = 0 }   // resting: the ring goes
            return false
        }
        if t - last.t >= quiet {
            // The finger stopped (or crawled): a new gesture from here, either way round.
            restart(Point(x: last.x, y: last.y, t: t, heading: 0, length: 0))
            unlatch()
        }
        let h = atan2(dy, dx)
        var heading = h
        if path.count > 1 {
            let previous = path[path.count - 1]
            let turn = Self.wrapped(h - previous.heading)
            if abs(turn) > maxStepTurn {
                // A sharp turn (a shake, a zig-zag's corner): starts over from the corner.
                restart(Point(x: previous.x, y: previous.y, t: previous.t, heading: 0, length: 0))
                path.append(Point(x: x, y: y, t: t, heading: h, length: d))
                progress = 0
                unlatch()
                return false
            }
            heading = previous.heading + turn
        }
        path.append(Point(x: x, y: y, t: t, heading: heading, length: path[path.count - 1].length + d))
        if path.count > Self.capacity { path.removeFirst(path.count - Self.capacity) }
        return evaluate(at: t)
    }

    // MARK: Recognising

    private mutating func evaluate(at t: Double) -> Bool {
        guard let w = window() else { progress = 0; since = nil; return false }
        let turned = abs(w.turn)
        rearm(w.way, turned: turned)
        guard turned >= showTurn, let judged = judge(w) else { progress = 0; since = nil; return false }
        let start = since ?? path[w.start].t
        since = start
        if latched == w.way {
            // Still circling the way that switched: no ring, no switch. Follow that circle as it
            // drifts (the same size, nearby), so it's still the one the finger is going round.
            if let c = latchedCircle, hypot(judged.circle.x - c.x, judged.circle.y - c.y) <= 0.5 * latchedRadius + 8,
               (0.75...1.33).contains(judged.circle.r / latchedRadius) {
                latchedCircle = judged.circle
            }
            progress = 0
            return false
        }
        let turnPart = min((turned - showTurn) / (requiredTurn - showTurn), 1)
        let timePart = minimumDuration > 0 ? min((t - start) / minimumDuration, 1) : 1
        progress = max(min(turnPart, timePart, judged.deliberate ? 1 : 0.97), 0)
        guard judged.deliberate, timePart >= 1 else { return false }
        // Switch. The next circle is built only from what comes after this point.
        progress = 0
        latched = w.way
        latchedCircle = judged.circle
        latchedRadius = judged.circle.r
        restart(Point(x: path[path.count - 1].x, y: path[path.count - 1].y, t: path[path.count - 1].t, heading: 0, length: 0))
        return true
    }

    /// The stretch to judge: from `start` to the newest point, its signed turning and which way
    /// round. Complete once it has turned `requiredTurn`; until then (a partial loop) from where
    /// it had already turned almost all of it, so a straight lead-in isn't judged with it.
    private func window() -> (start: Int, turn: Double, way: Turn, complete: Bool)? {
        let n = path.count - 1
        guard n >= 2 else { return nil }
        let newest = path[n].heading
        var sign = 0.0, peak = 0.0, peakAt = n - 1
        var k = n - 1
        while k >= 0 {
            let turned = newest - path[k + 1].heading
            if sign == 0, abs(turned) >= .pi / 4 { sign = turned > 0 ? 1 : -1 }
            if sign != 0 {
                let v = turned * sign
                if v >= requiredTurn { return (k, turned, Self.turn(sign), true) }
                if v > peak + 1e-9 { peak = v; peakAt = k } else if v < peak - .pi / 2 { break }
            }
            k -= 1
        }
        guard sign != 0 else { return nil }
        var start = peakAt
        while start + 1 < n, (newest - path[start + 2].heading) * sign >= peak - 0.15 { start += 1 }
        return (start, newest - path[start + 1].heading, Self.turn(sign), false)
    }

    /// Whether the stretch plausibly is a loop (else nil), and, once complete, a deliberate one.
    private func judge(_ w: (start: Int, turn: Double, way: Turn, complete: Bool)) -> (circle: Circle, deliberate: Bool)? {
        let n = path.count - 1
        let points = path[w.start...n]
        let turned = abs(w.turn)
        let sign = Self.sign(w.way)
        guard let fit = Self.fitCircle(points), fit.circle.r >= minRadius, fit.circle.r <= maxRadius,
              fit.rms <= fitTolerance * fit.circle.r else { return nil }
        let round = Self.winding(points, around: fit.circle, sign: sign)
        guard round.angle >= 0.85 * turned, round.backwards <= 0.1 else { return nil }
        guard path[n].length - path[w.start].length <= compactness * fit.circle.r * turned + 2 * minStep else { return nil }
        // One way round all along: over 16 pt (two chords) the heading hardly ever turns back.
        var total = 0.0, i = w.start + 1
        while i + 2 <= n { total += abs(path[i + 2].heading - path[i].heading); i += 2 }
        total += abs(path[n].heading - path[i].heading)
        guard turned / max(total, 1e-9) >= steadiness else { return nil }
        guard w.complete, let closing = closure(sign: sign), closing.gap <= closeTolerance * fit.circle.r + 4 else {
            return (fit.circle, false)
        }
        return (fit.circle, Self.isoperimetric(path[closing.from...n]) >= roundness)
    }

    /// How far the finger is from where it was one full turn of heading back (the last chord's
    /// middle against the point a loop back where the heading was the same, between chord
    /// middles), and where that loop begins. A closed loop: about 0; a travelling one: how far it went.
    private func closure(sign: Double) -> (gap: Double, from: Int)? {
        let n = path.count - 1
        guard n >= 3 else { return nil }
        let newest = path[n].heading
        let mx = (path[n].x + path[n - 1].x) / 2, my = (path[n].y + path[n - 1].y) / 2
        var i = n - 1
        while i >= 2 {
            let a = (newest - path[i].heading) * sign, b = (newest - path[i - 1].heading) * sign
            if a < 2 * .pi, 2 * .pi <= b {
                let u = (2 * .pi - a) / max(b - a, 1e-9)
                let x0 = (path[i].x + path[i - 1].x) / 2, y0 = (path[i].y + path[i - 1].y) / 2
                let x1 = (path[i - 1].x + path[i - 2].x) / 2, y1 = (path[i - 1].y + path[i - 2].y) / 2
                return (hypot(mx - (x0 + (x1 - x0) * u), my - (y0 + (y1 - y0) * u)), i - 1)
            }
            i -= 1
        }
        return nil
    }

    // MARK: Rearming

    /// Whether the circling that switched has stopped (see the type's notes): then either way
    /// round can switch again.
    private mutating func rearm(_ way: Turn, turned: Double) {
        guard let latched, let c = latchedCircle else { return }
        let n = path.count - 1
        if way != latched, turned >= .pi / 2 {
            unlatch()   // turned the other way
        } else if hypot(path[n].x - c.x, path[n].y - c.y) > leaveRadii * c.r + 16 {
            unlatch()   // left the circle
        } else if let round = roundSince(c, sign: Self.sign(latched), over: stallRadii * c.r), round < .pi / 2 {
            unlatch()   // no longer going round it
        }
    }

    private mutating func unlatch() { latched = nil; latchedCircle = nil }

    /// How far (radians, the way round `sign`) the last `distance` of path went round `c`; nil
    /// while the path since it last started over is shorter.
    private func roundSince(_ c: Circle, sign: Double, over distance: Double) -> Double? {
        let n = path.count - 1
        guard path[n].length - path[0].length >= distance else { return nil }
        var angle = 0.0
        var previous = atan2(path[n].y - c.y, path[n].x - c.x)
        var i = n - 1
        while i >= 0 {
            let a = atan2(path[i].y - c.y, path[i].x - c.x)
            angle += Self.wrapped(previous - a) * sign
            previous = a
            if path[n].length - path[i].length >= distance { break }
            i -= 1
        }
        return angle
    }

    private mutating func restart(_ p: Point) { path = [p]; since = nil }

    // MARK: Geometry

    private static func turn(_ sign: Double) -> Turn { sign > 0 ? .clockwise : .counterclockwise }
    private static func sign(_ way: Turn) -> Double { way == .clockwise ? 1 : -1 }

    /// `a` in (-π, π].
    private static func wrapped(_ a: Double) -> Double {
        var a = a
        while a > .pi { a -= 2 * .pi }
        while a <= -.pi { a += 2 * .pi }
        return a
    }

    /// The algebraic (Kåsa) least-squares circle through the points, and the RMS distance off it.
    private static func fitCircle(_ points: ArraySlice<Point>) -> (circle: Circle, rms: Double)? {
        let count = Double(points.count)
        guard points.count >= 4 else { return nil }
        let mx = points.reduce(0) { $0 + $1.x } / count, my = points.reduce(0) { $0 + $1.y } / count
        var suu = 0.0, suv = 0.0, svv = 0.0, suuu = 0.0, svvv = 0.0, suvv = 0.0, svuu = 0.0
        for p in points {
            let u = p.x - mx, v = p.y - my
            let uu = u * u, vv = v * v
            suu += uu; suv += u * v; svv += vv
            suuu += uu * u; svvv += vv * v; suvv += u * vv; svuu += v * uu
        }
        let det = suu * svv - suv * suv
        guard abs(det) >= 1e-9 else { return nil }
        let a = 0.5 * (suuu + suvv), b = 0.5 * (svvv + svuu)
        let uc = (a * svv - b * suv) / det, vc = (b * suu - a * suv) / det
        let c = Circle(x: uc + mx, y: vc + my, r: (uc * uc + vc * vc + (suu + svv) / count).squareRoot())
        let squares = points.reduce(0.0) { sum, p in
            let e = hypot(p.x - c.x, p.y - c.y) - c.r
            return sum + e * e
        }
        return (c, (squares / count).squareRoot())
    }

    /// How far the points go round `c` the way round `sign` (radians), and the share of their
    /// steps that go back.
    private static func winding(_ points: ArraySlice<Point>, around c: Circle, sign: Double) -> (angle: Double, backwards: Double) {
        var angle = 0.0, back = 0
        var previous = atan2(points[points.startIndex].y - c.y, points[points.startIndex].x - c.x)
        for p in points.dropFirst() {
            let a = atan2(p.y - c.y, p.x - c.x)
            let step = wrapped(a - previous) * sign
            if step < 0 { back += 1 }
            angle += step
            previous = a
        }
        return (angle, Double(back) / Double(max(points.count - 1, 1)))
    }

    /// 4πA/L² of the closed polygon through the points: 1 for a circle, less the more stretched.
    private static func isoperimetric(_ points: ArraySlice<Point>) -> Double {
        var area = 0.0, perimeter = 0.0
        var previous = points[points.endIndex - 1]
        for p in points {
            area += previous.x * p.y - p.x * previous.y
            perimeter += hypot(p.x - previous.x, p.y - previous.y)
            previous = p
        }
        return 4 * .pi * abs(area / 2) / max(perimeter * perimeter, 1e-9)
    }
}

// MARK: - Docking a float by circling while moving it

/// A finger moving a float by its title or grabber. Circling (`WorkspaceCircleGesture`) switches
/// it into docking the float into the panes (`.dock`: it folds into a card under the finger and
/// the pane drop targets show) and back (`.float`: the card opens into the float under the
/// finger). An ordinary move, however it curves, a shake, a zig-zag, a figure eight or a pause
/// never switches. Circling on after a switch never switches back; a circle the other way round
/// does at once, and so does the same way round once the finger has stopped, moved on or turned
/// away. It keeps how the float was before the finger took it, so Cancel puts it back exactly
/// (`restoring`). Pure.
struct WorkspaceFloatMove: Equatable, Sendable {
    enum Switch: Equatable, Sendable { case dock, float }

    let id: String
    /// The float's frame, and its place among the floats (back to front), before the finger took it.
    let frame: WorkspaceRect
    let index: Int
    /// Folded into a card and being docked (else moving as a float).
    private(set) var docking = false
    private(set) var circling = WorkspaceCircleGesture()

    /// Nil when `id` isn't a float of `layout`.
    init?(_ id: String, in layout: WorkspaceLayout) {
        guard let i = layout.floats.firstIndex(where: { $0.tile == id }) else { return nil }
        self.id = id
        frame = layout.floats[i].frame
        index = i
    }

    /// One finger position (points) at `t` (seconds): the switch it makes, if any.
    mutating func add(x: Double, y: Double, at t: Double) -> Switch? {
        guard circling.add(x: x, y: y, at: t) else { return nil }
        docking.toggle()
        return docking ? .dock : .float
    }

    /// `layout` with the float back as the finger found it: its frame and its place among the
    /// floats. Its view (Fit or Fill, zoom, rotation) never changes while it moves or docks.
    func restoring(_ layout: WorkspaceLayout) -> WorkspaceLayout {
        guard let i = layout.floats.firstIndex(where: { $0.tile == id }) else { return layout }
        var copy = layout
        var f = copy.floats.remove(at: i)
        f.frame = frame
        copy.floats.insert(f, at: min(index, copy.floats.count))
        copy.normalize()
        return copy
    }
}
