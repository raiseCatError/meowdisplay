package com.raisecaterror.meowdisplay.core.controls

// Ported from MacTests/ViewportPanFreedomTests.swift.

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * Viewport translation at 100% and beyond: any edge of the remote display may
 * reach the viewport's center but never pass it, and Move View's navigation
 * session reuses the same clamp.
 */
class ViewportPanFreedomTests {
    /** A letterboxed 16:10 picture in a 1000x800 surface: 1000x625, centered. */
    private val base = CGRect(0.0, 87.5, 1000.0, 625.0)
    private val center: CGPoint get() = CGPoint(base.midX, base.midY)

    private fun displayed(state: ManualViewportState): RemoteViewportTransform =
        RemoteViewportCalculator.applyManualZoom(
            RemoteViewportTransform(CGRect(0.0, 0.0, 1.0, 1.0), base),
            state,
        )

    @Test
    fun testPanWorksAtExactlyOneHundredPercent() {
        val state = ManualViewportState(scale = 1.0, panX = 120.0, panY = -40.0).clamped(base)
        assertEquals(1.0, state.scale, 0.0)
        assertEquals(120.0, state.panX, 0.0)
        assertEquals(-40.0, state.panY, 0.0)
        assertFalse(state.isIdentity)
        assertEquals(base.offsetBy(120.0, -40.0), displayed(state).displayedRect)
    }

    @Test
    fun testLeftEdgeReachesTheCenterButNotPast() {
        val rect = displayed(ManualViewportState(scale = 1.0, panX = 10_000.0).clamped(base)).displayedRect
        assertEquals(center.x, rect.minX, 0.001)
    }

    @Test
    fun testRightEdgeReachesTheCenterButNotPast() {
        val rect = displayed(ManualViewportState(scale = 1.0, panX = -10_000.0).clamped(base)).displayedRect
        assertEquals(center.x, rect.maxX, 0.001)
    }

    @Test
    fun testTopEdgeReachesTheCenterButNotPast() {
        val rect = displayed(ManualViewportState(scale = 1.0, panY = 10_000.0).clamped(base)).displayedRect
        assertEquals(center.y, rect.minY, 0.001)
    }

    @Test
    fun testBottomEdgeReachesTheCenterButNotPast() {
        val rect = displayed(ManualViewportState(scale = 1.0, panY = -10_000.0).clamped(base)).displayedRect
        assertEquals(center.y, rect.maxY, 0.001)
    }

    @Test
    fun testTheDisplayCanNeverLeaveTheViewport() {
        // stride(from: -5_000, through: 5_000, by: 1_250)
        val pans = (0..8).map { -5_000.0 + it * 1_250.0 }
        for (panX in pans) {
            for (panY in pans) {
                for (scale in listOf(1.0, 1.7, 3.0)) {
                    val rect = displayed(
                        ManualViewportState(scale = scale, panX = panX, panY = panY).clamped(base),
                    ).displayedRect
                    // The picture always still touches the viewport's center.
                    assertTrue(rect.minX <= center.x + 0.001)
                    assertTrue(rect.maxX >= center.x - 0.001)
                    assertTrue(rect.minY <= center.y + 0.001)
                    assertTrue(rect.maxY >= center.y - 0.001)
                }
            }
        }
    }

    @Test
    fun testHigherZoomAllowsProportionallyMoreTravel() {
        val state = ManualViewportState(scale = 2.0, panX = 10_000.0, panY = -10_000.0).clamped(base)
        val rect = displayed(state).displayedRect
        assertEquals(center.x, rect.minX, 0.001)
        assertEquals(center.y, rect.maxY, 0.001)
    }

