package com.raisecaterror.meowdisplay.core.controls

// Ported from MacTests/TypedTextEchoTests.swift.

import com.raisecaterror.meowdisplay.core.controls.TypedTextEcho.Edit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The typing strip's model: it must read exactly like what the Mac received,
 * including deletes and a keyboard's word replacements, and clear whenever the
 * receiver can no longer follow the caret.
 */
class TypedTextEchoTest {
    private fun echo(vararg edits: Edit): TypedTextEcho = edits.fold(TypedTextEcho.EMPTY) { e, edit -> e.apply(edit) }

    @Test
    fun startsEmpty() {
        val e = TypedTextEcho.EMPTY
        assertTrue(e.isEmpty)
        assertEquals("", e.text)
        assertEquals("", e.tail())
    }

    @Test
    fun committedTextAppends() {
        assertEquals("Hello", echo(Edit.Commit("Hel"), Edit.Commit("lo")).text)
    }

    @Test
    fun composingTextShowsAfterCommittedAndIsReplacedByTheCommit() {
        var e = echo(Edit.Commit("Hi "), Edit.Composing("wor"))
        assertEquals("Hi wor", e.text)
        assertEquals("Hi ", e.committed)
        e = e.apply(Edit.Composing("world"))
        assertEquals("Hi world", e.text)
        e = e.apply(Edit.Commit("world "))
        assertEquals("", e.composing)
        assertEquals("Hi world ", e.text)
    }

    @Test
    fun deleteRemovesCharactersFromTheEndAndNeverGoesNegative() {
        assertEquals("ab", echo(Edit.Commit("abc"), Edit.Delete(1)).text)
        assertEquals("a", echo(Edit.Commit("abc"), Edit.Delete(2)).text)
        assertEquals("", echo(Edit.Commit("abc"), Edit.Delete(10)).text)
        assertEquals("", echo(Edit.Delete(3)).text)
        assertEquals("abc", echo(Edit.Commit("abc"), Edit.Delete(0)).text)
    }

    @Test
    fun deleteCountsOneBackspacePerGraphemeLikeTheMac() {
        // An emoji, a flag and a combining sequence are each one Backspace.
        assertEquals("a", echo(Edit.Commit("a👍🏽"), Edit.Delete(1)).text)
        assertEquals("x", echo(Edit.Commit("x🇮🇳"), Edit.Delete(1)).text)
        assertEquals("caf", echo(Edit.Commit("café"), Edit.Delete(1)).text)
    }

    @Test
    fun deleteLeavesTheComposingWordAlone() {
        // The Mac never received the composing word, so Backspace cannot touch it.
        val e = echo(Edit.Commit("ab"), Edit.Composing("cd"), Edit.Delete(1))
        assertEquals("a", e.committed)
        assertEquals("cd", e.composing)
    }

    @Test
    fun aWordReplacementReadsLikeTheMac() {
        // "teh" typed, then the keyboard replaces it: three Backspaces and the new word.
        val e = echo(Edit.Commit("teh"), Edit.Delete(1), Edit.Delete(1), Edit.Delete(1), Edit.Commit("the"), Edit.Commit(" "))
        assertEquals("the ", e.text)
    }

    @Test
    fun theCurrentLineStartsAfterTheLastNewline() {
        var e = echo(Edit.Commit("first line"), Edit.Newline)
        assertTrue("a fresh line shows the placeholder", e.isEmpty)
        assertEquals("", e.currentLine)
        e = e.apply(Edit.Commit("second"))
        assertEquals("second", e.currentLine)
        // Backspacing over the newline brings the previous line back, as on the Mac.
        e = echo(Edit.Commit("first line"), Edit.Newline, Edit.Delete(1))
        assertEquals("first line", e.currentLine)
    }

    @Test
    fun resetClearsEverything() {
        val e = echo(Edit.Commit("hello"), Edit.Composing("wor")).apply(Edit.Reset)
        assertTrue(e.isEmpty)
        assertEquals("", e.text)
        assertFalse(e.apply(Edit.Commit("a")).isEmpty)
    }

    @Test
    fun theKeptTextIsBounded() {
        var e = TypedTextEcho.EMPTY
        val chunk = "x".repeat(100)
        repeat(5) { e = e.apply(Edit.Commit(chunk)) }
        assertEquals(TypedTextEcho.MAX_COMMITTED, e.committed.length)
        e = e.apply(Edit.Commit("END"))
        assertTrue(e.text.endsWith("END"))
        assertEquals(TypedTextEcho.MAX_COMMITTED, e.committed.length)
    }

    @Test
    fun tailKeepsTheEndOfALongLine() {
        val e = echo(Edit.Commit("0123456789"), Edit.Composing("ab"))
        assertEquals("789ab", e.tail(5))
        assertEquals("0123456789ab", e.tail(100))
        assertEquals("", e.tail(0))
    }

    @Test
    fun editsAreValueEqual() {
        assertEquals(echo(Edit.Commit("a")), echo(Edit.Commit("a")))
    }
}
