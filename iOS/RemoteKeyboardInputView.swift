import SwiftUI
import UIKit

/// Bridges the native iOS software/hardware keyboard into the remote-display
/// UI (M4).
///
/// Backed by a real (but visually unobtrusive) `UITextView`, not a bare
/// `UIView + UIKeyInput`. A first pass used the latter to avoid maintaining
/// any local text — but a bare `UIKeyInput` responder does not get several
/// things the system keyboard otherwise provides for free to genuine
/// `UITextInput` conformers: repeat-on-hold for Delete, the press-and-hold
/// accent/alternate-character popup, the predictive QuickType suggestion
/// bar, and full marked-text/IME composition. Real text-field-adjacent
/// software (`UITextView`/`UITextField`) gets all of that automatically; a
/// bare `UIKeyInput` view only gets ordinary character and Delete calls.
/// Real on-device testing confirmed the gap (issue: holding Delete didn't
/// repeat; holding a letter showed no accent popup) — see the type's
/// `shouldChangeTextIn` delegate implementation below for how this stays
/// unobtrusive without becoming a full remote text-editor sync.
struct RemoteKeyboardInputView: UIViewRepresentable {
    @Binding var isActive: Bool
    let onCommitText: (String) -> Void
    let onSpecialPress: (Int) -> Void
    let onHardwareKeyDown: (Int, [String]) -> Void
    let onHardwareKeyUp: (Int, [String]) -> Void
    /// Invoked when the keyboard's own "Done" accessory is tapped, so the
    /// caller can drop `isActive` — the floating keyboard button lives near
    /// the bottom edge and can end up hidden behind the system keyboard
    /// itself, so the keyboard needs a dismissal control of its own.
    let onRequestDismiss: () -> Void

    func makeUIView(context: Context) -> RemoteKeyboardResponderView {
        let view = RemoteKeyboardResponderView()
        view.onCommitText = onCommitText
        view.onSpecialPress = onSpecialPress
        view.onHardwareKeyDown = onHardwareKeyDown
        view.onHardwareKeyUp = onHardwareKeyUp
        view.onRequestDismiss = onRequestDismiss
        return view
    }

    func updateUIView(_ uiView: RemoteKeyboardResponderView, context: Context) {
        // Closures may capture fresher state (e.g. a new receiver instance)
        // on each SwiftUI update — keep them current.
        uiView.onCommitText = onCommitText
        uiView.onSpecialPress = onSpecialPress
        uiView.onHardwareKeyDown = onHardwareKeyDown
        uiView.onHardwareKeyUp = onHardwareKeyUp
        uiView.onRequestDismiss = onRequestDismiss
        if isActive, !uiView.isFirstResponder {
            // Diagnostic breadcrumb for a real-device-only first-activation
            // crash under investigation — cheap, no behavior change. Remove
            // once root-caused.
            Log.info("keyboard: activating — inWindow=\(uiView.window != nil) bounds=\(uiView.bounds)")
            uiView.becomeFirstResponder()
        } else if !isActive, uiView.isFirstResponder {
            Log.info("keyboard: resigning")
            uiView.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: RemoteKeyboardResponderView, coordinator: ()) {
        // The view can be torn down without SwiftUI ever flipping `isActive`
        // back to false first (e.g. the stream stops and the whole overlay
        // is removed) — resign directly so a held hardware key isn't
        // orphaned on the Mac.
        if uiView.isFirstResponder { uiView.resignFirstResponder() }
    }
}

/// The first-responder view backing `RemoteKeyboardInputView`. See the
/// type-level doc comment above for why this is a real `UITextView`.
final class RemoteKeyboardResponderView: UITextView, UITextViewDelegate {
    var onCommitText: ((String) -> Void)?
    var onSpecialPress: ((Int) -> Void)?
    var onHardwareKeyDown: ((Int, [String]) -> Void)?
    var onHardwareKeyUp: ((Int, [String]) -> Void)?
    var onRequestDismiss: (() -> Void)?

    /// Bounds how large the underlying (never user-visible) text is allowed
    /// to grow, and how much of it survives a trim. A real, non-empty
    /// string is what unlocks native predictive-text continuation and
    /// accent-popup positioning — genuinely emptying it after every
    /// keystroke (the earlier `UIKeyInput` design) is what this replaces —
    /// but nothing requires it to grow without bound, so it's trimmed back
    /// to a short rolling tail instead of becoming a full document.
    private static let maxLocalTextLength = 64
    private static let trimmedTailLength = 16

    private var isTrimming = false

    // Tracked locally (mirrors the Mac's `HeldKeyTracker`) purely so losing
    // first-responder status can release anything still held — the Mac side
    // tolerates a redundant or spurious "up" regardless. Only ever holds
    // usages from `forwardedUsages` (arrows/Escape/Tab/forward-delete):
    // modifier keys (Command/Shift/Control/Option) held alone are never
    // captured or forwarded as their own down/up here — `modifierNames`
    // only reads their live `UIKeyModifierFlags` off whichever forwarded
    // key event they accompany — so this set cannot itself carry stale
    // modifier state across any lifecycle boundary. Cleared on every
    // activation and resignation regardless, as cheap insurance.
    private var heldUsages: Set<Int> = []

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        isScrollEnabled = false
        // Real text input (needed for native repeat/accent-popup/predictive
        // behavior), but nothing about it should read as a visible text
        // field: no visible caret or glyphs, no selection handles, no
        // system menu. `autocorrectionType`/`spellCheckingType` are left at
        // `.default` so predictive suggestions follow the system setting.
        tintColor = .clear
        textColor = .clear
        backgroundColor = .clear
        autocapitalizationType = .sentences
        inputAccessoryView = keyboardAccessoryToolbar
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: - Committed text / delete, via the real text-input delegate

