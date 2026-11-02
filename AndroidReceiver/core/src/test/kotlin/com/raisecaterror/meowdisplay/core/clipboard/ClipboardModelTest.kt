package com.raisecaterror.meowdisplay.core.clipboard

import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesExport
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** The receiver model against a scripted Mac: grant, copies both ways, ranged fetches, no echo, files on request. */
class ClipboardModelTest {
    private class FakeDevice : ClipboardPlatform {
        var token = 0L
        var items: List<List<Pair<ClipKind, ByteArray>>> = emptyList()
        var next: ClipLocalContent? = null
        override fun changeToken() = token
        override fun write(items: List<List<Pair<ClipKind, ByteArray>>>): Long { this.items = items; return ++token }
        override fun read(textOnly: Boolean, maxBytes: Int, done: (ClipLocalContent?) -> Unit) = done(next)
        val text get() = items.firstOrNull()?.firstOrNull { it.first == ClipKind.Text }?.second?.let { String(it) }
    }

    private val store = object : ClipboardSettingsStore {
        val m = HashMap<String, String>()
        override fun get(key: String) = m[key]
        override fun set(key: String, value: String?) { if (value == null) m.remove(key) else m[key] = value }
    }

    @Test
    fun copiesBothWaysWithRangesAndNoEcho() {
        val tmp = Files.createTempDirectory("clip-model").toFile()
        val sent = mutableListOf<JsonObject>()
        val model = ClipboardModel("moto-1", store, { sent.add(Json.parseToJsonElement(it.toString()).jsonObject); true }, { _, _ -> {} }, File(tmp, "t"))
        val device = FakeDevice()
        model.platform = device
        model.setEnabled(true)
        model.setAvailable(true)
        assertEquals("join", sent.last()["op"]!!.jsonPrimitive.content)
        model.handle(buildJsonObject { put("type", "clip"); put("op", "state"); put("state", "ready"); put("toDevice", true); put("toMac", true); put("types", "all"); put("files", true); put("max", 10_000_000) })
        assertTrue(model.ui.value.ready)

        // A Mac copy: inline text lands on the device.
        val mac = ClipboardSync("mac-1")
        fun macEvent(items: List<ClipItem>, files: List<ClipFile> = emptyList()) =
            ClipEvent(mac.localCopy(ClipEvent.contentHash(items, files))!!, 0, items, files)
        val hi = "hé ✓".toByteArray()
        model.handle(macEvent(listOf(ClipItem(listOf(ClipRep(ClipKind.Text, hi.size, ClipHash.of(hi), hi))))).wire())
        assertEquals("hé ✓", device.text)

        // A long one is fetched in ranges.
        val long = ByteArray(300_000) { ('a' + it % 26).code.toByte() }
        sent.clear()
        model.handle(macEvent(listOf(ClipItem(listOf(ClipRep(ClipKind.Text, long.size, ClipHash.of(long), blob = 0))))).wire())
        var rounds = 0
        while (true) {
            val read = sent.lastOrNull { it["op"]?.jsonPrimitive?.content == "read" } ?: break
            sent.clear(); rounds++
            val off = read["off"]!!.jsonPrimitive.long.toInt(); val n = read["n"]!!.jsonPrimitive.int
            ClipBlobWire.answer(read["req"]!!.jsonPrimitive.int, off.toLong(), long.copyOfRange(off, off + n)).forEach(model::handle)
        }
        assertEquals(2, rounds)
        assertArrayEquals(long, device.items[0][0].second)

        // Its own write is no new copy; a copy made elsewhere goes to the Mac.
        sent.clear()
        model.checkLocal(automatic = true)
        assertTrue(sent.isEmpty())
        device.token++
        val png = ByteArray(40_000) { it.toByte() }
        device.next = ClipLocalContent(listOf(listOf(ClipKind.Text to "x".toByteArray(), ClipKind.Png to png)), emptyList())
        model.checkLocal(automatic = true)
        val ev = ClipEvent.parse(sent.single { it["op"]!!.jsonPrimitive.content == "event" })!!
        assertEquals("moto-1", ev.id.origin)
        assertEquals(ClipboardSync.Decision.Apply, mac.receive(ev.header))
        val pngRep = ev.items[0].rep(ClipKind.Png)!!
        // The Mac reads the image from the device.
        sent.clear()
        model.handle(ClipBlobWire.read(5, ev.id, pngRep.blob!!, 0, png.size))
        val got = java.io.ByteArrayOutputStream()
        sent.filter { it["op"]!!.jsonPrimitive.content == "data" }.forEach { got.write(java.util.Base64.getDecoder().decode(it["d"]!!.jsonPrimitive.content)) }
        assertArrayEquals(png, got.toByteArray())

        // Mac files: fetched only on request, hierarchy kept.
        val files = listOf(ClipFile(listOf("Folder"), 0, true), ClipFile(listOf("Folder", "a.txt"), 3, false, 0))
        model.handle(macEvent(emptyList(), files).wire())
        assertNotNull(model.ui.value.macFiles)
        sent.clear()
        model.getMacFiles(RemoteFilesExport.Mode.Save)
        val read = sent.single { it["op"]!!.jsonPrimitive.content == "read" }
        ClipBlobWire.answer(read["req"]!!.jsonPrimitive.int, 0, "abc".toByteArray()).forEach(model::handle)
        val export = model.ui.value.export!!
        assertEquals(listOf("Folder"), export.files.map { it.name })
        assertEquals("abc", File(export.files[0], "a.txt").readText())
        model.exportFinished(export, completed = true)
        assertTrue(!export.directory.exists())
        tmp.deleteRecursively()
    }
}
