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
    static func validate(tiles raw: [[String: Any]], catalog: [UInt32: WindowCatalogEntry], hostID: String,
                         canvasPixels: CGSize, previous: [String: WorkspaceTileAssignment],
                         nextGeneration: inout UInt64, displays: [UInt32: CGRect] = [:]) -> Result {
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
                    displayID: displayID))
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
                zoom: zoom, viewEpoch: epoch, assignmentGeneration: generation))
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

    func transform(for a: WorkspaceTileAssignment) -> TileContentTransform? {
        guard let frame = windowFrames[a.windowID], frame.width > 0, frame.height > 0 else { return nil }
        let tile = a.rect.scaled(to: WorkspaceSize(width: canvas.width, height: canvas.height))
        return TileContentTransform(tile: tile, source: WorkspaceSize(width: frame.width, height: frame.height),
                                    rotation: a.rotation, fit: a.fit, zoom: a.zoom)
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

    /// The Mac point under canvas point `p` (normalized), changing nothing.
    func globalPoint(at p: WorkspacePoint) -> CGPoint? {
        guard let a = tile(at: p) else { return nil }
        return global(a, p, clamped: false)
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

    /// The text caret (a global rectangle in points) in canvas coordinates,
    /// normalized to the canvas, when it is inside the window the keyboard is
    /// typing into — the active tile, or the only tile showing a window that
    /// contains it. Nil for a caret in any other window, outside the picture
    /// of its tile (cropped away) or without a live canvas: the receiver
    /// then keeps following its last touch.
    func canvasCaretRect(forGlobal g: CGRect) -> CGRect? {
        guard canvas.width > 0, canvas.height > 0, g.minX.isFinite, g.minY.isFinite, g.width.isFinite, g.height.isFinite else { return nil }
        let centre = CGPoint(x: g.midX, y: g.midY)
        let candidates = keyboardTarget.map { [$0] } ?? assignments
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
    /// Paused although the catalog says the window is on the stage: restart after this long.
    static let pausedOnStageTimeout: TimeInterval = 6
    /// Restarts back off; after the last one the pane says it failed and offers Retry.
    static let backoff: [TimeInterval] = [1, 2, 4, 8, 16]

    static func verdict(now: TimeInterval, startedAt: TimeInterval, firstCompleteAt: TimeInterval?,
                        suspendedSince: TimeInterval?, sourceLooksAvailable: Bool) -> Verdict {
        if let since = suspendedSince {
            // macOS paused it (Stage Manager's strip, a hidden Space). It resumes by itself when the
            // window is shown; only a pause the catalog can't explain is treated as stuck.
            return sourceLooksAvailable && now - since >= pausedOnStageTimeout ? .stalled : .paused
        }
        // Frames came: the stream works, even if the content is static now (no new frames).
        if firstCompleteAt != nil { return .live }
        return now - startedAt >= firstFrameTimeout ? .stalled : .waiting
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
