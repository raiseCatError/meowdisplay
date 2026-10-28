package com.raisecaterror.meowdisplay.android.receiver

import androidx.core.view.WindowInsetsControllerCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowCompat
import com.raisecaterror.meowdisplay.core.controls.RemoteViewportTransform
import com.raisecaterror.meowdisplay.core.workspace.WAxis
import com.raisecaterror.meowdisplay.core.workspace.WRect
import com.raisecaterror.meowdisplay.core.workspace.WHinge
import com.raisecaterror.meowdisplay.core.workspace.WSize
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import com.raisecaterror.meowdisplay.android.receiver.workspace.StagePeekOverlay
import com.raisecaterror.meowdisplay.android.receiver.workspace.WindowModePrompt
import com.raisecaterror.meowdisplay.android.receiver.workspace.WindowOverview
import com.raisecaterror.meowdisplay.android.receiver.workspace.WindowRail
import com.raisecaterror.meowdisplay.android.receiver.workspace.WorkspaceChrome
import com.raisecaterror.meowdisplay.android.receiver.workspace.WorkspaceController
import android.app.Activity
import android.os.Build
import android.view.HapticFeedbackConstants
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.accessibility.AccessibilityManager
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.ime
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.window.layout.FoldingFeature
import androidx.window.layout.WindowInfoTracker
import com.raisecaterror.meowdisplay.android.media.MediaPipeline
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.CGSize
import com.raisecaterror.meowdisplay.core.controls.ControlReservedRegion
import com.raisecaterror.meowdisplay.core.controls.ControlSafeInsets
import com.raisecaterror.meowdisplay.core.controls.LandscapeTraySide
import com.raisecaterror.meowdisplay.core.controls.ReceiverInputPrompt
import com.raisecaterror.meowdisplay.core.controls.DirectTouchStyle
import com.raisecaterror.meowdisplay.core.controls.PointerInputMode
import com.raisecaterror.meowdisplay.core.controls.SmartTouchFeedback
import com.raisecaterror.meowdisplay.core.controls.StagePeekEdge
import com.raisecaterror.meowdisplay.core.controls.WindowSwitcherStyle
import kotlin.math.roundToInt

/** Everything the screen learned about the window this frame, in dp. */
data class ReceiverWindow(
    val size: CGSize,
    val safeInsets: ControlSafeInsets,
    val notchSide: LandscapeTraySide?,
    val reservedRegions: List<ControlReservedRegion>,
    val keyboardVisibleRect: CGRect?,
    val expanded: Boolean,
) {
    companion object {
        /**
         * The iPad-style presentation needs a tablet-class window: both sides at
         * least 600 dp. An unfolded foldable or a large split-screen pane
         * qualifies; a phone, a folded foldable or a narrow pane gets the
         * iPhone-style tray. Decided from the usable window, never the device.
         */
        fun isExpanded(widthDp: Double, heightDp: Double): Boolean = minOf(widthDp, heightDp) >= EXPANDED_MIN_DP

        const val EXPANDED_MIN_DP = 600.0
    }
}

/**
 * The live receiver: the Mac's picture placed by the viewport transform
 * (letterboxed, zoomed, panned), the streamed cursor, the video-off surface,
 * the input layer and the controls (iOS ReceiverScreen's layer stack).
 */
