package com.raisecaterror.meowdisplay.core.controls

// Ported from MacTests/ReceiverControlsTests.swift.

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

// Int-literal conveniences so the Swift literals port one to one.
private fun CGSize(width: Int, height: Int) = CGSize(width.toDouble(), height.toDouble())
private fun ControlSafeInsets(top: Int, leading: Int, bottom: Int, trailing: Int) =
    ControlSafeInsets(top.toDouble(), leading.toDouble(), bottom.toDouble(), trailing.toDouble())

private fun eq(expected: Double, actual: Double, message: String = "") = assertEquals(message, expected, actual, 0.0)
private fun eq(expected: Int, actual: Double, message: String = "") = assertEquals(message, expected.toDouble(), actual, 0.0)
private fun near(expected: Double, actual: Double, accuracy: Double) = assertEquals(expected, actual, accuracy)
private fun near(expected: Int, actual: Double, accuracy: Double) = assertEquals(expected.toDouble(), actual, accuracy)

private fun down(m: ControlModifier) = ControlInteractionEffect.ModifierDown(m)
private fun up(m: ControlModifier) = ControlInteractionEffect.ModifierUp(m)
private fun haptic(e: ControlHapticEvent) = ControlInteractionEffect.Haptic(e)

/** A profile with one tray item's visibility changed (Swift mutates `trayItems[i].isVisible` in place on its own copy). */
private fun ControlProfile.settingTrayItemVisible(index: Int, visible: Boolean): ControlProfile =
    copy(trayItems = trayItems.toMutableList().also { it[index] = it[index].copy(isVisible = visible) })

private fun FunctionTrayProfile.settingItem(index: Int, transform: (FunctionTrayItemConfiguration) -> FunctionTrayItemConfiguration): FunctionTrayProfile =
    copy(items = items.toMutableList().also { it[index] = transform(it[index]) })

private class MapStore : PreferenceBlobStore {
    val values = mutableMapOf<String, String>()
    override fun read(key: String) = values[key]
    override fun write(key: String, value: String) {
        values[key] = value
    }
}

private val defaultsKey = ReceiverControlPreferencesRepository.DEFAULTS_KEY

private fun MapStore.set(preferences: ReceiverControlPreferences) {
    values[defaultsKey] = preferences.toJson().toString()
}

private fun MapStore.set(json: JsonObject) {
    values[defaultsKey] = json.toString()
}

private fun JsonObject.removing(vararg keys: String) = JsonObject(filterKeys { it !in keys })
private fun JsonObject.putting(key: String, value: kotlinx.serialization.json.JsonElement) = JsonObject(this + (key to value))

class ReceiverControlsTests {
    @Test
    fun testModifierTapLatchesAndSecondTapUnlatches() {
        val state = ControlInteractionState()
        assertEquals(listOf(down(ControlModifier.Command), haptic(ControlHapticEvent.Latch)), state.tap(ControlModifier.Command))
        assertEquals(setOf(ControlModifier.Command), state.latchedModifiers)
        assertEquals(listOf(up(ControlModifier.Command), haptic(ControlHapticEvent.Latch)), state.tap(ControlModifier.Command))
        assertTrue(state.latchedModifiers.isEmpty())
    }

    @Test
    fun testMultipleModifiersLatch() {
        val state = ControlInteractionState()
        state.tap(ControlModifier.Command)
        state.tap(ControlModifier.Option)
        assertEquals(setOf(ControlModifier.Command, ControlModifier.Option), state.latchedModifiers)
    }

    @Test
    fun testHoldOpensPaletteWithoutLatchingAndBuildsChord() {
        val state = ControlInteractionState()
        state.press(ControlModifier.Command)
        val effects = state.beginPalette(ControlModifier.Command)
        assertEquals(listOf(down(ControlModifier.Command), haptic(ControlHapticEvent.Selection)), effects)
        assertTrue(state.latchedModifiers.isEmpty())
        assertEquals(ModifierChord(ControlModifier.Command), state.activeChord)

        assertEquals(
            listOf(down(ControlModifier.Option), haptic(ControlHapticEvent.Selection)),
            state.addTemporaryModifier(ControlModifier.Option),
        )
        assertEquals(ModifierChord(ControlModifier.Command, ControlModifier.Option), state.activeChord)
        assertEquals(ModifierChord(ControlModifier.Command, ControlModifier.Option), state.paletteChord)
        assertEquals(emptyList<ControlInteractionEffect>(), state.addTemporaryModifier(ControlModifier.Option))
        assertEquals(ModifierChord(ControlModifier.Command, ControlModifier.Option), state.activeChord)
    }

    @Test
    fun testContinuousChordSelectionHapticsAndExecutionAreSemantic() {
        val state = ControlInteractionState()
        state.press(ControlModifier.Command)
        state.beginPalette(ControlModifier.Command)
        assertEquals(
            listOf(down(ControlModifier.Option), haptic(ControlHapticEvent.Selection)),
            state.addTemporaryModifier(ControlModifier.Option),
        )
        assertEquals(emptyList<ControlInteractionEffect>(), state.addTemporaryModifier(ControlModifier.Option))

        val action = ShortcutItem(
            id = "move-here", title = "Move Item Here", displayKey = "V", usage = 25,
            modifiers = ModifierChord(ControlModifier.Command, ControlModifier.Option),
        )
        assertEquals(listOf(haptic(ControlHapticEvent.Selection)), state.selectAction(action.id))
        assertEquals(emptyList<ControlInteractionEffect>(), state.selectAction(action.id))
        assertEquals(
            listOf(
                ControlInteractionEffect.Execute(action), haptic(ControlHapticEvent.Confirmation),
                up(ControlModifier.Command), up(ControlModifier.Option),
            ),
            state.finish(action),
        )
        assertTrue(state.temporaryModifiers.isEmpty())
        assertNull(state.paletteChord)
    }

    @Test
    fun testTemporaryReleaseWithoutActionReturnsToLatchedPalette() {
        val state = ControlInteractionState()
        state.tap(ControlModifier.Shift)
        state.press(ControlModifier.Command)
        state.beginPalette(ControlModifier.Command)
        state.addTemporaryModifier(ControlModifier.Option)
        assertEquals(listOf(up(ControlModifier.Command), up(ControlModifier.Option)), state.finish(null))
        assertEquals(setOf(ControlModifier.Shift), state.latchedModifiers)
        assertEquals(ModifierChord(ControlModifier.Shift), state.paletteChord)
    }

    @Test
    fun testTapLatchedChordKeepsItsPaletteVisible() {
        val state = ControlInteractionState()
        state.tap(ControlModifier.Command)
        assertEquals(ModifierChord(ControlModifier.Command), state.paletteChord)
        state.tap(ControlModifier.Option)
        assertEquals(ModifierChord(ControlModifier.Command, ControlModifier.Option), state.paletteChord)
    }

    @Test
    fun testExecutingShortcutClearsTemporaryAndPreservesPermanentModifiers() {
        val state = ControlInteractionState()
        state.tap(ControlModifier.Shift)
        state.beginPalette(ControlModifier.Command)
        state.updateTemporaryChord(setOf(ControlModifier.Command, ControlModifier.Option))
        val action = ShortcutItem(
            title = "Paste", displayKey = "V", usage = 25,
            modifiers = ModifierChord(ControlModifier.Command, ControlModifier.Option, ControlModifier.Shift),
        )
        val effects = state.finish(action)
        assertEquals(
            listOf(
                ControlInteractionEffect.Execute(action), haptic(ControlHapticEvent.Confirmation),
                up(ControlModifier.Command), up(ControlModifier.Option),
            ),
            effects,
        )
        assertEquals(setOf(ControlModifier.Shift), state.latchedModifiers)
        assertTrue(state.temporaryModifiers.isEmpty())
    }

    @Test
    fun testCancelAndResetReleaseHeldModifiers() {
        val state = ControlInteractionState()
        state.beginPalette(ControlModifier.Command)
        assertEquals(listOf(up(ControlModifier.Command)), state.cancelTemporary())
        state.tap(ControlModifier.Command)
        state.tap(ControlModifier.Option)
        assertEquals(listOf(up(ControlModifier.Command), up(ControlModifier.Option)), state.resetAll())
        assertTrue(state.latchedModifiers.isEmpty())
    }

    @Test
    fun testCanonicalProfileContentsAndArbitraryChordLookup() {
        val profile = ControlProfile.canonical()
        assertEquals(ControlTrayItem.entries.toList(), profile.visibleTrayItems)
        assertEquals(
            listOf("C", "V", "X", "Z", "A", "W", "Space"),
            profile.actions(ModifierChord(ControlModifier.Command)).map { it.displayKey },
        )
        assertEquals(5, profile.actions(ModifierChord(ControlModifier.Command, ControlModifier.Option)).size)
        assertEquals(6, profile.actions(ModifierChord(ControlModifier.Command, ControlModifier.Shift)).size)

        val arbitrary = ModifierChord(ControlModifier.Control, ControlModifier.Option, ControlModifier.Shift)
        val action = ShortcutItem(title = "Test", displayKey = "T", usage = 23, modifiers = arbitrary)
        profile.setActions(listOf(action), arbitrary)
        assertEquals(
            listOf(action),
            profile.actions(ModifierChord(ControlModifier.Shift, ControlModifier.Control, ControlModifier.Option)),
        )
    }

    @Test
    fun testDefaultTrayIncludesCustomizableOneShotTab() {
        val profile = ControlProfile.canonical()
        assertEquals(
            listOf(
                ControlTrayItem.Command, ControlTrayItem.Option, ControlTrayItem.Control, ControlTrayItem.Shift,
                ControlTrayItem.Escape, ControlTrayItem.Tab, ControlTrayItem.Dock, ControlTrayItem.Keyboard,
                ControlTrayItem.Settings,
            ),
            profile.visibleTrayItems,
        )
        assertEquals("tab", ControlTrayItem.Tab.displayLabel)
        assertEquals(true, profile.trayItems.firstOrNull { it.item == ControlTrayItem.Tab }?.isVisible)
    }

    @Test
    fun testShortcutHUDReflectsActiveCombinationWithoutActionTitle() {
        assertEquals("⌘C", ModifierChord(ControlModifier.Command).hudText("C"))
        assertEquals("⌘⌥V", ModifierChord(ControlModifier.Command, ControlModifier.Option).hudText("V"))
        assertEquals("⌘⇧4", ModifierChord(ControlModifier.Command, ControlModifier.Shift).hudText("4"))
    }

    @Test
    fun testReceiverCanRequestMirrorToExtendAndExtendToMirror() {
        val mirror = DisplayModeRequestState()
        assertFalse(mirror.confirm(ReceiverDisplayMode.Mirror))
        assertTrue(mirror.request(ReceiverDisplayMode.Extend))
        assertEquals(ReceiverDisplayMode.Extend, mirror.pendingMode)

        val extend = DisplayModeRequestState()
        assertFalse(extend.confirm(ReceiverDisplayMode.Extend))
        assertTrue(extend.request(ReceiverDisplayMode.Mirror))
        assertEquals(ReceiverDisplayMode.Mirror, extend.pendingMode)
    }

    @Test
    fun testDuplicateModeRequestIsSuppressedWhilePending() {
        val state = DisplayModeRequestState()
        state.confirm(ReceiverDisplayMode.Mirror)
        assertTrue(state.request(ReceiverDisplayMode.Extend))
        assertFalse(state.request(ReceiverDisplayMode.Extend))
        assertFalse(state.request(ReceiverDisplayMode.Mirror))
        assertEquals(ReceiverDisplayMode.Extend, state.pendingMode)
    }

    @Test
    fun testConfirmedModeUpdatesReceiverAndProducesOneReceiverConfirmation() {
        val state = DisplayModeRequestState()
        state.confirm(ReceiverDisplayMode.Mirror)
        state.request(ReceiverDisplayMode.Extend)
        assertTrue(state.confirm(ReceiverDisplayMode.Extend))
        assertEquals(ReceiverDisplayMode.Extend, state.confirmedMode)
        assertNull(state.pendingMode)
        assertFalse(state.confirm(ReceiverDisplayMode.Extend))
    }

    @Test
    fun testUnansweredModeRequestExpiresAndKeepsTheActualMode() {
        val state = DisplayModeRequestState()
        state.confirm(ReceiverDisplayMode.Mirror)
        assertTrue(state.request(ReceiverDisplayMode.Extend))
        val generation = state.pendingGeneration
        assertTrue(state.expirePending(generation))
        assertNull(state.pendingMode)
        assertEquals(ReceiverDisplayMode.Mirror, state.confirmedMode)
        // Idempotent, and a stale deadline can never retire a newer request.
        assertFalse(state.expirePending(generation))
        assertTrue(state.request(ReceiverDisplayMode.Extend))
        assertFalse(state.expirePending(generation))
        assertEquals(ReceiverDisplayMode.Extend, state.pendingMode)
    }

    @Test
    fun testSessionResetClearsStalePendingAndConfirmedMode() {
        val state = DisplayModeRequestState()
        state.confirm(ReceiverDisplayMode.Mirror)
        state.request(ReceiverDisplayMode.Extend)
        state.reset()
        assertNull(state.pendingMode)
        assertNull(state.confirmedMode)
        // Nothing is carried over: the first state after a reset is a plain
        // Mac-originated update, not a receiver confirmation.
        assertFalse(state.confirm(ReceiverDisplayMode.Extend))
        assertTrue(state.request(ReceiverDisplayMode.Mirror))
    }

    @Test
    fun testMacOriginatedModeStateUpdatesWithoutReceiverConfirmation() {
        val state = DisplayModeRequestState()
        assertFalse(state.confirm(ReceiverDisplayMode.Mirror))
        assertEquals(ReceiverDisplayMode.Mirror, state.confirmedMode)
        assertFalse(state.confirm(ReceiverDisplayMode.Extend))
        assertEquals(ReceiverDisplayMode.Extend, state.confirmedMode)
    }

    @Test
    fun testCaptureModeMapsToExplicitReceiverModeBothWays() {
        assertEquals(CaptureMode.Mirror, CaptureMode.from(ReceiverDisplayMode.Mirror))
        assertEquals(CaptureMode.Extend, CaptureMode.from(ReceiverDisplayMode.Extend))
        assertEquals(ReceiverDisplayMode.Mirror, CaptureMode.Mirror.receiverMode)
        assertEquals(ReceiverDisplayMode.Extend, CaptureMode.Extend.receiverMode)
    }

