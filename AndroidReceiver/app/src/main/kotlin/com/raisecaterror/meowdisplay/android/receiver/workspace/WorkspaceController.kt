package com.raisecaterror.meowdisplay.android.receiver.workspace

import android.content.Context
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Base64
import android.util.Log
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.content.edit
import com.raisecaterror.meowdisplay.android.session.SessionHost
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import com.raisecaterror.meowdisplay.core.session.SessionEvent
import com.raisecaterror.meowdisplay.core.workspace.AppIcon
import com.raisecaterror.meowdisplay.core.workspace.CatalogWindow
import com.raisecaterror.meowdisplay.core.workspace.WAdaptation
import com.raisecaterror.meowdisplay.core.workspace.WDivider
import com.raisecaterror.meowdisplay.core.workspace.WDropTarget
import com.raisecaterror.meowdisplay.core.workspace.WFit
import com.raisecaterror.meowdisplay.core.workspace.WFrames
import com.raisecaterror.meowdisplay.core.workspace.WGeometry
import com.raisecaterror.meowdisplay.core.workspace.WHinge
import com.raisecaterror.meowdisplay.core.workspace.WHistory
import com.raisecaterror.meowdisplay.core.workspace.WLayout
import com.raisecaterror.meowdisplay.core.workspace.WLayoutRecord
import com.raisecaterror.meowdisplay.core.workspace.WPreset
import com.raisecaterror.meowdisplay.core.workspace.WSize
import com.raisecaterror.meowdisplay.core.workspace.WSource
import com.raisecaterror.meowdisplay.core.workspace.WTile
import com.raisecaterror.meowdisplay.core.workspace.WindowCatalog
import com.raisecaterror.meowdisplay.core.workspace.WindowThumbnail
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceState
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceWire
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Where the collapsible window rail sits. Top by default. */
enum class RailEdge { Top, Bottom, Left, Right }

data class WorkspaceUi(
    /** The connected Mac offers Window mode. */
    val available: Boolean = false,
    /** The Mac confirmed Window mode for this device. */
    val windowMode: Boolean = false,
    /** What's shown: the saved arrangement adapted to the space now. */
    val layout: WLayout = WLayout.of(),
    /** Tiles kept but not shown (smaller screen than they were arranged for). */
    val stacked: List<String> = emptyList(),
    val capacity: Int = 1,
    val remote: WorkspaceState? = null,
    val catalog: WindowCatalog? = null,
    val overviewOpen: Boolean = false,
    /** The overview is choosing a window for this tile. */
    val replacingTile: String? = null,
    val railExpanded: Boolean = false,
    /** Stage Peek is open or about to open: keep the catalog and thumbnails fresh. Changes nothing on the Mac. */
    val stagePeekOpen: Boolean = false,
    val railEdge: RailEdge = RailEdge.Top,
    /** Tile handles and dividers shown for moving and resizing. */
    val arranging: Boolean = false,
    val hovered: String? = null,
    val canUndo: Boolean = false,
    /** Tiles whose saved window is no longer on the Mac. */
    val missing: Set<String> = emptySet(),
) {
    val active: String? get() = remote?.active
    fun tileState(id: String) = remote?.tiles?.firstOrNull { it.id == id }
    /** The window in the tile a switcher replaces: the active tile, or the only one. */
    /** The tile a switcher (Stage Peek) replaces: the active tile, the only one, else the first tile still waiting for a window, else the last. */
    val switchTarget: String? get() {
        val order = layout.orderedTileIDs
        active?.takeIf { it in layout.tiles }?.let { return it }
        if (order.size == 1) return order.first()
        return order.firstOrNull { it in missing || layout.tiles[it]?.source == null } ?: order.lastOrNull()
    }
    val currentWindowID: Long? get() = switchTarget?.let { layout.tiles[it]?.source?.windowID }
    val canAddTile: Boolean get() = layout.tiles.size < capacity
    /** A switcher is showing windows, so the catalog and thumbnails refresh. */
    val wantsCatalog: Boolean get() = overviewOpen || railExpanded || stagePeekOpen
}

/**
 * The receiver's window workspace (Android). The Mac is authoritative for
 * what's captured, accepted and focused; this keeps the user's arrangement
 * per Mac, adapts it to the space available (fold, rotation, split screen)
 * without ever dropping tiles, and sends only this Mac's tiles to it.
 * Main thread only.
 */
