package com.raisecaterror.meowdisplay.android.receiver.workspace

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.horizontalScroll
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.ui.layout.positionInParent
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.key
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.RemoteViewportTransform
import com.raisecaterror.meowdisplay.core.workspace.CatalogWindow
import com.raisecaterror.meowdisplay.core.workspace.HostFocus
import com.raisecaterror.meowdisplay.core.workspace.TileStatus
import com.raisecaterror.meowdisplay.core.workspace.WDropTarget
import com.raisecaterror.meowdisplay.core.workspace.WFit
import com.raisecaterror.meowdisplay.core.workspace.WGeometry
import com.raisecaterror.meowdisplay.core.workspace.WPoint
import com.raisecaterror.meowdisplay.core.workspace.WPreset
import com.raisecaterror.meowdisplay.core.workspace.WRect
import com.raisecaterror.meowdisplay.core.workspace.WSize
import com.raisecaterror.meowdisplay.core.workspace.WindowAvailability
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.positionInWindow
import com.raisecaterror.meowdisplay.core.workspace.WRotation
import com.raisecaterror.meowdisplay.core.workspace.WSource
import com.raisecaterror.meowdisplay.core.workspace.WTile
import com.raisecaterror.meowdisplay.core.workspace.WWindowDrop
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.math.roundToInt

private val Accent = Color(0xFF7FB2FF)
private val Chip = Color(0xCC1C1C1E)

/** A tile's rect on screen (dp) from its normalized canvas rect. */
private fun RemoteViewportTransform.viewRect(r: WRect): CGRect {
    val a = viewPoint(CGPoint(r.x, r.y)); val b = viewPoint(CGPoint(r.maxX, r.maxY))
    return CGRect(minOf(a.x, b.x), minOf(a.y, b.y), kotlin.math.abs(b.x - a.x), kotlin.math.abs(b.y - a.y))
}

/**
 * Pane chrome over the live picture (iOS WorkspaceChromeView). Each pane has a strip of labels at
 * its top-left, one per window (tabs side by side, shortened to fit, scrollable by finger only).
 * Tap a label: that pane (or tab) is shown and typing goes there. Hold a label: drag it onto
 * another pane's labels (merge as tabs), an edge (move/split) or a middle (swap); release without
 * moving for the pane's menu. Everything else in a pane goes to the Mac as usual.
 */
/** A pill button under a pane's status text. */
@Composable
private fun PaneButton(label: String, enabled: Boolean, action: () -> Unit) {
    Text(
        label, color = Color.White, style = MaterialTheme.typography.labelLarge,
        modifier = Modifier.background(Chip, CircleShape).border(0.75.dp, Color.White.copy(alpha = 0.25f), CircleShape)
            .clickable(enabled = enabled, onClick = action)
            .padding(horizontal = 14.dp, vertical = 7.dp)
            .graphicsLayer { alpha = if (enabled) 1f else 0.5f },
    )
}

