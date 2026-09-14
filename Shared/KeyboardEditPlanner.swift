// Compiled into the iOS target (used by RemoteKeyboardInputView.swift) and
// the hostless Mac test target (pure-logic coverage — see
// MacTests/KeyboardEditPlannerTests.swift). Foundation-only, no UIKit, so it
// stays testable without a real text view or live keyboard events.

import Foundation

/// Pure decomposition of a text-input edit (UIKit's
/// `UITextViewDelegate.textView(_:shouldChangeTextIn:replacementText:)`,
/// concretely) into the ordered wire actions M4's keyboard responder must
/// forward to the Mac.
///
/// One edit callback covers several native behaviors at once — an ordinary
/// keystroke, every tick of native repeat-on-hold Delete, Return, an accent-
/// popup selection, a predictive-bar word insertion, and autocorrect's own
/// replacement — and this is the single place that turns any of them into
/// the right ordered `press(backspace)*` then optional text/Return action,
/// without ever producing a duplicate or reordered send.
enum KeyboardEditPlanner {
    enum Action: Equatable {
        case backspace
        case returnKey
        case commitText(String)
    }

    /// - Parameters:
    ///   - rangeLength: how many existing units are being replaced/removed
    ///     (a UITextView edit's `range.length`, in UTF-16 units). Zero for
    ///     a pure insertion.
    ///   - replacementText: what follows, if anything. Empty for a pure
    ///     deletion; `"\n"` for Return; otherwise the committed text.
    /// - Returns: the actions to forward, in order. A replacement (
    ///   autocorrect, predictive-bar insertion, typing over a selection)
    ///   first removes the old range so the Mac's cursor position matches
    ///   before any replacement text follows — that ordering is the whole
    ///   point of returning a list rather than a single action.
    static func plan(rangeLength: Int, replacementText: String) -> [Action] {
        var actions: [Action] = []
        if rangeLength > 0 {
            actions.append(contentsOf: repeatElement(.backspace, count: rangeLength))
        }
        if replacementText == "\n" {
            actions.append(.returnKey)
        } else if !replacementText.isEmpty {
            actions.append(.commitText(replacementText))
        }
        return actions
    }

    /// Converts a UTF-16 `NSRange` (as `shouldChangeTextIn` reports it, and
    /// as `plan(rangeLength:...)` above expects for backward compatibility
    /// with the wire's one-Backspace-per-key semantics) into the number of
    /// extended grapheme clusters (`Character`s) it spans within `text`.
    ///
    /// A single emoji, a flag (regional-indicator pair), a ZWJ family
    /// sequence, or a combining-character grapheme all span multiple UTF-16
    /// units but are exactly one on-screen character — and exactly one
    /// physical Backspace press, both on the Mac and in the deleted
    /// `NSRange` itself. Using `range.length` directly (the pre-fix
    /// behavior) counted UTF-16 units instead, so deleting one emoji sent
    /// two-or-more Backspace presses and ate an extra character. Falls back
    /// to the raw UTF-16 length for a range Foundation can't map onto
    /// `text` (e.g. one from a stale/mismatched string) — defensive, never
    /// crashes or silently emits nothing.
    static func graphemeCount(in text: String, utf16Range: NSRange) -> Int {
        guard let range = Range(utf16Range, in: text) else { return utf16Range.length }
        return text.distance(from: range.lowerBound, to: range.upperBound)
    }
}
