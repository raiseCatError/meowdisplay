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
    const val APP_CATALOG_REQUEST = "appCatalogRequest"
    const val APP_CATALOG = "appCatalog"
    const val APP_LAUNCH = "appLaunch"
    const val APP_LAUNCH_RESULT = "appLaunchResult"
    /** Close Window from Stage Peek (PROTOCOL.md 6.10): any display mode, control only. */
    const val CLOSE_FEATURE = "windowClose"
    const val WINDOW_CLOSE = "windowClose"
    const val WINDOW_CLOSE_RESULT = "windowCloseResult"
    const val DISPLAY_THUMBNAIL = "displayThumbnail"
    /** Mac -> receiver: `{tiles: {id: view epoch}}` once a frame with that pane view went out. */
    const val WORKSPACE_VIEW = "workspaceView"
    /** Receiver -> Mac: `{tile}`: start that pane's capture again now. */
    const val WORKSPACE_RETRY = "workspaceRetry"
    /** Receiver -> Mac: `{tile, max, req}`: the pane's whole source as a still, for the instant zoom. */
    const val WORKSPACE_BACKDROP_REQUEST = "workspaceBackdropRequest"
    const val WORKSPACE_BACKDROP = "workspaceBackdrop"
    /** A pane's whole-source still: the Mac keeps it under this (inside the 1 MiB control-message limit). */
    const val MAX_BACKDROP_BASE64 = 700_000
    const val MAX_MAC_APPS = 900

    /** Bounds on what the receiver keeps from the Mac (sizes are on the wire already bounded by the Mac). */
    const val MAX_WINDOWS = 120
    const val MAX_APPS = 60
    const val MAX_INSTALLED = 150
    const val MAX_THUMBNAIL_BASE64 = 256 * 1024   // a sharp 640-wide Stage Peek still

    fun catalogRequest(installed: Boolean = false) = buildJsonObject { put("type", CATALOG_REQUEST); if (installed) put("installed", true) }

    fun thumbnailRequest(ids: List<Long>, maxWidth: Int, icons: List<String> = emptyList(), displays: List<Long> = emptyList()) = buildJsonObject {
        put("type", THUMBNAIL_REQUEST)
        put("ids", buildJsonArray { ids.take(24).forEach { add(JsonPrimitive(it)) } })
        put("max", maxWidth)
        if (icons.isNotEmpty()) put("icons", buildJsonArray { icons.take(48).forEach { add(JsonPrimitive(it)) } })
        if (displays.isNotEmpty()) put("displays", buildJsonArray { displays.take(8).forEach { add(JsonPrimitive(it)) } })
    }

    /** Every launchable Mac app; `rev` lets the Mac answer "same". Read-only, any display mode. */
    fun appCatalogRequest(revision: Int?) = buildJsonObject { put("type", APP_CATALOG_REQUEST); revision?.let { put("rev", it) } }
    /** Opens an app on the Mac without activating it. The Mac refuses it without control. */
    fun appLaunch(bundleID: String) = buildJsonObject { put("type", APP_LAUNCH); put("bundle", bundleID) }
    /** Presses that listed window's own close button on the Mac (never Quit). Needs control. */
    fun windowClose(windowID: Long, generation: Long, req: Int) = buildJsonObject {
        put("type", WINDOW_CLOSE); put("window", windowID); put("gen", generation); put("req", req)
    }

    /** The tiles this host shows, at their normalized frames. Tiles of other hosts are not sent here. */
    fun workspaceRequest(layout: WLayout, frames: WFrames, host: String, focus: String?, displayID: (WSource) -> Long? = { null },
                         viewEpoch: (String) -> Int? = { null }) = buildJsonObject {
        put("type", WORKSPACE_REQUEST)
        put("tiles", buildJsonArray {
            for (id in layout.orderedTileIDs) {
                val tile = layout.tiles[id] ?: continue
                val source = tile.source ?: continue
                if (source.host != host) continue
                val r = frames.tiles[id] ?: continue
                if (r.width <= 0 || r.height <= 0) continue
                // A whole display goes by its real display id; one no longer listed isn't sent.
                val display = if (source.isDisplay) displayID(source) ?: continue else null
                add(buildJsonObject {
                    put("id", id); put("host", host)
                    put("x", r.x); put("y", r.y); put("w", r.width); put("h", r.height)
                    if (display != null) {
                        put("display", display)
                    } else {
                        put("window", source.windowID)
                        source.generation?.let { put("gen", it) }
                    }
                    put("follow", source.follow.wire)
                    put("rotation", tile.rotation.degrees)
                    put("fit", tile.fit.wire)
                    // Never a capture crop: the Mac captures the whole source and composes the zoom.
                    tile.zoom?.let { z -> put("zoom", buildJsonArray { z.wire.forEach { add(JsonPrimitive(it)) } }) }
                    viewEpoch(id)?.let { put("view", it) }
                })
            }
        })
        focus?.let { put("focus", it) }
    }

    fun focus(tile: String?) = buildJsonObject { put("type", WORKSPACE_FOCUS); tile?.let { put("tile", it) } }

    fun retry(tile: String) = buildJsonObject { put("type", WORKSPACE_RETRY); put("tile", tile) }
    fun backdrop(tile: String, max: Int, req: Int) = buildJsonObject { put("type", WORKSPACE_BACKDROP_REQUEST); put("tile", tile); put("max", max); put("req", req) }

    fun activate(windowID: Long, generation: Long?) = action("activate") { put("window", windowID); generation?.let { put("gen", it) } }
    /** Owner-confirmed on the device, control only: Stage Manager off for Window mode (turned back on after). */
    fun stageManager(on: Boolean) = action("stageManager") { put("on", on) }
    /** Control only: Stage Manager's own Add to Stage on the strip item holding exactly this window. */
    fun addToStage(windowID: Long, generation: Long) = action("addToStage") { put("window", windowID); put("gen", generation) }
    fun launch(bundleID: String) = action("launch") { put("bundle", bundleID) }
    /** Minimizes the real Mac window. Only ever from its own explicit action. */
    fun minimizeRemoteWindow(windowID: Long, generation: Long) = action("minimize") { put("window", windowID); put("gen", generation) }
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
    /** In Stage Manager's side strip: macOS pauses its picture there (PROTOCOL.md §6.10). */
    val inStageStrip: Boolean = false,
) {
    /** A short card badge for a window that can't show a current picture, or null. */
    val pausedBadge: String? get() = when {
        availability == WindowAvailability.Offscreen -> "Minimized"
        inStageStrip -> "In Strip"
        else -> null
    }
    /** The same for TalkBack. */
    val pausedSpoken: String? get() = when {
        availability == WindowAvailability.Offscreen -> "minimized"
        inStageStrip -> "in Stage Manager's side strip, picture paused"
        else -> null
    }
}

