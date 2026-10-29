import Foundation

// Window workspaces: the receiver-side layout engine and the tile content
// transform both ends share. Foundation-only and deterministic so every rule
// is unit testable and the Android port (`AndroidReceiver/core/.../workspace`)
// can follow it line for line, checked against the same JSON vectors.
//
// Geometry is normalized to the workspace: (0,0) top-left, (1,1) bottom-right.
// Sizes that need a minimum (tiles, dividers) take the workspace's size in
// points so "too small to use" means the same thing on every screen.

// MARK: - Basic geometry

struct WorkspacePoint: Equatable, Codable, Sendable {
    var x: Double
    var y: Double
}

struct WorkspaceSize: Equatable, Codable, Sendable {
    var width: Double
    var height: Double
}

struct WorkspaceRect: Equatable, Codable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    static let unit = WorkspaceRect(x: 0, y: 0, width: 1, height: 1)

    var maxX: Double { x + width }
    var maxY: Double { y + height }
    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }
    var area: Double { max(width, 0) * max(height, 0) }

    func contains(_ p: WorkspacePoint) -> Bool {
        p.x >= x && p.x < maxX && p.y >= y && p.y < maxY
    }

    func intersection(_ other: WorkspaceRect) -> WorkspaceRect? {
        let x0 = max(x, other.x), y0 = max(y, other.y)
        let x1 = min(maxX, other.maxX), y1 = min(maxY, other.maxY)
        guard x1 > x0, y1 > y0 else { return nil }
        return WorkspaceRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func scaled(to size: WorkspaceSize) -> WorkspaceRect {
        WorkspaceRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }

    /// Same rect with each edge snapped to whole pixels of `size`, used for
    /// codec-friendly tile boundaries in the sender's canvas.
    func pixelAligned(in size: WorkspaceSize) -> WorkspaceRect {
        let x0 = (x * size.width).rounded(), y0 = (y * size.height).rounded()
        let x1 = (maxX * size.width).rounded(), y1 = (maxY * size.height).rounded()
        return WorkspaceRect(x: x0, y: y0, width: max(x1 - x0, 0), height: max(y1 - y0, 0))
    }
}

enum WorkspaceAxis: String, Codable, Sendable {
    /// Children side by side (left to right).
    case horizontal
    /// Children stacked (top to bottom).
    case vertical
}

// MARK: - Tile presentation: rotation and fit

/// Clockwise rotation of a tile's received image. Presentation only: the Mac
/// window is never rotated, and input is mapped back through the inverse.
enum WorkspaceRotation: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case quarter = 90
    case half = 180
    case threeQuarter = 270

    var isQuarterTurn: Bool { self == .quarter || self == .threeQuarter }

    var clockwise: WorkspaceRotation {
        WorkspaceRotation(rawValue: (rawValue + 90) % 360) ?? .none
    }

    /// Lenient decode for wire/persisted values: anything else is no rotation.
    init(degrees: Int) {
        self = WorkspaceRotation(rawValue: ((degrees % 360) + 360) % 360) ?? .none
    }
}

enum WorkspaceFit: String, Codable, Sendable {
    /// Whole window visible, letterboxed.
    case fit
    /// Tile filled, window cropped evenly. Never stretched.
    case fill
    /// Default: fill when that still shows most of the window (no letterbox bars
    /// in split panes), whole window when filling would hide too much.
    case auto

    /// Filling must show at least this share of the window along the cropped side.
    static let autoFillMinimumShown = 0.7

    /// `.auto` resolved for a tile and a (rotated) source size. Pure: the Mac, iOS
    /// and Android resolve it identically.
    static func resolved(_ fit: WorkspaceFit, tile: WorkspaceSize, source: WorkspaceSize) -> WorkspaceFit {
        guard fit == .auto else { return fit }
        guard tile.width > 0, tile.height > 0, source.width > 0, source.height > 0 else { return .fit }
        let sx = tile.width / source.width, sy = tile.height / source.height
        return min(sx, sy) / max(sx, sy) >= autoFillMinimumShown ? .fill : .fit
    }
}

/// Maps between a source window's pixels and the workspace canvas for one
/// tile. Both directions are pure, so the sender's input path and the
/// receiver's hit-testing are provably inverse of the compositor.
struct TileContentTransform: Equatable, Sendable {
    /// The tile in canvas units (pixels or points, the caller decides).
    let tile: WorkspaceRect
    /// The window's size in its own pixels (before rotation).
    let source: WorkspaceSize
    let rotation: WorkspaceRotation
    let fit: WorkspaceFit
    /// Per-tile zoom: where `source` (the zoomed-in part) starts inside the
    /// whole window, in window pixels. Zero when the tile shows the whole window.
    var origin = WorkspacePoint(x: 0, y: 0)

    /// The rotated image's size before scaling.
    var rotatedSourceSize: WorkspaceSize {
        rotation.isQuarterTurn ? WorkspaceSize(width: source.height, height: source.width) : source
    }

    /// `.auto` resolved for this tile and source.
    var effectiveFit: WorkspaceFit {
        WorkspaceFit.resolved(fit, tile: WorkspaceSize(width: tile.width, height: tile.height), source: rotatedSourceSize)
    }

    var scale: Double {
        let r = rotatedSourceSize
        guard r.width > 0, r.height > 0, tile.width > 0, tile.height > 0 else { return 0 }
        let sx = tile.width / r.width, sy = tile.height / r.height
        return effectiveFit == .fit ? min(sx, sy) : max(sx, sy)
    }

    /// Where the whole (rotated, scaled) image lands. With `.fill` it is
    /// larger than the tile and the tile crops it.
    var contentRect: WorkspaceRect {
        let r = rotatedSourceSize, s = scale
        let w = r.width * s, h = r.height * s
        return WorkspaceRect(x: tile.midX - w / 2, y: tile.midY - h / 2, width: w, height: h)
    }

    /// The part of the tile that actually shows window pixels.
    var visibleRect: WorkspaceRect? { contentRect.intersection(tile) }

    /// Source pixel (whole-window coordinates) -> canvas.
    func canvasPoint(fromSource window: WorkspacePoint) -> WorkspacePoint {
        let r = rotated(WorkspacePoint(x: window.x - origin.x, y: window.y - origin.y))
        let c = contentRect, s = scale
        return WorkspacePoint(x: c.x + r.x * s, y: c.y + r.y * s)
    }

    /// Canvas -> source pixel, or nil when the point shows no window pixels
    /// (letterbox bars, cropped-away area, outside the tile). Input outside
    /// the visible image must never reach the Mac.
    func sourcePoint(fromCanvas q: WorkspacePoint) -> WorkspacePoint? {
        guard let visible = visibleRect, visible.contains(q) else { return nil }
        let c = contentRect, s = scale
        guard s > 0 else { return nil }
        let r = WorkspacePoint(x: (q.x - c.x) / s, y: (q.y - c.y) / s)
        let p = unrotated(r)
        // Clamp float residue at the far edges into the (zoomed-in part of the) window.
        return WorkspacePoint(x: min(max(p.x, 0), source.width) + origin.x, y: min(max(p.y, 0), source.height) + origin.y)
    }

