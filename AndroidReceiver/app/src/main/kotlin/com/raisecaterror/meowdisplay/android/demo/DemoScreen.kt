package com.raisecaterror.meowdisplay.android.demo

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.raisecaterror.meowdisplay.android.receiver.ReceiverOverlayHost
import com.raisecaterror.meowdisplay.android.receiver.ReceiverScreen
import com.raisecaterror.meowdisplay.core.demo.DemoFeedback
import com.raisecaterror.meowdisplay.core.demo.DemoMac
import kotlinx.coroutines.delay

/**
 * Explore Demo: the real receiver surface, controls, Stage Peek and Window
 * mode, driven by the in-process sample Mac. Always labelled DEMO; nothing
 * here connects to anything.
 */
@Composable
fun DemoScreen(runtime: DemoRuntime, onExit: () -> Unit, onOpenSettings: () -> Unit) {
    val scene by runtime.host.mac.scene.collectAsState()
    val feedback by runtime.host.mac.feedback.collectAsState()
    var showGuide by rememberSaveable { mutableStateOf(true) }
    var chip by remember { mutableStateOf<DemoFeedback?>(null) }
    LaunchedEffect(feedback?.generation) {
        val event = feedback ?: return@LaunchedEffect
        chip = event.feedback
        delay(2_600)
        chip = null
    }
    Box(Modifier.fillMaxSize()) {
        ReceiverScreen(
            runtime.controller, pipeline = null,
            overlay = { window, actions, generation -> ReceiverOverlayHost(runtime.controller, window, actions, generation) },
            onOpenSettings = onOpenSettings,
            onBack = onExit,
            workspace = runtime.workspace, macName = DemoMac.MAC_NAME,
            onMode = { runtime.host.session.requestDisplayMode(it) },
            immersive = true,
            picture = { modifier ->
                Canvas(modifier.semantics { contentDescription = "Sample Mac desktop (demo)" }) {
                    drawIntoCanvas { DemoPainter.draw(it.nativeCanvas, scene, size.width, size.height) }
                }
            },
            pictureSize = runtime.host.pictureSize,
        )
        val workspaceUi by runtime.workspace.ui.collectAsState()
        val switcherOpen = workspaceUi.overviewOpen || workspaceUi.stagePeekOpen || workspaceUi.railExpanded
        if (scene.mode == com.raisecaterror.meowdisplay.core.session.DisplayMode.Window && scene.tiles.isEmpty() && !switcherOpen) {
            Column(
                Modifier.align(Alignment.Center).padding(24.dp).widthIn(max = 380.dp)
                    .background(Color(0xE6202428), RoundedCornerShape(16.dp)).padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("Windows", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp, modifier = Modifier.semantics { heading() })
                Text(
                    "Show the sample Mac's windows side by side. Touch and hold the left edge to flip through them with Stage Peek, or choose them here.",
                    color = Color(0xFFD1D5DB), fontSize = 14.sp,
                )
                androidx.compose.material3.Button(onClick = { runtime.workspace.openOverview() }) { Text("Choose Windows…") }
            }
        }
        // The badge takes whichever top spot is free: trays run down the sides in landscape and along the
        // bottom in portrait; the keyboard's key row, Stage Peek's stack and the window labels of side-by-side
        // tiles take the top centre; the window chooser has its title on the left.
        val window = LocalWindowInfo.current.containerSize
        val density = LocalDensity.current.density
        val keyboardUp = WindowInsets.ime.getBottom(LocalDensity.current) > 0
        val badgeCentred = when {
            keyboardUp || workspaceUi.stagePeekOpen || workspaceUi.railExpanded -> false
            workspaceUi.overviewOpen -> true
            scene.mode == com.raisecaterror.meowdisplay.core.session.DisplayMode.Window -> false
            else -> window.width > window.height
        }
        DemoBadgeBar(
            onGuide = { showGuide = true }, onExit = onExit,
            modifier = Modifier.align(if (badgeCentred) Alignment.TopCenter else Alignment.TopStart)
                .windowInsetsPadding(WindowInsets.displayCutout).padding(10.dp)
                // Stage Peek and Remote Finder keep clear of it.
                .onGloballyPositioned { c ->
                    val b = c.boundsInRoot(); val d = density.toDouble()
                    runtime.workspace.hostChrome.value = listOf(com.raisecaterror.meowdisplay.core.controls.CGRect(b.left / d, b.top / d, b.width / d, b.height / d))
                },
        )
        chip?.let { current ->
            val (label, text) = when (current) {
                is DemoFeedback.Local -> null to current.text
                is DemoFeedback.OnMac -> "On a Mac" to current.text
            }
            Row(
                Modifier.align(Alignment.TopCenter).padding(top = 64.dp).widthIn(max = 420.dp)
                    .background(Color(0xE6202428), RoundedCornerShape(16.dp)).padding(horizontal = 14.dp, vertical = 8.dp)
                    .semantics { liveRegion = LiveRegionMode.Polite },
                horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically,
            ) {
                label?.let { Text(it.uppercase(), color = Color(0xFF93C5FD), fontSize = 11.sp, fontWeight = FontWeight.Bold) }
                Text(text, color = Color.White, fontSize = 13.sp)
            }
        }
    }
    if (showGuide) DemoGuide(onDismiss = { showGuide = false }, onExit = onExit)
}

