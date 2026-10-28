package com.raisecaterror.meowdisplay.android.receiver

import androidx.compose.material3.FilterChip
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import android.content.ClipData
import android.content.ClipboardManager
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.raisecaterror.meowdisplay.android.session.MediaController
import com.raisecaterror.meowdisplay.core.controls.AVSyncOffset
import com.raisecaterror.meowdisplay.core.controls.ControlEdge
import com.raisecaterror.meowdisplay.core.controls.ControlProfileSlot
import com.raisecaterror.meowdisplay.core.controls.CustomLayoutShareCode
import com.raisecaterror.meowdisplay.core.controls.FunctionTrayPosition
import com.raisecaterror.meowdisplay.core.controls.LandscapeTraySide
import com.raisecaterror.meowdisplay.core.controls.PadControlLayoutMode
import com.raisecaterror.meowdisplay.core.controls.PadControlScale
import com.raisecaterror.meowdisplay.core.controls.PadPaletteStyle
import com.raisecaterror.meowdisplay.core.controls.PadStandardControl
import com.raisecaterror.meowdisplay.core.controls.PointerGestureConfig
import com.raisecaterror.meowdisplay.core.controls.PointerInputMode
import com.raisecaterror.meowdisplay.core.controls.ReceiverControlPreferences
import com.raisecaterror.meowdisplay.core.controls.ReceiverGestureTarget
import com.raisecaterror.meowdisplay.core.controls.ShareCodeResult
import com.raisecaterror.meowdisplay.core.controls.activeCustomLayout
import com.raisecaterror.meowdisplay.core.controls.appGestureCommandDisplayText
import com.raisecaterror.meowdisplay.core.controls.canCreateCustomLayout
import com.raisecaterror.meowdisplay.core.controls.createCustomLayout
import com.raisecaterror.meowdisplay.core.controls.deleteCustomLayout
import com.raisecaterror.meowdisplay.core.controls.importCustomLayout
import com.raisecaterror.meowdisplay.core.session.InputWireState
import kotlin.math.roundToInt

/** The receiver categories of the iOS Settings (MobileSettingsCategory), plus the session actions. */
enum class SettingsPage(val title: String) {
    Input("Input"), Gestures("Gestures"), Controls("Controls"), TabletLayout("Tablet Layout"),
    Display("Display"), Audio("Audio"), Session("Session"), Help("Help & About"),
}

/**
 * Receiver Settings over the live session: a list beside its page on a large
 * window (like the iPad split view), a list that opens pages on a compact one.
 * Every change goes through the control store, which releases held input when
 * a change makes it stale.
 */
