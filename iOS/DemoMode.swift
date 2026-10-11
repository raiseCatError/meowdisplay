import SwiftUI
import UIKit

// MARK: - Demo Mode
//
// Demo Mode shows the receiver with a sample Mac so MeowDisplay can be
// explored without one. The boundary: the real control overlay, Settings
// shell and local-only pages are reused, driven by a `DemoSession` (in place
// of `StreamReceiver`) and a `ReceiverControlStore` saved to its own defaults
// domain. Nothing here holds the real receiver's wire, trust or endpoints.

/// The demo's own control store: saved to a separate defaults domain that is
/// cleared on entry and exit, so the reviewer's changes never reach the real
/// receiver preferences.
@MainActor
enum DemoControlStoreFactory {
    static func make() -> ReceiverControlStore {
        let defaults = UserDefaults(suiteName: DemoSession.controlDefaultsSuite) ?? UserDefaults()
        defaults.removePersistentDomain(forName: DemoSession.controlDefaultsSuite)
        let store = ReceiverControlStore(repository: ReceiverControlPreferencesRepository(defaults: defaults))
        store.update { $0.audioPreferred = true }
        store.applySessionInputState(.allowed)
        return store
    }

    static func discard() {
        UserDefaults(suiteName: DemoSession.controlDefaultsSuite)?
            .removePersistentDomain(forName: DemoSession.controlDefaultsSuite)
    }
}

/// The sample stream size: this device's own screen in pixels, landscape.
@MainActor
func demoVideoSize() -> CGSize {
    let bounds = UIScreen.main.nativeBounds.size
    return CGSize(width: max(bounds.width, bounds.height), height: min(bounds.width, bounds.height))
}

// MARK: - Receiver surface

struct DemoReceiverScreen: View {
    @ObservedObject var demo: DemoSession
    @ObservedObject var store: ReceiverControlStore
    @Binding var showSettings: Bool
    @Binding var keyboardActive: Bool
    let haptics: ReceiverHaptics
    let onExit: () -> Void

    @State private var padCanvas: CGRect?
    @State private var keyboardRect: CGRect?
    @State private var tapPoint: CGPoint?
    @State private var tapGeneration = 0
    @State private var showInputOffHint = false
    @State private var feedbackVisible = false