    /// Canvas -> source for a point that may lie outside the tile (a drag that
    /// started inside and wandered out). Clamped to the window's edge so a drag
    /// bound to this tile can never land in a neighbouring window.
    func clampedSourcePoint(fromCanvas q: WorkspacePoint) -> WorkspacePoint? {
        guard let visible = visibleRect else { return nil }
        let eps = 1e-9
        let clamped = WorkspacePoint(x: min(max(q.x, visible.x), visible.maxX - eps),
                                     y: min(max(q.y, visible.y), visible.maxY - eps))
        return sourcePoint(fromCanvas: clamped)
    }

    /// Canvas-space vector (scroll, relative motion) -> source-space vector.
    func sourceVector(fromCanvas v: WorkspacePoint) -> WorkspacePoint {
        let s = scale
        guard s > 0 else { return WorkspacePoint(x: 0, y: 0) }
        let a = v.x / s, b = v.y / s
        switch rotation {
        case .none: return WorkspacePoint(x: a, y: b)
        case .quarter: return WorkspacePoint(x: b, y: -a)
        case .half: return WorkspacePoint(x: -a, y: -b)
        case .threeQuarter: return WorkspacePoint(x: -b, y: a)
        }
    }

    private func rotated(_ p: WorkspacePoint) -> WorkspacePoint {
        let w = source.width, h = source.height
        switch rotation {
        case .none: return p
        case .quarter: return WorkspacePoint(x: h - p.y, y: p.x)
        case .half: return WorkspacePoint(x: w - p.x, y: h - p.y)
        case .threeQuarter: return WorkspacePoint(x: p.y, y: w - p.x)
        }
    }

    private func unrotated(_ r: WorkspacePoint) -> WorkspacePoint {
        let w = source.width, h = source.height
        switch rotation {
        case .none: return r
        case .quarter: return WorkspacePoint(x: r.y, y: h - r.x)
        case .half: return WorkspacePoint(x: w - r.x, y: h - r.y)
        case .threeQuarter: return WorkspacePoint(x: w - r.y, y: r.x)
        }
    }
}

// MARK: - Sources

/// What a tile shows. Identity is checked by the sender, never trusted from
/// this value: `windowID` only selects among windows the sender itself listed
/// for this session, and `host` only picks which connection the tile's
/// requests go to.
struct WorkspaceSource: Equatable, Codable, Sendable {
    enum Follow: String, Codable, Sendable {
        /// Exactly this window.
        case window
        /// This app's frontmost window, following it as it changes.
        case app
    }

    /// The sending Mac's stable install id (per macOS account).
    var host: String
    var windowID: UInt32
    var bundleID: String?
    var follow: Follow = .window
}

struct WorkspaceTile: Equatable, Codable, Sendable {
    var id: String
    /// The window this pane shows (its active tab). Only this one streams.
    var source: WorkspaceSource?
    var rotation: WorkspaceRotation = .none
    var fit: WorkspaceFit = .auto
    /// Per-tile zoom/pan: the part of the window shown, normalized to the window, with the
    /// pane's own shape (so it fills the pane: no bars). Nil = the fit's default view.
    var crop: WorkspaceRect?
    /// Every window in this pane, in label order, when it holds more than one (tabs).
    /// Empty for a single-window pane. `source` is always one of them.
    var tabs: [WorkspaceSource] = []

    /// The pane's windows in label order (one, or its tabs).
    var windows: [WorkspaceSource] { tabs.isEmpty ? (source.map { [$0] } ?? []) : tabs }
}

/// Pinch and pan inside one tile, as a change to the part of its window it shows.
/// A zoomed tile always shows a region with the TILE's shape, drawn filling the
/// tile: zooming never adds letterbox bars, and the Mac captures exactly that
/// region at the tile's resolution (sharp).
enum WorkspaceZoom {
    static let maximum = 8.0

    /// The largest region of the window with the tile's shape, centred: what "fill" shows.
    /// `window` and `tile` in any units (aspects matter); `rotation` turns the tile's
    /// shape into the window's orientation.
    static func fillCrop(window: WorkspaceSize, tile: WorkspaceSize, rotation: WorkspaceRotation) -> WorkspaceRect {
        guard window.width > 0, window.height > 0, tile.width > 0, tile.height > 0 else { return WorkspaceRect(x: 0, y: 0, width: 1, height: 1) }
        let t = rotation.isQuarterTurn ? WorkspaceSize(width: tile.height, height: tile.width) : tile
        let tileAspect = t.width / t.height, windowAspect = window.width / window.height
        if tileAspect >= windowAspect {
            let h = windowAspect / tileAspect
            return WorkspaceRect(x: 0, y: (1 - h) / 2, width: 1, height: h)
        }
        let w = tileAspect / windowAspect
        return WorkspaceRect(x: (1 - w) / 2, y: 0, width: w, height: 1)
    }

    /// `crop` (or `base`, the fill region, when nil) zoomed by `scale` (>1 zooms in) around
    /// `anchor` (a point in the tile, 0..1), then moved by `pan` (the fingers' travel as a share
    /// of the tile). The anchor stays under the fingers; the shape never changes; never larger
    /// than `base`, never more than `maximum` times smaller; clamped to the window. Nil when it
    /// is exactly `base` again (back to the default view).
    static func apply(_ crop: WorkspaceRect?, base: WorkspaceRect, scale: Double, anchor: WorkspacePoint, pan: WorkspacePoint) -> WorkspaceRect? {
        let c = crop ?? base
        guard scale.isFinite, scale > 0, [anchor.x, anchor.y, pan.x, pan.y].allSatisfy(\.isFinite),
              c.width > 0, c.height > 0, base.width > 0, base.height > 0 else { return crop }
        // Uniform: both sides scale together (the shape is the tile's).
        let k = min(max(c.width / scale, base.width / maximum), base.width) / c.width
        let w = c.width * k, h = c.height * k
        let ax = c.x + anchor.x * c.width, ay = c.y + anchor.y * c.height
        var x = ax - anchor.x * w - pan.x * w, y = ay - anchor.y * h - pan.y * h
        x = min(max(x, 0), max(1 - w, 0)); y = min(max(y, 0), max(1 - h, 0))
        let r = WorkspaceRect(x: x, y: y, width: w, height: h)
        let eps = 1e-6
        if abs(w - base.width) < eps, abs(h - base.height) < eps, abs(x - base.x) < eps, abs(y - base.y) < eps { return nil }
        return r
    }

    /// Back-compat for callers without a tile shape (whole window as base).
    static func apply(_ crop: WorkspaceRect?, scale: Double, anchor: WorkspacePoint, pan: WorkspacePoint) -> WorkspaceRect? {
        apply(crop, base: WorkspaceRect(x: 0, y: 0, width: 1, height: 1), scale: scale, anchor: anchor, pan: pan)
    }
}

// MARK: - Layout tree

/// A layout is a tree of splits whose leaves are slots. A slot holds a tile
/// or is empty (a drop target). Ratios are each child's share of its parent.
indirect enum WorkspaceNode: Equatable, Sendable {
    case slot(String?)
    case split(WorkspaceAxis, [WorkspaceNode], [Double])

    var tileIDs: [String] {
        switch self {
        case .slot(let id): return id.map { [$0] } ?? []
        case .split(_, let children, _): return children.flatMap(\.tileIDs)
        }
    }

    var slotCount: Int {
        switch self {
        case .slot: return 1
        case .split(_, let children, _): return children.reduce(0) { $0 + $1.slotCount }
        }
    }
}

