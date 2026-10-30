package com.raisecaterror.meowdisplay.core.controls

// Ported from MacTests/ReceiverUIPreferenceUpdateTests.swift.

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * `ReceiverUIPreferenceUpdate` decodes the Mac -> receiver `receiverUI` push and applies it onto a
 * receiver's `ReceiverControlPreferences`. Every field is additive/optional — a message naming only
 * one field must never disturb any other stored preference, and defaults must survive when a field
 * is absent entirely.
 */
class ReceiverUIPreferenceUpdateTests {
    private val receiverUI = "receiverUI" // WireMessage.receiverUI

    private fun message(vararg entries: Pair<String, JsonElement>) = JsonObject(mapOf(*entries))

    @Test
    fun testDecodesOnlyTheFieldsPresentInTheMessage() {
        val update = ReceiverUIPreferenceUpdate.parse(
            message("type" to JsonPrimitive(receiverUI), "hapticsEnabled" to JsonPrimitive(false)),
        )
        assertEquals(false, update?.hapticsEnabled)
        assertNull(update?.trayEnabled)
        assertNull(update?.inputMode)
        assertNull(update?.trackpadSensitivity)
    }

    @Test
    fun testWrongMessageTypeDecodesToNil() {
        assertNull(ReceiverUIPreferenceUpdate.parse(message("type" to JsonPrimitive("somethingElse"), "hapticsEnabled" to JsonPrimitive(false))))
    }

    @Test
    fun testEmptyKnownFieldsDecodesToNil() {
        assertNull(ReceiverUIPreferenceUpdate.parse(message("type" to JsonPrimitive(receiverUI))))
    }

    @Test
    fun testInputModeDecodesFromItsRawValue() {
        val update = ReceiverUIPreferenceUpdate.parse(
            message("type" to JsonPrimitive(receiverUI), "inputMode" to JsonPrimitive("trackpad")),
        )
        assertEquals(PointerInputMode.Trackpad, update?.inputMode)
    }

    @Test
    fun testUnknownInputModeRawValueIsIgnoredNotCrashing() {
        val update = ReceiverUIPreferenceUpdate.parse(
            message("type" to JsonPrimitive(receiverUI), "inputMode" to JsonPrimitive("not-a-real-mode")),
        )
        assertNull(update?.inputMode)
    }

    @Test
    fun testApplyOnlyTouchesFieldsThePayloadNamed() {
        val preferences = ReceiverControlPreferences()
        preferences.hapticsEnabled = true
        preferences.avoidNotch = true
        val update = ReceiverUIPreferenceUpdate.parse(
            message("type" to JsonPrimitive(receiverUI), "hapticsEnabled" to JsonPrimitive(false)),
        )!!

        update.apply(preferences)

        assertEquals(false, preferences.hapticsEnabled)
        assertEquals("a field the message never named must be left untouched", true, preferences.avoidNotch)
    }

    @Test
    fun testApplyClampsTrackpadSensitivityToItsSupportedRange() {
        val preferences = ReceiverControlPreferences()
        val update = ReceiverUIPreferenceUpdate.parse(
            message("type" to JsonPrimitive(receiverUI), "trackpadSensitivity" to JsonPrimitive(99.0)),
        )!!

        update.apply(preferences)

        assertEquals(PointerGestureConfig.trackpadSensitivityRange.endInclusive, preferences.trackpadSensitivity, 0.0)
    }

    @Test
    fun testDefaultsSurviveWhenAFieldIsNeverSent() {
        val fresh = ReceiverControlPreferences()
        val preferences = fresh.deepCopy()
        val update = ReceiverUIPreferenceUpdate.parse(
            message("type" to JsonPrimitive(receiverUI), "trayEnabled" to JsonPrimitive(false)),
        )!!

        update.apply(preferences)

        assertEquals(fresh.functionTrayEnabled, preferences.functionTrayEnabled)
        assertEquals(fresh.inputMode, preferences.inputMode)
        assertEquals(fresh.avSyncOffsetMs, preferences.avSyncOffsetMs)
    }
}
