package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/ControlTrayGeometry.swift.

import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min

data class ControlSafeInsets(
    var top: CGFloat,
    var leading: CGFloat,
    var bottom: CGFloat,
    var trailing: CGFloat,
) {
    companion object {
        val zero = ControlSafeInsets(top = 0.0, leading = 0.0, bottom = 0.0, trailing = 0.0)

        /**
         * The platform's live report is authoritative once the probe has published; the layout
         * proxy is only the startup fallback. Treating the runtime value as one complete snapshot
         * matters on rotation, when the old notch-side inset must become zero as the opposite side
         * gains it.
         */
        fun resolved(proxy: ControlSafeInsets, runtime: ControlSafeInsets?): ControlSafeInsets = runtime ?: proxy
    }
}

/** Mirrors only the two landscape cases of UIKit's `UIInterfaceOrientation`. */
enum class LandscapeInterfaceOrientation { LandscapeLeft, LandscapeRight }

/**
 * The ONLY reliable signal for which landscape edge holds the physical notch/Dynamic Island.
 * Comparing leading vs. trailing safe-area depth is unreliable (real devices can report equal
 * depths despite a single-sided notch). `UIInterfaceOrientation` describes how the CONTENT is
 * rotated, the OPPOSITE of the device's physical rotation: `.landscapeLeft` puts the notch on the
 * TRAILING edge; `.landscapeRight` puts it on the LEADING edge.
 */
object PhysicalNotchSide {
    fun forLandscape(orientation: LandscapeInterfaceOrientation?): LandscapeTraySide? = when (orientation) {
        LandscapeInterfaceOrientation.LandscapeLeft -> LandscapeTraySide.Trailing
        LandscapeInterfaceOrientation.LandscapeRight -> LandscapeTraySide.Leading
        null -> null
    }
}

enum class ControlTrayAxis { Horizontal, Vertical }

data class ControlTrayLayout(
    var trayFrame: CGRect,
    var paletteFrame: CGRect,
    var axis: ControlTrayAxis,
    /**
     * The side the Main Tray actually uses this pass. Equals the stored `preferredLandscapeSide`
     * unless an active division leaves that edge without usable space (see [ControlPlacementArea]);
     * the preference itself is never rewritten.
     */
    var side: LandscapeTraySide,
)

/**
 * A system-reserved area of the receiver's container, converted from the platform's reserved
 * region (iOS 27.1+; on Android a display cutout or fold feature) at the view boundary. Older
 * systems simply report no regions and take the existing safe-area/notch path unchanged.
 */
data class ControlReservedRegion(
    var kind: Kind,
    /** In the container's coordinate space, including the system's interactive margins around the reserved rect. */
    var frame: CGRect,
) {
    enum class Kind {
        /** Covered by hardware or system UI, e.g. a camera. */
        Occlusion,

        /** Content should split around it, e.g. a folded hinge. */
        Division,
    }

    companion object {
        fun frames(of: Kind, regions: List<ControlReservedRegion>): List<CGRect> =
            regions.filter { it.kind == of }.map { it.frame }
    }
}

/**
 * Where the controls may live once active divisions are removed from the visible container.
 * Divisions are taken from the runtime snapshot as a whole, so a fold appearing, moving or
 * disappearing simply yields a new area on the next layout.
 *
 * A division taller than it is wide splits the area into columns; a wider one splits it into rows.
 * Of the columns, the Main Tray keeps the preferred side's outer edge unless the opposite outer
 * edge offers clearly more usable width. A centered fold leaves both outer edges equally usable,
 * so the stored preference wins.
 */