enum WorkspacePreset: String, Codable, CaseIterable, Sendable {
    case single
    case sideBySide
    case stacked
    case primaryPlusTwo
    case threeColumns
    case threeRows
    case grid2x2
    case grid3x2
    case grid2x3
    case grid3x3
    case primaryPlusFour

    /// What a person hears or reads for the layout ("Two side by side").
    var title: String {
        switch self {
        case .single: return "One window"
        case .sideBySide: return "Two side by side"
        case .stacked: return "Two stacked"
        case .primaryPlusTwo: return "One large and two small"
        case .threeColumns: return "Three side by side"
        case .threeRows: return "Three stacked"
        case .grid2x2: return "Four in a grid"
        case .grid3x2: return "Six, three across"
        case .grid2x3: return "Six, two across"
        case .grid3x3: return "Nine in a grid"
        case .primaryPlusFour: return "One large and four small"
        }
    }

    var slotCount: Int {
        switch self {
        case .single: return 1
        case .sideBySide, .stacked: return 2
        case .primaryPlusTwo, .threeColumns, .threeRows: return 3
        case .grid2x2: return 4
        case .primaryPlusFour: return 5
        case .grid3x2, .grid2x3: return 6
        case .grid3x3: return 9
        }
    }

    /// Presets offered for a workspace that can show at most `capacity` tiles.
    static func available(capacity: Int) -> [WorkspacePreset] {
        allCases.filter { $0.slotCount <= capacity }
    }

    /// The natural preset for `count` tiles on a workspace of this shape.
    static func natural(for count: Int, landscape: Bool) -> WorkspacePreset {
        switch count {
        case ...1: return .single
        case 2: return landscape ? .sideBySide : .stacked
        case 3: return landscape ? .primaryPlusTwo : .threeRows
        case 4: return .grid2x2
        case 5: return .primaryPlusFour
        case 6: return landscape ? .grid3x2 : .grid2x3
        default: return .grid3x3
        }
    }

    /// Slots in reading order, filled with `tiles` (missing tiles leave empty slots).
    func node(tiles: [String?]) -> WorkspaceNode {
        var queue = tiles
        func next() -> WorkspaceNode {
            .slot(queue.isEmpty ? nil : queue.removeFirst())
        }
        func even(_ axis: WorkspaceAxis, _ count: Int, _ make: () -> WorkspaceNode) -> WorkspaceNode {
            let children = (0..<count).map { _ in make() }
            return .split(axis, children, Array(repeating: 1.0 / Double(count), count: count))
        }
        switch self {
        case .single: return next()
        case .sideBySide: return even(.horizontal, 2, next)
        case .stacked: return even(.vertical, 2, next)
        case .threeColumns: return even(.horizontal, 3, next)
        case .threeRows: return even(.vertical, 3, next)
        case .primaryPlusTwo:
            let primary = next()
            return .split(.horizontal, [primary, even(.vertical, 2, next)], [0.62, 0.38])
        case .primaryPlusFour:
            let primary = next()
            return .split(.horizontal, [primary, even(.vertical, 4, next)], [0.62, 0.38])
        case .grid2x2: return even(.vertical, 2) { even(.horizontal, 2, next) }
        case .grid3x2: return even(.vertical, 2) { even(.horizontal, 3, next) }
        case .grid2x3: return even(.vertical, 3) { even(.horizontal, 2, next) }
        case .grid3x3: return even(.vertical, 3) { even(.horizontal, 3, next) }
        }
    }
}

/// Which edge of a slot a dragged tile was dropped on.
enum WorkspaceEdge: String, Codable, Sendable {
    case left, right, top, bottom

    var axis: WorkspaceAxis { self == .left || self == .right ? .horizontal : .vertical }
    var leading: Bool { self == .left || self == .top }
}

/// Where a drag would land, with the rect to preview before release.
enum WorkspaceDropTarget: Equatable, Sendable {
    /// Swap with the tile in this slot, or move into it when it is empty.
    case slot(index: Int, preview: WorkspaceRect)
    /// Split this slot and insert on `edge`.
    case split(index: Int, edge: WorkspaceEdge, preview: WorkspaceRect)
}

/// Where a window dropped on the workspace goes.
enum WorkspaceWindowDrop: Equatable, Sendable {
    /// Show it in this pane instead of its window.
    case replace(tile: String, preview: WorkspaceRect)
    /// Add it to this pane as another tab.
    case tab(tile: String, preview: WorkspaceRect)
    /// A new pane beside the one in slot `index`.
    case split(index: Int, edge: WorkspaceEdge, preview: WorkspaceRect)
    /// Fill this empty slot.
    case emptySlot(index: Int, preview: WorkspaceRect)

    var preview: WorkspaceRect {
        switch self {
        case .replace(_, let p), .tab(_, let p), .split(_, _, let p), .emptySlot(_, let p): return p
        }
    }
}

/// The workspace a receiver arranges. Value type: every operation returns a
/// new layout, so undo is a stack of values and nothing is half-applied.
struct WorkspaceLayout: Equatable, Sendable {
    static let schema = 2
    /// Hard ceiling on tiles in one workspace (iPad / expanded Android).
    static let maximumTiles = 9

    var root: WorkspaceNode
    var tiles: [String: WorkspaceTile]
    /// A tile temporarily filling the workspace; the tree is kept for restore.
    var maximized: String?

    init(root: WorkspaceNode = .slot(nil), tiles: [String: WorkspaceTile] = [:], maximized: String? = nil) {
        self.root = root
        self.tiles = tiles
        self.maximized = maximized
        normalize()
    }

    init(preset: WorkspacePreset, tiles ordered: [WorkspaceTile]) {
        let used = Array(ordered.prefix(preset.slotCount))
        var map: [String: WorkspaceTile] = [:]
        for tile in used { map[tile.id] = tile }
        self.init(root: preset.node(tiles: used.map(\.id)), tiles: map)
    }

    /// Tile ids in reading order (the order slots appear in the tree).
    var orderedTileIDs: [String] { root.tileIDs }
    var slotCount: Int { root.slotCount }

    // MARK: Operations

    /// Swap two tiles' places; their sources, rotations and ids move with them.
    func swapping(_ a: String, _ b: String) -> WorkspaceLayout {
        guard a != b, tiles[a] != nil, tiles[b] != nil else { return self }
        var copy = self
        copy.root = Self.mapSlots(root) { id in id == a ? b : (id == b ? a : id) }
        return copy
    }

    /// Put a new tile into the first empty slot, or split the last slot.
    func adding(_ tile: WorkspaceTile, landscape: Bool) -> WorkspaceLayout {
        guard tiles[tile.id] == nil, tiles.count < Self.maximumTiles else { return self }
        var copy = self
        copy.tiles[tile.id] = tile
        if let empty = Self.slotIndices(root).first(where: { Self.slotID(root, at: $0) == .some(nil) }) {
            copy.root = Self.setSlot(root, at: empty, to: tile.id)
        } else {
            let last = slotCount - 1
            copy.root = Self.split(root, at: last, edge: landscape ? .right : .bottom, inserting: tile.id)
        }
        copy.maximized = nil
        copy.normalize()
        return copy
    }