@Composable
fun ReceiverSettings(
    controller: ReceiverController, media: MediaController, onDismiss: () -> Unit, onStartPictureInPicture: (() -> Unit)? = null,
    diagnostics: com.raisecaterror.meowdisplay.android.media.DiagnosticsPrefs? = null,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
            BoxWithConstraints(Modifier.safeDrawingPadding()) {
                val wide = maxWidth >= 600.dp
                var page by remember { mutableStateOf(if (wide) SettingsPage.Input else null) }
                Column(Modifier.fillMaxSize()) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (!wide && page != null) TextButton(onClick = { page = null }) { Text("Settings") }
                        Text(
                            if (!wide && page != null) page!!.title else "Settings",
                            style = MaterialTheme.typography.titleLarge,
                            modifier = Modifier.weight(1f).padding(horizontal = 8.dp).semantics { heading() },
                        )
                        TextButton(onClick = onDismiss) { Text("Done", fontWeight = FontWeight.SemiBold) }
                    }
                    HorizontalDivider()
                    Row(Modifier.fillMaxSize()) {
                        if (wide || page == null) {
                            Column(Modifier.then(if (wide) Modifier.width(240.dp) else Modifier.fillMaxWidth()).fillMaxHeight().verticalScroll(rememberScrollState())) {
                                SettingsPage.entries.forEach { entry ->
                                    val selected = wide && entry == page
                                    Text(
                                        entry.title,
                                        Modifier.fillMaxWidth()
                                            .background(if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface)
                                            .clickable { page = entry }
                                            .padding(horizontal = 20.dp, vertical = 14.dp),
                                        style = MaterialTheme.typography.bodyLarge,
                                    )
                                }
                            }
                        }
                        page?.let { current ->
                            Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                                SettingsPageContent(current, controller, media, onDismiss, onStartPictureInPicture, diagnostics)
                            }
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SettingsPageContent(
    page: SettingsPage, controller: ReceiverController, media: MediaController, onDismiss: () -> Unit, onStartPictureInPicture: (() -> Unit)?,
    diagnostics: com.raisecaterror.meowdisplay.android.media.DiagnosticsPrefs?,
) {
    val store = controller.store
    val prefs by store.preferences.collectAsState()
    val view by controller.view.collectAsState()
    fun set(change: (ReceiverControlPreferences) -> Unit) = store.update(change)
    when (page) {
        SettingsPage.Input -> {
            Section("Input")
            Text(inputStatus(view.inputState), style = MaterialTheme.typography.bodyMedium)
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = { controller.requestInput(true) }, enabled = view.inputState != InputWireState.Allowed && view.inputState != InputWireState.RequestsDisabled) {
                    Text("Request Input")
                }
                OutlinedButton(onClick = { controller.requestInput(false) }, enabled = view.inputState == InputWireState.Allowed) { Text("Turn Off") }
            }
            Caption("Your Mac decides. Every session starts View Only; input stops the moment the Mac revokes it.")
            Section("Pointer")
            Choice("Touch Mode", PointerInputMode.entries, prefs.inputMode, { it.title }) { mode -> set { it.inputMode = mode } }
            if (prefs.inputMode == PointerInputMode.Trackpad) {
                LabeledSlider(
                    "Trackpad Speed", prefs.trackpadSensitivity.toFloat(),
                    PointerGestureConfig.trackpadSensitivityRange.start.toFloat()..PointerGestureConfig.trackpadSensitivityRange.endInclusive.toFloat(),
                ) { value -> set { it.trackpadSensitivity = value.toDouble() } }
            }
            Toggle("Smart Touch (Experimental)", prefs.smartTouchEnabled) { on -> set { it.smartTouchEnabled = on } }
            Caption("A one-finger swipe scrolls when the Mac says the element under it scrolls; hold on a title bar to drag the window.")
            Toggle("Smart Touch Haptics", prefs.smartTouchLongPressHapticEnabled) { on -> set { it.smartTouchLongPressHapticEnabled = on } }
            Section("Hardware Keyboard")
            Toggle("Control Key Types ⌘", prefs.controlKeyAsCommand) { on -> set { it.controlKeyAsCommand = on } }
            Caption("Android keeps the ⌘ (Meta) key's shortcuts for itself, so turn this on to press Control-C for ⌘C on your Mac. The on-screen ^ key still sends Control.")
            Section("Scrolling")
            Toggle("Natural Vertical Scrolling", prefs.invertVerticalScroll) { on -> set { it.invertVerticalScroll = on } }
            Toggle("Natural Horizontal Scrolling", prefs.invertHorizontalScroll) { on -> set { it.invertHorizontalScroll = on } }
            Toggle("Haptics", prefs.hapticsEnabled) { on -> set { it.hapticsEnabled = on } }
        }
        SettingsPage.Gestures -> {
            Section("Two-Finger Gestures")
            Choice("Pinch", ReceiverGestureTarget.entries, prefs.pinchTarget, { it.title }) { target -> set { it.pinchTarget = target } }
            // Android draws the picture on a SurfaceView, which can't rotate: rotation offers App or Disabled.
            val rotateChoices = listOf(ReceiverGestureTarget.App, ReceiverGestureTarget.Disabled)
            val rotation = if (prefs.rotateTarget == ReceiverGestureTarget.Viewport) ReceiverGestureTarget.Disabled else prefs.rotateTarget
            Choice("Rotate", rotateChoices, rotation, { it.title }) { target -> set { it.rotateTarget = target } }
            Toggle("Local View Navigation", prefs.allowLocalViewNavigation) { on -> set { it.allowLocalViewNavigation = on } }
            Caption("Pinch to zoom the picture up to 8×, two fingers to pan, two-finger double tap to reset and restore. Never sent to the Mac.")
            Toggle("Prefer MeowDisplay Gestures", prefs.preferMeowDisplayGestures) { on -> set { it.preferMeowDisplayGestures = on } }
            Section("App Gesture Commands")
            Caption("Sent when Pinch or Rotate targets the App.")
            listOf("Zoom In" to prefs.appGestureCommands.zoomIn, "Zoom Out" to prefs.appGestureCommands.zoomOut,
                "Rotate Left" to prefs.appGestureCommands.rotateLeft, "Rotate Right" to prefs.appGestureCommands.rotateRight).forEach { (title, shortcut) ->
                Row(Modifier.fillMaxWidth()) { Text(title, Modifier.weight(1f)); Text(appGestureCommandDisplayText(shortcut)) }
            }
            OutlinedButton(onClick = { set { it.resetAppGestureCommands() } }) { Text("Reset to Defaults") }
        }
        SettingsPage.Controls -> {
            Section("Main Tray")
            Toggle("Show Controls", prefs.trayEnabled) { on -> set { it.trayEnabled = on } }
            Toggle("Collapse to Settings Button", prefs.trayCollapsed) { on -> set { it.trayCollapsed = on } }
            Toggle("Keyboard Button", prefs.keyboardButtonEnabled) { on -> set { it.keyboardButtonEnabled = on } }
            Choice("Profile", ControlProfileSlot.entries, prefs.activeControlProfile, { it.title }) { slot -> set { it.activeControlProfile = slot } }
            Choice("Landscape Side", LandscapeTraySide.entries, prefs.preferredLandscapeSide, { it.title }) { side -> set { it.preferredLandscapeSide = side } }
            ProfileTrayEditor(controller)
            Section("Function Tray")
            Toggle("Show Function Tray", prefs.functionTrayEnabled) { on -> set { it.functionTrayEnabled = on } }
            Choice("Profile", ControlProfileSlot.entries, prefs.activeFunctionTrayProfile, { it.title }) { slot -> set { it.activeFunctionTrayProfile = slot } }
            Choice("Position", FunctionTrayPosition.entries, prefs.functionTrayPosition, { it.title }) { position -> set { it.functionTrayPosition = position } }
            FunctionTrayEditor(controller)
            Section("Behavior")
            Toggle("Auto-hide", prefs.autoHideEnabled) { on -> set { it.autoHideEnabled = on } }
            Toggle("Avoid Cutouts", prefs.avoidNotch) { on -> set { it.avoidNotch = on } }
        }
        SettingsPage.TabletLayout -> {
            Caption("Used whenever the window is large enough (tablets, unfolded foldables, large split-screen panes). Phones and folded foldables use the compact tray.")
            Choice("Control Layout", PadControlLayoutMode.entries, prefs.padControlLayout, { it.title }) { mode -> set { it.padControlLayout = mode } }
            Choice("Main Controls", ControlEdge.entries, prefs.padMainEdge, { it.title }) { edge -> set { it.padMainEdge = edge } }
            Choice("Function Controls", ControlEdge.entries, prefs.padFunctionEdge, { it.title }) { edge -> set { it.padFunctionEdge = edge } }
            Choice("Palette", PadPaletteStyle.entries, prefs.padOverlayPaletteStyle, { it.title }) { style -> set { it.padOverlayPaletteStyle = style } }
            LabeledSlider("Control Size", prefs.padControlScale.toFloat(), PadControlScale.range.start.toFloat()..PadControlScale.range.endInclusive.toFloat()) { value ->
                set { it.padControlScale = PadControlScale.clamped(value.toDouble()) }
            }
            Toggle("Control Hints (Strip)", prefs.padShowControlHints) { on -> set { it.padShowControlHints = on } }
            Section("Standard Controls")
            PadStandardControl.entries.forEach { control ->
                Toggle(control.title, prefs.padStandardControls.isVisible(control)) { on -> set { it.padStandardControls.setVisible(on, control) } }
            }
            CustomLayoutsSection(controller)
        }
        SettingsPage.Display -> {
            val ws = controller.workspace
            val wsUi = ws?.ui?.collectAsState()?.value
            val mediaUi by media.ui.collectAsState()
            Section("What This Device Shows")
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOfNotNull(DisplayMode.Mirror, DisplayMode.Extend, DisplayMode.Window.takeIf { wsUi?.available == true }).forEach { mode ->
                    val selected = mediaUi.source == mode.wire
                    FilterChip(selected = selected, onClick = { media.session.requestDisplayMode(mode) },
                        label = { Text(when (mode) { DisplayMode.Mirror -> "Mirror"; DisplayMode.Extend -> "Extend"; DisplayMode.Window -> "Windows" }) })
                }
            }
            Caption(
                if (wsUi?.available == true) "Mirror shows a Mac display. Extend adds a separate desktop. Windows shows Mac windows you pick, side by side. Only this device changes."
                else "Mirror shows a Mac display. Extend adds a separate desktop. Only this device changes."
            )
            if (wsUi?.available == true) {
                OutlinedButton(onClick = { onDismiss(); ws.openOverview() }) { Text("Choose Windows…") }
                Caption("Tip: hold three fingers still on the picture to open your windows.")
            }
            Toggle("Surface Grid When Video Is Off", prefs.showSurfaceGrid) { on -> set { it.showSurfaceGrid = on } }
            OutlinedButton(onClick = { controller.resetViewport() }) { Text("Reset View") }
            Toggle("Picture in Picture", prefs.pictureInPictureEnabled) { on -> set { it.pictureInPictureEnabled = on } }
            Caption(
                if (onStartPictureInPicture == null) "This device doesn't offer picture-in-picture."
                else "When you leave MeowDisplay during a session, your Mac stays on screen in a small window. It's view only; to control the Mac, come back to MeowDisplay."
            )
            if (onStartPictureInPicture != null && prefs.pictureInPictureEnabled && media.ui.collectAsState().value.admitted) {
                OutlinedButton(onClick = { onDismiss(); onStartPictureInPicture() }) { Text("Start Picture in Picture") }
            }
        }
        SettingsPage.Audio -> {
            Toggle("Mac Audio", prefs.audioPreferred) { on ->
                set { it.audioPreferred = on }
                media.session.requestAudio(on)
            }
            Caption("Plays your Mac's sound on this device. Your Mac confirms it; the choice is kept for every connection.")
            val offset = AVSyncOffset.clamped(prefs.avSyncOffsetMs)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("A/V Sync", Modifier.weight(1f))
                Text(if (offset > 0) "+$offset ms" else "$offset ms")
                if (offset != 0) TextButton(onClick = { set { it.avSyncOffsetMs = 0 } }) { Text("Reset") }
            }
            Slider(
                value = offset.toFloat(), valueRange = AVSyncOffset.range.first.toFloat()..AVSyncOffset.range.last.toFloat(),
                steps = (AVSyncOffset.range.last - AVSyncOffset.range.first) / AVSyncOffset.STEP_MS - 1,
                onValueChange = { value -> set { it.avSyncOffsetMs = AVSyncOffset.clamped((value / AVSyncOffset.STEP_MS).roundToInt() * AVSyncOffset.STEP_MS) } },
                modifier = Modifier.semantics { contentDescription = "A/V Sync" },
            )
            Caption("Adjust if sound plays slightly before or after the picture. Right delays the sound; left delays the picture.")
        }
        SettingsPage.Help -> HelpPage()
        SettingsPage.Session -> {
            val mediaUi by media.ui.collectAsState()
            val view by controller.view.collectAsState()
            val mac = media.macName(mediaUi.peerID)
            Section("Status")
            LabeledRow("Connection", com.raisecaterror.meowdisplay.android.ui.sessionStatus(mediaUi, mac))
            if (view.videoSize.width > 0) {
                LabeledRow("Stream", "${view.videoSize.width.roundToInt()}×${view.videoSize.height.roundToInt()}" +
                    (when (mediaUi.source) { "mirror" -> " · Mirror"; "extend" -> " · Extend"; "window" -> " · Windows"; else -> "" }))
            }
            diagnostics?.let { d ->
                val overlay by d.performanceOverlay.collectAsState()
                Toggle("Performance Overlay", overlay) { d.setPerformanceOverlay(it) }
                Caption("Shows frame rate, bitrate, decode time and latency over the picture.")
            }
            Section("Reconnecting")
            Toggle("Auto-Reconnect", prefs.autoReconnectEnabled) { on ->
                set { it.autoReconnectEnabled = on }
                media.session.autoReconnectEnabled = on
            }
            Caption("Reconnects by itself after a dropped connection. Off, tap Connect on the home screen, or connect from the Mac.")
            Section("Session")
            Button(onClick = { media.session.disconnect(); onDismiss() }) { Text("Disconnect") }
            Caption("Ends this session. The Mac can connect again.")
        }
    }
}

