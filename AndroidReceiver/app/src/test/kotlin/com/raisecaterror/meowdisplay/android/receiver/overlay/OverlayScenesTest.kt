package com.raisecaterror.meowdisplay.android.receiver.overlay

import com.raisecaterror.meowdisplay.android.receiver.OverlayEnvironment
import com.raisecaterror.meowdisplay.core.controls.CGPoint
import com.raisecaterror.meowdisplay.core.controls.CGRect
import com.raisecaterror.meowdisplay.core.controls.CGSize
import com.raisecaterror.meowdisplay.core.controls.ControlInteractionState
import com.raisecaterror.meowdisplay.core.controls.ControlModifier
import com.raisecaterror.meowdisplay.core.controls.ControlSafeInsets
import com.raisecaterror.meowdisplay.core.controls.ControlTrayItem
import com.raisecaterror.meowdisplay.core.controls.PadControlLayoutMode
import com.raisecaterror.meowdisplay.core.controls.ReceiverControlPreferences
import com.raisecaterror.meowdisplay.core.controls.initial
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OverlayScenesTest {
    private fun input(
        env: OverlayEnvironment,
        prefs: ReceiverControlPreferences = ReceiverControlPreferences(),
        interaction: ControlInteractionState = ControlInteractionState(),
        autoHiding: Boolean = false,
        moveView: Boolean = false,
    ): SceneInput {
        val mode = if (prefs.padControlLayout == PadControlLayoutMode.Custom && prefs.customLayouts.isEmpty()) PadControlLayoutMode.Overlay else prefs.padControlLayout
        return SceneInput(
            env, prefs, prefs.profile(prefs.activeControlProfile), prefs.functionTrayProfile(prefs.activeFunctionTrayProfile),
            mode, autoHiding, moveView, ChordSnapshot.of(interaction, null), interaction,
        )
    }

    private val phoneEnv = OverlayEnvironment(
        containerSize = CGSize(390.0, 844.0), safeInsets = ControlSafeInsets(47.0, 0.0, 34.0, 0.0),
        senderPV = 22, keyboardAvailable = true,
    )
    private val tabletEnv = OverlayEnvironment(
        containerSize = CGSize(1150.0, 780.0), safeInsets = ControlSafeInsets(24.0, 0.0, 0.0, 0.0),
        senderPV = 22, keyboardAvailable = true, expanded = true,
    )

    @Test
    fun theIPhoneTrayShrinksNineChipsToFitAndCentersThemAtTheBottom() {
        val scene = OverlayScenes.build(input(phoneEnv))
        assertEquals(Presentation.Phone, scene.presentation)
        val tray = scene.chips.filter { it.hide == HideKind.Retreat && !it.ownTap }
        assertEquals(9, tray.size)
        // fittedChipDiameter(9, 390) = floor((390 - 24 - 4 - 32) / 9) = 36
        assertEquals(36.0, tray.first().frame.width, 0.0)
        assertTrue(tray.all { it.frame.maxY <= phoneEnv.containerSize.height - 12 })
        assertTrue(scene.frames.containsKey("modifier:command"))
        assertTrue(scene.frames.containsKey("tray:more"))
        assertEquals(listOf("tray"), scene.region.map { it.key })
    }

    @Test
    fun autoHidingEmptiesTheTouchRegionButKeepsTheOccupiedFrames() {
        val shown = OverlayScenes.build(input(phoneEnv))
        val hidden = OverlayScenes.build(input(phoneEnv, autoHiding = true))
        assertTrue(hidden.region.isEmpty())
        assertEquals(shown.occupied, hidden.occupied)
    }

    @Test
    fun aLatchedModifierShowsItsPaletteAsAnExtraRegionWithActionFrames() {
        val interaction = ControlInteractionState()
        interaction.tap(ControlModifier.Command)
        val scene = OverlayScenes.build(input(phoneEnv, interaction = interaction))
        assertEquals(listOf("tray", "palette"), scene.region.map { it.key })
        assertEquals(7, scene.keys.size) // Copy Paste Cut Undo Select All Close Spotlight
        assertTrue(scene.frames.keys.any { it.startsWith("action:") })
        assertTrue(scene.chips.first { it.key == "modifier:command" }.selected)
        // The latched chip's frame inside the tray.
        val cmd = scene.frames["modifier:command"]!!
        assertTrue(scene.region[0].rect.contains(CGPoint(cmd.midX, cmd.midY)))
    }

    @Test
    fun theHudShowsTheLiveChordNotTheStoredOne() {
        val interaction = ControlInteractionState()
        interaction.tap(ControlModifier.Command)
        val copy = OverlayScenes.build(input(phoneEnv, interaction = interaction)).keys.first { it.action.title == "Copy" }.action
        interaction.selectAction(copy.id)
        val scene = OverlayScenes.build(input(phoneEnv, interaction = interaction))
        assertEquals("⌘C", scene.hud?.text)
    }

    @Test
    fun withoutInputTheTrayReducesToTheGearAndTheOldMacHasNoModifiers() {
        val prefs = ReceiverControlPreferences().also { it.allowInput = false }
        val scene = OverlayScenes.build(input(phoneEnv, prefs))
        assertEquals(listOf(ControlTrayItem.Settings), scene.interactiveItems)
        assertEquals(1, scene.chips.count { !it.ownTap })
        val old = OverlayScenes.build(input(phoneEnv.copy(senderPV = 5)))
        assertTrue(old.chips.none { it.key.startsWith("modifier:") })
    }

    @Test
    fun theKeyboardBarReplacesEverythingAndSitsAboveTheKeyboard() {
        val env = phoneEnv.copy(keyboardVisibleRect = CGRect(0.0, 0.0, 390.0, 500.0))
        val scene = OverlayScenes.build(input(env))
        assertEquals(Presentation.KeyboardBar, scene.presentation)
        assertEquals(listOf("modifier:command", "modifier:option", "modifier:control", "modifier:shift", "tray:escape", "tray:tab", "control:return", "tray:keyboard"), scene.chips.map { it.key })
        assertTrue(scene.chips.all { it.frame.maxY <= 500.0 - 8 })
        assertTrue(scene.chips.none { it.hide != HideKind.None })
        assertEquals("bar", scene.region.single().key)
    }

    @Test
    fun theStripReservesARailAndReportsTheCanvasBesideIt() {
        val prefs = ReceiverControlPreferences() // Strip, main on the trailing edge
        val scene = OverlayScenes.build(input(tabletEnv, prefs))
        assertEquals(Presentation.Strip, scene.presentation)
        assertTrue(scene.strips.isNotEmpty())
        val canvas = scene.canvas!!
        assertTrue(canvas.width < 1150.0)
        assertTrue(scene.chips.none { it.hide != HideKind.None }) // the Strip never auto-hides
        assertTrue(scene.frames.containsKey("modifier:command"))
    }

    @Test
    fun theOverlayLayoutHasNoCanvasAndFloatsTrays() {
        val prefs = ReceiverControlPreferences().also { it.padControlLayout = PadControlLayoutMode.Overlay }
        val scene = OverlayScenes.build(input(tabletEnv, prefs))
        assertEquals(Presentation.Overlay, scene.presentation)
        assertNull(scene.canvas)
        assertTrue(scene.trays.isNotEmpty() && scene.trays.all { it.hideable })
        assertTrue(scene.chips.all { it.hide == HideKind.Fade })
    }

    @Test
    fun oneTapChipsAreOutsideTheGestureRegion() {
        val prefs = ReceiverControlPreferences().also { it.padControlLayout = PadControlLayoutMode.Overlay }
        val scene = OverlayScenes.build(input(tabletEnv, prefs))
        val ownTap = scene.chips.filter { it.ownTap }
        assertTrue(ownTap.isNotEmpty())
        for (chip in ownTap) {
            val c = CGPoint(chip.frame.midX, chip.frame.midY)
            assertFalse("${chip.key} must not be in the region", scene.region.any { it.rect.contains(c) })
        }
    }

    @Test
    fun theRadialCustomLayoutPlacesSettingsAndFourModifiersAndOnlySettingsSurvivesAutoHide() {
        val prefs = ReceiverControlPreferences.initial(isPad = true)
        val scene = OverlayScenes.build(input(tabletEnv, prefs))
        assertEquals(Presentation.Custom, scene.presentation)
        assertEquals(4, scene.chips.count { it.key.startsWith("modifier:") })
        val settings = scene.chips.first { it.key == "tray:more" }
        assertTrue(scene.chips.filter { it.frame.width > 0 }.all { it.frame.minX >= 0 && it.frame.maxX <= 1150.0 && it.frame.maxY <= 780.0 })

        val hidden = OverlayScenes.build(input(tabletEnv, prefs, autoHiding = true))
        assertEquals(1, hidden.region.size)
        assertTrue(hidden.region.single().rect.contains(CGPoint(settings.frame.midX, settings.frame.midY)))
        assertEquals(HideKind.None, hidden.chips.first { it.key == "tray:more" }.hide)
        assertTrue(hidden.chips.filter { it.key != "tray:more" }.all { it.hide == HideKind.Fade })
    }

    @Test
    fun aLatchedModifierBloomsItsCustomPaletteKeysAsRegionsAroundTheLayout() {
        val prefs = ReceiverControlPreferences.initial(isPad = true)
        val interaction = ControlInteractionState()
        interaction.tap(ControlModifier.Command)
        val scene = OverlayScenes.build(input(tabletEnv, prefs, interaction))
        assertTrue(scene.keys.isNotEmpty())
        assertEquals(scene.keys.size, scene.region.count { it.key.startsWith("key:") })
        assertEquals(scene.keys.size, scene.frames.keys.count { it.startsWith("action:") })
    }

    @Test
    fun moveViewBannerOnlyOnExpandedPresentations() {
        assertFalse(OverlayScenes.build(input(phoneEnv, moveView = true)).showsMoveBanner)
        assertTrue(OverlayScenes.build(input(tabletEnv, moveView = true)).showsMoveBanner)
    }
}
