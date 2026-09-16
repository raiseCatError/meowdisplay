import SwiftUI

/// Organizes existing Tailscale/Remote functionality that already exists —
/// remote availability, route info, and endpoint hints. Remote QR pairing,
/// relay productization, and QUIC are explicitly out of scope for this
/// milestone.
struct RemoteAccessSettingsView: View {
    @ObservedObject var controller: SenderController

    private var remoteEntries: [SenderController.ActiveDisplayEntry] {
        controller.activeDisplayEntries.filter { $0.route == .remote }
    }

    private var knownRemotePeers: [(peerID: String, name: String, host: String, port: UInt16)] {
        TrustStore.shared.pinnedPeers().compactMap { peer in
            guard let hint = RemoteEndpointStore.endpoint(forPeerID: peer.peerID) else { return nil }
            return (peer.peerID, peer.displayName, hint.host, hint.port)
        }
    }

    var body: some View {
        Form {
            Section("Status") {
                if remoteEntries.isEmpty {
                    Text("No device is currently connected over Remote.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(remoteEntries) { entry in
                        LabeledContent(entry.name, value: "Connected · Remote")
                    }
                }
            }

            Section("Known Remote Endpoints") {
                if knownRemotePeers.isEmpty {
                    Text("No paired device has a saved Remote (Tailscale) address yet — this is learned automatically once a device connects over Remote at least once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(knownRemotePeers, id: \.peerID) { peer in
                        LabeledContent(peer.name, value: "\(peer.host):\(peer.port)")
                    }
                }
            }

            #if DEBUG
            Section("Manual Endpoint (DEBUG)") {
                RemoteEndpointDebugView(controller: controller)
            }
            #endif
        }
        .formStyle(.grouped)
    }
}
