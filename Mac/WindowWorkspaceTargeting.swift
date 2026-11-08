import CoreGraphics
import Foundation

// The sender's authoritative view of a receiver's window workspace: which
// tile shows which window, and where an input event in the receiver's canvas
// lands on the Mac. Pure so every routing rule is unit tested; the live
// engine (WindowWorkspaceEngine) feeds it window frames and acts on its answers.
//
// Trust: the receiver only proposes tiles. A tile is accepted only for a
// window this Mac listed to this session with the same identity generation;
// a stale or reused id is refused, never retargeted.

/// Mac-wide switch for Window mode (default on). Off: the welcome doesn't
/// offer it and every window-catalog message is ignored.
enum WindowStreamingPolicy {
    static let defaultsKey = "allowWindowStreaming"

    static func isAllowed(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

struct WorkspaceTileAssignment: Equatable, Sendable {
    var tileID: String
    /// Normalized to the canvas.
    var rect: WorkspaceRect
    var windowID: UInt32
    var windowGeneration: UInt64
    var pid: Int32
    var bundleID: String
    var follow: WorkspaceSource.Follow
    var rotation: WorkspaceRotation
    var fit: WorkspaceFit
    /// This pane's own zoom (0.7x-8x of its fit/fill size) and centre. The whole source is
    /// always captured; the zoom is applied when composing, never as a capture crop.
    var zoom = WorkspacePaneZoom.identity
    /// The receiver's counter for this pane's view: echoed once a frame with it was composed.
    var viewEpoch = 0
    /// Bumped whenever this tile's window changes: frames, held input and
    /// focus from an older generation are discarded.
    var assignmentGeneration: UInt64
    /// A whole display in this tile (Full Desktop as a tile source). `windowID` is then its
    /// reserved key (`WorkspaceSource.displayKey`), so window-keyed maps never collide.
    var displayID: UInt32? = nil
    /// A floating pane (`layer: "float"`, only from a receiver that said `ws` 2 to a Mac that
    /// offers `windowFloat`): drawn after every tiled pane, in `z` order, and hit first.
    var isFloat = false
    /// Back (0) to front among the floats.
    var z = 0
    /// A float the receiver is drawing itself under the finger (moving or resizing it,
    /// `lift: true`): left out of the picture and of input, its capture kept running, so it
    /// comes back without a restart where it is let go.
    var isLifted = false
    /// A floating pane drawn in the picture now (not lifted).
    var isDrawnFloat: Bool { isFloat && !isLifted }
    /// On the canvas now: every tiled pane, and the floats that aren't lifted.
    var isOnCanvas: Bool { !isLifted }
}

enum WorkspaceRequestValidator {
    static let maxTiles = WorkspaceLayout.maximumTiles
    static let minimumTilePixels = CGSize(width: 64, height: 48)

    struct Result: Equatable {
        var assignments: [WorkspaceTileAssignment]
        /// tile id -> reason, reported back in `workspaceState`.
        var rejected: [String: String]
    }

    static func isValidTileID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 32 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        } && id.allSatisfy(\.isASCII)
    }

