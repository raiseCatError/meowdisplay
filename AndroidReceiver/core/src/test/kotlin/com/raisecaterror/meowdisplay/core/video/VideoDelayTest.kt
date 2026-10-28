package com.raisecaterror.meowdisplay.core.video

import com.raisecaterror.meowdisplay.core.controls.AVSyncOffset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoDelayTest {
    @Test fun `no offset means no delay`() {
        val d = VideoDelay()
        assertEquals(100L, d.dueAt(100, AVSyncOffset.videoDelayMs(0)))
        assertEquals(100L, d.dueAt(100, AVSyncOffset.videoDelayMs(250)), "a positive offset delays audio, not video")
    }

    @Test fun `a negative offset delays the picture by that much`() {
        assertEquals(1_250L, VideoDelay().dueAt(1_000, AVSyncOffset.videoDelayMs(-250)))
    }

    @Test fun `frames keep their order when the delay shrinks`() {
        val d = VideoDelay()
        val first = d.dueAt(1_000, 400)
        val second = d.dueAt(1_016, 100)   // the user moved the slider back
        assertTrue(second >= first)
    }

    @Test fun `the delay is capped and reset forgets the past`() {
        val d = VideoDelay()
        assertEquals(1_000L + VideoDelay.MAX_DELAY_MS, d.dueAt(1_000, 60_000))
        d.reset()
        assertEquals(10L, d.dueAt(10, 0))
    }

    private fun assertEquals(expected: Long, actual: Long, message: String) = org.junit.Assert.assertEquals(message, expected, actual)
}
