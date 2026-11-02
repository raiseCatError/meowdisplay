package com.raisecaterror.meowdisplay.core.demo

import com.raisecaterror.meowdisplay.core.workspace.AppMenuWire
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/**
 * Pane menus against the demo Mac (PROTOCOL.md 6.13): a small fixed menu bar per sample app,
 * answered with the real wire. Pressing an item only says so; nothing else changes.
 */
internal object DemoMenus {
    private class Item(val title: String, val key: String? = null, val enabled: Boolean = true, val checked: Boolean = false,
                       val sub: List<Item>? = null) {
        val separator get() = title.isEmpty()
    }

    private val sep = Item("")

    private fun bar(app: String) = listOf(
        Item("Apple", sub = listOf(Item("About This Mac"))),   // index 0: never sent, as on a real Mac
        Item(app, sub = listOf(Item("About $app"), sep, Item("Hide $app", "⌘H"), Item("Quit $app", "⌘Q", enabled = false))),
        Item("File", sub = listOf(Item("New", "⌘N"), Item("Open…", "⌘O"), Item("Open Recent", sub = listOf(Item("Groceries.txt"), Item("Ideas.md"))),
            sep, Item("Close Window", "⌘W"), Item("Save", "⌘S"))),
        Item("Edit", sub = listOf(Item("Undo", "⌘Z"), Item("Redo", "⇧⌘Z", enabled = false), sep, Item("Cut", "⌘X"), Item("Copy", "⌘C"),
            Item("Paste", "⌘V"), Item("Select All", "⌘A"))),
        Item("View", sub = listOf(Item("Show Sidebar", checked = true), Item("Show Toolbar", checked = true), sep,
            Item("Zoom In", "⌘+"), Item("Zoom Out", "⌘−"))),
        Item("Window", sub = listOf(Item("Minimize", "⌘M"), Item("Zoom"), sep, Item("Bring All to Front"))),
        Item("Help", sub = listOf(Item("$app Help"))),
    )

    /** The reply to a menuRequest for a pane showing [app], or a press result. [pressed] reports a press. */
    fun answer(obj: JsonObject, app: String?, inputGranted: Boolean, pressed: (String) -> Unit): JsonObject {
        val type = (obj["type"] as? JsonPrimitive)?.content
        val req = (obj["req"] as? JsonPrimitive)?.intOrNull
        val tile = (obj["tile"] as? JsonPrimitive)?.content
        val path = (obj["path"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.intOrNull }.orEmpty()
        if (type == AppMenuWire.PRESS) {
            val titles = (obj["titles"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty()
            val ok = inputGranted && app != null && path.size >= 2 && path.size == titles.size && path[0] >= 1 && run {
                var level = bar(app)
                var item: Item? = null
                for ((d, i) in path.withIndex()) {
                    item = level.getOrNull(i)?.takeIf { it.title == titles[d] } ?: return@run false
                    level = item.sub.orEmpty()
                }
                item != null && item.sub == null && item.enabled
            }
            if (ok) pressed(titles.joinToString(" › "))
            return buildJsonObject {
                put("type", AppMenuWire.RESULT); put("ok", ok); if (!ok) put("error", if (inputGranted) "changed" else "control"); req?.let { put("req", it) }
            }
        }
        fun error(code: String) = buildJsonObject {
            put("type", AppMenuWire.MENU); put("ok", false); put("error", code); tile?.let { put("tile", it) }
            put("path", buildJsonArray { path.forEach { add(JsonPrimitive(it)) } }); req?.let { put("req", it) }
        }
        if (!inputGranted) return error("control")
        if (app == null) return error("notFound")
        val all = bar(app)
        val level: List<Item> = if (path.isEmpty()) all else {
            if (path[0] < 1) return error("notFound")
            path.fold(all as List<Item>?) { l, i -> l?.getOrNull(i)?.sub } ?: return error("notFound")
        }
        return buildJsonObject {
            put("type", AppMenuWire.MENU); put("ok", true); put("tile", tile ?: ""); put("app", app)
            put("path", buildJsonArray { path.forEach { add(JsonPrimitive(it)) } }); req?.let { put("req", it) }
            put("items", buildJsonArray {
                level.forEachIndexed { i, item ->
                    if (path.isEmpty() && i == 0) return@forEachIndexed
                    add(buildJsonObject {
                        put("i", i)
                        if (item.separator) put("sep", true) else {
                            put("t", item.title)
                            if (!item.enabled) put("on", false)
                            if (item.checked) put("mark", true)
                            if (item.sub != null) put("sub", true)
                            item.key?.let { put("key", it) }
                        }
                    })
                }
            })
        }
    }
}
