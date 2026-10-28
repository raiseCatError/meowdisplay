package com.raisecaterror.meowdisplay.core.controls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The persisted form matches what the Swift receiver's JSONEncoder writes, and old schemas migrate the same way. */
class ControlPreferencesJsonTest {
    private class MapStore : PreferenceBlobStore {
        val values = mutableMapOf<String, String>()
        override fun read(key: String) = values[key]
        override fun write(key: String, value: String) {
            values[key] = value
        }
    }

    @Test
    fun freshPreferencesRoundTripExactly() {
        val preferences = ReceiverControlPreferences()
        preferences.activeControlProfile = ControlProfileSlot.Profile2
        preferences.functionTrayProfiles = preferences.functionTrayProfiles.map { profile ->
            profile.copy().also { it.setDisplay("undo", ShortcutButtonDisplay.Emoji("↩️")) }
        }
        val store = MapStore()
        val repository = ReceiverControlPreferencesRepository(store)
        repository.save(preferences)
        assertEquals(preferences, repository.load())
        assertEquals(preferences, preferences.deepCopy())
    }

    @Test
    fun actionsUseSwiftSynthesizedEnumShapes() {
        val item = ShortcutItem(id = "copy", title = "Copy", displayKey = "C", usage = 6, modifiers = ModifierChord(ControlModifier.Command))
        assertEquals(
            """{"id":"copy","title":"Copy","displayKey":"C","action":{"keyboardShortcut":{"_0":{"usage":6,"modifiers":{"modifiers":["command"]}}}}}""",
            item.toJson().toString(),
        )
        val gesture = ShortcutItem("launchpad", "Launchpad", ReceiverGesture.Launchpad, "square.grid.3x3")
        assertEquals("""{"receiverGesture":{"_0":"launchpad"}}""", gesture.action.toJson().toString())
        assertEquals("""{"keys":{}}""", ShortcutButtonDisplay.Keys.toJson().toString())
        val decoded = ShortcutItem.fromJson(parseJson("""{"id":"x","title":"X","displayKey":"X","action":{"sequence":{"_0":[{"action":{"receiverGesture":{"_0":"spotlight"}},"delayMs":200}]}},"display":{"text":{"_0":"Hi"}}}"""))
        assertEquals(ControlAction.Sequence(listOf(ControlActionStep(ControlAction.ReceiverGestureAction("spotlight"), 200))), decoded?.action)
        assertEquals(ShortcutButtonFace.Text("Hi"), decoded?.face)
    }

    @Test
    fun schemaOneGainsTabAndSchemaTwoCornerBecomesASide() {
        val store = MapStore()
        val profile = ControlProfile.canonical().copy(trayItems = ControlProfile.canonical().trayItems.filter { it.item != ControlTrayItem.Tab && it.item != ControlTrayItem.Dock })
        store.values[ReceiverControlPreferencesRepository.DEFAULTS_KEY] =
            """{"version":1,"preferredLandscapeCorner":"bottomLeading","profiles":[${profile.toJson()}]}"""
        val loaded = ReceiverControlPreferencesRepository(store).load()
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, loaded.version)
        assertEquals(LandscapeTraySide.Leading, loaded.preferredLandscapeSide)
        val items = loaded.profiles.single().trayItems.map { it.item }
        // Tab (schema 2) and then Dock (schema 8) each land immediately before Keyboard.
        assertEquals(items.indexOf(ControlTrayItem.Keyboard) - 2, items.indexOf(ControlTrayItem.Tab))
        assertEquals(items.indexOf(ControlTrayItem.Keyboard) - 1, items.indexOf(ControlTrayItem.Dock))
        assertTrue(loaded.profiles.single().trayItems.first { it.item == ControlTrayItem.Dock }.isVisible)
        // A save older than the opposite-side default keeps the same side.
        assertEquals(FunctionTrayPosition.SameSide, loaded.functionTrayPosition)
        assertEquals(ControlEdge.Trailing, loaded.padFunctionEdge)
    }

    @Test
    fun schemaSixteenMigrationAndNewerSchemasFallBack() {
        val store = MapStore()
        store.values[ReceiverControlPreferencesRepository.DEFAULTS_KEY] =
            """{"version":15,"smartTouchEnabled":false,"autoHideEnabled":false,"pinchTarget":"app","rotateTarget":"viewport","padShowControlHints":true}"""
        val loaded = ReceiverControlPreferencesRepository(store).load()
        assertTrue(loaded.smartTouchEnabled)
        assertTrue(loaded.autoHideEnabled)
        assertEquals(ReceiverGestureTarget.Viewport, loaded.pinchTarget)
        assertEquals(ReceiverGestureTarget.Disabled, loaded.rotateTarget)
        assertFalse(loaded.padShowControlHints)

        val initial = ReceiverControlPreferences(trayEnabled = false)
        store.values[ReceiverControlPreferencesRepository.DEFAULTS_KEY] = """{"version":99}"""
        assertEquals(initial, ReceiverControlPreferencesRepository(store).load(initial))
        store.values[ReceiverControlPreferencesRepository.DEFAULTS_KEY] = """{"trayEnabled":"yes"}"""
        assertEquals(initial, ReceiverControlPreferencesRepository(store).load(initial))
        assertNull(ReceiverControlPreferences.decode(parseJson("[]")))
    }

    @Test
    fun receiverUIUpdateAppliesOnlySuppliedFields() {
        val message = parseJson("""{"type":"receiverUI","trayEnabled":false,"trackpadSensitivity":9,"inputMode":"trackpad","bogus":1}""").obj()!!
        val update = ReceiverUIPreferenceUpdate.parse(message)!!
        val preferences = ReceiverControlPreferences()
        update.apply(preferences)
        assertFalse(preferences.trayEnabled)
        assertEquals(2.0, preferences.trackpadSensitivity, 0.0)
        assertEquals(PointerInputMode.Trackpad, preferences.inputMode)
        assertTrue(preferences.keyboardButtonEnabled)
        assertNull(ReceiverUIPreferenceUpdate.parse(parseJson("""{"type":"receiverUI"}""").obj()!!))
    }
}
