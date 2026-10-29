package com.raisecaterror.meowdisplay.android.receiver.workspace

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.workspace.RemoteFileEntry
import com.raisecaterror.meowdisplay.core.workspace.RemoteFileKind
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesAccess
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesLocation
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesModel
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesNotice
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesStyle
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesUi
import com.raisecaterror.meowdisplay.core.workspace.RemotePreview
import com.raisecaterror.meowdisplay.core.workspace.RemotePreviewContent
import java.text.DateFormat
import java.util.Date
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

private val Panel = Color(0xF8222226)
private val Line = Color.White.copy(alpha = 0.12f)
private val FinderAccent = Color(0xFF5499FF)
private val Dim = Color.White.copy(alpha = 0.62f)

/**
 * Remote Finder: a temporary, read-only, Finder-like browser of the Mac's approved folders,
 * drawn here over the unchanged picture. Nothing happens on the Mac until "Open on Mac" (which
 * needs control and never brings the app forward). Closing it changes nothing. Mirrors iOS
 * RemoteFinderView.
 */
@Composable
fun RemoteFinderOverlay(
    controller: WorkspaceController,
    macName: String,
    /** The screen's safe area, in window dp. */
    safe: CGRect,
    inputAllowed: Boolean,
) {
    val files = controller.files
    val ui by files.ui.collectAsState()
    if (!ui.isOpen) return
    val d = LocalDensity.current.density
    BackHandler {
        when {
            ui.preview != null -> files.closePreview()
            ui.canGoBack -> files.goBack()
            else -> files.close()
        }
    }
    Box(Modifier.fillMaxSize()) {
        // The dim backdrop owns every touch: nothing here reaches the Mac.
        Box(
            Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.5f))
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { files.close() },
        )
        val width = min(safe.width - 16, 760.0)
        val height = max(240.0, safe.height - 16)
        Box(
            Modifier.offset { IntOffset(((safe.midX - width / 2) * d).roundToInt(), ((safe.midY - height / 2) * d).roundToInt()) }
                .size(width.dp, height.dp)
                .clip(RoundedCornerShape(24.dp)).background(Panel).border(0.75.dp, Color.White.copy(alpha = 0.16f), RoundedCornerShape(24.dp))
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { },
        ) {
            FinderPanel(controller, files, ui, macName, inputAllowed)
        }
        ui.preview?.let { p ->
            val pw = min(safe.width - 24, 640.0)
            val ph = max(220.0, safe.height - 40)
            Box(
                Modifier.offset { IntOffset(((safe.midX - pw / 2) * d).roundToInt(), ((safe.midY - ph / 2) * d).roundToInt()) }
                    .size(pw.dp, ph.dp)
                    .clip(RoundedCornerShape(22.dp)).background(Color(0xFC2A2A2E)).border(0.75.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(22.dp))
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { },
            ) { PreviewCard(controller, files, p, inputAllowed) }
        }
        ui.notice?.let { n ->
            val text = when (n) {
                is RemoteFilesNotice.Opened -> "Opened ${n.name} on the Mac"
                RemoteFilesNotice.NeedsControl -> "Ask for control of the Mac to open files there"
                RemoteFilesNotice.OpenFailed -> "The Mac couldn't open it"
            }
            // Above the preview's buttons.
            Box(Modifier.fillMaxWidth().offset { IntOffset(0, ((safe.maxY - 150) * d).roundToInt()) }, contentAlignment = Alignment.Center) {
                Text(text, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium,
                    modifier = Modifier.background(Color(0xF0333338), CircleShape).padding(horizontal = 16.dp, vertical = 10.dp))
            }
        }
    }
}

