// Pure gesture-to-camera reducer behind the receiver's full-screen Multi-Display
// Overview: what a pan, a pinch, a tap or a double-tap does to the camera and the
// selection, so the SwiftUI/UIKit layer only forwards touches and draws.
//
// Compiled into the iOS/Mac receiver targets (presentation) and the hostless
// Mac test target (see MacTests/OverviewInteractionTests.swift).
// Foundation + CoreGraphics only, so it stays platform-neutral. No UI here.
//
// It owns the `DisplayOverviewModel` and the `OverviewCamera` as plain values: a
// gesture frame mutates only the camera, never rebuilds the model, so the view
// can follow a finger at the display's refresh rate.

import CoreGraphics
import Foundation

/// Where the overview draws the Mac cursor's glyph (pure, tested).
enum OverviewCursorGlyph {
    /// On-screen size of the glyph, in view points; never scaled with the camera.
    static let pointSize: Double = 18

    /// The view point of the cursor's tip, or nil when it is outside the viewport (or the
    /// inputs are unusable): nothing is drawn then.
    static func viewPoint(world: CGPoint, camera: OverviewCamera, viewport: CGSize) -> CGPoint? {
        guard world.x.isFinite, world.y.isFinite, viewport.width > 0, viewport.height > 0 else { return nil }
        let point = camera.viewPoint(world: world, viewport: viewport)
        guard point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x <= viewport.width, point.y <= viewport.height else { return nil }
        return point
    }
}

/// Where the overview's toolbar and action bar split around a vertical fold (an iPhone Duo held
/// like a book), so no button sits on the crease. Pure, tested. The canvas itself is not split:
/// the arrangement may cross the fold like a photo does.
enum OverviewChromeFold {
    struct Split: Equatable {
        /// Width from the container's leading edge to where the gap starts.
        var leading: CGFloat
        /// Width kept clear around the fold.
        var gap: CGFloat
    }

    /// A division taller than wide that crosses the chrome, or nil (no fold, a horizontal fold,
    /// or one so close to an edge that a side would be narrower than `minimumSide`).
    static func split(containerWidth: CGFloat, divisions: [CGRect], clearance: CGFloat = 8,
                      minimumSide: CGFloat = 120) -> Split? {
        guard containerWidth.isFinite, containerWidth > 0 else { return nil }
        let folds = divisions.filter { !$0.isNull && !$0.isEmpty && $0.height > $0.width
            && $0.maxX > 0 && $0.minX < containerWidth }
        guard let fold = folds.min(by: { abs($0.midX - containerWidth / 2) < abs($1.midX - containerWidth / 2) })
        else { return nil }
        let start = max(0, fold.minX - clearance)
        let end = min(containerWidth, fold.maxX + clearance)
        guard start >= minimumSide, containerWidth - end >= minimumSide else { return nil }
        return Split(leading: start, gap: end - start)
    }
}

struct OverviewInteraction: Equatable {
    /// What a point of the view lands on.
    enum Target: Equatable {
        /// A real display that can be selected and shown in a pane.
        case display(UInt32)
        /// A MeowDisplay virtual display (this device's or another's): drawn for honesty,
        /// never selected by touch and never zoomed to, but it absorbs the touch.
        case placeholder(UInt32)
        /// A gap between displays or outside the arrangement.
        case emptySpace
    }

    /// What a tap did.
    enum TapOutcome: Equatable {
        case selected(UInt32)
        case zoomedToDisplay(UInt32)
        case fitAll
        /// A placeholder took the touch; nothing changed.
        case absorbed
        /// Empty space was tapped once: nothing to do.
        case none
    }

    private(set) var model: DisplayOverviewModel
    private(set) var camera: OverviewCamera
    /// The area the camera draws into, in view points. Zero until the view is laid out.
    private(set) var viewport: CGSize
    private(set) var safeInsets: OverviewInsets
    /// Receiver pixels per view point (the view's display scale), for `ZoomLimits`.
    private(set) var viewDisplayScale: Double
    /// True until the person moves the camera: while it holds, a new viewport or a
    /// changed arrangement refits instead of leaving the picture off-centre.
    private(set) var followsFitAll = true

    /// Pixels per point assumed for a focused display whose Mac did not report one
    /// (a Retina Mac).
    static let defaultDisplayPixelsPerPoint = 2.0

    init(model: DisplayOverviewModel, viewport: CGSize = .zero, safeInsets: OverviewInsets = .zero,
         viewDisplayScale: Double = 2) {
        self.model = model
        self.viewport = viewport
        self.safeInsets = safeInsets
        self.viewDisplayScale = OverviewCamera.sanitized(viewDisplayScale)
        self.camera = OverviewCamera.fitAll(bounds: model.arrangementBounds, viewport: viewport, safeInsets: safeInsets)
    }

    /// The view moved to a display with another scale (iPhone Duo outer and inner displays).
    mutating func setViewDisplayScale(_ scale: Double) {
        viewDisplayScale = OverviewCamera.sanitized(scale)
    }

