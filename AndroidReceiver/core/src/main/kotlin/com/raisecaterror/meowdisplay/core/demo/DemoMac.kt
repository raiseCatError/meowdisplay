package com.raisecaterror.meowdisplay.core.demo

import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.CGSize
import com.raisecaterror.meowdisplay.core.controls.ReceiverGesture
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import com.raisecaterror.meowdisplay.core.session.MediaLink
import com.raisecaterror.meowdisplay.core.session.WireProtocol
import com.raisecaterror.meowdisplay.core.workspace.TileTransform
import com.raisecaterror.meowdisplay.core.workspace.WPaneZoom
import com.raisecaterror.meowdisplay.core.workspace.WFit
import com.raisecaterror.meowdisplay.core.workspace.WPoint
import com.raisecaterror.meowdisplay.core.workspace.WRect
import com.raisecaterror.meowdisplay.core.workspace.WRotation
import com.raisecaterror.meowdisplay.core.workspace.WSize
import com.raisecaterror.meowdisplay.core.workspace.AppMenuWire
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesWire
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceWire
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** A tile the demo Mac accepted (Window mode), canvas-normalized. */
data class DemoTile(
    val id: String, val kind: DemoWindowKind, val frame: WRect, val rotation: WRotation, val fit: WFit,
    val zoom: WPaneZoom = WPaneZoom.IDENTITY,
    /** The receiver's view counter for this pane, echoed once the demo Mac has drawn it. */
    val view: Int? = null,
)

/** Everything the demo screen draws, one immutable snapshot per change. */
data class DemoScene(
    val mode: DisplayMode,
    /** Desktop (Mirror/Extend) or canvas (Window) size in points. */
    val size: CGSize,
    val windows: List<DemoWindow>,
    val focused: DemoWindowKind?,
    val selectedFile: String?,
    val previewFile: String,
    val previewZoom: Double,
    val notes: String,
    val highlightedDisplay: Int,
    val showingDesktop: Boolean,
    val hasDock: Boolean,
    val tiles: List<DemoTile>,
    val activeTile: String?,
    val scrollOffsets: Map<DemoWindowKind, Double>,
    val videoEnabled: Boolean,
    /** Video pixels the demo Mac reports (videoState). */
    val videoWidth: Int,
    val videoHeight: Int,
)

/** One feedback chip; [generation] changes for every event, even a repeated text. */
data class DemoFeedbackEvent(val feedback: DemoFeedback, val generation: Long)

/**
 * The Mac side of Explore Demo, in process. It speaks the sender half of the
 * session protocol (PROTOCOL.md 6, 6.9, 6.10) to a real [ReceiverSession]
 * through [link], so the receiver's own admission, input gate, controls,
 * Stage Peek and workspace run unchanged against it. It never touches a
 * socket, a pin store or a preference: the session it talks to is a
 * separate, demo-only instance whose only "pin" is [PEER_ID]'s placeholder.
 *
 * Replies are posted ([post]) rather than delivered inside the session's
 * own call, like a real network round trip. Single-threaded: everything
 * here runs on [post]'s thread.
 */
