package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/RemoteViewport.swift.

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

// Compiled into the iOS target (presentation) and the hostless Mac test target
// (pure-logic coverage). CoreGraphics + Foundation only, so it stays platform-neutral.

object VideoInteractionPolicy {
    fun effectiveTarget(stored: ReceiverGestureTarget, videoEnabled: Boolean): ReceiverGestureTarget {
        // Disabled is a true no-op: unlike `.viewport`, it must never be
        // promoted to `.app` just because video is off.
        if (stored == ReceiverGestureTarget.Disabled) return ReceiverGestureTarget.Disabled
        return if (videoEnabled) stored else ReceiverGestureTarget.App
    }

    fun viewportTransform(
        base: RemoteViewportTransform,
        state: ManualViewportState,
        videoEnabled: Boolean,
    ): RemoteViewportTransform =
        if (videoEnabled) RemoteViewportCalculator.applyManualZoom(base, state) else base
}

/**
 * Begin-only hit admission: moving outside never cancels an admitted
 * sequence, while an outside begin can never enter the input pipeline later.
 */
class SurfaceTouchAdmission<ID> {
    var admitted: Set<ID> = emptySet()
        private set

    fun begin(id: ID, inside: Boolean) {
        if (inside) admitted = admitted + id
    }

    fun contains(id: ID): Boolean = admitted.contains(id)
    fun end(id: ID) { admitted = admitted - id }
    fun reset() { admitted = emptySet() }

    /** Swift value semantics: an independent copy. */
    fun copy(): SurfaceTouchAdmission<ID> = SurfaceTouchAdmission<ID>().also { it.admitted = admitted }
}

/** The `(current:, memory:)` tuple of `ViewportResetRestorePolicy.toggled`. */
data class ViewportResetRestoreResult(val current: ManualViewportState, val memory: ManualViewportState?)

object ViewportResetRestorePolicy {
    fun toggled(current: ManualViewportState, memory: ManualViewportState?, base: CGRect): ViewportResetRestoreResult? {
        if (!current.isIdentity) return ViewportResetRestoreResult(ManualViewportState.identity, current)
        if (memory == null || memory.isIdentity) return null
        return ViewportResetRestoreResult(memory.clamped(base), memory)
    }
}

/**
 * Maps between normalized remote-display coordinates (the same [0,1],
 * top-left-origin space as `touch.x/y` on the wire - PROTOCOL.md section 7)
 * and a host view's local point space.
 *
 * One transform serves both rendering (where to draw the video/cursor layer)
 * and input mapping (where a touch landed on the remote display), so the two
 * can never independently drift out of sync: `displayedRect` is exactly what a
 * caller assigns to its content layer's `frame`, and `remotePoint(forView)` is
 * its precise inverse. `displayedRect` may be larger than the host view's own
 * bounds (while magnified); `remotePoint`'s math stays correct regardless,
 * since it's a plain inverse of `viewPoint`.
 */
class RemoteViewportTransform(
    /**
     * The sub-rectangle of the normalized [0,1] remote display currently being
     * shown. Always the full unit square today, but the field stays general in
     * case a future mode legitimately needs a sub-rect.
     */
    val remoteCrop: CGRect,
    /** Where `remoteCrop` is drawn, in the host view's local coordinates. */
    val displayedRect: CGRect,
    /** Clockwise rotation in UIKit's y-down coordinate space, around the displayed rectangle's center. */
    val rotationRadians: CGFloat = 0.0,
) {
    val isValid: Boolean
        get() = remoteCrop.width > 0 && remoteCrop.height > 0 &&
            displayedRect.width > 0 && displayedRect.height > 0

    /** Normalized remote-space point -> host-view-local point. */
    fun viewPoint(forRemote: CGPoint): CGPoint {
        val p = forRemote
        if (!isValid) return CGPoint.zero
        val nx = (p.x - remoteCrop.minX) / remoteCrop.width
        val ny = (p.y - remoteCrop.minY) / remoteCrop.height
        val point = CGPoint(
            displayedRect.minX + nx * displayedRect.width,
            displayedRect.minY + ny * displayedRect.height,
        )
        return rotated(point, CGPoint(displayedRect.midX, displayedRect.midY), rotationRadians)
    }

    /**
     * Host-view-local point -> normalized remote-space point, clamped to [0,1]
     * (a touch past the visible content's edge still maps to that edge). `null`
     * when the transform is invalid or the mapped point is non-finite; never NaN.
     */
    fun remotePoint(forView: CGPoint): CGPoint? {
        val p = forView
        if (!isValid) return null
        val unrotated = rotated(p, CGPoint(displayedRect.midX, displayedRect.midY), -rotationRadians)
        val nx = (unrotated.x - displayedRect.minX) / displayedRect.width
        val ny = (unrotated.y - displayedRect.minY) / displayedRect.height
        val x = remoteCrop.minX + nx * remoteCrop.width
        val y = remoteCrop.minY + ny * remoteCrop.height
        if (!x.isFinite() || !y.isFinite()) return null
        return CGPoint(min(max(x, 0.0), 1.0), min(max(y, 0.0), 1.0))
    }

    /**
     * Whether a host-view-local point falls on the actually-rendered video (not
     * a letterbox bar, and not outside the view).
     */
    fun containsViewPoint(p: CGPoint): Boolean {
        if (!isValid) return false
        val unrotated = rotated(p, CGPoint(displayedRect.midX, displayedRect.midY), -rotationRadians)
        return displayedRect.contains(unrotated)
    }

    // Swift's synthesized == compares Doubles with IEEE ==, not Double.compare.
    override fun equals(other: Any?): Boolean =
        other is RemoteViewportTransform && remoteCrop == other.remoteCrop &&
            displayedRect == other.displayedRect && rotationRadians == other.rotationRadians

    override fun hashCode(): Int =
        31 * (31 * remoteCrop.hashCode() + displayedRect.hashCode()) + (if (rotationRadians == 0.0) 0 else rotationRadians.hashCode())

    override fun toString(): String =
        "RemoteViewportTransform(remoteCrop=$remoteCrop, displayedRect=$displayedRect, rotationRadians=$rotationRadians)"

    companion object {
        /**
         * The identity element: nothing valid to draw or map. Every geometry
         * function returns this instead of producing NaN/invalid rects when its
         * inputs don't make sense; callers can check `isValid` once.
         */
        val invalid = RemoteViewportTransform(CGRect.zero, CGRect.zero)

        private fun rotated(point: CGPoint, center: CGPoint, radians: CGFloat): CGPoint {
            if (!radians.isFinite()) return point
            val dx = point.x - center.x
            val dy = point.y - center.y
            val c = cos(radians)
            val s = sin(radians)
            return CGPoint(center.x + dx * c - dy * s, center.y + dx * s + dy * c)
        }
    }
}

