package com.raisecaterror.meowdisplay.core.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Remote Finder on the receiver (RemoteFiles.kt), the same cases as iOS RemoteFilesModelTests. */
class RemoteFilesModelTest {
    private val sent = mutableListOf<JsonObject>()
    private var control = false
    private val timers = mutableListOf<Triple<() -> Unit, BooleanArray, Long>>()

    private fun model() = RemoteFilesModel(
        send = { sent += it; true },
        inputAllowed = { control },
        scheduler = { ms, block -> val alive = booleanArrayOf(true); timers += Triple(block, alive, ms); { alive[0] = false } },
        cacheDir = kotlin.io.path.createTempDirectory("RemoteFilesModelTest").toFile(),
    ).also { it.setAvailable(true) }

    /** Runs the short delays (debounces, notices); time is not modelled. Timeouts run only with [timeouts]. */
    private fun runTimers(timeouts: Boolean = false) {
        val due = timers.filter { timeouts || it.third < 10_000 }
        timers.removeAll(due)
        due.forEach { (block, alive, _) -> if (alive[0]) block() }
    }

    private fun reply(json: String) = RemoteFilesReply.parse(Json.parseToJsonElement(json).jsonObject)!!
    private fun last(op: String) = sent.last { it["op"]?.jsonPrimitive?.content == op }
    private fun JsonObject.req() = this["req"]!!.jsonPrimitive.int
    private fun JsonObject.strings(k: String) = this[k]!!.jsonArray.map { it.jsonPrimitive.content }

    @Test
    fun asksTheMacFirstAndOpensTheOnlyFolder() {
        val m = model()
        m.open()
        assertEquals(RemoteFilesAccess.Asking, m.ui.value.access)
        assertEquals("filesRequest", sent.single()["type"]!!.jsonPrimitive.content)
        assertEquals("state", sent.single()["op"]!!.jsonPrimitive.content)
        m.apply(reply("""{"op":"state","state":"asking","req":1}"""))
        assertTrue(m.ui.value.entries.isEmpty())
        m.apply(reply("""{"op":"state","state":"ready","roots":[{"id":"r1","name":"Projects"}]}"""))
        assertEquals(RemoteFilesAccess.Ready, m.ui.value.access)
        assertEquals(RemoteFilesLocation.Folder("r1", emptyList()), m.ui.value.location)
        val list = last("list")
        assertEquals("r1", list["root"]!!.jsonPrimitive.content)
        assertTrue(m.ui.value.loading)
        m.apply(reply("""{"op":"list","ok":true,"root":"r1","path":[],"req":${list.req()},"entries":[
            {"name":"App","dir":true,"kind":"folder"},{"name":"photo.jpg","dir":false,"kind":"image","size":2048,"mod":1700000000}]}"""))
        assertFalse(m.ui.value.loading)
        assertEquals(listOf("App", "photo.jpg"), m.ui.value.entries.map { it.name })
        assertEquals(RemoteFileKind.Image, m.ui.value.entries[1].kind)
        assertEquals(2048L, m.ui.value.entries[1].size)
        assertEquals(listOf("Locations", "Projects"), m.ui.value.breadcrumbs.map { it.first })
    }

    @Test
    fun foldersBackAndStaleReplies() {
        val m = model()
        m.open()
        m.apply(reply("""{"op":"state","state":"ready","roots":[{"id":"r1","name":"Projects"},{"id":"r2","name":"Photos"}]}"""))
        assertEquals(RemoteFilesLocation.Locations, m.ui.value.location)
        m.go(RemoteFilesLocation.Folder("r1", emptyList()))
        val first = last("list").req()
        m.openEntry(RemoteFileEntry("App", true, RemoteFileKind.Folder))
        assertEquals(RemoteFilesLocation.Folder("r1", listOf("App")), m.ui.value.location)
        assertEquals(listOf("Locations", "Projects", "App"), m.ui.value.breadcrumbs.map { it.first })
        m.apply(reply("""{"op":"list","ok":true,"root":"r1","path":[],"req":$first,"entries":[{"name":"old","dir":true}]}"""))
        assertTrue("a late answer for the folder we left is ignored", m.ui.value.entries.isEmpty())
        m.goBack(); m.goBack()
        assertEquals(RemoteFilesLocation.Locations, m.ui.value.location)
        assertFalse(m.ui.value.canGoBack)
        m.go(RemoteFilesLocation.Folder("r2", emptyList()))
        m.apply(reply("""{"op":"list","ok":false,"error":"permission","req":${last("list").req()}}"""))
        assertEquals("permission", m.ui.value.folderError)
    }

    @Test
    fun ownerSaysNoOrTurnsItOff() {
        val m = model()
        m.open()
        m.apply(reply("""{"op":"state","state":"denied"}"""))
        assertEquals(RemoteFilesAccess.Denied, m.ui.value.access)
        m.apply(reply("""{"op":"list","ok":false,"error":"off"}"""))
        assertEquals(RemoteFilesAccess.Off, m.ui.value.access)
        m.setAvailable(false)
        assertFalse(m.ui.value.isOpen)
        assertEquals(RemoteFilesAccess.Unknown, m.ui.value.access)
    }

