import SwiftUI

/// Release-visible Remote Access settings: lets someone connect to an
/// already-paired Mac through a reachable private-network address (a
/// Tailscale IP, a MagicDNS name, or any other routable hostname) without
/// needing Developer settings. The saved address is only a routing hint —
/// pinned mutual TLS (`TrustStore`/`TLSConfigurator`) remains the sole
/// authority over whether a connection is trusted; nothing here can change
/// that. Remote QR pairing, relay productization, and QUIC are explicitly
/// out of scope for this milestone.
struct RemoteAccessSettingsView: View {
    @ObservedObject var controller: SenderController

    private var remoteEntries: [SenderController.ActiveDisplayEntry] {
        controller.activeDisplayEntries.filter { $0.route == .remote }
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
                        LabeledContent(entry.name, value: String(localized: "Connected · Remote"))
                    }
                }
            }

            Section("Remote Access") {
                Text("Connect to this paired Mac through a reachable private-network address, such as its Tailscale address or MagicDNS name. This address is only used to reach the device — it does not grant trust; every connection still requires the existing secure pairing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RemoteEndpointEditorView(controller: controller)
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

/// Production editor for a paired peer's saved Remote endpoint. Loads the
/// existing saved value the moment a peer is selected (the earlier DEBUG-
/// only editor never did this, which is why a save could look like it
/// "didn't persist" — the value was there in `RemoteEndpointStore` all
/// along, the fields just never showed it on reopen). Validates before
/// saving and reports a concrete error instead of a fake "Saved" — the
/// draft is kept on failure so nothing typed is lost.
struct RemoteEndpointEditorView: View {
    @ObservedObject var controller: SenderController

    @State private var peerID = ""
    @State private var host = ""
    @State private var port = String(WireCrypto.remoteRequestPort)
    @State private var errorMessage: String?
    @State private var savedConfirmation = false

    private var pairedPeers: [(peerID: String, displayName: String)] {
        TrustStore.shared.pinnedPeers()
    }

    private var selectedPeerHasSavedEndpoint: Bool {
        !peerID.isEmpty && RemoteEndpointStore.endpoint(forPeerID: peerID) != nil
    }

    private var statusText: String? {
        guard !peerID.isEmpty else { return nil }
        let target = ConnectionTarget.remote(peerID: peerID)
        if let session = controller.session(for: target.sessionID) {
            if controller.activeDisplayEntries.contains(where: { $0.id == session.id }) {
                return String(localized: "Connected via Remote")
            }
            if session.failed {
                return String(localized: "Connection Lost")
            }
            return String(localized: "Connecting…")
        }
        return selectedPeerHasSavedEndpoint ? nil : String(localized: "Endpoint unavailable")
    }

    var body: some View {
        if pairedPeers.isEmpty {
            Text("Pair a device first — Remote access uses the same secure pairing as local connections.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Paired device", selection: Binding(
                get: { PickerSelection.valid(peerID, among: pairedPeers.map(\.peerID), fallback: "") },
                set: { peerID = $0 })) {
                Text("Select…").tag("")
                ForEach(pairedPeers, id: \.peerID) { peer in
                    Text(peer.displayName).tag(peer.peerID)
                }
            }
            .onChange(of: peerID) { _, newValue in
                loadSavedEndpoint(for: newValue)
            }

            if !peerID.isEmpty {
                TextField("Host (Tailscale IP or MagicDNS name)", text: $host)
                    .onChange(of: host) { _, _ in errorMessage = nil; savedConfirmation = false }
                TextField("Port", text: $port)
                    .onChange(of: port) { _, _ in errorMessage = nil; savedConfirmation = false }

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                } else if savedConfirmation {
                    Text("Saved").font(.caption).foregroundStyle(.secondary)
                }
                if let statusText {
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Save") { save() }
                        .disabled(peerID.isEmpty)
                    Button("Remove Remote Endpoint") { remove() }
                        .disabled(!selectedPeerHasSavedEndpoint)
                    Button("Connect") { connect() }
                        .disabled(!selectedPeerHasSavedEndpoint)
                }
                .controlSize(.small)
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
            // Read back from the canonical store rather than trusting the
            // local write — if persistence actually failed, show that
            // instead of claiming success.
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

    private func remove() {
        RemoteEndpointStore.removeEndpoint(forPeerID: peerID)
        host = ""
        port = String(WireCrypto.remoteRequestPort)
        errorMessage = nil
        savedConfirmation = false
    }

    private func connect() {
        controller.connect(to: .remote(peerID: peerID), userInitiated: true)
    }
}
