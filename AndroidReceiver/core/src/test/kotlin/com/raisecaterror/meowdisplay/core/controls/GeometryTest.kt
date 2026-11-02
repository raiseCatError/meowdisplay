package com.raisecaterror.meowdisplay.core.controls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every expectation here was measured from CoreGraphics on macOS (2026-10-28). */
class GeometryTest {
    private val a = CGRect(0, 0, 10, 10)

    @Test
    fun intersectsIsHalfOpenPerAxis() {
        val cases = listOf(
            CGRect(10, 0, 10, 10) to false, // adjacent right
            CGRect(5.0, 5.0, 0.0, 0.0) to true, // point inside
            CGRect(10.0, 5.0, 0.0, 0.0) to false, // point on the right edge
            CGRect(0.0, 5.0, 0.0, 0.0) to true, // point on the left edge
            CGRect(11.0, 5.0, 0.0, 0.0) to false,
            CGRect(10.0, 0.0, 0.0, 10.0) to false, // zero width on the right edge
            CGRect(5.0, 0.0, 0.0, 10.0) to true,
            CGRect(0.0, 0.0, 0.0, 10.0) to true,
            CGRect(0, 10, 10, 5) to false, // adjacent below
            CGRect(9, 0, 10, 10) to true,
            CGRect(10, 10, 5, 5) to false, // corner touch
            CGRect.zero to true,
            CGRect(0.0, 0.0, 10.0, 0.0) to true,
            CGRect(0.0, 10.0, 10.0, 0.0) to false,
        )
        for ((rect, expected) in cases) {
            assertEquals("$rect", expected, rect.intersects(a))
            assertEquals("$rect", expected, a.intersects(rect))
        }
    }

    @Test
    fun intersectionOfTouchingRectsIsZeroSizedNotNull() {
        assertEquals(CGRect(10, 0, 0, 10), a.intersection(CGRect(10, 0, 10, 10)))
        assertFalse(a.intersection(CGRect(10, 0, 10, 10)).isNull)
        val disjoint = a.intersection(CGRect(20, 0, 10, 10))
        assertTrue(disjoint.isNull)
        assertTrue(disjoint.isEmpty)
        assertEquals(Double.POSITIVE_INFINITY, disjoint.minX, 0.0)
        assertEquals(0.0, disjoint.width, 0.0)
        assertEquals(CGRect(3.0, 3.0, 0.0, 4.0), CGRect(3.0, 3.0, 0.0, 4.0).intersection(a))
    }

    @Test
    fun containsPointIsHalfOpenContainsRectIsClosed() {
        assertFalse(a.contains(CGPoint(10.0, 5.0)))
        assertTrue(a.contains(CGPoint(0.0, 0.0)))
        assertTrue(a.contains(a))
        assertTrue(a.contains(CGRect(5.0, 5.0, 0.0, 0.0)))
        assertTrue(a.contains(CGRect(10.0, 5.0, 0.0, 0.0)))
        assertFalse(a.contains(CGRect(20.0, 20.0, 0.0, 0.0)))
        assertFalse(a.contains(CGRect(5, 5, 10, 1)))
        assertFalse(CGRect.NULL.contains(CGPoint(0.0, 0.0)))
        assertTrue(a.contains(CGRect.NULL))
    }

    @Test
    fun unionInsetOffsetAndStandardization() {
        assertEquals(a, CGRect.NULL.union(a))
        assertEquals(CGRect(0, 0, 50, 50), CGRect(50.0, 50.0, 0.0, 0.0).union(a))
        assertEquals(CGRect(1, 1, 4, 4), CGRect(1.0, 1.0, 0.0, 0.0).union(CGRect(5.0, 5.0, 0.0, 0.0)))
        assertTrue(a.insetBy(6.0, 6.0).isNull)
        assertEquals(CGRect(5.0, 5.0, 0.0, 0.0), a.insetBy(5.0, 5.0))
        assertFalse(a.insetBy(5.0, 5.0).isNull)
        assertTrue(CGRect.NULL.offsetBy(1.0, 1.0).isNull)
        assertTrue(CGRect.zero.isEmpty)
        assertFalse(CGRect.zero.isNull)
        val negative = CGRect(10.0, 10.0, -5.0, -5.0)
        assertEquals(5.0, negative.minX, 0.0)
        assertEquals(10.0, negative.maxX, 0.0)
        assertEquals(5.0, negative.width, 0.0)
    }

    @Test
    fun dividedSlicesFromTheEdge() {
        val (slice, remainder) = a.divided(atDistance = 3.0, from = CGRectEdge.MinXEdge)
        assertEquals(CGRect(0, 0, 3, 10), slice)
        assertEquals(CGRect(3, 0, 7, 10), remainder)
    }
}
