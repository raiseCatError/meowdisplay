import Sparkle
import SwiftUI

/// The Receiver application itself — its name on the network, connection
/// behavior, app behavior, updates, and support. Mirrors Mac Sender's System
/// page layout.
struct ReceiverSystemSettingsView: View {
    @ObservedObject var controller: ReceiverController
    let updater: SPUStandardUpdaterController?

    var body: some View {
        WithReceiver(controller) { receiver in
            ReceiverSystemPage(receiver: receiver, controller: controller, updater: updater)
        }
    }
}

private struct ReceiverSystemPage: View {
    @ObservedObject var receiver: StreamReceiver
    let controller: ReceiverController
    let updater: SPUStandardUpdaterController?
    @AppStorage("showAnalytics") private var showAnalytics = false

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        ReceiverSettingsForm {
            Section {
                ReceiverNameField { controller.setAdvertisedName($0) }
            } header: {
                Text("Name")
            } footer: {
                ReceiverCaption("How this Mac appears in the other Mac's Devices list.")
            }

            Section {
                Toggle("Auto-Reconnect", isOn: $receiver.autoReconnectEnabled)
                ReceiverCaption("Automatically reconnect to paired devices after connection interruptions.")
            } header: {
                Text("Connection")
            } footer: {
                ReceiverCaption("Turning this off only stops automatic reconnecting — Connect, Reconnect, and Wake & Connect still work, and this Mac keeps listening for a connection either way.")
            }

            Section("App Behavior") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Performance Overlay", isOn: $showAnalytics)
                    ReceiverCaption("FPS, bitrate, frame timing, and latency graphs at the bottom of the video window while streaming — the same HUD the iPhone app has.")
                }
                ReceiverCaption("Closing this window keeps MeowDisplay Receiver running and available as a display. While a stream is on screen this Mac stays awake; if its screen sleeps, the other Mac is told and reconnects after it wakes.")
            }

            Section("Updates") {
                if let updater {
                    CheckForUpdatesView(updater: updater)
                } else {
                    ReceiverCaption("Updater unavailable")
                }
            }

            Section("Support") {
                Button("Reveal Log Files in Finder") { Log.revealInFinder() }
                    .controlSize(.small)
            }

            Section("About") {
                ReceiverValueRow("Version", value: appVersion)
            }
        }
    }
}

/// The advertised-name editor — kept out of any high-frequency observed
/// object so streaming updates can't rebuild it mid-edit (same reasoning as
/// the iOS DeviceNameField).
private struct ReceiverNameField: View {
    @AppStorage("receiverName") private var name = Host.current().localizedName ?? "Mac"
    let onChange: (String) -> Void

    var body: some View {
        TextField("Receiver Name", text: $name)
            // The single-value onChange: the two-value form is macOS 14.
            .onChange(of: name, perform: onChange)
    }
}

#if DEBUG
/// DEBUG only — never in Release (see `ReceiverSettingsCategory.developer`).
struct ReceiverDeveloperSettingsView: View {
    @ObservedObject var controller: ReceiverController

    var body: some View {
        ReceiverSettingsForm {
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
                Text("Wake")
            } footer: {
                ReceiverCaption("Wake Testing sends a standard Wake-on-LAN magic packet to an already-paired Mac's last-learned local network address (same-LAN only). Promote Interactive Wake asks the connected Mac to declare remote user activity, to test whether that promotes a dark/network wake into a full interactive wake.")
            }
        }
    }
}
#endif
