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
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.systemGestureExclusion
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.Stable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
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
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.platform.LocalWindowInfo
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.dismiss
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.edit
import androidx.core.graphics.withMatrix
import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.StagePeekCard
import com.raisecaterror.meowdisplay.core.controls.StagePeekEdge
import com.raisecaterror.meowdisplay.core.controls.StagePeekEffect
import com.raisecaterror.meowdisplay.core.controls.StagePeekHaptic
import com.raisecaterror.meowdisplay.core.controls.StagePeekLayout
import com.raisecaterror.meowdisplay.core.controls.StagePeekMachine
import com.raisecaterror.meowdisplay.core.workspace.CatalogDisplay
import com.raisecaterror.meowdisplay.core.workspace.CatalogWindow
import com.raisecaterror.meowdisplay.core.workspace.MacApp
import com.raisecaterror.meowdisplay.core.workspace.WSource
import com.raisecaterror.meowdisplay.core.workspace.WindowAvailability
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceSearch
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.TextButton
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.heightIn
import com.raisecaterror.meowdisplay.android.ui.rememberScreenReaderRunning
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.foundation.layout.fillMaxHeight
import com.raisecaterror.meowdisplay.core.controls.StagePeekConfig
import com.raisecaterror.meowdisplay.core.controls.StagePeekDockStyle
import com.raisecaterror.meowdisplay.core.controls.StagePeekGalleryLayout
import com.raisecaterror.meowdisplay.core.workspace.WindowCloseNotice

/** MeowDisplay blue: the Stage Peek focus ring. */
private val StagePeekAccent = Color(0xFF5499FF)
private val CardFill = Color(0xFF2B2B2B)
private val ChipFill = Color(0xE61C1C1E)
private val Glass = Color(0xD92A2A2E)

/** Room around a card's rectangle for what its perspective and shadow draw beyond it (dp). */
private const val CARD_BLEED = 24.0

/** Stage Peek ids for display cards: 0 is the main display (Full Desktop), others count up from a reserved base. */
private object PeekIDs {
    fun display(index: Int): Long = if (index == 0) StagePeekMachine.fullDesktopID else 0xFFFF_FF00L + index
    fun displayIndex(id: Long): Int? = when {
        id == StagePeekMachine.fullDesktopID -> 0
        id > 0xFFFF_FF00L && id <= 0xFFFF_FF08L -> (id - 0xFFFF_FF00L).toInt()
        else -> null
    }
}

/** Height of the floating search pill and app carousel above the gallery (dp). */
private const val TOP_CONTROLS = 12.0 + 44 + 10 + 66 + 14

/**
 * Stage Peek (iOS StagePeekView): tap, flick or hold the configured screen edge for a Dock-like
 * column of the Mac's windows; scrub it, then tap a card to show that window. A sideways flick
 * opens the gallery (every window and display, two columns at most), with a floating search pill
 * and an app carousel at the top. Hold a card and drag it onto a pane (or onto the desktop in
 * Mirror/Extend). Browsing never changes the Mac: only a tap or a drop does.
 *
 * Touch ownership: while closed only the edge strip takes touches; while open the whole overlay
 * does, so nothing Stage Peek handles reaches the Mac. Geometry is in dp: [frame] is the picture
 * area in the window, [safe] its safe part and [avoiding] the controls the strip stays clear of,
 * both relative to [frame].
 */
@Composable
fun StagePeekOverlay(
    controller: WorkspaceController,
    edge: StagePeekEdge,
    /** Compact: the stack stays in a fading band between the controls above and below. */
    dock: StagePeekDockStyle = StagePeekDockStyle.Compact,
    frame: CGRect,
    safe: CGRect,
    avoiding: List<CGRect>,
    hapticsEnabled: Boolean,
    /** A tablet-class window (the iPad layout metrics). */
    isExpanded: Boolean,
    /** This session may change the Mac ("Open on Mac", Close Window). */
    inputAllowed: Boolean,
    /** A display card in Mirror/Extend (the desktop already shows: nothing to do by default). */
    onFullDesktop: () -> Unit,
    /** The edge strip's frame in window dp (null when there is none): the screen's other controls avoid it. */
    onStripFrame: (CGRect?) -> Unit,
) {
    val ui by controller.ui.collectAsState()
    val thumbnails by controller.thumbnails.collectAsState()
    val displayStills by controller.displayThumbnails.collectAsState()
    val icons by controller.icons.collectAsState()
    val context = LocalContext.current
    val view = LocalView.current
    val density = LocalDensity.current.density
    val scope = rememberCoroutineScope()
    val host = remember { StagePeekHost(controller, scope) }
    // Every new opening starts unfiltered: all windows, no app selected, no search (layout prefs kept).
    LaunchedEffect(ui.stagePeekOpen) { if (ui.stagePeekOpen) host.resetBrowsing() }
    val machine = host.machine
    // Reading the revision subscribes this composition to every state change of the machine.
    @Suppress("UNUSED_VARIABLE") val revision = host.revision
    val visible = machine.isVisible
    val reduceMotion = remember(visible) { reduceMotionRequested(context) }
    val focusManager = LocalFocusManager.current

    val allWindows = ui.catalog?.windows.orEmpty()
    val displays = ui.catalog?.displays.orEmpty()
    // The compact column's windows: the chosen app's, matching the search.
    val windows = allWindows.filter { host.appFilter == null || it.bundleID == host.appFilter }.let {
        if (host.query.isBlank()) it else WorkspaceSearch.search(host.query, emptyList(), it).windows
    }
    // Finder first, running apps next, then every installed app; the running apps from the window list until the Mac's app list arrives.
    val dockApps = ui.apps.ifEmpty {
        WorkspaceSearch.carouselOrder(ui.catalog?.apps.orEmpty().map { a -> MacApp(a.bundleID, a.name, true, allWindows.count { it.bundleID == a.bundleID }) })
    }

    host.edge = edge
    host.safe = safe
    host.frame = frame
    host.isExpanded = isExpanded
    host.reduceMotion = reduceMotion
    host.windows = windows
    host.displays = displays
    host.onFullDesktop = onFullDesktop
    host.haptics = { haptic -> if (hapticsEnabled) view.performHapticFeedback(haptic.feedbackConstant()) }
    host.announce = { message -> view.announceForAccessibility(message) }
    host.canClose = ui.canCloseWindows
    // The Compact Dock's band: under the search and app carousel, above the buttons.
    val region = if (dock == StagePeekDockStyle.Compact) {
        val compactWidth = min(max(safe.width * (if (isExpanded) 0.24 else 0.36), 110.0), if (isExpanded) 300.0 else 210.0)
        val column = if (edge == StagePeekEdge.Left) safe.minX + 16 + compactWidth / 2 else safe.maxX - 16 - compactWidth / 2
        StagePeekLayout.dockRegion(safe, safe.minY + TOP_CONTROLS - 14, toolbarY(column, safe, avoiding) - 20)
    } else null
    host.region = region

    LaunchedEffect(frame) { controller.desktopFrame = frame }
    LaunchedEffect(windows, displays, ui.currentWindowID, ui.windowMode) {
        // Displays first (Full Desktop at the top), then the Mac's windows. Always at least Full Desktop,
        // so the edge bar works before the first listing (it asks for one).
        val displayIDs = if (displays.isEmpty()) listOf(StagePeekMachine.fullDesktopID) else displays.indices.map(PeekIDs::display)
        machine.setItems(displayIDs + windows.map { it.id }, if (ui.windowMode) ui.currentWindowID else StagePeekMachine.fullDesktopID)
        host.changed()
    }
    // Everything that makes an open or half-open Stage Peek stale.
    LaunchedEffect(ui.available) { if (!ui.available) host.cancelAll() }
    LaunchedEffect(ui.overviewOpen) { if (ui.overviewOpen) host.cancelAll() }
    val resizeCount = remember { intArrayOf(0) }
    LaunchedEffect(frame.width, edge) { if (resizeCount[0]++ > 0 && !host.searchFocused) host.cancelAll() }
    val windowFocused = LocalWindowInfo.current.isWindowFocused
    // Not for the peek's own dialogs (a card's menu, Close Window's confirmation): they take focus too.
    LaunchedEffect(windowFocused) { if (!windowFocused && !host.searchFocused && host.menuWindow == null && host.confirmClose == null) host.cancelAll() }
    LaunchedEffect(visible) { if (!visible) { host.query = ""; focusManager.clearFocus(); host.searchFocused = false } }
    LaunchedEffect(host.launchpad) { controller.setLaunchpadOpen(host.launchpad) }
    // Remote Finder's "Finder Windows": the peek opens on Finder's windows.
    val peekApp = controller.peekAppRequest.value
    LaunchedEffect(peekApp) {
        val b = peekApp ?: return@LaunchedEffect
        controller.peekAppRequest.value = null
        host.openApp(dockApps.firstOrNull { it.bundleID == b } ?: MacApp(b, "Finder", true, 0))
        if (!machine.expanded) host.expand()
    }
    DisposableEffect(host) {
        onDispose {
            host.cancelAll()
            onStripFrame(null)
            controller.setLaunchpadOpen(false)
        }
    }
    BackHandler(enabled = visible || host.launchpad) {
        if (host.launchpad) host.launchpad = false else host.finish(machine.dismiss())
    }

    // Animated position and expansion: they follow the finger exactly while scrubbing and settle with a spring otherwise.
    val following = !visible || machine.phase == StagePeekMachine.Phase.Scrubbing
    val settle: AnimationSpec<Float> = if (following) snap() else if (reduceMotion) tween(180) else spring(dampingRatio = 0.86f, stiffness = 340f)
    val settledPosition by animateFloatAsState(machine.position.toFloat(), settle, label = "stagePeekPosition")
    val settledExpansion by animateFloatAsState(machine.expansion.toFloat(), settle, label = "stagePeekExpansion")
    val shownPosition = if (following) machine.position else settledPosition.toDouble()
    val shownExpansion = if (following) machine.expansion else settledExpansion.toDouble()
    val appear by animateFloatAsState(if (visible) 1f else 0f, if (visible) tween(if (reduceMotion) 120 else 200) else snap(), label = "stagePeekAppear")
    val dragging = ui.drag != null

    val cards = host.revealShifted(StagePeekLayout.cards(host.aspects(), shownPosition, shownExpansion, edge, safe, isExpanded, reduceMotion, region))
    val strip = if (machine.ids.isNotEmpty() && !ui.overviewOpen && !host.launchpad) StagePeekLayout.strip(edge, safe, avoiding) else null
    LaunchedEffect(strip == null) { if (strip == null) onStripFrame(null) }
    // Cards near the highlight first (compact); the gallery reports its own visible cards.
    LaunchedEffect(visible, machine.expanded, shownPosition.roundToInt(), windows) {
        if (visible && !machine.expanded) {
            controller.thumbnailPriority = machine.ids.indices.filter { abs(it - machine.position) <= 4 }.map { machine.ids[it] }.filter { PeekIDs.displayIndex(it) == null }
        }
    }

    Box(
        Modifier
            .offset { IntOffset((frame.minX * density).roundToInt(), (frame.minY * density).roundToInt()) }
            .size(frame.width.dp, frame.height.dp),
    ) {
        if (visible) {
            // Barely there (not gone) while dragging, so the finger's gesture keeps its node.
            Backdrop(edge, frame, shownExpansion, isExpanded, { if (dragging) 0.001f else appear }, host)
            if (shownExpansion < 0.999 && !dragging) {
                Box(
                    Modifier.fillMaxSize().graphicsLayer {
                        alpha = appear * (1f - shownExpansion.toFloat())
                        if (!reduceMotion) translationX = (1f - appear) * 48.dp.toPx() * (if (edge == StagePeekEdge.Left) -1f else 1f)
                        // Compact Dock: the cards fade and clip at the band's edges, never under the controls.
                        if (region != null) compositingStrategy = CompositingStrategy.Offscreen
                    }.then(if (region == null) Modifier else Modifier.drawWithContent {
                        drawContent()
                        val e = shownExpansion.toFloat()
                        // Expanding releases the band smoothly.
                        val top = (region.minY * (1 - e)).toFloat() * density
                        val bottom = (region.maxY + (frame.height - region.maxY) * e).toFloat() * density
                        val f = (StagePeekConfig.dockFade.toFloat() * density / (bottom - top).coerceAtLeast(1f)).coerceAtMost(0.4f) * (1 - e)
                        drawRect(
                            Brush.verticalGradient(0f to Color.Transparent, f to Color.Black, (1 - f) to Color.Black, 1f to Color.Transparent, startY = top, endY = bottom),
                            blendMode = BlendMode.DstIn,
                        )
                    }),
                ) {
                    for (card in cards) key(card.index) {
                        val id = machine.ids.getOrNull(card.index)
                        val displayIndex = id?.let(PeekIDs::displayIndex)
                        val display = displayIndex?.let { displays.getOrNull(it) }
                        val window = if (displayIndex == null) id?.let { wanted -> windows.firstOrNull { it.id == wanted } } else null
                        StagePeekCardView(
                            card = card, displayIndex = displayIndex, display = display, window = window,
                            thumbnail = window?.let { thumbnails[it.id] } ?: display?.let { displayStills[it.id] },
                            icon = window?.let { icons[it.bundleID] },
                            radius = if (isExpanded) 14.0 else 11.0, host = host,
                        )
                    }
                    if (shownExpansion < 0.5) cards.firstOrNull { it.highlighted }?.let { focus ->
                        val id = machine.ids.getOrNull(focus.index)
                        val window = id?.let { wanted -> windows.firstOrNull { it.id == wanted } }
                        val display = id?.let(PeekIDs::displayIndex)?.let { displays.getOrNull(it) }
                        TitleChip(focus, window, display, window?.let { icons[it.bundleID] }, safe, edge)
                    }
                }
                if (shownExpansion < 0.5) machine.closeRevealed?.let { rid ->
                    val index = machine.ids.indexOf(rid)
                    val card = cards.firstOrNull { it.index == index }
                    val w = windows.firstOrNull { it.id == rid }
                    if (card != null && w != null) CompactCloseButton(w, card, inputAllowed) { host.hideClose(); controller.closeWindow(w) }
                }
            }
            if (shownExpansion > 0.001) {
                // The top controls step down below chrome already at the top (the demo's badge); the gallery follows.
                val controlsShift = ((avoiding.filter { it.minY < safe.minY + 80 && it.maxX > safe.minX && it.minX < safe.maxX }
                    .maxOfOrNull { it.maxY + 8 } ?: 0.0) - (safe.minY + 12)).coerceAtLeast(0.0)
                Gallery(
                    controller, ui, host, allWindows, displays, thumbnails, displayStills, icons, inputAllowed, safe,
                    Modifier.graphicsLayer { alpha = if (dragging) 0f else shownExpansion.toFloat() },
                    enabled = machine.expanded, topExtra = controlsShift,
                    // The gallery stops above Compact and Close (lifted over the tray), never under them.
                    bottom = toolbarY(safe.midX, safe, avoiding) - 26,
                )
            }
            // Kept (invisible) while dragging, so a drag that began on the app carousel keeps its gesture.
            TopControls(host, controller, dockApps, icons, safe, shownExpansion, if (dragging) 0f else appear, avoiding)
            if (!dragging) Toolbar(host, cards, safe, avoiding)
        }
        if (host.launchpad) Launchpad(controller, ui, host, icons, inputAllowed, safe)
        if (dragging) {
            // Landing areas and Cancel over the panes (Window mode) or over the desktop (Mirror/Extend).
            WorkspaceDropOverlay(controller, CGPoint(frame.minX, frame.minY))
            val d = ui.drag
            if (d != null && d.item is WorkspaceDrag.Item.Window) DragPreview(d.item.window, controller.still(d.item.window), icons[d.item.window.bundleID], d.location, frame)
            if (d != null && d.item is WorkspaceDrag.Item.App) {
                val px = LocalDensity.current.density
                Box(Modifier.offset { IntOffset(((d.location.x - frame.minX - 28) * px).roundToInt(), ((d.location.y - frame.minY - 28) * px).roundToInt()) }
                    .graphicsLayer { alpha = 0.95f; scaleX = 1.08f; scaleY = 1.08f }) {
                    AppIconView(icons[d.item.app.bundleID], d.item.app.name, 56.0)
                }
            }
        }
        if (strip != null) StripView(strip, edge, host, onStripFrame)
        ui.closeNotice?.let { CloseToast(it, safe, avoiding) { controller.dismissCloseNotice() } }
    }
}

