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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.raisecaterror.meowdisplay.android.session.SessionHost
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
import com.raisecaterror.meowdisplay.core.controls.DirectTouchStyle
import com.raisecaterror.meowdisplay.core.controls.PointerInputMode
import com.raisecaterror.meowdisplay.core.controls.ReceiverControlPreferences
import com.raisecaterror.meowdisplay.core.controls.ReceiverGestureTarget
import com.raisecaterror.meowdisplay.core.controls.ShareCodeResult
import com.raisecaterror.meowdisplay.core.controls.StagePeekDockStyle
import com.raisecaterror.meowdisplay.core.controls.StagePeekEdge
import com.raisecaterror.meowdisplay.core.controls.WindowSwitcherStyle
import com.raisecaterror.meowdisplay.core.controls.activeCustomLayout
import com.raisecaterror.meowdisplay.core.controls.appGestureCommandDisplayText
import com.raisecaterror.meowdisplay.core.controls.canCreateCustomLayout
import com.raisecaterror.meowdisplay.core.controls.createCustomLayout
import com.raisecaterror.meowdisplay.core.controls.deleteCustomLayout
import com.raisecaterror.meowdisplay.core.controls.importCustomLayout
import com.raisecaterror.meowdisplay.core.session.InputWireState
import com.raisecaterror.meowdisplay.core.session.CustomFrameRate
import com.raisecaterror.meowdisplay.core.session.ExtendShape
import com.raisecaterror.meowdisplay.core.session.MaxFPSPreference
import com.raisecaterror.meowdisplay.core.session.StreamSettings
import com.raisecaterror.meowdisplay.core.session.StreamingPriority
import com.raisecaterror.meowdisplay.core.session.StreamingProfile
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.material3.LinearProgressIndicator
import kotlin.math.roundToInt

/** The receiver categories of the iOS Settings (MobileSettingsCategory), plus the session actions. */
enum class SettingsPage(val title: String) {
    Input("Input"), Gestures("Gestures"), Controls("Controls"), TabletLayout("Tablet Layout"),
    Display("Display"), Audio("Audio"), Clipboard("Clipboard"), Session("Session"), Help("Help"),
}

/**
 * Receiver Settings over the live session: a list beside its page on a large
 * window (like the iPad split view), a list that opens pages on a compact one.
 * Every change goes through the control store, which releases held input when
 * a change makes it stale.
 */