    // MARK: Derived state

    /// The camera that shows the whole arrangement ("Fit All").
    var fitAllCamera: OverviewCamera {
        OverviewCamera.fitAll(bounds: model.arrangementBounds, viewport: viewport, safeInsets: safeInsets,
                              quarterTurns: camera.quarterTurns)
    }

    /// The zoom range for the selected display: down to half of fit-all, up to 8 source
    /// pixels per receiver pixel of it (deep zoom, far beyond 8 x fit-all for a wide
    /// arrangement). Changes with the selection because displays differ in pixel density.
    var zoomLimits: ZoomLimits {
        let selectedScale = model.selected.flatMap { model.display(withID: $0)?.scale }
        return ZoomLimits.limits(fitAllScale: fitAllCamera.scale,
                                 focusedDisplayPixelsPerPoint: selectedScale ?? Self.defaultDisplayPixelsPerPoint,
                                 viewDisplayScale: viewDisplayScale)
    }

    var selectedDisplay: OverviewDisplay? {
        model.selected.flatMap { model.display(withID: $0) }
    }

    /// The one visible display whose still needs more pixels at the current zoom.
    var detailRequest: OverviewDisplayDetailRequest? {
        let visible = model.drawnDisplays.filter {
            !model.isPlaceholder($0.id) && !visibleRect(of: viewRect(of: $0)).isEmpty
        }
        let center = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        guard let display = visible.first(where: { viewRect(of: $0).contains(center) })
                ?? visible.first(where: { $0.id == model.selected })
                ?? visible.first else { return nil }
        let sourceSide = max(display.frame.width, display.frame.height)
        let density = min(camera.scale * viewDisplayScale, display.scale ?? Self.defaultDisplayPixelsPerPoint)
        let needed = sourceSide * density
        guard needed.isFinite, needed > 700 else { return nil }
        let sizes = OverviewDisplayDetailRequest.sizes
        let maximum = sizes[sizes.count - 1]
        let region = needed > Double(maximum) ? detailRegion(for: display) : nil
        let crop = region?.rect(in: display.frame) ?? display.frame
        let pixels = max(crop.width, crop.height) * density
        let side = sizes.first(where: { Double($0) >= pixels }) ?? maximum
        return OverviewDisplayDetailRequest(id: display.id, maxSide: side, region: region)
    }