data class ControlPlacementArea(
    /** The Main Tray, its palette and Same Side Function groups. */
    var main: CGRect,
    /** Opposite Side Function groups (landscape). */
    var opposite: CGRect,
    var side: LandscapeTraySide,
) {
    companion object {
        /**
         * How much wider (as a fraction of the visible extent) the other outer segment must be
         * before the effective side leaves the stored preference.
         */
        const val balanceTolerance: CGFloat = 0.1

        /** Decides the effective side, then resolves the areas for it. */
        fun resolve(
            visible: CGRect, divisions: List<CGRect>, portrait: Boolean,
            preferredSide: LandscapeTraySide, minimumExtent: CGFloat,
        ): ControlPlacementArea {
            val splitters = activeSplitters(divisions, visible)
            if (splitters.first.isEmpty() && splitters.second.isEmpty()) {
                return ControlPlacementArea(main = visible, opposite = visible, side = preferredSide)
            }
            val columns = segments(visible, splitters.first, horizontal = true)
            val side = if (chooseEnd(columns, visible, horizontal = true,
                    preferringTrailing = preferredSide == LandscapeTraySide.Trailing,
                    minimumExtent = minimumExtent)
            ) LandscapeTraySide.Trailing else LandscapeTraySide.Leading
            return area(visible, divisions, portrait, side, minimumExtent)
        }

        /** Resolves the areas for an already-decided side, so the Function Tray follows the Main Tray's effective side. */
        fun area(
            visible: CGRect, divisions: List<CGRect>, portrait: Boolean,
            side: LandscapeTraySide, minimumExtent: CGFloat,
        ): ControlPlacementArea {
            val splitters = activeSplitters(divisions, visible)
            if (splitters.first.isEmpty() && splitters.second.isEmpty()) {
                return ControlPlacementArea(main = visible, opposite = visible, side = side)
            }
            val columns = segments(visible, splitters.first, horizontal = true)
            val rows = segments(visible, splitters.second, horizontal = false)
            // Rows: the bottom edge is the natural home in both orientations.
            val row = segment(
                chooseEnd(rows, visible, horizontal = false, preferringTrailing = true, minimumExtent = minimumExtent),
                rows, visible, horizontal = false, minimumExtent = minimumExtent,
            ) ?: visible
            val mainColumn = segment(side == LandscapeTraySide.Trailing, columns, visible,
                horizontal = true, minimumExtent = minimumExtent) ?: visible
            val main = mainColumn.intersection(row)
            if (portrait) return ControlPlacementArea(main = main, opposite = main, side = side)
            val oppositeColumn = segment(side != LandscapeTraySide.Trailing, columns, visible,
                horizontal = true, minimumExtent = minimumExtent) ?: mainColumn
            return ControlPlacementArea(main = main, opposite = oppositeColumn.intersection(row), side = side)
        }

        /** (columns, rows) */
        private fun activeSplitters(divisions: List<CGRect>, visible: CGRect): Pair<List<CGRect>, List<CGRect>> {
            val clipped = divisions
                .map { it.intersection(visible) }
                .filter { !it.isNull && !it.isEmpty }
            return clipped.filter { it.height >= it.width } to clipped.filter { it.height < it.width }
        }

        /** The pieces of [area] left between [splitters] along one axis, in increasing coordinate order. */
        fun segments(area: CGRect, splitters: List<CGRect>, horizontal: Boolean): List<CGRect> {
            var pieces: List<Pair<CGFloat, CGFloat>> =
                listOf(if (horizontal) area.minX to area.maxX else area.minY to area.maxY)
            for (splitter in splitters) {
                val cut = if (horizontal) splitter.minX to splitter.maxX else splitter.minY to splitter.maxY
                pieces = pieces.flatMap { (lower, upper) ->
                    if (!(cut.first < upper && cut.second > lower)) {
                        listOf(lower to upper)
                    } else {
                        listOf(lower to min(upper, cut.first), max(lower, cut.second) to upper)
                            .filter { it.second > it.first }
                    }
                }
            }
            return pieces.sortedBy { it.first }.map { (lower, upper) ->
                if (horizontal) CGRect(lower, area.minY, upper - lower, area.height)
                else CGRect(area.minX, lower, area.width, upper - lower)
            }
        }

        /** Usable extent of the segment touching one outer edge; 0 when the division occupies that edge or leaves only a sliver. */
        private fun edgeExtent(
            trailing: Boolean, segments: List<CGRect>, area: CGRect,
            horizontal: Boolean, minimumExtent: CGFloat,
        ): CGFloat {
            val edge = (if (trailing) segments.lastOrNull() else segments.firstOrNull()) ?: return 0.0
            val touches = if (horizontal) {
                if (trailing) edge.maxX >= area.maxX else edge.minX <= area.minX
            } else {
                if (trailing) edge.maxY >= area.maxY else edge.minY <= area.minY
            }
            val extent = if (horizontal) edge.width else edge.height
            return if (touches && extent >= minimumExtent) extent else 0.0
        }

        /** `true` for the trailing (or bottom) end. */
        private fun chooseEnd(
            segments: List<CGRect>, area: CGRect, horizontal: Boolean,
            preferringTrailing: Boolean, minimumExtent: CGFloat,
        ): Boolean {
            val preferred = edgeExtent(preferringTrailing, segments, area, horizontal, minimumExtent)
            val other = edgeExtent(!preferringTrailing, segments, area, horizontal, minimumExtent)
            val total = if (horizontal) area.width else area.height
            return if (other - preferred > total * balanceTolerance) !preferringTrailing else preferringTrailing
        }

        /** The usable segment at one outer edge, or, when that edge has none, the nearest usable segment toward it. */
        private fun segment(
            trailing: Boolean, segments: List<CGRect>, area: CGRect,
            horizontal: Boolean, minimumExtent: CGFloat,
        ): CGRect? {
            val usable = segments.filter { (if (horizontal) it.width else it.height) >= minimumExtent }
            return (if (trailing) usable.lastOrNull() else usable.firstOrNull())
                ?: (if (trailing) segments.lastOrNull() else segments.firstOrNull())
        }
    }
}

