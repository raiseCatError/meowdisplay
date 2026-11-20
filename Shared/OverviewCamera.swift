// Pure camera for the receiver-side Multi-Display Overview: maps between the
// Mac's global point space ("world") and the receiver's view space.
//
// Compiled into the iOS/Mac receiver targets (presentation) and the hostless
// Mac test target (see MacTests/OverviewCameraTests.swift).
// Foundation + CoreGraphics only, so it stays platform-neutral. No UI here.
//
// - World: Mac global points, y grows down, origin may be negative.
// - View: receiver points, y grows down, origin at the viewport's top-left.
// - The camera is `center` (the world point drawn at the viewport centre),
//   `scale` (view points per world point) and a receiver-side-only rotation
//   restricted to multiples of pi/2. The Mac is never told about rotation.
//
//   view = viewportCentre + R(rotation) * ((world - center) * scale)
//
// R is the y-down rotation matrix [[cos, -sin], [sin, cos]], i.e. a positive
// rotation turns the picture clockwise on screen. Quarter turns are stored as
// an integer, so cos/sin are exactly 0 or +-1 and round trips are exact up to
// floating-point rounding of the scale.

import CoreGraphics
import Foundation

/// Insets of the area the overview may use inside the viewport (notch, home
/// indicator, toolbars), in view points.
struct OverviewInsets: Equatable, Sendable {
    var top: Double
    var left: Double
    var bottom: Double
    var right: Double

    static let zero = OverviewInsets(top: 0, left: 0, bottom: 0, right: 0)
}

/// Allowed camera scale range (view points per world point).
struct ZoomLimits: Equatable, Sendable {
    var min: Double
    var max: Double

    /// Limits for zooming around an arrangement.
    ///
    /// - min = 0.5 x `fitAllScale`: you can zoom out to half of fit-all.
    /// - max = 8 x the scale at which one source pixel of the focused display
    ///   is exactly one receiver pixel ("1:1 scale"), NOT 8 x fit-all.
    ///
    /// Derivation of the 1:1 scale. Let `p` = `focusedDisplayPixelsPerPoint`
    /// (source pixels per world point, e.g. 2 on a Retina Mac) and `d` =
    /// `viewDisplayScale` (receiver pixels per view point, e.g. 3 on an
    /// iPhone Pro). At camera scale `s` one world point covers `s` view points
    /// = `s * d` receiver pixels, and carries `p` source pixels. Source pixel
    /// == receiver pixel needs `s * d = p`, so `s1to1 = p / d` (the Retina Mac
    /// on the iPhone: 2 / 3 view points per world point). Hence
    /// `max = 8 * p / d`. For a very wide arrangement the fit-all scale is
    /// tiny, so this max is far above 8 x fit-all, which is the point.
    ///
    /// Invalid (non-finite or non-positive) inputs fall back to 1. `max` is
    /// never below `fitAllScale`, so fit-all itself is always inside the range
    /// even on a small arrangement that fit-all already magnifies past 8:1.
    static func limits(fitAllScale: Double, focusedDisplayPixelsPerPoint: Double,
                       viewDisplayScale: Double) -> ZoomLimits {
        let fit = OverviewCamera.sanitized(fitAllScale)
        let sourcePixelsPerPoint = OverviewCamera.sanitized(focusedDisplayPixelsPerPoint)
        let viewPixelsPerPoint = OverviewCamera.sanitized(viewDisplayScale)
        let oneToOne = sourcePixelsPerPoint / viewPixelsPerPoint
        return ZoomLimits(min: 0.5 * fit, max: Swift.max(8 * oneToOne, fit))
    }

    /// `scale` limited to `min...max`.
    func clamped(_ scale: Double) -> Double {
        Swift.min(Swift.max(scale, min), max)
    }
}

struct OverviewCamera: Equatable, Sendable {
    /// Default margin around the arrangement in `fitAll`: a fraction of the
    /// smaller viewport side.
    static let defaultMargin = 0.08
    /// Margin used when framing a single selected display.
    static let selectionMargin = 0.04

    /// World point shown at the viewport centre.
    var center: CGPoint
    /// View points per world point (> 0).
    private(set) var scale: Double
    /// Clockwise quarter turns, 0...3.
    private(set) var quarterTurns: Int

    /// Rotation in radians; always a multiple of pi/2.
    var rotation: Double { Double(quarterTurns) * (Double.pi / 2) }