data class CatalogApp(val bundleID: String, val name: String, val hasWindows: Boolean)
data class InstalledApp(val bundleID: String, val name: String)

data class WindowCatalog(val host: String?, val windows: List<CatalogWindow>, val apps: List<CatalogApp>, val installed: List<InstalledApp>, val unavailable: Boolean, val starting: Boolean = false, val displays: List<CatalogDisplay> = emptyList()) {
    /** Windows grouped by app, apps in catalog order. */
    val byApp: List<Pair<String, List<CatalogWindow>>> get() = windows.groupBy { it.bundleID }.map { (_, w) -> w.first().app to w }

    fun search(query: String): List<CatalogWindow> {
        val q = query.trim()
        if (q.isEmpty()) return windows
        return windows.filter { it.title.contains(q, ignoreCase = true) || it.app.contains(q, ignoreCase = true) }
    }

    /**
     * Tiles of [layout] whose window isn't listed, or whose id now belongs to another app: kept
     * and marked on the device, never sent. A tile given a listed window is no longer missing.
     */
    fun missingTiles(layout: WLayout): Set<String> = layout.tiles.mapNotNullTo(mutableSetOf()) { (id, tile) ->
        val source = tile.source ?: return@mapNotNullTo null
        if (source.isDisplay) return@mapNotNullTo id.takeUnless { displays.any { WSource.displayKey(it.id) == source.windowID } }
        id.takeUnless { windows.any { it.id == source.windowID && (source.bundleID == null || source.bundleID == it.bundleID) } }
    }