/**
 * One source of truth for the Video-Off interaction surface. The returned rectangle is consumed
 * unchanged by drawing, hit testing, and input admission. In portrait, Trackpad deliberately fills
 * the tall space left between the unsafe top edge and bottom controls.
 */
object VideoOffSurfaceGeometry {
    const val margin: CGFloat = 12.0
    const val controlGap: CGFloat = 10.0

    fun interactionRect(
        container: CGRect,
        safeInsets: ControlSafeInsets,
        occupiedControlFrames: List<CGRect>,
        portrait: Boolean,
        inputMode: PointerInputMode,
        remoteAspectSize: CGSize,
        divisions: List<CGRect> = emptyList(),
    ): CGRect {
        if (!(container.width > 0 && container.height > 0)) return CGRect.zero
        var available = container.insetBy(margin, margin)
        available = CGRect(available.minX, max(available.minY, container.minY + safeInsets.top + controlGap),
            available.width, available.height)

        if (portrait) {
            // Only bottom chrome limits the large portrait surface. A temporary palette higher on
            // screen is still an occupied control, so use the first lower-half frame as the boundary.
            val bottomBoundary = occupiedControlFrames
                .filter { !it.isNull && !it.isEmpty && it.midY >= container.midY }
                .map { it.minY }
                .minOrNull() ?: (container.maxY - safeInsets.bottom)
            val maxY = min(
                available.maxY,
                min(bottomBoundary - controlGap, container.maxY - safeInsets.bottom - controlGap),
            )
            available = CGRect(available.minX, available.minY, available.width, max(0.0, maxY - available.minY))
            available = usablePiece(available, divisions)
            if (inputMode != PointerInputMode.Direct) return available
        } else {
            // Landscape keeps the established broad surface, but carves away only the side
            // actually occupied by visible controls.
            for (frame in occupiedControlFrames) {
                if (!frame.intersects(available)) continue
                available = if (frame.midX < container.midX) {
                    val minX = max(available.minX, frame.maxX + controlGap)
                    CGRect(minX, available.minY, max(0.0, available.maxX - minX), available.height)
                } else {
                    CGRect(available.minX, available.minY,
                        max(0.0, min(available.maxX, frame.minX - controlGap) - available.minX), available.height)
                }
            }
            available = usablePiece(available, divisions)
            if (inputMode != PointerInputMode.Direct) return available
        }

        // Direct Touch must retain an exact aspect-mapped surface. Trackpad is free-form because
        // it sends relative movement.
        if (!(remoteAspectSize.width > 0 && remoteAspectSize.height > 0 &&
                available.width > 0 && available.height > 0)
        ) return CGRect.zero
        val aspect = remoteAspectSize.width / remoteAspectSize.height
        val size = if (available.width / available.height > aspect) {
            CGSize(available.height * aspect, available.height)
        } else {
            CGSize(available.width, available.width / aspect)
        }
        return CGRect(available.midX - size.width / 2, available.midY - size.height / 2, size.width, size.height)
    }