    /// `tiles`: the request's `tiles` array. `hostID`: this Mac's install id;
    /// tiles naming another host belong to another connection and are skipped.
    /// `displays`: the displays this Mac listed to this session (id -> global bounds); a tile may show one.
    /// `allowFloats`: the receiver speaks floating panes (`hello.ws` >= 2) and this Mac offers
    /// them (`windowFloat`). Otherwise `layer` is ignored and every tile is a tiled pane, exactly
    /// as before (a float sent anyway overlaps and is refused as `overlap`).
    ///
    /// Tiled panes may never overlap each other. Floats may overlap anything. The result lists
    /// the tiled panes first (request order), then the floats back to front by `z`: the
    /// compositor draws in that order, and `WorkspaceInputTargeting` hits it front first.
    static func validate(tiles raw: [[String: Any]], catalog: [UInt32: WindowCatalogEntry], hostID: String,
                         canvasPixels: CGSize, previous: [String: WorkspaceTileAssignment],
                         nextGeneration: inout UInt64, displays: [UInt32: CGRect] = [:], allowFloats: Bool = false) -> Result {
        var accepted: [WorkspaceTileAssignment] = []
        var rejected: [String: String] = [:]
        var seen = Set<String>()
        for item in raw.prefix(maxTiles * 2) {
            guard let id = item["id"] as? String, isValidTileID(id) else { continue }
            guard !seen.contains(id) else { rejected[id] = "duplicate"; continue }
            seen.insert(id)
            if let host = item["host"] as? String, host != hostID { continue }
            guard accepted.count < maxTiles else { rejected[id] = "limit"; continue }
            guard let x = item["x"] as? Double, let y = item["y"] as? Double,
                  let w = item["w"] as? Double, let h = item["h"] as? Double,
                  [x, y, w, h].allSatisfy(\.isFinite), x >= -1e-6, y >= -1e-6, w > 0, h > 0,
                  x + w <= 1 + 1e-6, y + h <= 1 + 1e-6 else { rejected[id] = "geometry"; continue }
            let rect = WorkspaceRect(x: max(x, 0), y: max(y, 0), width: min(w, 1 - max(x, 0)), height: min(h, 1 - max(y, 0)))
            guard rect.width * canvasPixels.width >= minimumTilePixels.width,
                  rect.height * canvasPixels.height >= minimumTilePixels.height else { rejected[id] = "tooSmall"; continue }
            let isFloat = allowFloats && (item["layer"] as? String) == "float"
            let z = isFloat ? min(max(item["z"] as? Int ?? 0, 0), maxTiles * 2) : 0
            let lifted = isFloat && (item["lift"] as? Bool) == true
            if !isFloat, accepted.contains(where: { !$0.isFloat && ($0.rect.intersection(rect)?.area ?? 0) > 1e-6 }) {
                rejected[id] = "overlap"
                continue
            }
            let rotation = WorkspaceRotation(degrees: item["rotation"] as? Int ?? 0)
            let fit = (item["fit"] as? String).flatMap(WorkspaceFit.init(rawValue:)) ?? .fit
            // Older receivers send `crop` (a capture crop); it is ignored: the pane shows the whole source.
            let zoom = WorkspacePaneZoom(wire: item["zoom"]) ?? .identity
            let epoch = min(max(item["view"] as? Int ?? 0, 0), Int(Int32.max))
            if let raw = item["display"] {
                // A whole display: only one this Mac listed, at most once in the layout.
                guard let displayID = (raw as? Int).flatMap({ UInt32(exactly: $0) }), displays[displayID] != nil else {
                    rejected[id] = "unavailable"; continue
                }
                let key = WorkspaceSource.displayKey(displayID)
                guard !accepted.contains(where: { $0.windowID == key }) else { rejected[id] = "duplicateWindow"; continue }
                var generation: UInt64
                if let old = previous[id], old.windowID == key, old.displayID == displayID {
                    generation = old.assignmentGeneration
                } else {
                    generation = nextGeneration
                    nextGeneration += 1
                }
                accepted.append(WorkspaceTileAssignment(
                    tileID: id, rect: rect, windowID: key, windowGeneration: 0, pid: 0, bundleID: "", follow: .window,
                    rotation: rotation, fit: fit, zoom: zoom, viewEpoch: epoch, assignmentGeneration: generation,
                    displayID: displayID, isFloat: isFloat, z: z, isLifted: lifted))
                continue
            }
            guard let windowNumber = (item["window"] as? Int).flatMap({ UInt32(exactly: $0) }),
                  !WorkspaceSource.isDisplayKey(windowNumber),
                  let entry = catalog[windowNumber] else { rejected[id] = "unavailable"; continue }
            // The generation is required: without it a reused id can't be told apart.
            guard let gen = (item["gen"] as? Int).flatMap({ UInt64(exactly: $0) }), gen == entry.generation else {
                rejected[id] = "unavailable"
                continue
            }
            // One window, one tile: a second tile asking for it stays empty.
            guard !accepted.contains(where: { $0.windowID == entry.windowID }) else { rejected[id] = "duplicateWindow"; continue }
            let follow = (item["follow"] as? String).flatMap(WorkspaceSource.Follow.init(rawValue:)) ?? .window
            var generation: UInt64
            if let old = previous[id], old.windowID == entry.windowID, old.windowGeneration == entry.generation {
                generation = old.assignmentGeneration
            } else {
                generation = nextGeneration
                nextGeneration += 1
            }
            accepted.append(WorkspaceTileAssignment(
                tileID: id, rect: rect, windowID: entry.windowID, windowGeneration: entry.generation, pid: entry.pid,
                bundleID: entry.bundleID, follow: follow, rotation: rotation, fit: fit,
                zoom: zoom, viewEpoch: epoch, assignmentGeneration: generation, isFloat: isFloat, z: z, isLifted: lifted))
        }
        return Result(assignments: paintOrder(accepted), rejected: rejected)
    }

    /// Tiled panes first (as requested), then floats back to front (`z`, ties in request order).
    static func paintOrder(_ list: [WorkspaceTileAssignment]) -> [WorkspaceTileAssignment] {
        guard list.contains(where: \.isFloat) else { return list }
        let floats = list.enumerated().filter { $0.element.isFloat }.sorted { ($0.element.z, $0.offset) < ($1.element.z, $1.offset) }.map(\.element)
        return list.filter { !$0.isFloat } + floats
    }
}

/// Window mode's hook in `InputInjector`: canvas point -> global Mac point,
/// or nil for "send nothing". Called with the injector's lock held.
enum InputMapPhase: Sendable { case down, drag, hover, up, scroll }

protocol InputTargetMapper: AnyObject, Sendable {
    /// `x`/`y` nil: at the workspace pointer, moved by `dx`/`dy` canvas pixels.
    func mapPointer(phase: InputMapPhase, x: Double?, y: Double?, dx: Double, dy: Double) -> CGPoint?
    /// A scroll delta in canvas pixels -> Mac points for the tile under the
    /// pointer (scale and rotation applied).
    func scrollVector(dx: Double, dy: Double) -> CGVector
    func keyboardTargetReady() -> Bool
    /// Where canvas point `x`/`y` (normalized) lands on the Mac, without
    /// changing hover, focus or bindings. Nil outside every tile.
    func locate(x: Double, y: Double) -> CGPoint?
}