    /// `rotation` is snapped to the nearest multiple of pi/2. A non-finite or
    /// non-positive `scale` becomes 1.
    init(center: CGPoint, scale: Double, rotation: Double = 0) {
        self.center = center
        self.scale = Self.sanitized(scale)
        self.quarterTurns = Self.snappedQuarterTurns(forRadians: rotation)
    }

    // MARK: Mapping

    /// Where `world` is drawn in the view (viewport size in view points).
    func viewPoint(world: CGPoint, viewport: CGSize) -> CGPoint {
        let dx = (Double(world.x) - Double(center.x)) * scale
        let dy = (Double(world.y) - Double(center.y)) * scale
        let r = Self.rotate(dx, dy, quarterTurns: quarterTurns)
        return CGPoint(x: Double(viewport.width) / 2 + r.x, y: Double(viewport.height) / 2 + r.y)
    }

    /// Exact inverse of `viewPoint(world:viewport:)`.
    func worldPoint(view: CGPoint, viewport: CGSize) -> CGPoint {
        let dx = Double(view.x) - Double(viewport.width) / 2
        let dy = Double(view.y) - Double(viewport.height) / 2
        let r = Self.rotate(dx, dy, quarterTurns: -quarterTurns)
        return CGPoint(x: Double(center.x) + r.x / scale, y: Double(center.y) + r.y / scale)
    }

