import SwiftUI

/// Session Actions: opened by touching and holding the session's Settings
/// control. A modal over the live session (blurred and dimmed, framed by a
/// thin red outline that follows the screen's corners) with Back to Home —
/// Keep Connected, Lock Mac (when the Mac supports it), Disconnect from Mac and Cancel. Which actions appear and
/// what dismissing restores are decided in `ReceiverSessionActionsState` /
/// `ReceiverSessionActionsPolicy`; ReceiverScreen keeps every input from the
/// Mac while this is up.
struct SessionActionsOverlay: View {
    let macName: String
    /// Lock Mac's flow, status and confirmation (decided in `LockMacFlow`).
    @ObservedObject var workspace: WorkspaceModel
    let actions: [ReceiverSessionAction]
    let onAction: (ReceiverSessionAction) -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @AccessibilityFocusState private var titleFocused: Bool
    @State private var appeared = false

    var body: some View {
        ZStack {
            backdrop
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onCancel() }
                .accessibilityHidden(true)
            outline
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            // Centred when it fits; scrolls at large Dynamic Type or in a short landscape window.
            GeometryReader { geo in
                ScrollView {
                    card
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                        // Empty space around the card cancels too.
                        .contentShape(Rectangle())
                        .onTapGesture { onCancel() }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .scaleEffect(appeared || reduceMotion ? 1 : 0.96)
        }
        // Always light-on-dark: the picture underneath can be anything.
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("sessionActionsOverlay")
        .accessibilityAction(.escape) { onCancel() }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) { appeared = true }
        }
        .task {
            // Give VoiceOver the new screen before moving focus to the title.
            try? await Task.sleep(nanoseconds: 150_000_000)
            titleFocused = true
        }
    }

    @ViewBuilder
    private var backdrop: some View {
        if reduceTransparency {
            Color.black.opacity(0.88)
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.35)
            }
        }
    }

    /// The screen's own corner shape from the system on iOS 26+, inset by half
    /// the line so the whole stroke sits on screen. Earlier systems expose no
    /// public display corner geometry, so they get no outline rather than a guess.
    @ViewBuilder
    private var outline: some View {
        let increased = contrast == .increased
        let width: CGFloat = increased ? 4 : 2
        if #available(iOS 26, *) {
            ConcentricRectangle()
                .stroke(Color.red.opacity(increased ? 1 : 0.8), lineWidth: width)
                .padding(width / 2)
        }
    }

    private var card: some View {
        VStack(spacing: 12) {
            Text("Connected to \(macName)")
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
                .padding(.bottom, 4)
            ForEach(actions, id: \.self) { action in
                actionButton(action)
            }
            Button(role: .cancel, action: onCancel) {
                label("Cancel")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)   // Esc on a hardware keyboard
            .padding(.top, 8)
            .accessibilityIdentifier("sessionActionsCancel")
        }
        .padding(20)
        .frame(maxWidth: 400)
        .background(cardBackground)
        // A tap on the card itself, between buttons, doesn't cancel.
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture {}
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 1)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(white: 0.14))
        } else {
            shape.fill(.regularMaterial)
        }
    }

    @ViewBuilder
    private func actionButton(_ action: ReceiverSessionAction) -> some View {
        switch action {
        case .backToHome:
            Button { onAction(.backToHome) } label: {
                label("Back to Home — Keep Connected")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityHint(Text("Shows Home. The Mac keeps this display until you resume or disconnect."))
            .accessibilityIdentifier("sessionActionsHome")
        case .lockMac:
            lockMacRow
        case .disconnect:
            Button(role: .destructive) { onAction(.disconnect) } label: {
                label("Disconnect from Mac")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .accessibilityHint(Text("Ends the session. It doesn't reconnect by itself."))
            .accessibilityIdentifier("sessionActionsDisconnect")
        }
    }

    /// Lock Mac, with the flow's status under it. The confirmation presents from this row, so it
    /// shows over the overlay itself (a dialog under a sheet wouldn't).
    private var lockMacRow: some View {
        VStack(spacing: 6) {
            Button { onAction(.lockMac) } label: {
                label(workspace.lockMacBusy ? (workspace.lockFlow.isAwaiting ? "Waiting for the Mac…" : "Locking…") : "Lock Mac")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(workspace.lockMacBusy)
            .accessibilityHint(Text("Asks you to confirm. If this device doesn't have control, it asks the Mac to allow control first."))
            .accessibilityIdentifier("sessionActionsLockMac")
            .lockMacConfirmation(workspace)
            if workspace.lockFlow.isAwaiting {
                Button("Stop Waiting") { workspace.cancelLockMac() }
                    .buttonStyle(.borderless)
                    .accessibilityHint(Text("Nothing is locked."))
                    .accessibilityIdentifier("sessionActionsLockMacStop")
            }
            if let line = workspace.lockMacStatusLine {
                Text(line)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("lockMacStatus")
            }
        }
    }

    private func label(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: 30)
    }
}
