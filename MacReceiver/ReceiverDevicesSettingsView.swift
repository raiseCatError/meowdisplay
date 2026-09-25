import Network
import SwiftUI

/// Devices: the Macs this receiver trusts (`TrustStore`) and the unpaired
/// ones it can see nearby — the same shared pairing, Forget, Connect and
/// Wake & Connect paths the iPhone app uses. The sending Mac is always the
/// one that dials; Connect asks it to (see `StreamReceiver.connectPrimary`).
struct ReceiverDevicesSettingsView: View {
    @ObservedObject var controller: ReceiverController

    var body: some View {
        WithReceiver(controller) { receiver in
            if let wakeConnect = controller.wakeConnect {
                ReceiverDevicesPage(receiver: receiver, wakeConnect: wakeConnect)
            }
        }
    }
}

private struct ReceiverDevicesPage: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var wakeConnect: WakeConnectCoordinator
    @State private var forgetConfirmation = PeerForgetPrompt()
    // TrustStore isn't observable; bumped after a local Forget. Pairing
    // successes and forgets also republish the receiver itself.
    @State private var trustRefresh = 0

    private var pairedMacs: [(peerID: String, displayName: String)] {
        _ = trustRefresh
        return ReceiverMacList.paired()
    }

    private var unpairedNearby: [NWBrowser.Result] {
        ReceiverMacList.unpairedNearby(receiver)
    }

    var body: some View {
        ReceiverSettingsForm {
            Section {
                if let status = receiver.pairingPrompt.status {
                    ReceiverCaption(verbatim: status)
                }
                if pairedMacs.isEmpty {
                    ReceiverCaption("No paired Macs")
                } else {
                    AutomaticallyAllowConnectionsToggle()
                    ForEach(pairedMacs, id: \.peerID) { mac in
                        ReceiverPairedMacRow(receiver: receiver, wakeConnect: wakeConnect,
                                             peerID: mac.peerID, name: mac.displayName) {
                            Button("Forget…", role: .destructive) {
                                forgetConfirmation.request(peerID: mac.peerID, name: mac.displayName)
                            }
                            .controlSize(.small)
                        }
                        IncomingSessionPolicyPicker(peerID: mac.peerID)
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Paired Macs")
            } footer: {
                ReceiverCaption("Connect asks that Mac to start streaming to this one. Connection Requests: Default follows Automatically Allow Connections; blocking keeps the Mac paired. Forgetting a Mac removes its pairing; you'll need to pair again before connecting.")
            }

            Section {
                if unpairedNearby.isEmpty {
                    ReceiverCaption("No unpaired Macs nearby")
                } else {
                    ForEach(unpairedNearby, id: \.endpoint) { result in
                        ReceiverNearbyMacRow(receiver: receiver, result: result)
                    }
                }
            } header: {
                Text("Nearby Macs")
            } footer: {
                ReceiverCaption("Macs on this network running MeowDisplay. Pairing shows a code on both Macs — confirm only if they match. You can also start pairing from the other Mac's Devices list.")
            }
        }
        .alert(Text("Forget “\(forgetConfirmation.candidate?.name ?? String(localized: "This Mac"))”?"),
               isPresented: Binding(get: { forgetConfirmation.isPresented },
                                    set: { if !$0 { forgetConfirmation.cancel() } })) {
            Button("Forget", role: .destructive) {
                forgetConfirmation.confirm { peerID in
                    receiver.forgetPeer(peerID)
                    receiver.pairingPrompt.cancel()
                    trustRefresh &+= 1
                }
            }
            Button("Cancel", role: .cancel) { forgetConfirmation.cancel() }
        } message: {
            Text("You'll need to pair with this Mac again before connecting.")
        }
    }
}

/// Remote Access: a saved private-network address (Tailscale IP, MagicDNS
/// name, …) for a paired Mac, so Connect can reach it when it isn't on this
/// network. Connect on the Devices page then also sends one authenticated
/// connect request there (`StreamReceiver.requestRemoteConnect`). The address
/// is only a routing hint; pinned mutual TLS stays the sole authority.
struct ReceiverRemoteAccessSettingsView: View {
    @ObservedObject var controller: ReceiverController

    var body: some View {
        WithReceiver(controller) { receiver in
            ReceiverRemoteAccessPage(receiver: receiver)
        }
    }
}

private struct ReceiverRemoteAccessPage: View {
    @ObservedObject var receiver: StreamReceiver

    var body: some View {
        ReceiverSettingsForm {
            Section("Remote Access") {
                ReceiverCaption("Use a reachable private-network address for a paired Mac, such as its Tailscale address or MagicDNS name, to connect when it isn't on the same network. The address is only used to reach that Mac — it does not grant trust, and every connection still requires the existing secure pairing.")
                ReceiverRemoteEndpointEditor()
            }
            Section {
                ReceiverCaption("Use Connect on the Devices page to reach a Mac through its saved address. The other Mac must have Remote Access turned on. Wake & Connect can only wake a Mac on this local network.")
            }
        }
    }
}

/// Editor for one paired Mac's saved Remote endpoint — the Mac-native twin of
/// the iPhone app's `RemoteEndpointEditorView`, over the same shared
/// `RemoteEndpointStore`/`RemoteEndpointValidation`. Validates before saving
/// and keeps the draft on failure.
private struct ReceiverRemoteEndpointEditor: View {
    @State private var peerID = ""
    @State private var host = ""
    @State private var port = String(WireCrypto.remoteRequestPort)
    @State private var errorMessage: String?
    @State private var savedConfirmation = false

    private var pairedMacs: [(peerID: String, displayName: String)] {
        TrustStore.shared.pinnedPeers()
    }

    private var selectedPeerHasSavedEndpoint: Bool {
        !peerID.isEmpty && RemoteEndpointStore.endpoint(forPeerID: peerID) != nil
    }

    var body: some View {
        if pairedMacs.isEmpty {
            ReceiverCaption("Pair with a Mac first — Remote Access uses the same secure pairing as local connections.")
        } else {
            Picker("Paired Mac", selection: $peerID) {
                Text("Select…").tag("")
                ForEach(pairedMacs, id: \.peerID) { peer in
                    Text(peer.displayName).tag(peer.peerID)
                }
            }
            .onChange(of: peerID) { loadSavedEndpoint(for: $0) }

            if !peerID.isEmpty {
                TextField("Host", text: $host, prompt: Text("Tailscale IP or MagicDNS name"))
                    .disableAutocorrection(true)
                    .onChange(of: host) { _ in errorMessage = nil; savedConfirmation = false }
                TextField("Port", text: $port)
                    .onChange(of: port) { _ in errorMessage = nil; savedConfirmation = false }

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                } else if savedConfirmation {
                    ReceiverCaption("Saved")
                }

                HStack {
                    Button("Save") { save() }
                        .controlSize(.small)
                    Button("Remove Remote Details", role: .destructive) { remove() }
                        .controlSize(.small)
                        .disabled(!selectedPeerHasSavedEndpoint)
                    Spacer()
                }
            }
        }
    }

    private func loadSavedEndpoint(for peerID: String) {
        errorMessage = nil
        savedConfirmation = false
        guard let hint = RemoteEndpointStore.endpoint(forPeerID: peerID) else {
            host = ""
            port = String(WireCrypto.remoteRequestPort)
            return
        }
        host = hint.host
        port = String(hint.port)
    }

    private func save() {
        switch RemoteEndpointValidation.validate(host: host, port: port) {
        case .success(let value):
            RemoteEndpointStore.setEndpoint(value.host, port: value.port, forPeerID: peerID)
            guard let readBack = RemoteEndpointStore.endpoint(forPeerID: peerID),
                  readBack.host == value.host, readBack.port == value.port else {
                errorMessage = String(localized: "Couldn't save this endpoint. Try again.")
                return
            }
            host = readBack.host
            port = String(readBack.port)
            errorMessage = nil
            savedConfirmation = true
        case .failure(let error):
            savedConfirmation = false
            switch error {
            case .emptyHost: errorMessage = String(localized: "Enter a host or IP address.")
            case .invalidHost: errorMessage = String(localized: "That doesn't look like a valid host or IP address.")
            case .invalidPort: errorMessage = String(localized: "Enter a port between 1 and 65535.")
            }
        }
    }

    /// Removing the saved endpoint never touches the pairing itself.
    private func remove() {
        RemoteEndpointStore.removeEndpoint(forPeerID: peerID)
        host = ""
        port = String(WireCrypto.remoteRequestPort)
        errorMessage = nil
        savedConfirmation = false
    }
}

