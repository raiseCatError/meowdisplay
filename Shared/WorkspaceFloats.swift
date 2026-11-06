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

/// Where a tucked float waits: on an edge of the picture, its strip centred at `offset` along
/// that edge (0 = its top or left end, 1 = its bottom or right end). Its frame (flush with that
/// edge, at its own size) is kept, so it comes back out there.
struct WorkspaceFloatTuck: Equatable, Sendable {
    /// Any edge. The strips themselves stay clear of the system's edge gestures (the status bar,
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

    /// Hidden to an edge (any of the four): it keeps its size and its place in the workspace,
    /// waiting at `frame` to come back there (nil: where it is); nothing happens to the Mac
    /// window. Its capture stops while it isn't sent.
    func tuckingFloat(_ id: String, edge: WorkspaceEdge, offset: Double, frame: WorkspaceRect? = nil) -> WorkspaceLayout {
        guard let i = floats.firstIndex(where: { $0.tile == id }) else { return self }
        var copy = self
        copy.floats[i].tuck = WorkspaceFloatTuck(edge: edge, offset: min(max(offset.isFinite ? offset : 0.5, 0), 1))
        if let frame { copy.floats[i].frame = WorkspaceFloat(tile: id, frame: frame).sanitized.frame }
        if copy.maximized == id { copy.maximized = nil }
        return copy
    }

