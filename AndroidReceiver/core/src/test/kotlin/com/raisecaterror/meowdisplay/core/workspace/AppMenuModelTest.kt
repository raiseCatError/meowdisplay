package com.raisecaterror.meowdisplay.core.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Pane menus on the receiver (AppMenu.kt), the same cases as iOS AppMenuTests. */
class AppMenuModelTest {
    private val sent = mutableListOf<JsonObject>()
    private fun reply(json: String) = AppMenuReply.parse(Json.parseToJsonElement(json).jsonObject)
    private fun JsonObject.req() = this["req"]!!.jsonPrimitive.int
    private fun JsonObject.ints(k: String) = this[k]!!.jsonArray.map { it.jsonPrimitive.int }

    @Test
    fun barFollowsTheFocusedPaneAndPressesWithTitles() {
        val m = AppMenuModel(send = { sent += it; true }, scheduler = { _, _ -> {} })
        m.setAvailable(true)
        assertTrue("on by default", m.ui.value.barShown)
        m.sync("w1", "dev.zed.Zed", enabled = false)
        assertTrue("no control: nothing is read", sent.isEmpty())
        m.sync("w1", "dev.zed.Zed", enabled = true)
        assertEquals("menuRequest", sent.last()["type"]!!.jsonPrimitive.content)
        assertEquals(emptyList<Int>(), sent.last().ints("path"))
        m.sync("w1", "dev.zed.Zed", enabled = true)
        assertEquals("same pane, same app: no new request", 1, sent.size)
        m.apply(reply("""{"type":"menu","tile":"w1","path":[],"app":"Zed","req":${sent.last().req()},"items":[{"i":1,"t":"Zed","sub":true},{"i":2,"t":"File","sub":true}]}"""))
        assertEquals("Zed", m.ui.value.app)
        assertEquals(listOf("Zed", "File"), m.ui.value.top.map { it.title })

        m.openMenu(m.ui.value.top[1])
        assertEquals(listOf(2), sent.last().ints("path"))
        m.apply(reply("""{"type":"menu","tile":"w1","path":[2],"req":${sent.last().req()},"items":[{"i":0,"t":"New File","key":"⌘N"},{"i":1,"sep":true},
            {"i":2,"t":"Open Recent","sub":true},{"i":3,"t":"Save","on":false}]}"""))
        val level = m.ui.value.open.last()
        assertEquals(4, level.items.size)
        assertEquals("⌘N", level.items[0].shortcut)
        assertTrue(level.items[1].separator)
        val before = sent.size
        m.press(level.items[3])
        assertEquals("a disabled item is never pressed", before, sent.size)
        m.openSubmenu(level.items[2])
        assertEquals(listOf(2, 2), sent.last().ints("path"))
        m.apply(reply("""{"type":"menu","tile":"w1","path":[2,2],"req":${sent.last().req()},"items":[{"i":0,"t":"notes.md"}]}"""))
        m.press(m.ui.value.open.last().items[0])
        assertEquals("menuPress", sent.last()["type"]!!.jsonPrimitive.content)
        assertEquals(listOf(2, 2, 0), sent.last().ints("path"))
        assertEquals(listOf("File", "Open Recent", "notes.md"), sent.last()["titles"]!!.jsonArray.map { it.jsonPrimitive.content })
        assertTrue("the drop-down closes", m.ui.value.open.isEmpty())

        m.sync("w2", "com.google.Chrome", enabled = true)
        assertTrue(m.ui.value.top.isEmpty())
        assertEquals("w2", sent.last()["tile"]!!.jsonPrimitive.content)
        m.apply(reply("""{"type":"menu","tile":"w1","path":[],"app":"Zed","items":[{"i":1,"t":"Zed"}]}"""))
        assertTrue("a late answer for the old pane is ignored", m.ui.value.top.isEmpty())
        m.setAvailable(false)
        assertNull(m.ui.value.tile)
    }
}
