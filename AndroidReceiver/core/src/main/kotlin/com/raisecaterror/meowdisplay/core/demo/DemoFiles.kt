package com.raisecaterror.meowdisplay.core.demo

import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesWire
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/**
 * Remote Finder against the demo Mac: a small, fixed, made-up folder tree, answered with the
 * real wire (PROTOCOL.md 6.12). Its owner allows browsing at once; nothing is read from anywhere.
 */
internal object DemoFiles {
    private class Node(val name: String, val kind: String, val size: Long = 0, val mod: Long = 1_761_700_000, val text: String? = null,
                       val children: List<Node> = emptyList()) {
        val dir get() = kind == "folder"
    }

    private val roots = listOf(
        "demo-documents" to Node("Documents", "folder", children = listOf(
            Node("Notes", "folder", children = listOf(
                Node("Ideas.md", "text", 412, text = "# Ideas\n\n- Put the editor and the browser side by side\n- Pinch a pane to zoom just that window\n- Hold a divider to resize\n"),
                Node("Groceries.txt", "text", 96, text = "Oat milk\nCoffee beans\nBasil\nTomatoes\n"),
            )),
            Node("Beach.jpg", "image", 1_428_000),
            Node("Budget 2026.numbers", "document", 312_000),
            Node("Trip Itinerary.pdf", "pdf", 845_000),
            Node("Welcome.txt", "text", 210, text = "Welcome to the demo Mac.\n\nThis is a read-only view of folders its owner approved. Nothing here is real, and nothing on a Mac changes.\n"),
        )),
        "demo-projects" to Node("Projects", "folder", children = listOf(
            Node("MeowDisplay", "folder", children = listOf(
                Node("README.md", "text", 1_204, text = "# MeowDisplay\n\nUse a phone or tablet as a display for a Mac.\n"),
                Node("Sources", "folder", children = listOf(Node("App.swift", "text", 2_048, text = "import SwiftUI\n\n@main\nstruct App: SwiftUI.App {\n    var body: some Scene { WindowGroup { Text(\"Hello\") } }\n}\n"))),
            )),
            Node("Logo.png", "image", 64_000),
            Node("Archive.zip", "archive", 9_800_000),
        )),
    )

    /** A small sunset over the sea (96×64 JPEG). */
    private const val PICTURE = "/9j/4AAQSkZJRgABAQAASABIAAD/4QBMRXhpZgAATU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAYKADAAQAAAABAAAAQAAAAAD/7QA4UGhvdG9zaG9wIDMuMAA4QklNBAQAAAAAAAA4QklNBCUAAAAAABDUHYzZjwCyBOmACZjs+EJ+/8AAEQgAQABgAwEiAAIRAQMRAf/EAB8AAAEFAQEBAQEBAAAAAAAAAAABAgMEBQYHCAkKC//EALUQAAIBAwMCBAMFBQQEAAABfQECAwAEEQUSITFBBhNRYQcicRQygZGhCCNCscEVUtHwJDNicoIJChYXGBkaJSYnKCkqNDU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6g4SFhoeIiYqSk5SVlpeYmZqio6Slpqeoqaqys7S1tre4ubrCw8TFxsfIycrS09TV1tfY2drh4uPk5ebn6Onq8fLz9PX29/j5+v/EAB8BAAMBAQEBAQEBAQEAAAAAAAABAgMEBQYHCAkKC//EALURAAIBAgQEAwQHBQQEAAECdwABAgMRBAUhMQYSQVEHYXETIjKBCBRCkaGxwQkjM1LwFWJy0QoWJDThJfEXGBkaJicoKSo1Njc4OTpDREVGR0hJSlNUVVZXWFlaY2RlZmdoaWpzdHV2d3h5eoKDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uLj5OXm5+jp6vLz9PX29/j5+v/bAEMABAQEBAQEBgQEBgkGBgYJDAkJCQkMDwwMDAwMDxIPDw8PDw8SEhISEhISEhUVFRUVFRkZGRkZHBwcHBwcHBwcHP/bAEMBBAUFBwcHDAcHDB0UEBQdHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHR0dHf/dAAQABv/aAAwDAQACEQMRAD8A92xRipMUYr8j9gfqP1kjxRipMUYo9gH1kjxRipMUYo9gH1kjxRipMUoUsQAMk8ACj2AfWSLFGK6KPSItv71yW/2eB+uap3un/Zl82Mlkzgg9RXDCvRnPki9SVi1exk4oxUmKMV3ewK+sn//Q9+xRipMUYr4H2B9T9ZI8UYqTFGKPYB9ZI8UYqTFGKPYB9ZI8VLAVSaN24CsCfwNJijFKWHummH1k66qOosBaMD/EQB+ef6VkJdXMa7UkOB64P86jlklmO6Vi1fN0MjqwrKUpKyd/Mt4qNtCtijFSYoxX0vsCPrJ//9HpP+Frn/oFf+R//tdH/C1z/wBAr/yP/wDa68s8n2o8n2r9B/1dyv8A58/jL/M/Nv8AWHHf8/PwX+R6n/wtc/8AQK/8j/8A2uj/AIWuf+gV/wCR/wD7XXlnk+1Hk+1H+ruV/wDPn8Zf5h/rDjv+fn4L/I9T/wCFrn/oFf8Akf8A+10f8LXP/QK/8j//AGuvLPJ9qPJ9qP8AV3K/+fP4y/zD/WHHf8/PwX+R6n/wtc/9Ar/yP/8Aa6P+Frn/AKBX/kf/AO115Z5PtR5PtR/q7lf/AD5/GX+Yf6w47/n5+C/yPU/+Frn/AKBX/kf/AO10f8LXP/QK/wDI/wD9rryzyfajyfaj/V3K/wDnz+Mv8w/1hx3/AD8/Bf5Hqf8Awtc/9Ar/AMj/AP2uj/ha5/6BX/kf/wC115Z5PtR5PtR/q7lf/Pn8Zf5h/rDjv+fn4L/I/9LD8qjyq0/K9qPK9q/Ufan4D7YzPKo8qtPyvajyvaj2oe2MzyqPKrT8r2o8r2o9qHtjM8qjyq0/K9qPK9qPah7YzPKo8qtPyvajyvaj2oe2MzyqPKrT8r2o8r2o9qHtj//Z"

