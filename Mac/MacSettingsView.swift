import SwiftUI
import Sparkle

/// The primary GUI: a native, resizable macOS Settings-style sidebar window.
/// There is no separate dashboard — this *is* the main window. See
/// `MacSettingsWindow` for its one-identifiable-window lifecycle.
struct MacSettingsView: View {
    @ObservedObject var controller: SenderController
    @StateObject private var permissions = PermissionMonitor()
    let updater: SPUStandardUpdaterController?
    @State private var selection: SettingsCategory? = .overview
    @State private var sidebarExpanded = true

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(SettingsCategory.allCases) { category in
                        Group {
                            if sidebarExpanded {
                                Label(category.label, systemImage: category.systemImage)
                            } else {
                                Image(systemName: category.systemImage)
                                    .frame(maxWidth: .infinity)
                                    .help(category.label)
                            }
                        }
                        .tag(category)
                    }
                }
                Divider()
                Image("MeowBrand")
                    .resizable()
                    .scaledToFit()
                    .frame(width: sidebarExpanded ? 112 : 42, height: sidebarExpanded ? 112 : 48)
                    .padding(.vertical, 8)
                    .animation(.easeInOut(duration: 0.18), value: sidebarExpanded)
                Button(role: .destructive) { NSApp.terminate(nil) } label: {
                    Group {
                        if sidebarExpanded { Label("Quit MeowDisplay", systemImage: "power") }
                        else { Image(systemName: "power").frame(maxWidth: .infinity) }
                    }
                    .frame(maxWidth: .infinity, alignment: sidebarExpanded ? .leading : .center)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .help("Quit MeowDisplay")
            }
            .frame(width: sidebarExpanded ? 190 : collapsedSidebarWidth)
            .animation(.easeInOut(duration: 0.18), value: sidebarExpanded)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { withAnimation(.easeInOut(duration: 0.18)) { sidebarExpanded.toggle() } } label: {
                        Image(systemName: sidebarExpanded ? "sidebar.leading" : "sidebar.left")
                    }
                    .buttonStyle(.borderless)
                    StatusBadge(controller: controller)
                    Spacer()
                    Text("MeowDisplay v\(appVersion)").font(.callout).foregroundStyle(.secondary)
                    if let updater { CheckForUpdatesView(updater: updater) }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                NavigationStack {
                Group {
                    switch selection ?? .overview {
                    case .overview:
                        OverviewSettingsView(controller: controller,
                                             permissions: permissions,
                                             onOpenDisplays: { selection = .displays },
                                             onOpenDevices: { selection = .devices },
                                             onOpenSystem: { selection = .system })
                    case .displays:
                        DisplaysSettingsView(controller: controller)
                    case .streaming:
                        StreamingSettingsView(controller: controller)
                    case .input:
                        InputSettingsView(controller: controller, permissions: permissions)
                    case .devices:
                        DevicesSettingsView(controller: controller)
                    case .remoteAccess:
                        RemoteAccessSettingsView(controller: controller)
                    case .system:
                        SystemSettingsView(controller: controller, permissions: permissions, updater: updater)
                    #if DEBUG
                    case .developer:
                        DeveloperSettingsView(controller: controller)
                    #endif
                    }
                }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private let collapsedSidebarWidth: CGFloat = 60

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Quick actions only appear when there's exactly one active display —
    /// with more than one, "Pause"/"Disconnect" in the toolbar would be
    /// ambiguous about which session it targets; Overview and Devices stay
    /// the place for per-device actions once there's more than one.
    private var soleActiveSession: DeviceSession? {
        guard controller.activeDisplayEntries.count == 1,
              let id = controller.activeDisplayEntries.first?.id else { return nil }
        return controller.session(for: id)
    }
}

/// The one canonical status readout — same source (`SenderController.
/// canonicalStatusText`/`canonicalPhase`, built from `activeDisplayEntries`)
/// the menu bar quick view and Overview also read, so no surface can ever
/// show "Idle" while another shows a live session, and none can show a
/// stale "connected" color while the canonical phase says otherwise.
struct StatusBadge: View {
    @ObservedObject var controller: SenderController

    private var dotColor: Color {
        switch controller.canonicalPhase {
        case .connected: return .green
        case .paused: return .secondary
        case .reconnecting: return .yellow
        case .lost: return .red
        case .idle: return .secondary.opacity(0.5)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(controller.canonicalStatusText)
                .font(.callout)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .frame(minWidth: 76)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }
}

/// Compact, state-aware toolbar actions for the sole active display —
/// icons only (never text-heavy buttons), reusing the exact same session
/// actions Overview/Devices/the menu bar already call. No duplicate
/// runtime logic lives here.
struct ToolbarQuickActions: View {
    @ObservedObject var session: DeviceSession
    let controller: SenderController

    private var phase: CanonicalConnectionPhase {
        CanonicalRuntimeStatus.phase(capturePhase: session.capturePhase, failed: session.failed)
    }

    var body: some View {
        // Connected -> Pause/Disconnect. Paused -> Resume/Disconnect.
        // Reconnecting/Lost -> Reconnect/Disconnect. Disconnect is always
        // available while a session exists at all.
        if session.canPauseOrResume, phase == .connected || phase == .paused {
            Button {
                if session.isPaused {
                    session.sender.resumeDisplay()
                } else {
                    session.sender.pauseDisplay()
                }
            } label: {
                Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
            }
            .help(session.isPaused ? "Resume streaming" : "Pause streaming")
            .accessibilityLabel(session.isPaused ? "Resume" : "Pause")
        }
        if phase == .reconnecting || phase == .lost {
            Button {
                if session.failed {
                    controller.retry(session)
                } else {
                    session.sender.forceReconnect()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reconnect")
            .accessibilityLabel("Reconnect")
        }
        Button(role: .destructive) {
            controller.disconnect(session)
        } label: {
            Image(systemName: "xmark.circle")
        }
        .help("Disconnect")
        .accessibilityLabel("Disconnect")
    }
}
