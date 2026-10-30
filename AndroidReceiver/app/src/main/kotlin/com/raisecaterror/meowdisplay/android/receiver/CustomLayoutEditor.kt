package com.raisecaterror.meowdisplay.android.receiver

import android.content.res.Configuration
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.ControlModifier
import com.raisecaterror.meowdisplay.core.controls.ControlProfileSlot
import com.raisecaterror.meowdisplay.core.controls.ControlSafeInsets
import com.raisecaterror.meowdisplay.core.controls.ControlTrayItem
import com.raisecaterror.meowdisplay.core.controls.CustomControlArrangement
import com.raisecaterror.meowdisplay.core.controls.CustomControlKind
import com.raisecaterror.meowdisplay.core.controls.CustomControlLayout
import com.raisecaterror.meowdisplay.core.controls.CustomControlPlacement
import com.raisecaterror.meowdisplay.core.controls.CustomLayoutEditing
import com.raisecaterror.meowdisplay.core.controls.CustomLayoutGeometry
import com.raisecaterror.meowdisplay.core.controls.ModifierChord
import com.raisecaterror.meowdisplay.core.controls.PadControlMetrics
import com.raisecaterror.meowdisplay.core.controls.PalettePresentation
import com.raisecaterror.meowdisplay.core.controls.PaletteShape
import com.raisecaterror.meowdisplay.core.controls.ShortcutItem
import com.raisecaterror.meowdisplay.core.controls.updateCustomLayout
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * iOS `CustomLayoutEditor`: the layout at the device's own proportions, in
 * Landscape or Portrait, over a draft. Drag a control to move it (Snap to
 * Edges / Snap to Guides through the shared [CustomLayoutGeometry]); tap one
 * to resize it, style its palette, edit its shortcut or remove it. Done saves
 * the draft; Cancel discards it (asking first when something changed).
 */