/// Where one input event goes. Hover, active tile and the Mac's own focus are
/// separate: moving over a tile never changes keyboard focus; a press on a
/// tile makes it active (the engine activates its window first); a drag stays
/// bound to the tile it started in until release.
struct WorkspaceInputTargeting: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case down, move, up, scroll }

    struct Target: Equatable, Sendable {
        var tileID: String
        var windowID: UInt32
        var pid: Int32
        var assignmentGeneration: UInt64
        /// Global Mac point (points, top-left origin).
        var point: CGPoint
        /// The press lands on a tile that isn't the active one: activate first.
        var activates: Bool
    }

    var assignments: [WorkspaceTileAssignment] = []
    /// Canvas size in pixels (the encoded stream).
    var canvas: CGSize = .zero
    /// Live window frames in global points, by window id.
    var windowFrames: [UInt32: CGRect] = [:]
    private(set) var activeTile: String?
    private(set) var hoveredTile: String?
    private(set) var boundTile: String?
    /// The workspace pointer, normalized to the canvas (for relative motion).
    private(set) var pointer = WorkspacePoint(x: 0.5, y: 0.5)
    /// Trackpad mode keeps one cursor per pane and tab: where it was last, on that window's
    /// own content (normalized to the window), so it is there again when the pane gets focus,
    /// even after a zoom, pan or turn. Keyed by `cursorKey`.
    private(set) var paneCursors: [String: WorkspacePoint] = [:]
    /// The pane and tab the pointer is in now.
    private(set) var pointerKey: String?
    static let paneCursorLimit = 64

    func transform(for a: WorkspaceTileAssignment) -> TileContentTransform? {
        guard let frame = windowFrames[a.windowID], frame.width > 0, frame.height > 0 else { return nil }
        let tile = a.rect.scaled(to: WorkspaceSize(width: canvas.width, height: canvas.height))
        return TileContentTransform(tile: tile, source: WorkspaceSize(width: frame.width, height: frame.height),
                                    rotation: a.rotation, fit: a.fit, zoom: a.zoom)
    }

    /// The pane under `p`: the frontmost float that contains it, else the tiled pane (which
    /// never overlap). A pane a float covers can't be reached through the float.
    func tile(at p: WorkspacePoint) -> WorkspaceTileAssignment? {
        if let float = assignments.last(where: { $0.isDrawnFloat && $0.rect.contains(p) }) { return float }
        return assignments.first { !$0.isFloat && $0.rect.contains(p) }
    }

    /// Front to back: floats (frontmost first), then the tiled panes.
    private var frontToBack: [WorkspaceTileAssignment] {
        assignments.filter(\.isDrawnFloat).reversed() + assignments.filter { !$0.isFloat }
    }

    private func global(_ a: WorkspaceTileAssignment, _ p: WorkspacePoint, clamped: Bool) -> CGPoint? {
        guard let t = transform(for: a), let frame = windowFrames[a.windowID] else { return nil }
        let q = WorkspacePoint(x: p.x * canvas.width, y: p.y * canvas.height)
        guard let s = clamped ? t.clampedSourcePoint(fromCanvas: q) : t.sourcePoint(fromCanvas: q) else { return nil }
        return CGPoint(x: frame.minX + s.x, y: frame.minY + s.y)
    }

    private func target(_ a: WorkspaceTileAssignment, _ point: CGPoint, activates: Bool) -> Target {
        Target(tileID: a.tileID, windowID: a.windowID, pid: a.pid, assignmentGeneration: a.assignmentGeneration,
               point: point, activates: activates)
    }

    /// Resolve an absolute event at canvas point `p` (normalized). Nil means
    /// "send nothing to the Mac": letterbox, gaps, an inactive tile's hover,
    /// or a tile without a live window.
    mutating func resolve(_ phase: Phase, at p: WorkspacePoint) -> Target? {
        pointer = WorkspacePoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        if let a = assignment(boundTile) ?? tile(at: pointer) { remember(a) }
        return resolveAtCurrentPointer(phase)
    }

    private mutating func resolveAtCurrentPointer(_ phase: Phase) -> Target? {
        switch phase {
        case .down:
            guard boundTile == nil else {
                // A second press while bound (multi-button): same tile.
                guard let a = assignment(boundTile), let point = global(a, pointer, clamped: true) else { return nil }
                return target(a, point, activates: false)
            }
            guard let a = tile(at: pointer), let point = global(a, pointer, clamped: false) else { return nil }
            let activates = activeTile != a.tileID
            activeTile = a.tileID
            hoveredTile = a.tileID
            boundTile = a.tileID
            return target(a, point, activates: activates)
        case .move:
            if let a = assignment(boundTile) {
                // Bound drag: stays in its window even across tile edges.
                guard let point = global(a, pointer, clamped: true) else { return nil }
                return target(a, point, activates: false)
            }
            let a = tile(at: pointer)
            hoveredTile = a?.tileID
            // Hover reaches the Mac only over the active tile: never move the
            // Mac's pointer over another app just to simulate hover.
            guard let a, a.tileID == activeTile, let point = global(a, pointer, clamped: false) else { return nil }
            return target(a, point, activates: false)
        case .up:
            defer { boundTile = nil }
            guard let a = assignment(boundTile), let point = global(a, pointer, clamped: true) else { return nil }
            return target(a, point, activates: false)
        case .scroll:
            // The tile under the pointer, active or not; the engine scrolls it
            // only if its window is frontmost at that point.
            if let a = assignment(boundTile), let point = global(a, pointer, clamped: true) {
                return target(a, point, activates: false)
            }
            guard let a = tile(at: pointer), let point = global(a, pointer, clamped: false) else { return nil }
            return target(a, point, activates: false)
        }
    }

    /// The Mac point under canvas point `p` (normalized), changing nothing.
    func globalPoint(at p: WorkspacePoint) -> CGPoint? {
        guard let a = tile(at: p) else { return nil }
        return global(a, p, clamped: false)
    }

    /// Relative motion (Trackpad mode, mice): moves the workspace pointer in
    /// canvas pixels, then resolves like an absolute move. With a pane in focus the
    /// pointer stays on that pane's picture (another pane gets it by being focused:
    /// its label, a touch); with none it moves freely.
    mutating func resolveRelative(dx: Double, dy: Double) -> Target? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        var p = WorkspacePoint(x: pointer.x + dx / canvas.width, y: pointer.y + dy / canvas.height)
        if let a = assignment(boundTile) ?? assignment(activeTile), let box = pointerBox(a) {
            p = Self.clamp(p, to: box)
        }
        return resolve(.move, at: p)
    }

    // MARK: Pane cursors (Trackpad mode)

    /// One cursor per pane and tab.
    static func cursorKey(_ a: WorkspaceTileAssignment) -> String { "\(a.tileID)|\(a.windowID)" }

    /// Where the pointer may go in a pane (normalized canvas): the part of the pane that shows
    /// its window.
    func pointerBox(_ a: WorkspaceTileAssignment) -> WorkspaceRect? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let px = transform(for: a)?.visibleRect ?? a.rect.scaled(to: WorkspaceSize(width: canvas.width, height: canvas.height))
        guard px.width > 0, px.height > 0 else { return nil }
        return WorkspaceRect(x: px.x / canvas.width, y: px.y / canvas.height, width: px.width / canvas.width, height: px.height / canvas.height)
    }

    /// `p` kept in `box`, a hair inside the far edges so it still hit-tests as inside.
    private static func clamp(_ p: WorkspacePoint, to box: WorkspaceRect) -> WorkspacePoint {
        let eps = 1e-6
        return WorkspacePoint(x: min(max(p.x, box.x), max(box.maxX - eps, box.x)), y: min(max(p.y, box.y), max(box.maxY - eps, box.y)))
    }

    /// Notes where the pointer is on `a`'s window, for when the pane gets focus again.
    private mutating func remember(_ a: WorkspaceTileAssignment) {
        guard let t = transform(for: a), t.source.width > 0, t.source.height > 0,
              let s = t.clampedSourcePoint(fromCanvas: WorkspacePoint(x: pointer.x * canvas.width, y: pointer.y * canvas.height))
        else { return }
        let key = Self.cursorKey(a)
        if paneCursors[key] == nil, paneCursors.count >= Self.paneCursorLimit, let drop = paneCursors.keys.first(where: { $0 != pointerKey }) {
            paneCursors[drop] = nil
        }
        paneCursors[key] = WorkspacePoint(x: s.x / t.source.width, y: s.y / t.source.height)
        pointerKey = key
    }

    /// Puts the pointer in `a`: where it was last on that pane's window, or the middle of
    /// what the pane shows the first time. Kept on the picture after a zoom, pan or turn.
    private mutating func placePointer(in a: WorkspaceTileAssignment) {
        guard let box = pointerBox(a) else { return }
        var p = WorkspacePoint(x: box.x + box.width / 2, y: box.y + box.height / 2)
        if let saved = paneCursors[Self.cursorKey(a)], let t = transform(for: a) {
            let q = t.canvasPoint(fromSource: WorkspacePoint(x: saved.x * t.source.width, y: saved.y * t.source.height))
            p = Self.clamp(WorkspacePoint(x: q.x / canvas.width, y: q.y / canvas.height), to: box)
        }
        pointer = p
        remember(a)
    }

    /// Trackpad mode's cursor as the receiver draws it: the workspace pointer, with the scale
    /// and turn of the pane it is in (as `cursorPlacement`). Nil outside every pane.
    func pointerPlacement() -> (x: Double, y: Double, kx: Double, ky: Double, rotation: Int)? {
        guard canvas.width > 0, canvas.height > 0,
              let a = assignment(boundTile) ?? tile(at: pointer), let t = transform(for: a) else { return nil }
        return (pointer.x, pointer.y, t.scale / canvas.width, t.scale / canvas.height, a.rotation.rawValue)
    }

    /// Re-resolve at the current pointer (pointer buttons press where the cursor is).
    mutating func resolveAtPointer(_ phase: Phase) -> Target? { resolve(phase, at: pointer) }

    /// The keyboard target: the active tile, if it still has a live window.
    var keyboardTarget: WorkspaceTileAssignment? {
        guard let a = assignment(activeTile), windowFrames[a.windowID] != nil else { return nil }
        return a
    }

    /// A press the engine refused (covered, gone): no tile stays bound to it.
    mutating func cancelBinding() { boundTile = nil }

    mutating func setActive(_ id: String?) {
        activeTile = id.flatMap { assignment($0)?.tileID }
        if boundTile == nil, let a = assignment(activeTile), Self.cursorKey(a) != pointerKey { placePointer(in: a) }
    }

    /// New assignments (a workspace change). Returns true when held input
    /// must be released: the bound tile vanished or now shows another window.
    mutating func update(assignments new: [WorkspaceTileAssignment]) -> Bool {
        let oldBound = assignment(boundTile)
        assignments = new
        var release = false
        if let oldBound {
            let now = assignment(oldBound.tileID)
            if now?.assignmentGeneration != oldBound.assignmentGeneration {
                boundTile = nil
                release = true
            }
        }
        if assignment(activeTile) == nil { activeTile = new.count == 1 ? new.first?.tileID : nil }
        if activeTile == nil, new.count == 1 { activeTile = new.first?.tileID }
        if assignment(hoveredTile) == nil { hoveredTile = nil }
        // Forget the cursors of panes that are gone (a pane's other tabs keep theirs).
        let tiles = Set(new.map(\.tileID))
        paneCursors = paneCursors.filter { tiles.contains(String($0.key.prefix { $0 != "|" })) }
        // The focused pane's cursor stays on its picture: after a zoom, pan, turn or resize it
        // is put back on the same spot of the window; after a tab switch, where that tab had it.
        if boundTile == nil, let a = assignment(activeTile) { placePointer(in: a) }
        return release
    }

    /// The Mac's cursor in canvas coordinates (normalized), when it is over a
    /// tile's window; nil hides the remote cursor indicator.
    func canvasPoint(forGlobal g: CGPoint) -> WorkspacePoint? {
        cursorPlacement(forGlobal: g).map { WorkspacePoint(x: $0.x, y: $0.y) }
    }

    /// The cursor over a tile: where it is (normalized canvas), how big one Mac point is there
    /// (`kx`/`ky`: normalized to the canvas width and height — the pane's own scale with Fit,
    /// Fill and zoom) and the pane's rotation in degrees. The receiver sizes and turns its
    /// cursor sprite from these, so it keeps its shape in a pane of any shape.
    func cursorPlacement(forGlobal g: CGPoint) -> (x: Double, y: Double, kx: Double, ky: Double, rotation: Int)? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        for a in frontToBack {
            guard let frame = windowFrames[a.windowID], frame.contains(g), let t = transform(for: a) else { continue }
            let q = t.canvasPoint(fromSource: WorkspacePoint(x: g.x - frame.minX, y: g.y - frame.minY))
            guard let visible = t.visibleRect, visible.contains(q) else { continue }
            // Where a float covers this pane, the cursor isn't drawn over the float.
            let n = WorkspacePoint(x: q.x / canvas.width, y: q.y / canvas.height)
            if assignments.contains(where: \.isDrawnFloat), tile(at: n)?.tileID != a.tileID { continue }
            return (n.x, n.y, t.scale / canvas.width, t.scale / canvas.height, a.rotation.rawValue)
        }
        return nil
    }

    /// The text caret (a global rectangle in points) in canvas coordinates,
    /// normalized to the canvas, when it is inside the window the keyboard is
    /// typing into — the active tile, or the only tile showing a window that
    /// contains it. Nil for a caret in any other window, outside the picture
    /// of its tile (cropped away) or without a live canvas: the receiver
    /// then keeps following its last touch.
    func canvasCaretRect(forGlobal g: CGRect) -> CGRect? {
        guard canvas.width > 0, canvas.height > 0, g.minX.isFinite, g.minY.isFinite, g.width.isFinite, g.height.isFinite else { return nil }
        let centre = CGPoint(x: g.midX, y: g.midY)
        let candidates = keyboardTarget.map { [$0] } ?? frontToBack
        for a in candidates {
            guard let frame = windowFrames[a.windowID], frame.contains(centre), let t = transform(for: a) else { continue }
            let corners = [CGPoint(x: g.minX, y: g.minY), CGPoint(x: g.maxX, y: g.minY),
                           CGPoint(x: g.minX, y: g.maxY), CGPoint(x: g.maxX, y: g.maxY)].map {
                t.canvasPoint(fromSource: WorkspacePoint(x: $0.x - frame.minX, y: $0.y - frame.minY))
            }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { continue }
            guard let visible = t.visibleRect,
                  visible.contains(WorkspacePoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)) else { continue }
            // A caret a float covers isn't followed (the receiver keeps following its last touch).
            if assignments.contains(where: \.isDrawnFloat),
               tile(at: WorkspacePoint(x: (minX + maxX) / 2 / canvas.width, y: (minY + maxY) / 2 / canvas.height))?.tileID != a.tileID { continue }
            return CGRect(x: minX / canvas.width, y: minY / canvas.height,
                          width: (maxX - minX) / canvas.width, height: (maxY - minY) / canvas.height)
        }
        return nil
    }

    /// A canvas-pixel delta in the tile under the pointer, in that window's
    /// points (its scale and rotation undone).
    func sourceVector(dx: Double, dy: Double) -> CGVector {
        guard let a = assignment(boundTile) ?? tile(at: pointer), let t = transform(for: a) else {
            return CGVector(dx: dx / 2, dy: dy / 2)
        }
        let v = t.sourceVector(fromCanvas: WorkspacePoint(x: dx, y: dy))
        return CGVector(dx: v.x, dy: v.y)
    }

    func assignment(_ id: String?) -> WorkspaceTileAssignment? {
        guard let id else { return nil }
        return assignments.first { $0.tileID == id }
    }
}

