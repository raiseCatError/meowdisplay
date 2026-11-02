package com.raisecaterror.meowdisplay.android.receiver

import android.view.KeyEvent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentSize
import androidx.compose.material3.LocalTextStyle
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.raisecaterror.meowdisplay.android.receiver.overlay.GlyphIcon
import com.raisecaterror.meowdisplay.android.receiver.overlay.ChipFace
import com.raisecaterror.meowdisplay.android.receiver.overlay.OverlayGlyph
import com.raisecaterror.meowdisplay.android.receiver.overlay.OverlayGlyphs
import com.raisecaterror.meowdisplay.core.controls.AppGestureCommandKind
import com.raisecaterror.meowdisplay.core.controls.ControlAction
import com.raisecaterror.meowdisplay.core.controls.ControlModifier
import com.raisecaterror.meowdisplay.core.controls.ControlProfile
import com.raisecaterror.meowdisplay.core.controls.ControlTrayItem
import com.raisecaterror.meowdisplay.core.controls.FunctionTrayProfile
import com.raisecaterror.meowdisplay.core.controls.CustomControlKind
import com.raisecaterror.meowdisplay.core.controls.KeyboardShortcut
import com.raisecaterror.meowdisplay.core.controls.ModifierChord
import com.raisecaterror.meowdisplay.core.controls.ReceiverGesture
import com.raisecaterror.meowdisplay.core.controls.ReceiverGestureActions
import com.raisecaterror.meowdisplay.core.controls.ShortcutButtonDisplay
import com.raisecaterror.meowdisplay.core.controls.ShortcutButtonFace
import com.raisecaterror.meowdisplay.core.controls.ShortcutDraft
import com.raisecaterror.meowdisplay.core.controls.ShortcutItem
import com.raisecaterror.meowdisplay.core.controls.appGestureCommandDisplayText
import com.raisecaterror.meowdisplay.core.controls.appGestureCommandEditableKeys
import com.raisecaterror.meowdisplay.core.controls.appGestureCommandKeyLabel
import com.raisecaterror.meowdisplay.core.controls.newUUIDString
import com.raisecaterror.meowdisplay.core.controls.title

// MARK: - Faces

/** A control's face as the overlay draws it, for editor lists and the layout canvas. */
@Composable
internal fun ControlFaceView(kind: CustomControlKind, functionItems: List<ShortcutItem>, diameter: Dp, color: Color = Color.White) {
    val d = diameter.value.toDouble()
    val face: ChipFace = when (kind) {
        is CustomControlKind.Tray -> when {
            kind.item.modifier != null -> ChipFace.Label(kind.item.modifier!!.symbol, d * 0.46)
            kind.item == ControlTrayItem.Escape || kind.item == ControlTrayItem.Tab -> ChipFace.Label(kind.item.displayLabel, d * 0.3)
            else -> ChipFace.Glyph(OverlayGlyphs.forSymbol(kind.item.displayLabel), d * 0.4)
        }
        CustomControlKind.MoveView -> ChipFace.Glyph(OverlayGlyph.Move, d * 0.38)
        is CustomControlKind.Function -> functionItems.firstOrNull { it.id == kind.id }?.let { itemFace(it, d) } ?: ChipFace.Label("?", d * 0.4)
        is CustomControlKind.Shortcut -> itemFace(kind.item, d)
    }
    Box(Modifier.size(diameter).wrapContentSize(unbounded = true), contentAlignment = Alignment.Center) {
        when (face) {
            is ChipFace.Glyph -> GlyphIcon(face.glyph, face.size.toFloat().dp, color)
            // The theme's 24sp line height is taller than a small canvas control: size the line to the font.
            is ChipFace.Label -> {
                val size = with(LocalDensity.current) { (if (face.shrinks) face.size * 0.9 else face.size).toFloat().dp.toSp() }
                Text(face.text, color = color, fontSize = size, lineHeight = size, maxLines = 1, softWrap = false,
                    style = LocalTextStyle.current.copy(platformStyle = PlatformTextStyle(includeFontPadding = false)))
            }
        }
    }
}

private fun itemFace(item: ShortcutItem, d: Double): ChipFace = when (val face = item.face) {
    is ShortcutButtonFace.Symbol -> ChipFace.Glyph(OverlayGlyphs.forSymbol(face.name), d * 0.42)
    is ShortcutButtonFace.Text -> ChipFace.Label(face.text, d * 0.3, shrinks = true)
}