@Composable
internal fun CustomLayoutEditor(controller: ReceiverController, layoutID: String, onDismiss: () -> Unit) {
    val prefs by controller.store.preferences.collectAsState()
    val stored = prefs.customLayouts.firstOrNull { it.id == layoutID }
    if (stored == null) {
        // Deleted elsewhere (another device's sync, or a share import replaced it).
        LaunchedEffect(layoutID) { onDismiss() }
        return
    }
    val configuration = LocalConfiguration.current
    var draft by remember(layoutID) { mutableStateOf(stored) }
    var portrait by remember { mutableStateOf(configuration.orientation == Configuration.ORIENTATION_PORTRAIT) }
    var selectedID by remember { mutableStateOf<String?>(null) }
    var snapToEdges by remember { mutableStateOf(true) }
    var snapToGuides by remember { mutableStateOf(true) }
    var confirmingDiscard by remember { mutableStateOf(false) }
    var confirmingTemplate by remember { mutableStateOf(false) }
    var editingShortcut by remember { mutableStateOf<Pair<String?, ShortcutItem?>?>(null) }

    val arrangement = draft.arrangement(portrait)
    val functionItems = CustomLayoutEditing.functionItems(prefs, draft)
    val selected = arrangement.placements.firstOrNull { it.id == selectedID }
    fun mutate(change: (CustomControlArrangement) -> CustomControlArrangement) {
        draft = draft.setArrangement(change(draft.arrangement(portrait)), portrait)
    }
    fun cancel() = if (draft != stored) confirmingDiscard = true else onDismiss()
    fun add(kind: CustomControlKind) {
        CustomLayoutEditing.add(arrangement, kind)?.let { (next, id) -> mutate { next }; selectedID = id }
    }

    Dialog(onDismissRequest = ::cancel, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        BackHandler { cancel() }
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
            Column(Modifier.safeDrawingPadding()) {
                EditorTopBar(
                    title = draft.name, portrait = portrait, onOrientation = { portrait = it; selectedID = null },
                    onCancel = ::cancel,
                    onDone = { controller.store.update { it.updateCustomLayout(draft) }; onDismiss() },
                    addMenu = { close ->
                        AddControlMenu(arrangement, functionItems, onShortcut = { close(); editingShortcut = null to null }) { kind -> close(); add(kind) }
                    },
                )
                HorizontalDivider()
                BoxWithConstraints(Modifier.fillMaxSize()) {
                    val wide = maxWidth > maxHeight
                    val panelMax = maxHeight * 0.38f
                    val panel: @Composable (Modifier) -> Unit = { modifier ->
                        Column(modifier.verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            if (selected != null) {
                                PlacementInspector(selected, functionItems,
                                    onResize = { size -> mutate { CustomLayoutEditing.resize(it, selected.id, size) } },
                                    onRestyle = { change -> mutate { CustomLayoutEditing.restyle(it, selected.id, change) } },
                                    onEditShortcut = { item -> editingShortcut = selected.id to item },
                                    onRemove = { mutate { CustomLayoutEditing.remove(it, selected.id) }; selectedID = null },
                                    onDeselect = { selectedID = null },
                                )
                            } else {
                                LayoutOptions(
                                    draft, snapToEdges, snapToGuides,
                                    onRename = { name -> draft = draft.copy(name = name) },
                                    onSnapToEdges = { snapToEdges = it }, onSnapToGuides = { snapToGuides = it },
                                    onTwoHandAssist = { draft = draft.copy(twoHandAssist = it) },
                                    onFunctionProfile = { draft = draft.copy(functionProfile = it) },
                                    onUseTemplate = { confirmingTemplate = true },
                                )
                            }
                        }
                    }
                    val canvas: @Composable (Modifier) -> Unit = { modifier ->
                        LayoutCanvas(
                            modifier, arrangement, portrait, PadControlMetrics(prefs.padControlScale), functionItems,
                            paletteActions = { modifier -> prefs.profile(prefs.activeControlProfile).actions(ModifierChord(modifier)) },
                            selectedID = selectedID, snapToEdges = snapToEdges, snapToGuides = snapToGuides,
                            onSelect = { selectedID = it },
                            onDrop = { id, position -> mutate { CustomLayoutEditing.move(it, id, position) } },
                        )
                    }
                    if (wide) {
                        Row(Modifier.fillMaxSize()) {
                            canvas(Modifier.weight(1f).fillMaxHeight())
                            panel(Modifier.width(320.dp).fillMaxHeight())
                        }
                    } else {
                        Column(Modifier.fillMaxSize()) {
                            canvas(Modifier.weight(1f).fillMaxWidth())
                            HorizontalDivider()
                            panel(Modifier.fillMaxWidth().heightIn(max = panelMax))
                        }
                    }
                }
            }
        }
    }

    if (confirmingDiscard) {
        AlertDialog(
            onDismissRequest = { confirmingDiscard = false },
            title = { Text("Discard your changes?") },
            confirmButton = { TextButton(onClick = { confirmingDiscard = false; onDismiss() }) { Text("Discard Changes", color = MaterialTheme.colorScheme.error) } },
            dismissButton = { TextButton(onClick = { confirmingDiscard = false }) { Text("Keep Editing") } },
        )
    }
    if (confirmingTemplate) {
        AlertDialog(
            onDismissRequest = { confirmingTemplate = false },
            title = { Text("Replace this orientation with the radial template?") },
            text = { Text("Only the ${if (portrait) "portrait" else "landscape"} arrangement changes. Cancel still discards it.") },
            confirmButton = {
                TextButton(onClick = { draft = CustomLayoutEditing.useTemplate(draft, portrait); selectedID = null; confirmingTemplate = false }) {
                    Text("Use Template", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = { TextButton(onClick = { confirmingTemplate = false }) { Text("Cancel") } },
        )
    }
    editingShortcut?.let { (placementID, item) ->
        ShortcutEditorDialog(initial = item, keysOnly = true, onSave = { edited ->
            CustomLayoutEditing.setShortcut(draft.arrangement(portrait), placementID, edited)?.let { (next, id) -> mutate { next }; selectedID = id }
        }, onDismiss = { editingShortcut = null })
    }
}

@Composable
private fun EditorTopBar(
    title: String, portrait: Boolean, onOrientation: (Boolean) -> Unit, onCancel: () -> Unit, onDone: () -> Unit,
    addMenu: @Composable (close: () -> Unit) -> Unit,
) {
    var adding by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            TextButton(onClick = onCancel) { Text("Cancel") }
            Text(title, style = MaterialTheme.typography.titleMedium, maxLines = 1, textAlign = TextAlign.Center, modifier = Modifier.weight(1f).semantics { heading() })
            Button(onClick = onDone) { Text("Done") }
        }
        Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f)) {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    listOf(false, true).forEachIndexed { index, value ->
                        SegmentedButton(selected = portrait == value, onClick = { onOrientation(value) },
                            shape = SegmentedButtonDefaults.itemShape(index, 2)) { Text(if (value) "Portrait" else "Landscape", maxLines = 1) }
                    }
                }
            }
            Box {
                OutlinedButton(onClick = { adding = true }) { Text("Add Control") }
                DropdownMenu(expanded = adding, onDismissRequest = { adding = false }, modifier = Modifier.heightIn(max = 480.dp)) { addMenu { adding = false } }
            }
        }
    }
}