    @Test
    fun testRotatedExtentsLimitTravelToTheCenter() {
        val quarter = ManualViewportState(scale = 1.0, panX = 10_000.0, panY = 10_000.0, rotationRadians = PI / 2)
            .clamped(base)
        val limits = quarter.panLimits(base)
        assertNotNull(limits)
        limits!!
        // A quarter turn swaps the extents.
        assertEquals(base.height / 2, limits.x, 0.001)
        assertEquals(base.width / 2, limits.y, 0.001)
        val transform = displayed(quarter)
        // The rotated picture's leftmost/topmost point sits on the center.
        val corners = listOf(CGPoint(0.0, 0.0), CGPoint(1.0, 0.0), CGPoint(0.0, 1.0), CGPoint(1.0, 1.0))
            .map { transform.viewPoint(it) }
        assertEquals(center.x, corners.map { it.x }.minOrNull() ?: 0.0, 0.01)
        assertEquals(center.y, corners.map { it.y }.minOrNull() ?: 0.0, 0.01)

        // A tilted picture's own right edge stops at the center: the center
        // stays on the picture (the rotated bounding box let it slide off).
        val tilted = ManualViewportState(scale = 1.5, panX = -10_000.0, rotationRadians = PI / 6).clamped(base)
        val onPicture = displayed(tilted).remotePoint(center) ?: return fail("expected a mapping")
        assertEquals(1.0, onPicture.x, 0.0001)
        val diagonal = ManualViewportState(scale = 3.0, panX = 10_000.0, panY = 10_000.0, rotationRadians = PI / 4)
            .clamped(base)
        val unrotated = displayed(diagonal)
        val local = CGPoint(center.x - unrotated.displayedRect.midX, center.y - unrotated.displayedRect.midY)
        val c = cos(-diagonal.rotationRadians)
        val s = sin(-diagonal.rotationRadians)
        assertTrue(abs(local.x * c - local.y * s) <= unrotated.displayedRect.width / 2 + 0.001)
        assertTrue(abs(local.x * s + local.y * c) <= unrotated.displayedRect.height / 2 + 0.001)
    }

    @Test
    fun testInvalidGeometryResetsToIdentity() {
        val state = ManualViewportState(scale = 2.0, panX = 50.0, panY = 50.0, rotationRadians = 1.0)
        assertEquals(ManualViewportState(scale = 2.0), state.clamped(CGRect.zero))
        assertNull(state.panLimits(CGRect(0.0, 0.0, 0.0, 100.0)))
        val nonFinite = ManualViewportState(scale = 1.0, panX = Double.NaN, panY = Double.POSITIVE_INFINITY).clamped(base)
        assertEquals(0.0, nonFinite.panX, 0.0)
        assertEquals(0.0, nonFinite.panY, 0.0)
    }

    @Test
    fun testResetAndRestoreIncludeAPanOnlyView() {
        val panned = ManualViewportState(scale = 1.0, panX = 200.0, panY = 0.0)
        val reset = ViewportResetRestorePolicy.toggled(panned, null, base)!!
        assertEquals(ManualViewportState.identity, reset.current)
        assertEquals(panned, reset.memory)
        val restored = ViewportResetRestorePolicy.toggled(reset.current, reset.memory, base)!!
        assertEquals(panned, restored.current)
        // Restoring into a smaller viewport re-clamps rather than overshoots.
        val small = CGRect(0.0, 0.0, 200.0, 200.0)
        val reclamped = ViewportResetRestorePolicy.toggled(ManualViewportState.identity, panned, small)!!
        assertEquals(100.0, reclamped.current.panX, 0.0)
    }

    @Test
    fun testInputMappingStaysTheInverseOfRendering() {
        val states = listOf(
            ManualViewportState(scale = 1.0, panX = 300.0, panY = -200.0),
            ManualViewportState(scale = 2.4, panX = -900.0, panY = 400.0, rotationRadians = 0.7),
            ManualViewportState(scale = 1.0, panX = 499.0, panY = 0.0, rotationRadians = PI / 2),
        )
        for (state in states) {
            val transform = displayed(state.clamped(base))
            for (remote in listOf(CGPoint(0.1, 0.2), CGPoint(0.5, 0.5), CGPoint(0.93, 0.71))) {
                val view = transform.viewPoint(remote)
                assertTrue(transform.containsViewPoint(view))
                val back = transform.remotePoint(view) ?: return fail("unmappable")
                assertEquals(remote.x, back.x, 0.0001)
                assertEquals(remote.y, back.y, 0.0001)
            }
        }
    }

