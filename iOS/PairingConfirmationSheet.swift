import SwiftUI

/// The secure pairing ceremony sheet, shared by every transport (LAN, USB,
/// Remote). It renders the shared `PairingPromptModel` state only:
/// SAS ready → local confirmed / waiting for the other device.
struct PairingConfirmationSheet: View {
    @ObservedObject var prompt: PairingPromptModel

    var body: some View {
        // Scrolls so large text or a small screen never cuts off the code or the buttons.
        ScrollView {
            Group {
                if let pending = prompt.pending {
                    sas(pending)
                } else if let confirmed = prompt.confirmedLocally {
                    waiting(confirmed)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(28)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
    }

    private func sas(_ pending: PendingPairing) -> some View {
        VStack(spacing: 20) {
            Text("Pair with \(pending.peerName)?").font(.title3.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            // Read the code one digit at a time, not as one large number.
            Text(pending.sas).font(.system(.largeTitle, design: .monospaced)).bold()
                .speechSpellsOutCharacters()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            VStack(spacing: 4) {
                Text(PairingCopy.sasTitle).font(.subheadline.weight(.semibold))
                Text(PairingCopy.sasHelper)
                    .font(.subheadline)
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { prompt.decide(accept: false) }
                    .buttonStyle(.bordered)
                Button("Codes Match") { prompt.decide(accept: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(prompt.isAuthenticating)
            }
        }
    }

    private func waiting(_ confirmed: PendingPairing) -> some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(PairingCopy.waitingTitle).font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text(PairingCopy.waitingHelper(
                otherDevice: PairingCopy.otherDevice(localIsMac: false, peerName: confirmed.peerName)))
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !prompt.isCommitting {
                Button("Cancel", role: .cancel) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    prompt.cancelWaiting()
                }
                .buttonStyle(.bordered)
            }
        }
    }
}