    /// Remove a tile from the workspace. Its Mac window is untouched.
    func removing(_ id: String) -> WorkspaceLayout {
        guard tiles[id] != nil else { return self }
        var copy = self
        copy.tiles[id] = nil
        copy.root = Self.removeSlot(root, tileID: id)
        if copy.maximized == id { copy.maximized = nil }
        copy.normalize()
        return copy
    }

    /// Change what a tile shows without moving the tile. In a tabbed pane this replaces
    /// the active tab (nil removes it and shows the next one).
    func replacingSource(of id: String, with source: WorkspaceSource?) -> WorkspaceLayout {
        guard var tile = tiles[id] else { return self }
        if tile.source != source { tile.crop = nil }   // zoom belongs to the window it was set on
        if !tile.tabs.isEmpty, let current = tile.source, let i = tile.tabs.firstIndex(of: current) {
            if let source {
                tile.tabs[i] = source
                tile.tabs = Self.unique(tile.tabs)
            } else {
                tile.tabs.remove(at: i)
                tile.source = tile.tabs.isEmpty ? nil : tile.tabs[min(i, tile.tabs.count - 1)]
                if tile.tabs.count <= 1 { tile.tabs = [] }
                var copy = self
                copy.tiles[id] = tile
                return copy
            }
            if tile.tabs.count <= 1 { tile.tabs = [] }
        }
        tile.source = source
        var copy = self
        copy.tiles[id] = tile
        return copy
    }

    private static func unique(_ list: [WorkspaceSource]) -> [WorkspaceSource] {
        var seen: [WorkspaceSource] = []
        for s in list where !seen.contains(where: { $0.host == s.host && $0.windowID == s.windowID }) { seen.append(s) }
        return seen
    }

    /// Adds a window to a pane as a new tab and shows it (the pane's current window stays as a tab).
    func addingTab(_ source: WorkspaceSource, to id: String) -> WorkspaceLayout {
        guard var tile = tiles[id] else { return self }
        guard let current = tile.source else { return replacingSource(of: id, with: source) }
        var list = tile.windows
        if !list.contains(where: { $0.host == current.host && $0.windowID == current.windowID }) { list.append(current) }
        list.removeAll { $0.host == source.host && $0.windowID == source.windowID }
        list.append(source)
        tile.tabs = list.count > 1 ? list : []
        tile.source = source
        tile.crop = nil
        var copy = self
        copy.tiles[id] = tile
        return copy
    }

    /// Shows another tab of a pane (only the shown tab streams from the Mac).
    func switchingTab(of id: String, to index: Int) -> WorkspaceLayout {
        guard var tile = tiles[id], tile.tabs.indices.contains(index), tile.source != tile.tabs[index] else { return self }
        tile.source = tile.tabs[index]
        tile.crop = nil
        var copy = self
        copy.tiles[id] = tile
        return copy
    }

    /// Takes one window out of a pane's tabs (the Mac window is untouched).
    func removingTab(of id: String, at index: Int) -> WorkspaceLayout {
        guard let tile = tiles[id], tile.tabs.indices.contains(index) else { return self }
        var copy = self
        var t = tile
        let removed = t.tabs.remove(at: index)
        if t.source == removed { t.source = t.tabs.isEmpty ? nil : t.tabs[min(index, t.tabs.count - 1)]; t.crop = nil }
        if t.tabs.count <= 1 { t.tabs = [] }
        copy.tiles[id] = t
        return copy
    }

    /// The pane showing (or holding as a tab) this window, if any.
    func tile(holding host: String, windowID: UInt32) -> String? {
        orderedTileIDs.first { id in tiles[id]?.windows.contains { $0.host == host && $0.windowID == windowID } == true }
    }

    /// A new pane beside the one in slot `index` (a drop on a pane's edge).
    func insertingSplit(_ tile: WorkspaceTile, at index: Int, edge: WorkspaceEdge) -> WorkspaceLayout {
        guard tiles[tile.id] == nil, tiles.count < Self.maximumTiles, Self.slotIndices(root).contains(index) else { return self }
        var copy = self
        copy.tiles[tile.id] = tile
        copy.root = Self.split(root, at: index, edge: edge, inserting: tile.id)
        copy.maximized = nil
        copy.normalize()
        return copy
    }

    /// Fills an empty slot with a new pane.
    func filling(slot index: Int, with tile: WorkspaceTile) -> WorkspaceLayout {
        guard tiles[tile.id] == nil, Self.slotID(root, at: index) == .some(nil) else { return self }
        var copy = self
        copy.tiles[tile.id] = tile
        copy.root = Self.setSlot(root, at: index, to: tile.id)
        copy.normalize()
        return copy
    }

    func zooming(_ id: String, to crop: WorkspaceRect?) -> WorkspaceLayout {
        guard var tile = tiles[id], tile.crop != crop else { return self }
        tile.crop = crop
        var copy = self
        copy.tiles[id] = tile
        return copy
    }

    func rotating(_ id: String) -> WorkspaceLayout {
        guard var tile = tiles[id] else { return self }
        tile.rotation = tile.rotation.clockwise
        var copy = self
        copy.tiles[id] = tile
        return copy
    }

    func settingFit(_ fit: WorkspaceFit, for id: String) -> WorkspaceLayout {
        guard var tile = tiles[id] else { return self }
        tile.fit = fit
        var copy = self
        copy.tiles[id] = tile
        return copy
    }

    func maximizing(_ id: String) -> WorkspaceLayout {
        guard tiles[id] != nil else { return self }
        var copy = self
        copy.maximized = id
        return copy
    }

    func restoringMaximized() -> WorkspaceLayout {
        var copy = self
        copy.maximized = nil
        return copy
    }

    /// Re-flow the current tiles into a preset, keeping reading order.
    /// Tiles beyond the preset's slots are kept in the returned overflow.
    func applying(_ preset: WorkspacePreset) -> (layout: WorkspaceLayout, overflow: [String]) {
        let ordered = orderedTileIDs
        let kept = Array(ordered.prefix(preset.slotCount))
        let overflow = Array(ordered.dropFirst(preset.slotCount))
        var copy = self
        copy.root = preset.node(tiles: kept)
        for id in overflow { copy.tiles[id] = nil }
        copy.maximized = nil
        copy.normalize()
        return (copy, overflow)
    }

