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

    var body: some View {
        NavigationSplitView {
            // Explicit `ForEach` + `.tag(category)` per row — the form that
            // reliably drives `List(selection:)` on macOS. The single-closure
            // `List(data, selection:rowContent:)` initializer used here
            // previously compiled but never actually wired row clicks to the
            // binding: rows rendered, but there was no `.tag()` telling the
            // list which selection value each row corresponds to, so every
            // click was a no-op.
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(SettingsCategory.allCases) { category in
                        Label(category.label, systemImage: category.systemImage)
                            .tag(category)
                    }
                }
                // Deliberately not a `SettingsCategory` and not part of the
                // selectable list: the red window-close button must keep
                // meaning "close this window, MEOW keeps running" (App Exit
                // Policy). This is a separate, visually-detached action for
                // the rare case the user actually wants to end the app —
                // same effect as Cmd+Q, reusing NSApp's own termination path
                // rather than a bespoke shutdown route.
                Divider()
                Button(role: .destructive) {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit MeowDisplay", systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .help("Quit MeowDisplay entirely — equivalent to ⌘Q. Closing just this window keeps MEOW and any active stream running.")
                .accessibilityLabel("Quit MeowDisplay")
                .accessibilityHint("Terminates the application, ending any active connection.")
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
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
                .navigationTitle((selection ?? .overview).label)
                // Opaque title-bar backing so scrolled content doesn't
                // show through the toolbar area.
                .toolbarBackground(Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
                .toolbar {
                    // Trailing/utility position — `.principal` centers and
                    // competes with the page title; a status indicator reads
                    // as a stable trailing item instead, like the rest of
                    // macOS's own toolbar status affordances.
                    ToolbarItemGroup(placement: .primaryAction) {
                        if let session = soleActiveSession {
                            ToolbarQuickActions(session: session, controller: controller)
                        }
                    }
                    StatusPillsToolbarItem(controller: controller)
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
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

/// The status pill and (only while the assertion is actually held) the
/// Keep Mac Available pill, as two independent capsules side by side. The
/// system's shared toolbar background is hidden where supported so it
/// can't fuse them into one glass capsule.
struct StatusPillsToolbarItem: ToolbarContent {
    @ObservedObject var controller: SenderController

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { pills }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .primaryAction) { pills }
        }
    }

    private var pills: some View {
        HStack(spacing: 8) {
            StatusBadge(controller: controller)
            if controller.keepMacAvailableActive {
                KeepAvailablePill()
            }
        }
    }
}

/// Shown only while the power assertion is actually held.
struct KeepAvailablePill: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
            Text("Keeping Mac Available")
                .font(.callout)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
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