@Composable
private fun FinderPanel(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi, macName: String, inputAllowed: Boolean) {
    Column(Modifier.fillMaxSize()) {
        Header(controller, files, ui, macName)
        if (ui.access == RemoteFilesAccess.Ready) {
            SearchField(ui, files)
            Breadcrumbs(ui, files)
        }
        Box(Modifier.fillMaxWidth().height(0.75.dp).background(Line))
        Box(Modifier.fillMaxSize()) {
            when (ui.access) {
                RemoteFilesAccess.Unknown, RemoteFilesAccess.Asking -> Message("✋", "Waiting for $macName",
                    "Allow this device on the Mac to browse the folders you approved there. Nothing is shown until you do.", progress = true)
                RemoteFilesAccess.Off -> Message("📁", "Files is off on $macName",
                    "On the Mac, open MeowDisplay Settings › Displays › Files and turn on “Let devices browse approved folders”.", retry = files::retry)
                RemoteFilesAccess.Denied -> Message("✋", "$macName said Not Now", "Reconnect to ask again.")
                RemoteFilesAccess.NoFolders -> Message("📁", "No folders approved",
                    "On the Mac, add folders in MeowDisplay Settings › Displays › Files.", retry = files::retry)
                RemoteFilesAccess.Ready -> when {
                    ui.query.isNotBlank() -> SearchResults(controller, files, ui)
                    ui.location == RemoteFilesLocation.Locations -> Locations(files, ui)
                    ui.location == RemoteFilesLocation.Applications -> Applications(controller, inputAllowed)
                    else -> Folder(controller, files, ui)
                }
            }
        }
    }
}

@Composable
private fun Header(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi, macName: String) {
    val title = when (val l = ui.location) {
        RemoteFilesLocation.Locations -> "Files on $macName"
        RemoteFilesLocation.Applications -> "Applications"
        is RemoteFilesLocation.Folder -> l.path.lastOrNull() ?: ui.currentRoot?.name.orEmpty()
    }
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        RoundButton("‹", "Back", enabled = ui.canGoBack) { files.goBack() }
        Text(title, color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f))
        if (ui.access == RemoteFilesAccess.Ready && ui.location is RemoteFilesLocation.Folder) {
            Row(Modifier.clip(RoundedCornerShape(9.dp)).background(Color.White.copy(alpha = 0.1f))) {
                StyleButton("☰", "List", ui.style == RemoteFilesStyle.List) { files.setStyle(RemoteFilesStyle.List) }
                StyleButton("▦", "Icons", ui.style == RemoteFilesStyle.Grid) { files.setStyle(RemoteFilesStyle.Grid) }
            }
        }
        Box {
            RoundButton("⋯", "More") { menu = true }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("Finder Windows") }, onClick = {
                    menu = false; files.close(); controller.peekAppRequest.value = controller.finderBundle
                })
                DropdownMenuItem(text = { Text("Refresh") }, onClick = { menu = false; files.retry() })
            }
        }
        RoundButton("✕", "Close") { files.close() }
    }
}

/** Finder, and the demo Mac's own file browser app. */
val FINDER_BUNDLE_IDS = setOf("com.apple.finder", "app.meowdisplay.demo.files")