    /// Back from its edge, in front: at the frame it waited at, or at `frame`.
    func untuckingFloat(_ id: String, frame: WorkspaceRect? = nil) -> WorkspaceLayout {
        guard let i = floats.firstIndex(where: { $0.tile == id }) else { return self }
        var copy = self
        if let frame { copy.floats[i].frame = WorkspaceFloat(tile: id, frame: frame).sanitized.frame }
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

    /// Where a float of `r`'s size may come to rest (its origin, picture shares): inside the
    /// picture with room for its title bar (`clamped`) and, given `safe` (picture shares: the safe
    /// area, clear of the system's edge bands), its title pill (its title and ⋯ button) inside
    /// that. The picture wins where the two can't both be met. Only for where a float settles or
    /// comes back to: a finger may hold it anywhere, past any edge.
    static func reachableOrigins(_ r: WorkspaceRect, in size: WorkspaceSize, safe: WorkspaceRect?) -> (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        let bar = size.height > 0 ? min(barHeight / size.height, 0.5) : 0
        var x = 0...max(1 - r.width, 0), y = bar...max(1 - r.height, bar)
        guard let safe, size.width > 0, size.height > 0, safe.width > 0, safe.height > 0,
              [safe.x, safe.y, safe.width, safe.height, r.width, r.height].allSatisfy(\.isFinite) else { return (x, y) }
        func meet(_ range: ClosedRange<Double>, _ lo: Double, _ hi: Double) -> ClosedRange<Double> {
            guard hi >= lo else { return range }
            let a = max(range.lowerBound, lo), b = min(range.upperBound, hi)
            if a <= b { return a...b }
            let v = lo > range.upperBound ? range.upperBound : range.lowerBound
            return v...v
        }
        // The pill is centred on the content's top edge. Across, it's kept in as far as the
        // content: its widest is a few points wider, and a float flush with an edge stays flush.
        let content = WorkspaceRect(x: 0, y: 0, width: r.width * size.width, height: r.height * size.height)
        let pill = WorkspaceFloatLayering.pillBounds(content)
        let halfW = min(pill.width, content.width) / 2 / size.width, halfH = pill.height / 2 / size.height
        x = meet(x, safe.x + halfW - r.width / 2, safe.maxX - halfW - r.width / 2)
        y = meet(y, safe.y + halfH, safe.maxY - halfH)
        return (x, y)
    }

    /// `rect` kept usable (`clamped`) and moved the least for its title pill to be inside `safe`
    /// (see `reachableOrigins`).
    static func reachable(_ rect: WorkspaceRect, in size: WorkspaceSize, safe: WorkspaceRect?) -> WorkspaceRect {
        var r = clamped(rect, in: size)
        guard size.width > 0, size.height > 0 else { return r }
        let o = reachableOrigins(r, in: size, safe: safe)
        r.x = min(max(r.x, o.x.lowerBound), o.x.upperBound)
        r.y = min(max(r.y, o.y.lowerBound), o.y.upperBound)
        return r
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

    // MARK: Tucked floats

    /// One tucked float at its edge (a strip of the float itself), or several sharing a stack.
    struct TuckTab: Equatable, Sendable {
        /// Back to front as tucked; more than one = a stack (opens a list).
        var ids: [String]
        /// What shows, in points (picture coordinates): `stripDepth` of the float's inner side,
        /// as long as the float or the room it was given; for a stack, its handle. Its touch area
        /// reaches `touchDepth` in from the edge.
        var rect: WorkspaceRect
        /// The edge it waits at.
        var edge: WorkspaceEdge
        /// The float itself as it waits (points): its own size, all of it past the edge but the
        /// strip, placed so the strip is a part of it. A stack's handle for a stack.
        var float: WorkspaceRect
        var isStack: Bool { ids.count > 1 }
    }

    /// How much of a tucked float shows at its edge (points): the inner side of the window itself,
    /// twice its 10 pt corner radius, so the slice reads as the window's own rounded edge with room
    /// for a grip, while a phone keeps 95% of its width for the picture. Its touch area reaches
    /// `touchDepth` in from the edge.
    static let stripDepth = 20.0
    /// How much shows while a finger rests on it (a peek): it comes out a little more.
    static let peekDepth = 40.0
    /// Shortest strip (points): a crowded edge shortens its strips evenly to share the room, never
    /// below this (a 44 pt target and its grip); past that they share one stack handle.
    static let minimumStripLength = 68.0
    /// The stack handle, the last resort when an edge has no room for a strip each (or holds more
    /// than `maximumTabsPerEdge`): `width` deep, `height` long (rotated on the top and bottom edges).
    static let tabSize = WorkspaceSize(width: 28, height: 68)
    /// How far in from the edge a strip takes touches (points): a 44 pt target.
    static let touchDepth = 44.0
    static let tabSpacing = 8.0
    /// The ends of the left and right edges are left to the system (Control Center, the Home
    /// indicator, notification and app switching gestures): strips stay within the middle.
    static let tabBand = 0.12
    /// Kept clear of the screen's top and bottom (points), beyond the safe area: the system's own
    /// edge swipes start there (Notification Center, Control Center, the Home indicator, the Dock).
    static let systemEdgeClearance = 24.0
    /// More tucked floats than this on one edge share one stack handle.
    static let maximumTabsPerEdge = 4

    /// Where tucked floats may wait (points): the picture inside the safe area (clear of the notch,
    /// the Dynamic Island, the status bar and the Home indicator) and at least
    /// `systemEdgeClearance` from the screen's top and bottom, where the system's swipes start. Its
    /// edges are where they go behind. `screen` nil: the safe area alone. nil when nothing is left.
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

    /// Where tucked floats' strips are drawn (points): `handleArea`, else (nothing of the picture
    /// is clear of the system's edges) the picture itself, so a tucked float always has a handle
    /// to come back from. nil only without a usable picture.
    static func waitingArea(picture: WorkspaceRect, safe: WorkspaceRect?, screen: WorkspaceRect?) -> WorkspaceRect? {
        if let area = handleArea(picture: picture, safe: safe, screen: screen) { return area }
        guard [picture.x, picture.y, picture.width, picture.height].allSatisfy(\.isFinite), picture.width > 0, picture.height > 0 else { return nil }
        return picture
    }

    /// Strips go along y on the left and right edges, along x on the top and bottom.
    private static func alongY(_ edge: WorkspaceEdge) -> Bool { edge.axis == .horizontal }

    /// The stretch of `edge` strips may use (points along it): the left and right edges' middle
    /// (`tabBand` kept at each end); the top and bottom edges clear of the corners, so they never
    /// meet the side strips. At least one shortest strip long while the area is.
    static func run(_ edge: WorkspaceEdge, in area: WorkspaceRect) -> (lo: Double, hi: Double) {
        let start = alongY(edge) ? area.y : area.x, extent = alongY(edge) ? area.height : area.width
        let inset = alongY(edge) ? extent * tabBand : max(extent * tabBand, touchDepth + tabSpacing)
        var lo = start + inset, hi = start + extent - inset
        if hi - lo < minimumStripLength {
            let mid = start + extent / 2
            lo = max(start, mid - minimumStripLength / 2)
            hi = min(start + extent, mid + minimumStripLength / 2)
        }
        return (lo, hi)
    }

    /// The edges a float may be thrown into here: those with room for a strip, beside the
    /// controls in `reserved` or just inside them (`stripArea`). A throw toward an edge the
    /// controls fill deeper than that glides back instead of vanishing under them.
    static func tuckEdges(area: WorkspaceRect?, reserved: [WorkspaceRect] = []) -> Set<WorkspaceEdge> {
        guard let area, area.width > 0, area.height > 0 else { return [] }
        return Set([WorkspaceEdge.left, .right, .top, .bottom].filter { stripArea($0, in: area, avoiding: reserved) != nil })
    }

    /// The most the controls may move an edge's strips inward (a share of the area across that
    /// edge); past that the edge has no room for strips.
    static let maximumStripInset = 0.35

    private static func usable(_ r: WorkspaceRect) -> Bool {
        r.width > 0 && r.height > 0 && [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite)
    }

    /// Where `edge`'s strips wait (points): `area`, or, where the controls fill that edge's run
    /// (the control tray along the bottom of a phone in portrait, a column of keys down a side),
    /// `area` up to the controls' inner side: the strips wait just inside the controls, as if
    /// that were the edge, and their windows slide in under the controls. nil: no room on that
    /// edge (its floats wait on another, `tuckHandles`).
    static func stripArea(_ edge: WorkspaceEdge, in area: WorkspaceRect, avoiding reserved: [WorkspaceRect]) -> WorkspaceRect? {
        guard usable(area) else { return nil }
        let base = run(edge, in: area)
        guard base.hi - base.lo >= minimumStripLength - 1e-9, (alongY(edge) ? area.width : area.height) >= touchDepth else { return nil }
        let controls = reserved.filter(usable)
        let limit = (alongY(edge) ? area.width : area.height) * maximumStripInset
        var a = area
        // A tray with a palette or a keypad above it: step inside each layer in turn.
        for _ in 0..<4 {
            if !freeRuns(edge, in: a, avoiding: controls).isEmpty { return a }
            let r = run(edge, in: a)
            // The controls in the edge's touch band, along its run.
            let band: (lo: Double, hi: Double) = {
                switch edge {
                case .left: return (a.x, a.x + touchDepth)
                case .right: return (a.maxX - touchDepth, a.maxX)
                case .top: return (a.y, a.y + touchDepth)
                case .bottom: return (a.maxY - touchDepth, a.maxY)
                }
            }()
            let blocking = controls.filter { c in
                let across = alongY(edge) ? (c.x, c.maxX) : (c.y, c.maxY), along = alongY(edge) ? (c.y, c.maxY) : (c.x, c.maxX)
                return across.1 > band.lo && across.0 < band.hi && along.1 > r.lo && along.0 < r.hi
            }
            guard !blocking.isEmpty else { return nil }
            switch edge {
            case .left:
                let x = (blocking.map(\.maxX).max() ?? a.x) + tabSpacing
                a.width = a.maxX - x; a.x = x
            case .right: a.width = (blocking.map(\.x).min() ?? a.maxX) - tabSpacing - a.x
            case .top:
                let y = (blocking.map(\.maxY).max() ?? a.y) + tabSpacing
                a.height = a.maxY - y; a.y = y
            case .bottom: a.height = (blocking.map(\.y).min() ?? a.maxY) - tabSpacing - a.y
            }
            let inset = alongY(edge) ? area.width - a.width : area.height - a.height
            guard inset <= limit + 1e-9, (alongY(edge) ? a.width : a.height) >= touchDepth else { return nil }
        }
        return nil
    }

    /// Where a float tucked at an edge with no room for strips (`stripArea` nil) waits instead,
    /// among the edges in `open`: the nearer of the two edges beside it, at its end next to the
    /// float's own edge, else the opposite edge where it was along it. nil: none is open.
    static func refuge(for tuck: WorkspaceFloatTuck, open: Set<WorkspaceEdge>) -> (edge: WorkspaceEdge, offset: Double)? {
        let offset = tuck.offset.isFinite ? min(max(tuck.offset, 0), 1) : 0.5
        let low = offset < 0.5   // nearer the top or left end of its own edge
        let tries: [(WorkspaceEdge, Double)]
        switch tuck.edge {
        case .left: tries = [(low ? .top : .bottom, 0), (low ? .bottom : .top, 0), (.right, offset)]
        case .right: tries = [(low ? .top : .bottom, 1), (low ? .bottom : .top, 1), (.left, offset)]
        case .top: tries = [(low ? .left : .right, 0), (low ? .right : .left, 0), (.bottom, offset)]
        case .bottom: tries = [(low ? .left : .right, 1), (low ? .right : .left, 1), (.top, offset)]
        }
        return tries.first { open.contains($0.0) }.map { (edge: $0.0, offset: $0.1) }
    }

    /// The parts of `edge`'s run no reserved rect reaches (each at least a shortest strip long). A
    /// rect counts when it comes within the strips' touch depth of the edge; a spacing is kept to it.
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
        return free.filter { $0.hi - $0.lo >= minimumStripLength - 1e-9 }
    }

    /// Where something `length` long centred at `centre` starts, inside `lo…hi`.
    private static func place(_ centre: Double, _ length: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(centre - length / 2, lo), max(hi - length, lo))
    }

