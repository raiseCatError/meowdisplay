package com.raisecaterror.meowdisplay.android.receiver.overlay

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.changedToUp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.raisecaterror.meowdisplay.android.controls.ReceiverControlStore
import com.raisecaterror.meowdisplay.android.receiver.OverlayActions
import com.raisecaterror.meowdisplay.android.receiver.OverlayEnvironment
import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.ControlHapticEvent
import com.raisecaterror.meowdisplay.core.controls.ControlHapticPolicy
import com.raisecaterror.meowdisplay.core.controls.ControlModifier
import com.raisecaterror.meowdisplay.core.controls.ModifierChord
import com.raisecaterror.meowdisplay.core.controls.ShortcutItem
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * MeowDisplay's on-screen control overlay, native Compose (the iOS `ReceiverControlOverlay`):
 * the free-floating circular chips, trays, chord palettes, HUD, iPad rails and radial Custom layout.
 *
 * Mount it ABOVE the video surface, filling the receiver window (its coordinate space is the window,
 * origin top-left, 1 dp = 1 iOS point), only while a stream is live. Only the control frames own
 * touches; every other touch falls through to whatever is below.
 *
 * Presentation: keyboard accessory bar while [OverlayEnvironment.keyboardVisibleRect] is non-null;
 * else the compact iPhone tray when `!environment.expanded`; else the iPad Strip / Overlay / Custom
 * layout chosen by `store.effectivePadLayout`.
 *
 * The host provides [store], a live [environment], the [actions] sink, and bumps [inputResetGeneration]
 * whenever held input must be released (the overlay also releases on profile/layout changes, Settings,
 * and when it leaves composition). The host also owns calling `store.beginAutoHideActivity()` /
 * `scheduleAutoHide()` for touches on the video surface.
 */
