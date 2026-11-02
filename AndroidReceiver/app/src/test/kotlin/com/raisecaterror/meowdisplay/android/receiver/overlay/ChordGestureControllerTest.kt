package com.raisecaterror.meowdisplay.android.receiver.overlay

import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.ControlHapticEvent
import com.raisecaterror.meowdisplay.core.controls.ControlInteractionPhase
import com.raisecaterror.meowdisplay.core.controls.ControlModifier
import com.raisecaterror.meowdisplay.core.controls.ControlTrayItem
import com.raisecaterror.meowdisplay.core.controls.ModifierChord
import com.raisecaterror.meowdisplay.core.controls.ShortcutItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Swift `controlGesture` semantics, driven with synthetic pointer positions and a manual hold timer. */
class ChordGestureControllerTest {
    private val copy = ShortcutItem(id = "copy", title = "Copy", displayKey = "C", usage = 6, modifiers = ModifierChord(setOf(ControlModifier.Command)))
    private val paste = ShortcutItem(id = "paste", title = "Paste", displayKey = "V", usage = 25, modifiers = ModifierChord(setOf(ControlModifier.Command)))

    private val log = mutableListOf<String>()
    private val sink = object : EffectSink {
        override fun modifier(modifier: ControlModifier, down: Boolean) { log += "${modifier.raw}:${if (down) "down" else "up"}" }
        override fun execute(item: ShortcutItem) { log += "run:${item.id}" }
        override fun haptic(event: ControlHapticEvent) { log += "haptic:${event.raw}" }
    }
    private val model = ChordModel { sink }

    private var hold: (() -> Unit)? = null
    private var holdCancelled = false
    private val timer = HoldTimer { ms, block ->
        assertEquals(350L, ms)
        hold = block
        holdCancelled = false
        return@HoldTimer { holdCancelled = true; hold = null }
    }
    private fun fireHold() { hold?.invoke() }

    private val performed = mutableListOf<ControlTrayItem>()
    private var returns = 0
    private var hides = 0
    private val frames = mapOf(
        "modifier:command" to CGRect(0.0, 100.0, 40.0, 40.0),
        "modifier:option" to CGRect(44.0, 100.0, 40.0, 40.0),
        "tray:escape" to CGRect(88.0, 100.0, 40.0, 40.0),
        "control:return" to CGRect(132.0, 100.0, 40.0, 40.0),
        "action:copy" to CGRect(0.0, 40.0, 38.0, 38.0),
        "action:paste" to CGRect(43.0, 40.0, 38.0, 38.0),
    )
    private val host = object : ChordGestureHost {
        override val frames get() = this@ChordGestureControllerTest.frames
        override val interactiveItems = listOf(ControlTrayItem.Command, ControlTrayItem.Option, ControlTrayItem.Escape)
        override val wheelHit: WheelHit? = null
        override fun actionsFor(chord: ModifierChord) = if (ControlModifier.Command in chord.modifiers) listOf(copy, paste) else emptyList()
        override fun beginActivity() { log += "activity" }
        override fun scheduleHide(interactionIdle: Boolean) { hides++ }
        override fun performTray(item: ControlTrayItem) { performed += item }
        override fun sendReturn() { returns++ }
        override fun toggleMoveView() {}
    }
    private val controller = ChordGestureController(model, { host }, timer)

    private fun pt(x: Double, y: Double) = CGPoint(x, y)
    private val onCommand = pt(20.0, 120.0)
    private val onOption = pt(60.0, 120.0)
    private val onCopy = pt(10.0, 50.0)
    private val onPaste = pt(60.0, 50.0)

    @Test
    fun aQuickTapOnAModifierLatchesWhereverTheFingerLifts() {
        assertTrue(controller.down(onCommand))
        assertEquals(ControlInteractionPhase.Pressed(ControlModifier.Command), model.interaction.phase)
        controller.up(pt(300.0, 300.0))
        assertEquals(setOf(ControlModifier.Command), model.interaction.latchedModifiers)
        assertTrue(holdCancelled)
        assertEquals(listOf("activity", "command:down", "haptic:latch"), log)
        // The latched chord keeps its palette on screen.
        assertEquals(ModifierChord(setOf(ControlModifier.Command)), model.interaction.paletteChord)
    }

