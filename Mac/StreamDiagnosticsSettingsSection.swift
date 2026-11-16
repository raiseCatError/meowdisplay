import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → System → Streaming Diagnostics (#123): the opt-in switch, a
/// live stage table and verdict per connected device, and Export. Thin over
/// `StreamDiagnosticsPresentation` (tested); the device name shown here is
/// local UI only and never part of the export.
struct StreamDiagnosticsSettingsSection: View {
    @ObservedObject var controller: SenderController
    @AppStorage(StreamDiagnosticsSwitch.defaultsKey) private var enabled = false
    @State private var exportFailed = false

    var body: some View {
        Section {
            Toggle("Streaming Diagnostics", isOn: Binding(
                get: { enabled },
                set: { enabled = $0; StreamDiagnosticsSwitch.shared.set($0) }))
            if enabled {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let sessions = controller.sessions.filter { !$0.failed }
                    if sessions.isEmpty {
                        Text(verbatim: "No device is streaming.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(sessions) { session in
                        DisclosureGroup(session.name) {
                            StreamDiagnosticsPanel(snapshot: session.sender.diagnostics.snapshot())
                        }
                    }
                }
                Button("Export Diagnostics…") { export() }
                    .controlSize(.small)
                    .disabled(controller.sessions.allSatisfy(\.failed))
            }
        } header: {
            Text("Streaming Diagnostics")
        } footer: {
            Text("Measures each stage of the stream on this Mac (capture, encode, send) and what the device reports back, and names the stage that limits it when the evidence is clear. Off by default. The export holds aggregate numbers only: no window titles, app names, device names, addresses or screen content, and nothing is sent anywhere.")
        }
        .onAppear { StreamDiagnosticsSwitch.shared.set(enabled) }
        .alert("The diagnostics file could not be saved.", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func export() {
        let snapshots = controller.sessions.filter { !$0.failed }.map { $0.sender.diagnostics.snapshot() }
        let export = StreamDiagnosticsExport(sessions: snapshots, build: .current(deviceClass: .mac))
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "meowdisplay-stream-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try export.jsonData().write(to: url, options: .atomic)
        } catch {
            exportFailed = true
        }
    }
}