/** iOS `addMenu`: everything but a user shortcut appears once per orientation. */
@Composable
private fun AddControlMenu(arrangement: CustomControlArrangement, functionItems: List<ShortcutItem>, onShortcut: () -> Unit, onAdd: (CustomControlKind) -> Unit) {
    @Composable
    fun header(text: String) = Text(text, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp))
    @Composable
    fun entry(kind: CustomControlKind) = DropdownMenuItem(
        text = { Text(kind.editorTitle(functionItems)) }, enabled = CustomLayoutEditing.canAdd(arrangement, kind), onClick = { onAdd(kind) },
    )
    DropdownMenuItem(text = { Text("Keyboard Shortcut…") }, onClick = onShortcut)
    header("Modifiers")
    CustomControlArrangement.templateModifiers.forEach { entry(CustomControlKind.Tray(it)) }
    header("System")
    CustomControlArrangement.templateSystem.forEach { entry(it) }
    header("Keys & Utilities")
    listOf(ControlTrayItem.Escape, ControlTrayItem.Tab, ControlTrayItem.Keyboard, ControlTrayItem.Dock).forEach { entry(CustomControlKind.Tray(it)) }
    entry(CustomControlKind.MoveView)
    if (functionItems.isNotEmpty()) {
        header("Actions")
        functionItems.forEach { entry(CustomControlKind.Function(it.id)) }
    }
}

/**
 * The surface at the device's proportions, scaled to fit, through the same
 * geometry as the live overlay: [CustomLayoutGeometry.layoutArea], `frame`,
 * `droppedPosition` and, for a selected modifier, `palettePoints`.
 */
