import SwiftUI

/// iPhone-side Remote Access: lets this device request a connection from an
/// already-paired Mac through a reachable private-network address (a
/// Tailscale IP, a MagicDNS name, or any other routable hostname), for when
/// the Mac isn't visible on the local network. The saved address is only a
/// routing hint the Mac's authenticated remote connect-request listener is
/// dialed with — pinned mutual TLS (`TrustStore`/`TLSConfigurator`) remains
/// the sole authority over whether either side trusts the other; nothing
/// here can change that. Mirrors `Mac/RemoteAccessSettingsView.swift`'s
/// editor, but keyed on a *paired Mac's* peerID and defaulting to
/// `WireCrypto.remoteRequestPort` rather than the media `tlsPort`.
struct RemoteAccessSettingsView: View {
    @ObservedObject var receiver: StreamReceiver
    /// Preselects a paired Mac in the editor (e.g. from a Home remote row's menu).
    var initialPeerID: String?

    var body: some View {
        Form {
            Section {
                Text("Use a reachable private-network address for this paired Mac, such as its Tailscale address or MagicDNS name. This lets you connect when the Mac isn't on the same network — it's only used to reach the device, it does not grant trust, and every connection still requires the existing secure pairing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Remote Access") {
                RemoteEndpointEditorView(receiver: receiver, initialPeerID: initialPeerID)
            }
        }
        .navigationTitle("Remote Access")
    }
}

struct RemoteEndpointEditorView: View {
    @ObservedObject var receiver: StreamReceiver
    var initialPeerID: String?

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
            Text("Pair with a Mac first — Remote Access uses the same secure pairing as local connections.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Picker("Paired Mac", selection: $peerID) {
                Text("Select…").tag("")
                ForEach(pairedMacs, id: \.peerID) { peer in
                    Text(peer.displayName).tag(peer.peerID)
                }
            }
            .onChange(of: peerID) { newValue in loadSavedEndpoint(for: newValue) }
            .onAppear {
                if peerID.isEmpty, let initialPeerID,
                   pairedMacs.contains(where: { $0.peerID == initialPeerID }) {
                    peerID = initialPeerID
                }
            }

            if !peerID.isEmpty {
                TextField("Host (Tailscale IP or MagicDNS name)", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: host) { _ in errorMessage = nil; savedConfirmation = false }
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                    .onChange(of: port) { _ in errorMessage = nil; savedConfirmation = false }

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                } else if savedConfirmation {
                    Text("Saved").font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Save") { save() }
                        .disabled(peerID.isEmpty)
                    Button("Remove Remote Details", role: .destructive) { remove() }
                        .disabled(!selectedPeerHasSavedEndpoint)
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
                errorMessage = "Couldn't save this endpoint. Try again."
                return
            }
            host = readBack.host
            port = String(readBack.port)
            errorMessage = nil
            savedConfirmation = true
        case .failure(let error):
            savedConfirmation = false
            switch error {
            case .emptyHost: errorMessage = "Enter a host or IP address."
            case .invalidHost: errorMessage = "That doesn't look like a valid host or IP address."
            case .invalidPort: errorMessage = "Enter a port between 1 and 65535."
            }
        }
    }

    /// Removing a saved Remote endpoint never touches `TrustStore`'s pin —
    /// the Mac remains paired and reachable locally exactly as before (see
    /// `ForgetDeviceAction` on the Mac side for the same distinction).
    private func remove() {
        RemoteEndpointStore.removeEndpoint(forPeerID: peerID)
        host = ""
        port = String(WireCrypto.remoteRequestPort)
        errorMessage = nil
        savedConfirmation = false
    }
}
