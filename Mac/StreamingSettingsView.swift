import SwiftUI

/// Streaming answers: HOW SHOULD MEOW TRANSMIT THE DISPLAY/AUDIO? Video
/// bitrate configuration lives here (see the ownership rule in the settings
/// taxonomy — Displays owns geometry, Streaming owns transmission).
struct StreamingSettingsView: View {
    @ObservedObject var controller: SenderController

    var body: some View {
        Form {
            Section("Video") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Video Streaming", isOn: Binding(
                        get: { controller.videoEnabled },
                        set: { controller.requestVideoEnabled($0) }))
                    Text("Stop screen capture and streaming while keeping connected-device controls active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Streaming Profile", selection: $controller.streamingProfile) {
                        ForEach(StreamingProfile.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .onChange(of: controller.streamingProfile) { controller.restartAll() }
                    Text(controller.streamingProfile.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if controller.streamingProfile == .custom {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Frame Rate", selection: $controller.customFrameRate) {
                            ForEach(CustomFrameRateSelection.allCases) { r in
                                Text(r.label).tag(r)
                            }
                        }
                        .onChange(of: controller.customFrameRate) { controller.restartAll() }
                        Text("Clamped to the connected device's actual maximum refresh rate. "
                            + "Auto uses the same ceiling as Performance.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Quality", selection: $controller.quality) {
                        ForEach(StreamQuality.allCases, id: \.self) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    .onChange(of: controller.quality) { controller.restartAll() }
                    Text(controller.quality.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Video Bitrate", value: "\(controller.quality.bitrate / 1_000_000) Mbps")
            }

            Section("Audio") {
                let anyAudioActive = controller.activeDisplayEntries.contains { $0.audioActive }
                LabeledContent("Audio Streaming", value: anyAudioActive ? "Streaming" : "Off")
                Text("Audio streaming is started by the connected device — there is no Mac-side enable toggle.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !controller.activeDisplayEntries.isEmpty {
                Section("Current Stream") {
                    ForEach(controller.activeDisplayEntries) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.subheadline.bold())
                            if entry.videoWidth > 0, entry.videoHeight > 0 {
                                // "Stream", not "Video": in Extend mode this can be
                                // smaller than the desktop's own resolution (Quality
                                // below 100%, or the receiver's decode ceiling) —
                                // the virtual display itself always stays native.
                                LabeledContent("Stream Resolution", value: "\(entry.videoWidth) × \(entry.videoHeight)")
                            }
                            if entry.videoFPS > 0 {
                                LabeledContent("Frame Rate", value: "\(entry.videoFPS) fps")
                            }
                            LabeledContent("Bitrate", value: "\(entry.bitrateBps / 1_000_000) Mbps")
                            LabeledContent("Audio", value: entry.audioActive ? "On" : "Off")
                            // Receiver-owned playback timing — see
                            // `ReceiverDeviceDetailView`'s Audio & Sync
                            // section for the same value; shown here too
                            // since Streaming is where the rest of this
                            // device's stream health already lives.
                            if let session = controller.session(for: entry.id), session.receiverPreferencesReported {
                                LabeledContent("A/V Sync",
                                    value: "\(session.receiverAVSyncOffsetMs >= 0 ? "+" : "")\(session.receiverAVSyncOffsetMs) ms")
                            }
                            LabeledContent("Route", value: entry.route?.rawValue ?? "—")
                            // Pause/Resume here means exactly what the label
                            // says: MacSender.pauseDisplay() stops capture
                            // (video + audio) while the connection stays up
                            // — never a connection-level action, which is
                            // why only this toggle (not Reconnect/Disconnect)
                            // belongs on the Streaming page.
                            if let session = controller.session(for: entry.id), session.canPauseOrResume {
                                Button(session.isPaused ? "Resume" : "Pause") {
                                    if session.isPaused {
                                        session.sender.resumeDisplay()
                                    } else {
                                        session.sender.pauseDisplay()
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