/// Keyboard arbitration: macOS has ONE keyboard focus per login session, so
/// keys go only to the active tile, and only while the Mac really has that
/// window's app in front. Otherwise nothing is typed and the receiver is told.
enum WorkspaceKeyboardGate {
    enum Decision: String, Equatable, Sendable {
        case deliver
        /// No active tile (several tiles, none chosen yet).
        case noActiveTile
        /// The Mac's frontmost app isn't the active tile's app.
        case hostFocusElsewhere
        /// The app is in front but a different, unrelated window has focus.
        case otherWindowFocused
    }

    /// `focusedWindowIsChild`: the focused window is a dialog/sheet/panel of
    /// the same app (followed as part of the tile).
    /// Which tiled window the Mac's focused window is, by frame (AX has no window
    /// id). The active tile's own window is checked first, so another tile's
    /// window with the same frame never takes its place. 0: some untiled window;
    /// nil: a dialog or panel of the app (its child).
    static func focusedTileWindow(active: UInt32, focusedFrame: CGRect, isChild: Bool, frames: [UInt32: CGRect],
                                  matches: (CGRect, CGRect) -> Bool) -> UInt32? {
        if let own = frames[active], matches(own, focusedFrame) { return active }
        return frames.first { matches($0.value, focusedFrame) }?.key ?? (isChild ? nil : 0)
    }