    var body: some View {
        GeometryReader { geo in
            let insets = ControlSafeInsets(top: geo.safeAreaInsets.top, leading: geo.safeAreaInsets.leading,
                                           bottom: geo.safeAreaInsets.bottom, trailing: geo.safeAreaInsets.trailing)
            let canvas = canvas(in: geo.size)
            ZStack {
                Color.black.ignoresSafeArea()
                SampleDesktopView(mode: demo.displayMode, videoEnabled: demo.videoEnabled,
                                  showGrid: store.preferences.showSurfaceGrid)
                    .overlay { tapRipple }
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in surfaceTapped(at: location) }
                    .frame(width: canvas.width, height: canvas.height)
                    .clipped()
                    .position(x: canvas.midX, y: canvas.midY)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Sample Mac display"))
                    .accessibilityHint(Text("Demo content drawn on this device. Taps show locally and are not sent."))
                if demo.showPerformanceOverlay {
                    VStack {
                        Spacer()
                        PerfOverlay(stats: Self.sampleStats(demo), videoSize: demo.videoSize)
                            .padding(.bottom, 10)
                    }
                    .allowsHitTesting(false)
                }
                RemoteKeyboardInputView(
                    isActive: $keyboardActive,
                    onCommitText: { demo.noteTyped($0) },
                    onSpecialPress: { demo.sendKeyboardPress(usage: $0) },
                    onHardwareKeyDown: { usage, modifiers in demo.sendKeyboardPress(usage: usage, modifiers: modifiers) },
                    onHardwareKeyUp: { _, _ in },
                    onRequestDismiss: { keyboardActive = false })
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
                ReceiverControlOverlay(
                    store: store,
                    receiver: demo,
                    keyboardActive: $keyboardActive,
                    showSettings: $showSettings,
                    keyboardAvailable: demo.inputAllowed,
                    keyboardVisibleRect: keyboardRect,
                    containerSize: geo.size,
                    safeInsets: insets,
                    notchSide: nil,
                    reservedRegions: [],
                    haptics: haptics,
                    onOccupiedFramesChange: { _ in },
                    onCanvasChange: { padCanvas = $0 },
                    surfaceOrigin: canvas.origin)
                VStack(spacing: 8) {
                    DemoSessionBanner(demo: demo, onExit: onExit)
                    if feedbackVisible, let action = demo.lastAction {
                        DemoFeedbackChip(action: action)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if showInputOffHint && !demo.inputAllowed {
                        Button {
                            demo.setInputAllowed(true)
                        } label: {
                            Label("Input is off (Demo). Allow Input", systemImage: "hand.tap")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(Color(white: 0.16).opacity(0.94)))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                    Spacer()
                }
                .padding(.top, max(insets.top, 12))
                .padding(.horizontal, 16)
            }
        }
        .ignoresSafeArea(.keyboard)
        .onAppear { store.applySessionInputState(demo.inputState) }
        .onChange(of: demo.inputState) { state in
            store.applySessionInputState(state)
            if state != .allowed { keyboardActive = false }
            withAnimation { showInputOffHint = false }
        }
        .onChange(of: demo.actionGeneration) { generation in
            withAnimation(.easeOut(duration: 0.15)) { feedbackVisible = true }
            Task {
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                guard generation == demo.actionGeneration else { return }
                withAnimation(.easeIn(duration: 0.3)) { feedbackVisible = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let screen = UIScreen.main.bounds
            keyboardRect = frame.minY >= screen.maxY - 1 ? nil : frame
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardRect = nil
        }
    }

    private func canvas(in size: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: size)
        guard store.isPad, let padCanvas, padCanvas.width > 0, padCanvas.height > 0 else { return full }
        return padCanvas.intersection(full)
    }

    @ViewBuilder
    private var tapRipple: some View {
        if let tapPoint {
            Circle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 2)
                .background(Circle().fill(Color.white.opacity(0.25)))
                .frame(width: 44, height: 44)
                .position(tapPoint)
                .id(tapGeneration)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    private func surfaceTapped(at location: CGPoint) {
        guard demo.inputAllowed else {
            withAnimation { showInputOffHint = true }
            return
        }
        store.beginAutoHideActivity()
        store.scheduleAutoHide()
        withAnimation(.easeOut(duration: 0.15)) {
            tapPoint = location
            tapGeneration &+= 1
        }
        demo.noteAction(String(localized: "Click"))
        let generation = tapGeneration
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard generation == tapGeneration else { return }
            withAnimation(.easeIn(duration: 0.2)) { tapPoint = nil }
        }
    }

    static func sampleStats(_ demo: DemoSession) -> PerfStats {
        var stats = PerfStats()
        stats.fps = demo.fps
        stats.mbps = demo.throughputMbps
        stats.avgFrameMs = 16.7
        stats.maxFrameMs = 19.2
        stats.e2eP50 = Double(demo.latencyMs)
        stats.e2eP95 = Double(demo.latencyMs) + 6
        stats.rttMs = 4
        stats.transport = String(localized: "Sample")
        stats.samples = (0..<120).map { 16.7 + sin(Double($0) / 6) * 0.8 }
        stats.e2eSamples = (0..<120).map { Double(demo.latencyMs) + sin(Double($0) / 9) * 2 }
        stats.capFps = demo.fps
        return stats
    }
}

/// Always-visible Demo Mode identification, with Allow Input and Exit Demo.
struct DemoSessionBanner: View {
    @ObservedObject var demo: DemoSession
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            DemoBadge()
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: DemoSession.macName).font(.subheadline.weight(.semibold))
                Text("Sample session").font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .accessibilityElement(children: .combine)
            Divider().frame(height: 24).overlay(Color.white.opacity(0.3))
            Toggle(isOn: Binding(get: { demo.inputAllowed }, set: { demo.setInputAllowed($0) })) {
                Text("Input").font(.subheadline)
            }
            .toggleStyle(.button)
            .tint(.white)
            .accessibilityLabel(Text("Allow Input (Demo)"))
            .accessibilityValue(demo.inputAllowed ? Text("On") : Text("Off"))
            Button(action: onExit) {
                Text("Exit Demo").font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .accessibilityHint(Text("Returns to the home screen."))
        }
        .foregroundStyle(.white)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.8), lineWidth: 1))
        .fixedSize()
    }
}