/**
 * Builds `RemoteViewportTransform`s for the M4 keyboard presentation modes,
 * plus the ordinary (keyboard-hidden) case they both fall back to.
 *
 * Product rule: whenever the keyboard is open, the likely typing anchor must
 * stay visible via vertical translation alone (never horizontal) at the exact
 * normal scale. In constrained geometry (a portrait phone's tall/narrow
 * viewport) translation alone cannot bring the anchor into a comfortable
 * margin; `requiredScaleForComfort` finds the smallest scale reduction that
 * makes some valid translation work. "On" reuses that same visibility floor and
 * applies its own modest magnification on top, so `zoomOnScale >= zoomOffScale`
 * holds structurally.
 */
object RemoteViewportCalculator {
    /** Cap on the "Zoom While Typing" magnification, applied on top of whatever scale visibility already required. */
    val defaultMaxZoom: CGFloat = 1.5

    /**
     * The least `verticalTransform` will ever shrink content to while searching
     * for a translation that exposes the anchor.
     */
    val minimumScaleFactor: CGFloat = 0.35

    /**
     * Below this, a keyboard-free viewport is too short to usefully pan,
     * magnify, or shrink into; the one case where shrink-to-fit is appropriate.
     */
    val minimumUsableViewportHeight: CGFloat = 60.0

    /** Fraction of the keyboard-free viewport's vertical edge kept clear as a comfort margin. */
    val comfortMarginFraction: CGFloat = 0.12

    /**
     * While following a text caret, the fraction of the keyboard-free viewport kept clear on every
     * side as the inner region: the view stays put while the caret is inside it, and re-centers on
     * the caret (on the axis that left) once it crosses out. Wider than [comfortMarginFraction] so
     * ordinary typing never pans per character.
     */
    val caretInnerMarginFraction: CGFloat = 0.25

    /** The ordinary, keyboard-hidden presentation: the whole remote display aspect-fit into `viewBounds`. */
    fun normal(viewBounds: CGRect, remoteAspectSize: CGSize): RemoteViewportTransform =
        fitFull(viewBounds, remoteAspectSize)

    /**
     * The keyboard-open presentation.
     *
     * @param viewBounds the full host view's bounds, unaffected by the keyboard.
     * @param remoteAspectSize the remote display's pixel size (aspect ratio only).
     * @param visibleRect the sub-rect of `viewBounds` not covered by the keyboard.
     * @param anchor the last meaningful touch, in normalized remote-space. Only
     *   its `y` is ever used; `null`, or an anchor with no usable `y`, defaults
     *   to the remote display's vertical center (ordinary behavior, not a
     *   fallback). Used only when there is no usable [caret].
     * @param zoomEnabled the "Zoom While Typing" preference.
     * @param caret the Mac's text caret, a normalized remote-space rect (the `textCaret` wire
     *   message), when the Mac knows one. A usable caret replaces [anchor]: both its x and y steer
     *   the view ([caretTransform]), at the same scale the touch anchor would use. `null`, or one
     *   off the display or not finite, changes nothing: the touch anchor applies exactly as before.
     * @param previous the `displayedRect` this function returned for the caret last time, so the
     *   view only moves once the caret leaves the comfortable inner region of [visibleRect] rather
     *   than on every character. Ignored without a [caret], and when it was for a different scale.
     */
    fun keyboardOpen(
        viewBounds: CGRect,
        remoteAspectSize: CGSize,
        visibleRect: CGRect,
        anchor: CGPoint?,
        zoomEnabled: Boolean,
        maxZoom: CGFloat = defaultMaxZoom,
        caret: CGRect? = null,
        previous: CGRect? = null,
    ): RemoteViewportTransform {
        if (!(viewBounds.width > 0 && viewBounds.height > 0 &&
                remoteAspectSize.width > 0 && remoteAspectSize.height > 0 &&
                visibleRect.width > 0 && visibleRect.height > 0)
        ) {
            return normal(viewBounds, remoteAspectSize)
        }
        // Genuinely unworkable geometry: the one case a shrink-to-fit fallback is appropriate.
        if (!(visibleRect.height >= minimumUsableViewportHeight)) {
            return fitFull(visibleRect, remoteAspectSize)
        }
        val caretPoint = usableCaretPoint(caret)
        val anchorY: CGFloat = if (caretPoint != null) {
            caretPoint.y
        } else if (anchor != null && anchor.y.isFinite() && anchor.y in 0.0..1.0) {
            anchor.y
        } else {
            // No usable recent interaction: default to vertical center. This is
            // ordinary behavior, not a fallback; it must not shrink the display.
            0.5
        }
        val base = normal(viewBounds, remoteAspectSize)
        val requiredScale = if (base.isValid) requiredScaleForComfort(base.displayedRect, visibleRect, anchorY) else null
        if (requiredScale == null) {
            // Even the most aggressive allowed shrink can't bring the anchor into
            // a comfortable margin: fall back to showing everything.
            return fitFull(visibleRect, remoteAspectSize)
        }
        // "Zoom While Typing" off stops at `requiredScale`. On applies its own
        // modest magnification on top of that same floor (always >= 1).
        val scaleFactor = if (zoomEnabled) {
            requiredScale * magnification(viewBounds, visibleRect, maxZoom)
        } else {
            requiredScale
        }
        if (caretPoint != null) {
            return caretTransform(base.displayedRect, visibleRect, caretPoint, scaleFactor, previous)
                ?: fitFull(visibleRect, remoteAspectSize)
        }
        return verticalTransform(base.displayedRect, visibleRect, anchorY, scaleFactor)
            ?: fitFull(visibleRect, remoteAspectSize)
    }