@Composable
private fun LayoutCanvas(
    modifier: Modifier,
    arrangement: CustomControlArrangement,
    portrait: Boolean,
    metrics: PadControlMetrics,
    functionItems: List<ShortcutItem>,
    paletteActions: (ControlModifier) -> List<ShortcutItem>,
    selectedID: String?,
    snapToEdges: Boolean,
    snapToGuides: Boolean,
    onSelect: (String?) -> Unit,
    onDrop: (String, com.raisecaterror.meowdisplay.core.controls.NormalizedPosition) -> Unit,
) {
    val configuration = LocalConfiguration.current
    val long = max(configuration.screenWidthDp, configuration.screenHeightDp).toDouble()
    val short = min(configuration.screenWidthDp, configuration.screenHeightDp).toDouble()
    // Custom layouts apply only to large windows: on a phone, edit them on the tablet reference
    // surface the template is built for, so controls keep their real proportions.
    val device = when {
        short < 600 -> (if (portrait) CustomControlArrangement.referencePortrait else CustomControlArrangement.referenceLandscape)
            .let { CGRect(0.0, 0.0, it.width, it.height) }
        portrait -> CGRect(0.0, 0.0, short, long)
        else -> CGRect(0.0, 0.0, long, short)
    }
    // The receiver surface keeps a thin top inset and the gesture bar clear, as iOS does.
    val area = CustomLayoutGeometry.layoutArea(device, ControlSafeInsets(top = 24.0, leading = 0.0, bottom = 20.0, trailing = 0.0))
    val base = metrics.item
    val frames = CustomLayoutGeometry.frames(arrangement, area, base)
    val density = LocalDensity.current
    val drags = remember(arrangement) { mutableStateMapOf<String, Offset>() }
    val currentDrop by rememberUpdatedState(onDrop)
    val currentSelect by rememberUpdatedState(onSelect)

    BoxWithConstraints(modifier.padding(12.dp), contentAlignment = Alignment.Center) {
        val scale = min(maxWidth.value / device.width, maxHeight.value / device.height).toFloat()
        val surface = Color(0xFF16161A)
        Box(
            Modifier.size((device.width * scale).dp, (device.height * scale).dp)
                .background(surface, RoundedCornerShape(18.dp))
                .border(1.dp, MaterialTheme.colorScheme.outlineVariant, RoundedCornerShape(18.dp))
                .pointerInput(Unit) { detectTapGestures { currentSelect(null) } }
                .semantics { contentDescription = "Layout canvas, ${if (portrait) "portrait" else "landscape"}" },
        ) {
            val guide = MaterialTheme.colorScheme.primary
            Canvas(Modifier.fillMaxSize()) {
                val s = scale * density.density
                val left = (area.minX * s).toFloat(); val top = (area.minY * s).toFloat()
                val right = (area.maxX * s).toFloat(); val bottom = (area.maxY * s).toFloat()
                val dashed = PathEffect.dashPathEffect(floatArrayOf(6f, 6f))
                drawRect(Color.White.copy(alpha = 0.18f), Offset(left, top), androidx.compose.ui.geometry.Size(right - left, bottom - top),
                    style = androidx.compose.ui.graphics.drawscope.Stroke(1f, pathEffect = dashed))
                if (snapToGuides) {
                    for (i in 1 until 24) {
                        val x = left + (right - left) * i / 24f
                        val y = top + (bottom - top) * i / 24f
                        drawLine(Color.White.copy(alpha = 0.05f), Offset(x, top), Offset(x, bottom))
                        drawLine(Color.White.copy(alpha = 0.05f), Offset(left, y), Offset(right, y))
                    }
                }
                if (snapToEdges) {
                    val midX = (left + right) / 2; val midY = (top + bottom) / 2
                    drawLine(guide.copy(alpha = 0.25f), Offset(midX, top), Offset(midX, bottom), pathEffect = dashed)
                    drawLine(guide.copy(alpha = 0.25f), Offset(left, midY), Offset(right, midY), pathEffect = dashed)
                }
            }
            // The selected modifier's palette, where it blooms at runtime.
            val anchor = arrangement.placements.firstOrNull { it.id == selectedID && it.kind.modifier != null }
            if (anchor != null && drags.isEmpty()) {
                val actions = paletteActions(anchor.kind.modifier!!)
                val key = CustomLayoutGeometry.paletteKeyDiameter(base)
                CustomLayoutGeometry.palettePoints(actions.size, anchor.id, arrangement, frames, area, base, metrics.gap)
                    .zip(actions).forEach { (point, action) ->
                        Box(
                            Modifier.absoluteOffset(((point.x - key / 2) * scale).dp, ((point.y - key / 2) * scale).dp)
                                .size((key * scale).dp).background(Color(0xFF2C2C30).copy(alpha = 0.9f), CircleShape),
                            contentAlignment = Alignment.Center,
                        ) { ControlFaceView(CustomControlKind.Shortcut(action), emptyList(), (key * scale).dp, Color.White.copy(alpha = 0.8f)) }
                    }
            }
            arrangement.placements.mapNotNull { p -> frames[p.id]?.let { p to it } }.forEach { (placement, frame) ->
              key(placement.id) {
                // The drag handler lives across recompositions; it reads the latest values here.
                val latest by rememberUpdatedState(DragContext(frame, scale, area, snapToEdges, snapToGuides))
                val drag = drags[placement.id] ?: Offset.Zero
                val dx = with(density) { drag.x.toDp().value }
                val dy = with(density) { drag.y.toDp().value }
                val isSelected = placement.id == selectedID
                Box(
                    Modifier
                        .absoluteOffset((frame.minX * scale + dx).dp, (frame.minY * scale + dy).dp)
                        .size((frame.width * scale).dp)
                        .background(if (isSelected) MaterialTheme.colorScheme.primary.copy(alpha = 0.85f) else Color(0xFF3A3A3F), CircleShape)
                        .border(if (isSelected) 2.dp else 1.dp, if (isSelected) Color.White else Color.White.copy(alpha = 0.2f), CircleShape)
                        .pointerInput(placement.id) { detectTapGestures { currentSelect(placement.id) } }
                        .pointerInput(placement.id) {
                            detectDragGestures(
                                onDragStart = { currentSelect(placement.id) },
                                onDragCancel = { drags.remove(placement.id) },
                                onDragEnd = {
                                    val moved = drags.remove(placement.id) ?: Offset.Zero
                                    val c = latest
                                    val center = CGPoint(
                                        c.frame.midX + moved.x / density.density / c.scale,
                                        c.frame.midY + moved.y / density.density / c.scale,
                                    )
                                    currentDrop(placement.id, CustomLayoutGeometry.droppedPosition(center, c.area, c.frame.width, c.snapToEdges, c.snapToGuides))
                                },
                            ) { change, amount ->
                                change.consume()
                                drags[placement.id] = (drags[placement.id] ?: Offset.Zero) + amount
                            }
                        }
                        .semantics {
                            // Tapping selects and dragging moves; a screen reader gets both as actions (moves go through the same drop and snapping).
                            contentDescription = placement.kind.editorTitle(functionItems)
                            role = Role.Button
                            stateDescription = if (isSelected) "Selected" else "Not selected"
                            onClick(label = "Select") { currentSelect(placement.id); true }
                            fun nudge(dx: Double, dy: Double): Boolean {
                                val c = latest
                                currentSelect(placement.id)
                                currentDrop(placement.id, CustomLayoutGeometry.droppedPosition(
                                    CGPoint(c.frame.midX + dx, c.frame.midY + dy), c.area, c.frame.width, c.snapToEdges, c.snapToGuides,
                                ))
                                return true
                            }
                            customActions = listOf(
                                CustomAccessibilityAction("Move left") { nudge(-NUDGE, 0.0) },
                                CustomAccessibilityAction("Move right") { nudge(NUDGE, 0.0) },
                                CustomAccessibilityAction("Move up") { nudge(0.0, -NUDGE) },
                                CustomAccessibilityAction("Move down") { nudge(0.0, NUDGE) },
                            )
                        },
                    contentAlignment = Alignment.Center,
                ) { ControlFaceView(placement.kind, functionItems, (frame.width * scale).dp) }
              }
            }
        }
    }
}

