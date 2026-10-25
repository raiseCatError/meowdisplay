import SwiftUI

/// "Use This Mac as a Display": the unified app's receiver role, one switch
/// away from the sender. Off by default; while on, this Mac shares nothing
/// and waits for another Mac to connect to it as a display.
struct DisplayRoleSection: View {
    @ObservedObject var controller: SenderController
    /// Overview's link to the "This Mac as a Display" settings page.
    var onOpenSettings: (() -> Void)?
    @ObservedObject private var receiver = ReceiverController.shared

    var body: some View {
        Section {
            Toggle("Use This Mac as a Display", isOn: Binding(
                get: { controller.receiverModeEnabled },
                set: { controller.setReceiverModeEnabled($0) }))
            if controller.receiverModeEnabled {
                if receiver.statusNeedsAttention {
                    // What to quit or fix; the role starts by itself
                    // afterwards, except after a lock problem.
                    Text(receiver.statusTitle)
                        .font(.caption)
                        .foregroundStyle(receiver.statusColor)
                    if receiver.lockProblem != nil {
                        Button("Try Again") { receiver.start() }
                            .controlSize(.small)
                    }
                } else {
                    LabeledContent("Status", value: receiver.statusTitle)
                }
            }
            if receiver.streaming || onOpenSettings != nil {
                HStack {
                    if receiver.streaming {
                        Button("Show Window") { receiver.showWindow() }
                            .controlSize(.small)
                    }
                    if let onOpenSettings {
                        Button("Display Settings…", action: onOpenSettings)
                            .controlSize(.small)
                    }
                    Spacer()
                }
            }
        } header: {
            Text("This Mac as a Display")
        } footer: {
            Text(controller.receiverModeEnabled
                 ? "Another Mac can connect and use this Mac as a display, with this Mac's keyboard and trackpad once it allows control. Sharing this Mac to your devices is paused until you turn this off."
                 : "Let another Mac use this Mac as a display. Sharing this Mac to your devices pauses while it's on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// "This Mac as a Display" in MeowDisplay's Settings: the receiver role's
/// own settings, on one page apart from the sender's. Built from the
/// standalone receiver's sections, so both manage the role identically:
/// status, name, the sending Macs paired with this role (Automatically Allow
/// Connections, each Mac's Connection Requests, Connect, Forget) and audio
/// with A/V Sync. Everything here reads and writes the receiver role's own
/// trust and settings (`TrustStore.receiverRole`, `RolePreferences.receiverRole`).
struct DisplayRoleSettingsView: View {
    @ObservedObject var controller: SenderController
    @ObservedObject private var receiverController = ReceiverController.shared

    var body: some View {
        Form {
            DisplayRoleSection(controller: controller)

            Section {
                ReceiverNameField { receiverController.setAdvertisedName($0) }
            } header: {
                Text("Name")
            } footer: {
                DisplayRoleCaption("How this Mac appears in the sending Mac's Devices list.")
            }

            if let receiver = receiverController.receiver, let wakeConnect = receiverController.wakeConnect {
                ReceiverPairedMacsSection(receiver: receiver, wakeConnect: wakeConnect)
                ReceiverAudioSection(receiver: receiver, controller: receiverController)
            } else {
                DisplayRoleStoredMacsSection()
            }
        }
        .formStyle(.grouped)
    }
}

/// The display role's paired Macs while the role is off: still listed and
/// forgettable, so trust can be revoked without first putting this Mac on
/// the network as a display. Nothing is live, so Forget is the stored part
/// of the receiver's Forget (`StreamReceiver.removeStoredTrust`).
private struct DisplayRoleStoredMacsSection: View {
    @State private var forgetConfirmation = PeerForgetPrompt()
    @State private var trustRefresh = 0

    private var pairedMacs: [(peerID: String, displayName: String)] {
        _ = trustRefresh
        return TrustStore.receiverRole.pinnedPeers()
    }

    var body: some View {
        Section {
            if pairedMacs.isEmpty {
                DisplayRoleCaption("No paired Macs")
            } else {
                AutomaticallyAllowConnectionsToggle()
                ForEach(pairedMacs, id: \.peerID) { mac in
                    HStack {
                        Text(verbatim: mac.displayName)
                        Spacer()
                        Button("Forget…", role: .destructive) {
                            forgetConfirmation.request(peerID: mac.peerID, name: mac.displayName)
                        }
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Paired Macs")
        } footer: {
            DisplayRoleCaption("Macs paired with this Mac as a display — separate from the devices this Mac shares to. Turn on Use This Mac as a Display to connect, pair, set each Mac's connection requests, or change audio.")
        }
        .alert(Text("Forget “\(forgetConfirmation.candidate?.name ?? String(localized: "This Mac"))”?"),
               isPresented: Binding(get: { forgetConfirmation.isPresented },
                                    set: { if !$0 { forgetConfirmation.cancel() } })) {
            Button("Forget", role: .destructive) {
                forgetConfirmation.confirm { peerID in
                    StreamReceiver.removeStoredTrust(peerID: peerID)
                    trustRefresh &+= 1
                }
            }
            Button("Cancel", role: .cancel) { forgetConfirmation.cancel() }
        } message: {
            Text("That Mac will need to pair with this Mac again before using it as a display.")
        }
    }
}

private struct DisplayRoleCaption: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// The same switch in the menu bar's quick view.
struct DisplayRoleMenuToggle: View {
    @ObservedObject var controller: SenderController
    @ObservedObject private var receiver = ReceiverController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Use This Mac as a Display", isOn: Binding(
                get: { controller.receiverModeEnabled },
                set: { controller.setReceiverModeEnabled($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
            if controller.receiverModeEnabled {
                Text(receiver.statusTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