    /**
     * "Zoom While Typing" magnification, derived from how much of the view the
     * keyboard covers; capped, and never below 1x.
     */
    private fun magnification(viewBounds: CGRect, visibleRect: CGRect, maxZoom: CGFloat): CGFloat {
        val factor = viewBounds.height / visibleRect.height
        if (!factor.isFinite()) return 1.0
        return min(max(factor, 1.0), maxZoom)
    }

    /**
     * The smallest scale factor (`<= 1`, floored at `minimumScaleFactor`) for
     * which some vertical-only translation of `base` can bring `anchorY`'s row
     * into a comfortable margin of `visibleRect`. Returns 1 whenever translation
     * alone already suffices. `null` means no scale down to the floor makes it
     * work; the caller falls back to fitting the whole display.
     *
     * Scaling `base` by `s` keeps it centered where `base` is centered, which
     * makes reachability monotonic enough in `s` for a bounded binary search.
     */
    private fun requiredScaleForComfort(base: CGRect, visibleRect: CGRect, anchorY: CGFloat): CGFloat? {
        val visibleSize = visibleRect.height
        if (!(visibleSize > 0 && base.height > 0)) return null
        fun comfortReachable(s: CGFloat): Boolean {
            val contentHeight = base.height * s
            val contentMin = base.midY - contentHeight / 2
            val contentMax = base.midY + contentHeight / 2
            val a = visibleRect.minY - contentMin
            val b = visibleRect.maxY - contentMax
            val lower = min(a, b)
            val upper = max(a, b)
            val anchorPos = contentMin + anchorY * contentHeight
            val margin = visibleSize * comfortMarginFraction
            val comfortMin = visibleRect.minY + margin
            val comfortMax = visibleRect.maxY - margin
            // Reachable iff the achievable anchor-position interval
            // [anchorPos+lower, anchorPos+upper] intersects the comfort interval.
            return anchorPos + upper >= comfortMin - 0.01 && anchorPos + lower <= comfortMax + 0.01
        }
        if (comfortReachable(1.0)) return 1.0
        if (!comfortReachable(minimumScaleFactor)) return null
        var lo = minimumScaleFactor
        var hi: CGFloat = 1.0
        for (i in 0 until 24) {
            val mid = (lo + hi) / 2
            if (comfortReachable(mid)) lo = mid else hi = mid
        }
        return lo
    }

    /**
     * The shared vertical-only presentation both "Zoom While Typing" modes use:
     * scale `base` by `scaleFactor` around its own center (so the horizontal
     * center never moves and is never derived from the anchor), then translate
     * vertically only as far as needed to bring `anchorY`'s row into a
     * comfortable margin of `visibleRect`, clamped so translation can never
     * manufacture blank space beyond the content's own edges. `null` on invalid inputs.
     */
    private fun verticalTransform(
        base: CGRect,
        visibleRect: CGRect,
        anchorY: CGFloat,
        scaleFactor: CGFloat,
    ): RemoteViewportTransform? {
        if (!(scaleFactor.isFinite() && scaleFactor > 0)) return null
        val width = base.width * scaleFactor
        val height = base.height * scaleFactor
        if (!(width.isFinite() && height.isFinite() && width > 0 && height > 0)) return null
        // Horizontal center matches `base` exactly: scaleFactor changes size,
        // never horizontal position (VERTICAL-ONLY movement).
        val originX = base.midX - width / 2
        var rect = CGRect(originX, base.midY - height / 2, width, height)
        val unpannedAnchorY = rect.minY + anchorY * rect.height
        val panY = clampedPan(unpannedAnchorY, rect.minY, rect.maxY, visibleRect.minY, visibleRect.maxY)
        rect = rect.offsetBy(0.0, panY)
        if (!(rect.width > 0 && rect.height > 0)) return null
        return RemoteViewportTransform(CGRect(0.0, 0.0, 1.0, 1.0), rect)
    }

    /**
     * How far to translate one axis of a fixed-size content rect so `point` (a
     * coordinate within it, pre-pan) lands inside a comfort margin of
     * `[visibleMin, visibleMax]`, clamped so translation can never expose blank
     * space beyond the content's own edges.
     *
     * The two candidate extremes are "align content's near edge with visible's
     * near edge" and "align content's far edge with visible's far edge"; min/max
     * of the two gives the correct valid range in both regimes (content larger
     * than the visible span, where a positive pan can be needed just as easily as
     * a negative one, and content smaller than it, where the range is any
     * position keeping the whole content inside the visible span - the M4
     * portrait bug was treating that case as "already fits, don't pan").
     */
    private fun clampedPan(
        point: CGFloat,
        contentMin: CGFloat,
        contentMax: CGFloat,
        visibleMin: CGFloat,
        visibleMax: CGFloat,
    ): CGFloat {
        val visibleSize = visibleMax - visibleMin
        if (!(visibleSize > 0)) return 0.0
        val margin = visibleSize * comfortMarginFraction
        val comfortMin = visibleMin + margin
        val comfortMax = visibleMax - margin
        var pan: CGFloat = 0.0
        if (point < comfortMin) {
            pan = comfortMin - point
        } else if (point > comfortMax) {
            pan = comfortMax - point
        }
        val alignNear = visibleMin - contentMin
        val alignFar = visibleMax - contentMax
        val lowerBound = min(alignNear, alignFar)
        val upperBound = max(alignNear, alignFar)
        return min(max(pan, lowerBound), upperBound)
    }

