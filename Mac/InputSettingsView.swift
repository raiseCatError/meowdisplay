import SwiftUI

/// Normal interaction/security controls. Two deliberately separate layers
/// live here (see the per-device/per-session input consent milestone):
/// `Allow Input` is the Mac-wide master switch/kill-switch — while OFF, no
/// receiver may control the Mac, full stop, regardless of any session grant
/// or per-device policy. "Input Requests" per device is a permanent POLICY,
/// never a live grant: `Always Allow Requests` only means a future control
/// request from that device skips the Mac prompt — every new connection
/// still starts that session's own input OFF, and the receiver must still
/// explicitly ask.
struct InputSettingsView: View {
    @ObservedObject var controller: SenderController
    @ObservedObject var permissions: PermissionMonitor

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Allow Input", isOn: $controller.allowInput)
                    Text("Master switch for remote control. While off, no connected device can control this Mac, no matter what it was previously granted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !controller.activeDisplayEntries.isEmpty {
                Section("Current Session") {
                    LabeledContent("Accessibility", value: permissions.accessibility ? "Granted" : "Not Granted")
                }
            }

            Section {
                if controller.knownDeviceEntries.isEmpty {
                    Text("No paired devices yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.knownDeviceEntries) { entry in
                        Picker(entry.name, selection: Binding(
                            get: { entry.inputPolicy },
                            set: { controller.setInputPolicy($0, peerID: entry.id) })) {
                            Text("Ask").tag(PeerInputRequestPolicy.ask)
                            Text("Always Allow Requests").tag(PeerInputRequestPolicy.alwaysAllow)
                            Text("Never Allow Requests").tag(PeerInputRequestPolicy.neverAllow)
                        }
                        .disabled(!controller.canSetInputPolicy(.alwaysAllow, peerID: entry.id)
                            && entry.inputPolicy != .alwaysAllow)
                    }
                }
            } header: {
                Text("Input Requests")
            } footer: {
                if controller.anySessionHasEffectiveInput {
                    Text("A device currently controlling this Mac can't be promoted to Always Allow Requests right now — this prevents a connected device from granting itself permanent access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ask shows a prompt on this Mac for every new request. Always Allow Requests skips the prompt but still requires the device to explicitly ask each session — connecting alone never turns input on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
