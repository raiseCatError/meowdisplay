// Compiled into the iOS target (presentation) and the hostless Mac test
// target (pure-logic coverage — see MacTests/RemoteViewportTests.swift).
// CoreGraphics + Foundation only, so it stays platform-neutral.

import CoreGraphics
import Foundation

/// Maps between normalized remote-display coordinates (the same [0,1],
/// top-left-origin space as `touch.x/y` on the wire — PROTOCOL.md section 7)
/// and a host view's local point space.
///
/// One transform serves both rendering (where to draw the video/cursor
/// layer) and input mapping (where a touch landed on the remote display),
/// so the two can never independently drift out of sync: `displayedRect` is
/// exactly what a caller assigns to its content layer's `frame`, and
/// `remotePoint(forView:)` is its precise inverse. `displayedRect` may be
/// larger than the host view's own bounds (while magnified) — a caller
/// that clips its content layer to its bounds gets the "may crop
/// horizontally when magnified" behavior for free, and `remotePoint`'s math
/// stays correct regardless, since it's a plain inverse of `viewPoint`.
struct RemoteViewportTransform: Equatable {
    /// The sub-rectangle of the normalized [0,1] remote display currently
    /// being shown. Always the full unit square in this file today —
    /// magnification is expressed by making `displayedRect` larger than
    /// the host view, not by cropping the source — but the field stays
    /// general in case a future mode legitimately needs a sub-rect.
    let remoteCrop: CGRect
    /// Where `remoteCrop` is drawn, in the host view's local coordinates.
    let displayedRect: CGRect

    /// The identity element: nothing valid to draw or map. Every geometry
    /// function in this file returns this instead of producing NaN/invalid
    /// rects when its inputs don't make sense (zero-size bounds, degenerate
    /// aspect ratios, etc.) — callers can check `isValid` once.
    static let invalid = RemoteViewportTransform(remoteCrop: .zero, displayedRect: .zero)

    var isValid: Bool {
        remoteCrop.width > 0 && remoteCrop.height > 0
            && displayedRect.width > 0 && displayedRect.height > 0
    }

    /// Normalized remote-space point -> host-view-local point. Used to draw
    /// the cursor sprite and to test where the anchor would land.
    func viewPoint(forRemote p: CGPoint) -> CGPoint {
        guard isValid else { return .zero }
        let nx = (p.x - remoteCrop.minX) / remoteCrop.width
        let ny = (p.y - remoteCrop.minY) / remoteCrop.height
        return CGPoint(x: displayedRect.minX + nx * displayedRect.width,
                       y: displayedRect.minY + ny * displayedRect.height)
    }

    /// Host-view-local point -> normalized remote-space point, clamped to
    /// [0,1] (a touch that lands past the visible content's edge still maps
    /// to that edge, matching pre-M4 touch behavior). `nil` when the
    /// transform itself is invalid, or the mapped point is non-finite —
    /// never returns NaN.
    func remotePoint(forView p: CGPoint) -> CGPoint? {
        guard isValid else { return nil }
        let nx = (p.x - displayedRect.minX) / displayedRect.width
        let ny = (p.y - displayedRect.minY) / displayedRect.height
        let x = remoteCrop.minX + nx * remoteCrop.width
        let y = remoteCrop.minY + ny * remoteCrop.height
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    /// Whether a host-view-local point falls on the actually-rendered video
    /// (not a letterbox bar, and not outside the view). Used to keep the
    /// M4 typing-focus anchor from ever being set to a point that isn't
    /// really on the remote display.
    func containsViewPoint(_ p: CGPoint) -> Bool {
        isValid && displayedRect.contains(p)
    }
}

/// Builds `RemoteViewportTransform`s for the M4 keyboard presentation
/// modes, plus the ordinary (keyboard-hidden) case they both fall back to.
///
/// Product rule: whenever the keyboard is open, the likely typing anchor
/// must stay visible above it, preferring vertical translation alone (never
/// horizontal) at the exact normal scale. That's sufficient most of the
/// time — but in constrained geometry (a portrait phone's tall/narrow
/// viewport, where the widescreen remote display is already letterboxed to
/// a modest band, and the anchor sits near an edge the keyboard covers)
/// translation alone cannot bring the anchor into a comfortable margin no
/// matter how it's clamped. `requiredScaleForComfort` finds the *smallest*
/// scale reduction that makes some valid translation work, so "Zoom While
/// Typing" off shrinks only exactly as much as the geometry forces, never
/// as a generic aspect-fit fallback. "On" reuses that same visibility
/// floor and applies its own modest magnification *on top of* it, so
/// `zoomOnScale >= zoomOffScale` holds structurally in every case,
/// including this one.
enum RemoteViewportCalculator {
    /// Cap on the "Zoom While Typing" magnification, applied *on top of*
    /// whatever scale visibility already required (never used to shrink
    /// toward a smaller container — that was the earlier M4 bug this
    /// replaces). Modest by design.
    static let defaultMaxZoom: CGFloat = 1.5