    /**
     * The centre of a normalized caret rect when it is a usable steering point: finite and on the
     * display. Everything else answers `null` so the caller falls back to the touch anchor.
     */
    private fun usableCaretPoint(caret: CGRect?): CGPoint? {
        if (caret == null || caret.isNull || caret.isInfinite) return null
        val x = caret.midX
        val y = caret.midY
        if (!(x.isFinite() && y.isFinite() && x in 0.0..1.0 && y in 0.0..1.0)) return null
        return CGPoint(x, y)
    }

    /**
     * The caret-following presentation: `base` scaled by `scaleFactor` around its own center (the
     * same size [verticalTransform] would use), then panned on both axes so the caret sits in the
     * keyboard-free area. Unlike the touch anchor it moves horizontally too, but only when the scaled
     * picture is wider than the visible area; an unmagnified picture already fits across, so its
     * horizontal center never moves.
     *
     * Each axis keeps `previous`'s pan while the caret stays inside the inner region
     * ([caretInnerMarginFraction]), and re-centers on the caret once it leaves: a pan of a few points
     * per character would read as the picture shaking. Both are clamped so no blank space opens up
     * beyond the picture's own edges.
     */
    private fun caretTransform(
        base: CGRect,
        visibleRect: CGRect,
        caret: CGPoint,
        scaleFactor: CGFloat,
        previous: CGRect?,
    ): RemoteViewportTransform? {
        if (!(scaleFactor.isFinite() && scaleFactor > 0)) return null
        val width = base.width * scaleFactor
        val height = base.height * scaleFactor
        if (!(width.isFinite() && height.isFinite() && width > 0 && height > 0)) return null
        val unpanned = CGRect(base.midX - width / 2, base.midY - height / 2, width, height)
        // The previous pan counts only for the same size: a changed scale (keyboard resized,
        // rotation) starts over from the caret.
        var previousPanX: CGFloat? = null
        var previousPanY: CGFloat? = null
        if (previous != null && abs(previous.width - width) < 0.5 && abs(previous.height - height) < 0.5) {
            previousPanX = previous.minX - unpanned.minX
            previousPanY = previous.minY - unpanned.minY
        }
        val panX = caretPan(
            unpanned.minX + caret.x * width, unpanned.minX, unpanned.maxX, visibleRect.minX, visibleRect.maxX,
            previousPanX, pansOnlyWhenWider = true,
        )
        val panY = caretPan(
            unpanned.minY + caret.y * height, unpanned.minY, unpanned.maxY, visibleRect.minY, visibleRect.maxY,
            previousPanY, pansOnlyWhenWider = false,
        )
        val rect = unpanned.offsetBy(panX, panY)
        if (!(rect.width > 0 && rect.height > 0)) return null
        return RemoteViewportTransform(CGRect(0.0, 0.0, 1.0, 1.0), rect)
    }

    /**
     * One axis of [caretTransform]. The valid range is the one [clampedPan] uses (content edges
     * against visible edges); inside it, `previous` stands while the caret stays in the inner region,
     * and otherwise the caret is centered in the visible span.
     */
    private fun caretPan(
        point: CGFloat,
        contentMin: CGFloat,
        contentMax: CGFloat,
        visibleMin: CGFloat,
        visibleMax: CGFloat,
        previous: CGFloat?,
        pansOnlyWhenWider: Boolean,
    ): CGFloat {
        val visibleSize = visibleMax - visibleMin
        if (!(visibleSize > 0)) return 0.0
        if (pansOnlyWhenWider && contentMax - contentMin <= visibleSize + 0.5) return 0.0
        val alignNear = visibleMin - contentMin
        val alignFar = visibleMax - contentMax
        val lowerBound = min(alignNear, alignFar)
        val upperBound = max(alignNear, alignFar)
        fun clamped(pan: CGFloat): CGFloat = min(max(pan, lowerBound), upperBound)
        if (previous != null) {
            val kept = clamped(previous)
            val inner = visibleSize * caretInnerMarginFraction
            val at = point + kept
            if (at >= visibleMin + inner && at <= visibleMax - inner) return kept
        }
        return clamped(visibleMin + visibleSize / 2 - point)
    }

    // MARK: - Shared geometry primitives

    /** The whole unit square, aspect-fit into `bounds`: the "show everything" fallback and the keyboard-hidden `normal()` case. */
    private fun fitFull(bounds: CGRect, remoteAspectSize: CGSize): RemoteViewportTransform {
        if (!(remoteAspectSize.width > 0 && remoteAspectSize.height > 0)) return RemoteViewportTransform.invalid
        val unit = CGRect(0.0, 0.0, 1.0, 1.0)
        val rect = fitRect(aspectRatio(unit, remoteAspectSize), bounds)
        if (!(rect.width > 0 && rect.height > 0)) return RemoteViewportTransform.invalid
        return RemoteViewportTransform(unit, rect)
    }

    /** The real (pixel-space) aspect ratio of a normalized crop rect. */
    private fun aspectRatio(crop: CGRect, aspectSize: CGSize): CGFloat {
        if (!(crop.height > 0 && aspectSize.height > 0)) return 1.0
        val width = crop.width * aspectSize.width
        val height = crop.height * aspectSize.height
        if (!(height > 0)) return 1.0
        return width / height
    }

    /** Centers a rect of the given aspect ratio inside `bounds`, scaled to fit without cropping. */
    private fun fitRect(aspectRatio: CGFloat, bounds: CGRect): CGRect {
        if (!(bounds.width > 0 && bounds.height > 0 && aspectRatio.isFinite() && aspectRatio > 0)) return CGRect.zero
        val boundsAspect = bounds.width / bounds.height
        val size = if (aspectRatio > boundsAspect) {
            CGSize(bounds.width, bounds.width / aspectRatio)
        } else {
            CGSize(bounds.height * aspectRatio, bounds.height)
        }
        if (!(size.width.isFinite() && size.height.isFinite() && size.width > 0 && size.height > 0)) return CGRect.zero
        return CGRect(
            bounds.minX + (bounds.width - size.width) / 2,
            bounds.minY + (bounds.height - size.height) / 2,
            size.width, size.height,
        )
    }

