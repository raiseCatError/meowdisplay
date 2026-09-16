#if DEBUG
import SwiftUI

/// Physical-test control panel: force a single route (e.g. Remote only) so
/// being near the Mac can't accidentally let AWDL/LAN win the connection.
/// Session-only — nothing here survives a relaunch.
struct RouteOverridesView: View {
    @ObservedObject private var overrides = RouteOverrides.shared

    var body: some View {
        Toggle("USB", isOn: $overrides.usbEnabled)
        Toggle("LAN", isOn: $overrides.lanEnabled)
        Toggle("AWDL", isOn: $overrides.awdlEnabled)
        Toggle("Remote", isOn: $overrides.remoteEnabled)
        HStack {
            Button("Force Remote Only") { overrides.forceRemoteOnly() }
            Button("Enable All Routes") { overrides.reset() }
        }
        .controlSize(.small)
    }
}

/// Bootstrap/testing fallback for entering a paired peer's Tailscale address
/// by hand (Phase 3/6 of the Remote milestone) — persisted per stable peer
/// install ID via `RemoteEndpointStore` so it only needs to be typed once.
struct RemoteEndpointDebugView: View {
    @ObservedObject var controller: SenderController
    @State private var peerID = ""
    @State private var host = ""
    @State private var port = "9001"

    var body: some View {
        if !TrustStore.shared.pinnedPeers().isEmpty {
            Picker("Paired device", selection: $peerID) {
                Text("Select…").tag("")
                ForEach(TrustStore.shared.pinnedPeers(), id: \.peerID) { peer in
                    Text(peer.displayName).tag(peer.peerID)
                }
            }
        }
        TextField("Tailscale host or IP", text: $host)
        TextField("Port", text: $port)
        HStack {
            Button("Save") {
                guard !peerID.isEmpty, let portNum = UInt16(port), !host.isEmpty else { return }
                RemoteEndpointStore.setEndpoint(host, port: portNum, forPeerID: peerID)
            }
            .disabled(peerID.isEmpty || host.isEmpty || UInt16(port) == nil)
            Button("Forget") {
                guard !peerID.isEmpty else { return }
                RemoteEndpointStore.removeEndpoint(forPeerID: peerID)
            }
            .disabled(peerID.isEmpty)
        }
        .controlSize(.small)
    }
}
#endif
