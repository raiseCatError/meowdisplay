import SwiftUI

/// Streaming: how the other Mac transmits to this one. Profile, frame rate,
/// priority and maximum FPS are REQUESTS the sender confirms (the same
/// shared `StreamReceiver` requests as the iPhone app); the codec and the
/// sender's Automatic/Custom mode are sender-owned and only shown. Audio
/// lives here too, matching Mac Sender's Streaming taxonomy.
struct ReceiverStreamingSettingsView: View {
    @ObservedObject var controller: ReceiverController

    var body: some View {
        WithReceiver(controller) { receiver in
            ReceiverStreamingPage(receiver: receiver, controller: controller)
        }
    }
}

private struct ReceiverStreamingPage: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var controller: ReceiverController
    @AppStorage(ReceiverController.audioPreferredKey) private var audioPreferred = false

    var body: some View {
        ReceiverSettingsForm {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Streaming Profile", selection: Binding(
                        get: { receiver.streamingProfile },
                        set: { receiver.requestStreamingProfile($0, customFrameRate: receiver.customFrameRate) })) {
                        ForEach(StreamingProfile.allCases) { profile in
                            Text(profile.label).tag(profile)
                        }
                    }
                    ReceiverCaption(verbatim: receiver.streamingProfile.explanation)
                }
                if receiver.streamingProfile == .custom {
                    Picker("Frame Rate", selection: Binding(
                        get: { receiver.customFrameRate },
                        set: { receiver.requestStreamingProfile(.custom, customFrameRate: $0) })) {
                        ForEach(CustomFrameRateSelection.allCases) { frameRate in
                            Text(frameRate.label).tag(frameRate)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Streaming Priority", selection: Binding(
                        get: { receiver.streamingPriority },
                        set: { receiver.requestStreamingPriority($0) })) {
                        ForEach(StreamingPriority.allCases) { priority in
                            Text(priority.label).tag(priority)
                        }
                    }
                    ReceiverCaption(verbatim: receiver.streamingPriority.explanation)
                }
                ReceiverValueRow("Codec", value: receiver.connected
                                 ? ReceiverStreamingPresentation.codecLabel(receiver.activeStreamCodec) : "—")
            } header: {
                Text("Video")
            } footer: {
                ReceiverCaption("The other Mac decides what is actually applied and reports it back. Automatic/Custom mode and the codec choice (Auto, H.264, HEVC) are set in MeowDisplay on that Mac.")
            }

            if receiver.macProtocolVersion >= WireProtocol.maxFPSWireVersion {
                Section {
                    maxFPSControls
                } header: {
                    Text("Maximum FPS")
                } footer: {
                    ReceiverCaption("Caps how fast the other Mac streams to this one, on top of its normal profile and display limits.")
                }
            }

            audioSection

            if receiver.connected, receiver.videoSize != .zero {
                Section("Current Stream") {
                    ReceiverValueRow("Stream Resolution",
                                     value: "\(Int(receiver.videoSize.width)) × \(Int(receiver.videoSize.height))")
                    ReceiverValueRow("Frame Rate", value: "\(receiver.fps) fps")
                }
            }
        }
    }

    @ViewBuilder
    private var maxFPSControls: some View {
        if let confirmed = receiver.confirmedMaxFPS {
            let current = receiver.pendingMaxFPS ?? confirmed
            let locked = !receiver.connected || receiver.pendingMaxFPS != nil
            Toggle("Enforce Maximum FPS", isOn: Binding(
                get: { current.enabled },
                set: { enabled in
                    var preference = current
                    preference.enabled = enabled
                    receiver.requestMaxFPS(preference)
                }))
                .disabled(locked)
            if current.enabled {
                let tiers = receiver.lastMaxFPSState?.availableTiers ?? EncoderCapability.supportedFPSTiers
                Picker("Maximum FPS", selection: Binding(
                    get: { current.maxFPS },
                    set: { fps in
                        var preference = current
                        preference.maxFPS = fps
                        receiver.requestMaxFPS(preference)
                    })) {
                    ForEach(tiers, id: \.self) { fps in Text(verbatim: "\(fps)").tag(fps) }
                }
                .disabled(locked)
            }
            if receiver.pendingMaxFPS != nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    ReceiverCaption("Updating Maximum FPS…")
                }
            }
            if let text = ReceiverStreamingPresentation.fpsLimitation(
                state: receiver.lastMaxFPSState, profileLabel: receiver.streamingProfile.label) {
                ReceiverCaption(verbatim: text)
            }
        } else {
            ReceiverValueRow("Maximum FPS", value: receiver.connected
                             ? String(localized: "Waiting for Mac") : String(localized: "Unavailable"))
        }
    }

    /// The receiver's own audio opt-in, plus the receiver-local A/V Sync
    /// offset and Resync — the same controls, range and step
    /// (`AVSyncOffset`) as the iPhone app.
    @ViewBuilder
    private var audioSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Audio", isOn: Binding(
                    get: { audioPreferred },
                    set: { audioPreferred = $0; controller.setAudioPreferred($0) }))
                    .disabled(!receiver.connected || !receiver.macSupportsAudio)
                ReceiverCaption("Plays a copy of what the other Mac is playing. It keeps playing there too — this never changes that Mac's output device.")
                if receiver.connected && !receiver.macSupportsAudio {
                    ReceiverCaption("The other Mac's version of MeowDisplay doesn't support audio.")
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("A/V Sync")
                    Spacer()
                    Text(verbatim: Self.avSyncLabel(controller.avSyncOffsetMs))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if controller.avSyncOffsetMs != 0 {
                        Button("Reset") { controller.setAVSyncOffset(0) }
                            .controlSize(.small)
                    }
                }
                Slider(value: Binding(
                    get: { Double(controller.avSyncOffsetMs) },
                    set: { controller.setAVSyncOffset(Int($0)) }),
                       in: Double(AVSyncOffset.range.lowerBound)...Double(AVSyncOffset.range.upperBound),
                       step: Double(AVSyncOffset.stepMs))
                ReceiverCaption("Adjust if sound plays slightly before or after the picture.")
            }
            .disabled(!audioPreferred)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Button("Resync") { receiver.resync() }
                        .controlSize(.small)
                        .disabled(!receiver.connected || !receiver.audioEnabled)
                    Spacer()
                }
                ReceiverCaption("If audio drifts or stutters, Resync re-establishes timing without reconnecting. It doesn't change your A/V Sync adjustment above.")
            }
        } header: {
            Text("Audio")
        }
    }

    private static func avSyncLabel(_ milliseconds: Int) -> String {
        milliseconds > 0 ? "+\(milliseconds) ms" : "\(milliseconds) ms"
    }
}