@Composable
internal fun ItemBadge(item: ShortcutItem, diameter: Dp = 32.dp) {
    Box(Modifier.size(diameter).background(Color(0xFF383838), CircleShape), contentAlignment = Alignment.Center) {
        ControlFaceView(CustomControlKind.Shortcut(item), emptyList(), diameter)
    }
}

internal fun CustomControlKind.editorTitle(functionItems: List<ShortcutItem>): String = when (this) {
    is CustomControlKind.Tray -> item.title
    CustomControlKind.MoveView -> "Move View"
    is CustomControlKind.Function -> functionItems.firstOrNull { it.id == id }?.title ?: id
    is CustomControlKind.Shortcut -> item.title
}

// MARK: - Shortcut editor

private enum class ShortcutKind(val title: String) { Keys("Keyboard Shortcut"), MacAction("Mac Action") }

private enum class FaceChoice(val title: String) { Default("Default"), Keys("Keys"), Text("Text") }

/**
 * iOS `ShortcutButtonEditor`: a chord (modifiers + up to four keys, recorded
 * from a hardware keyboard or picked) or a Mac action, with a name and face.
 * [keysOnly] limits it to chords (Custom Layout shortcut controls).
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun ShortcutEditorDialog(
    initial: ShortcutItem?,
    defaultModifiers: Set<ControlModifier> = emptySet(),
    keysOnly: Boolean = false,
    onSave: (ShortcutItem) -> Unit,
    onDismiss: () -> Unit,
    /** Shown as Delete (with a confirmation) when the caller can delete this button. */
    onDelete: (() -> Unit)? = null,
) {
    var confirmingDelete by remember { mutableStateOf(false) }
    val start = remember(initial) { ShortcutDraft.initialChord(initial, defaultModifiers) }
    val initialGesture = (initial?.action as? ControlAction.ReceiverGestureAction)?.let { ReceiverGesture.of(it.name) }
    val isSequence = initial?.action is ControlAction.Sequence
    var kind by remember { mutableStateOf(if (initialGesture != null && !keysOnly) ShortcutKind.MacAction else ShortcutKind.Keys) }
    var modifiers by remember { mutableStateOf(start.first) }
    var keys by remember { mutableStateOf(start.second) }
    var gesture by remember { mutableStateOf(initialGesture ?: ReceiverGesture.MissionControl) }
    var name by remember { mutableStateOf(initial?.title?.takeIf { initial.title != initial.keysDescription } ?: "") }
    var faceChoice by remember {
        mutableStateOf(when (initial?.display) { ShortcutButtonDisplay.Keys -> FaceChoice.Keys; is ShortcutButtonDisplay.Text -> FaceChoice.Text; else -> FaceChoice.Default })
    }
    var faceText by remember { mutableStateOf((initial?.display as? ShortcutButtonDisplay.Text)?.text ?: "") }
    var recording by remember { mutableStateOf(false) }
    val id = remember(initial) { initial?.id ?: newUUIDString() }
    val display: ShortcutButtonDisplay? = when (faceChoice) {
        FaceChoice.Default -> (initial?.display as? ShortcutButtonDisplay.Symbol)
        FaceChoice.Keys -> ShortcutButtonDisplay.Keys
        FaceChoice.Text -> faceText.trim().takeIf { it.isNotEmpty() }?.let { ShortcutButtonDisplay.Text(it.take(ShortcutButtonDisplay.MAXIMUM_TEXT_LENGTH)) }
    }
    val item = when (kind) {
        ShortcutKind.Keys -> ShortcutDraft.keyboard(id, name, modifiers, keys, display)
        ShortcutKind.MacAction -> ShortcutDraft.gesture(id, name, gesture, display)
    }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.widthIn(max = 560.dp).fillMaxWidth().padding(16.dp), shape = MaterialTheme.shapes.large) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(if (initial == null) "New Button" else "Edit Button", style = MaterialTheme.typography.titleLarge, modifier = Modifier.semantics { heading() })
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    ItemBadge(item, 56.dp)
                    Column {
                        Text(item.title)
                        Text("Sends ${item.keysDescription}", style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                    }
                }
                if (isSequence) Caption("This button sends a sequence, which you can edit on iPhone or iPad. Saving here replaces it with what you choose below.")
                if (!keysOnly) Choice("Type", ShortcutKind.entries, kind, { it.title }) { kind = it }
                when (kind) {
                    ShortcutKind.Keys -> {
                        ShortcutRecorder(recording, onToggle = { recording = !recording }) { recordedModifiers, usage ->
                            modifiers = recordedModifiers
                            keys = listOf(usage)
                            recording = false
                        }
                        Text("Modifiers")
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            ControlModifier.entries.forEach { modifier ->
                                FilterChip(selected = modifier in modifiers, onClick = {
                                    modifiers = if (modifier in modifiers) modifiers - modifier else modifiers + modifier
                                }, label = { Text("${modifier.symbol} ${modifier.title}") })
                            }
                        }
                        keys.forEachIndexed { index, usage ->
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(if (keys.size > 1) "Key ${index + 1}" else "Key", Modifier.weight(1f))
                                KeyPicker(usage, exclude = keys.toSet() - usage) { picked -> keys = keys.toMutableList().also { it[index] = picked } }
                                if (keys.size > 1) TextButton(
                                    onClick = { keys = keys.filterIndexed { i, _ -> i != index } },
                                    modifier = Modifier.semantics { contentDescription = "Remove key ${index + 1}" },
                                ) { Text("Remove") }
                            }
                        }
                        if (keys.size < KeyboardShortcut.MAXIMUM_KEYS) {
                            TextButton(onClick = {
                                appGestureCommandEditableKeys.firstOrNull { it.second !in keys }?.let { keys = keys + it.second }
                            }) { Text("Add Another Key") }
                        }
                        Caption("Keys are pressed together, then released.")
                    }
                    ShortcutKind.MacAction -> ChipChoice("Action", ReceiverGestureActions.oneTap, gesture, { it.title }) { gesture = it }
                }
                HorizontalDivider()
                OutlinedTextField(name, { name = it.take(40) }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text(if (kind == ShortcutKind.Keys) item.keysDescription else gesture.title) })
                Choice("Face", FaceChoice.entries, faceChoice, { it.title }) { faceChoice = it }
                if (faceChoice == FaceChoice.Text) {
                    OutlinedTextField(faceText, { faceText = it.take(ShortcutButtonDisplay.MAXIMUM_TEXT_LENGTH) }, label = { Text("Up to 4 characters") }, singleLine = true)
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
                    if (onDelete != null) {
                        TextButton(onClick = { confirmingDelete = true }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
                        Box(Modifier.weight(1f))
                    }
                    TextButton(onClick = onDismiss) { Text("Cancel") }
                    Button(onClick = { onSave(item); onDismiss() }, enabled = item.action.isValid) { Text("Save") }
                }
            }
        }
    }
    if (confirmingDelete && onDelete != null) {
        DeleteConfirmation(initial?.title ?: "", onDelete = { confirmingDelete = false; onDelete() }, onCancel = { confirmingDelete = false })
    }
}

