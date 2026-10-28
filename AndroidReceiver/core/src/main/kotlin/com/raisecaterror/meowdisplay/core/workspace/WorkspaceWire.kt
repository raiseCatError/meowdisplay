package com.raisecaterror.meowdisplay.core.workspace

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

// Window workspaces on the wire (PROTOCOL.md 6.10). The Mac is authoritative:
// it lists windows, accepts or rejects tiles and reports focus. Nothing here
// is trusted for identity; ids only select among what the Mac itself listed.

object WorkspaceWire {
    const val VERSION = 1
    const val WELCOME_FEATURE = "window"

    const val CATALOG_REQUEST = "windowCatalogRequest"
    const val CATALOG = "windowCatalog"
    const val THUMBNAIL_REQUEST = "windowThumbnailRequest"
    const val THUMBNAIL = "windowThumbnail"
    const val APP_ICON = "appIcon"
    const val WORKSPACE_REQUEST = "workspaceRequest"
    const val WORKSPACE_FOCUS = "workspaceFocus"
    const val WORKSPACE_STATE = "workspaceState"
    const val WINDOW_ACTION = "windowAction"

    /** Bounds on what the receiver keeps from the Mac (sizes are on the wire already bounded by the Mac). */
    const val MAX_WINDOWS = 120
    const val MAX_APPS = 60
    const val MAX_INSTALLED = 150
    const val MAX_THUMBNAIL_BASE64 = 96 * 1024

    fun catalogRequest(installed: Boolean = false) = buildJsonObject { put("type", CATALOG_REQUEST); if (installed) put("installed", true) }

    fun thumbnailRequest(ids: List<Long>, maxWidth: Int, icons: List<String> = emptyList()) = buildJsonObject {
        put("type", THUMBNAIL_REQUEST)
        put("ids", buildJsonArray { ids.take(24).forEach { add(JsonPrimitive(it)) } })
        put("max", maxWidth)
        if (icons.isNotEmpty()) put("icons", buildJsonArray { icons.take(32).forEach { add(JsonPrimitive(it)) } })
    }

    /** The tiles this host shows, at their normalized frames. Tiles of other hosts are not sent here. */
    fun workspaceRequest(layout: WLayout, frames: WFrames, host: String, focus: String?) = buildJsonObject {
        put("type", WORKSPACE_REQUEST)
        put("tiles", buildJsonArray {
            for (id in layout.orderedTileIDs) {
                val tile = layout.tiles[id] ?: continue
                val source = tile.source ?: continue
                if (source.host != host) continue
                val r = frames.tiles[id] ?: continue
                if (r.width <= 0 || r.height <= 0) continue
                add(buildJsonObject {
                    put("id", id); put("host", host)
                    put("x", r.x); put("y", r.y); put("w", r.width); put("h", r.height)
                    put("window", source.windowID)
                    source.generation?.let { put("gen", it) }
                    put("follow", source.follow.wire)
                    put("rotation", tile.rotation.degrees)
                    put("fit", tile.fit.wire)
                })
            }
        })
        focus?.let { put("focus", it) }
    }

    fun focus(tile: String?) = buildJsonObject { put("type", WORKSPACE_FOCUS); tile?.let { put("tile", it) } }

    fun activate(windowID: Long, generation: Long?) = action("activate") { put("window", windowID); generation?.let { put("gen", it) } }
    fun launch(bundleID: String) = action("launch") { put("bundle", bundleID) }
    /** Closes the real Mac window. Only ever from an explicit, separate action. */
    fun closeRemoteWindow(windowID: Long, generation: Long) = action("close") { put("window", windowID); put("gen", generation) }

    private fun action(name: String, body: kotlinx.serialization.json.JsonObjectBuilder.() -> Unit) = buildJsonObject {
        put("type", WINDOW_ACTION); put("action", name); body()
    }
}

enum class WindowAvailability(val wire: String) { Visible("visible"), Offscreen("offscreen");
    companion object { fun of(s: String?) = entries.firstOrNull { it.wire == s } ?: Visible }
}

data class CatalogWindow(
    val id: Long, val generation: Long, val bundleID: String, val app: String, val title: String,
    val width: Int, val height: Int, val availability: WindowAvailability, val active: Boolean,
)

data class CatalogApp(val bundleID: String, val name: String, val hasWindows: Boolean)
data class InstalledApp(val bundleID: String, val name: String)

data class WindowCatalog(val host: String?, val windows: List<CatalogWindow>, val apps: List<CatalogApp>, val installed: List<InstalledApp>, val unavailable: Boolean) {
    /** Windows grouped by app, apps in catalog order. */
    val byApp: List<Pair<String, List<CatalogWindow>>> get() = windows.groupBy { it.bundleID }.map { (_, w) -> w.first().app to w }