@Composable
fun ReceiverScreen(
    controller: ReceiverController,
    pipeline: MediaPipeline,
    overlay: @Composable (ReceiverWindow, OverlayActions, Int) -> Unit,
    onOpenSettings: () -> Unit,
    onBack: () -> Unit = {},
    workspace: WorkspaceController? = null,
    macName: String = "your Mac",
    onMode: (DisplayMode) -> Unit = {},
    /** The picture fills the screen; false while Home is shown over it. */
    immersive: Boolean = true,
    /** In picture-in-picture only the picture shows; the workspace keeps its full-screen size. */
    pictureInPicture: Boolean = false,
    /** Settings > Session > Performance Overlay. */
    showPerformance: Boolean = false,
    rttMs: () -> Double? = { null },
    /** `Remote (Tailscale)` and the like when the session came over Remote Access; null for a local one. */
    routeLabel: String? = null,
) {
    val state by controller.view.collectAsState()
    val prefs by controller.store.preferences.collectAsState()
    val transient by controller.store.transient.collectAsState()
    val decoded by pipeline.videoSize.collectAsState()
    val density = LocalDensity.current
    val context = LocalContext.current
    val hostView = LocalView.current
    var canvas by remember { mutableStateOf<CGRect?>(null) }
    var occupied by remember { mutableStateOf(emptyList<CGRect>()) }
    // The one-time Natural Touch hint's frame: like the controls, taps on it never reach the Mac.
    var hintFrame by remember { mutableStateOf<CGRect?>(null) }
    // Stage Peek's edge strip and the "Switch to Window view?" offer are controls too: the rest of the screen avoids them.
    var stripFrame by remember { mutableStateOf<CGRect?>(null) }
    var promptFrame by remember { mutableStateOf<CGRect?>(null) }
    val folds = rememberFoldRegions()

    LaunchedEffect(prefs, transient.moveViewActive) { controller.refreshConfig() }
    // Back never ends a live session: it goes to Home, with the session and picture kept, so
    // Return to Display is instant. The keyboard, Settings and the window overview take Back first.
    BackHandler { onBack() }
    // Like iOS, the live picture hides the status and navigation bars (C4 O-03); an edge
    // swipe shows them for a moment. Home brings them back.
    LaunchedEffect(immersive) {
        val window = (context as? Activity)?.window ?: return@LaunchedEffect
        val bars = WindowCompat.getInsetsController(window, window.decorView)
        bars.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        if (immersive) bars.hide(WindowInsetsCompat.Type.systemBars()) else bars.show(WindowInsetsCompat.Type.systemBars())
    }
    DisposableEffect(Unit) {
        onDispose {
            (context as? Activity)?.window?.let { WindowCompat.getInsetsController(it, it.decorView).show(WindowInsetsCompat.Type.systemBars()) }
        }
    }
    LaunchedEffect(Unit) {
        controller.hapticEvents.collect { haptic -> hapticConstant(haptic)?.let(hostView::performHapticFeedback) }
    }
    DisposableEffect(Unit) {
        val accessibility = context.getSystemService(AccessibilityManager::class.java)
        val listener = AccessibilityManager.TouchExplorationStateChangeListener { controller.screenReaderRunning = it }
        controller.screenReaderRunning = accessibility.isTouchExplorationEnabled
        accessibility.addTouchExplorationStateChangeListener(listener)
        onDispose { accessibility.removeTouchExplorationStateChangeListener(listener) }
    }

    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
        val widthDp = maxWidth.value.toDouble()
        val heightDp = maxHeight.value.toDouble()
        val layoutDirection = LocalLayoutDirection.current
        val safe = WindowInsets.safeDrawing
        val cutout = WindowInsets.displayCutout
        val ime = WindowInsets.ime
        fun dp(px: Int) = px / density.density.toDouble()
        val insets = ControlSafeInsets(
            top = dp(safe.getTop(density)),
            leading = dp(safe.getLeft(density, layoutDirection)),
            bottom = dp(safe.getBottom(density) - ime.getBottom(density)).coerceAtLeast(0.0),
            trailing = dp(safe.getRight(density, layoutDirection)),
        )
        val cutoutLeft = cutout.getLeft(density, LayoutDirection.Ltr)
        val cutoutRight = cutout.getRight(density, LayoutDirection.Ltr)
        val notchSide = when {
            widthDp <= heightDp -> null
            cutoutLeft > 0 -> LandscapeTraySide.Leading
            cutoutRight > 0 -> LandscapeTraySide.Trailing
            else -> null
        }
        val imeHeight = dp(ime.getBottom(density))
        // The typing strip sits on the keyboard's top edge, so the picture treats it as part of the keyboard.
        val keyboardShown = state.keyboardRequested && imeHeight > 0
        val keyboardRect = if (keyboardShown) CGRect(0.0, 0.0, widthDp, (heightDp - imeHeight - TypingStripHeight.value).coerceAtLeast(0.0)) else null
        val window = ReceiverWindow(
            size = CGSize(widthDp, heightDp),
            safeInsets = insets,
            notchSide = notchSide,
            reservedRegions = folds.map { ControlReservedRegion(ControlReservedRegion.Kind.Division, it) },
            keyboardVisibleRect = keyboardRect,
            expanded = ReceiverWindow.isExpanded(widthDp, heightDp),
        )
        controller.store.isExpanded = window.expanded
        // The Mac follows its text caret only while the keyboard is really up.
        LaunchedEffect(keyboardShown) { controller.keyboardVisibilityChanged(keyboardShown) }
        val windowRect = CGRect(0.0, 0.0, widthDp, heightDp)
        LaunchedEffect(window, canvas, occupied, hintFrame, stripFrame, promptFrame, decoded, state.videoEnabled, prefs.inputMode) {
            controller.layout(windowRect, canvas ?: windowRect, keyboardRect, insets, occupied + listOfNotNull(hintFrame, stripFrame, promptFrame), folds)
        }

        val transform = state.transform
        val frame = transform.displayedRect
        // Following the Mac's text caret eases the picture to its new place (iOS animates the same
        // change over 0.25 s); a pinch, a pan or the keyboard sliding in moves it instantly.
        val easing = if (state.transformAnimated && !frame.isEmpty) tween<Float>(220) else snap()
        val shownX by animateFloatAsState(frame.minX.toFloat(), easing, label = "pictureX")
        val shownY by animateFloatAsState(frame.minY.toFloat(), easing, label = "pictureY")
        val shownWidth by animateFloatAsState(frame.width.toFloat(), easing, label = "pictureWidth")
        val shownHeight by animateFloatAsState(frame.height.toFloat(), easing, label = "pictureHeight")
        val shownFrame = if (frame.isEmpty) frame else CGRect(shownX.toDouble(), shownY.toDouble(), shownWidth.toDouble(), shownHeight.toDouble())
        val shown = if (shownFrame == frame) transform else RemoteViewportTransform(transform.remoteCrop, shownFrame, transform.rotationRadians)
        // The picture. The SurfaceView is always composed: the decoder needs its surface to produce the
        // first frame that sizes it, and recreating it mid-session is avoided. Until a size is known it
        // fills the window. It can't rotate, so it is sized and placed to the zoomed frame (viewport
        // rotation is off on Android; see the parity notes).
        val videoModifier = if (!frame.isEmpty) {
            Modifier
                .offset { IntOffset((shownFrame.minX * density.density).roundToInt(), (shownFrame.minY * density.density).roundToInt()) }
                .size(shownFrame.width.dp, shownFrame.height.dp)
        } else {
            Modifier.fillMaxSize()
        }
        AndroidView(factory = { ctx -> videoSurface(ctx, pipeline) }, modifier = videoModifier)
        // Video off: the last frame is discarded from view (PROTOCOL.md 6.2) and the mapped surface shown.
        if (!state.videoEnabled) {
            Box(Modifier.fillMaxSize().background(Color.Black))
            if (!frame.isEmpty) VideoOffSurface(frame, prefs.showSurfaceGrid)
        }

        // The streamed cursor, at the Mac's position under the current zoom.
        val cursor = state.cursor
        val sprite = cursor.sprite
        // In Window mode the workspace pointer is the local one; the Mac's cursor isn't drawn twice.
        val windowMode = workspace?.ui?.collectAsState()?.value?.windowMode == true
        if (cursor.visible && sprite != null && transform.isValid && !windowMode) {
            val image = remember(sprite) { sprite.bitmap.asImageBitmap() }
            Canvas(Modifier.fillMaxSize()) {
                val crop = shown.remoteCrop
                val w = sprite.normalizedWidth * shownFrame.width / crop.width
                val h = sprite.normalizedHeight * shownFrame.height / crop.height
                val at = shown.viewPoint(com.raisecaterror.meowdisplay.core.controls.CGPoint(cursor.x, cursor.y))
                val px = density.density
                drawImage(
                    image,
                    srcOffset = IntOffset.Zero,
                    srcSize = IntSize(image.width, image.height),
                    dstOffset = IntOffset(((at.x - sprite.anchorX * w) * px).roundToInt(), ((at.y - sprite.anchorY * h) * px).roundToInt()),
                    dstSize = IntSize((w * px).roundToInt().coerceAtLeast(1), (h * px).roundToInt().coerceAtLeast(1)),
                )
            }
        }

        // The input layer over the whole window (touches outside the picture still navigate locally).
        AndroidView(
            factory = { ctx ->
                ReceiverInputView(
                    ctx, controller.surface, controller.keyboard, controller.surfaceSender(),
                    inputAllowed = { controller.view.value.inputAllowed },
                    hideSystemPointer = { controller.view.value.inputAllowed && workspace?.ui?.value?.windowMode != true },
                    controlAsCommand = { controller.store.current.controlKeyAsCommand },
                ).also { view ->
                    controller.inputView = view
                    view.onHardwarePointer = { p -> workspace?.hover(p?.x, p?.y) }
                }
            },
            modifier = Modifier.fillMaxSize(),
            onRelease = { if (controller.inputView === it) controller.inputView = null },
        )

        if (pictureInPicture) return@BoxWithConstraints
        if (workspace != null) {
            val wsUi by workspace.ui.collectAsState()
            LaunchedEffect(frame, folds, transform) {
                if (!frame.isEmpty) workspace.updateSpace(WSize(minOf(frame.width, widthDp), minOf(frame.height, heightDp)), hingeFor(folds, transform))
            }
            WorkspaceChrome(workspace, transform, state.inputAllowed, avoid = occupied)
            if (wsUi.available && prefs.windowSwitcher == WindowSwitcherStyle.Rail) WindowRail(workspace)
        }

        val actions = remember(controller) { controller.overlayActions(onOpenSettings, onOccupied = { occupied = it }, onCanvas = { canvas = it }) }
        overlay(window, actions, state.inputResetGeneration)

        // The typing strip, pinned to the keyboard's top edge while it is up. It sits above the input
        // layer and takes its own touches, so nothing tapped on it reaches the Mac.
        if (keyboardShown) {
            val echo by controller.typedEcho.collectAsState()
            TypingStrip(
                echo = echo,
                macName = macName,
                onDone = { controller.setKeyboardRequested(false) },
                modifier = Modifier.align(Alignment.BottomCenter).windowInsetsPadding(WindowInsets.ime),
            )
        }

        // Stage Peek: Window mode only (in Mirror/Extend the edge belongs to the Mac), above the controls.
        // Only its edge strip takes touches until it opens; the picture underneath never moves.
        if (workspace != null && immersive && prefs.windowSwitcher == WindowSwitcherStyle.StagePeek) {
            val wsUi by workspace.ui.collectAsState()
            val peekFrame = canvas ?: windowRect
            val peekSafe = CGRect(
                insets.leading, insets.top, widthDp - insets.leading - insets.trailing, heightDp - insets.top - insets.bottom,
            ).intersection(peekFrame).offsetBy(-peekFrame.minX, -peekFrame.minY)
            if (wsUi.windowMode && !peekSafe.isNull && !peekSafe.isEmpty) {
                StagePeekOverlay(
                    controller = workspace,
                    edge = prefs.stagePeekEdge,
                    frame = peekFrame,
                    safe = peekSafe,
                    avoiding = (occupied + folds).map { it.offsetBy(-peekFrame.minX, -peekFrame.minY) },
                    hapticsEnabled = prefs.hapticsEnabled,
                    isExpanded = window.expanded,
                    onFullDesktop = { onMode(workspace.fullDisplayMode) },
                    onStripFrame = { stripFrame = it },
                )
            }
        }

        InputPromptCapsule(
            kind = state.prompt,
            onTap = controller::requestInputTapped,
            modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = (insets.bottom + 76 - 22).dp),
        )
        if (state.inputAllowed && prefs.inputMode == PointerInputMode.Direct &&
            prefs.touchStyle == DirectTouchStyle.Natural && !prefs.naturalTouchHintShown
        ) {
            NaturalTouchHint(
                onDone = { controller.store.update { it.naturalTouchHintShown = true } },
                modifier = Modifier.align(Alignment.TopCenter).padding(horizontal = 16.dp).padding(top = (insets.top + 12).dp)
                    .onGloballyPositioned { c ->
                        val b = c.boundsInRoot(); val d = density.density.toDouble()
                        hintFrame = CGRect(b.left / d, b.top / d, b.width / d, b.height / d)
                    },
            )
            DisposableEffect(Unit) { onDispose { hintFrame = null } }
        }
        // The full-desktop view offers Window view once per launch, never forced.
        if (workspace != null && immersive) {
            val wsUi by workspace.ui.collectAsState()
            val answered by workspace.windowPromptAnswered
            if (wsUi.available && !wsUi.windowMode && !answered && !wsUi.overviewOpen) {
                val top = maxOf(insets.top + 12, (hintFrame?.maxY ?: 0.0) + 8, (workspace.railHandle.value?.maxY ?: 0.0) + 8)
                WindowModePrompt(
                    onYes = { workspace.windowPromptAnswered.value = true; onMode(DisplayMode.Window) },
                    onNo = { workspace.windowPromptAnswered.value = true },
                    modifier = Modifier.align(Alignment.TopCenter).padding(top = top.dp)
                        .onGloballyPositioned { c ->
                            val b = c.boundsInRoot(); val d = density.density.toDouble()
                            promptFrame = CGRect(b.left / d, b.top / d, b.width / d, b.height / d)
                        },
                )
                DisposableEffect(Unit) { onDispose { promptFrame = null } }
            }
        }
        if (showPerformance) {
            com.raisecaterror.meowdisplay.android.media.PerformanceOverlay(
                pipeline.stats, rttMs,
                Modifier.align(Alignment.BottomCenter).padding(bottom = (insets.bottom + 76 + 34).dp),
                route = routeLabel,
            )
        }
        workspace?.let { WindowOverview(it, macName, state.inputAllowed, onMirror = { onMode(DisplayMode.Mirror) }, onExtend = { onMode(DisplayMode.Extend) }) }
    }
}

