package com.raisecaterror.meowdisplay.core.controls

// The keyboard rules of iOS/RemoteKeyboardInputView.swift and ReceiverScreen's
// commitKeyboardText, without UIKit: committed text goes as `text` (or as
// chord presses while an on-screen modifier chord is active), Backspace and
// Return as presses carrying that chord, and only Escape, Tab, Delete Forward
// and the arrows as held down/up keys.

import com.raisecaterror.meowdisplay.core.session.ReceiverInputSender

class RemoteKeyboardBridge(
    private val input: ReceiverInputSender,
    /** The modifiers the on-screen chord holds right now (ControlInteractionState.activeChord). */
    private val chord: () -> Set<ControlModifier>,
) {
    private val heldUsages = LinkedHashSet<Int>()

    /**
     * What the typing strip shows (iOS `TypingStripView`): this keyboard session's typing as the Mac
     * received it. Changed only by what was actually sent, so deletes and a keyboard's word
     * replacements read the same here as they land on the Mac.
     */
    var echo: TypedTextEcho = TypedTextEcho.EMPTY
        private set

    /** Called with each new [echo]. */
    var onEchoChanged: ((TypedTextEcho) -> Unit)? = null

    private fun edit(edit: TypedTextEcho.Edit) {
        val next = echo.apply(edit)
        if (next == echo) return
        echo = next
        onEchoChanged?.invoke(next)
    }

    /** The word the keyboard is composing (marked text): shown in the strip, never sent. */
    fun setComposing(text: String) = edit(TypedTextEcho.Edit.Composing(text))

    /** The keyboard opened or closed: the strip starts over. */
    fun resetEcho() = edit(TypedTextEcho.Edit.Reset)

    /** Finished text from the software or hardware keyboard — never composing (marked) text. */
    fun commitText(text: String) {
        if (text.isEmpty()) return
        val modifiers = chord()
        if (modifiers.isEmpty()) {
            if (text == "\n") returnKey() else sendText(text)
            return
        }
        // Under a chord each character with a key becomes that chord (⌘ latched, C → ⌘C); the rest stays text.
        val plain = StringBuilder()
        for (character in graphemes(text)) {
            val press = SoftwareKeyboardChordPolicy.press(character, modifiers)
            if (press == null) {
                plain.append(character)
            } else {
                if (plain.isNotEmpty()) sendText(plain.toString()).also { plain.clear() }
                // A shortcut, not typing: the strip cannot follow what it did.
                if (input.keyboardPress(press.first, press.second)) edit(TypedTextEcho.Edit.Reset)
            }
        }
        if (plain.isNotEmpty()) sendText(plain.toString())
    }

    private fun sendText(text: String) {
        if (input.keyboardText(text)) edit(TypedTextEcho.Edit.Commit(text))
    }

    fun backspace(times: Int = 1) = repeat(times) { special(BACKSPACE) }

    fun forwardDelete(times: Int = 1) = repeat(times) { special(DELETE_FORWARD) }

    fun returnKey() = special(RETURN)

    /** A one-shot special key (Escape and Tab from the bar and tray). */
    fun press(usage: Int) = special(usage)

    /** A modified hardware shortcut (⌘C from a physical keyboard): one atomic press. */
    fun shortcut(usage: Int, modifierNames: List<String>) {
        if (input.keyboardPress(usage, SoftwareKeyboardChordPolicy.modifiers(modifierNames, chord()))) edit(TypedTextEcho.Edit.Reset)
    }

    /** A physical key going down. Only [HELD_USAGES] have a lifecycle; false means "type it instead". */
    fun keyDown(usage: Int, modifierNames: List<String>): Boolean {
        if (usage !in HELD_USAGES) return false
        // One down per physical press: the Mac runs its own key repeat, like iOS.
        if (usage in heldUsages) return true
        if (input.keyboardDown(usage, SoftwareKeyboardChordPolicy.modifiers(modifierNames, chord()))) {
            heldUsages += usage
            // Arrows, Tab, Escape, Forward Delete: the caret moves or leaves the field.
            edit(TypedTextEcho.Edit.Reset)
        }
        return true
    }

    fun keyUp(usage: Int, modifierNames: List<String>): Boolean {
        if (usage !in HELD_USAGES) return false
        if (heldUsages.remove(usage)) input.keyboardUp(usage, SoftwareKeyboardChordPolicy.modifiers(modifierNames, chord()))
        return true
    }

    /** The keyboard lost focus or became unavailable: let go of every physical key still down. */
    fun releaseHeldKeys() {
        for (usage in heldUsages.toList()) input.keyboardUp(usage, emptyList())
        heldUsages.clear()
    }

    val holdsKeys: Boolean get() = heldUsages.isNotEmpty()

    private fun special(usage: Int) {
        val modifiers = SoftwareKeyboardChordPolicy.modifiers(emptyList(), chord())
        if (!input.keyboardPress(usage, modifiers)) return
        when {
            // ⌘⌫, ⌥⌫ and the like delete more than a character: the strip cannot follow.
            modifiers.isNotEmpty() -> edit(TypedTextEcho.Edit.Reset)
            usage == BACKSPACE -> edit(TypedTextEcho.Edit.Delete(1))
            usage == RETURN -> edit(TypedTextEcho.Edit.Newline)
            else -> edit(TypedTextEcho.Edit.Reset)
        }
    }

    companion object {
        const val RETURN = 40
        const val ESCAPE = 41
        const val BACKSPACE = 42
        const val TAB = 43
        const val DELETE_FORWARD = 76
        const val RIGHT = 79
        const val LEFT = 80
        const val DOWN = 81
        const val UP = 82

        /** The only physical keys sent as down/up (RemoteKeyboardInputView.forwardedUsages). */
        val HELD_USAGES = setOf(ESCAPE, TAB, DELETE_FORWARD, RIGHT, LEFT, DOWN, UP)

        fun graphemes(text: String): List<String> {
            val starts = GraphemeSegmenter.boundaries(text)
            return starts.indices.map { i -> text.substring(starts[i], if (i + 1 < starts.size) starts[i + 1] else text.length) }
        }
    }
}
