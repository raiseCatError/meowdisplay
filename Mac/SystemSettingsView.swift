import SwiftUI
import Sparkle

/// The macOS application itself — permissions, app behavior, updates.
struct SystemSettingsView: View {
    @ObservedObject var controller: SenderController
    @ObservedObject var permissions: PermissionMonitor
    let updater: SPUStandardUpdaterController?

    // Cat Mode (hidden easter egg — nine taps on the About/version row
    // below). Local-only presentation state: never synced, never on the
    // wire. `catModeTapCount` intentionally isn't persisted — a relaunch
    // mid-tapping just resets the count.
    @AppStorage(CatMode.unlockedDefaultsKey) private var catModeUnlocked = false
    @AppStorage(CatMode.enabledDefaultsKey) private var catModeEnabledStorage = false
    @AppStorage(CatMode.tapCountDefaultsKey) private var catModeTapCount = 0
    @State private var showCatModeUnlockedAlert = false

    private var catModeEnabled: Bool {
        CatMode.resolveEnabled(requestedEnabled: catModeEnabledStorage, unlocked: catModeUnlocked)
    }

    private var catModeToggleBinding: Binding<Bool> {
        Binding(
            get: { catModeEnabled },
            set: { catModeEnabledStorage = CatMode.resolveEnabled(requestedEnabled: $0, unlocked: catModeUnlocked) }
        )
    }

    private func registerCatModeTap() {
        let result = CatMode.registerTap(tapCount: catModeTapCount, alreadyUnlocked: catModeUnlocked)
        catModeTapCount = result.tapCount
        if result.justUnlocked {
            catModeUnlocked = true
            showCatModeUnlockedAlert = true
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

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
                    help: "Required for WiFi mode. If no device appears in the Devices list, allow MeowDisplay under Privacy & Security → Local Network on this Mac AND on the device — and keep the MeowDisplay app open there.",
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
                Picker("Show app in", selection: $controller.presentation) {
                    ForEach(AppPresentation.allCases, id: \.self) { p in
                        Text(p.label).tag(p)
                    }
                }

                Toggle("Start at Login", isOn: $controller.startAtLoginEnabled)
                if let message = controller.startAtLoginStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 8) {
                    Circle()
                        .fill(controller.keepMacAvailableActive ? Color.green
                              : controller.keepMacAvailableRequested ? Color.orange
                              : Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Toggle("Keep Mac Available", isOn: $controller.keepMacAvailableRequested)
                }
                if controller.keepMacAvailableRequested && !controller.keepMacAvailableActive {
                    Text("macOS didn't allow the sleep-prevention request, so this Mac may still sleep.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Prevent this Mac from automatically sleeping while MEOW is running, so remote devices can connect without Wake-on-LAN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The display can still turn off normally. Closing a MacBook's lid can still put it to sleep; closed-lid use requires your MacBook to be connected to power and is up to macOS.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup("Prefer Terminal?") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("caffeinate -i")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text("Press Ctrl-C to stop. Add -t 3600 to stop after an hour. On a Mac connected to power, caffeinate -is also requests system-sleep prevention.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Copy Command") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("caffeinate -i", forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
                .font(.caption)
            } header: {
                Text("Availability")
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

            Section {
                LabeledContent("Version", value: appVersion)
                    // Hidden unlock gesture: nine taps here (a cat's nine
                    // lives) reveals Cat Mode below. No visible affordance
                    // before unlock — this reads like an ordinary,
                    // non-interactive detail row.
                    .contentShape(Rectangle())
                    .onTapGesture { registerCatModeTap() }
                if catModeUnlocked {
                    Toggle(isOn: catModeToggleBinding) {
                        Label("Cat Mode", systemImage: "pawprint.fill")
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Text("About")
                    if catModeEnabled {
                        Image(systemName: "pawprint.fill")
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .alert("Cat Mode unlocked 🐾", isPresented: $showCatModeUnlockedAlert) {
            Button("Nice", role: .cancel) {}
        }
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
