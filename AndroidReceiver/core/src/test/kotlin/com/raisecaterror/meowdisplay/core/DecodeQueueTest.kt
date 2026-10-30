package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.session.StreamCodec
import com.raisecaterror.meowdisplay.core.video.DecodableSample
import com.raisecaterror.meowdisplay.core.video.DecodeQueue
import com.raisecaterror.meowdisplay.core.video.DecodeQueue.Offer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** What waits for the decoder across connect, rotation, decoder loss, surface recreation and reconnect. */
class DecodeQueueTest {
    private val sps = listOf(byteArrayOf(0, 0, 0, 1, 0x67), byteArrayOf(0, 0, 0, 1, 0x68))
    private fun key(format: List<ByteArray>? = sps, size: Int = 100, codec: StreamCodec = StreamCodec.H264) =
        DecodableSample(codec, format, isKeyframe = true, data = ByteArray(size), captureMs = null)
    private fun delta(size: Int = 10) = DecodableSample(StreamCodec.H264, null, isKeyframe = false, data = ByteArray(size), captureMs = null)

    @Test
    fun initialConnectionHoldsTheFirstKeyframeUntilTheDecoderTakesIt() {
        val queue = DecodeQueue()
        assertEquals("nothing decodes before a keyframe", Offer.NeedsKeyframe, queue.offer(delta()))
        val first = key()
        assertEquals(Offer.HeldNeedsDecoder, queue.offer(first))
        // No surface or input buffer yet: everything waits, in order, nothing dropped.
        val deltas = List(5) { delta() }
        deltas.forEach { assertEquals(Offer.Held, queue.offer(it)) }
        assertSame(first, queue.next())
        deltas.forEach { assertSame(it, queue.next()) }
        assertNull(queue.next())
    }

    @Test
    fun backpressureIsBoundedAndRecoversThroughAKeyframe() {
        val queue = DecodeQueue(maxSamples = 4)
        queue.offer(key())
        repeat(3) { assertEquals(Offer.Held, queue.offer(delta())) }
        assertEquals("one past the bound drops the queue", Offer.Overflowed, queue.offer(delta()))
        assertTrue(queue.isEmpty)
        assertEquals(Offer.NeedsKeyframe, queue.offer(delta()))
        assertEquals(Offer.Held, queue.offer(key(format = null)))
        assertEquals(1, queue.size)
        val bytes = DecodeQueue(maxBytes = 150)
        bytes.offer(key(size = 100))
        assertEquals(Offer.Overflowed, bytes.offer(delta(size = 60)))
    }

    @Test
    fun aNewKeyframeSupersedesTheBacklog() {
        val queue = DecodeQueue()
        queue.offer(key())
        repeat(10) { queue.offer(delta()) }
        val fresh = key(format = null)
        queue.offer(fresh)
        assertEquals(1, queue.size)
        assertSame(fresh, queue.next())
    }

    @Test
    fun anOrientationChangeBringsANewFormatAndDropsTheOldOne() {
        val queue = DecodeQueue()
        queue.offer(key())
        queue.offer(delta())
        val portrait = listOf(byteArrayOf(0, 0, 0, 1, 0x67, 9), byteArrayOf(0, 0, 0, 1, 0x68, 9))
        assertEquals(Offer.HeldNeedsDecoder, queue.offer(key(format = portrait)))
        assertEquals(1, queue.size)
        assertSame(portrait, queue.format)
    }

    @Test
    fun aLostDecoderKeepsWhatStartsAtAKeyframeAndOtherwiseAsksForOne() {
        val queue = DecodeQueue()
        queue.offer(key())
        queue.offer(delta())
        assertFalse("surface recreated before the keyframe was fed: replay it", queue.decoderLost())
        assertEquals(2, queue.size)
        queue.next()
        assertTrue("the keyframe went into the lost decoder: its dependents cannot decode", queue.decoderLost())
        assertTrue(queue.isEmpty)
        assertEquals(Offer.NeedsKeyframe, queue.offer(delta()))
        assertTrue(queue.decoderLost())
        assertTrue("the format survives a decoder loss", queue.format != null)
    }

    @Test
    fun anOversizeUnitGoesBackUntouchedAndSizesTheNextDecoder() {
        val queue = DecodeQueue()
        val big = key(size = 5_000)
        queue.offer(big)
        assertEquals(5_000, queue.largestUnit)
        val taken = queue.next()!!
        queue.putBack(taken)
        assertFalse(queue.decoderLost())
        assertSame(big, queue.next())
        assertEquals("never truncated", 5_000, big.data.size)
    }

    @Test
    fun reconnectAndCodecChangesStartFromNothing() {
        val queue = DecodeQueue()
        queue.offer(key())
        queue.offer(delta())
        queue.reset()
        assertTrue(queue.isEmpty)
        assertNull(queue.format)
        assertEquals(Offer.NeedsKeyframe, queue.offer(delta()))
        val hevc = listOf(byteArrayOf(0, 0, 0, 1, 0x40), byteArrayOf(0, 0, 0, 1, 0x42), byteArrayOf(0, 0, 0, 1, 0x44))
        assertEquals(Offer.HeldNeedsDecoder, queue.offer(key(format = hevc, codec = StreamCodec.Hevc)))
        assertEquals(StreamCodec.Hevc, queue.codec)
    }
}
