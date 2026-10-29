package com.raisecaterror.meowdisplay.core.workspace

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.util.Base64
import kotlin.random.Random

/** Remote Finder transfers on Android (RemoteTransferQueue.kt, RemoteFiles.kt) against a small fake Mac. */
class RemoteTransferQueueTest {
    /** The Mac side of PROTOCOL.md 6.12, in memory: files by path, folders, transfers. */
    private class FakeMac(val caps: Set<String> = setOf("browse", "download", "upload", "modify", "delete")) {
        val files = HashMap<String, ByteArray>()
        val folders = hashSetOf("")
        var corrupt = false
        private var nextX = 0
        private val open = HashMap<Int, ByteArray>()
        private val uploads = HashMap<Int, Triple<String, ByteArrayOutputStream, Long>>()
        var oversized = 0

        fun answer(o: JsonObject): List<JsonObject> {
            if (o.toString().length >= 32_768) oversized++
            val op = o.s("op")!!
            val req = o["req"]?.jsonPrimitive?.int
            fun reply(body: JsonObjectBuilder.() -> Unit) = buildJsonObject { put("type", "files"); put("op", op); req?.let { put("req", it) }; body() }
            fun err(code: String, more: JsonObjectBuilder.() -> Unit = {}) = listOf(reply { put("ok", false); put("error", code); more() })
            val path = (o["path"] as? JsonArray)?.map { it.jsonPrimitive.content }.orEmpty().joinToString("/")
            fun need(c: String) = if (c in caps) null else err("notAllowed") { put("need", c) }
            return when (op) {
                "state" -> listOf(reply {
                    put("state", "ready")
                    put("roots", buildJsonArray { add(buildJsonObject { put("id", "r1"); put("name", "Shared") }) })
                    put("grant", buildJsonObject { put("duration", "session"); put("scope", "selectedFolders"); put("caps", buildJsonArray { caps.forEach { add(JsonPrimitive(it)) } }) })
                })
                "list" -> {
                    if (path !in folders) return err("notFound")
                    val prefix = if (path.isEmpty()) "" else "$path/"
                    val names = (files.keys + folders).filter { it.startsWith(prefix) && it != path && !it.removePrefix(prefix).contains('/') && it.isNotEmpty() }
                    listOf(reply {
                        put("ok", true); put("root", "r1"); put("path", o["path"] ?: buildJsonArray {})
                        put("entries", buildJsonArray {
                            names.sorted().forEach { n ->
                                add(buildJsonObject {
                                    put("name", n.removePrefix(prefix)); put("dir", n in folders)
                                    if (n !in folders) put("size", files[n]!!.size)
                                })
                            }
                        })
                    })
                }
                "download" -> {
                    if (o.s("purpose") == "save") need("download")?.let { return it }
                    val bytes = files[path] ?: return err("notFound")
                    val x = ++nextX
                    open[x] = bytes
                    listOf(reply { put("ok", true); put("x", x); put("size", bytes.size); put("mod", 1); put("mime", "video/mp4") })
                }
                "read" -> {
                    val x = o["x"]!!.jsonPrimitive.int
                    val bytes = open[x] ?: return err("noTransfer")
                    val off = o["o"]!!.jsonPrimitive.long.toInt()
                    val n = minOf(o["n"]!!.jsonPrimitive.int, bytes.size - off)
                    val range = bytes.copyOfRange(off, off + n)
                    val out = mutableListOf<JsonObject>()
                    var i = 0
                    while (i < range.size) {
                        val j = minOf(i + 22_000, range.size)
                        val part = range.copyOfRange(i, j).also { if (corrupt) it[0] = (it[0] + 1).toByte() }
                        out += buildJsonObject { put("type", "files"); put("op", "data"); put("x", x); put("o", off + i); put("d", Base64.getEncoder().encodeToString(part)) }
                        i = j
                    }
                    val sha = MessageDigest.getInstance("SHA-256").digest(range).take(8).joinToString("") { "%02x".format(it) }
                    out + reply { put("ok", true); put("x", x); put("o", off); put("n", n); put("sha", sha) }
                }
                "close" -> { open.remove(o["x"]!!.jsonPrimitive.int); emptyList() }
                "uploadBegin" -> {
                    need("upload")?.let { return it }
                    val name = o.s("name")!!
                    val full = if (path.isEmpty()) name else "$path/$name"
                    var target = full
                    if (full in files || full in folders) when (o.s("conflict")) {
                        "skip" -> return listOf(reply { put("ok", true); put("skipped", true); put("name", name) })
                        "rename" -> { var k = 2; while ("${full.substringBeforeLast('.')} $k.${full.substringAfterLast('.')}" in files) k++; target = "${full.substringBeforeLast('.')} $k.${full.substringAfterLast('.')}" }
                        "replace" -> need("delete")?.let { return it }
                        else -> return err("exists") { put("suggest", "x") }
                    }
                    val x = ++nextX
                    uploads[x] = Triple(target, ByteArrayOutputStream(), o["size"]!!.jsonPrimitive.long)
                    listOf(reply { put("ok", true); put("x", x); put("name", target.substringAfterLast('/')) })
                }
                "uploadData" -> {
                    val x = o["x"]!!.jsonPrimitive.int
                    val u = uploads[x]!!
                    assertEquals(u.second.size().toLong(), o["o"]!!.jsonPrimitive.long)
                    u.second.write(Base64.getDecoder().decode(o.s("d")))
                    listOf(buildJsonObject { put("type", "files"); put("op", "uploadAck"); put("ok", true); put("x", x); put("o", u.second.size()) })
                }
                "uploadEnd" -> {
                    val x = o["x"]!!.jsonPrimitive.int
                    val u = uploads.remove(x)!!
                    val bytes = u.second.toByteArray()
                    val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
                    if (bytes.size.toLong() != u.third || sha != o.s("sha")) return err("digest")
                    files[u.first] = bytes
                    listOf(reply { put("ok", true); put("x", x); put("name", u.first.substringAfterLast('/')) })
                }
                "mkdir" -> {
                    need("upload")?.let { return it }
                    val name = o.s("name")!!
                    val full = if (path.isEmpty()) name else "$path/$name"
                    if (full in folders) when (o.s("conflict")) {
                        "skip" -> return listOf(reply { put("ok", true); put("name", name) })
                        "rename" -> { var k = 2; while ("$full $k" in folders) k++; folders += "$full $k"; return listOf(reply { put("ok", true); put("name", "$name $k") }) }
                        else -> return err("exists")
                    }
                    folders += full
                    listOf(reply { put("ok", true); put("name", name) })
                }
                else -> err("unsupported")
            }
        }
    }