    /** Replies to one request; [opened] reports a file opened on the demo Mac. */
    fun answer(obj: JsonObject, inputGranted: Boolean, opened: (String) -> Unit): List<JsonObject> {
        val op = obj.s("op") ?: return emptyList()
        val req = (obj["req"] as? JsonPrimitive)?.intOrNull
        fun reply(body: JsonObjectBuilder.() -> Unit) = buildJsonObject { put("type", RemoteFilesWire.REPLY); put("op", op); req?.let { put("req", it) }; body() }
        fun error(code: String) = listOf(reply { put("ok", false); put("error", code) })
        val rootID = obj.s("root")
        val root = roots.firstOrNull { it.first == rootID }?.second
        val path = (obj["path"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.content }.orEmpty()
        fun find(): Node? = path.fold(root as Node?) { n, c -> n?.children?.firstOrNull { it.name == c } }
        return when (op) {
            "state" -> listOf(reply {
                put("state", "ready")
                put("roots", buildJsonArray { roots.forEach { (id, n) -> add(buildJsonObject { put("id", id); put("name", n.name) }) } })
                // The demo Mac lets you look around only: nothing is copied or changed.
                put("grant", buildJsonObject {
                    put("duration", "session"); put("scope", "selectedFolders"); put("caps", buildJsonArray { add(JsonPrimitive("browse")) })
                })
            })
            "list" -> {
                val dir = find()?.takeIf { it.dir } ?: return error("notFound")
                listOf(reply {
                    put("ok", true); put("root", rootID!!); put("path", names(path))
                    put("entries", buildJsonArray { dir.children.forEach { add(entry(it)) } })
                })
            }
            "search" -> {
                val start = find()?.takeIf { it.dir } ?: return error("notFound")
                val q = obj.s("q")?.trim().orEmpty()
                if (q.isEmpty()) return error("badQuery")
                val hits = mutableListOf<Pair<Node, List<String>>>()
                walkInto(start, path, hits, q)
                listOf(reply {
                    put("ok", true); put("root", rootID!!); put("q", q); put("complete", true)
                    put("entries", buildJsonArray { hits.forEach { (n, at) -> add(entry(n) { put("in", names(at)) }) } })
                })
            }
            "preview" -> {
                val n = find()?.takeIf { !it.dir } ?: return error("notFound")
                listOf(reply {
                    put("root", rootID!!); put("path", names(path))
                    when {
                        n.text != null -> { put("ok", true); put("text", n.text) }
                        n.kind == "image" -> { put("ok", true); put("jpeg", PICTURE); put("w", 96); put("h", 64) }
                        else -> { put("ok", false); put("error", "noPreview") }
                    }
                })
            }
            "thumbs" -> {
                val dir = find()?.takeIf { it.dir } ?: return error("notFound")
                (obj["names"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.content }.take(48).map { name ->
                    val n = dir.children.firstOrNull { it.name == name }
                    buildJsonObject {
                        put("type", RemoteFilesWire.REPLY); put("op", "thumb"); put("root", rootID!!); put("path", names(path)); put("name", name)
                        if (n?.kind == "image") { put("ok", true); put("jpeg", PICTURE); put("w", 96); put("h", 64) } else put("ok", false)
                    }
                }
            }
            "open" -> {
                if (!inputGranted) return error("control")
                val n = find()?.takeIf { path.isNotEmpty() } ?: return error("notFound")
                opened(n.name)
                listOf(reply { put("ok", true) })
            }
            else -> error("unsupported")
        }
    }

    private fun walkInto(n: Node, at: List<String>, hits: MutableList<Pair<Node, List<String>>>, q: String) {
        n.children.forEach { c -> if (c.name.contains(q, ignoreCase = true)) hits += c to at; if (c.dir) walkInto(c, at + c.name, hits, q) }
    }

    private fun entry(n: Node, more: JsonObjectBuilder.() -> Unit = {}) = buildJsonObject {
        put("name", n.name); put("dir", n.dir); put("kind", n.kind)
        if (!n.dir) put("size", n.size)
        put("mod", n.mod)
        more()
    }

    private fun names(list: List<String>) = buildJsonArray { list.forEach { add(JsonPrimitive(it)) } }
    private fun JsonObject.s(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
}