    private func detailRegion(for display: OverviewDisplay) -> OverviewDisplayDetailRequest.Region? {
        // A gutter keeps some detail on screen while the next crop is on its way.
        let view = CGRect(origin: .zero, size: viewport).insetBy(dx: -80, dy: -80)
            .intersection(viewRect(of: display))
        guard !view.isEmpty else { return nil }
        let a = camera.worldPoint(view: CGPoint(x: view.minX, y: view.minY), viewport: viewport)
        let b = camera.worldPoint(view: CGPoint(x: view.maxX, y: view.maxY), viewport: viewport)
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return nil }
        let frame = display.frame
        let units = Double(OverviewDisplayDetailRequest.Region.units)
        func grid(_ value: Double, origin: Double, length: Double, roundDown: Bool) -> Int {
            let bounded = min(max((value - origin) / length, 0), 1) * units
            return Int(bounded.rounded(roundDown ? .down : .up))
        }
        let edges = [grid(min(a.x, b.x), origin: frame.minX, length: frame.width, roundDown: true),
                     grid(min(a.y, b.y), origin: frame.minY, length: frame.height, roundDown: true),
                     grid(max(a.x, b.x), origin: frame.minX, length: frame.width, roundDown: false),
                     grid(max(a.y, b.y), origin: frame.minY, length: frame.height, roundDown: false)]
        guard edges != [0, 0, Int(units), Int(units)] else { return nil }
        return OverviewDisplayDetailRequest.Region(edges)
    }

    /// The selected display is real, so the pane actions apply to it.
    var selectionCanBeShown: Bool {
        guard let id = model.selected else { return false }
        return model.display(withID: id) != nil && !model.isPlaceholder(id)
    }

    var isArrangementVisible: Bool {
        camera.isArrangementVisible(bounds: model.arrangementBounds, viewport: viewport)
    }

    /// Offer "Show All Displays": the arrangement was panned or zoomed out of view.
    var showsRecovery: Bool {
        !model.drawnDisplays.isEmpty && viewport.width > 0 && viewport.height > 0 && !isArrangementVisible
    }

    /// Where a display is drawn, in view points.
    func viewRect(of display: OverviewDisplay) -> CGRect {
        camera.viewRect(world: display.frame, viewport: viewport)
    }

    /// The part of `rect` (view points) that is inside the viewport: labels sit in it so a
    /// display zoomed far past the screen still shows its name.
    func visibleRect(of rect: CGRect) -> CGRect {
        rect.intersection(CGRect(origin: .zero, size: viewport))
    }

    /// Caption size for a tile `height` view points tall: readable on a small tile, and
    /// growing (to a cap) on a large one instead of staying a speck.
    static func labelPointSize(forTileHeight height: CGFloat) -> CGFloat {
        guard height.isFinite else { return 10 }
        return Swift.min(Swift.max(height / 14, 10), 18)
    }

    // MARK: Inputs from the view

    /// A new viewport (rotation, split view, Dynamic Type changing a toolbar): refits while
    /// the camera was never moved, otherwise leaves it alone.
    mutating func updateLayout(viewport newViewport: CGSize, safeInsets newInsets: OverviewInsets = .zero) {
        guard newViewport != viewport || newInsets != safeInsets else { return }
        viewport = newViewport
        safeInsets = newInsets
        if followsFitAll { camera = fitAllCamera }
    }

    /// A refreshed catalog. The selection survives when its display is still there; the camera
    /// stays where the person left it unless it was still following fit-all. Identical
    /// displays are ignored, so the periodic catalog refresh costs nothing.
    mutating func update(model newModel: DisplayOverviewModel) {
        guard newModel.displays != model.displays else { return }
        var next = newModel
        if let current = model.selected { next.select(id: current) }
        model = next
        if followsFitAll { camera = fitAllCamera }
    }

    /// One-finger drag: the content follows the finger. Never clamped; `showsRecovery` offers the
    /// way back.
    mutating func pan(byView delta: CGVector) {
        camera.pan(byView: delta)
        followsFitAll = false
    }

    /// One step of a pinch: `factor` is this step's scale change (not the gesture's total),
    /// `focal` the fingers' midpoint now, and `focalTranslation` how far the midpoint moved
    /// since the previous step (two fingers dragging while pinching pan too). The point of
    /// the arrangement under the fingers stays under them; the scale is clamped to `zoomLimits`.
    mutating func pinch(factor: Double, focal: CGPoint, focalTranslation: CGVector = .zero) {
        if focalTranslation != .zero { camera.pan(byView: focalTranslation) }
        camera.zoom(by: factor, anchorView: focal, viewport: viewport, limits: zoomLimits)
        followsFitAll = false
    }

    /// What `point` (view points) lands on.
    func target(atView point: CGPoint) -> Target {
        let world = camera.worldPoint(view: point, viewport: viewport)
        guard let display = model.display(at: world) else { return .emptySpace }
        return model.isPlaceholder(display.id) ? .placeholder(display.id) : .display(display.id)
    }

    /// A single tap selects a real display (the camera stays); a placeholder absorbs it.
    @discardableResult
    mutating func tap(atView point: CGPoint) -> TapOutcome {
        switch target(atView: point) {
        case .display(let id):
            model.select(id: id)
            return .selected(id)
        case .placeholder:
            return .absorbed
        case .emptySpace:
            return .none
        }
    }

    /// A double-tap on a display selects it and zooms to it; on empty space it is Fit All; a
    /// placeholder absorbs it (it is not worth a close-up and must not read as empty space).
    @discardableResult
    mutating func doubleTap(atView point: CGPoint) -> TapOutcome {
        switch target(atView: point) {
        case .display(let id):
            model.select(id: id)
            zoomToSelection()
            return .zoomedToDisplay(id)
        case .placeholder:
            return .absorbed
        case .emptySpace:
            fitAll()
            return .fitAll
        }
    }

    /// Frames the whole arrangement again (and follows it from here on).
    mutating func fitAll() {
        camera = fitAllCamera
        followsFitAll = true
    }

    /// Moves the selection in reading order (wrapping) and brings that display into frame.
    mutating func select(_ step: DisplayOverviewModel.SelectionStep) {
        model.select(step)
        zoomToSelection()
    }

    /// Selects `id` (a mirror member selects its primary) without moving the camera.
    mutating func select(id: UInt32) {
        model.select(id: id)
    }

    /// Frames the selected display, within `zoomLimits`. A frame that would need a scale outside
    /// the limits (a tiny display on a huge screen) is brought back to the limit about the middle of
    /// the safe area, so the display stays centred.
    mutating func zoomToSelection() {
        guard let display = selectedDisplay else { return }
        var framed = camera.frame(selectedDisplay: display, viewport: viewport, safeInsets: safeInsets)
        let limits = zoomLimits
        let clamped = limits.clamped(framed.scale)
        if clamped != framed.scale {
            let unbounded = ZoomLimits(min: 0, max: Double.greatestFiniteMagnitude)
            framed.zoom(by: clamped / framed.scale, anchorView: safeCentre, viewport: viewport, limits: unbounded)
        }
        camera = framed
        followsFitAll = false
    }

    // MARK: Internals

    private var safeCentre: CGPoint {
        let left = Swift.max(safeInsets.left, 0), right = Swift.max(safeInsets.right, 0)
        let top = Swift.max(safeInsets.top, 0), bottom = Swift.max(safeInsets.bottom, 0)
        return CGPoint(x: (left + Double(viewport.width) - right) / 2, y: (top + Double(viewport.height) - bottom) / 2)
    }
}
