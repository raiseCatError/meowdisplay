package com.raisecaterror.meowdisplay.core.controls

import com.raisecaterror.meowdisplay.core.controls.KeyboardEditPlanner.Action
import org.junit.Assert.*
import org.junit.Test

class KeyboardEditPlannerTests {



    // MARK: - Committed text forwarding

    @Test
    fun testPlainKeystrokeCommitsExactlyThatText() {
        assertEquals(listOf(Action.CommitText("a")), KeyboardEditPlanner.plan(rangeLength = 0, replacementText = "a"))
    }


    @Test
    fun testEmojiAndMultiCharacterCommitsForwardAsOneAction() {
        assertEquals(listOf(Action.CommitText("👍🏽")), KeyboardEditPlanner.plan(rangeLength = 0, replacementText = "👍🏽"))
        assertEquals(listOf(Action.CommitText("café")), KeyboardEditPlanner.plan(rangeLength = 0, replacementText = "café"))
    }


    @Test
    fun testReturnProducesOnlyTheReturnActionNeverCommittedTextToo() {
        assertEquals(listOf(Action.ReturnKey), KeyboardEditPlanner.plan(rangeLength = 0, replacementText = "\n"))
    }


    @Test
    fun testEmptyEditProducesNoActions() {
        assertEquals(emptyList<PointerCommand>(), KeyboardEditPlanner.plan(rangeLength = 0, replacementText = ""))
    }


    // MARK: - Delete handling (including native repeat-on-hold)

    @Test
    fun testSingleCharacterDeleteProducesOneBackspace() {
        assertEquals(listOf(Action.Backspace), KeyboardEditPlanner.plan(rangeLength = 1, replacementText = ""))
    }


    /// Holding Delete fires this decision once per native repeat tick, each
    /// with `rangeLength == 1` — this documents that each tick maps to
    /// exactly one Backspace, so N ticks (the OS's repeat timer) naturally
    /// produce N Backspace presses without this code batching or dropping
    /// any of them.
    @Test
    fun testRepeatedSingleCharacterDeletesEachProduceOneBackspace() {
        for (unused in 0 until 5) {
            assertEquals(listOf(Action.Backspace), KeyboardEditPlanner.plan(rangeLength = 1, replacementText = ""))
        }
    }


    @Test
    fun testMultiCharacterDeleteProducesOneBackspacePerUnit() {
        assertEquals(listOf(Action.Backspace, Action.Backspace, Action.Backspace), KeyboardEditPlanner.plan(rangeLength = 3, replacementText = ""))
    }


    @Test
    fun testZeroLengthRangeWithNoReplacementProducesNothing() {
        assertEquals(emptyList<PointerCommand>(), KeyboardEditPlanner.plan(rangeLength = 0, replacementText = ""))
    }


    // MARK: - Replacement (autocorrect / predictive-bar / typing over a selection)

    @Test
    fun testReplacementDeletesTheOldRangeBeforeCommittingTheNewText() {
        // Autocorrect fixing "teh" -> "the": range covers "teh" (3 units),
        // replacement is "the". The old range must be removed first so the
        // Mac ends up with "the", not "tehthe".
        assertEquals(listOf(Action.Backspace, Action.Backspace, Action.Backspace, Action.CommitText("the")), KeyboardEditPlanner.plan(rangeLength = 3, replacementText = "the"))
    }


    @Test
    fun testTypingOverASingleCharacterSelectionReplacesItCleanly() {
        assertEquals(listOf(Action.Backspace, Action.CommitText("x")), KeyboardEditPlanner.plan(rangeLength = 1, replacementText = "x"))
    }


    @Test
    fun testReplacingASelectionWithReturnDeletesThenSendsReturnNotText() {
        assertEquals(listOf(Action.Backspace, Action.Backspace, Action.ReturnKey), KeyboardEditPlanner.plan(rangeLength = 2, replacementText = "\n"))
    }


    // MARK: - No duplicate printable text path

    @Test
    fun testAPlainInsertionNeverAlsoProducesABackspace() {
        val plan = KeyboardEditPlanner.plan(rangeLength = 0, replacementText = "z")
        assertEquals(0, plan.filter { it == Action.Backspace }.size)
        assertEquals(listOf(Action.CommitText("z")), plan)
    }