@Composable
private fun ProfileTrayEditor(controller: ReceiverController) {
    val prefs by controller.store.preferences.collectAsState()
    val profile = prefs.profile(prefs.activeControlProfile)
    Section("Tray Items (${prefs.activeControlProfile.title})")
    profile.trayItems.forEachIndexed { index, item ->
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(item.item.title, Modifier.weight(1f))
            TextButton(onClick = { controller.store.updateActiveProfile { it.moveTrayItems(setOf(index), maxOf(0, index - 1)) } }, enabled = index > 0) { Text("Up") }
            Switch(
                checked = item.isVisible,
                // Settings is permanent chrome on iOS: never hidden.
                enabled = item.item != com.raisecaterror.meowdisplay.core.controls.ControlTrayItem.Settings,
                onCheckedChange = { on ->
                    controller.store.updateActiveProfile { p -> p.trayItems = p.trayItems.mapIndexed { i, c -> if (i == index) c.copy(isVisible = on) else c } }
                },
            )
        }
    }
    TextButton(onClick = { controller.store.update { it.resetProfile(prefs.activeControlProfile) } }) { Text("Reset Profile") }
}

@Composable
private fun FunctionTrayEditor(controller: ReceiverController) {
    val prefs by controller.store.preferences.collectAsState()
    val profile = prefs.functionTrayProfile(prefs.activeFunctionTrayProfile)
    profile.items.forEachIndexed { index, configuration ->
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(configuration.resolvedItem.title, Modifier.weight(1f))
            TextButton(onClick = { controller.store.updateActiveFunctionTrayProfile { it.moveItems(setOf(index), maxOf(0, index - 1)) } }, enabled = index > 0) { Text("Up") }
            Switch(checked = configuration.isVisible, onCheckedChange = { on ->
                controller.store.updateActiveFunctionTrayProfile { p -> p.items = p.items.mapIndexed { i, c -> if (i == index) c.copy(isVisible = on) else c } }
            })
        }
    }
    TextButton(onClick = { controller.store.update { it.resetFunctionTrayProfile(prefs.activeFunctionTrayProfile) } }) { Text("Reset Function Tray") }
}