class DemoMac(
    private val post: (() -> Unit) -> Unit,
    /** Base64 JPEG of a window at most [Int] pixels wide, for the window picker; null: none. */
    private val thumbnail: (DemoWindowKind, Int) -> String? = { _, _ -> null },
    /** Base64 PNG app icon; null: none. */
    private val appIcon: (DemoWindowKind) -> String? = { null },
    private val now: () -> Long = System::currentTimeMillis,
) {
    private var deliver: ((ByteArray) -> Unit)? = null
    private var panelWide = 1280
    private var panelHigh = 800
    private var receiverSpeaksWorkspace = false
    private var greeted = false
    private var admitted = false
    private var inviteSequence = 0
    private var pendingInvitation: String? = null
    private var inputGranted = false
    private var videoEnabled = true
    private var audioEnabled = false
    private var mode = DisplayMode.Mirror
    private val desktop = DemoDesktop(mode, DemoDesktop.desktopSize(mode, panelWide, panelHigh))
    private var tiles: List<DemoTile> = emptyList()
    private var activeTile: String? = null
    private var cursor = CGPoint(0.5, 0.5)
    private var cursorSequence = 0L
    private var leftDown = false
    private var dragging: DemoWindowKind? = null
    private var pressTile: String? = null
    private val heldModifiers = linkedSetOf<String>()
    private var feedbackGeneration = 0L
    private var closed = false

    private val sceneState = MutableStateFlow(snapshot())
    val scene: StateFlow<DemoScene> = sceneState.asStateFlow()
    private val feedbackState = MutableStateFlow<DemoFeedbackEvent?>(null)
    val feedback: StateFlow<DemoFeedbackEvent?> = feedbackState.asStateFlow()

    /** The receiver's end of the demo connection: what the session sends lands in [receive]. */
    val link: MediaLink = object : MediaLink {
        override val peerID: String = PEER_ID
        override fun send(payload: ByteArray): Boolean {
            if (closed) return false
            val copy = payload.copyOf()
            post { receive(copy) }
            return true
        }
        override fun close() {
            closed = true
        }
    }

    /** Where the demo Mac's frames go (the session's `onFrame` for [link]). */
    fun attach(deliver: (ByteArray) -> Unit) {
        this.deliver = deliver
        closed = false
    }

    // MARK: - From the receiver

    internal fun receive(payload: ByteArray) {
        if (closed) return
        val obj = try {
            Json.parseToJsonElement(String(payload, Charsets.UTF_8)) as? JsonObject
        } catch (_: Exception) {
            null
        } ?: return
        when (obj.str("type")) {
            "hello" -> hello(obj)
            "sessionInviteResponse" -> if (obj.str("id") == pendingInvitation && obj.str("result") == "accepted") admit()
            "ping" -> send(buildJsonObject { put("type", "pong"); put("t", obj.num("t") ?: 0.0); put("mt", now().toDouble()) })
            "allowInputRequest" -> if (admitted) {
                inputGranted = obj.bool("allowed") == true
                releasePointer()
                sendInputState()
                show(DemoFeedback.Local(if (inputGranted) "Control allowed by the demo Mac" else "View Only"))
            }
            "audioRequest" -> if (admitted) {
                audioEnabled = obj.bool("enabled") == true
                send(buildJsonObject { put("type", "audioState"); put("enabled", audioEnabled) })
            }
            "videoRequest" -> if (admitted) {
                videoEnabled = obj.bool("enabled") != false
                sendVideoState()
                publish()
            }
            "displayModeRequest" -> if (admitted) DisplayMode.of(obj.str("mode"))?.let(::switchMode)
            "pointer", "touch", "scroll", "keyboard", "gesture", "nativeAppGesture" -> if (admitted && inputGranted) input(obj)
            WorkspaceWire.CATALOG_REQUEST -> if (admitted && windowModeOffered) sendCatalog()
            WorkspaceWire.THUMBNAIL_REQUEST -> if (admitted && windowModeOffered) sendThumbnails(obj)
            WorkspaceWire.WORKSPACE_REQUEST -> if (admitted && windowModeOffered) workspace(obj)
            WorkspaceWire.WORKSPACE_BACKDROP_REQUEST -> if (admitted && windowModeOffered && mode == DisplayMode.Window) sendBackdrop(obj)
            // Sample windows never stall: a retry just reports them live again.
            WorkspaceWire.WORKSPACE_RETRY -> if (admitted && windowModeOffered) sendWorkspaceState(emptyMap())
            WorkspaceWire.WORKSPACE_FOCUS -> if (admitted && windowModeOffered) {
                activeTile = obj.str("tile")?.takeIf { id -> tiles.any { it.id == id } }
                focusActiveTile()
                sendWorkspaceState(emptyMap())
                publish()
            }
            WorkspaceWire.WINDOW_ACTION -> if (admitted && inputGranted && windowModeOffered) windowAction(obj)
            WorkspaceWire.WINDOW_CLOSE -> if (admitted && windowModeOffered) closeSample(obj)
            AppMenuWire.REQUEST, AppMenuWire.PRESS -> if (admitted && windowModeOffered && mode == DisplayMode.Window) {
                val app = tiles.firstOrNull { it.id == obj.str("tile") }?.kind?.title
                send(DemoMenus.answer(obj, app, inputGranted) { what -> show(DemoFeedback.Local("Chose $what in $app on the demo Mac")) })
            }
            RemoteFilesWire.REQUEST -> if (admitted && windowModeOffered) {
                DemoFiles.answer(obj, inputGranted) { name -> show(DemoFeedback.Local("Opened $name on the demo Mac")) }.forEach(::send)
            }
            else -> Unit // kf, stats, keyboardState, closing, sleeping, smartTouchProbe: nothing to do
        }
    }

    private val windowModeOffered get() = receiverSpeaksWorkspace

    private fun hello(obj: JsonObject) {
        val wide = obj.int("pixelsWide")?.takeIf { it in 1..16384 } ?: panelWide
        val high = obj.int("pixelsHigh")?.takeIf { it in 1..16384 } ?: panelHigh
        receiverSpeaksWorkspace = obj["ws"] != null
        val resized = wide != panelWide || high != panelHigh
        panelWide = wide
        panelHigh = high
        if (!greeted) {
            greeted = true
            desktop.reconfigure(mode, DemoDesktop.desktopSize(mode, panelWide, panelHigh))
            send(buildJsonObject {
                put("type", "welcome")
                put("pv", WireProtocol.VERSION)
                put("min", 1)
                put("features", buildJsonArray {
                    if (receiverSpeaksWorkspace) {
                        add(JsonPrimitive(WorkspaceWire.WELCOME_FEATURE)); add(JsonPrimitive(RemoteFilesWire.WELCOME_FEATURE))
                        add(JsonPrimitive(AppMenuWire.WELCOME_FEATURE)); add(JsonPrimitive(WorkspaceWire.CLOSE_FEATURE))
                    }
                })
            })
            invite()
        } else if (resized) {
            desktop.reconfigure(mode, DemoDesktop.desktopSize(mode, panelWide, panelHigh))
            if (admitted) sendVideoState()
            publish()
        }
    }

    private fun invite() {
        val id = "demo-${++inviteSequence}"
        pendingInvitation = id
        send(buildJsonObject {
            put("type", "sessionInvite")
            put("id", id)
            put("initiator", "sender")
            put("intent", "automatic")
            put("mode", mode.wire)
        })
    }

    private fun admit() {
        if (admitted) return
        admitted = true
        pendingInvitation = null
        // The demo Mac allows control from the start, like a Mac whose user already said yes.
        inputGranted = true
        send(buildJsonObject { put("type", "displayModeState"); put("mode", mode.wire) })
        sendVideoState()
        send(buildJsonObject { put("type", "audioState"); put("enabled", audioEnabled) })
        sendInputState()
        sendCursor()
        publish()
    }

    // MARK: - Modes

    private fun switchMode(requested: DisplayMode) {
        val next = if (requested == DisplayMode.Window && !windowModeOffered) DisplayMode.Mirror else requested
        releasePointer()
        mode = next
        desktop.reconfigure(mode, DemoDesktop.desktopSize(mode, panelWide, panelHigh))
        if (mode != DisplayMode.Window) activeTile = null
        send(buildJsonObject { put("type", "displayModeState"); put("mode", mode.wire) })
        sendVideoState()
        if (mode == DisplayMode.Window) sendWorkspaceState(emptyMap())
        show(DemoFeedback.Local(when (mode) {
            DisplayMode.Mirror -> "Mirror: the sample Mac's own display"
            DisplayMode.Extend -> "Extend: a second desktop beside the sample Mac"
            DisplayMode.Window -> "Windows: pick sample windows to show side by side"
        }))
        publish()
    }

    private val videoSize: Pair<Int, Int> get() {
        val s = desktop.size
        return if (mode == DisplayMode.Mirror) (s.width * 2).roundToInt() to (s.height * 2).roundToInt() else panelWide to panelHigh
    }

    // MARK: - Input

    private fun input(obj: JsonObject) {
        when (obj.str("type")) {
            "pointer" -> pointer(obj)
            "touch" -> {
                val x = obj.num("x") ?: return
                val y = obj.num("y") ?: return
                when (obj.str("phase")) {
                    "began" -> { moveCursor(x, y); press(1) }
                    "moved" -> moveCursor(x, y)
                    "ended", "cancelled" -> { moveCursor(x, y); releasePointer() }
                }
            }
            "scroll" -> scroll(obj.num("dy") ?: 0.0)
            "keyboard" -> keyboard(obj)
            "gesture" -> gesture(obj.str("name"))
            "nativeAppGesture" -> if (obj.str("phase") == "began") {
                show(DemoFeedback.OnMac(if (obj.str("kind") == "rotate") "Rotate in the front app" else "Zoom in the front app"))
            }
        }
        publish()
    }

    private fun pointer(obj: JsonObject) {
        when (obj.str("action")) {
            "move" -> moveCursor(obj.num("x") ?: return, obj.num("y") ?: return)
            "moveRelative" -> {
                val (w, h) = videoSize
                moveCursor(cursor.x + (obj.num("dx") ?: 0.0) / max(w, 1), cursor.y + (obj.num("dy") ?: 0.0) / max(h, 1))
            }
            "down" -> when (obj.str("button")) {
                "left" -> press(obj.int("clickCount") ?: 1)
                "right" -> show(DemoFeedback.OnMac("Secondary click: the app's shortcut menu opens on a Mac"))
            }
            "up" -> if (obj.str("button") == "left") releasePointer()
        }
    }

    private fun moveCursor(x: Double, y: Double) {
        val nx = min(max(x, 0.0), 1.0)
        val ny = min(max(y, 0.0), 1.0)
        val dragged = dragging
        if (leftDown && dragged != null && mode != DisplayMode.Window) {
            desktop.moveWindow(dragged, (nx - cursor.x) * desktop.size.width, (ny - cursor.y) * desktop.size.height)
        }
        cursor = CGPoint(nx, ny)
        sendCursor()
    }

    private fun desktopPoint(): CGPoint = CGPoint(cursor.x * desktop.size.width, cursor.y * desktop.size.height)

    /** The tile under the cursor and the cursor in that window's own points. */
    private fun tileHit(): Pair<DemoTile, CGPoint>? {
        val canvas = desktop.size
        val p = WPoint(cursor.x * canvas.width, cursor.y * canvas.height)
        for (tile in tiles) {
            val transform = transform(tile)
            val local = transform.sourcePoint(p) ?: continue
            return tile to CGPoint(local.x, local.y)
        }
        return null
    }

    fun transform(tile: DemoTile): TileTransform {
        val canvas = desktop.size
        return TileTransform(tile.frame.scaled(WSize(canvas.width, canvas.height)), WSize(tile.kind.nativeWidth, tile.kind.nativeHeight), tile.rotation, tile.fit, tile.zoom)
    }

    private fun press(clickCount: Int) {
        leftDown = true
        if (mode == DisplayMode.Window) {
            val (tile, local) = tileHit() ?: return
            pressTile = tile.id
            if (activeTile != tile.id) {
                activeTile = tile.id
                sendWorkspaceState(emptyMap())
            }
            desktop.clickInWindow(tile.kind, local, clickCount >= 2)?.let(::show)
            return
        }
        val point = desktopPoint()
        val hit = desktop.hit(point)
        if (hit is DemoHit.TitleBar && clickCount < 2) {
            desktop.raise(hit.kind)
            dragging = hit.kind
            return
        }
        (if (clickCount >= 2) desktop.doubleClick(point) else desktop.click(point))?.let(::show)
    }

    private fun releasePointer() {
        leftDown = false
        dragging = null
        pressTile = null
    }

    private fun scroll(dy: Double) {
        val (_, h) = videoSize
        // Natural-scrolling sign: fingers up (negative dy) move the content up, showing what is below.
        val content = -dy * desktop.size.height / max(h, 1)
        if (mode == DisplayMode.Window) {
            val (tile, _) = tileHit() ?: return
            desktop.scrollInWindow(tile.kind, content)
        } else {
            desktop.scroll(desktopPoint(), content)
        }
    }

    private fun keyboard(obj: JsonObject) {
        when (obj.str("action")) {
            "text" -> {
                val text = obj.str("text")?.take(200) ?: return
                if (!desktop.type(text)) show(DemoFeedback.OnMac("Typing goes to the focused window. Click Notes to type there."))
            }
            "press", "down" -> {
                val usage = obj.int("usage") ?: return
                val mods = (obj["modifiers"] as? JsonArray).orEmpty().mapNotNull { (it as? JsonPrimitive)?.content }.toSet() + heldModifiers
                val result = desktop.key(usage, mods)
                show(result ?: DemoFeedback.OnMac("Sent ${describe(usage, mods)} to your Mac"))
            }
            "modifierDown" -> obj.str("modifier")?.let { heldModifiers += it }
            "modifierUp" -> obj.str("modifier")?.let { heldModifiers -= it }
            "cancel" -> heldModifiers.clear()
        }
    }

    private fun gesture(name: String?) {
        when (val gesture = ReceiverGesture.of(name)) {
            ReceiverGesture.ShowDesktop -> if (mode != DisplayMode.Window) show(desktop.toggleShowDesktop())
            null -> Unit
            else -> show(DemoFeedback.OnMac(when (gesture) {
                ReceiverGesture.MissionControl -> "Mission Control opens on your Mac"
                ReceiverGesture.AppExpose -> "App Exposé opens on your Mac"
                ReceiverGesture.NextSpace -> "Your Mac moves to the next Space"
                ReceiverGesture.PreviousSpace -> "Your Mac moves to the previous Space"
                ReceiverGesture.Launchpad -> "Launchpad opens on your Mac"
                ReceiverGesture.Spotlight -> "Spotlight opens on your Mac"
                ReceiverGesture.ControlCenter -> "Control Center opens on your Mac"
                ReceiverGesture.MenuBar -> "Your Mac shows its menu bar"
                ReceiverGesture.ShowDesktop -> ""
            }))
        }
    }

    // MARK: - Window mode

    private fun sendCatalog() {
        send(buildJsonObject {
            put("type", WorkspaceWire.CATALOG)
            put("host", PEER_ID)
            put("windows", buildJsonArray {
                DemoWindowKind.entries.filter { it !in closedSamples }.forEach { kind ->
                    add(buildJsonObject {
                        put("id", kind.windowID); put("gen", GENERATION); put("bundle", kind.bundleID); put("app", kind.title)
                        put("title", windowTitle(kind)); put("w", kind.nativeWidth.toInt()); put("h", kind.nativeHeight.toInt())
                        put("state", "visible"); put("active", desktop.focused == kind)
                    })
                }
            })
            put("apps", buildJsonArray {
                DemoWindowKind.entries.forEach { kind ->
                    add(buildJsonObject { put("bundle", kind.bundleID); put("name", kind.title); put("windows", true) })
                }
            })
        })
    }

    private fun sendThumbnails(obj: JsonObject) {
        val maxWidth = (obj.int("max") ?: 160).coerceIn(64, 320)
        val ids = (obj["ids"] as? JsonArray).orEmpty().take(24).mapNotNull { (it as? JsonPrimitive)?.longOrNull }
        for (id in ids) {
            val kind = DemoWindowKind.ofWindow(id) ?: continue
            val jpeg = thumbnail(kind, maxWidth.coerceAtMost(320))
            send(buildJsonObject {
                put("type", WorkspaceWire.THUMBNAIL); put("id", id); put("gen", GENERATION)
                if (jpeg != null) put("jpeg", jpeg) else put("unavailable", true)
            })
        }
        val icons = (obj["icons"] as? JsonArray).orEmpty().take(32).mapNotNull { (it as? JsonPrimitive)?.content }
        for (bundle in icons) {
            val kind = DemoWindowKind.entries.firstOrNull { it.bundleID == bundle } ?: continue
            val png = appIcon(kind) ?: continue
            send(buildJsonObject { put("type", WorkspaceWire.APP_ICON); put("bundle", bundle); put("png", png) })
        }
    }

    private fun workspace(obj: JsonObject) {
        val rejected = linkedMapOf<String, String>()
        val accepted = mutableListOf<DemoTile>()
        for (t in (obj["tiles"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }) {
            val id = t.str("id")?.takeIf { it.matches(TILE_ID) } ?: continue
            if (t.str("host") != PEER_ID) continue
            val kind = t.long("window")?.let(DemoWindowKind::ofWindow)
            val frame = WRect(t.num("x") ?: -1.0, t.num("y") ?: -1.0, t.num("w") ?: 0.0, t.num("h") ?: 0.0)
            when {
                kind == null || (t.long("gen") ?: GENERATION) != GENERATION -> rejected[id] = "unavailable"
                accepted.size >= MAX_TILES -> rejected[id] = "limit"
                frame.width <= 0 || frame.height <= 0 || frame.x < -EPS || frame.y < -EPS || frame.maxX > 1 + EPS || frame.maxY > 1 + EPS -> rejected[id] = "geometry"
                accepted.any { it.kind == kind } -> rejected[id] = "duplicate"
                accepted.any { it.frame.intersection(frame)?.let { r -> r.area > EPS } == true } -> rejected[id] = "overlap"
                else -> accepted += DemoTile(id, kind, frame, WRotation.of(t.int("rotation") ?: 0), WFit.of(t.str("fit")),
                    WPaneZoom.fromWire(t["zoom"]) ?: WPaneZoom.IDENTITY, t.int("view"))
            }
        }
        tiles = accepted
        val focus = obj.str("focus")
        activeTile = when {
            focus != null && accepted.any { it.id == focus } -> focus
            activeTile != null && accepted.any { it.id == activeTile } -> activeTile
            else -> accepted.firstOrNull()?.id
        }
        releasePointer()
        focusActiveTile()
        sendWorkspaceState(rejected)
        publish()
        // Drawn at once here: the receiver's instant zoom can hand over to the picture.
        val views = accepted.mapNotNull { tile -> tile.view?.let { tile.id to it } }
        if (views.isNotEmpty()) send(buildJsonObject {
            put("type", WorkspaceWire.WORKSPACE_VIEW)
            put("tiles", buildJsonObject { views.forEach { (id, v) -> put(id, v) } })
        })
    }

    /** A pane's whole window as a still, for the receiver's instant zoom. */
    private fun sendBackdrop(obj: JsonObject) {
        val tile = tiles.firstOrNull { it.id == obj.str("tile") } ?: return
        val jpeg = thumbnail(tile.kind, (obj.int("max") ?: 1280).coerceIn(320, 1600)) ?: return
        send(buildJsonObject {
            put("type", WorkspaceWire.WORKSPACE_BACKDROP); put("tile", tile.id); put("window", tile.kind.windowID)
            obj.int("req")?.let { put("req", it) }
            put("jpeg", jpeg)
        })
    }

    private fun focusActiveTile() {
        val kind = tiles.firstOrNull { it.id == activeTile }?.kind
        if (mode == DisplayMode.Window) desktop.focus(kind)
    }

    /** Sample windows closed from Stage Peek: gone from the listing until the demo starts again. */
    private val closedSamples = mutableSetOf<DemoWindowKind>()

    /** Close Window from Stage Peek: like the Mac, only with control and only the listed window. */
    private fun closeSample(obj: JsonObject) {
        val id = obj.long("window") ?: return
        val kind = DemoWindowKind.ofWindow(id)
        val result = when {
            !inputGranted -> "control"
            kind == null || kind in closedSamples || obj.long("gen") != GENERATION -> "stale"
            else -> "closed"
        }
        if (result == "closed" && kind != null) {
            closedSamples += kind
            show(DemoFeedback.OnMac("${kind.title} closed on the demo Mac. Sample windows come back when the demo starts again."))
        }
        send(buildJsonObject {
            put("type", WorkspaceWire.WINDOW_CLOSE_RESULT); put("window", id); put("result", result)
            obj.int("req")?.let { put("req", it) }
        })
        if (result == "closed") sendCatalog()
        publish()
    }

    private fun windowAction(obj: JsonObject) {
        val kind = obj.long("window")?.let(DemoWindowKind::ofWindow)
        when (obj.str("action")) {
            "activate" -> {
                val tile = tiles.firstOrNull { it.kind == kind } ?: return
                activeTile = tile.id
                focusActiveTile()
                sendWorkspaceState(emptyMap())
            }
            "close" -> if (kind != null) show(DemoFeedback.OnMac("${kind.title} would close on your Mac. Sample windows stay open."))
            "launch" -> show(DemoFeedback.OnMac("The app would open on your Mac"))
        }
        publish()
    }

    private fun sendWorkspaceState(rejected: Map<String, String>) {
        send(buildJsonObject {
            put("type", WorkspaceWire.WORKSPACE_STATE)
            put("host", PEER_ID)
            put("tiles", buildJsonArray {
                tiles.forEach { tile ->
                    add(buildJsonObject {
                        put("id", tile.id); put("window", tile.kind.windowID); put("gen", GENERATION); put("state", "live")
                        put("app", tile.kind.title); put("bundle", tile.kind.bundleID); put("title", windowTitle(tile.kind))
                        put("follow", "window"); put("rotation", tile.rotation.degrees); put("fit", tile.fit.wire)
                    })
                }
            })
            activeTile?.let { put("active", it) }
            put("hostFocus", if (activeTile != null) "deliver" else "noActiveTile")
            put("rejected", buildJsonObject { rejected.forEach { (k, v) -> put(k, v) } })
            put("canvas", buildJsonObject { put("w", panelWide); put("h", panelHigh) })
            put("limit", MAX_TILES)
        })
    }

    private fun windowTitle(kind: DemoWindowKind): String = when (kind) {
        DemoWindowKind.Notes -> "Welcome"
        DemoWindowKind.Files -> "Documents"
        DemoWindowKind.Preview -> DemoFile.samples.firstOrNull { it.id == desktop.previewFile }?.name ?: "Preview"
        DemoWindowKind.Displays -> "Arrangement"
    }

    // MARK: - To the receiver

    private fun sendVideoState() {
        val (w, h) = videoSize
        send(buildJsonObject { put("type", "videoState"); put("enabled", videoEnabled); put("width", w); put("height", h) })
    }

    private fun sendInputState() =
        send(buildJsonObject { put("type", "allowInputState"); put("allowed", inputGranted); put("state", if (inputGranted) "allowed" else "off") })

    private fun sendCursor() {
        if (!admitted) return
        send(buildJsonObject { put("type", "cursor"); put("x", cursor.x); put("y", cursor.y); put("v", 1); put("s", ++cursorSequence) })
    }

    private fun send(message: JsonObject) {
        if (closed) return
        val bytes = message.toString().toByteArray(Charsets.UTF_8)
        post { if (!closed) deliver?.invoke(bytes) }
    }

    private fun show(feedback: DemoFeedback) {
        feedbackState.value = DemoFeedbackEvent(feedback, ++feedbackGeneration)
    }

    private fun publish() {
        sceneState.value = snapshot()
    }

    private fun snapshot(): DemoScene {
        val (w, h) = videoSize
        return DemoScene(
            mode, desktop.size, desktop.windows, desktop.focused, desktop.selectedFile, desktop.previewFile, desktop.previewZoom,
            desktop.notes, desktop.highlightedDisplay, desktop.showingDesktop, desktop.hasDock, tiles, activeTile,
            DemoWindowKind.entries.associateWith { desktop.scrollOffset(it) }, videoEnabled, w, h,
        )
    }

    companion object {
        /** The demo Mac's identity inside the demo-only session. Never stored, never a real pin. */
        const val PEER_ID = "meowdisplay-demo-mac"
        const val MAC_NAME = "Sample Mac"
        private const val GENERATION = 1L
        private const val MAX_TILES = 9
        private const val EPS = 1e-6
        private val TILE_ID = Regex("[A-Za-z0-9_-]{1,32}")

        fun describe(usage: Int, modifiers: Set<String>): String {
            val symbols = listOf("control" to "⌃", "option" to "⌥", "shift" to "⇧", "command" to "⌘")
                .filter { it.first in modifiers }.joinToString("") { it.second }
            val key = DemoDesktop.character(usage, shift = false)?.uppercase() ?: when (usage) {
                40 -> "Return"; 41 -> "Esc"; 42 -> "Delete"; 43 -> "Tab"; 44 -> "Space"
                79 -> "→"; 80 -> "←"; 81 -> "↓"; 82 -> "↑"
                in 58..69 -> "F${usage - 57}"
                else -> "key"
            }
            return symbols + key
        }
    }
}

private fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
private fun JsonObject.num(k: String): Double? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull?.takeIf { it.isFinite() }
private fun JsonObject.long(k: String): Long? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.let { it.longOrNull ?: it.doubleOrNull?.toLong() }
private fun JsonObject.int(k: String): Int? = long(k)?.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()
private fun JsonObject.bool(k: String): Boolean? = (this[k] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