    @Test
    fun testPinchCommittedPanAtOneHundredPercentTranslates() {
        val result = ManualViewportState.pinching(
            from = ManualViewportState.identity, initialBase = base,
            initialMidpoint = center,
            currentMidpoint = CGPoint(center.x + 80, center.y),
            scaleRatio = 1.0,
        )
        assertEquals(1.0, result.scale, 0.0)
        assertEquals(80.0, result.panX, 0.001)
    }

    // MARK: - Move View

    @Test
    fun testOneFingerMoveViewPans() {
        val session = ViewportNavigationSession()
        var state = ManualViewportState.identity
        state = session.update(
            points = listOf(CGPoint(100.0, 100.0)), current = state, base = base,
            allowsZoom = true, allowsRotation = false,
        )
        assertEquals("the first sample only sets the baseline", ManualViewportState.identity, state)
        state = session.update(
            points = listOf(CGPoint(160.0, 70.0)), current = state, base = base,
            allowsZoom = true, allowsRotation = false,
        )
        assertEquals(60.0, state.panX, 0.001)
        assertEquals(-30.0, state.panY, 0.001)
        assertEquals(1.0, state.scale, 0.0)
    }

    @Test
    fun testAddingAFingerReBaselinesWithoutAJump() {
        val session = ViewportNavigationSession()
        var state = ManualViewportState.identity
        state = session.update(
            points = listOf(CGPoint(100.0, 100.0)), current = state, base = base,
            allowsZoom = true, allowsRotation = false,
        )
        state = session.update(
            points = listOf(CGPoint(150.0, 100.0)), current = state, base = base,
            allowsZoom = true, allowsRotation = false,
        )
        val beforeSecondFinger = state.copy()
        state = session.update(
            points = listOf(CGPoint(150.0, 100.0), CGPoint(400.0, 400.0)), current = state,
            base = base, allowsZoom = true, allowsRotation = false,
        )
        assertEquals(beforeSecondFinger, state)
    }

    @Test
    fun testMoveViewPinchZoomsAndRotatesOnlyWhenAllowed() {
        fun pinch(allowsZoom: Boolean, allowsRotation: Boolean): ManualViewportState {
            val session = ViewportNavigationSession()
            var state = ManualViewportState.identity
            state = session.update(
                points = listOf(CGPoint(400.0, 400.0), CGPoint(600.0, 400.0)), current = state,
                base = base, allowsZoom = allowsZoom, allowsRotation = allowsRotation,
            )
            // Twice as far apart, and turned a quarter.
            return session.update(
                points = listOf(CGPoint(500.0, 200.0), CGPoint(500.0, 600.0)), current = state,
                base = base, allowsZoom = allowsZoom, allowsRotation = allowsRotation,
            )
        }
        val both = pinch(allowsZoom = true, allowsRotation = true)
        assertEquals(2.0, both.scale, 0.001)
        assertEquals(PI / 2, both.rotationRadians, 0.001)
        val zoomOnly = pinch(allowsZoom = true, allowsRotation = false)
        assertEquals(2.0, zoomOnly.scale, 0.001)
        assertEquals(0.0, zoomOnly.rotationRadians, 0.0)
        val panOnly = pinch(allowsZoom = false, allowsRotation = false)
        assertEquals(1.0, panOnly.scale, 0.0)
    }

    @Test
    fun testMoveViewStillStopsAtTheCenter() {
        val session = ViewportNavigationSession()
        var state = session.update(
            points = listOf(CGPoint(0.0, 0.0)), current = ManualViewportState.identity, base = base,
            allowsZoom = true, allowsRotation = false,
        )
        state = session.update(
            points = listOf(CGPoint(5_000.0, 0.0)), current = state, base = base,
            allowsZoom = true, allowsRotation = false,
        )
        assertEquals(center.x, displayed(state).displayedRect.minX, 0.001)
    }
}
