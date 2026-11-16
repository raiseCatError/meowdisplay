import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings → System → Streaming Diagnostics on a Mac used as a display
/// (#123): the opt-in switch, the live stage table and verdict, and Export.
/// Thin over `StreamDiagnosticsPresentation` (tested in MacTests).
struct ReceiverStreamDiagnosticsSection: View {
    let receiver: StreamReceiver
    @AppStorage(StreamDiagnosticsSwitch.defaultsKey) private var enabled = false
    @State private var exportFailed = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Streaming Diagnostics", isOn: Binding(
                    get: { enabled },
                    set: { enabled = $0; StreamDiagnosticsSwitch.shared.set($0) }))
                ReceiverCaption("Measures each stage of the stream on this Mac and names the stage that limits it when the evidence is clear. Turn it on on the sending Mac too. Exports hold aggregate numbers only.")
            }
            if enabled {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    StreamDiagnosticsPanel(snapshot: receiver.diagnostics.snapshot())
                }
                Button("Export Diagnostics…") { export() }
                    .controlSize(.small)
            }
        } header: {
            Text("Streaming Diagnostics")
        }
        .onAppear { StreamDiagnosticsSwitch.shared.set(enabled) }
        .alert("The diagnostics file could not be saved.", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func export() {
        let export = StreamDiagnosticsExport(sessions: [receiver.diagnostics.snapshot()], build: .current(deviceClass: .mac))
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