    fun search(query: String): List<CatalogWindow> {
        val q = query.trim()
        if (q.isEmpty()) return windows
        return windows.filter { it.title.contains(q, ignoreCase = true) || it.app.contains(q, ignoreCase = true) }
    }

    companion object {
        fun parse(obj: JsonObject): WindowCatalog {
            val windows = obj.arrayOrEmpty("windows").objects().take(WorkspaceWire.MAX_WINDOWS).mapNotNull { w ->
                val id = w.long("id") ?: return@mapNotNull null
                CatalogWindow(
                    id, w.long("gen") ?: 0, w.str("bundle") ?: return@mapNotNull null, w.str("app")?.take(80) ?: "",
                    w.str("title")?.take(160) ?: "", w.int("w") ?: 0, w.int("h") ?: 0,
                    WindowAvailability.of(w.str("state")), w.bool("active") == true,
                )
            }
            val apps = obj.arrayOrEmpty("apps").objects().take(WorkspaceWire.MAX_APPS).mapNotNull { a ->
                CatalogApp(a.str("bundle") ?: return@mapNotNull null, a.str("name")?.take(80) ?: "", a.bool("windows") == true)
            }
            val installed = obj.arrayOrEmpty("installed").objects().take(WorkspaceWire.MAX_INSTALLED).mapNotNull { a ->
                InstalledApp(a.str("bundle") ?: return@mapNotNull null, a.str("name")?.take(80) ?: "")
            }
            return WindowCatalog(obj.str("host"), windows, apps, installed, obj.str("error") != null)
        }
    }
}

/** A tile as the Mac accepted it. */
data class RemoteTileState(val id: String, val windowID: Long, val generation: Long, val state: TileStatus, val app: String, val bundleID: String, val title: String)

enum class TileStatus(val wire: String) {
    Live("live"), Waiting("waiting"), Offscreen("offscreen"), Closed("closed"), Failed("failed"), Limit("limit");
    companion object { fun of(s: String?) = entries.firstOrNull { it.wire == s } ?: Waiting }
}

enum class HostFocus(val wire: String) {
    Deliver("deliver"), NoActiveTile("noActiveTile"), HostFocusElsewhere("hostFocusElsewhere"), OtherWindowFocused("otherWindowFocused");
    val isMismatch get() = this == HostFocusElsewhere || this == OtherWindowFocused
    companion object { fun of(s: String?) = entries.firstOrNull { it.wire == s } ?: NoActiveTile }
}

data class WorkspaceState(
    val host: String?, val tiles: List<RemoteTileState>, val active: String?, val hostFocus: HostFocus,
    val rejected: Map<String, String>, val limit: Int,
) {
    companion object {
        fun parse(obj: JsonObject): WorkspaceState {
            val tiles = obj.arrayOrEmpty("tiles").objects().take(WLayout.MAXIMUM_TILES).mapNotNull { t ->
                RemoteTileState(
                    t.str("id") ?: return@mapNotNull null, t.long("window") ?: 0, t.long("gen") ?: 0, TileStatus.of(t.str("state")),
                    t.str("app")?.take(80) ?: "", t.str("bundle") ?: "", t.str("title")?.take(120) ?: "",
                )
            }
            val rejected = (obj["rejected"] as? JsonObject)?.entries?.take(32)?.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.takeIf { it.isString }?.content?.let { k to it } }?.toMap() ?: emptyMap()
            return WorkspaceState(obj.str("host"), tiles, obj.str("active"), HostFocus.of(obj.str("hostFocus")), rejected, obj.int("limit") ?: WLayout.MAXIMUM_TILES)
        }
    }
}

data class WindowThumbnail(val windowID: Long, val generation: Long, val jpegBase64: String?) {
    companion object {
        fun parse(obj: JsonObject): WindowThumbnail? {
            val id = obj.long("id") ?: return null
            val jpeg = obj.str("jpeg")?.takeIf { it.length <= WorkspaceWire.MAX_THUMBNAIL_BASE64 }
            return WindowThumbnail(id, obj.long("gen") ?: 0, jpeg)
        }
    }
}

data class AppIcon(val bundleID: String, val pngBase64: String) {
    companion object {
        fun parse(obj: JsonObject): AppIcon? {
            val png = obj.str("png")?.takeIf { it.length <= WorkspaceWire.MAX_THUMBNAIL_BASE64 } ?: return null
            return AppIcon(obj.str("bundle") ?: return null, png)
        }
    }
}

private fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonObject.long(k: String): Long? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.longOrNull
private fun JsonObject.int(k: String): Int? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull
private fun JsonObject.bool(k: String): Boolean? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
