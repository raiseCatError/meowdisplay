import Foundation

/// How the receiver's keyboard behaves, as plain values (UIKit maps them in
/// `RemoteKeyboardResponderView`). While the Mac is locked, what is typed is a password for its
/// own lock screen (SECURITY.md "Lock screen control"): secure entry, no autocorrect, spelling,
/// capitals, smart punctuation or predictions (nothing learns or suggests it), and nothing of it
/// shown or read out (the typing strip shows a fixed label, never the characters or their count).
struct RemoteKeyboardTraits: Equatable, Sendable {
    var secureEntry: Bool
    var autocorrection: Bool
    var spellChecking: Bool
    /// Sentence capitals; off means none.
    var autocapitalization: Bool
    var smartPunctuation: Bool
    var inlinePrediction: Bool
    /// Marks the field as a password (`textContentType = .password`).
    var passwordContentType: Bool
    /// The typing strip (and its accessibility value) mirrors what is typed.
    var echoesTypedText: Bool

    /// The ordinary keyboard: the system's own settings for suggestions, the strip echoes.
    static let normal = RemoteKeyboardTraits(secureEntry: false, autocorrection: true, spellChecking: true,
                                             autocapitalization: true, smartPunctuation: true,
                                             inlinePrediction: true, passwordContentType: false,
                                             echoesTypedText: true)
    /// Typing into the Mac's lock screen.
    static let lockScreen = RemoteKeyboardTraits(secureEntry: true, autocorrection: false, spellChecking: false,
                                                 autocapitalization: false, smartPunctuation: false,
                                                 inlinePrediction: false, passwordContentType: true,
                                                 echoesTypedText: false)

    /// `macLocked`: the Mac said it's locked (`macLockState`), so anything typed can only reach its
    /// lock screen: always the secure traits then, shown or not.
    static func current(macLocked: Bool) -> RemoteKeyboardTraits { macLocked ? .lockScreen : .normal }
}
