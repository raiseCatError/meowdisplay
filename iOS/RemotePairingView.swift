import SwiftUI

/// Pair with a Mac that isn't visible on the local network, using an address
/// the user types (Tailscale IP, MagicDNS name, or any reachable host). The
/// address is only a routing hint: pairing still shows a code on both devices
/// that must be confirmed on both, and nothing is trusted until then.
///
/// One sheet covers the whole lifecycle, driven by `receiver.remotePairingState`:
/// form (idle) → progress (connecting) → failure. The SAS confirmation sheet is
/// presented from the root, so the presenting `IdleView` hides this sheet while
/// a SAS is pending.
struct RemotePairingView: View {
    @ObservedObject var receiver: StreamReceiver
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var errorMessage: String?

    var body: some View {
        switch receiver.remotePairingState {
        case .connecting: progress
        case .failed(let kind): failure(kind)
        case .idle, .succeeded: form
        }
    }

    private var form: some View {
        Form {
            Section {
                Text("On the Mac, open Devices and choose Open Pair over Remote, then enter the Mac's Tailscale address or MagicDNS name here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Mac Address") {
                TextField("Tailscale IP or MagicDNS name", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: host) { _ in errorMessage = nil }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
                Button("Pair") { start() }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .navigationTitle("Pair over Remote")
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear {
            if host.isEmpty, let last = receiver.remotePairingRetry.lastEndpoint { host = last.host }
        }
    }

    private var progress: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            let waiting = receiver.pairingPrompt.confirmedLocally
            Text(waiting == nil ? PairingCopy.connectingTitle : PairingCopy.waitingTitle).font(.headline)
            Text(waiting == nil
                 ? PairingCopy.connectingHelper(target: .mac)
                 : PairingCopy.waitingHelper(otherDevice: PairingCopy.otherDevice(localIsMac: false, peerName: waiting?.peerName ?? "")))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !receiver.pairingPrompt.isCommitting {
                Button("Cancel", role: .cancel) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    receiver.cancelRemotePairing()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failure(_ kind: RemotePairingFailureKind) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
            Text(kind.title).font(.headline).multilineTextAlignment(.center)
            if let detail = kind.detail {
                Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack {
                Button("Close") { receiver.acknowledgeRemotePairingResult(); dismiss() }
                    .buttonStyle(.bordered)
                if kind.isRetryable {
                    Button("Try Again") { receiver.retryRemotePairing() }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func start() {
        switch RemotePairingEndpoint.make(host: host) {
        case .success(let endpoint): receiver.pairWithRemoteHost(endpoint)
        case .failure(.emptyHost): errorMessage = "Enter a host or IP address."
        case .failure: errorMessage = "That doesn't look like a valid host or IP address."
        }
    }
}

/// Small transient confirmation; not a notification framework.
struct PairedToast: View {
    var body: some View {
        VStack(spacing: 2) {
            Text("Paired Successfully").font(.subheadline.weight(.semibold))
            Text("You can now connect to this Mac.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}