@Composable
private fun RoundButton(glyph: String, label: String, enabled: Boolean = true, onClick: () -> Unit) {
    Box(
        Modifier.size(36.dp).clip(CircleShape).background(Color.White.copy(alpha = if (enabled) 0.14f else 0.05f))
            .clickable(enabled = enabled, onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { Text(glyph, color = Color.White.copy(alpha = if (enabled) 1f else 0.35f), fontSize = if (glyph == "‹") 24.sp else 16.sp) }
}

@Composable
private fun StyleButton(glyph: String, label: String, selected: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(width = 40.dp, height = 32.dp).background(if (selected) Color.White.copy(alpha = 0.22f) else Color.Transparent)
            .clickable(onClick = onClick).semantics { contentDescription = label + if (selected) ", selected" else "" },
        contentAlignment = Alignment.Center,
    ) { Text(glyph, color = Color.White, fontSize = 15.sp) }
}

@Composable
private fun SearchField(ui: RemoteFilesUi, files: RemoteFilesModel) {
    val placeholder = (ui.location as? RemoteFilesLocation.Folder)?.let { "Search " + (it.path.lastOrNull() ?: ui.currentRoot?.name.orEmpty()) }
        ?: "Search all approved folders"
    Row(
        Modifier.padding(horizontal = 14.dp).padding(bottom = 8.dp).fillMaxWidth().height(42.dp)
            .background(Color.White.copy(alpha = 0.1f), CircleShape).padding(horizontal = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("⌕", color = Dim, fontSize = 18.sp)
        Spacer(Modifier.width(8.dp))
        Box(Modifier.weight(1f)) {
            if (ui.query.isEmpty()) Text(placeholder, color = Color.White.copy(alpha = 0.5f), fontSize = 15.sp, maxLines = 1)
            BasicTextField(
                value = ui.query, onValueChange = files::setQuery, singleLine = true,
                textStyle = TextStyle(color = Color.White, fontSize = 15.sp), cursorBrush = SolidColor(FinderAccent),
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                modifier = Modifier.fillMaxWidth().semantics { contentDescription = placeholder },
            )
        }
        if (ui.query.isNotEmpty()) Text("✕", color = Dim, modifier = Modifier.clickable { files.setQuery("") }.padding(6.dp))
    }
}

@Composable
private fun Breadcrumbs(ui: RemoteFilesUi, files: RemoteFilesModel) {
    val crumbs = ui.breadcrumbs
    val list = rememberLazyListState()
    LaunchedEffect(crumbs.size) { list.scrollToItem(max(0, crumbs.size - 1)) }
    LazyRow(state = list, modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp)) {
        itemsIndexed(crumbs) { i, (title, location) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (i > 0) Text("›", color = Dim, fontSize = 13.sp, modifier = Modifier.padding(end = 4.dp))
                val last = i == crumbs.size - 1
                Text(title, color = if (last) Color.White else Dim, fontSize = 14.sp, fontWeight = if (last) FontWeight.SemiBold else FontWeight.Normal,
                    maxLines = 1, modifier = Modifier.clip(RoundedCornerShape(6.dp)).clickable { files.go(location) }.padding(horizontal = 4.dp, vertical = 2.dp))
            }
        }
    }
}

@Composable
private fun Message(glyph: String, title: String, detail: String, progress: Boolean = false, retry: (() -> Unit)? = null) {
    Column(Modifier.fillMaxSize().padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text(glyph, fontSize = 38.sp)
        Spacer(Modifier.height(12.dp))
        Text(title, color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(detail, color = Dim, fontSize = 14.sp, textAlign = TextAlign.Center, modifier = Modifier.width(400.dp))
        if (progress) { Spacer(Modifier.height(14.dp)); CircularProgressIndicator(color = FinderAccent, modifier = Modifier.size(28.dp), strokeWidth = 2.5.dp) }
        if (retry != null) {
            Spacer(Modifier.height(14.dp))
            Text("Try Again", color = Color.White, fontSize = 15.sp, modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.14f))
                .clickable(onClick = retry).padding(horizontal = 18.dp, vertical = 9.dp))
        }
    }
}

@Composable
private fun Locations(files: RemoteFilesModel, ui: RemoteFilesUi) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 8.dp)) {
        item { SectionTitle("Approved Folders") }
        items(ui.roots, key = { "root:" + it.id }) { root ->
            ListRow(root.name, null, { KindIcon(RemoteFileKind.Folder, 28.0) }, chevron = true) { files.go(RemoteFilesLocation.Folder(root.id, emptyList())) }
        }
        item { SectionTitle("Mac") }
        item { ListRow("Applications", null, { Text("▦", color = FinderAccent, fontSize = 24.sp) }, chevron = true) { files.go(RemoteFilesLocation.Applications) } }
    }
}