    private val timers = mutableListOf<Triple<() -> Unit, BooleanArray, Long>>()
    private val scheduler = RemoteFilesScheduler { ms, block -> val alive = booleanArrayOf(true); timers += Triple(block, alive, ms); { alive[0] = false } }
    private val wire = ArrayDeque<JsonObject>()

    private fun model(mac: FakeMac): RemoteFilesModel {
        lateinit var m: RemoteFilesModel
        m = RemoteFilesModel(
            send = { o -> wire.addAll(mac.answer(o)); true },
            inputAllowed = { false },
            scheduler = scheduler,
            cacheDir = kotlin.io.path.createTempDirectory("RemoteTransferQueueTest").toFile(),
        )
        m.setAvailable(true)
        return m
    }

    /** Delivers the Mac's replies in order until nothing is left (replies are never handled inside a send). */
    private fun deliver(m: RemoteFilesModel) {
        var guard = 0
        while (wire.isNotEmpty() && guard++ < 100_000) RemoteFilesReply.parse(wire.removeFirst())?.let(m::apply)
    }

    private fun runShortTimers() {
        val due = timers.filter { it.third < 10_000 }; timers.removeAll(due)
        due.forEach { (b, alive, _) -> if (alive[0]) b() }
    }

    private fun ready(mac: FakeMac): RemoteFilesModel {
        val m = model(mac)
        m.open(); deliver(m); deliver(m)
        assertEquals(RemoteFilesAccess.Ready, m.ui.value.access)
        return m
    }