    /**
     * The surface is drawn, hit-tested and mapped as ONE rectangle, so it must never bridge an
     * active division. The largest piece left beside the division is kept (ties go to the later,
     * i.e. bottom/trailing, piece); `controlGap` separates it from the fold. Without an
     * intersecting division the rectangle is returned unchanged.
     */
    fun usablePiece(available: CGRect, divisions: List<CGRect>): CGRect {
        val splitters = divisions
            .map { it.insetBy(-controlGap, -controlGap).intersection(available) }
            .filter { !it.isNull && !it.isEmpty }
        if (splitters.isEmpty()) return available
        val columns = ControlPlacementArea.segments(
            available, splitters.filter { it.height >= it.width }, horizontal = true)
        val rows = ControlPlacementArea.segments(
            available, splitters.filter { it.height < it.width }, horizontal = false)
        val pieces = columns.flatMap { column -> rows.map { column.intersection(it) } }
            .filter { !it.isNull && !it.isEmpty }
        fun area(rect: CGRect): CGFloat = rect.width * rect.height
        var best: CGRect? = null
        for (piece in pieces) {
            val b = best
            best = if (b == null) piece else if (area(piece) >= area(b)) piece else b
        }
        return best ?: CGRect.zero
    }
}

private fun clamp(value: CGFloat, min: CGFloat, max: CGFloat): CGFloat {
    // `max` can fall below `min` when the visible area is tiny; the lower bound wins so the tray
    // never leaves the safe area.
    return kotlin.math.max(min, kotlin.math.min(value, kotlin.math.max(min, max)))
}

