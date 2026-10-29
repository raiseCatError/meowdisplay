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
import com.raisecaterror.meowdisplay.core.workspace.RemoteFileKindFilter
import com.raisecaterror.meowdisplay.core.workspace.RemoteFileViewer
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesFormat
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesGrant
import com.raisecaterror.meowdisplay.core.workspace.RemoteFilesSort
import com.raisecaterror.meowdisplay.core.workspace.RemoteOpenWithApp
import com.raisecaterror.meowdisplay.core.workspace.RemoteTransferPurpose
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

/** Dialogs and pickers the panel's menus open. */
private class FinderActions(val requests: RemoteFinderRequests) {
    var renaming by mutableStateOf<RemoteFileEntry?>(null)
    var newFolder by mutableStateOf(false)
    var transfers by mutableStateOf(false)
}

/**
 * Remote Finder: a Finder-like browser of what the Mac's owner allowed this device to reach,
 * drawn here over the unchanged picture. Viewing, saving, sharing, uploading and changing files
 * each follow the Mac's grant (shown under the title); "Open on Mac" also needs control and never
 * brings the app forward. Closing it changes nothing on the Mac. Mirrors iOS RemoteFinderView.
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
    val actions = remember { FinderActions(RemoteFinderRequests()) }
    RemoteFinderSystem(files, actions.requests)
    BackHandler {
        when {
            ui.preview != null -> files.closePreview()
            ui.selecting -> files.setSelecting(false)
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
            FinderPanel(controller, files, ui, macName, inputAllowed, actions)
        }
        ui.preview?.let { p ->
            val pw = min(safe.width - 24, 640.0)
            val ph = max(220.0, safe.height - 40)
            Box(
                Modifier.offset { IntOffset(((safe.midX - pw / 2) * d).roundToInt(), ((safe.midY - ph / 2) * d).roundToInt()) }
                    .size(pw.dp, ph.dp)
                    .clip(RoundedCornerShape(22.dp)).background(Color(0xFC2A2A2E)).border(0.75.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(22.dp))
                    .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) { },
            ) { PreviewCard(controller, files, ui, p, inputAllowed) }
        }
        ui.notice?.let { n ->
            var action: Pair<String, () -> Unit>? = null
            val text = when (n) {
                is RemoteFilesNotice.Opened -> "Opened ${n.name} on the Mac"
                RemoteFilesNotice.NeedsControl -> "Ask for control of the Mac to open files there"
                RemoteFilesNotice.OpenFailed -> "The Mac couldn't open it"
                is RemoteFilesNotice.Text -> n.text
                is RemoteFilesNotice.Trashed -> {
                    if (n.tokens.isNotEmpty() && ui.grant?.canModify == true) action = "Undo" to { files.putBack(n.tokens) }
                    if (n.count == 1) "Moved to the Trash on the Mac" else "Moved ${n.count} items to the Trash on the Mac"
                }
                is RemoteFilesNotice.Needs -> {
                    if (n.capability.isNotEmpty()) action = "Ask" to { files.requestAccess(listOf(n.capability)) }
                    "The Mac doesn't allow ${RemoteFilesFormat.capabilityName(n.capability)} for this device"
                }
            }
            // Above the preview's buttons.
            Box(Modifier.fillMaxWidth().offset { IntOffset(0, ((safe.maxY - 150) * d).roundToInt()) }, contentAlignment = Alignment.Center) {
                Row(Modifier.padding(horizontal = 16.dp).background(Color(0xF0333338), CircleShape).padding(horizontal = 16.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(text, color = Color.White, fontSize = 14.sp, fontWeight = FontWeight.Medium, modifier = Modifier.weight(1f, fill = false))
                    action?.let { (label, run) ->
                        Text(label, color = FinderAccent, fontSize = 14.sp, fontWeight = FontWeight.Bold, modifier = Modifier.clickable(onClick = run).padding(4.dp))
                    }
                }
            }
        }
    }
    if (actions.transfers) RemoteTransfersDialog(files.transfers) { actions.transfers = false }
    ui.info?.let { RemoteInfoDialog(it) { files.dismissInfo() } }
    ui.folderConflict?.let { RemoteFolderConflictDialog(it, files::answerFolderConflict) }
    RemoteUploadConflictDialog(files.transfers, canReplace = ui.grant?.canDelete == true)
    actions.renaming?.let { e ->
        RemoteNameDialog("Rename", e.name, "Rename") { name -> actions.renaming = null; if (name != null) files.rename(e, name) }
    }
    if (actions.newFolder) {
        RemoteNameDialog("New Folder", "untitled folder", "Create", "The folder is made on the Mac, here.") { name ->
            actions.newFolder = false; if (name != null) files.newFolder(name)
        }
    }
}

@Composable
private fun FinderPanel(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi, macName: String, inputAllowed: Boolean, actions: FinderActions) {
    Column(Modifier.fillMaxSize()) {
        Header(controller, files, ui, macName, actions)
        if (ui.access == RemoteFilesAccess.Ready) {
            SearchField(ui, files)
            Breadcrumbs(ui, files)
            GrantBar(files, ui)
        }
        Box(Modifier.fillMaxWidth().height(0.75.dp).background(Line))
        Box(Modifier.fillMaxSize()) {
            when (ui.access) {
                RemoteFilesAccess.Unknown, RemoteFilesAccess.Asking -> Message("✋", "Waiting for $macName",
                    "Allow this device on the Mac to browse the folders you approved there. Nothing is shown until you do.", progress = true)
                RemoteFilesAccess.Off -> Message("📁", "Files is off on $macName",
                    "On the Mac, open MeowDisplay Settings › Displays › Files and turn on “Let devices browse approved folders”.", retry = files::retry)
                RemoteFilesAccess.Denied -> Message("✋", "$macName said Not Now", "Reconnect to ask again.")
                RemoteFilesAccess.Revoked -> Message("🔒", "Files access ended",
                    "The Mac's owner turned off access for this device. Ask again to show them the prompt on the Mac.", retry = files::retry, retryLabel = "Ask Again")
                RemoteFilesAccess.NoFolders -> Message("📁", "No folders approved",
                    "On the Mac, add folders in MeowDisplay Settings › Displays › Files.", retry = files::retry)
                RemoteFilesAccess.Ready -> when {
                    ui.query.isNotBlank() -> SearchResults(controller, files, ui)
                    ui.location == RemoteFilesLocation.Locations -> Locations(files, ui)
                    ui.location == RemoteFilesLocation.Applications -> Applications(controller, inputAllowed)
                    else -> Folder(controller, files, ui, actions)
                }
            }
        }
        if (ui.selecting && ui.access == RemoteFilesAccess.Ready) {
            Box(Modifier.fillMaxWidth().height(0.75.dp).background(Line))
            SelectionBar(files, ui)
        }
    }
}

/** What the Mac allows this device, and a way to ask for more. */
@Composable
private fun GrantBar(files: RemoteFilesModel, ui: RemoteFilesUi) {
    val g = ui.grant ?: return
    var menu by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp).padding(bottom = 8.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box {
            Text((if (g.readOnly) "🔒 " else "✎ ") + grantSummary(g) + "  ▾", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Medium,
                modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.12f)).clickable { menu = true }
                    .padding(horizontal = 10.dp, vertical = 5.dp).semantics { contentDescription = "Files access: " + grantDescription(g) })
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text(grantDescription(g), fontSize = 12.sp) }, onClick = {}, enabled = false)
                val missing = listOf("download", "upload", "modify", "delete").filter { it !in g.capabilities }
                missing.forEach { cap ->
                    DropdownMenuItem(text = { Text("Ask the Mac for ${RemoteFilesFormat.capabilityName(cap)}") }, onClick = { menu = false; files.requestAccess(listOf(cap)) })
                }
                if (missing.size > 1) DropdownMenuItem(text = { Text("Ask the Mac for all of these") }, onClick = { menu = false; files.requestAccess(missing) })
            }
        }
        ui.clipboard?.let { c ->
            if (ui.location is RemoteFilesLocation.Folder) {
                Pill(if (c.move) "Move ${c.names.size} Here" else "Paste ${c.names.size}", enabled = ui.canPaste) { files.paste() }
                Text("✕", color = Dim, modifier = Modifier.clickable { files.clearClipboard() }.padding(6.dp).semantics { contentDescription = "Clear Paste" })
            }
        }
    }
}

