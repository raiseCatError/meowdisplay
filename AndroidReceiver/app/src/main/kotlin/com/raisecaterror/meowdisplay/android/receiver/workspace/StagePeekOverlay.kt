package com.raisecaterror.meowdisplay.android.receiver.workspace

import android.content.Context
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import android.view.HapticFeedbackConstants
import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.changedToDownIgnoreConsumed
import androidx.compose.ui.input.pointer.changedToUpIgnoreConsumed
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChangedIgnoreConsumed
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.dismiss
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.graphics.withMatrix
import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.StagePeekCard
import com.raisecaterror.meowdisplay.core.controls.StagePeekEdge
import com.raisecaterror.meowdisplay.core.controls.StagePeekEffect
import com.raisecaterror.meowdisplay.core.controls.StagePeekHaptic
import com.raisecaterror.meowdisplay.core.controls.StagePeekLayout
import com.raisecaterror.meowdisplay.core.controls.StagePeekMachine
import com.raisecaterror.meowdisplay.core.workspace.CatalogWindow
import com.raisecaterror.meowdisplay.core.workspace.WindowAvailability
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** MeowDisplay blue: the Stage Peek focus ring. */
private val StagePeekAccent = Color(0xFF5499FF)
private val CardFill = Color(0xFF2B2B2B)
private val ChipFill = Color(0xE61C1C1E)

/** Room around a card's rectangle for what its perspective and shadow draw beyond it (dp). */
private const val CARD_BLEED = 24.0

/**
 * Stage Peek: hold the configured screen edge, scrub the floating window stack, lift (nothing
 * changes), tap a card to switch. Drawn above the video and the controls; the picture underneath
 * never moves or resizes. Mirrors iOS StagePeekView; the rules live in [StagePeekMachine].
 *
 * Touch ownership: while closed only the edge strip takes touches; while open the whole overlay
 * does. A pointer-input node above the receiver's input view claims the touch in Compose's hit
 * test, so nothing Stage Peek handles reaches the Mac.
 *
 * All geometry is in dp, in the overlay's own coordinates: [frame] is the picture area in the
 * window, [safe] the safe part of it and [avoiding] the controls and hinges the strip stays clear
 * of, both relative to [frame].
 */
