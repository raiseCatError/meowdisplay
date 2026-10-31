import AppKit
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

            Section("Automatic") {
                AutomaticRemoteAccessToggle(role: .sender, peers: .devices)
            }

            Section("Tailscale") {
                TailscaleThisMacView()
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
    @State private var port = String(WireCrypto.tlsPort)
    @State private var errorMessage: String?
    @State private var savedConfirmation = false

    private var pairedPeers: [(peerID: String, displayName: String)] {
        TrustStore.shared.pinnedPeers()
    }

    private var selectedPeerHasSavedEndpoint: Bool {
        !peerID.isEmpty && RemoteEndpointStore.endpoint(forPeerID: peerID, role: .sender) != nil
    }

    /// What the selected device reported about itself, when no address was typed and that address
    /// is used (a verified path, automatic Remote Access on).
    private var reportedHost: String? {
        guard !peerID.isEmpty, !selectedPeerHasSavedEndpoint,
              let hint = AutomaticRemoteRoutes.macMediaEndpoint(forPeerID: peerID, pin: TrustStore.shared.pin(peerID: peerID)),
              hint.automatic else { return nil }
        return hint.host
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
        return selectedPeerHasSavedEndpoint || reportedHost != nil ? nil : String(localized: "Endpoint unavailable")
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
                if let reportedHost {
                    Text("Found automatically: \(reportedHost). An address you save here is used instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                TailscaleSuggestionsView(deviceName: pairedPeers.first { $0.peerID == peerID }?.displayName ?? "") { suggested in
                    host = suggested
                    port = String(WireCrypto.tlsPort)
                }

                HStack {
                    Button("Save") { save() }
                        .disabled(peerID.isEmpty)
                    Button("Remove Remote Endpoint") { remove() }
                        .disabled(!selectedPeerHasSavedEndpoint)
                    Button("Connect") { connect() }
                        .disabled(!selectedPeerHasSavedEndpoint && reportedHost == nil)
                }
                .controlSize(.small)
            }
        }
    }

    private func loadSavedEndpoint(for peerID: String) {
        errorMessage = nil
        savedConfirmation = false
        guard let hint = RemoteEndpointStore.mediaEndpoint(forPeerID: peerID, role: .sender) else {
            host = ""
            port = String(WireCrypto.tlsPort)
            return
        }
        host = hint.host
        port = String(hint.port)
    }

    private func save() {
        switch RemoteEndpointValidation.validate(host: host, port: port) {
        case .success(let value):
            RemoteEndpointStore.setEndpoint(value.host, port: value.port, forPeerID: peerID, role: .sender)
            // Read back from the canonical store rather than trusting the
            // local write — if persistence actually failed, show that
            // instead of claiming success.
            guard let readBack = RemoteEndpointStore.endpoint(forPeerID: peerID, role: .sender),
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
        RemoteEndpointStore.removeEndpoint(forPeerID: peerID, role: .sender)
        host = ""
        port = String(WireCrypto.tlsPort)
        errorMessage = nil
        savedConfirmation = false
    }

    private func connect() {
        controller.connect(to: .remote(peerID: peerID), userInitiated: true)
    }
}


/// This Mac's own Tailscale name and address, to enter on an iPhone, iPad or
/// Android device as its Remote address. Read only when asked.
private struct TailscaleThisMacView: View {
    @State private var outcome: TailscaleCLI.Outcome?
    @State private var checking = false

    var body: some View {
        Text("If this Mac and your device both use Tailscale, enter this Mac's Tailscale name on the device (Remote Access → Add Remote Mac). MeowDisplay reads Tailscale's status only when you check, and never changes Tailscale.")
            .font(.caption)
            .foregroundStyle(.secondary)
        switch outcome {
        case .status(let status):
            if let node = status.selfNode {
                if let dns = node.dnsName { copyRow("MagicDNS name", dns) }
                if let ipv4 = node.ipv4 { copyRow("Tailscale IPv4", ipv4) }
            } else {
                Text("Tailscale is running but didn't report this Mac.").font(.caption).foregroundStyle(.secondary)
            }
        case .notInstalled:
            Text("Tailscale isn't installed on this Mac. You can still enter any private-network address by hand.").font(.caption).foregroundStyle(.secondary)
        case .unavailable:
            Text("Tailscale isn't running or is signed out. Start it, then check again.").font(.caption).foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
        Button(checking ? "Checking…" : "Check Tailscale") {
            checking = true
            Task { outcome = await TailscaleCLI.status(); checking = false }
        }
        .disabled(checking)
        .controlSize(.small)
    }

    private func copyRow(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            HStack {
                Text(value).textSelection(.enabled).font(.body.monospaced())
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                }
                .controlSize(.small)
            }
        }
    }
}

/// Tailnet peers that could be the selected paired device, to fill its Remote
/// host. Choosing one only fills the field: nothing is saved until Save, and
/// the address never replaces the pairing that authenticates every session.
private struct TailscaleSuggestionsView: View {
    let deviceName: String
    let onUse: (String) -> Void
    @State private var outcome: TailscaleCLI.Outcome?
    @State private var checking = false

    var body: some View {
        HStack {
            Button(checking ? "Looking…" : "Find on Tailscale") {
                checking = true
                Task { outcome = await TailscaleCLI.status(); checking = false }
            }
            .disabled(checking)
            .controlSize(.small)
            Spacer()
        }
        switch outcome {
        case .status(let status):
            let candidates = Array(status.candidates(forDeviceNamed: deviceName).prefix(6))
            if candidates.isEmpty {
                Text("No phone, tablet or Mac on your tailnet. Install Tailscale on the device and sign in to the same tailnet.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(candidates) { node in
                HStack {
                    VStack(alignment: .leading) {
                        Text(node.hostName == "localhost" ? (node.dnsName?.components(separatedBy: ".").first ?? node.hostName) : node.hostName)
                        Text([node.preferredHost, node.os, node.online ? String(localized: "online") : String(localized: "offline")]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let host = node.preferredHost {
                        Button("Use") { onUse(host) }.controlSize(.small)
                    }
                }
            }
        case .notInstalled:
            Text("Tailscale isn't installed on this Mac.").font(.caption).foregroundStyle(.secondary)
        case .unavailable:
            Text("Tailscale isn't running or is signed out.").font(.caption).foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }
}