@Composable
private fun DeleteConfirmation(title: String, onDelete: () -> Unit, onCancel: () -> Unit) {
    AlertDialog(
        onDismissRequest = onCancel,
        title = { Text("Delete \u201C$title\u201D?") },
        confirmButton = { TextButton(onClick = onDelete) { Text("Delete", color = MaterialTheme.colorScheme.error) } },
        dismissButton = { TextButton(onClick = onCancel) { Text("Cancel") } },
    )
}

/** One key from the editable key list (letters, digits, symbols, special keys, F1–F12). */
@Composable
private fun KeyPicker(usage: Int, exclude: Set<Int> = emptySet(), onPick: (Int) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick = { open = true }, modifier = Modifier.semantics { contentDescription = "Key ${appGestureCommandKeyLabel(usage)}" }) {
            Text(appGestureCommandKeyLabel(usage))
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, modifier = Modifier.heightIn(max = 360.dp)) {
            appGestureCommandEditableKeys.filter { it.second !in exclude }.forEach { (label, value) ->
                DropdownMenuItem(text = { Text(label) }, onClick = { onPick(value); open = false })
            }
        }
    }
}

/**
 * Records one combination from a hardware keyboard (iOS `ShortcutRecorder`). Android never
 * delivers Meta (⌘) combinations to apps, so Control is offered as itself; pick ⌘ above.
 */