    @Test
    fun savesFilesAndFoldersIntactAndHandsThemOn() {
        val mac = FakeMac()
        val movie = Random(1).nextBytes(1_300_000)
        mac.files["movie.bin"] = movie
        mac.folders += "Album"; mac.folders += "Album/Inner"
        mac.files["Album/a.jpg"] = Random(2).nextBytes(70_000)
        mac.files["Album/Inner/b.txt"] = ByteArray(10)
        mac.files["Album/empty.txt"] = ByteArray(0)
        val m = ready(mac)
        val entries = m.ui.value.entries
        m.save(listOf(entries.first { it.name == "movie.bin" }, entries.first { it.name == "Album" }))
        deliver(m)
        val e = m.ui.value.export!!
        assertEquals(RemoteFilesExport.Mode.Save, e.mode)
        assertEquals(setOf("movie.bin", "Album"), e.files.map { it.name }.toSet())
        assertArrayEquals(movie, File(e.directory, "movie.bin").readBytes())
        assertArrayEquals(mac.files["Album/a.jpg"], File(e.directory, "Album/a.jpg").readBytes())
        assertEquals(10, File(e.directory, "Album/Inner/b.txt").length())
        assertTrue("zero-byte files come too", File(e.directory, "Album/empty.txt").exists())
        m.exportFinished(e, completed = true)
        assertTrue("copies go once saved", !e.directory.exists())
        assertEquals(0, mac.oversized)
    }

    @Test
    fun aDamagedRangeFailsAndRetryResumes() {
        val mac = FakeMac()
        mac.files["big.bin"] = Random(3).nextBytes(1_200_000)
        val m = ready(mac)
        mac.corrupt = true
        m.save(listOf(m.ui.value.entries.single()))
        deliver(m)
        val item = m.transfers.items.value.single()
        assertEquals(RemoteTransferItem.State.Failed("digest"), item.state)
        assertNull("nothing handed on", m.ui.value.export)
        mac.corrupt = false
        m.transfers.retry(item.id)
        deliver(m)
        assertEquals(RemoteTransferItem.State.Done, m.transfers.items.value.single().state)
        assertArrayEquals(mac.files["big.bin"], m.ui.value.export!!.files.single().readBytes())
    }

    @Test
    fun uploadsStayUnderTheLimitAndAskBeforeReplacing() {
        val mac = FakeMac()
        mac.files["report.txt"] = "old".toByteArray()
        val m = ready(mac)
        val payload = Random(4).nextBytes(600_000)
        val src = object : RemoteUploadSource {
            override val name = "report.txt"; override val size = payload.size.toLong(); override val modified: Long? = null
            override fun open() = ByteArrayInputStream(payload)
        }
        m.upload(listOf(src))
        deliver(m)
        val c = m.transfers.firstConflict!!
        assertArrayEquals("never overwritten without Replace", "old".toByteArray(), mac.files["report.txt"])
        m.transfers.resolveConflict(c.id, RemoteFileConflictChoice.KeepBoth, forAll = false)
        deliver(m)
        assertEquals(RemoteTransferItem.State.Done, m.transfers.items.value.single().state)
        assertEquals("report 2.txt", m.transfers.items.value.single().resultName)
        assertArrayEquals(payload, mac.files["report 2.txt"])
        assertEquals("every message stays under the control limit", 0, mac.oversized)

        // A folder keeps its structure; an existing one can merge.
        val folder = RemoteUploadFolder("Project", listOf(listOf("Sub")), listOf(
            RemoteLocalFileSource(File.createTempFile("one", ".bin").apply { writeBytes(ByteArray(1000) { 1 }) }) to listOf("one.bin"),
            RemoteLocalFileSource(File.createTempFile("two", ".bin").apply { writeBytes(ByteArray(2000) { 2 }) }) to listOf("Sub", "two.bin"),
        ))
        m.upload(emptyList(), listOf(folder))
        deliver(m)
        assertEquals(1000, mac.files["Project/one.bin"]?.size)
        assertEquals(2000, mac.files["Project/Sub/two.bin"]?.size)
        m.upload(emptyList(), listOf(folder))
        deliver(m)
        assertEquals("Project", m.ui.value.folderConflict)
        m.answerFolderConflict(RemoteFolderConflictChoice.KeepBoth)
        deliver(m)
        assertEquals(2000, mac.files["Project 2/Sub/two.bin"]?.size)
    }