@Composable
fun ReceiverControlOverlay(
    store: ReceiverControlStore,
    environment: OverlayEnvironment,
    actions: OverlayActions,
    inputResetGeneration: Int,
    modifier: Modifier = Modifier,
) {
    val prefs by store.preferences.collectAsState()
    val transient by store.transient.collectAsState()
    val actionsState = rememberUpdatedState(actions)
    val reduceMotion = environment.reduceMotion

    val model = remember { ChordModel { sinkFor(actionsState.value, store) } }
    val behavior = remember { OverlayBehavior(store, model) }
    behavior.actions = actions
    // The hold timer (350 ms) runs on the composition's scope; cancelling it is the returned lambda.
    val scope = rememberCoroutineScope()
    val timer = remember {
        HoldTimer { ms, block ->
            val job: Job = scope.launch { delay(ms); block() }
            return@HoldTimer { job.cancel() }
        }
    }

    // One pass: read every input once, build the scene (pure), draw it.
    @Suppress("UNUSED_VARIABLE") val revision = model.revision
    val chord = ChordSnapshot.of(model.interaction, model.paletteAnchor)
    val autoHiding = transient.autoHidden && !environment.screenReaderRunning
    val input = SceneInput(
        env = environment, prefs = prefs, profile = prefs.profile(prefs.activeControlProfile),
        functionProfile = prefs.functionTrayProfile(prefs.activeFunctionTrayProfile),
        layoutMode = store.effectivePadLayout, autoHiding = autoHiding, moveViewActive = transient.moveViewActive,
        chord = chord, interaction = model.interaction,
    )
    val scene = OverlayScenes.build(input)
    SideEffect { behavior.scene = scene }

    val host = remember {
        object : ChordGestureHost {
            override val frames get() = behavior.scene.frames
            override val interactiveItems get() = behavior.scene.interactiveItems
            override val wheelHit get() = behavior.scene.wheelHit
            override fun actionsFor(chord: ModifierChord) = behavior.actionsFor(chord)
            override fun beginActivity() = store.beginAutoHideActivity()
            override fun scheduleHide(interactionIdle: Boolean) = store.scheduleAutoHide(interactionIdle)
            override fun performTray(item: com.raisecaterror.meowdisplay.core.controls.ControlTrayItem) = behavior.performTray(item)
            override fun sendReturn() = behavior.sendReturn()
            override fun toggleMoveView() = behavior.toggleMoveView()
        }
    }
    val controller = remember { ChordGestureController(model, { host }, timer) }

    // Lifecycle: expanded flag, auto-hide, held input (spec 3.1 / 4.2).
    LaunchedEffect(environment.expanded) { store.isExpanded = environment.expanded }
    LaunchedEffect(prefs.autoHideEnabled, prefs.trayCollapsed, prefs.trayCanBeShown, prefs.padControlLayout) { store.resetAutoHide() }
    LaunchedEffect(
        inputResetGeneration, prefs.activeControlProfile, prefs.activeFunctionTrayProfile, store.effectivePadLayout,
        prefs.activeCustomLayoutID,
    ) {
        controller.cancel()
        model.resetAll()
    }
    LaunchedEffect(chord.activeChord.modifiers) { actionsState.value.chordChanged(chord.activeChord.modifiers) }
    LaunchedEffect(scene.occupied) { actionsState.value.occupiedFramesChanged(scene.occupied) }
    LaunchedEffect(scene.canvas) { actionsState.value.canvasChanged(scene.canvas) }
    DisposableEffect(Unit) {
        onDispose {
            controller.cancel()
            model.resetAll()
            actionsState.value.occupiedFramesChanged(emptyList())
            actionsState.value.canvasChanged(null)
            actionsState.value.chordChanged(emptySet())
        }
    }

    val hide by animateFloatAsState(
        if (autoHiding) 1f else 0f,
        tween(if (reduceMotion) 120 else 280, easing = FastOutSlowInEasing), label = "autoHide",
    )
    val animate = !reduceMotion
    val retreat = Offset(scene.retreat.x.toFloat(), scene.retreat.y.toFloat())

    // Coordinates are physical (iOS leading/trailing are given as left/right), so never mirror them.
    CompositionLocalProvider(LocalLayoutDirection provides LayoutDirection.Ltr) {
        Box(modifier.fillMaxSize()) {
            scene.strips.forEach { StripView(it) }
            scene.trays.forEachIndexed { i, tray -> key("tray$i") { ControlTrayView(tray, hide) } }
            scene.paletteTray?.let { ControlTrayView(it, 0f) }
            scene.chips.forEach { chip ->
                key(chip.key) { ChipView(chip, hide, reduceMotion, retreat, autoHiding, behavior::activate) }
            }
            val wheel = scene.wheel
            if (wheel != null) {
                WheelView(wheel, scene.paletteEnterScale, animate) { behavior.finish(it) }
            } else {
                scene.emptyLabel?.let { EmptyLabelView(it) }
                scene.keys.forEach { k ->
                    key(k.action.id) { PaletteKeyView(k, scene.paletteEnterScale, animate) { behavior.finish(k.action) } }
                }
            }
            scene.hud?.let { HudView(it, animate) }
            if (scene.showsMoveBanner) {
                MoveViewBanner(
                    cx = environment.containerSize.width / 2, cy = scene.bannerCenterY,
                    onReset = { actions.resetViewport(); behavior.haptic(ControlHapticEvent.Reset) },
                    onDone = { actions.toggleMoveView(); behavior.haptic(ControlHapticEvent.Selection) },
                )
            }
            // The gesture layer: exactly the union of control frames, one node per rect, all sharing one
            // controller. Compose delivers a pointer to the top-most node hit, so empty space has no
            // pointer node at all and its touches reach the video surface below.
            scene.region.forEach { region -> key(region.key) { RegionGestureBox(region, controller) } }
        }
    }
}

private fun sinkFor(actions: OverlayActions, store: ReceiverControlStore) = object : EffectSink {
    override fun modifier(modifier: ControlModifier, down: Boolean) = actions.modifier(modifier.raw, down)
    override fun execute(item: ShortcutItem) = actions.perform(item)
    override fun haptic(event: ControlHapticEvent) {
        if (ControlHapticPolicy.shouldPlay(event, store.current.hapticsEnabled)) actions.haptic(event)
    }
}

/** One rect of the touch region. A pointer that lands here belongs to [controller] until it lifts, wherever it travels. */
@Composable
private fun RegionGestureBox(region: RegionRect, controller: ChordGestureController) {
    val rect by rememberUpdatedState(region.rect)
    Box(
        Modifier
            .absoluteOffset(region.rect.minX.dp, region.rect.minY.dp)
            .size(region.rect.width.dp, region.rect.height.dp)
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    down.consume()
                    val id = down.id
                    fun point(p: Offset) = CGPoint(rect.minX + p.x / density, rect.minY + p.y / density)
                    if (!controller.down(point(down.position))) {
                        // Another finger owns the chord gesture: this one is not ours to track.
                        return@awaitEachGesture
                    }
                    var finished = false
                    try {
                        while (true) {
                            val event = awaitPointerEvent(PointerEventPass.Main)
                            val change = event.changes.firstOrNull { it.id == id } ?: break
                            if (change.changedToUp()) {
                                change.consume()
                                controller.up(point(change.position))
                                finished = true
                                break
                            }
                            if (!change.pressed) break
                            change.consume()
                            controller.move(point(change.position))
                        }
                    } finally {
                        if (!finished) controller.cancel()
                    }
                }
            },
    )
}
