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
///
/// What to set up comes first (Before You Start), open until an address is
/// saved. Nothing on this page checks a network: it reads only what this
/// device already stores.
struct RemoteAccessSettingsView: View {
    @ObservedObject var receiver: StreamReceiver
    /// Preselects a paired Mac in the editor (e.g. from a Home remote row's menu).
    var initialPeerID: String?

    @State private var showsPrerequisites: Bool
    @Environment(\.settingsHighlight) private var highlight

    init(receiver: StreamReceiver, initialPeerID: String? = nil) {
        self.receiver = receiver
        self.initialPeerID = initialPeerID
        _showsPrerequisites = State(initialValue: Self.currentSetup().showsPrerequisitesExpanded)
    }

    private static func currentSetup() -> RemoteAccessSetup {
        RemoteAccessSetup(pairedPeerIDs: TrustStore.shared.pinnedPeers().map(\.peerID),
                          savedAddressPeerIDs: Set(RemoteEndpointStore.allPeerIDs(role: .receiverRole)))
    }

    var body: some View {
        SettingsForm {
            Section {
                DisclosureGroup(isExpanded: $showsPrerequisites) {
                    prerequisite("network", "Install Tailscale on your Mac and on this \(deviceKind), and sign in on both. They need to be on the same tailnet, or allowed to reach each other.")
                    prerequisite("power", "Turn on Tailscale on both devices.")
                    prerequisite("laptopcomputer", "Keep your Mac awake and logged in, with MeowDisplay open.")
                    prerequisite("lock", "Pair this \(deviceKind) with the Mac first: on the same Wi-Fi, with a USB cable, or with Pair over Remote.")
                    Link(destination: TailscaleLinks.appStore) {
                        Label("Get Tailscale on the App Store", systemImage: "arrow.down.app")
                    }
                    Link(destination: TailscaleLinks.vpnOnDemand) {
                        Label("Keep Tailscale On with VPN On Demand", systemImage: "arrow.up.forward.app")
                    }
                } label: {
                    Text("Before You Start")
                }
                .settingsAnchor("remoteAccessPrerequisites")
            } footer: {
                Text("MeowDisplay doesn't install, sign in to or change Tailscale. An address only finds your Mac; the pairing decides who it is, and every connection still needs it.")
            }

            Section {
                RemoteEndpointEditorView(receiver: receiver, initialPeerID: initialPeerID)
            } header: {
                Text("Address")
            } footer: {
                Text("Your Mac's Tailscale address or MagicDNS name. On the Mac, Settings → Remote Access → Check Tailscale shows both.")
            }

            Section {
                AutomaticRemoteAccessToggle(role: .receiverRole, peers: .macs)
                    .settingsAnchor("shareTailscaleAddresses")
                if !RemoteAddressSuggestion.connectsAutomatically {
                    Text("On iPhone and iPad, Remote Access connects with the address saved above. An address your Mac shared appears there as Found Automatically, and is used only after you save it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Automatic")
            }

            Section {
                Text("To pair a Mac that isn't on this Wi-Fi, first choose Settings → Devices → Open Pair over Remote on the Mac. Then, on Home, choose Remote Access → Pair over Remote and enter the Mac's address.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .settingsAnchor("pairOverRemote")
            } header: {
                Text("Pair over Remote")
            }

            Section {
                NavigationLink {
                    RemoteAccessHelpView()
                } label: {
                    Label("If Remote Access Doesn't Connect", systemImage: "questionmark.circle")
                }
                .settingsAnchor("remoteAccessHelp")
            }
        }
        .navigationTitle(MobileSettingsCategory.remoteAccess.title)
        // A search result for Before You Start opens it, even after setup closed it.
        .onAppear { if highlight == "remoteAccessPrerequisites" { showsPrerequisites = true } }
        .onChange(of: highlight) { id in if id == "remoteAccessPrerequisites" { showsPrerequisites = true } }
    }

    /// One requirement: a decorative symbol and a sentence, read as one element.
    private func prerequisite(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RemoteEndpointEditorView: View {
    @ObservedObject var receiver: StreamReceiver
    var initialPeerID: String?

    @State private var peerID = ""
    @State private var host = ""
    @State private var errorMessage: String?
    @State private var savedConfirmation = false
    /// Bumped when the saved address changes, so the (non-observable) store is re-read.
    @State private var storeRevision = 0

    private var pairedMacs: [(peerID: String, displayName: String)] {
        TrustStore.shared.pinnedPeers()
    }

    private var savedHost: String? {
        _ = storeRevision
        guard !peerID.isEmpty else { return nil }
        return RemoteEndpointStore.endpoint(forPeerID: peerID, role: .receiverRole)?.host
    }

    /// The address the selected Mac shared during an earlier connection, while its pin still
    /// matches and the report is fresh. Offered only, never saved or used by itself
    /// (`RemoteAddressSuggestion`).
    private var suggestedHost: String? {
        guard !peerID.isEmpty, AutomaticRemoteAccessPreference.isEnabled(.receiverRole),
              let entry = AutomaticRemoteEndpointStore(role: .receiverRole)
                .entry(forPeerID: peerID, currentPin: TrustStore.receiverRole.pin(peerID: peerID)) else { return nil }
        return RemoteAddressSuggestion.host(sharedNames: entry.names, sharedIPs: entry.ips, saved: savedHost)
    }

    var body: some View {
        if pairedMacs.isEmpty {
            Text("Pair with a Mac first — Remote Access uses the same secure pairing as local connections.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .settingsAnchor("remoteAddress")
        } else {
            Picker("Paired Mac", selection: $peerID) {
                Text("Select…").tag("")
                ForEach(pairedMacs, id: \.peerID) { peer in
                    Text(peer.displayName).tag(peer.peerID)
                }
            }
            .settingsAnchor("remoteAddress")
            .onChange(of: peerID) { newValue in loadSavedEndpoint(for: newValue) }
            .onAppear {
                if peerID.isEmpty, let initialPeerID,
                   pairedMacs.contains(where: { $0.peerID == initialPeerID }) {
                    peerID = initialPeerID
                }
            }

            if !peerID.isEmpty {
                if let suggestedHost {
                    LabeledContent("Found Automatically") {
                        Text(verbatim: suggestedHost).textSelection(.enabled)
                    }
                    Button("Use This Address") {
                        host = suggestedHost
                        errorMessage = nil
                        savedConfirmation = false
                        UIAccessibility.post(notification: .announcement,
                                             argument: String(localized: "Address filled in. Tap Save to use it."))
                    }
                    .accessibilityHint(Text("Fills in the address. Nothing is saved until you tap Save."))
                }

                // No port: this device always knocks on the Mac's connect-request port
                // (WireCrypto.remoteRequestPort); a field here changed nothing.
                TextField("Address", text: $host, prompt: Text("Tailscale address or MagicDNS name"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit { save() }
                    .onChange(of: host) { _ in errorMessage = nil; savedConfirmation = false }
                    .onChange(of: errorMessage) { message in
                        if let message { UIAccessibility.post(notification: .announcement, argument: message) }
                    }
                    .onChange(of: savedConfirmation) { saved in
                        if saved { UIAccessibility.post(notification: .announcement, argument: String(localized: "Saved")) }
                    }

                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                        .accessibilityLabel(Text("Error: \(errorMessage)"))
                } else if savedConfirmation {
                    Text("Saved").font(.caption).foregroundStyle(.secondary)
                }

                // One button per row: in a Form, every button in a row fires on a tap, so a
                // Save beside Remove Address also removed the address it had just saved.
                Button("Save") { save() }
                    .disabled(peerID.isEmpty)
                Button("Remove Address", role: .destructive) { remove() }
                    .disabled(savedHost == nil)
            }
        }
    }

    private func loadSavedEndpoint(for peerID: String) {
        errorMessage = nil
        savedConfirmation = false
        guard let hint = RemoteEndpointStore.endpoint(forPeerID: peerID, role: .receiverRole) else {
            host = ""
            return
        }
        host = hint.host
    }

    private func save() {
        switch RemoteEndpointValidation.validate(host: host, port: String(WireCrypto.remoteRequestPort)) {
        case .success(let value):
            RemoteEndpointStore.setEndpoint(value.host, port: value.port, forPeerID: peerID, role: .receiverRole)
            storeRevision &+= 1
            guard let readBack = RemoteEndpointStore.endpoint(forPeerID: peerID, role: .receiverRole),
                  readBack.host == value.host, readBack.port == value.port else {
                errorMessage = String(localized: "Couldn't save this address. Try again.")
                return
            }
            host = readBack.host
            errorMessage = nil
            savedConfirmation = true
        case .failure(let error):
            savedConfirmation = false
            switch error {
            case .emptyHost: errorMessage = String(localized: "Enter an address.")
            case .invalidHost: errorMessage = String(localized: "That doesn't look like an address. Enter a name such as mac.tailnet-name.ts.net or an address such as 100.101.102.103.")
            case .invalidPort: errorMessage = String(localized: "Enter a port between 1 and 65535.")
            }
        }
    }

    /// Removing a saved Remote endpoint never touches `TrustStore`'s pin —
    /// the Mac remains paired and reachable locally exactly as before (see
    /// `ForgetDeviceAction` on the Mac side for the same distinction).
    private func remove() {
        RemoteEndpointStore.removeEndpoint(forPeerID: peerID, role: .receiverRole)
        storeRevision &+= 1
        host = ""
        errorMessage = nil
        savedConfirmation = false
    }
}

/// What each Remote Access message on Home means and what to do about it: the same words the
/// Mac's row shows (`RemoteAccessProblem`), so the two never disagree.
struct RemoteAccessHelpView: View {
    var body: some View {
        Form {
            Section {
                Text("When Connect over Remote doesn't finish, the Mac's row on Home says what happened and what to check.")
                    .font(.callout)
            }
            Section("Messages") {
                ForEach(RemoteAccessProblem.allCases, id: \.self) { problem in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: problem.summary(deviceKind: deviceKind))
                            .font(.body.weight(.semibold))
                        Text(verbatim: problem.hint(deviceKind: deviceKind))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            }
            Section("Still Not Connecting") {
                Text("Check that the Tailscale app shows both devices as connected. Connecting once on the same Wi-Fi or with a USB cable shows that the pairing works, and lets your Mac share its Tailscale address when sharing is on. A Mac that is asleep can't answer until it wakes.")
                    .font(.callout)
            }
        }
        .navigationTitle("If Remote Access Doesn't Connect")
        .navigationBarTitleDisplayMode(.inline)
    }
}
