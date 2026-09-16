import SwiftUI

/// Normal interaction/security controls. Two deliberately separate gates
/// live here (see the milestone's SETTINGS / ALLOW INPUT INVARIANTS):
/// `Allow Input` is the Mac-wide master switch — while OFF, no receiver may
/// control the Mac, full stop. "Devices allowed to enable input" is a much
/// narrower, per-device SECURITY authorization: it only lets an already-
/// trusted device ask to turn the master switch on without a fresh Mac
/// confirmation every time — it can never itself bypass the master switch,
/// and un-authorizing a device never touches the master switch either.
struct InputSettingsView: View {
    @ObservedObject var controller: SenderController
    @ObservedObject var permissions: PermissionMonitor

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Allow Input", isOn: $controller.allowInput)
                    Text("Allow touch, scrolling, and pointer input from the connected device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !controller.activeDisplayEntries.isEmpty {
                Section("Current Session") {
                    LabeledContent("Touch/Input", value: controller.allowInput ? "Active" : "Disabled")
                    LabeledContent("Keyboard", value: "Available")
                    LabeledContent("Accessibility", value: permissions.accessibility ? "Granted" : "Not Granted")
                }
            }

            Section {
                if controller.knownDeviceEntries.isEmpty {
                    Text("No devices are currently allowed to enable input remotely.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.knownDeviceEntries) { entry in
                        Toggle(entry.name, isOn: Binding(
                            get: { entry.inputAuthorized },
                            set: { controller.setInputAuthorized($0, peerID: entry.id) }))
                    }
                }
            } header: {
                Text("Devices allowed to enable input")
            } footer: {
                Text("A permanently allowed device can turn Allow Input on from its own screen without asking here every time. It can never do this while Allow Input is off for a reason other than that device's own request, and it never bypasses this Mac's Allow Input master switch above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
