import XCTest

/// The typing strip's model: it must read exactly like what the Mac received,
/// including deletes and autocorrect replacements, and clear whenever the
/// receiver can no longer follow the caret.
final class TypedTextEchoTests: XCTestCase {
    private func echo(_ edits: [TypedTextEcho.Edit]) -> TypedTextEcho {
        var echo = TypedTextEcho()
        for edit in edits { echo.apply(edit) }
        return echo
    }

    func testStartsEmpty() {
        let e = TypedTextEcho()
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(e.text, "")
        XCTAssertEqual(e.tail(), "")
    }

    func testCommittedTextAppends() {
        XCTAssertEqual(echo([.commit("Hel"), .commit("lo")]).text, "Hello")
    }

    func testComposingTextShowsAfterCommittedAndIsReplacedByTheCommit() {
        var e = echo([.commit("Hi "), .composing("wor")])
        XCTAssertEqual(e.text, "Hi wor")
        XCTAssertEqual(e.committed, "Hi ")
        e.apply(.composing("world"))
        XCTAssertEqual(e.text, "Hi world")
        e.apply(.commit("world "))
        XCTAssertEqual(e.composing, "")
        XCTAssertEqual(e.text, "Hi world ")
    }

    func testDeleteRemovesCharactersFromTheEndAndNeverGoesNegative() {
        XCTAssertEqual(echo([.commit("abc"), .delete(1)]).text, "ab")
        XCTAssertEqual(echo([.commit("abc"), .delete(2)]).text, "a")
        XCTAssertEqual(echo([.commit("abc"), .delete(10)]).text, "")
        XCTAssertEqual(echo([.delete(3)]).text, "")
        XCTAssertEqual(echo([.commit("abc"), .delete(0)]).text, "abc")
    }

    func testDeleteCountsOneBackspacePerGraphemeLikeTheMac() {
        // An emoji, a flag and a combining sequence are each one Backspace.
        XCTAssertEqual(echo([.commit("a👍🏽"), .delete(1)]).text, "a")
        XCTAssertEqual(echo([.commit("x🇮🇳"), .delete(1)]).text, "x")
        XCTAssertEqual(echo([.commit("cafe\u{301}"), .delete(1)]).text, "caf")
    }

    func testDeleteLeavesTheComposingWordAlone() {
        // The Mac never received the composing word, so Backspace cannot touch it.
        let e = echo([.commit("ab"), .composing("cd"), .delete(1)])
        XCTAssertEqual(e.committed, "a")
        XCTAssertEqual(e.composing, "cd")
    }

    func testAutocorrectReplacementReadsLikeTheMac() {
        // "teh " typed, then autocorrect replaces the 3-letter word: UIKit's
        // edit is range length 3 + "the", which the planner turns into
        // three Backspaces and the new text.
        var e = echo([.commit("teh")])
        for edit in TypedTextEcho.edits(for: KeyboardEditPlanner.plan(rangeLength: 3, replacementText: "the")) {
            e.apply(edit)
        }
        XCTAssertEqual(e.text, "the")
        for edit in TypedTextEcho.edits(for: KeyboardEditPlanner.plan(rangeLength: 0, replacementText: " ")) {
            e.apply(edit)
        }
        XCTAssertEqual(e.text, "the ")
    }

    func testPlannerReturnBecomesANewline() {
        let edits = TypedTextEcho.edits(for: KeyboardEditPlanner.plan(rangeLength: 0, replacementText: "\n"))
        XCTAssertEqual(edits, [.newline])
    }

    func testTheCurrentLineStartsAfterTheLastNewline() {
        var e = echo([.commit("first line"), .newline])
        XCTAssertTrue(e.isEmpty, "a fresh line shows the placeholder")
        XCTAssertEqual(e.currentLine, "")
        e.apply(.commit("second"))
        XCTAssertEqual(e.currentLine, "second")
        // Backspacing over the newline brings the previous line back, as on the Mac.
        e = echo([.commit("first line"), .newline, .delete(1)])
        XCTAssertEqual(e.currentLine, "first line")
    }

    func testResetClearsEverything() {
        var e = echo([.commit("hello"), .composing("wor")])
        e.apply(.reset)
        XCTAssertTrue(e.isEmpty)
        XCTAssertEqual(e.text, "")
        e.apply(.commit("a"))
        e.clear()
        XCTAssertEqual(e.text, "")
    }

    func testTheKeptTextIsBounded() {
        var e = TypedTextEcho()
        let chunk = String(repeating: "x", count: 100)
        for _ in 0..<5 { e.apply(.commit(chunk)) }
        XCTAssertEqual(e.committed.count, TypedTextEcho.maxCommitted)
        e.apply(.commit("END"))
        XCTAssertTrue(e.text.hasSuffix("END"))
        XCTAssertEqual(e.committed.count, TypedTextEcho.maxCommitted)
    }

    func testTailKeepsTheEndOfALongLine() {
        let e = echo([.commit("0123456789"), .composing("ab")])
        XCTAssertEqual(e.tail(maxCharacters: 5), "789ab")
        XCTAssertEqual(e.tail(maxCharacters: 100), "0123456789ab")
        XCTAssertEqual(e.tail(maxCharacters: 0), "")
    }

    func testEditsBoundToTheirPlannerOrder() {
        // Replacing a selection: backspaces first, then the text.
        let actions = KeyboardEditPlanner.plan(rangeLength: 2, replacementText: "yo")
        XCTAssertEqual(TypedTextEcho.edits(for: actions), [.delete(1), .delete(1), .commit("yo")])
    }
}
