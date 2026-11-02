package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/PadControlLayout.swift.
//
// iPad-only control presentation: Strip / Overlay edge geometry, control
// scale, rail composition and palette placement. Pure geometry, so a Compose
// UI on a tablet or unfolded foldable lays out exactly like the iPad.

import kotlinx.serialization.json.JsonElement
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sign
import kotlin.math.truncate

/** Swift's `Double.rounded()`: halves round away from zero (Kotlin's `round` rounds half to even). */
internal fun Double.roundedAwayFromZero(): Double {
    if (!isFinite()) return this
    val whole = truncate(this)
    return if (abs(this - whole) >= 0.5) whole + sign(this) else whole
}

/** The iPad `Control Layout` setting. */
enum class PadControlLayoutMode(val raw: String, val title: String) {
    /** A solid edge rail; the Mac canvas fits beside it. */
    Strip("strip", "Strip"),

    /** Controls float over a full-screen Mac canvas. */
    Overlay("overlay", "Overlay"),

    /** The active user-built layout; see [CustomControlLayout]. */
    Custom("custom", "Custom");

    val id: String get() = raw

    companion object {
        fun of(raw: String?): PadControlLayoutMode? = entries.firstOrNull { it.raw == raw }
    }
}

/** A screen edge for the iPad Main or Function controls. */
enum class ControlEdge(val raw: String, val title: String) {
    Leading("leading", "Left"),
    Trailing("trailing", "Right"),
    Top("top", "Top"),
    Bottom("bottom", "Bottom");

    val id: String get() = raw

    /** Controls along a left/right edge stack vertically. */
    val stacksVertically: Boolean get() = this == Leading || this == Trailing

