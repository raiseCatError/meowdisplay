import SwiftUI

/// Overview is STATUS first, like Mac Sender's: who this receiver is, the
/// canonical connection state (`controller.statusTitle`/`statusColor`, the
/// same pair the toolbar badge reads), what is streaming, and the actions
/// that apply right now. Configuration lives on the other pages.
struct ReceiverOverviewSettingsView: View {
    @ObservedObject var controller: ReceiverController
    let navigationModel: ReceiverSettingsNavigationModel

    var body: some View {
        WithReceiver(controller) { receiver in
            ReceiverOverviewPage(receiver: receiver, controller: controller, navigationModel: navigationModel)
        }
    }
}

private struct ReceiverOverviewPage: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var controller: ReceiverController
    let navigationModel: ReceiverSettingsNavigationModel
    /// Remembered like the iPhone app's Connection Instructions, but
    /// collapsed until opened.
    @AppStorage("overview.connectionInstructionsExpanded") private var instructionsExpanded = false

    private var connectedMacName: String? {
        guard receiver.connected, let peerID = receiver.authenticatedPeerID else { return nil }
        return TrustStore.shared.pinnedPeers().first { $0.peerID == peerID }?.displayName
    }

    /// Compatibility copy from the sender (issue #132) — surfaced inline;
    /// the Mac app has Sparkle, so there is no blocking gate like on iOS.
    private var peerMessage: String? {
        switch receiver.peerSignal {
        case let .updateReceiver(message, _): return message
        case let .updateMac(message): return message
        case nil: return nil
        }
    }

    var body: some View {
        ReceiverSettingsForm {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 40, height: 40)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MeowDisplay Receiver", comment: "App title. \"MeowDisplay\" is the product name and must stay untranslated; only \"Receiver\" (this Mac acting as a display for another Mac) is translatable.")
                            .font(.headline)
                        Text("This Mac as an extra display for another Mac")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Appears as “\(receiver.serviceName)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Status") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(controller.statusColor)
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.statusTitle)
                        if receiver.status != controller.statusTitle {
                            ReceiverCaption(verbatim: receiver.status)
                        }
                    }
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                if let peerMessage {
                    Label(peerMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                actions
                // The receiver's own published preference — the same state
                // System → Connection binds, so the two always agree.
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Auto-Reconnect", isOn: $receiver.autoReconnectEnabled)
                    ReceiverCaption("Automatically reconnect after connection interruptions.")
                }
            }

            if !receiver.connected, let wakeConnect = controller.wakeConnect {
                ReceiverOverviewMacsSection(receiver: receiver, wakeConnect: wakeConnect,
                                            navigationModel: navigationModel)
            }

            if !receiver.connected {
                Section {
                    DisclosureGroup("How to Connect", isExpanded: $instructionsExpanded) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Install and open MeowDisplay on the Mac whose screen you want to extend.",
                                  systemImage: "laptopcomputer")
                            Label("With both Macs on the same network, this Mac appears in its Devices list — click Connect there.",
                                  systemImage: "wifi")
                            Label("The stream opens here in full screen. The green traffic light switches to a window, and MeowDisplay remembers your choice.",
                                  systemImage: "arrow.up.left.and.arrow.down.right")
                            Button("Open Devices…") { navigationModel.navigateTo(.devices) }
                                .controlSize(.small)
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                }
            }

            if receiver.connected {
                Section("Current Stream") {
                    if let connectedMacName {
                        ReceiverValueRow("Sending Mac", value: connectedMacName)
                    }
                    if receiver.videoSize != .zero {
                        ReceiverValueRow("Resolution",
                                         value: "\(Int(receiver.videoSize.width)) × \(Int(receiver.videoSize.height))")
                        ReceiverValueRow("Frame Rate", value: "\(receiver.fps) fps")
                    }
                    ReceiverValueRow("Video", value: receiver.videoEnabled
                                     ? String(localized: "On") : String(localized: "Off"))
                    if let mode = receiver.confirmedDisplayMode {
                        ReceiverValueRow("Display Mode", value: mode.title)
                    }
                    ReceiverValueRow("Streaming Profile", value: receiver.streamingProfile.label)
                    ReceiverValueRow("Codec", value: ReceiverStreamingPresentation.codecLabel(receiver.activeStreamCodec))
                    ReceiverValueRow("Audio", value: receiver.audioEnabled
                                     ? String(localized: "Playing") : String(localized: "Off"))
                }
            }

            Section {
                ReceiverCaption("This Mac only displays the stream. Its keyboard and trackpad are not sent to the other Mac, so there is no input permission to request.")
            } header: {
                Text("Input")
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        let controls = ReceiverConnectionControls(session: receiver.session, connected: receiver.connected)
        if controller.streaming || controls.canReconnect || controls.canDisconnect {
            HStack {
                if controller.streaming {
                    Button("Show Window") { controller.showWindow() }
                        .controlSize(.small)
                        .help("Bring the video window back if you closed it — the stream keeps running either way.")
                }
                if controls.canReconnect {
                    Button("Reconnect") { receiver.reconnectNow() }
                        .controlSize(.small)
                        .help("Re-arm this Mac's listener and wait for the other Mac to reconnect.")
                }
                if controls.canDisconnect {
                    Button("Disconnect") { receiver.disconnect() }
                        .controlSize(.small)
                        .help("End this session. Pairing is kept — connect again from the other Mac.")
                }
                Button("Open Displays…") { navigationModel.navigateTo(.displays) }
                    .controlSize(.small)
                Spacer()
            }
        }
    }
}

/// Paired and nearby Macs while disconnected — a compact view of the Devices
/// page using its shared rows, so status and actions are identical there.
/// Hidden when there is nothing to show; Forget stays on Devices.
private struct ReceiverOverviewMacsSection: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var wakeConnect: WakeConnectCoordinator
    let navigationModel: ReceiverSettingsNavigationModel

    var body: some View {
        let paired = ReceiverMacList.paired()
        let nearby = ReceiverMacList.unpairedNearby(receiver)
        if !paired.isEmpty || !nearby.isEmpty {
            Section("Macs") {
                ForEach(paired, id: \.peerID) { mac in
                    ReceiverPairedMacRow(receiver: receiver, wakeConnect: wakeConnect,
                                         peerID: mac.peerID, name: mac.displayName)
                }
                ForEach(nearby, id: \.endpoint) { result in
                    ReceiverNearbyMacRow(receiver: receiver, result: result)
                }
                HStack {
                    Button("Open Devices…") { navigationModel.navigateTo(.devices) }
                        .controlSize(.small)
                    Spacer()
                }
            }
        }
    }
}