    static func decide(active: WorkspaceTileAssignment?, frontmostPID: Int32?, focusedWindowID: UInt32?,
                       focusedWindowIsChild: Bool) -> Decision {
        guard let active else { return .noActiveTile }
        // A desktop tile types wherever the Mac's focus is, as Mirror does.
        if active.displayID != nil { return .deliver }
        guard frontmostPID == active.pid else { return .hostFocusElsewhere }
        guard let focusedWindowID else { return .deliver }   // app in front, no window info (AX unavailable): its own window or nothing
        if focusedWindowID == active.windowID || focusedWindowIsChild || active.follow == .app { return .deliver }
        return .otherWindowFocused
    }
}

/// When a new window listing must resize or re-rate running captures (#138).
/// Capture size follows the tile's source frame: a window that enters or
/// leaves full screen, is resized, or moves to a display with another scale
/// needs a new size, or the pane stays soft (or oversized) until some other
/// layout change. A tile going off screen or coming back changes its budget.
/// `WorkspaceWindowCapture.update` skips a stream whose size and rate are
/// unchanged, so a false positive costs nothing but a check.
enum WorkspaceCaptureRetune {
    static func needed(oldFrames: [UInt32: CGRect], newFrames: [UInt32: CGRect],
                       oldStates: [String: String], newStates: [String: String]) -> Bool {
        let frameChanged = newFrames.contains { window, frame in
            oldFrames[window].map { $0 != frame } ?? false
        }
        let availabilityChanged = newStates.contains { tile, state in
            oldStates[tile].map { ($0 == "offscreen") != (state == "offscreen") } ?? false
        }
        return frameChanged || availabilityChanged
    }
}

/// Per-tile capture budget: the active tile at the stream rate, the rest
/// reduced as more tiles share one encoder; paused windows cost nothing.
enum WorkspaceCaptureBudget {
    /// A tiled pane that floats hide at least this much is captured at `coveredFPS` only.
    static let coveredShare = 0.9
    static let coveredFPS = 2
    /// A visible floating pane never drops below this (it is usually what someone watches).
    static let floatFloorFPS = 15

