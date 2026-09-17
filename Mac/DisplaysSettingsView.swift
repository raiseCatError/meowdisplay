import SwiftUI

/// Displays answers: WHAT DISPLAY / PIXELS SHOULD MEOW PRODUCE OR CAPTURE?
/// Resolution/scaling configuration belongs here — transmission quality
/// (bitrate, frame rate) belongs to Streaming instead.
struct DisplaysSettingsView: View {
    @ObservedObject var controller: SenderController

    var body: some View {
        Form {
            Section("Display Mode") {
                Picker("Mode", selection: Binding(
                    get: { controller.mode },
                    set: { controller.requestMode($0) })) {
                    Text("Extend").tag(CaptureMode.extend)
                        .disabled(!controller.videoEnabled)
                    Text("Mirror").tag(CaptureMode.mirror)
                }
                .pickerStyle(.segmented)
            }

            if controller.mode == .mirror {
                Section("Mirror") {
                    MirrorDisplayPickerView(controller: controller)
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
