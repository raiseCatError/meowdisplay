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
        case .failure(.emptyHost): errorMessage = String(localized: "Enter a host or IP address.")
        case .failure: errorMessage = String(localized: "That doesn't look like a valid host or IP address.")
        }
    }
}

/// Small transient confirmation; not a notification framework.
/// Compact success banner. Reads on black, on bright desktop content and
/// over the Home screen: a nearly opaque system background (not a thin
/// material that takes on whatever is behind it), a green success mark,
/// primary text, and a hairline border plus soft shadow for separation.
struct PairedToast: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Paired Successfully")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("You can now connect to this Mac.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .padding(.vertical, 11)
        .background(Color(.secondarySystemGroupedBackground).opacity(0.97),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.green.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 14, y: 4)
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
