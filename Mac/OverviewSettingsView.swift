import SwiftUI

/// Overview is primarily STATUS — the first thing the user should see, read
/// entirely from `SenderController.activeDisplayEntries`, the same canonical
/// projection Devices → Active Display and the menu bar use.
struct OverviewSettingsView: View {
    @ObservedObject var controller: SenderController
    let onOpenDisplays: () -> Void
    let onOpenDevices: () -> Void

    var body: some View {
        Form {
            if controller.activeDisplayEntries.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No active display")
                            .font(.headline)
                        Text("Ready to connect")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                disconnectedSuggestions
            } else {
                if controller.activeDisplayEntries.count > 1 {
                    Section {
                        Button("Disconnect All") { controller.disconnectAll() }
                    }
                }
                ForEach(controller.activeDisplayEntries) { entry in
                    Section(entry.name) {
                        Text(headline(for: entry))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        LabeledContent("Video", value: entry.videoActive ? "Streaming" : "Off")
                        LabeledContent("Audio", value: entry.audioActive ? "Streaming" : "Off")
                        LabeledContent("Input", value: entry.allowInput ? "Enabled" : "Disabled")

                        if entry.videoWidth > 0, entry.videoHeight > 0 {
                            LabeledContent("Resolution", value: "\(entry.videoWidth) × \(entry.videoHeight)")
                        }
                        LabeledContent("Video Bitrate", value: "\(entry.bitrateBps / 1_000_000) Mbps")

                        LabeledContent("Connection", value: entry.route?.rawValue ?? "Connecting…")
                        LabeledContent("Status", value: "Authenticated")

                        HStack {
                            if let session = controller.session(for: entry.id) {
                                if session.canPauseOrResume {
                                    Button(session.isPaused ? "Resume" : "Pause") {
                                        if session.isPaused {
                                            session.sender.resumeDisplay()
                                        } else {
                                            session.sender.pauseDisplay()
                                        }
                                    }
                                    .controlSize(.small)
                                }
                                Button("Reconnect") {
                                    if session.failed {
                                        controller.retry(session)
                                    } else {
                                        session.sender.forceReconnect()
                                    }
                                }
                                .controlSize(.small)
                                Button("Disconnect") { controller.disconnect(session) }
                                    .controlSize(.small)
                            }
                            Button("Open Displays…") { onOpenDisplays() }
                                .controlSize(.small)
                            Spacer()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Disconnected-state "what can I do now?" — priority: reconnectable
    /// known devices, then unrecognized nearby ones, then (nothing shown)
    /// the true empty state already covered above. Deliberately concise —
    /// this is not a second copy of the Devices page, just enough to act
    /// without leaving Overview; Devices remains where full management
    /// (Forget, all known/nearby rows) lives.
    @ViewBuilder
    private var disconnectedSuggestions: some View {
        let reconnectableKnown = controller.knownDeviceEntries.filter { $0.resolvedTarget != nil }
        let unknownNearby = controller.deviceEntries.filter { controller.pairedPeerID(for: $0) == nil }

        if !reconnectableKnown.isEmpty {
            Section("Known Devices") {
                ForEach(reconnectableKnown) { entry in
                    HStack {
                        Text(entry.name)
                        Spacer()
                        if let target = entry.resolvedTarget {
                            Button("Connect") { controller.connect(to: target, userInitiated: true) }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }

        if !unknownNearby.isEmpty {
            Section("Nearby") {
                ForEach(unknownNearby) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                            Text(entry.transportLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let target = entry.preferredTarget {
                            if case .wifi(let result) = target, !controller.isPaired(result) {
                                Button("Pair") { controller.pair(result) }
                                    .controlSize(.small)
                            } else {
                                Button("Connect") { controller.connect(to: target, userInitiated: true) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }

        if !reconnectableKnown.isEmpty || !unknownNearby.isEmpty {
            Section {
                Button("Open Devices…") { onOpenDevices() }
                    .controlSize(.small)
            }
        }
    }

    private func headline(for entry: SenderController.ActiveDisplayEntry) -> String {
        var text = CanonicalRuntimeStatus.entryStatusText(mode: entry.mode, route: entry.route, phase: entry.phase)
        if entry.videoWidth > 0, entry.videoHeight > 0 {
            text += "\n\(entry.videoWidth) × \(entry.videoHeight)"
        }
        return text
    }
}