@Composable
fun ReceiverSettings(
    controller: ReceiverController, media: SessionHost, onDismiss: () -> Unit, onStartPictureInPicture: (() -> Unit)? = null,
    diagnostics: com.raisecaterror.meowdisplay.android.media.DiagnosticsPrefs? = null,
    /** Audio → Resync: re-establish audio timing without reconnecting. Null: no live audio here. */
    onResyncAudio: (() -> Unit)? = null,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Surface(Modifier.fillMaxSize().semantics { paneTitle = "Settings" }, color = MaterialTheme.colorScheme.surface) {
            BoxWithConstraints(Modifier.safeDrawingPadding()) {
                val wide = maxWidth >= 600.dp
                var page by remember { mutableStateOf(if (wide) SettingsPage.Input else null) }
                Column(Modifier.fillMaxSize()) {
                    Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (!wide && page != null) TextButton(onClick = { page = null }, modifier = Modifier.semantics { contentDescription = "Back to Settings" }) { Text("Settings") }
                        Text(
                            if (!wide && page != null) page!!.title else "Settings",
                            style = MaterialTheme.typography.titleLarge,
                            modifier = Modifier.weight(1f).padding(horizontal = 8.dp).semantics { heading() },
                        )
                        TextButton(onClick = onDismiss) { Text("Done", fontWeight = FontWeight.SemiBold) }
                    }
                    HorizontalDivider()
                    if (media.isDemo) {
                        Text(
                            "DEMO · Sample session with ${media.macName(null)}. No Mac is connected; changes here are discarded when you leave.",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSecondaryContainer,
                            modifier = Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.secondaryContainer).padding(horizontal = 20.dp, vertical = 8.dp),
                        )
                    }
                    Row(Modifier.fillMaxSize()) {
                        if (wide || page == null) {
                            Column(Modifier.then(if (wide) Modifier.width(240.dp) else Modifier.fillMaxWidth()).fillMaxHeight().verticalScroll(rememberScrollState())) {
                                SettingsPage.entries.forEach { entry ->
                                    val selected = wide && entry == page
                                    Text(
                                        entry.title,
                                        Modifier.fillMaxWidth()
                                            .background(if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface)
                                            .clickable(role = Role.Button) { page = entry }
                                            .semantics { if (wide) this.selected = selected }
                                            .heightIn(min = 48.dp)
                                            .padding(horizontal = 20.dp, vertical = 14.dp),
                                        style = MaterialTheme.typography.bodyLarge,
                                    )
                                }
                            }
                        }
                        page?.let { current ->
                            Column(Modifier.weight(1f).fillMaxHeight().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                                SettingsPageContent(current, controller, media, onDismiss, onStartPictureInPicture, diagnostics, onResyncAudio)
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
    page: SettingsPage, controller: ReceiverController, media: SessionHost, onDismiss: () -> Unit, onStartPictureInPicture: (() -> Unit)?,
    diagnostics: com.raisecaterror.meowdisplay.android.media.DiagnosticsPrefs?,
    onResyncAudio: (() -> Unit)?,
) {
    val store = controller.store
    val prefs by store.preferences.collectAsState()
    val view by controller.view.collectAsState()
    fun set(change: (ReceiverControlPreferences) -> Unit) = store.update(change)
    when (page) {
        SettingsPage.Input -> {
            Section("Input")
            Text(inputStatus(view.inputState), style = MaterialTheme.typography.bodyMedium, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = { controller.requestInput(true) }, enabled = view.inputState != InputWireState.Allowed && view.inputState != InputWireState.RequestsDisabled) {
                    Text("Request Control")
                }
                OutlinedButton(onClick = { controller.requestInput(false) }, enabled = view.inputState == InputWireState.Allowed) { Text("Turn Off") }
            }
            Caption("Your Mac decides. Every session starts View Only; control stops the moment the Mac revokes it.")
            controller.workspace?.let { ws -> LockMacSection(ws) }
            controller.workspace?.let { ws -> StageManagerSection(ws, view.inputState) { controller.requestInput(true) } }
            Section("Keyboard")
            val zoomWhileTyping by controller.store.zoomWhileTyping.collectAsState()
            Toggle("Zoom While Typing", zoomWhileTyping) { on -> controller.store.setZoomWhileTyping(on) }
            Caption("Enlarge the area you're typing in when the keyboard is open.")
            Section("Pointer")
            Choice("Input Mode", PointerInputMode.entries, prefs.inputMode, { it.title }) { mode -> set { it.inputMode = mode } }
            if (prefs.inputMode == PointerInputMode.Trackpad) {
                LabeledSlider(
                    "Trackpad Sensitivity", prefs.trackpadSensitivity.toFloat(),
                    PointerGestureConfig.trackpadSensitivityRange.start.toFloat()..PointerGestureConfig.trackpadSensitivityRange.endInclusive.toFloat(),
                ) { value -> set { it.trackpadSensitivity = value.toDouble() } }
            }
            if (prefs.inputMode == PointerInputMode.Direct) {
                Choice("Touch Style", DirectTouchStyle.entries, prefs.touchStyle, { if (it == DirectTouchStyle.Natural) "Natural Touch" else "Classic" }) { style ->
                    set { it.touchStyle = style }
                }
                Caption(
                    if (prefs.touchStyle == DirectTouchStyle.Natural) {
                        "Tap to click, swipe to scroll, press then move to drag, touch and hold to right-click. Pinch follows the Pinch setting in Gestures."
                    } else {
                        "The finger is the pointer: tap to click, tap then hold to drag. Choose Natural Touch for macOS-style touch."
                    },
                )
            }
            if (prefs.inputMode == PointerInputMode.Direct && prefs.touchStyle == DirectTouchStyle.Classic) {
                Toggle("Smart Touch (Experimental)", prefs.smartTouchEnabled) { on -> set { it.smartTouchEnabled = on } }
                Caption("Scroll with one finger where the Mac says the area scrolls. Hold a title bar, then drag, to move its window.")
                Toggle("Smart Touch Haptics", prefs.smartTouchLongPressHapticEnabled) { on -> set { it.smartTouchLongPressHapticEnabled = on } }
            }
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
            Choice("Pinch / Zoom", ReceiverGestureTarget.entries, prefs.pinchTarget, { it.title }) { target -> set { it.pinchTarget = target } }
            // Android draws the picture on a SurfaceView, which can't rotate: rotation offers App or Disabled.
            val rotateChoices = listOf(ReceiverGestureTarget.App, ReceiverGestureTarget.Disabled)
            val rotation = if (prefs.rotateTarget == ReceiverGestureTarget.Viewport) ReceiverGestureTarget.Disabled else prefs.rotateTarget
            Choice("Rotation", rotateChoices, rotation, { it.title }) { target -> set { it.rotateTarget = target } }
            Toggle("Allow Local View Navigation", prefs.allowLocalViewNavigation) { on -> set { it.allowLocalViewNavigation = on } }
            Caption("Pinch to zoom the picture up to 8×, two fingers to pan, two-finger double tap to reset and restore. Never sent to the Mac.")
            Toggle("Prefer MeowDisplay Gestures", prefs.preferMeowDisplayGestures) { on -> set { it.preferMeowDisplayGestures = on } }
            Section("App Gesture Commands")
            Caption("Sent when Pinch or Rotate targets the App.")
            AppGestureCommandsEditor(controller)
            OutlinedButton(onClick = { set { it.resetAppGestureCommands() } }) { Text("Reset to Defaults") }
        }
        SettingsPage.Controls -> {
            Section("Control Tray")
            Toggle("Show Control Tray", prefs.trayEnabled) { on -> set { it.trayEnabled = on } }
            Toggle("Collapse Control Tray", prefs.trayCollapsed) { on -> set { it.trayCollapsed = on } }
            Toggle("Show Keyboard Button", prefs.keyboardButtonEnabled) { on -> set { it.keyboardButtonEnabled = on } }
            Choice("Control Profile", ControlProfileSlot.entries, prefs.activeControlProfile, { it.title }) { slot -> set { it.activeControlProfile = slot } }
            Choice("Landscape Tray Side", LandscapeTraySide.entries, prefs.preferredLandscapeSide, { it.title }) { side -> set { it.preferredLandscapeSide = side } }
            ProfileTrayEditor(controller)
            ChordPaletteEditor(controller)
            Section("Function Tray")
            Toggle("Show Function Tray", prefs.functionTrayEnabled) { on -> set { it.functionTrayEnabled = on } }
            Choice("Function Profile", ControlProfileSlot.entries, prefs.activeFunctionTrayProfile, { it.title }) { slot -> set { it.activeFunctionTrayProfile = slot } }
            Choice("Function Tray Position", FunctionTrayPosition.entries, prefs.functionTrayPosition, { it.title }) { position -> set { it.functionTrayPosition = position } }
            FunctionTrayEditor(controller)
            Section("Behavior")
            Toggle("Auto-hide Control Trays", prefs.autoHideEnabled) { on -> set { it.autoHideEnabled = on } }
            Toggle("Avoid Cutouts", prefs.avoidNotch) { on -> set { it.avoidNotch = on } }
        }
        SettingsPage.TabletLayout -> {
            Caption("Used whenever the window is large enough (tablets, unfolded foldables, large split-screen panes). Phones and folded foldables use the compact tray.")
            Choice("Control Layout", PadControlLayoutMode.entries, prefs.padControlLayout, { it.title }) { mode -> set { it.padControlLayout = mode } }
            Choice("Main Controls", ControlEdge.entries, prefs.padMainEdge, { it.title }) { edge -> set { it.padMainEdge = edge } }
            Choice("Function Controls", ControlEdge.entries, prefs.padFunctionEdge, { it.title }) { edge -> set { it.padFunctionEdge = edge } }
            Choice("Palette Style", PadPaletteStyle.entries, prefs.padOverlayPaletteStyle, { it.title }) { style -> set { it.padOverlayPaletteStyle = style } }
            LabeledSlider("Control Size", prefs.padControlScale.toFloat(), PadControlScale.range.start.toFloat()..PadControlScale.range.endInclusive.toFloat()) { value ->
                set { it.padControlScale = PadControlScale.clamped(value.toDouble()) }
            }
            Toggle("Show Control Hints", prefs.padShowControlHints) { on -> set { it.padShowControlHints = on } }
            Caption("Hints appear on the Strip layout only.")
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
            val stream by media.session.streamSettings.collectAsState()
            val live = mediaUi.admitted && !media.isDemo
            Toggle("Video", stream.videoEnabled ?: true, enabled = live && stream.supportsVideoControl) { on -> media.session.requestVideo(on) }
            Caption(
                if (live && !stream.supportsVideoControl) "This Mac's MeowDisplay can't turn video off. Update it to use this."
                else "Turning video off keeps the connection, keyboard, controls, and selected input mode active."
            )
            Section("Display Mode")
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
            if (live && mediaUi.source == "mirror" && stream.supportsMirrorDisplay) MirrorDisplayPicker(media, stream)
            if (live && mediaUi.source == "extend" && stream.supportsExtendShape) ExtendShapePicker(media, stream)
            Toggle("Show Surface Grid", prefs.showSurfaceGrid) { on -> set { it.showSurfaceGrid = on } }
            Caption("Shown while Video is off.")
            OutlinedButton(onClick = { controller.resetViewport() }) { Text("Reset View") }
            Toggle("Picture in Picture", prefs.pictureInPictureEnabled) { on -> set { it.pictureInPictureEnabled = on } }
            Caption(
                if (media.isDemo) "In a session with your Mac: when you leave MeowDisplay, your Mac stays on screen in a small window."
                else if (onStartPictureInPicture == null) "This device doesn't offer Picture in Picture."
                else "When you leave MeowDisplay during a session, your Mac stays on screen in a small window. It shows your Mac; control stays in MeowDisplay."
            )
            if (onStartPictureInPicture != null && prefs.pictureInPictureEnabled && media.ui.collectAsState().value.admitted) {
                OutlinedButton(onClick = { onDismiss(); onStartPictureInPicture() }) { Text("Start Picture in Picture") }
            }
            Section("Window Switcher")
            Choice("Window Switcher", WindowSwitcherStyle.entries, prefs.windowSwitcher, { if (it == WindowSwitcherStyle.StagePeek) "Stage Peek" else "Rail" }) { style ->
                set { it.windowSwitcher = style }
            }
            if (prefs.windowSwitcher == WindowSwitcherStyle.StagePeek) {
                Choice("Stage Peek Edge", StagePeekEdge.entries, prefs.stagePeekEdge, { if (it == StagePeekEdge.Left) "Left" else "Right" }) { edge ->
                    set { it.stagePeekEdge = edge }
                }
                Choice("Dock", StagePeekDockStyle.entries, prefs.stagePeekDock, { it.title }) { dock ->
                    set { it.stagePeekDock = dock }
                }
            }
            controller.workspace?.let { ws ->
                var spatial by remember { mutableStateOf(ws.spatialOverview) }
                Choice("Expanded Layout", listOf(false, true), spatial, { if (it) "Spatial Overview" else "Gallery" }) { on -> spatial = on; ws.spatialOverview = on }
                var bring by remember { mutableStateOf(ws.bringStripWindowsForward) }
                Toggle("Bring Stage Manager Windows Forward", bring) { on -> bring = on; ws.bringStripWindowsForward = on }
                Caption("macOS pauses windows in Stage Manager's side strip. With this on, choosing one also brings it forward on the Mac (its stage changes) so it shows live. Needs control. Off: tap Show on Mac in its pane.")
            }
            Caption(
                (if (prefs.windowSwitcher == WindowSwitcherStyle.StagePeek) "Touch and hold the screen edge to see your windows. Tap one to switch."
                else "A compact strip of windows along one edge.") + " Used in Window view." +
                    (if (prefs.windowSwitcher != WindowSwitcherStyle.StagePeek) ""
                    else if (prefs.stagePeekDock == StagePeekDockStyle.Compact) " Compact keeps the windows between the search bar and the buttons below."
                    else " Normal uses the whole edge.")
            )
            StreamingSection(media, stream, live)
        }
        SettingsPage.Audio -> {
            Toggle("Audio", prefs.audioPreferred) { on ->
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
                modifier = Modifier.semantics { contentDescription = "A/V Sync"; stateDescription = if (offset > 0) "Plus $offset milliseconds" else "$offset milliseconds" },
            )
            Caption("Adjust if sound plays slightly before or after the picture. Right delays the sound; left delays the picture.")
            if (onResyncAudio != null) {
                OutlinedButton(onClick = onResyncAudio, enabled = media.ui.collectAsState().value.admitted && prefs.audioPreferred) { Text("Resync") }
                Caption("If audio drifts or stutters, Resync re-establishes timing without reconnecting. It doesn't change your A/V Sync adjustment above.")
            }
        }
        SettingsPage.Help -> HelpPage()
        SettingsPage.Clipboard -> com.raisecaterror.meowdisplay.android.receiver.workspace.ClipboardSettingsPage(controller.workspace?.clipboard, media.isDemo)
        SettingsPage.Session -> {
            val mediaUi by media.ui.collectAsState()
            val view by controller.view.collectAsState()
            val mac = media.macName(mediaUi.peerID)
            (media as? com.raisecaterror.meowdisplay.android.session.MediaController)?.let { real ->
                @Suppress("UNUSED_VARIABLE") val changes by real.connectionPolicyChanges.collectAsState()
                Section("Connection Requests")
                Toggle("Automatically Allow Connections", real.automaticallyAllowConnections) { on -> real.automaticallyAllowConnections = on }
                Caption("On, a paired Mac can start a session on this device without asking. Off, you approve each one. Choose per Mac from its ••• menu on Home.")
            }
            Section("Status")
            LabeledRow("Connection", if (media.isDemo) "Demo: a sample Mac on this device. Nothing is connected." else com.raisecaterror.meowdisplay.android.ui.sessionStatus(mediaUi, mac))
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
            Button(onClick = { media.session.disconnect(); onDismiss() }) { Text(if (media.isDemo) "Exit Demo" else "Disconnect") }
            Caption(if (media.isDemo) "Ends the demo and returns to Home." else "Ends this session. The Mac can connect again.")
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
            TextButton(
                onClick = { controller.store.updateActiveProfile { it.moveTrayItems(setOf(index), maxOf(0, index - 1)) } }, enabled = index > 0,
                modifier = Modifier.semantics { contentDescription = "Move ${item.item.title} up" },
            ) { Text("Up") }
            Switch(
                modifier = Modifier.semantics { contentDescription = "Show ${item.item.title}" },
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
private fun CustomLayoutsSection(controller: ReceiverController) {
    val context = LocalContext.current
    val prefs by controller.store.preferences.collectAsState()
    var importText by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var editingLayoutID by remember { mutableStateOf<String?>(null) }
    editingLayoutID?.let { id -> CustomLayoutEditor(controller, id, onDismiss = { editingLayoutID = null }) }
    Section("Custom Layouts")
    prefs.customLayouts.forEach { layout ->
        val active = prefs.activeCustomLayout?.id == layout.id
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                (if (active) "✓ " else "") + layout.name,
                Modifier.weight(1f).heightIn(min = 48.dp)
                    .clickable(onClickLabel = "Use this layout", role = Role.Button) { controller.store.update { it.activeCustomLayoutID = layout.id } }
                    .semantics { contentDescription = layout.name; stateDescription = if (active) "Active layout" else "Not active" },
            )
            TextButton(onClick = { editingLayoutID = layout.id }, modifier = Modifier.semantics { contentDescription = "Edit ${layout.name}" }) { Text("Edit") }
            TextButton(onClick = {
                val code = CustomLayoutShareCode.encode(layout, prefs.functionTrayProfile(prefs.activeFunctionTrayProfile).allItems)
                context.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("MeowDisplay layout", code))
                message = "Share code copied."
            }, modifier = Modifier.semantics { contentDescription = "Share ${layout.name}" }) { Text("Share") }
            TextButton(
                onClick = { controller.store.update { it.deleteCustomLayout(layout.id) } },
                modifier = Modifier.semantics { contentDescription = "Delete ${layout.name}" },
            ) { Text("Delete") }
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
    InputWireState.Requesting -> "Waiting for your Mac to allow control…"
    InputWireState.NotAllowed -> "Your Mac declined control for this session."
    InputWireState.RequestsDisabled -> "This Mac isn't accepting control requests."
    InputWireState.Off -> "View Only."
}

@Composable
private fun LabeledRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp).semantics(mergeDescendants = true) {}, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
    }
}

@Composable
internal fun Section(title: String) {
    Text(title.uppercase(), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 8.dp).semantics { heading(); contentDescription = title })
}

@Composable
internal fun Caption(text: String) = Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
internal fun Toggle(title: String, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    // One switch row for TalkBack and Voice Access: the whole row toggles, the Switch itself is not a second stop.
    Row(
        Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(value = checked, enabled = enabled, role = Role.Switch, onValueChange = onChange),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, Modifier.weight(1f), color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f))
        Switch(checked = checked, onCheckedChange = null, enabled = enabled)
    }
}

