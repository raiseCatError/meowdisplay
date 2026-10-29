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
import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import com.raisecaterror.meowdisplay.core.session.InputWireState
import com.raisecaterror.meowdisplay.core.session.SessionEvent
import com.raisecaterror.meowdisplay.core.workspace.AppCatalogMessage
import com.raisecaterror.meowdisplay.core.workspace.AppIcon
import com.raisecaterror.meowdisplay.core.workspace.AppLaunchResult
import com.raisecaterror.meowdisplay.core.workspace.CatalogDisplay
import com.raisecaterror.meowdisplay.core.workspace.CatalogWindow
import com.raisecaterror.meowdisplay.core.workspace.DisplayThumbnail
import com.raisecaterror.meowdisplay.core.workspace.MacApp
import com.raisecaterror.meowdisplay.core.workspace.AppMenuModel
import com.raisecaterror.meowdisplay.core.workspace.AppMenuReply
import com.raisecaterror.meowdisplay.core.workspace.AppMenuWire
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesModel
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesReply
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesStyle
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesWire
import com.raisecaterror.meowdisplay.core.workspace.ThumbnailRequestPlanner
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
import com.raisecaterror.meowdisplay.core.workspace.WPaneZoom
import com.raisecaterror.meowdisplay.core.workspace.WPoint
import com.raisecaterror.meowdisplay.core.workspace.WPreset
import com.raisecaterror.meowdisplay.core.workspace.WRect
import com.raisecaterror.meowdisplay.core.workspace.TileTransform
import com.raisecaterror.meowdisplay.core.workspace.WRotation
import com.raisecaterror.meowdisplay.core.workspace.WSavedLayout
import com.raisecaterror.meowdisplay.core.workspace.rebinding
import com.raisecaterror.meowdisplay.core.workspace.WZoomPreview
import com.raisecaterror.meowdisplay.core.workspace.WSize
import com.raisecaterror.meowdisplay.core.workspace.WSource
import com.raisecaterror.meowdisplay.core.workspace.WTile
import com.raisecaterror.meowdisplay.core.workspace.WWindowDrop
import com.raisecaterror.meowdisplay.core.workspace.WZoom
import com.raisecaterror.meowdisplay.core.workspace.WindowAvailability
import com.raisecaterror.meowdisplay.core.workspace.WindowCatalog
import com.raisecaterror.meowdisplay.core.workspace.WindowThumbnail
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceSearch
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceState
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceWire
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceBackdrop
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceViewEcho
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlin.math.max
import kotlin.math.min

/** Where the collapsible window rail sits. Top by default. */
enum class RailEdge { Top, Bottom, Left, Right }

/** A window (from Stage Peek) or a pane's label being dragged; [location] in window dp. */
data class WorkspaceDrag(val item: Item, val location: CGPoint) {
    sealed interface Item {
        data class Window(val window: CatalogWindow) : Item
        /** A pane's label (all its windows), or one of its tabs. */
        data class Pane(val tile: String, val tab: Int?) : Item
    }
}

data class WorkspaceUi(
    /** The connected Mac offers Window mode. */
    val available: Boolean = false,
    /** The Mac confirmed Window mode for this device. */
    val windowMode: Boolean = false,
    /** What's shown: the saved arrangement adapted to the space now (local fullscreen applied). */
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
    val launchpadOpen: Boolean = false,
    val railEdge: RailEdge = RailEdge.Top,
    /** Tile handles and dividers shown for moving and resizing. */
    val arranging: Boolean = false,
    val hovered: String? = null,
    val canUndo: Boolean = false,
    val canRedo: Boolean = false,
    /** Layouts saved by name for this Mac, newest first. */
    val savedLayouts: List<WSavedLayout> = emptyList(),
    /** Tiles whose saved window is no longer on the Mac. */
    val missing: Set<String> = emptySet(),
    /** Every app on the Mac (Finder first, running next), from `appCatalog`. */
    val apps: List<MacApp> = emptyList(),
    /** Apps opened from here that haven't shown a window yet. */
    val launching: Set<String> = emptySet(),
    val launchFailed: String? = null,
    val drag: WorkspaceDrag? = null,
    /** "Fullscreen on This Device": this pane fills the screen locally; the arrangement is kept. */
    val localFullscreen: String? = null,
    /** Bumped on any touch on the picture: reveals the fullscreen strip. */
    val touchPulse: Int = 0,
) {
    val active: String? get() = remote?.active
    fun tileState(id: String) = remote?.tiles?.firstOrNull { it.id == id }
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
    val wantsCatalog: Boolean get() = overviewOpen || railExpanded || stagePeekOpen || launchpadOpen
}