    /// Move `id` to `target`. Dropping on its own slot does nothing.
    func moving(_ id: String, to target: WorkspaceDropTarget) -> WorkspaceLayout {
        guard tiles[id] != nil else { return self }
        switch target {
        case .slot(let index, _):
            guard let occupant = Self.slotID(root, at: index) else { return self }
            if let other = occupant {
                return swapping(id, other)
            }
            var copy = self
            copy.root = Self.mapSlots(root) { $0 == id ? nil : $0 }
            copy.root = Self.setSlot(copy.root, at: index, to: id)
            copy.normalize()
            return copy
        case .split(let index, let edge, _):
            guard let occupant = Self.slotID(root, at: index), occupant != id else { return self }
            // Mark the target and the tile's old slot, close only the old
            // slot (other empty slots stay), then split the marked target.
            let marker = "\u{0}target", gone = "\u{0}gone"
            var tree = Self.setSlot(root, at: index, to: occupant ?? marker)
            tree = Self.mapSlots(tree) { $0 == id ? gone : $0 }
            tree = Self.removeSlot(tree, tileID: gone)
            guard let markedIndex = Self.slotIndices(tree).first(where: {
                Self.slotID(tree, at: $0) == .some(occupant ?? marker)
            }) else { return self }
            tree = Self.split(tree, at: markedIndex, edge: edge, inserting: id)
            if occupant == nil { tree = Self.mapSlots(tree) { $0 == marker ? nil : $0 } }
            var copy = self
            copy.root = tree
            copy.maximized = nil
            copy.normalize()
            return copy
        }
    }

    /// The tree as laid out beside `hinge`, so the slot on the hinge's far side
    /// (which `WorkspaceGeometry.frames` shows as a drop target) becomes a real
    /// slot before a tile is moved into it. Unchanged without a hinge.
    func materializing(hinge: WorkspaceHinge?) -> WorkspaceLayout {
        var copy = self
        copy.root = WorkspaceGeometry.hingeAdjustedRoot(root, hinge: hinge)
        return copy
    }

    // MARK: Validation

    /// Keep the tree and the tile table consistent: drop slots naming unknown
    /// or duplicate tiles, drop tiles with no slot, fix ratios, flatten
    /// single-child splits. Called by every init and operation, and on decode.
    mutating func normalize() {
        var seen = Set<String>()
        root = Self.mapSlots(root) { id in
            guard let id, self.tiles[id] != nil, !seen.contains(id) else { return nil }
            seen.insert(id)
            return id
        }
        for id in Array(tiles.keys) where !seen.contains(id) { tiles[id] = nil }
        root = Self.normalizeNode(root)
        if let m = maximized, tiles[m] == nil { maximized = nil }
    }

    // MARK: Tree helpers (pure)

    static func slotIndices(_ node: WorkspaceNode) -> Range<Int> { 0..<node.slotCount }

    /// `.some(nil)` is an empty slot; `nil` means no such slot.
    static func slotID(_ node: WorkspaceNode, at index: Int) -> String?? {
        var i = index
        func walk(_ n: WorkspaceNode) -> String?? {
            switch n {
            case .slot(let id):
                if i == 0 { return .some(id) }
                i -= 1
                return nil
            case .split(_, let children, _):
                for child in children {
                    if let found = walk(child) { return found }
                }
                return nil
            }
        }
        return walk(node)
    }

    static func mapSlots(_ node: WorkspaceNode, _ transform: (String?) -> String?) -> WorkspaceNode {
        switch node {
        case .slot(let id): return .slot(transform(id))
        case .split(let axis, let children, let ratios):
            return .split(axis, children.map { mapSlots($0, transform) }, ratios)
        }
    }

    static func setSlot(_ node: WorkspaceNode, at index: Int, to id: String?) -> WorkspaceNode {
        var i = index
        func walk(_ n: WorkspaceNode) -> WorkspaceNode {
            switch n {
            case .slot(let old):
                defer { i -= 1 }
                return i == 0 ? .slot(id) : .slot(old)
            case .split(let axis, let children, let ratios):
                return .split(axis, children.map(walk), ratios)
            }
        }
        return walk(node)
    }

    static func split(_ node: WorkspaceNode, at index: Int, edge: WorkspaceEdge, inserting id: String) -> WorkspaceNode {
        var i = index
        func walk(_ n: WorkspaceNode) -> WorkspaceNode {
            switch n {
            case .slot(let old):
                defer { i -= 1 }
                guard i == 0 else { return .slot(old) }
                let pair: [WorkspaceNode] = edge.leading ? [.slot(id), .slot(old)] : [.slot(old), .slot(id)]
                return .split(edge.axis, pair, [0.5, 0.5])
            case .split(let axis, let children, let ratios):
                return .split(axis, children.map(walk), ratios)
            }
        }
        return walk(node)
    }

    static func removeSlot(_ node: WorkspaceNode, tileID: String) -> WorkspaceNode {
        switch node {
        case .slot(let id): return .slot(id == tileID ? nil : id)
        case .split(let axis, let children, let ratios):
            var kept: [WorkspaceNode] = []
            var keptRatios: [Double] = []
            for (child, ratio) in zip(children, ratios) {
                if case .slot(let id) = child, id == tileID { continue }
                kept.append(removeSlot(child, tileID: tileID))
                keptRatios.append(ratio)
            }
            if kept.isEmpty { return .slot(nil) }
            return .split(axis, kept, keptRatios)
        }
    }

    /// Remove empty slots (used while moving a tile so its old place closes).
    static func collapseEmptySlots(_ node: WorkspaceNode, keeping: Set<String>) -> WorkspaceNode {
        switch node {
        case .slot: return node
        case .split(let axis, let children, let ratios):
            var kept: [WorkspaceNode] = []
            var keptRatios: [Double] = []
            for (child, ratio) in zip(children, ratios) {
                if case .slot(nil) = child { continue }
                kept.append(collapseEmptySlots(child, keeping: keeping))
                keptRatios.append(ratio)
            }
            if kept.isEmpty { return .slot(nil) }
            return .split(axis, kept, keptRatios)
        }
    }

    static func normalizeNode(_ node: WorkspaceNode) -> WorkspaceNode {
        switch node {
        case .slot: return node
        case .split(let axis, let children, let ratios):
            var flat: [WorkspaceNode] = []
            var flatRatios: [Double] = []
            let safe = ratios.count == children.count ? ratios : Array(repeating: 1, count: children.count)
            for (child, raw) in zip(children, safe) {
                let ratio = raw.isFinite && raw > 0 ? raw : 1.0 / Double(max(children.count, 1))
                let normalized = normalizeNode(child)
                // A child split on the same axis merges into this one.
                if case .split(let childAxis, let grand, let grandRatios) = normalized, childAxis == axis {
                    let total = grandRatios.reduce(0, +)
                    for (g, r) in zip(grand, grandRatios) {
                        flat.append(g)
                        flatRatios.append(ratio * r / max(total, 1e-12))
                    }
                } else {
                    flat.append(normalized)
                    flatRatios.append(ratio)
                }
            }
            if flat.isEmpty { return .slot(nil) }
            if flat.count == 1 { return flat[0] }
            let total = flatRatios.reduce(0, +)
            return .split(axis, flat, flatRatios.map { $0 / total })
        }
    }
}

// MARK: - Geometry: frames, dividers, hinge, capacity

/// A separating or occluding display feature (a hinge or fold), normalized.
/// Nothing interactive is placed inside it.
struct WorkspaceHinge: Equatable, Codable, Sendable {
    var rect: WorkspaceRect
    /// `.horizontal` hinge = a band across the screen (tabletop); `.vertical` = book.
    var orientation: WorkspaceAxis
}

enum WorkspaceSizeClass: String, Codable, Sendable {
    /// Phones and folded covers.
    case compact
    /// Tablets, unfolded foldables, large Mac windows.
    case expanded

