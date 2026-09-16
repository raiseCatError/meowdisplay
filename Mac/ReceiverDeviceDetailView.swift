import SwiftUI

/// One known/connected receiver's own settings — "Devices → iPhone → device
/// settings" from the milestone spec. Global Mac-wide settings stay on the
/// top-level pages (Streaming/Input/etc.); this page is everything that is
/// specific to THIS peer, keyed by its stable peerID, never by session/name/
/// address. Only ever shows live values reported by the connected receiver
/// (`DeviceSession.receiver*` — see `PhoneInfo`/`StreamReceiver.
/// announceReceiverPreferences`) or the Mac-local, peer-keyed input
/// authorization record; it never fabricates a value for a disconnected
/// device, and offline editing is deliberately NOT offered for the
/// receiver-reported fields below — there is no persisted per-device cache
/// of them, only the connected receiver's own store, so an edit while
/// offline would silently do nothing.
struct ReceiverDeviceDetailView: View {
    @ObservedObject var controller: SenderController
    let peerID: String
    let name: String

    private var session: DeviceSession? {
        controller.sessions.first { $0.deviceID == peerID && $0.applicationAuthenticated }
    }

    private var entry: SenderController.ActiveDisplayEntry? {
        controller.activeDisplayEntries.first { $0.peerID == peerID }
    }

    var body: some View {
        Form {
            Section("Overview") {
                if let entry {
                    LabeledContent("Status", value: CanonicalRuntimeStatus.entryStatusText(
                        mode: entry.mode, route: entry.route, phase: entry.phase))
                } else {
                    LabeledContent("Status", value: "Paired · Offline")
                }
            }

            if let session, session.receiverPreferencesReported {
                receiverControlsSection(session)
                audioSyncSection(session, entry: entry)
                functionTraySection(session)
            } else {
                Section {
                    Text("No compatible device connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Allow this device to enable input from the receiver", isOn: Binding(
                    get: { controller.isInputAuthorized(peerID: peerID) },
                    set: { controller.setInputAuthorized($0, peerID: peerID) }))
            } header: {
                Text("Input Authorization")
            } footer: {
                Text("Never bypasses this Mac's Allow Input master switch on the Input page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Forget Device…", role: .destructive) {
                    controller.requestForget(peerID: peerID, name: name)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(name)
    }

    @ViewBuilder
    private func receiverControlsSection(_ session: DeviceSession) -> some View {
        Section("Receiver Controls") {
            Picker("Input Mode", selection: Binding(
                get: { session.receiverInputMode },
                set: { value in
                    session.receiverInputMode = value
                    session.sender.setReceiverControlOverrides(inputMode: value)
                })) {
                Text("Direct").tag("direct")
                Text("Trackpad").tag("trackpad")
            }
            .pickerStyle(.segmented)

            if session.receiverInputMode == "trackpad" {
                VStack(alignment: .leading) {
                    Slider(value: Binding(
                        get: { session.receiverTrackpadSensitivity },
                        set: { value in
                            session.receiverTrackpadSensitivity = value
                            session.sender.setReceiverControlOverrides(trackpadSensitivity: value)
                        }), in: 0.5...2.0)
                    Text("Sensitivity: \(session.receiverTrackpadSensitivity, specifier: "%.1f")×")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Haptics", isOn: Binding(
                get: { session.receiverHapticsEnabled },
                set: { value in
                    session.receiverHapticsEnabled = value
                    session.sender.setReceiverControlOverrides(hapticsEnabled: value)
                }))

            Toggle("Avoid Notch", isOn: Binding(
                get: { session.receiverAvoidNotch },
                set: { value in
                    session.receiverAvoidNotch = value
                    session.sender.setReceiverControlOverrides(avoidNotch: value)
                }))

            Picker("Pinch Gesture", selection: Binding(
                get: { session.receiverPinchTarget },
                set: { value in
                    session.receiverPinchTarget = value
                    session.sender.setReceiverControlOverrides(pinchTarget: value)
                })) {
                Text("Viewport").tag("viewport")
                Text("App").tag("app")
            }
            Picker("Rotate Gesture", selection: Binding(
                get: { session.receiverRotateTarget },
                set: { value in
                    session.receiverRotateTarget = value
                    session.sender.setReceiverControlOverrides(rotateTarget: value)
                })) {
                Text("Viewport").tag("viewport")
                Text("App").tag("app")
            }
            Toggle("Snap Rotation", isOn: Binding(
                get: { session.receiverSnapRotation },
                set: { value in
                    session.receiverSnapRotation = value
                    session.sender.setReceiverControlOverrides(snapRotation: value)
                }))
        }
    }

    @ViewBuilder
    private func audioSyncSection(_ session: DeviceSession, entry: SenderController.ActiveDisplayEntry?) -> some View {
        Section("Audio & Sync") {
            LabeledContent("Audio", value: (entry?.audioActive ?? false) ? "On" : "Off")
            LabeledContent("A/V Sync", value: "\(session.receiverAVSyncOffsetMs >= 0 ? "+" : "")\(session.receiverAVSyncOffsetMs) ms")
            Text("A/V Sync is set on the receiver — this Mac can only display it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func functionTraySection(_ session: DeviceSession) -> some View {
        Section("Function Tray") {
            Toggle("Function Tray", isOn: Binding(
                get: { session.receiverFunctionTrayEnabled },
                set: { value in
                    session.receiverFunctionTrayEnabled = value
                    session.sender.setReceiverControlOverrides(functionTrayEnabled: value)
                }))
            Toggle("Keyboard Button", isOn: Binding(
                get: { session.receiverKeyboardButtonEnabled },
                set: { value in
                    session.receiverKeyboardButtonEnabled = value
                    session.sender.setReceiverUIPreferences(
                        trayEnabled: session.receiverTrayEnabled, keyboardButtonEnabled: value)
                }))
            Toggle("Control Tray", isOn: Binding(
                get: { session.receiverTrayEnabled },
                set: { value in
                    session.receiverTrayEnabled = value
                    session.sender.setReceiverUIPreferences(
                        trayEnabled: value, keyboardButtonEnabled: session.receiverKeyboardButtonEnabled)
                }))
            Text("Tray item layout is configured on the device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