    @Test
    fun holdingOpensATransientPaletteAndLiftingOnTheHighlightedKeyRunsItThenReleases() {
        controller.down(onCommand)
        fireHold()
        assertTrue(model.interaction.phase is ControlInteractionPhase.Palette)
        controller.move(onCopy)
        assertEquals("copy", model.interaction.selectedActionID)
        controller.up(onCopy)
        assertEquals(listOf("activity", "command:down", "haptic:selection", "haptic:selection", "run:copy", "haptic:confirmation", "command:up"), log)
        assertEquals(ControlInteractionPhase.Idle, model.interaction.phase)
        assertTrue(model.interaction.latchedModifiers.isEmpty())
    }

    @Test
    fun slidingOffTheHighlightedKeyBeforeLiftingCancelsIt() {
        controller.down(onCommand)
        fireHold()
        controller.move(onCopy)
        controller.up(pt(300.0, 300.0))
        assertFalse(log.any { it.startsWith("run:") })
        assertTrue(log.contains("command:up"))
    }

    @Test
    fun slidingOntoAnotherModifierDuringAHoldAddsItToTheChord() {
        controller.down(onCommand)
        fireHold()
        controller.move(onOption)
        assertEquals(setOf(ControlModifier.Command, ControlModifier.Option), model.interaction.temporaryModifiers)
        // Sliding back off never drops it.
        controller.move(onCopy)
        assertEquals(setOf(ControlModifier.Command, ControlModifier.Option), model.interaction.temporaryModifiers)
    }

    @Test
    fun aLatchedPaletteIsBrowsedByPressingAKeyAndKeepsTheLatch() {
        controller.down(onCommand); controller.up(onCommand)
        log.clear()
        assertTrue(controller.down(onPaste))
        assertEquals("paste", model.interaction.selectedActionID)
        controller.up(onPaste)
        assertEquals(listOf("activity", "haptic:selection", "run:paste", "haptic:confirmation"), log)
        assertEquals(setOf(ControlModifier.Command), model.interaction.latchedModifiers)
    }

    @Test
    fun aPlainTrayButtonFiresOnlyWhenLiftedOnTheSameFrame() {
        controller.down(pt(100.0, 120.0)); controller.up(pt(100.0, 121.0))
        assertEquals(listOf(ControlTrayItem.Escape), performed)
        controller.down(pt(100.0, 120.0)); controller.up(pt(100.0, 200.0))
        assertEquals(listOf(ControlTrayItem.Escape), performed)
    }

    @Test
    fun returnFiresOnLiftInsideItsFrame() {
        controller.down(pt(150.0, 120.0)); controller.up(pt(150.0, 120.0))
        assertEquals(1, returns)
    }

    @Test
    fun aSecondFingerDoesNotStealOrEndTheGesture() {
        assertTrue(controller.down(onCommand))
        assertFalse(controller.down(onOption))
        assertTrue(controller.isActive)
    }

    @Test
    fun aCancelledStreamReleasesTemporariesAndFiresNothing() {
        controller.down(onCommand)
        fireHold()
        controller.cancel()
        assertFalse(log.any { it.startsWith("run:") })
        assertTrue(log.contains("command:up"))
        assertFalse(controller.isActive)
        assertNull(model.interaction.selectedActionID)
    }

    @Test
    fun liftingElsewhereWithAnOpenPaletteDropsTemporariesButKeepsLatches() {
        controller.down(onCommand); controller.up(onCommand)
        controller.down(pt(300.0, 300.0))
        controller.up(pt(300.0, 300.0))
        assertEquals(setOf(ControlModifier.Command), model.interaction.latchedModifiers)
        assertEquals(2, hides)
    }
}