private const val COMPACT_REVEAL = 92.0

/** Close Window beside a swiped compact card. Without control it says so instead. */
@Composable
private fun CompactCloseButton(w: CatalogWindow, card: StagePeekCard, inputAllowed: Boolean, onClose: () -> Unit) {
    val height = card.size.height.coerceIn(48.0, 96.0)
    val x = card.center.x + card.size.width / 2 + 4
    val d = LocalDensity.current.density
    val name = w.title.ifEmpty { w.app }
    Box(
        Modifier.offset { IntOffset((x * d).roundToInt(), ((card.center.y - height / 2) * d).roundToInt()) }
            .size((COMPACT_REVEAL - 8).dp, height.dp)
            .background(if (inputAllowed) CloseRed else Color(0xFF6B6B70), RoundedCornerShape(11.dp))
            .clickable(role = Role.Button, onClickLabel = "Close Window", onClick = LocalControlRequest.current.let { cr -> { if (inputAllowed) onClose() else cr?.request?.invoke(); Unit } })
            .semantics { contentDescription = if (inputAllowed) "Close Window $name" else "Close Window needs control" },
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(if (inputAllowed) "✕" else "🔒", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold)
            Text(if (inputAllowed) "Close Window" else (LocalControlRequest.current?.gatedLabel ?: "Needs Control"), color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                textAlign = TextAlign.Center, maxLines = 2)
        }
    }
}

private val CloseRed = Color(0xFFE5483B)

/** What happened to the last Close Window, for a few seconds (tap to dismiss). */
@Composable
private fun CloseToast(notice: WindowCloseNotice, safe: CGRect, avoiding: List<CGRect>, onDismiss: () -> Unit) {
    val view = LocalView.current
    LaunchedEffect(notice.serial) { view.announceForAccessibility(notice.message) }
    CenteredAt(safe.midX, max(toolbarY(safe.midX, safe, avoiding) - 64, safe.minY + 160), min(460.0, safe.width - 32)) {
        Row(
            Modifier.background(Color(0xF01C1C1E), RoundedCornerShape(14.dp)).border(0.75.dp, Color.White.copy(alpha = 0.18f), RoundedCornerShape(14.dp))
                .clickable(onClickLabel = "Dismiss", role = Role.Button, onClick = onDismiss).heightIn(min = 48.dp).padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                if (notice.isError) "⚠︎" else "✓", color = if (notice.isError) Color(0xFFFFA94D) else Color(0xFF4CD964), fontSize = 15.sp,
                modifier = Modifier.clearAndSetSemantics {},
            )
            Text(notice.message, color = Color.White, fontSize = 13.sp)
        }
    }
}

// MARK: - Pieces

/** Translucent depth behind the stack, strongest at the edge; the Mac stays visible. The gallery adds a soft veil. Never opaque. Owns every touch while Stage Peek is open. */
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
                    Brush.horizontalGradient(listOf(Color.Black.copy(alpha = 0.30f), Color.Black.copy(alpha = 0f)), startX = x0, endX = x1),
                    topLeft = Offset(min(x0, x1), 0f), size = Size(gradientWidth, size.height),
                )
                // The gallery: a soft veil over the Mac picture (a live video surface can't be blurred from here).
                if (expansion > 0) drawRect(Color(0xFF15151A).copy(alpha = (0.55 * expansion).toFloat()))
            }
            .semantics {
                paneTitle = "Stage Peek"
                dismiss(label = "Close Stage Peek") { host.finish(host.machine.dismiss()); true }
            },
    )
}