@Composable
private fun SectionTitle(text: String) =
    Text(text, color = Dim, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 18.dp, top = 12.dp, bottom = 4.dp))

@Composable
private fun Folder(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi) {
    when {
        ui.loading && ui.entries.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = FinderAccent, modifier = Modifier.size(30.dp), strokeWidth = 2.5.dp)
        }
        ui.folderError == "permission" -> Message("🔒", "macOS didn't allow this",
            "On the Mac, allow MeowDisplay in System Settings › Privacy & Security › Files and Folders, then try again.", retry = files::retry)
        ui.folderError != null -> Message("📁", "This folder isn't available", "It may have moved, or it's no longer approved on the Mac.", retry = files::retry)
        ui.entries.isEmpty() -> Message("📁", "This folder is empty", "Hidden files aren't shown.")
        ui.style == RemoteFilesStyle.Grid -> {
            val grid = androidx.compose.foundation.lazy.grid.rememberLazyGridState()
            LaunchedEffect(ui.highlighted) { ui.highlighted?.let { h -> ui.entries.indexOfFirst { it.name == h }.takeIf { it >= 0 }?.let { grid.scrollToItem(it) } } }
            LazyVerticalGrid(GridCells.Adaptive(104.dp), state = grid, modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(14.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                items(ui.entries, key = { it.id }) { e -> GridTile(controller, files, ui, e) }
                if (ui.truncated) item { Text("Showing the first 2,000 items.", color = Dim, fontSize = 12.sp) }
            }
        }
        else -> {
            val list = rememberLazyListState()
            LaunchedEffect(ui.highlighted) { ui.highlighted?.let { h -> ui.entries.indexOfFirst { it.name == h }.takeIf { it >= 0 }?.let { list.scrollToItem(max(0, it - 2)) } } }
            LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 6.dp)) {
                items(ui.entries, key = { it.id }) { e ->
                    EntryRow(controller, files, ui, e, if (e.isDirectory) formatDate(e.modified) else "${formatSize(e.size)} · ${formatDate(e.modified)}")
                }
                if (ui.truncated) item { Text("Showing the first 2,000 items.", color = Dim, fontSize = 12.sp, modifier = Modifier.padding(16.dp)) }
            }
        }
    }
}