    /// `covered`: the share of a tiled pane hidden by floats. `isFloat`: a floating pane.
    static func fps(isActive: Bool, tileCount: Int, streamFPS: Int, available: Bool,
                    covered: Double = 0, isFloat: Bool = false) -> Int {
        guard available else { return 0 }
        if isActive || tileCount == 1 { return streamFPS }
        if !isFloat, covered >= coveredShare { return min(streamFPS, coveredFPS) }
        let shared: Int
        switch tileCount {
        case ...3: shared = min(streamFPS, 30)
        case 4...6: shared = min(streamFPS, 15)
        default: shared = min(streamFPS, 10)
        }
        return isFloat ? max(shared, min(streamFPS, floatFloorFPS)) : shared
    }

    /// How much of each tiled pane the floats hide (floats: 0). A lifted float hides nothing:
    /// the panes under it are on screen while the receiver moves it.
    static func coverage(_ assignments: [WorkspaceTileAssignment]) -> [String: Double] {
        let floats = assignments.filter(\.isDrawnFloat).map(\.rect)
        guard !floats.isEmpty else { return [:] }
        var out: [String: Double] = [:]
        for a in assignments where !a.isFloat { out[a.tileID] = WorkspaceOcclusion.coveredFraction(of: a.rect, by: floats) }
        return out
    }

    /// Capture size for a tile: its share of the canvas (rotated to the
    /// window's orientation), never above the window's own pixels, even.
    static func captureSize(tilePixels: CGSize, window: CGSize, backingScale: Double, rotation: WorkspaceRotation,
                            fit: WorkspaceFit = .fit) -> CGSize {
        let tile = rotation.isQuarterTurn ? CGSize(width: tilePixels.height, height: tilePixels.width) : tilePixels
        guard window.width > 0, window.height > 0 else { return CGSize(width: 2, height: 2) }
        // The window's aspect at the size it is drawn in the tile (fill draws
        // it larger and crops), never above its own pixels.
        let sx = tile.width / window.width, sy = tile.height / window.height
        let resolved = WorkspaceFit.resolved(fit, tile: WorkspaceSize(width: tile.width, height: tile.height),
                                             source: WorkspaceSize(width: window.width, height: window.height))
        let s = min(resolved == .fit ? min(sx, sy) : max(sx, sy), backingScale)
        let w = max(Int((window.width * s).rounded()) & ~1, 2), h = max(Int((window.height * s).rounded()) & ~1, 2)
        return CGSize(width: w, height: h)
    }
}

/// One pane's capture health: is it live, still starting, paused by macOS, or stuck?
/// Pure, so the rules are tested; the engine acts on the verdict.
///
/// Measured on macOS 27 with Stage Manager on: a window in the side strip delivers one frame
/// with status `.suspended` and nothing more, while ScreenCaptureKit still lists it on screen
/// (its frame is the strip thumbnail's). Before this, such a pane said "Waiting…" forever.
enum TileCaptureWatch {
    enum Verdict: Equatable { case waiting, live, paused, stalled }

    /// No complete frame this long after starting (and not paused): the stream is stuck.
    static let firstFrameTimeout: TimeInterval = 4
    /// Paused although the catalog says the window is on the stage: restart after this long. A
    /// stream rebuilt after the window left the strip went live within a second (capture lab
    /// 2026-10-30), so a short wait brings a returning window back quickly.
    static let pausedOnStageTimeout: TimeInterval = 2
    /// Restarts back off; after the last one the pane says it failed and offers Retry.
    static let backoff: [TimeInterval] = [1, 2, 4, 8, 16]

    static func verdict(now: TimeInterval, startedAt: TimeInterval, firstCompleteAt: TimeInterval?,
                        suspendedSince: TimeInterval?, sourceLooksAvailable: Bool, missionControlOpen: Bool = false) -> Verdict {
        // Mission Control pauses every window capture (2026-10-31 log: panes "paused by macOS",
        // then restarted as if stuck). While it is open nothing is stuck: wait for it to close.
        if missionControlOpen {
            if firstCompleteAt != nil, suspendedSince == nil { return .live }
            return .paused
        }
        if let since = suspendedSince {
            // macOS paused it (Stage Manager's strip, a hidden Space). A pause the catalog can't
            // explain (the window is on the stage again) gets a fresh stream.
            return sourceLooksAvailable && now - since >= pausedOnStageTimeout ? .stalled : .paused
        }
        // Frames came: the stream works, even if the content is static now (no new frames).
        if firstCompleteAt != nil { return .live }
        return now - startedAt >= firstFrameTimeout ? .stalled : .waiting
    }

    enum UnexplainedPause: Equatable { case restart, stayPaused }

    /// macOS keeps a window paused although the catalog lists it on the stage. One fresh stream per
    /// change in what the catalog says about the window; with nothing new, the pane stays Paused.
    /// Before (2026-10-30 21:3x, after Home and back): each fresh stream sent one frame ("live
    /// again", which also cleared the restart count), then paused again; restarted every 2–3 s.
    static func unexplainedPause(signature: String, restartedFor: String?) -> UnexplainedPause {
        signature == restartedFor ? .stayPaused : .restart
    }

    /// What the catalog says about a window that could make a paused capture resume.
    static func windowSignature(frame: CGRect, availability: String, inStageStrip: Bool, isActive: Bool) -> String {
        "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height)) \(availability) strip=\(inStageStrip) active=\(isActive)"
    }

    /// Delay before restart number `attempt` (1-based), or nil when it's time to give up.
    static func retryDelay(attempt: Int) -> TimeInterval? {
        attempt >= 1 && attempt <= backoff.count ? backoff[attempt - 1] : nil
    }
}