    /// The axis-aligned rectangle a world rectangle covers in the view.
    func viewRect(world: CGRect, viewport: CGSize) -> CGRect {
        let corners = [CGPoint(x: world.minX, y: world.minY), CGPoint(x: world.maxX, y: world.minY),
                       CGPoint(x: world.minX, y: world.maxY), CGPoint(x: world.maxX, y: world.maxY)]
            .map { viewPoint(world: $0, viewport: viewport) }
        let xs = corners.map { Double($0.x) }
        let ys = corners.map { Double($0.y) }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: Gestures

    /// Drags the content with the finger by `byView` view points. Pan is
    /// never clamped; use `isArrangementVisible` to offer a way back.
    mutating func pan(byView delta: CGVector) {
        let r = Self.rotate(Double(delta.dx), Double(delta.dy), quarterTurns: -quarterTurns)
        center = CGPoint(x: Double(center.x) - r.x / scale, y: Double(center.y) - r.y / scale)
    }

    /// Multiplies the scale by `factor` (clamped to `limits`) while the world
    /// point under `anchorView` stays exactly under it. A non-finite or
    /// non-positive factor is ignored.
    ///
    /// A scale already outside `limits` is never pushed further out, but is
    /// not snapped to the limit either: it may move back toward the range.
    mutating func zoom(by factor: Double, anchorView: CGPoint, viewport: CGSize, limits: ZoomLimits) {
        guard factor.isFinite, factor > 0 else { return }
        let anchorWorld = worldPoint(view: anchorView, viewport: viewport)
        let target = scale * factor
        let newScale: Double
        if target >= scale {
            newScale = Swift.min(target, Swift.max(limits.max, scale))
        } else {
            newScale = Swift.max(target, Swift.min(limits.min, scale))
        }
        scale = newScale
        // Solve viewPoint(anchorWorld) == anchorView for the new centre.
        let dx = Double(anchorView.x) - Double(viewport.width) / 2
        let dy = Double(anchorView.y) - Double(viewport.height) / 2
        let r = Self.rotate(dx, dy, quarterTurns: -quarterTurns)
        center = CGPoint(x: Double(anchorWorld.x) - r.x / newScale, y: Double(anchorWorld.y) - r.y / newScale)
    }

    /// Turns the picture by whole quarter turns (positive = clockwise),
    /// keeping `center` and `scale`.
    mutating func rotate(byQuarterTurns turns: Int) {
        quarterTurns = (((quarterTurns + turns) % 4) + 4) % 4
    }

    // MARK: Framing

    /// The camera showing all of `bounds` (world) inside the safe viewport,
    /// centred, with `margin` (a fraction of the smaller viewport side) on
    /// every side. The scale is uniform, so the arrangement is never
    /// stretched. `quarterTurns` keeps an existing receiver-side rotation.
    ///
    /// Degenerate input (empty/non-finite bounds or viewport) yields scale 1
    /// centred on the bounds' midpoint (or the world origin).
    static func fitAll(bounds: CGRect, viewport: CGSize, safeInsets: OverviewInsets = .zero,
                       margin: Double = defaultMargin, quarterTurns: Int = 0) -> OverviewCamera {
        let turns = ((quarterTurns % 4) + 4) % 4
        let rotation = Double(turns) * (Double.pi / 2)
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        let fallbackCenter = (mid.x.isFinite && mid.y.isFinite) ? mid : .zero
        let vw = Double(viewport.width)
        let vh = Double(viewport.height)
        let bw = Double(bounds.width)
        let bh = Double(bounds.height)
        guard vw.isFinite, vh.isFinite, vw > 0, vh > 0, bw.isFinite, bh.isFinite, bw > 0, bh > 0 else {
            return OverviewCamera(center: fallbackCenter, scale: 1, rotation: rotation)
        }

        let left = Swift.max(insetValue(safeInsets.left), 0)
        let right = Swift.max(insetValue(safeInsets.right), 0)
        let top = Swift.max(insetValue(safeInsets.top), 0)
        let bottom = Swift.max(insetValue(safeInsets.bottom), 0)
        let safeWidth = Swift.max(vw - left - right, 1)
        let safeHeight = Swift.max(vh - top - bottom, 1)

        let marginFraction = margin.isFinite ? Swift.min(Swift.max(margin, 0), 0.45) : defaultMargin
        let inset = marginFraction * Swift.min(vw, vh)
        let availableWidth = Swift.max(safeWidth - 2 * inset, 1)
        let availableHeight = Swift.max(safeHeight - 2 * inset, 1)

        // A quarter turn swaps which world side runs along the view's x axis.
        let odd = turns % 2 == 1
        let extentX = odd ? bh : bw
        let extentY = odd ? bw : bh
        let scale = Swift.min(availableWidth / extentX, availableHeight / extentY)

        // The safe rect's centre is offset from the viewport centre; shift the
        // camera so the bounds' midpoint lands on the safe rect's centre.
        let offsetX = (left + safeWidth / 2) - vw / 2
        let offsetY = (top + safeHeight / 2) - vh / 2
        let unrotated = Self.rotate(offsetX, offsetY, quarterTurns: -turns)
        let center = CGPoint(x: Double(mid.x) - unrotated.x / scale, y: Double(mid.y) - unrotated.y / scale)
        return OverviewCamera(center: center, scale: scale, rotation: rotation)
    }

    /// The zoom-to-selection camera: frames `selectedDisplay` in the safe
    /// viewport (a tighter margin than fit-all), keeping this camera's
    /// rotation. Not clamped to `ZoomLimits`; the caller owns those.
    func frame(selectedDisplay: OverviewDisplay, viewport: CGSize,
               safeInsets: OverviewInsets = .zero) -> OverviewCamera {
        Self.fitAll(bounds: selectedDisplay.frame, viewport: viewport, safeInsets: safeInsets,
                    margin: Self.selectionMargin, quarterTurns: quarterTurns)
    }

    /// True while any part of `bounds` (world) is inside the viewport; false
    /// means the arrangement was panned or zoomed away and a recovery button
    /// should be offered.
    func isArrangementVisible(bounds: CGRect, viewport: CGSize) -> Bool {
        guard !bounds.isNull, !bounds.isInfinite, bounds.width >= 0, bounds.height >= 0 else { return false }
        let projected = viewRect(world: bounds, viewport: viewport)
        let visible = projected.intersection(CGRect(origin: .zero, size: viewport))
        return !visible.isNull && visible.width > 0 && visible.height > 0
    }

    // MARK: Internals

    /// `value` if finite and positive, else 1.
    static func sanitized(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 1
    }

    private static func insetValue(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    private static func snappedQuarterTurns(forRadians radians: Double) -> Int {
        guard radians.isFinite else { return 0 }
        let turns = Int((radians / (Double.pi / 2)).rounded())
        return ((turns % 4) + 4) % 4
    }

    /// y-down rotation by `quarterTurns` x 90 degrees, exact for integers.
    private static func rotate(_ x: Double, _ y: Double, quarterTurns: Int) -> (x: Double, y: Double) {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return (-y, x)
        case 2: return (-x, -y)
        case 3: return (y, -x)
        default: return (x, y)
        }
    }
}