object ControlTrayGeometry {
    /**
     * Base placement always uses the raw/full container, or, while an active division splits it,
     * the usable piece at the effective outer edge ([ControlPlacementArea]). `avoidNotch` affects
     * only the final per-frame obstacle pass; it never turns the safe-area rectangle into a global
     * layout margin.
     *
     * Compose entry point: container = the receiver's container rect; safeInsets/notchSide from
     * the window insets and cutout; keyboardVisibleRect = the IME-free rect (null if none);
     * reservedRegions = hinge (Division) and cutout (Occlusion) frames in container coordinates.
     */
    fun layout(
        container: CGRect, safeInsets: ControlSafeInsets,
        keyboardVisibleRect: CGRect?, portrait: Boolean,
        side: LandscapeTraySide, traySize: CGSize,
        paletteSize: CGSize, avoidNotch: Boolean,
        notchSide: LandscapeTraySide? = null,
        reservedRegions: List<ControlReservedRegion> = emptyList(),
        spacing: CGFloat = 10.0,
    ): ControlTrayLayout {
        var fullVisible = container
        if (keyboardVisibleRect != null) fullVisible = fullVisible.intersection(keyboardVisibleRect)
        if (fullVisible.isNull || fullVisible.isEmpty) {
            return ControlTrayLayout(CGRect.zero, CGRect.zero,
                if (portrait) ControlTrayAxis.Horizontal else ControlTrayAxis.Vertical, side)
        }

        val margin = 12.0
        val axis = if (portrait) ControlTrayAxis.Horizontal else ControlTrayAxis.Vertical
        // Without an active division this is `visible` itself and `side` unchanged.
        val divisions = ControlReservedRegion.frames(ControlReservedRegion.Kind.Division, reservedRegions)
        val area = ControlPlacementArea.resolve(
            fullVisible, divisions, portrait, side,
            minimumExtent = min(traySize.width, traySize.height) + margin * 2)
        val visible = area.main
        val requestedTraySize = traySize
        val tray = CGSize(
            min(requestedTraySize.width, max(0.0, visible.width - margin * 2)),
            min(requestedTraySize.height, max(0.0, visible.height - margin * 2)))
        // Portrait: bottom-centered. Landscape: hugging the chosen side and vertically centered.
        val trailing = area.side == LandscapeTraySide.Trailing
        val trayOrigin = if (portrait) {
            CGPoint(visible.midX - tray.width / 2, visible.maxY - margin - tray.height)
        } else {
            CGPoint(
                if (trailing) visible.maxX - margin - tray.width else visible.minX + margin,
                clamp(visible.midY - tray.height / 2, visible.minY + margin, visible.maxY - margin - tray.height))
        }
        var trayFrame = CGRect(trayOrigin, tray)

        val palette = CGSize(
            max(0.0, min(paletteSize.width, visible.width - margin * 2)),
            max(0.0, min(paletteSize.height, visible.height - margin * 2)))
        var paletteOriginX: Double
        var paletteOriginY: Double
        if (portrait) {
            paletteOriginX = min(max(visible.minX + margin, visible.midX - palette.width / 2),
                visible.maxX - margin - palette.width)
            paletteOriginY = trayFrame.minY - spacing - palette.height
        } else {
            val proposedX = if (trailing) trayFrame.minX - spacing - palette.width else trayFrame.maxX + spacing
            paletteOriginX = proposedX
            paletteOriginY = min(max(visible.minY + margin, trayFrame.midY - palette.height / 2),
                visible.maxY - margin - palette.height)
            if (proposedX < visible.minX + margin || proposedX + palette.width > visible.maxX - margin) {
                paletteOriginX = min(max(visible.minX + margin, trayFrame.midX - palette.width / 2),
                    visible.maxX - margin - palette.width)
                paletteOriginY = trayFrame.minY - spacing - palette.height
            }
        }
        paletteOriginY = min(max(visible.minY + margin, paletteOriginY), visible.maxY - margin - palette.height)
        var paletteFrame = CGRect(CGPoint(paletteOriginX, paletteOriginY), palette)

        // Obstacle avoidance is deliberately after normal placement. A non-intersecting frame
        // must remain bit-for-bit unchanged.
        val unsafeTrayFrame = avoidingUnsafeRegion(trayFrame, container, safeInsets,
            enabled = avoidNotch, portrait = portrait, notchSide = notchSide)
        // The palette belongs to the tray: when the tray steps off the home indicator or notch,
        // the palette moves with it.
        paletteFrame = paletteFrame.offsetBy(unsafeTrayFrame.minX - trayFrame.minX,
            unsafeTrayFrame.minY - trayFrame.minY)
        trayFrame = unsafeTrayFrame
        paletteFrame = avoidingUnsafeRegion(paletteFrame, container, safeInsets, enabled = avoidNotch,
            portrait = portrait, notchSide = notchSide)
        val obstacles = reservedObstacles(reservedRegions, avoidNotch)
        val obstacleBounds = fullVisible.insetBy(margin, margin)
        val reservedTrayFrame = avoidingReservedRegions(trayFrame, obstacles, obstacleBounds)
        // Carry the palette along by the same amount before clearing it too.
        paletteFrame = paletteFrame.offsetBy(reservedTrayFrame.minX - trayFrame.minX,
            reservedTrayFrame.minY - trayFrame.minY)
        trayFrame = reservedTrayFrame
        paletteFrame = avoidingReservedRegions(paletteFrame, obstacles, obstacleBounds,
            alsoAvoiding = listOf(trayFrame))
        return ControlTrayLayout(trayFrame, paletteFrame, axis, area.side)
    }

    /**
     * Divisions are never usable for controls, whatever Avoid Notch says. Occlusions follow Avoid
     * Notch, and are added on top of the safe-area fallback rather than replacing it.
     */
    fun reservedObstacles(regions: List<ControlReservedRegion>, avoidNotch: Boolean): List<CGRect> =
        ControlReservedRegion.frames(ControlReservedRegion.Kind.Division, regions) +
            (if (avoidNotch) ControlReservedRegion.frames(ControlReservedRegion.Kind.Occlusion, regions) else emptyList())

    /**
     * Moves [frame] the shortest distance that clears every obstacle it touches while staying
     * inside [bounds] and off [alsoAvoiding] (other controls it must not land on). A frame that
     * touches no obstacle is returned unchanged.
     */
    fun avoidingReservedRegions(
        frame: CGRect, obstacles: List<CGRect>, within: CGRect,
        alsoAvoiding: List<CGRect> = emptyList(),
    ): CGRect {
        val bounds = within
        val obs = obstacles.filter { !it.isNull && !it.isEmpty }
        if (frame.isEmpty || obs.none { it.intersects(frame) }) return frame
        fun isClear(candidate: CGRect): Boolean =
            bounds.contains(candidate) && (obs + alsoAvoiding).none { it.intersects(candidate) }
        // Candidates hug each side of every obstacle the frame currently touches; the nearest wins.
        val candidates = mutableListOf<CGRect>()
        for (obstacle in obs) {
            if (!obstacle.intersects(frame)) continue
            candidates += listOf(
                CGRect(obstacle.minX - frame.width, frame.minY, frame.width, frame.height),
                CGRect(obstacle.maxX, frame.minY, frame.width, frame.height),
                CGRect(frame.minX, obstacle.minY - frame.height, frame.width, frame.height),
                CGRect(frame.minX, obstacle.maxY, frame.width, frame.height),
            )
        }
        fun distance(candidate: CGRect): CGFloat =
            abs(candidate.minX - frame.minX) + abs(candidate.minY - frame.minY)
        return candidates.filter(::isClear).minByOrNull { distance(it) } ?: frame
    }

