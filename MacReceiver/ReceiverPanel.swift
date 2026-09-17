import SwiftUI

// MARK: - Receiver panel (issues #82/#17)
//
// Mac Receiver has far less configuration than Mac Sender, so it keeps its
// existing single grouped-Form panel rather than a sidebar — the taxonomy
// still applies (same section names/ownership as Mac Sender/iOS where the
// concept is shared), just without the page-per-category chrome that would
// be clutter here. This target's macOS 12 floor also rules out
// NavigationSplitView (macOS 13+).

/// The receiver-mode sections of the panel: live status, display identity,
/// system/app behavior, and how-to copy. Lives inside the shared grouped Form.
struct ReceiverSections: View {
    @ObservedObject var controller: ReceiverController

    var body: some View {
        // The receiver exists only while receiver mode is on; observed in a
        // subview because nested ObservableObjects don't republish.
        if let receiver = controller.receiver {
            ReceiverStatusSection(receiver: receiver, controller: controller)
        }

        Section {
            Image("MeowBrand")
                .resizable().scaledToFit().frame(width: 72)
            ReceiverNameField { controller.setAdvertisedName($0) }
        } header: {
            Text("Display")
        } footer: {
            Text("How this Mac appears in the other Mac's Devices list.")
        }

        SystemSection()

        Section("How to connect") {
            Label("Install and open MeowDisplay on the Mac whose screen you want to extend.",
                  systemImage: "macbook.and.macbook")
            Label("With both Macs on the same network, this Mac appears in its Devices list — click Connect there.",
                  systemImage: "wifi")
            Label("The stream opens in a window here — use the green traffic light for full screen.",
                  systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .font(.subheadline)

        #if DEBUG
        DeveloperSection(controller: controller)
        #endif
    }
}

/// Live state of the running receiver: connection, stream format, and any
/// compatibility signal from the connected Mac. Status text/color come from
/// `controller.statusTitle`/`statusColor` — the same canonical projection
/// the bottom status strip reads, so the two can never disagree.
private struct ReceiverStatusSection: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var controller: ReceiverController

    var body: some View {
        Section("Connection") {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(controller.statusColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.statusTitle)
                    Text(receiver.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.streaming {
                    Button("Show Window") { controller.showWindow() }
                        .controlSize(.small)
                        .help("Bring the video window back if you closed it — the stream keeps running either way.")
                }
            }
            if receiver.videoSize != .zero {
                // Not LabeledContent: that is macOS 13, the app runs on 12.
                HStack {
                    Text("Stream")
                    Spacer()
                    Text("\(Int(receiver.videoSize.width))×\(Int(receiver.videoSize.height)) @ \(receiver.fps) fps")
                        .foregroundColor(.secondary)
                }
            }
            if let message = peerMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Toggle("Auto-Reconnect", isOn: $receiver.autoReconnectEnabled)
            Text("Automatically reconnect to paired devices after connection interruptions. This Mac keeps listening for a connection either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
}

/// The macOS application itself — matches Mac Sender's System category.
private struct SystemSection: View {
    @AppStorage("showAnalytics") private var showAnalytics = false

    var body: some View {
        Section {
            Toggle("Performance overlay", isOn: $showAnalytics)
        } header: {
            Text("System")
        } footer: {
            Text("FPS, bitrate, frame timing, and latency graphs at the bottom of the video window while streaming — the same HUD the iPhone app has.")
        }
    }
}

#if DEBUG
/// DEBUG only — matches Mac Sender's Developer category naming/scope.
private struct DeveloperSection: View {
    @ObservedObject var controller: ReceiverController

    var body: some View {
        Section {
            DisclosureGroup("Wake Testing") {
                WakeTestingView()
            }
            if let receiver = controller.receiver {
                DisclosureGroup("Promote Interactive Wake") {
                    PromoteInteractiveWakeView(receiver: receiver)
                }
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Wake Testing sends a standard Wake-on-LAN magic packet to an already-paired Mac's last-learned local network address (same-LAN only). Promote Interactive Wake asks the connected Mac to declare remote user activity, to test whether that promotes a dark/network wake into a full interactive wake.")
        }
    }
}
#endif

/// The advertised-name editor — kept out of any high-frequency observed
/// object so streaming updates can't rebuild it mid-edit (same reasoning as
/// the iOS DeviceNameField).
private struct ReceiverNameField: View {
    @AppStorage("receiverName") private var name = Host.current().localizedName ?? "Mac"
    let onChange: (String) -> Void

    var body: some View {
        TextField("Name", text: $name)
            // The single-value onChange: the two-value form is macOS 14.
            .onChange(of: name, perform: onChange)
    }
}