    @Test
    fun searchEveryFolderFromLocationsAndShowInFolder() {
        val m = model()
        m.open()
        m.apply(reply("""{"op":"state","state":"ready","roots":[{"id":"r1","name":"Projects"},{"id":"r2","name":"Photos"}]}"""))
        m.setQuery("rea")
        m.setQuery("readme")
        runTimers()
        val searches = sent.filter { it["op"]?.jsonPrimitive?.content == "search" }
        assertEquals("typing is debounced", 1, searches.size)
        assertEquals("r1", searches[0]["root"]!!.jsonPrimitive.content)
        m.apply(reply("""{"op":"search","ok":true,"root":"r1","q":"readme","req":${searches[0].req()},"complete":true,
            "entries":[{"name":"readme.txt","dir":false,"kind":"text","in":["App","docs"]}]}"""))
        val second = last("search")
        assertEquals("then the next folder", "r2", second["root"]!!.jsonPrimitive.content)
        m.apply(reply("""{"op":"search","ok":true,"root":"r2","q":"readme","req":${second.req()},"complete":false,"entries":[]}"""))
        assertFalse(m.ui.value.searching)
        assertFalse(m.ui.value.searchComplete)
        assertEquals("r1", m.ui.value.results.single().root)
        m.showInFolder(m.ui.value.results.single())
        assertEquals(RemoteFilesLocation.Folder("r1", listOf("App", "docs")), m.ui.value.location)
        assertEquals("readme.txt", m.ui.value.highlighted)
        assertEquals("", m.ui.value.query)
    }

    @Test
    fun previewThumbnailsAndOpen() {
        val m = model()
        m.open()
        m.apply(reply("""{"op":"state","state":"ready","roots":[{"id":"r1","name":"Projects"}]}"""))
        val note = RemoteFileEntry("notes.md", false, RemoteFileKind.Text)
        m.openEntry(note)
        val p = last("preview")
        assertEquals(listOf("notes.md"), p.strings("path"))
        m.apply(reply("""{"op":"preview","ok":true,"root":"r1","path":["notes.md"],"req":${p.req()},"text":"# Hi"}"""))
        assertEquals(RemotePreviewContent.Text("# Hi", false), m.ui.value.preview?.content)
        m.closePreview()
        val count = sent.size
        m.showPreview(note)
        assertEquals("seen before: no second request", count, sent.size)

        m.wantThumbnail(RemoteFileEntry("a.png", false, RemoteFileKind.Image))
        m.wantThumbnail(RemoteFileEntry("b.pdf", false, RemoteFileKind.Pdf))
        m.wantThumbnail(RemoteFileEntry("c.zip", false, RemoteFileKind.Archive))
        runTimers()
        val thumbs = sent.filter { it["op"]?.jsonPrimitive?.content == "thumbs" }
        assertEquals(1, thumbs.size)
        assertEquals(listOf("a.png", "b.pdf"), thumbs[0].strings("names"))
        m.apply(reply("""{"op":"thumb","ok":true,"root":"r1","path":[],"name":"a.png","jpeg":"AAAA"}"""))
        assertEquals("AAAA", m.ui.value.thumbnails["r1//a.png"])

        val before = sent.size
        m.openOnMac(note)
        assertEquals("no control: nothing sent", before, sent.size)
        assertEquals(RemoteFilesNotice.NeedsControl, m.ui.value.notice)
        control = true
        m.openOnMac(note, app = "com.apple.TextEdit")
        val open = last("open")
        assertEquals(listOf("notes.md"), open.strings("path"))
        assertEquals("com.apple.TextEdit", open["with"]!!.jsonPrimitive.content)
        m.apply(reply("""{"op":"open","ok":true}"""))
        assertEquals(RemoteFilesNotice.Opened("notes.md"), m.ui.value.notice)
    }

    @Test
    fun parsingIsBounded() {
        val long = "x".repeat(5000)
        val r = reply("""{"op":"list","ok":true,"root":"$long","entries":[{"name":"$long","dir":false,"kind":"nonsense"},{"dir":true}],
            "jpeg":"${"A".repeat(RemoteFilesWire.MAX_BASE64 + 4)}"}""")
        assertEquals(64, r.root?.length)
        assertEquals(1, r.entries.size)
        assertEquals(255, r.entries[0].name.length)
        assertEquals(RemoteFileKind.File, r.entries[0].kind)
        assertNull(r.jpegBase64)
        assertNull(RemoteFilesReply.parse(Json.parseToJsonElement("""{"ok":true}""").jsonObject))
    }

    @Test
    fun namesThatCouldLeaveTheirFolderAreDropped() {
        val r = reply("""{"op":"list","ok":true,"entries":[{"name":".."},{"name":"."},{"name":"a/b"},{"name":"../../x"},
            {"name":"nul\u0000x"},{"name":""},{"name":"ok.txt"},{"name":"..hidden"}]}""")
        assertEquals(listOf("ok.txt", "..hidden"), r.entries.map { it.name })
        assertFalse(RemoteFilesReply.isSafeName("a\u0000"))
        assertTrue(RemoteFilesReply.isSafeName("a\\b"))
    }
}
