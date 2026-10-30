import CoreGraphics
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

/// Clockwise rotation of a tile's received image, in whole degrees (0..<360): any angle, turned
/// freely with two fingers; the pane menu's Rotate steps to the next right angle. Presentation
/// only: the Mac window is never rotated, and input is mapped back through the inverse. Whole
/// degrees keep the wire and saved layouts integers (older peers read them as before).
struct WorkspaceRotation: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: Int

    static let none = WorkspaceRotation(degrees: 0)
    static let quarter = WorkspaceRotation(degrees: 90)
    static let half = WorkspaceRotation(degrees: 180)
    static let threeQuarter = WorkspaceRotation(degrees: 270)
    /// The right angles.
    static let allCases = [none, quarter, half, threeQuarter]

    /// Lenient: any whole number of degrees, wrapped into 0..<360.
    init(degrees: Int) {
        rawValue = ((degrees % 360) + 360) % 360
    }

    /// Rounded to a whole degree; not finite = no rotation.
    init(degrees: Double) {
        self.init(degrees: degrees.isFinite ? Int((degrees.truncatingRemainder(dividingBy: 360)).rounded()) : 0)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self.init(degrees: i) } else { self.init(degrees: (try? c.decode(Double.self)) ?? 0) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    var description: String { "\(rawValue)°" }
    var isRightAngle: Bool { rawValue % 90 == 0 }
    var isQuarterTurn: Bool { rawValue == 90 || rawValue == 270 }
    var radians: Double { Double(rawValue) * .pi / 180 }

    /// Cosine and sine, exact at the right angles.
    var cosSin: (c: Double, s: Double) {
        switch rawValue {
        case 0: return (1, 0)
        case 90: return (0, 1)
        case 180: return (-1, 0)
        case 270: return (0, -1)
        default: return (cos(radians), sin(radians))
        }
    }

    /// The pane menu's Rotate: the next right angle clockwise.
    var clockwise: WorkspaceRotation { WorkspaceRotation(degrees: (rawValue / 90 + 1) * 90) }

    /// Turned by `degrees` (clockwise); with `snap`, within `snapRange` of a right angle lands on it.
    func turned(by degrees: Double, snap: Bool, snapRange: Double = 5) -> WorkspaceRotation {
        guard degrees.isFinite else { return self }
        let raw = Double(rawValue) + degrees
        if snap {
            let nearest = (raw / 90).rounded() * 90
            if abs(raw - nearest) <= snapRange { return WorkspaceRotation(degrees: nearest) }
        }
        return WorkspaceRotation(degrees: raw)
    }
}

enum WorkspaceFit: String, Codable, Sendable {
    /// Default: the whole source, centred, letterboxed where the shapes differ (like Full Desktop).
    case fit
    /// Explicit: the pane filled, the source cropped evenly. Never stretched.
    case fill
    /// Old saved layouts and older receivers: shown as `.fit` (a resized pane never crops).
    case auto

    /// `.auto` is Fit. Pure: the Mac, iOS and Android resolve it identically.
    static func resolved(_ fit: WorkspaceFit, tile: WorkspaceSize, source: WorkspaceSize) -> WorkspaceFit {
        fit == .fill ? .fill : .fit
    }
}

/// One pane's own zoom: a factor of its Fit (or Fill) size, 0.7x to 8x, and the point of the
/// (rotated) source shown at the pane's centre, normalized to the source. Each pane has its own;
/// a pane resize never changes it. Identity = the whole source at the mode's size, centred.
struct WorkspacePaneZoom: Equatable, Codable, Sendable {
    static let minimum = 0.7
    static let maximum = 8.0
    static let identity = WorkspacePaneZoom(scale: 1, centerX: 0.5, centerY: 0.5)

    var scale: Double
    var centerX: Double
    var centerY: Double

    var isIdentity: Bool {
        abs(scale - 1) < 1e-4 && abs(centerX - 0.5) < 1e-4 && abs(centerY - 0.5) < 1e-4
    }

    /// Lenient decode for wire/persisted values: scale clamped, centre finite.
    init(scale: Double, centerX: Double, centerY: Double) {
        self.scale = scale.isFinite ? min(max(scale, Self.minimum), Self.maximum) : 1
        self.centerX = centerX.isFinite ? min(max(centerX, -4), 5) : 0.5
        self.centerY = centerY.isFinite ? min(max(centerY, -4), 5) : 0.5
    }

