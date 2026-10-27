package com.raisecaterror.meowdisplay.core.video

import com.raisecaterror.meowdisplay.core.session.StreamCodec

/**
 * What waits for the decoder (pure, so every rule is host-tested). Samples
 * are held, bounded, until the decoder has a free input buffer, instead of
 * being dropped on momentary backpressure: a dropped reference frame costs
 * the whole GOP. Nothing is held that could not decode: until a keyframe
 * arrives (first connect, after a reset, after an overflow), dependent
 * frames are refused and the caller asks the Mac for a keyframe.
 */
class DecodeQueue(private val maxSamples: Int = 60, private val maxBytes: Long = 16L shl 20) {
    sealed interface Offer {
        /** Held for the decoder. */
        data object Held : Offer
        /** Held, and the decoder must be (re)built for this format before it is fed. */
        data object HeldNeedsDecoder : Offer
        /** Undecodable without a keyframe: refused; ask the Mac for one. */
        data object NeedsKeyframe : Offer
        /** The decoder fell too far behind: everything dropped; ask for a keyframe. */
        data object Overflowed : Offer
    }

    private val pending = ArrayDeque<DecodableSample>()
    private var pendingBytes = 0L

    var codec: StreamCodec = StreamCodec.H264
        private set
    /** Codec-specific data of the current format, null until a keyframe brought it. */
    var format: List<ByteArray>? = null
        private set
    /** Largest access unit seen in this format: sizes input buffers so no unit is ever truncated. */
    var largestUnit = 0
        private set
    var awaitingKeyframe = true
        private set

    val size: Int get() = pending.size
    val isEmpty: Boolean get() = pending.isEmpty()

    fun offer(sample: DecodableSample): Offer {
        val newFormat = sample.newFormat
        if (newFormat != null) {
            // Units of the old format cannot go to the new decoder.
            clear()
            codec = sample.codec
            format = newFormat
            largestUnit = 0
            awaitingKeyframe = true
        }
        if (awaitingKeyframe && !sample.isKeyframe) return Offer.NeedsKeyframe
        if (sample.isKeyframe) {
            // A live display wants the newest picture: a keyframe supersedes any backlog.
            clear()
            awaitingKeyframe = false
        }
        pending.addLast(sample)
        pendingBytes += sample.data.size
        largestUnit = maxOf(largestUnit, sample.data.size)
        if (pending.size > maxSamples || pendingBytes > maxBytes) {
            clear()
            awaitingKeyframe = true
            return Offer.Overflowed
        }
        return if (newFormat != null) Offer.HeldNeedsDecoder else Offer.Held
    }

    /** The next unit for a free input buffer, oldest first. */
    fun next(): DecodableSample? = pending.removeFirstOrNull()?.also { pendingBytes -= it.data.size }

    /** A unit that did not fit goes back to the front, untouched. */
    fun putBack(sample: DecodableSample) {
        pending.addFirst(sample)
        pendingBytes += sample.data.size
    }

    /**
     * The decoder went away (surface lost, error, too-small buffers) with
     * whatever it had consumed. What is held survives only if it starts at a
     * keyframe; otherwise its references are gone. True when a keyframe is needed.
     */
    fun decoderLost(): Boolean {
        if (pending.firstOrNull()?.isKeyframe == true) return false
        clear()
        awaitingKeyframe = true
        return true
    }

    /** Session reset, codec change or video off: nothing carries over. */
    fun reset() {
        clear()
        format = null
        largestUnit = 0
        awaitingKeyframe = true
    }

    private fun clear() {
        pending.clear()
        pendingBytes = 0
    }
}
