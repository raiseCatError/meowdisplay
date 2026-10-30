package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/TypedTextEcho.swift.

/**
 * What the typing strip shows: the tail of what was typed in this keyboard
 * session, as the Mac received it, plus the word still being composed (text
 * the Mac has not been sent yet).
 *
 * It is a mirror of the wire, never a second source of truth: every edit is
 * applied from the same call that sent it (committed text, Backspace,
 * Return), so a keyboard's replacement of a word and its deletes read the same
 * on the phone as they land on the Mac. Anything the receiver cannot follow
 * (an arrow key, Escape, Tab, a modified shortcut) makes the position unknown,
 * so the strip is cleared rather than showing text the Mac no longer has at
 * the caret. Nothing here is ever sent anywhere.
 *
 * Immutable: each edit returns the next value, which is what a Compose state
 * holder wants.
 */
class TypedTextEcho private constructor(
    /** Finished text the Mac has, newest last, bounded to [MAX_COMMITTED] characters. */
    val committed: String,
    /** The word being composed; never sent to the Mac. */
    val composing: String,
) {
    sealed interface Edit {
        /** Finished text; replaces any composing text. */
        data class Commit(val text: String) : Edit
        /** The word being composed (IME). Never sent to the Mac. */
        data class Composing(val text: String) : Edit
        /** That many Backspace presses. */
        data class Delete(val count: Int) : Edit
        /** Return. */
        data object Newline : Edit
        /** The caret moved or the position is otherwise unknown. */
        data object Reset : Edit
    }

    /** Everything kept, committed then composing. */
    val text: String get() = committed + composing

    /** The line being typed: text after the last newline. */
    val currentLine: String get() = text.substringAfterLast('\n')

    val isEmpty: Boolean get() = currentLine.isEmpty()

    /** The last [maxCharacters] characters of the current line, for a one-line label. */
    fun tail(maxCharacters: Int = 80): String {
        if (maxCharacters <= 0) return ""
        val line = currentLine
        return lastGraphemes(line, maxCharacters)
    }

    fun apply(edit: Edit): TypedTextEcho = when (edit) {
        is Edit.Commit -> TypedTextEcho(trim(committed + edit.text), "")
        is Edit.Composing -> TypedTextEcho(committed, edit.text)
        is Edit.Delete -> if (edit.count <= 0 || committed.isEmpty()) this else TypedTextEcho(dropLastGraphemes(committed, edit.count), composing)
        Edit.Newline -> TypedTextEcho(trim(committed + "\n"), "")
        Edit.Reset -> EMPTY
    }

    override fun equals(other: Any?): Boolean = other is TypedTextEcho && committed == other.committed && composing == other.composing

    override fun hashCode(): Int = 31 * committed.hashCode() + composing.hashCode()

    override fun toString(): String = "TypedTextEcho(committed=$committed, composing=$composing)"

    companion object {
        /** Characters (grapheme clusters) kept; older ones fall off the front. */
        const val MAX_COMMITTED = 160

        val EMPTY = TypedTextEcho("", "")

        private fun trim(text: String): String = lastGraphemes(text, MAX_COMMITTED)

        private fun lastGraphemes(text: String, count: Int): String {
            val starts = GraphemeSegmenter.boundaries(text)
            return if (starts.size <= count) text else text.substring(starts[starts.size - count])
        }

        private fun dropLastGraphemes(text: String, count: Int): String {
            val starts = GraphemeSegmenter.boundaries(text)
            return if (count >= starts.size) "" else text.substring(0, starts[starts.size - count])
        }
    }
}