    companion object {
        fun parse(obj: JsonObject): WindowCatalog {
            val windows = obj.arrayOrEmpty("windows").objects().take(WorkspaceWire.MAX_WINDOWS).mapNotNull { w ->
                val id = w.long("id") ?: return@mapNotNull null
                CatalogWindow(
                    id, w.long("gen") ?: 0, w.str("bundle") ?: return@mapNotNull null, w.str("app")?.take(80) ?: "",
                    w.str("title")?.take(160) ?: "", w.int("w") ?: 0, w.int("h") ?: 0,
                    WindowAvailability.of(w.str("state")), w.bool("active") == true, w.bool("strip") == true,
                )
            }
            val apps = obj.arrayOrEmpty("apps").objects().take(WorkspaceWire.MAX_APPS).mapNotNull { a ->
                CatalogApp(a.str("bundle") ?: return@mapNotNull null, a.str("name")?.take(80) ?: "", a.bool("windows") == true)
            }
            val installed = obj.arrayOrEmpty("installed").objects().take(WorkspaceWire.MAX_INSTALLED).mapNotNull { a ->
                InstalledApp(a.str("bundle") ?: return@mapNotNull null, a.str("name")?.take(80) ?: "")
            }
            // "starting": Window mode is still starting on the Mac. It isn't a listing failure; the picker asks again.
            val displays = obj.arrayOrEmpty("displays").objects().take(8).mapNotNull { d ->
                CatalogDisplay(d.long("id") ?: return@mapNotNull null, d.str("name")?.take(80) ?: "Display", d.int("w") ?: 0, d.int("h") ?: 0,
                    d.bool("main") == true, d.bool("virtual") == true)
            }
            val error = obj.str("error")
            return WindowCatalog(obj.str("host"), windows, apps, installed, error != null && error != "starting", error == "starting", displays)
        }
    }
}

/** A tile as the Mac accepted it. */
data class RemoteTileState(
    val id: String, val windowID: Long, val generation: Long, val state: TileStatus, val app: String, val bundleID: String, val title: String,
    /** Restarts so far while [TileStatus.Retrying]. */
    val attempt: Int = 0,
    /** In Stage Manager's side strip: macOS pauses its picture. */
    val inStageStrip: Boolean = false,
)

/** A pane's capture on the Mac (RemoteTileStatus): paused by macOS, retrying after a stall, failed (Retry). */
enum class TileStatus(val wire: String) {
    Live("live"), Waiting("waiting"), Offscreen("offscreen"), Closed("closed"), Failed("failed"), Limit("limit"), Paused("paused"), Retrying("retrying");
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
    /** Stage Manager is on on the Mac (its strip pauses windows). */
    val stageManager: Boolean = false,
    /**
     * Whether the Mac can switch it: "ready", "setup" (the owner hasn't made the two shortcuts on the
     * Mac yet) or "failed" (macOS didn't apply the last change). null: an older Mac, never offered.
     */
    val stageManagerControl: String? = null,
    /** The last Add to Current Stage (for 8 s): window id and "added", "notInStrip", "ambiguous", "accessibility" or "failed". */
    val stageAdd: Pair<Long, String>? = null,
    /** The Mac can add a strip window to the current stage (off until it is shown to work). */
    val stageAddAvailable: Boolean = false,
) {
    companion object {
        fun parse(obj: JsonObject): WorkspaceState {
            val tiles = obj.arrayOrEmpty("tiles").objects().take(WLayout.MAXIMUM_TILES).mapNotNull { t ->
                RemoteTileState(
                    t.str("id") ?: return@mapNotNull null, t.long("window") ?: 0, t.long("gen") ?: 0, TileStatus.of(t.str("state")),
                    t.str("app")?.take(80) ?: "", t.str("bundle") ?: "", t.str("title")?.take(120) ?: "",
                    (t.int("attempt") ?: 0).coerceIn(0, 99), t.bool("strip") == true,
                )
            }
            val rejected = (obj["rejected"] as? JsonObject)?.entries?.take(32)?.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.takeIf { it.isString }?.content?.let { k to it } }?.toMap() ?: emptyMap()
            return WorkspaceState(obj.str("host"), tiles, obj.str("active"), HostFocus.of(obj.str("hostFocus")), rejected, obj.int("limit") ?: WLayout.MAXIMUM_TILES,
                obj.bool("stageManager") == true, obj.str("stageManagerControl")?.take(16),
                (obj["stageAdd"] as? JsonObject)?.let { a -> a.long("window")?.let { w -> a.str("result")?.take(16)?.let { w to it } } },
                obj.bool("stageAddAvailable") == true)
        }
    }
}

data class WindowThumbnail(val windowID: Long, val generation: Long, val jpegBase64: String?, val stale: Boolean = false) {
    companion object {
        fun parse(obj: JsonObject): WindowThumbnail? {
            val id = obj.long("id") ?: return null
            val jpeg = obj.str("jpeg")?.takeIf { it.length <= WorkspaceWire.MAX_THUMBNAIL_BASE64 }
            return WindowThumbnail(id, obj.long("gen") ?: 0, jpeg, obj.bool("stale") == true)
        }
    }
}