    private static func distance(_ c: Double, _ seg: (lo: Double, hi: Double)) -> Double {
        c < seg.lo ? seg.lo - c : (c > seg.hi ? c - seg.hi : 0)
    }

    /// Strips of `lengths` (`order`: along the edge), each at most `cap` long, in the free
    /// stretches `runs`: each in the one nearest where it wants to be (`wanted`, its centre) that
    /// has room for it and for the ones after it (one longer than its stretch has the stretch to
    /// itself, shortened to it). Room left in a stretch goes back evenly to the ones shortened
    /// there, up to their own length. Inside a stretch they're at their wanted places, pushed
    /// apart. nil: they don't all fit.
    private static func assign(_ order: [Int], lengths: [Double], cap: Double, wanted: [Double],
                               runs: [(lo: Double, hi: Double)]) -> [(index: Int, start: Double, length: Double)]? {
        guard !runs.isEmpty else { return nil }
        let gap = tabSpacing
        let longest = runs.map { $0.hi - $0.lo }.max() ?? 0
        var length = lengths.map { min($0, cap) }
        var used = Array(repeating: [Int](), count: runs.count)
        var room = runs.map { $0.hi - $0.lo }
        var current = 0
        for (k, i) in order.enumerated() {
            let restNeed = order[(k + 1)...].reduce(0.0) { $0 + min(length[$1], longest) + gap }
            var best: Int?
            for j in current..<runs.count {
                let full = runs[j].hi - runs[j].lo
                let l = min(length[i], full)
                if l < length[i], !used[j].isEmpty { continue }
                let need = l + (used[j].isEmpty ? 0 : gap)
                guard need <= room[j] + 1e-9 else { continue }
                let left = room[j] - need + runs[(j + 1)...].reduce(0.0) { $0 + ($1.hi - $1.lo) + gap }
                guard restNeed <= left + 1e-9 else { continue }
                if best.map({ distance(wanted[i], runs[j]) < distance(wanted[i], runs[$0]) }) ?? true { best = j }
            }
            guard let j = best else { return nil }
            length[i] = min(length[i], runs[j].hi - runs[j].lo)
            room[j] -= length[i] + (used[j].isEmpty ? 0 : gap)
            used[j].append(i)
            current = j
        }
        for (j, items) in used.enumerated() where !items.isEmpty {
            let full = runs[j].hi - runs[j].lo
            func short(_ i: Int) -> Bool { length[i] < min(lengths[i], full) - 1e-9 }
            var growing = items.filter(short)
            while room[j] > 1e-9, !growing.isEmpty {
                let share = room[j] / Double(growing.count)
                for i in growing {
                    let g = min(share, min(lengths[i], full) - length[i])
                    length[i] += g
                    room[j] -= g
                }
                growing = growing.filter(short)
            }
        }
        var out: [(index: Int, start: Double, length: Double)] = []
        for (j, items) in used.enumerated() where !items.isEmpty {
            let lo = runs[j].lo, hi = runs[j].hi
            var starts = items.map { place(wanted[$0], length[$0], lo, hi) }
            for n in starts.indices.dropFirst() where starts[n] < starts[n - 1] + length[items[n - 1]] + gap {
                starts[n] = starts[n - 1] + length[items[n - 1]] + gap
            }
            if let last = starts.indices.last, starts[last] + length[items[last]] > hi {
                starts[last] = hi - length[items[last]]
                for n in starts.indices.dropLast().reversed() where starts[n] + length[items[n]] + gap > starts[n + 1] {
                    starts[n] = starts[n + 1] - gap - length[items[n]]
                }
            }
            for (i, a) in zip(items, starts) { out.append((i, a, length[i])) }
        }
        return out
    }

