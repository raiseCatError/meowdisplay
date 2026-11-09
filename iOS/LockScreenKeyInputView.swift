import ObjectiveC
import SwiftUI
import UIKit

/// The keyboard for the Mac's lock screen (SECURITY.md "Lock screen control"): what is typed here
/// is the Mac's login password, so it doesn't go through the ordinary Full Desktop keyboard
/// (`RemoteKeyboardInputView`, a real text view for predictions, accents and IME).
///
/// `LockScreenKeyResponder` adopts only `UIKeyInput`, never `UITextInput`: iOS gets no document,
/// so it has nothing to show in a QuickType bar, predict, autocorrect, replace, learn from or offer
/// AutoFill for. It also says secure entry (iOS then turns off dictation and keyboard learning),
/// sets no content type, and turns autocorrect, spelling, capitals and smart punctuation off
/// (`LockScreenKeyInputTraits.lockScreen`). It keeps no text: each key goes straight out, tagged
/// for the lock screen, and the strip over the keyboard shows a fixed label, never the characters
/// or how many, to VoiceOver either.
///
/// Limits: without a document there is no marked text, so input methods that compose (Chinese,
/// Japanese, Korean) can't be used here, nor the press-and-hold accent popup; characters the
/// keyboard types directly (including non-ASCII ones) work. A hardware keyboard types through the
/// same responder while it is open, and through `HardwareKeyboardForwarder` (tagged the same way)
/// while it isn't.
struct LockScreenKeyInputView: UIViewRepresentable {
    let isActive: Bool
    let onText: (String) -> Void
    let onReturn: () -> Void
    let onDelete: () -> Void
    let onRequestDismiss: () -> Void

    func makeUIView(context: Context) -> LockScreenKeyResponder {
        let view = LockScreenKeyResponder()
        update(view)
        return view
    }

    func updateUIView(_ uiView: LockScreenKeyResponder, context: Context) {
        update(uiView)
        if isActive, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isActive, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    private func update(_ view: LockScreenKeyResponder) {
        view.onText = onText
        view.onReturn = onReturn
        view.onDelete = onDelete
        view.onRequestDismiss = onRequestDismiss
    }

    static func dismantleUIView(_ uiView: LockScreenKeyResponder, coordinator: ()) {
        if uiView.isFirstResponder { uiView.resignFirstResponder() }
    }
}

/// A bare key input: no text storage, no document context (see `LockScreenKeyInputView`).
final class LockScreenKeyResponder: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?
    var onRequestDismiss: (() -> Void)?

    private static let traits = LockScreenKeyInputTraits.lockScreen

    // UITextInputTraits (from `LockScreenKeyInputTraits.lockScreen`). No `textContentType`.
    var isSecureTextEntry: Bool = LockScreenKeyResponder.traits.secureTextEntry
    var autocorrectionType: UITextAutocorrectionType = LockScreenKeyResponder.traits.autocorrection ? .default : .no
    var spellCheckingType: UITextSpellCheckingType = LockScreenKeyResponder.traits.spellChecking ? .default : .no
    var autocapitalizationType: UITextAutocapitalizationType = LockScreenKeyResponder.traits.autocapitalization ? .sentences : .none
    var smartQuotesType: UITextSmartQuotesType = LockScreenKeyResponder.traits.smartPunctuation ? .default : .no
    var smartDashesType: UITextSmartDashesType = LockScreenKeyResponder.traits.smartPunctuation ? .default : .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = LockScreenKeyResponder.traits.smartPunctuation ? .default : .no
    var keyboardType: UIKeyboardType = .default   // any character the keyboard types directly
    var returnKeyType: UIReturnKeyType = .go
    var enablesReturnKeyAutomatically: Bool = false

    private let strip = LockScreenKeyStrip()

    /// The responder must never be a text document (no predictions, AutoFill or replacement).
    static var hasNoDocumentContext: Bool {
        !class_conformsToProtocol(LockScreenKeyResponder.self, UITextInput.self)
            && class_conformsToProtocol(LockScreenKeyResponder.self, UIKeyInput.self)
    }

    init() {
        super.init(frame: .zero)
        assert(Self.hasNoDocumentContext && !Self.traits.documentContext,
               "the lock screen keyboard must not be a UITextInput")
        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Mac lock screen keyboard")
        accessibilityValue = nil
        strip.onDone = { [weak self] in
            self?.resignFirstResponder()
            self?.onRequestDismiss?()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { strip }

    // MARK: UIKeyInput

    /// Always true, so Delete always reaches the Mac (this view keeps no text to know otherwise).
    var hasText: Bool { true }

    func insertText(_ text: String) {
        for action in LockScreenKeyInputPlan.plan(insertText: text) { perform(action) }
    }

    func deleteBackward() {
        for action in LockScreenKeyInputPlan.deleteBackward { perform(action) }
    }

    private func perform(_ action: LockScreenKeyInputPlan.Action) {
        switch action {
        case .text(let t): onText?(t)
        case .returnKey: onReturn?()
        case .delete: onDelete?()
        }
    }
}

/// Over the keyboard: a fixed label and Done. Never the typed characters or their count.
final class LockScreenKeyStrip: UIInputView {
    var onDone: (() -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let label = UILabel()
        label.text = String(localized: "Typing to the Mac’s lock screen")
        label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 15), maximumPointSize: 22)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byTruncatingTail
        label.accessibilityTraits = .staticText
        label.accessibilityValue = nil
        let done = UIButton(type: .system)
        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "Done")
        done.configuration = configuration
        done.setContentHuggingPriority(.required, for: .horizontal)
        done.setContentCompressionResistancePriority(.required, for: .horizontal)
        done.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [label, done])
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let guide = safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }
}
