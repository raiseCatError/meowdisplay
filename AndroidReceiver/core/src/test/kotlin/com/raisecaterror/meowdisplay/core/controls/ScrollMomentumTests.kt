package com.raisecaterror.meowdisplay.core.controls

import org.junit.Assert.*
import org.junit.Test
import kotlin.math.hypot

class ScrollMomentumTests {



    // MARK: - Release-velocity estimation

    @Test
    fun testSlowScrollReleaseProducesNoMomentum() {
        var tracker = ScrollVelocityTracker()
        // A slow drag: ~5pt every 20ms -> 250pt/s, but spread thin — still
        // well under minReleaseVelocity once averaged over the window.
        var t: Double = 0.0
        for (unused in 0 until 5) {
            tracker.record(dx = 1.0, dy = 0.0, time = t)
            t += 0.02
        }
        val velocity = tracker.releaseVelocity(releaseTime = t)
        assertNull(velocity)
    }


    @Test
    fun testFastScrollReleaseStartsMomentum() {
        var tracker = ScrollVelocityTracker()
        var t: Double = 0.0
        for (unused in 0 until 6) {
            tracker.record(dx = 40.0, dy = 0.0, time = t)   // 40pt every ~16.7ms ≈ 2400pt/s
            t += 1.0 / 60
        }
        val velocity = tracker.releaseVelocity(releaseTime = t)
        assertNotNull(velocity)
        assertTrue(velocity!!.dx > ScrollMomentumConfig.minReleaseVelocity)

        val session = ScrollMomentumSession.create(initialVelocity = velocity!!, time = t)
        assertNotNull(session)
    }


    @Test
    fun testGreaterReleaseVelocityProducesGreaterInitialMomentum() {
        var slow = ScrollVelocityTracker()
        var fast = ScrollVelocityTracker()
        var t: Double = 0.0
        for (unused in 0 until 6) {
            slow.record(dx = 10.0, dy = 0.0, time = t)
            fast.record(dx = 40.0, dy = 0.0, time = t)
            t += 1.0 / 60
        }
        val slowVelocity = slow.releaseVelocity(releaseTime = t)
        val fastVelocity = fast.releaseVelocity(releaseTime = t)
        assertNotNull(slowVelocity)
        assertNotNull(fastVelocity)
        assertTrue(fastVelocity!!.dx > slowVelocity!!.dx)

        val slowSession = ScrollMomentumSession.create(initialVelocity = slowVelocity!!, time = t)!!
        val fastSession = ScrollMomentumSession.create(initialVelocity = fastVelocity!!, time = t)!!
        val slowFirstTick = slowSession.tick(now = t + 1.0 / 60)
        val fastFirstTick = fastSession.tick(now = t + 1.0 / 60)
        assertTrue(fastFirstTick.delta.dx > slowFirstTick.delta.dx)
    }


    @Test
    fun testReleaseVelocityUsesRecentWindowNotJustLastFrame() {
        var tracker = ScrollVelocityTracker()
        // A fast swipe, then the finger nearly stops right before lifting
        // (a single noisy/coalesced low-delta sample at release).
        var t: Double = 0.0
        for (unused in 0 until 8) {
            tracker.record(dx = 40.0, dy = 0.0, time = t)
            t += 1.0 / 60
        }
        tracker.record(dx = 0.1, dy = 0.0, time = t)
        val velocity = tracker.releaseVelocity(releaseTime = t)
        // Still reads as a fast release — one trailing near-zero sample
        // doesn't dominate the estimate.
        assertNotNull(velocity)
        assertTrue(velocity!!.dx > 1000)
    }


    @Test
    fun testReleaseVelocityIsCappedAtMaximum() {
        var tracker = ScrollVelocityTracker()
        var t: Double = 0.0
        for (unused in 0 until 6) {
            tracker.record(dx = 400.0, dy = 0.0, time = t)   // absurdly fast
            t += 1.0 / 60
        }
        val velocity = tracker.releaseVelocity(releaseTime = t)
        assertNotNull(velocity)
        assertTrue(hypot(velocity!!.dx, velocity!!.dy) <= ScrollMomentumConfig.maxReleaseVelocity + 0.01)
    }


    // MARK: - Decay physics

    @Test
    fun testMomentumDecaysMonotonically() {
        val session = ScrollMomentumSession.create(initialVelocity = CGVector(2000.0, 0.0), time = 0.0)!!
        var lastMagnitude = Double.MAX_VALUE
        var t: Double = 0.0
        for (unused in 0 until 20) {
            t += 1.0 / 60
            session.tick(now = t)
            val magnitude = hypot(session.velocity.dx, session.velocity.dy)
            assertTrue(magnitude < lastMagnitude)
            lastMagnitude = magnitude
        }
    }


    @Test
    fun testMomentumEventuallyTerminates() {
        val session = ScrollMomentumSession.create(initialVelocity = CGVector(1000.0, 0.0), time = 0.0)!!
        var t: Double = 0.0
        var alive = true
        var ticks = 0
        while (alive && ticks < 10_000) {
            t += 1.0 / 60
            alive = session.tick(now = t).alive
            ticks += 1
        }
        assertFalse(alive)
        assertTrue(t < 5.0)   // terminates well within a few seconds
    }


    @Test
    fun testVariableFrameIntervalsProduceComparableTotalDisplacement() {
        // 60Hz ticking vs. one big jump covering the same wall-clock span
        // should land at nearly the same total displacement and end
        // velocity — the model integrates continuously, not per-frame.
        val steady = ScrollMomentumSession.create(initialVelocity = CGVector(1200.0, 0.0), time = 0.0)!!
        var steadyTotal: Double = 0.0
        var t: Double = 0.0
        for (unused in 0 until 18) {   // 0.3s at 60Hz
            t += 1.0 / 60
            steadyTotal += steady.tick(now = t).delta.dx
        }

        val jumpy = ScrollMomentumSession.create(initialVelocity = CGVector(1200.0, 0.0), time = 0.0)!!
        val jumpyTick = jumpy.tick(now = 0.3)   // one single 0.3s jump

        assertEquals(jumpyTick.delta.dx, steadyTotal, steadyTotal * 0.01)
        assertEquals(hypot(jumpy.velocity.dx, jumpy.velocity.dy), hypot(steady.velocity.dx, steady.velocity.dy), 1.0)
    }


    @Test
    fun testZeroOrNegativeElapsedTimeProducesNoDeltaAndNoCrash() {
        val session = ScrollMomentumSession.create(initialVelocity = CGVector(500.0, 0.0), time = 1.0)!!
        val same = session.tick(now = 1.0)
        assertEquals(CGVector.zero, same.delta)
        assertTrue(same.alive)
        val backwards = session.tick(now = 0.5)
        assertEquals(CGVector.zero, backwards.delta)
    }


    @Test
    fun testMomentumSessionRefusesToStartBelowMinimumVelocity() {
        val session = ScrollMomentumSession.create(initialVelocity = CGVector(5.0, 0.0), time = 0.0)
        assertNull(session)
    }
}