/** A choice among more options than fit a segmented row: chips that wrap. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
internal fun <T> ChipChoice(title: String, options: List<T>, selected: T?, label: (T) -> String, enabled: Boolean = true, onSelect: (T) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            options.forEach { option ->
                FilterChip(selected = option == selected, onClick = { onSelect(option) }, enabled = enabled, label = { Text(label(option), maxLines = 1) })
            }
        }
    }
}

@Composable
private fun Updating(text: String) {
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Caption(text)
        LinearProgressIndicator(Modifier.fillMaxWidth())
    }
}

/** Remote control for the Mac's own Mirror source (Auto, or one display it listed). The Mac confirms. */
@Composable
private fun MirrorDisplayPicker(media: SessionHost, stream: StreamSettings) {
    val state = stream.mirrorDisplays
    Section("Mirror Display")
    if (state == null) {
        Caption("Waiting for Mac")
        return
    }
    val manual = state.selectedUUID != null
    Choice("Mirror Display", listOf(false, true), manual, { if (it) "Manual" else "Auto" }) { wantManual ->
        if (!wantManual) media.session.requestMirrorDisplay(null)
        else (state.displays.firstOrNull { it.isMain } ?: state.displays.firstOrNull())?.let { media.session.requestMirrorDisplay(it.uuid) }
    }
    if (!manual) {
        Caption("Auto mirrors your Mac's main display.")
    } else if (state.displays.isEmpty()) {
        Caption("No displays reported.")
    } else {
        state.displays.forEach { display ->
            val selected = display.uuid == state.selectedUUID
            Row(
                Modifier.fillMaxWidth().heightIn(min = 48.dp)
                    .selectable(selected = selected, role = Role.RadioButton) { media.session.requestMirrorDisplay(display.uuid) }.padding(vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(Modifier.weight(1f)) {
                    Text(if (display.isMain) "${display.name} (Main)" else display.name)
                    if (display.pixelWidth != null && display.pixelHeight != null) Caption("${display.pixelWidth}×${display.pixelHeight}")
                }
                if (selected) Text("✓", color = MaterialTheme.colorScheme.primary, fontWeight = FontWeight.Bold, modifier = Modifier.clearAndSetSemantics {})
            }
        }
        if (state.selectionUnavailable) Text("Selected display unavailable", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
    }
}

/** The Extend display's shape (PROTOCOL.md 6.7). Requests only; the shown value is the Mac's, or this device's request in flight. */
@Composable
private fun ExtendShapePicker(media: SessionHost, stream: StreamSettings) {
    Section("Extend Shape")
    val current = stream.shownExtendShape
    if (current == null) {
        Caption("Waiting for Mac")
        return
    }
    val busy = stream.pendingExtendShape != null
    ChipChoice("Extend Shape", ExtendShape.entries, current.shape, { it.title }, enabled = !busy) { shape ->
        media.session.requestExtendShape(current.copy(shape = shape))
    }
    if (current.shape == ExtendShape.Automatic) {
        Toggle("Use Full Display", current.useFullDisplay, enabled = !busy) { on -> media.session.requestExtendShape(current.copy(useFullDisplay = on)) }
        Caption("Automatic uses a standard 16:10 desktop. Use Full Display matches this screen's shape instead.")
    }
    if (busy) Updating("Updating Extend shape…")
    stream.fpsLimitationText?.let { Caption(it) }
}

/** Streaming Profile, Priority and Maximum FPS: the Mac's own settings, asked for from here. */
@Composable
private fun StreamingSection(media: SessionHost, stream: StreamSettings, live: Boolean) {
    Section("Streaming")
    if (!live) {
        Caption("Available while connected to a Mac.")
        return
    }
    if (!stream.supportsProfileRequest) {
        Caption("Update MeowDisplay on your Mac to change streaming settings from here.")
    } else {
        val profile = stream.profile
        Choice<StreamingProfile>("Streaming Profile", StreamingProfile.entries, profile, { it.title }) { picked -> media.session.requestStreamingProfile(picked) }
        Caption(profile?.explanation ?: "Waiting for Mac")
        if (profile == StreamingProfile.Custom) {
            Choice("Frame Rate", CustomFrameRate.entries, stream.customFrameRate, { it.title }) { rate ->
                media.session.requestStreamingProfile(StreamingProfile.Custom, rate)
            }
        }
        Caption("Applies to every device this Mac streams to.")
    }
    if (stream.supportsPriority) {
        val priority = stream.priority
        Choice<StreamingPriority>("Streaming Priority", StreamingPriority.entries, priority, { it.title }) { picked -> media.session.requestStreamingPriority(picked) }
        Caption(priority?.explanation ?: "Waiting for Mac")
    }
    if (stream.supportsMaxFPS) {
        val current = stream.shownMaxFPS
        if (current == null) {
            LabeledRow("Maximum FPS", "Waiting for Mac")
        } else {
            val busy = stream.pendingMaxFPS != null
            Toggle("Enforce Maximum FPS", current.enabled, enabled = !busy) { on -> media.session.requestMaxFPS(current.copy(enabled = on)) }
            if (current.enabled) {
                val tiers = stream.maxFPSTiers
                ChipChoice("Maximum FPS", tiers, StreamSettings.tierFor(current.maxFPS, tiers), { "$it" }, enabled = !busy) { fps ->
                    media.session.requestMaxFPS(MaxFPSPreference(true, fps))
                }
            }
            if (busy) Updating("Updating Maximum FPS…")
            Caption("Caps how fast this Mac streams to this device, on top of its normal profile and display limits.")
        }
    }
}

@Composable
internal fun <T> Choice(title: String, options: List<T>, selected: T?, label: (T) -> String, onSelect: (T) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            options.forEachIndexed { index, option ->
                SegmentedButton(selected = option == selected, onClick = { onSelect(option) }, shape = SegmentedButtonDefaults.itemShape(index, options.size)) {
                    // Two lines, so a large font size wraps the label instead of cutting it off.
                    Text(label(option), maxLines = 2)
                }
            }
        }
    }
}

