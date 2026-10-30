package com.raisecaterror.meowdisplay.core.controls

import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/**
 * Spatial Overview: Stage Peek's optional expanded layout (port of Shared/SpatialOverview.swift).
 * Every window keeps its shape, bigger Mac windows look bigger (clamped), packed in rows without
 * overlapping in a stable order; more pages when they can't all be at least [MINIMUM_SIDE].
 * Checked against fixtures/stage-peek/spatial.json.
 */
object SpatialOverviewLayout {
    data class Item(val width: Double, val height: Double)
    data class Placement(val page: Int, val rect: CGRect)
    private class Box(val w: Double, val h: Double)

    const val MINIMUM_SIDE = 72.0
    const val SPACING = 14.0
    const val MARGIN = 16.0
    const val MINIMUM_PROMINENCE = 0.6
    const val ASPECT_MIN = 0.4
    const val ASPECT_MAX = 3.0

    private fun normalized(items: List<Item>): List<Box> {
        val areas = items.map { max(it.width, 1.0) * max(it.height, 1.0) }
        val biggest = areas.maxOrNull() ?: 1.0
        return items.mapIndexed { i, item ->
            val aspect = (max(item.width, 1.0) / max(item.height, 1.0)).coerceIn(ASPECT_MIN, ASPECT_MAX)
            val p = sqrt(areas[i] / biggest).coerceIn(MINIMUM_PROMINENCE, 1.0)
            Box(p * sqrt(aspect), p / sqrt(aspect))
        }
    }

    private fun rows(boxes: List<Box>, k: Double, width: Double): List<List<Int>> {
        val rows = mutableListOf(mutableListOf<Int>())
        var x = 0.0
        boxes.forEachIndexed { i, b ->
            val w = b.w * k
            if (rows.last().isNotEmpty() && x + SPACING + w > width) { rows.add(mutableListOf()); x = 0.0 }
            x += (if (rows.last().isEmpty()) 0.0 else SPACING) + w
            rows.last().add(i)
        }
        return rows
    }

    private fun fits(boxes: List<Box>, k: Double, width: Double, height: Double): Boolean {
        if (boxes.any { it.w * k > width + 1e-9 }) return false
        val r = rows(boxes, k, width)
        val total = r.sumOf { row -> row.maxOf { boxes[it].h * k } } + SPACING * max(r.size - 1, 0)
        return total <= height + 1e-9
    }

    private fun bestScale(boxes: List<Box>, width: Double, height: Double): Double {
        var lo = 0.0
        var hi = max(width, height) * 2
        repeat(40) {
            val mid = (lo + hi) / 2
            if (fits(boxes, mid, width, height)) lo = mid else hi = mid
        }
        return lo
    }

    private fun paging(boxes: List<Box>, perPage: Int, width: Double, height: Double): Pair<List<List<Int>>, Double> {
        val pages = (boxes.indices step perPage).map { s -> (s until min(s + perPage, boxes.size)).toList() }
        val k = pages.minOf { page -> bestScale(page.map { boxes[it] }, width, height) }
        return pages to k
    }

    /** Where each window goes, in input order. */
    fun layout(items: List<Item>, sizeWidth: Double, sizeHeight: Double): List<Placement> {
        if (items.isEmpty()) return emptyList()
        val width = max(sizeWidth - 2 * MARGIN, 1.0)
        val height = max(sizeHeight - 2 * MARGIN, 1.0)
        val boxes = normalized(items)
        val smallest = boxes.minOf { min(it.w, it.h) }
        fun tappable(perPage: Int) = paging(boxes, perPage, width, height).second * smallest >= MINIMUM_SIDE - 1e-9
        var lo = 1
        var hi = items.size
        if (tappable(hi)) lo = hi else {
            while (hi - lo > 1) { val mid = (lo + hi) / 2; if (tappable(mid)) lo = mid else hi = mid }
        }
        val (pages, k) = paging(boxes, lo, width, height)
        val out = arrayOfNulls<Placement>(items.size)
        pages.forEachIndexed { page, members ->
            val pageBoxes = members.map { boxes[it] }
            val r = rows(pageBoxes, k, width)
            val heights = r.map { row -> row.maxOf { pageBoxes[it].h * k } }
            val total = heights.sum() + SPACING * max(r.size - 1, 0)
            var y = MARGIN + (height - total) / 2
            r.forEachIndexed { ri, row ->
                val rowWidth = row.sumOf { pageBoxes[it].w * k } + SPACING * max(row.size - 1, 0)
                var x = MARGIN + (width - rowWidth) / 2
                for (i in row) {
                    val w = pageBoxes[i].w * k
                    val h = pageBoxes[i].h * k
                    out[members[i]] = Placement(page, CGRect(x, y + (heights[ri] - h) / 2, w, h))
                    x += w + SPACING
                }
                y += heights[ri] + SPACING
            }
        }
        return out.map { it!! }
    }
}
