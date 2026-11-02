package com.raisecaterror.meowdisplay.android.media

import com.raisecaterror.meowdisplay.core.video.StreamStats
import org.junit.Assert.assertEquals
import org.junit.Test

class PerformanceOverlayTest {
    @Test fun `the line shows what is known and skips the rest`() {
        assertEquals("0 fps · 0.0 Mbit/s", describe(StreamStats.Snapshot(0, 0.0, null, null, null, 0), null))
        assertEquals(
            "60 fps · 12.5 Mbit/s · decode 4.0 ms · latency 38 ms (p95 52) · rtt 6 ms · dropped 2",
            describe(StreamStats.Snapshot(60, 12.5, 4.0, 38.0, 52.0, 2), 6.0),
        )
    }

    @Test fun `a remote session says so first and the numbers stay exactly as measured`() {
        val remote = StreamStats.Snapshot(30, 6.5, 5.0, 112.0, 180.0, 0)
        assertEquals(
            "Remote (Tailscale) · 30 fps · 6.5 Mbit/s · decode 5.0 ms · latency 112 ms (p95 180) · rtt 48 ms",
            describe(remote, 48.0, "Remote (Tailscale)"),
        )
        assertEquals("a local session adds nothing", describe(remote, 48.0, null), describe(remote, 48.0))
    }
}