    /**
     * `notchSide` is the physical notch edge, as determined by [PhysicalNotchSide.forLandscape]
     * (NOT derived from safe-area depth comparison). `null` means no known/applicable physical
     * notch side: portrait (the notch there is the top inset), a flat/unknown orientation, or a
     * non-notched device.
     */
    fun unsafeRegions(
        container: CGRect, safeInsets: ControlSafeInsets,
        portrait: Boolean = false, notchSide: LandscapeTraySide? = null,
    ): List<CGRect> {
        val regions = mutableListOf<CGRect>()
        if (!portrait && notchSide == LandscapeTraySide.Leading && safeInsets.leading > 0) {
            val span = min(container.height, safeInsets.leading * 3)
            regions += CGRect(container.minX, container.midY - span / 2, safeInsets.leading, span)
        }
        if (!portrait && notchSide == LandscapeTraySide.Trailing && safeInsets.trailing > 0) {
            val span = min(container.height, safeInsets.trailing * 3)
            regions += CGRect(container.maxX - safeInsets.trailing, container.midY - span / 2,
                safeInsets.trailing, span)
        }
        if (safeInsets.top > 0) {
            val span = min(container.width, safeInsets.top * 3)
            regions += CGRect(container.midX - span / 2, container.minY, span, safeInsets.top)
        }
        if (safeInsets.bottom > 0) {
            val span = min(container.width, safeInsets.bottom * 3)
            regions += CGRect(container.midX - span / 2, container.maxY - safeInsets.bottom, span, safeInsets.bottom)
        }
        return regions
    }

    /**
     * Shifts [frame] inward just enough to clear localized physical edge obstacles. The platform
     * exposes each obstruction's edge depth through safe area insets, but not its outline; the
     * cross-edge extent is conservatively a centered band three times that depth. These are
     * obstacles rather than full-edge strips: a group that does not touch the sensor area stays at
     * its exact raw position.
     */
    fun avoidingUnsafeRegion(
        frame: CGRect, container: CGRect, safeInsets: ControlSafeInsets, enabled: Boolean,
        portrait: Boolean = false, notchSide: LandscapeTraySide? = null,
    ): CGRect {
        if (!enabled) return frame
        var result = frame
        if (!portrait && notchSide == LandscapeTraySide.Leading && safeInsets.leading > 0) {
            val span = min(container.height, safeInsets.leading * 3)
            val unsafe = CGRect(container.minX, container.midY - span / 2, safeInsets.leading, span)
            if (result.intersects(unsafe)) result = CGRect(unsafe.maxX, result.minY, result.width, result.height)
        }
        if (!portrait && notchSide == LandscapeTraySide.Trailing && safeInsets.trailing > 0) {
            val span = min(container.height, safeInsets.trailing * 3)
            val unsafe = CGRect(container.maxX - safeInsets.trailing, container.midY - span / 2,
                safeInsets.trailing, span)
            if (result.intersects(unsafe)) {
                result = CGRect(unsafe.minX - result.width, result.minY, result.width, result.height)
            }
        }
        if (safeInsets.top > 0) {
            val span = min(container.width, safeInsets.top * 3)
            val unsafe = CGRect(container.midX - span / 2, container.minY, span, safeInsets.top)
            if (result.intersects(unsafe)) result = CGRect(result.minX, unsafe.maxY, result.width, result.height)
        }
        if (safeInsets.bottom > 0) {
            val span = min(container.width, safeInsets.bottom * 3)
            val unsafe = CGRect(container.midX - span / 2, container.maxY - safeInsets.bottom, span, safeInsets.bottom)
            if (result.intersects(unsafe)) {
                result = CGRect(result.minX, unsafe.minY - result.height, result.width, result.height)
            }
        }
        return result
    }