    @Test
    fun testProfileReorderHideAndPaletteEditing() {
        var profile = ControlProfile.canonical()
        profile.moveTrayItems(setOf(0), 3)
        assertEquals(
            listOf(ControlTrayItem.Option, ControlTrayItem.Control, ControlTrayItem.Command),
            profile.trayItems.map { it.item }.take(3),
        )
        profile = profile.settingTrayItemVisible(0, false)
        assertFalse(profile.visibleTrayItems.contains(ControlTrayItem.Option))

        val chord = ModifierChord(ControlModifier.Command)
        val originalCount = profile.actions(chord).size
        val actions = profile.actions(chord).toMutableList()
        actions.removeFirst()
        actions.add(ShortcutItem(title = "New", displayKey = "N", usage = 17, modifiers = chord))
        profile.setActions(actions, chord)
        profile.moveActions(chord, setOf(originalCount - 1), 0)
        assertEquals("New", profile.actions(chord).firstOrNull()?.title)
    }

    @Test
    fun testPreferencesSerializationSlotsPersistenceAndReset() {
        val repository = ReceiverControlPreferencesRepository(MapStore())
        val preferences = ReceiverControlPreferences()
        preferences.activeControlProfile = ControlProfileSlot.Profile2
        preferences.trayEnabled = false
        preferences.keyboardButtonEnabled = false
        preferences.hapticsEnabled = false
        preferences.preferredLandscapeSide = LandscapeTraySide.Leading
        preferences.allowInput = false
        preferences.inputMode = PointerInputMode.Trackpad
        preferences.showSurfaceGrid = false
        val profile1 = preferences.profile(ControlProfileSlot.Profile1).settingTrayItemVisible(0, false)
        preferences.updateProfile(profile1)
        repository.save(preferences)

        val loaded = repository.load()
        assertEquals(preferences, loaded)
        assertNotEquals(loaded.profile(ControlProfileSlot.Profile1), loaded.profile(ControlProfileSlot.Profile2))
        val reset = loaded.deepCopy()
        reset.resetProfile(ControlProfileSlot.Profile1)
        assertEquals(ControlProfile.canonical(ControlProfileSlot.Profile1), reset.profile(ControlProfileSlot.Profile1))
        assertFalse(reset.trayEnabled)
    }

