package com.raisecaterror.meowdisplay.core.remote

import com.raisecaterror.meowdisplay.core.crypto.hexBytes
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The knock frame, byte for byte against fixtures/remote/knock-frame-vectors.json (also run by the Swift tests). */
class RemoteKnockFrameTest {
    private val vectors: JsonObject by lazy {
        val dir = requireNotNull(System.getProperty("meow.remoteFixtures")) { "meow.remoteFixtures not set" }
        Json.parseToJsonElement(File(dir, "knock-frame-vectors.json").readText()).jsonObject
    }

    private fun JsonObject.str(key: String) = getValue(key).jsonPrimitive.content
    private fun intent(wire: String) = KnockIntent.entries.single { it.wire == wire }

    @Test
    fun framesAreByteIdenticalToTheSwiftReceivers() {
        val cases = vectors.getValue("encode").jsonArray.map { it.jsonObject }
        assertEquals(2, cases.size)
        for (case in cases) assertArrayEquals(case.str("intent"), case.str("hex").hexBytes(), KnockFrame.encode(intent(case.str("intent"))))
    }

    @Test
    fun theMacReadsAnythingButOneWellFormedFrameAsAutomatic() {
        val cases = vectors.getValue("decode").jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 12)
        for (case in cases) {
            val hex = case.str("hex")
            val bytes = if (hex.isEmpty()) null else hex.hexBytes()
            assertEquals(case.str("name"), intent(case.str("intent")), KnockFrame.intent(bytes))
        }
        assertEquals("no frame at all", KnockIntent.Automatic, KnockFrame.intent(null))
    }

    @Test
    fun aFrameIsALengthPrefixAndExactlyThatManyBytes() {
        for (intent in KnockIntent.entries) {
            val frame = KnockFrame.encode(intent)
            val length = ((frame[0].toInt() and 0xFF) shl 24) or ((frame[1].toInt() and 0xFF) shl 16) or ((frame[2].toInt() and 0xFF) shl 8) or (frame[3].toInt() and 0xFF)
            assertEquals(frame.size - 4, length)
            assertTrue(frame.size <= KnockFrame.MAX_FRAME_BYTES)
            assertEquals(intent, KnockFrame.intent(frame))
        }
    }
}