@Composable
fun StagePeekOverlay(
    controller: WorkspaceController,
    edge: StagePeekEdge,
    frame: CGRect,
    safe: CGRect,
    avoiding: List<CGRect>,
    hapticsEnabled: Boolean,
    /** A tablet-class window (the iPad layout metrics). */
    isExpanded: Boolean,
    /** The Full Desktop card: leave Window mode for the whole Mac screen. */
    onFullDesktop: () -> Unit,
    /** The edge strip's frame in window dp (null when there is none): the screen's other controls avoid it. */
    onStripFrame: (CGRect?) -> Unit,
) {
    val ui by controller.ui.collectAsState()
    val thumbnails by controller.thumbnails.collectAsState()
    val icons by controller.icons.collectAsState()
    val context = LocalContext.current
    val view = LocalView.current
    val density = LocalDensity.current.density
    val scope = rememberCoroutineScope()
    val windows = ui.catalog?.windows.orEmpty()
    val host = remember { StagePeekHost(controller, scope) }
    val machine = host.machine
    // Reading the revision subscribes this composition to every state change of the machine.
    @Suppress("UNUSED_VARIABLE") val revision = host.revision
    val visible = machine.isVisible
    val reduceMotion = remember(visible) { reduceMotionRequested(context) }

    host.edge = edge
    host.safe = safe
    host.isExpanded = isExpanded
    host.reduceMotion = reduceMotion
    host.windows = windows
    host.onFullDesktop = onFullDesktop
    host.haptics = { haptic -> if (hapticsEnabled) view.performHapticFeedback(haptic.feedbackConstant()) }

    LaunchedEffect(windows, ui.currentWindowID) {
        // Full Desktop first (top of the stack), then the Mac's windows.
        val ids = windows.map { it.id }
        machine.setItems(if (ids.isEmpty()) emptyList() else listOf(StagePeekMachine.fullDesktopID) + ids, ui.currentWindowID)
        host.changed()
    }
    // Everything that makes an open or half-open Stage Peek stale: the Mac went away, the overview took
    // over, the window changed shape (rotation, fold, split screen), the edge moved, focus left the window.
    LaunchedEffect(ui.available) { if (!ui.available) host.cancelAll() }
    LaunchedEffect(ui.overviewOpen) { if (ui.overviewOpen) host.cancelAll() }
    val resizeCount = remember { intArrayOf(0) }
    LaunchedEffect(frame.width, frame.height, edge) { if (resizeCount[0]++ > 0) host.cancelAll() }
    val windowFocused = LocalWindowInfo.current.isWindowFocused
    LaunchedEffect(windowFocused) { if (!windowFocused) host.cancelAll() }
    DisposableEffect(host) {
        onDispose {
            host.cancelAll()
            onStripFrame(null)
        }
    }
    BackHandler(enabled = visible) { host.finish(machine.dismiss()) }

    // Animated position and expansion: they follow the finger exactly while scrubbing and settle with a spring otherwise.
    val following = !visible || machine.phase == StagePeekMachine.Phase.Scrubbing
    val settle: AnimationSpec<Float> = if (following) snap() else if (reduceMotion) tween(180) else spring(dampingRatio = 0.86f, stiffness = 340f)
    val settledPosition by animateFloatAsState(machine.position.toFloat(), settle, label = "stagePeekPosition")
    val settledExpansion by animateFloatAsState(machine.expansion.toFloat(), settle, label = "stagePeekExpansion")
    val shownPosition = if (following) machine.position else settledPosition.toDouble()
    val shownExpansion = if (following) machine.expansion else settledExpansion.toDouble()
    val appear by animateFloatAsState(if (visible) 1f else 0f, if (visible) tween(if (reduceMotion) 120 else 200) else snap(), label = "stagePeekAppear")

    val cards = StagePeekLayout.cards(
        host.aspects(), shownPosition, shownExpansion, edge, safe, isExpanded, reduceMotion,
    )
    val strip = if (machine.ids.isNotEmpty() && !ui.overviewOpen) StagePeekLayout.strip(edge, safe, avoiding) else null
    LaunchedEffect(strip == null) { if (strip == null) onStripFrame(null) }

    Box(
        Modifier
            .offset { IntOffset((frame.minX * density).roundToInt(), (frame.minY * density).roundToInt()) }
            .size(frame.width.dp, frame.height.dp),
    ) {
        if (visible) {
            Backdrop(edge, frame, shownExpansion, isExpanded, { appear }, host)
            Box(
                Modifier.fillMaxSize().graphicsLayer {
                    alpha = appear
                    if (!reduceMotion) translationX = (1f - appear) * 48.dp.toPx() * (if (edge == StagePeekEdge.Left) -1f else 1f)
                },
            ) {
                for (card in cards) key(card.index) {
                    val id = machine.ids.getOrNull(card.index)
                    val window = id?.let { wanted -> windows.firstOrNull { it.id == wanted } }
                    StagePeekCardView(
                        card = card, fullDesktop = id == StagePeekMachine.fullDesktopID, window = window,
                        thumbnail = window?.let { thumbnails[it.id] }, icon = window?.let { icons[it.bundleID] },
                        radius = if (isExpanded) 14.0 else 11.0, host = host,
                    )
                }
                cards.firstOrNull { it.highlighted }?.let { focus ->
                    val window = machine.ids.getOrNull(focus.index)?.let { wanted -> windows.firstOrNull { it.id == wanted } }
                    TitleChip(focus, window, window?.let { icons[it.bundleID] }, safe)
                }
                Toolbar(host, cards, safe, ui.canAddTile, windows)
            }
        }
        if (strip != null) StripView(strip, edge, host, frame, onStripFrame)
    }
}

// MARK: - Pieces

