package com.raisecaterror.meowdisplay.core.video

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StreamStatsTest {
    @Test fun `one second of 60 frames reads 60 fps and the bitrate`() {
        val s = StreamStats()
        for (i in 0 until 60) {
            val t = 1000.0 + i * 16.0
            s.frameArrived(25_000, t)
            s.frameShown(decodeMs = 4.0 + (i % 3), latencyMs = 30.0 + i % 10, nowMs = t)
        }
        val snap = s.snapshot(1000.0 + 59 * 16.0)
        assertEquals(60, snap.fps)
        assertEquals(60 * 25_000 * 8 / 1_000_000.0, snap.mbps, 1e-9)
        assertEquals(5.0, snap.decodeP50Ms!!, 1e-9)
        assertEquals(34.0, snap.latencyP50Ms!!, 1.0)
        assertEquals(0, snap.dropped)
    }

    @Test fun `old frames leave the window`() {
        val s = StreamStats()
        s.frameArrived(1000, 0.0); s.frameShown(3.0, null, 0.0); s.frameDropped(0.0)
        val snap = s.snapshot(2000.0)
        assertEquals(0, snap.fps)
        assertEquals(0.0, snap.mbps, 0.0)
        assertEquals(0, snap.dropped)
        assertNull(snap.decodeP50Ms)
    }

    @Test fun `latency is left out until the clocks are synced and when it is implausible`() {
        val s = StreamStats()
        s.frameShown(2.0, null, 10.0)
        s.frameShown(2.0, -5.0, 11.0)
        s.frameShown(2.0, 50_000.0, 12.0)
        val snap = s.snapshot(20.0)
        assertEquals(3, snap.fps)
        assertNull(snap.latencyP50Ms)
        assertNull(snap.latencyP95Ms)
    }

    @Test fun `bursts stay bounded`() {
        val s = StreamStats()
        repeat(5000) { s.frameArrived(10, 5.0) }
        assertEquals(StreamStats.MAX_EVENTS * 10 * 8 / 1_000_000.0, s.snapshot(5.0).mbps, 1e-9)
    }
}