    /// Up to 9 panes everywhere (2x2 and 3x3 grids on phones too); the minimum pane
    /// size decides how many actually fit the space.
    var tileLimit: Int { 9 }

    /// From the usable window size in points/dp (not the screen, not the model).
    static func of(_ size: WorkspaceSize) -> WorkspaceSizeClass {
        let short = min(size.width, size.height), long = max(size.width, size.height)
        return short >= 600 && long >= 800 ? .expanded : .compact
    }
}

struct WorkspaceDivider: Equatable, Sendable {
    /// Path of the split node in the tree (child indices) plus the divider index.
    var path: [Int]
    var index: Int
    var axis: WorkspaceAxis
    /// Normalized hit area (wider than the drawn line).
    var hitRect: WorkspaceRect
}

struct WorkspaceFrames: Equatable, Sendable {
    /// Normalized rect per tile id.
    var tiles: [String: WorkspaceRect]
    /// Normalized rect per slot index (empty slots included).
    var slots: [WorkspaceRect]
    var dividers: [WorkspaceDivider]
}

enum WorkspaceGeometry {
    /// Minimum usable tile, in points. Smaller tiles are not offered.
    static let minimumTile = WorkspaceSize(width: 120, height: 90)
    /// Divider grab width in points.
    static let dividerHitWidth: Double = 24

    /// How many tiles fit: the size-class limit, further limited so every
    /// tile in the natural preset keeps its minimum size.
    static func capacity(for size: WorkspaceSize, hinge: WorkspaceHinge? = nil) -> Int {
        let limit = WorkspaceSizeClass.of(size).tileLimit
        let landscape = size.width >= size.height
        for count in stride(from: limit, through: 1, by: -1) {
            let preset = WorkspacePreset.natural(for: count, landscape: landscape)
            let ids = (0..<count).map { "c\($0)" }
            var map: [String: WorkspaceTile] = [:]
            for id in ids { map[id] = WorkspaceTile(id: id) }
            let layout = WorkspaceLayout(root: preset.node(tiles: ids), tiles: map)
            let frames = self.frames(for: layout, in: size, hinge: hinge)
            let fits = frames.slots.allSatisfy {
                $0.width * size.width >= minimumTile.width - 0.5 && $0.height * size.height >= minimumTile.height - 0.5
            }
            if fits { return count }
        }
        return 1
    }

    static func frames(for layout: WorkspaceLayout, in size: WorkspaceSize, hinge: WorkspaceHinge? = nil) -> WorkspaceFrames {
        if let m = layout.maximized {
            let region = hinge.map { largestRegion(beside: $0) } ?? .unit
            let index = (0..<layout.slotCount).first { WorkspaceLayout.slotID(layout.root, at: $0) == .some(m) } ?? 0
            var slots = Array(repeating: WorkspaceRect(x: 0, y: 0, width: 0, height: 0), count: layout.slotCount)
            if index < slots.count { slots[index] = region }
            return WorkspaceFrames(tiles: [m: region], slots: slots, dividers: [])
        }
        var slots: [WorkspaceRect] = []
        var dividers: [WorkspaceDivider] = []
        let hitW = dividerHitWidth
        func place(_ node: WorkspaceNode, in rect: WorkspaceRect, path: [Int]) {
            switch node {
            case .slot:
                slots.append(rect)
            case .split(let axis, let children, let ratios):
                let bounds = splitBounds(axis: axis, rect: rect, ratios: ratios, hinge: hinge)
                for (i, child) in children.enumerated() {
                    place(child, in: bounds[i], path: path + [i])
                    if i < children.count - 1 {
                        let a = bounds[i], b = bounds[i + 1]
                        let hit: WorkspaceRect
                        if axis == .horizontal {
                            let cx = (a.maxX + b.x) / 2, w = hitW / max(size.width, 1)
                            hit = WorkspaceRect(x: cx - w / 2, y: rect.y, width: w, height: rect.height)
                        } else {
                            let cy = (a.maxY + b.y) / 2, h = hitW / max(size.height, 1)
                            hit = WorkspaceRect(x: rect.x, y: cy - h / 2, width: rect.width, height: h)
                        }
                        dividers.append(WorkspaceDivider(path: path, index: i, axis: axis, hitRect: hit))
                    }
                }
            }
        }
        let root = hingeAdjustedRoot(layout.root, hinge: hinge)
        place(root, in: .unit, path: [])
        // Slot order is the tree's reading order; the hinge wrapper only ever
        // appends one trailing empty slot, which stays last.
        var tiles: [String: WorkspaceRect] = [:]
        for (i, rect) in slots.enumerated() {
            if case .some(.some(let id)) = WorkspaceLayout.slotID(root, at: i) { tiles[id] = rect }
        }
        return WorkspaceFrames(tiles: tiles, slots: slots, dividers: dividers)
    }

    /// With a separating hinge and a tree that doesn't split along it, the
    /// whole arrangement goes on one side and the other side is an empty slot
    /// (a drop target, or the control surface in tabletop posture). A tree
    /// that does split along the hinge keeps its children on either side.
    static func hingeAdjustedRoot(_ root: WorkspaceNode, hinge: WorkspaceHinge?) -> WorkspaceNode {
        guard let hinge else { return root }
        // A vertical hinge separates left/right, i.e. a horizontal split.
        let splitAxis: WorkspaceAxis = hinge.orientation == .vertical ? .horizontal : .vertical
        if case .split(let axis, let children, _) = root, axis == splitAxis, children.count >= 2 { return root }
        let first = hinge.orientation == .vertical ? hinge.rect.x : hinge.rect.y
        return .split(splitAxis, [root, .slot(nil)], [first, 1 - first])
    }

    /// Child rects for a split. When a separating hinge crosses this split
    /// along its axis, the divider nearest the hinge snaps to it and the
    /// hinge band is excluded, so no child straddles the fold.
    static func splitBounds(axis: WorkspaceAxis, rect: WorkspaceRect, ratios: [Double], hinge: WorkspaceHinge?) -> [WorkspaceRect] {
        let start = axis == .horizontal ? rect.x : rect.y
        let extent = axis == .horizontal ? rect.width : rect.height
        var edges: [Double] = [start]
        var acc = start
        for r in ratios { acc += r * extent; edges.append(acc) }
        edges[edges.count - 1] = start + extent
        var gaps = Array(repeating: (0.0, 0.0), count: ratios.count)   // (lead trim, trail trim) per child
        if let hinge, ratios.count >= 2 {
            let crosses = (axis == .horizontal && hinge.orientation == .vertical) || (axis == .vertical && hinge.orientation == .horizontal)
            let h0 = axis == .horizontal ? hinge.rect.x : hinge.rect.y
            let h1 = axis == .horizontal ? hinge.rect.maxX : hinge.rect.maxY
            let spansRect = axis == .horizontal
                ? (hinge.rect.y <= rect.y + 1e-9 && hinge.rect.maxY >= rect.maxY - 1e-9)
                : (hinge.rect.x <= rect.x + 1e-9 && hinge.rect.maxX >= rect.maxX - 1e-9)
            if crosses, spansRect, h0 > start, h1 < start + extent {
                let mid = (h0 + h1) / 2
                var best = 1
                for i in 1..<(edges.count - 1) where abs(edges[i] - mid) < abs(edges[best] - mid) { best = i }
                edges[best] = mid
                gaps[best - 1].1 = mid - h0
                gaps[best].0 = h1 - mid
                // Keep edges monotonic if the snap overtook a neighbour.
                for i in 1..<best where edges[i] > edges[best] { edges[i] = edges[best] }
                for i in (best + 1)..<(edges.count - 1) where edges[i] < edges[best] { edges[i] = edges[best] }
            }
        }
        return (0..<ratios.count).map { i in
            let a = edges[i] + gaps[i].0, b = max(edges[i + 1] - gaps[i].1, a)
            return axis == .horizontal
                ? WorkspaceRect(x: a, y: rect.y, width: b - a, height: rect.height)
                : WorkspaceRect(x: rect.x, y: a, width: rect.width, height: b - a)
        }
    }

