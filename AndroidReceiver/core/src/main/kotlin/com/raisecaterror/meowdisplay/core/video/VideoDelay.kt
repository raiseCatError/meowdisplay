package com.raisecaterror.meowdisplay.core.video

/**
 * When a received video frame may go to the decoder, for a negative A/V sync
 * offset (picture later than sound). Frames keep their order even while the
 * delay changes: a frame is never due before the one received before it.
 */
class VideoDelay {
    private var lastDueMs = Long.MIN_VALUE

    /** The time to hand the frame to the decoder; [nowMs] when there is no delay. */
    fun dueAt(nowMs: Long, delayMs: Int): Long {
        val due = maxOf(nowMs + delayMs.coerceIn(0, MAX_DELAY_MS), lastDueMs)
        lastDueMs = due
        return due
    }

    fun reset() {
        lastDueMs = Long.MIN_VALUE
    }

    companion object {
        const val MAX_DELAY_MS = 1_000
    }
}
