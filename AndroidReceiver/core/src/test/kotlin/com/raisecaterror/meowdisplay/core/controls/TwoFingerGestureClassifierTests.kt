package com.raisecaterror.meowdisplay.core.controls

// Ported from MacTests/TwoFingerGestureClassifierTests.swift.

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pure-logic coverage for the two-finger gesture arbitration policy: the
 * three-way choice between remote-Mac scroll, local viewport pinch-zoom, and
 * (once a viewport session is already under way) local viewport pan.
 *
 * Product rule under test: an ordinary two-finger drag (parallel finger
 * movement with little separation change) must classify as `Scroll`,
 * regardless of current manual zoom (zoom level never enters this decision at
 * all). A clear, deliberate change in finger separation classifies as
 * `ViewportZoomPan`. Once a session commits to either, it must hold that
 * answer for the rest of the touch sequence.
 */
class TwoFingerGestureClassifierTests {

    private val origin = CGPoint(200.0, 400.0)

    // MARK: - Fresh gesture: scroll

    @Test
    fun testFreshParallelDragClassifiesAsScroll() {
        val result = TwoFingerGestureClassifier.classify(
            initialDistance = 120.0, currentDistance = 122.0, // negligible separation change
            initialMidpoint = origin, currentMidpoint = CGPoint(origin.x + 40, origin.y + 5),
        )
        assertEquals(TwoFingerGestureIntent.Scroll, result)
    }

    @Test
    fun testFreshParallelDragClassifiesAsScrollRegardlessOfCurrentZoomLevel() {
        // The classifier takes no zoom parameter at all: scroll eligibility
        // must not depend on manual zoom state.
        val result = TwoFingerGestureClassifier.classify(
            initialDistance = 300.0, currentDistance = 305.0,
            initialMidpoint = origin, currentMidpoint = CGPoint(origin.x - 30, origin.y + 20),
        )
        assertEquals("scroll must remain reachable regardless of manual zoom", TwoFingerGestureIntent.Scroll, result)
    }

    @Test
    fun testSmallSeparationJitterDuringADragRemainsScroll() {
        // A big centroid move with only a tiny (sub-threshold) spacing change.
        val result = TwoFingerGestureClassifier.classify(
            initialDistance = 100.0, currentDistance = 103.0, // 3% - under the 6% pinch threshold
            initialMidpoint = origin, currentMidpoint = CGPoint(origin.x + 50, origin.y),
        )
        assertEquals(TwoFingerGestureIntent.Scroll, result)
    }

    // MARK: - Fresh gesture: pinch

    @Test
    fun testClearSeparationIncreaseClassifiesAsViewportZoom() {
        val result = TwoFingerGestureClassifier.classify(
            initialDistance = 100.0, currentDistance = 130.0, // 30% spread
            initialMidpoint = origin, currentMidpoint = origin, // centroid barely moves
        )
        assertEquals(TwoFingerGestureIntent.ViewportZoomPan, result)
    }

    @Test
    fun testClearSeparationDecreaseClassifiesAsViewportZoom() {
        val result = TwoFingerGestureClassifier.classify(
            initialDistance = 200.0, currentDistance = 150.0, // pinching inward
            initialMidpoint = origin, currentMidpoint = origin,
        )
        assertEquals(TwoFingerGestureIntent.ViewportZoomPan, result)
    }

    // MARK: - Ambiguous samples: dominance

    @Test
    fun testUndecidedBelowBothThresholds() {
        val result = TwoFingerGestureClassifier.classify(
            initialDistance = 100.0, currentDistance = 102.0, // 2%, under threshold
            initialMidpoint = origin, currentMidpoint = CGPoint(origin.x + 3, origin.y), // under threshold
        )
        assertEquals(TwoFingerGestureIntent.Undecided, result)
    }

    @Test
    fun testScaleSignalDominatesWhenBothThresholdsAreCrossedTogether() {
        // Distance changed 20% (well past its 6% threshold) while the centroid
        // moved only barely past its own threshold: the pinch signal is
        // proportionally far stronger, so it wins.
        val result = TwoFingerGestureClassifier.classify(
            initialDistance = 100.0, currentDistance = 120.0,
            initialMidpoint = origin, currentMidpoint = CGPoint(origin.x + 11, origin.y),
        )
        assertEquals(TwoFingerGestureIntent.ViewportZoomPan, result)
    }

