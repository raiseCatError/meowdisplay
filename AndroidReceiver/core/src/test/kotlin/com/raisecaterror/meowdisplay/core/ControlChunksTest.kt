package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.crypto.base64
import com.raisecaterror.meowdisplay.core.session.SenderMessage
import com.raisecaterror.meowdisplay.core.wire.ControlChunkAssembler
import com.raisecaterror.meowdisplay.core.wire.ControlChunkAssembler.Outcome
import com.raisecaterror.meowdisplay.core.wire.ControlChunkWire
import com.raisecaterror.meowdisplay.core.wire.IncomingFrame
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Large control messages in parts (PROTOCOL.md 6.14); mirrors MacTests/ControlChunksTests.swift. */
class ControlChunksTest {
    private fun message(bytes: Int): ByteArray = buildJsonObject {
        put("type", "files"); put("op", "preview"); put("ok", true)
        put("jpeg", ByteArray(bytes) { (it * 31 + 7).toByte() }.base64())
    }.toString().toByteArray()

    private fun ControlChunkAssembler.addAll(parts: List<JsonObject>, now: Long = 0): Outcome {
        var last: Outcome = Outcome.Pending
        for (p in parts) last = add(p, now)
        return last
    }

    private fun JsonObject.with(k: String, v: JsonPrimitive) = JsonObject(this + (k to v))

    @Test
    fun roundTripAndEveryPartIsAControlFrame() {
        for (size in listOf(1, 16_000, 22_000, 23_999, 520_000, 2_900_000)) {
            val m = message(size)
            val parts = ControlChunkWire.split(m, 9)
            for (p in parts) {
                val frame = p.toString().toByteArray()
                assertTrue(frame.size < 32_768)
                assertTrue(IncomingFrame.classify(frame) is IncomingFrame.Control)
                assertTrue(SenderMessage.parse(p.toString()) is SenderMessage.Chunk)
            }
            val r = ControlChunkAssembler().addAll(parts)
            assertTrue(r is Outcome.Complete)
            assertArrayEquals(m, (r as Outcome.Complete).bytes)
        }
    }

    @Test
    fun interleavedMessagesAssembleIndependently() {
        val m1 = message(60_000); val m2 = message(90_000)
        val p1 = ControlChunkWire.split(m1, 1); val p2 = ControlChunkWire.split(m2, 2)
        val a = ControlChunkAssembler()
        val done = mutableListOf<String>()
        for (k in 0 until maxOf(p1.size, p2.size)) for (p in listOf(p1, p2)) if (k < p.size) {
            (a.add(p[k], 1) as? Outcome.Complete)?.let { done += it.text }
        }
        assertEquals(setOf(String(m1), String(m2)), done.toSet())
    }

    @Test
    fun gapsRepeatsAndMissingStartAreDropped() {
        val parts = ControlChunkWire.split(message(100_000), 3)
        val a = ControlChunkAssembler()
        assertEquals(Outcome.Pending, a.add(parts[0], 0))
        assertEquals(Outcome.Dropped("out of order"), a.add(parts[2], 0))
        assertEquals(0, a.inFlight)
        assertEquals(Outcome.Dropped("no start"), a.add(parts[1], 0))
        val b = ControlChunkAssembler()
        b.add(parts[0], 0); b.add(parts[1], 0)
        assertEquals(Outcome.Dropped("out of order"), b.add(parts[1], 0))
    }

    @Test
    fun digestLengthAndHeaderAreChecked() {
        val parts = ControlChunkWire.split(message(50_000), 4).toMutableList()
        parts[0] = parts[0].with("sha", JsonPrimitive("0000000000000000"))
        assertEquals(Outcome.Dropped("digest"), ControlChunkAssembler().addAll(parts))

        val big = ControlChunkWire.split(message(50_000), 5)
        assertEquals(Outcome.Dropped("bad header"), ControlChunkAssembler().add(big[0].with("len", JsonPrimitive(ControlChunkWire.MAX_TOTAL_BYTES + 1)), 0))

        val short = ControlChunkWire.split(message(50_000), 6).toMutableList()
        short[0] = short[0].with("len", JsonPrimitive(short[0].getValue("len").jsonPrimitive.int - 10))
        assertEquals(Outcome.Dropped("too long"), ControlChunkAssembler().addAll(short))

        val junk = ControlChunkWire.split(message(50_000), 7)
        val c = ControlChunkAssembler()
        c.add(junk[0], 0)
        assertEquals(Outcome.Dropped("bad base64"), c.add(junk[1].with("d", JsonPrimitive("%%%not base64%%%")), 0))
        assertEquals(0, c.inFlight)
    }

    @Test
    fun stalePartialsExpireAndInFlightIsBounded() {
        val a = ControlChunkAssembler()
        val parts = (1..6).map { ControlChunkWire.split(message(40_000), it) }
        parts.forEachIndexed { k, p -> a.add(p[0], k * 1000L) }
        assertEquals(ControlChunkWire.MAX_IN_FLIGHT, a.inFlight)
        assertEquals(Outcome.Dropped("no start"), a.add(parts[0][1], 6000))
        assertEquals(Outcome.Dropped("no start"), a.add(parts[5][1], 6000 + ControlChunkWire.TIMEOUT_MS + 1))
        assertEquals(0, a.inFlight)
    }

    /** fixtures/receiver-protocol/control-chunks.json, shared with the Swift code. */
    @Test
    fun sharedVector() {
        val dir = requireNotNull(System.getProperty("meow.fixtures"))
        val v = Json.parseToJsonElement(File(dir, "control-chunks.json").readText()).jsonObject
        val message = v.getValue("message").jsonPrimitive.content.toByteArray()
        val expected = v.getValue("parts").jsonArray.map { it.jsonObject }
        assertEquals(v.getValue("sha").jsonPrimitive.content, ControlChunkWire.digest(message))
        assertEquals(expected, ControlChunkWire.split(message, v.getValue("id").jsonPrimitive.int, v.getValue("partBytes").jsonPrimitive.int))
        val r = ControlChunkAssembler().addAll(expected)
        assertArrayEquals(message, (r as Outcome.Complete).bytes)
    }
}
