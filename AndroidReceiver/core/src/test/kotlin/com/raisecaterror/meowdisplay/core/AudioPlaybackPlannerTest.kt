package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.wire.AudioPlaybackPlanner
import com.raisecaterror.meowdisplay.core.wire.AudioPlaybackPlanner.Decision
import org.junit.Assert.assertEquals
import org.junit.Test

/** iOS PCMPlaybackEngine's continuous scheduling: anchor once, then chain; re-anchor only on real discontinuities. */
class AudioPlaybackPlannerTest {
    private var offset = 0
    private val planner = AudioPlaybackPlanner { offset }
    private val packetMs = 1024.0 / 48.0 // 21.333 ms: AAC-LC at 48 kHz

    /** Capture times as the wire carries them: whole milliseconds (21 or 22 ms apart). */
    private fun capture(n: Int) = (1_000_000 + n * packetMs).toLong()

    @Test
    fun onlyTheFirstPacketIsPlacedAndQuantizedCaptureTimesStillChain() {
        assertEquals(Decision.Play((0.064 * 48_000).toInt(), flush = false), planner.packet(1, capture(1), packetMs, 48_000, 0))
        for (n in 2..200) {
            assertEquals("packet $n", Decision.Play(0, flush = false), planner.packet(n.toLong(), capture(n), packetMs, 48_000, 3))
        }
    }

    @Test
    fun aRealGapReanchorsWithAFlushAndANewGeneration() {
        planner.packet(1, capture(1), packetMs, 48_000, 0)
        planner.packet(2, capture(2), packetMs, 48_000, 1)
        val generation = planner.generation
        assertEquals(Decision.Play(3072, flush = true), planner.packet(3, capture(2) + 400, packetMs, 48_000, 1))
        assertEquals(generation + 1, planner.generation)
        assertEquals(Decision.Play(0, flush = false), planner.packet(4, capture(2) + 400 + 21, packetMs, 48_000, 1))
    }

    @Test
    fun staleAndOverflowingPacketsAreDropped() {
        planner.packet(5, capture(5), packetMs, 48_000, 0)
        assertEquals(Decision.Drop(AudioPlaybackPlanner.Reason.Stale), planner.packet(5, capture(5), packetMs, 48_000, 0))
        assertEquals(Decision.Drop(AudioPlaybackPlanner.Reason.Stale), planner.packet(4, capture(4), packetMs, 48_000, 0))
        assertEquals(Decision.Drop(AudioPlaybackPlanner.Reason.Overflow), planner.packet(6, capture(6), packetMs, 48_000, 24))
        assertEquals(Decision.Play(0, flush = false), planner.packet(7, capture(7), packetMs, 48_000, 23))
    }

    @Test
    fun aPositiveAvOffsetDelaysTheAnchorAndAChangeReanchors() {
        offset = 200
        assertEquals(Decision.Play(((0.064 + 0.2) * 48_000).toInt(), flush = false), planner.packet(1, capture(1), packetMs, 48_000, 0))
        offset = -300 // Negative offsets delay video instead: audio keeps only the preroll.
        assertEquals(Decision.Play((0.064 * 48_000).toInt(), flush = true), planner.packet(2, capture(2), packetMs, 48_000, 1))
        offset = 5_000 // Clamped to +1000 ms.
        assertEquals(Decision.Play(((0.064 + 1.0) * 48_000).toInt(), flush = true), planner.packet(3, capture(3), packetMs, 48_000, 1))
    }

    @Test
    fun resetStartsAFreshSessionWithoutAFlush() {
        planner.packet(9, capture(9), packetMs, 44_100, 0)
        planner.reset()
        assertEquals(Decision.Play((0.064 * 44_100).toInt(), flush = false), planner.packet(1, capture(1), packetMs, 44_100, 0))
    }
}