/** Panes whose latest view the Mac has composed (`workspaceView`). */
data class WorkspaceViewEcho(val tiles: Map<String, Int>) {
    companion object {
        fun parse(obj: JsonObject): WorkspaceViewEcho = WorkspaceViewEcho(
            (obj["tiles"] as? JsonObject)?.entries?.take(WLayout.MAXIMUM_TILES * 2)
                ?.mapNotNull { (k, v) -> (v as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull?.takeIf { k.length <= 32 }?.let { k to it } }
                ?.toMap() ?: emptyMap(),
        )
    }
}

/** A pane's whole source as a still (`workspaceBackdrop`). */
data class WorkspaceBackdrop(val tile: String, val windowID: Long, val jpegBase64: String, val stale: Boolean) {
    companion object {
        fun parse(obj: JsonObject): WorkspaceBackdrop? {
            val tile = obj.str("tile")?.takeIf { it.length <= 32 } ?: return null
            val jpeg = obj.str("jpeg")?.takeIf { it.length <= WorkspaceWire.MAX_BACKDROP_BASE64 } ?: return null
            return WorkspaceBackdrop(tile, obj.long("window") ?: 0, jpeg, obj.bool("stale") == true)
        }
    }
}

data class DisplayThumbnail(val displayID: Long, val jpegBase64: String) {
    companion object {
        fun parse(obj: JsonObject): DisplayThumbnail? {
            val jpeg = obj.str("jpeg")?.takeIf { it.length <= WorkspaceWire.MAX_THUMBNAIL_BASE64 } ?: return null
            return DisplayThumbnail(obj.long("id") ?: return null, jpeg)
        }
    }
}

/** `apps` null: the receiver's revision is current. */
data class AppCatalogMessage(val revision: Int, val apps: List<MacApp>?) {
    companion object {
        fun parse(obj: JsonObject): AppCatalogMessage? {
            val rev = obj.int("rev") ?: return null
            if (obj.bool("same") == true) return AppCatalogMessage(rev, null)
            val apps = obj.arrayOrEmpty("apps").objects().take(WorkspaceWire.MAX_MAC_APPS).mapNotNull { a ->
                val b = a.str("bundle")?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                MacApp(b, a.str("name")?.take(80) ?: b, a.bool("running") == true, a.int("windows") ?: 0, a.long("used"))
            }
            return AppCatalogMessage(rev, apps)
        }
    }
}

/** What the Mac reports after `windowClose`. */
enum class WindowCloseResult(val raw: String) {
    Closed("closed"), SaveDialog("saveDialog"), StillOpen("stillOpen"), Stale("stale"),
    Control("control"), Accessibility("accessibility"), NoButton("noButton"), Ambiguous("ambiguous");

    /** The card can go: the window is closed (or was already gone). */
    val removesCard: Boolean get() = this == Closed || this == Stale

    companion object { fun of(raw: String?) = entries.firstOrNull { it.raw == raw } }
}

data class WindowCloseReply(val windowID: Long, val result: WindowCloseResult) {
    companion object {
        fun parse(obj: JsonObject): WindowCloseReply? =
            WindowCloseReply(obj.long("window")?.takeIf { it in 0..0xFFFF_FFFFL } ?: return null,
                WindowCloseResult.of(obj.str("result")?.take(32)) ?: return null)
    }
}

/** The outcome of one Close Window, worded for the person who asked. [result] null: no answer. */
data class WindowCloseNotice(val windowID: Long, val name: String, val result: WindowCloseResult?, val unsupported: Boolean = false, val serial: Int = 0) {
    val isError: Boolean get() = result != WindowCloseResult.Closed && result != WindowCloseResult.Stale
    val message: String get() = if (unsupported) "Update MeowDisplay on the Mac to close windows from here." else when (result) {
        WindowCloseResult.Closed -> "Closed “$name”."
        WindowCloseResult.SaveDialog -> "“$name” has unsaved changes. Choose Save or Don’t Save on the Mac."
        WindowCloseResult.StillOpen -> "“$name” stayed open. Its app may be busy or asking something on the Mac."
        WindowCloseResult.Stale -> "“$name” was already closed."
        WindowCloseResult.Control -> "Closing windows needs control of the Mac. Use Request Control first."
        WindowCloseResult.Accessibility -> "The Mac needs Accessibility permission for MeowDisplay to close windows."
        WindowCloseResult.NoButton -> "“$name” can’t be closed: it has no close button."
        WindowCloseResult.Ambiguous -> "The Mac couldn’t tell which window to close, so nothing was closed."
        null -> "The Mac didn’t confirm closing “$name”."
    }
}

data class AppLaunchResult(val bundleID: String, val ok: Boolean) {
    companion object { fun parse(obj: JsonObject): AppLaunchResult? = AppLaunchResult(obj.str("bundle") ?: return null, obj.bool("ok") == true) }
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
