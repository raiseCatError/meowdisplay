package com.raisecaterror.meowdisplay.core.controls

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

// CoreGraphics value types with Darwin's semantics, so the control geometry
// ported from Shared/*.swift reads and behaves like the Swift it came from.
// The names stay CoreGraphics' on purpose: they say which rules apply, and
// they never collide with Compose's own Offset/Size/Rect in the app module.
//
// Measured against CoreGraphics on macOS (not corelibs-foundation, which
// differs): `intersects` treats each axis as half-open [min, max), with a
// zero-length side being the single point {min}; `intersection` of rects
// that only touch is a zero-width rect, not null; `contains(point)` is
// half-open; `contains(rect)` is closed and true for the null rect.

typealias CGFloat = Double
typealias TimeInterval = Double

data class CGPoint(val x: Double, val y: Double) {
    operator fun plus(v: CGVector) = CGPoint(x + v.dx, y + v.dy)
    operator fun minus(v: CGVector) = CGPoint(x - v.dx, y - v.dy)

    companion object {
        val zero = CGPoint(0.0, 0.0)
    }
}

data class CGSize(val width: Double, val height: Double) {
    companion object {
        val zero = CGSize(0.0, 0.0)
    }
}

data class CGVector(val dx: Double, val dy: Double) {
    companion object {
        val zero = CGVector(0.0, 0.0)
    }
}

enum class CGRectEdge { MinXEdge, MinYEdge, MaxXEdge, MaxYEdge }

/**
 * CGRect. Stored standardized (a negative width or height moves the origin),
 * so `origin` always equals (`minX`, `minY`). The null rect has an infinite
 * origin and zero size, exactly like `CGRect.null`.
 */