    /**
     * One frame per Function Tray group (see `FunctionTrayProfile.visibleGroups`), never a single
     * combined frame, so groups can anchor independently. Portrait lays every group out in one
     * horizontal row, stacked above the Main Tray. Landscape splits the groups in half: the first
     * half anchors toward the top of the tray's side, the second half toward the bottom; "Same
     * Side" additionally keeps both halves clear of the Main Tray; "Opposite Side" anchors
     * independently against the opposite edge.
     */
    fun functionTrayLayout(
        container: CGRect, safeInsets: ControlSafeInsets,
        keyboardVisibleRect: CGRect?, portrait: Boolean,
        mainSide: LandscapeTraySide, position: FunctionTrayPosition,
        mainTrayFrame: CGRect, groupSizes: List<CGSize>,
        avoiding: CGRect?, avoidNotch: Boolean,
        notchSide: LandscapeTraySide? = null,
        reservedRegions: List<ControlReservedRegion> = emptyList(),
        spacing: CGFloat = 10.0, groupGap: CGFloat = 14.0,
    ): List<CGRect> {
        val collisionFrame = avoiding
        if (groupSizes.isEmpty()) return emptyList()
        var fullVisible = container
        if (keyboardVisibleRect != null) fullVisible = fullVisible.intersection(keyboardVisibleRect)
        if (fullVisible.isNull || fullVisible.isEmpty) return List(groupSizes.size) { CGRect.zero }

        val margin = 12.0
        // `mainSide` is the Main Tray's EFFECTIVE side (`ControlTrayLayout.side`). Each group is
        // laid out, and kept, inside its own usable piece.
        val area = ControlPlacementArea.area(
            fullVisible, ControlReservedRegion.frames(ControlReservedRegion.Kind.Division, reservedRegions),
            portrait, mainSide,
            minimumExtent = min(mainTrayFrame.width, mainTrayFrame.height) + margin * 2)
        val visible = if (portrait || position == FunctionTrayPosition.SameSide) area.main else area.opposite
        fun bounded(size: CGSize) = CGSize(
            min(size.width, max(0.0, visible.width - margin * 2)),
            min(size.height, max(0.0, visible.height - margin * 2)))

        var frames: MutableList<CGRect>
        if (portrait) {
            val sizes = groupSizes.map(::bounded)
            val totalWidth = sizes.fold(0.0) { acc, s -> acc + s.width } +
                max(0, sizes.size - 1).toDouble() * groupGap
            var x = visible.midX - totalWidth / 2
            val rowHeight = sizes.map { it.height }.maxOrNull() ?: 0.0
            val y = mainTrayFrame.minY - spacing - rowHeight
            frames = sizes.map { size ->
                val frame = CGRect(x, y, size.width, size.height)
                x += size.width + groupGap
                frame
            }.toMutableList()
        } else {
            val side = if (position == FunctionTrayPosition.SameSide) mainSide else mainSide.opposite
            fun originX(width: CGFloat): CGFloat =
                if (side == LandscapeTraySide.Trailing) visible.maxX - margin - width else visible.minX + margin
            // Only constrains the halves against the Main Tray when they share its edge.
            val topBound = if (position == FunctionTrayPosition.SameSide) mainTrayFrame.minY - spacing
            else visible.maxY - margin
            val bottomBound = if (position == FunctionTrayPosition.SameSide) mainTrayFrame.maxY + spacing
            else visible.minY + margin
            val topCount = (groupSizes.size + 1) / 2
            frames = MutableList(groupSizes.size) { CGRect.zero }

            // Top half: anchored at the corner unless that would run into the Main Tray, in which
            // case it's pulled up only as much as needed to stay clear.
            var y = visible.minY + margin
            for (index in 0 until topCount) {
                val size = bounded(groupSizes[index])
                val originY = min(y, topBound - size.height)
                frames[index] = CGRect(originX(size.width), max(visible.minY + margin, originY),
                    size.width, size.height)
                y = frames[index].maxY + spacing
            }
            // Bottom half: same idea from the opposite corner.
            var yBottom = visible.maxY - margin
            for (index in groupSizes.size - 1 downTo topCount) {
                val size = bounded(groupSizes[index])
                val originY = max(yBottom - size.height, bottomBound)
                frames[index] = CGRect(originX(size.width), min(originY, visible.maxY - margin - size.height),
                    size.width, size.height)
                yBottom = frames[index].minY - spacing
            }
        }

        // If the rendered tray is taller than the available middle region, vertical clearance is
        // impossible: move only the colliding group inward along the horizontal axis.
        if (!portrait && position == FunctionTrayPosition.SameSide) {
            frames = frames.map {
                displaced(it, mainTrayFrame, within = visible.insetBy(margin, margin),
                    axis = ControlTrayAxis.Vertical, spacing = spacing)
            }.toMutableList()
        }
        // The temporary palette has priority over both trays. Resolve it after the Same Side Main
        // Tray fallback, retaining the Main Tray as a protected obstacle.
        val protectedFrames = if (!portrait && position == FunctionTrayPosition.SameSide) listOf(mainTrayFrame)
        else emptyList()
        frames = frames.map {
            displaced(it, collisionFrame, alsoAvoiding = protectedFrames,
                within = visible.insetBy(margin, margin),
                axis = if (portrait) ControlTrayAxis.Horizontal else ControlTrayAxis.Vertical, spacing = spacing)
        }.toMutableList()
        frames = frames.map {
            avoidingUnsafeRegion(it, container, safeInsets, enabled = avoidNotch,
                portrait = portrait, notchSide = notchSide)
        }.toMutableList()
        val obstacles = reservedObstacles(reservedRegions, avoidNotch)
        return frames.map { frame ->
            val x = clamp(frame.minX, visible.minX + margin, visible.maxX - margin - frame.width)
            val yy = clamp(frame.minY, visible.minY + margin, visible.maxY - margin - frame.height)
            val result = CGRect(x, yy, frame.width, frame.height)
            avoidingReservedRegions(result, obstacles, within = fullVisible.insetBy(margin, margin),
                alsoAvoiding = listOf(mainTrayFrame) + (if (collisionFrame != null) listOf(collisionFrame) else emptyList()))
        }
    }

