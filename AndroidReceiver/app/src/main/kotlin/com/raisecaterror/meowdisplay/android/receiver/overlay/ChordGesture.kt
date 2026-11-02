package com.raisecaterror.meowdisplay.android.receiver.overlay

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.ControlInteractionEffect
import com.raisecaterror.meowdisplay.core.controls.ControlInteractionPhase
import com.raisecaterror.meowdisplay.core.controls.ControlInteractionState
import com.raisecaterror.meowdisplay.core.controls.ControlModifier
import com.raisecaterror.meowdisplay.core.controls.ControlTrayItem
import com.raisecaterror.meowdisplay.core.controls.ModifierChord
import com.raisecaterror.meowdisplay.core.controls.ShortcutItem
import com.raisecaterror.meowdisplay.core.controls.WheelPaletteLayout

/** What a [ChordModel] does with the interaction state machine's effects (the overlay maps them onto OverlayActions). */
internal interface EffectSink {
    fun modifier(modifier: ControlModifier, down: Boolean)
    fun execute(item: ShortcutItem)
    fun haptic(event: com.raisecaterror.meowdisplay.core.controls.ControlHapticEvent)
}

/**
 * The chord state machine plus a Compose-observable revision. [ControlInteractionState]
 * is a plain mutable object; every change goes through [run] / [touch], which
 * applies its effects and bumps [revision] so composables that read it redraw.
 */
internal class ChordModel(private val sink: () -> EffectSink) {
    val interaction = ControlInteractionState()

    var revision by mutableIntStateOf(0)
        private set

    /** The modifier whose press began the palette (the Wheel / Custom palette anchors on it). */
    var paletteAnchor by mutableStateOf<ControlModifier?>(null)

    /** Runs a state-machine call and applies its effects in order. */
    fun run(call: ControlInteractionState.() -> List<ControlInteractionEffect>) {
        apply(interaction.call())
    }

    /** A state change with no effects (press). */
    fun touch(call: ControlInteractionState.() -> Unit) {
        interaction.call()
        revision++
    }

    fun apply(effects: List<ControlInteractionEffect>) {
        val out = sink()
        for (effect in effects) when (effect) {
            is ControlInteractionEffect.ModifierDown -> out.modifier(effect.modifier, true)
            is ControlInteractionEffect.ModifierUp -> out.modifier(effect.modifier, false)
            is ControlInteractionEffect.Execute -> out.execute(effect.item)
            is ControlInteractionEffect.Haptic -> out.haptic(effect.event)
        }
        revision++
    }

    /** Releases everything held (every interruption in spec 3.1) and forgets the anchor. */
    fun resetAll() {
        paletteAnchor = null
        run { resetAll() }
    }
}

/** A read-only copy of the chord state for one composition pass (the scene builders are pure). */
internal data class ChordSnapshot(
    val phase: ControlInteractionPhase = ControlInteractionPhase.Idle,
    val latched: Set<ControlModifier> = emptySet(),
    val temporary: Set<ControlModifier> = emptySet(),
    val selectedActionID: String? = null,
    val paletteChord: ModifierChord? = null,
    val activeChord: ModifierChord = ModifierChord(),
    val paletteAnchor: ControlModifier? = null,
) {
    fun isHeld(modifier: ControlModifier) = modifier in latched || modifier in temporary

    /** Pad and keyboard-bar chips light as soon as the finger is down; the phone tray waits for the hold. */
    fun isHeldOrPressed(modifier: ControlModifier) = isHeld(modifier) || (phase as? ControlInteractionPhase.Pressed)?.modifier == modifier

    companion object {
        fun of(interaction: ControlInteractionState, anchor: ControlModifier?) = ChordSnapshot(
            phase = interaction.phase,
            latched = interaction.latchedModifiers,
            temporary = interaction.temporaryModifiers,
            selectedActionID = interaction.selectedActionID,
            paletteChord = interaction.paletteChord,
            activeChord = interaction.activeChord,
            paletteAnchor = anchor,
        )
    }
}

/** The wheel as the gesture hit-tests it: its geometry and the actions it was drawn for. */
internal class WheelHit(val layout: WheelPaletteLayout, val actionIDs: List<String>)

/** Everything the chord gesture reads from the current scene and acts on. */
internal interface ChordGestureHost {
    val frames: Map<String, CGRect>
    val interactiveItems: List<ControlTrayItem>
    val wheelHit: WheelHit?
    fun actionsFor(chord: ModifierChord): List<ShortcutItem>
    fun beginActivity()
    fun scheduleHide(interactionIdle: Boolean)
    fun performTray(item: ControlTrayItem)
    fun sendReturn()
    fun toggleMoveView()
}

/** Starts a one-shot timer; the returned function cancels it. */
internal fun interface HoldTimer {
    fun start(delayMs: Long, block: () -> Unit): () -> Unit
}

/** Frame-id hit testing, identical to the Swift `trayItem(at:)` / `modifier(at:)` / `action(at:)`. */
internal object ChordHitTesting {
    fun trayItem(point: CGPoint, items: List<ControlTrayItem>, frames: Map<String, CGRect>): ControlTrayItem? =
        items.firstOrNull { item ->
            val id = item.modifier?.let { "modifier:${it.raw}" } ?: "tray:${item.raw}"
            frames[id]?.contains(point) == true
        }

