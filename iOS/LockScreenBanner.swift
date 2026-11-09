import SwiftUI

/// The strip over the picture while the Mac's own lock screen is shown on this device
/// (`lockScreen == .active`). The password is typed with the lock screen's own key input
/// (`LockScreenKeyInputView`: no document, so no predictions, AutoFill or echo); this view never
/// has a text field and never sees what is typed.
struct LockScreenBanner: View {
    let keyboardAvailable: Bool
    let onKeyboard: () -> Void
    let onHide: () -> Void

    /// `compact`: an iPhone's width: icons, still labelled for VoiceOver.
    private func row(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            Label("Mac lock screen", systemImage: "lock.fill")
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("lockScreenTitle")
            Spacer(minLength: compact ? 4 : 8)
            Button(action: onKeyboard) {
                if compact {
                    Label("Keyboard", systemImage: "keyboard").labelStyle(.iconOnly)
                } else {
                    Label("Keyboard", systemImage: "keyboard")
                }
            }
            .disabled(!keyboardAvailable)
            .accessibilityLabel("Keyboard")
            .accessibilityIdentifier("lockScreenKeyboard")
            Button("Hide", action: onHide)
                .accessibilityIdentifier("lockScreenHide")
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(compact: false)
            row(compact: true)
        }
        .font(.footnote)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lockScreenBanner")
    }
}