/**
 * The receiver's window workspace (Android). The Mac is authoritative for
 * what's captured, accepted and focused; this keeps the user's arrangement
 * per Mac, adapts it to the space available (fold, rotation, split screen)
 * without ever dropping tiles, and sends only this Mac's tiles to it.
 * Mirrors iOS WorkspaceModel. Main thread only.
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
    val railHandle = androidx.compose.runtime.mutableStateOf<CGRect?>(null)

    /** The full-desktop "Switch to Window view?" offer was answered since the app started (UI only: asked once per launch). */
    val windowPromptAnswered = androidx.compose.runtime.mutableStateOf(false)

    /** The Mirror or Extend mode the Mac last confirmed this session: what "View Full Screen" returns to. */
    var fullDisplayMode = DisplayMode.Extend
        private set

    private val thumbs = MutableStateFlow<Map<Long, ImageBitmap>>(emptyMap())
    val thumbnails: StateFlow<Map<Long, ImageBitmap>> = thumbs.asStateFlow()
    private val iconState = MutableStateFlow<Map<String, ImageBitmap>>(emptyMap())
    val icons: StateFlow<Map<String, ImageBitmap>> = iconState.asStateFlow()
    private val displayThumbs = MutableStateFlow<Map<Long, ImageBitmap>>(emptyMap())
    val displayThumbnails: StateFlow<Map<Long, ImageBitmap>> = displayThumbs.asStateFlow()
    private val thumbAge = HashMap<Long, Long>()
    private val planner = ThumbnailRequestPlanner()
    private var appRevision: Int? = null
    /** Cards on screen now (Stage Peek, overview): their stills are asked for first. */
    var thumbnailPriority: List<Long> = emptyList()
        set(value) { if (field != value) { field = value; state.value.catalog?.let(::requestThumbnails) } }

    /** The picture's frame in window dp (Window mode), so drags from Stage Peek find the panes. */
    var pictureFrame: CGRect = CGRect.zero
    /** Mirror/Extend: the desktop picture's frame (Stage Peek reports it), so a window can land beside it. */
    var desktopFrame: CGRect = CGRect.zero
    /** The "Cancel" drop zone shown during a drag (window dp). Dropping there changes nothing. */
    var cancelZone: CGRect = CGRect.zero

    private var saved: WLayout = WLayout.of()
    /** The arrangement without local fullscreen: what edits apply to. */
    private var arranged: WLayout = WLayout.of()
    private var host: String? = null
    private var size = WSize(400.0, 800.0)
    private var hinge: WHinge? = null
    private var history = WHistory()
    private var nextTile = 1
    private var catalogAwaitingSend = false
    private val sendRunnable = Runnable { sendNow() }
    private var throttledSendPending = false
    private val throttledSend = Runnable { throttledSendPending = false; sendNow() }
    private val refreshRunnable = object : Runnable {
        private var tick = 0
        override fun run() {
            val s = state.value
            if (!s.wantsCatalog) return
            requestCatalog()
            if (++tick % 5 == 0) requestApps()
            main.postDelayed(this, if (s.overviewOpen || s.stagePeekOpen || s.launchpadOpen) 3_000 else 5_000)
        }
    }

    /** Workspace frames in the canvas, as sent to the Mac. */
    fun frames(): WFrames = WGeometry.frames(state.value.layout, size, hinge)

    private val inputAllowed: Boolean get() = media.ui.value.input == InputWireState.Allowed

    /** Remote Finder: the Mac's approved folders, browsed here (Finder in the carousel opens it). */
    val files = RemoteFilesModel(
        send = { media.session.sendWorkspace(it) },
        inputAllowed = { inputAllowed },
        scheduler = { ms, block -> val r = Runnable(block); main.postDelayed(r, ms); { main.removeCallbacks(r) } },
        style = runCatching { RemoteFilesStyle.valueOf(prefs.getString(FILES_STYLE, null) ?: "") }.getOrDefault(RemoteFilesStyle.List),
        onStyle = { prefs.edit().putString(FILES_STYLE, it.name).apply() },
    )

    /** The focused pane's app menus (a bar under its label). */
    val menus = AppMenuModel(
        send = { media.session.sendWorkspace(it) },
        scheduler = { ms, block -> val r = Runnable(block); main.postDelayed(r, ms); { main.removeCallbacks(r) } },
        barShown = prefs.getBoolean(MENU_BAR, true),
        onBarShown = { prefs.edit().putBoolean(MENU_BAR, it).apply() },
    )

    // MARK: Session

    fun onSessionEvent(event: SessionEvent) {
        when (event) {
            is SessionEvent.Connected -> if (event.peerID != host) loadFor(event.peerID)
            is SessionEvent.MacFeatures -> {
                state.update { it.copy(available = WorkspaceWire.WELCOME_FEATURE in event.features) }
                files.setAvailable(RemoteFilesWire.WELCOME_FEATURE in event.features)
                menus.setAvailable(AppMenuWire.WELCOME_FEATURE in event.features)
            }
            is SessionEvent.DisplayModeConfirmed -> {
                val window = event.mode == DisplayMode.Window
                if (!window) fullDisplayMode = event.mode
                state.update { it.copy(windowMode = window, remote = if (window) it.remote else null, localFullscreen = if (window) it.localFullscreen else null) }
                if (window) { catalogAwaitingSend = true; requestCatalog() }
                publish()
            }
            is SessionEvent.Disconnected, SessionEvent.AdmissionWithdrawn -> {
                main.removeCallbacks(sendRunnable)
                fullDisplayMode = DisplayMode.Extend
                planner.reset()
                clearViews()
                files.setAvailable(false)
                menus.setAvailable(false)
                state.update {
                    it.copy(windowMode = false, remote = null, available = false, arranging = false, stagePeekOpen = false,
                        launchpadOpen = false, launching = emptySet(), drag = null)
                }
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
                WorkspaceWire.WORKSPACE_VIEW -> onViewEcho(WorkspaceViewEcho.parse(event.body))
                WorkspaceWire.WORKSPACE_BACKDROP -> WorkspaceBackdrop.parse(event.body)?.let(::onBackdrop)
                WorkspaceWire.APP_ICON -> AppIcon.parse(event.body)?.let(::onIcon)
                WorkspaceWire.DISPLAY_THUMBNAIL -> DisplayThumbnail.parse(event.body)?.let { d ->
                    decodeBounded(d.jpegBase64, MAX_THUMB_SIDE)?.let { b -> displayThumbs.update { it + (d.displayID to b.asImageBitmap()) } }
                }
                WorkspaceWire.APP_CATALOG -> AppCatalogMessage.parse(event.body)?.let { m ->
                    appRevision = m.revision
                    m.apps?.let { list -> state.update { it.copy(apps = WorkspaceSearch.carouselOrder(list)) } }
                    requestIcons()
                }
                RemoteFilesWire.REPLY -> RemoteFilesReply.parse(event.body)?.let(files::apply)
                AppMenuWire.MENU -> menus.apply(AppMenuReply.parse(event.body))
                AppMenuWire.RESULT -> menus.applyResult(
                    (event.body["ok"] as? kotlinx.serialization.json.JsonPrimitive)?.content == "true",
                    (event.body["error"] as? kotlinx.serialization.json.JsonPrimitive)?.content?.take(32),
                )
                WorkspaceWire.APP_LAUNCH_RESULT -> AppLaunchResult.parse(event.body)?.let { r ->
                    if (!r.ok) state.update { it.copy(launching = it.launching - r.bundleID, launchFailed = r.bundleID) }
                    requestCatalog()
                }
            }
            else -> Unit
        }
    }

    private fun loadFor(peerID: String) {
        host = peerID
        saved = (prefs.getString(LAYOUT + peerID, null)?.let(WLayoutRecord::decode) ?: WLayout.of()).compacted()
        nextTile = (saved.tiles.keys.mapNotNull { it.removePrefix("w").toIntOrNull() }.maxOrNull() ?: 0) + 1
        history = WHistory()
        val savedLayouts = prefs.getString(SAVED + peerID, null)?.let(WSavedLayout::decodeList).orEmpty()
        state.update { it.copy(savedLayouts = savedLayouts) }
        thumbs.value = emptyMap(); thumbAge.clear(); iconState.value = emptyMap(); displayThumbs.value = emptyMap()
        planner.reset(); appRevision = null
        state.update { it.copy(apps = emptyList(), launching = emptySet(), localFullscreen = null) }
        publish()
    }

    private fun onCatalog(catalog: WindowCatalog) {
        if (catalog.starting) return
        state.update { it.copy(catalog = catalog) }
        // A reconnect starts a new Mac session with new window generations:
        // keep a saved tile only for the same window id of the same app.
        val byID = catalog.windows.associateBy { it.id }
        var rebased = saved
        val missing = catalog.missingTiles(saved)
        for ((id, tile) in saved.tiles) {
            val source = tile.source ?: continue
            if (source.isDisplay) continue
            val window = byID[source.windowID] ?: continue
            if (id !in missing && window.generation != source.generation) rebased = rebased.replacingSource(id, source.copy(generation = window.generation, bundleID = window.bundleID))
        }
        if (rebased != saved) { saved = rebased; persist() }
        // An app opened from here showed a window: it's no longer "opening".
        val launched = catalog.windows.map { it.bundleID }.toSet()
        state.update { it.copy(missing = missing, launching = it.launching - launched) }
        publish()
        if (catalogAwaitingSend) { catalogAwaitingSend = false; scheduleSend(0) }
        requestThumbnails(catalog)
    }

    /** Visible cards first; nothing asked twice within a few seconds; failures back off. */
    private fun requestThumbnails(catalog: WindowCatalog) {
        val s = state.value
        if (!s.wantsCatalog) return
        val ids = planner.plan(thumbnailPriority, catalog.windows.map { it.id }, SystemClock.uptimeMillis())
        val icons = (catalog.windows.map { it.bundleID } + catalog.apps.map { it.bundleID }).distinct().filter { it !in iconState.value }.take(48)
        val displays = if (s.stagePeekOpen || s.overviewOpen) catalog.displays.map { it.id } else emptyList()
        if (ids.isEmpty() && icons.isEmpty() && displays.isEmpty()) return
        // Stage Peek's gallery shows large cards: sharp stills.
        media.session.sendWorkspace(WorkspaceWire.thumbnailRequest(ids, if (s.stagePeekOpen) 560 else 320, icons, displays))
    }

    /** Icons for the app carousel and Launchpad, a page at a time. */
    fun requestIcons(bundles: List<String>? = null) {
        val wanted = (bundles ?: state.value.apps.take(64).map { it.bundleID }).filter { it !in iconState.value }
        if (!state.value.wantsCatalog || wanted.isEmpty()) return
        media.session.sendWorkspace(WorkspaceWire.thumbnailRequest(emptyList(), 320, wanted.take(48)))
    }

    fun requestApps() {
        media.session.sendWorkspace(WorkspaceWire.appCatalogRequest(if (state.value.apps.isEmpty()) null else appRevision))
    }

    private fun onThumbnail(t: WindowThumbnail) {
        val now = SystemClock.uptimeMillis()
        val bitmap = t.jpegBase64?.let { decodeBounded(it, MAX_THUMB_SIDE) }
        if (bitmap == null) { planner.failed(t.windowID, now); return }
        planner.received(t.windowID, now)
        thumbAge[t.windowID] = now
        thumbs.update { map ->
            var next = map + (t.windowID to bitmap.asImageBitmap())
            // Bounded: the least recently refreshed still that isn't on screen goes first.
            if (next.size > MAX_THUMBS) {
                thumbAge.filterKeys { it !in thumbnailPriority }.minByOrNull { it.value }?.key?.let { old ->
                    next = next - old; thumbAge.remove(old); planner.forget(old)
                }
            }
            next
        }
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
    /** A Remote Finder still or preview, decoded with the same bounds as window stills. */
    fun decodeStill(base64: String, maxSide: Int): ImageBitmap? = decodeBounded(base64, maxSide)?.asImageBitmap()

    /** Stage Peek should open on this app's windows (Remote Finder's "Finder Windows"). UI only. */
    val peekAppRequest = androidx.compose.runtime.mutableStateOf<String?>(null)
    /** Chrome the host draws over the receiver (the demo's badge), in window dp: overlays keep clear of it. UI only. */
    val hostChrome = androidx.compose.runtime.mutableStateOf<List<CGRect>>(emptyList())

    /** The app whose tap opened Remote Finder (Finder, or the demo's file browser). */
    var finderBundle = "com.apple.finder"

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
        media.session.sendWorkspace(WorkspaceWire.catalogRequest(installed = false))
    }

    // MARK: Displays as pane sources (Full Desktop in a tile)

    /** A Mac display as a pane source: a pseudo-window Stage Peek, drops and pickers can use. */
    fun displayWindow(d: CatalogDisplay) = CatalogWindow(
        WSource.displayKey(d.id), 0, "", "Desktop", if (d.isMain) "Full Desktop" else d.name, d.width, d.height, WindowAvailability.Visible, false,
    )

    /** The display a display source shows (null when it isn't one, or the display is gone). */
    fun display(source: WSource): CatalogDisplay? =
        if (!source.isDisplay) null else state.value.catalog?.displays?.firstOrNull { WSource.displayKey(it.id) == source.windowID }

    /** The Mac's main real display: what Mirror shows as "the desktop". */
    val mainDisplay: CatalogDisplay? get() {
        val all = state.value.catalog?.displays.orEmpty()
        return all.firstOrNull { it.isMain && !it.isVirtual } ?: all.firstOrNull { !it.isVirtual } ?: all.firstOrNull()
    }

    /** The catalog entry a pane source shows (a display's pseudo-window for displays). */
    fun windowItem(source: WSource): CatalogWindow? =
        if (source.isDisplay) display(source)?.let(::displayWindow) else state.value.catalog?.windows?.firstOrNull { it.id == source.windowID }

    /** A card's picture: the window's still, or the display's. */
    fun still(w: CatalogWindow): ImageBitmap? =
        if (!WSource.isDisplayKey(w.id)) thumbs.value[w.id]
        else state.value.catalog?.displays?.firstOrNull { WSource.displayKey(it.id) == w.id }?.let { displayThumbs.value[it.id] }

    private fun source(w: CatalogWindow): WSource? {
        val host = host ?: return null
        return if (WSource.isDisplayKey(w.id)) WSource(host, w.id) else WSource(host, w.id, w.generation, w.bundleID)
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
        arranged = adapted.visible
        val full = state.value.localFullscreen?.takeIf { it in adapted.visible.tiles }
        // Local fullscreen is presentation only: the saved tree is untouched.
        state.update {
            it.copy(
                layout = full?.let { id -> adapted.visible.maximizing(id) } ?: adapted.visible, localFullscreen = full,
                stacked = adapted.stacked, capacity = WGeometry.capacity(size, hinge), canUndo = history.canUndo, canRedo = history.canRedo,
            )
        }
    }

    // MARK: Editing (every change: undoable, saved per Mac, sent to the Mac)

    private fun edit(change: (WLayout) -> WLayout) {
        // Never an empty pane: a window that leaves a pane closes it up and the rest grow.
        val next = change(arranged).compacted()
        if (next == arranged) return
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
        val previous = history.undo(saved) ?: return
        saved = previous
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    fun redo() {
        val next = history.redo(saved) ?: return
        saved = next
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    // MARK: Saved layouts

    /** Keeps this arrangement under [name] for this Mac (a saved layout with the same name is replaced). */
    fun saveLayout(name: String) {
        val host = host ?: return
        val trimmed = name.trim().take(40)
        val existing = state.value.savedLayouts
        var n = existing.size + 1
        while (trimmed.isEmpty() && existing.any { it.name == "Layout $n" }) n++
        val title = trimmed.ifEmpty { "Layout $n" }
        val list = (listOf(WSavedLayout(java.util.UUID.randomUUID().toString(), title, saved)) + existing.filter { it.name != title }).take(WSavedLayout.MAXIMUM)
        state.update { it.copy(savedLayouts = list) }
        prefs.edit { putString(SAVED + host, WSavedLayout.encodeList(list)) }
    }

    /** Puts a saved layout back, on the windows open now (one undo step). */
    fun applySaved(id: String) {
        val s = state.value.savedLayouts.firstOrNull { it.id == id } ?: return
        val catalog = state.value.catalog
        val layout = (catalog?.let { c -> s.layout.rebinding(c.windows.map { it.id to it.bundleID }) } ?: s.layout).compacted()
        if (layout == saved) return
        history.record(saved)
        saved = layout
        nextTile = maxOf(nextTile, (saved.tiles.keys.mapNotNull { it.removePrefix("w").toIntOrNull() }.maxOrNull() ?: 0) + 1)
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    fun deleteSavedLayout(id: String) {
        val host = host ?: return
        val list = state.value.savedLayouts.filter { it.id != id }
        state.update { it.copy(savedLayouts = list) }
        prefs.edit { putString(SAVED + host, WSavedLayout.encodeList(list)) }
    }

    fun applyPreset(preset: WPreset) = edit { layout ->
        val ordered = layout.orderedTileIDs.mapNotNull { layout.tiles[it] }.toMutableList()
        // 2x2 or 3x3 with fewer windows showing: the Mac's other open windows (front to back)
        // fill the rest, so the grid has no empty panes. Fewer windows than panes: it closes up.
        val catalog = state.value.catalog
        if (ordered.size < preset.slotCount && catalog != null) {
            val shown = layout.tiles.values.flatMap { it.windows }.map { it.windowID }.toSet()
            for (w in catalog.windows) {
                if (ordered.size >= preset.slotCount) break
                if (w.availability == WindowAvailability.Offscreen || w.id in shown) continue
                val s = source(w) ?: break
                ordered += WTile("w${nextTile++}", s)
            }
        }
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
    /** Fill Pane / Show Whole Window, from what the pane shows now (auto resolved). Clears zoom. */
    fun toggleFit(tile: String) {
        val next = if (effectiveFit(tile) == WFit.Fill) WFit.Fit else WFit.Fill
        edit { l -> l.zooming(tile, null).settingFit(next, tile) }
    }
    fun toggleMaximize(tile: String) = edit { l -> if (l.maximized == tile) l.restoringMaximized() else l.maximizing(tile) }

    /** Two-finger double-tap or Reset View: this pane back to 1x Fit, centred, no rotation. Other panes untouched. */
    fun resetView(tile: String) = edit { l ->
        val t = l.tiles[tile] ?: return@edit l
        l.with(tiles = l.tiles + (tile to t.copy(zoom = null, rotation = WRotation.None, fit = WFit.Fit)))
    }

    /** Removes the tile only; the Mac window stays open. */
    fun removeTile(tile: String) = edit { it.removing(tile) }

    /** Closes the real Mac window, from its own explicit confirm. Needs control. */
    fun closeRemoteWindow(tile: String) {
        val source = state.value.layout.tiles[tile]?.source ?: return
        if (source.isDisplay || !inputAllowed) return
        val gen = source.generation ?: return
        media.session.sendWorkspace(WorkspaceWire.closeRemoteWindow(source.windowID, gen))
    }

    /** Minimizes the real Mac window (explicit action, needs control; the Mac checks the generation). */
    fun minimizeRemoteWindow(tile: String) {
        val source = state.value.layout.tiles[tile]?.source ?: return
        if (source.isDisplay || !inputAllowed) return
        val gen = source.generation ?: return
        media.session.sendWorkspace(WorkspaceWire.minimizeRemoteWindow(source.windowID, gen))
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

    /** A window chosen in the overview, rail or Stage Peek. */
    fun choose(window: CatalogWindow, asNewTile: Boolean) {
        val host = host ?: return
        val source = source(window) ?: return
        val replacing = state.value.replacingTile
        closeOverview()
        state.update { it.copy(railExpanded = false, stagePeekOpen = false) }
        if (!state.value.windowMode) media.session.requestDisplayMode(DisplayMode.Window)
        val current = state.value.layout
        // A background tab: show that tab.
        current.tileHolding(host, window.id)?.let { holder ->
            val t = current.tiles[holder]
            if (t?.source?.windowID != window.id) {
                val i = t?.tabs?.indexOfFirst { it.windowID == window.id } ?: -1
                if (i >= 0) { edit { it.switchingTab(holder, i) }; focus(holder); return }
            }
        }
        // One window, one tile: choosing a window that's already showing selects its tile,
        // or swaps the two tiles when replacing another one.
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
            val target = replacing ?: if (asNewTile) null else (state.value.active?.takeIf { it in layout.tiles } ?: layout.orderedTileIDs.singleOrNull())
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

    /** Opens an app on the Mac without activating it (explicit action; needs control). */
    fun launch(bundleID: String) {
        if (!inputAllowed) return
        state.update { it.copy(launching = it.launching + bundleID, launchFailed = null) }
        media.session.sendWorkspace(WorkspaceWire.appLaunch(bundleID))
    }

    fun focus(tile: String) {
        media.session.sendWorkspace(WorkspaceWire.focus(tile))
    }

    /** The hardware pointer at a normalized canvas point: hover only, never focus. */
    fun hover(x: Double?, y: Double?) {
        val id = if (x == null || y == null) null else frames().tiles.entries.firstOrNull { it.value.contains(WPoint(x, y)) }?.key
        setHovered(id)
    }

    fun setHovered(tile: String?) {
        if (state.value.hovered != tile) state.update { it.copy(hovered = tile) }
    }

    /** The first touch in a pane selects it (typing goes there), also in View Only. */
    fun selectTile(at: WPoint) {
        val id = frames().tiles.entries.firstOrNull { it.value.contains(at) }?.key ?: return
        if (state.value.layout.tiles[id]?.source != null && state.value.active != id) focus(id)
    }

    // MARK: Per-pane zoom

    private data class ZoomGesture(val tile: String, val start: WPaneZoom?, val rect: WRect, val drawn: WRect?)
    private var zoomGesture: ZoomGesture? = null

    /**
     * One pane's instant local zoom ([gesture] changes with each new gesture): the picture it showed
     * when the gesture began, moved with the fingers, over the pane's whole-source [backdrop] where
     * that picture doesn't reach. [composed]: the Mac's frame with the final view is out.
     */
    data class ZoomPreviewState(val gesture: Int, val preview: WZoomPreview, val backdrop: ImageBitmap?, val composed: Boolean)
    private val zoomPreviewState = MutableStateFlow<ZoomPreviewState?>(null)
    val zoomPreview: StateFlow<ZoomPreviewState?> = zoomPreviewState.asStateFlow()
    private var zoomGestures = 0
    private val clearZoomPreview = Runnable { zoomPreviewState.value = null }
    /** Bounded: the live video takes over after this even if the Mac's echo never comes. */
    private val zoomPreviewDeadline = Runnable { main.removeCallbacks(clearZoomPreview); zoomPreviewState.value = null }

    /**
     * Each pane's view counter: bumped when its zoom, fit, rotation or frame changes, sent with the
     * request, echoed by the Mac once a frame with that view went out (`workspaceView`).
     */
    private val viewEpochs = HashMap<String, Int>()
    private val viewSignatures = HashMap<String, String>()
    private var nextViewEpoch = 1
    private val composedViewEpochs = HashMap<String, Int>()

    /** Each pane's whole source as a still (from the Mac), for zooming out and panning instantly. */
    private data class Backdrop(val windowID: Long, val image: ImageBitmap, val stale: Boolean)
    private val backdrops = HashMap<String, Backdrop>()
    private var backdropReq = 0
    private val backdropAskedAt = HashMap<String, Long>()

    /**
     * Two-finger pinch/pan in Window mode; points normalized to the picture. Only the pane under the
     * fingers where the gesture began changes. A pinch zooms it from 0.7x to 8x of its Fit (or Fill)
     * size around the fingers; a two-finger pan moves a pane that is zoomed or filled (otherwise it
     * stays a scroll on the Mac).
     */
    fun pinch(began: Boolean, ended: Boolean, isPinch: Boolean, initial: WPoint, current: WPoint, scale: Double): Boolean {
        if (began || zoomGesture == null) {
            main.removeCallbacks(clearZoomPreview)
            main.removeCallbacks(zoomPreviewDeadline)
            zoomPreviewState.value = null
            val (id, rect) = frames().tiles.entries.firstOrNull { it.value.contains(initial) }?.toPair() ?: run { zoomGesture = null; return false }
            val tile = state.value.layout.tiles[id]
            if (tile?.source == null || !(isPinch || tile.zoom != null || effectiveFit(id) == WFit.Fill) || windowSize(tile) == null) {
                zoomGesture = null; return false
            }
            zoomGesture = ZoomGesture(id, tile.zoom, rect, drawnSourceRect(tile, rect))
            zoomGestures += 1
            if (state.value.active != id) focus(id)
            requestBackdrop(id)
        }
        val g = zoomGesture ?: return false
        val tile = state.value.layout.tiles[g.tile] ?: return false
        val source = windowSize(tile) ?: return false
        val pane = WSize(g.rect.width * size.width, g.rect.height * size.height)
        fun inPane(p: WPoint) = WPoint((p.x - g.rect.x) / max(g.rect.width, 1e-6), (p.y - g.rect.y) / max(g.rect.height, 1e-6))
        val zoom = WZoom.pinched(g.start, pane, source, tile.rotation, effectiveFit(g.tile), scale, inPane(initial), inPane(current))
        val next = saved.zooming(g.tile, zoom)
        if (next != saved) {
            saved = next
            publish(); scheduleThrottledSend()
        }
        val start = g.drawn
        val now = next.tiles[g.tile]?.let { drawnSourceRect(it, g.rect) }
        val preview = if (start != null && now != null) {
            WZoomPreview.between(g.tile, g.rect, start, now, tile.rotation, tile.source?.windowID ?: 0)
        } else null
        zoomPreviewState.value = preview?.let { ZoomPreviewState(zoomGestures, it, backdrop(g.tile), composed = false) }
        if (ended) {
            zoomGesture = null
            persist()
            // The final view goes now (its epoch is what the preview waits for), not on the next tick.
            main.removeCallbacks(throttledSend); throttledSendPending = false
            sendNow()
            if (zoom != null) requestBackdrop(g.tile, refresh = true)   // fresh for the next gesture
            main.postDelayed(zoomPreviewDeadline, 1_500)
            refreshZoomPreview()
        }
        return true
    }

    /** After the fingers lift: once the Mac's frame with the final view is out, a frame or two for it to decode, then the live video. */
    private fun refreshZoomPreview() {
        val cur = zoomPreviewState.value ?: return
        val composed = zoomGesture == null && viewComposed(cur.preview.tile)
        val next = cur.copy(backdrop = backdrop(cur.preview.tile) ?: cur.backdrop, composed = composed)
        if (next != cur) zoomPreviewState.value = next
        if (composed) {
            main.removeCallbacks(zoomPreviewDeadline)
            main.removeCallbacks(clearZoomPreview)
            main.postDelayed(clearZoomPreview, 70)
        }
    }

    /** The pane's newest view has reached the screen (or there is nothing to wait for). */
    fun viewComposed(tile: String): Boolean {
        val want = viewEpochs[tile] ?: return true
        return (composedViewEpochs[tile] ?: 0) >= want
    }

    /**
     * Where the pane draws its whole source (picture-normalized; larger than the pane when filled
     * or zoomed in, smaller when zoomed out), as the Mac composes it.
     */
    private fun drawnSourceRect(tile: WTile, rect: WRect): WRect? {
        if (size.width <= 0 || size.height <= 0) return null
        val w = windowSize(tile) ?: return null
        val c = TileTransform(WRect(rect.x * size.width, rect.y * size.height, rect.width * size.width, rect.height * size.height),
            w, tile.rotation, tile.fit, tile.zoom ?: WPaneZoom.IDENTITY).contentRect
        return WRect(c.x / size.width, c.y / size.height, c.width / size.width, c.height / size.height)
    }

    /** Two-finger double-tap: the pane under the fingers back to 1x Fit, centred, no rotation. */
    fun resetView(at: WPoint) {
        val id = frames().tiles.entries.firstOrNull { it.value.contains(at) }?.key ?: return
        if (state.value.layout.tiles[id]?.source == null) return
        main.removeCallbacks(clearZoomPreview)
        main.removeCallbacks(zoomPreviewDeadline)
        zoomPreviewState.value = null
        resetView(id)
    }

    private fun windowSize(tile: WTile): WSize? {
        val w = tile.source?.let(::windowItem) ?: return null
        return if (w.width > 0 && w.height > 0) WSize(w.width.toDouble(), w.height.toDouble()) else null
    }

    /** Fit (default) or Fill, as drawn. */
    fun effectiveFit(id: String): WFit = if (state.value.layout.tiles[id]?.fit == WFit.Fill) WFit.Fill else WFit.Fit

    /** Asks the Mac for the pane's whole source (bounded: once a second unless refreshing after a gesture). */
    fun requestBackdrop(id: String, refresh: Boolean = false) {
        if (!state.value.windowMode || state.value.layout.tiles[id]?.source == null) return
        val now = SystemClock.elapsedRealtime()
        if (!refresh && backdropAskedAt[id]?.let { now - it < 1_000 } == true) return
        backdropAskedAt[id] = now
        backdropReq = if (backdropReq >= 1_000_000) 1 else backdropReq + 1
        media.session.sendWorkspace(WorkspaceWire.backdrop(id, 1280, backdropReq))
    }

    /** The pane's whole-source still, when it is of the window the pane shows now. */
    private fun backdrop(id: String): ImageBitmap? {
        val b = backdrops[id] ?: return null
        return b.image.takeIf { b.windowID == state.value.layout.tiles[id]?.source?.windowID }
    }

    private fun onBackdrop(b: WorkspaceBackdrop) {
        val wid = state.value.layout.tiles[b.tile]?.source?.windowID ?: return
        if (b.windowID != wid && b.windowID != 0L) return
        val image = decodeBounded(b.jpegBase64, MAX_BACKDROP_SIDE)?.asImageBitmap() ?: return
        backdrops[b.tile] = Backdrop(wid, image, b.stale)
        if (zoomPreviewState.value?.preview?.tile == b.tile) {
            if (zoomGesture != null) zoomPreviewState.update { it?.copy(backdrop = image) } else refreshZoomPreview()
        }
    }

    private fun onViewEcho(echo: WorkspaceViewEcho) {
        for ((id, epoch) in echo.tiles) composedViewEpochs[id] = max(composedViewEpochs[id] ?: 0, epoch)
        if (zoomGesture == null) refreshZoomPreview()
    }

    /** Bumps a pane's view epoch when what the Mac must draw for it changed. */
    private fun noteViews(layout: WLayout, frames: WFrames) {
        for ((id, tile) in layout.tiles) {
            val r = frames.tiles[id]
            val z = tile.zoom ?: WPaneZoom.IDENTITY
            val sig = "${tile.source?.windowID ?: 0}|${tile.fit}|${tile.rotation}|${z.scale}|${z.centerX}|${z.centerY}|${r?.x}|${r?.y}|${r?.width}|${r?.height}"
            if (viewSignatures[id] != sig) {
                viewSignatures[id] = sig
                viewEpochs[id] = nextViewEpoch
                nextViewEpoch = if (nextViewEpoch >= Int.MAX_VALUE) 1 else nextViewEpoch + 1
            }
        }
        viewEpochs.keys.retainAll(layout.tiles.keys)
        viewSignatures.keys.retainAll(layout.tiles.keys)
    }

    private fun clearViews() {
        viewEpochs.clear(); viewSignatures.clear(); composedViewEpochs.clear()
        backdrops.clear(); backdropAskedAt.clear()
        zoomGesture = null
        main.removeCallbacks(clearZoomPreview); main.removeCallbacks(zoomPreviewDeadline)
        zoomPreviewState.value = null
    }

    /** A pane whose capture failed (or stalled): ask the Mac to start it again now. */
    fun retryTile(id: String) {
        media.session.sendWorkspace(WorkspaceWire.retry(id))
    }

    /** A window macOS keeps paused (Stage Manager's strip): bring it forward on the Mac (needs control). */
    fun showOnMac(id: String) {
        val source = state.value.layout.tiles[id]?.source ?: return
        if (source.isDisplay || !inputAllowed) return
        media.session.sendWorkspace(WorkspaceWire.activate(source.windowID, source.generation ?: return))
    }

    // MARK: Tabs and drops

    fun switchTab(tile: String, index: Int) {
        edit { it.switchingTab(tile, index) }
        focus(tile)
    }

    fun removeTab(tile: String, index: Int) = edit { it.removingTab(tile, index) }

    /** A window dropped from Stage Peek: replace a pane's window, add it as a tab, split a pane, or fill an empty slot. */
    fun drop(window: CatalogWindow, target: WWindowDrop) {
        val source = source(window) ?: return
        if (!state.value.windowMode) media.session.requestDisplayMode(DisplayMode.Window)
        var focusTile: String? = null
        edit { l -> dropping(source, target, l).also { focusTile = it.second }.first }
        focusTile?.let(::focus)
    }

    /** One window shows in one pane only: it leaves the pane (or tab) it was in. */
    private fun dropping(source: WSource, target: WWindowDrop, start: WLayout): Pair<WLayout, String?> {
        var l = start
        l.tileHolding(source.host, source.windowID)?.let { holder ->
            if (target is WWindowDrop.Replace && target.tile == holder) return l to holder
            if (target is WWindowDrop.Tab && target.tile == holder) {
                val i = l.tiles[holder]?.tabs?.indexOfFirst { it.windowID == source.windowID } ?: -1
                if (i >= 0) l = l.switchingTab(holder, i)
                return l to holder
            }
            l = detach(source, holder, l)
        }
        return when (target) {
            is WWindowDrop.Replace -> l.replacingSource(target.tile, source) to target.tile
            is WWindowDrop.Tab -> l.addingTab(source, target.tile) to target.tile
            is WWindowDrop.Split -> {
                val id = "w${nextTile++}"
                if (l.tiles.size < state.value.capacity) l.insertingSplit(WTile(id, source), target.index, target.edge) to id
                else {
                    val holder = WLayout.slotAt(l.root, target.index)
                    (holder?.let { l.addingTab(source, it) } ?: l) to holder
                }
            }
            is WWindowDrop.EmptySlot -> {
                val id = "w${nextTile++}"
                l.filling(target.index, WTile(id, source)) to id
            }
        }
    }

    /** A pane's label dragged elsewhere: onto another pane's labels = merge as tabs, onto an edge = move the pane there, onto a pane's middle = swap. [tab] moves just that tab. */
    fun dropTile(id: String, tab: Int?, target: WWindowDrop) {
        val moving = state.value.layout.tiles[id] ?: return
        val windows = if (tab != null) listOfNotNull(moving.tabs.getOrNull(tab)) else moving.windows
        if (windows.isEmpty()) return
        edit { start ->
            var l = start
            when {
                target is WWindowDrop.Tab && target.tile != id -> {
                    for (s in windows) { l = detach(s, id, l); l = l.addingTab(s, target.tile) }
                    l
                }
                target is WWindowDrop.Replace && target.tile != id -> {
                    if (tab != null) { val s = windows.first(); l = detach(s, id, l); l.addingTab(s, target.tile) }
                    else l.swapping(id, target.tile)
                }
                target is WWindowDrop.Split -> {
                    if (tab != null && l.tiles.size < state.value.capacity) {
                        val s = windows.first()
                        l = detach(s, id, l)
                        l.insertingSplit(WTile("w${nextTile++}", s), target.index, target.edge)
                    } else l.materializing(hinge).moving(id, WDropTarget.Split(target.index, target.edge, target.preview))
                }
                target is WWindowDrop.EmptySlot -> l.materializing(hinge).moving(id, WDropTarget.Slot(target.index, target.preview))
                else -> l
            }
        }
    }

    /** Takes a window out of a pane (a tab leaves; a single-window pane is removed). */
    private fun detach(s: WSource, id: String, l: WLayout): WLayout {
        val tile = l.tiles[id] ?: return l
        val i = tile.tabs.indexOfFirst { it.host == s.host && it.windowID == s.windowID }
        if (i >= 0) return l.removingTab(id, i)
        return if (tile.source?.windowID == s.windowID) l.removing(id) else l
    }

    /** Where a dragged window or label would land (normalized picture point). */
    fun windowDrop(p: WPoint, labelHeight: Double): WWindowDrop? =
        WGeometry.windowDrop(p, state.value.layout, frames(), size, labelHeight, state.value.layout.tiles.size < state.value.capacity)

    /** Mirror/Extend: the picture is one pane showing the desktop, so a window dragged onto it lands beside it. */
    private fun desktopLayout(): WLayout? {
        val host = host ?: return null
        val d = mainDisplay ?: return null
        return WLayout.preset(WPreset.Single, listOf(WTile("w$nextTile", WSource(host, WSource.displayKey(d.id)))))
    }

    // MARK: Dragging windows and labels onto panes

    fun beginDrag(item: WorkspaceDrag.Item, at: CGPoint) = state.update { it.copy(drag = WorkspaceDrag(item, at)) }
    fun moveDrag(to: CGPoint) { if (state.value.drag != null) state.update { it.copy(drag = it.drag?.copy(location = to)) } }
    fun cancelDrag() = state.update { it.copy(drag = null) }

    fun overCancelZone(p: CGPoint): Boolean = !cancelZone.isEmpty && cancelZone.insetBy(-8.0, -8.0).contains(p)

    /** The drop under the finger. Null outside the picture and over Cancel. In Mirror/Extend the desktop counts as one pane. */
    fun dropTarget(p: CGPoint, labelHeight: Double = 30.0): WWindowDrop? {
        if (overCancelZone(p)) return null
        val s = state.value
        if (!s.windowMode) {
            if (s.drag?.item !is WorkspaceDrag.Item.Window) return null
            val g = desktopFrame
            if (g.isEmpty || !g.contains(p)) return null
            // No display listed (an older Mac): the window simply shows in Window mode.
            val desk = desktopLayout() ?: return WWindowDrop.Replace(NO_DESKTOP, WRect(0.0, 0.0, 1.0, 1.0))
            val sz = WSize(g.width, g.height)
            return WGeometry.windowDrop(WPoint((p.x - g.minX) / g.width, (p.y - g.minY) / g.height), desk, WGeometry.frames(desk, sz), sz, labelHeight / g.height, true)
        }
        val g = pictureFrame
        if (g.isEmpty || !g.contains(p)) return null
        return windowDrop(WPoint((p.x - g.minX) / g.width, (p.y - g.minY) / g.height), labelHeight / g.height)
    }

    /** Ends a drag: drops onto the pane under the finger. On Cancel or outside the picture nothing changes. Returns whether anything changed. */
    fun endDrag(): Boolean {
        val d = state.value.drag ?: return false
        val target = dropTarget(d.location)
        state.update { it.copy(drag = null) }
        target ?: return false
        return when (val item = d.item) {
            is WorkspaceDrag.Item.Window -> {
                if (!state.value.windowMode) {
                    // Mirror/Extend: Window mode starts with the desktop and the window as dropped.
                    val desk = desktopLayout() ?: run { choose(item.window, asNewTile = false); return true }
                    val source = source(item.window) ?: return false
                    nextTile++ // the desktop pane's id
                    val (next, focusTile) = dropping(source, target, desk)
                    history.record(saved)
                    saved = next.compacted()
                    state.update { it.copy(localFullscreen = null) }
                    refreshMissing(); persist(); publish()
                    media.session.requestDisplayMode(DisplayMode.Window)
                    focusTile?.let(::focus)
                    true
                } else {
                    drop(item.window, target); true
                }
            }
            is WorkspaceDrag.Item.Pane -> { dropTile(item.tile, item.tab, target); true }
        }
    }

    // MARK: Local fullscreen (receiver only)

    fun enterLocalFullscreen(tile: String) {
        if (tile !in state.value.layout.tiles) return
        state.update { it.copy(localFullscreen = tile) }
        publish(); scheduleSend(0)
        focus(tile)
    }

    fun exitLocalFullscreen() {
        if (state.value.localFullscreen == null) return
        state.update { it.copy(localFullscreen = null) }
        publish(); scheduleSend(0)
    }

    fun noteSurfaceTouch() { if (state.value.localFullscreen != null) state.update { it.copy(touchPulse = it.touchPulse + 1) } }

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
        if (open) startRefreshing() else thumbnailPriority = emptyList()
    }

    fun setLaunchpadOpen(open: Boolean) {
        if (state.value.launchpadOpen == open) return
        state.update { it.copy(launchpadOpen = open) }
        if (open) startRefreshing()
    }

    fun setRailEdge(edge: RailEdge) {
        prefs.edit { putString(RAIL_EDGE, edge.name) }
        state.update { it.copy(railEdge = edge) }
    }

    fun setArranging(on: Boolean) = state.update { it.copy(arranging = on) }

    /** While any browser is open (in every display mode): catalog every few seconds, stills as cards appear, the app list once. */
    private fun startRefreshing() {
        main.removeCallbacks(refreshRunnable)
        requestCatalog()
        requestApps()
        main.postDelayed(refreshRunnable, 3_000)
    }

    // MARK: Sending

    private fun scheduleSend(delayMs: Long = 60) {
        main.removeCallbacks(sendRunnable)
        main.postDelayed(sendRunnable, delayMs)
    }

    /** Continuous changes (a pinch): send at a steady ~30/s while they keep coming. */
    private fun scheduleThrottledSend() {
        if (throttledSendPending) return
        throttledSendPending = true
        main.postDelayed(throttledSend, 33)
    }

    private fun sendNow() {
        val host = host ?: return
        val s = state.value
        if (!s.windowMode) return
        if (s.catalog == null) { catalogAwaitingSend = true; requestCatalog(); return }
        // A tile whose window is gone is kept (and marked) but not sent.
        val sendable = s.missing.fold(s.layout) { l, id -> l.replacingSource(id, null) }
        val frames = WGeometry.frames(sendable, size, hinge)
        noteViews(sendable, frames)
        val ok = media.session.sendWorkspace(WorkspaceWire.workspaceRequest(sendable, frames, host, s.active,
            displayID = { display(it)?.id }, viewEpoch = { viewEpochs[it] }))
        if (!ok) Log.i(TAG, "workspace request not sent (not admitted or no Window mode)")
    }

    private fun persist() {
        val host = host ?: return
        prefs.edit { putString(LAYOUT + host, WLayoutRecord.encode(saved).toString()) }
    }

    private companion object {
        const val TAG = "MeowWorkspace"
        /** The drop target when no display can join the window (it then shows alone). */
        const val NO_DESKTOP = "\u0000desktop"
        const val LAYOUT = "layout."
        const val SAVED = "savedLayouts."
        const val RAIL_EDGE = "railEdge"
        const val FILES_STYLE = "files.style"
        const val MENU_BAR = "menuBar"
        const val MAX_THUMBS = 72
        const val MAX_ICONS = 400
        const val MAX_THUMB_SIDE = 640
        const val MAX_ICON_SIDE = 128
        /** A pane's whole-source still for instant zoom (the Mac sends at most 1600 wide). */
        const val MAX_BACKDROP_SIDE = 1600
        /** Refuse anything that would decode to more than 16 MP, whatever its file size. */
        const val MAX_DECODE_PIXELS = 4096L * 4096L
    }
}