class WorkspaceController(
    context: Context,
    private val media: SessionHost,
    /** Explore Demo keeps its arrangement in its own file, cleared on entry and exit. */
    prefsName: String = "workspace",
) {
    private val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
    private val main = Handler(Looper.getMainLooper())
    private val state = MutableStateFlow(WorkspaceUi(railEdge = runCatching { RailEdge.valueOf(prefs.getString(RAIL_EDGE, null) ?: "") }.getOrDefault(RailEdge.Top)))
    val ui: StateFlow<WorkspaceUi> = state.asStateFlow()

    /** Where the collapsed rail handle is (window dp), so tile pills stay clear of it. UI only. */
    val railHandle = androidx.compose.runtime.mutableStateOf<com.raisecaterror.meowdisplay.core.controls.CGRect?>(null)

    /** The full-desktop "Switch to Window view?" offer was answered since the app started (UI only: asked once per launch). */
    val windowPromptAnswered = androidx.compose.runtime.mutableStateOf(false)

    /** The Mirror or Extend mode the Mac last confirmed this session: what Stage Peek's Full Desktop card returns to. */
    var fullDisplayMode = DisplayMode.Extend
        private set

    private val thumbs = MutableStateFlow<Map<Long, ImageBitmap>>(emptyMap())
    val thumbnails: StateFlow<Map<Long, ImageBitmap>> = thumbs.asStateFlow()
    private val iconState = MutableStateFlow<Map<String, ImageBitmap>>(emptyMap())
    val icons: StateFlow<Map<String, ImageBitmap>> = iconState.asStateFlow()
    private val thumbAge = HashMap<Long, Long>()

    private var saved: WLayout = WLayout.of()
    private var host: String? = null
    private var size = WSize(400.0, 800.0)
    private var hinge: WHinge? = null
    private var history = WHistory()
    private var nextTile = 1
    private var catalogAwaitingSend = false
    private val sendRunnable = Runnable { sendNow() }
    private val refreshRunnable = object : Runnable {
        override fun run() {
            val s = state.value
            if (!s.wantsCatalog) return
            requestCatalog()
            main.postDelayed(this, if (s.overviewOpen || s.stagePeekOpen) 3_000 else 5_000)
        }
    }

    /** Workspace frames in the canvas, as sent to the Mac. */
    fun frames(): WFrames = WGeometry.frames(state.value.layout, size, hinge)

    // MARK: Session

    fun onSessionEvent(event: SessionEvent) {
        when (event) {
            is SessionEvent.Connected -> if (event.peerID != host) loadFor(event.peerID)
            is SessionEvent.MacFeatures -> state.update { it.copy(available = WorkspaceWire.WELCOME_FEATURE in event.features) }
            is SessionEvent.DisplayModeConfirmed -> {
                val window = event.mode == DisplayMode.Window
                if (!window) fullDisplayMode = event.mode
                state.update { it.copy(windowMode = window, remote = if (window) it.remote else null) }
                if (window) { catalogAwaitingSend = true; requestCatalog() }
            }
            is SessionEvent.Disconnected, SessionEvent.AdmissionWithdrawn -> {
                main.removeCallbacks(sendRunnable)
                fullDisplayMode = DisplayMode.Extend
                state.update { it.copy(windowMode = false, remote = null, available = false, arranging = false, stagePeekOpen = false) }
            }
            is SessionEvent.Control -> when (event.type) {
                WorkspaceWire.CATALOG -> onCatalog(WindowCatalog.parse(event.body))
                WorkspaceWire.WORKSPACE_STATE -> {
                    val parsed = WorkspaceState.parse(event.body)
                    state.update { it.copy(remote = parsed) }
                    // The Mac refused a tile because its window already shows in another one
                    // (e.g. a layout saved before that rule): empty the tile instead of leaving
                    // it labelled with a window it will never show.
                    val layout = state.value.layout
                    val duplicates = parsed.rejected.filterValues { it == "duplicateWindow" }.keys.filter { layout.tiles[it]?.source != null }
                    if (duplicates.isNotEmpty()) edit { l -> duplicates.fold(l) { acc, id -> acc.replacingSource(id, null) } }
                }
                WorkspaceWire.THUMBNAIL -> WindowThumbnail.parse(event.body)?.let(::onThumbnail)
                WorkspaceWire.APP_ICON -> AppIcon.parse(event.body)?.let(::onIcon)
            }
            else -> Unit
        }
    }

    private fun loadFor(peerID: String) {
        host = peerID
        saved = prefs.getString(LAYOUT + peerID, null)?.let(WLayoutRecord::decode) ?: WLayout.of()
        nextTile = (saved.tiles.keys.mapNotNull { it.removePrefix("w").toIntOrNull() }.maxOrNull() ?: 0) + 1
        history = WHistory()
        thumbs.value = emptyMap(); thumbAge.clear(); iconState.value = emptyMap()
        publish()
    }

    private fun onCatalog(catalog: WindowCatalog) {
        state.update { it.copy(catalog = catalog) }
        // A reconnect starts a new Mac session with new window generations:
        // keep a saved tile only for the same window id of the same app.
        val byID = catalog.windows.associateBy { it.id }
        var rebased = saved
        val missing = catalog.missingTiles(saved)
        for ((id, tile) in saved.tiles) {
            val source = tile.source ?: continue
            val window = byID[source.windowID] ?: continue
            if (id !in missing && window.generation != source.generation) rebased = rebased.replacingSource(id, source.copy(generation = window.generation, bundleID = window.bundleID))
        }
        if (rebased != saved) { saved = rebased; persist() }
        state.update { it.copy(missing = missing) }
        publish()
        if (catalogAwaitingSend) { catalogAwaitingSend = false; scheduleSend(0) }
        requestThumbnails(catalog)
    }

    private fun requestThumbnails(catalog: WindowCatalog) {
        val s = state.value
        if (!s.wantsCatalog) return
        val now = SystemClock.uptimeMillis()
        val ids = catalog.windows.filter { now - (thumbAge[it.id] ?: 0) > 8_000 }.map { it.id }.take(24)
        val icons = catalog.apps.map { it.bundleID }.filter { it !in iconState.value }.take(32)
        if (ids.isNotEmpty() || icons.isNotEmpty()) media.session.sendWorkspace(WorkspaceWire.thumbnailRequest(ids, if (s.stagePeekOpen) 320 else 240, icons))
    }

    private fun onThumbnail(t: WindowThumbnail) {
        val data = t.jpegBase64 ?: return
        val bitmap = decodeBounded(data, MAX_THUMB_SIDE) ?: return
        thumbAge[t.windowID] = SystemClock.uptimeMillis()
        thumbs.update { map -> (map + (t.windowID to bitmap.asImageBitmap())).let { if (it.size > MAX_THUMBS) it.entries.drop(it.size - MAX_THUMBS).associate { e -> e.key to e.value } else it } }
    }

    private fun onIcon(icon: AppIcon) {
        val bitmap = decodeBounded(icon.pngBase64, MAX_ICON_SIDE) ?: return
        iconState.update { if (it.size >= MAX_ICONS) it else it + (icon.bundleID to bitmap.asImageBitmap()) }
    }

    /**
     * Images from the Mac are bounded before they are decoded: the header's
     * size is checked first (a small file can declare a huge image), larger
     * ones are downsampled, and a failed decode is dropped.
     */
    private fun decodeBounded(base64: String, maxSide: Int): android.graphics.Bitmap? {
        val bytes = runCatching { Base64.decode(base64, Base64.DEFAULT) }.getOrNull() ?: return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        val w = bounds.outWidth; val h = bounds.outHeight
        if (w <= 0 || h <= 0 || w.toLong() * h > MAX_DECODE_PIXELS) return null
        var sample = 1
        while (w / sample > maxSide * 2 || h / sample > maxSide * 2) sample *= 2
        return try {
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, BitmapFactory.Options().apply { inSampleSize = sample })
        } catch (_: OutOfMemoryError) {
            null
        }
    }

    fun requestCatalog() {
        media.session.sendWorkspace(WorkspaceWire.catalogRequest(installed = media.ui.value.input == com.raisecaterror.meowdisplay.core.session.InputWireState.Allowed))
    }

    // MARK: Space

    /** The usable workspace in dp and the fold (normalized to the canvas), from the screen. */
    fun updateSpace(newSize: WSize, newHinge: WHinge?) {
        if (newSize == size && newHinge == hinge) return
        size = newSize
        hinge = newHinge
        publish()
        scheduleSend()
    }

    private fun publish() {
        val active = state.value.remote?.active
        val adapted = WAdaptation.adapt(saved, size, hinge, active)
        state.update { it.copy(layout = adapted.visible, stacked = adapted.stacked, capacity = WGeometry.capacity(size, hinge), canUndo = history.canUndo) }
    }

    // MARK: Editing (every change: undoable, saved per Mac, sent to the Mac)

    private fun edit(change: (WLayout) -> WLayout) {
        val visible = state.value.layout
        val next = change(visible)
        if (next == visible) return
        history.record(saved)
        // Tiles stacked away on this smaller screen are kept: re-add them behind the visible ones.
        var updated = next
        for (id in state.value.stacked) saved.tiles[id]?.let { updated = updated.adding(it, size.width >= size.height) }
        saved = if (state.value.stacked.isEmpty()) next else updated
        refreshMissing()
        persist()
        publish()
        scheduleSend()
    }

    /** After an edit: a tile is missing only while its window is unlisted, so choosing another window for it (or removing it) clears the mark. */
    private fun refreshMissing() {
        val catalog = state.value.catalog ?: return
        state.update { it.copy(missing = catalog.missingTiles(saved)) }
    }

    fun undo() {
        val previous = history.undo() ?: return
        saved = previous
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    fun applyPreset(preset: WPreset) = edit { layout ->
        val ordered = layout.orderedTileIDs.mapNotNull { layout.tiles[it] }
        if (ordered.size > preset.slotCount) layout.applying(preset).first else WLayout.preset(preset, ordered)
    }

    fun swap(a: String, b: String) = edit { it.swapping(a, b) }
    fun move(tile: String, target: WDropTarget) = edit { it.materializing(hinge).moving(tile, target) }
    /** A divider drag: every step resizes, the whole drag is one undo step. Call [endResize] when it ends. */
    fun resize(divider: WDivider, delta: Double) {
        history.beginGroup()
        edit { WGeometry.resizing(it, divider, delta, size) }
    }

    fun endResize() = history.endGroup()
    fun rotate(tile: String) = edit { it.rotating(tile) }
    fun toggleFit(tile: String) = edit { l -> l.settingFit(if (l.tiles[tile]?.fit == WFit.Fill) WFit.Fit else WFit.Fill, tile) }
    fun toggleMaximize(tile: String) = edit { l -> if (l.maximized == tile) l.restoringMaximized() else l.maximizing(tile) }

    /** Removes the tile only; the Mac window stays open. */
    fun removeTile(tile: String) = edit { it.removing(tile) }

    /** Closes the real Mac window, from its own explicit confirm. Needs control. */
    fun closeRemoteWindow(tile: String) {
        val source = state.value.layout.tiles[tile]?.source ?: return
        val gen = source.generation ?: return
        media.session.sendWorkspace(WorkspaceWire.closeRemoteWindow(source.windowID, gen))
    }

    /** Bring a stacked tile back into view (replaces the active, or last, tile's slot). */
    fun bringBack(tile: String) {
        if (tile !in saved.tiles) return
        val visible = state.value.layout
        val target = state.value.active?.takeIf { it in visible.tiles } ?: visible.orderedTileIDs.lastOrNull() ?: return
        history.record(saved)
        saved = saved.swapping(tile, target)
        persist(); publish(); scheduleSend()
    }

    /** Stage Peek's tap: shows [window] in [WorkspaceUi.switchTarget]; never adds a tile. */
    fun switchTo(window: CatalogWindow) {
        val target = state.value.switchTarget
        state.update { it.copy(replacingTile = target) }
        choose(window, asNewTile = false)
    }

    /** A window chosen in the overview or rail. */
    fun choose(window: CatalogWindow, asNewTile: Boolean) {
        val host = host ?: return
        val source = WSource(host, window.id, window.generation, window.bundleID)
        val replacing = state.value.replacingTile
        closeOverview()
        state.update { it.copy(railExpanded = false, stagePeekOpen = false) }
        if (!state.value.windowMode) media.session.requestDisplayMode(DisplayMode.Window)
        // One window, one tile: choosing a window that's already showing selects its tile,
        // or swaps the two tiles when replacing another one.
        val current = state.value.layout
        current.orderedTileIDs.firstOrNull { current.tiles[it]?.source?.let { s -> s.host == host && s.windowID == window.id } == true }?.let { existing ->
            val target = replacing ?: if (asNewTile) null else state.value.active
            val other = target?.let { current.tiles[it]?.source }
            if (target != null && target != existing && other != null) {
                edit { it.replacingSource(target, source).replacingSource(existing, other) }
            }
            focus(target ?: existing)
            return
        }
        edit { layout ->
            val target = replacing ?: if (asNewTile) null else (state.value.active ?: layout.orderedTileIDs.singleOrNull())
            when {
                target != null && target in layout.tiles -> layout.replacingSource(target, source)
                layout.tiles.size < state.value.capacity -> {
                    val tile = WTile("w${nextTile++}", source)
                    if (layout.tiles.isEmpty()) WLayout.preset(WPreset.Single, listOf(tile)) else layout.adding(tile, size.width >= size.height)
                        .let { added -> WLayout.preset(WPreset.natural(added.tiles.size, size.width >= size.height), added.orderedTileIDs.mapNotNull { added.tiles[it] }) }
                }
                else -> layout.orderedTileIDs.lastOrNull()?.let { layout.replacingSource(it, source) } ?: layout
            }
        }
    }

    fun launch(bundleID: String) {
        media.session.sendWorkspace(WorkspaceWire.launch(bundleID))
    }

    fun focus(tile: String) {
        media.session.sendWorkspace(WorkspaceWire.focus(tile))
    }

    /** The hardware pointer at a normalized canvas point: hover only, never focus. */
    fun hover(x: Double?, y: Double?) {
        val id = if (x == null || y == null) null else frames().tiles.entries.firstOrNull { it.value.contains(com.raisecaterror.meowdisplay.core.workspace.WPoint(x, y)) }?.key
        setHovered(id)
    }

    fun setHovered(tile: String?) {
        if (state.value.hovered != tile) state.update { it.copy(hovered = tile) }
    }

    // MARK: Overview, rail, arrange

    fun openOverview(replacing: String? = null) {
        state.update { it.copy(overviewOpen = true, replacingTile = replacing) }
        startRefreshing()
    }

    fun closeOverview() {
        state.update { it.copy(overviewOpen = false, replacingTile = null) }
    }

    fun setRailExpanded(expanded: Boolean) {
        state.update { it.copy(railExpanded = expanded) }
        if (expanded) startRefreshing()
    }

    /** Stage Peek is arming or open (browsing only: nothing is sent to change the Mac). */
    fun setStagePeekOpen(open: Boolean) {
        if (state.value.stagePeekOpen == open) return
        state.update { it.copy(stagePeekOpen = open) }
        if (open) startRefreshing()
    }

    fun setRailEdge(edge: RailEdge) {
        prefs.edit { putString(RAIL_EDGE, edge.name) }
        state.update { it.copy(railEdge = edge) }
    }

    fun setArranging(on: Boolean) = state.update { it.copy(arranging = on) }

    private fun startRefreshing() {
        main.removeCallbacks(refreshRunnable)
        requestCatalog()
        main.postDelayed(refreshRunnable, 3_000)
    }

    // MARK: Sending

    private fun scheduleSend(delayMs: Long = 60) {
        main.removeCallbacks(sendRunnable)
        main.postDelayed(sendRunnable, delayMs)
    }

    private fun sendNow() {
        val host = host ?: return
        val s = state.value
        if (!s.windowMode) return
        if (s.catalog == null) { catalogAwaitingSend = true; requestCatalog(); return }
        // A tile whose window is gone is kept (and marked) but not sent.
        val sendable = s.missing.fold(s.layout) { l, id -> l.replacingSource(id, null) }
        val frames = WGeometry.frames(sendable, size, hinge)
        val ok = media.session.sendWorkspace(WorkspaceWire.workspaceRequest(sendable, frames, host, s.active))
        if (!ok) Log.i(TAG, "workspace request not sent (not admitted or no Window mode)")
    }

    private fun persist() {
        val host = host ?: return
        prefs.edit { putString(LAYOUT + host, WLayoutRecord.encode(saved).toString()) }
    }

    private companion object {
        const val TAG = "MeowWorkspace"
        const val LAYOUT = "layout."
        const val RAIL_EDGE = "railEdge"
        const val MAX_THUMBS = 48
        const val MAX_ICONS = 64
        const val MAX_THUMB_SIDE = 320
        const val MAX_ICON_SIDE = 128
        /** Refuse anything that would decode to more than 16 MP, whatever its file size. */
        const val MAX_DECODE_PIXELS = 4096L * 4096L
    }
}