    /**
     * Applies local manual zoom/pan on top of `base`, reusing
     * `RemoteViewportTransform`'s "`displayedRect` may be larger than the host
     * view while magnified" convention rather than a second transform system.
     *
     * At identity (1x, no pan, no rotation) returns `base` completely unchanged,
     * so resetting manual zoom lands at exactly the normal/keyboard-adjusted
     * presentation with no accumulated floating-point drift. A 1x state that is
     * only panned is a plain translation of `base`.
     */
    fun applyManualZoom(base: RemoteViewportTransform, state: ManualViewportState): RemoteViewportTransform {
        if (!base.isValid) return base
        val clamped = state.clamped(base.displayedRect)
        if (clamped.isIdentity) return base
        val rect = base.displayedRect
        val width = rect.width * clamped.scale
        val height = rect.height * clamped.scale
        if (!(width.isFinite() && height.isFinite() && width > 0 && height > 0)) return base
        val scaled = CGRect(
            rect.midX - width / 2 + clamped.panX,
            rect.midY - height / 2 + clamped.panY,
            width, height,
        )
        return RemoteViewportTransform(base.remoteCrop, scaled, clamped.rotationRadians)
    }
}

/** `panLimits(against:)`'s `(x:, y:)` tuple. */
data class PanLimits(val x: CGFloat, val y: CGFloat)

/**
 * Local, receiver-only manual zoom/pan applied on top of whichever base
 * presentation (`RemoteViewportCalculator.normal`/`keyboardOpen`) is in effect:
 * the user's own pinch-to-zoom/pan on the displayed video, never sent to the
 * Mac and never affecting remote input semantics. `identity` is the at-rest
 * state: 1x, no pan.
 */
