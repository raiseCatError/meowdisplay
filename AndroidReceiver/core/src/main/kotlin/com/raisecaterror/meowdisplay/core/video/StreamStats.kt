package com.raisecaterror.meowdisplay.core.video

/**
 * Numbers for the performance overlay, over the last second: frames shown,
 * bitrate, decode time, Mac-to-screen latency (when the clocks are synced)
 * and frames the decoder had to drop. Thread-safe; times in milliseconds.
 */
class StreamStats(private val windowMs: Double = 1000.0) {
    data class Snapshot(
        val fps: Int,
        val mbps: Double,
        val decodeP50Ms: Double?,
        val latencyP50Ms: Double?,
        val latencyP95Ms: Double?,
        val dropped: Int,
    )

    private class Event(val atMs: Double, val bytes: Int = 0, val decodeMs: Double? = null, val latencyMs: Double? = null)

    private val arrived = ArrayDeque<Event>()
    private val shown = ArrayDeque<Event>()
    private val drops = ArrayDeque<Double>()

    @Synchronized fun frameArrived(bytes: Int, nowMs: Double) {
        arrived.addLast(Event(nowMs, bytes = bytes))
        trim(nowMs)
    }

    /** A frame went to the screen. [latencyMs] is null until the Mac's clock is known. */
    @Synchronized fun frameShown(decodeMs: Double, latencyMs: Double?, nowMs: Double) {
        shown.addLast(Event(nowMs, decodeMs = decodeMs.takeIf { it.isFinite() && it >= 0 },
            latencyMs = latencyMs?.takeIf { it.isFinite() && it >= 0 && it < MAX_PLAUSIBLE_LATENCY_MS }))
        trim(nowMs)
    }

    @Synchronized fun frameDropped(nowMs: Double) {
        drops.addLast(nowMs)
        trim(nowMs)
    }

    @Synchronized fun snapshot(nowMs: Double): Snapshot {
        trim(nowMs)
        val seconds = windowMs / 1000.0
        val decode = shown.mapNotNull { it.decodeMs }.sorted()
        val latency = shown.mapNotNull { it.latencyMs }.sorted()
        return Snapshot(
            fps = (shown.size / seconds).toInt(),
            mbps = arrived.sumOf { it.bytes.toLong() } * 8 / 1_000_000.0 / seconds,
            decodeP50Ms = percentile(decode, 0.5),
            latencyP50Ms = percentile(latency, 0.5),
            latencyP95Ms = percentile(latency, 0.95),
            dropped = drops.size,
        )
    }

    @Synchronized fun reset() {
        arrived.clear(); shown.clear(); drops.clear()
    }

    private fun trim(nowMs: Double) {
        val cutoff = nowMs - windowMs
        while (arrived.firstOrNull()?.let { it.atMs <= cutoff } == true) arrived.removeFirst()
        while (shown.firstOrNull()?.let { it.atMs <= cutoff } == true) shown.removeFirst()
        while (drops.firstOrNull()?.let { it <= cutoff } == true) drops.removeFirst()
        // A stalled clock or a burst can't grow these without bound.
        while (arrived.size > MAX_EVENTS) arrived.removeFirst()
        while (shown.size > MAX_EVENTS) shown.removeFirst()
        while (drops.size > MAX_EVENTS) drops.removeFirst()
    }

    companion object {
        const val MAX_EVENTS = 1000
        /** A clock jump, not a frame: such samples are left out. */
        const val MAX_PLAUSIBLE_LATENCY_MS = 10_000.0

        fun percentile(sorted: List<Double>, p: Double): Double? {
            if (sorted.isEmpty()) return null
            val i = ((sorted.size - 1) * p).let { kotlin.math.round(it).toInt() }.coerceIn(0, sorted.size - 1)
            return sorted[i]
        }
    }
}