    companion object {
        fun of(raw: String?): ControlEdge? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * Bounded iPad `Control Size`. The floor keeps a control's hit target
 * (`PadControlMetrics.baseItem` x scale, plus touch slack) around 40 pt; the
 * ceiling keeps a full Main cluster on a portrait 11" edge.
 */
object PadControlScale {
    val range: ClosedFloatingPointRange<Double> = 0.85..1.4
    const val defaultValue = 1.0

    fun clamped(value: Double): Double {
        if (!value.isFinite()) return defaultValue
        return min(max(value, range.start), range.endInclusive)
    }
}

/** Point sizes for one scale/hints combination. */
class PadControlMetrics(scale: Double = PadControlScale.defaultValue, val showsHints: Boolean = false) {
    val scale: CGFloat = PadControlScale.clamped(scale)

    val item: CGFloat get() = (baseItem * scale).roundedAwayFromZero()
    val gap: CGFloat get() = baseGap * scale
    val groupGap: CGFloat get() = baseGroupGap * scale

    /**
     * One control's footprint: its circle, plus a caption line below it (and
     * room for the caption's width) while hints show.
     */
    val cell: CGSize
        get() = if (showsHints) {
            CGSize(width = item + hintWidthAllowance, height = item + hintHeight + 2)
        } else {
            CGSize(width = item, height = item)
        }

    /** Cross-edge thickness of a cluster on [edge]. */
    fun clusterThickness(edge: ControlEdge): CGFloat = if (edge.stacksVertically) cell.width else cell.height

    /** Along-edge length of [count] controls. */
    fun clusterLength(count: Int, edge: ControlEdge): CGFloat {
        if (count <= 0) return 0.0
        val along = if (edge.stacksVertically) cell.height else cell.width
        return count.toDouble() * along + (count - 1).toDouble() * gap
    }

    fun clusterSize(count: Int, edge: ControlEdge): CGSize {
        val along = clusterLength(count, edge)
        val thickness = clusterThickness(edge)
        return if (edge.stacksVertically) CGSize(thickness, along) else CGSize(along, thickness)
    }

    /** The Strip rail's thickness before any safe-area inset on its edge. */
    fun stripThickness(edge: ControlEdge): CGFloat = clusterThickness(edge) + stripPadding * 2

    override fun equals(other: Any?): Boolean = other is PadControlMetrics && scale == other.scale && showsHints == other.showsHints
    override fun hashCode(): Int = 31 * scale.hashCode() + showsHints.hashCode()
    override fun toString(): String = "PadControlMetrics(scale=$scale, showsHints=$showsHints)"

    companion object {
        const val baseItem: CGFloat = 44.0
        const val baseGap: CGFloat = 8.0
        const val baseGroupGap: CGFloat = 20.0
        const val hintHeight: CGFloat = 12.0
        const val hintWidthAllowance: CGFloat = 18.0
        const val stripPadding: CGFloat = 10.0
        const val edgeMargin: CGFloat = 12.0
    }
}

data class PadStrip(
    var edge: ControlEdge,
    /** The solid rail, including the part under the edge's safe-area inset. */
    var frame: CGRect,
)

/** One placed run of controls: a whole group, or the part of one that had to continue in another lane. */
data class PadSegment(var group: Int, var cells: List<CGRect>) {
    val frame: CGRect get() = cells.drop(1).fold(cells.firstOrNull() ?: CGRect.NULL) { a, b -> a.union(b) }
}

/** One Strip/Overlay layout pass. */
data class PadEdgeLayout(
    /**
     * Where the Mac display is presented: the container minus any Strip rails
     * in Strip mode, the whole container in Overlay.
     */
    var canvas: CGRect,
    var strips: List<PadStrip>,
    var mainSegments: List<PadSegment>,
    var functionSegments: List<PadSegment>,
    /** Lanes per used edge (more than one only when an edge overflows). */
    var laneCounts: Map<ControlEdge, Int>,
) {
    /** Main control cells, in item order. */
    val mainCells: List<CGRect> get() = mainSegments.flatMap { it.cells }

    /** Function control cells, in item order. */
    val functionCells: List<CGRect> get() = functionSegments.flatMap { it.cells }

    val mainFrame: CGRect?
        get() {
            val frames = mainSegments.map { it.frame }
            return if (frames.isEmpty()) null else frames.drop(1).fold(frames[0]) { a, b -> a.union(b) }
        }

    companion object {
        val empty = PadEdgeLayout(CGRect.zero, emptyList(), emptyList(), emptyList(), emptyMap())
    }
}

object PadEdgeGeometry {
    /**
     * The iPad Strip/Overlay layout, as lanes of control groups along each
     * used edge.
     *
     * - Main groups (system, keys, view; see [PadRailComposition]) keep their
     *   order with a group gap between them and sit centered on their edge.
     * - Function groups split in two: the first half toward the start of their
     *   edge (top, or left), the rest toward the end.
     * - On a shared edge, Function groups take the two ends and the Main run
     *   shifts off center as far as needed to clear them.
     * - Nothing ever overlaps. When an edge can't hold everything in one lane,
     *   the overflow moves to the next lane inward, deterministically: Main
     *   groups wrap at group boundaries (a group longer than the edge wraps at
     *   the last control that fits), and Function groups that don't fit beside
     *   the Main run get a lane of their own. A Strip widens to hold every lane.
     *
     * @param keyboardTop the docked software keyboard's top edge in [container]
     * coordinates, if one is open. Bottom lanes rise above it and side lanes
     * stop short of it; Strip rails don't move.
     */
    fun layout(
        container: CGRect,
        safeInsets: ControlSafeInsets,
        reservesStrips: Boolean,
        mainEdge: ControlEdge,
        functionEdge: ControlEdge,
        mainGroupCounts: List<Int>,
        mainGroupAlignments: List<PadGroupAlignment> = emptyList(),
        functionGroupCounts: List<Int>,
        metrics: PadControlMetrics,
        keyboardTop: CGFloat? = null,
    ): PadEdgeLayout {
        if (!(container.width > 0 && container.height > 0)) {
            return PadEdgeLayout(container, emptyList(), emptyList(), emptyList(), emptyMap())
        }
        val mainAlignments = mainGroupCounts.indices.filter { mainGroupCounts[it] > 0 }.map {
            if (it < mainGroupAlignments.size) mainGroupAlignments[it] else PadGroupAlignment.Center
        }
        val main = mainGroupCounts.filter { it > 0 }
        val function = functionGroupCounts.filter { it > 0 }
        val usedEdges = mutableListOf<ControlEdge>()
        if (main.isNotEmpty()) usedEdges.add(mainEdge)
        if (function.isNotEmpty() && functionEdge !in usedEdges) usedEdges.add(functionEdge)

        // Rails depend on the lanes of perpendicular edges and vice versa;
        // settle lane counts with a few deterministic passes.
        var lanes: Map<ControlEdge, Int> = usedEdges.associateWith { 1 }
        val packed = mutableMapOf<ControlEdge, List<PlacedBlock>>()
        for (pass in 0 until 4) {
            val next = mutableMapOf<ControlEdge, Int>()
            for (edge in usedEdges) {
                val range = alongRange(edge, container, safeInsets, reservesStrips, lanes, metrics, keyboardTop)
                val blocks = pack(
                    length = range.endInclusive - range.start, edge = edge, metrics = metrics,
                    main = if (edge == mainEdge) main else emptyList(), alignments = mainAlignments,
                    function = if (edge == functionEdge) function else emptyList(),
                )
                packed[edge] = blocks
                next[edge] = max(1, (blocks.maxOfOrNull { it.lane } ?: 0) + 1)
            }
            if (next == lanes) break
            lanes = next
        }

        val strips = if (reservesStrips) stripFrames(container, safeInsets, lanes, metrics) else emptyList()
        val mainSegments = mutableListOf<PadSegment>()
        val functionSegments = mutableListOf<PadSegment>()
        for (edge in usedEdges) {
            val range = alongRange(edge, container, safeInsets, reservesStrips, lanes, metrics, keyboardTop)
            for (block in packed[edge] ?: emptyList()) {
                val cross = laneCenter(edge, block.lane, container, safeInsets, reservesStrips, metrics, keyboardTop)
                val cells = (0 until block.count).map { index ->
                    val along = range.start + block.start +
                        index.toDouble() * ((if (edge.stacksVertically) metrics.cell.height else metrics.cell.width) + metrics.gap)
                    if (edge.stacksVertically) {
                        CGRect(cross - metrics.cell.width / 2, along, metrics.cell.width, metrics.cell.height)
                    } else {
                        CGRect(along, cross - metrics.cell.height / 2, metrics.cell.width, metrics.cell.height)
                    }
                }
                val segment = PadSegment(block.group, cells)
                if (block.isMain) mainSegments.add(segment) else functionSegments.add(segment)
            }
        }
        // Item order: by group, then by the order the runs were placed.
        val orderedMain = mainSegments.withIndex().sortedWith(compareBy({ it.value.group }, { it.index })).map { it.value }
        val orderedFunction = functionSegments.withIndex().sortedWith(compareBy({ it.value.group }, { it.index })).map { it.value }
        return PadEdgeLayout(canvasRect(container, strips), strips, orderedMain, orderedFunction, lanes)
    }

    /** Where a palette opens: beyond everything on the Main edge. */
    fun paletteAnchor(layout: PadEdgeLayout, mainEdge: ControlEdge, functionEdge: ControlEdge): CGRect? {
        val frames = layout.mainSegments.map { it.frame } +
            (if (functionEdge == mainEdge) layout.functionSegments.map { it.frame } else emptyList())
        return if (frames.isEmpty()) null else frames.drop(1).fold(frames[0]) { a, b -> a.union(b) }
    }

    // region Packing

    private class PlacedBlock(
        val isMain: Boolean,
        val group: Int,
        val count: Int,
        val lane: Int,
        /** Along-edge offset from the start of the rail. */
        val start: CGFloat,
    )

    private class Run(val isMain: Boolean, val group: Int, val count: Int)

    /**
     * Packs Main and Function runs into lanes along a rail [length] long.
     *
     * Lane 0 reads, from the rail's start: start-aligned Main groups, the first
     * half of the Function groups, the centered Main groups, the other Function
     * half, and the end-aligned Main groups (e.g. Settings last). What doesn't
     * fit moves inward, Function first.
     */
    private fun pack(
        length: CGFloat, edge: ControlEdge, metrics: PadControlMetrics,
        main: List<Int>, alignments: List<PadGroupAlignment>, function: List<Int>,
    ): List<PlacedBlock> {
        if (!(length > 0)) return emptyList()
        val along = if (edge.stacksVertically) metrics.cell.height else metrics.cell.width
        val perLane = max(1, ((length + metrics.gap) / (along + metrics.gap)).toInt())
        val gap = metrics.groupGap
        fun runLength(run: Run): CGFloat = metrics.clusterLength(run.count, edge)
        fun span(runs: List<Run>): CGFloat =
            if (runs.isEmpty()) 0.0 else runs.map(::runLength).fold(0.0) { a, b -> a + b } + (runs.size - 1).toDouble() * gap
        fun chunks(counts: List<Int>, isMain: Boolean, groupOffset: Int = 0): List<Run> =
            counts.withIndex().flatMap { (index, count) ->
                (0 until count step perLane).map { Run(isMain, groupOffset + index, min(perLane, count - it)) }
            }
        // Greedy lanes, in order, never splitting a run.
        fun lanesOf(runs: List<Run>): List<List<Run>> {
            val lanes = mutableListOf<List<Run>>()
            for (run in runs) {
                val last = lanes.lastOrNull()
                if (last != null && span(last) + gap + runLength(run) <= length + 0.001) {
                    lanes[lanes.size - 1] = last + run
                } else {
                    lanes.add(listOf(run))
                }
            }
            return lanes
        }
        fun placed(runs: List<Run>, lane: Int, from: CGFloat): List<PlacedBlock> {
            var cursor = from
            return runs.map { run ->
                val block = PlacedBlock(run.isMain, run.group, run.count, lane, cursor)
                cursor += runLength(run) + gap
                block
            }
        }
        fun joined(parts: List<List<Run>>): List<Run> = parts.flatten()
        // Places head at the start, tail at the end, and middle centered between them; false if they don't fit.
        fun fits(head: List<Run>, middle: List<Run>, tail: List<Run>): Boolean {
            val pieces = listOf(head, middle, tail).filter { it.isNotEmpty() }
            return pieces.map(::span).fold(0.0) { a, b -> a + b } + max(0, pieces.size - 1).toDouble() * gap <= length + 0.001
        }
        fun place(head: List<Run>, middle: List<Run>, tail: List<Run>, lane: Int): List<PlacedBlock> {
            val headSpan = span(head)
            val tailSpan = span(tail)
            val middleSpan = span(middle)
            val lower = if (head.isEmpty()) 0.0 else headSpan + gap
            val upper = length - middleSpan - (if (tail.isEmpty()) 0.0 else tailSpan + gap)
            val centered = (length - middleSpan) / 2
            return placed(head, lane, 0.0) +
                placed(middle, lane, min(max(centered, lower), max(lower, upper))) +
                placed(tail, lane, length - tailSpan)
        }

        val mainRuns = chunks(main, isMain = true)
        fun alignment(run: Run): PadGroupAlignment = if (run.group < alignments.size) alignments[run.group] else PadGroupAlignment.Center
        val mainStart = mainRuns.filter { alignment(it) == PadGroupAlignment.Start }
        val mainCenter = mainRuns.filter { alignment(it) == PadGroupAlignment.Center }
        val mainEnd = mainRuns.filter { alignment(it) == PadGroupAlignment.End }
        val startCount = (function.size + 1) / 2
        val startRuns = chunks(function.take(startCount), isMain = false)
        val endRuns = chunks(function.drop(startCount), isMain = false, groupOffset = startCount)

        if (fits(mainStart + startRuns, mainCenter, endRuns + mainEnd)) {
            return place(mainStart + startRuns, mainCenter, endRuns + mainEnd, lane = 0)
        }
        var result = listOf<PlacedBlock>()
        var nextLane = 0
        if (mainRuns.isNotEmpty()) {
            if (fits(mainStart, mainCenter, mainEnd)) {
                result = place(mainStart, mainCenter, mainEnd, lane = 0)
                nextLane = 1
            } else if (mainCenter.isNotEmpty() && fits(mainStart, emptyList(), mainEnd)) {
                // Anchored groups keep the outer lane's ends (system actions
                // first, Settings last); the centered groups move inward.
                result = place(mainStart, emptyList(), mainEnd, lane = 0)
                val lanes = lanesOf(mainCenter)
                for ((offset, runs) in lanes.withIndex()) {
                    result = result + placed(runs, 1 + offset, (length - span(runs)) / 2)
                }
                nextLane = 1 + lanes.size
            } else {
                val lanes = lanesOf(joined(listOf(mainStart, mainCenter, mainEnd)))
                for ((lane, runs) in lanes.withIndex()) {
                    result = result + placed(runs, lane, (length - span(runs)) / 2)
                }
                nextLane = lanes.size
            }
        }
        if (function.isNotEmpty()) {
            // Lanes of their own: ends first, then plain wrapping.
            if (fits(startRuns, emptyList(), endRuns)) {
                result = result + place(startRuns, emptyList(), endRuns, nextLane)
            } else {
                for ((offset, runs) in lanesOf(startRuns + endRuns).withIndex()) {
                    result = result + placed(runs, nextLane + offset, 0.0)
                }
            }
        }
        return result
    }

    // endregion

    // region Rails and lanes

    private fun laneThickness(edge: ControlEdge, lanes: Int, metrics: PadControlMetrics): CGFloat {
        val one = metrics.clusterThickness(edge)
        return lanes.toDouble() * one + max(0, lanes - 1).toDouble() * metrics.gap
    }

    /** The along-edge range controls may occupy on [edge]. */
    private fun alongRange(
        edge: ControlEdge, container: CGRect, safeInsets: ControlSafeInsets, reservesStrips: Boolean,
        lanes: Map<ControlEdge, Int>, metrics: PadControlMetrics, keyboardTop: CGFloat?,
    ): ClosedFloatingPointRange<CGFloat> {
        val margin = PadControlMetrics.edgeMargin
        fun band(other: ControlEdge): CGFloat {
            val count = lanes[other] ?: return 0.0
            return if (reservesStrips) {
                laneThickness(other, count, metrics) + PadControlMetrics.stripPadding * 2 + inset(safeInsets, other)
            } else {
                laneThickness(other, count, metrics) + metrics.gap
            }
        }
        var lower: CGFloat
        var upper: CGFloat
        if (edge.stacksVertically) {
            lower = container.minY + safeInsets.top + margin
            upper = container.maxY - safeInsets.bottom - margin
            if (!reservesStrips) {
                // Clear the corners any top/bottom lanes occupy.
                lower += band(ControlEdge.Top)
                upper -= band(ControlEdge.Bottom)
            }
            if (keyboardTop != null && keyboardTop.isFinite()) upper = min(upper, keyboardTop - margin)
        } else {
            lower = container.minX + safeInsets.leading + margin
            upper = container.maxX - safeInsets.trailing - margin
            if (reservesStrips) {
                // Top/bottom strips run between the side strips.
                if (lanes[ControlEdge.Leading] != null) lower = max(lower, container.minX + band(ControlEdge.Leading) + margin)
                if (lanes[ControlEdge.Trailing] != null) upper = min(upper, container.maxX - band(ControlEdge.Trailing) - margin)
            } else {
                lower += band(ControlEdge.Leading)
                upper -= band(ControlEdge.Trailing)
            }
        }
        return lower..max(lower, upper)
    }

    /** Cross-edge center of [lane] (0 = outermost). */
    private fun laneCenter(
        edge: ControlEdge, lane: Int, container: CGRect, safeInsets: ControlSafeInsets,
        reservesStrips: Boolean, metrics: PadControlMetrics, keyboardTop: CGFloat?,
    ): CGFloat {
        val one = metrics.clusterThickness(edge)
        val offset = (if (reservesStrips) PadControlMetrics.stripPadding else PadControlMetrics.edgeMargin) +
            lane.toDouble() * (one + metrics.gap) + one / 2
        return when (edge) {
            ControlEdge.Leading -> container.minX + safeInsets.leading + offset
            ControlEdge.Trailing -> container.maxX - safeInsets.trailing - offset
            ControlEdge.Top -> container.minY + safeInsets.top + offset
            ControlEdge.Bottom -> {
                var outer = container.maxY - safeInsets.bottom
                if (keyboardTop != null && keyboardTop.isFinite()) outer = min(outer, keyboardTop)
                outer - offset
            }
        }
    }

    /**
     * Strip rails for the used edges. Left/right rails run the full height;
     * top/bottom rails run between them. Each includes its edge's safe inset
     * and is as thick as its lanes need.
     */
    fun stripFrames(container: CGRect, safeInsets: ControlSafeInsets, lanes: Map<ControlEdge, Int>, metrics: PadControlMetrics): List<PadStrip> {
        fun thickness(edge: ControlEdge): CGFloat =
            laneThickness(edge, lanes[edge] ?: 1, metrics) + PadControlMetrics.stripPadding * 2 + inset(safeInsets, edge)
        val leading = if (lanes[ControlEdge.Leading] != null) thickness(ControlEdge.Leading) else 0.0
        val trailing = if (lanes[ControlEdge.Trailing] != null) thickness(ControlEdge.Trailing) else 0.0
        return ControlEdge.entries.filter { lanes[it] != null }.map { edge ->
            val t = thickness(edge)
            val frame = when (edge) {
                ControlEdge.Leading -> CGRect(container.minX, container.minY, t, container.height)
                ControlEdge.Trailing -> CGRect(container.maxX - t, container.minY, t, container.height)
                ControlEdge.Top -> CGRect(container.minX + leading, container.minY, max(0.0, container.width - leading - trailing), t)
                ControlEdge.Bottom -> CGRect(container.minX + leading, container.maxY - t, max(0.0, container.width - leading - trailing), t)
            }
            PadStrip(edge, frame)
        }
    }

    fun canvasRect(container: CGRect, strips: List<PadStrip>): CGRect {
        var canvas = container
        for (strip in strips) {
            canvas = when (strip.edge) {
                ControlEdge.Leading ->
                    CGRect(strip.frame.maxX, canvas.minY, max(0.0, canvas.maxX - strip.frame.maxX), canvas.height)
                ControlEdge.Trailing ->
                    CGRect(canvas.minX, canvas.minY, max(0.0, strip.frame.minX - canvas.minX), canvas.height)
                ControlEdge.Top ->
                    CGRect(canvas.minX, strip.frame.maxY, canvas.width, max(0.0, canvas.maxY - strip.frame.maxY))
                ControlEdge.Bottom ->
                    CGRect(canvas.minX, canvas.minY, canvas.width, max(0.0, strip.frame.minY - canvas.minY))
            }
        }
        return canvas
    }

    /**
     * Where a palette opens beside the Main cluster: toward the canvas,
     * centered on [anchor] along the edge, and kept inside [bounds].
     */
    fun paletteFrame(size: CGSize, anchor: CGRect, edge: ControlEdge, bounds: CGRect, gap: CGFloat): CGRect {
        val frame = when (edge) {
            ControlEdge.Leading -> CGRect(anchor.maxX + gap, anchor.midY - size.height / 2, size.width, size.height)
            ControlEdge.Trailing -> CGRect(anchor.minX - gap - size.width, anchor.midY - size.height / 2, size.width, size.height)
            ControlEdge.Top -> CGRect(anchor.midX - size.width / 2, anchor.maxY + gap, size.width, size.height)
            ControlEdge.Bottom -> CGRect(anchor.midX - size.width / 2, anchor.minY - gap - size.height, size.width, size.height)
        }
        return clamped(frame, bounds)
    }

    /** Result of [paletteGrid]. */
    data class PaletteGrid(val rows: Int, val columns: Int, val size: CGSize)

    /**
     * Rows and columns for [count] palette keys laid along [edge], wrapping
     * into more lines once one line would leave [available].
     */
    fun paletteGrid(count: Int, key: CGSize, gap: CGFloat, edge: ControlEdge, available: CGSize): PaletteGrid {
        val n = max(count, 1)
        val perLine = if (edge.stacksVertically) {
            max(1, ((available.height + gap) / (key.height + gap)).toInt())
        } else {
            max(1, ((available.width + gap) / (key.width + gap)).toInt())
        }
        val lines = ceil(n.toDouble() / perLine.toDouble()).toInt()
        val inLine = min(n, perLine)
        val rows = if (edge.stacksVertically) inLine else lines
        val columns = if (edge.stacksVertically) lines else inLine
        val size = CGSize(
            width = columns.toDouble() * key.width + (columns - 1).toDouble() * gap,
            height = rows.toDouble() * key.height + (rows - 1).toDouble() * gap,
        )
        return PaletteGrid(rows, columns, size)
    }

    /** Each control's cell inside a cluster frame, in order along [edge]. */
    fun cellFrames(cluster: CGRect, count: Int, edge: ControlEdge, metrics: PadControlMetrics): List<CGRect> {
        if (count <= 0) return emptyList()
        val cell = metrics.cell
        return (0 until count).map { index ->
            val offset = index.toDouble() * ((if (edge.stacksVertically) cell.height else cell.width) + metrics.gap)
            if (edge.stacksVertically) {
                CGRect(cluster.midX - cell.width / 2, cluster.minY + offset, cell.width, cell.height)
            } else {
                CGRect(cluster.minX + offset, cluster.midY - cell.height / 2, cell.width, cell.height)
            }
        }
    }

    /** The span of a segment's control circles (captions excluded). */
    fun circleRun(segment: PadSegment, metrics: PadControlMetrics): CGRect =
        segment.cells.map { circleFrame(it, metrics) }.fold(CGRect.NULL) { a, b -> a.union(b) }

    /** The control circle within a cell (its caption, if any, sits below). */
    fun circleFrame(cell: CGRect, metrics: PadControlMetrics): CGRect =
        CGRect(cell.midX - metrics.item / 2, cell.minY, metrics.item, metrics.item)

    // endregion

    private fun inset(insets: ControlSafeInsets, edge: ControlEdge): CGFloat = when (edge) {
        ControlEdge.Leading -> insets.leading
        ControlEdge.Trailing -> insets.trailing
        ControlEdge.Top -> insets.top
        ControlEdge.Bottom -> insets.bottom
    }

    /** Shifts [frame] inside [bounds] (centering it on any axis where it is larger), never resizing it. */
    fun clamped(frame: CGRect, bounds: CGRect): CGRect {
        fun axis(origin: CGFloat, length: CGFloat, lower: CGFloat, upper: CGFloat): CGFloat {
            if (length >= upper - lower) return lower + (upper - lower - length) / 2
            return min(max(origin, lower), upper - length)
        }
        return CGRect(
            axis(frame.minX, frame.width, bounds.minX, bounds.maxX),
            axis(frame.minY, frame.height, bounds.minY, bounds.maxY),
            frame.width, frame.height,
        )
    }
}

/**
 * Auto-hide never applies to the iPad Strip: its rail is reserved space, and
 * fading the controls would leave an empty black band.
 */
object ControlAutoHidePolicy {
    fun applies(isPad: Boolean, layout: PadControlLayoutMode): Boolean = !(isPad && layout == PadControlLayoutMode.Strip)
}

// region Standard rail controls

/**
 * The standard system and utility controls the iPad Strip/Overlay rail can
 * show, each independently. Modifiers come from the Control Profile, and
 * Settings is permanent, so neither is listed here.
 */
enum class PadStandardControl(val raw: String, val title: String) {
    MenuBar("menuBar", "Menu Bar"),
    Dock("dock", "Dock"),
    ShowDesktop("showDesktop", "Show Desktop"),
    ControlCenter("controlCenter", "Control Center"),
    Escape("escape", "Escape"),
    Tab("tab", "Tab"),
    Keyboard("keyboard", "Keyboard"),
    MoveView("moveView", "Move View");

    val id: String get() = raw

    /**
     * The existing control this entry shows. Dock, Escape, Tab and Keyboard
     * are Main tray items; Show Desktop and Control Center are the Function
     * Tray's semantic `ReceiverGesture` actions: one action system.
     */
    val kind: CustomControlKind
        get() = when (this) {
            MenuBar -> CustomControlKind.Function("menu-bar")
            Dock -> CustomControlKind.Tray(ControlTrayItem.Dock)
            ShowDesktop -> CustomControlKind.Function("show-desktop")
            ControlCenter -> CustomControlKind.Function("control-center")
            Escape -> CustomControlKind.Tray(ControlTrayItem.Escape)
            Tab -> CustomControlKind.Tray(ControlTrayItem.Tab)
            Keyboard -> CustomControlKind.Tray(ControlTrayItem.Keyboard)
            MoveView -> CustomControlKind.MoveView
        }

    companion object {
        val systemKinds: Set<CustomControlKind> by lazy { setOf(MenuBar.kind, Dock.kind, ShowDesktop.kind, ControlCenter.kind) }

        fun of(raw: String?): PadStandardControl? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * Which standard controls show. Stores the *hidden* set, so a control added by
 * a later build appears by default, and decodes lossily. Encodes as a plain
 * array of raw values in declaration order.
 */
data class PadStandardControlVisibility(var hidden: Set<PadStandardControl> = emptySet()) {
    fun isVisible(control: PadStandardControl): Boolean = control !in hidden

    fun setVisible(visible: Boolean, control: PadStandardControl) {
        hidden = if (visible) hidden - control else hidden + control
    }

    fun toJson(): JsonElement = jsonArrayOf(PadStandardControl.entries.filter { it in hidden }.map { jsonOf(it.raw) })

    companion object {
        fun fromJson(e: JsonElement?): PadStandardControlVisibility? =
            e.listOf { it.str() }?.let { raw -> PadStandardControlVisibility(raw.mapNotNull(PadStandardControl::of).toSet()) }
    }
}

/** Where a Main group sits along its rail. */
enum class PadGroupAlignment {
    /** At the rail's start (the top of a side rail). */
    Start,
    Center,

    /** At the rail's end (the bottom of a side rail). */
    End,
}

/**
 * The Strip/Overlay Main rail, as visually separate groups in a fixed,
 * Sidecar-like order: system actions at the rail's start (top-right by
 * default), modifiers and keys centered, and view controls with the permanent
 * Settings gear at the rail's end (bottom-right by default). Empty groups
 * vanish; Settings keeps the last group from ever being empty.
 */
object PadRailComposition {
    /** Alignment for each of [mainGroups]' groups, in the same order. */
    fun alignments(groups: List<List<CustomControlKind>>): List<PadGroupAlignment> = groups.map { group ->
        when {
            CustomControlKind.Tray(ControlTrayItem.Settings) in group -> PadGroupAlignment.End
            group.any { it in PadStandardControl.systemKinds } -> PadGroupAlignment.Start
            else -> PadGroupAlignment.Center
        }
    }

    data class Availability(
        /** Visible modifiers from the active Control Profile (the Mac must also understand receiver controls). */
        var modifiers: List<ControlModifier>,
        var keyboardAvailable: Boolean,
        /** Move View needs live video and Local View Navigation. */
        var moveViewAvailable: Boolean,
    )

    fun mainGroups(visibility: PadStandardControlVisibility, availability: Availability): List<List<CustomControlKind>> {
        fun shown(control: PadStandardControl): Boolean {
            if (!visibility.isVisible(control)) return false
            return when (control) {
                PadStandardControl.Keyboard -> availability.keyboardAvailable
                PadStandardControl.MoveView -> availability.moveViewAvailable
                else -> true
            }
        }
        val system = listOf(PadStandardControl.MenuBar, PadStandardControl.Dock, PadStandardControl.ShowDesktop, PadStandardControl.ControlCenter)
            .filter(::shown).map { it.kind }
        val keys = availability.modifiers.map { CustomControlKind.Tray(ControlTrayItem.item(it)) } +
            listOf(PadStandardControl.Escape, PadStandardControl.Tab, PadStandardControl.Keyboard).filter(::shown).map { it.kind }
        val view = listOf(PadStandardControl.MoveView).filter(::shown).map { it.kind } + CustomControlKind.Tray(ControlTrayItem.Settings)
        return listOf(system, keys, view).filter { it.isNotEmpty() }
    }
}

fun ControlTrayItem.Companion.item(modifier: ControlModifier): ControlTrayItem = when (modifier) {
    ControlModifier.Command -> ControlTrayItem.Command
    ControlModifier.Option -> ControlTrayItem.Option
    ControlModifier.Control -> ControlTrayItem.Control
    ControlModifier.Shift -> ControlTrayItem.Shift
}

// endregion
