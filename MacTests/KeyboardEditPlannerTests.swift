import Foundation
import XCTest

/// Pure-logic coverage for the M4 native-keyboard edit decomposition. The
/// UIKit responder itself (`RemoteKeyboardInputView.swift`) can't be
/// exercised here — it's iOS/UIKit-only and this is a hostless macOS test
/// bundle — so this covers exactly the part that decides *what* to forward
/// and *in what order*, which is where a duplicate-text or wrong-ordering
/// bug would actually live.
final class KeyboardEditPlannerTests: XCTestCase {

    // MARK: - Committed text forwarding

    func testPlainKeystrokeCommitsExactlyThatText() {
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: 0, replacementText: "a"),
                       [.commitText("a")])
    }

    func testEmojiAndMultiCharacterCommitsForwardAsOneAction() {
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: 0, replacementText: "👍🏽"),
                       [.commitText("👍🏽")])
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: 0, replacementText: "café"),
                       [.commitText("café")])
    }

    func testReturnProducesOnlyTheReturnActionNeverCommittedTextToo() {
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: 0, replacementText: "\n"),
                       [.returnKey])
    }

    func testEmptyEditProducesNoActions() {
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: 0, replacementText: ""), [])
    }

    // MARK: - Delete handling (including native repeat-on-hold)

    func testSingleCharacterDeleteProducesOneBackspace() {
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: 1, replacementText: ""),
                       [.backspace])
    }

    /// Holding Delete fires this decision once per native repeat tick, each
    /// with `rangeLength == 1` — this documents that each tick maps to
    /// exactly one Backspace, so N ticks (the OS's repeat timer) naturally
    /// produce N Backspace presses without this code batching or dropping
    /// any of them.
    func testRepeatedSingleCharacterDeletesEachProduceOneBackspace() {
        for _ in 0..<5 {
            XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: 1, replacementText: ""), [.backspace])
        }
    }

    func testMultiCharacterDeleteProducesOneBackspacePerUnit() {
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: 3, replacementText: ""),
                       [.backspace, .backspace, .backspace])
    }

    func testZeroLengthRangeWithNoReplacementProducesNothing() {
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: 0, replacementText: ""), [])
    }

    // MARK: - Replacement (autocorrect / predictive-bar / typing over a selection)

    func testReplacementDeletesTheOldRangeBeforeCommittingTheNewText() {
        // Autocorrect fixing "teh" -> "the": range covers "teh" (3 units),
        // replacement is "the". The old range must be removed first so the
        // Mac ends up with "the", not "tehthe".
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: 3, replacementText: "the"),
                       [.backspace, .backspace, .backspace, .commitText("the")])
    }

    func testTypingOverASingleCharacterSelectionReplacesItCleanly() {
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: 1, replacementText: "x"),
                       [.backspace, .commitText("x")])
    }

    func testReplacingASelectionWithReturnDeletesThenSendsReturnNotText() {
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: 2, replacementText: "\n"),
                       [.backspace, .backspace, .returnKey])
    }

    // MARK: - No duplicate printable text path

    func testAPlainInsertionNeverAlsoProducesABackspace() {
        let plan = KeyboardEditPlanner.plan(rangeLength: 0, replacementText: "z")
        XCTAssertEqual(plan.filter { $0 == .backspace }.count, 0)
        XCTAssertEqual(plan, [.commitText("z")])
    }

    func testActionCountMatchesExactlyOneCommitPlusExpectedBackspaces() {
        // Guards against any future change accidentally emitting the
        // commit text twice (e.g. once from a delegate call and once from
        // a duplicated planner invocation).
        let plan = KeyboardEditPlanner.plan(rangeLength: 2, replacementText: "hi")
        let commits = plan.filter { if case .commitText = $0 { return true }; return false }
        XCTAssertEqual(commits, [.commitText("hi")])
    }

    // MARK: - Grapheme-correct deletion (UTF-16 NSRange -> Character count)

    // Regression coverage for the confirmed real-device bug: typing
    // "abc😂" then pressing Backspace once deleted two characters ("ab"),
    // because the emoji is two UTF-16 units but exactly one grapheme
    // cluster (one on-screen character, one physical Backspace).

    func testSingleEmojiGraphemeCountsAsOneCharacterNotTwoUTF16Units() {
        let text = "abc😂"
        let utf16 = text as NSString
        let range = NSRange(location: utf16.length - 2, length: 2)   // the emoji's two UTF-16 units
        XCTAssertEqual(KeyboardEditPlanner.graphemeCount(in: text, utf16Range: range), 1)
    }

    func testFlagEmojiGraphemeCountsAsOneCharacter() {
        // A flag is a pair of regional-indicator scalars — 4 UTF-16 units,
        // one grapheme.
        let text = "abc🇮🇳"
        let utf16 = text as NSString
        let range = NSRange(location: utf16.length - 4, length: 4)
        XCTAssertEqual(KeyboardEditPlanner.graphemeCount(in: text, utf16Range: range), 1)
    }

    func testZWJFamilyEmojiGraphemeCountsAsOneCharacter() {
        // A ZWJ-joined family sequence: several scalars, one grapheme.
        let family = "👨‍👩‍👧‍👦"
        let text = "abc" + family
        let utf16 = text as NSString
        let range = NSRange(location: 3, length: utf16.length - 3)
        XCTAssertEqual(KeyboardEditPlanner.graphemeCount(in: text, utf16Range: range), 1)
    }

    func testCombiningCharacterGraphemeCountsAsOneCharacter() {
        // "é" composed as "e" + combining acute accent (U+0301) — two UTF-16
        // units, one grapheme cluster.
        let text = "cafe\u{0301}"
        let utf16 = text as NSString
        XCTAssertEqual(utf16.length, 5)   // c, a, f, e, U+0301
        let range = NSRange(location: 3, length: 2)   // "e" + the combining mark
        XCTAssertEqual(KeyboardEditPlanner.graphemeCount(in: text, utf16Range: range), 1)
    }

    func testMultipleASCIICharactersCountCorrectly() {
        let text = "hello world"
        let range = NSRange(location: 6, length: 5)   // "world"
        XCTAssertEqual(KeyboardEditPlanner.graphemeCount(in: text, utf16Range: range), 5)
    }

    func testGraphemeCountFeedsPlanSoOneEmojiProducesExactlyOneBackspace() {
        let text = "abc😂"
        let utf16 = text as NSString
        let range = NSRange(location: utf16.length - 2, length: 2)
        let count = KeyboardEditPlanner.graphemeCount(in: text, utf16Range: range)
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: count, replacementText: ""), [.backspace])
    }

    func testInvalidRangeFallsBackSafelyToUTF16Length() {
        // A range that doesn't correspond to any position in `text` (e.g.
        // stale/mismatched) must never crash — it degrades to the old
        // UTF-16-length approximation rather than emitting nothing.
        let range = NSRange(location: 100, length: 3)   // far past "abc"'s length
        XCTAssertEqual(KeyboardEditPlanner.graphemeCount(in: "abc", utf16Range: range), 3)
    }

    func testReplacementStillDeletesGraphemeCorrectCountBeforeCommitting() {
        // Autocorrect-style replace where the replaced span includes an
        // emoji: still delete-first-then-commit, now with the right count.
        let text = "hi😂"
        let utf16 = text as NSString
        let range = NSRange(location: utf16.length - 2, length: 2)
        let count = KeyboardEditPlanner.graphemeCount(in: text, utf16Range: range)
        XCTAssertEqual(KeyboardEditPlanner.plan(rangeLength: count, replacementText: "👍"),
                       [.backspace, .commitText("👍")])
    }
}