/// The DEMO label. Text, not only color, so it reads in every mode.
struct DemoBadge: View {
    var body: some View {
        Text("DEMO")
            .font(.caption.weight(.heavy))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange))
            .foregroundStyle(.black)
            .accessibilityLabel(Text("Demo Mode"))
    }
}

private struct DemoFeedbackChip: View {
    let action: String

    var body: some View {
        Text("\(action) · Demo, not sent")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(white: 0.16).opacity(0.94)))
            .foregroundStyle(.white)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Sample desktop

/// A generic sample workspace drawn by MeowDisplay itself. It stands in for
/// the Mac's picture in Demo Mode; it is not a screenshot of any real app.
struct SampleDesktopView: View {
    let mode: ReceiverDisplayMode
    let videoEnabled: Bool
    let showGrid: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let unit = min(size.width, size.height) / 100
            ZStack(alignment: .topLeading) {
                if videoEnabled {
                    LinearGradient(colors: [Color(red: 0.24, green: 0.18, blue: 0.45),
                                            Color(red: 0.12, green: 0.36, blue: 0.52),
                                            Color(red: 0.20, green: 0.55, blue: 0.50)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: unit * 40))
                        .foregroundStyle(.white.opacity(0.06))
                        .position(x: size.width * 0.72, y: size.height * 0.62)
                    menuBar(unit: unit)
                    if mode == .mirror {
                        notesWindow(unit: unit)
                            .frame(width: size.width * 0.42, height: size.height * 0.5)
                            .position(x: size.width * 0.29, y: size.height * 0.36)
                        photosWindow(unit: unit)
                            .frame(width: size.width * 0.38, height: size.height * 0.42)
                            .position(x: size.width * 0.70, y: size.height * 0.52)
                    } else {
                        chartWindow(unit: unit)
                            .frame(width: size.width * 0.5, height: size.height * 0.5)
                            .position(x: size.width * 0.5, y: size.height * 0.44)
                    }
                    dock(unit: unit)
                        .position(x: size.width / 2, y: size.height - unit * 7)
                    if showGrid { grid(size: size) }
                } else {
                    Color.black
                    VStack(spacing: 10) {
                        Image(systemName: "video.slash").font(.largeTitle)
                        Text("Video is off (Demo)").font(.headline)
                        Text("Controls and input keep working.").font(.subheadline)
                    }
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: size.width, height: size.height)
                }
            }
        }
    }

    private func menuBar(unit: CGFloat) -> some View {
        HStack(spacing: unit * 3) {
            Image(systemName: "pawprint.fill")
            Text(verbatim: "Sample Workspace").fontWeight(.semibold)
            Spacer()
            Text(mode == .mirror ? "Mirror (Demo)" : "Extend (Demo)")
            Text(verbatim: "9:41")
        }
        .font(.system(size: unit * 2.2))
        .foregroundStyle(.white)
        .padding(.horizontal, unit * 2)
        .frame(height: unit * 4.4)
        .background(Color.black.opacity(0.28))
    }

    private func window<Content: View>(title: String, unit: CGFloat,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: unit * 0.9) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.85)).frame(width: unit * 1.6, height: unit * 1.6)
                }
                Spacer()
                Text(verbatim: title).font(.system(size: unit * 2, weight: .semibold))
                Spacer()
                Color.clear.frame(width: unit * 6)
            }
            .padding(.horizontal, unit * 1.4)
            .frame(height: unit * 4)
            .background(Color(white: 0.92))
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.white)
        }
        .foregroundStyle(Color(white: 0.15))
        .clipShape(RoundedRectangle(cornerRadius: unit * 1.4, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: unit * 2, y: unit * 0.8)
    }

    private func notesWindow(unit: CGFloat) -> some View {
        window(title: "Welcome.txt", unit: unit) {
            VStack(alignment: .leading, spacing: unit * 1.4) {
                Text("Welcome to the MeowDisplay demo").font(.system(size: unit * 2.8, weight: .bold))
                Text("This sample workspace is drawn on this device. With the Mac app, your Mac’s real screen appears here.")
                    .font(.system(size: unit * 2))
                ForEach(["Tap to click", "Drag to move", "Two fingers to scroll", "Use the trays for shortcuts"], id: \.self) { line in
                    Label(LocalizedStringKey(line), systemImage: "checkmark.circle")
                        .font(.system(size: unit * 2))
                }
            }
            .padding(unit * 2)
        }
    }

    private func photosWindow(unit: CGFloat) -> some View {
        window(title: "Gallery", unit: unit) {
            let colors: [[Color]] = [[.orange, .pink], [.teal, .blue], [.purple, .indigo],
                                     [.green, .mint], [.yellow, .orange], [.cyan, .purple]]
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: unit), count: 3), spacing: unit) {
                ForEach(colors.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: unit, style: .continuous)
                        .fill(LinearGradient(colors: colors[index], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .aspectRatio(1.3, contentMode: .fit)
                }
            }
            .padding(unit * 1.5)
        }
    }

    private func chartWindow(unit: CGFloat) -> some View {
        window(title: "Extended Display", unit: unit) {
            VStack(alignment: .leading, spacing: unit * 1.2) {
                Text("A second screen for your Mac").font(.system(size: unit * 2.8, weight: .bold))
                Text("In Extend, this device adds space beside your Mac’s own display. Move windows here to use both.")
                    .font(.system(size: unit * 2))
                HStack(alignment: .bottom, spacing: unit * 1.2) {
                    ForEach([0.45, 0.7, 0.55, 0.9, 0.65, 0.8, 0.5], id: \.self) { value in
                        RoundedRectangle(cornerRadius: unit * 0.5)
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(height: unit * 18 * value)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(unit * 2)
        }
    }

    private func dock(unit: CGFloat) -> some View {
        HStack(spacing: unit * 1.4) {
            ForEach(["doc.text", "photo", "chart.bar", "terminal", "music.note", "gearshape"], id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(.system(size: unit * 3))
                    .foregroundStyle(.white)
                    .frame(width: unit * 7, height: unit * 7)
                    .background(RoundedRectangle(cornerRadius: unit * 1.6, style: .continuous)
                        .fill(Color.white.opacity(0.18)))
            }
        }
        .padding(unit * 1.2)
        .background(RoundedRectangle(cornerRadius: unit * 2.4, style: .continuous).fill(Color.black.opacity(0.25)))
    }

    private func grid(size: CGSize) -> some View {
        Path { path in
            let step = min(size.width, size.height) / 8
            stride(from: step, to: size.width, by: step).forEach {
                path.move(to: CGPoint(x: $0, y: 0)); path.addLine(to: CGPoint(x: $0, y: size.height))
            }
            stride(from: step, to: size.height, by: step).forEach {
                path.move(to: CGPoint(x: 0, y: $0)); path.addLine(to: CGPoint(x: size.width, y: $0))
            }
        }
        .stroke(Color.white.opacity(0.25), lineWidth: 1)
    }
}

// MARK: - Home entry point

struct ExploreDemoCard: View {
    let onExplore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Explore MeowDisplay").font(.headline)
            Text("See how display, input, controls, audio and connections work using a sample Mac. The demo uses sample content and doesn’t connect to another device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: onExplore) {
                Label("Explore Demo", systemImage: "play.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("exploreDemo")
            .accessibilityHint(Text("Opens a sample session. Nothing connects to another device."))
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Settings

/// Shown along the bottom of Settings while Demo Mode is active.
struct DemoSettingsBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            DemoBadge()
            Text("Sample session with \(DemoSession.macName). No Mac is connected.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

/// Settings pages that need a real Mac, populated from the demo session.
/// Every value here is labeled Demo or Sample, and nothing is persisted.
struct DemoSettingsPage: View {
    let category: MobileSettingsCategory
    @ObservedObject var demo: DemoSession
    @ObservedObject var controlStore: ReceiverControlStore

    var body: some View {
        SettingsForm {
            switch category {
            case .general: general
            case .display: display
            case .audio: audio
            case .connections: connections
            case .pairedMacs: pairedMacs
            case .remoteAccess: remoteAccess
            case .permissions: permissions
            case .diagnostics: diagnostics
            default: EmptyView()
            }
        }
        .navigationTitle(category.title)
    }

    private func sample(_ value: String) -> String {
        String(localized: "\(value) (Sample)", comment: "A demo value, such as 60 fps (Sample).")
    }

    private var streamText: String {
        "\(Int(demo.videoSize.width))×\(Int(demo.videoSize.height)) @ \(demo.fps) fps"
    }

    // MARK: General

    @ViewBuilder
    private var general: some View {
        Section {
            TextField("Device name", text: $demo.deviceName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        } header: {
            Text("Name")
        } footer: {
            Text("Demo: changes here last only for this demo and don't rename this \(deviceKind).")
        }
        Section {
            Toggle("Auto-Reconnect", isOn: $demo.autoReconnect)
        } header: {
            Text("Connection")
        } footer: {
            Text("Automatically reconnect to paired devices after connection interruptions. In the demo this only changes the sample session.")
        }
        Section {
            Toggle("Haptics", isOn: preferenceBinding(controlStore, \.hapticsEnabled))
        }
    }

    // MARK: Display

    @ViewBuilder
    private var display: some View {
        Section {
            LabeledContent("Mac", value: DemoSession.macName)
            LabeledContent("Stream", value: sample(streamText))
            LabeledContent("Codec", value: sample(demo.codec == .hevc ? "HEVC" : "H.264"))
        } header: {
            Text("Sample Session")
        }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Video", isOn: Binding(get: { demo.videoEnabled }, set: { demo.setVideoEnabled($0) }))
                SettingNote("Turning video off keeps the connection, keyboard, controls, and selected input mode active.")
            }
            Picker("Display Mode", selection: $demo.displayMode) {
                ForEach(ReceiverDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            SettingNote("Demo: switching changes the sample display only. With a real Mac, the Mac switches between mirroring its screen and adding this device as a second display.")
            Toggle("Show Surface Grid", isOn: preferenceBinding(controlStore, \.showSurfaceGrid))
        }
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Picture in Picture", isOn: preferenceBinding(controlStore, \.pictureInPictureEnabled))
                SettingNote("Leaving MeowDisplay during a session keeps your Mac visible in a floating window. It’s view-only — control stays in MeowDisplay.")
                SettingNote("Picture in Picture needs live video from a Mac, so it doesn't start from the demo.")
            }
        }
        Section("Streaming") {
            Picker("Streaming Profile", selection: $demo.streamingProfile) {
                ForEach(StreamingProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }
            Text(demo.streamingProfile.explanation).font(.footnote).foregroundStyle(.secondary)
        }
    }

    // MARK: Audio

    @ViewBuilder
    private var audio: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Audio", isOn: Binding(
                    get: { demo.audioEnabled },
                    set: { value in
                        demo.audioEnabled = value
                        controlStore.update { $0.audioPreferred = value }
                    }))
                SettingNote("Plays a copy of what the Mac is playing. It keeps playing there too — this never changes the Mac's output device.")
            }
            LabeledContent("System Audio", value: demo.audioEnabled ? sample(String(localized: "Playing")) : String(localized: "Off"))
        } footer: {
            Text("Demo: no sound plays from the sample Mac.")
        }
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("A/V Sync")
                    Spacer()
                    Text("\(controlStore.preferences.avSyncOffsetMs) ms").foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(controlStore.preferences.avSyncOffsetMs) },
                    set: { value in
                        let stepped = Int((value / Double(AVSyncOffset.stepMs)).rounded()) * AVSyncOffset.stepMs
                        controlStore.update { $0.avSyncOffsetMs = AVSyncOffset.clamped(stepped) }
                    }),
                       in: Double(AVSyncOffset.range.lowerBound)...Double(AVSyncOffset.range.upperBound),
                       step: Double(AVSyncOffset.stepMs))
                SettingNote("Adjust if sound plays slightly before or after the picture.")
            }
            Button("Resync") { demo.log("Demo audio resynced") }
                .disabled(!demo.audioEnabled)
        }
        .disabled(!demo.audioEnabled)
    }

    // MARK: Connections

    @ViewBuilder
    private var connections: some View {
        Section {
            LabeledContent("Mac", value: DemoSession.macName)
            LabeledContent("Connection", value: String(localized: "Connected (Demo)"))
            LabeledContent("Route", value: sample("Wi-Fi"))
            LabeledContent("Stream", value: sample(streamText))
            LabeledContent("Latency", value: sample("\(demo.latencyMs) ms"))
            LabeledContent("Throughput", value: sample("\(Int(demo.throughputMbps)) Mbps"))
        } header: {
            Text("Status")
        } footer: {
            Text("Sample values for the demo. No network connection is open.")
        }
        Section {
            Label("USB: plug in the cable, run the Mac app — it connects automatically through the wire (lowest latency).",
                  systemImage: "cable.connector")
            Label("WiFi: both devices on the same network, then pick this \(deviceKind) in the Mac app's Connection menu.",
                  systemImage: "wifi")
            Label("Rotate the \(deviceKind) for a vertical second monitor.",
                  systemImage: "rectangle.portrait.rotate")
            Label("Touch: tap to click, drag to drag, two-finger pan to scroll.",
                  systemImage: "hand.tap")
        } header: {
            Text("How to connect")
        }
    }

    // MARK: Paired Macs

    @ViewBuilder
    private var pairedMacs: some View {
        Section {
            HStack {
                Image(systemName: "laptopcomputer").accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: DemoSession.macName)
                    Text("Paired · Connected").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                DemoBadge()
            }
            .accessibilityElement(children: .combine)
            Toggle("Request Input Automatically", isOn: $demo.requestInputAutomatically)
                .font(.subheadline)
            Button("Forget", role: .destructive) {}
                .disabled(true)
        } footer: {
            Text("Demo: \(DemoSession.macName) is a sample and isn't saved as a paired Mac. Forget is unavailable for it. Your real paired Macs aren't shown in the demo. Pairing with a real Mac is confirmed on both devices.")
        }
    }

    // MARK: Remote Access

    @ViewBuilder
    private var remoteAccess: some View {
        Section {
            Text("Use a reachable private-network address for this paired Mac, such as its Tailscale address or MagicDNS name. This lets you connect when the Mac isn't on the same network — it's only used to reach the device, it does not grant trust, and every connection still requires the existing secure pairing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section {
            LabeledContent("Paired Mac", value: DemoSession.macName)
            LabeledContent("Network", value: sample("Tailscale"))
            LabeledContent("Address", value: DemoSession.remoteHost)
            LabeledContent("Port", value: String(DemoSession.remotePort))
            Toggle("Use Remote Access", isOn: $demo.remoteAccessEnabled)
            LabeledContent("Status", value: demo.remoteAccessEnabled ? sample(String(localized: "Ready")) : String(localized: "Off"))
        } header: {
            Text("Remote Access")
        } footer: {
            Text("Sample configuration. Nothing is saved and no connection is attempted.")
        }
    }

    // MARK: Permissions

    @ViewBuilder
    private var permissions: some View {
        Section {
            Button("Open iOS Settings for MeowDisplay") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("This \(deviceKind)")
        } footer: {
            Text("WiFi mode needs Local Network access. If your Mac can't find this \(deviceKind), enable it under Settings → Privacy & Security → Local Network → MeowDisplay. USB mode works without it. Face ID or your passcode confirms each new pairing.")
        }
        Section {
            Label("Screen Recording: lets the Mac app send its screen to this \(deviceKind).", systemImage: "rectangle.dashed.badge.record")
            Label("Accessibility: lets touches and keys from this \(deviceKind) control the Mac.", systemImage: "accessibility")
        } header: {
            Text("On the Mac")
        } footer: {
            Text("Shown for reference in the demo. These are granted on the Mac when you set up the Mac app. The demo hasn't checked or changed any permission.")
        }
    }

    // MARK: Diagnostics

    @ViewBuilder
    private var diagnostics: some View {
        Section {
            ForEach(demo.events) { event in
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: "+\(event.secondsIntoSession)s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(event.message).font(.callout)
                }
            }
        } header: {
            Text("Demo Diagnostics")
        } footer: {
            Text("Sample session data. It isn't saved to the connection log, and no network activity took place.")
        }
        Section {
            Toggle("Performance overlay", isOn: $demo.showPerformanceOverlay)
        } header: {
            Text("Analytics")
        } footer: {
            Text("Shows FPS, bitrate, frame timing and latency graphs over the display. In the demo the numbers are samples.")
        }
    }
}
