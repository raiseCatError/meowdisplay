package com.raisecaterror.meowdisplay.core.wire

import com.raisecaterror.meowdisplay.core.controls.AVSyncOffset
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The iOS receiver's production audio timing (Shared/PCMPlaybackEngine.swift,
 * `PCMJitterBufferPolicy` and `PCMSchedulingMode.continuous`), without any
 * audio API: only the first buffer of a playback generation is placed (after
 * a preroll cushion plus the receiver's A/V offset); every later buffer
 * chains straight after the previous one, which is what a streaming
 * AudioTrack does by itself. Placing each packet from its millisecond-
 * quantized capture time instead produces a gap or overlap at every
 * boundary (iOS's documented "robotic noise" regression).
 *
 * A capture-timeline jump beyond [MAJOR_DISCONTINUITY_MS], or a change of
 * the A/V offset, starts a new generation (flush, re-anchor). More than
 * [MAX_PENDING_PACKETS] packets queued drops the newest arrival, bounding
 * added latency. A packet older than the last one is dropped.
 */
class AudioPlaybackPlanner(private val avSyncOffsetMs: () -> Int = { 0 }) {
    sealed interface Decision {
        /** Play it; first write [leadingSilenceFrames] of silence, after flushing what is queued when [flush]. */
        data class Play(val leadingSilenceFrames: Int, val flush: Boolean) : Decision

        data class Drop(val reason: Reason) : Decision
    }

    enum class Reason { Stale, Overflow }

    private var lastSequence: Long? = null
    private var expectedNextCaptureMs: Double? = null
    private var anchoredOffsetMs: Int? = null

    var generation = 0
        private set

    /** A new format, audio off, a pause, a new session: the next packet anchors a fresh generation. */
    fun reset() {
        lastSequence = null
        expectedNextCaptureMs = null
        anchoredOffsetMs = null
        generation++
    }

    /**
     * @param pendingPackets packets written but not yet played (queued audio ÷ one packet).
     */
    fun packet(sequence: Long, capturedAtMs: Long, durationMs: Double, sampleRate: Int, pendingPackets: Int): Decision {
        val last = lastSequence
        if (last != null && sequence <= last) return Decision.Drop(Reason.Stale)
        lastSequence = sequence
        val offset = AVSyncOffset.clamped(avSyncOffsetMs())
        val expected = expectedNextCaptureMs
        expectedNextCaptureMs = capturedAtMs + durationMs
        val anchored = anchoredOffsetMs
        val reanchor = anchored == null || anchored != offset || (expected != null && abs(capturedAtMs - expected) > MAJOR_DISCONTINUITY_MS)
        if (!reanchor && pendingPackets >= MAX_PENDING_PACKETS) return Decision.Drop(Reason.Overflow)
        if (!reanchor) return Decision.Play(0, flush = false)
        val firstOfSession = anchored == null
        anchoredOffsetMs = offset
        if (!firstOfSession) generation++
        val leadSeconds = PREROLL_SECONDS + AVSyncOffset.audioDelayMs(offset) / 1000.0
        return Decision.Play((leadSeconds * sampleRate).roundToInt(), flush = !firstOfSession)
    }

    companion object {
        /** Cushion against ordinary arrival jitter before a generation's first sample plays. */
        const val PREROLL_SECONDS = 0.064

        /** ~500 ms at ~21.33 ms per AAC-LC packet: bounds added latency, never chases it. */
        const val MAX_PENDING_PACKETS = 24

        /** A real discontinuity (loss, reorder, stall) rather than cadence or jitter. */
        const val MAJOR_DISCONTINUITY_MS = 100.0
    }
}