@Composable
private fun CustomLayoutsSection(controller: ReceiverController) {
    val context = LocalContext.current
    val prefs by controller.store.preferences.collectAsState()
    var importText by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    Section("Custom Layouts")
    prefs.customLayouts.forEach { layout ->
        val active = prefs.activeCustomLayout?.id == layout.id
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text((if (active) "✓ " else "") + layout.name, Modifier.weight(1f).clickable { controller.store.update { it.activeCustomLayoutID = layout.id } })
            TextButton(onClick = {
                val code = CustomLayoutShareCode.encode(layout, prefs.functionTrayProfile(prefs.activeFunctionTrayProfile).allItems)
                context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("MeowDisplay layout", code))
                message = "Share code copied."
            }) { Text("Share") }
            TextButton(onClick = { controller.store.update { it.deleteCustomLayout(layout.id) } }) { Text("Delete") }
        }
    }
    if (prefs.canCreateCustomLayout) {
        OutlinedButton(onClick = { controller.store.update { it.createCustomLayout(); it.padControlLayout = PadControlLayoutMode.Custom } }) { Text("New Radial Layout") }
    }
    OutlinedTextField(importText, { importText = it }, label = { Text("Paste a share code") }, singleLine = true, modifier = Modifier.fillMaxWidth())
    Button(onClick = {
        message = when (val result = CustomLayoutShareCode.decode(importText)) {
            is ShareCodeResult.Success -> {
                val summary = result.summary
                var outcome = ""
                controller.store.update { prefs -> outcome = prefs.importCustomLayout(summary.layout).toString() }
                importText = ""
                "Imported \"${summary.layout.name}\": ${summary.landscapeControls} controls, ${summary.shortcutCount} shortcuts. $outcome"
            }
            is ShareCodeResult.Failure -> "Couldn't import: ${result.failure?.javaClass?.simpleName ?: "invalid code"}"
        }
    }, enabled = importText.isNotBlank()) { Text("Import") }
    message?.let { Caption(it) }
}