class CGRect private constructor(
    private val ox: Double,
    private val oy: Double,
    private val w: Double,
    private val h: Double,
) {
    val origin: CGPoint get() = CGPoint(ox, oy)
    val size: CGSize get() = CGSize(w, h)
    val width: Double get() = w
    val height: Double get() = h
    val minX: Double get() = ox
    val minY: Double get() = oy
    val maxX: Double get() = if (isNull) ox else ox + w
    val maxY: Double get() = if (isNull) oy else oy + h
    val midX: Double get() = if (isNull) ox else ox + w / 2
    val midY: Double get() = if (isNull) oy else oy + h / 2
    val isNull: Boolean get() = ox == Double.POSITIVE_INFINITY || oy == Double.POSITIVE_INFINITY
    val isEmpty: Boolean get() = isNull || w == 0.0 || h == 0.0
    val isInfinite: Boolean get() = w == Double.POSITIVE_INFINITY && h == Double.POSITIVE_INFINITY
    val standardized: CGRect get() = this

    /** Not a CoreGraphics member; the frame's center, which SwiftUI code reaches through midX/midY. */
    val center: CGPoint get() = CGPoint(midX, midY)

    fun insetBy(dx: Double, dy: Double): CGRect {
        if (isNull) return this
        val nw = w - 2 * dx
        val nh = h - 2 * dy
        if (nw < 0 || nh < 0) return NULL
        return CGRect(ox + dx, oy + dy, nw, nh)
    }

    fun offsetBy(dx: Double, dy: Double): CGRect = if (isNull) this else CGRect(ox + dx, oy + dy, w, h)

    fun intersection(other: CGRect): CGRect {
        if (isNull || other.isNull) return NULL
        val x1 = max(minX, other.minX)
        val x2 = min(maxX, other.maxX)
        val y1 = max(minY, other.minY)
        val y2 = min(maxY, other.maxY)
        if (x1 > x2 || y1 > y2) return NULL
        return CGRect(x1, y1, x2 - x1, y2 - y1)
    }

    fun intersects(other: CGRect): Boolean {
        if (isNull || other.isNull) return false
        return overlaps(minX, w, other.minX, other.w) && overlaps(minY, h, other.minY, other.h)
    }

    fun union(other: CGRect): CGRect {
        if (isNull) return other
        if (other.isNull) return this
        val x1 = min(minX, other.minX)
        val y1 = min(minY, other.minY)
        return CGRect(x1, y1, max(maxX, other.maxX) - x1, max(maxY, other.maxY) - y1)
    }

    fun contains(point: CGPoint): Boolean =
        !isNull && point.x >= minX && point.x < maxX && point.y >= minY && point.y < maxY

    fun contains(rect: CGRect): Boolean {
        if (rect.isNull) return true
        if (isNull) return false
        return rect.minX >= minX && rect.maxX <= maxX && rect.minY >= minY && rect.maxY <= maxY
    }

    /** `divided(atDistance:from:)`: (slice, remainder). */
    fun divided(atDistance: Double, from: CGRectEdge): Pair<CGRect, CGRect> {
        if (isNull) return NULL to NULL
        return when (from) {
            CGRectEdge.MinXEdge -> {
                val d = atDistance.coerceIn(0.0, w)
                CGRect(ox, oy, d, h) to CGRect(ox + d, oy, w - d, h)
            }
            CGRectEdge.MaxXEdge -> {
                val d = atDistance.coerceIn(0.0, w)
                CGRect(maxX - d, oy, d, h) to CGRect(ox, oy, w - d, h)
            }
            CGRectEdge.MinYEdge -> {
                val d = atDistance.coerceIn(0.0, h)
                CGRect(ox, oy, w, d) to CGRect(ox, oy + d, w, h - d)
            }
            CGRectEdge.MaxYEdge -> {
                val d = atDistance.coerceIn(0.0, h)
                CGRect(ox, maxY - d, w, d) to CGRect(ox, oy, w, h - d)
            }
        }
    }

    override fun equals(other: Any?): Boolean =
        other is CGRect && ox == other.ox && oy == other.oy && w == other.w && h == other.h

    override fun hashCode(): Int = arrayOf(ox, oy, w, h).contentHashCode()

    override fun toString(): String = "CGRect($ox, $oy, $w, $h)"

    /** True when every edge is within [tolerance] of [other]'s. */
    fun isApproximately(other: CGRect, tolerance: Double = 1e-9): Boolean =
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance

    companion object {
        val NULL = CGRect(Double.POSITIVE_INFINITY, Double.POSITIVE_INFINITY, 0.0, 0.0)
        val zero = CGRect(0.0, 0.0, 0.0, 0.0)

        operator fun invoke(x: Double, y: Double, width: Double, height: Double): CGRect {
            val nx = if (width < 0) x + width else x
            val ny = if (height < 0) y + height else y
            return CGRect(nx, ny, abs(width), abs(height))
        }

        operator fun invoke(x: Int, y: Int, width: Int, height: Int) =
            invoke(x.toDouble(), y.toDouble(), width.toDouble(), height.toDouble())

        operator fun invoke(origin: CGPoint, size: CGSize) = invoke(origin.x, origin.y, size.width, size.height)

        /** One axis of CoreGraphics' `intersects`: half-open spans, a zero-length span is a point. */
        private fun overlaps(min1: Double, len1: Double, min2: Double, len2: Double): Boolean {
            if (len1 > 0 && len2 > 0) return max(min1, min2) < min(min1 + len1, min2 + len2)
            if (len1 == 0.0 && len2 == 0.0) return min1 == min2
            val (point, low, high) = if (len1 == 0.0) Triple(min1, min2, min2 + len2) else Triple(min2, min1, min1 + len1)
            return point >= low && point < high
        }
    }
}

/** SwiftUI's `Angle`. */
data class Angle(val radians: Double) : Comparable<Angle> {
    val degrees: Double get() = radians * 180.0 / PI

    operator fun plus(other: Angle) = Angle(radians + other.radians)
    operator fun minus(other: Angle) = Angle(radians - other.radians)
    operator fun times(factor: Double) = Angle(radians * factor)
    operator fun div(divisor: Double) = Angle(radians / divisor)
    operator fun unaryMinus() = Angle(-radians)
    override fun compareTo(other: Angle) = radians.compareTo(other.radians)

    companion object {
        val zero = Angle(0.0)
        fun degrees(value: Double) = Angle(value * PI / 180.0)
        fun radians(value: Double) = Angle(value)
    }
}

/** Swift's `UUID().uuidString`: uppercase. */
fun newUUIDString(): String = java.util.UUID.randomUUID().toString().uppercase()