@Composable
fun WorkspaceChrome(
    controller: WorkspaceController,
    transform: RemoteViewportTransform,
    inputAllowed: Boolean,
    /** On-screen controls (window dp): labels and the Arrange bar stay clear of them. */
    avoid: List<CGRect> = emptyList(),
    onSettings: () -> Unit = {},
    /** "View Full Screen" on a desktop pane: back to the full-screen desktop (Mirror/Extend). */
    onViewFullScreen: () -> Unit = {},
) {
    val ui by controller.ui.collectAsState()
    val icons by controller.icons.collectAsState()
    if (!ui.windowMode || !transform.isValid) return
    val frames = controller.frames()
    val density = LocalDensity.current.density
    var confirmClose by remember { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf<PaneMenuTarget?>(null) }
    var layoutsOpen by remember { mutableStateOf(false) }
    var savingLayout by remember { mutableStateOf(false) }
    /** Outside Arrange: the divider held (long press) and being dragged. */
    var heldDivider by remember { mutableStateOf<Pair<List<Int>, Int>?>(null) }
    val chromeView = androidx.compose.ui.platform.LocalView.current
    val screenReader = remember(chromeView) {
        (chromeView.context.getSystemService(android.content.Context.ACCESSIBILITY_SERVICE) as? android.view.accessibility.AccessibilityManager)?.isTouchExplorationEnabled == true
    }
    val multi = ui.layout.tiles.size > 1
    // Labels at the top edge stay clear of the cutout and any visible status bar.
    val topInset = with(LocalDensity.current) { WindowInsets.safeDrawing.getTop(this).toDp().value.toDouble() }
    val railHandle by controller.railHandle
    var box by remember { mutableStateOf(IntSize.Zero) }
    var origin by remember { mutableStateOf(CGPoint.zero) }
    val picture = transform.displayedRect
    LaunchedEffect(picture, origin) { controller.pictureFrame = picture.offsetBy(origin.x, origin.y) }

    Box(
        Modifier.fillMaxSize().onSizeChanged { box = it }
            .onGloballyPositioned { c -> val p = c.positionInWindow(); origin = CGPoint(p.x / density.toDouble(), p.y / density.toDouble()) },
    ) {
        // A pane corner in a corner of the screen follows the screen's rounding; the rest stay square.
        val insets = chromeView.rootWindowInsets
        fun screenCorner(position: Int): Double =
            if (android.os.Build.VERSION.SDK_INT >= 31) (insets?.getRoundedCorner(position)?.radius ?: 0) / density.toDouble() else 0.0
        val rootW = chromeView.rootView.width / density.toDouble()
        val rootH = chromeView.rootView.height / density.toDouble()
        for ((id, rect) in frames.tiles) key(id) {
            val r = transform.viewRect(rect)
            val tile = ui.layout.tiles[id] ?: continue
            val g = r.offsetBy(origin.x, origin.y)
            fun near(a: Double, b: Double) = kotlin.math.abs(a - b) < 2.0
            val left = near(g.minX, 0.0); val top = near(g.minY, 0.0); val right = near(g.maxX, rootW); val bottom = near(g.maxY, rootH)
            val outline = RoundedCornerShape(
                topStart = if (left && top) screenCorner(android.view.RoundedCorner.POSITION_TOP_LEFT).dp else 0.dp,
                topEnd = if (right && top) screenCorner(android.view.RoundedCorner.POSITION_TOP_RIGHT).dp else 0.dp,
                bottomEnd = if (right && bottom) screenCorner(android.view.RoundedCorner.POSITION_BOTTOM_RIGHT).dp else 0.dp,
                bottomStart = if (left && bottom) screenCorner(android.view.RoundedCorner.POSITION_BOTTOM_LEFT).dp else 0.dp,
            )
            val remote = ui.tileState(id)
            val active = ui.active == id
            val hovered = ui.hovered == id && !active
            val border = when {
                active && multi -> BorderStroke(2.dp, Accent)
                hovered -> BorderStroke(1.dp, Color.White.copy(alpha = 0.35f))
                multi -> BorderStroke(0.5.dp, Color.White.copy(alpha = 0.12f))
                else -> null
            }
            Box(
                Modifier
                    .offset { IntOffset((r.minX * density).roundToInt(), (r.minY * density).roundToInt()) }
                    .size(r.width.dp, r.height.dp)
                    .let { m -> border?.let { m.border(it, outline) } ?: m },
            ) {
                val desktop = tile.source?.isDisplay == true
                val status = when {
                    // The Mac is drawing this pane's window: never a stale "choose a window" over a live picture.
                    remote?.state == TileStatus.Live && tile.source?.windowID?.let { it == remote.windowID } == true -> null
                    desktop && id in ui.missing -> "This display isn't connected to the Mac now"
                    id in ui.missing || tile.source == null -> "Choose a window for this pane"
                    // Refused by the Mac (e.g. that window already shows in another pane).
                    ui.remote?.rejected?.containsKey(id) == true -> "Tap to choose a window for this pane"
                    remote == null -> null
                    remote.state == TileStatus.Waiting -> "Waiting for ${remote.app.ifEmpty { "the window" }}…"
                    remote.state == TileStatus.Offscreen -> "${remote.app.ifEmpty { "This window" }} is minimized or hidden on the Mac"
                    remote.state == TileStatus.Closed -> "Closed on Mac. Tap to choose another window."
                    remote.state == TileStatus.Failed -> "The Mac stopped sending ${remote.app.ifEmpty { "this window" }}. Tap Retry."
                    remote.state == TileStatus.Limit -> "Paused: too many windows at once"
                    remote.state == TileStatus.Paused -> if (remote.inStageStrip)
                        "${remote.app.ifEmpty { "This window" }} is in Stage Manager's side strip, so macOS pauses its picture. Show it on the Mac, or turn Stage Manager off, to see it live."
                    else "macOS paused ${remote.app.ifEmpty { "this window" }}'s picture. It comes back when the window is shown on the Mac."
                    remote.state == TileStatus.Retrying -> "Reconnecting to ${remote.app.ifEmpty { "the window" }}… (try ${remote.attempt})"
                    else -> null
                }
                if (status != null) {
                    Column(Modifier.align(Alignment.Center).padding(12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        Row(
                            Modifier.background(Chip, RoundedCornerShape(10.dp)).clickable { controller.openOverview(replacing = id) }
                                .padding(horizontal = 12.dp, vertical = 8.dp),
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            // Still working: a live spinner (still with the system's animations off).
                            if (remote?.state == TileStatus.Waiting || remote?.state == TileStatus.Retrying) {
                                androidx.compose.material3.CircularProgressIndicator(Modifier.size(16.dp), color = Color.White, strokeWidth = 2.dp)
                            }
                            Text(status, color = Color.White, style = MaterialTheme.typography.bodyMedium)
                        }
                        // A stalled or failed capture can be started again now (no control needed: nothing on the Mac changes).
                        if (remote?.state == TileStatus.Failed || remote?.state == TileStatus.Retrying) {
                            PaneButton("Retry", enabled = true) { controller.retryTile(id) }
                        }
                        // Stage Manager keeps the window in its strip: only bringing it forward shows it (explicit; needs control).
                        if (remote?.state == TileStatus.Paused && remote.inStageStrip && !desktop) {
                            if (inputAllowed) {
                                if (ui.remote?.stageAddAvailable == true) PaneButton("Add to Current Stage", enabled = true) { controller.addToStage(id) }
                                // Explicit only: switches the Mac to that window's stage (brings its app forward).
                                PaneButton("Show on Mac", enabled = true) { controller.showOnMac(id) }
                                var confirmOff by remember { mutableStateOf(false) }
                                // Offered only when the Mac can actually do it (the owner's shortcuts exist).
                                val smControl = ui.remote?.stageManagerControl
                                if (smControl == "ready" || smControl == "failed") PaneButton("Turn Off Stage Manager", enabled = true) { confirmOff = true }
                                val addProblem = controller.stageAddProblem(id)
                                if (smControl == "failed" || smControl == "setup" || addProblem != null) Text(
                                    addProblem ?: if (smControl == "failed") "macOS didn't turn Stage Manager off. Try again, or turn it off on the Mac."
                                    else "Turn Off Stage Manager: Setup Required. On the Mac, open MeowDisplay Settings ▸ System ▸ Stage Manager and click Set Up Automatically.",
                                    color = Color.White.copy(alpha = 0.85f), style = MaterialTheme.typography.bodySmall,
                                    textAlign = androidx.compose.ui.text.style.TextAlign.Center, modifier = Modifier.widthIn(max = 320.dp),
                                )
                                if (confirmOff) androidx.compose.material3.AlertDialog(
                                    onDismissRequest = { confirmOff = false },
                                    title = { Text("Turn off Stage Manager on the Mac?") },
                                    text = { Text("Windows in its side strip then show live here. MeowDisplay turns Stage Manager back on when Window mode ends.") },
                                    confirmButton = { androidx.compose.material3.TextButton(onClick = { confirmOff = false; controller.turnOffStageManager() }) { Text("Turn Off") } },
                                    dismissButton = { androidx.compose.material3.TextButton(onClick = { confirmOff = false }) { Text("Cancel") } },
                                )
                            } else RequestControlInline()
                        }
                        // A closed window's app can open it again (explicit; needs control).
                        val bundle = remote?.bundleID?.ifEmpty { null } ?: tile.source?.bundleID
                        if (remote?.state == TileStatus.Closed && bundle != null && !desktop) {
                            Text(
                                if (bundle in ui.launching) "Opening on the Mac…" else "Open on Mac", color = Color.White,
                                style = MaterialTheme.typography.labelLarge,
                                modifier = Modifier.background(Chip, CircleShape).border(0.75.dp, Color.White.copy(alpha = 0.25f), CircleShape)
                                    .clickable(enabled = inputAllowed && bundle !in ui.launching) { controller.launch(bundle) }
                                    .padding(horizontal = 14.dp, vertical = 7.dp)
                                    .graphicsLayer { alpha = if (inputAllowed) 1f else 0.5f },
                            )
                        }
                    }
                }
                if (multi || ui.arranging || tile.tabs.isNotEmpty() || ui.localFullscreen == null) {
                    // Where the strip would sit; if the rail handle or a control is there, it moves down below it.
                    val nominal = CGRect(r.minX + 6, maxOf(r.minY, topInset) + 6, minOf(r.width - 12, 200.0), 30.0)
                    val clear = (avoid + listOfNotNull(railHandle)).filter { it.intersects(nominal) }.maxOfOrNull { it.maxY + 4 - nominal.minY } ?: 0.0
                    LabelStrip(
                        controller, ui, id, tile, r, active, icons,
                        top = maxOf(0.0, topInset - r.minY) + clear,
                        onMenu = { tab -> menu = PaneMenuTarget(id, tab) },
                    )
                }
                if (active && ui.remote?.hostFocus?.isMismatch == true) {
                    Text(
                        if (ui.remote?.hostFocus == HostFocus.OtherWindowFocused) "Typing paused: another window is in front on the Mac. Tap to resume."
                        else "Typing paused: another app is in front on the Mac. Tap to resume.",
                        color = Color.White, style = MaterialTheme.typography.labelMedium,
                        modifier = Modifier.align(Alignment.BottomCenter).padding(8.dp).background(Chip, RoundedCornerShape(10.dp))
                            .clickable { controller.focus(id) }.padding(horizontal = 10.dp, vertical = 6.dp),
                    )
                }
            }
        }

        // The focused pane's app menus, as a bar under its label (control only).
        val activeSource = ui.active?.let { ui.layout.tiles[it]?.source }
        // `available` too: after a reconnect the same pane and app need their menus asked for again.
        val menusAvailable = controller.menus.ui.collectAsState().value.available
        LaunchedEffect(ui.active, activeSource?.bundleID, activeSource?.isDisplay, inputAllowed, ui.windowMode, menusAvailable) {
            controller.menus.sync(ui.active, activeSource?.takeIf { !it.isDisplay }?.bundleID, inputAllowed && ui.windowMode)
        }
        val activeRect = ui.active?.let { frames.tiles[it] }?.let { transform.viewRect(it) }
        if (activeRect != null && !ui.arranging && ui.drag == null && (multi || ui.localFullscreen == ui.active)) {
            val nominal = CGRect(activeRect.minX + 6, maxOf(activeRect.minY, topInset) + 6, minOf(activeRect.width - 12, 200.0), 30.0)
            val clear = (avoid + listOfNotNull(railHandle)).filter { it.intersects(nominal) }.maxOfOrNull { it.maxY + 4 - nominal.minY } ?: 0.0
            PaneMenuBar(controller, activeRect, top = nominal.minY + clear + 30 + 4, bounds = picture)
        }

        // Landing areas and Cancel while a label (or a window from Stage Peek) is dragged.
        WorkspaceDropOverlay(controller, origin)

        // Arrange: divider grips and Done.
        if (ui.arranging) {
            for (divider in frames.dividers) key(divider.path, divider.index, divider.axis) {
                val r = transform.viewRect(divider.hitRect)
                val horizontal = divider.axis == com.raisecaterror.meowdisplay.core.workspace.WAxis.Horizontal
                // Keyed by which divider it is, not where it is: each resize step moves the
                // divider, and a changing key would cancel the drag after the first step.
                val current by rememberUpdatedState(divider)
                val scale by rememberUpdatedState(if (horizontal) transform.displayedRect.width else transform.displayedRect.height)
                Box(
                    Modifier.offset { IntOffset((r.minX * density).roundToInt(), (r.minY * density).roundToInt()) }.size(r.width.dp, r.height.dp)
                        .pointerInput(divider.path, divider.index, divider.axis) {
                            detectDragGestures(
                                onDragEnd = controller::endResize,
                                onDragCancel = controller::endResize,
                            ) { change, amount ->
                                change.consume()
                                val delta = (if (horizontal) amount.x else amount.y) / density / scale
                                controller.resize(current, delta.toDouble())
                            }
                        }
                        .semantics { contentDescription = "Resize panes" },
                    contentAlignment = Alignment.Center,
                ) {
                    Box(Modifier.size(if (horizontal) 6.dp else 44.dp, if (horizontal) 44.dp else 6.dp).background(Color.White.copy(alpha = 0.85f), CircleShape))
                }
            }
            // Lifted above any control sitting at the bottom centre (the collapsed tray's button).
            val band = CGRect(box.width / density / 2.0 - 110, box.height / density - 24.0 - 48, 220.0, 48.0)
            val lift = avoid.filter { it.intersects(band) }.maxOfOrNull { band.maxY - it.minY + 8 } ?: 0.0
            Row(Modifier.align(Alignment.BottomCenter).padding(bottom = (24 + lift).dp).background(Chip, RoundedCornerShape(20.dp)).padding(4.dp)) {
                if (ui.canUndo) TextButton(onClick = controller::undo) { Text("Undo", color = Color.White) }
                if (ui.canRedo) TextButton(onClick = controller::redo) { Text("Redo", color = Color.White) }
                Box {
                    TextButton(onClick = { layoutsOpen = true }) { Text("Layouts", color = Color.White) }
                    DropdownMenu(expanded = layoutsOpen, onDismissRequest = { layoutsOpen = false }) {
                        DropdownMenuItem(text = { Text("Save This Layout…") }, onClick = { layoutsOpen = false; savingLayout = true })
                        for (s in ui.savedLayouts) {
                            DropdownMenuItem(
                                text = { Text(s.name) },
                                onClick = { layoutsOpen = false; controller.applySaved(s.id) },
                                trailingIcon = {
                                    TextButton(onClick = { controller.deleteSavedLayout(s.id) }) { Text("Delete", color = Color(0xFFFF6B6B)) }
                                },
                            )
                        }
                        androidx.compose.material3.HorizontalDivider()
                        Text("Arrangements", color = Color.Gray, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
                        for (p in com.raisecaterror.meowdisplay.core.workspace.WPreset.available(ui.capacity)) {
                            DropdownMenuItem(text = { Text(p.title) }, onClick = { layoutsOpen = false; controller.applyPreset(p) })
                        }
                    }
                }
                TextButton(onClick = { controller.setArranging(false) }) { Text("Done", color = Accent) }
            }
        } else if (ui.localFullscreen == null && !screenReader) {
            // Outside Arrange: press and hold a divider, then drag it. The strip is narrow so the
            // windows' own edges still get their touches.
            for (divider in frames.dividers) key(divider.path, divider.index, divider.axis) {
                val r = transform.viewRect(divider.hitRect)
                val horizontal = divider.axis == com.raisecaterror.meowdisplay.core.workspace.WAxis.Horizontal
                val current by rememberUpdatedState(divider)
                val scale by rememberUpdatedState(if (horizontal) transform.displayedRect.width else transform.displayedRect.height)
                val id = divider.path to divider.index
                val w = if (horizontal) minOf(r.width, 14.0) else r.width
                val h = if (horizontal) r.height else minOf(r.height, 14.0)
                Box(
                    Modifier.offset { IntOffset(((r.midX - w / 2) * density).roundToInt(), ((r.midY - h / 2) * density).roundToInt()) }.size(w.dp, h.dp)
                        .pointerInput(divider.path, divider.index, divider.axis) {
                            detectDragGesturesAfterLongPress(
                                onDragStart = {
                                    heldDivider = id
                                    chromeView.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
                                },
                                onDragEnd = { heldDivider = null; controller.endResize() },
                                onDragCancel = { heldDivider = null; controller.endResize() },
                            ) { change, amount ->
                                change.consume()
                                val delta = (if (horizontal) amount.x else amount.y) / density / scale
                                controller.resize(current, delta.toDouble())
                            }
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    if (heldDivider == id) {
                        Box(Modifier.size(if (horizontal) 6.dp else 44.dp, if (horizontal) 44.dp else 6.dp).background(Accent, CircleShape))
                    }
                }
            }
        }
        if (savingLayout) {
            var name by remember { mutableStateOf("") }
            AlertDialog(
                onDismissRequest = { savingLayout = false },
                title = { Text("Save Layout") },
                text = {
                    Column {
                        Text("Saved layouts are kept for this Mac. Their windows are matched again when you use one.")
                        OutlinedTextField(name, { name = it.take(40) }, singleLine = true, label = { Text("Name") })
                    }
                },
                confirmButton = { TextButton(onClick = { savingLayout = false; controller.saveLayout(name) }) { Text("Save") } },
                dismissButton = { TextButton(onClick = { savingLayout = false }) { Text("Cancel") } },
            )
        }

        // The label menu: tap anywhere else to close; nothing reaches the Mac while it's open.
        menu?.let { m ->
            val tile = ui.layout.tiles[m.tile]
            val rect = frames.tiles[m.tile]?.let { transform.viewRect(it) }
            if (tile == null || rect == null) { menu = null; return@let }
            Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.001f)).pointerInput(Unit) { detectTapGestures { menu = null } })
            val x = minOf(maxOf(rect.minX + 6, picture.minX + 6), picture.maxX - 258)
            val y = maxOf(minOf(maxOf(rect.minY, topInset) + 44, picture.maxY - 360), topInset + 8)
            PaneMenu(
                controller, ui, m, tile, inputAllowed,
                modifier = Modifier.offset { IntOffset((x * density).roundToInt(), (y * density).roundToInt()) }
                    .heightIn(max = maxOf(160.0, box.height / density - y - 12).dp),
                onClose = { menu = null }, onCloseWindow = { confirmClose = m.tile }, onViewFullScreen = onViewFullScreen,
            )
        }

        if (ui.localFullscreen != null) FullscreenStrip(controller, ui, onSettings, Modifier.align(Alignment.TopCenter).padding(top = (topInset + 8).dp))
    }

    confirmClose?.let { id ->
        val name = ui.tileState(id)?.app?.ifEmpty { null } ?: "this window"
        AlertDialog(
            onDismissRequest = { confirmClose = null },
            title = { Text("Close $name on the Mac?") },
            text = { Text("The window closes on the Mac itself, as if you clicked its close button. The app keeps running, and unsaved work asks to be saved there first.") },
            confirmButton = { TextButton(onClick = { controller.closeRemoteWindow(id); confirmClose = null }) { Text("Close Window") } },
            dismissButton = { TextButton(onClick = { confirmClose = null }) { Text("Cancel") } },
        )
    }
}

