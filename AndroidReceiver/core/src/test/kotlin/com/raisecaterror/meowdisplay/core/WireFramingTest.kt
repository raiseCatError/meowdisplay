package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.wire.AudioMediaFrame
import com.raisecaterror.meowdisplay.core.wire.IncomingFrame
import com.raisecaterror.meowdisplay.core.wire.WireFraming
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream

class WireFramingTest {
    /** TCP gives no boundaries: frames split across reads and packed together still reassemble. */
    @Test
    fun framesReassembleFromOneByteReadsAndPackedReads() {
        val first = """{"type":"ping","t":1}""".toByteArray()
        val second = byteArrayOf(0, 0, 0, 1, 0x65, 0x11)
        val bytes = WireFraming.frame(first) + WireFraming.frame(second)
        val trickle = object : InputStream() {
            var index = 0
            override fun read(): Int = if (index < bytes.size) bytes[index++].toInt() and 0xFF else -1
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (index >= bytes.size) return -1
                b[off] = bytes[index++]
                return 1
            }
        }
        val reader = WireFraming.reader(trickle)
        assertArrayEquals(first, WireFraming.read(reader))
        assertArrayEquals(second, WireFraming.read(reader))
        assertNull(WireFraming.read(reader))
    }

    @Test
    fun zeroAndOversizedLengthsAreProtocolErrors() {
        for (header in listOf(byteArrayOf(0, 0, 0, 0), byteArrayOf(0x7F, 0, 0, 0))) {
            val failed = runCatching { WireFraming.read(WireFraming.reader(ByteArrayInputStream(header))) }
            assertTrue(failed.exceptionOrNull() is IOException)
        }
        assertTrue(runCatching { WireFraming.frame(ByteArray(0)) }.isFailure)
        assertTrue(runCatching { WireFraming.frame(ByteArray(WireFraming.MAX_OUTGOING_BYTES + 1)) }.isFailure)
    }

    @Test
    fun theDemuxChecksTheAudioMarkerFirstThenTheJsonHeuristic() {
        assertTrue(IncomingFrame.classify("""{"type":"ping"}""".toByteArray()) is IncomingFrame.Control)
        // Telemetry prefix then Annex B: starts with '{' but has NULs.
        val video = """{"cap":1,"snd":2}""".toByteArray() + byteArrayOf(0, 0, 0, 1, 0x65)
        assertTrue(IncomingFrame.classify(video) is IncomingFrame.Video)
        assertTrue(IncomingFrame.classify(byteArrayOf(0, 0, 0, 1, 0x67)) is IncomingFrame.Video)
        // A JSON-looking payload of 32768 bytes or more is not control.
        val huge = ("{" + " ".repeat(32767)).toByteArray()
        assertTrue(IncomingFrame.classify(huge) is IncomingFrame.Video)

        val config = AudioMediaFrame.Config(48_000, 2, AudioMediaFrame.Bytes(byteArrayOf(0x11, 0x90.toByte())))
        assertEquals(config, (IncomingFrame.classify(config.encode()) as IncomingFrame.Audio).frame)
        // Malformed audio is dropped, never fatal and never mistaken for video.
        assertEquals(IncomingFrame.Ignored, IncomingFrame.classify(byteArrayOf(0x01, 0x09)))
        assertEquals(IncomingFrame.Ignored, IncomingFrame.classify(config.encode().copyOf(5)))
        val packet = AudioMediaFrame.Packet(1, 2, 3, AudioMediaFrame.Bytes(ByteArray(4)))
        val lying = packet.encode().also { it[it.size - 5] = 0x7F }
        assertEquals(IncomingFrame.Ignored, IncomingFrame.classify(lying))
    }
}
