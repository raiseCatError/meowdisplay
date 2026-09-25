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
            Picker("Paired device", selection: Binding(
                get: { PickerSelection.valid(peerID, among: TrustStore.shared.pinnedPeers().map(\.peerID), fallback: "") },
                set: { peerID = $0 })) {
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
                host = ""
                port = "9001"
            }
            .disabled(peerID.isEmpty)
        }
        .controlSize(.small)
        // Loads the same canonical `RemoteEndpointStore` value the
        // release-visible `RemoteEndpointEditorView` does on selection —
        // this view previously left the fields blank/stale here, which is
        // what made a successful Save look like it hadn't persisted.
        .onChange(of: peerID) { _, newValue in
            guard let hint = RemoteEndpointStore.endpoint(forPeerID: newValue) else {
                host = ""
                port = "9001"
                return
            }
            host = hint.host
            port = String(hint.port)
        }
    }
}

/// Local Wake-on-LAN proof-of-concept for this Mac: shows the interface/MAC
/// this device would be woken at, and a way to sleep it deliberately to test
/// that. Logs everything non-secret before sleeping so the exact target of
/// the follow-up wake attempt is on record.
struct WakeTestingDebugView: View {
    @State private var metadata = WakeInspector.currentInterfaceWakeMetadata()
    @State private var wakeStatus = WakeForNetworkAccessStatus.unknown
    @State private var promotionResult: String?

    var body: some View {
        if let metadata {
            LabeledContent("Interface", value: metadata.interfaceName)
            LabeledContent("IPv4", value: metadata.ipv4 ?? "unknown")
            LabeledContent("Subnet mask", value: metadata.subnetMask ?? "unknown")
            LabeledContent("Broadcast", value: metadata.broadcastAddress ?? "unknown")
            LabeledContent("MAC address", value: metadata.macAddress)
        } else {
            Text("No active LAN interface found").foregroundStyle(.secondary)
        }
        LabeledContent("Wake for Network Access", value: wakeStatus.rawValue)
            .task { wakeStatus = await WakeInspector.wakeForNetworkAccessStatus() }
        HStack {
            Button("Recheck") {
                metadata = WakeInspector.currentInterfaceWakeMetadata()
                Task { wakeStatus = await WakeInspector.wakeForNetworkAccessStatus() }
            }
            Button("Sleep This Mac for WoL Test") {
                if let metadata {
                    Log.info("wakeDebug: sleeping for WoL test interface=\(metadata.interfaceName) mac=\(metadata.macAddress) ipv4=\(metadata.ipv4 ?? "unknown") broadcast=\(metadata.broadcastAddress ?? "unknown") wakeForNetworkAccess=\(wakeStatus.rawValue)")
                } else {
                    Log.info("wakeDebug: sleeping for WoL test — no LAN interface metadata available")
                }
                WakeInspector.sleepNow()
            }
        }
        .controlSize(.small)

        Divider()

        // Isolates one question: does declaring remote user activity promote
        // a dark/network wake into a graphical/interactive one? Makes only
        // the single public IOPMAssertionDeclareUserActivity call — no
        // synthesized input, no capture/display rebuild, not wired to
        // reconnect yet.
        VStack(alignment: .leading, spacing: 4) {
            Button("Promote to Interactive Wake") {
                let attempt = InteractiveWakePromotion.promote()
                promotionResult = attempt.result == kIOReturnSuccess
                    ? "Success (assertionID=\(attempt.assertionID ?? 0))"
                    : "Failed: \(attempt.result)"
            }
            .controlSize(.small)
            if let promotionResult {
                Text(promotionResult).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