/** Translucent depth behind the stack, strongest at the edge; the Mac stays visible. The expanded browser adds a darker veil. Never opaque. Owns every touch while Stage Peek is open. */
@Composable
private fun Backdrop(edge: StagePeekEdge, frame: CGRect, expansion: Double, isExpanded: Boolean, appear: () -> Float, host: StagePeekHost) {
    val touches = remember(host) { stagePeekTouches(host, onStrip = false) { CGPoint.zero } }
    Box(
        Modifier
            .fillMaxSize()
            .graphicsLayer { alpha = appear() }
            .pointerInput(host, touches)
            .drawBehind {
                val d = density
                val gradientWidth = min(frame.width, (if (isExpanded) 520.0 else 380.0) + expansion * frame.width).toFloat() * d
                val left = edge == StagePeekEdge.Left
                val x0 = if (left) 0f else size.width
                val x1 = if (left) gradientWidth else size.width - gradientWidth
                drawRect(
                    Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.42f), Color.Black.copy(alpha = 0f)), startX = x0, endX = x1),
                    topLeft = Offset(min(x0, x1), 0f), size = Size(gradientWidth, size.height),
                )
                if (expansion > 0) {
                    drawRect(Color(0xFF111114).copy(alpha = (0.62 * expansion).toFloat()))
                    drawRect(Color.Black.copy(alpha = (0.2 * expansion).toFloat()))
                }
            }
            .semantics {
                paneTitle = "Stage Peek"
                dismiss(label = "Close Stage Peek") { host.finish(host.machine.dismiss()); true }
            },
    )
}