    static func largestRegion(beside hinge: WorkspaceHinge) -> WorkspaceRect {
        if hinge.orientation == .vertical {
            let left = WorkspaceRect(x: 0, y: 0, width: hinge.rect.x, height: 1)
            let right = WorkspaceRect(x: hinge.rect.maxX, y: 0, width: 1 - hinge.rect.maxX, height: 1)
            return left.area >= right.area ? left : right
        }
        let top = WorkspaceRect(x: 0, y: 0, width: 1, height: hinge.rect.y)
        let bottom = WorkspaceRect(x: 0, y: hinge.rect.maxY, width: 1, height: 1 - hinge.rect.maxY)
        return top.area >= bottom.area ? top : bottom
    }

    /// The drop target under `point` while dragging a tile. The middle of a
    /// slot swaps (or fills an empty slot); a band along each edge splits.
    /// Corners resolve to the edge on the slot's longer side, so a corner drop
    /// produces a half on that side. Hinge band: no target.
    static func dropTarget(at point: WorkspacePoint, frames: WorkspaceFrames, size: WorkspaceSize,
                           hinge: WorkspaceHinge? = nil, canSplit: Bool) -> WorkspaceDropTarget? {
        if let hinge, hinge.rect.contains(point) { return nil }
        guard let index = frames.slots.firstIndex(where: { $0.contains(point) }) else { return nil }
        let slot = frames.slots[index]
        guard canSplit else { return .slot(index: index, preview: slot) }
        let px = slot.width * size.width, py = slot.height * size.height
        let band = 0.22
        let fx = (point.x - slot.x) / max(slot.width, 1e-12)
        let fy = (point.y - slot.y) / max(slot.height, 1e-12)
        let nearLeft = fx < band, nearRight = fx > 1 - band
        let nearTop = fy < band, nearBottom = fy > 1 - band
        var edge: WorkspaceEdge?
        let horizontalNear = nearLeft || nearRight, verticalNear = nearTop || nearBottom
        if horizontalNear && verticalNear {
            edge = px >= py ? (nearLeft ? .left : .right) : (nearTop ? .top : .bottom)
        } else if horizontalNear {
            edge = nearLeft ? .left : .right
        } else if verticalNear {
            edge = nearTop ? .top : .bottom
        }
        guard let edge else { return .slot(index: index, preview: slot) }
        // A split that would make either half smaller than a tile becomes a swap.
        let halfW = edge.axis == .horizontal ? px / 2 : px
        let halfH = edge.axis == .vertical ? py / 2 : py
        guard halfW >= minimumTile.width, halfH >= minimumTile.height else {
            return .slot(index: index, preview: slot)
        }
        let preview: WorkspaceRect
        switch edge {
        case .left: preview = WorkspaceRect(x: slot.x, y: slot.y, width: slot.width / 2, height: slot.height)
        case .right: preview = WorkspaceRect(x: slot.midX, y: slot.y, width: slot.width / 2, height: slot.height)
        case .top: preview = WorkspaceRect(x: slot.x, y: slot.y, width: slot.width, height: slot.height / 2)
        case .bottom: preview = WorkspaceRect(x: slot.x, y: slot.midY, width: slot.width, height: slot.height / 2)
        }
        return .split(index: index, edge: edge, preview: preview)
    }

    /// Where a window dragged from Stage Peek (or a file) lands on the panes:
    /// the pane's label strip adds it as a tab, a band along an edge splits the pane,
    /// the middle replaces the pane's window. `labelHeight` is the label strip's
    /// height normalized to the workspace.
    static func windowDrop(at point: WorkspacePoint, layout: WorkspaceLayout, frames: WorkspaceFrames, size: WorkspaceSize,
                           labelHeight: Double, canSplit: Bool) -> WorkspaceWindowDrop? {
        guard let index = frames.slots.firstIndex(where: { $0.contains(point) }) else { return nil }
        let slot = frames.slots[index]
        guard let occupant = WorkspaceLayout.slotID(layout.root, at: index) else { return nil }
        guard let tile = occupant, layout.tiles[tile]?.source != nil else { return .emptySlot(index: index, preview: slot) }
        let strip = min(labelHeight * 1.6, slot.height * 0.25)
        if point.y - slot.y <= strip {
            return .tab(tile: tile, preview: WorkspaceRect(x: slot.x, y: slot.y, width: slot.width, height: strip))
        }
        if canSplit, case .split(let i, let edge, let preview)? = dropTarget(at: point, frames: frames, size: size, canSplit: true), i == index {
            return .split(index: i, edge: edge, preview: preview)
        }
        return .replace(tile: tile, preview: slot)
    }

    /// Move a divider by `delta` (normalized workspace units along its axis).
    /// Both neighbours keep at least the minimum size of everything inside
    /// them; the move is clamped, never rejected, so dragging past a limit
    /// just stops there.
    static func resizing(_ layout: WorkspaceLayout, divider: WorkspaceDivider, delta: Double, in size: WorkspaceSize) -> WorkspaceLayout {
        guard delta.isFinite else { return layout }
        func walk(_ node: WorkspaceNode, _ path: ArraySlice<Int>, rect: WorkspaceRect) -> WorkspaceNode {
            guard case .split(let axis, var children, var ratios) = node else { return node }
            if path.isEmpty {
                guard axis == divider.axis, divider.index + 1 < ratios.count else { return node }
                let extentPts = axis == .horizontal ? rect.width * size.width : rect.height * size.height
                let extentNorm = axis == .horizontal ? rect.width : rect.height
                guard extentPts > 0, extentNorm > 0 else { return node }
                let i = divider.index
                let minA = minimumExtent(children[i], axis: axis) / extentPts
                let minB = minimumExtent(children[i + 1], axis: axis) / extentPts
                let pair = ratios[i] + ratios[i + 1]
                var a = ratios[i] + delta / extentNorm
                a = min(max(a, minA), pair - minB)
                if pair - minB < minA { a = pair / 2 }   // both can't fit: split evenly, no oscillation
                ratios[i] = a
                ratios[i + 1] = pair - a
                return .split(axis, children, ratios)
            }
            let i = path.first!
            guard i < children.count else { return node }
            let bounds = splitBounds(axis: axis, rect: rect, ratios: ratios, hinge: nil)
            children[i] = walk(children[i], path.dropFirst(), rect: bounds[i])
            return .split(axis, children, ratios)
        }
        var copy = layout
        copy.root = walk(layout.root, divider.path[...], rect: .unit)
        return copy
    }

