package com.raisecaterror.meowdisplay.android.receiver

import android.view.KeyEvent

/**
 * Android key codes to USB HID keyboard-page usages (PROTOCOL.md 6.1). The
 * usage names a physical key; the Mac's own layout decides the character.
 * Modifier keys are never sent as keys: they travel as named modifiers.
 */
object HidKeyMap {
    private val usages: Map<Int, Int> = buildMap {
        for (i in 0 until 26) put(KeyEvent.KEYCODE_A + i, 4 + i)
        for (i in 1..9) put(KeyEvent.KEYCODE_1 + i - 1, 29 + i)
        put(KeyEvent.KEYCODE_0, 39)
        put(KeyEvent.KEYCODE_ENTER, 40)
        put(KeyEvent.KEYCODE_ESCAPE, 41)
        put(KeyEvent.KEYCODE_DEL, 42)
        put(KeyEvent.KEYCODE_TAB, 43)
        put(KeyEvent.KEYCODE_SPACE, 44)
        put(KeyEvent.KEYCODE_MINUS, 45)
        put(KeyEvent.KEYCODE_EQUALS, 46)
        put(KeyEvent.KEYCODE_LEFT_BRACKET, 47)
        put(KeyEvent.KEYCODE_RIGHT_BRACKET, 48)
        put(KeyEvent.KEYCODE_BACKSLASH, 49)
        put(KeyEvent.KEYCODE_SEMICOLON, 51)
        put(KeyEvent.KEYCODE_APOSTROPHE, 52)
        put(KeyEvent.KEYCODE_GRAVE, 53)
        put(KeyEvent.KEYCODE_COMMA, 54)
        put(KeyEvent.KEYCODE_PERIOD, 55)
        put(KeyEvent.KEYCODE_SLASH, 56)
        for (i in 0 until 12) put(KeyEvent.KEYCODE_F1 + i, 58 + i)
        put(KeyEvent.KEYCODE_INSERT, 73)
        put(KeyEvent.KEYCODE_MOVE_HOME, 74)
        put(KeyEvent.KEYCODE_PAGE_UP, 75)
        put(KeyEvent.KEYCODE_FORWARD_DEL, 76)
        put(KeyEvent.KEYCODE_MOVE_END, 77)
        put(KeyEvent.KEYCODE_PAGE_DOWN, 78)
        put(KeyEvent.KEYCODE_DPAD_RIGHT, 79)
        put(KeyEvent.KEYCODE_DPAD_LEFT, 80)
        put(KeyEvent.KEYCODE_DPAD_DOWN, 81)
        put(KeyEvent.KEYCODE_DPAD_UP, 82)
        put(KeyEvent.KEYCODE_NUMPAD_DIVIDE, 84)
        put(KeyEvent.KEYCODE_NUMPAD_MULTIPLY, 85)
        put(KeyEvent.KEYCODE_NUMPAD_SUBTRACT, 86)
        put(KeyEvent.KEYCODE_NUMPAD_ADD, 87)
        put(KeyEvent.KEYCODE_NUMPAD_ENTER, 88)
        for (i in 1..9) put(KeyEvent.KEYCODE_NUMPAD_1 + i - 1, 88 + i)
        put(KeyEvent.KEYCODE_NUMPAD_0, 98)
        put(KeyEvent.KEYCODE_NUMPAD_DOT, 99)
        put(KeyEvent.KEYCODE_NUMPAD_EQUALS, 103)
    }

    fun usage(keyCode: Int): Int? = usages[keyCode]

    /** Named protocol modifiers held with a key, in the iOS hardware order. Meta (⌘/Windows key) is Command, Alt is Option. */
    fun modifierNames(metaState: Int): List<String> = buildList {
        if (metaState and KeyEvent.META_SHIFT_ON != 0) add("shift")
        if (metaState and KeyEvent.META_CTRL_ON != 0) add("control")
        if (metaState and KeyEvent.META_ALT_ON != 0) add("option")
        if (metaState and KeyEvent.META_META_ON != 0) add("command")
        if (metaState and KeyEvent.META_CAPS_LOCK_ON != 0) add("capsLock")
    }

    /** Command or Control with a key means a shortcut for the Mac; Option alone still types its character. */
    fun isShortcut(metaState: Int): Boolean = metaState and (KeyEvent.META_META_ON or KeyEvent.META_CTRL_ON) != 0
}