class ManualViewportState(
    var scale: CGFloat = minScale,
    /** Pan offset, in the host view's local points, applied to the scaled base rect's center. */
    var panX: CGFloat = 0.0,
    var panY: CGFloat = 0.0,
    var rotationRadians: CGFloat = 0.0,
) {
    val isIdentity: Boolean get() = this == identity

    fun copy(
        scale: CGFloat = this.scale,
        panX: CGFloat = this.panX,
        panY: CGFloat = this.panY,
        rotationRadians: CGFloat = this.rotationRadians,
    ) = ManualViewportState(scale, panX, panY, rotationRadians)

    // Swift's synthesized == compares Doubles with IEEE ==: 0.0 == -0.0, NaN != NaN.
    override fun equals(other: Any?): Boolean =
        other is ManualViewportState && scale == other.scale && panX == other.panX &&
            panY == other.panY && rotationRadians == other.rotationRadians

    override fun hashCode(): Int {
        // 0.0 and -0.0 must hash alike since they are equal.
        fun h(d: Double) = if (d == 0.0) 0 else d.hashCode()
        return ((h(scale) * 31 + h(panX)) * 31 + h(panY)) * 31 + h(rotationRadians)
    }

    override fun toString(): String =
        "ManualViewportState(scale=$scale, panX=$panX, panY=$panY, rotationRadians=$rotationRadians)"

    /**
     * Clamps `scale` to `[minScale, maxScale]` and `pan{X,Y}` so that translation
     * is independent of zoom (100% can pan too), but any edge of the remote
     * display may travel at most to the viewport's center, never past it. The
     * rule holds in the picture's own (rotated) frame: the viewport's center
     * always stays on the picture. (Clamping each screen axis to the rotated
     * bounding box instead let a tilted, diagonally panned picture leave the
     * screen entirely.) At 0, 90 and 180 degrees the two are identical. The
     * viewport's center is `base`'s center. The single source of truth for this
     * math: `applyManualZoom` and the live pinch/pan policy (`pinching`) both
     * funnel through it, which also makes it the one place that re-derives valid
     * pan bounds whenever `base` changes.
     */
    fun clamped(against: CGRect): ManualViewportState {
        val base = against
        val copy = this.copy()
        copy.scale = if (scale.isFinite()) min(max(scale, minScale), maxScale) else minScale
        copy.rotationRadians = if (rotationRadians.isFinite()) normalizedAngle(rotationRadians) else 0.0
        if (copy.panLimits(base) == null) {
            copy.panX = 0.0
            copy.panY = 0.0
            copy.rotationRadians = 0.0
            return copy
        }
        val halfWidth = base.width * copy.scale / 2
        val halfHeight = base.height * copy.scale / 2
        val c = cos(copy.rotationRadians)
        val s = sin(copy.rotationRadians)
        val x = if (panX.isFinite()) panX else 0.0
        val y = if (panY.isFinite()) panY else 0.0
        // The viewport's center relative to the picture's center, in the
        // picture's unrotated frame...
        fun local(x: CGFloat, y: CGFloat): CGPoint = CGPoint(-(x * c + y * s), -(-x * s + y * c))
        // ...with a millionth of a point of slack: a pan this clamp itself put on
        // the edge maps back a rounding error outside it.
        fun isOnPicture(x: CGFloat, y: CGFloat): Boolean {
            val point = local(x, y)
            return abs(point.x) <= halfWidth + 1e-6 && abs(point.y) <= halfHeight + 1e-6
        }
        var resultX = x
        var resultY = y
        // Already on the picture: the pan is kept exactly, so re-clamping
        // (restore, relayout) never nudges it by rounding. Otherwise the nearest
        // point of the picture, turned back into a screen-space pan.
        if (!isOnPicture(x, y)) {
            val unclamped = local(x, y)
            val localX = min(max(unclamped.x, -halfWidth), halfWidth)
            val localY = min(max(unclamped.y, -halfHeight), halfHeight)
            resultX = -(localX * c - localY * s)
            resultY = -(localX * s + localY * c)
        }
        // Floating-point dust from a pinch that ended back at rest must not leave
        // a technically-non-identity state behind, unless, tilted, dropping it
        // would step the center off the picture's edge.
        val snappedX = if (abs(resultX) < 0.01) 0.0 else resultX
        val snappedY = if (abs(resultY) < 0.01) 0.0 else resultY
        if (isOnPicture(snappedX, snappedY)) {
            resultX = snappedX
            resultY = snappedY
        }
        copy.panX = resultX
        copy.panY = resultY
        return copy
    }

    /**
     * The largest |panX|/|panY| for this scale and rotation: half the displayed
     * content's axis-aligned extent, which is how far its center can move before
     * one of its (rotated) edges would cross the viewport's center. `null` for
     * unusable geometry.
     */
    fun panLimits(against: CGRect): PanLimits? {
        val base = against
        if (!(base.width > 0 && base.height > 0 && base.width.isFinite() && base.height.isFinite())) return null
        val scale = if (this.scale.isFinite()) min(max(this.scale, minScale), maxScale) else minScale
        val rotation = if (rotationRadians.isFinite()) rotationRadians else 0.0
        val width = base.width * scale
        val height = base.height * scale
        if (!(width.isFinite() && height.isFinite() && width > 0 && height > 0)) return null
        val c = abs(cos(rotation))
        val s = abs(sin(rotation))
        return PanLimits((width * c + height * s) / 2, (width * s + height * c) / 2)
    }

    companion object {
        /** Manual zoom can never go below 1x (no such thing as "zoomed out" of the normal fit). */
        val minScale: CGFloat = 1.0

        /**
         * Cap on manual magnification. Zoom is a transform on the content layer:
         * stream resolution, decoded frame and render pass are the same at any
         * scale, so zooming adds no network, decode or render work. Unrelated to
         * Zoom While Typing's `RemoteViewportCalculator.defaultMaxZoom`.
         */
        val maxScale: CGFloat = 8.0

        /** A fresh at-rest state each time (Swift's value semantics; the Kotlin class is mutable). */
        val identity: ManualViewportState get() = ManualViewportState()

        /**
         * Pure pinch/pan policy for a live two-finger gesture: given the manual
         * state at gesture-start and the gesture's initial/current two-finger
         * midpoint and distance ratio, returns the manual state that keeps the
         * remote content under `initialMidpoint` anchored under `currentMidpoint`
         * as closely as `clamped` allows. When `scaleRatio` is ~1 but the midpoint
         * moved, this degrades to plain panning (PRODUCT RULE 2); no separate code
         * path is needed.
         *
         * `initialBase` is the unzoomed base presentation's `displayedRect` at
         * gesture start, the same fixed reference frame `applyManualZoom` scales from.
         */
        fun pinching(
            from: ManualViewportState,
            initialBase: CGRect,
            initialMidpoint: CGPoint,
            currentMidpoint: CGPoint,
            scaleRatio: CGFloat,
            rotationDelta: CGFloat = 0.0,
        ): ManualViewportState {
            val initial = from
            if (!(initialBase.width > 0 && initialBase.height > 0 && scaleRatio.isFinite() && scaleRatio > 0)) {
                return initial
            }
            val start = initial.clamped(initialBase)
            val width0 = initialBase.width * start.scale
            val height0 = initialBase.height * start.scale
            if (!(width0 > 0 && height0 > 0)) return initial
            val center0 = CGPoint(initialBase.midX + start.panX, initialBase.midY + start.panY)
            val unrotatedInitial = rotate(initialMidpoint, center0, -start.rotationRadians)
            val originX0 = center0.x - width0 / 2
            val originY0 = center0.y - height0 / 2
            // Which fraction of the currently displayed content sits under the
            // gesture's starting midpoint: this is what stays anchored.
            val fractionX = (unrotatedInitial.x - originX0) / width0
            val fractionY = (unrotatedInitial.y - originY0) / height0
            if (!(fractionX.isFinite() && fractionY.isFinite())) return initial

            val newScale = min(max(start.scale * scaleRatio, minScale), maxScale)
            val width1 = initialBase.width * newScale
            val height1 = initialBase.height * newScale
            if (!(width1.isFinite() && height1.isFinite() && width1 > 0 && height1 > 0)) return initial
            val newRotation = normalizedAngle(start.rotationRadians + rotationDelta)
            val local = CGPoint((fractionX - 0.5) * width1, (fractionY - 0.5) * height1)
            val rotatedLocal = rotate(local, CGPoint.zero, newRotation)
            val center1 = CGPoint(currentMidpoint.x - rotatedLocal.x, currentMidpoint.y - rotatedLocal.y)
            val result = ManualViewportState(
                scale = newScale,
                panX = center1.x - initialBase.midX,
                panY = center1.y - initialBase.midY,
                rotationRadians = newRotation,
            )
            return result.clamped(initialBase)
        }

        fun normalizedAngle(angle: CGFloat): CGFloat {
            if (!angle.isFinite()) return 0.0
            var value = angle % (PI * 2)
            if (value > PI) value -= PI * 2
            if (value <= -PI) value += PI * 2
            return value
        }

        private fun rotate(point: CGPoint, center: CGPoint, radians: CGFloat): CGPoint {
            val dx = point.x - center.x
            val dy = point.y - center.y
            val c = cos(radians)
            val s = sin(radians)
            return CGPoint(center.x + dx * c - dy * s, center.y + dx * s + dy * c)
        }
    }
}

/** `snappedAngle`'s `(angle:, targetQuarter:)` tuple. */
data class SnappedAngle(val angle: CGFloat, val targetQuarter: Int?)

object ViewportRotationSnap {
    val threshold: CGFloat = 7 * PI / 180

    fun snappedAngle(angle: CGFloat, enabled: Boolean): SnappedAngle {
        val normalized = ManualViewportState.normalizedAngle(angle)
        if (!enabled) return SnappedAngle(normalized, null)
        val quarter = roundedAwayFromZero(normalized / (PI / 2)).toInt()
        val target = quarter.toDouble() * PI / 2
        if (!(abs(ManualViewportState.normalizedAngle(normalized - target)) <= threshold)) {
            return SnappedAngle(normalized, null)
        }
        return SnappedAngle(ManualViewportState.normalizedAngle(target), ((quarter % 4) + 4) % 4)
    }

