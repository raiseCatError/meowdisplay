import SwiftUI
import UIKit

/// Settings → Diagnostics → Streaming Diagnostics (#123): the live stage
/// table and verdict for this device's stream, and Export (a local JSON file
/// handed to the share sheet; nothing is uploaded). Thin over
/// `StreamDiagnosticsPresentation`, which is tested in MacTests.
struct StreamDiagnosticsDetailView: View {
    let receiver: StreamReceiver
    @State private var exportURL: URL?
    @State private var exportFailed = false

    var body: some View {
        List {
            Section {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    StreamDiagnosticsPanel(snapshot: receiver.diagnostics.snapshot())
                }
            } footer: {
                Text("Turn Streaming Diagnostics on on the Mac as well to see its stages and a verdict here.")
            }
            Section {
                Button("Prepare Export") { prepareExport() }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share Export", systemImage: "square.and.arrow.up")
                    }
                }
                if exportFailed {
                    Text("The export could not be written.").foregroundStyle(.secondary)
                }
            } footer: {
                Text("A JSON file with aggregate numbers only: no names, addresses or screen content.")
            }
        }
        .navigationTitle("Streaming Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        // Battery state needs monitoring on; only while this page is open.
        .task {
            UIDevice.current.isBatteryMonitoringEnabled = true
            while !Task.isCancelled {
                StreamDiagnosticsResourceSampler.setBatteryState(Self.batteryState(UIDevice.current.batteryState))
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        .onDisappear {
            StreamDiagnosticsResourceSampler.setBatteryState(nil)
            UIDevice.current.isBatteryMonitoringEnabled = false
        }
    }

    private static func batteryState(_ state: UIDevice.BatteryState) -> DiagnosticsBatteryState {
        switch state {
        case .unplugged: return .unplugged
        case .charging: return .charging
        case .full: return .full
        default: return .unknown
        }
    }

    private func prepareExport() {
        let deviceClass: DiagnosticsDeviceClass = UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        let export = StreamDiagnosticsExport(sessions: [receiver.diagnostics.snapshot()],
                                             build: .current(deviceClass: deviceClass))
        do {
            exportURL = try export.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("StreamDiagnostics"))
            exportFailed = false
        } catch {
            exportURL = nil
            exportFailed = true
        }
    }
}
