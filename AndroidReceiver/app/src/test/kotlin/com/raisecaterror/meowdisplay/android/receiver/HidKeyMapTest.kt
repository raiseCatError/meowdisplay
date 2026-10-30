package com.raisecaterror.meowdisplay.android.receiver

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Test

/** Android never hands Meta (⌘) combinations to apps, so Control can stand in for ⌘ on request. */
class HidKeyMapTest {
    @Test
    fun controlIsControlUnlessItStandsInForCommand() {
        val ctrlShift = KeyEvent.META_CTRL_ON or KeyEvent.META_SHIFT_ON
        assertEquals(listOf("shift", "control"), HidKeyMap.modifierNames(ctrlShift))
        assertEquals(listOf("shift", "command"), HidKeyMap.modifierNames(ctrlShift, controlAsCommand = true))
        assertEquals(listOf("command"), HidKeyMap.modifierNames(KeyEvent.META_META_ON or KeyEvent.META_CTRL_ON, controlAsCommand = true))
        assertEquals(listOf("option"), HidKeyMap.modifierNames(KeyEvent.META_ALT_ON, controlAsCommand = true))
        assertEquals("control", HidKeyMap.modifierKeyName(KeyEvent.KEYCODE_CTRL_LEFT))
        assertEquals("command", HidKeyMap.modifierKeyName(KeyEvent.KEYCODE_CTRL_RIGHT, controlAsCommand = true))
        assertEquals("command", HidKeyMap.modifierKeyName(KeyEvent.KEYCODE_META_LEFT))
    }
}