/** Always on screen and clear of the trays: DEMO (opens the guide) and Exit. The demo turns off the top-centre prompts. */
@Composable
private fun DemoBadgeBar(onGuide: () -> Unit, onExit: () -> Unit, modifier: Modifier) {
    Row(
        modifier.background(Color(0xD9202428), RoundedCornerShape(18.dp)).padding(start = 6.dp, end = 2.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Text(
            "DEMO", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold,
            modifier = Modifier.minimumInteractiveComponentSize().clip(RoundedCornerShape(6.dp)).background(Color(0xFFEA580C))
                .clickable(onClickLabel = "Open the demo guide", role = Role.Button, onClick = onGuide)
                .padding(horizontal = 8.dp, vertical = 4.dp)
                .semantics { contentDescription = "Demo: a sample Mac, nothing is connected" },
        )
        TextButton(onClick = onExit) { Text("Exit", color = Color.White, fontWeight = FontWeight.SemiBold) }
    }
}

@Composable
private fun DemoGuide(onDismiss: () -> Unit, onExit: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Try the Demo", modifier = Modifier.semantics { heading() }) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("This is a sample Mac drawn on this device. No Mac is connected, nothing goes over the network, and what you change here is discarded when you leave. Tap DEMO to see this guide again.")
                GuideItem("Natural Touch", "Tap to click. Swipe to scroll. Press, then move, to drag a window by its title bar. Touch and hold to right-click. Double-tap a file to preview it.")
                GuideItem("Typing", "Tap Notes, then the keyboard button in the Control Tray. What you type appears in Notes.")
                GuideItem("Control Tray", "⌘ ⌥ ⌃ ⇧ hold or latch a modifier for the next key, like ⌘Z to undo in Notes. The gear opens Settings.")
                GuideItem("Function Tray", "Shortcut buttons for common Mac actions. With a real Mac they act on the front app.")
                GuideItem("Mirror, Extend, Windows", "Settings → Display switches between the Mac's own screen, a second desktop, and windows you pick, side by side.")
                GuideItem("Stage Peek", "In Windows, touch and hold the screen's left edge to see the sample windows. Tap one to show it.")
                GuideItem("With your Mac", "Install MeowDisplay on your Mac (macOS 14 or later), join the same Wi-Fi, then pair from Home. Exit the demo any time.")
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Start") } },
        dismissButton = { TextButton(onClick = onExit) { Text("Exit Demo") } },
    )
}

@Composable
private fun GuideItem(title: String, body: String) {
    Column {
        Text(title, style = MaterialTheme.typography.titleSmall, modifier = Modifier.semantics { heading() })
        Text(body, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
