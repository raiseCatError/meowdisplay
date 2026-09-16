import SwiftUI

/// The menu bar's content: a SMALL quick-status/quick-actions surface, never
/// the main Settings UI. Reads the exact same canonical projection Overview
/// and Devices → Active Display do, so it can never disagree with them.
struct MenuBarQuickView: View {
    @ObservedObject var controller: SenderController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("MeowDisplay")
                .font(.headline)

            if controller.activeDisplayEntries.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No active display")
                    Text("Idle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(controller.activeDisplayEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name).font(.subheadline.bold())
                        Text(headline(for: entry))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("Video").foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.videoActive ? "On" : "Off")
                        }
                        .font(.caption)
                        HStack {
                            Text("Input").foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.allowInput ? "On" : "Off")
                        }
                        .font(.caption)
                        if let session = controller.session(for: entry.id) {
                            HStack(spacing: 8) {
                                if session.canPauseOrResume {
                                    Button(session.isPaused ? "Resume" : "Pause") {
                                        if session.isPaused {
                                            session.sender.resumeDisplay()
                                        } else {
                                            session.sender.pauseDisplay()
                                        }
                                    }
                                    .controlSize(.small)
                                }
                                Button("Reconnect") {
                                    if session.failed {
                                        controller.retry(session)
                                    } else {
                                        session.sender.forceReconnect()
                                    }
                                }
                                .controlSize(.small)
                                Button("Disconnect") { controller.disconnect(session) }
                                    .controlSize(.small)
                            }
                        }
                    }
                    Divider()
                }
            }

            Button("Open Settings…") { MacSettingsWindow.show() }
                .controlSize(.small)

            Divider()

            Button("Quit") { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .padding(12)
        .frame(width: 280)
    }

    private func headline(for entry: SenderController.ActiveDisplayEntry) -> String {
        CanonicalRuntimeStatus.entryStatusText(mode: entry.mode, route: entry.route, phase: entry.phase)
    }
}