private data class PaneMenuTarget(val tile: String, val tab: Int?)

/** A label's text: the app's name; when a pane holds several windows of one app, their titles. Desktop panes: "Full Desktop" or the display's name. */
private fun labelText(controller: WorkspaceController, ui: WorkspaceUi, s: WSource, tile: WTile, id: String): String {
    val w = controller.windowItem(s)
    if (s.isDisplay) return w?.title ?: "Desktop"
    val app = w?.app ?: (if (s == tile.source) ui.tileState(id)?.app else null) ?: "Window"
    if (tile.windows.size <= 1) return app.ifEmpty { "Window" }
    val apps = tile.windows.map { controller.windowItem(it)?.app ?: "" }
    if (apps.count { it == app } > 1 && !w?.title.isNullOrEmpty()) return w!!.title
    return app.ifEmpty { w?.title ?: "Window" }
}

@Composable
private fun LabelStrip(
    controller: WorkspaceController, ui: WorkspaceUi, id: String, tile: WTile, r: CGRect, active: Boolean,
    icons: Map<String, ImageBitmap>, top: Double, onMenu: (Int?) -> Unit,
) {
    val windows = tile.windows
    val available = maxOf(r.width - 12, 60.0)
    // Shorter labels when the pane holds several windows; the strip scrolls (by finger only) past that.
    val each = if (windows.size <= 1) minOf(180.0, available) else maxOf(76.0, minOf(150.0, available / windows.size - 6))
    val dragging = ui.drag != null
    Row(
        Modifier.padding(top = top.dp).padding(6.dp).widthIn(max = available.dp)
            .horizontalScroll(rememberScrollState(), enabled = !dragging),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        if (windows.isEmpty()) PaneLabel(controller, id, null, "Empty", null, shown = true, active = active, width = each, onMenu = onMenu)
        windows.forEachIndexed { i, s ->
            PaneLabel(
                controller, id, if (windows.size > 1) i else null, labelText(controller, ui, s, tile, id),
                s.bundleID?.let { icons[it] }, shown = s == tile.source, active = active, width = each, onMenu = onMenu,
            )
        }
    }
}