// MARK: - Mac rows shared by Devices and Overview

/// Which Macs to list — one definition for Devices and Overview.
@MainActor
enum ReceiverMacList {
    static func paired() -> [(peerID: String, displayName: String)] {
        TrustStore.shared.pinnedPeers()
    }

    static func unpairedNearby(_ receiver: StreamReceiver) -> [NWBrowser.Result] {
        receiver.discoveredMacs.filter { !receiver.pairingMacIsPaired($0) }
    }
}

/// One paired Mac: live status plus Connect / Wake & Connect through the
/// shared `WakeConnectCoordinator`. `trailing` adds page-specific actions
/// (Devices adds Forget…).
struct ReceiverPairedMacRow<Trailing: View>: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var wakeConnect: WakeConnectCoordinator
    let peerID: String
    let name: String
    private let trailing: Trailing

    init(receiver: StreamReceiver, wakeConnect: WakeConnectCoordinator, peerID: String, name: String,
         @ViewBuilder trailing: () -> Trailing) {
        self.receiver = receiver
        self.wakeConnect = wakeConnect
        self.peerID = peerID
        self.name = name
        self.trailing = trailing()
    }

    var body: some View {
        let isConnected = receiver.connected && receiver.authenticatedPeerID == peerID
        let isNearby = receiver.discoveredMacs.contains { receiver.pairingMacPeerID($0) == peerID }
        let canWake = WakeMetadataStore.metadata(forPeerID: peerID)?.broadcastAddress != nil
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(isConnected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(status(isConnected: isConnected, isNearby: isNearby))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if wakeConnect.isRunning(forPeerID: peerID) {
                ProgressView().controlSize(.small)
                Button("Cancel") { wakeConnect.cancel() }
                    .controlSize(.small)
            } else if !receiver.connected {
                // Wake & Connect only when a local-network wake hint was
                // learned from this Mac; it never claims remote wake.
                Menu {
                    Button("Connect with Mirror") { wakeConnect.begin(peerID: peerID, mode: .mirror) }
                    Button("Connect with Extend") { wakeConnect.begin(peerID: peerID, mode: .extend) }
                } label: {
                    Text(wakeConnect.failed(forPeerID: peerID) ? "Try Again"
                         : canWake ? "Wake & Connect" : "Connect")
                } primaryAction: {
                    wakeConnect.begin(peerID: peerID)
                }
                .fixedSize()
                .controlSize(.small)
            }
            trailing
        }
    }

    private func status(isConnected: Bool, isNearby: Bool) -> String {
        if isConnected { return String(localized: "Connected") }
        if wakeConnect.isRunning(forPeerID: peerID) { return wakeConnect.statusLabel }
        if let reason = wakeConnect.failureReason(forPeerID: peerID) {
            switch reason {
            case "timedOut": return String(localized: "Connection timed out")
            case "cancelled": return String(localized: "Cancelled")
            case "protocolIncompatible": return String(localized: "Mac requires app update")
            case "peerForgotten": return String(localized: "Mac pairing removed")
            default: return String(localized: "Connection failed")
            }
        }
        if isNearby { return String(localized: "Paired · Nearby") }
        if RemoteEndpointStore.endpoint(forPeerID: peerID) != nil { return String(localized: "Paired · Remote Access") }
        return String(localized: "Paired · Not nearby")
    }
}

extension ReceiverPairedMacRow where Trailing == EmptyView {
    init(receiver: StreamReceiver, wakeConnect: WakeConnectCoordinator, peerID: String, name: String) {
        self.init(receiver: receiver, wakeConnect: wakeConnect, peerID: peerID, name: name) { EmptyView() }
    }
}

/// One unpaired Mac seen nearby, with Pair (confirmed by the pairing panel).
struct ReceiverNearbyMacRow: View {
    @ObservedObject var receiver: StreamReceiver
    let result: NWBrowser.Result

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(receiver.pairingMacName(result)).lineLimit(1)
                Text("Nearby")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Pair") { receiver.pairWithMac(result) }
                .controlSize(.small)
        }
    }
}
