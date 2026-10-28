package com.raisecaterror.meowdisplay.core.controls

// Ported from Shared/KeyboardEditPlanner.swift.

/** Foundation's `NSRange`: a UTF-16 location and length. */
data class NSRange(val location: Int, val length: Int)

/**
 * Pure decomposition of a text-input edit (`shouldChangeTextIn:replacementText:`) into the
 * ordered wire actions the keyboard responder must forward to the Mac.
 *
 * One edit callback covers several native behaviors at once - an ordinary keystroke, every tick
 * of native repeat-on-hold Delete, Return, an accent-popup selection, a predictive-bar word
 * insertion, and autocorrect's own replacement - and this is the single place that turns any of
 * them into the right ordered `backspace*` then optional text/Return action, without ever
 * producing a duplicate or reordered send.
 */
object KeyboardEditPlanner {
    sealed interface Action {
        data object Backspace : Action
        data object ReturnKey : Action
        data class CommitText(val text: String) : Action
    }

    /**
     * @param rangeLength how many existing units are being replaced/removed (a text edit's
     *   `range.length`). Zero for a pure insertion.
     * @param replacementText what follows, if anything. Empty for a pure deletion; `"\n"` for
     *   Return; otherwise the committed text.
     * @return the actions to forward, in order. A replacement (autocorrect, predictive-bar
     *   insertion, typing over a selection) first removes the old range so the Mac's cursor
     *   position matches before any replacement text follows.
     */
    fun plan(rangeLength: Int, replacementText: String): List<Action> {
        val actions = ArrayList<Action>()
        if (rangeLength > 0) {
            repeat(rangeLength) { actions.add(Action.Backspace) }
        }
        if (replacementText == "\n") {
            actions.add(Action.ReturnKey)
        } else if (replacementText.isNotEmpty()) {
            actions.add(Action.CommitText(replacementText))
        }
        return actions
    }

    /**
     * Converts a UTF-16 range into the number of extended grapheme clusters (Swift `Character`s)
     * it spans within [text]. A single emoji, a flag, a ZWJ family sequence, or a combining-
     * character grapheme all span multiple UTF-16 units but are exactly one on-screen character
     * and one physical Backspace press. Falls back to the raw UTF-16 length for a range that
     * can't be mapped onto [text] - defensive, never crashes or silently emits nothing.
     */
    fun graphemeCount(text: String, utf16Range: NSRange): Int {
        val start = utf16Range.location
        val end = start.toLong() + utf16Range.length.toLong()
        if (start < 0 || utf16Range.length < 0 || end > text.length) return utf16Range.length
        var count = 0
        for (boundary in GraphemeSegmenter.boundaries(text)) {
            if (boundary >= start && boundary < end) count++
        }
        return count
    }
}

/**
 * Extended grapheme cluster segmentation (UAX #29, the subset Swift's `Character` applies to
 * text typed on a keyboard): CR LF, extending marks, ZWJ emoji sequences, emoji modifiers, tag
 * sequences, regional-indicator pairs, Hangul syllables. The JDK 17 `BreakIterator` does not join
 * emoji sequences, so this is hand-written.
 */
internal object GraphemeSegmenter {
    /** UTF-16 offsets at which each cluster of [text] starts. */
    fun boundaries(text: String): List<Int> {
        val result = ArrayList<Int>()
        var i = 0
        var prev = -1          // previous code point
        var riRun = 0          // regional indicators in the current run
        var pictoZwj = false   // saw Extended_Pictographic Extend* ZWJ
        var pictoSeen = false  // inside Extended_Pictographic Extend*
        while (i < text.length) {
            val cp = text.codePointAt(i)
            val brk = if (prev < 0) true else shouldBreak(prev, cp, riRun, pictoZwj)
            if (brk) {
                result.add(i)
                riRun = 0
                pictoSeen = false
                pictoZwj = false
            }
            // Update run state for the next pair.
            if (isRegionalIndicator(cp)) riRun++ else riRun = 0
            if (isExtendedPictographic(cp)) {
                pictoSeen = true
                pictoZwj = false
            } else if (pictoSeen && cp == ZWJ) {
                pictoZwj = true
            } else if (pictoSeen && isExtend(cp)) {
                pictoZwj = false
            } else {
                pictoSeen = false
                pictoZwj = false
            }
            prev = cp
            i += Character.charCount(cp)
        }
        return result
    }