    /// The least `verticalTransform` will ever shrink content to while
    /// searching for a translation that exposes the anchor. Below this,
    /// the content reads as too small to usefully type into anyway, so
    /// `requiredScaleForComfort` gives up and the caller falls back to
    /// fitting the whole display instead of shrinking further.
    static let minimumScaleFactor: CGFloat = 0.35

    /// Below this, a keyboard-free viewport is too short to usefully pan,
    /// magnify, or even minimally shrink into (e.g. a sliver a couple of
    /// keyboard rows tall) — the one case where falling back to a
    /// shrink-to-fit view is appropriate, because the geometry is
    /// genuinely unworkable, not merely "the keyboard is open".
    static let minimumUsableViewportHeight: CGFloat = 60

    /// Fraction of the keyboard-free viewport's vertical edge kept clear as
    /// a comfort margin when panning to reveal the anchor.
    static let comfortMarginFraction: CGFloat = 0.12

    /// The ordinary, keyboard-hidden presentation: the whole remote display
    /// aspect-fit into `viewBounds`.
    static func normal(viewBounds: CGRect, remoteAspectSize: CGSize) -> RemoteViewportTransform {
        fitFull(into: viewBounds, remoteAspectSize: remoteAspectSize)
    }

    /// The keyboard-open presentation.
    ///
    /// - Parameters:
    ///   - viewBounds: the full host view's bounds, unaffected by the
    ///     keyboard.
    ///   - remoteAspectSize: the remote display's pixel size (aspect ratio
    ///     only; never assumed to equal `viewBounds`' size).
    ///   - visibleRect: the sub-rect of `viewBounds` not covered by the
    ///     keyboard (including its accessory view).
    ///   - anchor: the last meaningful touch, in normalized remote-space.
    ///     Only its `y` is ever used (vertical-only movement — see the type
    ///     doc); `nil`, or an anchor with no usable `y`, defaults to the
    ///     remote display's vertical center, which is ordinary behavior,
    ///     not a degraded fallback.
    ///   - zoomEnabled: the "Zoom While Typing" preference.
    static func keyboardOpen(viewBounds: CGRect,
                             remoteAspectSize: CGSize,
                             visibleRect: CGRect,
                             anchor: CGPoint?,
                             zoomEnabled: Bool,
                             maxZoom: CGFloat = defaultMaxZoom) -> RemoteViewportTransform {
        guard viewBounds.width > 0, viewBounds.height > 0,
              remoteAspectSize.width > 0, remoteAspectSize.height > 0,
              visibleRect.width > 0, visibleRect.height > 0 else {
            return normal(viewBounds: viewBounds, remoteAspectSize: remoteAspectSize)
        }
        // Genuinely unworkable geometry — the one case a shrink-to-fit
        // fallback is appropriate (see `minimumUsableViewportHeight`'s doc).
        guard visibleRect.height >= minimumUsableViewportHeight else {
            return fitFull(into: visibleRect, remoteAspectSize: remoteAspectSize)
        }
        let anchorY: CGFloat
        if let anchor, anchor.y.isFinite, (0...1).contains(anchor.y) {
            anchorY = anchor.y
        } else {
            // No usable recent interaction: default to vertical center.
            // This is ordinary behavior, not a fallback — it must not
            // shrink the display either.
            anchorY = 0.5
        }
        let base = normal(viewBounds: viewBounds, remoteAspectSize: remoteAspectSize)
        guard base.isValid,
              let requiredScale = requiredScaleForComfort(base: base.displayedRect, visibleRect: visibleRect, anchorY: anchorY)
        else {
            // Even the most aggressive allowed shrink can't bring the
            // anchor into a comfortable margin — genuinely unworkable
            // geometry, so fall back to showing everything.
            return fitFull(into: visibleRect, remoteAspectSize: remoteAspectSize)
        }
        // "Zoom While Typing" off stops here — `requiredScale` alone is
        // the answer: 1 whenever translation alone suffices (the common
        // case), or the minimal shrink the geometry forces. On applies its
        // own modest magnification *on top of* that same floor, so it can
        // never end up smaller (magnification is always >= 1).
        let scaleFactor = zoomEnabled
            ? requiredScale * magnification(viewBounds: viewBounds, visibleRect: visibleRect, maxZoom: maxZoom)
            : requiredScale
        return verticalTransform(base: base.displayedRect, visibleRect: visibleRect,
                                 anchorY: anchorY, scaleFactor: scaleFactor)
            ?? fitFull(into: visibleRect, remoteAspectSize: remoteAspectSize)
    }