    /// Smallest extent (points) a subtree needs along `axis`.
    static func minimumExtent(_ node: WorkspaceNode, axis: WorkspaceAxis) -> Double {
        switch node {
        case .slot: return axis == .horizontal ? minimumTile.width : minimumTile.height
        case .split(let a, let children, _):
            let mins = children.map { minimumExtent($0, axis: axis) }
            return a == axis ? mins.reduce(0, +) : (mins.max() ?? 0)
        }
    }
}

// MARK: - Adapting to the available space (fold, rotation, Split View)

/// The workspace the user arranged is kept as-is. What is shown is derived
/// from it for the space available now: when fewer tiles fit, the extra tiles
/// move to a recoverable stack (never deleted), the active tile always stays
/// visible, and the saved arrangement comes back when space returns.
enum WorkspaceAdaptation {
    struct Result: Equatable, Sendable {
        var visible: WorkspaceLayout
        /// Tiles kept but not shown, in their saved reading order.
        var stacked: [String]
    }

    static func adapt(_ saved: WorkspaceLayout, to size: WorkspaceSize, hinge: WorkspaceHinge? = nil,
                      active: String?) -> Result {
        let capacity = WorkspaceGeometry.capacity(for: size, hinge: hinge)
        let ordered = saved.orderedTileIDs
        guard ordered.count > capacity else { return Result(visible: saved, stacked: []) }
        var shown = Array(ordered.prefix(capacity))
        if let active, ordered.contains(active), !shown.contains(active) {
            shown[shown.count - 1] = active
        }
        let stacked = ordered.filter { !shown.contains($0) }
        let landscape = size.width >= size.height
        let preset = WorkspacePreset.natural(for: shown.count, landscape: landscape)
        let tiles = shown.compactMap { saved.tiles[$0] }
        var visible = WorkspaceLayout(preset: preset, tiles: tiles)
        if let m = saved.maximized, shown.contains(m) { visible.maximized = m }
        return Result(visible: visible, stacked: stacked)
    }
}

// MARK: - Undo

struct WorkspaceHistory: Equatable, Sendable {
    static let depth = 20
    private(set) var past: [WorkspaceLayout] = []
    private var grouping = false
    private var groupRecorded = false

    var canUndo: Bool { !past.isEmpty }

    /// Until `endGroup()`, changes are one undo step (a divider drag sends many).
    mutating func beginGroup() {
        guard !grouping else { return }
        grouping = true
        groupRecorded = false
    }

    mutating func endGroup() {
        grouping = false
        groupRecorded = false
    }

    mutating func record(_ layout: WorkspaceLayout) {
        if grouping {
            if groupRecorded { return }
            groupRecorded = true
        }
        if past.last == layout { return }
        past.append(layout)
        if past.count > Self.depth { past.removeFirst(past.count - Self.depth) }
    }

    mutating func undo() -> WorkspaceLayout? { past.popLast() }
}

// MARK: - Persistence (schema 1, lenient)

/// Stored and wire form. Unknown fields are ignored; invalid parts are dropped
/// and the rest kept, so a layout saved by a newer version or referencing a
/// window that no longer exists still restores what it can.
struct WorkspaceLayoutRecord: Codable, Equatable, Sendable {
    struct Node: Codable, Equatable, Sendable {
        var tile: String?
        var axis: WorkspaceAxis?
        var children: [Node]?
        var ratios: [Double]?
    }

    struct Tile: Codable, Equatable, Sendable {
        var id: String
        var host: String?
        var window: UInt32?
        var bundle: String?
        var follow: String?
        var rotation: Int?
        var fit: String?
        /// A tabbed pane's windows, in label order (schema 2).
        var tabs: [TabRecord]?
    }

    struct TabRecord: Codable, Equatable, Sendable {
        var host: String
        var window: UInt32
        var bundle: String?
        var follow: String?
    }

    var schema: Int
    var root: Node
    var tiles: [Tile]
    var maximized: String?

    init(_ layout: WorkspaceLayout) {
        schema = WorkspaceLayout.schema
        func encode(_ n: WorkspaceNode) -> Node {
            switch n {
            case .slot(let id): return Node(tile: id)
            case .split(let axis, let children, let ratios):
                return Node(axis: axis, children: children.map(encode), ratios: ratios)
            }
        }
        root = encode(layout.root)
        tiles = layout.orderedTileIDs.compactMap { layout.tiles[$0] }.map {
            Tile(id: $0.id, host: $0.source?.host, window: $0.source?.windowID, bundle: $0.source?.bundleID,
                 follow: $0.source?.follow.rawValue, rotation: $0.rotation.rawValue, fit: $0.fit.rawValue,
                 tabs: $0.tabs.isEmpty ? nil : $0.tabs.map { TabRecord(host: $0.host, window: $0.windowID, bundle: $0.bundleID, follow: $0.follow.rawValue) })
        }
        maximized = layout.maximized
    }

    var layout: WorkspaceLayout {
        var depthBudget = 32
        func decode(_ n: Node) -> WorkspaceNode {
            depthBudget -= 1
            guard depthBudget > 0 else { return .slot(nil) }
            if let children = n.children, let axis = n.axis, !children.isEmpty {
                let nodes = children.prefix(WorkspaceLayout.maximumTiles).map(decode)
                let ratios = n.ratios ?? []
                return .split(axis, Array(nodes), ratios.count == nodes.count ? ratios : [])
            }
            return .slot(n.tile)
        }
        var map: [String: WorkspaceTile] = [:]
        for t in tiles.prefix(WorkspaceLayout.maximumTiles) where !t.id.isEmpty && t.id.count <= 64 {
            var source: WorkspaceSource?
            if let host = t.host, let window = t.window, !host.isEmpty {
                source = WorkspaceSource(host: host, windowID: window, bundleID: t.bundle,
                                         follow: t.follow.flatMap(WorkspaceSource.Follow.init(rawValue:)) ?? .window)
            }
            // Schema 1 saved every tile as "fit" (there was no automatic fill): start them on auto.
            let storedFit = t.fit.flatMap(WorkspaceFit.init(rawValue:))
            let fit: WorkspaceFit = schema < 2 && storedFit == .fit ? .auto : (storedFit ?? .auto)
            var tile = WorkspaceTile(id: t.id, source: source, rotation: WorkspaceRotation(degrees: t.rotation ?? 0), fit: fit)
            let tabs = (t.tabs ?? []).prefix(8).filter { !$0.host.isEmpty }.map {
                WorkspaceSource(host: $0.host, windowID: $0.window, bundleID: $0.bundle,
                                follow: $0.follow.flatMap(WorkspaceSource.Follow.init(rawValue:)) ?? .window)
            }
            if tabs.count > 1, let s = source, tabs.contains(s) { tile.tabs = Array(tabs) }
            map[t.id] = tile
        }
        return WorkspaceLayout(root: decode(root), tiles: map, maximized: maximized)
    }

    static func decode(_ data: Data) -> WorkspaceLayout? {
        guard let record = try? JSONDecoder().decode(WorkspaceLayoutRecord.self, from: data),
              record.schema >= 1 else { return nil }
        return record.layout
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}
