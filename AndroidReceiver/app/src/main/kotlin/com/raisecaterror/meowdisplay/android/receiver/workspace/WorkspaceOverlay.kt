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
import kotlin.math.roundToInt

private val Accent = Color(0xFF7FB2FF)
private val Chip = Color(0xCC1C1C1E)

/** A tile's rect on screen (dp) from its normalized canvas rect. */
private fun RemoteViewportTransform.viewRect(r: WRect): CGRect {
    val a = viewPoint(CGPoint(r.x, r.y)); val b = viewPoint(CGPoint(r.maxX, r.maxY))
    return CGRect(minOf(a.x, b.x), minOf(a.y, b.y), kotlin.math.abs(b.x - a.x), kotlin.math.abs(b.y - a.y))
}

/**
 * Tile chrome over the live picture. Only the pills, menus and (in Arrange)
 * dividers take touches; everything else in a tile goes to the Mac as usual.
 */
@Composable
fun WorkspaceChrome(
    controller: WorkspaceController,
    transform: RemoteViewportTransform,
    inputAllowed: Boolean,
    /** On-screen controls (window dp): tile pills and the Arrange bar stay clear of them. */
    avoid: List<CGRect> = emptyList(),
) {
    val ui by controller.ui.collectAsState()
    val icons by controller.icons.collectAsState()
    if (!ui.windowMode || !transform.isValid) return
    val frames = controller.frames()
    val density = LocalDensity.current.density
    var dragging by remember { mutableStateOf<String?>(null) }
    var dragPoint by remember { mutableStateOf<CGPoint?>(null) }
    var confirmClose by remember { mutableStateOf<String?>(null) }
    val workspaceSize = WSize(transform.displayedRect.width, transform.displayedRect.height)
    val multi = ui.layout.tiles.size > 1
    // Pills at the top edge stay clear of the cutout and any visible status bar.
    val topInset = with(LocalDensity.current) { WindowInsets.safeDrawing.getTop(this).toDp().value.toDouble() }
    val railHandle by controller.railHandle
    var box by remember { mutableStateOf(IntSize.Zero) }

    Box(Modifier.fillMaxSize().onSizeChanged { box = it }) {
        for ((id, rect) in frames.tiles) key(id) {
            val r = transform.viewRect(rect)
            val tile = ui.layout.tiles[id] ?: continue
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
                    .let { m -> border?.let { m.border(it) } ?: m },
            ) {
                val status = when {
                    id in ui.missing || tile.source == null -> "Choose a window for this tile"
                    remote == null -> null
                    remote.state == TileStatus.Waiting -> "Waiting for ${remote.app.ifEmpty { "the window" }}…"
                    remote.state == TileStatus.Offscreen -> "${remote.app.ifEmpty { "This window" }} is minimized or hidden on the Mac"
                    remote.state == TileStatus.Closed -> "This window was closed. Tap to choose another."
                    remote.state == TileStatus.Failed -> "Can't show this window right now"
                    remote.state == TileStatus.Limit -> "Paused: too many windows at once"
                    else -> null
                }
                if (status != null) {
                    Text(
                        status, color = Color.White, style = MaterialTheme.typography.bodyMedium,
                        modifier = Modifier.align(Alignment.Center).padding(12.dp).background(Chip, RoundedCornerShape(10.dp)).padding(horizontal = 12.dp, vertical = 8.dp)
                            .clickable { controller.openOverview(replacing = id) },
                    )
                }
                if (multi || ui.arranging) {
                    var menu by remember { mutableStateOf(false) }
                    var pill by remember { mutableStateOf(IntSize.Zero) }
                    val name = remote?.app?.ifEmpty { null } ?: ui.catalog?.windows?.firstOrNull { it.id == tile.source?.windowID }?.app ?: "Window"
                    // Where the pill would sit; if the rail handle or a control is there, it moves down below it.
                    val nominal = CGRect(r.minX + 6, maxOf(r.minY, topInset) + 6, pill.width / density.toDouble(), pill.height / density.toDouble())
                    val clear = (avoid + listOfNotNull(railHandle)).filter { !nominal.isEmpty && it.intersects(nominal) }
                        .maxOfOrNull { it.maxY + 4 - nominal.minY } ?: 0.0
                    Row(
                        Modifier
                            .padding(top = (maxOf(0.0, topInset - r.minY) + clear).dp)
                            .padding(6.dp)
                            .background(if (active) Accent.copy(alpha = 0.9f) else Chip, RoundedCornerShape(14.dp))
                            .pointerInput(id) {
                                detectDragGesturesAfterLongPress(
                                    onDragStart = { dragging = id; dragPoint = CGPoint(r.minX + it.x / density, r.minY + it.y / density) },
                                    onDrag = { change, amount -> change.consume(); dragPoint = dragPoint?.let { CGPoint(it.x + amount.x / density, it.y + amount.y / density) } },
                                    onDragEnd = {
                                        val p = dragPoint; val d = dragging
                                        if (p != null && d != null) transform.remotePoint(p)?.let { n ->
                                            WGeometry.dropTarget(WPoint(n.x, n.y), frames, workspaceSize, null, canSplit = true)?.let { controller.move(d, it) }
                                        }
                                        dragging = null; dragPoint = null
                                    },
                                    onDragCancel = { dragging = null; dragPoint = null },
                                )
                            }
                            .clickable { menu = true }
                            .semantics { contentDescription = "$name tile options" + if (active) ", typing goes here" else "" }
                            .onSizeChanged { pill = it }
                            .padding(horizontal = 10.dp, vertical = 5.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        tile.source?.bundleID?.let { icons[it] }?.let { Image(it, null, Modifier.size(16.dp)); Spacer(Modifier.width(6.dp)) }
                        Text(name, color = if (active) Color.Black else Color.White, style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.widthIn(max = 160.dp))
                        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                            DropdownMenuItem(text = { Text("Type Here") }, onClick = { menu = false; controller.focus(id) })
                            DropdownMenuItem(text = { Text("Change Window…") }, onClick = { menu = false; controller.openOverview(replacing = id) })
                            DropdownMenuItem(text = { Text("Rotate") }, onClick = { menu = false; controller.rotate(id) })
                            DropdownMenuItem(text = { Text(if (tile.fit == WFit.Fill) "Show Whole Window" else "Fill Tile") }, onClick = { menu = false; controller.toggleFit(id) })
                            DropdownMenuItem(text = { Text(if (ui.layout.maximized == id) "Restore Layout" else "Maximize") }, onClick = { menu = false; controller.toggleMaximize(id) })
                            DropdownMenuItem(text = { Text("Arrange Tiles") }, onClick = { menu = false; controller.setArranging(true) })
                            DropdownMenuItem(text = { Text("Remove Tile") }, onClick = { menu = false; controller.removeTile(id) })
                            DropdownMenuItem(
                                text = { Text("Close Window on Mac…") }, enabled = inputAllowed && tile.source?.generation != null,
                                onClick = { menu = false; confirmClose = id },
                            )
                        }
                    }
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

        // Drop preview while a tile is dragged.
        val p = dragPoint
        if (dragging != null && p != null) {
            transform.remotePoint(p)?.let { n -> WGeometry.dropTarget(WPoint(n.x, n.y), frames, workspaceSize, null, canSplit = true) }?.let { target ->
                val r = transform.viewRect(target.preview)
                Box(
                    Modifier.offset { IntOffset((r.minX * density).roundToInt(), (r.minY * density).roundToInt()) }.size(r.width.dp, r.height.dp)
                        .background(Accent.copy(alpha = if (target is WDropTarget.Slot) 0.18f else 0.28f), RoundedCornerShape(8.dp))
                        .border(2.dp, Accent, RoundedCornerShape(8.dp)),
                )
            }
        }

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
                        .semantics { contentDescription = "Resize tiles" },
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
                TextButton(onClick = { controller.setArranging(false) }) { Text("Done", color = Accent) }
            }
        }
    }

    confirmClose?.let { id ->
        val name = ui.tileState(id)?.app?.ifEmpty { null } ?: "this window"
        AlertDialog(
            onDismissRequest = { confirmClose = null },
            title = { Text("Close $name on the Mac?") },
            text = { Text("The window closes on the Mac itself, as if you clicked its close button. Unsaved work may ask to be saved there.") },
            confirmButton = { TextButton(onClick = { controller.closeRemoteWindow(id); confirmClose = null }) { Text("Close Window") } },
            dismissButton = { TextButton(onClick = { confirmClose = null }) { Text("Cancel") } },
        )
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
                            catalog == null -> Text("Asking $macName for its windows…", color = Color.White.copy(alpha = 0.7f))
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
                contentDescription = "${w.app}: ${w.title.ifEmpty { "untitled window" }}" + if (w.availability == WindowAvailability.Offscreen) ", minimized" else ""
                if (current) stateDescription = "Showing"
            },
    ) {
        Box(Modifier.fillMaxWidth().aspectRatio(16f / 10f).background(Color(0xFF2C2C2E))) {
            if (thumb != null) Image(thumb, null, Modifier.fillMaxSize(), contentScale = ContentScale.Fit)
            else icon?.let { Image(it, null, Modifier.size(40.dp).align(Alignment.Center)) }
            if (w.availability == WindowAvailability.Offscreen) Text("Minimized", color = Color.White, style = MaterialTheme.typography.labelSmall,
                modifier = Modifier.align(Alignment.BottomStart).padding(6.dp).background(Chip, RoundedCornerShape(6.dp)).padding(horizontal = 6.dp, vertical = 2.dp))
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

