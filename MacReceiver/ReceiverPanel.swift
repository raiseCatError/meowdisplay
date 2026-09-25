import SwiftUI

// MARK: - Receiver panel (issues #82/#17)
//
// Mac Receiver has far less configuration than Mac Sender, so it keeps its
// existing single grouped-Form panel rather than a sidebar — the taxonomy
// still applies (same section names/ownership as Mac Sender/iOS where the
// concept is shared), just without the page-per-category chrome that would
// be clutter here. This target's macOS 12 floor also rules out
// NavigationSplitView (macOS 13+).

/// The receiver-mode sections of the panel: live status, display identity,
/// system/app behavior, and how-to copy. Lives inside the shared grouped Form.
struct ReceiverSections: View {
    @ObservedObject var controller: ReceiverController

    var body: some View {
        // The receiver exists only while receiver mode is on; observed in a
        // subview because nested ObservableObjects don't republish.
        if let receiver = controller.receiver {
            ReceiverStatusSection(receiver: receiver, controller: controller)
        }

        Section {
            Image("MeowBrand")
                .resizable().scaledToFit().frame(width: 72)
            ReceiverNameField { controller.setAdvertisedName($0) }
        } header: {
            Text("Display")
        } footer: {
            Text("How this Mac appears in the other Mac's Devices list.")
        }

        WindowSection()

        SystemSection()

        Section("How to connect") {
            Label("Install and open MeowDisplay on the Mac whose screen you want to extend.",
                  systemImage: "macbook.and.macbook")
            Label("With both Macs on the same network, this Mac appears in its Devices list — click Connect there.",
                  systemImage: "wifi")
            Label("The stream opens here in full screen. The green traffic light switches to a window, and MeowDisplay remembers your choice.",
                  systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .font(.subheadline)

        #if DEBUG
        DeveloperSection(controller: controller)
        #endif
    }
}

/// Live state of the running receiver: connection, stream format, and any
/// compatibility signal from the connected Mac. Status text/color come from
/// `controller.statusTitle`/`statusColor` — the same canonical projection
/// the bottom status strip reads, so the two can never disagree.
private struct ReceiverStatusSection: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var controller: ReceiverController

    var body: some View {
        Section("Connection") {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(controller.statusColor)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.statusTitle)
                    Text(receiver.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.streaming {
                    Button("Show Window") { controller.showWindow() }
                        .controlSize(.small)
                        .help("Bring the video window back if you closed it — the stream keeps running either way.")
                }
            }
            if receiver.videoSize != .zero {
                // Not LabeledContent: that is macOS 13, the app runs on 12.
                HStack {
                    Text("Stream")
                    Spacer()
                    Text("\(Int(receiver.videoSize.width))×\(Int(receiver.videoSize.height)) @ \(receiver.fps) fps")
                        .foregroundColor(.secondary)
                }
            }
            if let message = peerMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            let controls = ReceiverConnectionControls(session: receiver.session,
                                                      connected: receiver.connected)
            if controls.canReconnect {
                Button("Reconnect") { receiver.reconnectNow() }
                    .help("Re-arm this Mac's listener and wait for the other Mac to reconnect.")
            }
            if controls.canDisconnect {
                Button("Disconnect") { receiver.disconnect() }
                    .help("End this session. Pairing is kept — connect again from the other Mac.")
            }
            Toggle("Auto-Reconnect", isOn: $receiver.autoReconnectEnabled)
            Text("Automatically reconnect to paired devices after connection interruptions. This Mac keeps listening for a connection either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        ReceiverDisplaySection(receiver: receiver)
        ReceiverStreamingSection(receiver: receiver)
        ReceiverAudioSection(receiver: receiver, controller: controller)

        Section {
            Text("This Mac only displays the stream. Its keyboard and trackpad are not sent to the other Mac, so there is no input permission to request.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Input")
        }
    }

    /// Compatibility copy from the sender (issue #132) — surfaced inline;
    /// the Mac app has Sparkle, so there is no blocking gate like on iOS.
    private var peerMessage: String? {
        switch receiver.peerSignal {
        case let .updateReceiver(message, _): return message
        case let .updateMac(message): return message
        case nil: return nil
        }
    }
}

/// Video on/off and Mirror/Extend. Every value shown is the sender's
/// confirmed state; a request only shows as "Switching…" until it answers.
private struct ReceiverDisplaySection: View {
    @ObservedObject var receiver: StreamReceiver

    var body: some View {
        Section("Display") {
            Toggle("Video", isOn: Binding(
                get: { receiver.videoEnabled },
                set: { receiver.requestVideoEnabled($0) }))
                .disabled(!receiver.connected || !receiver.macSupportsVideoControl)
            if let state = DisplayModePickerState(
                confirmed: receiver.confirmedDisplayMode, pending: receiver.pendingDisplayMode,
                connected: receiver.connected, macProtocolVersion: receiver.macProtocolVersion,
                videoEnabled: receiver.videoEnabled) {
                Picker("Display Mode", selection: Binding(
                    get: { state.selection },
                    set: { receiver.requestDisplayMode($0) })) {
                    ForEach(ReceiverDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                            .disabled(state.extendDisabled && mode == .extend)
                    }
                }
                .disabled(!state.isEnabled)
                if state.isSwitching {
                    Text("Switching to \(state.selection.title)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                HStack {
                    Text("Display Mode")
                    Spacer()
                    Text(receiver.connected ? "Waiting for Mac" : "Unavailable")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// The controls the sender lets a receiver request, plus what it actually
/// runs. The high-level Automatic/Custom switch and the codec preference are
/// sender-owned settings with no receiver request on the wire, so the codec
/// is shown read-only here.
private struct ReceiverStreamingSection: View {
    @ObservedObject var receiver: StreamReceiver

    var body: some View {
        Section {
            Picker("Streaming Profile", selection: Binding(
                get: { receiver.streamingProfile },
                set: { receiver.requestStreamingProfile($0, customFrameRate: receiver.customFrameRate) })) {
                ForEach(StreamingProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }
            Text(receiver.streamingProfile.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            if receiver.streamingProfile == .custom {
                Picker("Frame Rate", selection: Binding(
                    get: { receiver.customFrameRate },
                    set: { receiver.requestStreamingProfile(.custom, customFrameRate: $0) })) {
                    ForEach(CustomFrameRateSelection.allCases) { frameRate in
                        Text(frameRate.label).tag(frameRate)
                    }
                }
            }
            Picker("Streaming Priority", selection: Binding(
                get: { receiver.streamingPriority },
                set: { receiver.requestStreamingPriority($0) })) {
                ForEach(StreamingPriority.allCases) { priority in
                    Text(priority.label).tag(priority)
                }
            }
            Text(receiver.streamingPriority.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            maxFPSControls
            HStack {
                Text("Codec")
                Spacer()
                Text(receiver.connected
                     ? ReceiverStreamingPresentation.codecLabel(receiver.activeStreamCodec)
                     : "—")
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Streaming")
        } footer: {
            Text("The other Mac decides what is actually applied and reports it back. Automatic/Custom mode and the codec choice (Auto, H.264, HEVC) are set in MeowDisplay on that Mac.")
        }
    }

    @ViewBuilder
    private var maxFPSControls: some View {
        if receiver.macProtocolVersion >= WireProtocol.maxFPSWireVersion {
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
                        ForEach(tiers, id: \.self) { fps in Text("\(fps)").tag(fps) }
                    }
                    .disabled(locked)
                }
                if receiver.pendingMaxFPS != nil {
                    Text("Updating Maximum FPS…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let text = ReceiverStreamingPresentation.fpsLimitation(
                    state: receiver.lastMaxFPSState, profileLabel: receiver.streamingProfile.label) {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text("Maximum FPS")
                    Spacer()
                    Text(receiver.connected ? "Waiting for Mac" : "Unavailable")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

private struct ReceiverAudioSection: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var controller: ReceiverController
    @AppStorage(ReceiverController.audioPreferredKey) private var audioPreferred = false

    var body: some View {
        Section {
            Toggle("Audio", isOn: Binding(
                get: { audioPreferred },
                set: { audioPreferred = $0; controller.setAudioPreferred($0) }))
                .disabled(!receiver.connected || !receiver.macSupportsAudio)
        } header: {
            Text("Audio")
        } footer: {
            Text("Plays a copy of what the other Mac is playing. It keeps playing there too.")
        }
    }
}

/// Receiver window behavior. The green button writes the same preference,
/// so the toggle always shows what the next window will do.
private struct WindowSection: View {
    @AppStorage(FullscreenPreference.key) private var openInFullScreen = true

    var body: some View {
        Section {
            Toggle("Open in Full Screen", isOn: $openInFullScreen)
        } header: {
            Text("Window")
        } footer: {
            Text("Automatically open the receiver window in native macOS full screen when a stream starts.")
        }
    }
}

/// The macOS application itself — matches Mac Sender's System category.
private struct SystemSection: View {
    @AppStorage("showAnalytics") private var showAnalytics = false

    var body: some View {
        Section {
            Toggle("Performance overlay", isOn: $showAnalytics)
        } header: {
            Text("System")
        } footer: {
            Text("FPS, bitrate, frame timing, and latency graphs at the bottom of the video window while streaming — the same HUD the iPhone app has.")
        }
    }
}

#if DEBUG
/// DEBUG only — matches Mac Sender's Developer category naming/scope.
private struct DeveloperSection: View {
    @ObservedObject var controller: ReceiverController

    var body: some View {
        Section {
            DisclosureGroup("Wake Testing") {
                WakeTestingView()
            }
            if let receiver = controller.receiver {
                DisclosureGroup("Promote Interactive Wake") {
                    PromoteInteractiveWakeView(receiver: receiver)
                }
            }
        } header: {
            Text("Developer")
        } footer: {
            Text("Wake Testing sends a standard Wake-on-LAN magic packet to an already-paired Mac's last-learned local network address (same-LAN only). Promote Interactive Wake asks the connected Mac to declare remote user activity, to test whether that promotes a dark/network wake into a full interactive wake.")
        }
    }
}
#endif

/// The advertised-name editor — kept out of any high-frequency observed
/// object so streaming updates can't rebuild it mid-edit (same reasoning as
/// the iOS DeviceNameField).
private struct ReceiverNameField: View {
    @AppStorage("receiverName") private var name = Host.current().localizedName ?? "Mac"
    let onChange: (String) -> Void

    var body: some View {
        TextField("Name", text: $name)
            // The single-value onChange: the two-value form is macOS 14.
            .onChange(of: name, perform: onChange)
    }
}