@Composable
private fun ShortcutRecorder(recording: Boolean, onToggle: () -> Unit, onRecorded: (Set<ControlModifier>, Int) -> Unit) {
    val focus = remember { FocusRequester() }
    OutlinedButton(onClick = onToggle, modifier = Modifier
        .focusRequester(focus)
        .focusable()
        .onPreviewKeyEvent { event ->
            val native = event.nativeKeyEvent
            if (!recording || native.action != KeyEvent.ACTION_DOWN) return@onPreviewKeyEvent false
            if (HidKeyMap.modifierKeyName(native.keyCode) != null) return@onPreviewKeyEvent true
            val usage = HidKeyMap.usage(native.keyCode) ?: return@onPreviewKeyEvent true
            if (usage !in KeyboardShortcut.VALID_USAGES) return@onPreviewKeyEvent true
            val names = HidKeyMap.modifierNames(native.metaState)
            onRecorded(ControlModifier.entries.filter { it.raw in names }.toSet(), usage)
            true
        }) { Text(if (recording) "Press Keys Now…" else "Record from Keyboard") }
    LaunchedEffect(recording) { if (recording) runCatching { focus.requestFocus() } }
    if (recording) Caption("Press the combination on a hardware keyboard.")
}

/** App Gesture Commands: one chord per command (iOS `AppGestureCommandEditor`). */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun GestureCommandDialog(kind: AppGestureCommandKind, initial: KeyboardShortcut, onSave: (KeyboardShortcut) -> Unit, onDismiss: () -> Unit) {
    var modifiers by remember { mutableStateOf(initial.modifiers.modifiers) }
    var usage by remember { mutableStateOf(initial.usage) }
    val shortcut = KeyboardShortcut(usage, ModifierChord(modifiers))
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(kind.title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ControlModifier.entries.forEach { modifier ->
                        FilterChip(selected = modifier in modifiers, onClick = {
                            modifiers = if (modifier in modifiers) modifiers - modifier else modifiers + modifier
                        }, label = { Text("${modifier.symbol} ${modifier.title}") })
                    }
                }
                Row(verticalAlignment = Alignment.CenterVertically) { Text("Key", Modifier.weight(1f)); KeyPicker(usage) { usage = it } }
                Text(appGestureCommandDisplayText(shortcut), style = MaterialTheme.typography.headlineSmall, fontFamily = FontFamily.Monospace)
            }
        },
        confirmButton = { Button(onClick = { onSave(shortcut); onDismiss() }, enabled = shortcut.isValid) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

// MARK: - Function Tray

/** iOS `FunctionTrayEditor`: reorder, show/hide, rename and restyle built-ins, add/edit/delete your own. */
@Composable
internal fun FunctionTrayEditor(controller: ReceiverController) {
    val prefs by controller.store.preferences.collectAsState()
    val slot = prefs.activeFunctionTrayProfile
    val profile = prefs.functionTrayProfile(slot)
    var editing by remember { mutableStateOf<String?>(null) }
    var creating by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    Section("Function Tray (${slot.title})")
    profile.items.forEachIndexed { index, configuration ->
        val item = configuration.resolvedItem
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ItemBadge(item)
            Column(Modifier.weight(1f).heightIn(min = 48.dp).clickable(role = Role.Button) { editing = item.id }.semantics {
                contentDescription = "Edit ${item.title}, sends ${item.keysDescription}" + if (configuration.isVisible) "" else ", hidden"
            }) {
                Text(item.title)
                Text(item.keysDescription + if (configuration.isVisible) "" else " · Hidden", style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
            ReorderButtons(index, profile.items.size, item.title) { from, to -> controller.store.updateActiveFunctionTrayProfile { it.moveItems(setOf(from), to) } }
            Switch(checked = configuration.isVisible, modifier = Modifier.semantics { contentDescription = "Show ${item.title}" }, onCheckedChange = { on ->
                controller.store.updateActiveFunctionTrayProfile { p -> p.items = p.items.map { if (it.id == item.id) it.copy(isVisible = on) else it } }
            })
        }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { creating = true }) { Text("Add Action") }
        TextButton(onClick = { controller.store.update { it.resetFunctionTrayProfile(slot) } }) { Text("Restore Defaults") }
    }
    Caption("Tap an action to rename it or change how it looks. Built-in actions can be hidden; your own can also be deleted.")
    message?.let { Caption(it) }

    if (creating) {
        ShortcutEditorDialog(initial = null, onSave = { item ->
            var added = false
            controller.store.updateActiveFunctionTrayProfile { added = it.addCustomItem(item) }
            message = if (added) null else "The Function Tray is full. Delete one of your actions first."
        }, onDismiss = { creating = false })
    }
    editing?.let { id ->
        val configuration = profile.items.firstOrNull { it.id == id } ?: return@let
        if (FunctionTrayProfile.isBuiltIn(id)) {
            BuiltInActionDialog(configuration.resolvedItem, configuration.customTitle ?: "", onSave = { title, display ->
                controller.store.updateActiveFunctionTrayProfile { it.rename(id, title); it.setDisplay(id, display) }
            }, onDismiss = { editing = null })
        } else {
            ShortcutEditorDialog(initial = configuration.item, onSave = { item ->
                controller.store.updateActiveFunctionTrayProfile { it.updateCustomItem(item) }
            }, onDismiss = { editing = null }, onDelete = {
                controller.store.updateActiveFunctionTrayProfile { it.removeItem(id) }
                editing = null
            })
        }
    }
}

/** A built-in action keeps what it sends; only its name and face are yours. */
@Composable
private fun BuiltInActionDialog(item: ShortcutItem, customTitle: String, onSave: (String, ShortcutButtonDisplay?) -> Unit, onDismiss: () -> Unit) {
    var name by remember { mutableStateOf(customTitle) }
    var choice by remember { mutableStateOf(when (item.display) { ShortcutButtonDisplay.Keys -> FaceChoice.Keys; is ShortcutButtonDisplay.Text -> FaceChoice.Text; else -> FaceChoice.Default }) }
    var faceText by remember { mutableStateOf((item.display as? ShortcutButtonDisplay.Text)?.text ?: "") }
    val display = when (choice) {
        FaceChoice.Default -> null
        FaceChoice.Keys -> ShortcutButtonDisplay.Keys
        FaceChoice.Text -> faceText.trim().takeIf { it.isNotEmpty() }?.let(ShortcutButtonDisplay::Text)
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(item.title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    ItemBadge(item.copy(display = display ?: item.display.takeIf { choice != FaceChoice.Default }), 48.dp)
                    Text("Sends ${item.keysDescription}", fontFamily = FontFamily.Monospace)
                }
                OutlinedTextField(name, { name = it.take(40) }, label = { Text("Name") }, placeholder = { Text(item.title) }, singleLine = true)
                Choice("Face", FaceChoice.entries, choice, { it.title }) { choice = it }
                if (choice == FaceChoice.Text) {
                    OutlinedTextField(faceText, { faceText = it.take(ShortcutButtonDisplay.MAXIMUM_TEXT_LENGTH) }, label = { Text("Up to 4 characters") }, singleLine = true)
                }
            }
        },
        confirmButton = { Button(onClick = { onSave(name, display); onDismiss() }) { Text("Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun ReorderButtons(index: Int, count: Int, name: String, onMove: (Int, Int) -> Unit) {
    TextButton(onClick = { onMove(index, index - 1) }, enabled = index > 0, modifier = Modifier.semantics { contentDescription = "Move $name up" }) { Text("↑") }
    // `moveItems` uses SwiftUI onMove semantics: moving down one row targets index + 2.
    TextButton(onClick = { onMove(index, index + 2) }, enabled = index < count - 1, modifier = Modifier.semantics { contentDescription = "Move $name down" }) { Text("↓") }
}

// MARK: - Chord palettes

/** iOS `ChordPaletteEditor`: the actions a held or latched modifier chord shows. */
@Composable
internal fun ChordPaletteEditor(controller: ReceiverController) {
    val prefs by controller.store.preferences.collectAsState()
    val profile = prefs.profile(prefs.activeControlProfile)
    val chords = (ControlModifier.entries.map { ModifierChord(it) } + profile.palettes.map { it.chord }).distinct()
    var chord by remember { mutableStateOf(chords.first()) }
    var editing by remember { mutableStateOf<ShortcutItem?>(null) }
    var creating by remember { mutableStateOf(false) }
    var adding by remember { mutableStateOf(false) }
    val actions = profile.actions(chord)
    val functionItems = prefs.functionTrayProfile(prefs.activeFunctionTrayProfile).allItems
    fun setActions(next: List<ShortcutItem>) = controller.store.updateActiveProfile { it.setActions(next, chord) }

    Section("Shortcut Palettes (${prefs.activeControlProfile.title})")
    ChipChoice("Modifier Chord", chords, chord, { it.displayName }) { chord = it }
    actions.forEachIndexed { index, action ->
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            ItemBadge(action)
            Column(Modifier.weight(1f).heightIn(min = 48.dp).clickable(role = Role.Button) { editing = action }.semantics {
                contentDescription = "Edit ${action.title}, sends ${action.keysDescription}"
            }) {
                Text(action.title)
                Text(action.keysDescription, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
            ReorderButtons(index, actions.size, action.title) { from, to -> controller.store.updateActiveProfile { it.moveActions(chord, setOf(from), to) } }
            TextButton(onClick = { setActions(actions.filterIndexed { i, _ -> i != index }) }, modifier = Modifier.semantics { contentDescription = "Remove ${action.title}" }) { Text("Remove") }
        }
    }
    if (actions.isEmpty()) Caption("No actions yet. Hold or latch ${chord.symbols} to show what you add here.")
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box {
            OutlinedButton(onClick = { adding = true }) { Text("Add Action") }
            DropdownMenu(expanded = adding, onDismissRequest = { adding = false }, modifier = Modifier.heightIn(max = 420.dp)) {
                DropdownMenuItem(text = { Text("Shortcut…") }, onClick = { adding = false; creating = true })
                HorizontalDivider()
                Text("Function Action", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
                functionItems.forEach { item ->
                    // Palette entries own their definition: a copied action is independent of the tray.
                    DropdownMenuItem(text = { Text(item.title) }, onClick = { adding = false; setActions(actions + item.copy(id = newUUIDString())) })
                }
                HorizontalDivider()
                Text("Mac Action", style = MaterialTheme.typography.labelMedium, modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp))
                ReceiverGestureActions.oneTap.forEach { gesture ->
                    DropdownMenuItem(text = { Text(gesture.title) }, onClick = { adding = false; setActions(actions + ShortcutDraft.gesture(newUUIDString(), "", gesture, null)) })
                }
            }
        }
        TextButton(onClick = { setActions(ControlProfile.canonical().actions(chord)) }) { Text("Restore This Palette") }
    }
    Caption("Tap an action to change what it sends or how it looks.")
    if (creating) {
        ShortcutEditorDialog(initial = null, defaultModifiers = chord.modifiers, onSave = { setActions(actions + it) }, onDismiss = { creating = false })
    }
    editing?.let { current ->
        ShortcutEditorDialog(initial = current, defaultModifiers = chord.modifiers, onSave = { item ->
            setActions(actions.map { if (it.id == item.id) item else it })
        }, onDismiss = { editing = null })
    }
}

// MARK: - App Gesture Commands

@Composable
internal fun AppGestureCommandsEditor(controller: ReceiverController) {
    val prefs by controller.store.preferences.collectAsState()
    var editing by remember { mutableStateOf<AppGestureCommandKind?>(null) }
    AppGestureCommandKind.entries.forEach { kind ->
        val shortcut = prefs.appGestureCommands.shortcut(kind)
        Row(
            Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button) { editing = kind }.padding(vertical = 6.dp)
                .semantics { contentDescription = "Edit ${kind.title}, now ${appGestureCommandDisplayText(shortcut)}" },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(kind.title, Modifier.weight(1f))
            Text(appGestureCommandDisplayText(shortcut), fontFamily = FontFamily.Monospace)
        }
    }
    editing?.let { kind ->
        GestureCommandDialog(kind, prefs.appGestureCommands.shortcut(kind), onSave = { shortcut ->
            controller.store.update { it.appGestureCommands = it.appGestureCommands.copy().also { c -> c.setShortcut(shortcut, kind) } }
        }, onDismiss = { editing = null })
    }
}