    /// The tucked floats on one edge of `area` (points). `tucked`, in tuck order: each float's id,
    /// where it wants to wait along the edge (`offset`: its centre, a share of `picture`'s side;
    /// nil picture: the area's) and its size (points).
    ///
    /// Each gets a strip as long as itself where it wants to be, sliding along the edge to the
    /// nearest free room (past whatever `reserved` holds, never overlapping another); one longer
    /// than the room it gets shows that much of itself. When the edge has no room for each at full
    /// length, the longest are shortened evenly (each still a part of its own window, with its own
    /// touch area), down to `minimumStripLength`. Past that, or with more than
    /// `maximumTabsPerEdge`, they share one stack handle where most of them want to be. Never lost:
    /// with no free room at all, a strip (or the stack) sits over whatever is there.
    static func tuckTabs(_ tucked: [(id: String, offset: Double, size: WorkspaceSize)], edge: WorkspaceEdge, area: WorkspaceRect,
                         picture: WorkspaceRect? = nil, avoiding reserved: [WorkspaceRect] = []) -> [TuckTab] {
        guard !tucked.isEmpty, area.width > 0, area.height > 0 else { return [] }
        let along = alongY(edge)
        let side = picture ?? area
        let start = along ? side.y : side.x, extent = along ? side.height : side.width
        let wanted = tucked.map { start + (($0.offset.isFinite ? min(max($0.offset, 0), 1) : 0.5) * extent) }
        let sizes = tucked.map { t in
            WorkspaceSize(width: t.size.width.isFinite && t.size.width > 0 ? t.size.width : minimumStripLength,
                          height: t.size.height.isFinite && t.size.height > 0 ? t.size.height : minimumStripLength)
        }
        let lengths = sizes.map { along ? $0.height : $0.width }
        // Along the edge, in tuck order where they want the same place.
        let order = tucked.indices.sorted { (wanted[$0], $0) < (wanted[$1], $1) }
        let runs = freeRuns(edge, in: area, avoiding: reserved)

        /// `a…a+length` along the edge, `depth` in from it.
        func strip(_ a: Double, _ length: Double, depth: Double = stripDepth) -> WorkspaceRect {
            switch edge {
            case .left: return WorkspaceRect(x: area.x, y: a, width: depth, height: length)
            case .right: return WorkspaceRect(x: area.maxX - depth, y: a, width: depth, height: length)
            case .top: return WorkspaceRect(x: a, y: area.y, width: length, height: depth)
            case .bottom: return WorkspaceRect(x: a, y: area.maxY - depth, width: length, height: depth)
            }
        }
        /// Float `i` waiting behind the edge with `a…a+length` of it showing, as near where it wants
        /// to be as that allows.
        func tab(_ i: Int, _ a: Double, _ length: Double) -> TuckTab {
            let s = sizes[i], full = lengths[i]
            let from = min(max(wanted[i] - full / 2, a + length - full), a)
            let f: WorkspaceRect
            switch edge {
            case .left: f = WorkspaceRect(x: area.x + stripDepth - s.width, y: from, width: s.width, height: s.height)
            case .right: f = WorkspaceRect(x: area.maxX - stripDepth, y: from, width: s.width, height: s.height)
            case .top: f = WorkspaceRect(x: from, y: area.y + stripDepth - s.height, width: s.width, height: s.height)
            case .bottom: f = WorkspaceRect(x: from, y: area.maxY - stripDepth, width: s.width, height: s.height)
            }
            return TuckTab(ids: [tucked[i].id], rect: strip(a, length), edge: edge, float: f)
        }
        func nearest(_ c: Double) -> (lo: Double, hi: Double) {
            runs.min { distance(c, $0) < distance(c, $1) } ?? run(edge, in: area)
        }

        if tucked.count <= maximumTabsPerEdge, !runs.isEmpty {
            // Full length first; then the longest shortened evenly until all fit.
            let longest = lengths.max() ?? minimumStripLength
            var cap = Double.infinity
            while true {
                if let placed = assign(order, lengths: lengths, cap: cap, wanted: wanted, runs: runs) {
                    return placed.sorted { $0.start < $1.start }.map { tab($0.index, $0.start, $0.length) }
                }
                guard cap > minimumStripLength else { break }
                cap = max(min(cap, longest) * 0.85, minimumStripLength)
            }
        }
        if tucked.count == 1 {
            // No free room on this edge: the strip stays reachable over whatever is there (a
            // window is never lost behind a control).
            let r = nearest(wanted[0])
            let length = min(lengths[0], max(r.hi - r.lo, 1))
            return [tab(0, place(wanted[0], length, r.lo, r.hi), length)]
        }
        // One stack where most of them want to be, else over whatever is there.
        let mid = wanted[order[order.count / 2]]
        let r = nearest(mid)
        let handle = strip(place(mid, tabSize.height, r.lo, r.hi), tabSize.height, depth: tabSize.width)
        return [TuckTab(ids: tucked.map(\.id), rect: handle, edge: edge, float: handle)]
    }

