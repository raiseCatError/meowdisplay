import SwiftUI

/// The secure pairing ceremony sheet, shared by every transport (LAN, USB,
/// Remote). It renders the shared `PairingPromptModel` state only:
/// SAS ready → local confirmed / waiting for the other device.
struct PairingConfirmationSheet: View {
    @ObservedObject var prompt: PairingPromptModel

    var body: some View {
        Group {
            if let pending = prompt.pending {
                sas(pending)
            } else if let confirmed = prompt.confirmedLocally {
                waiting(confirmed)
            }
        }
        .padding(28)
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private func sas(_ pending: PendingPairing) -> some View {
        VStack(spacing: 20) {
            Text("Pair with \(pending.peerName)?").font(.title3.bold())
            Text(pending.sas).font(.system(.largeTitle, design: .monospaced)).bold()
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