    private const val ZWJ = 0x200D

    private fun shouldBreak(prev: Int, cp: Int, riRun: Int, pictoZwj: Boolean): Boolean {
        if (prev == '\r'.code && cp == '\n'.code) return false
        if (isControl(prev) || isControl(cp)) return true
        if (isHangulJoin(prev, cp)) return false
        if (isExtend(cp) || cp == ZWJ || isSpacingMark(cp)) return false
        if (isPrepend(prev)) return false
        if (pictoZwj && isExtendedPictographic(cp)) return false
        if (isRegionalIndicator(prev) && isRegionalIndicator(cp)) return riRun % 2 == 0
        return true
    }

    private fun isControl(cp: Int): Boolean {
        if (cp == ZWJ || cp == 0x200C) return false
        return when (Character.getType(cp).toByte()) {
            Character.CONTROL, Character.LINE_SEPARATOR, Character.PARAGRAPH_SEPARATOR -> true
            Character.FORMAT -> cp != 0x200D && cp != 0x200C && cp !in 0x0600..0x0605 && cp != 0x06DD &&
                cp != 0x070F && cp != 0x08E2 && cp != 0x110BD && cp != 0x110CD
            else -> false
        }
    }

    private fun isPrepend(cp: Int) = cp in 0x0600..0x0605 || cp == 0x06DD || cp == 0x070F || cp == 0x08E2

    private fun isExtend(cp: Int): Boolean {
        if (cp == 0x200C) return true
        if (cp in 0x1F3FB..0x1F3FF) return true            // emoji modifiers
        if (cp in 0xE0020..0xE007F) return true            // tags
        if (cp in 0xFE00..0xFE0F || cp in 0xE0100..0xE01EF) return true // variation selectors
        return when (Character.getType(cp).toByte()) {
            Character.NON_SPACING_MARK, Character.ENCLOSING_MARK -> true
            else -> false
        }
    }

    private fun isSpacingMark(cp: Int): Boolean =
        Character.getType(cp).toByte() == Character.COMBINING_SPACING_MARK

    private fun isRegionalIndicator(cp: Int) = cp in 0x1F1E6..0x1F1FF

    private fun isExtendedPictographic(cp: Int): Boolean =
        cp == 0x00A9 || cp == 0x00AE || cp in 0x203C..0x203D || cp == 0x2049 || cp == 0x2122 || cp == 0x2139 ||
            cp in 0x2194..0x21AA || cp in 0x231A..0x23FF || cp == 0x24C2 || cp in 0x25AA..0x25FE ||
            cp in 0x2600..0x27BF || cp in 0x2934..0x2935 || cp in 0x2B05..0x2B55 || cp == 0x3030 ||
            cp == 0x303D || cp == 0x3297 || cp == 0x3299 || cp in 0x1F000..0x1F1E5 ||
            cp in 0x1F200..0x1FAFF || cp in 0x1FC00..0x1FFFD

    private fun isHangulJoin(prev: Int, cp: Int): Boolean {
        fun l(c: Int) = c in 0x1100..0x115F || c in 0xA960..0xA97C
        fun v(c: Int) = c in 0x1160..0x11A7 || c in 0xD7B0..0xD7C6
        fun t(c: Int) = c in 0x11A8..0x11FF || c in 0xD7CB..0xD7FB
        fun syl(c: Int) = c in 0xAC00..0xD7A3
        fun lv(c: Int) = syl(c) && (c - 0xAC00) % 28 == 0
        return (l(prev) && (l(cp) || v(cp) || syl(cp))) ||
            ((lv(prev) || v(prev)) && (v(cp) || t(cp))) ||
            ((syl(prev) && !lv(prev) || t(prev)) && t(cp))
    }
}