    /// "Zoom While Typing" magnification, derived from how much of the view
    /// the keyboard covers — capped, and never below 1x. Multiplying this
    /// onto `requiredScaleForComfort`'s result (rather than fitting into
    /// the smaller `visibleRect` directly, the earlier M4 bug) is what
    /// makes `zoomOnScale >= zoomOffScale` hold structurally in every case.
    private static func magnification(viewBounds: CGRect, visibleRect: CGRect, maxZoom: CGFloat) -> CGFloat {
        let factor = viewBounds.height / visibleRect.height
        guard factor.isFinite else { return 1 }
        return min(max(factor, 1), maxZoom)
    }

    /// The smallest scale factor (`<= 1`, floored at `minimumScaleFactor`)
    /// for which some vertical-only translation of `base` can bring
    /// `anchorY`'s row into a comfortable margin of `visibleRect`. Returns
    /// `1` whenever translation alone already suffices — this is a search
    /// for the *minimum necessary* shrink, not a generic aspect-fit
    /// fallback, and shrinking is the exception, not the common path.
    ///
    /// `nil` means no scale down to the floor makes it work; the caller
    /// falls back to fitting the whole display.
    ///
    /// Scaling `base` by `s` keeps it centered where `base` is centered
    /// (the same convention `verticalTransform` uses), so the anchor's
    /// *unpanned* position moves continuously with `s`, and the valid pan
    /// range (see `clampedPan`) is centered a fixed distance away — this
    /// makes "can translation alone reach the comfort margin at scale s"
    /// monotonic enough in `s` for a bounded binary search to be reliable
    /// without solving the (otherwise piecewise, absolute-value-laden)
    /// closed form exactly.
    private static func requiredScaleForComfort(base: CGRect, visibleRect: CGRect, anchorY: CGFloat) -> CGFloat? {
        let visibleSize = visibleRect.height
        guard visibleSize > 0, base.height > 0 else { return nil }
        func comfortReachable(_ s: CGFloat) -> Bool {
            let contentHeight = base.height * s
            let contentMin = base.midY - contentHeight / 2
            let contentMax = base.midY + contentHeight / 2
            let a = visibleRect.minY - contentMin
            let b = visibleRect.maxY - contentMax
            let lower = min(a, b), upper = max(a, b)
            let anchorPos = contentMin + anchorY * contentHeight
            let margin = visibleSize * comfortMarginFraction
            let comfortMin = visibleRect.minY + margin
            let comfortMax = visibleRect.maxY - margin
            // Reachable iff the achievable anchor-position interval
            // [anchorPos+lower, anchorPos+upper] intersects the comfort
            // interval.
            return anchorPos + upper >= comfortMin - 0.01 && anchorPos + lower <= comfortMax + 0.01
        }
        if comfortReachable(1) { return 1 }
        guard comfortReachable(minimumScaleFactor) else { return nil }
        var lo = minimumScaleFactor
        var hi: CGFloat = 1
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if comfortReachable(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// The shared vertical-only presentation both "Zoom While Typing" modes
    /// use: scale `base` (the normal presentation's `displayedRect`) by
    /// `scaleFactor` around its own center — so the horizontal center never
    /// moves and is never derived from the anchor — then translate
    /// vertically only as far as needed to bring `anchorY`'s row into a
    /// comfortable margin of `visibleRect`, clamped so translation can
    /// never manufacture blank space beyond the content's own edges. `nil`
    /// on invalid inputs; callers already have a fallback for that.
    private static func verticalTransform(base: CGRect, visibleRect: CGRect,
                                          anchorY: CGFloat, scaleFactor: CGFloat) -> RemoteViewportTransform? {
        guard scaleFactor.isFinite, scaleFactor > 0 else { return nil }
        let width = base.width * scaleFactor
        let height = base.height * scaleFactor
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        // Horizontal center matches `base` exactly — scaleFactor changes
        // size, never horizontal position, and the anchor's x is never
        // consulted (VERTICAL-ONLY movement).
        let originX = base.midX - width / 2
        var rect = CGRect(x: originX, y: base.midY - height / 2, width: width, height: height)
        let unpannedAnchorY = rect.minY + anchorY * rect.height
        let panY = clampedPan(point: unpannedAnchorY, contentMin: rect.minY, contentMax: rect.maxY,
                              visibleMin: visibleRect.minY, visibleMax: visibleRect.maxY)
        rect = rect.offsetBy(dx: 0, dy: panY)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return RemoteViewportTransform(remoteCrop: CGRect(x: 0, y: 0, width: 1, height: 1), displayedRect: rect)
    }

    /// How far to translate one axis of a fixed-size content rect so
    /// `point` (a coordinate within it, pre-pan) lands inside a comfort
    /// margin of `[visibleMin, visibleMax]` — clamped so translation can
    /// never expose blank space beyond the content's own edges.
    ///
    /// The two candidate extremes are "align content's near edge with
    /// visible's near edge" (`visibleMin - contentMin`) and "align
    /// content's far edge with visible's far edge" (`visibleMax -
    /// contentMax`); `min`/`max` of the two always gives the correct valid
    /// range in *both* regimes without branching on which is bigger:
    /// - Content at least as large as the visible span (the ordinary case
    ///   once magnified, or unzoomed whenever the keyboard covers a
    ///   letterbox-free portion of the video): the range covers the
    ///   visible span from both edges, and content centered on the view
    ///   (as the zoomed presentation is) can legitimately need a
    ///   *positive* pan just as easily as negative — e.g. magnified
    ///   content's top can start above the view's own top edge, so
    ///   revealing an anchor near the source's top edge means panning
    ///   *down*, not up.
    /// - Content smaller than the visible span (common in portrait, where
    ///   a widescreen remote display is letterboxed to a band well inside
    ///   the keyboard-free area): the range is "any position that keeps
    ///   the whole (smaller) content inside the visible span" — this was
    ///   the M4 portrait bug: an earlier version of this function treated
    ///   this case as "already fits, don't pan" and forced pan to 0
    ///   unconditionally, when the content usually still needed to move
    ///   to actually sit inside the visible region rather than merely be
    ///   no bigger than it.
    private static func clampedPan(point: CGFloat, contentMin: CGFloat, contentMax: CGFloat,
                                   visibleMin: CGFloat, visibleMax: CGFloat) -> CGFloat {
        let visibleSize = visibleMax - visibleMin
        guard visibleSize > 0 else { return 0 }
        let margin = visibleSize * comfortMarginFraction
        let comfortMin = visibleMin + margin
        let comfortMax = visibleMax - margin
        var pan: CGFloat = 0
        if point < comfortMin {
            pan = comfortMin - point
        } else if point > comfortMax {
            pan = comfortMax - point
        }
        let alignNear = visibleMin - contentMin
        let alignFar = visibleMax - contentMax
        let lowerBound = min(alignNear, alignFar)
        let upperBound = max(alignNear, alignFar)
        return min(max(pan, lowerBound), upperBound)
    }

    // MARK: - Shared geometry primitives

    /// The whole unit square, aspect-fit into `bounds` — the "show
    /// everything" fallback, and the keyboard-hidden `normal()` case.
    private static func fitFull(into bounds: CGRect, remoteAspectSize: CGSize) -> RemoteViewportTransform {
        guard remoteAspectSize.width > 0, remoteAspectSize.height > 0 else { return .invalid }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let rect = fitRect(aspectRatio: aspectRatio(of: unit, times: remoteAspectSize), into: bounds)
        guard rect.width > 0, rect.height > 0 else { return .invalid }
        return RemoteViewportTransform(remoteCrop: unit, displayedRect: rect)
    }

    /// The real (pixel-space) aspect ratio of a normalized crop rect.
    private static func aspectRatio(of crop: CGRect, times aspectSize: CGSize) -> CGFloat {
        guard crop.height > 0, aspectSize.height > 0 else { return 1 }
        let width = crop.width * aspectSize.width
        let height = crop.height * aspectSize.height
        guard height > 0 else { return 1 }
        return width / height
    }

    /// Centers a rect of the given aspect ratio inside `bounds`, scaled to
    /// fit without cropping (standard aspect-fit/letterbox math).
    private static func fitRect(aspectRatio: CGFloat, into bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0,
              aspectRatio.isFinite, aspectRatio > 0 else { return .zero }
        let boundsAspect = bounds.width / bounds.height
        let size: CGSize
        if aspectRatio > boundsAspect {
            size = CGSize(width: bounds.width, height: bounds.width / aspectRatio)
        } else {
            size = CGSize(width: bounds.height * aspectRatio, height: bounds.height)
        }
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return .zero }
        return CGRect(x: bounds.minX + (bounds.width - size.width) / 2,
                      y: bounds.minY + (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

/// Local, receiver-only manual zoom/pan applied on top of whichever base
/// presentation (`RemoteViewportCalculator.normal`/`.keyboardOpen`) is
/// currently in effect — the user's own pinch-to-zoom/pan on the *displayed*
/// video, never sent to the Mac and never affecting remote input semantics.
/// `.identity` is the at-rest state: 1x, no pan, byte-for-byte equal to
/// whatever the base presentation already computed.
struct ManualViewportState: Equatable {
    /// Manual zoom can never go below 1x (no such thing as "zoomed out"
    /// of the normal fit) — see `clamped(against:)`.
    static let minScale: CGFloat = 1
    /// Initial cap on manual magnification (PRODUCT RULE: "approximately
    /// 3x unless architecture suggests a better bound" — nothing here does).
    static let maxScale: CGFloat = 3

    var scale: CGFloat = minScale
    /// Pan offset, in the host view's local points, applied to the scaled
    /// base rect's center — see `RemoteViewportCalculator.applyManualZoom`.
    var panX: CGFloat = 0
    var panY: CGFloat = 0

    static let identity = ManualViewportState()

    var isIdentity: Bool { self == .identity }

    /// Clamps `scale` to `[minScale, maxScale]` and `pan{X,Y}` so that
    /// `base`, scaled by the result, can never reveal blank space beyond
    /// `base`'s own footprint — i.e. the scaled rect always fully contains
    /// `base` (PRODUCT RULE: "cannot drag the remote display completely
    /// away and reveal arbitrary blank space"). At `minScale`, pan is
    /// forced to zero so returning to 1x always lands at exactly the
    /// normal, unpanned presentation. The single source of truth for this
    /// math — both `applyManualZoom` and the live pinch/pan policy
    /// (`pinching(from:...)`) funnel through this rather than duplicating
    /// clamp arithmetic, which also makes it the one place that re-derives
    /// valid pan bounds whenever `base` changes (rotation, keyboard
    /// open/close) — see the type's use from `VideoView.layoutSubviews`.
    func clamped(against base: CGRect) -> ManualViewportState {
        var copy = self
        copy.scale = scale.isFinite ? min(max(scale, Self.minScale), Self.maxScale) : Self.minScale
        guard base.width > 0, base.height > 0, copy.scale > Self.minScale else {
            copy.panX = 0
            copy.panY = 0
            return copy
        }
        let width = base.width * copy.scale
        let height = base.height * copy.scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            copy.panX = 0
            copy.panY = 0
            return copy
        }
        let maxPanX = max(0, (width - base.width) / 2)
        let maxPanY = max(0, (height - base.height) / 2)
        copy.panX = panX.isFinite ? min(max(panX, -maxPanX), maxPanX) : 0
        copy.panY = panY.isFinite ? min(max(panY, -maxPanY), maxPanY) : 0
        return copy
    }

    /// Pure pinch/pan policy for a live two-finger gesture: given the
    /// manual state at gesture-start and the gesture's initial/current
    /// two-finger midpoint and distance ratio, returns the manual state
    /// that keeps the remote content under `initialMidpoint` anchored
    /// under `currentMidpoint` as closely as `clamped(against:)` allows.
    /// Combines zoom and pan into the single gesture users expect from a
    /// pinch — when `scaleRatio` is ~1 but the midpoint moved, this
    /// degrades to plain panning, which is exactly "two-finger pan while
    /// zoomed" (PRODUCT RULE 2); no separate code path is needed for it.
    ///
    /// `initialBase` is the *unzoomed* base presentation's `displayedRect`
    /// at gesture start (before this gesture's own manual zoom is
    /// applied) — the same fixed reference frame `applyManualZoom` scales
    /// from, so this stays a pure function of that one shared geometry
    /// rather than a second transform system.
    static func pinching(from initial: ManualViewportState,
                         initialBase: CGRect,
                         initialMidpoint: CGPoint,
                         currentMidpoint: CGPoint,
                         scaleRatio: CGFloat) -> ManualViewportState {
        guard initialBase.width > 0, initialBase.height > 0,
              scaleRatio.isFinite, scaleRatio > 0 else { return initial }
        let start = initial.clamped(against: initialBase)
        let width0 = initialBase.width * start.scale
        let height0 = initialBase.height * start.scale
        guard width0 > 0, height0 > 0 else { return initial }
        let originX0 = initialBase.midX - width0 / 2 + start.panX
        let originY0 = initialBase.midY - height0 / 2 + start.panY
        // Which fraction of the *currently displayed* content sits under
        // the gesture's starting midpoint — this is what stays anchored.
        let fractionX = (initialMidpoint.x - originX0) / width0
        let fractionY = (initialMidpoint.y - originY0) / height0
        guard fractionX.isFinite, fractionY.isFinite else { return initial }

        let newScale = min(max(start.scale * scaleRatio, Self.minScale), Self.maxScale)
        let width1 = initialBase.width * newScale
        let height1 = initialBase.height * newScale
        guard width1.isFinite, height1.isFinite, width1 > 0, height1 > 0 else { return initial }
        let originX1 = currentMidpoint.x - fractionX * width1
        let originY1 = currentMidpoint.y - fractionY * height1
        let result = ManualViewportState(
            scale: newScale,
            panX: originX1 - (initialBase.midX - width1 / 2),
            panY: originY1 - (initialBase.midY - height1 / 2))
        return result.clamped(against: initialBase)
    }
}

/// A live two-finger touch sequence's local intent: whether it should
/// drive remote Mac scrolling or local viewport zoom/pan. `.undecided`
/// means "not enough data yet" — never sent to a caller as a final answer,
/// only ever a `TwoFingerGestureClassifier.classify` return value pending
/// more motion.
enum TwoFingerGestureIntent: Equatable {
    case undecided
    case scroll
    case viewportZoomPan
}

/// Pure decision logic for the three-way two-finger arbitration problem:
/// ordinary remote scroll vs. local viewport pinch-zoom vs. (once a
/// viewport session is already under way) viewport pan — see the PRODUCT
/// discussion in `iOS/OpenSidecarPhoneApp.swift`'s `TwoFingerViewportGestureRecognizer`.
///
/// Deliberately stateless and UIKit-free: it answers "given this one live
/// sample of a still-undecided two-finger gesture, what does it look
/// like?" — the caller (the gesture recognizer) is what remembers a
/// commitment once made and stops asking. Re-invoking this after a
/// gesture has already committed to `.scroll` or `.viewportZoomPan` would
/// defeat that "acquire ownership and keep it" contract, which is exactly
/// the oscillation this replaces (see the type's git history: an earlier
/// version re-decided every frame, including a rule that treated *any*
/// small movement while already manually zoomed as pan — which starved
/// ordinary scrolling while zoomed).
enum TwoFingerGestureClassifier {
    /// Minimum |distanceRatio - 1| before a still-undecided gesture is
    /// confidently a pinch. Deliberately not hair-trigger: small natural
    /// finger-spacing changes during an otherwise-parallel scroll drag
    /// must not tip into zoom.
    static let pinchIntentThreshold: CGFloat = 0.06
    /// Minimum centroid (midpoint) movement, in points, before a
    /// still-undecided gesture is confidently a scroll drag.
    static let scrollIntentThreshold: CGFloat = 10

    /// Classifies one live sample of an as-yet-undecided two-finger
    /// gesture from its distance-ratio and centroid movement since the
    /// gesture started. Whichever threshold is crossed by the larger
    /// *relative* margin wins when both are crossed in the same sample
    /// (the "dominance" check) — this is what keeps a diagonal, slightly
    /// converging/diverging scroll drag from misfiring as a pinch just
    /// because it happens to cross the (much smaller, percentage-based)
    /// scale threshold a frame before the absolute movement threshold.
    static func classify(initialDistance: CGFloat, currentDistance: CGFloat,
                         initialMidpoint: CGPoint, currentMidpoint: CGPoint) -> TwoFingerGestureIntent {
        guard initialDistance > 0, currentDistance.isFinite else { return .undecided }
        let scaleDeviation = abs(currentDistance / initialDistance - 1)
        let centroidMoved = hypot(currentMidpoint.x - initialMidpoint.x, currentMidpoint.y - initialMidpoint.y)
        let scaleSignal = scaleDeviation / pinchIntentThreshold
        let scrollSignal = centroidMoved / scrollIntentThreshold
        if scaleSignal >= 1, scaleSignal >= scrollSignal { return .viewportZoomPan }
        if scrollSignal >= 1 { return .scroll }
        return .undecided
    }
}

/// A pure, UIKit-free model of one two-finger touch sequence's commitment
/// state: "decide once, via `TwoFingerGestureClassifier`, then hold that
/// answer for the rest of the sequence" — the exact policy
/// `TwoFingerViewportGestureRecognizer` needs, factored out so it is
/// directly testable without a real touch/gesture-recognizer harness, and
/// so the recognizer itself has nowhere to duplicate or drift from this
/// logic. A fresh `TwoFingerGestureSession()` (one per touch-down sequence,
/// discarded when fingers lift) is what "lifting fingers resets ownership"
/// means in practice.
struct TwoFingerGestureSession {
    private(set) var intent: TwoFingerGestureIntent = .undecided

    /// Feeds one live sample. Once `intent` has committed to `.scroll` or
    /// `.viewportZoomPan`, this is a no-op — the whole point of the type —
    /// so a caller can feed it every `touchesMoved` sample unconditionally
    /// without checking whether it has already decided.
    @discardableResult
    mutating func update(initialDistance: CGFloat, currentDistance: CGFloat,
                         initialMidpoint: CGPoint, currentMidpoint: CGPoint) -> TwoFingerGestureIntent {
        guard intent == .undecided else { return intent }
        let classified = TwoFingerGestureClassifier.classify(
            initialDistance: initialDistance, currentDistance: currentDistance,
            initialMidpoint: initialMidpoint, currentMidpoint: currentMidpoint)
        if classified != .undecided { intent = classified }
        return intent
    }
}

extension RemoteViewportCalculator {
    /// Applies local manual zoom/pan on top of `base` — reusing
    /// `RemoteViewportTransform`'s existing "`displayedRect` may be larger
    /// than the host view while magnified" convention (see its type doc)
    /// rather than introducing a second transform/mapping system. Manual
    /// zoom is expressed purely as a further scale+translate of
    /// `base.displayedRect`; `viewPoint`/`remotePoint` need no changes to
    /// stay each other's exact inverse under it.
    ///
    /// At `state.scale <= 1` (identity), returns `base` completely
    /// unchanged — not merely numerically equal — so resetting manual zoom
    /// always lands at exactly the normal/keyboard-adjusted presentation,
    /// with no accumulated floating-point drift.
    static func applyManualZoom(to base: RemoteViewportTransform,
                                state: ManualViewportState) -> RemoteViewportTransform {
        guard base.isValid else { return base }
        let clamped = state.clamped(against: base.displayedRect)
        guard clamped.scale > ManualViewportState.minScale else { return base }
        let rect = base.displayedRect
        let width = rect.width * clamped.scale
        let height = rect.height * clamped.scale
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return base }
        let scaled = CGRect(x: rect.midX - width / 2 + clamped.panX,
                            y: rect.midY - height / 2 + clamped.panY,
                            width: width, height: height)
        return RemoteViewportTransform(remoteCrop: base.remoteCrop, displayedRect: scaled)
    }
}
