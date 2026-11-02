package com.raisecaterror.meowdisplay.core.session

import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Regression (Moto, 2026-10-31 00:45:33): an interrupted close killed the app. */
class MediaListenerCloseTest {
    @Test
    fun anInterruptedWaitReturnsFalseInsteadOfThrowing() {
        val busy = Executors.newSingleThreadExecutor()
        busy.execute { Thread.sleep(2_000) }
        busy.shutdown()
        Thread.currentThread().interrupt()
        assertFalse(MediaListener.awaitQuietly(busy, 1_000))
        assertTrue("the interruption is kept for the caller", Thread.interrupted())
        busy.shutdownNow()
        assertTrue(busy.awaitTermination(2, TimeUnit.SECONDS))
    }
}
