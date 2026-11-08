import SwiftUI

/// The strip over the picture while the Mac's own lock screen is shown on this device
/// (`lockScreen == .active`). The password is typed on the Mac's lock screen through the ordinary
/// Full Desktop keyboard; this view never has a text field and never sees what is typed.
struct LockScreenBanner: View {
    let keyboardAvailable: Bool
    let onKeyboard: () -> Void
    let onHide: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("Mac lock screen", systemImage: "lock.fill")
                .font(.footnote.weight(.semibold))
                .accessibilityIdentifier("lockScreenTitle")
            Spacer(minLength: 8)
            Button(action: onKeyboard) { Label("Keyboard", systemImage: "keyboard") }
                .disabled(!keyboardAvailable)
                .accessibilityIdentifier("lockScreenKeyboard")
            Button("Hide", action: onHide)
                .accessibilityIdentifier("lockScreenHide")
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