/// How many pixels a pane's capture needs: the whole source at the scale the pane draws it,
/// never above the source's own pixels, in a few fixed steps so zooming reconfigures rarely.
enum WorkspaceCaptureSizing {
    /// Shares of the source's own pixels a capture may use.
    static let steps: [Double] = [1.0 / 8, 1.0 / 6, 1.0 / 4, 1.0 / 3, 1.0 / 2, 2.0 / 3, 1]
    static let maxSide = 4096.0
    static let maxPixels = 12_000_000.0

    /// One active display, as `backingScale(source:displays:)` reads it.
    struct DisplayScale: Equatable {
        /// Global points (`CGDisplayBounds`).
        var bounds: CGRect
        /// The display mode's width in points and in pixels (`CGDisplayMode.width` / `.pixelWidth`).
        var modeWidth: Int
        var modePixelWidth: Int
    }

    /// Pixels per point of the display holding most of `source` (global points).
    ///
    /// From the display mode: `CGDisplayPixelsWide` reports the mode's width in points on a
    /// HiDPI display, so dividing it by the bounds gave 1 on every Retina Mac and each window
    /// was captured at half its pixels per side, then scaled up to fill the pane (issue #138).
    ///
    /// A source on no display (parked offscreen) takes the highest scale among the active
    /// displays, the most it could have on any of them: a Mac with only 1x displays never
    /// captures at 2x (4x the pixels, nothing gained). 2 only when no display reports a mode.
    static func backingScale(source: CGRect, displays: [DisplayScale]) -> Double {
        func overlap(_ d: DisplayScale) -> CGFloat {
            let i = d.bounds.intersection(source)
            return i.isNull ? 0 : i.width * i.height
        }
        func scale(_ d: DisplayScale) -> Double? {
            guard d.modeWidth > 0, d.modePixelWidth > 0 else { return nil }
            return max(Double(d.modePixelWidth) / Double(d.modeWidth), 1)
        }
        if let display = displays.max(by: { overlap($0) < overlap($1) }), overlap(display) > 0 {
            return scale(display) ?? 2
        }
        return displays.compactMap(scale).max() ?? 2
    }

    /// `source`: the source in points. `drawScale`: canvas pixels per source point (zoom included).
    /// `backingScale`: the source's pixels per point.
    static func size(source: CGSize, drawScale: Double, backingScale: Double) -> CGSize {
        guard source.width > 0, source.height > 0, drawScale > 0 else { return CGSize(width: 2, height: 2) }
        let native = max(backingScale, 1)
        let wanted = min(drawScale / native, 1)
        let share = steps.first { $0 >= wanted - 1e-9 } ?? 1
        var perPoint = native * share
        // Bounded: a huge window never asks for more than this.
        perPoint = min(perPoint, maxSide / source.width, maxSide / source.height,
                       (maxPixels / (source.width * source.height)).squareRoot())
        func even(_ v: Double) -> Double { max(2, (v / 2).rounded() * 2) }
        return CGSize(width: even(source.width * perPoint), height: even(source.height * perPoint))
    }
}

// MARK: - Covered windows

/// Whether input at a point may go to a tiled window: nothing else may be over it there, so a
/// press, hover or scroll never lands in a window the receiver isn't showing. Pure; the engine
/// feeds it what macOS lists above the target and, only when needed, the window server's own
/// mouse-down hit-test.
///
/// Any window over the point covers it: another app, a menu, a panel, a sheet that isn't the
/// target's own, Stage Manager's strip. The one exception is a *display-wide surface*: a window
/// above the normal layer whose bounds are exactly a whole display. On macOS 27 the Dock is one
/// (measured: a single 1920×1080 window at layer 20, holding the Dock strip, over every app
/// window). Its bounds say nothing about where it takes clicks, so for it the window server
/// decides: the point is clear only when a mouse-down there would hit the target itself (or
/// its own sheet). Where such a surface takes the click (the Dock strip, Mission Control, a
/// screen-capture overlay), or the answer is missing, the target stays covered.
enum WorkspaceInputCover {
    /// A window macOS lists above the target (`.optionOnScreenAboveWindow`), front to back.
    struct Window: Equatable, Sendable {
        var id: UInt32
        var owner: String
        var layer: Int
        /// Global, top-left origin.
        var bounds: CGRect
        var alpha: Double
        /// The owning process (`kCGWindowOwnerPID`), -1 when unknown (never a file-panel companion).
        var pid: Int32 = -1
    }

    enum Verdict: Equatable {
        /// Nothing else is over the target here: input may go to it.
        case clear
        /// Something is over the target here (`by`, when known); the answer holds within `cache`.
        case covered(by: UInt32?, cache: CGRect)
        /// The point isn't on the target on screen (outside it, on another Space, minimized).
        case outside
    }

    /// How far a window's bounds may be from a display's and still span it, in points.
    static let displayTolerance: CGFloat = 0.5

    /// - Parameters:
    ///   - targetFrame: the target's current on-screen frame, nil when it isn't on screen.
    ///   - ownSheets: the target's own sheets, which are part of it.
    ///   - displays: the active displays' bounds (global, top-left origin).
    ///   - hitTest: the window a mouse-down at `point` would hit, nil when unknown. Asked only
    ///     when every window over the point is a display-wide surface.
    ///   - isFilePanelService: whether a process is the system Open/Save panel service
    ///     (see `filePanelCompanions`). Defaults to never.
    static func verdict(target: UInt32, targetFrame: CGRect?, at point: CGPoint, above: [Window],
                        ownSheets: Set<UInt32>, displays: [CGRect],
                        isFilePanelService: (Int32) -> Bool = { _ in false },
                        hitTest: () -> UInt32?) -> Verdict {
        let partOfTarget = ownSheets.union(filePanelCompanions(
            target: target, targetFrame: targetFrame, above: above, ownSheets: ownSheets,
            isFilePanelService: isFilePanelService))
        let covering = above.filter {
            !partOfTarget.contains($0.id) && $0.alpha > 0.01 && $0.owner != "Window Server" && $0.bounds.contains(point)
        }
        if let cover = covering.first(where: { !isDisplayWideSurface($0, at: point, displays: displays) }) {
            return .covered(by: cover.id, cache: cover.bounds)
        }
        guard targetFrame?.contains(point) == true else { return .outside }
        let around = CGRect(x: point.x - 40, y: point.y - 40, width: 80, height: 80)
        guard !covering.isEmpty else { return .clear }
        // Only display-wide surfaces are over the point: the window server knows where they
        // take clicks. Cached small, as it changes across the surface (the Dock strip).
        guard let hit = hitTest(), hit == target || partOfTarget.contains(hit) else {
            return .covered(by: covering.first?.id, cache: around)
        }
        return .clear
    }