/** One compact card: the window's still (or its icon) on a rounded plate, drawn exactly where [StagePeekLayout.hit] looks. */
@Composable
private fun StagePeekCardView(
    card: StagePeekCard, displayIndex: Int?, display: CatalogDisplay?, window: CatalogWindow?,
    thumbnail: ImageBitmap?, icon: ImageBitmap?, radius: Double, host: StagePeekHost,
) {
    val d = LocalDensity.current.density
    val bleed = CARD_BLEED
    val left = card.center.x - card.size.width / 2
    val top = card.center.y - card.size.height / 2
    val projected = StagePeekLayout.corners(card).flatMap { listOf(((it.x - left + bleed) * d).toFloat(), ((it.y - top + bleed) * d).toFloat()) }.toFloatArray()
    val desktopName = if (display?.isMain == false) display.name else "Full Desktop"
    val label = when {
        displayIndex != null -> desktopName
        window == null -> ""
        else -> (if (window.title.isEmpty()) window.app else "${window.app}, ${window.title}") +
            (window.pausedSpoken?.let { ", $it" } ?: "")
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
                val matrix = android.graphics.Matrix().apply { setPolyToPoly(src, 0, projected, 0, 4) }
                val outline = Path().apply { addRoundRect(RoundRect(pad, pad, pad + w, pad + h, CornerRadius(r))) }
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.withMatrix(matrix) {
                        val flat = this
                        val plate = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply {
                            color = CardFill.toArgb()
                            setShadowLayer((if (highlighted) 18f else 8f) * d, 0f, 6f * d, Color.Black.copy(alpha = if (highlighted) 0.5f else 0.32f).toArgb())
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
                    onClick(label = if (displayIndex != null) "Show the desktop" else "Show this window") { host.finish(host.machine.select(card.index)); true }
                },
            contentAlignment = Alignment.Center,
        ) {
            when {
                thumbnail != null -> Image(thumbnail, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
                displayIndex != null -> Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    MonitorGlyph(Modifier.size(34.dp, 28.dp), Color.White)
                    Text(desktopName, color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                }
                icon != null -> Image(icon, null, Modifier.size(44.dp))
                else -> WindowGlyph(Modifier.size(34.dp, 26.dp), Color.White.copy(alpha = 0.6f))
            }
            if (displayIndex != null && thumbnail != null) {
                Text(desktopName, color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.align(Alignment.BottomStart).padding(6.dp).background(Color.Black.copy(alpha = 0.55f), CircleShape).padding(horizontal = 6.dp, vertical = 2.dp))
            }
            if (icon != null && thumbnail != null) {
                // The app's icon at the card's bottom-left, like Stage Manager.
                Image(icon, null, Modifier.align(Alignment.BottomStart).padding(6.dp).size(24.dp))
            }
            window?.pausedBadge?.let { paused ->
                Text(paused, color = Color.White, fontSize = 11.sp, fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.align(Alignment.TopStart).padding(6.dp).background(Color.Black.copy(alpha = 0.55f), CircleShape).padding(horizontal = 6.dp, vertical = 2.dp))
            }
        }
    }
}

/** The highlighted card's app and title, beside it. Not interactive. */
@Composable
private fun TitleChip(focus: StagePeekCard, window: CatalogWindow?, display: CatalogDisplay?, icon: ImageBitmap?, safe: CGRect, edge: StagePeekEdge) {
    // Beside the highlighted card (never over the next card); under it only when there's no room.
    val width = min(200.0, safe.width - 24)
    val left = edge == StagePeekEdge.Left
    val fits = if (left) focus.center.x + focus.size.width / 2 + 12 + width <= safe.maxX else focus.center.x - focus.size.width / 2 - 12 - width >= safe.minX
    val x = if (!fits) min(max(focus.center.x, safe.minX + width / 2), safe.maxX - width / 2)
        else if (left) focus.center.x + focus.size.width / 2 + 12 + width / 2 else focus.center.x - focus.size.width / 2 - 12 - width / 2
    val y = if (fits) focus.center.y else min(focus.center.y + focus.size.height / 2 + 30, safe.maxY - 72)
    CenteredAt(x, y, width) {
        Row(
            Modifier.background(ChipFill, RoundedCornerShape(10.dp)).padding(horizontal = 10.dp, vertical = 6.dp).clearAndSetSemantics { },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (icon != null) Image(icon, null, Modifier.size(22.dp))
            Column(Modifier.widthIn(max = (width - 20).dp)) {
                Text(window?.app ?: if (display?.isMain == false) display.name else "Full Desktop", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (window == null) Text("Hold and drag into a pane", color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (window != null && window.title.isNotEmpty() && window.title != window.app) {
                    Text(window.title, color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
}

/** The floating search pill and the Dock-like app carousel: pinned at the top of the column (compact) or centred over the gallery. */
@Composable
private fun TopControls(host: StagePeekHost, controller: WorkspaceController, apps: List<MacApp>, icons: Map<String, ImageBitmap>, safe: CGRect, e: Double, appear: Float, avoiding: List<CGRect>) {
    val compactWidth = min(if (host.isExpanded) 380.0 else 320.0, safe.width - 24)
    val wideWidth = min(if (host.isExpanded) 620.0 else 560.0, safe.width - 32)
    val width = compactWidth + (wideWidth - compactWidth) * e
    val compactX = if (host.edge == StagePeekEdge.Left) safe.minX + 12 + compactWidth / 2 else safe.maxX - 12 - compactWidth / 2
    val x = compactX + (safe.midX - compactX) * e
    val focus = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    val d = LocalDensity.current.density
    // Searching filters the apps row too (owner, 2026-10-31); choosing one clears the search.
    val searching = host.query.isNotBlank()
    val shownApps = if (searching) WorkspaceSearch.search(host.query, apps, emptyList()).apps else apps
    // Below any control already at the top of the screen (a badge, the rail handle).
    val band = CGRect(x - width / 2, safe.minY, width, 12.0 + TOP_CONTROLS)
    val top = maxOf(safe.minY + 12, (avoiding.filter { it.intersects(band) && it.minY < safe.minY + 80 }.maxOfOrNull { it.maxY + 8 } ?: 0.0))
    Column(
        Modifier.offset { IntOffset(((x - width / 2) * d).roundToInt(), (top * d).roundToInt()) }.width(width.dp).graphicsLayer { alpha = appear },
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // Search: the phone's own keyboard. Nothing typed here reaches the Mac.
        Row(
            Modifier.fillMaxWidth().heightIn(min = 44.dp).background(Glass, CircleShape).border(0.75.dp, Color.White.copy(alpha = 0.16f), CircleShape)
                // Not a clickable: that would fold the search field and the clear button into one screen-reader stop.
                .pointerInput(Unit) { detectTapGestures { focus.requestFocus() } }.padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("⌕", color = Color.White.copy(alpha = 0.75f), fontSize = 18.sp, modifier = Modifier.clearAndSetSemantics {})
            Spacer(Modifier.width(8.dp))
            Box(Modifier.weight(1f)) {
                if (host.query.isEmpty()) Text("Search apps and windows", color = Color.White.copy(alpha = 0.55f), fontSize = 15.sp)
                BasicTextField(
                    value = host.query,
                    onValueChange = { q -> host.query = q; if (q.isNotEmpty() && !host.machine.expanded) host.expand() },
                    singleLine = true,
                    textStyle = TextStyle(color = Color.White, fontSize = 15.sp),
                    cursorBrush = SolidColor(StagePeekAccent),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { }),
                    modifier = Modifier.fillMaxWidth().focusRequester(focus).onFocusChanged { f ->
                        host.searchFocused = f.isFocused
                        if (f.isFocused && !host.machine.expanded) host.expand()
                    }.semantics { contentDescription = "Search apps and windows on the Mac" },
                )
            }
            if (host.query.isNotEmpty()) Text(
                "✕", color = Color.White.copy(alpha = 0.7f),
                modifier = Modifier.minimumInteractiveComponentSize().clickable(role = Role.Button) { host.query = "" }.padding(6.dp)
                    .semantics { contentDescription = "Clear search" },
            )
        }
        // The app carousel: Finder first; tap an app to show just its windows (tap again for all).
        Row(
            Modifier.fillMaxWidth().height(66.dp).background(Glass, RoundedCornerShape(22.dp)).border(0.75.dp, Color.White.copy(alpha = 0.14f), RoundedCornerShape(22.dp))
                .padding(horizontal = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (searching && shownApps.isEmpty()) Text(
                "No apps match “${host.query.trim()}”.", color = Color.White.copy(alpha = 0.8f), fontSize = 13.sp, maxLines = 2,
                overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f).padding(horizontal = 6.dp),
            )
            else LazyRow(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                items(shownApps.take(120), key = { it.bundleID }) { app ->
                    LaunchedEffect(app.bundleID) { controller.requestIcons(listOf(app.bundleID)) }
                    val selected = host.appFilter == app.bundleID
                    Box(
                        Modifier.size(50.dp).clip(RoundedCornerShape(12.dp))
                            .background(if (selected) StagePeekAccent.copy(alpha = 0.35f) else Color.Transparent)
                            .appHoldToDrag(controller, host, app)
                            .clickable(role = Role.Button) {
                                if (controller.ui.value.drag == null) {
                                    if (searching) { host.query = ""; focusManager.clearFocus(); host.searchFocused = false }
                                    host.tapApp(app)
                                }
                            }
                            .semantics {
                                contentDescription = app.name + if (app.running) ", running" else ""
                                if (selected) stateDescription = "Showing only this app's windows"
                            },
                        contentAlignment = Alignment.Center,
                    ) {
                        AppIconView(icons[app.bundleID], app.name, 40.0)
                        if (app.running) Box(Modifier.align(Alignment.BottomCenter).padding(bottom = 1.dp).size(4.dp).background(Color.White.copy(alpha = 0.85f), CircleShape))
                    }
                }
            }
            Box(
                Modifier.size(50.dp).clip(RoundedCornerShape(12.dp)).clickable(role = Role.Button) { host.launchpad = true }.semantics { contentDescription = "All apps" },
                contentAlignment = Alignment.Center,
            ) { Text("⋯", color = Color.White, fontSize = 24.sp) }
        }
    }
}

@Composable
private fun AppIconView(icon: ImageBitmap?, name: String, size: Double) {
    if (icon != null) Image(icon, null, Modifier.size(size.dp))
    else Box(Modifier.size(size.dp).background(Color.White.copy(alpha = 0.14f), RoundedCornerShape((size * 0.22).dp)), contentAlignment = Alignment.Center) {
        Text(name.take(1).uppercase(), color = Color.White, fontSize = (size * 0.42).sp, fontWeight = FontWeight.SemiBold)
    }
}

/**
 * The toolbar's centre: the bottom of the column, lifted above any control under it (the
 * Control Tray, a hinge), so nothing overlaps and every button stays reachable.
 */
private fun toolbarY(column: Double, safe: CGRect, avoiding: List<CGRect>): Double {
    val x = min(max(column, safe.minX + 130), safe.maxX - 130)
    var y = safe.maxY - 30
    for (r in avoiding.sortedByDescending { it.minY }) {
        if (r.maxX > x - 140 && r.minX < x + 140 && r.maxY > y - 22 && r.minY < y + 22) y = r.minY - 30
    }
    return max(y, safe.minY + 30)
}

/** Expand/Compact and Close, at the bottom of the column. */
@Composable
private fun Toolbar(host: StagePeekHost, cards: List<StagePeekCard>, safe: CGRect, avoiding: List<CGRect>) {
    val machine = host.machine
    // Fixed at the bottom centre: following the highlighted card made it slide and jump while the
    // compact peek scrolled (owner report 2026-10-31). Same as Apple devices.
    val column = safe.midX
    CenteredAt(min(max(column, safe.minX + 130), safe.maxX - 130), toolbarY(column, safe, avoiding), safe.width) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            ToolbarButton(if (machine.expanded) "Compact" else "Expand") { if (machine.expanded) host.compact() else host.expand() }
            ToolbarButton("Close", glyph = "✕") { host.finish(machine.dismiss()) }
        }
    }
}

@Composable
private fun ToolbarButton(label: String, glyph: String? = null, onClick: () -> Unit) {
    Box(
        Modifier
            .minimumInteractiveComponentSize()
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

/** The card under the finger while dragging; the peek steps aside to show the panes. */
@Composable
private fun DragPreview(w: CatalogWindow, still: ImageBitmap?, icon: ImageBitmap?, at: CGPoint, frame: CGRect) {
    val d = LocalDensity.current.density
    Box(
        Modifier.offset { IntOffset(((at.x - frame.minX - 75) * d).roundToInt(), ((at.y - frame.minY - 47) * d).roundToInt()) }
            .size(150.dp, 94.dp).graphicsLayer { alpha = 0.95f; scaleX = 1.04f; scaleY = 1.04f }
            .background(Color(0xFF262626), RoundedCornerShape(10.dp)).border(2.dp, StagePeekAccent, RoundedCornerShape(10.dp)),
    ) {
        if (still != null) Image(still, null, Modifier.fillMaxSize().padding(4.dp).clip(RoundedCornerShape(8.dp)), contentScale = ContentScale.Fit)
        else Text(w.title.ifEmpty { w.app }, color = Color.White, fontSize = 12.sp, modifier = Modifier.align(Alignment.Center).padding(8.dp), maxLines = 2)
        if (icon != null) Image(icon, null, Modifier.align(Alignment.BottomStart).offset((-4).dp, 4.dp).size(24.dp))
    }
}

// MARK: - Gallery (expanded)

/**
 * Every window (and display) as a vertical gallery, as many columns as fit (phones two at most);
 * search results; an app's windows or its empty state.
 */
/**
 * Spatial Overview: each window at its shape and relative size (SpatialOverviewLayout, shared with
 * iOS), pages when they can't all be comfortably tappable. Same tap / hold-to-drag / menu / close as
 * the gallery's cards.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SpatialPages(
    controller: WorkspaceController, host: StagePeekHost, windows: List<CatalogWindow>, thumbnails: Map<Long, ImageBitmap>,
    icons: Map<String, ImageBitmap>, tiled: Set<Long>, ui: WorkspaceUi, inputAllowed: Boolean, width: Double, height: Double,
) {
    val w = max(width, 200.0)
    val h = max(height, 220.0)
    val placements = remember(windows, w, h) {
        com.raisecaterror.meowdisplay.core.controls.SpatialOverviewLayout.layout(
            windows.map { com.raisecaterror.meowdisplay.core.controls.SpatialOverviewLayout.Item(it.width.toDouble(), it.height.toDouble()) }, w, h)
    }
    val pages = (placements.maxOfOrNull { it.page } ?: 0) + 1
    val pager = androidx.compose.foundation.pager.rememberPagerState { pages }
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        androidx.compose.foundation.pager.HorizontalPager(pager, Modifier.size(w.dp, h.dp)) { page ->
            Box(Modifier.size(w.dp, h.dp)) {
                windows.forEachIndexed { i, win ->
                    val p = placements[i]
                    if (p.page == page) Box(Modifier.offset(p.rect.minX.dp, p.rect.minY.dp).size(p.rect.width.dp, p.rect.height.dp)) {
                        SpatialCard(controller, host, win, thumbnails[win.id], icons[win.bundleID], win.id in tiled,
                            ui.windowMode && ui.currentWindowID == win.id, ui.canCloseWindows && inputAllowed, win.id in ui.closingWindows)
                    }
                }
            }
        }
        if (pages > 1) Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(top = 6.dp)) {
            repeat(pages) { i -> Box(Modifier.size(6.dp).clip(CircleShape).background(Color.White.copy(alpha = if (i == pager.currentPage) 0.9f else 0.35f))) }
        }
    }
}

@Composable
private fun SpatialCard(
    controller: WorkspaceController, host: StagePeekHost, w: CatalogWindow, still: ImageBitmap?, icon: ImageBitmap?,
    inTile: Boolean, current: Boolean, closable: Boolean, closing: Boolean,
) {
    val d = LocalDensity.current.density
    var origin by remember { mutableStateOf(CGPoint.zero) }
    var lifted by remember(w.id) { mutableStateOf(false) }
    val lift by animateFloatAsState(if (lifted) 1.04f else 1f, label = "spatialLift")
    val name = w.title.ifEmpty { w.app }
    Box(
        Modifier.fillMaxSize()
            .graphicsLayer { scaleX = lift; scaleY = lift; alpha = if (closing) 0.6f else 1f }
            .onGloballyPositioned { c -> val p = c.positionInWindow(); origin = CGPoint(p.x / d.toDouble(), p.y / d.toDouble()) }
            .clip(RoundedCornerShape(8.dp)).background(Color.White.copy(alpha = 0.08f))
            .border(if (current) 2.5.dp else 1.dp, if (current) StagePeekAccent else Color.White.copy(alpha = if (inTile) 0.6f else 0.18f), RoundedCornerShape(8.dp))
            .holdToDrag(controller, host, w, { origin }, onLift = { lifted = it }, onMenu = { host.menuWindow = w })
            .clickable(role = Role.Button) { if (controller.ui.value.drag == null) host.pick(w) }
            .semantics {
                contentDescription = "${w.app}: ${w.title.ifEmpty { "window" }}" + (if (inTile) ", in a pane" else "") + (if (closing) ", closing" else "")
                if (current) stateDescription = "Showing now"
                customActions = listOfNotNull(
                    CustomAccessibilityAction("Add as New Pane") { controller.choose(w, asNewTile = true); host.closeAfterPick(); true },
                    if (closable) CustomAccessibilityAction("Close Window") { host.confirmClose = w; true } else null,
                )
            },
    ) {
        if (still != null) Image(still, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { AppIconView(icon, w.app, 32.0) }
        Text(name, color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.align(Alignment.BottomStart).padding(5.dp).background(Color.Black.copy(alpha = 0.55f), CircleShape).padding(horizontal = 6.dp, vertical = 3.dp))
        if (closable && !closing) Box(
            Modifier.align(Alignment.TopStart).size(36.dp).clickable(role = Role.Button, onClickLabel = "Close Window") { host.confirmClose = w },
            contentAlignment = Alignment.Center,
        ) { Text("✕", color = Color.White, fontSize = 9.sp, fontWeight = FontWeight.Bold, modifier = Modifier.background(Color.Black.copy(alpha = 0.6f), CircleShape).padding(5.dp)) }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Gallery(
    controller: WorkspaceController, ui: WorkspaceUi, host: StagePeekHost, allWindows: List<CatalogWindow>, displays: List<CatalogDisplay>,
    thumbnails: Map<Long, ImageBitmap>, displayStills: Map<Long, ImageBitmap>, icons: Map<String, ImageBitmap>,
    inputAllowed: Boolean, safe: CGRect, modifier: Modifier, enabled: Boolean, topExtra: Double = 0.0, bottom: Double = safe.maxY,
) {
    // Between the search and app carousel above and the buttons below; cards fade at both edges.
    val top = safe.minY + TOP_CONTROLS - 8 + topExtra
    val height = max(bottom - top, 140.0)
    val d = LocalDensity.current.density
    val configuration = LocalConfiguration.current
    // Phones (and narrow split screens) by size, never by device name; larger text, wider cards.
    val compactSize = min(configuration.screenWidthDp, configuration.screenHeightDp) < 600
    val columns = StagePeekGalleryLayout.columns(safe.width, compactSize, LocalDensity.current.fontScale.toDouble())
    val grid = rememberLazyGridState()
    // Scrolling the gallery puts a swiped card back.
    LaunchedEffect(grid.isScrollInProgress) { if (grid.isScrollInProgress) host.galleryRevealed = null }
    LaunchedEffect(ui.closingWindows) { if (host.galleryRevealed in ui.closingWindows) host.galleryRevealed = null }
    val tiled = ui.layout.tiles.values.mapNotNull { it.source?.windowID }.toSet()
    val query = host.query.trim()
    val results = if (query.isEmpty()) null else WorkspaceSearch.search(query, ui.apps, allWindows)
    val filter = host.appFilter?.let { b -> ui.apps.firstOrNull { it.bundleID == b } ?: ui.catalog?.apps?.firstOrNull { it.bundleID == b }?.let { MacApp(it.bundleID, it.name, true, 0) } }
    LaunchedEffect(grid) {
        snapshotFlow { grid.layoutInfo.visibleItemsInfo.mapNotNull { (it.key as? String)?.removePrefix("w")?.toLongOrNull() } }
            .collect { controller.thumbnailPriority = it }
    }
    // A flick toward the edge compacts the gallery again.
    var flick by remember { mutableStateOf(0f) }
    LazyVerticalGrid(
        columns = GridCells.Fixed(columns), state = grid, userScrollEnabled = enabled && ui.drag == null,
        modifier = modifier
            .offset { IntOffset((safe.minX * d).roundToInt(), (top * d).roundToInt()) }.size(safe.width.dp, height.dp)
            .graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }
            .drawWithContent {
                drawContent()
                val f = (18f * density / size.height.coerceAtLeast(1f)).coerceAtMost(0.3f)
                drawRect(Brush.verticalGradient(0f to Color.Transparent, f to Color.Black, (1 - f) to Color.Black, 1f to Color.Transparent), blendMode = BlendMode.DstIn)
            }
            .pointerInput(host.edge) {
                // Not a swipe or hold that a card took (those consume their moves, or just ended).
                detectHorizontalDragGestures(onDragStart = { flick = 0f }, onDragEnd = {
                    val toward = if (host.edge == StagePeekEdge.Left) -flick else flick
                    if (toward / density > 90 && !host.cardGestureRecent()) host.compact()
                }) { _, amount -> flick += amount }
            }
            .padding(horizontal = 20.dp),
        horizontalArrangement = Arrangement.spacedBy(StagePeekGalleryLayout.spacing.dp), verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item(span = { GridItemSpan(columns) }) { Spacer(Modifier.height(12.dp)) }
        // Spatial Overview (Settings ▸ Controls ▸ Expanded Layout): search results stay a grid.
        val spatial = controller.spatialOverview
        fun spatialCards(list: List<CatalogWindow>) = item(span = { GridItemSpan(columns) }, key = "spatial") {
            SpatialPages(controller, host, list, thumbnails, icons, tiled, ui, inputAllowed, safe.width - 40, height - 110)
        }
        fun windowCards(list: List<CatalogWindow>) = items(list, key = { "w" + it.id }) { w ->
            GalleryCard(
                controller, host, w, thumbnails[w.id], icons[w.bundleID], inTile = w.id in tiled, current = ui.windowMode && ui.currentWindowID == w.id,
                closable = ui.canCloseWindows, inputAllowed = inputAllowed, closing = w.id in ui.closingWindows,
                revealed = host.galleryRevealed == w.id, onReveal = { open -> host.galleryRevealed = if (open) w.id else host.galleryRevealed.takeIf { it != w.id } },
                onConfirmClose = { host.confirmClose = w }, onMenu = { host.menuWindow = w },
            )
        }
        // The cards' close buttons need control and are hidden without it. An app with no windows
        // offers its own Request Control (Open on Mac).
        if (!inputAllowed && ui.canCloseWindows && filter?.let { f -> allWindows.none { it.bundleID == f.bundleID } } != true) {
            item(span = { GridItemSpan(columns) }, key = "moreActionsNeedControl") {
                MoreActionsNeedControl("Request Control for more actions, like closing windows.", Modifier.fillMaxWidth())
            }
        }
        when {
            results != null -> {
                if (results.apps.isNotEmpty()) {
                    item(span = { GridItemSpan(columns) }) { SectionTitle("Applications") }
                    item(span = { GridItemSpan(columns) }) {
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            items(results.apps.take(30), key = { it.bundleID }) { app ->
                                LaunchedEffect(app.bundleID) { controller.requestIcons(listOf(app.bundleID)) }
                                Column(
                                    Modifier.width(76.dp).appHoldToDrag(controller, host, app)
                                        .clickable(role = Role.Button) { if (controller.ui.value.drag == null) { host.query = ""; host.tapApp(app, forceFilter = true) } }
                                        .semantics { contentDescription = app.name },
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                ) {
                                    AppIconView(icons[app.bundleID], app.name, 48.0)
                                    Text(app.name, color = Color.White, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                    Text(if (app.running) (if (app.windowCount > 0) "${app.windowCount} open" else "Running") else "Not running",
                                        color = Color.White.copy(alpha = 0.65f), fontSize = 10.sp, maxLines = 1)
                                }
                            }
                        }
                    }
                }
                item(span = { GridItemSpan(columns) }) { SectionTitle("Windows") }
                if (results.windows.isEmpty()) item(span = { GridItemSpan(columns) }) {
                    EmptyText(if (results.apps.isEmpty()) "No apps or windows match “$query”." else "No open windows match.")
                } else windowCards(results.windows)
                if (controller.files.ui.value.available) {
                    item(span = { GridItemSpan(columns) }) { SectionTitle("Files") }
                    item(span = { GridItemSpan(columns) }) {
                        Row(
                            Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Glass)
                                .clickable(role = Role.Button) { controller.files.open(query) }.padding(12.dp)
                                .semantics { contentDescription = "Search files on the Mac for $query" },
                            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Text("📁", fontSize = 20.sp)
                            Text("Search files on the Mac for “$query”", color = Color.White, fontSize = 15.sp, modifier = Modifier.weight(1f), maxLines = 2)
                            Text("›", color = Color.White.copy(alpha = 0.5f), fontSize = 18.sp)
                        }
                    }
                }
            }
            filter != null -> {
                val list = allWindows.filter { it.bundleID == filter.bundleID }
                item(span = { GridItemSpan(columns) }) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        AppIconView(icons[filter.bundleID], filter.name, 40.0)
                        Column {
                            Text(filter.name, color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                            Text(
                                when { list.size == 1 -> "1 window"; list.isNotEmpty() -> "${list.size} windows"; filter.running -> "Running, no open windows"; else -> "Not running" },
                                color = Color.White.copy(alpha = 0.75f), fontSize = 12.sp,
                            )
                        }
                    }
                }
                if (list.isEmpty()) item(span = { GridItemSpan(columns) }) { EmptyApp(controller, ui, filter, icons[filter.bundleID], inputAllowed) }
                else if (spatial) spatialCards(list) else windowCards(list)
            }
            else -> {
                if (displays.isNotEmpty()) {
                    item(span = { GridItemSpan(columns) }) { SectionTitle("Displays") }
                    items(displays, key = { "d" + it.id }) { disp ->
                        DisplayCard(controller, host, disp, displayStills[disp.id], current = if (ui.windowMode) WSource.displayKey(disp.id) in tiled else disp.isMain)
                    }
                }
                item(span = { GridItemSpan(columns) }) { SectionTitle("Windows") }
                if (allWindows.isEmpty()) item(span = { GridItemSpan(columns) }) {
                    EmptyText(when { ui.catalog?.unavailable == true -> "The Mac can't list its windows right now."; ui.catalog == null -> "Loading windows…"; else -> "No windows are open on the Mac." })
                } else if (spatial) spatialCards(allWindows) else windowCards(allWindows)
            }
        }
        item(span = { GridItemSpan(columns) }) { Spacer(Modifier.height(20.dp)) }
    }
    host.menuWindow?.let { w ->
        // Held in place: the window's actions.
        AlertDialog(
            onDismissRequest = { host.menuWindow = null },
            title = { Text(w.title.ifEmpty { w.app }, maxLines = 2, overflow = TextOverflow.Ellipsis) },
            text = {
                Column {
                    TextButton(onClick = { host.menuWindow = null; host.pick(w) }) { Text("Show in Pane") }
                    if (ui.canAddTile && w.id !in tiled) TextButton(onClick = { host.menuWindow = null; controller.choose(w, asNewTile = true); host.closeAfterPick() }) { Text("Add as New Pane") }
                    if (ui.canCloseWindows) TextButton(onClick = { host.menuWindow = null; controller.closeWindow(w) }) { Text("Close Window on Mac", color = CloseRed) }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { host.menuWindow = null }) { Text("Cancel") } },
        )
    }
    host.confirmClose?.let { w ->
        AlertDialog(
            onDismissRequest = { host.confirmClose = null },
            title = { Text("Close “${w.title.ifEmpty { w.app }}” on the Mac?") },
            text = { Text("Only this window closes; its app keeps running. If it has unsaved changes, the app asks on the Mac.") },
            confirmButton = { TextButton(onClick = { host.confirmClose = null; controller.closeWindow(w) }) { Text("Close Window", color = CloseRed) } },
            dismissButton = { TextButton(onClick = { host.confirmClose = null }) { Text("Cancel") } },
        )
    }
}

@Composable
private fun SectionTitle(text: String) =
    Text(text, color = Color.White.copy(alpha = 0.85f), fontSize = 14.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.semantics { heading() })

@Composable
private fun EmptyText(text: String) =
    Text(text, color = Color.White.copy(alpha = 0.8f), fontSize = 15.sp, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp))

/** An app with no window: "Open on Mac" (explicit; needs control). Browsing never opens or activates anything. */
@Composable
private fun EmptyApp(controller: WorkspaceController, ui: WorkspaceUi, app: MacApp, icon: ImageBitmap?, inputAllowed: Boolean) {
    Column(Modifier.fillMaxWidth().padding(vertical = 28.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
        AppIconView(icon, app.name, 72.0)
        Text(if (app.running) "${app.name} has no windows you can show." else "${app.name} isn't open on the Mac.", color = Color.White, fontSize = 15.sp, textAlign = TextAlign.Center)
        if (app.bundleID in ui.launching) {
            Text("Opening on the Mac…", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp)
        } else {
            Text(
                "Open on Mac", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
                modifier = Modifier.graphicsLayer { alpha = if (inputAllowed) 1f else 0.5f }.minimumInteractiveComponentSize().background(Glass, CircleShape)
                    .border(0.75.dp, Color.White.copy(alpha = 0.2f), CircleShape)
                    .clickable(enabled = inputAllowed, role = Role.Button) { controller.launch(app.bundleID) }.padding(horizontal = 18.dp, vertical = 10.dp),
            )
            if (!inputAllowed) RequestControlInline(compact = true)
            if (!inputAllowed) Text("Opening apps needs control of the Mac.", color = Color.White.copy(alpha = 0.75f), fontSize = 12.sp, textAlign = TextAlign.Center)
            if (ui.launchFailed == app.bundleID) Text("The Mac couldn't open ${app.name}.", color = Color(0xFFFFA94D), fontSize = 12.sp)
        }
    }
}

/**
 * A card's hold: after the long press the card lifts; moving drags it onto a pane (middle
 * replaces, its labels add a tab, an edge splits), lifting in place opens its menu ([onMenu]).
 * Before the hold completes a vertical drag is the gallery's scroll and cancels it.
 */
private fun Modifier.holdToDrag(
    controller: WorkspaceController, host: StagePeekHost, item: CatalogWindow, origin: () -> CGPoint,
    onLift: (Boolean) -> Unit, onMenu: (() -> Unit)?,
): Modifier = holdToDrag(controller, host, item.id, WorkspaceDrag.Item.Window(item), origin, onLift, onMenu)

/**
 * An app icon: press, hold and move drags the app onto a pane (its window goes there; several →
 * the person picks; none → offered to open it). Lifting in place does nothing.
 */
private fun Modifier.appHoldToDrag(controller: WorkspaceController, host: StagePeekHost, app: MacApp): Modifier = composed {
    val d = LocalDensity.current.density
    var origin by remember { mutableStateOf(CGPoint.zero) }
    onGloballyPositioned { c -> val p = c.positionInWindow(); origin = CGPoint(p.x / d.toDouble(), p.y / d.toDouble()) }
        .holdToDrag(controller, host, app.bundleID, WorkspaceDrag.Item.App(app), { origin }, onLift = {}, onMenu = null)
}

private fun Modifier.holdToDrag(
    controller: WorkspaceController, host: StagePeekHost, key: Any, item: WorkspaceDrag.Item, origin: () -> CGPoint,
    onLift: (Boolean) -> Unit, onMenu: (() -> Unit)?,
): Modifier = pointerInput(key, onMenu != null) {
    var at = CGPoint.zero
    var start = CGPoint.zero
    var dragging = false
    detectDragGesturesAfterLongPress(
        onDragStart = { p ->
            val o = origin()
            host.haptics(StagePeekHaptic.Activate)
            host.markCardGesture()
            at = CGPoint(o.x + p.x / density, o.y + p.y / density)
            start = at
            dragging = false
            onLift(true)
        },
        onDrag = { change, amount ->
            change.consume()
            host.markCardGesture()
            at = CGPoint(at.x + amount.x / density, at.y + amount.y / density)
            if (!dragging) {
                if (hypot(at.x - start.x, at.y - start.y) <= 12) return@detectDragGesturesAfterLongPress
                dragging = true
                controller.beginDrag(item, at)
            } else {
                controller.moveDrag(at)
            }
        },
        onDragEnd = {
            onLift(false)
            if (dragging) { dragging = false; host.dropped(controller.endDrag()) } else onMenu?.invoke()
        },
        onDragCancel = { onLift(false); if (dragging) { dragging = false; controller.cancelDrag() } },
    )
}

/**
 * A deliberate sideways swipe on a card (reveal or hide Close Window). Anything more vertical is
 * left alone, so the gallery's scroll takes it; once sideways, the swipe consumes the moves so the
 * gallery neither scrolls nor flicks. [onSwipe] gets the travel in dp; [onEnd] travel and velocity.
 */
private fun Modifier.sidewaysSwipe(enabled: Boolean, key: Any, onSwipe: (Float) -> Unit, onEnd: (Float, Float) -> Unit): Modifier =
    if (!enabled) this else pointerInput(key) {
        awaitEachGesture {
            val down = awaitFirstDown(requireUnconsumed = false)
            val tracker = VelocityTracker()
            tracker.addPosition(down.uptimeMillis, down.position)
            var total = Offset.Zero
            var swiping = false
            while (true) {
                val event = awaitPointerEvent()
                val change = event.changes.firstOrNull { it.id == down.id } ?: break
                if (!change.pressed) {
                    if (swiping) onEnd(total.x / density, tracker.calculateVelocity().x / density)
                    break
                }
                if (!swiping && change.isConsumed) break   // the scroll or a hold took it
                total += change.positionChange()
                tracker.addPosition(change.uptimeMillis, change.position)
                if (!swiping && total.getDistance() > viewConfiguration.touchSlop) {
                    if (abs(total.x) > abs(total.y) * 1.6f) swiping = true else break
                }
                if (swiping) { change.consume(); onSwipe(total.x / density) }
            }
        }
    }

private const val GALLERY_REVEAL = 96f

/**
 * One window card: tap shows it, hold lifts it (drag to a pane, or lift in place for its menu), a
 * swipe left reveals Close Window, and the X asks before closing. Vertical drags scroll the gallery.
 */
@Composable
private fun GalleryCard(
    controller: WorkspaceController, host: StagePeekHost, w: CatalogWindow, still: ImageBitmap?, icon: ImageBitmap?, inTile: Boolean, current: Boolean,
    closable: Boolean, inputAllowed: Boolean, closing: Boolean, revealed: Boolean, onReveal: (Boolean) -> Unit,
    onConfirmClose: () -> Unit, onMenu: () -> Unit,
) {
    val d = LocalDensity.current.density
    var origin by remember { mutableStateOf(CGPoint.zero) }
    var swipe by remember(w.id) { mutableStateOf<Float?>(null) }
    var lifted by remember(w.id) { mutableStateOf(false) }
    // The swipe handler outlives recompositions: it reads the current reveal state through this.
    val revealedNow by rememberUpdatedState(revealed)
    val target = swipe ?: if (revealed) -GALLERY_REVEAL else 0f
    val shown by animateFloatAsState(target, if (swipe != null) snap() else spring(dampingRatio = 0.85f, stiffness = 500f), label = "cardSwipe")
    val lift by animateFloatAsState(if (lifted) 1.04f else 1f, label = "cardLift")
    val name = w.title.ifEmpty { w.app }
    Box(Modifier.fillMaxWidth()) {
        if (shown < -1f) {
            Box(Modifier.matchParentSize(), contentAlignment = Alignment.CenterEnd) {
                val width = min(-shown, GALLERY_REVEAL + 40f)
                Column(
                    Modifier.width((width - 8f).coerceAtLeast(0f).dp).fillMaxHeight().graphicsLayer { alpha = min(1f, width / 60f) }
                        .background(if (inputAllowed) CloseRed else Color(0xFF6B6B70), RoundedCornerShape(12.dp))
                        .clickable(role = Role.Button, onClickLabel = "Close Window", onClick = LocalControlRequest.current.let { cr -> { onReveal(false); if (inputAllowed) controller.closeWindow(w) else cr?.request?.invoke(); Unit } })
                        .semantics { contentDescription = if (inputAllowed) "Close Window $name" else "Close Window needs control" },
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center,
                ) {
                    Text(if (inputAllowed) "✕" else "🔒", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                    Text(if (inputAllowed) "Close Window" else (LocalControlRequest.current?.gatedLabel ?: "Needs Control"), color = Color.White, fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 2)
                }
            }
        }
        Column(
            Modifier
                .offset { IntOffset((shown * d).roundToInt(), 0) }
                .graphicsLayer { scaleX = lift; scaleY = lift }
                .onGloballyPositioned { c -> val p = c.positionInWindow(); origin = CGPoint(p.x / d.toDouble(), p.y / d.toDouble()) }
                .sidewaysSwipe(closable && !closing, w.id,
                    onSwipe = { dx ->
                        host.markCardGesture()
                        val base = if (revealedNow) -GALLERY_REVEAL else 0f
                        var x = base + dx
                        if (x > 0) x *= 0.25f
                        if (x < -GALLERY_REVEAL) x = -GALLERY_REVEAL + (x + GALLERY_REVEAL) * 0.3f
                        swipe = x
                    },
                    onEnd = { _, velocity ->
                        host.markCardGesture()
                        val x = swipe ?: 0f
                        val open = velocity < -400f || (x < -GALLERY_REVEAL / 2 && velocity < 300f)
                        swipe = null
                        onReveal(open)
                        if (open) host.haptics(StagePeekHaptic.Tick)
                    })
                .holdToDrag(controller, host, w, { origin }, onLift = { lifted = it; if (it) onReveal(false) }, onMenu = onMenu)
                .clickable(role = Role.Button) {
                    if (controller.ui.value.drag != null) return@clickable
                    // A tap while a Close Window button shows only puts the card back.
                    if (host.galleryRevealed != null) { host.galleryRevealed = null; return@clickable }
                    host.pick(w)
                }
                .semantics {
                    contentDescription = "${w.app}: ${w.title.ifEmpty { "window" }}" + (w.pausedSpoken?.let { ", $it" } ?: "") +
                        (if (inTile) ", in a pane" else "") + (if (closing) ", closing" else "")
                    if (current) stateDescription = "Showing now"
                    customActions = listOfNotNull(
                        CustomAccessibilityAction("Add as New Pane") { controller.choose(w, asNewTile = true); host.closeAfterPick(); true },
                        if (closable) CustomAccessibilityAction("Close Window") { onConfirmClose(); true } else null,
                    )
                },
            verticalArrangement = Arrangement.spacedBy(5.dp),
        ) {
            Box(
                Modifier.fillMaxWidth().aspectRatio(16f / 10f).background(Color.White.copy(alpha = 0.07f), RoundedCornerShape(12.dp))
                    .border(if (current) 2.5.dp else 0.6.dp, if (current) StagePeekAccent else Color.White.copy(alpha = 0.14f), RoundedCornerShape(12.dp)),
                contentAlignment = Alignment.Center,
            ) {
                if (still != null) Image(still, null, Modifier.fillMaxSize().padding(6.dp).clip(RoundedCornerShape(8.dp)), contentScale = ContentScale.Fit)
                else AppIconView(icon, w.app, 44.0)
                Row(Modifier.align(Alignment.TopEnd).padding(8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    w.pausedBadge?.let { Badge(it) }
                    if (inTile) Badge("In Pane")
                }
                if (icon != null && still != null) Image(icon, null, Modifier.align(Alignment.BottomStart).padding(8.dp).size(26.dp))
                if (closing) {
                    Box(Modifier.matchParentSize().background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(12.dp)), contentAlignment = Alignment.Center) {
                        Text("Closing…", color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
                    }
                }
                if (closable && inputAllowed && !closing && shown == 0f) {
                    // Small to look at, comfortable to hit; away from the title and the badges.
                    Box(
                        Modifier.align(Alignment.TopStart).size(48.dp).clickable(role = Role.Button, onClickLabel = "Close Window", onClick = onConfirmClose)
                            .semantics { contentDescription = "Close Window $name" },
                        contentAlignment = Alignment.Center,
                    ) {
                        Box(
                            Modifier.size(22.dp).background(Color.Black.copy(alpha = 0.6f), CircleShape).border(0.6.dp, Color.White.copy(alpha = 0.35f), CircleShape),
                            contentAlignment = Alignment.Center,
                        ) { Text("✕", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold) }
                    }
                }
            }
            Text(w.title.ifEmpty { w.app }, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (w.title.isNotEmpty()) Text(w.app, color = Color.White.copy(alpha = 0.7f), fontSize = 11.sp, maxLines = 1)
        }
    }
}

@Composable
private fun DisplayCard(controller: WorkspaceController, host: StagePeekHost, disp: CatalogDisplay, still: ImageBitmap?, current: Boolean) {
    val d = LocalDensity.current.density
    var origin by remember { mutableStateOf(CGPoint.zero) }
    var lifted by remember(disp.id) { mutableStateOf(false) }
    val lift by animateFloatAsState(if (lifted) 1.04f else 1f, label = "displayLift")
    val name = if (disp.isMain) "Full Desktop" else disp.name
    Column(
        Modifier
            .graphicsLayer { scaleX = lift; scaleY = lift }
            .onGloballyPositioned { c -> val p = c.positionInWindow(); origin = CGPoint(p.x / d.toDouble(), p.y / d.toDouble()) }
            .holdToDrag(controller, host, controller.displayWindow(disp), { origin }, onLift = { lifted = it }, onMenu = null)
            .clickable(role = Role.Button) { if (controller.ui.value.drag == null) host.pickDisplay(disp) }
            .semantics {
                contentDescription = if (disp.isMain) "Full Desktop, ${disp.name}" else disp.name
                if (current) stateDescription = "Showing now"
            },
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(
            Modifier.fillMaxWidth().aspectRatio(16f / 10f).background(Color.White.copy(alpha = 0.07f), RoundedCornerShape(12.dp))
                .border(if (current) 2.5.dp else 0.6.dp, if (current) StagePeekAccent else Color.White.copy(alpha = 0.14f), RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center,
        ) {
            if (still != null) Image(still, null, Modifier.fillMaxSize().padding(6.dp).clip(RoundedCornerShape(8.dp)), contentScale = ContentScale.Fit)
            else MonitorGlyph(Modifier.size(40.dp, 34.dp), Color.White.copy(alpha = 0.8f))
        }
        Text(name, color = Color.White, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
        Text(if (disp.isMain) disp.name else if (disp.isVirtual) "Extended display" else "Display", color = Color.White.copy(alpha = 0.7f), fontSize = 11.sp, maxLines = 1)
    }
}

@Composable
private fun Badge(text: String) =
    Text(text, color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.SemiBold,
        modifier = Modifier.background(Color.Black.copy(alpha = 0.6f), CircleShape).padding(horizontal = 6.dp, vertical = 2.dp))

// MARK: - Launchpad

/** Every Mac app as a grid: favorites, recent, running, all. Tap: its windows in the gallery (or "Open on Mac"). Long-press: favorite. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun Launchpad(controller: WorkspaceController, ui: WorkspaceUi, host: StagePeekHost, icons: Map<String, ImageBitmap>, inputAllowed: Boolean, safe: CGRect) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("stagePeek", Context.MODE_PRIVATE) }
    var favorites by remember { mutableStateOf(prefs.getStringSet("favorites", emptySet()).orEmpty()) }
    val d = LocalDensity.current.density
    val apps = ui.apps
    val sections = buildList {
        val fav = apps.filter { it.bundleID in favorites }
        if (fav.isNotEmpty()) add("Favorites" to fav)
        val recent = WorkspaceSearch.recents(apps)
        if (recent.isNotEmpty()) add("Recent" to recent)
        val running = apps.filter { it.running }
        if (running.isNotEmpty()) add("Running" to running)
        add("All Apps" to apps)
    }
    Box(Modifier.fillMaxSize().semantics { paneTitle = "Apps on the Mac" }.background(Color.Black.copy(alpha = 0.6f)).pointerInput(Unit) { detectDragGesturesAfterLongPress(onDrag = { _, _ -> }) }.pointerInput(Unit) { detectTapGestures { host.launchpad = false } }) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(84.dp),
            modifier = Modifier.offset { IntOffset((safe.minX * d).roundToInt(), (safe.minY * d).roundToInt()) }.size(safe.width.dp, safe.height.dp).padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Row(Modifier.padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Apps on the Mac", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f).semantics { heading() })
                    ToolbarButton("Done") { host.launchpad = false }
                }
            }
            if (apps.isEmpty()) item(span = { GridItemSpan(maxLineSpan) }) { EmptyText("Loading apps…") }
            for ((title, list) in sections) {
                if (apps.isEmpty()) break
                item(span = { GridItemSpan(maxLineSpan) }, key = "h$title") { SectionTitle(title) }
                items(list, key = { "$title/${it.bundleID}" }) { app ->
                    LaunchedEffect(app.bundleID) { controller.requestIcons(listOf(app.bundleID)) }
                    Column(
                        Modifier.combinedClickable(
                            role = Role.Button, onLongClickLabel = if (app.bundleID in favorites) "Remove from favorites" else "Make a favorite",
                            onClick = { host.launchpad = false; host.openApp(app) },
                            onLongClick = {
                                favorites = if (app.bundleID in favorites) favorites - app.bundleID else favorites + app.bundleID
                                prefs.edit { putStringSet("favorites", favorites) }
                            },
                        ).semantics { contentDescription = app.name + (if (app.running) ", running" else "") + (if (app.bundleID in favorites) ", favorite" else "") },
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Box { AppIconView(icons[app.bundleID], app.name, 56.0)
                            if (app.running) Box(Modifier.align(Alignment.BottomCenter).offset(y = 6.dp).size(4.dp).background(Color.White, CircleShape)) }
                        Spacer(Modifier.height(8.dp))
                        Text(app.name, color = Color.White, fontSize = 11.sp, maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.Center)
                    }
                }
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                if (inputAllowed) Text("Tap an app to see its windows. Hold to make it a favorite.",
                    color = Color.White.copy(alpha = 0.7f), fontSize = 12.sp, modifier = Modifier.padding(vertical = 16.dp))
                else MoreActionsNeedControl("Tap an app to see its windows. Request Control for more actions, like opening apps on the Mac.",
                    Modifier.fillMaxWidth().padding(vertical = 16.dp))
            }
        }
    }
}

// MARK: - Edge strip

/** The edge strip: a few dp wide, taking only the touches that start on it. Excluded from the system back gesture. */
@Composable
private fun StripView(strip: CGRect, edge: StagePeekEdge, host: StagePeekHost, onStripFrame: (CGRect?) -> Unit) {
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
                onClick(label = if (machine.isVisible) "Show the highlighted window" else "Show your Mac windows") {
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

/** Lays [content] out at its natural size (up to [maxWidth] dp) centred on ([x], [y]) in the parent; the rest stays transparent to touches. */
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
 * down here is consumed so nothing underneath sees it; a cancelled gesture never selects.
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
    var frame = CGRect.zero
    var isExpanded = false
    var reduceMotion = false
    var windows: List<CatalogWindow> = emptyList()
    var displays: List<CatalogDisplay> = emptyList()
    var onFullDesktop: () -> Unit = {}
    var haptics: (StagePeekHaptic) -> Unit = {}
    var announce: (String) -> Unit = {}
    /** The Mac can close windows from here (swipe left on a compact card). */
    var canClose = false
    /** The Compact Dock's band (null: Normal). */
    var region: CGRect? = null
    var stripOrigin = CGPoint.zero
    var query by mutableStateOf("")
    var appFilter by mutableStateOf<String?>(null)
    var launchpad by mutableStateOf(false)
    var searchFocused = false
    /** A gallery card's drag position (window dp). */
    var dragStart = CGPoint.zero
    /** The gallery card showing its Close Window button (swiped left). */
    var galleryRevealed by mutableStateOf<Long?>(null)
    /** A card's menu (held in place) and Close Window's confirmation (the X): the peek's own dialogs. */
    var menuWindow by mutableStateOf<CatalogWindow?>(null)
    var confirmClose by mutableStateOf<CatalogWindow?>(null)
    private var cardGestureAt = 0L
    /** A card swiped or was held just now: the gallery's own flick ignores that touch. */
    fun markCardGesture() { cardGestureAt = SystemClock.uptimeMillis() }
    fun cardGestureRecent() = SystemClock.uptimeMillis() - cardGestureAt < 800
    private var poll: Job? = null
    /** Compact peek: a still finger on a card lifts it after a moment, then drags it. */
    private var hold: Job? = null
    private var holdTouch: Long? = null
    private var holdStart = CGPoint.zero
    private var cardDragging = false

    fun changed() { revision++ }

    /** Width / height per card, in stack order: a display is a typical screen; a window with no known size is 3:2. */
    fun aspects(): List<Double> = machine.ids.map { id ->
        PeekIDs.displayIndex(id)?.let { i -> displays.getOrNull(i)?.takeIf { it.width > 0 && it.height > 0 }?.let { it.width.toDouble() / it.height } ?: 1.6 }
            ?: windows.firstOrNull { it.id == id }?.takeIf { it.width > 0 && it.height > 0 }?.let { it.width.toDouble() / it.height } ?: 1.5
    }

    /** The cards as laid out from the machine's state right now: what a tap lands on. */
    private fun hitCards() = revealShifted(StagePeekLayout.cards(aspects(), machine.position, machine.expansion, edge, safe, isExpanded, reduceMotion, region))

    /** Hit testing for the compact stack: only inside the Compact Dock's band. */
    private fun hitRegion() = if (machine.expansion < 0.5) region else null

    /** The card whose Close Window shows slides aside to make room for the button. */
    fun revealShifted(cards: List<StagePeekCard>): List<StagePeekCard> {
        val index = machine.closeRevealed?.let { machine.ids.indexOf(it) }?.takeIf { it >= 0 } ?: return cards
        return cards.map { c -> if (c.index == index) c.copy(center = CGPoint(c.center.x - COMPACT_REVEAL, c.center.y)) else c }
    }

    fun hideClose() { machine.hideClose(); changed() }

    private fun window(at: CGPoint) = CGPoint(frame.minX + at.x, frame.minY + at.y)

    private fun itemAt(index: Int): CatalogWindow? {
        val id = machine.ids.getOrNull(index) ?: return null
        PeekIDs.displayIndex(id)?.let { i -> return (displays.getOrNull(i) ?: controller.mainDisplay)?.let(controller::displayWindow) }
        return windows.firstOrNull { it.id == id }
    }

    fun began(id: Long, at: CGPoint, time: Double, onStrip: Boolean) {
        val wasOpen = machine.phase == StagePeekMachine.Phase.Open
        // A compact window card this Mac can close: a swipe left on it reveals Close Window.
        val closable = if (!onStrip && wasOpen && canClose && machine.expansion < 0.5) {
            StagePeekLayout.hit(at, hitCards(), hitRegion())?.takeIf { i -> machine.ids.getOrNull(i)?.let { PeekIDs.displayIndex(it) == null } == true }
        } else null
        machine.touchBegan(id, at, time, onStrip, closable)
        if (machine.phase == StagePeekMachine.Phase.Arming) {
            controller.setStagePeekOpen(true) // fresh catalog and thumbnails while the hold completes
            schedulePoll()
        }
        if (wasOpen && !onStrip && machine.expansion < 0.5) armHold(id, at)
        changed()
    }

    private fun armHold(id: Long, at: CGPoint) {
        hold?.cancel()
        val index = StagePeekLayout.hit(at, hitCards(), hitRegion()) ?: return
        val item = itemAt(index) ?: return
        holdTouch = id; holdStart = at
        hold = scope.launch {
            delay(420)
            if (holdTouch != id || cardDragging) return@launch
            // The touch now belongs to the drag: the peek never selects or scrubs with it.
            machine.touchCancelled(id)
            cardDragging = true
            haptics(StagePeekHaptic.Activate)
            controller.beginDrag(WorkspaceDrag.Item.Window(item), window(at))
            changed()
        }
    }

    fun moved(id: Long, at: CGPoint, time: Double) {
        if (cardDragging && id == holdTouch) { controller.moveDrag(window(at)); return }
        if (id == holdTouch && hypot(at.x - holdStart.x, at.y - holdStart.y) > 10) { hold?.cancel(); holdTouch = null }
        val wasArming = machine.phase == StagePeekMachine.Phase.Arming
        val effects = machine.touchMoved(id, at, time, edge)
        if (wasArming && machine.phase == StagePeekMachine.Phase.Closed) {
            poll?.cancel()
            controller.setStagePeekOpen(false)
        }
        changed()
        perform(effects)
    }

    fun ended(id: Long, at: CGPoint, time: Double) {
        if (id == holdTouch) { hold?.cancel(); holdTouch = null }
        if (cardDragging) {
            cardDragging = false
            controller.moveDrag(window(at))
            dropped(controller.endDrag())
            return
        }
        poll?.cancel()
        val cards = hitCards()
        val region = hitRegion()
        finish(machine.touchEnded(id, at, time) { StagePeekLayout.hit(it, cards, region) })
        if (machine.phase == StagePeekMachine.Phase.Arming) schedulePoll() // another finger lifted; the hold goes on
    }

    /** Dropped on a pane: done. On Cancel or nowhere: the peek comes back as it was. */
    fun dropped(changed: Boolean) {
        if (changed) { haptics(StagePeekHaptic.Select); closeAfterPick() }
        changed()
    }

    /** The system took a touch (a gesture conflict, a fold, focus loss): never selects. */
    fun cancelled(id: Long) {
        if (id == holdTouch) { hold?.cancel(); holdTouch = null }
        if (cardDragging) { cardDragging = false; controller.cancelDrag() }
        poll?.cancel()
        machine.touchCancelled(id)
        finish(emptyList())
    }

    fun cancelAll() {
        poll?.cancel(); hold?.cancel(); holdTouch = null
        menuWindow = null; confirmClose = null; galleryRevealed = null
        if (cardDragging) { cardDragging = false; controller.cancelDrag() }
        machine.cancelAll()
        appFilter = null
        changed()
        controller.setStagePeekOpen(false)
    }

    fun expand() { machine.expand(); changed() }
    fun compact() { machine.compact(); changed() }

    /** TalkBack's next/previous window: opens first if needed, nothing is selected. */
    fun stepFromStrip(delta: Int) {
        if (!machine.isVisible) finish(machine.openDirectly())
        finish(machine.step(delta))
    }

    /** A carousel app: just its windows (tap again for all). An app with no window opens the gallery on its empty state. */
    fun tapApp(app: MacApp, forceFilter: Boolean = false) {
        haptics(StagePeekHaptic.Tick)
        // Finder opens a Finder-like browser here, backed by the Mac (its windows stay one tap away).
        if (app.bundleID in FINDER_BUNDLE_IDS && controller.files.ui.value.available && !forceFilter) {
            controller.finderBundle = app.bundleID
            controller.files.open()
            return
        }
        val clearing = appFilter == app.bundleID && !forceFilter
        appFilter = if (clearing) null else app.bundleID
        val hasWindows = controller.ui.value.catalog?.windows?.any { it.bundleID == app.bundleID } == true
        if (!clearing && (!hasWindows || forceFilter) && machine.isVisible && !machine.expanded) expand()
        changed()
    }

    /** From Launchpad: open the peek (if needed) on that app. */
    fun openApp(app: MacApp) {
        if (!machine.isVisible) finish(machine.openDirectly())
        tapApp(app, forceFilter = true)
    }

    fun pick(w: CatalogWindow) {
        haptics(StagePeekHaptic.Select)
        closeAfterPick()
        controller.switchTo(w)
    }

    /** A display: in Window mode the desktop goes into the pane (a tile source, never a mode switch); in Mirror/Extend it already shows. */
    fun pickDisplay(d: CatalogDisplay?) {
        haptics(StagePeekHaptic.Select)
        closeAfterPick()
        showDisplay(d)
    }

    private fun showDisplay(d: CatalogDisplay?) {
        val display = d ?: controller.mainDisplay
        if (controller.ui.value.windowMode && display != null) controller.switchTo(controller.displayWindow(display)) else onFullDesktop()
    }

    /** Temporary browsing state only; pins, favourites and preferences are untouched. */
    fun resetBrowsing() { query = ""; appFilter = null; launchpad = false }

    fun closeAfterPick() {
        query = ""; appFilter = null
        machine.cancelAll()
        changed()
        controller.setStagePeekOpen(false)
    }

    /** Performs effects, then drops the catalog refresh once nothing shows. */
    fun finish(effects: List<StagePeekEffect>) {
        changed()
        perform(effects)
        if (machine.phase == StagePeekMachine.Phase.Closed) {
            resetBrowsing()
            if (controller.ui.value.stagePeekOpen) controller.setStagePeekOpen(false)
        }
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
                val index = PeekIDs.displayIndex(effect.id)
                if (index != null) showDisplay(displays.getOrNull(index))
                else windows.firstOrNull { it.id == effect.id }?.let { controller.switchTo(it) }
            }
            StagePeekEffect.Dismissed -> controller.setStagePeekOpen(false)
            is StagePeekEffect.RevealClose -> effect.id?.let { rid ->
                windows.firstOrNull { it.id == rid }?.let { announce("Close Window for ${it.title.ifEmpty { it.app }}") }
            }
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
    // It sits over the Mac's menu bar: unanswered, it leaves by itself (as No) after a few
    // seconds, counting only while this screen has focus.
    val focused = LocalWindowInfo.current.isWindowFocused
    val screenReader = rememberScreenReaderRunning()
    val latestNo by androidx.compose.runtime.rememberUpdatedState(onNo)
    LaunchedEffect(focused, screenReader) {
        // With a screen reader the prompt waits for an answer: eight seconds is too short to find it.
        if (!focused || screenReader) return@LaunchedEffect
        delay(WINDOW_PROMPT_TIMEOUT_MS)
        latestNo()
    }
    Row(
        modifier
            .semantics { paneTitle = "Switch to Window view?" }
            .background(Color(0xF0222224), CircleShape)
            .border(0.75.dp, Color.White.copy(alpha = 0.14f), CircleShape)
            .padding(start = 16.dp, end = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("Switch to Window view?", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Text(
            "Yes", color = Color.Black, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
            modifier = Modifier.minimumInteractiveComponentSize().background(StagePeekAccent, CircleShape).clickable(role = Role.Button, onClick = onYes)
                .padding(horizontal = 16.dp, vertical = 8.dp).semantics { contentDescription = "Yes, switch to Window view" },
        )
        Text(
            "No", color = Color.White, fontSize = 15.sp,
            modifier = Modifier.minimumInteractiveComponentSize().border(0.75.dp, Color.White.copy(alpha = 0.3f), CircleShape).clickable(role = Role.Button, onClick = onNo)
                .padding(horizontal = 16.dp, vertical = 8.dp).semantics { contentDescription = "No, stay on the full desktop" },
        )
    }
}

/** How long the unanswered "Switch to Window view?" prompt stays (iOS: same). */
private const val WINDOW_PROMPT_TIMEOUT_MS = 8_000L