    /** Swift's `rounded()`: to nearest, ties away from zero (Kotlin's `round` is ties-to-even). */
    private fun roundedAwayFromZero(x: Double): Double {
        if (!x.isFinite()) return x
        val t = if (x < 0) Math.ceil(x) else Math.floor(x)
        return if (abs(x - t) >= 0.5) t + (if (x < 0) -1.0 else 1.0) else t
    }
}

/**
 * A live two-finger touch sequence's local intent: whether it should drive
 * remote Mac scrolling or local viewport zoom/pan. `Undecided` means "not
 * enough data yet", only ever a `TwoFingerGestureClassifier.classify` return
 * value pending more motion.
 */
enum class TwoFingerGestureIntent { Undecided, Scroll, ViewportZoomPan }

/**
 * Pure decision logic for the three-way two-finger arbitration problem:
 * ordinary remote scroll vs. local viewport pinch-zoom vs. (once a viewport
 * session is under way) viewport pan; see the UIKit
 * `TwoFingerViewportGestureRecognizer` in `iOS/OpenSidecarPhoneApp.swift`.
 *
 * Deliberately stateless and UIKit-free: it answers "given this one live sample
 * of a still-undecided two-finger gesture, what does it look like?" The caller
 * remembers a commitment once made and stops asking. Re-invoking this after a
 * gesture has committed would defeat that "acquire ownership and keep it"
 * contract, which is the oscillation this replaces (an earlier version
 * re-decided every frame, treating any small movement while already zoomed as
 * pan, which starved ordinary scrolling while zoomed).
 */
object TwoFingerGestureClassifier {
    /**
     * Minimum |distanceRatio - 1| before a still-undecided gesture is
     * confidently a pinch. Deliberately not hair-trigger: small natural
     * finger-spacing changes during a parallel scroll drag must not tip into zoom.
     */
    val pinchIntentThreshold: CGFloat = 0.06

    /** Minimum centroid (midpoint) movement, in points, before a still-undecided gesture is confidently a scroll drag. */
    val scrollIntentThreshold: CGFloat = 10.0
    val rotationIntentThreshold: CGFloat = 5 * PI / 180

    /**
     * Classifies one live sample of an as-yet-undecided two-finger gesture from
     * its distance-ratio and centroid movement since the gesture started.
     * Whichever threshold is crossed by the larger relative margin wins when both
     * are crossed in the same sample (the "dominance" check); this keeps a
     * diagonal, slightly converging/diverging scroll drag from misfiring as a
     * pinch just because it crosses the (much smaller, percentage-based) scale
     * threshold a frame before the absolute movement threshold.
     */
    fun classify(
        initialDistance: CGFloat,
        currentDistance: CGFloat,
        initialMidpoint: CGPoint,
        currentMidpoint: CGPoint,
        rotationDelta: CGFloat = 0.0,
    ): TwoFingerGestureIntent {
        if (!(initialDistance > 0 && currentDistance.isFinite())) return TwoFingerGestureIntent.Undecided
        val scaleDeviation = abs(currentDistance / initialDistance - 1)
        val centroidMoved = hypot(currentMidpoint.x - initialMidpoint.x, currentMidpoint.y - initialMidpoint.y)
        val scaleSignal = scaleDeviation / pinchIntentThreshold
        val scrollSignal = centroidMoved / scrollIntentThreshold
        val rotationSignal = abs(rotationDelta) / rotationIntentThreshold
        if (rotationSignal >= 1 && rotationSignal >= scrollSignal && rotationSignal >= scaleSignal) {
            return TwoFingerGestureIntent.ViewportZoomPan
        }
        if (scaleSignal >= 1 && scaleSignal >= scrollSignal) return TwoFingerGestureIntent.ViewportZoomPan
        if (scrollSignal >= 1) return TwoFingerGestureIntent.Scroll
        return TwoFingerGestureIntent.Undecided
    }
}

/**
 * A pure, UIKit-free model of one two-finger touch sequence's commitment state:
 * "decide once, via `TwoFingerGestureClassifier`, then hold that answer for the
 * rest of the sequence", the exact policy `TwoFingerViewportGestureRecognizer`
 * needs, factored out so it is testable without a touch harness. A fresh
 * `TwoFingerGestureSession()` (one per touch-down sequence, discarded when
 * fingers lift) is what "lifting fingers resets ownership" means in practice.
 */
class TwoFingerGestureSession {
    var intent: TwoFingerGestureIntent = TwoFingerGestureIntent.Undecided
        private set

    /**
     * Feeds one live sample. Once `intent` has committed to `Scroll` or
     * `ViewportZoomPan`, this is a no-op, so a caller can feed it every
     * `touchesMoved` sample unconditionally.
     */
    fun update(
        initialDistance: CGFloat,
        currentDistance: CGFloat,
        initialMidpoint: CGPoint,
        currentMidpoint: CGPoint,
        rotationDelta: CGFloat = 0.0,
    ): TwoFingerGestureIntent {
        if (intent != TwoFingerGestureIntent.Undecided) return intent
        val classified = TwoFingerGestureClassifier.classify(
            initialDistance, currentDistance, initialMidpoint, currentMidpoint, rotationDelta,
        )
        if (classified != TwoFingerGestureIntent.Undecided) intent = classified
        return intent
    }

    /** Swift value semantics: an independent copy. */
    fun copy(): TwoFingerGestureSession = TwoFingerGestureSession().also { it.intent = intent }
}

/**
 * Move View: while active, the receiver surface navigates the local viewport
 * instead of controlling the Mac. One finger pans; two fingers pan plus
 * pinch-zoom (when `allowsZoom`) and rotate (when `allowsRotation`). Every
 * change in the number of fingers re-baselines from the current state, so
 * lifting or adding a finger never jumps. Reuses `ManualViewportState.pinching`.
 */