private fun inputStatus(state: InputWireState): String = when (state) {
    InputWireState.Allowed -> "Controlling: touches, keys and the controls reach your Mac."
    InputWireState.Requesting -> "Waiting for your Mac to allow input…"
    InputWireState.NotAllowed -> "Your Mac declined input for this session."
    InputWireState.RequestsDisabled -> "This Mac isn't accepting input requests."
    InputWireState.Off -> "View Only."
}

@Composable
private fun LabeledRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
    }
}

@Composable
private fun Section(title: String) {
    Text(title.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 8.dp).semantics { heading() })
}

@Composable
private fun Caption(text: String) = Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
private fun Toggle(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { onChange(!checked) }, verticalAlignment = Alignment.CenterVertically) {
        Text(title, Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun <T> Choice(title: String, options: List<T>, selected: T, label: (T) -> String, onSelect: (T) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            options.forEachIndexed { index, option ->
                SegmentedButton(selected = option == selected, onClick = { onSelect(option) }, shape = SegmentedButtonDefaults.itemShape(index, options.size)) {
                    Text(label(option), maxLines = 1)
                }
            }
        }
    }
}

@Composable
private fun LabeledSlider(title: String, value: Float, range: ClosedFloatingPointRange<Float>, onChange: (Float) -> Unit) {
    Column {
        Row { Text(title, Modifier.weight(1f)); Text("%.2f×".format(value)) }
        Slider(value = value, onValueChange = onChange, valueRange = range)
    }
}
