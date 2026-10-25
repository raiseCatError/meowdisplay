import SwiftUI

/// "Use This Mac as a Display": the unified app's receiver role, one switch
/// away from the sender. Off by default; while on, this Mac shares nothing
/// and waits for another Mac to connect to it as a display.
struct DisplayRoleSection: View {
    @ObservedObject var controller: SenderController
    @ObservedObject private var receiver = ReceiverController.shared

    var body: some View {
        Section {
            Toggle("Use This Mac as a Display", isOn: Binding(
                get: { controller.receiverModeEnabled },
                set: { controller.setReceiverModeEnabled($0) }))
            if let notice = controller.receiverModeNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if controller.receiverModeEnabled {
                LabeledContent("Status", value: receiver.statusTitle)
                if receiver.streaming {
                    Button("Show Window") { receiver.showWindow() }
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
