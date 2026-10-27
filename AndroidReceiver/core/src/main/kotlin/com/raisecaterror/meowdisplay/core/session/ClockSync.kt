package com.raisecaterror.meowdisplay.core.session

/**
 * NTP-style offset to the sender's clock over ping/pong (PROTOCOL.md 8.1):
 * samples with an RTT in [0, 2000) ms, the last 15 kept, and the offset of
 * the minimum-RTT one used. Offset = sender clock - receiver clock.
 */
class ClockSync {
    private val samples = ArrayDeque<Pair<Double, Double>>()

    var offsetMs: Double? = null
        private set
    var lastRttMs: Double? = null
        private set

    /** Records the pong for a ping sent at [t1]; false when the sample is discarded. */
    fun record(t1: Double, mt: Double, t2: Double): Boolean {
        val rtt = t2 - t1
        if (!(rtt >= 0 && rtt < MAX_RTT_MS)) return false
        samples.addLast(rtt to mt - (t1 + t2) / 2)
        if (samples.size > MAX_SAMPLES) samples.removeFirst()
        offsetMs = samples.minBy { it.first }.second
        lastRttMs = rtt
        return true
    }

    /** A sender-clock timestamp (telemetry `cap`/`snd`) on this device's clock. */
    fun toLocal(senderMs: Double): Double? = offsetMs?.let { senderMs - it }

    /** A local timestamp in the sender's clock (`touch.t`); null until an offset is known. */
    fun toSender(localMs: Double): Double? = offsetMs?.let { localMs + it }

    companion object {
        const val MAX_RTT_MS = 2000.0
        const val MAX_SAMPLES = 15
    }
}