    @Test
    fun testScrollSignalDominatesWhenScaleChangeIsOnlyMarginallyOverThreshold() {
        // Distance changed only just past its threshold while the centroid
        // moved far past its own: a diagonal scroll drag that happens to also
        // spread the fingers slightly must still read as scroll.
        val result = TwoFingerGestureClassifier.classify(
            initialDistance = 100.0, currentDistance = 106.5, // just over 6%
            initialMidpoint = origin, currentMidpoint = CGPoint(origin.x + 60, origin.y), // 6x its threshold
        )
        assertEquals(TwoFingerGestureIntent.Scroll, result)
    }

    // MARK: - Degenerate inputs never crash or hang

    @Test
    fun testZeroInitialDistanceIsUndecidedNotNaN() {
        val result = TwoFingerGestureClassifier.classify(
            initialDistance = 0.0, currentDistance = 50.0,
            initialMidpoint = origin, currentMidpoint = origin,
        )
        assertEquals(TwoFingerGestureIntent.Undecided, result)
    }

    // MARK: - Session: commit-once / no oscillation

    @Test
    fun testSessionCommitsToScrollAndHoldsItDespiteALaterClearPinchSample() {
        val session = TwoFingerGestureSession()
        assertEquals(
            TwoFingerGestureIntent.Scroll,
            session.update(
                initialDistance = 100.0, currentDistance = 101.0,
                initialMidpoint = origin, currentMidpoint = CGPoint(origin.x + 20, origin.y),
            ),
        )
        // A later sample in the same session that looks like a strong pinch
        // must NOT flip the already-committed intent.
        val after = session.update(
            initialDistance = 100.0, currentDistance = 160.0,
            initialMidpoint = origin, currentMidpoint = origin,
        )
        assertEquals("a committed session must never oscillate back to a different intent", TwoFingerGestureIntent.Scroll, after)
        assertEquals(TwoFingerGestureIntent.Scroll, session.intent)
    }

    @Test
    fun testSessionCommitsToViewportZoomAndHoldsItAcrossPureCentroidMovement() {
        val session = TwoFingerGestureSession()
        assertEquals(
            TwoFingerGestureIntent.ViewportZoomPan,
            session.update(
                initialDistance = 100.0, currentDistance = 140.0,
                initialMidpoint = origin, currentMidpoint = origin,
            ),
        )
        // After the pinch commits, moving the midpoint (panning the zoomed
        // viewport, fingers still down) must stay the same intent: this is
        // "viewport pan after pinch", not a new decision.
        val after = session.update(
            initialDistance = 100.0, currentDistance = 140.0,
            initialMidpoint = origin, currentMidpoint = CGPoint(origin.x + 80, origin.y - 40),
        )
        assertEquals(TwoFingerGestureIntent.ViewportZoomPan, after)
        assertEquals(TwoFingerGestureIntent.ViewportZoomPan, session.intent)
    }

    @Test
    fun testSessionStaysUndecidedUntilAThresholdIsCrossed() {
        val session = TwoFingerGestureSession()
        assertEquals(
            TwoFingerGestureIntent.Undecided,
            session.update(
                initialDistance = 100.0, currentDistance = 101.0,
                initialMidpoint = origin, currentMidpoint = CGPoint(origin.x + 1, origin.y),
            ),
        )
        assertEquals(TwoFingerGestureIntent.Undecided, session.intent)
    }

    @Test
    fun testAFreshSessionAfterOneCommitsStartsUndecidedAgain() {
        // Models "lifting fingers resets ownership": a brand-new session value
        // (as `reset()` creates) carries none of a prior gesture's commitment.
        val first = TwoFingerGestureSession()
        first.update(initialDistance = 100.0, currentDistance = 140.0, initialMidpoint = origin, currentMidpoint = origin)
        assertEquals(TwoFingerGestureIntent.ViewportZoomPan, first.intent)

        val second = TwoFingerGestureSession()
        assertEquals(
            "a fresh two-finger touch-down must not inherit the previous gesture's intent",
            TwoFingerGestureIntent.Undecided, second.intent,
        )
    }
}