/** One card: the window's thumbnail (or its icon) on a rounded plate, tilted in perspective exactly as [StagePeekLayout.hit] assumes. */
@Composable
private fun StagePeekCardView(
    card: StagePeekCard, fullDesktop: Boolean, window: CatalogWindow?,
    thumbnail: ImageBitmap?, icon: ImageBitmap?, radius: Double, host: StagePeekHost,
) {
    val d = LocalDensity.current.density
    val bleed = CARD_BLEED
    val left = card.center.x - card.size.width / 2
    val top = card.center.y - card.size.height / 2
    // The card's projected corners, relative to the padded node's top-left, in px.
    val projected = StagePeekLayout.corners(card).flatMap { listOf(((it.x - left + bleed) * d).toFloat(), ((it.y - top + bleed) * d).toFloat()) }.toFloatArray()
    val label = when {
        fullDesktop -> "Full Desktop"
        window == null -> ""
        else -> (if (window.title.isEmpty()) window.app else "${window.app}, ${window.title}") +
            if (window.availability == WindowAvailability.Offscreen) ", minimized" else ""
    }
    val highlighted = card.highlighted
    Box(
        Modifier
            .offset { IntOffset(((left - bleed) * d).roundToInt(), ((top - bleed) * d).roundToInt()) }
            .size((card.size.width + 2 * bleed).dp, (card.size.height + 2 * bleed).dp)
            .graphicsLayer { alpha = card.opacity.toFloat() }
            .drawWithContent {
                val w = card.size.width.toFloat() * d
                val h = card.size.height.toFloat() * d
                val pad = bleed.toFloat() * d
                val r = radius.toFloat() * d
                val src = floatArrayOf(pad, pad, pad + w, pad, pad + w, pad + h, pad, pad + h)
                // A tilted rectangle seen through a perspective camera is a homography of the flat one, so
                // mapping the flat card's corners onto StagePeekLayout.corners draws exactly what the hit test tests.
                val matrix = android.graphics.Matrix().apply { setPolyToPoly(src, 0, projected, 0, 4) }
                val outline = Path().apply { addRoundRect(RoundRect(pad, pad, pad + w, pad + h, CornerRadius(r))) }
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.withMatrix(matrix) {
                        val flat = this
                        val plate = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                            color = CardFill.toArgb()
                            setShadowLayer(
                                (if (highlighted) 18f else 8f) * d, 0f, 6f * d,
                                Color.Black.copy(alpha = if (highlighted) 0.5f else 0.32f).toArgb(),
                            )
                        }
                        flat.drawRoundRect(pad, pad, pad + w, pad + h, r, r, plate)
                        this@drawWithContent.clipPath(outline) { this@drawWithContent.drawContent() }
                        val line = (if (highlighted) 2.5f else 1f) * d
                        val ring = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                            style = android.graphics.Paint.Style.STROKE
                            strokeWidth = line
                            color = (if (highlighted) StagePeekAccent else Color.White.copy(alpha = 0.16f)).toArgb()
                        }
                        flat.drawRoundRect(pad + line / 2, pad + line / 2, pad + w - line / 2, pad + h - line / 2, r - line / 2, r - line / 2, ring)
                    }
                }
            },
    ) {
        Box(
            Modifier
                .padding(bleed.dp)
                .fillMaxSize()
                .clearAndSetSemantics {
                    contentDescription = label
                    role = Role.Button
                    selected = highlighted
                    onClick(label = if (fullDesktop) "Show the whole Mac screen" else "Switch to this window") {
                        host.finish(host.machine.select(card.index)); true
                    }
                },
            contentAlignment = Alignment.Center,
        ) {
            when {
                fullDesktop -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    MonitorGlyph(Modifier.size(34.dp, 28.dp), Color.White)
                    Text("Full Desktop", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
                thumbnail != null -> Image(thumbnail, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                icon != null -> Image(icon, null, Modifier.size(44.dp))
                else -> WindowGlyph(Modifier.size(34.dp, 26.dp), Color.White.copy(alpha = 0.6f))
            }
            if (window?.availability == WindowAvailability.Offscreen) {
                Text(
                    "Minimized", color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.align(Alignment.TopStart).padding(6.dp)
                        .background(Color.Black.copy(alpha = 0.55f), CircleShape).padding(horizontal = 6.dp, vertical = 2.dp),
                )
            }
        }
    }
}

/** The highlighted window's app and title, under its card. Not interactive. */
@Composable
private fun TitleChip(focus: StagePeekCard, window: CatalogWindow?, icon: ImageBitmap?, safe: CGRect) {
    val width = min(max(focus.size.width + 48, 200.0), safe.width - 24)
    val x = min(max(focus.center.x, safe.minX + width / 2), safe.maxX - width / 2)
    val y = min(focus.center.y + focus.size.height / 2 + 24, safe.maxY - 72)
    CenteredAt(x, y, width) {
        Row(
            Modifier.background(ChipFill, RoundedCornerShape(10.dp)).padding(horizontal = 10.dp, vertical = 6.dp)
                .clearAndSetSemantics { },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (icon != null) Image(icon, null, Modifier.size(22.dp))
            Column(Modifier.widthIn(max = (width - 20).dp)) {
                Text(window?.app ?: "Full Desktop", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (window == null) {
                    Text("Show the whole Mac screen", color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
                if (window != null && window.title.isNotEmpty() && window.title != window.app) {
                    Text(window.title, color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

/** Expand/Compact, Add as Tile (expanded, room for another tile), Close. Kept at the bottom of the stack's column, away from the cards' centre. */
@Composable
private fun Toolbar(host: StagePeekHost, cards: List<StagePeekCard>, safe: CGRect, canAddTile: Boolean, windows: List<CatalogWindow>) {
    val machine = host.machine
    val column = cards.firstOrNull { it.highlighted }?.center?.x ?: safe.midX
    val chosen = machine.highlightedID?.let { id -> windows.firstOrNull { it.id == id } }
    CenteredAt(min(max(column, safe.minX + 130), safe.maxX - 130), safe.maxY - 30, safe.width) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            ToolbarButton(if (machine.expanded) "Compact" else "Expand") {
                if (machine.expanded) machine.compact() else machine.expand()
                host.changed()
            }
            if (machine.expanded && canAddTile && chosen != null) {
                ToolbarButton("Add as Tile") { host.addAsTile(chosen) }
            }
            ToolbarButton("Close", glyph = "✕") { host.finish(machine.dismiss()) }
        }
    }
}

@Composable
private fun ToolbarButton(label: String, glyph: String? = null, onClick: () -> Unit) {
    Box(
        Modifier
            .background(Color(0xE61C1C1E), CircleShape)
            .border(0.75.dp, Color.White.copy(alpha = 0.18f), CircleShape)
            .clickable(role = Role.Button, onClickLabel = label, onClick = onClick)
            .semantics { contentDescription = label }
            .padding(horizontal = 14.dp, vertical = 9.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(glyph ?: label, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

/**
 * The edge strip: a few dp wide, taking only the touches that start on it. Excluded from the system
 * back gesture so an edge hold reaches Stage Peek instead of navigating back.
 */
@Composable
private fun StripView(strip: CGRect, edge: StagePeekEdge, host: StagePeekHost, frame: CGRect, onStripFrame: (CGRect?) -> Unit) {
    val d = LocalDensity.current.density
    val machine = host.machine
    val arming = machine.phase == StagePeekMachine.Phase.Arming
    val markAlpha by animateFloatAsState(if (arming) 0.9f else if (machine.isVisible) 0f else 0.42f, tween(200), label = "stagePeekStrip")
    val touches = remember(host) { stagePeekTouches(host, onStrip = true) { host.stripOrigin } }
    host.stripOrigin = CGPoint(strip.minX, strip.minY)
    Box(
        Modifier
            .offset { IntOffset((strip.minX * d).roundToInt(), (strip.minY * d).roundToInt()) }
            .size(strip.width.dp, strip.height.dp)
            .systemGestureExclusion()
            .onGloballyPositioned { c ->
                val b = c.boundsInRoot()
                onStripFrame(CGRect(b.left / d.toDouble(), b.top / d.toDouble(), b.width / d.toDouble(), b.height / d.toDouble()))
            }
            .pointerInput(host, touches)
            .semantics(mergeDescendants = true) {
                contentDescription = "Stage Peek. Shows your Mac windows"
                role = Role.Button
                if (machine.isVisible) stateDescription = "Open"
                onClick(label = if (machine.isVisible) "Switch to the highlighted window" else "Show your Mac windows") {
                    host.finish(if (machine.isVisible) machine.selectHighlighted() else machine.openDirectly()); true
                }
                customActions = listOf(
                    CustomAccessibilityAction("Next window") { host.stepFromStrip(1); true },
                    CustomAccessibilityAction("Previous window") { host.stepFromStrip(-1); true },
                )
            },
    ) {
        val markHeight = min(if (arming) 56.0 else 40.0, strip.height * 0.4)
        Box(
            Modifier
                .align(if (edge == StagePeekEdge.Left) Alignment.CenterStart else Alignment.CenterEnd)
                .padding(horizontal = 3.dp)
                .size(4.dp, markHeight.dp)
                .background(Color.White.copy(alpha = markAlpha), CircleShape),
        )
    }
}

/** Lays [content] out at its natural size (up to [maxWidth] dp) centred on ([x], [y]) in the parent; the rest of the parent stays transparent to touches. */
@Composable
private fun CenteredAt(x: Double, y: Double, maxWidth: Double, content: @Composable () -> Unit) {
    val d = LocalDensity.current.density
    Layout(content = content, modifier = Modifier.fillMaxSize()) { measurables, constraints ->
        val placeable = measurables.first().measure(Constraints(maxWidth = min((maxWidth * d).roundToInt(), constraints.maxWidth)))
        layout(constraints.maxWidth, constraints.maxHeight) {
            placeable.place((x * d - placeable.width / 2.0).roundToInt(), (y * d - placeable.height / 2.0).roundToInt())
        }
    }
}

@Composable
private fun MonitorGlyph(modifier: Modifier, color: Color) {
    Canvas(modifier) {
        val line = 2f * density
        drawRoundRect(color, Offset(line / 2, line / 2), Size(size.width - line, size.height * 0.72f), CornerRadius(3f * density), Stroke(line))
        drawLine(color, Offset(size.width * 0.5f, size.height * 0.72f), Offset(size.width * 0.5f, size.height * 0.9f), line)
        drawLine(color, Offset(size.width * 0.28f, size.height - line / 2), Offset(size.width * 0.72f, size.height - line / 2), line)
    }
}

@Composable
private fun WindowGlyph(modifier: Modifier, color: Color) {
    Canvas(modifier) {
        val line = 2f * density
        drawRoundRect(color, Offset(line / 2, line / 2), Size(size.width - line, size.height - line), CornerRadius(4f * density), Stroke(line))
        drawLine(color, Offset(line / 2, size.height * 0.3f), Offset(size.width - line / 2, size.height * 0.3f), line)
    }
}

// MARK: - Touches

/**
 * Feeds a node's pointers to Stage Peek: [onStrip] says whether a touch that begins here counts as
 * starting on the edge strip, [origin] is this node's top-left in overlay dp. Every pointer that goes
 * down here is consumed so nothing underneath sees it, and a cancelled gesture (the system took the
 * touch, the node left composition) becomes [StagePeekMachine.touchCancelled], never a selection.
 */
private fun stagePeekTouches(host: StagePeekHost, onStrip: Boolean, origin: () -> CGPoint): suspend androidx.compose.ui.input.pointer.PointerInputScope.() -> Unit = {
    val active = mutableSetOf<Long>()
    try {
        awaitPointerEventScope {
            while (true) {
                val event = awaitPointerEvent(PointerEventPass.Main)
                val o = origin()
                for (change in event.changes) {
                    val id = change.id.value
                    val at = CGPoint(o.x + change.position.x / density, o.y + change.position.y / density)
                    val time = change.uptimeMillis / 1000.0
                    when {
                        change.changedToDownIgnoreConsumed() -> {
                            active += id
                            host.began(id, at, time, onStrip)
                            change.consume()
                        }
                        change.changedToUpIgnoreConsumed() && id in active -> {
                            active -= id
                            host.ended(id, at, time)
                            change.consume()
                        }
                        change.pressed && id in active -> {
                            if (change.positionChangedIgnoreConsumed()) host.moved(id, at, time)
                            change.consume()
                        }
                    }
                }
            }
        }
    } finally {
        for (id in active) host.cancelled(id)
    }
}

// MARK: - State

/**
 * The machine, the gesture plumbing around it and its effects. The machine is plain mutable
 * state, so [revision] is bumped after every change to recompose the overlay. Main thread only.
 */
@Stable
private class StagePeekHost(private val controller: WorkspaceController, private val scope: CoroutineScope) {
    val machine = StagePeekMachine()
    var revision by mutableIntStateOf(0)
        private set

    var edge = StagePeekEdge.Left
    var safe = CGRect.zero
    var isExpanded = false
    var reduceMotion = false
    var windows: List<CatalogWindow> = emptyList()
    var onFullDesktop: () -> Unit = {}
    var haptics: (StagePeekHaptic) -> Unit = {}
    var stripOrigin = CGPoint.zero
    private var poll: Job? = null

    fun changed() { revision++ }

    /** Width / height per card, in stack order: Full Desktop is a typical screen; a window with no known size is 3:2. */
    fun aspects(): List<Double> = machine.ids.map { id ->
        if (id == StagePeekMachine.fullDesktopID) 1.6
        else windows.firstOrNull { it.id == id }?.takeIf { it.width > 0 && it.height > 0 }?.let { it.width.toDouble() / it.height } ?: 1.5
    }

    /** The cards as laid out from the machine's state right now: what a tap lands on. */
    private fun hitCards() = StagePeekLayout.cards(aspects(), machine.position, machine.expansion, edge, safe, isExpanded, reduceMotion)

    fun began(id: Long, at: CGPoint, time: Double, onStrip: Boolean) {
        machine.touchBegan(id, at, time, onStrip)
        if (machine.phase == StagePeekMachine.Phase.Arming) {
            controller.setStagePeekOpen(true) // fresh catalog and thumbnails while the hold completes
            schedulePoll()
        }
        changed()
    }

    fun moved(id: Long, at: CGPoint, time: Double) {
        val wasArming = machine.phase == StagePeekMachine.Phase.Arming
        val effects = machine.touchMoved(id, at, time, edge)
        if (wasArming && machine.phase == StagePeekMachine.Phase.Closed) {
            // A swipe from the edge: nothing opens.
            poll?.cancel()
            controller.setStagePeekOpen(false)
        }
        changed()
        perform(effects)
    }

    fun ended(id: Long, at: CGPoint, time: Double) {
        poll?.cancel()
        val cards = hitCards()
        finish(machine.touchEnded(id, at, time) { StagePeekLayout.hit(it, cards) })
        if (machine.phase == StagePeekMachine.Phase.Arming) schedulePoll() // another finger lifted; the hold goes on
    }

    /** The system took a touch (a gesture conflict, a fold, focus loss): never selects. */
    fun cancelled(id: Long) {
        poll?.cancel()
        machine.touchCancelled(id)
        finish(emptyList())
    }

    fun cancelAll() {
        poll?.cancel()
        machine.cancelAll()
        changed()
        controller.setStagePeekOpen(false)
    }

    /** TalkBack's next/previous window: opens first if needed, nothing is selected. */
    fun stepFromStrip(delta: Int) {
        if (!machine.isVisible) finish(machine.openDirectly())
        finish(machine.step(delta))
    }

    fun addAsTile(window: CatalogWindow) {
        haptics(StagePeekHaptic.Select)
        machine.cancelAll()
        changed()
        controller.setStagePeekOpen(false)
        controller.choose(window, asNewTile = true)
    }

    /** Performs effects, then drops the catalog refresh once nothing shows. */
    fun finish(effects: List<StagePeekEffect>) {
        changed()
        perform(effects)
        if (machine.phase == StagePeekMachine.Phase.Closed && controller.ui.value.stagePeekOpen) controller.setStagePeekOpen(false)
    }

    private fun now(): Double = SystemClock.uptimeMillis() / 1000.0

    private fun schedulePoll() {
        poll?.cancel()
        val delaySeconds = machine.pollDelay(now()) ?: return
        poll = scope.launch {
            delay(((delaySeconds + 0.004) * 1000).toLong())
            val effects = machine.poll(now())
            changed()
            if (machine.phase == StagePeekMachine.Phase.Arming) schedulePoll() // woke a hair early
            perform(effects)
        }
    }

    private fun perform(effects: List<StagePeekEffect>) {
        for (effect in effects) when (effect) {
            StagePeekEffect.Opened -> controller.setStagePeekOpen(true)
            is StagePeekEffect.Haptic -> haptics(effect.haptic)
            is StagePeekEffect.Select -> {
                controller.setStagePeekOpen(false)
                if (effect.id == StagePeekMachine.fullDesktopID) onFullDesktop()
                else windows.firstOrNull { it.id == effect.id }?.let { controller.choose(it, asNewTile = false) }
            }
            StagePeekEffect.Dismissed -> controller.setStagePeekOpen(false)
        }
    }
}

/** Stage Peek's haptics are discrete events only, never continuous. CONFIRM needs API 30, so 29 falls back to a tap. */
private fun StagePeekHaptic.feedbackConstant(): Int = when (this) {
    StagePeekHaptic.Activate -> HapticFeedbackConstants.LONG_PRESS
    StagePeekHaptic.Tick -> HapticFeedbackConstants.CLOCK_TICK
    StagePeekHaptic.Boundary -> HapticFeedbackConstants.KEYBOARD_TAP
    StagePeekHaptic.Select ->
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) HapticFeedbackConstants.CONFIRM else HapticFeedbackConstants.KEYBOARD_TAP
}

/** Android's "Remove animations" (animator duration scale 0) is the Reduce Motion switch: no tilt, no slide. */
private fun reduceMotionRequested(context: Context): Boolean =
    runCatching { Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f }.getOrDefault(false)

/**
 * The full-desktop view's offer to switch to Window view: shown once per launch, never forced.
 * Its frame is reported so the rest of the screen treats it as an occupied control.
 */
@Composable
fun WindowModePrompt(onYes: () -> Unit, onNo: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier
            .background(Color(0xF0222224), CircleShape)
            .border(0.75.dp, Color.White.copy(alpha = 0.14f), CircleShape)
            .padding(start = 16.dp, end = 6.dp, top = 6.dp, bottom = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Switch to Window view?", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Text(
            "Yes", color = Color.Black, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.background(StagePeekAccent, CircleShape).clickable(role = Role.Button, onClick = onYes).padding(horizontal = 16.dp, vertical = 8.dp),
        )
        Text(
            "No", color = Color.White, fontSize = 15.sp,
            modifier = Modifier.border(0.75.dp, Color.White.copy(alpha = 0.3f), CircleShape).clickable(role = Role.Button, onClick = onNo).padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
}