    /// `[scale, centerX, centerY]` on the wire.
    init?(wire: Any?) {
        guard let a = wire as? [Any], a.count == 3 else { return nil }
        let v = a.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? Double) }
        guard v.count == 3 else { return nil }
        self.init(scale: v[0], centerX: v[1], centerY: v[2])
    }

    var wire: [Double] { [scale, centerX, centerY] }
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
    /// The pane's own zoom and centre (identity: the whole source at the fit's size, centred).
    var zoom = WorkspacePaneZoom.identity

    /// The rotated image's size before scaling: its bounding box (any angle).
    var rotatedSourceSize: WorkspaceSize {
        if rotation.isRightAngle { return rotation.isQuarterTurn ? WorkspaceSize(width: source.height, height: source.width) : source }
        let (c, s) = rotation.cosSin
        return WorkspaceSize(width: abs(source.width * c) + abs(source.height * s), height: abs(source.width * s) + abs(source.height * c))
    }

    /// `.auto` resolved for this tile and source.
    var effectiveFit: WorkspaceFit {
        WorkspaceFit.resolved(fit, tile: WorkspaceSize(width: tile.width, height: tile.height), source: rotatedSourceSize)
    }

    /// The mode's own size (zoom 1x): the whole source (Fit) or the pane filled (Fill).
    var baseScale: Double {
        let r = rotatedSourceSize
        guard r.width > 0, r.height > 0, tile.width > 0, tile.height > 0 else { return 0 }
        let sx = tile.width / r.width, sy = tile.height / r.height
        return effectiveFit == .fill ? max(sx, sy) : min(sx, sy)
    }

    var scale: Double { baseScale * zoom.scale }

    /// Where the whole (rotated, scaled) source lands: `zoom`'s centre at the pane's centre.
    /// A free canvas: the centre may be any point of the source, so any edge or corner can be
    /// brought to the pane's centre and left there (the empty canvas around it is intended).
    /// The source always covers the pane's centre, so it can never be lost.
    var contentRect: WorkspaceRect {
        let r = rotatedSourceSize, s = scale
        let w = r.width * s, h = r.height * s
        func place(_ start: Double, _ extent: Double, _ size: Double, _ center: Double) -> Double {
            start + extent / 2 - min(max(center, 0), 1) * size
        }
        return WorkspaceRect(x: place(tile.x, tile.width, w, zoom.centerX), y: place(tile.y, tile.height, h, zoom.centerY),
                             width: w, height: h)
    }

    /// `zoom` with its centre as actually drawn (after keeping the source navigable).
    var effectiveZoom: WorkspacePaneZoom {
        let c = contentRect
        guard c.width > 0, c.height > 0 else { return zoom }
        return WorkspacePaneZoom(scale: zoom.scale, centerX: (tile.midX - c.x) / c.width, centerY: (tile.midY - c.y) / c.height)
    }

    /// The part of the tile that actually shows window pixels.
    var visibleRect: WorkspaceRect? { contentRect.intersection(tile) }

    /// Source pixel (whole-window coordinates) -> canvas.
    func canvasPoint(fromSource window: WorkspacePoint) -> WorkspacePoint {
        let r = rotated(window)
        let c = contentRect, s = scale
        return WorkspacePoint(x: c.x + r.x * s, y: c.y + r.y * s)
    }

    /// Canvas -> source pixel, or nil when the point shows no window pixels
    /// (letterbox bars, cropped-away area, outside the tile). Input outside
    /// the visible image must never reach the Mac.
    func sourcePoint(fromCanvas q: WorkspacePoint) -> WorkspacePoint? {
        guard let visible = visibleRect, visible.contains(q), let p = unclampedSourcePoint(fromCanvas: q) else { return nil }
        // At an angle the corners of the turned picture's box show no window.
        if !rotation.isRightAngle {
            let slack = 1e-6 * max(source.width, source.height, 1)
            guard p.x >= -slack, p.y >= -slack, p.x <= source.width + slack, p.y <= source.height + slack else { return nil }
        }
        // Clamp float residue at the far edges into the window.
        return WorkspacePoint(x: min(max(p.x, 0), source.width), y: min(max(p.y, 0), source.height))
    }

    /// Canvas -> source for any canvas point, even one off the window (gestures need the
    /// window point under the fingers wherever they are).
    func unclampedSourcePoint(fromCanvas q: WorkspacePoint) -> WorkspacePoint? {
        let c = contentRect, s = scale
        guard s > 0 else { return nil }
        return unrotated(WorkspacePoint(x: (q.x - c.x) / s, y: (q.y - c.y) / s))
    }

    /// Canvas -> source for a point that may lie outside the tile (a drag that
    /// started inside and wandered out). Clamped to the window's edge so a drag
    /// bound to this tile can never land in a neighbouring window.
    func clampedSourcePoint(fromCanvas q: WorkspacePoint) -> WorkspacePoint? {
        guard let visible = visibleRect else { return nil }
        let eps = 1e-9
        let clamped = WorkspacePoint(x: min(max(q.x, visible.x), visible.maxX - eps),
                                     y: min(max(q.y, visible.y), visible.maxY - eps))
        guard !rotation.isRightAngle else { return sourcePoint(fromCanvas: clamped) }
        // At an angle: the nearest point of the window itself.
        guard let p = unclampedSourcePoint(fromCanvas: clamped) else { return nil }
        return WorkspacePoint(x: min(max(p.x, 0), source.width), y: min(max(p.y, 0), source.height))
    }

    /// Canvas-space vector (scroll, relative motion) -> source-space vector.
    func sourceVector(fromCanvas v: WorkspacePoint) -> WorkspacePoint {
        let s = scale
        guard s > 0 else { return WorkspacePoint(x: 0, y: 0) }
        let a = v.x / s, b = v.y / s
        // The inverse turn (exact at the right angles: multiplying by 0 and ±1).
        let (c, sn) = rotation.cosSin
        return WorkspacePoint(x: a * c + b * sn, y: -a * sn + b * c)
    }

    /// Window point -> the turned picture's box (unscaled).
    func rotated(_ p: WorkspacePoint) -> WorkspacePoint {
        let w = source.width, h = source.height
        switch rotation.rawValue {
        case 0: return p
        case 90: return WorkspacePoint(x: h - p.y, y: p.x)
        case 180: return WorkspacePoint(x: w - p.x, y: h - p.y)
        case 270: return WorkspacePoint(x: p.y, y: w - p.x)
        default:
            // About the window's centre, then into its turned bounding box.
            let (c, s) = rotation.cosSin, box = rotatedSourceSize
            let x = p.x - w / 2, y = p.y - h / 2
            return WorkspacePoint(x: x * c - y * s + box.width / 2, y: x * s + y * c + box.height / 2)
        }
    }

    /// The turned picture's box (unscaled) -> window point.
    func unrotated(_ r: WorkspacePoint) -> WorkspacePoint {
        let w = source.width, h = source.height
        switch rotation.rawValue {
        case 0: return r
        case 90: return WorkspacePoint(x: r.y, y: h - r.x)
        case 180: return WorkspacePoint(x: w - r.x, y: h - r.y)
        case 270: return WorkspacePoint(x: w - r.y, y: r.x)
        default:
            let (c, s) = rotation.cosSin, box = rotatedSourceSize
            let x = r.x - box.width / 2, y = r.y - box.height / 2
            return WorkspacePoint(x: x * c + y * s + w / 2, y: -x * s + y * c + h / 2)
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

    /// A whole Mac display can fill a pane too (Full Desktop as a tile source). It is kept
    /// as a reserved window id with the high bit set (CGWindowIDs never get there), so
    /// layouts, tabs and records treat it like any window; on the wire it is
    /// `"display": <CGDirectDisplayID>` instead of `"window"`.
    static let displayKeyBit: UInt32 = 0x8000_0000
    static func displayKey(_ displayID: UInt32) -> UInt32 { displayKeyBit | (displayID & ~displayKeyBit) }
    static func isDisplayKey(_ id: UInt32) -> Bool { id & displayKeyBit != 0 }
    var isDisplay: Bool { Self.isDisplayKey(windowID) }
}

struct WorkspaceTile: Equatable, Codable, Sendable {
    var id: String
    /// The window this pane shows (its active tab). Only this one streams.
    var source: WorkspaceSource?
    var rotation: WorkspaceRotation = .none
    var fit: WorkspaceFit = .fit
    /// This pane's own zoom (0.7x-8x of its Fit or Fill size) and centre. Nil = 1x, centred.
    var zoom: WorkspacePaneZoom?
    /// Every window in this pane, in label order, when it holds more than one (tabs).
    /// Empty for a single-window pane. `source` is always one of them.
    var tabs: [WorkspaceSource] = []

    /// The views of the tabs not shown (rotation, Fit/Fill, zoom), by `WorkspaceSource.tabKey`:
    /// each tab keeps its own while another is shown. Absent = the default view.
    var tabViews: [String: WorkspaceTabView] = [:]

    /// The pane's windows in label order (one, or its tabs).
    var windows: [WorkspaceSource] { tabs.isEmpty ? (source.map { [$0] } ?? []) : tabs }

    /// Shows `s` (one of its tabs): the shown tab's view is kept for it (unless it is leaving),
    /// and `s` gets its own view back (the default the first time).
    mutating func show(_ s: WorkspaceSource, keepingCurrent: Bool = true) {
        if let current = source, current.tabKey != s.tabKey {
            if keepingCurrent {
                let v = WorkspaceTabView(rotation: rotation, fit: fit, zoom: zoom)
                tabViews[current.tabKey] = v.isDefault ? nil : v
            }
            let v = tabViews.removeValue(forKey: s.tabKey) ?? WorkspaceTabView()
            rotation = v.rotation; fit = v.fit; zoom = v.zoom
        }
        source = s
        let keys = Set(tabs.map(\.tabKey))
        tabViews = tabViews.filter { keys.contains($0.key) }
    }
}

enum WorkspaceTabOrder {
    /// Where a tab dragged from `from` lands when dropped at `dropX` on its pane's labels
    /// (their centres, in label order): after every other label whose centre is left of it.
    static func index(from: Int, dropX: Double, labelMidXs: [Double]) -> Int {
        guard labelMidXs.indices.contains(from) else { return from }
        return labelMidXs.enumerated().filter { $0.offset != from && $0.element < dropX }.count
    }
}

/// A tab's own view, kept while another tab of its pane is shown.
struct WorkspaceTabView: Equatable, Codable, Sendable {
    var rotation: WorkspaceRotation = .none
    var fit: WorkspaceFit = .fit
    var zoom: WorkspacePaneZoom?
    var isDefault: Bool { rotation == .none && fit == .fit && (zoom?.isIdentity ?? true) }
}

extension WorkspaceSource {
    /// One window on one Mac (generation and follow aside): a tab's identity in its pane.
    var tabKey: String { "\(host)#\(windowID)" }
}

/// Pinch and pan inside one pane: the source point under the fingers when they came down stays
/// under them, zoom 0.7x to 8x of the pane's Fit (or Fill) size, the source kept navigable.
enum WorkspaceZoom {
    static let minimum = WorkspacePaneZoom.minimum
    static let maximum = WorkspacePaneZoom.maximum

    /// `start` changed by a pinch of `ratio` (1 = a pan) whose midpoint went from `from` to `to`
    /// (pane-normalized, 0..1, as drawn: rotation included). `tile` in canvas units;
    /// `source` the window's own (unrotated) size. Nil when the result is the default view.
    static func pinched(_ start: WorkspacePaneZoom?, tile: WorkspaceSize, source: WorkspaceSize, rotation: WorkspaceRotation,
                        fit: WorkspaceFit, ratio: Double, from: WorkspacePoint, to: WorkspacePoint) -> WorkspacePaneZoom? {
        let z0 = start ?? .identity
        guard ratio.isFinite, ratio > 0, [from.x, from.y, to.x, to.y].allSatisfy(\.isFinite),
              tile.width > 0, tile.height > 0, source.width > 0, source.height > 0 else { return start }
        let rect = WorkspaceRect(x: 0, y: 0, width: tile.width, height: tile.height)
        let t0 = TileContentTransform(tile: rect, source: source, rotation: rotation, fit: fit, zoom: z0)
        let c0 = t0.contentRect
        guard c0.width > 0, c0.height > 0 else { return start }
        // The (rotated) source point under the fingers when they came down, normalized.
        let ux = (from.x * tile.width - c0.x) / c0.width, uy = (from.y * tile.height - c0.y) / c0.height
        let scale = min(max(z0.scale * ratio, minimum), maximum)
        let w = c0.width / z0.scale * scale, h = c0.height / z0.scale * scale
        // Put that point under the fingers now; the centre follows.
        let ox = to.x * tile.width - ux * w, oy = to.y * tile.height - uy * h
        let wanted = WorkspacePaneZoom(scale: scale, centerX: (tile.width / 2 - ox) / w, centerY: (tile.height / 2 - oy) / h)
        let drawn = TileContentTransform(tile: rect, source: source, rotation: rotation, fit: fit, zoom: wanted).effectiveZoom
        return drawn.isIdentity ? nil : drawn
    }

    /// A two-finger gesture that turns as well: the window point under the fingers when they
    /// came down stays under them while the picture scales by `ratio` and turns by `degrees`
    /// (clockwise, from `rotation`). The size follows the fingers only: turning never shrinks or
    /// grows the picture by itself (zoom stays 0.7x to 8x of the new angle's Fit or Fill size).
    /// With `snap`, an angle within a few degrees of a right angle lands on it.
    static func turned(_ start: WorkspacePaneZoom?, rotation: WorkspaceRotation, by degrees: Double, snap: Bool,
                       tile: WorkspaceSize, source: WorkspaceSize, fit: WorkspaceFit,
                       ratio: Double, from: WorkspacePoint, to: WorkspacePoint) -> (rotation: WorkspaceRotation, zoom: WorkspacePaneZoom?) {
        let z0 = start ?? .identity
        guard ratio.isFinite, ratio > 0, degrees.isFinite, [from.x, from.y, to.x, to.y].allSatisfy(\.isFinite),
              tile.width > 0, tile.height > 0, source.width > 0, source.height > 0 else { return (rotation, start) }
        let rect = WorkspaceRect(x: 0, y: 0, width: tile.width, height: tile.height)
        let t0 = TileContentTransform(tile: rect, source: source, rotation: rotation, fit: fit, zoom: z0)
        guard let anchor = t0.unclampedSourcePoint(fromCanvas: WorkspacePoint(x: from.x * tile.width, y: from.y * tile.height))
        else { return (rotation, start) }
        let r1 = rotation.turned(by: degrees, snap: snap)
        let base1 = TileContentTransform(tile: rect, source: source, rotation: r1, fit: fit).baseScale
        guard base1 > 0 else { return (rotation, start) }
        let scale = min(max(t0.scale * ratio / base1, minimum), maximum)
        let s1 = base1 * scale
        let probe = TileContentTransform(tile: rect, source: source, rotation: r1, fit: fit,
                                         zoom: WorkspacePaneZoom(scale: scale, centerX: 0.5, centerY: 0.5))
        let box = probe.rotatedSourceSize
        let w = box.width * s1, h = box.height * s1
        guard w > 0, h > 0 else { return (rotation, start) }
        // The anchor's place in the turned picture; the centre is what puts it under the fingers.
        let u = probe.rotated(anchor)
        let ox = to.x * tile.width - u.x * s1, oy = to.y * tile.height - u.y * s1
        let wanted = WorkspacePaneZoom(scale: scale, centerX: (tile.width / 2 - ox) / w, centerY: (tile.height / 2 - oy) / h)
        let drawn = TileContentTransform(tile: rect, source: source, rotation: r1, fit: fit, zoom: wanted).effectiveZoom
        return (r1, drawn.isIdentity ? nil : drawn)
    }
}

/// Instant local zoom: while the fingers move, the receiver moves the picture it already has
/// (clipped to the pane) and fills what that picture doesn't cover from the pane's whole-source
/// still; the Mac's frame with the same view replaces it. Picture-normalized units throughout.
struct WorkspaceZoomPreview: Equatable, Sendable {
    var tile: String
    /// The preview is clipped to this pane.
    var pane: WorkspaceRect
    /// `v' = (scaleX·x + shearC·y + offsetX, shearB·x + scaleY·y + offsetY)`: a point of the
    /// picture as drawn when the gesture began, moved to where it belongs now (picture-normalized;
    /// the shear terms carry a turn and are 0 without one).
    var scaleX: Double, scaleY: Double, offsetX: Double, offsetY: Double
    var shearB: Double = 0, shearC: Double = 0
    /// Where the whole (rotated) source is drawn now: the whole-source still goes here.
    var source: WorkspaceRect
    /// Where it was drawn when the gesture began (the moved picture shows only this part).
    var from: WorkspaceRect
    var rotation: WorkspaceRotation
    /// The whole source's own (unturned) size as drawn now, picture-normalized per axis: the
    /// still is this size, turned by `rotation`, centred in `source`. Nil: work it out from `source`.
    var drawnSource: WorkspaceSize?
    /// The window (or display key) the still must be of.
    var sourceKey: UInt32
    /// The window's four corners as drawn when the gesture began (picture-normalized, clockwise from
    /// its top-left): only this shape of the old picture is moved. At an angle the box `from` also
    /// holds empty corners, which must never be dragged over the still below. Nil: all of `from`.
    var fromQuad: [WorkspacePoint]?

    init?(tile: String, pane: WorkspaceRect, from old: WorkspaceRect, to new: WorkspaceRect,
          rotation: WorkspaceRotation = .none, sourceKey: UInt32 = 0) {
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0,
              [old.x, old.y, new.x, new.y, new.width, new.height].allSatisfy(\.isFinite) else { return nil }
        self.tile = tile
        self.pane = pane
        scaleX = new.width / old.width
        scaleY = new.height / old.height
        offsetX = new.x - scaleX * old.x
        offsetY = new.y - scaleY * old.y
        source = new
        from = old
        self.rotation = rotation
        self.sourceKey = sourceKey
    }

    /// From the pane's view when the gesture began (`start`) to now (`now`), both in canvas
    /// pixels on a canvas of `canvas` pixels: any zoom, pan and turn.
    init?(tile: String, pane: WorkspaceRect, start t0: TileContentTransform, now t1: TileContentTransform,
          canvas: WorkspaceSize, sourceKey: UInt32 = 0) {
        let W = canvas.width, H = canvas.height
        guard W > 0, H > 0, t0.scale > 0, t1.scale > 0 else { return nil }
        func map(_ x: Double, _ y: Double) -> WorkspacePoint? {
            guard let s = t0.unclampedSourcePoint(fromCanvas: WorkspacePoint(x: x * W, y: y * H)) else { return nil }
            let q = t1.canvasPoint(fromSource: s)
            return WorkspacePoint(x: q.x / W, y: q.y / H)
        }
        guard let p0 = map(0, 0), let p1 = map(1, 0), let p2 = map(0, 1) else { return nil }
        func norm(_ r: WorkspaceRect) -> WorkspaceRect { WorkspaceRect(x: r.x / W, y: r.y / H, width: r.width / W, height: r.height / H) }
        let old = norm(t0.contentRect), new = norm(t1.contentRect)
        guard old.width > 0, old.height > 0, new.width > 0, new.height > 0,
              [p0.x, p0.y, p1.x, p1.y, p2.x, p2.y].allSatisfy(\.isFinite) else { return nil }
        self.tile = tile
        self.pane = pane
        scaleX = p1.x - p0.x; shearB = p1.y - p0.y
        shearC = p2.x - p0.x; scaleY = p2.y - p0.y
        offsetX = p0.x; offsetY = p0.y
        source = new
        from = old
        rotation = t1.rotation
        drawnSource = WorkspaceSize(width: t1.source.width * t1.scale / W, height: t1.source.height * t1.scale / H)
        self.sourceKey = sourceKey
        let w = t0.source.width, h = t0.source.height
        fromQuad = [WorkspacePoint(x: 0, y: 0), WorkspacePoint(x: w, y: 0), WorkspacePoint(x: w, y: h), WorkspacePoint(x: 0, y: h)].map {
            let q = t0.canvasPoint(fromSource: $0)
            return WorkspacePoint(x: q.x / W, y: q.y / H)
        }
    }

    func apply(_ p: WorkspacePoint) -> WorkspacePoint {
        WorkspacePoint(x: scaleX * p.x + shearC * p.y + offsetX, y: shearB * p.x + scaleY * p.y + offsetY)
    }
}

/// What the receiver's video view draws for an instant zoom: the moved picture, the pane's
/// whole-source still under it, and whether the Mac's frame with this view is out yet.
struct WorkspaceLiveZoom: @unchecked Sendable {
    var preview: WorkspaceZoomPreview
    var backdrop: CGImage?
    var composed: Bool
}

/// A pane's whole source as a still (from the Mac's live capture of it).
struct WorkspaceBackdrop: @unchecked Sendable {
    /// Largest still on the wire (base64): well inside the 1 MiB control-message limit (QUIC
    /// drops a connection that sends more), so the Mac re-encodes smaller until it fits.
    static let maxBase64 = 700_000

    var windowID: UInt32
    var image: CGImage
    /// From before macOS paused the window.
    var stale: Bool
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
    static let schema = 3
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
        if tile.source != source { tile.zoom = nil }   // zoom belongs to the window it was set on
        if !tile.tabs.isEmpty, let current = tile.source, let i = tile.tabs.firstIndex(of: current) {
            if let source {
                tile.tabs[i] = source
                tile.tabs = Self.unique(tile.tabs)
            } else {
                tile.tabs.remove(at: i)
                if tile.tabs.isEmpty { tile.source = nil } else { tile.show(tile.tabs[min(i, tile.tabs.count - 1)], keepingCurrent: false) }
                if tile.tabs.count <= 1 { tile.tabs = []; tile.tabViews = [:] }
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
        tile.show(source)
        var copy = self
        copy.tiles[id] = tile
        return copy
    }

    /// Shows another tab of a pane (only the shown tab streams from the Mac).
    func switchingTab(of id: String, to index: Int) -> WorkspaceLayout {
        guard var tile = tiles[id], tile.tabs.indices.contains(index), tile.source != tile.tabs[index] else { return self }
        tile.show(tile.tabs[index])
        var copy = self
        copy.tiles[id] = tile
        return copy
    }

    /// Moves a tab to another place among its pane's labels (the shown tab stays shown).
    func movingTab(of id: String, from: Int, to: Int) -> WorkspaceLayout {
        guard var tile = tiles[id], tile.tabs.indices.contains(from) else { return self }
        let to = min(max(to, 0), tile.tabs.count - 1)
        guard to != from else { return self }
        tile.tabs.insert(tile.tabs.remove(at: from), at: to)
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
        t.tabViews[removed.tabKey] = nil
        if t.source == removed {
            if t.tabs.isEmpty { t.source = nil; t.zoom = nil } else { t.show(t.tabs[min(index, t.tabs.count - 1)], keepingCurrent: false) }
        }
        if t.tabs.count <= 1 { t.tabs = []; t.tabViews = [:] }
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

    func zooming(_ id: String, to zoom: WorkspacePaneZoom?) -> WorkspaceLayout {
        let zoom = zoom?.isIdentity == true ? nil : zoom
        guard var tile = tiles[id], tile.zoom != zoom else { return self }
        tile.zoom = zoom
        var copy = self
        copy.tiles[id] = tile
        return copy
    }

    /// A pane's turn and zoom together (a two-finger turn changes both).
    func viewing(_ id: String, rotation: WorkspaceRotation, zoom: WorkspacePaneZoom?) -> WorkspaceLayout {
        let zoom = zoom?.isIdentity == true ? nil : zoom
        guard var tile = tiles[id], tile.zoom != zoom || tile.rotation != rotation else { return self }
        tile.zoom = zoom
        tile.rotation = rotation
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

    /// No empty panes: tiles without a window are dropped, empty slots close up and their
    /// neighbours take the space (ratios kept in proportion); one window fills the picture.
    /// Only a layout with no windows at all keeps its single empty slot.
    func compacted() -> WorkspaceLayout {
        var copy = self
        for (id, tile) in tiles where tile.source == nil { copy.tiles[id] = nil }
        copy.normalize()
        func prune(_ n: WorkspaceNode) -> WorkspaceNode? {
            switch n {
            case .slot(let id): return id == nil ? nil : n
            case .split(let axis, let children, let ratios):
                var kept: [WorkspaceNode] = [], keptRatios: [Double] = []
                let safe = ratios.count == children.count ? ratios : Array(repeating: 1, count: children.count)
                for (child, ratio) in zip(children, safe) {
                    if let p = prune(child) { kept.append(p); keptRatios.append(ratio) }
                }
                if kept.isEmpty { return nil }
                if kept.count == 1 { return kept[0] }
                let sum = keptRatios.reduce(0, +)
                return .split(axis, kept, sum > 0 ? keptRatios.map { $0 / sum } : [])
            }
        }
        copy.root = prune(copy.root) ?? .slot(nil)
        copy.normalize()
        return copy
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
    /// Undone layouts, newest last; any new change clears them.
    private(set) var future: [WorkspaceLayout] = []
    private var grouping = false
    private var groupRecorded = false

    var canUndo: Bool { !past.isEmpty }
    var canRedo: Bool { !future.isEmpty }

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
        future.removeAll()
        if grouping {
            if groupRecorded { return }
            groupRecorded = true
        }
        if past.last == layout { return }
        past.append(layout)
        if past.count > Self.depth { past.removeFirst(past.count - Self.depth) }
    }

    /// The layout before the last change. With `current`, that change can be redone.
    mutating func undo(current: WorkspaceLayout? = nil) -> WorkspaceLayout? {
        guard let previous = past.popLast() else { return nil }
        if let current { future.append(current) }
        return previous
    }

    /// The change undone last, back again.
    mutating func redo(current: WorkspaceLayout) -> WorkspaceLayout? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        if past.count > Self.depth { past.removeFirst(past.count - Self.depth) }
        return next
    }
}

// MARK: - Saved layouts

/// A layout the user saved by name, kept per Mac. Its windows are matched again when it is applied.
struct WorkspaceSavedLayout: Codable, Equatable, Identifiable, Sendable {
    static let maximum = 8
    var id: String
    var name: String
    var record: WorkspaceLayoutRecord

    static func decodeList(_ data: Data) -> [WorkspaceSavedLayout] {
        Array(((try? JSONDecoder().decode([WorkspaceSavedLayout].self, from: data)) ?? []).prefix(maximum))
    }

    static func encodeList(_ list: [WorkspaceSavedLayout]) -> Data? { try? JSONEncoder().encode(list) }
}

extension WorkspaceLayout {
    /// A saved layout on today's windows: each pane keeps its window while it is still open,
    /// otherwise takes another open window of the same app that no pane shows yet. Desktop panes
    /// and windows with nothing to match stay as they are (the pane then asks for a window).
    func rebinding(to windows: [(id: UInt32, bundleID: String)]) -> WorkspaceLayout {
        let listed = Set(windows.map(\.id))
        var used = Set<UInt32>()
        for tile in tiles.values {
            for s in tile.windows where !s.isDisplay && listed.contains(s.windowID) { used.insert(s.windowID) }
        }
        var moved: [UInt32: UInt32] = [:]
        for id in orderedTileIDs {
            for s in tiles[id]?.windows ?? [] where !s.isDisplay && !listed.contains(s.windowID) && moved[s.windowID] == nil {
                guard let bundle = s.bundleID,
                      let w = windows.first(where: { $0.bundleID == bundle && !used.contains($0.id) }) else { continue }
                used.insert(w.id)
                moved[s.windowID] = w.id
            }
        }
        guard !moved.isEmpty else { return self }
        func mapped(_ s: WorkspaceSource) -> WorkspaceSource {
            guard !s.isDisplay, let n = moved[s.windowID] else { return s }
            var copy = s
            copy.windowID = n
            return copy
        }
        var next = self
        for (id, tile) in tiles {
            var t = tile
            t.source = t.source.map(mapped)
            t.tabs = t.tabs.map(mapped)
            next.tiles[id] = t
        }
        return next
    }
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
        /// The pane's zoom `[scale, centerX, centerY]` (schema 3).
        var zoom: [Double]?
    }

    struct TabRecord: Codable, Equatable, Sendable {
        var host: String
        var window: UInt32
        var bundle: String?
        var follow: String?
        /// A tab's own view while another is shown (absent = the default view; older readers ignore it).
        var rotation: Int?
        var fit: String?
        var zoom: [Double]?
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
                 tabs: $0.tabs.isEmpty ? nil : $0.tabs.map { [views = $0.tabViews] s in
                     let v = views[s.tabKey]
                     return TabRecord(host: s.host, window: s.windowID, bundle: s.bundleID, follow: s.follow.rawValue,
                                      rotation: v.map { $0.rotation.rawValue }, fit: v.map { $0.fit.rawValue }, zoom: v?.zoom?.wire)
                 },
                 zoom: $0.zoom?.wire)
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
            // Fit unless Fill was chosen ("auto", the old default, shows the whole window too).
            let fit: WorkspaceFit = t.fit == WorkspaceFit.fill.rawValue ? .fill : .fit
            var tile = WorkspaceTile(id: t.id, source: source, rotation: WorkspaceRotation(degrees: t.rotation ?? 0), fit: fit)
            if source != nil, let z = WorkspacePaneZoom(wire: t.zoom), !z.isIdentity { tile.zoom = z }
            let tabs = (t.tabs ?? []).prefix(8).filter { !$0.host.isEmpty }.map {
                WorkspaceSource(host: $0.host, windowID: $0.window, bundleID: $0.bundle,
                                follow: $0.follow.flatMap(WorkspaceSource.Follow.init(rawValue:)) ?? .window)
            }
            if tabs.count > 1, let s = source, tabs.contains(s) {
                tile.tabs = Array(tabs)
                for r in (t.tabs ?? []).prefix(8) where r.rotation != nil || r.fit != nil || r.zoom != nil {
                    let key = WorkspaceSource(host: r.host, windowID: r.window).tabKey
                    guard key != s.tabKey, tile.tabs.contains(where: { $0.tabKey == key }) else { continue }
                    let v = WorkspaceTabView(rotation: WorkspaceRotation(degrees: r.rotation ?? 0), fit: r.fit == WorkspaceFit.fill.rawValue ? .fill : .fit,
                                             zoom: WorkspacePaneZoom(wire: r.zoom).flatMap { $0.isIdentity ? nil : $0 })
                    if !v.isDefault { tile.tabViews[key] = v }
                }
            }
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