    @Test
    fun testActionCountMatchesExactlyOneCommitPlusExpectedBackspaces() {
        // Guards against any future change accidentally emitting the
        // commit text twice (e.g. once from a delegate call and once from
        // a duplicated planner invocation).
        val plan = KeyboardEditPlanner.plan(rangeLength = 2, replacementText = "hi")
        val commits = plan.filter { it is Action.CommitText }
        assertEquals(listOf(Action.CommitText("hi")), commits)
    }


    // MARK: - Grapheme-correct deletion (UTF-16 NSRange -> Character count)

    // Regression coverage for the confirmed real-device bug: typing
    // "abc😂" then pressing Backspace once deleted two characters ("ab"),
    // because the emoji is two UTF-16 units but exactly one grapheme
    // cluster (one on-screen character, one physical Backspace).

    @Test
    fun testSingleEmojiGraphemeCountsAsOneCharacterNotTwoUTF16Units() {
        val text = "abc😂"
        val range = NSRange(text.length - 2, 2)   // the emoji's two UTF-16 units
        assertEquals(1, KeyboardEditPlanner.graphemeCount(text, range))
    }


    @Test
    fun testFlagEmojiGraphemeCountsAsOneCharacter() {
        // A flag is a pair of regional-indicator scalars — 4 UTF-16 units,
        // one grapheme.
        val text = "abc🇮🇳"
        val range = NSRange(text.length - 4, 4)
        assertEquals(1, KeyboardEditPlanner.graphemeCount(text, range))
    }


    @Test
    fun testZWJFamilyEmojiGraphemeCountsAsOneCharacter() {
        // A ZWJ-joined family sequence: several scalars, one grapheme.
        val family = "👨‍👩‍👧‍👦"
        val text = "abc" + family
        val range = NSRange(3, text.length - 3)
        assertEquals(1, KeyboardEditPlanner.graphemeCount(text, range))
    }


    @Test
    fun testCombiningCharacterGraphemeCountsAsOneCharacter() {
        // "é" composed as "e" + combining acute accent (U+0301) — two UTF-16
        // units, one grapheme cluster.
        val text = "cafe\u0301"
        assertEquals(5, text.length)   // c, a, f, e, U+0301
        val range = NSRange(3, 2)   // "e" + the combining mark
        assertEquals(1, KeyboardEditPlanner.graphemeCount(text, range))
    }


    @Test
    fun testMultipleASCIICharactersCountCorrectly() {
        val text = "hello world"
        val range = NSRange(6, 5)   // "world"
        assertEquals(5, KeyboardEditPlanner.graphemeCount(text, range))
    }


    @Test
    fun testGraphemeCountFeedsPlanSoOneEmojiProducesExactlyOneBackspace() {
        val text = "abc😂"
        val range = NSRange(text.length - 2, 2)
        val count = KeyboardEditPlanner.graphemeCount(text, range)
        assertEquals(listOf(Action.Backspace), KeyboardEditPlanner.plan(rangeLength = count, replacementText = ""))
    }


    @Test
    fun testInvalidRangeFallsBackSafelyToUTF16Length() {
        // A range that doesn't correspond to any position in `text` (e.g.
        // stale/mismatched) must never crash — it degrades to the old
        // UTF-16-length approximation rather than emitting nothing.
        val range = NSRange(100, 3)   // far past "abc"'s length
        assertEquals(3, KeyboardEditPlanner.graphemeCount("abc", range))
    }


    @Test
    fun testReplacementStillDeletesGraphemeCorrectCountBeforeCommitting() {
        // Autocorrect-style replace where the replaced span includes an
        // emoji: still delete-first-then-commit, now with the right count.
        val text = "hi😂"
        val range = NSRange(text.length - 2, 2)
        val count = KeyboardEditPlanner.graphemeCount(text, range)
        assertEquals(listOf(Action.Backspace, Action.CommitText("👍")), KeyboardEditPlanner.plan(rangeLength = count, replacementText = "👍"))
    }
}
