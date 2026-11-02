// Compiled into the iOS target (the keyboard strip) and the hostless Mac test
// target (pure-logic coverage — see MacTests/TypedTextEchoTests.swift).
// Foundation only. Ported 1:1 by AndroidReceiver/core TypedTextEcho.kt.

import Foundation

/// What the receiver's typing strip shows: the tail of what was typed in this
/// keyboard session, as the Mac received it, plus the word still being
/// composed (marked text the Mac has not been sent yet).
///
/// It is a mirror of the wire, never a second source of truth: every edit is
/// applied from the same action that was sent (committed text, Backspace,
/// Return), so autocorrect replacements and deletes read the same on the
/// phone as they land on the Mac. Anything the receiver cannot follow — an
/// arrow key, Escape, Tab, a modified shortcut — makes the position unknown,
/// so the strip is cleared rather than showing text the Mac no longer has at
/// the caret. Nothing here is ever sent anywhere.
struct TypedTextEcho: Equatable {
    /// Characters (grapheme clusters) kept; older ones fall off the front.
    static let maxCommitted = 160

    enum Edit: Equatable {
        /// Finished text; replaces any composing text.
        case commit(String)
        /// The word being composed (IME / marked text). Never sent to the Mac.
        case composing(String)
        /// That many Backspace presses.
        case delete(Int)
        /// Return.
        case newline
        /// The caret moved or the position is otherwise unknown.
        case reset
    }

    private(set) var committed = ""
    private(set) var composing = ""

    init() {}

    var isEmpty: Bool { currentLine.isEmpty }

    /// Everything kept, committed then composing.
    var text: String { committed + composing }

    /// The line being typed: text after the last newline.
    var currentLine: String {
        let all = text
        guard let newline = all.lastIndex(of: "\n") else { return all }
        return String(all[all.index(after: newline)...])
    }

    /// The last `maxCharacters` characters of the current line, for a one-line label.
    func tail(maxCharacters: Int = 80) -> String {
        let line = currentLine
        guard maxCharacters > 0, line.count > maxCharacters else { return maxCharacters > 0 ? line : "" }
        return String(line.suffix(maxCharacters))
    }

    mutating func apply(_ edit: Edit) {
        switch edit {
        case .commit(let text):
            composing = ""
            committed += text
            trim()
        case .composing(let text):
            composing = text
        case .delete(let count):
            guard count > 0, !committed.isEmpty else { return }
            committed = String(committed.dropLast(count))
        case .newline:
            composing = ""
            committed += "\n"
            trim()
        case .reset:
            committed = ""
            composing = ""
        }
    }

    mutating func clear() { apply(.reset) }

    private mutating func trim() {
        if committed.count > Self.maxCommitted { committed = String(committed.suffix(Self.maxCommitted)) }
    }

    /// The edits one keyboard callback turns into: exactly the actions
    /// `KeyboardEditPlanner` sends, in the same order.
    static func edits(for actions: [KeyboardEditPlanner.Action]) -> [Edit] {
        actions.map {
            switch $0 {
            case .backspace: return .delete(1)
            case .returnKey: return .newline
            case .commitText(let text): return .commit(text)
            }
        }
    }
}