@Composable
internal fun LabeledSlider(title: String, value: Float, range: ClosedFloatingPointRange<Float>, onChange: (Float) -> Unit) {
    Column {
        Row { Text(title, Modifier.weight(1f)); Text("%.2f×".format(value)) }
        Slider(
            value = value, onValueChange = onChange, valueRange = range,
            modifier = Modifier.semantics { contentDescription = title; stateDescription = "%.2f times".format(value) },
        )
    }
}

/**
 * Stage Manager on the Mac (Window mode): its side strip pauses windows, so their panes stand still.
 * Turn it off (confirmed; MeowDisplay turns it back on when Window mode ends) or on. Needs control.
 */
@Composable
private fun StageManagerSection(
    ws: com.raisecaterror.meowdisplay.android.receiver.workspace.WorkspaceController,
    inputState: InputWireState,
    onRequestControl: () -> Unit,
) {
    val s by ws.ui.collectAsState()
    val on = s.remote?.stageManagerIsOn ?: return
    var confirmingOff by remember { mutableStateOf(false) }
    Section("Stage Manager on the Mac")
    Text(if (on) "On" else "Off", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.semantics { contentDescription = "Stage Manager on the Mac: ${if (on) "on" else "off"}" })
    val control = s.remote?.stageManagerControl
    if (control == "setup") {
        Caption("To switch it from here, open MeowDisplay's Settings on the Mac ▸ System ▸ Stage Manager and choose Set Up Automatically.")
    } else {
        // Without control the button asks for it here (this screen stays while the Mac decides);
        // the switch is tapped again once control is allowed.
        val canControl = ws.canControlMac
        if (canControl) {
            OutlinedButton(onClick = { if (on) confirmingOff = true else ws.turnOnStageManager() }) {
                Text(if (on) "Turn Off Stage Manager" else "Turn On Stage Manager")
            }
        } else {
            OutlinedButton(
                onClick = onRequestControl,
                enabled = inputState != InputWireState.Requesting && inputState != InputWireState.RequestsDisabled,
                modifier = Modifier.semantics { contentDescription = "Request Control. Turning Stage Manager ${if (on) "off" else "on"} needs control of the Mac." },
            ) { Text(if (inputState == InputWireState.Requesting) "Awaiting Approval" else "Request Control") }
        }
        val action = if (on) "Turning Stage Manager off" else "Turning Stage Manager on"
        when {
            control == "failed" -> Caption("The Mac didn't change it. Try again, or switch it in Control Center on the Mac.")
            canControl -> {}
            inputState == InputWireState.Requesting -> Caption("Awaiting approval on the Mac… Then tap Turn ${if (on) "Off" else "On"} Stage Manager.")
            inputState == InputWireState.NotAllowed -> Caption("The Mac didn't allow control. $action needs it; Request Control to ask again.")
            inputState == InputWireState.RequestsDisabled -> Caption("This Mac doesn't take control requests from this device, so it can't be switched from here.")
            else -> Caption("$action needs control of the Mac.")
        }
    }
    Caption("Stage Manager's side strip pauses the windows in it, so their panes stand still. With it off they show live. If MeowDisplay turned it off, it turns it back on when Window mode ends.")
    if (confirmingOff) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirmingOff = false },
            title = { Text("Turn off Stage Manager on the Mac?") },
            text = { Text("Windows in its side strip then show live here. MeowDisplay turns Stage Manager back on when Window mode ends.") },
            confirmButton = { TextButton(onClick = { confirmingOff = false; ws.turnOffStageManager() }) { Text("Turn Off") } },
            dismissButton = { TextButton(onClick = { confirmingOff = false }) { Text("Cancel") } },
        )
    }
}

/** Lock This Mac: macOS's own lock screen on the Mac (needs control; shows what the Mac reports). */
@Composable
private fun LockMacSection(ws: com.raisecaterror.meowdisplay.android.receiver.workspace.WorkspaceController) {
    val s by ws.ui.collectAsState()
    if (!s.canLockMac) return
    var confirming by remember { mutableStateOf(false) }
    Section("This Mac")
    val locking = s.lockMac?.locking == true
    OutlinedButton(onClick = { ws.clearLockMac(); confirming = true }, enabled = !locking) { Text(if (locking) "Locking…" else "Lock Mac") }
    s.lockMac?.result?.let { Text(it.message, style = MaterialTheme.typography.bodyMedium) }
    Caption("Shows the Mac's lock screen. To use it again, type the Mac's login password. Needs control of the Mac.")
    if (confirming) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { confirming = false },
            title = { Text("Lock the Mac?") },
            text = { Text("Anyone at the Mac will need its login password.") },
            confirmButton = { TextButton(onClick = { confirming = false; ws.lockMac() }) { Text("Lock Mac") } },
            dismissButton = { TextButton(onClick = { confirming = false }) { Text("Cancel") } },
        )
    }
}
