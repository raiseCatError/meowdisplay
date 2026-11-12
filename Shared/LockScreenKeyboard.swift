import Foundation

/// The lock screen's own keyboard on iOS (`LockScreenKeyResponder`), as plain values so they can be
/// tested off-device. What is typed there is the Mac's login password (SECURITY.md "Lock screen
/// control"), so the responder is a bare `UIKeyInput`, never a `UITextInput`: iOS has no document
/// around the caret, so there is no QuickType or prediction bar, no AutoFill, no text replacement
/// and nothing to learn from. On top of that it says secure entry (no learning, no dictation, no
/// keyboard caching), no content type (nothing for AutoFill to match), and no autocorrect,
/// spelling, capitals or smart punctuation. Nothing typed is shown, counted or read out: the strip
/// over the keyboard says a fixed label.
struct LockScreenKeyInputTraits: Equatable, Sendable {
    var secureTextEntry: Bool
    var autocorrection: Bool
    var spellChecking: Bool
    var autocapitalization: Bool
    var smartPunctuation: Bool
    /// `UITextContentType` raw value; nil sets none.
    var contentType: String?
    /// `UITextInput` (a document iOS can read, predict from and fill). Never for the lock screen.
    var documentContext: Bool
    /// The strip or accessibility shows what was typed (or how much).
    var echoesTypedText: Bool

    static let lockScreen = LockScreenKeyInputTraits(
        secureTextEntry: true, autocorrection: false, spellChecking: false, autocapitalization: false,
        smartPunctuation: false, contentType: nil, documentContext: false, echoesTypedText: false)
}

/// What one keyboard callback of the lock screen's responder sends (tagged `lockScreen`).
enum LockScreenKeyInputPlan {
    enum Action: Equatable, Sendable {
        case text(String)
        case returnKey
        case delete
    }

    /// The Mac takes text in pieces of at most this many characters.
    static let maxTextChunk = 128

    /// `insertText`: line breaks are Return; Tab and other control characters are dropped (the
    /// lock screen takes neither); the rest goes as text, in order.
    static func plan(insertText text: String) -> [Action] {
        var actions: [Action] = []
        var pending = ""
        func flush() {
            while !pending.isEmpty {
                let piece = String(pending.prefix(maxTextChunk))
                actions.append(.text(piece))
                pending.removeFirst(piece.count)
            }
        }
        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                flush()
                actions.append(.returnKey)
            } else if character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) {
                continue
            } else {
                pending.append(character)
            }
        }
        flush()
        return actions
    }

    /// `deleteBackward`.
    static let deleteBackward: [Action] = [.delete]
}