@Composable
private fun SearchResults(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 6.dp)) {
        if (ui.searching && ui.results.isEmpty()) item {
            Box(Modifier.fillMaxWidth().padding(30.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = FinderAccent, modifier = Modifier.size(26.dp), strokeWidth = 2.5.dp) }
        } else if (ui.results.isEmpty()) item { Text("No matches", color = Dim, modifier = Modifier.fillMaxWidth().padding(30.dp), textAlign = TextAlign.Center) }
        items(ui.results, key = { "s:" + it.id }) { e ->
            val place = (listOf(ui.roots.firstOrNull { it.id == e.root }?.name.orEmpty()) + e.location.orEmpty()).joinToString(" › ")
            EntryRow(controller, files, ui, e, place)
        }
        if (!ui.searchComplete && !ui.searching) item {
            Text("Showing the first matches. Type more to narrow it down.", color = Dim, fontSize = 12.sp, modifier = Modifier.padding(16.dp))
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun EntryRow(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi, e: RemoteFileEntry, detail: String) {
    var menu by remember { mutableStateOf(false) }
    ThumbnailLifecycle(files, e)
    Box {
        ListRow(
            e.name, detail, { Thumb(controller, files, ui, e, 30.0) }, chevron = e.isDirectory, highlighted = ui.highlighted == e.name,
            onLongClick = { menu = true },
        ) { files.openEntry(e) }
        EntryMenu(files, e, menu) { menu = false }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GridTile(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi, e: RemoteFileEntry) {
    var menu by remember { mutableStateOf(false) }
    ThumbnailLifecycle(files, e)
    Box {
        Column(
            Modifier.clip(RoundedCornerShape(12.dp)).background(if (ui.highlighted == e.name) FinderAccent.copy(alpha = 0.35f) else Color.Transparent)
                .combinedClickable(onLongClick = { menu = true }) { files.openEntry(e) }
                .padding(6.dp).semantics { contentDescription = e.name + ", " + kindName(e.kind) },
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(Modifier.size(width = 84.dp, height = 76.dp), contentAlignment = Alignment.Center) { Thumb(controller, files, ui, e, 72.0) }
            Spacer(Modifier.height(6.dp))
            Text(e.name, color = Color.White, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
        }
        EntryMenu(files, e, menu) { menu = false }
    }
}

@Composable
private fun ThumbnailLifecycle(files: RemoteFilesModel, e: RemoteFileEntry) {
    DisposableEffect(e.id) {
        files.wantThumbnail(e)
        onDispose { files.dropThumbnail(e) }
    }
}

@Composable
private fun EntryMenu(files: RemoteFilesModel, e: RemoteFileEntry, expanded: Boolean, dismiss: () -> Unit) {
    DropdownMenu(expanded = expanded, onDismissRequest = dismiss) {
        if (!e.isDirectory) DropdownMenuItem(text = { Text("Quick Look") }, onClick = { dismiss(); files.showPreview(e) })
        DropdownMenuItem(text = { Text("Open on Mac") }, onClick = { dismiss(); files.openOnMac(e) })
        if (e.location != null) DropdownMenuItem(text = { Text("Show in Folder") }, onClick = { dismiss(); files.showInFolder(e) })
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ListRow(name: String, detail: String?, icon: @Composable () -> Unit, chevron: Boolean, highlighted: Boolean = false,
                onLongClick: (() -> Unit)? = null, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().background(if (highlighted) FinderAccent.copy(alpha = 0.35f) else Color.Transparent)
            .combinedClickable(onLongClick = onLongClick, onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp)
            .semantics { contentDescription = name },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(Modifier.size(width = 36.dp, height = 34.dp), contentAlignment = Alignment.Center) { icon() }
        Column(Modifier.weight(1f)) {
            Text(name, color = Color.White, fontSize = 15.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (!detail.isNullOrEmpty()) Text(detail, color = Dim, fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        if (chevron) Text("›", color = Color.White.copy(alpha = 0.4f), fontSize = 18.sp)
    }
}

@Composable
private fun Thumb(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi, e: RemoteFileEntry, size: Double) {
    val key = files.thumbnailKey(e)
    val jpeg = key?.let { ui.thumbnails[it] }
    val image = remember(key, jpeg) { jpeg?.let { controller.decodeStill(it, 256) } }
    LaunchedEffect(key, jpeg, image) { if (key != null && jpeg != null && image == null) files.thumbnailUnusable(key) }
    if (image != null) {
        Image(image, null, Modifier.size(size.dp).clip(RoundedCornerShape(if (size > 40) 6.dp else 3.dp)), contentScale = ContentScale.Fit)
    } else KindIcon(e.kind, size)
}

@Composable
private fun KindIcon(kind: RemoteFileKind, size: Double) {
    val glyph = when (kind) {
        RemoteFileKind.Folder -> "📁"; RemoteFileKind.App -> "🧩"; RemoteFileKind.Image -> "🖼️"; RemoteFileKind.Video -> "🎬"
        RemoteFileKind.Audio -> "🎵"; RemoteFileKind.Pdf -> "📕"; RemoteFileKind.Archive -> "📦"; RemoteFileKind.Text -> "📝"
        RemoteFileKind.Document -> "📄"; RemoteFileKind.File -> "📄"
    }
    Text(glyph, fontSize = (size * 0.7).sp)
}

@Composable
private fun Applications(controller: WorkspaceController, inputAllowed: Boolean) {
    val ws by controller.ui.collectAsState()
    val icons by controller.icons.collectAsState()
    LaunchedEffect(Unit) { if (ws.apps.isEmpty()) controller.requestApps() }
    // The running apps from the window list until the Mac's full app list arrives.
    val apps = ws.apps.ifEmpty { ws.catalog?.apps.orEmpty().map { com.raisecaterror.meowdisplay.core.workspace.MacApp(it.bundleID, it.name, true, 0) } }
    Column(Modifier.fillMaxSize()) {
        if (!inputAllowed) Text("Ask for control of the Mac to open apps there.", color = Dim, fontSize = 12.sp, modifier = Modifier.padding(16.dp))
        if (apps.isEmpty()) Box(Modifier.fillMaxWidth().padding(30.dp), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = FinderAccent, modifier = Modifier.size(26.dp), strokeWidth = 2.5.dp)
        }
        LazyVerticalGrid(GridCells.Adaptive(88.dp), modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(14.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            items(apps, key = { it.bundleID }) { app ->
                LaunchedEffect(app.bundleID) { controller.requestIcons(listOf(app.bundleID)) }
                Column(
                    Modifier.clip(RoundedCornerShape(12.dp)).clickable(enabled = inputAllowed) { controller.launch(app.bundleID) }
                        .padding(4.dp).semantics { contentDescription = "Open ${app.name} on the Mac" },
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    val icon = icons[app.bundleID]
                    if (icon != null) Image(icon, null, Modifier.size(52.dp)) else KindIcon(RemoteFileKind.App, 52.0)
                    Text(app.name, color = Color.White.copy(alpha = if (inputAllowed) 1f else 0.6f), fontSize = 12.sp, maxLines = 2,
                        overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                    if (app.bundleID in ws.launching) CircularProgressIndicator(color = FinderAccent, modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                }
            }
        }
    }
}

/** Quick Look on this device: the Mac's own preview, read-only. */
@Composable
private fun PreviewCard(controller: WorkspaceController, files: RemoteFilesModel, p: RemotePreview, inputAllowed: Boolean) {
    val ws by controller.ui.collectAsState()
    // Apps shown in panes now: a file can open in one of them.
    val paneApps = ws.remote?.tiles.orEmpty().filter { it.bundleID.isNotEmpty() }.distinctBy { it.bundleID }
    var openWith by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            KindIcon(p.entry.kind, 24.0)
            Column(Modifier.weight(1f)) {
                Text(p.entry.name, color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(listOfNotNull(kindName(p.entry.kind), formatSize(p.entry.size).takeIf { !p.entry.isDirectory }, formatDate(p.entry.modified).ifEmpty { null })
                    .joinToString(" · "), color = Dim, fontSize = 12.sp, maxLines = 1)
            }
            RoundButton("✕", "Close Quick Look") { files.closePreview() }
        }
        Box(Modifier.fillMaxWidth().height(0.75.dp).background(Line))
        Box(Modifier.weight(1f).fillMaxWidth().clip(RoundedCornerShape(0.dp)), contentAlignment = Alignment.Center) {
            when (val c = p.content) {
                RemotePreviewContent.Loading -> CircularProgressIndicator(color = FinderAccent, modifier = Modifier.size(30.dp), strokeWidth = 2.5.dp)
                is RemotePreviewContent.Image -> {
                    val image = remember(c.jpegBase64) { controller.decodeStill(c.jpegBase64, RemoteFilesModel.PREVIEW_SIDE) }
                    if (image == null) Unavailable(p) else ZoomableImage(image)
                }
                is RemotePreviewContent.Text -> SelectionContainer {
                    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(14.dp)) {
                        Text(c.text, color = Color.White, fontSize = 13.sp, fontFamily = FontFamily.Monospace)
                        if (c.truncated) Text("Showing the beginning of the file.", color = Dim, fontSize = 12.sp, modifier = Modifier.padding(top = 8.dp))
                    }
                }
                RemotePreviewContent.Unavailable -> Unavailable(p)
            }
        }
        Box(Modifier.fillMaxWidth().height(0.75.dp).background(Line))
        Column(Modifier.fillMaxWidth().padding(12.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (p.entry.location != null) Pill("Show in Folder") { files.showInFolder(p.entry) }
                Spacer(Modifier.weight(1f))
                if (paneApps.isNotEmpty()) Box {
                    Pill("Open With", enabled = inputAllowed) { openWith = true }
                    DropdownMenu(expanded = openWith, onDismissRequest = { openWith = false }) {
                        paneApps.forEach { t ->
                            DropdownMenuItem(text = { Text("Open in ${t.app.ifEmpty { t.bundleID }}") }, onClick = { openWith = false; files.openOnMac(p.entry, t.bundleID) })
                        }
                    }
                }
                Pill("Open on Mac", prominent = true, enabled = inputAllowed) { files.openOnMac(p.entry) }
            }
            if (!inputAllowed) Text("Opening on the Mac needs control of the Mac.", color = Dim, fontSize = 12.sp,
                modifier = Modifier.fillMaxWidth().padding(top = 6.dp), textAlign = TextAlign.End)
        }
    }
}

@Composable
private fun Unavailable(p: RemotePreview) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        KindIcon(p.entry.kind, 72.0)
        Text("No preview", color = Dim, fontSize = 14.sp)
    }
}

@Composable
private fun ZoomableImage(image: ImageBitmap) {
    var zoom by remember { mutableFloatStateOf(1f) }
    var panX by remember { mutableFloatStateOf(0f) }
    var panY by remember { mutableFloatStateOf(0f) }
    Image(
        image, null, contentScale = ContentScale.Fit,
        modifier = Modifier.fillMaxSize().padding(10.dp)
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, z, _ ->
                    zoom = (zoom * z).coerceIn(1f, 4f)
                    if (zoom > 1f) { panX += pan.x; panY += pan.y } else { panX = 0f; panY = 0f }
                }
            }
            .pointerInput(Unit) { detectTapGestures(onDoubleTap = { zoom = if (zoom > 1f) 1f else 2f; panX = 0f; panY = 0f }) }
            .graphicsLayer { scaleX = zoom; scaleY = zoom; translationX = panX; translationY = panY },
    )
}

@Composable
private fun Pill(text: String, prominent: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    Text(
        text, color = Color.White.copy(alpha = if (enabled) 1f else 0.4f), fontSize = 14.sp, fontWeight = if (prominent) FontWeight.SemiBold else FontWeight.Normal,
        modifier = Modifier.clip(CircleShape).background(if (prominent && enabled) FinderAccent else Color.White.copy(alpha = 0.14f))
            .clickable(enabled = enabled, onClick = onClick).padding(horizontal = 14.dp, vertical = 8.dp),
    )
}

private fun kindName(kind: RemoteFileKind) = when (kind) {
    RemoteFileKind.Folder -> "Folder"; RemoteFileKind.App -> "Application"; RemoteFileKind.Image -> "Image"; RemoteFileKind.Video -> "Movie"
    RemoteFileKind.Audio -> "Audio"; RemoteFileKind.Pdf -> "PDF Document"; RemoteFileKind.Archive -> "Archive"; RemoteFileKind.Text -> "Text"
    RemoteFileKind.Document -> "Document"; RemoteFileKind.File -> "File"
}

private fun formatSize(bytes: Long?): String {
    if (bytes == null) return "--"
    if (bytes < 1000) return "$bytes bytes"
    val units = listOf("KB", "MB", "GB", "TB")
    var v = bytes / 1000.0
    var i = 0
    while (v >= 1000 && i < units.size - 1) { v /= 1000; i++ }
    return if (v >= 10) "${v.roundToInt()} ${units[i]}" else "%.1f %s".format(v, units[i])
}

private fun formatDate(seconds: Long?): String =
    seconds?.let { DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(it * 1000)) }.orEmpty()