/** One screen-reader move, in the layout's own units: more than a snapping step, so a nudge always lands somewhere new. */
private const val NUDGE = 48.0

private class DragContext(val frame: CGRect, val scale: Float, val area: CGRect, val snapToEdges: Boolean, val snapToGuides: Boolean)

@Composable
private fun PlacementInspector(
    placement: CustomControlPlacement,
    functionItems: List<ShortcutItem>,
    onResize: (Double) -> Unit,
    onRestyle: ((PalettePresentation) -> PalettePresentation) -> Unit,
    onEditShortcut: (ShortcutItem) -> Unit,
    onRemove: () -> Unit,
    onDeselect: () -> Unit,
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(placement.kind.editorTitle(functionItems), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f).semantics { heading() })
        TextButton(onClick = onDeselect) { Text("Layout Options") }
    }
    LabeledSlider("Size", placement.size.toFloat(),
        CustomControlPlacement.sizeRange.start.toFloat()..CustomControlPlacement.sizeRange.endInclusive.toFloat()) { onResize(it.toDouble()) }
    (placement.kind as? CustomControlKind.Shortcut)?.let { shortcut ->
        OutlinedButton(onClick = { onEditShortcut(shortcut.item) }) { Text("Edit Shortcut…") }
    }
    if (placement.kind.modifier != null) {
        val style = placement.palette ?: PalettePresentation()
        Section("Shortcut Palette")
        ChipChoice("Shape", PaletteShape.entries, style.shape, { it.title }) { shape -> onRestyle { it.copy(shape = shape) } }
        Column {
            Row { Text("Palette Distance", Modifier.weight(1f)); Text("%.1f×".format(style.spacing)) }
            Slider(style.spacing.toFloat(), { value -> onRestyle { it.copy(spacing = value.toDouble()) } },
                valueRange = PalettePresentation.spacingRange.start.toFloat()..PalettePresentation.spacingRange.endInclusive.toFloat(),
                modifier = Modifier.semantics { contentDescription = "Palette Distance"; stateDescription = "%.1f times".format(style.spacing) })
        }
        Toggle("Toward Screen Center", style.directionDegrees == null) { on -> onRestyle { it.copy(directionDegrees = if (on) null else 0.0) } }
        style.directionDegrees?.let { degrees ->
            Column {
                Row { Text("Palette Direction", Modifier.weight(1f)); Text("${degrees.roundToInt()}°") }
                // 15° steps across −180…180, as iOS.
                Slider(degrees.toFloat(), { value -> onRestyle { it.copy(directionDegrees = (value / 15f).roundToInt() * 15.0) } },
                    valueRange = -180f..180f, steps = 23,
                    modifier = Modifier.semantics { contentDescription = "Palette Direction"; stateDescription = "${degrees.roundToInt()} degrees" })
            }
        }
        Caption("The canvas shows this modifier's palette while it's selected. Its actions come from your Control Profile (Settings → Controls → Shortcut Palettes).")
    }
    if (CustomLayoutEditing.isRemovable(placement.kind)) {
        TextButton(onClick = onRemove, modifier = Modifier.semantics { contentDescription = "Remove ${placement.kind.editorTitle(functionItems)}" }) {
            Text("Remove", color = MaterialTheme.colorScheme.error)
        }
    } else {
        Caption("Settings always stays on the layout so you can reach these options.")
    }
}

