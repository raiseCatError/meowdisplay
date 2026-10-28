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
}
