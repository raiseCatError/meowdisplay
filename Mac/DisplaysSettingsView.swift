import SwiftUI

/// Displays answers: WHAT DISPLAY / PIXELS SHOULD MEOW PRODUCE OR CAPTURE?
/// Resolution/scaling configuration belongs here — transmission quality
/// (bitrate, frame rate) belongs to Streaming instead.
struct DisplaysSettingsView: View {
    @ObservedObject var controller: SenderController
    @AppStorage(WindowStreamingPolicy.defaultsKey) private var allowWindowStreaming = true

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: Binding(
                    get: { controller.mode },
                    set: { controller.requestMode($0) })) {
                    Text("Extend", comment: "Display mode: add the device as a second, separate screen (not the verb \"to extend\").")
                        .tag(CaptureMode.extend)
                        .disabled(!controller.videoEnabled)
                    Text("Mirror", comment: "Display mode: duplicate the Mac's screen onto the device.")
                        .tag(CaptureMode.mirror)
                        .disabled(!controller.hasUsablePhysicalDisplay)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Default Display Mode")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Applies to devices that haven't chosen their own mode. Each device can Mirror or Extend on its own — set it in that device's settings, or from the device itself.")
                    // Disabling the segment alone still lets a stale keyboard/
                    // accessibility selection reach it — `requestMode` is the
                    // actual authority and rejects Mirror regardless; this is
                    // just telling the user why.
                    if !controller.hasUsablePhysicalDisplay {
                        Text("Mirror requires an active physical display.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Let devices show individual windows", isOn: $allowWindowStreaming)
            } header: {
                Text("Windows")
            } footer: {
                Text("A connected device can pick Mac windows to show side by side instead of a whole display. Nothing on this Mac moves. Applies the next time a device connects.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            RemoteFilesSettingsSection()

            if controller.mode == .mirror {
                Section {
                    MirrorDisplayPickerView(controller: controller)
                } header: {
                    Text("Default Mirror Display")
                } footer: {
                    Text("Used by mirroring devices that haven't chosen their own display.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            let connected = controller.activeDisplayEntries
            if connected.count > 1 {
                Section("Connected Devices") {
                    ForEach(connected) { entry in
                        LabeledContent(entry.name, value: entry.mode.title)
                    }
                }
            }

            Section {
                Picker("Extend Display", selection: Binding(
                    get: { controller.extendShapeDefault.shape },
                    set: { controller.extendShapeDefault.shape = $0 })) {
                    ForEach(ExtendDisplayShape.allCases) { shape in
                        Text(shape.title).tag(shape)
                    }
                }
                if controller.extendShapeDefault.shape == .automatic {
                    Toggle("Use Full Display", isOn: Binding(
                        get: { controller.extendShapeDefault.useFullDisplay },
                        set: { controller.extendShapeDefault.useFullDisplay = $0 }))
                }
            } header: {
                Text("Extend Shape")
            } footer: {
                Text("Applies to devices that haven't chosen their own shape yet. Each device remembers whatever shape it (or this Mac, in its own device settings) last selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                LabeledContent("Display layout") {
                    Button("Arrange Displays…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .help("Opens System Settings → Displays, where you can position the extended displays relative to your Mac screen (Arrange…). Each device shows up as its own display, named after the device.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Remote Finder: off by default; the owner picks the folders, and every session still asks.
private struct RemoteFilesSettingsSection: View {
    @AppStorage(RemoteFilesPolicy.enabledKey) private var enabled = false
    @State private var roots = RemoteFileRoot.load()
    @State private var refused: String?

    var body: some View {
        Section {
            Toggle("Let devices browse approved folders", isOn: $enabled)
                .onChange(of: enabled) { _ in RemoteFilesPolicy.bumpEpoch() }
            if enabled {
                ForEach(roots) { root in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: root.path))
                            .resizable().frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(root.name)
                            Text(root.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Remove") { remove(root) }
                    }
                }
                if roots.isEmpty {
                    Text("No folders yet. Devices see nothing until you add one.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Add Folder…") { addFolders() }
                    if let refused {
                        Text(refused).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Files")
        } footer: {
            Text("A connected device can look through these folders on its own screen: names, sizes and previews, read-only. Each session asks you first. Hidden files and your Library folder never show. Opening a file on this Mac also needs control.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Approve")
        panel.message = String(localized: "Choose folders connected devices may browse.")
        guard panel.runModal() == .OK else { return }
        refused = nil
        for url in panel.urls {
            let canonical = RemoteFilesPolicy.canonical(url)
            guard RemoteFilesPolicy.isAllowedRoot(canonical) else {
                refused = String(localized: "\(canonical.lastPathComponent) can't be shared: only folders in your home folder (not Library) or on external drives.")
                continue
            }
            guard !roots.contains(where: { $0.path == canonical.path }) else { continue }
            roots.append(RemoteFileRoot(id: UUID().uuidString, path: canonical.path))
        }
        RemoteFileRoot.save(roots)
    }

    private func remove(_ root: RemoteFileRoot) {
        roots.removeAll { $0.id == root.id }
        RemoteFileRoot.save(roots)
    }
}