@Composable
private fun LayoutOptions(
    layout: CustomControlLayout, snapToEdges: Boolean, snapToGuides: Boolean,
    onRename: (String) -> Unit, onSnapToEdges: (Boolean) -> Unit, onSnapToGuides: (Boolean) -> Unit,
    onTwoHandAssist: (Boolean) -> Unit, onFunctionProfile: (ControlProfileSlot?) -> Unit, onUseTemplate: () -> Unit,
) {
    var name by remember(layout.id) { mutableStateOf(layout.name) }
    OutlinedTextField(name, { text ->
        name = text.take(40)
        name.trim().takeIf { it.isNotEmpty() }?.let(onRename)
    }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    Caption("Drag a control to move it. Tap one to resize it, change its palette or remove it.")
    Section("Guides")
    Toggle("Snap to Edges", snapToEdges, onChange = onSnapToEdges)
    Toggle("Snap to Guides", snapToGuides, onChange = onSnapToGuides)
    Section("Two-Hand Assist")
    Toggle("Use Two-Hand Assist", layout.twoHandAssist, onChange = onTwoHandAssist)
    Caption("While a modifier is held, its partner modifiers appear on the opposite side.")
    ChipChoice("Actions From", listOf<ControlProfileSlot?>(null) + ControlProfileSlot.entries, layout.functionProfile, { it?.title ?: "Active Profile" }) { onFunctionProfile(it) }
    Caption("Which Function Tray profile this layout's action controls come from.")
    OutlinedButton(onClick = onUseTemplate) { Text("Use Template") }
}