/** One-time note after Natural Touch became the default: what changed and where Classic is. */
@Composable
private fun NaturalTouchHint(onDone: () -> Unit, modifier: Modifier = Modifier) {
    // Counts down only while this screen has focus: under the Settings dialog (or with the app in
    // the background) nobody can read it.
    val focused = androidx.compose.ui.platform.LocalWindowInfo.current.isWindowFocused
    LaunchedEffect(focused) {
        if (!focused) return@LaunchedEffect
        kotlinx.coroutines.delay(12_000)
        onDone()
    }
    androidx.compose.material3.Surface(
        modifier = modifier.widthIn(max = 460.dp),
        shape = RoundedCornerShape(14.dp),
        color = androidx.compose.material3.MaterialTheme.colorScheme.surfaceContainerHigh,
        tonalElevation = 6.dp,
        shadowElevation = 6.dp,
    ) {
        androidx.compose.foundation.layout.Row(Modifier.padding(14.dp), verticalAlignment = Alignment.Top) {
            androidx.compose.foundation.layout.Column(Modifier.weight(1f)) {
                Text("Natural Touch is on", fontWeight = FontWeight.SemiBold, style = androidx.compose.material3.MaterialTheme.typography.titleSmall)
                Text(
                    "Swipe to scroll, press then move to drag, touch and hold to right-click. To use Classic, go to Settings → Input.",
                    style = androidx.compose.material3.MaterialTheme.typography.bodyMedium,
                    color = androidx.compose.material3.MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            androidx.compose.material3.TextButton(onClick = onDone) { Text("OK", fontWeight = FontWeight.SemiBold) }
        }
    }
}

/** A separating fold as a hinge in canvas coordinates (nothing is placed inside it). */
private fun hingeFor(folds: List<CGRect>, t: RemoteViewportTransform): WHinge? {
    val f = folds.firstOrNull() ?: return null
    if (!t.isValid) return null
    val a = t.remotePoint(com.raisecaterror.meowdisplay.core.controls.CGPoint(f.minX, f.minY)) ?: return null
    val b = t.remotePoint(com.raisecaterror.meowdisplay.core.controls.CGPoint(f.maxX, f.maxY)) ?: return null
    val x0 = minOf(a.x, b.x).coerceIn(0.0, 1.0); val x1 = maxOf(a.x, b.x).coerceIn(0.0, 1.0)
    val y0 = minOf(a.y, b.y).coerceIn(0.0, 1.0); val y1 = maxOf(a.y, b.y).coerceIn(0.0, 1.0)
    val vertical = f.height >= f.width
    if (vertical && (x1 <= 0.05 || x0 >= 0.95)) return null
    if (!vertical && (y1 <= 0.05 || y0 >= 0.95)) return null
    return if (vertical) WHinge(WRect(x0, 0.0, maxOf(x1 - x0, 0.0), 1.0), WAxis.Vertical)
    else WHinge(WRect(0.0, y0, 1.0, maxOf(y1 - y0, 0.0)), WAxis.Horizontal)
}

/** The Mac's frames on a SurfaceView; the decoder renders straight into it. */
private fun videoSurface(context: android.content.Context, pipeline: MediaPipeline): SurfaceView = SurfaceView(context).apply {
    keepScreenOn = true
    holder.addCallback(object : SurfaceHolder.Callback {
        override fun surfaceCreated(holder: SurfaceHolder) {
            pipeline.video.setSurface(holder.surface)
        }
        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) = Unit
        override fun surfaceDestroyed(holder: SurfaceHolder) {
            pipeline.video.setSurface(null)
        }
    })
}

/** The mapped surface shown while the Mac's video is off (iOS: rounded rect, hairline, optional dot grid). */
@Composable
private fun VideoOffSurface(frame: CGRect, showGrid: Boolean) {
    Canvas(Modifier.fillMaxSize()) {
        val px = density
        val left = frame.minX.toFloat() * px
        val top = frame.minY.toFloat() * px
        val width = frame.width.toFloat() * px
        val height = frame.height.toFloat() * px
        drawRoundRect(Color(0xFF1C1C1E), Offset(left, top), Size(width, height), androidx.compose.ui.geometry.CornerRadius(12 * px))
        drawRoundRect(
            Color(0x4D545458), Offset(left + 0.5f, top + 0.5f), Size(width - 1, height - 1),
            androidx.compose.ui.geometry.CornerRadius(12 * px), style = androidx.compose.ui.graphics.drawscope.Stroke(1 * px),
        )
        if (showGrid) {
            val spacing = 28 * px
            var y = top + spacing
            while (y < top + height - 14 * px) {
                var x = left + spacing
                while (x < left + width - 14 * px) {
                    drawCircle(Color(0x59EBEBF5), radius = 1.1f * px, center = Offset(x, y))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

/** The on-surface Request Control affordance (iOS InputPromptButton). */
@Composable
private fun InputPromptCapsule(kind: ReceiverInputPrompt.Kind?, onTap: () -> Unit, modifier: Modifier = Modifier) {
    AnimatedVisibility(visible = kind != null, enter = fadeIn(), exit = fadeOut(), modifier = modifier) {
        val title = when (kind) {
            ReceiverInputPrompt.Kind.EnableInput -> "Request Control"
            ReceiverInputPrompt.Kind.RequestInput -> "Request Control"
            ReceiverInputPrompt.Kind.Requesting -> "Requesting Control…"
            ReceiverInputPrompt.Kind.Enabled -> "Control Allowed"
            ReceiverInputPrompt.Kind.Unavailable -> "This Mac isn't accepting control requests"
            null -> ""
        }
        val tappable = kind == ReceiverInputPrompt.Kind.RequestInput || kind == ReceiverInputPrompt.Kind.EnableInput
        Box(
            Modifier
                .background(Color.White.copy(alpha = 0.16f * 0.94f), CircleShape)
                .background(Color(0xF0222224), CircleShape)
                .border(0.75.dp, Color.White.copy(alpha = 0.14f), CircleShape)
                .then(if (tappable) Modifier.clickable(role = Role.Button, onClick = onTap) else Modifier)
                .semantics { contentDescription = title }
                .padding(horizontal = 16.dp, vertical = 10.dp),
        ) {
            Text(title, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
        }
    }
}

/** Hinges and folds that split the window (WindowManager FoldingFeature), in dp window coordinates. */
@Composable
private fun rememberFoldRegions(): List<CGRect> {
    val context = LocalContext.current
    val activity = context as? Activity ?: return emptyList()
    val density = LocalDensity.current.density.toDouble()
    val regions by produceState(initialValue = emptyList<CGRect>(), activity) {
        WindowInfoTracker.getOrCreate(activity).windowLayoutInfo(activity).collect { info ->
            value = info.displayFeatures.filterIsInstance<FoldingFeature>()
                .filter { it.isSeparating || it.state == FoldingFeature.State.HALF_OPENED }
                .map { fold ->
                    val b = fold.bounds
                    // A zero-width fold still divides: give it a hairline so it has an area.
                    CGRect(b.left / density, b.top / density, maxOf(b.width() / density, 1.0), maxOf(b.height() / density, 1.0))
                }
        }
    }
    return regions
}

/** The Android feedback for a receiver haptic; null plays nothing. CONFIRM needs API 30, so 29 falls back to a tap. */
private fun hapticConstant(haptic: ReceiverHaptic): Int? {
    val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.KEYBOARD_TAP
    return when (haptic) {
        is ReceiverHaptic.Control -> when (haptic.event) {
            com.raisecaterror.meowdisplay.core.controls.ControlHapticEvent.Selection -> HapticFeedbackConstants.CLOCK_TICK
            com.raisecaterror.meowdisplay.core.controls.ControlHapticEvent.Confirmation,
            com.raisecaterror.meowdisplay.core.controls.ControlHapticEvent.Reset -> confirm
            else -> HapticFeedbackConstants.KEYBOARD_TAP
        }
        is ReceiverHaptic.SmartTouch -> when (haptic.feedback) {
            SmartTouchFeedback.DirectTouchOverride -> HapticFeedbackConstants.LONG_PRESS
            SmartTouchFeedback.WindowDragArmed -> confirm
            SmartTouchFeedback.LongPressRightClick -> HapticFeedbackConstants.LONG_PRESS
            // No continuous ramp on Android: the build-up is silent, the arming tick confirms.
            else -> null
        }
        ReceiverHaptic.RotationSnap -> HapticFeedbackConstants.CLOCK_TICK
    }
}