    /// Every tucked float at its edge (left, top, right, bottom; along each in order). `picture`:
    /// where the picture is (points; the floats' frames are shares of it). `area`: where they wait
    /// (`handleArea`).
    ///
    /// Who gives way: the system's edge bands first (kept out of `area`), then the fixed controls in
    /// `reserved` (the control tray, the function tray, the shortcut column, keypads, Stage Peek's
    /// handle, folds), then the strips, which slide along their edge to the nearest free room,
    /// shorten to share a crowded edge, and share one stack when it has no room for each. Strips on
    /// different edges never meet: the top and bottom ones stay clear of the corners. Where the
    /// controls fill an edge, its strips wait just inside them (`stripArea`); where they fill it
    /// deeper than that, its floats wait on the nearest edge with room (`refuge`) until it has
    /// room again, so a finger can always reach every tucked float (`unreachableTucked`).
    static func tuckHandles(_ floats: [WorkspaceFloat], picture: WorkspaceRect, area: WorkspaceRect, reserved: [WorkspaceRect] = []) -> [TuckTab] {
        let edges: [WorkspaceEdge] = [.left, .top, .right, .bottom]
        var areas: [WorkspaceEdge: WorkspaceRect] = [:]
        for e in edges { areas[e] = stripArea(e, in: area, avoiding: reserved) }
        let open = Set(areas.keys)
        // A side whose strips wait inside the controls: the top and bottom strips keep clear of
        // its corner there too.
        for e in [WorkspaceEdge.top, .bottom] {
            guard var a = areas[e] else { continue }
            let lo = max(a.x, areas[.left]?.x ?? a.x), hi = min(a.maxX, areas[.right]?.maxX ?? a.maxX)
            guard lo > a.x || hi < a.maxX else { continue }
            a.x = lo
            a.width = hi - lo
            if usable(a), !freeRuns(e, in: a, avoiding: reserved).isEmpty { areas[e] = a }
        }
        var waiting: [WorkspaceEdge: [(id: String, offset: Double, size: WorkspaceSize)]] = [:]
        for f in floats {
            guard let t = f.tuck else { continue }
            let at = open.contains(t.edge) ? (edge: t.edge, offset: t.offset) : (refuge(for: t, open: open) ?? (edge: t.edge, offset: t.offset))
            waiting[at.edge, default: []].append((f.tile, at.offset, WorkspaceSize(width: f.frame.width * picture.width, height: f.frame.height * picture.height)))
        }
        // With no room anywhere they stay on their own edges, over whatever is there.
        return edges.flatMap { e in tuckTabs(waiting[e] ?? [], edge: e, area: areas[e] ?? area, picture: picture, avoiding: reserved) }
    }

