import SwiftUI

/// System Setup row for "Wake for Network Access" — read-only status via
/// `pmset -g`, never required for ordinary MEOW usage, only for Wake
/// functionality once the Tailscale wake relay exists.
struct WakeForNetworkAccessRow: View {
    @State private var status = WakeInspector.wakeForNetworkAccessStatus()

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wake for Network Access")
                Text(status.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if status != .enabled {
                    Text("Only required for Wake — turning this on lets a sleeping Mac respond to a Wake-on-LAN packet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.energysaver") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
            Button("Recheck") { status = WakeInspector.wakeForNetworkAccessStatus() }
                .controlSize(.small)
        }
    }

    private var iconName: String {
        switch status {
        case .enabled: return "checkmark.circle.fill"
        case .disabled: return "xmark.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch status {
        case .enabled: return .green
        case .disabled: return .red
        case .unknown: return .orange
        }
    }
}
