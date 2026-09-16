#if DEBUG
import SwiftUI

/// DEBUG-only "Send LAN Wake Packet" panel shared by the iOS and Mac
/// Receiver apps. Only ever targets an already-paired Mac's previously
/// learned LAN wake hint (`WakeMetadataStore`) — never an arbitrary
/// caller-supplied MAC/host, and never over Remote/Tailscale.
struct WakeTestingView: View {
    @State private var selectedPeerID = ""
    @State private var sendResult: String?

    private var pairedPeers: [(peerID: String, displayName: String)] {
        TrustStore.shared.pinnedPeers()
    }

    private var selectedMetadata: WakeMetadata? {
        guard !selectedPeerID.isEmpty else { return nil }
        return WakeMetadataStore.metadata(forPeerID: selectedPeerID)
    }

    var body: some View {
        if pairedPeers.isEmpty {
            Text("No paired Macs").foregroundStyle(.secondary)
        } else {
            Picker("Mac", selection: $selectedPeerID) {
                Text("Select…").tag("")
                ForEach(pairedPeers, id: \.peerID) { peer in
                    Text(peer.displayName).tag(peer.peerID)
                }
            }
            if let metadata = selectedMetadata {
                wakeRow("Target MAC", metadata.macAddress)
                wakeRow("Broadcast", metadata.broadcastAddress ?? "unknown")
                wakeRow("Learned", metadata.updatedAt.formatted())
            } else if !selectedPeerID.isEmpty {
                Text("No LAN wake info learned yet for this Mac — connect to it at least once first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Send LAN Wake Packet") { send() }
                .disabled(selectedMetadata?.broadcastAddress == nil)
            if let sendResult {
                Text(sendResult).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// `LabeledContent` needs macOS 13; the Mac Receiver target's floor is
    /// macOS 12 (see `project.yml`), so this stays a plain `HStack` row.
    private func wakeRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private func send() {
        guard let metadata = selectedMetadata, let broadcast = metadata.broadcastAddress else { return }
        let packetBytes = WakeOnLAN.magicPacket(macAddress: metadata.macAddress)?.count ?? 0
        Log.info("wakeDebug: targetPeer=\(selectedPeerID)")
        Log.info("wakeDebug: mac=\(metadata.macAddress)")
        Log.info("wakeDebug: broadcast=\(broadcast)")
        Log.info("wakeDebug: port=9")
        Log.info("wakeDebug: magicPacketBytes=\(packetBytes)")
        let result = WakeOnLAN.send(macAddress: metadata.macAddress, broadcastAddress: broadcast)
        switch result {
        case .success:
            Log.info("wakeDebug: sendResult=sent")
            sendResult = "Packet sent — this only confirms the send, not that the Mac woke."
        case .failure(let error):
            Log.info("wakeDebug: sendResult=failed(\(error))")
            sendResult = "Send failed: \(error)"
        }
    }
}

/// DEBUG-only manual diagnostic (not automated): lets the phone/Mac Receiver
/// ask the currently connected Mac to call
/// `IOPMAssertionDeclareUserActivity(..., kIOPMUserActiveRemote, ...)` over
/// the existing authenticated session — the correct way to test dark-wake
/// promotion while physically away from the Mac. Only enabled while an
/// authenticated session is actually connected; there is no other path for
/// the request to reach the Mac.
struct PromoteInteractiveWakeView: View {
    @ObservedObject var receiver: StreamReceiver

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Promote Mac to Interactive Wake") {
                receiver.requestPromoteInteractiveWake()
            }
            .disabled(!receiver.connected)
            if !receiver.connected {
                Text("Connect to the Mac first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let result = receiver.promoteInteractiveWakeResult {
                Text(result).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