@Composable
private fun PaneLabel(
    controller: WorkspaceController, id: String, tab: Int?, text: String, icon: ImageBitmap?, shown: Boolean, active: Boolean,
    width: Double, onMenu: (Int?) -> Unit,
) {
    val density = LocalDensity.current.density
    val view = androidx.compose.ui.platform.LocalView.current
    var labelOrigin by remember { mutableStateOf(CGPoint.zero) }
    val highlighted = shown && active
    Row(
        Modifier
            .onGloballyPositioned { c ->
                val p = c.positionInWindow(); labelOrigin = CGPoint(p.x / density.toDouble(), p.y / density.toDouble())
                // Where this tab's label is, for putting a dragged tab back between two others.
                if (tab != null) controller.tabLabelMidX(id, tab, labelOrigin.x + c.size.width / density / 2.0)
            }
            .widthIn(max = width.dp)
            .background(if (highlighted) Accent.copy(alpha = 0.92f) else if (shown) Chip else Chip.copy(alpha = 0.55f), RoundedCornerShape(14.dp))
            .border(if (shown && !active) 0.75.dp else 0.dp, Color.White.copy(alpha = if (shown && !active) 0.3f else 0f), RoundedCornerShape(14.dp))
            .pointerInput(id, tab) {
                val slop = viewConfiguration.touchSlop
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    // Tap (lift before the hold), scroll (moved: the strip scrolls) or hold (drag or menu).
                    val early = withTimeoutOrNull(400) {
                        while (true) {
                            val e = awaitPointerEvent()
                            val c = e.changes.firstOrNull { it.id == down.id } ?: return@withTimeoutOrNull false
                            if (!c.pressed) return@withTimeoutOrNull true
                            if ((c.position - down.position).getDistance() > slop) return@withTimeoutOrNull false
                        }
                        @Suppress("UNREACHABLE_CODE") false
                    }
                    when (early) {
                        true -> if (tab != null && !shown) controller.switchTab(id, tab) else controller.focus(id)
                        false -> Unit
                        null -> {
                            view.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
                            var dragging = false
                            while (true) {
                                val e = awaitPointerEvent()
                                val c = e.changes.firstOrNull { it.id == down.id } ?: break
                                val at = CGPoint(labelOrigin.x + c.position.x / density, labelOrigin.y + c.position.y / density)
                                if (!c.pressed) {
                                    c.consume()
                                    if (dragging) { controller.moveDrag(at); controller.endDrag() } else onMenu(tab)
                                    break
                                }
                                c.consume()
                                if (!dragging && (c.position - down.position).getDistance() > 10 * density) {
                                    dragging = true
                                    controller.beginDrag(WorkspaceDrag.Item.Pane(id, tab), at)
                                }
                                if (dragging) controller.moveDrag(at)
                            }
                            if (dragging && controller.ui.value.drag != null) controller.cancelDrag()
                        }
                    }
                }
            }
            .semantics { contentDescription = "$text" + (if (active && shown) ", typing goes here" else "") + ". Hold for pane options" }
            .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        icon?.let { Image(it, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)) }
        Text(text, color = if (highlighted) Color.Black else Color.White, style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** The label's floating menu (iOS paneMenu). Changing the Mac (Minimize, Close) needs control. */
@Composable
private fun PaneMenu(
    controller: WorkspaceController, ui: WorkspaceUi, m: PaneMenuTarget, tile: WTile, inputAllowed: Boolean, modifier: Modifier,
    onClose: () -> Unit, onCloseWindow: () -> Unit, onViewFullScreen: () -> Unit,
) {
    val full = ui.localFullscreen == m.tile
    val desktop = tile.source?.isDisplay == true
    val window = tile.source != null && !desktop
    val fill = controller.effectiveFit(m.tile) == WFit.Fill
    @Composable
    fun row(label: String, enabled: Boolean = true, destructive: Boolean = false, action: () -> Unit) {
        Text(
            label, color = if (!enabled) Color.White.copy(alpha = 0.4f) else if (destructive) Color(0xFFFF6B6B) else Color.White,
            style = MaterialTheme.typography.bodyMedium,
            modifier = Modifier.fillMaxWidth().clickable(enabled = enabled) { onClose(); action() }.padding(horizontal = 16.dp, vertical = 11.dp),
        )
    }
    Column(
        modifier.width(252.dp).background(Color(0xF2232326), RoundedCornerShape(14.dp)).border(0.75.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(14.dp))
            .padding(vertical = 6.dp).verticalScroll(rememberScrollState()),
    ) {
        row(if (full) "Exit Fullscreen" else "Fullscreen on This Device") { if (full) controller.exitLocalFullscreen() else controller.enterLocalFullscreen(m.tile) }
        if (desktop) row("View Full Screen", action = onViewFullScreen)
        row(if (fill) (if (desktop) "Show Whole Desktop" else "Show Whole Window") else "Fill Pane") { controller.toggleFit(m.tile) }
        if (tile.zoom != null || tile.rotation != WRotation.None || tile.fit == WFit.Fill) row("Reset View") { controller.resetView(m.tile) }
        row("Rotate") { controller.rotate(m.tile) }
        row(if (desktop) "Show a Window Here…" else "Change Window…") { controller.openOverview(replacing = m.tile) }
        row("Arrange Panes") { controller.setArranging(true) }
        m.tab?.let { tab -> row("Remove This Tab") { controller.removeTab(m.tile, tab) } }
        row("Remove from Layout") { controller.removeTile(m.tile) }
        val menus by controller.menus.ui.collectAsState()
        if (window && menus.available && inputAllowed) {
            row(if (menus.barShown) "Hide Menu Bar" else "Show Menu Bar") { controller.menus.setBarShown(!menus.barShown) }
        }
        if (window) {
            Box(Modifier.fillMaxWidth().padding(vertical = 4.dp).height(0.5.dp).background(Color.White.copy(alpha = 0.25f)))
            row("Minimize on Mac", enabled = inputAllowed) { controller.minimizeRemoteWindow(m.tile) }
            row("Close Window on Mac…", enabled = inputAllowed, destructive = true, action = onCloseWindow)
            if (!inputAllowed) RequestControlInline(compact = true)
            if (!inputAllowed) Text("Minimize and Close need control of the Mac.", color = Color.White.copy(alpha = 0.65f),
                style = MaterialTheme.typography.labelSmall, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
        }
    }
}

/** Local fullscreen's floating strip: shown on entering and on any touch, fades after ~3 s. Its buttons never reach the Mac. */
@Composable
private fun FullscreenStrip(controller: WorkspaceController, ui: WorkspaceUi, onSettings: () -> Unit, modifier: Modifier) {
    var visible by remember { mutableStateOf(true) }
    val talkBack = remember { mutableStateOf(false) }
    val context = androidx.compose.ui.platform.LocalContext.current
    LaunchedEffect(Unit) {
        talkBack.value = (context.getSystemService(android.content.Context.ACCESSIBILITY_SERVICE) as? android.view.accessibility.AccessibilityManager)?.isTouchExplorationEnabled == true
    }
    LaunchedEffect(ui.localFullscreen, ui.touchPulse) {
        visible = true
        if (!talkBack.value) { kotlinx.coroutines.delay(3_000); visible = false }
    }
    val alpha by androidx.compose.animation.core.animateFloatAsState(if (visible) 1f else 0f, androidx.compose.animation.core.tween(250), label = "fullscreenStrip")
    val id = ui.localFullscreen ?: return
    if (alpha <= 0.01f) return
    val fill = controller.effectiveFit(id) == WFit.Fill
    Row(
        modifier.graphicsLayer { this.alpha = alpha }.background(Chip, CircleShape).border(0.75.dp, Color.White.copy(alpha = 0.2f), CircleShape).padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(onClick = controller::exitLocalFullscreen) { Text("Exit", color = Color.White) }
        TextButton(onClick = { controller.toggleFit(id) }) { Text(if (fill) "Fit" else "Fill", color = Color.White) }
        TextButton(onClick = { controller.resetView(id) }) { Text("Reset", color = Color.White) }
        TextButton(onClick = onSettings) { Text("Settings", color = Color.White) }
    }
}

/**
 * While a window or a pane label is dragged: the highlighted landing area with what will happen
 * there, and a Cancel zone (drop on it and nothing changes). Window mode shows it over the panes;
 * Mirror/Extend over the desktop (a window dropped there joins it in Window mode). [origin] is
 * this overlay's top-left in window dp.
 */
@Composable
fun WorkspaceDropOverlay(controller: WorkspaceController, origin: CGPoint) {
    val ui by controller.ui.collectAsState()
    val drag = ui.drag ?: run { controller.cancelZone = CGRect.zero; return }
    val density = LocalDensity.current.density
    val view = androidx.compose.ui.platform.LocalView.current
    val target = controller.dropTarget(drag.location)
    val frame = if (ui.windowMode) controller.pictureFrame else controller.desktopFrame
    val over = controller.overCancelZone(drag.location)
    val key = if (over) "cancel" else target?.toString() ?: ""
    LaunchedEffect(key) { if (key.isNotEmpty()) view.performHapticFeedback(android.view.HapticFeedbackConstants.CLOCK_TICK) }
    Box(Modifier.fillMaxSize()) {
        if (target != null && !frame.isEmpty) {
            val p = target.preview
            val r = CGRect(frame.minX + p.x * frame.width - origin.x, frame.minY + p.y * frame.height - origin.y, p.width * frame.width, p.height * frame.height)
            val text = when (target) {
                is WWindowDrop.Replace -> when {
                    drag.item is WorkspaceDrag.Item.Pane -> "Swap"
                    ui.windowMode -> "Replace"
                    target.tile.startsWith("\u0000") -> "Show in Window Mode"
                    else -> "Show Instead of Desktop"
                }
                is WWindowDrop.Tab -> if ((drag.item as? WorkspaceDrag.Item.Pane)?.let { it.tile == target.tile && it.tab != null } == true) "Move Tab Here" else "Add as Tab"
                is WWindowDrop.Split -> "New Pane"
                is WWindowDrop.EmptySlot -> "Show Here"
            }
            Box(
                Modifier.offset { IntOffset((r.minX * density).roundToInt(), (r.minY * density).roundToInt()) }.size(r.width.dp, r.height.dp)
                    .background(Accent.copy(alpha = 0.22f), RoundedCornerShape(10.dp)).border(2.dp, Accent, RoundedCornerShape(10.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Text(text, color = Color.White, style = MaterialTheme.typography.labelLarge,
                    modifier = Modifier.background(Chip, CircleShape).padding(horizontal = 10.dp, vertical = 5.dp))
            }
        }
        if (!frame.isEmpty) {
            val cx = frame.midX - origin.x; val cy = frame.maxY - 64 - origin.y
            Row(
                Modifier
                    .offset { IntOffset(((cx - 105) * density).roundToInt(), ((cy - 24) * density).roundToInt()) }
                    .width(210.dp).height(48.dp)
                    .onGloballyPositioned { c ->
                        val b = c.boundsInWindow()
                        controller.cancelZone = CGRect(b.left / density.toDouble(), b.top / density.toDouble(), b.width / density.toDouble(), b.height / density.toDouble())
                    }
                    .background(if (over) Color(0xD9E53935) else Color.Black.copy(alpha = 0.62f), CircleShape)
                    .border(1.dp, Color.White.copy(alpha = if (over) 0.9f else 0.35f), CircleShape),
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(if (over) "✕  Release to Cancel" else "✕  Drop Here to Cancel", color = Color.White, style = MaterialTheme.typography.titleSmall)
            }
        }
    }
}

/** The collapsible window rail: a thin handle at rest, a strip of windows when open. */
@Composable
fun WindowRail(controller: WorkspaceController) {
    val ui by controller.ui.collectAsState()
    val thumbs by controller.thumbnails.collectAsState()
    if (!ui.available) return
    val edge = ui.railEdge
    val vertical = edge == RailEdge.Left || edge == RailEdge.Right
    val align = when (edge) {
        RailEdge.Top -> Alignment.TopCenter
        RailEdge.Bottom -> Alignment.BottomCenter
        RailEdge.Left -> Alignment.CenterStart
        RailEdge.Right -> Alignment.CenterEnd
    }
    Box(Modifier.fillMaxSize().safeDrawingPadding()) {
        if (!ui.railExpanded) {
            val current = ui.active?.let { ui.tileState(it)?.app }?.takeIf { it.isNotEmpty() }
            DisposableEffect(Unit) { onDispose { controller.railHandle.value = null } }
            val d = LocalDensity.current.density.toDouble()
            Box(
                Modifier.align(align).padding(4.dp)
                    .onGloballyPositioned { c ->
                        val b = c.boundsInWindow()
                        controller.railHandle.value = CGRect(b.left / d, b.top / d, b.width / d, b.height / d)
                    }
                    .clickable { controller.setRailExpanded(true) }
                    .semantics {
                        contentDescription = "Show windows"
                        current?.let { stateDescription = "Now showing $it" }
                    }
                    .padding(10.dp),
                contentAlignment = Alignment.Center,
            ) {
                if (current != null && !vertical) {
                    Text(current, color = Color.White, style = MaterialTheme.typography.labelSmall,
                        modifier = Modifier.background(Chip, RoundedCornerShape(10.dp)).padding(horizontal = 10.dp, vertical = 3.dp))
                } else {
                    Box(Modifier.size(if (vertical) 5.dp else 36.dp, if (vertical) 36.dp else 5.dp).background(Color.White.copy(alpha = 0.7f), CircleShape))
                }
            }
            return@Box
        }
        val windows = ui.catalog?.windows.orEmpty()
        Surface(
            color = Color(0xF21C1C1E), shape = RoundedCornerShape(16.dp),
            modifier = Modifier.align(align).padding(6.dp).let { if (vertical) it.width(168.dp).fillMaxHeight(0.92f) else it.fillMaxWidth().height(150.dp) },
        ) {
            val content: @Composable () -> Unit = {
                for (w in windows.take(30)) RailCard(w, thumbs[w.id], current = ui.layout.tiles.values.any { it.source?.windowID == w.id },
                    onPick = { controller.choose(w, asNewTile = false) }, onAdd = if (ui.layout.tiles.size < ui.capacity) ({ controller.choose(w, asNewTile = true) }) else null)
                if (windows.isEmpty()) Text("Looking for windows…", color = Color.White.copy(alpha = 0.7f), modifier = Modifier.padding(16.dp))
            }
            val controls: @Composable () -> Unit = {
                TextButton(onClick = { controller.openOverview() }) { Text("All Windows") }
                TextButton(onClick = { controller.setArranging(true); controller.setRailExpanded(false) }) { Text("Arrange") }
                var where by remember { mutableStateOf(false) }
                Box {
                    TextButton(onClick = { where = true }) { Text("Move Rail") }
                    DropdownMenu(expanded = where, onDismissRequest = { where = false }) {
                        RailEdge.entries.forEach { e -> DropdownMenuItem(text = { Text(e.name) }, onClick = { where = false; controller.setRailEdge(e) }) }
                    }
                }
                TextButton(onClick = { controller.setRailExpanded(false) }) { Text("Hide") }
            }
            if (vertical) {
                Column(Modifier.verticalScroll(rememberScrollState()).padding(6.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) { controls(); content() }
            } else {
                Column(Modifier.padding(6.dp)) {
                    Row(Modifier.horizontalScroll(rememberScrollState())) { controls() }
                    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) { content() }
                }
            }
        }
    }
}

@Composable
private fun RailCard(w: CatalogWindow, thumb: ImageBitmap?, current: Boolean, onPick: () -> Unit, onAdd: (() -> Unit)?) {
    Column(
        Modifier.width(132.dp).clip(RoundedCornerShape(10.dp)).border(if (current) 2.dp else 0.dp, if (current) Accent else Color.Transparent, RoundedCornerShape(10.dp))
            .clickable(onClick = onPick).semantics {
                contentDescription = "${w.app}: ${w.title.ifEmpty { "window" }}"
                if (current) stateDescription = "Showing"
            },
    ) {
        Box(Modifier.fillMaxWidth().height(64.dp).background(Color(0xFF2C2C2E))) {
            thumb?.let { Image(it, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit) }
            if (onAdd != null) Text("+", color = Color.White, modifier = Modifier.align(Alignment.TopEnd).padding(2.dp).background(Chip, CircleShape).clickable(onClick = onAdd)
                .semantics { contentDescription = "Add ${w.app} as a new tile" }.padding(horizontal = 8.dp, vertical = 2.dp))
        }
        Text(w.app, color = Color.White, style = MaterialTheme.typography.labelSmall, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp))
    }
}

/** Mission Control-style overview: every shareable window, grouped by app, plus layouts and whole-display modes. */
@Composable
fun WindowOverview(controller: WorkspaceController, macName: String, inputAllowed: Boolean, onMirror: () -> Unit, onExtend: () -> Unit) {
    val ui by controller.ui.collectAsState()
    val thumbs by controller.thumbnails.collectAsState()
    val icons by controller.icons.collectAsState()
    if (!ui.overviewOpen) return
    var query by remember { mutableStateOf("") }
    androidx.activity.compose.BackHandler { controller.closeOverview() }
    Surface(color = Color(0xF7101012), modifier = Modifier.fillMaxSize()) {
        BoxWithConstraints(Modifier.safeDrawingPadding()) {
            val columns = when { maxWidth >= 900.dp -> 4; maxWidth >= 600.dp -> 3; else -> 2 }
            val catalog = ui.catalog
            val windows = catalog?.search(query).orEmpty()
            LazyVerticalGrid(columns = GridCells.Fixed(columns), modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                item(span = { GridItemSpan(columns) }) {
                    Column(Modifier.padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(if (ui.replacingTile != null) "Choose a window for this tile" else "Windows on $macName",
                                style = MaterialTheme.typography.titleLarge, color = Color.White, modifier = Modifier.weight(1f))
                            TextButton(onClick = controller::closeOverview) { Text("Done") }
                        }
                        OutlinedTextField(value = query, onValueChange = { query = it }, singleLine = true, placeholder = { Text("Search windows and apps") }, modifier = Modifier.fillMaxWidth())
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text("Full Desktop:", color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.bodyMedium)
                            FilledTonalButton(onClick = { controller.closeOverview(); onMirror() }) { Text("Mirror") }
                            FilledTonalButton(onClick = { controller.closeOverview(); onExtend() }) { Text("Extend") }
                        }
                        if (ui.windowMode) LayoutPresets(ui.capacity, ui.layout.tiles.size, onPick = controller::applyPreset)
                        if (ui.stacked.isNotEmpty()) {
                            Text("Hidden on this screen", color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.labelLarge)
                            Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                ui.stacked.forEach { id ->
                                    FilledTonalButton(onClick = { controller.bringBack(id); controller.closeOverview() }) {
                                        Text(ui.tileState(id)?.app?.ifEmpty { null } ?: "Window")
                                    }
                                }
                            }
                        }
                        when {
                            catalog == null || catalog.starting -> Text("Asking $macName for its windows…", color = Color.White.copy(alpha = 0.7f))
                            catalog.unavailable -> Text("$macName can't list its windows right now. Check that MeowDisplay has Screen Recording permission on the Mac.", color = Color.White.copy(alpha = 0.8f))
                            windows.isEmpty() && query.isNotEmpty() -> Text("No windows match \"$query\".", color = Color.White.copy(alpha = 0.7f))
                            catalog.windows.isEmpty() -> Text("No windows to show. Open an app on the Mac, or pick one below.", color = Color.White.copy(alpha = 0.7f))
                        }
                    }
                }
                items(windows, key = { "w" + it.id }) { w ->
                    OverviewCard(w, thumbs[w.id], w.bundleID.let { icons[it] },
                        current = ui.layout.tiles.values.any { it.source?.windowID == w.id },
                        onPick = { controller.choose(w, asNewTile = false) },
                        onAdd = if (ui.replacingTile == null && ui.layout.tiles.size in 1 until ui.capacity) ({ controller.choose(w, asNewTile = true) }) else null)
                }
                val noWindow = catalog?.apps?.filter { !it.hasWindows && (query.isEmpty() || it.name.contains(query, true)) }.orEmpty()
                if (noWindow.isNotEmpty()) {
                    item(span = { GridItemSpan(columns) }) { SectionLabel("Running, no open window") }
                    items(noWindow, key = { "a" + it.bundleID }) { app ->
                        AppRow(app.name, icons[app.bundleID], action = "Bring Forward", enabled = inputAllowed) { controller.launch(app.bundleID) }
                    }
                }
                val installed = catalog?.installed?.filter { query.isEmpty() || it.name.contains(query, true) }.orEmpty()
                if (installed.isNotEmpty()) {
                    item(span = { GridItemSpan(columns) }) { SectionLabel(if (inputAllowed) "Open an app" else "Open an app (needs control of the Mac)") }
                    items(installed, key = { "i" + it.bundleID }) { app ->
                        AppRow(app.name, icons[app.bundleID], action = "Open", enabled = inputAllowed) { controller.launch(app.bundleID) }
                    }
                }
                item(span = { GridItemSpan(columns) }) { Spacer(Modifier.height(24.dp)) }
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String) = Text(text, color = Color.White.copy(alpha = 0.7f), style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 8.dp))

@Composable
private fun OverviewCard(w: CatalogWindow, thumb: ImageBitmap?, icon: ImageBitmap?, current: Boolean, onPick: () -> Unit, onAdd: (() -> Unit)?) {
    Column(
        Modifier.clip(RoundedCornerShape(12.dp)).background(Color(0xFF1F1F22))
            .border(if (current) 2.dp else 0.dp, if (current) Accent else Color.Transparent, RoundedCornerShape(12.dp))
            .clickable(onClick = onPick)
            .semantics {
                contentDescription = "${w.app}: ${w.title.ifEmpty { "untitled window" }}" + (w.pausedSpoken?.let { ", $it" } ?: "")
                if (current) stateDescription = "Showing"
            },
    ) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 10f).background(Color(0xFF2C2C2E))) {
            if (thumb != null) Image(thumb, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
            else icon?.let { Image(it, null, Modifier.size(40.dp).align(Alignment.Center)) }
            w.pausedBadge?.let { paused -> Text(paused, color = Color.White, style = MaterialTheme.typography.labelSmall,
                modifier = Modifier.align(Alignment.BottomStart).padding(6.dp).background(Chip, RoundedCornerShape(6.dp)).padding(horizontal = 6.dp, vertical = 2.dp)) }
            if (onAdd != null) Text("Add", color = Color.White, style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.align(Alignment.TopEnd).padding(6.dp).background(Chip, RoundedCornerShape(8.dp)).clickable(onClick = onAdd)
                    .semantics { contentDescription = "Add ${w.app} as a new tile" }.padding(horizontal = 8.dp, vertical = 4.dp))
        }
        Row(Modifier.padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
            icon?.let { Image(it, null, Modifier.size(18.dp)); Spacer(Modifier.width(6.dp)) }
            Column {
                Text(w.title.ifEmpty { w.app }, color = Color.White, style = MaterialTheme.typography.bodyMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (w.title.isNotEmpty()) Text(w.app, color = Color.White.copy(alpha = 0.6f), style = MaterialTheme.typography.labelSmall, maxLines = 1)
            }
        }
    }
}

@Composable
private fun AppRow(name: String, icon: ImageBitmap?, action: String, enabled: Boolean, onClick: () -> Unit) {
    Row(Modifier.clip(RoundedCornerShape(10.dp)).background(Color(0xFF1F1F22)).padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
        icon?.let { Image(it, null, Modifier.size(22.dp)); Spacer(Modifier.width(8.dp)) }
        Text(name, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
        TextButton(onClick = onClick, enabled = enabled) { Text(action) }
    }
}

/** Layout choices that fit this screen, drawn as their shapes. */
@Composable
fun LayoutPresets(capacity: Int, tileCount: Int, onPick: (WPreset) -> Unit) {
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        for (preset in WPreset.available(capacity)) {
            val node = preset.node((0 until preset.slotCount).map { "s$it" })
            val slots = WGeometry.frames(com.raisecaterror.meowdisplay.core.workspace.WLayout.of(node, (0 until preset.slotCount).associate { "s$it" to com.raisecaterror.meowdisplay.core.workspace.WTile("s$it") }), WSize(160.0, 100.0)).slots
            Canvas(
                Modifier.size(52.dp, 34.dp).clickable { onPick(preset) }
                    .semantics { contentDescription = "Layout: ${preset.title}" },
            ) {
                val stroke = Stroke(width = 1.5f * density)
                for (r in slots) {
                    drawRoundRect(
                        color = if (preset.slotCount == tileCount) Accent else Color.White.copy(alpha = 0.75f),
                        topLeft = Offset((r.x * size.width).toFloat() + 2f, (r.y * size.height).toFloat() + 2f),
                        size = Size((r.width * size.width).toFloat() - 4f, (r.height * size.height).toFloat() - 4f),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(3f * density), style = stroke,
                    )
                }
            }
        }
    }
}


// MARK: - Pane menu bar (PROTOCOL.md 6.13)

/** The focused pane's app menus (File, Edit, …) as a slim bar across the pane under its label; a title opens its drop-down. */
@Composable
private fun PaneMenuBar(controller: WorkspaceController, pane: CGRect, top: Double, bounds: CGRect) {
    val m by controller.menus.ui.collectAsState()
    if (!m.barShown || m.tile == null || pane.width < 120) return
    val density = LocalDensity.current.density
    val titleX = remember { mutableStateMapOf<Int, Double>() }
    var barOrigin by remember { mutableStateOf(0.0) }
    Box(Modifier.fillMaxSize()) {
        if (m.open.isNotEmpty()) {
            // Tap anywhere else to close; nothing reaches the Mac while a menu is open.
            Box(Modifier.fillMaxSize().clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { controller.menus.close() })
        }
        Row(
            Modifier.offset { IntOffset(((pane.minX + 6) * density).roundToInt(), (top * density).roundToInt()) }
                .size((pane.width - 12).dp, 30.dp).background(Chip, RoundedCornerShape(8.dp))
                .onGloballyPositioned { c -> barOrigin = c.positionInParent().x / density.toDouble() }
                .horizontalScroll(rememberScrollState()).padding(horizontal = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // The app's own menu comes first and is bold, as on a Mac; its name alone while loading or unavailable.
            if (m.app.isNotEmpty() && m.top.isEmpty()) Text(m.app, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 8.dp))
            m.topError?.let { Text(menuMessage(it), color = Color.White.copy(alpha = 0.75f), fontSize = 12.sp, modifier = Modifier.padding(horizontal = 8.dp)) }
            if (m.topError == null && m.top.isEmpty()) Text("…", color = Color.White.copy(alpha = 0.6f), modifier = Modifier.padding(horizontal = 8.dp))
            for (item in m.top) {
                val open = m.open.firstOrNull()?.path == listOf(item.index)
                Text(
                    item.title, color = Color.White.copy(alpha = if (item.enabled) 1f else 0.4f), fontSize = 13.sp,
                    fontWeight = if (item == m.top.first()) FontWeight.Bold else FontWeight.Normal,
                    modifier = Modifier.onGloballyPositioned { c -> titleX[item.index] = c.positionInParent().x / density.toDouble() }
                        .clip(RoundedCornerShape(6.dp)).background(if (open) Accent.copy(alpha = 0.85f) else Color.Transparent)
                        .clickable(enabled = item.enabled) { controller.menus.openMenu(item) }
                        .padding(horizontal = 8.dp, vertical = 5.dp),
                )
            }
        }
        m.open.lastOrNull()?.let { level ->
            val width = 270.0
            val anchor = pane.minX + 6 + (titleX[level.path.firstOrNull() ?: -1] ?: 0.0)
            val y = top + 30 + 4
            val x = anchor.coerceIn(bounds.minX + 6, maxOf(bounds.minX + 6, bounds.maxX - width - 6))
            Column(
                Modifier.offset { IntOffset((x * density).roundToInt(), (y * density).roundToInt()) }.width(width.dp)
                    .heightIn(max = maxOf(120.0, minOf(460.0, bounds.maxY - y - 8)).dp)
                    .background(Color(0xF2232326), RoundedCornerShape(12.dp)).border(0.75.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(12.dp))
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { },
            ) {
                if (m.open.size > 1) {
                    Text("‹  " + level.title, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, maxLines = 1,
                        modifier = Modifier.fillMaxWidth().clickable { controller.menus.back() }.padding(horizontal = 12.dp, vertical = 9.dp))
                    Box(Modifier.fillMaxWidth().height(0.5.dp).background(Color.White.copy(alpha = 0.2f)))
                }
                when {
                    level.loading -> Text("Loading…", color = Color.White.copy(alpha = 0.6f), fontSize = 13.sp, modifier = Modifier.padding(14.dp))
                    level.error != null -> Text(menuMessage(level.error.orEmpty()), color = Color.White.copy(alpha = 0.75f), fontSize = 13.sp, modifier = Modifier.padding(14.dp))
                    level.items.isEmpty() -> Text("No items", color = Color.White.copy(alpha = 0.6f), fontSize = 13.sp, modifier = Modifier.padding(14.dp))
                    else -> Column(Modifier.verticalScroll(rememberScrollState()).padding(vertical = 4.dp)) {
                        for (item in level.items) {
                            if (item.separator) {
                                Box(Modifier.fillMaxWidth().padding(vertical = 4.dp).height(0.5.dp).background(Color.White.copy(alpha = 0.2f)))
                            } else {
                                Row(
                                    Modifier.fillMaxWidth().clickable(enabled = item.enabled) {
                                        if (item.hasSubmenu) controller.menus.openSubmenu(item) else controller.menus.press(item)
                                    }.padding(horizontal = 10.dp, vertical = 8.dp).graphicsLayer { alpha = if (item.enabled) 1f else 0.4f },
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Text(if (item.checked) "✓" else "", color = Color.White, fontSize = 12.sp, modifier = Modifier.width(18.dp))
                                    Text(item.title, color = Color.White, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                                    item.shortcut?.let { Text(it, color = Color.White.copy(alpha = 0.55f), fontSize = 12.sp, modifier = Modifier.padding(start = 8.dp)) }
                                    if (item.hasSubmenu) Text("›", color = Color.White.copy(alpha = 0.6f), fontSize = 16.sp, modifier = Modifier.padding(start = 8.dp))
                                }
                            }
                        }
                    }
                }
                m.failed?.let { Text(menuMessage(it), color = Color(0xFFFFB347), fontSize = 12.sp, modifier = Modifier.padding(10.dp)) }
            }
        }
    }
}

private fun menuMessage(error: String) = when (error) {
    "accessibility" -> "Allow Accessibility for MeowDisplay on the Mac to use menus."
    "control" -> "Menus need control of the Mac."
    "changed" -> "That menu changed on the Mac. Try again."
    else -> "This app's menus aren't available."
}