    @Test
    fun readOnlyHidesWritesAndTheMacRefusesThemToo() {
        val mac = FakeMac(caps = setOf("browse"))
        val m = ready(mac)
        assertTrue(m.ui.value.grant!!.readOnly)
        m.upload(listOf(RemoteLocalFileSource(File.createTempFile("readonly", ".txt"))))
        assertEquals(RemoteFilesNotice.Needs("upload"), m.ui.value.notice)
        assertTrue(m.transfers.items.value.isEmpty())
        var got: RemoteFilesReply? = null
        m.request("mkdir", body = { put("root", "r1"); put("path", buildJsonArray {}); put("name", "X"); put("conflict", "rename") }) { got = it }
        deliver(m)
        assertEquals("notAllowed", got?.error)
        assertEquals("upload", got?.need)
        m.save(listOf(RemoteFileEntry("a", false, RemoteFileKind.File)))
        assertEquals(RemoteFilesNotice.Needs("download"), m.ui.value.notice)
    }

    @Test
    fun streamsReadAnyRangeAndTimeOut() {
        val mac = FakeMac()
        val bytes = Random(5).nextBytes(3_000_000)
        mac.files["clip.mov"] = bytes
        val m = ready(mac)
        m.openEntry(m.ui.value.entries.single().copy(kind = RemoteFileKind.Video))
        deliver(m)
        val c = m.ui.value.viewer?.content as RemoteFileViewer.Content.Stream
        val s = m.stream(c.x)!!
        val got = HashMap<Long, ByteArray?>()
        for (o in listOf(2_500_000L, 0L, 1_000_000L, 2_999_990L)) s.read(o, 300_000) { got[o] = it }
        deliver(m)
        for ((o, d) in got) assertArrayEquals("range at $o", bytes.copyOfRange(o.toInt(), minOf(o.toInt() + 300_000, bytes.size)), d)
        // Closing the viewer ends the stream; a pending read answers null instead of hanging.
        var late: ByteArray? = ByteArray(1)
        s.read(10, 10) { late = it }
        wire.clear()
        m.closePreview()
        assertNull(late)
        assertNull(m.stream(c.x))
    }

    @Test
    fun sortingAndNames() {
        fun e(n: String, dir: Boolean = false, size: Long? = null, days: Long = 0) = RemoteFileEntry(n, dir, if (dir) RemoteFileKind.Folder else RemoteFileKind.File, size, days * 86_400)
        val list = listOf(e("File 10.txt", size = 5, days = 3), e("File 2.txt", size = 50, days = 1), e("Photos", dir = true, days = 2), e("a.png", size = 7, days = 4))
        assertEquals(listOf("a.png", "File 2.txt", "File 10.txt", "Photos"), RemoteFilesSorting.sorted(list, RemoteFilesSort.Name, true).map { it.name })
        assertEquals(listOf("Photos", "File 10.txt", "a.png", "File 2.txt"), RemoteFilesSorting.sorted(list, RemoteFilesSort.Size, true).map { it.name })
        assertEquals(listOf("a.png", "File 10.txt", "Photos", "File 2.txt"), RemoteFilesSorting.sorted(list, RemoteFilesSort.Date, false).map { it.name })
        assertEquals("a-b-c", RemoteFilesFormat.cleanName(" a/b:c "))
        assertNull(RemoteFilesFormat.cleanName(".."))
        assertNull(RemoteFilesFormat.cleanName(".hidden"))
    }
}

private fun JsonObject.s(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
