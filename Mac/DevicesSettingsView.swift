import SwiftUI

/// Three explicitly separate concepts, never conflated — see
/// `SenderController.activeDisplayEntries` / `knownDeviceEntries` /
/// `deviceEntries` for the sources of truth this view only renders.
struct DevicesSettingsView: View {
    @ObservedObject var controller: SenderController

    var body: some View {
        Form {
            // Runtime (live, application-authenticated session) and
            // persistent trust are deliberately separate sections, each
            // with its own empty state, so neither can be mistaken for
            // the other.
            Section("Active Display") {
                if controller.activeDisplayEntries.isEmpty {
                    Text("No active display")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.activeDisplayEntries) { entry in
                    if let session = controller.session(for: entry.id) {
                        SessionRow(title: entry.name, session: session, controller: controller)
                            .contextMenu {
                                if let peerID = entry.peerID {
                                    Button("Forget Device", role: .destructive) {
                                        controller.requestForget(peerID: peerID, name: entry.name)
                                    }
                                }
                            }
                        if let peerID = entry.peerID {
                            NavigationLink("Device Settings…") {
                                ReceiverDeviceDetailView(controller: controller, peerID: peerID, name: entry.name)
                            }
                            .font(.caption)
                        }
                    }
                }
            }

            Section("Known Devices") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Automatically Allow Connections", isOn: $controller.automaticallyAllowConnections)
                    Text("When a paired device asks to connect, start sharing without asking. Remote input always starts off.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = controller.pairingMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if controller.knownDeviceEntries.isEmpty {
                    Text("No known devices")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.knownDeviceEntries) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Circle()
                            .fill(entry.activeSessionID != nil ? .green : .secondary.opacity(0.5))
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text(entry.activeSessionID != nil ? "Connected"
                                 : entry.resolvedTarget != nil ? "Paired · Nearby" : "Paired · Offline")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if entry.activeSessionID == nil, let target = entry.resolvedTarget {
                            Menu {
                                Button("Connect with Mirror") { controller.connect(to: target, mode: .mirror) }
                                Button("Connect with Extend") { controller.connect(to: target, mode: .extend) }
                            } label: {
                                Text("Connect")
                            } primaryAction: {
                                controller.connect(to: target, userInitiated: true)
                            }
                            .menuStyle(.button)
                            .fixedSize()
                            .controlSize(.small)
                        }
                        NavigationLink {
                            ReceiverDeviceDetailView(controller: controller, peerID: entry.id, name: entry.name)
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .controlSize(.small)
                        .help("\(entry.name) settings")
                        // A visible action, not only a context menu — a
                        // known device must be manageable regardless of
                        // whether it's currently active/discoverable.
                        Button("Forget…", role: .destructive) {
                            controller.requestForget(peerID: entry.id, name: entry.name)
                        }
                        .controlSize(.small)
                    }
                    .contextMenu {
                        Button("Forget Device", role: .destructive) {
                            controller.requestForget(peerID: entry.id, name: entry.name)
                        }
                    }
                }
            }

            Section("Pair over Remote") {
                switch controller.remotePairingPhase {
                case .off:
                    Text("Let a device on Tailscale or another reachable address pair with this Mac, for about 3 minutes. Both devices must confirm the same code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Pair over Remote") { controller.openRemotePairing() }
                case .available, .inProgress, .awaitingConfirmation:
                    Text(controller.remotePairingPhase == .available
                         ? "Pair over Remote is on. Enter this Mac's Tailscale address on the other device."
                         : "Pairing in progress…")
                        .font(.caption)
                    Button("Turn Off") { controller.closeRemotePairing() }
                }
            }

            Section("Nearby") {
                // Only genuinely unpaired devices — a Known Device that
                // happens to also be discoverable is reachable through
                // its Known Devices row instead, so it isn't duplicated
                // here.
                let nearby = controller.deviceEntries.filter { controller.pairedPeerID(for: $0) == nil }
                if nearby.isEmpty {
                    Text("No devices found — plug one in via USB, or open the MeowDisplay app on a device on this WiFi network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(nearby) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Circle()
                            .fill(.secondary.opacity(0.5))
                            .frame(width: 9, height: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text(entry.transportLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let target = entry.preferredTarget {
                            if case .wifi(let result) = target,
                               !controller.isPaired(result) {
                                Button("Pair") { controller.pair(result) }
                                    .controlSize(.small)
                            } else {
                                Button("Connect") {
                                    controller.connect(to: target, userInitiated: true)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// One connected device: live status, throughput, reconnect + disconnect.
@MainActor
struct SessionRow: View {
    let title: String
    @ObservedObject var session: DeviceSession
    let controller: SenderController

    private var statusColor: Color {
        if session.status.hasPrefix("Extending") || session.status.hasPrefix("Mirroring")
            || session.status.hasPrefix("Connected") || session.status.hasPrefix("Video off") {
            return .green
        }
        if session.status.hasPrefix("Failed") || session.status.contains("stopped") {
            return .red
        }
        return .orange
    }

    var body: some View {
        if session.invitationProgress != nil || (!session.invitationAdmitted && !session.failed) {
            invitationRow(session.invitationProgress)
        } else {
            sessionRow
        }
    }

    /// Waiting for the other device (or this Mac's own approval panel).
    private func invitationRow(_ progress: SessionInvitationProgress?) -> some View {
        HStack(alignment: .center) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(invitationText(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { controller.cancelInvitation(session) }
                .controlSize(.small)
        }
    }

    private func invitationText(_ progress: SessionInvitationProgress?) -> String {
        switch progress {
        case .waitingForSender: return String(localized: "Waiting for your approval…")
        case .waitingForReceiver: return String(localized: "Waiting for \(title) to accept…")
        default: return String(localized: "Waiting for approval…")
        }
    }

    private var sessionRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(session.statusWithRoute)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if session.mbps > 0 {
                Text("\(String(format: "%.1f", session.mbps)) Mbit/s")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button {
                if session.failed {
                    controller.retry(session)
                } else {
                    session.sender.forceReconnect()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help(session.failed
                ? "Start this connection over"
                : "Drop the connection and pair with the device again")
            Button(session.isPaused ? "Resume" : "Pause") {
                if session.isPaused {
                    session.sender.resumeDisplay()
                } else {
                    session.sender.pauseDisplay()
                }
            }
            .controlSize(.small)
            .disabled(!session.canPauseOrResume)
            if session.deviceKind != "Mac",
               session.receiverProtocolVersion >= WireProtocol.receiverControlsWireVersion {
                Menu {
                    Toggle("Show Control Tray", isOn: Binding(
                        get: { session.receiverTrayEnabled },
                        set: { value in
                            session.receiverTrayEnabled = value
                            session.sender.setReceiverUIPreferences(
                                trayEnabled: value,
                                keyboardButtonEnabled: session.receiverKeyboardButtonEnabled)
                        }))
                    Toggle("Show Keyboard Button", isOn: Binding(
                        get: { session.receiverKeyboardButtonEnabled },
                        set: { value in
                            session.receiverKeyboardButtonEnabled = value
                            session.sender.setReceiverUIPreferences(
                                trayEnabled: session.receiverTrayEnabled,
                                keyboardButtonEnabled: value)
                        }))
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .controlSize(.small)
                .help("Receiver controls")
            }
            Button("Disconnect") { controller.disconnect(session) }
                .controlSize(.small)
        }
    }
}
