package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/ControlInteraction.swift.

sealed interface ControlInteractionPhase {
    data object Idle : ControlInteractionPhase
    data class Pressed(val modifier: ControlModifier) : ControlInteractionPhase
    data class Latched(val chord: ModifierChord) : ControlInteractionPhase
    data class Palette(val active: ModifierChord, val selectedActionID: String?) : ControlInteractionPhase
    data object Executing : ControlInteractionPhase
    data object Cancelled : ControlInteractionPhase
}

sealed interface ControlInteractionEffect {
    data class ModifierDown(val modifier: ControlModifier) : ControlInteractionEffect
    data class ModifierUp(val modifier: ControlModifier) : ControlInteractionEffect
    data class Execute(val item: ShortcutItem) : ControlInteractionEffect
    data class Haptic(val event: ControlHapticEvent) : ControlInteractionEffect
}

enum class ControlHapticEvent(val raw: String) {
    Selection("selection"),
    Latch("latch"),
    Confirmation("confirmation"),
    ExpandCollapse("expandCollapse"),
    ProfileChange("profileChange"),
    Reset("reset"),
    Settings("settings"),
}

object ControlHapticPolicy {
    @Suppress("UNUSED_PARAMETER")
    fun shouldPlay(event: ControlHapticEvent, enabled: Boolean): Boolean = enabled
}

/**
 * Smart Touch hold haptics play only while both the global Haptics setting and
 * Smart Touch Haptics are on. Either switch only silences feedback.
 */
object SmartTouchHapticPolicy {
    fun isEnabled(haptics: Boolean, smartTouchHaptics: Boolean): Boolean = haptics && smartTouchHaptics
}

/** Pure state machine for tap-to-latch and hold/slide shortcut chords. */
data class ControlInteractionState(
    var phase: ControlInteractionPhase = ControlInteractionPhase.Idle,
    var latchedModifiers: Set<ControlModifier> = emptySet(),
    var temporaryModifiers: Set<ControlModifier> = emptySet(),
    var selectedActionID: String? = null,
) {
    val activeChord: ModifierChord get() = ModifierChord(latchedModifiers + temporaryModifiers)

    /**
     * Persistent for a latched chord and transient for a hold/slide chord.
     * Derived from state (not a view timer) so a harmless finger-up never
     * dismisses a latched menu.
     */
    val paletteChord: ModifierChord?
        get() = when (val p = phase) {
            is ControlInteractionPhase.Latched -> p.chord
            is ControlInteractionPhase.Pressed -> if (latchedModifiers.isNotEmpty()) ModifierChord(latchedModifiers) else null
            is ControlInteractionPhase.Palette -> p.active
            else -> null
        }

    fun press(modifier: ControlModifier) {
        phase = ControlInteractionPhase.Pressed(modifier)
    }

    fun tap(modifier: ControlModifier): List<ControlInteractionEffect> {
        temporaryModifiers = emptySet()
        selectedActionID = null
        val effect: ControlInteractionEffect
        if (modifier in latchedModifiers) {
            latchedModifiers = latchedModifiers - modifier
            effect = ControlInteractionEffect.ModifierUp(modifier)
        } else {
            latchedModifiers = latchedModifiers + modifier
            effect = ControlInteractionEffect.ModifierDown(modifier)
        }
        phase = settledPhase()
        return listOf(effect, ControlInteractionEffect.Haptic(ControlHapticEvent.Latch))
    }

    fun beginPalette(modifier: ControlModifier): List<ControlInteractionEffect> {
        selectedActionID = null
        val effects = mutableListOf<ControlInteractionEffect>()
        if (modifier !in latchedModifiers) {
            temporaryModifiers = temporaryModifiers + modifier
            effects += ControlInteractionEffect.ModifierDown(modifier)
        }
        phase = ControlInteractionPhase.Palette(activeChord, null)
        effects += ControlInteractionEffect.Haptic(ControlHapticEvent.Selection)
        return effects
    }

    fun updateTemporaryChord(touched: Set<ControlModifier>): List<ControlInteractionEffect> {
        val desired = touched - latchedModifiers
        val effects = mutableListOf<ControlInteractionEffect>()
        effects += ordered(temporaryModifiers - desired).map(ControlInteractionEffect::ModifierUp)
        effects += ordered(desired - temporaryModifiers).map(ControlInteractionEffect::ModifierDown)
        if (desired != temporaryModifiers) effects += ControlInteractionEffect.Haptic(ControlHapticEvent.Selection)
        temporaryModifiers = desired
        phase = ControlInteractionPhase.Palette(activeChord, selectedActionID)
        return effects
    }

    /**
     * Adds a modifier crossed by the same continuous hold gesture. Idempotent
     * so stationary drag samples can't build up haptics or duplicate downs.
     */
    fun addTemporaryModifier(modifier: ControlModifier): List<ControlInteractionEffect> {
        if (modifier in latchedModifiers || modifier in temporaryModifiers) return emptyList()
        temporaryModifiers = temporaryModifiers + modifier
        phase = ControlInteractionPhase.Palette(activeChord, selectedActionID)
        return listOf(ControlInteractionEffect.ModifierDown(modifier), ControlInteractionEffect.Haptic(ControlHapticEvent.Selection))
    }

    fun selectAction(id: String?): List<ControlInteractionEffect> {
        if (id == selectedActionID) return emptyList()
        selectedActionID = id
        phase = ControlInteractionPhase.Palette(activeChord, id)
        return listOf(ControlInteractionEffect.Haptic(ControlHapticEvent.Selection))
    }

    fun finish(action: ShortcutItem?): List<ControlInteractionEffect> {
        val effects = mutableListOf<ControlInteractionEffect>()
        if (action != null) {
            phase = ControlInteractionPhase.Executing
            effects += ControlInteractionEffect.Execute(action)
            effects += ControlInteractionEffect.Haptic(ControlHapticEvent.Confirmation)
        }
        effects += ordered(temporaryModifiers).map(ControlInteractionEffect::ModifierUp)
        temporaryModifiers = emptySet()
        selectedActionID = null
        phase = settledPhase()
        return effects
    }

    fun cancelTemporary(): List<ControlInteractionEffect> {
        val effects = ordered(temporaryModifiers).map(ControlInteractionEffect::ModifierUp)
        temporaryModifiers = emptySet()
        selectedActionID = null
        phase = settledPhase()
        return effects
    }

    fun resetAll(): List<ControlInteractionEffect> {
        val held = latchedModifiers + temporaryModifiers
        latchedModifiers = emptySet()
        temporaryModifiers = emptySet()
        selectedActionID = null
        phase = ControlInteractionPhase.Cancelled
        val effects = ordered(held).map(ControlInteractionEffect::ModifierUp)
        phase = ControlInteractionPhase.Idle
        return effects
    }

    private fun settledPhase(): ControlInteractionPhase =
        if (latchedModifiers.isEmpty()) ControlInteractionPhase.Idle else ControlInteractionPhase.Latched(ModifierChord(latchedModifiers))

    private fun ordered(modifiers: Set<ControlModifier>) = ControlModifier.ordered(modifiers)
}
