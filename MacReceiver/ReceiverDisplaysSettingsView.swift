import SwiftUI

/// Displays: what the other Mac shows on this one. Every value is the
/// sender's CONFIRMED state; a request only shows as switching/updating
/// until the sender answers — the same request/confirm contract (and the
/// same shared `StreamReceiver` requests) as the iPhone app. Also the
/// receiver-local video window behavior.
struct ReceiverDisplaysSettingsView: View {
    @ObservedObject var controller: ReceiverController

    var body: some View {
        WithReceiver(controller) { receiver in
            ReceiverDisplaysPage(receiver: receiver, controller: controller)
        }
    }
}

private struct ReceiverDisplaysPage: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var controller: ReceiverController
    @AppStorage(FullscreenPreference.key) private var openInFullScreen = true

    var body: some View {
        ReceiverSettingsForm {
            Section("Video") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Video", isOn: Binding(
                        get: { receiver.videoEnabled },
                        set: { receiver.requestVideoEnabled($0) }))
                        .disabled(!receiver.connected || !receiver.macSupportsVideoControl)
                    ReceiverCaption("Turning video off asks the other Mac to stop streaming its screen while staying connected.")
                }
            }

            displayModeSection

            if receiver.confirmedDisplayMode == .mirror,
               receiver.macProtocolVersion >= WireProtocol.mirrorDisplayWireVersion {
                Section {
                    mirrorDisplaySource
                } header: {
                    Text("Mirror")
                } footer: {
                    ReceiverCaption("Which of the other Mac's screens is mirrored here. Auto follows that Mac's own choice.")
                }
            }

            if receiver.confirmedDisplayMode == .extend,
               receiver.macProtocolVersion >= WireProtocol.extendShapeWireVersion {
                Section {
                    extendShape
                } header: {
                    Text("Extend Shape")
                } footer: {
                    ReceiverCaption("The shape of the extra display the other Mac creates for this one.")
                }
            }

            Section {
                Toggle("Open in Full Screen", isOn: $openInFullScreen)
                if controller.streaming {
                    HStack {
                        Text("Video Window")
                        Spacer()
                        Button("Show Window") { controller.showWindow() }
                            .controlSize(.small)
                            .help("Bring the video window back if you closed it — the stream keeps running either way.")
                    }
                }
            } header: {
                Text("Window")
            } footer: {
                // The green button writes the same preference, so the toggle
                // always shows what the next window will do.
                ReceiverCaption("Automatically open the receiver window in native macOS full screen when a stream starts. Using the window's green button also updates this.")
            }
        }
    }

    @ViewBuilder
    private var displayModeSection: some View {
        Section {
            if let state = DisplayModePickerState(
                confirmed: receiver.confirmedDisplayMode, pending: receiver.pendingDisplayMode,
                connected: receiver.connected, macProtocolVersion: receiver.macProtocolVersion,
                videoEnabled: receiver.videoEnabled) {
                Picker("Mode", selection: Binding(
                    get: { state.selection },
                    set: { receiver.requestDisplayMode($0) })) {
                    ForEach(ReceiverDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                            .disabled(state.extendDisabled && mode == .extend)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!state.isEnabled)
                if state.isSwitching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        ReceiverCaption("Switching to \(state.selection.title)…")
                    }
                }
                if receiver.mirrorRejectedWhileExtending {
                    HStack {
                        Label("Mirror needs an active physical display on the other Mac. It stays on Extend.",
                              systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss") { receiver.dismissMirrorRejection() }
                            .controlSize(.small)
                    }
                }
            } else {
                ReceiverValueRow("Mode", value: receiver.connected
                                 ? String(localized: "Waiting for Mac") : String(localized: "Unavailable"))
            }
        } header: {
            Text("Display Mode")
        } footer: {
            ReceiverCaption("Extend adds this Mac as a separate display; Mirror shows a copy of the other Mac's screen. The other Mac confirms every change.")
        }
    }

    /// Remote control of the sender's own Mirror capture source — never a
    /// receiver-side preference. `nil` selection means Auto, exactly the
    /// sender's semantic (same as the iPhone app's picker).
    @ViewBuilder
    private var mirrorDisplaySource: some View {
        let state = receiver.mirrorDisplayState
        Picker("Mirror Display", selection: Binding(
            get: { state?.selectedUUID == nil ? "auto" : "manual" },
            set: { newValue in
                if newValue == "auto" {
                    receiver.requestMirrorDisplaySelection(nil)
                } else if let uuid = state?.selectedUUID ?? state?.displays.first?.uuid {
                    receiver.requestMirrorDisplaySelection(uuid)
                }
            })) {
            Text("Auto").tag("auto")
            Text("Manual").tag("manual")
        }
        .pickerStyle(.segmented)
        .disabled(!receiver.connected || state == nil)
        if state == nil {
            ReceiverCaption(receiver.connected ? "Waiting for Mac" : "Unavailable")
        }
        if let state, state.selectedUUID != nil {
            if state.displays.isEmpty {
                ReceiverCaption("No displays reported.")
            } else {
                ForEach(state.displays, id: \.uuid) { display in
                    Button {
                        receiver.requestMirrorDisplaySelection(display.uuid)
                    } label: {
                        HStack {
                            Text(display.isMain ? String(localized: "\(display.name) (Main)", comment: "A display name, marked as the Mac's main display.") : display.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if state.selectedUUID == display.uuid {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!receiver.connected)
                }
                if let selected = state.selectedUUID, !state.displays.contains(where: { $0.uuid == selected }) {
                    Label("Selected display unavailable", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// Requests an Extend shape change; the shown value always tracks the
    /// sender's `confirmedExtendShape`/`pendingExtendShape`.
    @ViewBuilder
    private var extendShape: some View {
        if let confirmed = receiver.confirmedExtendShape {
            let current = receiver.pendingExtendShape ?? confirmed
            let locked = !receiver.connected || receiver.pendingExtendShape != nil
            Picker("Shape", selection: Binding(
                get: { current.shape },
                set: { shape in
                    var preference = current
                    preference.shape = shape
                    receiver.requestExtendShape(preference)
                })) {
                ForEach(ExtendDisplayShape.allCases) { shape in
                    Text(shape.title).tag(shape)
                }
            }
            .disabled(locked)
            if current.shape == .automatic {
                Toggle("Use Full Display", isOn: Binding(
                    get: { current.useFullDisplay },
                    set: { value in
                        var preference = current
                        preference.useFullDisplay = value
                        receiver.requestExtendShape(preference)
                    }))
                    .disabled(locked)
            }
            if receiver.pendingExtendShape != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    ReceiverCaption("Updating Extend shape…")
                }
            }
            if let text = ReceiverStreamingPresentation.fpsLimitation(
                state: receiver.lastMaxFPSState, profileLabel: receiver.streamingProfile.label) {
                ReceiverCaption(verbatim: text)
            }
        } else {
            ReceiverValueRow("Shape", value: receiver.connected
                             ? String(localized: "Waiting for Mac") : String(localized: "Unavailable"))
        }
    }
}