    /// The single interception point for everything the system considers a
    /// *committed* edit: ordinary keystrokes, Delete (including every tick
    /// of native repeat-on-hold), Return, an accent-popup selection, a
    /// predictive-bar word insertion, and autocorrect's own replacement.
    /// Marked/IME-intermediate composition never reaches here — UIKit calls
    /// this only once composition resolves to real text — so nothing
    /// intermediate is ever forwarded twice. Returning `true` lets the real
    /// `UITextView` apply the edit normally, which is what keeps delete
    /// repeat, the accent popup, and predictive continuation working: this
    /// only forwards a description of the edit, it doesn't reimplement it.
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        // The ordering/dedup logic, and the UTF-16-range -> grapheme-count
        // conversion (one Backspace per on-screen character, not per UTF-16
        // unit — an emoji or flag is one Backspace, not two), both live in
        // `KeyboardEditPlanner` (Shared/, UIKit-free) so they're covered by
        // MacTests; this just executes the plan.
        let deleteCount = KeyboardEditPlanner.graphemeCount(in: textView.text, utf16Range: range)
        for action in KeyboardEditPlanner.plan(rangeLength: deleteCount, replacementText: text) {
            switch action {
            case .backspace:
                onSpecialPress?(Int(UIKeyboardHIDUsage.keyboardDeleteOrBackspace.rawValue))
            case .returnKey:
                onSpecialPress?(Int(UIKeyboardHIDUsage.keyboardReturnOrEnter.rawValue))
            case .commitText(let text):
                onCommitText?(text)
            }
        }
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isTrimming, textView.markedTextRange == nil,
              textView.text.count > Self.maxLocalTextLength else { return }
        // Trim off the main thread's current delegate turn so this can't
        // itself race the input system's own bookkeeping for the edit that
        // just happened.
        DispatchQueue.main.async { [weak self] in self?.trimLocalTextIfSafe() }
    }

    /// Never touches the text while marked (IME composition) text is
    /// active — that would corrupt the composition session.
    private func trimLocalTextIfSafe() {
        guard markedTextRange == nil, text.count > Self.maxLocalTextLength else { return }
        isTrimming = true
        text = String(text.suffix(Self.trimmedTailLength))
        let end = endOfDocument
        selectedTextRange = textRange(from: end, to: end)
        isTrimming = false
    }

    // MARK: - Guaranteed dismissal

    // Always present while this view is first responder, so the system
    // keyboard itself carries a way to close it even where the floating
    // keyboard button ends up covered by the keyboard. `UITextView` already
    // declares `inputAccessoryView` as a plain settable property (unlike a
    // bare `UIResponder`, where it would need overriding), so it's just
    // assigned once here.
    private lazy var keyboardAccessoryToolbar: UIToolbar = {
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(dismissTapped)),
        ]
        toolbar.sizeToFit()
        return toolbar
    }()

    @objc private func dismissTapped() {
        resignFirstResponder()
        onRequestDismiss?()
    }

    // MARK: - Hardware keys the text-input system doesn't route as text

    private static let forwardedUsages: Set<Int> = [
        UIKeyboardHIDUsage.keyboardEscape,
        .keyboardTab,
        .keyboardDeleteForward,
        .keyboardLeftArrow,
        .keyboardRightArrow,
        .keyboardUpArrow,
        .keyboardDownArrow,
    ].map { Int($0.rawValue) }.reduce(into: Set<Int>()) { $0.insert($1) }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var remaining = presses
        for press in presses {
            guard let key = press.key else { continue }
            let usage = Int(key.keyCode.rawValue)
            guard Self.forwardedUsages.contains(usage) else { continue }
            heldUsages.insert(usage)
            onHardwareKeyDown?(usage, Self.modifierNames(key.modifierFlags))
            remaining.remove(press)
        }
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var remaining = presses
        for press in presses {
            guard let key = press.key else { continue }
            let usage = Int(key.keyCode.rawValue)
            guard Self.forwardedUsages.contains(usage) else { continue }
            heldUsages.remove(usage)
            onHardwareKeyUp?(usage, Self.modifierNames(key.modifierFlags))
            remaining.remove(press)
        }
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Treat a cancelled press like a release so a key can't get stuck
        // held — the Mac tolerates a spurious "up" for a key it never saw
        // "down" for.
        pressesEnded(presses, with: event)
    }

    @discardableResult
    override func becomeFirstResponder() -> Bool {
        // Defensive: a fresh focus should never inherit tracked state from
        // a previous session (reconnect, view reuse across SwiftUI updates,
        // or a resign that raced a press callback). Starting clean means a
        // stray leftover entry can't suppress a genuinely new key's down.
        heldUsages.removeAll()
        let result = super.becomeFirstResponder()
        // Diagnostic breadcrumb for a real-device-only first-activation
        // crash under investigation — cheap, no behavior change. Remove
        // once root-caused.
        Log.info("keyboard: becomeFirstResponder -> \(result)")
        return result
    }

    @discardableResult
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        releaseHeldKeys()
        // Also drop the rolling local text on close — nothing carries it
        // forward across a keyboard session, and it never needs to.
        if markedTextRange == nil { text = "" }
        return result
    }

    private func releaseHeldKeys() {
        guard !heldUsages.isEmpty else { return }
        for usage in heldUsages { onHardwareKeyUp?(usage, []) }
        heldUsages.removeAll()
    }

    private static func modifierNames(_ flags: UIKeyModifierFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.alternate) { names.append("option") }
        if flags.contains(.command) { names.append("command") }
        if flags.contains(.alphaShift) { names.append("capsLock") }
        return names
    }
}