    @Test
    fun testSchemaThreePreferencesDefaultAllowInputAndDirectTouch() {
        val store = MapStore()
        val repository = ReceiverControlPreferencesRepository(store)
        val old = ReceiverControlPreferences()
        old.version = 3
        store.set(old)

        val migrated = repository.load()
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, migrated.version)
        // A save written before either preference existed must migrate to
        // exactly the pre-feature behavior: input always allowed, touch
        // always direct/absolute — never silently disable input or switch
        // an existing user into an unfamiliar pointer model.
        assertTrue(migrated.allowInput)
        assertEquals(PointerInputMode.Direct, migrated.inputMode)
    }

    @Test
    fun testSchemaFourPreferencesDefaultTrackpadSensitivityToPreSettingSpeed() {
        val store = MapStore()
        val repository = ReceiverControlPreferencesRepository(store)
        val old = ReceiverControlPreferences()
        old.version = 4
        store.set(old)

        val migrated = repository.load()
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, migrated.version)
        eq(PointerGestureConfig.defaultTrackpadSensitivity, migrated.trackpadSensitivity)
    }

    @Test
    fun testSchemaEightPreferencesDefaultSurfaceGridOn() {
        val store = MapStore()
        val repository = ReceiverControlPreferencesRepository(store)
        val old = ReceiverControlPreferences()
        old.version = 8
        store.set(old.toJson().removing("showSurfaceGrid"))

        val migrated = repository.load()
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, migrated.version)
        assertTrue(migrated.showSurfaceGrid)
    }

    @Test
    fun testTrayCanBeShownRequiresBothAllowInputAndTrayEnabled() {
        val preferences = ReceiverControlPreferences()
        assertTrue(preferences.trayCanBeShown)

        preferences.allowInput = false
        assertFalse(preferences.trayCanBeShown)
        // Turning input back on restores the tray automatically because the
        // stored `trayEnabled` preference was never touched.
        preferences.allowInput = true
        assertTrue(preferences.trayCanBeShown)

        preferences.trayEnabled = false
        assertFalse(preferences.trayCanBeShown)
    }

    @Test
    fun testVersionOnePreferencesGainTabWithoutLosingCustomization() {
        val store = MapStore()
        val repository = ReceiverControlPreferencesRepository(store)
        val old = ReceiverControlPreferences()
        old.version = 1
        old.profiles = old.profiles.map { it.copy(trayItems = it.trayItems.filter { item -> item.item != ControlTrayItem.Tab }) }
        old.profiles = old.profiles.toMutableList().also { it[0] = it[0].settingTrayItemVisible(0, false) }
        store.set(old)

        val migrated = repository.load()
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, migrated.version)
        assertFalse(migrated.profiles[0].trayItems[0].isVisible)
        assertEquals(
            migrated.profiles[0].trayItems.indexOfFirst { it.item == ControlTrayItem.Keyboard } - 1,
            migrated.profiles[0].trayItems.indexOfFirst { it.item == ControlTrayItem.Tab },
        )
    }

    @Test
    fun testLandscapeTrayHugsChosenSideAndCentersVertically() {
        val container = CGRect(0, 0, 844, 390)
        fun layout(side: LandscapeTraySide) = ControlTrayGeometry.layout(
            container = container, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null,
            portrait = false, side = side, traySize = CGSize(44, 348),
            paletteSize = CGSize(42, 260), avoidNotch = true,
        )
        val right = layout(LandscapeTraySide.Trailing)
        val left = layout(LandscapeTraySide.Leading)
        near(container.maxX - 12, right.trayFrame.maxX, 0.5)
        near(container.minX + 12, left.trayFrame.minX, 0.5)
        // Vertically centered, and the palette opens inward on both sides.
        near(container.midY, right.trayFrame.midY, 0.5)
        near(container.midY, left.trayFrame.midY, 0.5)
        assertTrue(right.paletteFrame.maxX < right.trayFrame.minX)
        assertTrue(left.paletteFrame.minX > left.trayFrame.maxX)
    }

    @Test
    fun testSchemaTwoLandscapeCornerMigratesToTraySide() {
        val store = MapStore()
        val json = ReceiverControlPreferences().toJson()
            .putting("version", JsonPrimitive(2))
            .removing("preferredLandscapeSide")
            .putting("preferredLandscapeCorner", JsonPrimitive(LandscapeTrayCorner.BottomLeading.raw))
        store.set(json)

        val migrated = ReceiverControlPreferencesRepository(store).load()
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, migrated.version)
        assertEquals(LandscapeTraySide.Leading, migrated.preferredLandscapeSide)
    }

    @Test
    fun testGeometryKeepsPortraitTrayAndPaletteAboveKeyboard() {
        val visible = CGRect(0, 0, 390, 500)
        val layout = ControlTrayGeometry.layout(
            container = CGRect(0, 0, 390, 844), safeInsets = ControlSafeInsets.zero,
            keyboardVisibleRect = visible, portrait = true, side = LandscapeTraySide.Trailing,
            traySize = CGSize(360, 58), paletteSize = CGSize(330, 92),
            avoidNotch = true,
        )
        assertTrue(layout.trayFrame.maxY <= visible.maxY)
        assertTrue(layout.paletteFrame.maxY <= layout.trayFrame.minY)
        assertTrue(visible.contains(layout.paletteFrame))
    }

    /**
     * Nine 40pt chips need 396pt: wider than a 390pt (or 375pt) iPhone in
     * portrait, and taller than it in landscape, so the end chips ran off
     * the screen and out of the tray's touch area.
     */
    @Test
    fun testTrayChipsShrinkJustEnoughToFitTheScreen() {
        eq(40, ControlTrayGeometry.fittedChipDiameter(count = 9, length = 440.0))
        for (length in listOf(402.0, 390.0, 375.0)) {
            val chip = ControlTrayGeometry.fittedChipDiameter(count = 9, length = length)
            assertTrue(chip < 40)
            val tray = 9 * chip + 8 * 4 + 4
            assertTrue("${length}pt screen", tray <= length - 24)
        }
        eq(40, ControlTrayGeometry.fittedChipDiameter(count = 4, length = 390.0))
        eq(30, ControlTrayGeometry.fittedChipDiameter(count = 20, length = 390.0))
    }

    /**
     * Avoid Notch lifts the portrait tray off the home indicator; the
     * palette must move with it rather than stay where the tray used to
     * be (it covered half the tray on every Face ID iPhone).
     */
    @Test
    fun testAvoidNotchCarriesPortraitPaletteWithTheTray() {
        val container = CGRect(0, 0, 402, 874)
        val layout = ControlTrayGeometry.layout(
            container = container,
            safeInsets = ControlSafeInsets(top = 62, leading = 0, bottom = 34, trailing = 0),
            keyboardVisibleRect = null, portrait = true, side = LandscapeTraySide.Trailing,
            traySize = CGSize(396, 44), paletteSize = CGSize(300, 42),
            avoidNotch = true,
        )
        assertTrue(layout.trayFrame.maxY <= container.maxY - 34)
        assertFalse(layout.trayFrame.intersects(layout.paletteFrame))
        near(10.0, layout.trayFrame.minY - layout.paletteFrame.maxY, 0.001)
    }

    @Test
    fun testAvoidNotchCarriesLandscapePaletteWithTheTray() {
        val layout = ControlTrayGeometry.layout(
            container = CGRect(0, 0, 874, 402),
            safeInsets = ControlSafeInsets(top = 0, leading = 62, bottom = 21, trailing = 62),
            keyboardVisibleRect = null, portrait = false, side = LandscapeTraySide.Leading,
            traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )
        assertTrue(layout.trayFrame.minX >= 62)
        assertFalse(layout.trayFrame.intersects(layout.paletteFrame))
        near(10.0, layout.paletteFrame.minX - layout.trayFrame.maxX, 0.001)
    }

    @Test
    fun testLandscapeCornerFallsBackInsideKeyboardVisibleBounds() {
        val visible = CGRect(0, 0, 700, 190)
        val layout = ControlTrayGeometry.layout(
            container = CGRect(0, 0, 700, 390), safeInsets = ControlSafeInsets.zero,
            keyboardVisibleRect = visible, portrait = false, side = LandscapeTraySide.Trailing,
            traySize = CGSize(58, 300), paletteSize = CGSize(320, 92),
            avoidNotch = true,
        )
        assertTrue(visible.contains(layout.trayFrame))
        assertTrue(visible.contains(layout.paletteFrame))
        assertFalse(layout.trayFrame.intersects(layout.paletteFrame))
        assertEquals(ControlTrayAxis.Vertical, layout.axis)
    }

    // testHeldModifierTrackerNeverKeepsReleasedState: left out, HeldModifierTracker is Mac/InputRouting.swift (CGEventFlags), Mac-only.

    @Test
    fun testHapticPolicyHonorsPreference() {
        for (event in listOf(
            ControlHapticEvent.Selection, ControlHapticEvent.Latch, ControlHapticEvent.Confirmation,
            ControlHapticEvent.ProfileChange, ControlHapticEvent.Reset,
        )) {
            assertTrue(ControlHapticPolicy.shouldPlay(event, enabled = true))
            assertFalse(ControlHapticPolicy.shouldPlay(event, enabled = false))
        }
    }

    // MARK: - Function Tray

    @Test
    fun testDefaultFunctionTrayContainsZoomEditAndReturnActionsInOrder() {
        val profile = FunctionTrayProfile.canonical()
        assertEquals(listOf("zoom-in", "zoom-out", "undo", "redo", "return"), profile.visibleItems.map { it.id })
        assertEquals(listOf("Zoom In", "Zoom Out", "Undo", "Redo", "Return"), profile.visibleItems.map { it.title })
    }

    /**
     * Return gets its own cluster right after Undo/Redo: near the editing
     * actions, but with a gap so a reach for Redo doesn't submit.
     */
    @Test
    fun testDefaultFunctionTrayRendersReturnAsItsOwnGroupAfterEditing() {
        val groups = FunctionTrayProfile.canonical().visibleGroups
        assertEquals(listOf(listOf("zoom-in", "zoom-out"), listOf("undo", "redo"), listOf("return")), groups.map { g -> g.map { it.id } })
    }

    /**
     * One activation is one ordinary Return press: usage 40, no modifiers
     * of its own, so a latched ⌘ or ⇧ (held on the Mac) still applies.
     */
    @Test
    fun testReturnIsOnePlainReturnPress() {
        val item = FunctionTrayProfile.canonical().visibleItems.first { it.id == "return" }
        assertEquals(listOf<ControlActionOperation>(ControlActionOperation.Press(40, emptyList())), ControlActionPlan.operations(item.action))
        assertTrue(item.action.isValid)
        assertTrue(FunctionTrayProfile.isBuiltIn("return"))
    }

    // testReturnPressPicksUpLatchedModifiersOnTheMac: left out, it needs HIDKeyUsage, KeyModifier and HeldModifierTracker
    // (Mac/InputRouting.swift, CGEventFlags), which exist only for Mac event injection.

    /**
     * A profile saved before Return existed keeps its tray exactly as it
     * was; Return arrives hidden, ready to switch on in the editor.
     */
    @Test
    fun testSavedProfileGainsReturnHiddenWithoutChangingItsLayout() {
        val saved = FunctionTrayProfile.canonical()
        saved.items = saved.items.filter { it.id != "return" }
        saved.moveItems(setOf(3), 0)
        saved.items = saved.items.toMutableList().also { it[1] = it[1].copy(isVisible = false) }
        val refreshed = saved.resolvingCanonicalMetadata()
        assertEquals(saved.items, refreshed.items.take(saved.items.size))
        val savedIDs = saved.items.map { it.id }
        val added = refreshed.items.filter { it.id !in savedIDs }
        assertEquals(listOf("return"), added.map { it.id })
        assertEquals(false, added.firstOrNull()?.isVisible)
        assertEquals(saved.visibleItems.map { it.id }, refreshed.visibleItems.map { it.id })
    }

    // MARK: Return upgrade from v1.20.0

    /**
     * One Function Tray profile's items as v1.20.0 (schema 18) stored them:
     * every slot started with this tray, and saving any receiver setting
     * wrote it out even when the tray itself was never touched.
     */
    private val v1_20FunctionTrayItems = """
        [
          {"item": {"id": "zoom-in", "title": "Zoom In", "displayKey": "+", "systemImage": "plus.magnifyingglass",
                    "action": {"keyboardShortcut": {"_0": {"usage": 46, "modifiers": {"modifiers": ["command"]}}}}},
           "isVisible": true, "group": 0},
          {"item": {"id": "zoom-out", "title": "Zoom Out", "displayKey": "−", "systemImage": "minus.magnifyingglass",
                    "action": {"keyboardShortcut": {"_0": {"usage": 45, "modifiers": {"modifiers": ["command"]}}}}},
           "isVisible": true, "group": 0},
          {"item": {"id": "undo", "title": "Undo", "displayKey": "Z", "systemImage": "arrow.uturn.backward",
                    "action": {"keyboardShortcut": {"_0": {"usage": 29, "modifiers": {"modifiers": ["command"]}}}}},
           "isVisible": true, "group": 1},
          {"item": {"id": "redo", "title": "Redo", "displayKey": "Z", "systemImage": "arrow.uturn.forward",
                    "action": {"keyboardShortcut": {"_0": {"usage": 29,
                                                           "modifiers": {"modifiers": ["shift", "command"]}}}}},
           "isVisible": true, "group": 1},
          {"item": {"id": "menu-bar", "title": "Menu Bar", "displayKey": "Menu Bar", "systemImage": "menubar.rectangle",
                    "action": {"receiverGesture": {"_0": "menuBar"}}},
           "isVisible": false, "group": 2},
          {"item": {"id": "launchpad", "title": "Launchpad", "displayKey": "Launchpad", "systemImage": "square.grid.3x3",
                    "action": {"receiverGesture": {"_0": "launchpad"}}},
           "isVisible": false, "group": 2},
          {"item": {"id": "show-desktop", "title": "Show Desktop", "displayKey": "Show Desktop",
                    "systemImage": "rectangle.dashed", "action": {"receiverGesture": {"_0": "showDesktop"}}},
           "isVisible": false, "group": 2},
          {"item": {"id": "control-center", "title": "Control Center", "displayKey": "Control Center",
                    "systemImage": "switch.2", "action": {"receiverGesture": {"_0": "controlCenter"}}},
           "isVisible": false, "group": 2}
        ]
        """

    private fun v1_20FunctionTrayProfile(slot: ControlProfileSlot): FunctionTrayProfile {
        val json = """{"slot": "${slot.raw}", "items": $v1_20FunctionTrayItems}"""
        return FunctionTrayProfile.fromJson(parseJson(json))!!
    }

    /**
     * A schema-18 save holding [trays] (v1.20.0's tray in every slot when
     * null) with some unrelated receiver settings changed.
     */
    private fun saveV1_20Preferences(store: MapStore, trays: List<FunctionTrayProfile>? = null) {
        val old = ReceiverControlPreferences()
        old.version = 18
        old.hapticsEnabled = false
        old.inputMode = PointerInputMode.Trackpad
        old.activeFunctionTrayProfile = ControlProfileSlot.Profile1
        old.functionTrayPosition = FunctionTrayPosition.SameSide
        old.functionTrayProfiles = trays ?: ControlProfileSlot.entries.map { v1_20FunctionTrayProfile(it) }
        store.set(old)
    }

    private fun migrationDefaults(): Pair<MapStore, ReceiverControlPreferencesRepository> {
        val store = MapStore()
        return store to ReceiverControlPreferencesRepository(store)
    }

    /**
     * The fixture is v1.20.0's starting tray: Zoom and Undo/Redo showing,
     * the four system actions hidden, and no Return.
     */
    @Test
    fun testV1_20FixtureIsThatReleasesDefaultTray() {
        val profile = v1_20FunctionTrayProfile(ControlProfileSlot.Default)
        assertEquals(
            listOf("zoom-in", "zoom-out", "undo", "redo", "menu-bar", "launchpad", "show-desktop", "control-center"),
            profile.items.map { it.id },
        )
        assertEquals(listOf("zoom-in", "zoom-out", "undo", "redo"), profile.visibleItems.map { it.id })
        assertEquals(listOf(0, 0, 1, 1, 2, 2, 2, 2), profile.items.map { it.group })
        val today = FunctionTrayProfile.canonical()
        today.items = today.items.filter { it.id != "return" }
        assertEquals(today, profile)
    }

    @Test
    fun testFreshInstallShowsReturnInEverySlot() {
        val (_, repository) = migrationDefaults()
        // `ReceiverControlPreferences.initial(isPad:)` is in CustomControlLayout.swift (another port); the iPad start differs only
        // in its pad layout, so that is what the second initial value stands in with.
        val padInitial = ReceiverControlPreferences().also { it.padControlLayout = PadControlLayoutMode.Custom }
        for (initial in listOf(ReceiverControlPreferences(), padInitial)) {
            val loaded = repository.load(initial)
            for (slot in ControlProfileSlot.entries) {
                val profile = loaded.functionTrayProfile(slot)
                assertEquals("$slot", FunctionTrayProfile.canonical(slot), profile)
                assertEquals(listOf("zoom-in", "zoom-out", "undo", "redo", "return"), profile.visibleItems.map { it.id })
            }
        }
    }

    /**
     * An untouched v1.20.0 tray, saved only because other settings
     * changed, upgrades to today's default in all three slots, and those
     * other settings stay as they were.
     */
    @Test
    fun testUntouchedV1_20TraysUpgradeToShowReturnInEverySlot() {
        val (store, repository) = migrationDefaults()
        saveV1_20Preferences(store)

        val loaded = repository.load()
        for (slot in ControlProfileSlot.entries) {
            assertEquals("$slot", FunctionTrayProfile.canonical(slot), loaded.functionTrayProfiles.firstOrNull { it.slot == slot })
            assertEquals(
                "$slot",
                listOf(listOf("zoom-in", "zoom-out"), listOf("undo", "redo"), listOf("return")),
                loaded.functionTrayProfile(slot).visibleGroups.map { g -> g.map { it.id } },
            )
        }
        assertFalse(loaded.hapticsEnabled)
        assertEquals(PointerInputMode.Trackpad, loaded.inputMode)
        assertEquals(ControlProfileSlot.Profile1, loaded.activeFunctionTrayProfile)
        assertEquals(FunctionTrayPosition.SameSide, loaded.functionTrayPosition)
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, loaded.version)
    }

    /**
     * Each kind of customization keeps the user's tray exactly and only
     * adds Return hidden, ready in the editor. Untouched slots beside it
     * still upgrade on their own.
     */
    @Test
    fun testCustomizedV1_20TraysKeepTheirLayoutAndGainReturnHidden() {
        val custom = ShortcutItem(
            id = "custom-save", title = "Save", displayKey = "S", usage = 22,
            modifiers = ModifierChord(ControlModifier.Command),
        )
        val customizations: List<Pair<String, (FunctionTrayProfile) -> Unit>> = listOf(
            "order" to { it.moveItems(setOf(3), 0) },
            "hidden" to { it.removeItem("zoom-out") },
            "shown" to { it.items[4].isVisible = true },
            "group" to { it.items[1].group = 1 },
            "custom action" to { assertTrue(it.addCustomItem(custom)) },
            "name" to { it.rename("undo", "Back") },
            "display" to { it.setDisplay("redo", ShortcutButtonDisplay.Emoji("🔁")) },
        )
        for ((name, customize) in customizations) {
            val (store, repository) = migrationDefaults()
            val tray = v1_20FunctionTrayProfile(ControlProfileSlot.Profile2)
            customize(tray)
            saveV1_20Preferences(
                store,
                listOf(v1_20FunctionTrayProfile(ControlProfileSlot.Default), v1_20FunctionTrayProfile(ControlProfileSlot.Profile1), tray),
            )

            val loaded = repository.load()
            val migrated = loaded.functionTrayProfile(ControlProfileSlot.Profile2)
            assertEquals(name, tray.items, migrated.items.dropLast(1))
            assertEquals(name, "return", migrated.items.lastOrNull()?.id)
            assertEquals(name, false, migrated.items.lastOrNull()?.isVisible)
            assertEquals(name, tray.visibleItems, migrated.visibleItems)
            assertEquals(name, FunctionTrayProfile.canonical(ControlProfileSlot.Default), loaded.functionTrayProfile(ControlProfileSlot.Default))
            assertEquals(name, FunctionTrayProfile.canonical(ControlProfileSlot.Profile1), loaded.functionTrayProfile(ControlProfileSlot.Profile1))
        }
    }

    /** A tray that already has Return keeps the user's choice for it. */
    @Test
    fun testSavedReturnChoiceIsKept() {
        val hidden = FunctionTrayProfile.canonical(ControlProfileSlot.Default)
        hidden.removeItem("return")
        val moved = FunctionTrayProfile.canonical(ControlProfileSlot.Profile1)
        moved.moveItems(setOf(4), 0)
        // A pre-release build appended it hidden to a v1.20.0 tray.
        val appended = v1_20FunctionTrayProfile(ControlProfileSlot.Profile2)
        val returnItem = FunctionTrayProfile.canonical().items.first { it.id == "return" }
        appended.items = appended.items + FunctionTrayItemConfiguration(returnItem.item, false, returnItem.group)
        for (profile in listOf(hidden, moved, appended)) {
            assertEquals("${profile.slot}", profile, profile.resolvingCanonicalMetadata())
        }
        val (store, repository) = migrationDefaults()
        saveV1_20Preferences(store, listOf(hidden, moved, appended))
        val loaded = repository.load()
        assertEquals(listOf(hidden, moved, appended), loaded.functionTrayProfiles)
    }

    /**
     * Upgraded once, a tray is the user's: hiding Return sticks across
     * later loads, and loading again without a save upgrades the same way.
     */
    @Test
    fun testReturnUpgradeIsIdempotentAndRespectsALaterHide() {
        val (store, repository) = migrationDefaults()
        saveV1_20Preferences(store)
        val first = repository.load()
        assertEquals(first, repository.load())
        repository.save(first)
        assertEquals(first, repository.load())

        val preferences = first.deepCopy()
        val tray = preferences.functionTrayProfile(ControlProfileSlot.Profile1)
        tray.removeItem("return")
        preferences.updateFunctionTrayProfile(tray)
        repository.save(preferences)
        repeat(2) {
            val reloaded = repository.load()
            assertEquals(tray, reloaded.functionTrayProfile(ControlProfileSlot.Profile1))
            assertFalse(reloaded.functionTrayProfile(ControlProfileSlot.Profile1).visibleItems.any { it.id == "return" })
            assertTrue(reloaded.functionTrayProfile(ControlProfileSlot.Default).visibleItems.any { it.id == "return" })
            repository.save(reloaded)
        }
    }

    /** While typing, Return sits in the keyboard bar beside Escape and Tab. */
    @Test
    fun testKeyboardBarOffersReturnBeforeHideKeyboard() {
        val items = KeyboardBarItem.defaultItems
        assertEquals(listOf(KeyboardBarItem.Escape, KeyboardBarItem.Tab, KeyboardBarItem.ReturnKey, KeyboardBarItem.DismissKeyboard), items.takeLast(4))
        assertEquals(1, items.count { it == KeyboardBarItem.ReturnKey })
    }

    /**
     * The eight-key bar (same metrics as `keyboardBarBody`) fits a 375pt
     * and 390pt iPhone inside the layout margins, shrinking only as far as
     * it must and never below the 30pt floor.
     */
    @Test
    fun testEightKeyKeyboardBarFitsCompactIPhones() {
        val count = KeyboardBarItem.defaultItems.size
        assertEquals(8, count)
        val gap = 8.0
        val padding = 6.0
        for ((width, expected) in listOf(375.0 to 35.0, 390.0 to 37.0, 402.0 to 38.0, 440.0 to 38.0)) {
            val item = ControlTrayGeometry.fittedChipDiameter(
                count = count, length = width, preferred = 38.0, gap = gap, slack = padding * 2,
            )
            eq(expected, item, "${width}pt")
            val barWidth = count.toDouble() * item + (count - 1).toDouble() * gap + padding * 2
            assertTrue("${width}pt", barWidth <= width - 24)
        }
    }

    // HID keyboard-page usages the Swift tests read from `HIDKeyUsage` (Mac/InputRouting.swift, Mac-only): equal = 46, minus = 45, keyZ = 29.
    private val hidEqual = 46
    private val hidMinus = 45
    private val hidKeyZ = 29

    @Test
    fun testZoomInResolvesToCommandPlus() {
        val item = FunctionTrayProfile.canonical().visibleItems.first { it.id == "zoom-in" }
        val action = item.action as? ControlAction.KeyboardShortcutAction ?: return fail("expected a keyboard shortcut")
        assertEquals(hidEqual, action.shortcut.usage)
        assertEquals(ModifierChord(ControlModifier.Command), action.shortcut.modifiers)
    }

    @Test
    fun testZoomOutResolvesToCommandMinus() {
        val item = FunctionTrayProfile.canonical().visibleItems.first { it.id == "zoom-out" }
        val action = item.action as? ControlAction.KeyboardShortcutAction ?: return fail("expected a keyboard shortcut")
        assertEquals(hidMinus, action.shortcut.usage)
        assertEquals(ModifierChord(ControlModifier.Command), action.shortcut.modifiers)
    }

    @Test
    fun testUndoResolvesToCommandZ() {
        val item = FunctionTrayProfile.canonical().visibleItems.first { it.id == "undo" }
        val action = item.action as? ControlAction.KeyboardShortcutAction ?: return fail("expected a keyboard shortcut")
        assertEquals(hidKeyZ, action.shortcut.usage)
        assertEquals(ModifierChord(ControlModifier.Command), action.shortcut.modifiers)
    }

    @Test
    fun testRedoResolvesToShiftCommandZ() {
        val item = FunctionTrayProfile.canonical().visibleItems.first { it.id == "redo" }
        val action = item.action as? ControlAction.KeyboardShortcutAction ?: return fail("expected a keyboard shortcut")
        assertEquals(hidKeyZ, action.shortcut.usage)
        assertEquals(ModifierChord(ControlModifier.Command, ControlModifier.Shift), action.shortcut.modifiers)
    }

    // testHIDKeyUsageMinusAndEqualParseAndMapToCorrectKeyCodes: left out, HIDKeyUsage (parse, macOS keyCode) is Mac-only.

    @Test
    fun testMainTrayOwnsToggleDockNotFunctionTray() {
        val mainItems = ControlProfile.canonical().visibleTrayItems
        val dockIndex = mainItems.indexOf(ControlTrayItem.Dock)
        val keyboardIndex = mainItems.indexOf(ControlTrayItem.Keyboard)
        assertTrue(dockIndex >= 0 && keyboardIndex >= 0)
        assertEquals(keyboardIndex, dockIndex + 1)
        assertEquals("Toggle Dock", ControlTrayItem.Dock.title)
        assertEquals("dock.rectangle", ControlTrayItem.Dock.displayLabel)
        val functionIDs = FunctionTrayProfile.canonical().visibleItems.map { it.id }
        assertFalse(functionIDs.contains("dock"))
        assertFalse(functionIDs.any { it.lowercase().contains("dock") })
    }

    @Test
    fun testOldFunctionTrayItemsResolveCanonicalSymbolsWithoutLosingCustomization() {
        val saved = FunctionTrayProfile.canonical(ControlProfileSlot.Profile1)
        saved.items = saved.items.reversed().mapIndexed { index, configuration ->
            configuration.copy(
                item = configuration.item.copy(systemImage = null, title = "Old ${configuration.item.id}"),
                isVisible = if (index == 0) false else configuration.isVisible,
                group = if (index == 0) 42 else configuration.group,
            )
        }

        val resolved = saved.resolvingCanonicalMetadata()
        assertEquals(saved.items.map { it.id }, resolved.items.map { it.id })
        assertFalse(resolved.items[0].isVisible)
        assertEquals(42, resolved.items[0].group)
        assertEquals("plus.magnifyingglass", resolved.items.firstOrNull { it.id == "zoom-in" }?.item?.systemImage)
        assertEquals("minus.magnifyingglass", resolved.items.firstOrNull { it.id == "zoom-out" }?.item?.systemImage)
        assertEquals("arrow.uturn.backward", resolved.items.firstOrNull { it.id == "undo" }?.item?.systemImage)
        assertEquals("arrow.uturn.forward", resolved.items.firstOrNull { it.id == "redo" }?.item?.systemImage)
        assertEquals("Undo", resolved.items.firstOrNull { it.id == "undo" }?.item?.title)
    }

    /**
     * Launchpad and Show Desktop have no reliable Mac keyboard shortcut, so
     * these opt-in items are their only route besides the 4/5-finger pinch.
     * Hidden by default: the default tray is unchanged.
     */
    @Test
    fun testLaunchpadAndShowDesktopAreOptInFunctionTrayGestures() {
        val profile = FunctionTrayProfile.canonical()
        assertFalse(profile.visibleItems.any { it.id == "launchpad" || it.id == "show-desktop" })
        val launchpad = profile.items.first { it.id == "launchpad" }
        val showDesktop = profile.items.first { it.id == "show-desktop" }
        assertFalse(launchpad.isVisible)
        assertFalse(showDesktop.isVisible)
        assertEquals(ControlAction.ReceiverGestureAction(ReceiverGesture.Launchpad.raw), launchpad.item.action)
        assertEquals(ControlAction.ReceiverGestureAction(ReceiverGesture.ShowDesktop.raw), showDesktop.item.action)
        assertEquals(launchpad.group, showDesktop.group)
        // The system group holds exactly the semantic system actions.
        assertEquals(
            setOf("menu-bar", "launchpad", "show-desktop", "control-center"),
            profile.items.filter { it.group == launchpad.group }.map { it.id }.toSet(),
        )
    }

    @Test
    fun testSavedFunctionTrayGainsNewItemsHiddenWithoutChangingItsTray() {
        val saved = FunctionTrayProfile.canonical(ControlProfileSlot.Profile2)
        saved.items = saved.items.filter { it.id != "launchpad" && it.id != "show-desktop" }
        saved.items = saved.items.toMutableList().also { java.util.Collections.swap(it, 0, 1) }
        saved.items[2].isVisible = false
        val resolved = saved.resolvingCanonicalMetadata()
        assertEquals(saved.visibleItems.map { it.id }, resolved.visibleItems.map { it.id })
        assertEquals(saved.items.map { it.id }, resolved.items.map { it.id }.take(saved.items.size))
        assertEquals(listOf("launchpad", "show-desktop"), resolved.items.map { it.id }.takeLast(2))
        assertFalse(resolved.items.takeLast(2).any { it.isVisible })
        // Idempotent: nothing is appended twice.
        assertEquals(resolved.items.map { it.id }, resolved.resolvingCanonicalMetadata().items.map { it.id })
    }

    @Test
    fun testReceiverGestureActionRoundTripsThroughPersistence() {
        val item = ShortcutItem("launchpad", "Launchpad", ReceiverGesture.Launchpad, "square.grid.3x3")
        val decoded = ShortcutItem.fromJson(parseJson(item.toJson().toString()))
        assertEquals(item, decoded)
        val legacy = ShortcutItem.fromJson(
            parseJson(
                ShortcutItem(id = "undo", title = "Undo", displayKey = "Z", usage = 29, modifiers = ModifierChord(ControlModifier.Command))
                    .toJson().toString(),
            ),
        )!!
        assertEquals(
            ControlAction.KeyboardShortcutAction(KeyboardShortcut(usage = 29, modifiers = ModifierChord(ControlModifier.Command))),
            legacy.action,
        )
    }

    @Test
    fun testSchemaSevenProfilesGainDockImmediatelyBeforeKeyboard() {
        val store = MapStore()
        val repository = ReceiverControlPreferencesRepository(store)
        val old = ReceiverControlPreferences()
        old.version = 7
        old.profiles = old.profiles.map { it.copy(trayItems = it.trayItems.filter { item -> item.item != ControlTrayItem.Dock }) }
        store.set(old)

        val migrated = repository.load()
        for (profile in migrated.profiles) {
            val dock = profile.trayItems.indexOfFirst { it.item == ControlTrayItem.Dock }
            val keyboard = profile.trayItems.indexOfFirst { it.item == ControlTrayItem.Keyboard }
            assertTrue(dock >= 0 && keyboard >= 0)
            assertEquals(keyboard, dock + 1)
            assertEquals(profile.slot == ControlProfileSlot.Default, profile.trayItems[dock].isVisible)
        }
    }

    @Test
    fun testSameSideFunctionGroupsAvoidRenderedMainTrayWhenMiddleCannotFit() {
        val container = CGRect(0, 0, 844, 390)
        val renderedMain = CGRect(12, -3, 44, 396)
        val frames = ControlTrayGeometry.functionTrayLayout(
            container = container, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null,
            portrait = false, mainSide = LandscapeTraySide.Leading, position = FunctionTrayPosition.SameSide,
            mainTrayFrame = renderedMain,
            groupSizes = listOf(CGSize(44, 88), CGSize(44, 88)),
            avoiding = null, avoidNotch = true,
        )

        assertEquals(2, frames.size)
        assertTrue(frames.all { !it.intersects(renderedMain) })
        assertTrue(frames.all { container.contains(it) })
    }

    @Test
    fun testFunctionTrayProfilesPersistIndependentlyFromMainTrayProfiles() {
        val repository = ReceiverControlPreferencesRepository(MapStore())

        val preferences = ReceiverControlPreferences()
        preferences.activeControlProfile = ControlProfileSlot.Profile2
        preferences.activeFunctionTrayProfile = ControlProfileSlot.Profile1
        val mainProfile1 = preferences.profile(ControlProfileSlot.Profile1).settingTrayItemVisible(0, false)
        preferences.updateProfile(mainProfile1)
        val functionProfile1 = preferences.functionTrayProfile(ControlProfileSlot.Profile1)
            .settingItem(0) { it.copy(isVisible = false) }
        preferences.updateFunctionTrayProfile(functionProfile1)
        repository.save(preferences)

        val loaded = repository.load()
        assertEquals(preferences, loaded)
        assertEquals(ControlProfileSlot.Profile2, loaded.activeControlProfile)
        assertEquals(ControlProfileSlot.Profile1, loaded.activeFunctionTrayProfile)
        assertFalse(loaded.profile(ControlProfileSlot.Profile1).trayItems[0].isVisible)
        assertFalse(loaded.functionTrayProfile(ControlProfileSlot.Profile1).items[0].isVisible)
        // Changing one tray's profile 1 never touched the other's.
        assertEquals(FunctionTrayProfile.canonical(ControlProfileSlot.Profile2), loaded.functionTrayProfile(ControlProfileSlot.Profile2))
        assertEquals(ControlProfile.canonical(ControlProfileSlot.Profile2), loaded.profile(ControlProfileSlot.Profile2))
    }

    @Test
    fun testVisibilityAndOrderChangesDoNotMergeMainAndFunctionProfileState() {
        val preferences = ReceiverControlPreferences()
        val mainProfile = preferences.profile(ControlProfileSlot.Default).copy()
        mainProfile.moveTrayItems(setOf(0), mainProfile.trayItems.size)
        preferences.updateProfile(mainProfile)
        // The Function Tray's default profile — untouched by the Main Tray
        // edit above — still reads exactly as canonical.
        assertEquals(FunctionTrayProfile.canonical(ControlProfileSlot.Default), preferences.functionTrayProfile(ControlProfileSlot.Default))

        val functionProfile = preferences.functionTrayProfile(ControlProfileSlot.Default).settingItem(0) { it.copy(isVisible = false) }
        preferences.updateFunctionTrayProfile(functionProfile)
        // And the Main Tray edit from above is still intact after that.
        assertEquals(mainProfile, preferences.profile(ControlProfileSlot.Default))
    }

    @Test
    fun testSchemaFivePreferencesDefaultFunctionTrayToEnabledWithCanonicalProfiles() {
        val store = MapStore()
        val repository = ReceiverControlPreferencesRepository(store)
        val old = ReceiverControlPreferences()
        old.version = 5
        // Schema 5 had no Function Tray, so its saves carry none of its keys.
        store.set(old.toJson().removing("functionTrayEnabled", "activeFunctionTrayProfile", "functionTrayPosition", "functionTrayProfiles"))

        val migrated = repository.load()
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, migrated.version)
        assertTrue(migrated.functionTrayEnabled)
        // Older saves keep the earlier same-side placement.
        assertEquals(FunctionTrayPosition.SameSide, migrated.functionTrayPosition)
        assertEquals(FunctionTrayProfile.canonical(ControlProfileSlot.Default), migrated.functionTrayProfile(ControlProfileSlot.Default))
    }

    @Test
    fun testFunctionTrayHiddenWhenAllowInputOff() {
        val preferences = ReceiverControlPreferences()
        assertTrue(preferences.functionTrayCanBeShown)
        preferences.allowInput = false
        assertFalse(preferences.functionTrayCanBeShown)
        // Independent of the Main Tray's own visibility, which reacts the
        // same way to the same single `allowInput` gate.
        assertFalse(preferences.trayCanBeShown)
        preferences.allowInput = true
        preferences.functionTrayEnabled = false
        assertFalse(preferences.functionTrayCanBeShown)
        assertTrue(preferences.trayCanBeShown) // Main Tray unaffected by Function Tray's own toggle
    }

    // MARK: - Function Tray layout / collision avoidance

    private val functionContainer = CGRect(0, 0, 400, 300)
    private val functionGroupSizes = listOf(CGSize(44, 90), CGSize(44, 90))

    @Test
    fun testFunctionTraySameSideAnchorsZoomAboveAndEditBelowMainTrayWithoutOverlap() {
        val mainFrame = CGRect(300, 120, 44, 60)
        val frames = ControlTrayGeometry.functionTrayLayout(
            container = functionContainer, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null, portrait = false,
            mainSide = LandscapeTraySide.Trailing, position = FunctionTrayPosition.SameSide,
            mainTrayFrame = mainFrame, groupSizes = functionGroupSizes, avoiding = null, avoidNotch = false,
        )
        assertEquals(2, frames.size)
        val zoom = frames[0]
        val edit = frames[1]
        // Both hug the Main Tray's own (trailing) side.
        assertTrue(zoom.midX > 200)
        assertTrue(edit.midX > 200)
        // Zoom above, Edit below, neither overlapping the Main Tray or each other.
        assertTrue(zoom.maxY < mainFrame.minY)
        assertTrue(edit.minY > mainFrame.maxY)
        assertFalse(zoom.intersects(mainFrame))
        assertFalse(edit.intersects(mainFrame))
        assertFalse(zoom.intersects(edit))
        // Zoom anchors toward the top of the available space, Edit toward the bottom.
        assertTrue(zoom.minY < functionContainer.midY)
        assertTrue(edit.maxY > functionContainer.midY)
    }

    @Test
    fun testFunctionTrayOppositeSideUsesTheOtherEdgeIndependentlyOfMainTray() {
        val mainFrame = CGRect(300, 120, 44, 60)
        val frames = ControlTrayGeometry.functionTrayLayout(
            container = functionContainer, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null, portrait = false,
            mainSide = LandscapeTraySide.Trailing, position = FunctionTrayPosition.OppositeSide,
            mainTrayFrame = mainFrame, groupSizes = functionGroupSizes, avoiding = null, avoidNotch = false,
        )
        // Opposite of the Main Tray's trailing side — hugs leading instead,
        // nowhere near the Main Tray's own frame — and top/bottom anchoring
        // is independent of where the Main Tray happens to sit.
        for (frame in frames) {
            assertTrue(frame.midX < 200)
            assertFalse(frame.intersects(mainFrame))
        }
        assertTrue(frames[0].minY < frames[1].minY)
    }

    @Test
    fun testFunctionTrayDisplacesAroundACollidingPaletteThenReturns() {
        val mainFrame = CGRect(300, 120, 44, 60)
        fun layout(avoiding: CGRect?) = ControlTrayGeometry.functionTrayLayout(
            container = functionContainer, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null, portrait = false,
            mainSide = LandscapeTraySide.Trailing, position = FunctionTrayPosition.SameSide,
            mainTrayFrame = mainFrame, groupSizes = functionGroupSizes, avoiding = avoiding, avoidNotch = false,
        )
        val undisplaced = layout(null)
        // A palette that exactly covers where the Zoom group would sit.
        val collidingPalette = undisplaced[0].insetBy(-2.0, -2.0)
        val displaced = layout(collidingPalette)

        assertFalse(displaced[0].intersects(collidingPalette))
        assertNotEquals(undisplaced[0], displaced[0])
        // The uninvolved (Edit) group is untouched.
        assertEquals(undisplaced[1], displaced[1])

        // The palette closing (avoiding: nil) returns it to the exact
        // original position — no permanent reservation of the moved-to spot.
        assertEquals(undisplaced, layout(null))
    }

    @Test
    fun testLeftSameSideLivePaletteMovesOnlyTopGroupAndReturnsExactly() {
        assertSameSidePaletteMovement(LandscapeTraySide.Leading, 0)
    }

    @Test
    fun testRightSameSideLivePaletteMovesOnlyTopGroupAndReturnsExactly() {
        assertSameSidePaletteMovement(LandscapeTraySide.Trailing, 0)
    }

    @Test
    fun testSameSideBottomPaletteCollisionMovesOnlyBottomGroup() {
        assertSameSidePaletteMovement(LandscapeTraySide.Leading, 1)
    }

    private fun assertSameSidePaletteMovement(side: LandscapeTraySide, collidingGroup: Int) {
        // A tall rendered Main Tray forces the working Same Side base
        // fallback inward. This is the real-device geometry that exposed
        // the old palette->main displacement loop.
        val mainX = if (side == LandscapeTraySide.Leading) 12 else 344
        val main = CGRect(mainX, 20, 44, 260)
        fun layout(palette: CGRect?) = ControlTrayGeometry.functionTrayLayout(
            container = functionContainer, safeInsets = ControlSafeInsets.zero,
            keyboardVisibleRect = null, portrait = false,
            mainSide = side, position = FunctionTrayPosition.SameSide,
            mainTrayFrame = main, groupSizes = functionGroupSizes,
            avoiding = palette, avoidNotch = false,
        )

        val closed = layout(null)
        val palette = closed[collidingGroup].insetBy(-2.0, -2.0)
        val open = layout(palette)
        val other = if (collidingGroup == 0) 1 else 0

        assertNotEquals(closed[collidingGroup], open[collidingGroup])
        assertFalse(open[collidingGroup].intersects(palette))
        assertFalse(open[collidingGroup].intersects(main))
        assertEquals(closed[other], open[other])
        // `nil` models `paletteChord` closing: geometry is stateless and
        // recomputes the exact base frame used by SwiftUI's frame animation.
        assertEquals(closed, layout(null))
    }

    @Test
    fun testOppositeSideMovesOnlyForActualPaletteIntersection() {
        val main = CGRect(344, 100, 44, 100)
        fun layout(palette: CGRect?) = ControlTrayGeometry.functionTrayLayout(
            container = functionContainer, safeInsets = ControlSafeInsets.zero,
            keyboardVisibleRect = null, portrait = false,
            mainSide = LandscapeTraySide.Trailing, position = FunctionTrayPosition.OppositeSide,
            mainTrayFrame = main, groupSizes = functionGroupSizes,
            avoiding = palette, avoidNotch = false,
        )
        val base = layout(null)
        assertEquals(base, layout(CGRect(300, 120, 44, 60)))

        val palette = base[0].insetBy(-2.0, -2.0)
        val moved = layout(palette)
        assertNotEquals(base[0], moved[0])
        assertFalse(moved[0].intersects(palette))
        assertEquals(base[1], moved[1])
    }

    @Test
    fun testPaletteDisplacementRemainsClearOfUnsafeRegion() {
        val container = CGRect(0, 0, 800, 400)
        val safe = ControlSafeInsets(top = 0, leading = 50, bottom = 0, trailing = 0)
        val main = CGRect(50, 100, 44, 200)
        val base = ControlTrayGeometry.functionTrayLayout(
            container = container, safeInsets = safe, keyboardVisibleRect = null,
            portrait = false, mainSide = LandscapeTraySide.Leading, position = FunctionTrayPosition.SameSide,
            mainTrayFrame = main, groupSizes = functionGroupSizes,
            avoiding = null, avoidNotch = true,
        )
        val palette = base[0].insetBy(-2.0, -2.0)
        val moved = ControlTrayGeometry.functionTrayLayout(
            container = container, safeInsets = safe, keyboardVisibleRect = null,
            portrait = false, mainSide = LandscapeTraySide.Leading, position = FunctionTrayPosition.SameSide,
            mainTrayFrame = main, groupSizes = functionGroupSizes,
            avoiding = palette, avoidNotch = true,
        )

        assertFalse(moved[0].intersects(palette))
        assertFalse(moved[0].intersects(main))
        assertTrue(moved[0].minX >= safe.leading)
        assertTrue(container.contains(moved[0]))
    }

    @Test
    fun testFunctionTrayLayoutIsANoOpWhenNotActuallyColliding() {
        val mainFrame = CGRect(300, 120, 44, 60)
        val farAwayPalette = CGRect(0, 0, 20, 20)
        val frames = ControlTrayGeometry.functionTrayLayout(
            container = functionContainer, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null, portrait = false,
            mainSide = LandscapeTraySide.Trailing, position = FunctionTrayPosition.SameSide,
            mainTrayFrame = mainFrame, groupSizes = functionGroupSizes, avoiding = farAwayPalette, avoidNotch = false,
        )
        for (frame in frames) assertFalse(frame.intersects(farAwayPalette))
    }

    // MARK: - Avoid Notch

    @Test
    fun testAvoidingUnsafeRegionShiftsOnlyWhenIntersectingAndOnlyOnTheAffectedEdge() {
        val container = CGRect(0, 0, 800, 400)
        val leftNotch = ControlSafeInsets(top = 0, leading = 40, bottom = 0, trailing = 0)

        // Frame sitting inside the notch's strip — shifted to clear it.
        val overlapping = CGRect(10, 100, 44, 120)
        val shifted = ControlTrayGeometry.avoidingUnsafeRegion(overlapping, container, leftNotch, enabled = true, notchSide = LandscapeTraySide.Leading)
        eq(40, shifted.minX)
        eq(overlapping.minY, shifted.minY) // only the affected axis moves

        // A frame nowhere near the unsafe strip is returned unchanged.
        val clear = CGRect(200, 100, 44, 120)
        assertEquals(clear, ControlTrayGeometry.avoidingUnsafeRegion(clear, container, leftNotch, enabled = true, notchSide = LandscapeTraySide.Leading))

        // Disabled: never shifts, even when intersecting.
        assertEquals(overlapping, ControlTrayGeometry.avoidingUnsafeRegion(overlapping, container, leftNotch, enabled = false, notchSide = LandscapeTraySide.Leading))
    }

    @Test
    fun testAvoidingUnsafeRegionHandlesAllFourEdgesIndependently() {
        val container = CGRect(0, 0, 800, 400)
        val insets = ControlSafeInsets(top = 30, leading = 40, bottom = 20, trailing = 50)
        // Trailing-edge overlap — the physical notch side is given
        // explicitly (see `PhysicalNotchSide`), not inferred from comparing
        // `leading`/`trailing` depths.
        val trailing = CGRect(770, 100, 44, 44)
        val shiftedTrailing = ControlTrayGeometry.avoidingUnsafeRegion(trailing, container, insets, enabled = true, notchSide = LandscapeTraySide.Trailing)
        eq(750, shiftedTrailing.maxX)
        // Top overlap — independent of notchSide entirely.
        val top = CGRect(378, 5, 44, 44)
        eq(30, ControlTrayGeometry.avoidingUnsafeRegion(top, container, insets, enabled = true).minY)
        // Bottom overlap — independent of notchSide entirely.
        val bottom = CGRect(378, 370, 44, 44)
        eq(380, ControlTrayGeometry.avoidingUnsafeRegion(bottom, container, insets, enabled = true).maxY)
    }

    @Test
    fun testLeftSideNotchShiftsLeadingTrayInward() {
        val container = CGRect(0, 0, 800, 400)
        val leftNotch = ControlSafeInsets(top = 0, leading = 40, bottom = 0, trailing = 0)
        val on = ControlTrayGeometry.layout(
            container = container, safeInsets = leftNotch, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Leading, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )
        assertTrue(on.trayFrame.minX >= 40)
    }

    @Test
    fun testRightSideNotchShiftsTrailingTrayInward() {
        val container = CGRect(0, 0, 800, 400)
        val rightNotch = ControlSafeInsets(top = 0, leading = 0, bottom = 0, trailing = 40)
        val on = ControlTrayGeometry.layout(
            container = container, safeInsets = rightNotch, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Trailing, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true, notchSide = LandscapeTraySide.Trailing,
        )
        assertTrue(on.trayFrame.maxX <= container.maxX - 40)
    }

    @Test
    fun testLeftTrayIsUnchangedByRightUnsafeInset() {
        val container = CGRect(0, 0, 844, 390)
        val raw = ControlTrayGeometry.layout(
            container = container, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null,
            portrait = false, side = LandscapeTraySide.Leading,
            traySize = CGSize(44, 300), paletteSize = CGSize(46, 330),
            avoidNotch = true,
        )
        val rightUnsafe = ControlSafeInsets(top = 0, leading = 0, bottom = 21, trailing = 59)
        val resolved = ControlTrayGeometry.layout(
            container = container, safeInsets = rightUnsafe, keyboardVisibleRect = null,
            portrait = false, side = LandscapeTraySide.Leading,
            traySize = CGSize(44, 300), paletteSize = CGSize(46, 330),
            avoidNotch = true, notchSide = LandscapeTraySide.Trailing,
        )
        eq(raw.trayFrame.minX, resolved.trayFrame.minX)
    }

    @Test
    fun testRightTrayIsUnchangedByLeftUnsafeInset() {
        val container = CGRect(0, 0, 844, 390)
        val raw = ControlTrayGeometry.layout(
            container = container, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null,
            portrait = false, side = LandscapeTraySide.Trailing,
            traySize = CGSize(44, 300), paletteSize = CGSize(46, 330),
            avoidNotch = true,
        )
        val leftUnsafe = ControlSafeInsets(top = 0, leading = 59, bottom = 21, trailing = 0)
        val resolved = ControlTrayGeometry.layout(
            container = container, safeInsets = leftUnsafe, keyboardVisibleRect = null,
            portrait = false, side = LandscapeTraySide.Trailing,
            traySize = CGSize(44, 300), paletteSize = CGSize(46, 330),
            avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )
        eq(raw.trayFrame.maxX, resolved.trayFrame.maxX)
    }

    @Test
    fun testCollapsedGearUsesTheSameNotchSafeMainTrayFrame() {
        val container = CGRect(0, 0, 844, 390)
        val leftUnsafe = ControlSafeInsets(top = 0, leading = 59, bottom = 21, trailing = 0)
        val gearSize = CGSize(50, 50)
        val layout = ControlTrayGeometry.layout(
            container = container, safeInsets = leftUnsafe, keyboardVisibleRect = null,
            portrait = false, side = LandscapeTraySide.Leading, traySize = gearSize,
            paletteSize = CGSize.zero, avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )

        eq(leftUnsafe.leading, layout.trayFrame.minX)
        assertEquals(gearSize, layout.trayFrame.size)

        val off = ControlTrayGeometry.layout(
            container = container, safeInsets = leftUnsafe, keyboardVisibleRect = null,
            portrait = false, side = LandscapeTraySide.Leading, traySize = gearSize,
            paletteSize = CGSize.zero, avoidNotch = false, notchSide = LandscapeTraySide.Leading,
        )
        eq(12, off.trayFrame.minX)
    }

    @Test
    fun testRuntimeSafeAreaReportRepairsZeroedSwiftUIInsetsAfterRotation() {
        val zeroedProxy = ControlSafeInsets.zero
        val landscapeWindow = ControlSafeInsets(top = 0, leading = 59, bottom = 21, trailing = 0)
        assertEquals(landscapeWindow, ControlSafeInsets.resolved(proxy = zeroedProxy, runtime = landscapeWindow))

        // Rotating the other way swaps the physical sensor side. The live
        // snapshot replaces, rather than merges with, the stale proxy.
        val rotatedWindow = ControlSafeInsets(top = 0, leading = 0, bottom = 21, trailing = 59)
        assertEquals(rotatedWindow, ControlSafeInsets.resolved(proxy = landscapeWindow, runtime = rotatedWindow))
        assertEquals(landscapeWindow, ControlSafeInsets.resolved(proxy = landscapeWindow, runtime = null))
    }

    @Test
    fun testTrayOnNonNotchSideIsUnaffected() {
        val container = CGRect(0, 0, 800, 400)
        val leftNotch = ControlSafeInsets(top = 0, leading = 40, bottom = 0, trailing = 0)
        val unaffected = ControlTrayGeometry.layout(
            container = container, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Trailing, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true,
        )
        val withLeftNotch = ControlTrayGeometry.layout(
            container = container, safeInsets = leftNotch, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Trailing, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )
        // A trailing-side tray is unaffected by a leading-edge notch.
        assertEquals(unaffected.trayFrame, withLeftNotch.trayFrame)
    }

    @Test
    fun testAvoidNotchOffPreservesFullEdgePlacementEvenOverTheUnsafeStrip() {
        val container = CGRect(0, 0, 800, 400)
        val leftNotch = ControlSafeInsets(top = 0, leading = 40, bottom = 0, trailing = 0)
        val off = ControlTrayGeometry.layout(
            container = container, safeInsets = leftNotch, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Leading, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = false, notchSide = LandscapeTraySide.Leading,
        )
        // With Avoid Notch off, the tray sits at the literal screen edge,
        // ignoring the notch's inset entirely.
        near(12, off.trayFrame.minX, 0.5)
    }

    @Test
    fun testAvoidNotchOnWithNoActualMainTrayOverlapMatchesOffExactly() {
        val container = CGRect(0, 0, 844, 390)
        // A top sensor region is centered horizontally; this left-side
        // landscape tray never intersects it.
        val topUnsafe = ControlSafeInsets(top = 59, leading = 0, bottom = 0, trailing = 0)
        fun layout(avoid: Boolean) = ControlTrayGeometry.layout(
            container = container, safeInsets = topUnsafe, keyboardVisibleRect = null,
            portrait = false, side = LandscapeTraySide.Leading,
            traySize = CGSize(44, 300),
            paletteSize = CGSize(46, 330), avoidNotch = avoid,
        )
        assertEquals(layout(false), layout(true))
    }

    @Test
    fun testNonIntersectingFunctionTrayGroupsStayAtExactRawFrames() {
        val container = CGRect(0, 0, 800, 400)
        val leftNotch = ControlSafeInsets(top = 0, leading = 40, bottom = 0, trailing = 0)
        val mainFrame = CGRect(700, 120, 44, 60)
        fun layout(avoid: Boolean) = ControlTrayGeometry.functionTrayLayout(
            container = container, safeInsets = leftNotch, keyboardVisibleRect = null, portrait = false,
            mainSide = LandscapeTraySide.Trailing, position = FunctionTrayPosition.OppositeSide,
            mainTrayFrame = mainFrame, groupSizes = functionGroupSizes,
            avoiding = null, avoidNotch = avoid, notchSide = LandscapeTraySide.Leading,
        )
        assertEquals(layout(false), layout(true))
    }

    @Test
    fun testIntersectingFunctionTrayGroupMovesOnlyMinimumDistance() {
        val container = CGRect(0, 0, 800, 400)
        val leftNotch = ControlSafeInsets(top = 0, leading = 40, bottom = 0, trailing = 0)
        val mainFrame = CGRect(700, 120, 44, 60)
        val frames = ControlTrayGeometry.functionTrayLayout(
            container = container, safeInsets = leftNotch, keyboardVisibleRect = null,
            portrait = false, mainSide = LandscapeTraySide.Trailing, position = FunctionTrayPosition.OppositeSide,
            mainTrayFrame = mainFrame, groupSizes = listOf(CGSize(44, 200)),
            avoiding = null, avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )
        eq(leftNotch.leading, frames[0].minX)
    }

    @Test
    fun testTemporaryPaletteUsesConditionalObstacleAvoidance() {
        val container = CGRect(0, 0, 844, 390)
        val leftNotch = ControlSafeInsets(top = 0, leading = 59, bottom = 0, trailing = 0)
        val clearPalette = CGRect(12, 12, 46, 60)
        assertEquals(
            clearPalette,
            ControlTrayGeometry.avoidingUnsafeRegion(clearPalette, container, leftNotch, enabled = true, notchSide = LandscapeTraySide.Leading),
        )

        val collidingPalette = CGRect(12, 150, 46, 100)
        val shifted = ControlTrayGeometry.avoidingUnsafeRegion(
            collidingPalette, container, leftNotch, enabled = true, notchSide = LandscapeTraySide.Leading,
        )
        eq(leftNotch.leading, shifted.minX)
        eq(collidingPalette.minY, shifted.minY)
    }

    @Test
    fun testResultingFrameStaysWithinVisibleBoundsWithAvoidNotch() {
        // Asymmetric so the trailing edge is the notch side under test; the
        // symmetric case (a real device CAN report equal depths on both
        // edges while still having a real, single-sided notch) is covered
        // separately below.
        val container = CGRect(0, 0, 200, 150)
        val heavyInsets = ControlSafeInsets(top = 10, leading = 0, bottom = 10, trailing = 40)
        val layout = ControlTrayGeometry.layout(
            container = container, safeInsets = heavyInsets, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Trailing, traySize = CGSize(44, 120), paletteSize = CGSize(42, 100),
            avoidNotch = true, notchSide = LandscapeTraySide.Trailing,
        )
        val visible = CGRect(
            container.minX, heavyInsets.top,
            container.width - heavyInsets.trailing,
            container.height - heavyInsets.top - heavyInsets.bottom,
        )
        assertTrue(visible.contains(layout.trayFrame))
    }

    /**
     * The real-device failure this replaces: `leading=59, trailing=59`
     * used to make the old leading/trailing-depth-comparison heuristic
     * conclude "no notch," even though the device had a real, single-sided
     * physical notch. Depth comparison can never distinguish that case from
     * actual symmetric rounded corners, so equal insets must still produce an
     * exclusion once the physical side is given explicitly.
     */
    @Test
    fun testSymmetricSafeInsetsStillExcludeGivenAnExplicitNotchSide() {
        val container = CGRect(0, 0, 800, 400)
        val symmetric = ControlSafeInsets(top = 0, leading = 59, bottom = 20, trailing = 59)
        val on = ControlTrayGeometry.layout(
            container = container, safeInsets = symmetric, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Leading, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )
        assertTrue(on.trayFrame.minX >= symmetric.leading)

        // The opposite (non-notch) side is unaffected by the same symmetric
        // insets, exactly as with an asymmetric notch.
        val unaffected = ControlTrayGeometry.layout(
            container = container, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Trailing, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true,
        )
        val withSymmetricNotch = ControlTrayGeometry.layout(
            container = container, safeInsets = symmetric, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Trailing, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )
        assertEquals(unaffected.trayFrame, withSymmetricNotch.trayFrame)
    }

    /**
     * `null` (no known physical notch side) is the safe default — e.g. a
     * non-notched device, or an orientation that isn't clearly landscape —
     * and must not invent an obstacle on either edge even with sizable
     * insets present.
     */
    @Test
    fun testNoNotchSideProducesNoHorizontalObstacleEvenWithSizableInsets() {
        val container = CGRect(0, 0, 800, 400)
        val insets = ControlSafeInsets(top = 0, leading = 40, bottom = 0, trailing = 40)
        val on = ControlTrayGeometry.layout(
            container = container, safeInsets = insets, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Leading, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true, notchSide = null,
        )
        val raw = ControlTrayGeometry.layout(
            container = container, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Leading, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true,
        )
        assertEquals(on.trayFrame, raw.trayFrame)
    }

    // MARK: - Notch side vs. tray side matrix

    @Test
    fun testPhysicalNotchLeftAndControlLeftIsDisplaced() {
        val container = CGRect(0, 0, 800, 400)
        val insets = ControlSafeInsets(top = 0, leading = 59, bottom = 0, trailing = 0)
        val layout = ControlTrayGeometry.layout(
            container = container, safeInsets = insets, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Leading, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )
        assertTrue(layout.trayFrame.minX >= insets.leading)
    }

    @Test
    fun testPhysicalNotchLeftAndControlRightIsUnchanged() {
        val container = CGRect(0, 0, 800, 400)
        val insets = ControlSafeInsets(top = 0, leading = 59, bottom = 0, trailing = 0)
        val raw = ControlTrayGeometry.layout(
            container = container, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Trailing, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true,
        )
        val withNotch = ControlTrayGeometry.layout(
            container = container, safeInsets = insets, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Trailing, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )
        assertEquals(raw.trayFrame, withNotch.trayFrame)
    }

    @Test
    fun testPhysicalNotchRightAndControlRightIsDisplaced() {
        val container = CGRect(0, 0, 800, 400)
        val insets = ControlSafeInsets(top = 0, leading = 0, bottom = 0, trailing = 59)
        val layout = ControlTrayGeometry.layout(
            container = container, safeInsets = insets, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Trailing, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true, notchSide = LandscapeTraySide.Trailing,
        )
        assertTrue(layout.trayFrame.maxX <= container.maxX - insets.trailing)
    }

    @Test
    fun testPhysicalNotchRightAndControlLeftIsUnchanged() {
        val container = CGRect(0, 0, 800, 400)
        val insets = ControlSafeInsets(top = 0, leading = 0, bottom = 0, trailing = 59)
        val raw = ControlTrayGeometry.layout(
            container = container, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Leading, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true,
        )
        val withNotch = ControlTrayGeometry.layout(
            container = container, safeInsets = insets, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Leading, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true, notchSide = LandscapeTraySide.Trailing,
        )
        assertEquals(raw.trayFrame, withNotch.trayFrame)
    }

    // MARK: - Main Tray / Function Tray independence

    /**
     * Both trays share one geometry/avoidance path
     * (`ControlTrayGeometry.avoidingUnsafeRegion`, fed the same `notchSide`)
     * but are evaluated against their OWN actual rendered frame — a Main
     * Tray and Function Tray on opposite sides must not move together.
     */
    @Test
    fun testMainTrayAndFunctionTrayOnOppositeSidesOnlyTheIntersectingOneMoves() {
        val container = CGRect(0, 0, 800, 400)
        // Notch on the right; Main Tray on the right (intersects), Function
        // Tray on the left (opposite side — never intersects).
        val insets = ControlSafeInsets(top = 0, leading = 0, bottom = 0, trailing = 59)
        val mainLayout = ControlTrayGeometry.layout(
            container = container, safeInsets = insets, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Trailing, traySize = CGSize(44, 300), paletteSize = CGSize(42, 260),
            avoidNotch = true, notchSide = LandscapeTraySide.Trailing,
        )
        assertTrue(mainLayout.trayFrame.maxX <= container.maxX - insets.trailing)

        val mainFrame = CGRect(mainLayout.trayFrame.midX - 22, mainLayout.trayFrame.midY - 150, 44.0, 300.0)
        val functionRaw = ControlTrayGeometry.functionTrayLayout(
            container = container, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null, portrait = false,
            mainSide = LandscapeTraySide.Trailing, position = FunctionTrayPosition.OppositeSide,
            mainTrayFrame = mainFrame, groupSizes = functionGroupSizes, avoiding = null, avoidNotch = true,
        )
        val functionWithNotch = ControlTrayGeometry.functionTrayLayout(
            container = container, safeInsets = insets, keyboardVisibleRect = null, portrait = false,
            mainSide = LandscapeTraySide.Trailing, position = FunctionTrayPosition.OppositeSide,
            mainTrayFrame = mainFrame, groupSizes = functionGroupSizes, avoiding = null,
            avoidNotch = true, notchSide = LandscapeTraySide.Trailing,
        )
        // The Function Tray (opposite/left side) is untouched by the
        // right-side notch even though the Main Tray (right side) moved.
        assertEquals(functionRaw, functionWithNotch)
    }

    /**
     * Main Tray and Function Tray on the SAME side both avoid the notch
     * when it intersects them, independently, each shifted only its own
     * minimum distance.
     */
    @Test
    fun testMainTrayAndFunctionTrayOnTheSameSideBothAvoidTheNotch() {
        val container = CGRect(0, 0, 800, 400)
        val insets = ControlSafeInsets(top = 0, leading = 59, bottom = 0, trailing = 0)
        // Main Tray near the bottom, out of the group's way.
        val mainLayout = ControlTrayGeometry.layout(
            container = container, safeInsets = insets, keyboardVisibleRect = null, portrait = false,
            side = LandscapeTraySide.Leading, traySize = CGSize(44, 60), paletteSize = CGSize(42, 60),
            avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )
        assertTrue(mainLayout.trayFrame.minX >= insets.leading)
        val lowMainFrame = CGRect(mainLayout.trayFrame.minX, 340.0, 44.0, 60.0)

        // A single tall group anchored from the top corner — at height 200
        // starting at y=12, it spans into the notch's vertical band
        // (centered on the container, per `unsafeRegions`) and must be
        // pushed clear exactly like the Main Tray was, independently.
        val frames = ControlTrayGeometry.functionTrayLayout(
            container = container, safeInsets = insets, keyboardVisibleRect = null, portrait = false,
            mainSide = LandscapeTraySide.Leading, position = FunctionTrayPosition.SameSide,
            mainTrayFrame = lowMainFrame, groupSizes = listOf(CGSize(44, 200)), avoiding = null,
            avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )
        eq(insets.leading, frames[0].minX)
    }

    @Test
    fun testPortraitNeverTreatsSideInsetsAsANotch() {
        val container = CGRect(0, 0, 400, 844)
        val sideInsets = ControlSafeInsets(top = 0, leading = 30, bottom = 0, trailing = 0)
        // `notchSide` given explicitly (as if a landscape reading were
        // stale) — portrait's own guard must still win.
        val on = ControlTrayGeometry.layout(
            container = container, safeInsets = sideInsets, keyboardVisibleRect = null, portrait = true,
            side = LandscapeTraySide.Leading, traySize = CGSize(260, 60), paletteSize = CGSize(200, 60),
            avoidNotch = true, notchSide = LandscapeTraySide.Leading,
        )
        val off = ControlTrayGeometry.layout(
            container = container, safeInsets = sideInsets, keyboardVisibleRect = null, portrait = true,
            side = LandscapeTraySide.Leading, traySize = CGSize(260, 60), paletteSize = CGSize(200, 60),
            avoidNotch = false,
        )
        assertEquals(on.trayFrame, off.trayFrame)
    }

    @Test
    fun testSchemaSixPreferencesDefaultAvoidNotchToTrue() {
        val store = MapStore()
        val repository = ReceiverControlPreferencesRepository(store)
        val old = ReceiverControlPreferences()
        old.version = 6
        store.set(old)

        val migrated = repository.load()
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, migrated.version)
        assertTrue(migrated.avoidNotch)
    }

    @Test
    fun testAvoidNotchPersistsAcrossSaveAndLoad() {
        val repository = ReceiverControlPreferencesRepository(MapStore())
        val preferences = ReceiverControlPreferences()
        preferences.avoidNotch = false
        repository.save(preferences)
        assertFalse(repository.load().avoidNotch)
    }

    // MARK: - Function Tray icons

    @Test
    fun testUndoUsesUndoArrowSymbol() {
        val item = FunctionTrayProfile.canonical().visibleItems.first { it.id == "undo" }
        assertEquals("arrow.uturn.backward", item.systemImage)
    }

    @Test
    fun testRedoUsesRedoArrowSymbol() {
        val item = FunctionTrayProfile.canonical().visibleItems.first { it.id == "redo" }
        assertEquals("arrow.uturn.forward", item.systemImage)
    }

    @Test
    fun testZoomInUsesMagnifierPlusSymbol() {
        val item = FunctionTrayProfile.canonical().visibleItems.first { it.id == "zoom-in" }
        assertEquals("plus.magnifyingglass", item.systemImage)
    }

    @Test
    fun testZoomOutUsesMagnifierMinusSymbol() {
        val item = FunctionTrayProfile.canonical().visibleItems.first { it.id == "zoom-out" }
        assertEquals("minus.magnifyingglass", item.systemImage)
    }

    @Test
    fun testMainTrayPaletteShortcutsHaveNoSystemImageByDefault() {
        // Main Tray palette shortcuts keep their plain keycap presentation —
        // adding `systemImage` never touched their existing definitions.
        val copy = ControlProfile.canonical().actions(ModifierChord(ControlModifier.Command)).firstOrNull { it.id == "copy" }
        assertNull(copy?.systemImage)
    }

    @Test
    fun testMacDeliveredPreferenceUpdateChangesOnlySuppliedFields() {
        val preferences = ReceiverControlPreferences()
        preferences.hapticsEnabled = false
        val update = ReceiverUIPreferenceUpdate.parse(
            JsonObject(mapOf("type" to JsonPrimitive("receiverUI"), "trayEnabled" to JsonPrimitive(false))),
        )
        assertNotNull(update)
        update!!.apply(preferences)
        assertFalse(preferences.trayEnabled)
        assertTrue(preferences.keyboardButtonEnabled)
        assertFalse(preferences.hapticsEnabled)
        assertNull(
            ReceiverUIPreferenceUpdate.parse(
                JsonObject(mapOf("type" to JsonPrimitive("unknown"), "trayEnabled" to JsonPrimitive(true))),
            ),
        )
    }

    @Test
    fun testPortraitTrackpadSurfaceUsesMostAvailableHeightAndClearsControls() {
        val container = CGRect(0, 0, 390, 844)
        val tray = CGRect(40, 770, 310, 50)
        val surface = VideoOffSurfaceGeometry.interactionRect(
            container = container,
            safeInsets = ControlSafeInsets(top = 59, leading = 0, bottom = 34, trailing = 0),
            occupiedControlFrames = listOf(tray), portrait = true, inputMode = PointerInputMode.Trackpad,
            remoteAspectSize = CGSize(1920, 1080),
        )
        assertTrue(surface.height > surface.width)
        assertTrue(surface.height > 650)
        assertTrue(surface.minY >= 69)
        assertTrue(surface.maxY <= tray.minY - VideoOffSurfaceGeometry.controlGap)
    }

    @Test
    fun testDirectVideoOffSurfacePreservesRemoteAspectInsideSameAvailableRegion() {
        val surface = VideoOffSurfaceGeometry.interactionRect(
            container = CGRect(0, 0, 390, 844),
            safeInsets = ControlSafeInsets(top = 59, leading = 0, bottom = 34, trailing = 0),
            occupiedControlFrames = listOf(CGRect(50, 770, 290, 50)),
            portrait = true, inputMode = PointerInputMode.Direct,
            remoteAspectSize = CGSize(16, 9),
        )
        near(16.0 / 9.0, surface.width / surface.height, 0.001)
        assertTrue(surface.minY >= 69)
        assertTrue(surface.maxY <= 760)
    }

    @Test
    fun testGesturePreferencesDefaultAndMigrateWithoutOverwritingOldChoices() {
        val store = MapStore()
        val old = ReceiverControlPreferences()
        old.version = 9
        store.set(old)
        val loaded = ReceiverControlPreferencesRepository(store).load()
        // Schema 16 moves pre-release installs to Pinch → Viewport,
        // Rotation → Disabled once.
        assertEquals(ReceiverGestureTarget.Viewport, loaded.pinchTarget)
        assertEquals(ReceiverGestureTarget.Disabled, loaded.rotateTarget)
        assertTrue(loaded.snapRotation)
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, loaded.version)
    }

    @Test
    fun testAudioPreferencesMigrateInDisabledAndCentered() {
        val store = MapStore()
        val old = ReceiverControlPreferences()
        old.version = 11
        store.set(old)
        val loaded = ReceiverControlPreferencesRepository(store).load()
        assertFalse(loaded.audioPreferred)
        assertEquals(0, loaded.avSyncOffsetMs)
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, loaded.version)
    }

    @Test
    fun testAudioPreferencesPersistAcrossSaveAndLoad() {
        val preferences = ReceiverControlPreferences()
        preferences.audioPreferred = true
        preferences.avSyncOffsetMs = -250
        val repository = ReceiverControlPreferencesRepository(MapStore())
        repository.save(preferences)
        val loaded = repository.load()
        assertTrue(loaded.audioPreferred)
        assertEquals(-250, loaded.avSyncOffsetMs)
    }

    @Test
    fun testAudioSyncOffsetClampsOnDecodeOfOutOfRangeValue() {
        val preferences = ReceiverControlPreferences()
        preferences.avSyncOffsetMs = 5_000 // out of range if ever written by a future build
        val repository = ReceiverControlPreferencesRepository(MapStore())
        repository.save(preferences)
        val loaded = repository.load()
        assertEquals(AVSyncOffset.range.last, loaded.avSyncOffsetMs)
    }

    // MARK: - App Gesture Commands

    @Test
    fun testAppGestureCommandDefaultsMatchSpec() {
        val defaults = AppGestureCommands.defaults
        assertEquals(KeyboardShortcut(usage = 46, modifiers = ModifierChord(ControlModifier.Command)), defaults.zoomIn)
        assertEquals(KeyboardShortcut(usage = 45, modifiers = ModifierChord(ControlModifier.Command)), defaults.zoomOut)
        assertEquals(KeyboardShortcut(usage = 47, modifiers = ModifierChord(ControlModifier.Command)), defaults.rotateLeft)
        assertEquals(KeyboardShortcut(usage = 48, modifiers = ModifierChord(ControlModifier.Command)), defaults.rotateRight)
    }

    @Test
    fun testAppGestureCommandsMigrateInWithCanonicalDefaults() {
        val store = MapStore()
        val old = ReceiverControlPreferences()
        old.version = 10
        store.set(old)
        val loaded = ReceiverControlPreferencesRepository(store).load()
        assertEquals(AppGestureCommands.defaults, loaded.appGestureCommands)
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, loaded.version)
    }

    @Test
    fun testAppGestureCommandsPersistAcrossSaveAndLoad() {
        val repository = ReceiverControlPreferencesRepository(MapStore())
        val preferences = ReceiverControlPreferences()
        preferences.appGestureCommands.setShortcut(
            KeyboardShortcut(usage = 6, modifiers = ModifierChord(ControlModifier.Option, ControlModifier.Shift)),
            AppGestureCommandKind.ZoomIn,
        )
        repository.save(preferences)
        assertEquals(
            KeyboardShortcut(usage = 6, modifiers = ModifierChord(ControlModifier.Option, ControlModifier.Shift)),
            repository.load().appGestureCommands.zoomIn,
        )
    }

    @Test
    fun testResetAppGestureCommandsRestoresOnlyTheFourDefaultsNotUnrelatedSettings() {
        val preferences = ReceiverControlPreferences()
        preferences.appGestureCommands.setShortcut(
            KeyboardShortcut(usage = 6, modifiers = ModifierChord(ControlModifier.Control)),
            AppGestureCommandKind.RotateRight,
        )
        preferences.pinchTarget = ReceiverGestureTarget.App
        preferences.rotateTarget = ReceiverGestureTarget.App
        preferences.snapRotation = false
        preferences.avoidNotch = false

        preferences.resetAppGestureCommands()

        assertEquals(AppGestureCommands.defaults, preferences.appGestureCommands)
        // Unrelated settings — including the gesture targets themselves —
        // are untouched by this reset (spec section G).
        assertEquals(ReceiverGestureTarget.App, preferences.pinchTarget)
        assertEquals(ReceiverGestureTarget.App, preferences.rotateTarget)
        assertFalse(preferences.snapRotation)
        assertFalse(preferences.avoidNotch)
    }

    // MARK: - Physical notch side (orientation-derived)

    /**
     * `UIInterfaceOrientation` describes how CONTENT rotates to compensate
     * for the device — the opposite of the device's own physical rotation
     * — confirmed against a real notched iPhone: `.landscapeLeft` (device
     * rotated left) puts the physical notch on the screen's TRAILING edge.
     */
    @Test
    fun testLandscapeLeftMapsToTrailingNotchSide() {
        assertEquals(LandscapeTraySide.Trailing, PhysicalNotchSide.forLandscape(LandscapeInterfaceOrientation.LandscapeLeft))
    }

    /** `.landscapeRight` (device rotated right) puts the physical notch on the screen's LEADING edge. */
    @Test
    fun testLandscapeRightMapsToLeadingNotchSide() {
        assertEquals(LandscapeTraySide.Leading, PhysicalNotchSide.forLandscape(LandscapeInterfaceOrientation.LandscapeRight))
    }

    /**
     * No landscape orientation (portrait, flat, or simply unknown) means no
     * landscape notch side — never invented.
     */
    @Test
    fun testNoLandscapeOrientationMapsToNoNotchSide() {
        assertNull(PhysicalNotchSide.forLandscape(null))
    }

    // MARK: - ReservedRegionLayoutTests (second XCTestCase class in the same Swift file)
    //
    // Adaptive layout against system-reserved regions (iOS 27.1 `ReservedRegion`, converted to
    // `ControlReservedRegion` at the SwiftUI boundary). Every container and region below is a
    // representative fixture exercising the pure geometry — none of it is a device identifier or a
    // runtime constant.

    private val landscape = CGRect(0, 0, 844, 390)
    private val portrait = CGRect(0, 0, 390, 844)
    private val verticalTray = CGSize(44, 300)
    private val verticalPalette = CGSize(42, 260)
    private val horizontalTray = CGSize(300, 44)
    private val horizontalPalette = CGSize(260, 42)

    private fun divisionAtX(x: Double, width: Double = 24.0, container: CGRect) =
        ControlReservedRegion(ControlReservedRegion.Kind.Division, CGRect(x, container.minY, width, container.height))

    private fun divisionAtY(y: Double, height: Double = 24.0, container: CGRect) =
        ControlReservedRegion(ControlReservedRegion.Kind.Division, CGRect(container.minX, y, container.width, height))

    private fun layout(
        container: CGRect, portrait: Boolean = false, side: LandscapeTraySide = LandscapeTraySide.Trailing,
        safeInsets: ControlSafeInsets = ControlSafeInsets.zero, avoidNotch: Boolean = true,
        notchSide: LandscapeTraySide? = null,
        regions: List<ControlReservedRegion> = emptyList(),
        traySize: CGSize? = null, paletteSize: CGSize? = null,
    ): ControlTrayLayout = ControlTrayGeometry.layout(
        container = container, safeInsets = safeInsets, keyboardVisibleRect = null, portrait = portrait,
        side = side, traySize = traySize ?: (if (portrait) horizontalTray else verticalTray),
        paletteSize = paletteSize ?: (if (portrait) horizontalPalette else verticalPalette),
        avoidNotch = avoidNotch, notchSide = notchSide, reservedRegions = regions,
    )

    private fun functionFrames(
        container: CGRect, main: ControlTrayLayout, portrait: Boolean = false,
        position: FunctionTrayPosition,
        regions: List<ControlReservedRegion>,
    ): List<CGRect> {
        val sizes = if (portrait) listOf(CGSize(92, 44), CGSize(92, 44)) else listOf(CGSize(44, 92), CGSize(44, 92))
        return ControlTrayGeometry.functionTrayLayout(
            container = container, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null, portrait = portrait,
            mainSide = main.side, position = position, mainTrayFrame = main.trayFrame,
            groupSizes = sizes, avoiding = null, avoidNotch = true, reservedRegions = regions,
        )
    }

    // MARK: A. Existing-device compatibility

    @Test
    fun testOrdinaryPortraitTrayKeepsItsExactBottomCenteredFrame() {
        val insets = ControlSafeInsets(top = 59, leading = 0, bottom = 34, trailing = 0)
        val result = layout(portrait, portrait = true, safeInsets = insets)
        // Bottom-centered, lifted just clear of the home-indicator band.
        assertEquals(CGRect(45, 810 - 44, 300, 44), result.trayFrame)
        assertEquals(ControlTrayAxis.Horizontal, result.axis)
        assertEquals(LandscapeTraySide.Trailing, result.side)
    }

    @Test
    fun testOrdinaryLandscapeTrailingAndLeadingFramesAreUnchanged() {
        val trailing = layout(landscape, side = LandscapeTraySide.Trailing)
        val leading = layout(landscape, side = LandscapeTraySide.Leading)
        assertEquals(CGRect(844 - 12 - 44, 45, 44, 300), trailing.trayFrame)
        assertEquals(CGRect(12, 45, 44, 300), leading.trayFrame)
        assertEquals(LandscapeTraySide.Trailing, trailing.side)
        assertEquals(LandscapeTraySide.Leading, leading.side)
        assertEquals(ControlTrayAxis.Vertical, trailing.axis)
    }

    /**
     * A normal notched iPhone on a system that reports its camera as an
     * occlusion region: no control touches the region, so nothing moves.
     */
    @Test
    fun testNonCollidingOcclusionLeavesEveryFrameBitForBitUnchanged() {
        val island = ControlReservedRegion(ControlReservedRegion.Kind.Occlusion, CGRect(0, 140, 50, 110))
        val insets = ControlSafeInsets(top = 0, leading = 59, bottom = 21, trailing = 59)
        for (side in LandscapeTraySide.entries) {
            val legacy = layout(landscape, side = side, safeInsets = insets, notchSide = LandscapeTraySide.Leading)
            val adaptive = layout(landscape, side = side, safeInsets = insets, notchSide = LandscapeTraySide.Leading, regions = listOf(island))
            assertEquals(legacy, adaptive)
        }
        val portraitIsland = ControlReservedRegion(ControlReservedRegion.Kind.Occlusion, CGRect(140, 11, 110, 37))
        val portraitInsets = ControlSafeInsets(top = 59, leading = 0, bottom = 34, trailing = 0)
        assertEquals(
            layout(portrait, portrait = true, safeInsets = portraitInsets, regions = listOf(portraitIsland)),
            layout(portrait, portrait = true, safeInsets = portraitInsets),
        )
    }

    @Test
    fun testFunctionTrayWithoutRegionsMatchesLegacyCallExactly() {
        val main = layout(landscape)
        for (position in FunctionTrayPosition.entries) {
            val legacy = ControlTrayGeometry.functionTrayLayout(
                container = landscape, safeInsets = ControlSafeInsets.zero, keyboardVisibleRect = null, portrait = false,
                mainSide = LandscapeTraySide.Trailing, position = position, mainTrayFrame = main.trayFrame,
                groupSizes = listOf(CGSize(44, 92), CGSize(44, 92)),
                avoiding = null, avoidNotch = true,
            )
            assertEquals(legacy, functionFrames(landscape, main = main, position = position, regions = emptyList()))
        }
    }

    // MARK: B. Duo-like outer/full-width geometry

    @Test
    fun testCornerOcclusionAndAsymmetricInsetsNeverCoverTrailingControls() {
        val container = CGRect(0, 0, 800, 360)
        val camera = ControlReservedRegion(ControlReservedRegion.Kind.Occlusion, CGRect(740, 0, 60, 60))
        val insets = ControlSafeInsets(top = 0, leading = 0, bottom = 20, trailing = 40)
        val result = layout(container, safeInsets = insets, regions = listOf(camera))
        assertEquals(LandscapeTraySide.Trailing, result.side)
        assertFalse(result.trayFrame.intersects(camera.frame))
        assertFalse(result.paletteFrame.intersects(camera.frame))
        assertTrue(container.insetBy(12.0, 12.0).contains(result.trayFrame))
        // The palette still opens inward, away from the reserved edge.
        assertTrue(result.paletteFrame.maxX < result.trayFrame.minX)
        assertTrue(result.trayFrame.midX > container.midX)
    }

    @Test
    fun testAvoidNotchOffKeepsItsMeaningForOcclusionsButNeverForDivisions() {
        val container = CGRect(0, 0, 800, 360)
        val camera = ControlReservedRegion(ControlReservedRegion.Kind.Occlusion, CGRect(740, 0, 60, 60))
        val off = layout(container, avoidNotch = false, regions = listOf(camera))
        assertEquals(layout(container, avoidNotch = false), off)

        val fold = divisionAtX(700.0, container = landscape)
        val offWithFold = layout(landscape, avoidNotch = false, regions = listOf(fold))
        assertEquals(LandscapeTraySide.Leading, offWithFold.side)
        assertFalse(offWithFold.trayFrame.intersects(fold.frame))
        assertFalse(offWithFold.paletteFrame.intersects(fold.frame))
    }

    // MARK: C. Division / fold

    @Test
    fun testDivisionNearTrailingEdgeMovesTrayToLeadingOuterEdge() {
        val fold = divisionAtX(700.0, container = landscape)
        val result = layout(landscape, side = LandscapeTraySide.Trailing, regions = listOf(fold))
        assertEquals(LandscapeTraySide.Leading, result.side)
        eq(12, result.trayFrame.minX)
        assertFalse(result.trayFrame.intersects(fold.frame))
        assertFalse(result.paletteFrame.intersects(fold.frame))
        assertTrue(result.paletteFrame.minX > result.trayFrame.maxX)
    }

    @Test
    fun testDivisionNearLeadingEdgeMovesTrayToTrailingOuterEdge() {
        val fold = divisionAtX(120.0, container = landscape)
        val result = layout(landscape, side = LandscapeTraySide.Leading, regions = listOf(fold))
        assertEquals(LandscapeTraySide.Trailing, result.side)
        eq(844 - 12, result.trayFrame.maxX)
        assertFalse(result.trayFrame.intersects(fold.frame))
        assertFalse(result.paletteFrame.intersects(fold.frame))
    }

    /**
     * Split View style: the app's view ends at the fold, so the division
     * (with its margins) sits on — and partly beyond — one edge.
     */
    @Test
    fun testDivisionOnAnEdgeSendsControlsToTheOppositeOuterEdge() {
        val atTrailing = divisionAtX(830.0, width = 30.0, container = landscape)
        assertEquals(LandscapeTraySide.Leading, layout(landscape, side = LandscapeTraySide.Trailing, regions = listOf(atTrailing)).side)
        val atLeading = divisionAtX(-16.0, width = 30.0, container = landscape)
        val result = layout(landscape, side = LandscapeTraySide.Leading, regions = listOf(atLeading))
        assertEquals(LandscapeTraySide.Trailing, result.side)
        eq(844 - 12, result.trayFrame.maxX)
    }

    @Test
    fun testCenteredDivisionKeepsTheStoredPreferenceOnEitherSide() {
        val fold = divisionAtX(410.0, container = landscape)
        for (side in LandscapeTraySide.entries) {
            val result = layout(landscape, side = side, regions = listOf(fold))
            assertEquals(side, result.side)
            assertEquals(layout(landscape, side = side).trayFrame, result.trayFrame)
            assertFalse(result.paletteFrame.intersects(fold.frame))
        }
    }

    @Test
    fun testPaletteOpensInsideTheTraysUsablePieceOfACenteredDivision() {
        val fold = divisionAtX(410.0, container = landscape)
        for (side in LandscapeTraySide.entries) {
            val result = layout(landscape, side = side, regions = listOf(fold))
            assertFalse(result.paletteFrame.intersects(fold.frame))
            assertFalse(result.paletteFrame.intersects(result.trayFrame))
            if (side == LandscapeTraySide.Trailing) {
                assertTrue(result.paletteFrame.minX >= fold.frame.maxX)
            } else {
                assertTrue(result.paletteFrame.maxX <= fold.frame.minX)
            }
        }
    }

    @Test
    fun testPaletteMovesWithATrayDisplacedByAnOcclusion() {
        val container = CGRect(0, 0, 800, 360)
        val camera = ControlReservedRegion(ControlReservedRegion.Kind.Occlusion, CGRect(740, 0, 60, 60))
        val plain = layout(container)
        val result = layout(container, regions = listOf(camera))
        assertNotEquals(plain.trayFrame, result.trayFrame)
        assertFalse(result.paletteFrame.intersects(result.trayFrame))
        near(
            plain.trayFrame.minX - plain.paletteFrame.maxX,
            result.trayFrame.minX - result.paletteFrame.maxX, 0.5,
        )
    }

    @Test
    fun testFunctionTraySameSideFollowsEffectiveMainTraySide() {
        val fold = divisionAtX(700.0, container = landscape)
        // A tray short enough to leave room above and below it, so Same Side
        // groups keep their outer-edge anchors.
        val main = layout(landscape, side = LandscapeTraySide.Trailing, regions = listOf(fold), traySize = CGSize(44, 150))
        assertEquals(LandscapeTraySide.Leading, main.side)
        val frames = functionFrames(landscape, main = main, position = FunctionTrayPosition.SameSide, regions = listOf(fold))
        assertEquals(2, frames.size)
        for (frame in frames) {
            eq(12, frame.minX)
            assertFalse(frame.intersects(fold.frame))
            assertFalse(frame.intersects(main.trayFrame))
        }
    }

    @Test
    fun testFunctionTrayOppositeSideIsOppositeTheEffectiveSideAndNeverCrossesTheDivision() {
        // Fold at the trailing edge (Split View style): the trailing outer
        // edge has no usable space, so Opposite Side groups settle at the far
        // edge of the usable piece, just before the fold.
        val atEdge = divisionAtX(830.0, width = 30.0, container = landscape)
        val edgeMain = layout(landscape, side = LandscapeTraySide.Trailing, regions = listOf(atEdge))
        assertEquals(LandscapeTraySide.Leading, edgeMain.side)
        for (frame in functionFrames(landscape, main = edgeMain, position = FunctionTrayPosition.OppositeSide, regions = listOf(atEdge))) {
            assertFalse(frame.intersects(atEdge.frame))
            assertTrue(frame.maxX <= atEdge.frame.minX)
            assertTrue(frame.midX > landscape.midX)
        }
        // Centered fold: each side keeps a full half; Opposite Side uses the
        // other half's outer edge.
        val centered = divisionAtX(410.0, container = landscape)
        val centeredMain = layout(landscape, side = LandscapeTraySide.Trailing, regions = listOf(centered))
        for (frame in functionFrames(landscape, main = centeredMain, position = FunctionTrayPosition.OppositeSide, regions = listOf(centered))) {
            eq(12, frame.minX)
            assertFalse(frame.intersects(centered.frame))
        }
    }

    @Test
    fun testVideoOffSurfaceNeverBridgesAnActiveDivision() {
        val fold = divisionAtX(410.0, container = landscape)
        val tray = layout(landscape, regions = listOf(fold)).trayFrame
        for (mode in listOf(PointerInputMode.Trackpad, PointerInputMode.Direct)) {
            val surface = VideoOffSurfaceGeometry.interactionRect(
                container = landscape, safeInsets = ControlSafeInsets.zero, occupiedControlFrames = listOf(tray), portrait = false,
                inputMode = mode, remoteAspectSize = CGSize(16, 10), divisions = listOf(fold.frame),
            )
            assertFalse(surface.isEmpty)
            assertFalse(surface.intersects(fold.frame.insetBy(-VideoOffSurfaceGeometry.controlGap, 0.0)))
            assertFalse(surface.intersects(tray))
            if (mode == PointerInputMode.Direct) {
                near(1.6, surface.width / surface.height, 0.001)
            }
        }
        // Portrait with a horizontal fold: the tall Trackpad surface keeps
        // one side of it.
        val horizontalFold = divisionAtY(410.0, container = portrait)
        val portraitTray = layout(portrait, portrait = true, regions = listOf(horizontalFold)).trayFrame
        val surface = VideoOffSurfaceGeometry.interactionRect(
            container = portrait, safeInsets = ControlSafeInsets(top = 59, leading = 0, bottom = 34, trailing = 0),
            occupiedControlFrames = listOf(portraitTray), portrait = true, inputMode = PointerInputMode.Trackpad,
            remoteAspectSize = CGSize(16, 10), divisions = listOf(horizontalFold.frame),
        )
        assertFalse(surface.isEmpty)
        assertFalse(surface.intersects(horizontalFold.frame))
    }

    @Test
    fun testVideoOffSurfaceWithoutDivisionsIsUnchanged() {
        val tray = layout(landscape).trayFrame
        for (mode in listOf(PointerInputMode.Trackpad, PointerInputMode.Direct)) {
            val legacy = VideoOffSurfaceGeometry.interactionRect(
                container = landscape, safeInsets = ControlSafeInsets.zero, occupiedControlFrames = listOf(tray), portrait = false,
                inputMode = mode, remoteAspectSize = CGSize(16, 10),
            )
            val away = CGRect(2000, 0, 24, 390)
            assertEquals(
                legacy,
                VideoOffSurfaceGeometry.interactionRect(
                    container = landscape, safeInsets = ControlSafeInsets.zero, occupiedControlFrames = listOf(tray), portrait = false,
                    inputMode = mode, remoteAspectSize = CGSize(16, 10), divisions = listOf(away),
                ),
            )
        }
    }

    // MARK: D. Portrait inner layout

    @Test
    fun testPortraitStaysHorizontalAndBottomAnchoredBesideAVerticalFold() {
        val inner = CGRect(0, 0, 700, 800)
        val fold = divisionAtX(338.0, container = inner)
        val result = layout(inner, portrait = true, side = LandscapeTraySide.Trailing, regions = listOf(fold))
        assertEquals(ControlTrayAxis.Horizontal, result.axis)
        eq(inner.maxY - 12, result.trayFrame.maxY)
        assertFalse(result.trayFrame.intersects(fold.frame))
        assertFalse(result.paletteFrame.intersects(fold.frame))
        // Centered within the usable half on the preferred side.
        near((362.0 + 700.0) / 2, result.trayFrame.midX, 0.5)
        val leading = layout(inner, portrait = true, side = LandscapeTraySide.Leading, regions = listOf(fold))
        near(338.0 / 2, leading.trayFrame.midX, 0.5)
        for (frame in functionFrames(inner, main = result, portrait = true, position = FunctionTrayPosition.SameSide, regions = listOf(fold))) {
            assertFalse(frame.intersects(fold.frame))
            assertTrue(frame.maxY < result.trayFrame.minY)
        }
    }

    @Test
    fun testPortraitHorizontalFoldLeavesTheBottomCenteredTrayExactlyInPlace() {
        val inner = CGRect(0, 0, 700, 800)
        val fold = divisionAtY(388.0, container = inner)
        val result = layout(inner, portrait = true, regions = listOf(fold))
        assertEquals(layout(inner, portrait = true).trayFrame, result.trayFrame)
        assertEquals(layout(inner, portrait = true).paletteFrame, result.paletteFrame)
        assertEquals(ControlTrayAxis.Horizontal, result.axis)
    }

    /**
     * A fold always splits the display's longer dimension (landscape: a
     * vertical fold; portrait: a horizontal one), so the tray runs
     * parallel to it and keeps that dimension's full length. Even a tray
     * longer than the screen — which `ReceiverControlOverlay` draws at its
     * intrinsic size, centered on `trayFrame` — therefore overflows only
     * along the fold, never across it.
     */
    @Test
    fun testFullLengthTrayRunsParallelToAFoldThatSplitsTheLongerDimension() {
        fun rendered(layout: ControlTrayLayout, size: CGSize) = CGRect(
            layout.trayFrame.midX - size.width / 2, layout.trayFrame.midY - size.height / 2,
            size.width, size.height,
        )
        val wide = CGRect(0, 0, 900, 620)
        val verticalFold = divisionAtX(438.0, container = wide)
        val tallTray = CGSize(44, 700)
        for (side in LandscapeTraySide.entries) {
            val result = layout(wide, side = side, regions = listOf(verticalFold), traySize = tallTray)
            assertEquals(ControlTrayAxis.Vertical, result.axis)
            eq(wide.height - 24, result.trayFrame.height)
            assertFalse(rendered(result, tallTray).intersects(verticalFold.frame))
        }
        val tall = CGRect(0, 0, 620, 900)
        val horizontalFold = divisionAtY(438.0, container = tall)
        val wideTray = CGSize(700, 44)
        val result = layout(tall, portrait = true, regions = listOf(horizontalFold), traySize = wideTray)
        assertEquals(ControlTrayAxis.Horizontal, result.axis)
        eq(tall.width - 24, result.trayFrame.width)
        assertFalse(rendered(result, wideTray).intersects(horizontalFold.frame))
        assertFalse(result.paletteFrame.intersects(horizontalFold.frame))
    }

    // MARK: E. Dynamic changes

    @Test
    fun testFoldingAndUnfoldingRecomputesFromEachSnapshotWithoutStaleState() {
        val flat = layout(landscape, side = LandscapeTraySide.Trailing)
        val fold = divisionAtX(700.0, container = landscape)
        val folded = layout(landscape, side = LandscapeTraySide.Trailing, regions = listOf(fold))
        assertNotEquals(flat, folded)
        assertEquals(folded, layout(landscape, side = LandscapeTraySide.Trailing, regions = listOf(fold)))
        // The region disappears: nothing of it survives.
        assertEquals(flat, layout(landscape, side = LandscapeTraySide.Trailing))
        // Rotation to a new container is a fresh snapshot as well.
        assertEquals(layout(portrait, portrait = true), layout(portrait, portrait = true, regions = emptyList()))
    }

    @Test
    fun testRuntimePlacementNeverRewritesStoredPreferences() {
        val preferences = ReceiverControlPreferences()
        assertEquals(LandscapeTraySide.Trailing, preferences.preferredLandscapeSide)
        val before = preferences.deepCopy()
        val main = layout(landscape, side = preferences.preferredLandscapeSide, regions = listOf(divisionAtX(700.0, container = landscape)))
        functionFrames(landscape, main = main, position = preferences.functionTrayPosition, regions = listOf(divisionAtX(700.0, container = landscape)))
        assertEquals(LandscapeTraySide.Leading, main.side)
        assertEquals(before, preferences)
        assertEquals(LandscapeTraySide.Trailing, preferences.preferredLandscapeSide)
    }

    @Test
    fun testSegmentsSplitAroundDivisionsInOrder() {
        val area = CGRect(0, 0, 100, 50)
        val pieces = ControlPlacementArea.segments(
            area,
            listOf(CGRect(60, 0, 10, 50), CGRect(20, 0, 10, 50)),
            horizontal = true,
        )
        assertEquals(
            listOf(CGRect(0, 0, 20, 50), CGRect(30, 0, 30, 50), CGRect(70, 0, 30, 50)),
            pieces,
        )
    }
}
