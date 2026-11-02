package com.raisecaterror.meowdisplay.core.controls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CustomizationEditingTest {
    private val layout = CustomControlLayout.radialTemplate(id = "L", name = "Layout 1")
    private val landscape get() = layout.landscape
    private val settings = CustomControlKind.Tray(ControlTrayItem.Settings)

    @Test
    fun settingsCanNeverBeRemoved() {
        val id = landscape.placements.first { it.kind == settings }.id
        assertFalse(CustomLayoutEditing.isRemovable(settings))
        assertEquals(landscape, CustomLayoutEditing.remove(landscape, id))
        val escape = landscape.placements.first { it.kind == CustomControlKind.Tray(ControlTrayItem.Escape) }
        assertTrue(CustomLayoutEditing.remove(landscape, escape.id).placements.none { it.id == escape.id })
    }

    @Test
    fun builtInControlsAppearOncePerOrientationShortcutsAnyNumberOfTimes() {
        assertNull("Escape is already placed", CustomLayoutEditing.add(landscape, CustomControlKind.Tray(ControlTrayItem.Escape)))
        val shortcut = CustomControlKind.Shortcut(ShortcutDraft.keyboard("S", "", setOf(ControlModifier.Command), listOf(6), null))
        val (once, _) = CustomLayoutEditing.add(landscape, shortcut, id = "a")!!
        val (twice, id) = CustomLayoutEditing.add(once, shortcut, id = "b")!!
        assertEquals("b", id)
        assertEquals(landscape.placements.size + 2, twice.placements.size)
        val added = twice.placements.last()
        assertEquals("new controls start at the center", 0.5 to 0.5, added.x to added.y)
    }

    @Test
    fun movesAndSizesAreClampedLikeTheStoredModel() {
        val id = landscape.placements.first().id
        val moved = CustomLayoutEditing.move(landscape, id, NormalizedPosition(1.4, -2.0)).placements.first()
        assertEquals(1.0 to 0.0, moved.x to moved.y)
        val big = CustomLayoutEditing.resize(landscape, id, 9.0).placements.first()
        assertEquals(CustomControlPlacement.sizeRange.endInclusive, big.size, 0.0)
        val small = CustomLayoutEditing.resize(landscape, id, 0.1).placements.first()
        assertEquals(CustomControlPlacement.sizeRange.start, small.size, 0.0)
    }

    @Test
    fun paletteStyleOnlyForModifiersAndClamped() {
        val command = landscape.placements.first { it.kind.modifier == ControlModifier.Command }
        val styled = CustomLayoutEditing.restyle(landscape, command.id) { it.copy(spacing = 5.0, directionDegrees = 400.0) }
            .placements.first { it.id == command.id }.palette!!
        assertEquals(PalettePresentation.spacingRange.endInclusive, styled.spacing, 0.0)
        assertEquals(180.0, styled.directionDegrees!!, 0.0)
        val center = CustomLayoutEditing.restyle(landscape, command.id) { it.copy(directionDegrees = null) }
            .placements.first { it.id == command.id }.palette!!
        assertNull("Toward Screen Center", center.directionDegrees)
        val escape = landscape.placements.first { it.kind == CustomControlKind.Tray(ControlTrayItem.Escape) }
        assertEquals(landscape, CustomLayoutEditing.restyle(landscape, escape.id) { it.copy(spacing = 2.0) })
    }

    @Test
    fun shortcutPlacementsAreEditedInPlace() {
        val first = ShortcutDraft.keyboard("S", "", setOf(ControlModifier.Command), listOf(6), null)
        val (added, id) = CustomLayoutEditing.setShortcut(landscape, null, first)!!
        val edited = ShortcutDraft.keyboard("S", "Paste", setOf(ControlModifier.Command), listOf(25), null)
        val (replaced, sameID) = CustomLayoutEditing.setShortcut(added, id, edited)!!
        assertEquals(id, sameID)
        assertEquals(added.placements.size, replaced.placements.size)
        assertEquals("Paste", (replaced.placements.first { it.id == id }.kind as CustomControlKind.Shortcut).item.title)
        val settingsID = landscape.placements.first { it.kind == settings }.id
        assertNull("only a shortcut placement can take a shortcut", CustomLayoutEditing.setShortcut(added, settingsID, edited))
        val gesture = ShortcutDraft.gesture("G", "", ReceiverGesture.MissionControl, null)
        assertNull("a layout shortcut is a key chord", CustomLayoutEditing.setShortcut(landscape, null, gesture))
    }

    @Test
    fun useTemplateResetsOnlyTheEditedOrientation() {
        val id = layout.portrait.placements.first().id
        val edited = layout.setArrangement(CustomLayoutEditing.move(layout.portrait, id, NormalizedPosition(0.1, 0.1)), portrait = true)
            .setArrangement(CustomLayoutEditing.move(layout.landscape, layout.landscape.placements.first().id, NormalizedPosition(0.2, 0.2)), portrait = false)
        val reset = CustomLayoutEditing.useTemplate(edited, portrait = true)
        assertEquals(CustomControlArrangement.radialTemplate(layout.portrait.corner, portrait = true).placements.map { it.kind },
            reset.portrait.placements.map { it.kind })
        assertEquals("landscape keeps its edits", edited.landscape, reset.landscape)
    }

    @Test
    fun shortcutDraftNamesAndFacesByKeys() {
        val item = ShortcutDraft.keyboard("X", "  ", setOf(ControlModifier.Shift, ControlModifier.Command), listOf(19, 58), null)
        assertEquals("⌘⇧P+F1", item.title)
        assertEquals(item.title, item.displayKey)
        assertTrue(item.action.isValid)
        val named = ShortcutDraft.keyboard("X", " Print ", emptySet(), listOf(19), ShortcutButtonDisplay.Text("P"))
        assertEquals("Print", named.title)
        assertEquals(ShortcutButtonDisplay.Text("P"), named.display)
        assertEquals("Mission Control", ShortcutDraft.gesture("G", "", ReceiverGesture.MissionControl, null).title)
        assertEquals(setOf(ControlModifier.Command) to listOf(6), ShortcutDraft.initialChord(null, setOf(ControlModifier.Command)))
        assertEquals(setOf(ControlModifier.Shift, ControlModifier.Command) to listOf(19, 58), ShortcutDraft.initialChord(item, emptySet()))
    }

    @Test
    fun functionKeysHaveLabelsOnBothPlatforms() {
        assertEquals("F1", appGestureCommandKeyLabel(58))
        assertEquals("F12", appGestureCommandKeyLabel(69))
        assertNotNull(appGestureCommandEditableKeys.firstOrNull { it.first == "Return" })
    }

    @Test
    fun functionControlsFollowTheLayoutsProfile() {
        val prefs = ReceiverControlPreferences()
        val profile1 = prefs.functionTrayProfile(ControlProfileSlot.Profile1)
        profile1.addCustomItem(ShortcutDraft.keyboard("mine", "Mine", setOf(ControlModifier.Command), listOf(16), null))
        prefs.updateFunctionTrayProfile(profile1)
        assertTrue(CustomLayoutEditing.functionItems(prefs, layout.copy(functionProfile = ControlProfileSlot.Profile1)).any { it.id == "mine" })
        assertFalse(CustomLayoutEditing.functionItems(prefs, layout).any { it.id == "mine" })
    }
}