class ViewportNavigationSession {
    private var start = ManualViewportState.identity
    private var base = CGRect.zero
    private var initialCentroid = CGPoint.zero
    private var initialDistance: CGFloat = 0.0
    private var initialAngle: CGFloat = 0.0
    var touchCount: Int = 0
        private set

    /**
     * Feeds the current finger positions (surface coordinates). Returns the
     * viewport state to show; `current` unchanged when there is nothing to do
     * (no fingers, a re-baseline, or unusable geometry).
     */
    fun update(
        points: List<CGPoint>,
        current: ManualViewportState,
        base: CGRect,
        allowsZoom: Boolean,
        allowsRotation: Boolean,
    ): ManualViewportState {
        val fingers = points.take(2)
        if (fingers.isEmpty() || !(base.width > 0 && base.height > 0)) {
            touchCount = 0
            return current
        }
        val centroid = centroid(fingers)
        if (fingers.size != touchCount || base != this.base) {
            touchCount = fingers.size
            start = current
            this.base = base
            initialCentroid = centroid
            initialDistance = if (fingers.size == 2) distance(fingers) else 0.0
            initialAngle = if (fingers.size == 2) angle(fingers) else 0.0
            return current
        }
        var scaleRatio: CGFloat = 1.0
        var rotationDelta: CGFloat = 0.0
        if (fingers.size == 2) {
            if (allowsZoom && initialDistance > 0) scaleRatio = distance(fingers) / initialDistance
            if (allowsRotation) {
                rotationDelta = ManualViewportState.normalizedAngle(angle(fingers) - initialAngle)
            }
        }
        return ManualViewportState.pinching(
            start, this.base, initialCentroid, centroid, scaleRatio, rotationDelta,
        )
    }

    fun end() {
        touchCount = 0
    }

    /** Swift value semantics: an independent copy. */
    fun copy(): ViewportNavigationSession = ViewportNavigationSession().also {
        it.start = start.copy()
        it.base = base
        it.initialCentroid = initialCentroid
        it.initialDistance = initialDistance
        it.initialAngle = initialAngle
        it.touchCount = touchCount
    }

    private fun centroid(points: List<CGPoint>): CGPoint {
        var sx = 0.0
        var sy = 0.0
        for (p in points) {
            sx += p.x
            sy += p.y
        }
        return CGPoint(sx / points.size.toDouble(), sy / points.size.toDouble())
    }

    private fun distance(points: List<CGPoint>): CGFloat =
        hypot(points[1].x - points[0].x, points[1].y - points[0].y)

    private fun angle(points: List<CGPoint>): CGFloat =
        atan2(points[1].y - points[0].y, points[1].x - points[0].x)
}

/**
 * Local View Navigation vs. Allow Input: two separate permissions. Allow Input
 * gates everything that reaches the Mac (pointer, keyboard, remote scroll,
 * gesture commands); Local View Navigation gates only the receiver-local view
 * (pan, zoom, rotation, Move View, reset), which never sends anything. With
 * input off and navigation on, the Mac can be inspected but not controlled;
 * with both off, the view is locked.
 */
object LocalViewNavigationPolicy {
    /** Whether the receiver surface should receive touches at all. */
    fun surfaceAcceptsTouches(
        remoteInputAllowed: Boolean,
        localNavigationAllowed: Boolean,
        videoEnabled: Boolean,
    ): Boolean = remoteInputAllowed || allowsViewportChanges(localNavigationAllowed, videoEnabled)

    /** Manual viewport changes only apply to live video. */
    fun allowsViewportChanges(localNavigationAllowed: Boolean, videoEnabled: Boolean): Boolean =
        localNavigationAllowed && videoEnabled

    /** The Move View control shows only when it's wanted and would work. */
    fun showsMoveView(controlVisible: Boolean, localNavigationAllowed: Boolean, videoEnabled: Boolean): Boolean =
        controlVisible && allowsViewportChanges(localNavigationAllowed, videoEnabled)
}

/** What a committed two-finger gesture may do. */
enum class TwoFingerRoute {
    /** Remote Mac scrolling. */
    RemoteScroll,

    /** Local viewport pan/zoom/rotate. */
    Viewport,

    /** App Gesture Commands (keyboard chords sent to the Mac). */
    AppCommands,
}

object TwoFingerRoutingPolicy {
    /**
     * Routes for a committed intent. Anything that reaches the Mac requires
     * `remoteInputAllowed`; the local viewport requires Local View Navigation.
     * The effective targets already fold in video-off routing.
     */
    fun routes(
        intent: TwoFingerGestureIntent,
        remoteInputAllowed: Boolean,
        localNavigationAllowed: Boolean,
        videoEnabled: Boolean,
        pinchTarget: ReceiverGestureTarget,
        rotateTarget: ReceiverGestureTarget,
    ): Set<TwoFingerRoute> = when (intent) {
        TwoFingerGestureIntent.Undecided -> emptySet()
        TwoFingerGestureIntent.Scroll ->
            if (remoteInputAllowed) setOf(TwoFingerRoute.RemoteScroll) else emptySet()
        TwoFingerGestureIntent.ViewportZoomPan -> {
            val routes = mutableSetOf<TwoFingerRoute>()
            if (LocalViewNavigationPolicy.allowsViewportChanges(localNavigationAllowed, videoEnabled)) {
                routes.add(TwoFingerRoute.Viewport)
            }
            val pinch = VideoInteractionPolicy.effectiveTarget(pinchTarget, videoEnabled)
            val rotate = VideoInteractionPolicy.effectiveTarget(rotateTarget, videoEnabled)
            if (remoteInputAllowed && (pinch == ReceiverGestureTarget.App || rotate == ReceiverGestureTarget.App)) {
                routes.add(TwoFingerRoute.AppCommands)
            }
            routes
        }
    }
}
