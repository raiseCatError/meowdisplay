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
    /// Bumped whenever this tile's window changes: frames, held input and
    /// focus from an older generation are discarded.
    var assignmentGeneration: UInt64
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
    static func validate(tiles raw: [[String: Any]], catalog: [UInt32: WindowCatalogEntry], hostID: String,
                         canvasPixels: CGSize, previous: [String: WorkspaceTileAssignment],
                         nextGeneration: inout UInt64) -> Result {
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
            if accepted.contains(where: { ($0.rect.intersection(rect)?.area ?? 0) > 1e-6 }) {
                rejected[id] = "overlap"
                continue
            }
            guard let windowNumber = (item["window"] as? Int).flatMap({ UInt32(exactly: $0) }),
                  let entry = catalog[windowNumber] else { rejected[id] = "unavailable"; continue }
            // The generation is required: without it a reused id can't be told apart.
            guard let gen = (item["gen"] as? Int).flatMap({ UInt64(exactly: $0) }), gen == entry.generation else {
                rejected[id] = "unavailable"
                continue
            }
            let follow = (item["follow"] as? String).flatMap(WorkspaceSource.Follow.init(rawValue:)) ?? .window
            let rotation = WorkspaceRotation(degrees: item["rotation"] as? Int ?? 0)
            let fit = (item["fit"] as? String).flatMap(WorkspaceFit.init(rawValue:)) ?? .fit
            var generation: UInt64
            if let old = previous[id], old.windowID == entry.windowID, old.windowGeneration == entry.generation {
                generation = old.assignmentGeneration
            } else {
                generation = nextGeneration
                nextGeneration += 1
            }
            accepted.append(WorkspaceTileAssignment(
                tileID: id, rect: rect, windowID: entry.windowID, windowGeneration: entry.generation, pid: entry.pid,
                bundleID: entry.bundleID, follow: follow, rotation: rotation, fit: fit, assignmentGeneration: generation))
        }
        return Result(assignments: accepted, rejected: rejected)
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

    func transform(for a: WorkspaceTileAssignment) -> TileContentTransform? {
        guard let frame = windowFrames[a.windowID], frame.width > 0, frame.height > 0 else { return nil }
        let tile = a.rect.scaled(to: WorkspaceSize(width: canvas.width, height: canvas.height))
        return TileContentTransform(tile: tile, source: WorkspaceSize(width: frame.width, height: frame.height),
                                    rotation: a.rotation, fit: a.fit)
    }

    func tile(at p: WorkspacePoint) -> WorkspaceTileAssignment? {
        assignments.first { $0.rect.contains(p) }
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

    /// Relative motion (Trackpad mode, mice): moves the workspace pointer in
    /// canvas pixels, then resolves like an absolute move. The pointer moves
    /// freely across tiles; it is never trapped in the active one.
    mutating func resolveRelative(dx: Double, dy: Double) -> Target? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let p = WorkspacePoint(x: pointer.x + dx / canvas.width, y: pointer.y + dy / canvas.height)
        return resolve(.move, at: p)
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
        return release
    }

    /// The Mac's cursor in canvas coordinates (normalized), when it is over a
    /// tile's window; nil hides the remote cursor indicator.
    func canvasPoint(forGlobal g: CGPoint) -> WorkspacePoint? {
        for a in assignments {
            guard let frame = windowFrames[a.windowID], frame.contains(g), let t = transform(for: a) else { continue }
            let q = t.canvasPoint(fromSource: WorkspacePoint(x: g.x - frame.minX, y: g.y - frame.minY))
            guard let visible = t.visibleRect, visible.contains(q) else { continue }
            return WorkspacePoint(x: q.x / canvas.width, y: q.y / canvas.height)
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
    static func decide(active: WorkspaceTileAssignment?, frontmostPID: Int32?, focusedWindowID: UInt32?,
                       focusedWindowIsChild: Bool) -> Decision {
        guard let active else { return .noActiveTile }
        guard frontmostPID == active.pid else { return .hostFocusElsewhere }
        guard let focusedWindowID else { return .deliver }   // app in front, no window info (AX unavailable): its own window or nothing
        if focusedWindowID == active.windowID || focusedWindowIsChild || active.follow == .app { return .deliver }
        return .otherWindowFocused
    }
}

/// Per-tile capture budget: the active tile at the stream rate, the rest
/// reduced as more tiles share one encoder; paused windows cost nothing.
enum WorkspaceCaptureBudget {
    static func fps(isActive: Bool, tileCount: Int, streamFPS: Int, available: Bool) -> Int {
        guard available else { return 0 }
        if isActive || tileCount == 1 { return streamFPS }
        switch tileCount {
        case ...3: return min(streamFPS, 30)
        case 4...6: return min(streamFPS, 15)
        default: return min(streamFPS, 10)
        }
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
        let s = min(fit == .fit ? min(sx, sy) : max(sx, sy), backingScale)
        let w = max(Int((window.width * s).rounded()) & ~1, 2), h = max(Int((window.height * s).rounded()) & ~1, 2)
        return CGSize(width: w, height: h)
    }
}