@Composable
private fun SelectionBar(files: RemoteFilesModel, ui: RemoteFilesUi) {
    val chosen = ui.selectedEntries
    val g = ui.grant ?: RemoteFilesGrant()
    val all = ui.selection.size == ui.visibleEntries.size && ui.visibleEntries.isNotEmpty()
    Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(if (all) "None" else "All", color = FinderAccent, fontSize = 14.sp, modifier = Modifier.clickable { files.selectAll(!all) }.padding(6.dp))
        Text("${chosen.size} selected", color = Dim, fontSize = 13.sp, modifier = Modifier.weight(1f))
        val none = chosen.isEmpty()
        if (g.canDownload) {
            BarAction("⤓", "Save to Device", none) { files.save(chosen) }
            BarAction("⇪", "Share", none) { files.share(chosen) }
        }
        if (g.canModify) {
            BarAction("⧉", "Copy", none) { files.copyItems(chosen, move = false) }
            BarAction("➜", "Move", none) { files.copyItems(chosen, move = true) }
            BarAction("🗜", "Compress", none) { files.compress(chosen) }
        }
        if (g.canDelete) BarAction("🗑", "Move to Trash", none) { files.trash(chosen) }
    }
}

@Composable
private fun BarAction(glyph: String, label: String, disabled: Boolean, onClick: () -> Unit) {
    Box(Modifier.size(38.dp).clip(CircleShape).clickable(enabled = !disabled, onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center) {
        Text(glyph, color = Color.White.copy(alpha = if (disabled) 0.3f else 1f), fontSize = 18.sp)
    }
}

@Composable
private fun Header(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi, macName: String, actions: FinderActions) {
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
        if (ui.busy) CircularProgressIndicator(color = FinderAccent, modifier = Modifier.size(18.dp).semantics { contentDescription = "Working" }, strokeWidth = 2.dp)
        val transfers by files.transfers.items.collectAsState()
        val visible = transfers.filter { it.purpose != RemoteTransferPurpose.View }
        if (visible.isNotEmpty()) {
            val active = visible.count { !it.isFinished }
            Box {
                RoundButton("⇅", if (active > 0) "Transfers, $active running" else "Transfers") { actions.transfers = true }
                if (active > 0) Text("$active", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold,
                    modifier = Modifier.align(Alignment.TopEnd).offset(x = 4.dp, y = (-4).dp).background(FinderAccent, CircleShape).padding(horizontal = 5.dp))
            }
        }
        val inFolder = ui.access == RemoteFilesAccess.Ready && ui.location is RemoteFilesLocation.Folder
        val g = ui.grant
        if (inFolder && ui.selecting) {
            Text("Done", color = FinderAccent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.clip(CircleShape).clickable { files.setSelecting(false) }.padding(horizontal = 8.dp, vertical = 6.dp))
        } else Box {
            RoundButton("⋯", "More") { menu = true }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                if (inFolder) {
                    DropdownMenuItem(text = { Text("Select") }, onClick = { menu = false; files.setSelecting(true) })
                    if (g?.canUpload == true) {
                        DropdownMenuItem(text = { Text("New Folder") }, onClick = { menu = false; actions.newFolder = true })
                        DropdownMenuItem(text = { Text("Upload Files…") }, onClick = { menu = false; actions.requests.uploadFiles() })
                        DropdownMenuItem(text = { Text("Upload a Folder…") }, onClick = { menu = false; actions.requests.uploadFolder() })
                    }
                    if (ui.canPaste) DropdownMenuItem(text = { Text(if (ui.clipboard?.move == true) "Move Here" else "Paste") }, onClick = { menu = false; files.paste() })
                    RemoteFilesSort.entries.forEach { s ->
                        DropdownMenuItem(text = { Text((if (ui.sort == s) "✓ " else "    ") + "Sort by " + mapOf(RemoteFilesSort.Name to "Name", RemoteFilesSort.Date to "Date Modified",
                            RemoteFilesSort.Size to "Size", RemoteFilesSort.Kind to "Kind")[s]) }, onClick = { menu = false; files.setSort(s) })
                    }
                    DropdownMenuItem(text = { Text((if (ui.ascending) "✓ " else "    ") + "Ascending") }, onClick = { menu = false; files.setAscending(!ui.ascending) })
                    RemoteFileKindFilter.entries.forEach { f ->
                        val label = mapOf(RemoteFileKindFilter.All to "All Items", RemoteFileKindFilter.Folders to "Folders", RemoteFileKindFilter.Images to "Images",
                            RemoteFileKindFilter.Movies to "Movies", RemoteFileKindFilter.Audio to "Audio", RemoteFileKindFilter.Documents to "Documents",
                            RemoteFileKindFilter.Archives to "Archives")[f]
                        DropdownMenuItem(text = { Text((if (ui.kindFilter == f) "✓ " else "    ") + "Show " + label) }, onClick = { menu = false; files.setKindFilter(f) })
                    }
                    if (g?.hidden == true) DropdownMenuItem(text = { Text((if (ui.showHidden) "✓ " else "    ") + "Hidden Files") },
                        onClick = { menu = false; files.setShowHidden(!ui.showHidden) })
                }
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
private fun Message(glyph: String, title: String, detail: String, progress: Boolean = false, retry: (() -> Unit)? = null, retryLabel: String = "Try Again") {
    Column(Modifier.fillMaxSize().padding(28.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Text(glyph, fontSize = 38.sp)
        Spacer(Modifier.height(12.dp))
        Text(title, color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(detail, color = Dim, fontSize = 14.sp, textAlign = TextAlign.Center, modifier = Modifier.width(400.dp))
        if (progress) { Spacer(Modifier.height(14.dp)); CircularProgressIndicator(color = FinderAccent, modifier = Modifier.size(28.dp), strokeWidth = 2.5.dp) }
        if (retry != null) {
            Spacer(Modifier.height(14.dp))
            Text(retryLabel, color = Color.White, fontSize = 15.sp, modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.14f))
                .clickable(onClick = retry).padding(horizontal = 18.dp, vertical = 9.dp))
        }
    }
}

@Composable
private fun Locations(files: RemoteFilesModel, ui: RemoteFilesUi) {
    LazyColumn(Modifier.fillMaxSize(), contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 8.dp)) {
        if (ui.favorites.isNotEmpty()) {
            item { SectionTitle("Favorites") }
            items(ui.favorites, key = { "fav:" + it.id }) { f ->
                val reachable = ui.roots.any { it.id == f.root }
                var menu by remember { mutableStateOf(false) }
                Box {
                    ListRow(f.name, if (reachable) null else "Not reachable with this access", { Text("★", color = Color(0xFFFFD60A), fontSize = 22.sp) },
                        chevron = reachable, onLongClick = { menu = true }) { if (reachable) files.go(RemoteFilesLocation.Folder(f.root, f.path)) }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(text = { Text("Remove from Favorites") }, onClick = { menu = false; files.removeFavorite(f) })
                    }
                }
            }
        }
        if (ui.recents.isNotEmpty()) {
            item { SectionTitle("Recent") }
            items(ui.recents, key = { "recent:" + it.id }) { e ->
                ListRow(e.name, (listOf(ui.roots.firstOrNull { it.id == e.root }?.name.orEmpty()) + e.location.orEmpty()).joinToString(" › "),
                    { KindIcon(e.kind, 28.0) }, chevron = false) { files.openEntry(e) }
            }
        }
        item { SectionTitle(if (ui.grant?.allFiles == true) "Locations" else "Approved Folders") }
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
private fun Folder(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi, actions: FinderActions) {
    when {
        ui.loading && ui.entries.isEmpty() -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            CircularProgressIndicator(color = FinderAccent, modifier = Modifier.size(30.dp), strokeWidth = 2.5.dp)
        }
        ui.folderError == "permission" -> Message("🔒", "macOS didn't allow this",
            "On the Mac, allow MeowDisplay in System Settings › Privacy & Security › Files and Folders, then try again.", retry = files::retry)
        ui.folderError == "timeout" || ui.folderError == "disconnected" -> Message("📶", "The Mac didn't answer", "Check the connection, then try again.", retry = files::refresh)
        ui.folderError != null -> Message("📁", "This folder isn't available", "It may have moved, or it's no longer approved on the Mac.", retry = files::retry)
        ui.visibleEntries.isEmpty() -> Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
            Message("📁", "This folder is empty", if (ui.kindFilter != RemoteFileKindFilter.All) "Nothing here matches the filter." else "Hidden files aren't shown.")
            if (ui.grant?.canUpload == true) Pill("Upload Files…") { actions.requests.uploadFiles() }
        }
        ui.style == RemoteFilesStyle.Grid -> {
            val grid = androidx.compose.foundation.lazy.grid.rememberLazyGridState()
            LaunchedEffect(ui.highlighted) { ui.highlighted?.let { h -> ui.visibleEntries.indexOfFirst { it.name == h }.takeIf { it >= 0 }?.let { grid.scrollToItem(it) } } }
            LazyVerticalGrid(GridCells.Adaptive(104.dp), state = grid, modifier = Modifier.fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(14.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                items(ui.visibleEntries, key = { it.id }) { e -> GridTile(controller, files, ui, e, actions) }
                if (ui.truncated) item { Text("Showing the first 2,000 items.", color = Dim, fontSize = 12.sp) }
            }
        }
        else -> {
            val list = rememberLazyListState()
            LaunchedEffect(ui.highlighted) { ui.highlighted?.let { h -> ui.visibleEntries.indexOfFirst { it.name == h }.takeIf { it >= 0 }?.let { list.scrollToItem(max(0, it - 2)) } } }
            LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = androidx.compose.foundation.layout.PaddingValues(vertical = 6.dp)) {
                items(ui.visibleEntries, key = { it.id }) { e ->
                    EntryRow(controller, files, ui, e, if (e.isDirectory) formatDate(e.modified) else "${formatSize(e.size)} · ${formatDate(e.modified)}", actions)
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
private fun EntryRow(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi, e: RemoteFileEntry, detail: String, actions: FinderActions? = null) {
    var menu by remember { mutableStateOf(false) }
    ThumbnailLifecycle(files, e)
    val selectable = ui.selecting && e.location == null
    val selected = e.id in ui.selection
    Box {
        ListRow(
            e.name, detail, {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    if (selectable) SelectionMark(selected)
                    Thumb(controller, files, ui, e, 30.0)
                }
            }, chevron = e.isDirectory && !ui.selecting, highlighted = ui.highlighted == e.name || selected,
            onLongClick = { menu = true },
        ) { files.tap(e) }
        EntryMenu(files, ui, e, menu, actions) { menu = false }
    }
}

@Composable
private fun SelectionMark(selected: Boolean) {
    Text(if (selected) "◉" else "○", color = if (selected) FinderAccent else Dim, fontSize = 16.sp, modifier = Modifier.padding(end = 4.dp))
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun GridTile(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi, e: RemoteFileEntry, actions: FinderActions? = null) {
    var menu by remember { mutableStateOf(false) }
    ThumbnailLifecycle(files, e)
    val selected = e.id in ui.selection
    Box {
        Column(
            Modifier.clip(RoundedCornerShape(12.dp)).background(when {
                selected -> FinderAccent.copy(alpha = 0.45f)
                ui.highlighted == e.name -> FinderAccent.copy(alpha = 0.35f)
                else -> Color.Transparent
            })
                .combinedClickable(onLongClick = { menu = true }) { files.tap(e) }
                .padding(6.dp).semantics { contentDescription = e.name + ", " + kindName(e.kind) },
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Box(Modifier.size(width = 84.dp, height = 76.dp), contentAlignment = Alignment.Center) {
                Thumb(controller, files, ui, e, 72.0)
                if (ui.selecting) Box(Modifier.align(Alignment.TopEnd)) { SelectionMark(selected) }
            }
            Spacer(Modifier.height(6.dp))
            Text(e.name, color = Color.White, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
        }
        EntryMenu(files, ui, e, menu, actions) { menu = false }
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
private fun EntryMenu(files: RemoteFilesModel, ui: RemoteFilesUi, e: RemoteFileEntry, expanded: Boolean, actions: FinderActions?, dismiss: () -> Unit) {
    val g = ui.grant ?: RemoteFilesGrant()
    DropdownMenu(expanded = expanded, onDismissRequest = dismiss) {
        if (!e.isDirectory) DropdownMenuItem(text = { Text("Quick Look") }, onClick = { dismiss(); files.showPreview(e) })
        DropdownMenuItem(text = { Text("Open on Mac") }, onClick = { dismiss(); files.openOnMac(e) })
        if (e.location != null) DropdownMenuItem(text = { Text("Show in Folder") }, onClick = { dismiss(); files.showInFolder(e) })
        DropdownMenuItem(text = { Text("Get Info") }, onClick = { dismiss(); files.getInfo(e) })
        if (e.isDirectory && e.kind != RemoteFileKind.App) {
            DropdownMenuItem(text = { Text(if (files.isFavorite(e)) "Remove from Favorites" else "Add to Favorites") }, onClick = { dismiss(); files.toggleFavorite(e) })
        }
        if (g.canDownload && e.kind != RemoteFileKind.App) {
            DropdownMenuItem(text = { Text("Save to Device") }, onClick = { dismiss(); files.save(listOf(e)) })
            DropdownMenuItem(text = { Text("Share…") }, onClick = { dismiss(); files.share(listOf(e)) })
        }
        if (e.location == null && g.canModify) {
            if (!e.readOnly && actions != null) DropdownMenuItem(text = { Text("Rename") }, onClick = { dismiss(); actions.renaming = e })
            DropdownMenuItem(text = { Text("Duplicate") }, onClick = { dismiss(); files.duplicate(listOf(e)) })
            DropdownMenuItem(text = { Text("Copy") }, onClick = { dismiss(); files.copyItems(listOf(e), move = false) })
            DropdownMenuItem(text = { Text("Move…") }, onClick = { dismiss(); files.copyItems(listOf(e), move = true) })
            if (e.kind == RemoteFileKind.Archive && e.name.lowercase().endsWith(".zip")) {
                DropdownMenuItem(text = { Text("Expand") }, onClick = { dismiss(); files.expand(e) })
            } else DropdownMenuItem(text = { Text("Compress") }, onClick = { dismiss(); files.compress(listOf(e)) })
        }
        if (e.location == null && g.canDelete) {
            DropdownMenuItem(text = { Text("Move to Trash", color = Color(0xFFFF453A)) }, onClick = { dismiss(); files.trash(listOf(e)) })
        }
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

/**
 * Quick Look on this device: the Mac's still first, then the file itself where it helps — movies
 * and audio stream with seeking, PDFs show their pages, images come at full size.
 */
@Composable
private fun PreviewCard(controller: WorkspaceController, files: RemoteFilesModel, ui: RemoteFilesUi, p: RemotePreview, inputAllowed: Boolean) {
    val ws by controller.ui.collectAsState()
    // Apps shown in panes now: a file can open in one of them.
    val paneApps = ws.remote?.tiles.orEmpty().filter { it.bundleID.isNotEmpty() }.distinctBy { it.bundleID }
    var openWith by remember { mutableStateOf(false) }
    var macApps by remember(p.key) { mutableStateOf<List<RemoteOpenWithApp>>(emptyList()) }
    LaunchedEffect(p.key) { files.openWithApps(p.entry) { macApps = it } }
    val g = ui.grant ?: RemoteFilesGrant()
    val viewer = ui.viewer?.takeIf { it.previewKey == p.key }
    val context = androidx.compose.ui.platform.LocalContext.current
    val transfers by files.transfers.items.collectAsState()
    val progress = viewer?.transferID?.let { id -> transfers.firstOrNull { it.id == id }?.fraction }
    val still = (p.content as? RemotePreviewContent.Image)?.let { c -> remember(c.jpegBase64) { controller.decodeStill(c.jpegBase64, RemoteFilesModel.PREVIEW_SIDE) } }
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
            val vc = viewer?.content
            when {
                vc is RemoteFileViewer.Content.Stream -> RemoteMediaPlayer(files, vc.x, vc.size, video = p.entry.kind == RemoteFileKind.Video) { files.viewerFailed(it) }
                vc is RemoteFileViewer.Content.Local && p.entry.kind == RemoteFileKind.Pdf -> RemotePdfViewer(vc.file)
                vc is RemoteFileViewer.Content.Local && p.entry.kind == RemoteFileKind.Image -> RemoteFullImage(vc.file, still)
                vc is RemoteFileViewer.Content.Local -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    KindIcon(p.entry.kind, 64.0)
                    Spacer(Modifier.height(10.dp))
                    Pill("Open in Another App", prominent = true) { openElsewhere(context, vc.file) }
                }
                else -> PreviewContent(controller, files, p, g, viewer, still)
            }
            when (vc) {
                RemoteFileViewer.Content.Loading -> Column(Modifier.align(Alignment.BottomCenter).padding(12.dp).background(Color(0xE0333338), RoundedCornerShape(12.dp)).padding(10.dp),
                    horizontalAlignment = Alignment.CenterHorizontally) {
                    if (progress != null && progress > 0) androidx.compose.material3.LinearProgressIndicator(progress = { progress.toFloat() }, modifier = Modifier.width(200.dp))
                    else CircularProgressIndicator(color = FinderAccent, modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                    Text(if (p.entry.kind == RemoteFileKind.Video || p.entry.kind == RemoteFileKind.Audio) "Connecting to the Mac…" else "Loading from the Mac…",
                        color = Dim, fontSize = 12.sp, modifier = Modifier.padding(top = 6.dp))
                }
                is RemoteFileViewer.Content.Failed -> Row(Modifier.align(Alignment.BottomCenter).padding(12.dp).background(Color(0xE0333338), CircleShape)
                    .padding(horizontal = 14.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Text(if (vc.code == "unsupported") "This format can't play here." else RemoteFilesFormat.errorText(vc.code), color = Color.White, fontSize = 12.sp)
                    if (vc.code != "unsupported") Text("Retry", color = FinderAccent, fontSize = 12.sp, fontWeight = FontWeight.Bold, modifier = Modifier.clickable { files.retryViewer() })
                }
                else -> Unit
            }
        }
        Box(Modifier.fillMaxWidth().height(0.75.dp).background(Line))
        Column(Modifier.fillMaxWidth().padding(12.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (p.entry.location != null) Pill("⌕") { files.showInFolder(p.entry) }
                if (g.canDownload) {
                    Pill("Save") { files.save(listOf(p.entry)) }
                    Pill("Share") { files.share(listOf(p.entry)) }
                }
                Spacer(Modifier.weight(1f))
                if (paneApps.isNotEmpty() || macApps.isNotEmpty()) Box {
                    Pill("Open With", enabled = inputAllowed) { openWith = true }
                    DropdownMenu(expanded = openWith, onDismissRequest = { openWith = false }) {
                        paneApps.forEach { t ->
                            DropdownMenuItem(text = { Text("Open in ${t.app.ifEmpty { t.bundleID }}") }, onClick = { openWith = false; files.openOnMac(p.entry, t.bundleID) })
                        }
                        macApps.forEach { a ->
                            DropdownMenuItem(text = { Text(if (a.isDefault) "${a.name} (default)" else a.name) }, onClick = { openWith = false; files.openOnMac(p.entry, a.bundleID) })
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

/** The Mac's still, text or a message, before (or instead of) the file itself. */
@Composable
private fun PreviewContent(controller: WorkspaceController, files: RemoteFilesModel, p: RemotePreview, g: RemoteFilesGrant, viewer: RemoteFileViewer?, still: ImageBitmap?) {
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
        RemotePreviewContent.Unavailable -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Unavailable(p)
            if (g.canDownload && !p.entry.isDirectory && viewer == null) {
                Spacer(Modifier.height(10.dp))
                Pill("Open Here") { files.openCopyHere(p.entry) }
            }
        }
        is RemotePreviewContent.Failed -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
            KindIcon(p.entry.kind, 64.0)
            Text(RemoteFilesFormat.errorText(c.code), color = Dim, fontSize = 14.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(10.dp))
            Pill("Try Again") { files.retryPreview() }
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