    /**
     * Nudges [frame] clear of [avoid] along [axis]: up/down in portrait (`Horizontal` axis,
     * matching the tray's own row direction), left/right in landscape, preferring whichever
     * direction actually stays inside [within]. A no-op when there's nothing to avoid or they
     * don't overlap.
     */
    fun displaced(
        frame: CGRect, avoid: CGRect?, alsoAvoiding: List<CGRect> = emptyList(),
        within: CGRect, axis: ControlTrayAxis, spacing: CGFloat,
    ): CGRect {
        if (avoid == null || !frame.intersects(avoid)) return frame
        fun isAvailable(candidate: CGRect): Boolean =
            within.contains(candidate) && alsoAvoiding.all { !candidate.intersects(it) }
        if (axis == ControlTrayAxis.Horizontal) {
            val above = CGRect(frame.minX, avoid.minY - spacing - frame.height, frame.width, frame.height)
            val below = CGRect(frame.minX, avoid.maxY + spacing, frame.width, frame.height)
            if (isAvailable(above)) return above
            if (isAvailable(below)) return below
            return frame
        } else {
            val before = CGRect(avoid.minX - spacing - frame.width, frame.minY, frame.width, frame.height)
            val after = CGRect(avoid.maxX + spacing, frame.minY, frame.width, frame.height)
            if (isAvailable(before)) return before
            if (isAvailable(after)) return after
            return frame
        }
    }

    /**
     * The iPhone Main Tray's chip diameter along a screen edge [length] points long: the standard
     * size, shrunk just enough that every chip and the layout margins fit, never below [minimum].
     */
    fun fittedChipDiameter(
        count: Int, length: CGFloat, preferred: CGFloat = 40.0,
        gap: CGFloat = 4.0, slack: CGFloat = 4.0, margin: CGFloat = 12.0,
        minimum: CGFloat = 30.0,
    ): CGFloat {
        if (count <= 0) return preferred
        val room = length - margin * 2 - slack - (count - 1).toDouble() * gap
        return max(minimum, min(preferred, floor(room / count.toDouble())))
    }
}
