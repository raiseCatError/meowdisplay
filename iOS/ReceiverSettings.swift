import SwiftUI
import UIKit

// MARK: - Adaptive Settings

/// Receiver Settings: one category model (`MobileSettingsCategory`) and one
/// set of pages for both size classes. Regular width (iPad) shows a native
/// sidebar with the selected page beside it; compact width (iPhone)
/// collapses the same split view into a category list with pushed pages.
///
/// The root deliberately observes nothing: each page observes only what it
/// shows, so stream telemetry never rebuilds pages (or text fields) that
/// don't display it.
struct SettingsView: View {
    let receiver: StreamReceiver
    let controlStore: ReceiverControlStore
    let pictureInPicture: ReceiverPictureInPictureController
    let haptics: ReceiverHaptics
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: MobileSettingsCategory?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var query = ""
    /// The setting a search result pointed at; its page scrolls to it and
    /// tints it briefly.
    @State private var highlight: String?

    private static var debugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $selection) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    ForEach(MobileSettingsCategory.Group.allCases, id: \.self) { group in
                        Section {
                            ForEach(MobileSettingsCategory.visibleInThisBuild.filter { $0.group == group }) { category in
                                NavigationLink(value: category) {
                                    Label(category.title, systemImage: category.systemImage)
                                }
                            }
                        }
                    }
                } else {
                    searchResults
                }
            }
            .navigationTitle("Settings")
            .searchable(text: $query, placement: .sidebar, prompt: Text("Search Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .modifier(HidesSidebarToggle())
        } detail: {
            NavigationStack {
                if let selection {
                    page(for: selection)
                        .environment(\.settingsHighlight, highlight)
                } else {
                    Text("Select a category")
                        .foregroundStyle(.secondary)
                }
            }
            // A new category starts at its own root, never inside the
            // previous category's pushed pages.
            .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
        // Settings owns its system chrome: the receiver surface behind it
        // hides the status bar and home indicator, and a presentation that
        // inherited that would lay its navigation bar out under the top
        // system region. With the status bar shown here, the split view's
        // own safe area keeps every header and toolbar below it — through
        // rotation and re-presentation alike.
        .statusBarHidden(false)
        .persistentSystemOverlays(.automatic)
        .onAppear {
            if selection == nil {
                selection = MobileSettingsCategory.initialSelection(regularWidth: horizontalSizeClass == .regular)
            }
        }
        .task(id: highlight) {
            guard highlight != nil else { return }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation(.easeOut(duration: 0.4)) { highlight = nil }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        let results = MobileSettingsSearchIndex.search(query, isPad: controlStore.isPad, debug: Self.debugBuild)
        if results.isEmpty {
            Text("No Results").foregroundStyle(.secondary)
        } else {
            ForEach(results) { item in
                Button {
                    highlight = item.isCategory ? nil : item.id
                    selection = item.category
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).foregroundStyle(.primary)
                            if !item.isCategory {
                                Text(item.category.title).font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: item.category.systemImage)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func page(for category: MobileSettingsCategory) -> some View {
        switch category {
        case .general:
            GeneralSettingsPage(receiver: receiver, controlStore: controlStore)
        case .display:
            DisplaySettingsPage(receiver: receiver, controlStore: controlStore, pictureInPicture: pictureInPicture)
        case .input:
            InputSettingsPage(receiver: receiver, controlStore: controlStore)
        case .gestures:
            GestureSettingsPage(controlStore: controlStore)
        case .controls:
            ControlSettingsPage(controlStore: controlStore, haptics: haptics)
        case .audio:
            AudioSettingsPage(receiver: receiver, controlStore: controlStore)
        case .connections:
            ConnectionSettingsPage(receiver: receiver)
        case .pairedMacs:
            PairedMacsSettingsPage(receiver: receiver)
        case .remoteAccess:
            RemoteAccessSettingsPage(receiver: receiver)
        case .permissions:
            PermissionsSettingsPage()
        case .diagnostics:
            DiagnosticsSettingsPage()
        case .about:
            AboutSettingsPage()
        case .developer:
            #if DEBUG
            DeveloperSettingsPage(receiver: receiver)
            #else
            EmptyView()
            #endif
        }
    }
}

/// Binds one receiver preference through `ReceiverControlStore.update`.
@MainActor
private func preferenceBinding<Value>(_ store: ReceiverControlStore,
                                      _ keyPath: WritableKeyPath<ReceiverControlPreferences, Value>) -> Binding<Value> {
    Binding(get: { store.preferences[keyPath: keyPath] },
            set: { value in store.update { $0[keyPath: keyPath] = value } })
}

/// The setting a search result points at — see `SettingsForm`.
private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

/// A settings page: a `Form` that scrolls to, and briefly tints, the row a
/// search result pointed at (rows opt in with `settingsAnchor`).
private struct SettingsForm<Content: View>: View {
    @Environment(\.settingsHighlight) private var highlight
    @ViewBuilder let content: Content

    var body: some View {
        ScrollViewReader { proxy in
            Form { content }
                .task(id: highlight) {
                    guard let highlight else { return }
                    // Let the pushed page finish laying out first.
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    withAnimation { proxy.scrollTo(highlight, anchor: .center) }
                }
        }
    }
}

private struct SettingsAnchor: ViewModifier {
    let id: String
    @Environment(\.settingsHighlight) private var highlight

    func body(content: Content) -> some View {
        content
            .id(id)
            .listRowBackground(highlight == id ? Color.accentColor.opacity(0.18) : nil)
    }
}

private extension View {
    /// Marks a row as the target of the search item with this id.
    func settingsAnchor(_ id: String) -> some View { modifier(SettingsAnchor(id: id)) }
}

/// Settings' sidebar is its navigation, so it never collapses away.
private struct HidesSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}

/// A setting's secondary explanation line.
private struct SettingNote: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
    }
}

// MARK: - General

private struct GeneralSettingsPage: View {
    let receiver: StreamReceiver
    @ObservedObject var controlStore: ReceiverControlStore

    var body: some View {
        SettingsForm {
            Section {
                // Isolated from the receiver: a TextField that rebuilds
                // mid-tap loses focus (the "tap twice to edit" bug). This
                // subview owns its focus and doesn't observe the receiver.
                DeviceNameField { receiver.setServiceName($0) }
                    .settingsAnchor("deviceName")
            } header: {
                Text("Name")
            } footer: {
                Text("Shown in the Mac app's WiFi connection menu. iOS hides this \(deviceKind)'s real name from apps, so set it here once.")
            }
            Section {
                AutoReconnectToggle(receiver: receiver)
                    .settingsAnchor("autoReconnect")
            } header: {
                Text("Connection")
            } footer: {
                Text("Automatically reconnect to paired devices after connection interruptions. Turning this off only stops automatic reconnecting — Connect, Reconnect, and Wake & Connect still work, and an active session stays connected. Also shown on the Home screen.")
            }
            Section {
                Toggle("Haptics", isOn: preferenceBinding(controlStore, \.hapticsEnabled))
                    .settingsAnchor("haptics")
            }
        }
        .navigationTitle(MobileSettingsCategory.general.title)
    }
}

/// Its own view so only this toggle observes the receiver.
private struct AutoReconnectToggle: View {
    @ObservedObject var receiver: StreamReceiver
    var body: some View {
        Toggle("Auto-Reconnect", isOn: $receiver.autoReconnectEnabled)
    }
}

/// The device-name editor, deliberately kept out of any high-frequency
/// @ObservedObject so streaming updates can't rebuild it and steal focus.
struct DeviceNameField: View {
    @AppStorage("deviceName") private var deviceName = UIDevice.current.name
    @FocusState private var focused: Bool
    let onChange: (String) -> Void

    var body: some View {
        TextField("Device name", text: $deviceName)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .focused($focused)
            .onChange(of: deviceName) { name in onChange(name) }
    }
}

// MARK: - Display

private struct DisplaySettingsPage: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var controlStore: ReceiverControlStore
    @ObservedObject var pictureInPicture: ReceiverPictureInPictureController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsForm {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Video", isOn: Binding(
                        get: { receiver.videoEnabled },
                        set: { receiver.requestVideoEnabled($0) }))
                        .disabled(!receiver.connected || !receiver.macSupportsVideoControl)
                    SettingNote("Turning video off keeps the connection, keyboard, controls, and selected input mode active.")
                }
                .settingsAnchor("video")
                displayModeRows
                Toggle("Show Surface Grid", isOn: preferenceBinding(controlStore, \.showSurfaceGrid))
                    .settingsAnchor("surfaceGrid")
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Picture in Picture", isOn: preferenceBinding(controlStore, \.pictureInPictureEnabled))
                    SettingNote("Leaving MeowDisplay during a session keeps your Mac visible in a floating window. It’s view-only — control stays in MeowDisplay.")
                    if let note = pictureInPictureNote {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .settingsAnchor("pictureInPicture")
                if pictureInPicture.isShowingWindow {
                    Button("Stop Picture in Picture") { pictureInPicture.stop() }
                } else if pictureInPicture.availability == .available {
                    Button {
                        // Started from the tap itself: AVKit only honors a
                        // manual start made in response to user action.
                        pictureInPicture.start()
                        dismiss()
                    } label: {
                        Label("Start Picture in Picture", systemImage: "pip.enter")
                    }
                }
            }
            streamingProfileSection
            maxFPSSection
        }
        .navigationTitle(MobileSettingsCategory.display.title)
    }

    @ViewBuilder
    private var displayModeRows: some View {
        if let confirmedMode = receiver.confirmedDisplayMode {
            Picker("Display Mode", selection: Binding(
                get: { receiver.pendingDisplayMode ?? confirmedMode },
                set: { receiver.requestDisplayMode($0) })) {
                ForEach(ReceiverDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                        .disabled(!receiver.videoEnabled && mode == .extend)
                }
            }
            .disabled(!receiver.connected
                      || receiver.macProtocolVersion < WireProtocol.displayModeWireVersion
                      || receiver.pendingDisplayMode != nil)
            .settingsAnchor("displayMode")
            if let pendingMode = receiver.pendingDisplayMode {
                LabeledContent("Switching to \(pendingMode.title)") {
                    ProgressView()
                }
            }
            if confirmedMode == .mirror,
               receiver.macProtocolVersion >= WireProtocol.mirrorDisplayWireVersion {
                mirrorDisplaySourcePicker
            }
            if confirmedMode == .extend,
               receiver.macProtocolVersion >= WireProtocol.extendShapeWireVersion {
                extendShapePicker
            }
        } else {
            LabeledContent("Display Mode",
                           value: receiver.connected ? String(localized: "Waiting for Mac") : String(localized: "Unavailable"))
        }
    }

    /// Remote control for the Mac's own canonical Mirror capture source
    /// (`SenderController.mirrorDisplayUUID`) — never an independent
    /// iOS-only preference. `nil` selection means Auto, mirroring the Mac's
    /// own nil-means-automatic semantic exactly (see
    /// `Mac/MirrorDisplaySelection.swift`).
    @ViewBuilder
    private var mirrorDisplaySourcePicker: some View {
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
        .disabled(!receiver.connected || state == nil)
        if let state, state.selectedUUID != nil {
            if state.displays.isEmpty {
                SettingNote("No displays reported.")
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
                    }
                }
                if let selected = state.selectedUUID, !state.displays.contains(where: { $0.uuid == selected }) {
                    Text("Selected display unavailable")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// Requests an Extend virtual-display shape change (PROTOCOL.md 6.7).
    /// The Mac remains authoritative — this only requests; the shown value
    /// always tracks `confirmedExtendShape`/`pendingExtendShape`.
    @ViewBuilder
    private var extendShapePicker: some View {
        if let confirmed = receiver.confirmedExtendShape {
            let current = receiver.pendingExtendShape ?? confirmed
            Picker("Extend Shape", selection: Binding(
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
            .disabled(!receiver.connected || receiver.pendingExtendShape != nil)
            if current.shape == .automatic {
                Toggle("Use Full Display", isOn: Binding(
                    get: { current.useFullDisplay },
                    set: { value in
                        var preference = current
                        preference.useFullDisplay = value
                        receiver.requestExtendShape(preference)
                    }))
                .disabled(!receiver.connected || receiver.pendingExtendShape != nil)
            }
            if receiver.pendingExtendShape != nil {
                LabeledContent("Updating Extend shape…") { ProgressView() }
            }
            if let text = fpsLimitationText {
                Text(text).font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Extend Shape", value: receiver.connected ? String(localized: "Waiting for Mac") : String(localized: "Unavailable"))
        }
    }

    /// Re-sent by the Mac on every capture (re)start, derived entirely from
    /// `receiver.lastMaxFPSState` — never guessed from the shape alone.
    private var fpsLimitationText: String? {
        guard let state = receiver.lastMaxFPSState else { return nil }
        if state.encoderSafeFPS >= state.requestedFPS {
            return nil
        }
        return String(localized: "\(receiver.streamingProfile.label) requests \(state.requestedFPS) FPS. Limited to \(state.encoderSafeFPS) FPS at this display size.",
                      comment: "The first value is a streaming profile name, such as Performance.")
    }

    @ViewBuilder
    private var streamingProfileSection: some View {
        Section("Streaming") {
            let profileBinding = Binding<StreamingProfile>(
                get: { receiver.streamingProfile },
                set: { receiver.requestStreamingProfile($0, customFrameRate: receiver.customFrameRate) })
            Picker("Streaming Profile", selection: profileBinding) {
                ForEach(StreamingProfile.allCases) { profile in
                    Text(profile.label).tag(profile)
                }
            }
            .settingsAnchor("streamingProfile")
            Text(receiver.streamingProfile.explanation).font(.footnote).foregroundStyle(.secondary)
            if receiver.streamingProfile == .custom {
                let frameRateBinding = Binding<CustomFrameRateSelection>(
                    get: { receiver.customFrameRate },
                    set: { receiver.requestStreamingProfile(.custom, customFrameRate: $0) })
                Picker("Frame Rate", selection: frameRateBinding) {
                    ForEach(CustomFrameRateSelection.allCases) { frameRate in
                        Text(frameRate.label).tag(frameRate)
                    }
                }
            }
            let priorityBinding = Binding<StreamingPriority>(
                get: { receiver.streamingPriority },
                set: { receiver.requestStreamingPriority($0) })
            Picker("Streaming Priority", selection: priorityBinding) {
                ForEach(StreamingPriority.allCases) { priority in
                    Text(priority.label).tag(priority)
                }
            }
            Text(receiver.streamingPriority.explanation).font(.footnote).foregroundStyle(.secondary)
        }
    }

    /// Receiver-enforced max-FPS control, request/confirm-aware — disabled
    /// while a request is in flight, and only offering tiers the Mac says are
    /// reachable right now.
    @ViewBuilder
    private var maxFPSSection: some View {
        if receiver.macProtocolVersion >= WireProtocol.maxFPSWireVersion {
            Section {
                if let confirmed = receiver.confirmedMaxFPS {
                    let current = receiver.pendingMaxFPS ?? confirmed
                    Toggle("Enforce Maximum FPS", isOn: Binding(
                        get: { current.enabled },
                        set: { enabled in
                            var preference = current
                            preference.enabled = enabled
                            receiver.requestMaxFPS(preference)
                        }))
                        .disabled(!receiver.connected || receiver.pendingMaxFPS != nil)
                        .settingsAnchor("maxFPS")
                    if current.enabled {
                        let tiers = MaxFPSPicker.tiers(reported: receiver.lastMaxFPSState?.availableTiers)
                        Picker("Maximum FPS", selection: Binding(
                            get: { MaxFPSPicker.selection(current, among: tiers) },
                            set: { fps in
                                var preference = current
                                preference.maxFPS = fps
                                receiver.requestMaxFPS(preference)
                            })) {
                            ForEach(tiers, id: \.self) { fps in
                                Text("\(fps)").tag(fps)
                            }
                        }
                        .disabled(!receiver.connected || receiver.pendingMaxFPS != nil)
                    }
                    if receiver.pendingMaxFPS != nil {
                        LabeledContent("Updating Maximum FPS…") { ProgressView() }
                    }
                } else {
                    LabeledContent("Maximum FPS", value: receiver.connected ? String(localized: "Waiting for Mac") : String(localized: "Unavailable"))
                }
            } footer: {
                Text("Caps how fast this Mac streams to this device, on top of its normal profile/display limits.")
            }
        }
    }

    /// Why Picture in Picture can't run even though it's turned on, when
    /// that reason is something other than simply waiting for live video.
    private var pictureInPictureNote: String? {
        switch pictureInPicture.availability {
        case .unsupported:
            return String(localized: "Picture in Picture isn’t supported on this device.")
        case .requiresSystemVideoLayer:
            return String(localized: "Unavailable while the experimental Metal renderer is on.")
        case .available, .turnedOff, .waitingForVideo:
            return nil
        }
    }
}

// MARK: - Input

private struct InputSettingsPage: View {
    let receiver: StreamReceiver
    @ObservedObject var controlStore: ReceiverControlStore
    @AppStorage("zoomWhileTyping") private var zoomWhileTyping = true

    var body: some View {
        SettingsForm {
            Section {
                // Never optimistic: this only ever reflects the Mac's last
                // CONFIRMED decision (`ReceiverControlStore.sessionInputState`).
                LabeledContent("Control", value: controlStore.sessionInputState.receiverDisplayText)
                    .settingsAnchor("control")
                switch controlStore.sessionInputState {
                case .off, .notAllowed:
                    Button("Request Control") {
                        controlStore.noteInputTurnedOffByUser(false)
                        receiver.requestAllowInput(true)
                    }
                case .requesting:
                    EmptyView()
                case .allowed:
                    Button("Turn Off", role: .destructive) {
                        controlStore.noteInputTurnedOffByUser(true)
                        receiver.requestAllowInput(false)
                    }
                case .requestsDisabled:
                    SettingNote("This Mac isn't accepting control requests from this device right now. Enable it from the Mac's Input settings.")
                }
            } footer: {
                Text("Settings always stays reachable, even with input turned off.")
            }
            Section {
                Picker("Input Mode", selection: preferenceBinding(controlStore, \.inputMode)) {
                    ForEach(PointerInputMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .settingsAnchor("inputMode")
                Text(controlStore.preferences.inputMode.explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if controlStore.preferences.inputMode == .direct {
                    smartTouchRows
                }
            } header: {
                Text("Input Mode")
            }
            Section {
                HStack {
                    Text("Trackpad Sensitivity")
                    Spacer()
                    if controlStore.preferences.trackpadSensitivity != PointerGestureConfig.defaultTrackpadSensitivity {
                        Button("Reset") {
                            controlStore.update { $0.trackpadSensitivity = PointerGestureConfig.defaultTrackpadSensitivity }
                        }
                        .font(.footnote)
                    }
                }
                Slider(value: preferenceBinding(controlStore, \.trackpadSensitivity),
                       in: PointerGestureConfig.trackpadSensitivityRange, step: 0.1) {
                    Text("Trackpad Sensitivity")
                } minimumValueLabel: {
                    Text("Slow")
                } maximumValueLabel: {
                    Text("Fast")
                }
                .font(.footnote)
                .settingsAnchor("trackpadSensitivity")
            } footer: {
                Text("Sensitivity only affects Trackpad mode's one-finger pointer movement.")
            }
            Section {
                Toggle("Invert Vertical Scrolling", isOn: preferenceBinding(controlStore, \.invertVerticalScroll))
                    .settingsAnchor("scrollDirection")
                Toggle("Invert Horizontal Scrolling", isOn: preferenceBinding(controlStore, \.invertHorizontalScroll))
            } header: {
                Text("Scrolling")
            } footer: {
                Text("On, content moves with your fingers, like a Mac trackpad’s natural scrolling. Turn an axis off to reverse just that direction; diagonal scrolls follow both. Moving your own view of the Mac isn’t affected.")
            }
            Section {
                Toggle("Zoom While Typing", isOn: $zoomWhileTyping)
                    .settingsAnchor("zoomWhileTyping")
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Enlarge the area you're typing in when the keyboard is open.")
            }
        }
        .navigationTitle(MobileSettingsCategory.input.title)
    }

    @ViewBuilder
    private var smartTouchRows: some View {
        Toggle(isOn: preferenceBinding(controlStore, \.smartTouchEnabled)) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: "Smart Touch")
                    Text("Experimental")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
                SettingNote("Scroll with one finger in any direction. Hold a title bar, then drag, to move its window. Elsewhere, touch and hold for normal Direct Touch. Falls back to Direct Touch when the Mac can't identify the area.")
            }
        }
        .settingsAnchor("smartTouch")
        if controlStore.preferences.smartTouchEnabled {
            Toggle(isOn: preferenceBinding(controlStore, \.smartTouchLongPressHapticEnabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Touch Haptics", comment: "Toggle label. \"Smart Touch\" is the feature's brand name and must stay untranslated; only \"Haptics\" is translatable.")
                    Text(controlStore.preferences.hapticsEnabled
                         ? "Builds while you hold a title bar, then ticks when the window can move. Also confirms switching to Direct Touch."
                         : "Off while Haptics is turned off.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!controlStore.preferences.hapticsEnabled)
            .settingsAnchor("smartTouchHaptics")
        }
    }
}

// MARK: - Gestures

private struct GestureSettingsPage: View {
    @ObservedObject var controlStore: ReceiverControlStore

    var body: some View {
        SettingsForm {
            Section {
                targetPicker("Pinch / Zoom", \.pinchTarget)
                    .settingsAnchor("pinch")
                targetPicker("Rotation", \.rotateTarget)
                    .settingsAnchor("rotation")
                Toggle("Snap Rotation", isOn: preferenceBinding(controlStore, \.snapRotation))
                    .disabled(controlStore.preferences.rotateTarget != .viewport)
                if controlStore.preferences.pinchTarget == .app || controlStore.preferences.rotateTarget == .app {
                    NavigationLink("App Gesture Commands") {
                        AppGestureCommandsView(store: controlStore)
                    }
                }
            } header: {
                Text("Pinch and Rotation")
            } footer: {
                Text("Video Off temporarily routes pinch and rotate to App without changing these saved choices. App mode is experimental: instead of injecting native gestures into the foreground app, it sends the keyboard commands configured in App Gesture Commands.")
            }
            Section {
                Toggle("Prefer MeowDisplay Gestures", isOn: preferenceBinding(controlStore, \.preferMeowDisplayGestures))
                    .settingsAnchor("preferGestures")
            } footer: {
                Text("While you’re controlling the Mac, MeowDisplay gets priority for the gestures it supports: the first swipe from a screen edge goes to the Mac, and three-finger swipes aren’t taken by editing shortcuts. Some \(deviceKind) and accessibility gestures always stay with the system, and VoiceOver always takes precedence.")
            }
            Section {
                Toggle("Allow Local View Navigation", isOn: preferenceBinding(controlStore, \.allowLocalViewNavigation))
                    .settingsAnchor("localViewNavigation")
                if controlStore.preferences.allowLocalViewNavigation {
                    if controlStore.isPad {
                        LabeledContent("Move View", value: String(localized: "Drag to move, pinch to zoom"))
                            .settingsAnchor("moveView")
                    }
                    LabeledContent("Reset View", value: String(localized: "Double-tap with two fingers"))
                        .settingsAnchor("resetView")
                }
            } header: {
                Text("Viewport")
            } footer: {
                if controlStore.isPad {
                    Text("Pan, zoom and rotate your own view of the Mac — until an edge of your Mac reaches the middle of the screen. This never sends anything to the Mac, so it works even while Allow Input is off. Move View lets one finger move the picture without clicking or scrolling on the Mac; two-finger scrolling always goes to the Mac.")
                } else {
                    Text("Pan, zoom and rotate your own view of the Mac — until an edge of your Mac reaches the middle of the screen. This never sends anything to the Mac, so it works even while Allow Input is off. Two-finger scrolling always goes to the Mac.")
                }
            }
        }
        .navigationTitle(MobileSettingsCategory.gestures.title)
    }

    private func targetPicker(_ title: LocalizedStringKey,
                              _ keyPath: WritableKeyPath<ReceiverControlPreferences, ReceiverGestureTarget>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Picker(title, selection: preferenceBinding(controlStore, keyPath)) {
                ForEach(ReceiverGestureTarget.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if controlStore.preferences[keyPath: keyPath] == .app {
                SettingNote("Experimental app command mode")
            }
        }
    }
}

// MARK: - Controls

private struct ControlSettingsPage: View {
    @ObservedObject var controlStore: ReceiverControlStore
    let haptics: ReceiverHaptics
    @State private var confirmingReset = false
    @State private var confirmingFunctionTrayReset = false
    @State private var customEditorRequest: CustomLayoutEditorRequest?
    @State private var deletingCustomLayout: CustomControlLayout?

    private var visibility: PadControlSettingsVisibility {
        PadControlSettingsVisibility(isPad: controlStore.isPad, layout: controlStore.preferences.padControlLayout)
    }

    var body: some View {
        SettingsForm {
            if visibility.showsLayoutPicker {
                padLayoutSection
            }
            if visibility.showsCustomLayouts {
                CustomLayoutListSection(store: controlStore, editorRequest: $customEditorRequest,
                                        deleting: $deletingCustomLayout)
                    .settingsAnchor("customLayouts")
            }
            if visibility.showsEdgePickers {
                standardControlsSection
            }
            Section {
                Toggle("Show Control Tray", isOn: preferenceBinding(controlStore, \.trayEnabled))
                    .disabled(!controlStore.preferences.allowInput)
                    .settingsAnchor("showTray")
                Toggle("Show Keyboard Button", isOn: preferenceBinding(controlStore, \.keyboardButtonEnabled))
                Toggle("Collapse Control Tray", isOn: preferenceBinding(controlStore, \.trayCollapsed))
                Toggle("Auto-hide Control Trays", isOn: preferenceBinding(controlStore, \.autoHideEnabled))
                    .settingsAnchor("autoHide")
                if visibility.showsPhoneTrayPlacement {
                    Picker("Landscape Tray Side", selection: preferenceBinding(controlStore, \.preferredLandscapeSide)) {
                        ForEach(LandscapeTraySide.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .settingsAnchor("trayPlacement")
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Avoid Notch", isOn: preferenceBinding(controlStore, \.avoidNotch))
                        SettingNote("Keeps controls clear of the iPhone’s notch or Dynamic Island in landscape.")
                        Text("Experimental").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text("Main Controls")
            } footer: {
                if controlStore.isPad {
                    Text("Auto-hide fades Overlay and Custom controls after a few seconds without use. The Strip always stays visible.")
                }
            }
            Section {
                Picker("Active Profile", selection: Binding(
                    get: { controlStore.preferences.activeControlProfile },
                    set: { profile in
                        controlStore.update { $0.activeControlProfile = profile }
                        haptics.play(.profileChange)
                    })) {
                    ForEach(ControlProfileSlot.allCases) { Text($0.title).tag($0) }
                }
                .settingsAnchor("controlProfile")
                NavigationLink("Edit Current Profile") {
                    ControlProfileEditor(store: controlStore, haptics: haptics)
                }
                Button("Reset Profile to Default", role: .destructive) {
                    confirmingReset = true
                }
            } header: {
                Text("Control Profile")
            } footer: {
                Text("Which controls appear, and the shortcuts each modifier chord offers.")
            }
            Section {
                Toggle("Show Function Tray", isOn: preferenceBinding(controlStore, \.functionTrayEnabled))
                    .disabled(!controlStore.preferences.allowInput)
                    .settingsAnchor("functionTray")
                if visibility.showsPhoneTrayPlacement {
                    Picker("Function Tray Position", selection: preferenceBinding(controlStore, \.functionTrayPosition)) {
                        ForEach(FunctionTrayPosition.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Picker("Function Profile", selection: Binding(
                    get: { controlStore.preferences.activeFunctionTrayProfile },
                    set: { profile in
                        controlStore.update { $0.activeFunctionTrayProfile = profile }
                        haptics.play(.profileChange)
                    })) {
                    ForEach(ControlProfileSlot.allCases) { Text($0.title).tag($0) }
                }
                NavigationLink("Edit Function Tray") {
                    FunctionTrayEditor(store: controlStore, slot: controlStore.preferences.activeFunctionTrayProfile)
                }
                Button("Reset Function Tray to Default", role: .destructive) {
                    confirmingFunctionTrayReset = true
                }
            } header: {
                Text("Function Tray")
            } footer: {
                if visibility.showsPhoneTrayPlacement {
                    Text("A second, independent tray of one-tap shortcuts (Undo, Redo, …), separate from the Main Tray above. \"Same Side\" groups it with the Main Tray; \"Opposite Side\" puts it on the other edge of the screen.")
                } else {
                    Text("A second, independent set of one-tap shortcuts (Undo, Redo, …), separate from the Main controls.")
                }
            }
        }
        .navigationTitle(MobileSettingsCategory.controls.title)
        .modifier(CustomLayoutPresentations(store: controlStore, editorRequest: $customEditorRequest,
                                            deleting: $deletingCustomLayout))
        .confirmationDialog("Reset \(controlStore.preferences.activeControlProfile.title)?",
                            isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Profile", role: .destructive) {
                controlStore.update { $0.resetProfile($0.activeControlProfile) }
                haptics.play(.reset)
            }
        } message: {
            Text("This restores its tray layout and shortcut palettes. Other receiver settings stay unchanged.")
        }
        .confirmationDialog("Reset \(controlStore.preferences.activeFunctionTrayProfile.title)?",
                            isPresented: $confirmingFunctionTrayReset, titleVisibility: .visible) {
            Button("Reset Function Tray", role: .destructive) {
                controlStore.update { $0.resetFunctionTrayProfile($0.activeFunctionTrayProfile) }
                haptics.play(.reset)
            }
        } message: {
            Text("This restores its default Undo/Redo layout. Other receiver settings stay unchanged.")
        }
    }

    /// Which standard controls the Strip/Overlay rail shows — one model
    /// (`PadStandardControlVisibility`) for all of them. Settings is always
    /// there; modifiers come from the Control Profile.
    private var standardControlsSection: some View {
        Section {
            ForEach(PadStandardControl.allCases) { control in
                Toggle(control.title, isOn: Binding(
                    get: { controlStore.preferences.padStandardControls.isVisible(control) },
                    set: { visible in controlStore.update { $0.padStandardControls.setVisible(visible, control) } }))
            }
        } header: {
            Text("Standard Controls")
        } footer: {
            Text("Shown on the Strip and Overlay rail, grouped as system actions, then keys, then view controls. Settings always stays on the rail. Move View also needs Allow Local View Navigation.")
        }
        .settingsAnchor("standardControls")
    }

    /// iPad only (see `PadControlSettingsVisibility`).
    @ViewBuilder
    private var padLayoutSection: some View {
        Section {
            Picker("Control Layout", selection: Binding(
                get: { controlStore.preferences.padControlLayout },
                set: { mode in
                    controlStore.update { preferences in
                        preferences.padControlLayout = mode
                        // Custom always has something to show.
                        if mode == .custom, preferences.customLayouts.isEmpty {
                            preferences.createCustomLayout()
                        }
                    }
                })) {
                ForEach(PadControlLayoutMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .settingsAnchor("controlLayout")
            if visibility.showsEdgePickers {
                Picker("Main Controls", selection: preferenceBinding(controlStore, \.padMainEdge)) {
                    ForEach(ControlEdge.allCases) { Text($0.title).tag($0) }
                }
                .settingsAnchor("controlEdges")
                Picker("Function Controls", selection: preferenceBinding(controlStore, \.padFunctionEdge)) {
                    ForEach(ControlEdge.allCases) { Text($0.title).tag($0) }
                }
            }
            if visibility.showsEdgePickers {
                Picker("Palette Style", selection: preferenceBinding(controlStore, \.padOverlayPaletteStyle)) {
                    ForEach(PadPaletteStyle.allCases) { Text($0.title).tag($0) }
                }
                .settingsAnchor("paletteStyle")
            }
            if visibility.showsControlHints {
                Toggle("Show Control Hints", isOn: preferenceBinding(controlStore, \.padShowControlHints))
                    .settingsAnchor("controlHints")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Control Size")
                    Spacer()
                    Text(controlStore.preferences.padControlScale, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if controlStore.preferences.padControlScale != PadControlScale.defaultValue {
                        Button("Reset") { controlStore.update { $0.padControlScale = PadControlScale.defaultValue } }
                            .font(.footnote)
                            .buttonStyle(.borderless)
                    }
                }
                Slider(value: Binding(
                    get: { controlStore.preferences.padControlScale },
                    set: { value in controlStore.update { $0.padControlScale = PadControlScale.clamped(value) } }),
                       in: PadControlScale.range, step: 0.05) {
                    Text("Control Size")
                } minimumValueLabel: {
                    Image(systemName: "circle.fill").font(.system(size: 8)).accessibilityHidden(true)
                } maximumValueLabel: {
                    Image(systemName: "circle.fill").font(.system(size: 16)).accessibilityHidden(true)
                }
            }
            .settingsAnchor("controlSize")
        } header: {
            Text("Control Layout")
        } footer: {
            switch controlStore.preferences.padControlLayout {
            case .strip:
                Text("A solid rail at the edge of the screen holds the controls, and your Mac fits beside it.")
            case .overlay:
                Text("Your Mac uses the whole screen and the controls float over it.")
            case .custom:
                Text("Place every control yourself, with separate landscape and portrait layouts.")
            }
        }
    }
}

// MARK: - Audio

private struct AudioSettingsPage: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var controlStore: ReceiverControlStore

    var body: some View {
        SettingsForm {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Audio", isOn: Binding(
                        get: { controlStore.preferences.audioPreferred },
                        set: { value in
                            controlStore.update { $0.audioPreferred = value }
                            receiver.requestAudioEnabled(value)
                        }))
                        .disabled(!receiver.connected || !receiver.macSupportsAudio)
                        .settingsAnchor("audio")
                    SettingNote("Plays a copy of what the Mac is playing. It keeps playing there too — this never changes the Mac's output device.")
                }
            }
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("A/V Sync")
                        Spacer()
                        Text(avSyncOffsetLabel(controlStore.preferences.avSyncOffsetMs))
                            .foregroundStyle(.secondary)
                        if controlStore.preferences.avSyncOffsetMs != 0 {
                            Button("Reset") {
                                controlStore.update { $0.avSyncOffsetMs = 0 }
                            }
                            .font(.footnote)
                            .buttonStyle(.borderless)
                        }
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
                VStack(alignment: .leading, spacing: 4) {
                    Button("Resync") {
                        receiver.resync()
                    }
                    .disabled(!receiver.connected || !receiver.audioEnabled)
                    SettingNote("If audio drifts or stutters, Resync re-establishes timing without reconnecting. It doesn't change your A/V Sync adjustment above.")
                }
            }
            .disabled(!controlStore.preferences.audioPreferred)
        }
        .navigationTitle(MobileSettingsCategory.audio.title)
    }

    private func avSyncOffsetLabel(_ ms: Int) -> String {
        ms == 0 ? "0 ms" : (ms > 0 ? "+\(ms) ms" : "\(ms) ms")
    }
}

// MARK: - Connections

private struct ConnectionSettingsPage: View {
    @ObservedObject var receiver: StreamReceiver

    var body: some View {
        SettingsForm {
            Section("Status") {
                LabeledContent("Connection",
                               value: receiver.connected ? receiver.status : receiver.canonicalPhaseTitle)
                                   .settingsAnchor("connectionStatus")
                if receiver.videoSize != .zero {
                    LabeledContent("Stream",
                                   value: "\(Int(receiver.videoSize.width))×\(Int(receiver.videoSize.height)) @ \(receiver.fps) fps")
                }
                if receiver.connected {
                    Button("Disconnect", role: .destructive) {
                        receiver.disconnect()
                    }
                }
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
        .navigationTitle(MobileSettingsCategory.connections.title)
    }
}

// MARK: - Paired Macs

private struct PairedMacsSettingsPage: View {
    let receiver: StreamReceiver
    @State private var trustRefresh = 0
    @State private var forgetConfirmation = PeerForgetPrompt()

    var body: some View {
        SettingsForm {
            Section {
                let peers = TrustStore.shared.pinnedPeers()
                if peers.isEmpty {
                    Text("No paired Macs").foregroundStyle(.secondary)
                } else {
                    AutomaticallyAllowConnectionsToggle()
                        .settingsAnchor("pairedMacs")
                    ForEach(peers, id: \.peerID) { peer in
                        HStack {
                            Text(peer.displayName)
                            Spacer()
                            Button("Forget", role: .destructive) {
                                forgetConfirmation.request(peerID: peer.peerID, name: peer.displayName)
                            }
                            .buttonStyle(.borderless)
                        }
                        IncomingSessionPolicyPicker(peerID: peer.peerID, receiver: receiver)
                            .font(.subheadline)
                        RequestInputAutomaticallyToggle(peerID: peer.peerID)
                    }
                }
            } footer: {
                Text("Connection Requests: Default follows Automatically Allow Connections. Blocking keeps the Mac paired. Request Input Automatically lets a touch on the Mac’s screen ask that Mac for control without tapping Request Input first — the Mac still decides.")
            }
            .id(trustRefresh)
        }
        .navigationTitle(MobileSettingsCategory.pairedMacs.title)
        .alert("Forget \u{201C}\(forgetConfirmation.candidate?.name ?? "This Mac")\u{201D}?",
               isPresented: Binding(get: { forgetConfirmation.isPresented },
                                    set: { if !$0 { forgetConfirmation.cancel() } })) {
            Button("Forget", role: .destructive) {
                forgetConfirmation.confirm { peerID in
                    receiver.forgetPeer(peerID)
                    receiver.pairingPrompt.cancel()
                    trustRefresh &+= 1
                }
            }
            Button("Cancel", role: .cancel) { forgetConfirmation.cancel() }
        } message: {
            Text("You'll need to pair with this Mac again before connecting.")
        }
    }
}

/// Per-Mac opt-in for sending the input request from a blocked touch. Kept
/// separate from the connection policy on purpose.
private struct RequestInputAutomaticallyToggle: View {
    let peerID: String
    @State private var enabled = false

    var body: some View {
        Toggle("Request Input Automatically", isOn: Binding(
            get: { enabled },
            set: { value in
                enabled = value
                InputAutoRequestStore.setEnabled(value, peerID: peerID)
            }))
        .font(.subheadline)
        .onAppear { enabled = InputAutoRequestStore.isEnabled(peerID: peerID) }
    }
}

// MARK: - Remote Access

private struct RemoteAccessSettingsPage: View {
    let receiver: StreamReceiver

    var body: some View {
        if TrustStore.shared.pinnedPeers().isEmpty {
            SettingsForm {
                Section {
                    Text("Pair with a Mac first, then set up Remote Access for it here.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(MobileSettingsCategory.remoteAccess.title)
        } else {
            RemoteAccessSettingsView(receiver: receiver)
        }
    }
}

// MARK: - Permissions

private struct PermissionsSettingsPage: View {
    var body: some View {
        SettingsForm {
            Section {
                Button("Open iOS Settings for MeowDisplay") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .settingsAnchor("localNetwork")
            } footer: {
                Text("WiFi mode needs Local Network access. If your Mac can't find this \(deviceKind), enable it under Settings → Privacy & Security → Local Network → MeowDisplay. USB mode works without it.")
            }
        }
        .navigationTitle(MobileSettingsCategory.permissions.title)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSettingsPage: View {
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("metalRenderer") private var metalRenderer = false

    var body: some View {
        SettingsForm {
            Section {
                NavigationLink {
                    DiagnosticsLogView()
                } label: {
                    Label("Connection log", systemImage: "doc.text.magnifyingglass")
                }
            } footer: {
                Text("What this \(deviceKind) saw while connecting: sessions, restarts, decoder trouble. No screen content and nothing leaves the \(deviceKind) unless you share it. Attach it to a GitHub issue if a connection won't come up.")
            }
            Section {
                Toggle("Performance overlay", isOn: $showAnalytics)
                    .settingsAnchor("performanceOverlay")
                Toggle("Metal renderer (experimental)", isOn: $metalRenderer)
                    .settingsAnchor("metalRenderer")
            } header: {
                Text("Analytics")
            } footer: {
                Text("The overlay shows FPS, bitrate, frame timing, stalls, and latency graphs at the bottom of the screen while streaming. The experimental Metal renderer decodes and presents frames manually — it adds decode and true on-glass latency metrics to the overlay, but in our measurements the system video layer displays frames faster. Leave it off unless you're debugging.")
            }
        }
        .navigationTitle(MobileSettingsCategory.diagnostics.title)
    }
}

// MARK: - About

private struct AboutSettingsPage: View {
    // Cat Mode (hidden easter egg — nine taps on the version row). Local-only
    // presentation state: never synced, never on the wire.
    @AppStorage(CatMode.unlockedDefaultsKey) private var catModeUnlocked = false
    @AppStorage(CatMode.enabledDefaultsKey) private var catModeEnabledStorage = false
    @AppStorage(CatMode.tapCountDefaultsKey) private var catModeTapCount = 0
    @State private var showCatModeUnlockedAlert = false

    private var catModeEnabled: Bool {
        CatMode.resolveEnabled(requestedEnabled: catModeEnabledStorage, unlocked: catModeUnlocked)
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        SettingsForm {
            Section {
                LabeledContent("Version", value: version)
                    .settingsAnchor("version")
                    // Hidden unlock gesture: nine taps here (a cat's nine
                    // lives) reveals Cat Mode below. No visible affordance
                    // before unlock.
                    .contentShape(Rectangle())
                    .onTapGesture { registerCatModeTap() }
                Link(destination: macAppURL) {
                    Label("GitHub — raiseCatError/MeowDisplay", systemImage: "link")
                }
                if catModeUnlocked {
                    Toggle(isOn: Binding(
                        get: { catModeEnabled },
                        set: { catModeEnabledStorage = CatMode.resolveEnabled(requestedEnabled: $0, unlocked: catModeUnlocked) })) {
                        Label("Cat Mode", systemImage: "pawprint.fill")
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Text("About")
                    if catModeEnabled {
                        Image(systemName: "pawprint.fill").accessibilityHidden(true)
                    }
                }
            }
            Section {
                Link(destination: macAppURL) {
                    Label("Get the Mac app", systemImage: "arrow.down.circle")
                }
            } footer: {
                Text("MeowDisplay needs the Mac app running on a Mac on the same cable or WiFi network. Download it here if you haven't yet.")
            }
        }
        .navigationTitle(MobileSettingsCategory.about.title)
        .alert("Cat Mode unlocked 🐾", isPresented: $showCatModeUnlockedAlert) {
            Button("Nice", role: .cancel) {}
        }
    }

    private func registerCatModeTap() {
        let result = CatMode.registerTap(tapCount: catModeTapCount, alreadyUnlocked: catModeUnlocked)
        catModeTapCount = result.tapCount
        if result.justUnlocked {
            catModeUnlocked = true
            showCatModeUnlockedAlert = true
        }
    }
}

// MARK: - Developer

#if DEBUG
private struct DeveloperSettingsPage: View {
    let receiver: StreamReceiver
    @AppStorage("notchDebugOverlay") private var notchDebugOverlayEnabled = false
    // Developer / Audio Diagnostics (receiver-side AAC investigation): a
    // physical iPhone's sandboxed UserDefaults can't receive a Mac
    // terminal's `defaults write`, so these need an in-app control during a
    // real on-device retest — see `StreamReceiver`'s matching keys, all read
    // fresh (never latched) so a toggle here takes effect immediately.
    @AppStorage("audioPlaybackPath") private var audioPlaybackPath = "pcmEngine"
    @AppStorage("audioPCMSchedulingMode") private var audioPCMSchedulingMode = "continuous"
    @AppStorage("audioReceiverLocalDecode") private var audioReceiverLocalDecode = false
    @AppStorage("audioReceiverDumpEnabled") private var audioReceiverDumpEnabled = false
    @AppStorage("audioAACIntegrityLogging") private var audioAACIntegrityLogging = false
    @AppStorage(CatMode.unlockedDefaultsKey) private var catModeUnlocked = false
    @AppStorage(CatMode.enabledDefaultsKey) private var catModeEnabledStorage = false
    @AppStorage(CatMode.tapCountDefaultsKey) private var catModeTapCount = 0

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Notch Debug Overlay", isOn: $notchDebugOverlayEnabled)
                    .settingsAnchor("notchDebug")
            } footer: {
                Text("Draws the computed unsafe/obstacle regions (red) and the raw vs. Avoid-Notch-adjusted Main Tray frame (yellow/green) directly over the stream.")
            }
            Section {
                LabeledContent("Production Codec", value: "AAC")
                Picker("Playback Path", selection: $audioPlaybackPath) {
                    Text("PCM Engine").tag("pcmEngine")
                    Text("Legacy SampleBuffer Renderer").tag("legacyRenderer")
                }
                .onChange(of: audioPlaybackPath) { path in
                    Log.info("audioTrace: playbackPath=\(path)")
                }
                .settingsAnchor("audioDiagnostics")
                Picker("PCM Scheduling", selection: $audioPCMSchedulingMode) {
                    Text("Continuous").tag("continuous")
                    Text("Precise Scheduled").tag("preciseScheduled")
                }
                .onChange(of: audioPCMSchedulingMode) { mode in
                    Log.info("audioTrace: audioPCMSchedulingMode=\(mode)")
                }
                Toggle("Receiver Local AAC Decode", isOn: $audioReceiverLocalDecode)
                    .onChange(of: audioReceiverLocalDecode) { enabled in
                        Log.info("audioTrace: audioReceiverLocalDecode=\(enabled)")
                    }
                Toggle("AAC Integrity Logging", isOn: $audioAACIntegrityLogging)
                    .onChange(of: audioAACIntegrityLogging) { enabled in
                        Log.info("audioTrace: audioAACIntegrityLogging=\(enabled)")
                    }
                Toggle("Audio Comparison Dump", isOn: $audioReceiverDumpEnabled)
                    .onChange(of: audioReceiverDumpEnabled) { enabled in
                        Log.info("audioTrace: audioReceiverDumpEnabled=\(enabled)")
                    }
                Button("Reset Audio Diagnostics", role: .destructive) {
                    audioPlaybackPath = "pcmEngine"
                    audioPCMSchedulingMode = "continuous"
                    audioReceiverLocalDecode = false
                    audioAACIntegrityLogging = false
                    audioReceiverDumpEnabled = false
                    Log.info("audioTrace: audio diagnostics reset to defaults")
                }
            } header: {
                Text("Audio Diagnostics")
            } footer: {
                Text("PCM Engine is the default production audio path: AAC is still the only thing sent over the network, decoded on this \(deviceKind) and played through AVAudioEngine. Legacy SampleBuffer Renderer is the older AVSampleBufferAudioRenderer path, kept as a fallback/reference. PCM Scheduling controls how PCM Engine schedules buffers: Continuous (default) chains them on the player's own timeline after one startup anchor; Precise Scheduled independently re-targets every buffer from its own capture timestamp — this reintroduces electrical/robotic noise and exists only for A/B comparison. Receiver Local AAC Decode independently decodes received AAC and logs decode anomalies (clipping, discontinuities, NaN/Inf). AAC Integrity Logging adds a periodic checksum you can compare against the Mac's own log for the same packet. Audio Comparison Dump writes ~5s of the locally-decoded audio to a file in this app's Documents folder (Files app → On My \(deviceKind) → MeowDisplay) once Local AAC Decode is also on. All diagnostics off by default; a fresh Audio Off→On or reconnect applies a change.")
            }
            Section {
                WakeTestingView()
            } header: {
                Text("Wake Testing")
            } footer: {
                Text("Sends a standard Wake-on-LAN magic packet to an already-paired Mac's last-learned local network address. Same-LAN only — this never uses Remote/Tailscale.")
            }
            Section {
                PromoteInteractiveWakeView(receiver: receiver)
            } header: {
                Text("Promote Interactive Wake")
            } footer: {
                Text("Manual diagnostic, not automated: asks the connected Mac to declare remote user activity, to test whether that promotes a dark/network wake into a full interactive wake.")
            }
            Section {
                Button("Reset Cat Mode", role: .destructive) {
                    catModeUnlocked = false
                    catModeEnabledStorage = false
                    catModeTapCount = 0
                }
            } header: {
                Text("Cat Mode")
            } footer: {
                Text("Re-locks the About/version row's nine-tap easter egg for retesting the unlock flow.")
            }
        }
        .navigationTitle(MobileSettingsCategory.developer.title)
    }
}
#endif