    fun modifier(point: CGPoint, frames: Map<String, CGRect>): ControlModifier? =
        ControlModifier.entries.firstOrNull { frames["modifier:${it.raw}"]?.contains(point) == true }

    /** The wheel wins only while it was drawn for exactly the live chord's actions; otherwise exact key frames. */
    fun action(point: CGPoint, actions: List<ShortcutItem>, frames: Map<String, CGRect>, wheel: WheelHit?): ShortcutItem? {
        if (wheel != null && wheel.actionIDs == actions.map { it.id }) {
            wheel.layout.segmentIndex(point)?.let { return actions.getOrNull(it) }
        }
        return actions.firstOrNull { frames["action:${it.id}"]?.contains(point) == true }
    }
}

/**
 * The single drag gesture of every presentation (spec 3.2, RC controlGesture).
 * Pure: the Compose layer only forwards pointer positions (already in overlay
 * dp). One pointer at a time, no touch slop, hold = 350 ms, tap latches on lift
 * wherever the finger lifted, other chips fire only if lifted on the same frame.
 */
internal class ChordGestureController(
    private val model: ChordModel,
    private val host: () -> ChordGestureHost,
    private val timer: HoldTimer,
) {
    private var active = false
    private var initiatingItem: ControlTrayItem? = null
    private var initiatingModifier: ControlModifier? = null
    private var initiatingMoveView = false
    private var initiatingReturn = false
    private var lastHovered: ControlModifier? = null
    private var cancelHold: (() -> Unit)? = null

    val isActive: Boolean get() = active

    /** Starts tracking; false when another pointer already owns the gesture (the caller must then ignore this one). */
    fun down(point: CGPoint): Boolean {
        if (active) return false
        active = true
        val h = host()
        h.beginActivity()
        val item = ChordHitTesting.trayItem(point, h.interactiveItems, h.frames)
        initiatingItem = item
        initiatingMoveView = item == null && h.frames["control:moveView"]?.contains(point) == true
        initiatingReturn = item == null && h.frames["control:return"]?.contains(point) == true
        val modifier = item?.modifier
        if (modifier != null) {
            initiatingModifier = modifier
            model.paletteAnchor = modifier
            model.touch { press(modifier) }
            cancelHold?.invoke()
            cancelHold = timer.start(HOLD_MS) {
                if (model.interaction.phase == ControlInteractionPhase.Pressed(modifier)) model.run { beginPalette(modifier) }
            }
        } else {
            val action = currentAction(point, h)
            if (action != null) model.run { selectAction(action.id) }
        }
        track(point)
        return true
    }

    fun move(point: CGPoint) {
        if (active) track(point)
    }

    private fun track(point: CGPoint) {
        val h = host()
        // Sliding onto another modifier only builds a chord during a hold; a latched palette is browsed, not rebuilt.
        if (model.interaction.phase is ControlInteractionPhase.Palette) {
            val hovered = ChordHitTesting.modifier(point, h.frames)
            if (hovered != lastHovered) {
                lastHovered = hovered
                if (hovered != null) model.run { addTemporaryModifier(hovered) }
            }
        }
        // Highlight tracking runs for any visible palette except when the gesture began on a plain tray button.
        if (model.interaction.paletteChord != null && (initiatingItem?.modifier != null || initiatingItem == null)) {
            val id = currentAction(point, h)?.id
            model.run { selectAction(id) }
        }
    }

    fun up(point: CGPoint) {
        if (!active) return
        cancelHold?.invoke()
        cancelHold = null
        val h = host()
        val interaction = model.interaction
        val under = currentAction(point, h)
        val finishedOn = under?.takeIf { it.id == interaction.selectedActionID }
        val modifier = initiatingModifier
        val item = initiatingItem
        if (modifier != null) {
            if (interaction.phase == ControlInteractionPhase.Pressed(modifier)) model.run { tap(modifier) }
            else model.run { finish(finishedOn) }
        } else if (finishedOn != null) {
            model.run { finish(finishedOn) }
        } else if (item != null && h.frames["tray:${item.raw}"]?.contains(point) == true) {
            h.performTray(item)
        } else if (initiatingReturn && h.frames["control:return"]?.contains(point) == true) {
            h.sendReturn()
        } else if (initiatingMoveView && h.frames["control:moveView"]?.contains(point) == true) {
            h.toggleMoveView()
        } else if (interaction.paletteChord != null) {
            model.run { finish(null) }
        }
        reset()
        h.scheduleHide(model.interaction.phase == ControlInteractionPhase.Idle)
    }

    /** The pointer stream ended without a lift (system cancel, node left composition): drop temporaries, fire nothing. */
    fun cancel() {
        if (!active) return
        cancelHold?.invoke()
        cancelHold = null
        model.run { cancelTemporary() }
        reset()
        host().scheduleHide(model.interaction.phase == ControlInteractionPhase.Idle)
    }

    private fun reset() {
        initiatingModifier = null
        initiatingItem = null
        initiatingMoveView = false
        initiatingReturn = false
        lastHovered = null
        active = false
    }

    private fun currentAction(point: CGPoint, h: ChordGestureHost): ShortcutItem? =
        ChordHitTesting.action(point, h.actionsFor(model.interaction.activeChord), h.frames, h.wheelHit)

    companion object {
        const val HOLD_MS = 350L
    }
}
