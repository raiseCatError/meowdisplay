import SwiftUI
import Sparkle

/// The macOS application itself — permissions, app behavior, updates.
struct SystemSettingsView: View {
    @ObservedObject var controller: SenderController
    @ObservedObject var permissions: PermissionMonitor
    let updater: SPUStandardUpdaterController?

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow(
                    "Screen Recording",
                    granted: permissions.screenRecording,
                    help: "Required to capture the display.",
                    anchor: "Privacy_ScreenCapture",
                    request: { permissions.requestScreenRecording() }
                )
                permissionRow(
                    "Accessibility",
                    granted: permissions.accessibility,
                    help: "Required for touch input from the device.",
                    anchor: "Privacy_Accessibility",
                    request: { permissions.requestAccessibility() }
                )
                // macOS offers no API to query Local Network access, so
                // infer from discovery results and let the user check.
                permissionRow(
                    "Local Network",
                    granted: !controller.discovered.isEmpty,
                    uncertain: controller.discovered.isEmpty,
                    help: "Required for WiFi mode. If no device appears in the Devices list, allow OpenDisplay under Privacy & Security → Local Network on this Mac AND on the device — and keep the OpenDisplay app open there.",
                    anchor: "Privacy_LocalNetwork"
                )
                WakeForNetworkAccessRow()
            }

            Section {
                Toggle("Auto-Reconnect", isOn: $controller.autoReconnectEnabled)
                Text("Automatically connect and reconnect to paired devices when available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Connection")
            } footer: {
                Text("Turning this off only stops automatic connecting — Connect, Reconnect, and Wake & Connect still work, and an active session stays connected.")
            }

            Section("App Behavior") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Show app in", selection: $controller.presentation) {
                        ForEach(AppPresentation.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    if controller.presentation == .background {
                        Text("No menu bar or Dock icon — streaming keeps running. Open the OpenDisplay app again (Spotlight/Finder) to show this window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Updates") {
                if let updater {
                    CheckForUpdatesView(updater: updater)
                } else {
                    Text("Updater unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Support") {
                Button("Reveal Log Files in Finder") { Log.revealInFinder() }
                    .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, uncertain: Bool = false,
                               help: String, anchor: String,
                               request: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: uncertain ? "questionmark.circle.fill"
                            : granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(uncertain ? .orange : granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if uncertain || !granted {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if uncertain || !granted {
                if let request {
                    Button("Grant…") { request() }
                        .controlSize(.small)
                        .help("Ask macOS for this permission. If the system dialog was already dismissed once, this registers the app under \(title) in System Settings — flip the toggle there.")
                }
                Button("Open Settings") {
                    PermissionMonitor.openPrivacyPane(anchor)
                }
                .controlSize(.small)
            }
        }
    }
}
