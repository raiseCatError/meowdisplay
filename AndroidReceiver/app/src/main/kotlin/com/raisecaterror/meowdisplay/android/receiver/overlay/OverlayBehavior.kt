package com.raisecaterror.meowdisplay.android.receiver.overlay

import com.raisecaterror.meowdisplay.android.controls.ReceiverControlStore
import com.raisecaterror.meowdisplay.android.receiver.OverlayActions
import com.raisecaterror.meowdisplay.core.controls.ControlHapticEvent
import com.raisecaterror.meowdisplay.core.controls.ControlHapticPolicy
import com.raisecaterror.meowdisplay.core.controls.ControlInteractionPhase
import com.raisecaterror.meowdisplay.core.controls.ControlModifier
import com.raisecaterror.meowdisplay.core.controls.ControlTrayItem
import com.raisecaterror.meowdisplay.core.controls.ModifierChord
import com.raisecaterror.meowdisplay.core.controls.ShortcutItem
import com.raisecaterror.meowdisplay.core.controls.toggleAssistModifier

/**
 * What each control does (spec 3.5): the gesture's lift, TalkBack activation and
 * the own-tap chips all end up here, and every remote effect leaves through
 * [OverlayActions]. The overlay swaps [actions] and [scene] in as they change.
 */
internal class OverlayBehavior(
    private val store: ReceiverControlStore,
    private val model: ChordModel,
) {
    lateinit var actions: OverlayActions
    var scene: Scene = Scene(Presentation.Phone)

    private val prefs get() = store.current

    fun haptic(event: ControlHapticEvent) {
        if (ControlHapticPolicy.shouldPlay(event, prefs.hapticsEnabled)) actions.haptic(event)
    }

    /** RC `perform(_ item:)`. */
    fun performTray(item: ControlTrayItem) {
        when (item) {
            ControlTrayItem.Escape -> { actions.press(USAGE_ESCAPE); haptic(ControlHapticEvent.Confirmation) }
            ControlTrayItem.Tab -> { actions.press(USAGE_TAB); haptic(ControlHapticEvent.Confirmation) }
            ControlTrayItem.Dock -> { actions.perform(TOGGLE_DOCK); haptic(ControlHapticEvent.Confirmation) }
            ControlTrayItem.Keyboard -> {
                // On the accessory bar the same key closes the keyboard it sits on.
                if (scene.keyboardBar) actions.dismissKeyboard() else actions.toggleKeyboard()
                haptic(ControlHapticEvent.Selection)
            }
            ControlTrayItem.Settings -> {
                model.resetAll()
                actions.openSettings()
                haptic(ControlHapticEvent.Settings)
            }
            else -> Unit
        }
    }

    /** One plain Return press; held latches still apply. Gated like the Function Tray (the Mac enforces the grant again). */
    fun sendReturn() {
        if (!prefs.allowInput) return
        actions.press(USAGE_RETURN)
        haptic(ControlHapticEvent.Confirmation)
    }

    fun toggleMoveView() {
        actions.toggleMoveView()
        haptic(ControlHapticEvent.Selection)
    }

    fun performFunction(item: ShortcutItem) {
        actions.perform(item)
        haptic(ControlHapticEvent.Confirmation)
        store.scheduleAutoHide()
    }

    /** RC `activateForAccessibility`: TalkBack, Voice Access and Switch Access never touch the invisible gesture layer. */
    fun activateTray(item: ControlTrayItem) {
        store.beginAutoHideActivity()
        val modifier = item.modifier
        if (modifier != null) model.run { tap(modifier) } else performTray(item)
        store.scheduleAutoHide(model.interaction.phase == ControlInteractionPhase.Idle)
    }

    fun activate(activation: Activation) {
        when (activation) {
            is Activation.Tray -> activateTray(activation.item)
            Activation.DismissKeyboard -> activateTray(ControlTrayItem.Keyboard)
            Activation.ReturnKey -> sendReturn()
            Activation.MoveView -> toggleMoveView()
            is Activation.Function -> performFunction(activation.item)
            is Activation.AssistModifier -> assistToggle(activation.modifier)
        }
    }

    fun assistToggle(modifier: ControlModifier) {
        model.run { toggleAssistModifier(modifier) }
        store.beginAutoHideActivity()
    }

    fun finish(action: ShortcutItem) = model.run { finish(action) }

    fun actionsFor(chord: ModifierChord): List<ShortcutItem> = store.activeProfile.actions(chord)

    companion object {
        const val USAGE_RETURN = 40
        const val USAGE_ESCAPE = 41
        const val USAGE_TAB = 43

        /** The Dock chip's action (RC `perform(.dock)`): Command+Option+D, sent as one atomic press. */
        val TOGGLE_DOCK = ShortcutItem(
            id = "toggle-dock", title = "Toggle Dock", displayKey = "D", usage = 7,
            modifiers = ModifierChord(setOf(ControlModifier.Option, ControlModifier.Command)),
        )
    }
}