    /// Where a tucked float's handle takes touches (points): its visible slice and on in from its
    /// edge to a `touchDepth` target, at least that long.
    static func touchArea(_ tab: TuckTab) -> WorkspaceRect {
        let d = touchDepth, r = tab.rect
        let h = max(r.height, d), w = max(r.width, d)
        switch tab.edge {
        case .left: return WorkspaceRect(x: r.x, y: r.midY - h / 2, width: d, height: h)
        case .right: return WorkspaceRect(x: r.maxX - d, y: r.midY - h / 2, width: d, height: h)
        case .top: return WorkspaceRect(x: r.midX - w / 2, y: r.y, width: w, height: d)
        case .bottom: return WorkspaceRect(x: r.midX - w / 2, y: r.maxY - d, width: w, height: d)
        }
    }

    /// Whether every tucked float can be brought back by a finger: the tucked floats of `floats`
    /// that aren't on exactly one of `handles`, or whose handle has no `touchDepth` of its touch
    /// area clear of `reserved` (the controls are drawn over the strips). `tuckHandles` leaves
    /// none while any edge has room. With none anywhere VoiceOver still reaches every handle, and
    /// choosing the window in Stage Peek brings its float back.
    static func unreachableTucked(_ floats: [WorkspaceFloat], handles: [TuckTab], reserved: [WorkspaceRect]) -> [String] {
        let controls = reserved.filter(usable)
        return floats.compactMap { f -> String? in
            guard f.tuck != nil else { return nil }
            let on = handles.filter { $0.ids.contains(f.tile) }
            guard on.count == 1, let tab = on.first else { return f.tile }
            let clear = WorkspaceFloatLayering.uncovered(touchArea(tab), alongX: !alongY(tab.edge), by: controls, minLength: touchDepth - 1e-9)
            return clear.isEmpty ? f.tile : nil
        }
    }

    /// A float of `size` (points) all the way behind `edge` of `area`, centred at `along` (points
    /// along the edge), and the line it comes out through (no depth yet): where a float in a stack
    /// waits.
    static func hidden(_ size: WorkspaceSize, edge: WorkspaceEdge, area: WorkspaceRect, along: Double) -> (float: WorkspaceRect, line: WorkspaceRect) {
        switch edge {
        case .left:
            return (WorkspaceRect(x: area.x - size.width, y: along - size.height / 2, width: size.width, height: size.height),
                    WorkspaceRect(x: area.x, y: along - size.height / 2, width: 0, height: size.height))
        case .right:
            return (WorkspaceRect(x: area.maxX, y: along - size.height / 2, width: size.width, height: size.height),
                    WorkspaceRect(x: area.maxX, y: along - size.height / 2, width: 0, height: size.height))
        case .top:
            return (WorkspaceRect(x: along - size.width / 2, y: area.y - size.height, width: size.width, height: size.height),
                    WorkspaceRect(x: along - size.width / 2, y: area.y, width: size.width, height: 0))
        case .bottom:
            return (WorkspaceRect(x: along - size.width / 2, y: area.maxY, width: size.width, height: size.height),
                    WorkspaceRect(x: along - size.width / 2, y: area.maxY, width: size.width, height: 0))
        }
    }

    /// The frame a float keeps while it's tucked into `edge`, to come back to: its own size, flush
    /// with that edge (`area`: where tucked floats wait, picture shares; nil: the picture) and
    /// centred at `along` (a share of the picture along that edge), kept reachable (`safe`, see
    /// `reachableOrigins`). Pulling it back out is then a straight slide that ends there.
    static func tuckedFrame(_ r: WorkspaceRect, edge: WorkspaceEdge, along: Double, in size: WorkspaceSize,
                            area: WorkspaceRect? = nil, safe: WorkspaceRect? = nil) -> WorkspaceRect {
        let a = area ?? .unit
        var f = clamped(r, in: size)
        switch edge {
        case .left: f.x = a.x
        case .right: f.x = a.maxX - f.width
        case .top: f.y = a.y
        case .bottom: f.y = a.maxY - f.height
        }
        if along.isFinite {
            if alongY(edge) { f.y = along - f.height / 2 } else { f.x = along - f.width / 2 }
        }
        return reachable(f, in: size, safe: safe)
    }

