#if DEBUG
import SwiftUI

/// DEBUG only — never appears in Release (see SettingsCategory.developer,
/// which only exists under `#if DEBUG`). Organizes existing diagnostics
/// rather than deleting them.
struct DeveloperSettingsView: View {
    @ObservedObject var controller: SenderController

    var body: some View {
        Form {
            Section("Connection") {
                DisclosureGroup("Route Overrides") {
                    RouteOverridesView()
                }
                DisclosureGroup("Remote Endpoint") {
                    RemoteEndpointDebugView(controller: controller)
                }
            }

            Section("Wake") {
                DisclosureGroup("Wake Testing") {
                    WakeTestingDebugView()
                }
                Text("Power lifecycle (sleep/wake/screen) events are logged continuously to the app log — see System → Reveal Log Files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("State") {
                DisclosureGroup("Device Diagnostics") {
                    ForEach(controller.peerDiagnostics) { peer in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name).font(.caption.bold())
                            Text("peer=\(peer.id)").font(.caption2).foregroundStyle(.secondary)
                            Text("trusted=\(peer.trusted) normalDiscovered=\(peer.normalDiscovered) pairingDiscovered=\(peer.pairingDiscovered)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("connected=\(peer.connected) route=\(peer.route) generation=\(peer.sessionGeneration)")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text("normalEndpoint=\(peer.normalEndpoint)").font(.caption2).foregroundStyle(.secondary)
                            Text("pairingEndpoint=\(peer.pairingEndpoint)").font(.caption2).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        Divider()
                    }
                }
                LabeledContent("Manual Host", value: controller.host)
                LabeledContent("Manual Port", value: controller.port)
                Text("Set via -host/-port launch arguments — a debugging escape hatch, not a user setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
#endif
