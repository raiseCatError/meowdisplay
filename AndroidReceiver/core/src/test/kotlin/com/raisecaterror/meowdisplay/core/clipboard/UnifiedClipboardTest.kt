package com.raisecaterror.meowdisplay.core.clipboard

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File

/** The Kotlin clipboard rules against the Swift ones (fixtures/clipboard/vectors.json, MacTests/UnifiedClipboardTests). */
class UnifiedClipboardTest {
    private val root: JsonObject by lazy {
        val dir = System.getProperty("meow.clipboardFixtures") ?: error("meow.clipboardFixtures not set")
        Json.parseToJsonElement(File(dir, "vectors.json").readText()).jsonObject
    }

    @Test
    fun replaysTheSwiftVectors() {
        val scenarios = root["scenarios"]!!.jsonArray
        assertTrue(scenarios.size >= 7)
        for (sc in scenarios) {
            val s = sc.jsonObject
            val name = s["name"]!!.jsonPrimitive.content
            val syncs = s["devices"]!!.jsonArray.associate { it.jsonPrimitive.content.let { d -> d to ClipboardSync(d) } }
            val events = mutableMapOf<String, ClipHeader>()
            fun name(h: ClipHeader?) = h?.let { "${it.id.origin}:${it.id.seq}" }
            for ((i, st) in s["steps"]!!.jsonArray.withIndex()) {
                val step = st.jsonObject
                val sync = syncs.getValue(step["dev"]!!.jsonPrimitive.content)
                val expect = step["expect"]!!.jsonObject
                val where = "$name step $i"
                when (step["op"]!!.jsonPrimitive.content) {
                    "copy" -> {
                        val h = sync.localCopy(step["hash"]!!.jsonPrimitive.content)
                        if (expect["event"] is JsonNull) assertNull(where, h)
                        else {
                            h ?: return fail("$where: expected an event")
                            events[name(h)!!] = h
                            assertEquals(where, expect["event"]!!.jsonPrimitive.content, name(h))
                            assertEquals(where, expect["lc"]!!.jsonPrimitive.long, h.lamport)
                            assertEquals(where, expect["ctx"]!!.jsonObject.mapValues { it.value.jsonPrimitive.long }, h.context)
                        }
                    }
                    "recv" -> assertEquals(where, expect["decision"]!!.jsonPrimitive.content,
                        sync.receive(events.getValue(step["event"]!!.jsonPrimitive.content)).wire)
                    "merge" -> sync.merge(syncs.getValue(step["from"]!!.jsonPrimitive.content).seen)
                }
                fun opt(k: String) = expect[k]?.takeIf { it !is JsonNull }?.jsonPrimitive?.content
                assertEquals("$where current", opt("current"), name(sync.current))
                assertEquals("$where alt", opt("alt"), name(sync.alternative))
            }
        }
    }

    @Test
    fun eventsRoundTripAndUnsafeNamesAreRefused() {
        val sync = ClipboardSync("phone-1")
        val text = "héllo ✓".toByteArray()
        val items = listOf(ClipItem(listOf(ClipRep(ClipKind.Text, text.size, ClipHash.of(text), text), ClipRep(ClipKind.Png, 900_000, "0123456789abcdef", blob = 0))))
        val files = listOf(ClipFile(listOf("Folder"), 0, true), ClipFile(listOf("Folder", "a.txt"), 12, false, 1))
        val h = sync.localCopy(ClipEvent.contentHash(items, files))!!
        val event = ClipEvent(h, 1_700_000_000_000, items, files)
        val parsed = ClipEvent.parse(Json.parseToJsonElement(event.wire().toString()).jsonObject)!!
        assertEquals(event.header, parsed.header)
        assertArrayEquals(text, parsed.items[0].reps[0].inline)
        assertEquals(files, parsed.files)
        for (bad in listOf(listOf("..", "x"), listOf("a/b"), listOf("a\u0000"), listOf(""), listOf("a\\b"))) {
            val j = buildJsonObject {
                event.wire().forEach { (k, v) -> if (k != "files") put(k, v) }
                put("files", buildJsonArray { add(buildJsonObject { put("p", buildJsonArray { bad.forEach { add(JsonPrimitive(it)) } }); put("n", 1); put("b", 1) }) })
            }
            assertNull("$bad could leave its folder", ClipEvent.parse(j))
        }
    }

    @Test
    fun blobsArriveVerifiedRangeByRange() {
        val bytes = ByteArray(600_000) { (it % 251).toByte() }
        val id = ClipEventID("mac-1", 3)
        val fetch = ClipBlobFetch(9, id, 0, bytes.size.toLong(), ClipHash.of(bytes))
        val out = java.io.ByteArrayOutputStream()
        var reads = 0
        while (true) {
            val read = fetch.nextRead() ?: break
            reads++
            val off = read["off"]!!.jsonPrimitive.long.toInt(); val n = read["n"]!!.jsonPrimitive.int
            for (m in ClipBlobWire.answer(9, off.toLong(), bytes.copyOfRange(off, off + n))) {
                when (val s = fetch.handle(m)) {
                    is ClipBlobFetch.Step.RangeDone -> out.write(s.bytes)
                    is ClipBlobFetch.Step.Failed -> fail(s.code)
                    else -> Unit
                }
            }
        }
        assertEquals(3, reads)
        assertArrayEquals(bytes, out.toByteArray())
        val wrong = ClipBlobFetch(3, id, 0, 4, "0000000000000000")
        val ok = ClipBlobWire.answer(3, 0, byteArrayOf(1, 2, 3, 4))
        assertEquals(ClipBlobFetch.Step.More, wrong.handle(ok[0]))
        assertEquals(ClipBlobFetch.Step.Failed("digest"), wrong.handle(ok[1]))
    }
}