    /// Where a tucked float comes back to (picture shares): its frame, moved along `edge` to where
    /// it waits (`waiting`, picture shares: its strip may have slid along the edge to make room),
    /// kept reachable (`safe`, see `reachableOrigins`). Pulling it out is a straight slide.
    static func comingBack(_ frame: WorkspaceRect, waiting: WorkspaceRect, edge: WorkspaceEdge, in size: WorkspaceSize,
                           safe: WorkspaceRect? = nil) -> WorkspaceRect {
        var r = frame
        if alongY(edge), waiting.midY.isFinite { r.y = waiting.midY - r.height / 2 }
        if !alongY(edge), waiting.midX.isFinite { r.x = waiting.midX - r.width / 2 }
        return reachable(r, in: size, safe: safe)
    }

    /// Where a tucked float comes back to when pulled out of its handle on `edge` (picture
    /// shares): its frame flush with that edge of `area` (where that edge's strips wait, picture
    /// shares) and moved along it to where it waits (`waiting`), kept reachable (`safe`). A
    /// straight slide out of its strip even when it waits somewhere it wasn't tucked: past
    /// controls that fill its edge, on another edge, or after the screen turned.
    static func restoreFrame(_ frame: WorkspaceRect, waiting: WorkspaceRect, edge: WorkspaceEdge, in size: WorkspaceSize,
                             area: WorkspaceRect?, safe: WorkspaceRect?) -> WorkspaceRect {
        comingBack(tuckedFrame(frame, edge: edge, along: .nan, in: size, area: area, safe: safe), waiting: waiting, edge: edge, in: size, safe: safe)
    }

    /// A tucked float on its way out of its edge or back in, drawn as one picture: at `rect(p)`, its
    /// own size all the way, showing only inside `clip(p)`. Points; `p` 0 is `from`, 1 is `to`. The
    /// clip's sides across and along the edge move with `p`; its side beyond the edge holds
    /// `clipFrom` until `outerHold`, so while the float is behind the edge nothing of it shows past
    /// it (under the status bar or a notch, or in a letterbox).
    struct EdgePath: Equatable, Sendable {
        var edge: WorkspaceEdge
        var from: WorkspaceRect
        var to: WorkspaceRect
        var clipFrom: WorkspaceRect
        var clipTo: WorkspaceRect

        static let outerHold = 0.75

        private static func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        private static func unit(_ p: Double) -> Double { p.isFinite ? min(max(p, 0), 1) : 0 }

        func rect(_ p: Double) -> WorkspaceRect {
            let t = Self.unit(p)
            return WorkspaceRect(x: Self.mix(from.x, to.x, t), y: Self.mix(from.y, to.y, t),
                                 width: Self.mix(from.width, to.width, t), height: Self.mix(from.height, to.height, t))
        }

        func clip(_ p: Double) -> WorkspaceRect {
            let t = Self.unit(p)
            let o = t <= Self.outerHold ? 0 : (t - Self.outerHold) / (1 - Self.outerHold)
            var minX = Self.mix(clipFrom.x, clipTo.x, t), maxX = Self.mix(clipFrom.maxX, clipTo.maxX, t)
            var minY = Self.mix(clipFrom.y, clipTo.y, t), maxY = Self.mix(clipFrom.maxY, clipTo.maxY, t)
            switch edge {
            case .left: minX = Self.mix(clipFrom.x, clipTo.x, o)
            case .right: maxX = Self.mix(clipFrom.maxX, clipTo.maxX, o)
            case .top: minY = Self.mix(clipFrom.y, clipTo.y, o)
            case .bottom: maxY = Self.mix(clipFrom.maxY, clipTo.maxY, o)
            }
            return WorkspaceRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
        }

        /// Points it travels across the edge.
        var travel: Double { abs(WorkspaceFloatGeometry.alongY(edge) ? to.x - from.x : to.y - from.y) }

