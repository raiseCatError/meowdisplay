import AppKit
import SwiftUI

/// Settings ▸ Clipboard: the Unified Clipboard switch (off until turned on), what syncs, the
/// automatic size limit, Pause, and what happened last (never the content). Per-device
/// access lives in Devices ▸ a device ▸ Clipboard.
struct ClipboardSettingsView: View {
    @ObservedObject var controller: SenderController
    @ObservedObject private var hub = ClipboardHub.shared

    var body: some View {
        Form {
            Section {
                Toggle("Unified Clipboard", isOn: $hub.enabled)
                if hub.enabled {
                    Toggle("Pause", isOn: $hub.paused)
                }
            } footer: {
                Text("Copy on this Mac and paste on a connected iPhone, iPad or Android device, and the other way round. Each device asks first (or follows its setting in Devices), and turns it on itself. Copies can contain passwords or private messages: items that apps mark as private are skipped, but not every one can be recognized. Nothing is kept after it is replaced, and nothing is logged.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if hub.enabled {
                Section("What Syncs") {
                    Picker("Types", selection: $hub.types) {
                        Text("Text and Links Only").tag(ClipTypes.text)
                        Text("All Supported Types").tag(ClipTypes.all)
                    }
                    Toggle("Copied Files", isOn: $hub.syncFiles)
                        .disabled(hub.types == .text)
                    Picker("Transfer Automatically Up To", selection: $hub.maxBytes) {
                        ForEach(ClipboardWire.sizeChoices, id: \.self) { n in
                            Text(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)).tag(n)
                        }
                    }
                }

                Section {
                    LabeledContent("Reading This Mac's Clipboard") { Text(readAccessText) }
                    if hub.readAccess == "denied" || hub.readAccess == "ask" {
                        Button("Open Privacy & Security Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                } footer: {
                    Text("macOS asks before an app reads what you copied in another app. Choose Allow for MeowDisplay in System Settings ▸ Privacy & Security ▸ Paste from Other Apps so copies reach your devices without asking each time. Copies from your devices arrive either way.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Status") {
                    if hub.connectedNames.isEmpty {
                        Text("No device connected").foregroundStyle(.secondary)
                    }
                    if let last = hub.lastTransfer {
                        LabeledContent(last.toMac ? "Last from \(last.device)" : "Last sent to \(last.device)") {
                            Text(last.failure.map { "\(last.summary): \($0)" } ?? "\(last.summary), \(last.at.formatted(date: .omitted, time: .shortened))")
                        }
                    }
                    if hub.skippedPrivate {
                        Text("The last copy was marked private by its app and wasn't sent.").foregroundStyle(.secondary)
                    }
                    ForEach(hub.transfers) { t in
                        VStack(alignment: .leading) {
                            Text("\(t.summary) from \(t.device)")
                            ProgressView(value: Double(t.done), total: Double(max(t.bytes, 1)))
                        }
                    }
                    if let w = hub.waitingFiles {
                        HStack {
                            Text("\(w.device) copied \(w.summary) (\(ByteCountFormatter.string(fromByteCount: Int64(w.bytes), countStyle: .file)))")
                            Spacer()
                            Button("Get Files") { hub.getWaitingFiles() }
                        }
                    }
                    if let alt = hub.alternativeFrom {
                        HStack {
                            Text("\(alt) copied something at the same moment")
                            Spacer()
                            Button("Use That Copy") { hub.useAlternative() }
                        }
                    }
                    if !hub.transfers.isEmpty || hub.waitingFiles != nil || hub.alternativeFrom != nil {
                        Button("Clear Pending Transfers", role: .destructive) { hub.clearPending() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clipboard")
    }

    private var readAccessText: String {
        switch hub.readAccess {
        case "allowed": return String(localized: "Allowed")
        case "denied": return String(localized: "Denied in System Settings")
        case "ask": return String(localized: "macOS asks each time")
        default: return String(localized: "macOS asks the first time")
        }
    }
}