    /// How far a panel-service window's frame may be from its panel's, in points.
    static let companionTolerance: CGFloat = 1

    /// Windows of the system Open/Save panel service that are part of the target.
    ///
    /// An Open/Save panel (`NSOpenPanel`/`NSSavePanel`, a browser's upload chooser) is two windows
    /// (RESEARCH_TEMPORARY_DIALOGS.md): the app's own panel window, and directly over it at the
    /// same frame a window of `com.apple.appkit.xpc.openAndSavePanelService`, which draws the file
    /// browser and takes its presses. The app's panel window is either the target itself (the
    /// panel shown in a pane or float) or one of the target's own sheets (an untitled panel sheet
    /// drawn in its window's pane, as Chrome's upload chooser is). Without this every press in the
    /// panel was refused as covered (QA 9000025: the chooser showed, nothing in it could be clicked).
    ///
    /// A service window is part of the target only when all of these hold; anything else over the
    /// target (other apps, another app's panel, menus, system prompts) still covers it:
    /// - in window-server order it is *directly* above the target or one of the target's own
    ///   sheets, nothing in between (`above` is front to back),
    /// - its frame is that window's frame (within `companionTolerance`),
    /// - it is a visible, normal-layer window with a number,
    /// - its process is the system panel service (`isFilePanelService`: the sealed executable and
    ///   Apple's signature, never a name).
    static func filePanelCompanions(target: UInt32, targetFrame: CGRect?, above: [Window], ownSheets: Set<UInt32>,
                                    isFilePanelService: (Int32) -> Bool) -> Set<UInt32> {
        var result: Set<UInt32> = []
        for (i, w) in above.enumerated() where w.id != 0 && w.pid > 0 && w.layer == 0 && w.alpha > 0.01 {
            // The window right under `w`: the next one listed, or the target under them all.
            let under: (id: UInt32, frame: CGRect?) = i + 1 < above.count ? (above[i + 1].id, above[i + 1].bounds)
                                                                          : (target, targetFrame)
            guard under.id == target || ownSheets.contains(under.id), let frame = under.frame,
                  sameFrame(w.bounds, frame), isFilePanelService(w.pid) else { continue }
            result.insert(w.id)
        }
        return result
    }

    static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        let t = companionTolerance
        return abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t
            && abs(a.width - b.width) <= t && abs(a.height - b.height) <= t
    }

    /// The panel service's executable on the sealed system volume (macOS 27: `Versions/C`).
    static let filePanelServiceExecutablePrefix = "/System/Library/Frameworks/AppKit.framework/Versions/"
    static let filePanelServiceExecutableSuffix =
        "/XPCServices/com.apple.appkit.xpc.openAndSavePanelService.xpc/Contents/MacOS/com.apple.appkit.xpc.openAndSavePanelService"
    /// The code requirement its signature must meet: Apple's own, for that identifier.
    static let filePanelServiceRequirement = "anchor apple and identifier \"com.apple.appkit.xpc.openAndSavePanelService\""

    /// Whether an executable path is the system Open/Save panel service: exactly AppKit's copy
    /// under /System/Library (one version component, no `..`). Not anything else under /System:
    /// `/System/Volumes/Data` is the writable data volume.
    static func isFilePanelServicePath(_ path: String) -> Bool {
        guard path.hasPrefix(filePanelServiceExecutablePrefix), path.hasSuffix(filePanelServiceExecutableSuffix),
              path.count > filePanelServiceExecutablePrefix.count + filePanelServiceExecutableSuffix.count else { return false }
        let version = path.dropFirst(filePanelServiceExecutablePrefix.count).dropLast(filePanelServiceExecutableSuffix.count)
        return !version.contains("/") && version != "." && version != ".."
    }

    /// One `CGWindowListCopyWindowInfo` entry. Nil only without bounds (nothing to place it by).
    /// A missing value takes the reading that keeps the window a cover: no number (never the
    /// target or its sheet), layer 0 (never a display-wide surface), an unknown owner, opaque.
    static func window(from info: [String: Any]) -> Window? {
        guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
        return Window(id: (info[kCGWindowNumber as String] as? UInt32) ?? 0,
                      owner: info[kCGWindowOwnerName as String] as? String ?? "",
                      layer: info[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds,
                      alpha: (info[kCGWindowAlpha as String] as? Double) ?? 1,
                      pid: (info[kCGWindowOwnerPID as String] as? Int32) ?? -1)
    }

    /// `point` (global, top-left origin) in Cocoa's global coordinates, which the window
    /// server's hit-test takes: the same x, and y measured up from the primary display's bottom
    /// edge, on every display (one above the primary has y past its height, one below it a
    /// negative y).
    static func cocoaPoint(fromGlobal point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Above the normal window layer, and exactly the bounds of the display holding `point`.
    static func isDisplayWideSurface(_ w: Window, at point: CGPoint, displays: [CGRect]) -> Bool {
        guard w.layer > 0 else { return false }
        let t = displayTolerance
        return displays.contains { d in
            d.contains(point) && abs(w.bounds.minX - d.minX) <= t && abs(w.bounds.minY - d.minY) <= t
                && abs(w.bounds.width - d.width) <= t && abs(w.bounds.height - d.height) <= t
        }
    }
}