        /// Where a finger that has moved `inward` points into the picture puts it, from `start`.
        func progress(inward: Double, from start: Double = 0) -> Double {
            guard travel > 1e-9, inward.isFinite else { return Self.unit(start) }
            return Self.unit(start + inward / travel)
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
        /// Carried into `edge` and tucked; its strip waits at `offset` along that edge.
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

    /// The edge `r` hangs at least `pastEdge` past (an armed tuck: letting go slowly tucks it). In
    /// a corner, past two edges, the one more of it hangs over (left and right first on a tie).
    static func pulledEdge(_ r: WorkspaceRect, edges: Set<WorkspaceEdge> = allEdges) -> WorkspaceEdge? {
        furthest(r, among: [WorkspaceEdge.left, .right, .top, .bottom].filter { edges.contains($0) })
    }

    /// Of `candidates`, the edge `r` hangs furthest past, at least `pastEdge` (the first on a tie).
    private static func furthest(_ r: WorkspaceRect, among candidates: [WorkspaceEdge]) -> WorkspaceEdge? {
        var best: (edge: WorkspaceEdge, share: Double)?
        for e in candidates where past(r, e) >= pastEdge && past(r, e) > (best?.share ?? -1) { best = (e, past(r, e)) }
        return best?.edge
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

    /// `frame`: where the float is when let go (normalized; while dragging it may hang past any
    /// edge, a corner too). `velocity`: its release velocity in points per second. `canTuck`: false
    /// while the float can't be tucked (it isn't a float of a live workspace). `edges`: where it may
    /// tuck (those with room for a strip, `WorkspaceFloatGeometry.tuckEdges`). `safe`: where its
    /// title pill must be when it settles (picture shares, see `reachableOrigins`); nil: the picture.
    static func decide(release frame: WorkspaceRect, velocity: (x: Double, y: Double), in size: WorkspaceSize,
                       canTuck: Bool = true, edges: Set<WorkspaceEdge> = allEdges, safe: WorkspaceRect? = nil) -> Outcome {
        guard size.width > 0, size.height > 0, frame.width > 0, frame.height > 0,
              [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite) else {
            return .settle(frame: WorkspaceFloatGeometry.clamped(frame, in: size), glide: false)
        }
        let vx = velocity.x.isFinite ? velocity.x : 0, vy = velocity.y.isFinite ? velocity.y : 0
        let speed = (vx * vx + vy * vy).squareRoot()
        if canTuck, !edges.isEmpty {
            // Pulled more than halfway past an edge on purpose and let go there (slowly or not,
            // as long as it isn't being thrown back in); in a corner, the edge more of it is past.
            func inward(_ edge: WorkspaceEdge) -> Double {
                switch edge {
                case .left: return vx
                case .right: return -vx
                case .top: return vy
                case .bottom: return -vy
                }
            }
            let held = [WorkspaceEdge.left, .right, .top, .bottom].filter { edges.contains($0) && inward($0) < flingSpeed }
            if let edge = furthest(frame, among: held) { return .tuck(edge: edge, offset: along(frame, edge)) }
            // Thrown: fast enough, and its projected path carries it past an edge (from the
            // middle or from the far side alike): tucked into the first edge that path crosses,
            // where it crosses it. A corner throw takes whichever edge it meets first.
            if speed >= flingSpeed,
               let hit = firstEdge(frame, dx: projection(vx, rate: reachDecelerationRate) / size.width,
                                   dy: projection(vy, rate: reachDecelerationRate) / size.height, edges: edges) {
                return .tuck(edge: hit.edge, offset: hit.offset)
            }
        }
        // Let go inside, or hanging less than halfway past an edge (or a corner): it comes to rest
        // where its title pill can be reached, gliding back in from wherever the finger left it.
        let held = WorkspaceFloatGeometry.reachable(frame, in: size, safe: safe)
        guard speed >= glideSpeed else {
            let rest = snapped(held, in: size, safe: safe)
            return .settle(frame: rest, glide: rest != frame)
        }
        var target = frame
        target.x += projection(vx) / size.width
        target.y += projection(vy) / size.height
        let landed = snapped(WorkspaceFloatGeometry.reachable(target, in: size, safe: safe), in: size, safe: safe)
        return .settle(frame: landed, glide: landed != frame)
    }

    /// Close to where it may rest at an edge (within `WorkspaceFloatGeometry.snap` points of the
    /// picture's edge, or of where its title pill meets `safe`): flush with it.
    static func snapped(_ r: WorkspaceRect, in size: WorkspaceSize, safe: WorkspaceRect? = nil) -> WorkspaceRect {
        guard size.width > 0, size.height > 0 else { return r }
        var c = r
        let o = WorkspaceFloatGeometry.reachableOrigins(r, in: size, safe: safe)
        let sx = WorkspaceFloatGeometry.snap / size.width, sy = WorkspaceFloatGeometry.snap / size.height
        if c.x > o.x.lowerBound, c.x - o.x.lowerBound < sx { c.x = o.x.lowerBound }
        if c.x < o.x.upperBound, o.x.upperBound - c.x < sx { c.x = o.x.upperBound }
        if c.y > o.y.lowerBound, c.y - o.y.lowerBound < sy { c.y = o.y.lowerBound }
        if c.y < o.y.upperBound, o.y.upperBound - c.y < sy { c.y = o.y.upperBound }
        return c
    }

    // MARK: Pulling a tucked float back out

    /// Share of the way out (from its strip to where it comes back to, `EdgePath`) past which
    /// letting go of a pull brings the float back; short of it, it slides back into its edge.
    static let restoreProgress = 0.4

    /// A pull let go `progress` of the way out at `inwardVelocity` (points/s, positive away from
    /// the edge), with `travel` points from its strip to its frame: true brings it back (projected
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
