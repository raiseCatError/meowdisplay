import SwiftUI
import AVFoundation
import UIKit
import Combine

/// "iPad" or "iPhone" — so UI copy names the device the user is holding.
@MainActor let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

/// Repository — hosts the Mac app download and explains the two-app setup.
/// MeowDisplay does not yet have its own landing-page domain, so this points
/// at the GitHub repo rather than a hosted site.
let macAppURL = URL(string: "https://github.com/raiseCatError/MeowDisplay")!

@main
struct OpenSidecarPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            ReceiverScreen()
        }
    }
}

// MARK: - Shake to open settings

extension Notification.Name {
    static let deviceDidShake = Notification.Name("deviceDidShake")
}

extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            NotificationCenter.default.post(name: .deviceDidShake, object: nil)
        }
        super.motionEnded(motion, with: event)
    }
}

// MARK: - Root screen

struct ReceiverScreen: View {
    @StateObject private var model = ReceiverModel()
    @StateObject private var versionGate = VersionGate()
    @StateObject private var controlStore = ReceiverControlStore()
    @State private var showSettings = false
    @State private var showPairedToast = false
    @State private var showOnboarding = false
    @State private var nagDismissed = false
    @State private var keyboardVisibleRect: CGRect?
    @State private var runtimeSafeInsets: ControlSafeInsets?
    // Physical notch side (see `PhysicalNotchSide`) derived from
    // `UIInterfaceOrientation`, not from comparing safe-area depths — a real
    // device can report equal leading/trailing insets despite a genuinely
    // single-sided physical notch (see that type's doc).
    @State private var physicalNotchSide: LandscapeTraySide?
    @State private var occupiedControlFrames: [CGRect] = []
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("metalRenderer") private var metalRenderer = false
    // First-run onboarding (issue #49): explain the Mac app is required.
    // Shown until either the user dismisses it or the device connects once.
    @AppStorage("hasConnectedBefore") private var hasConnectedBefore = false
    @AppStorage("onboardingDismissed") private var onboardingDismissed = false
    // M4: the native keyboard responder is focused only while this is true.
    @State private var keyboardActive = false
    // M4: "Zoom While Typing" — default ON (see SettingsView).
    @AppStorage("zoomWhileTyping") private var zoomWhileTyping = true

    private var haptics: ReceiverHaptics {
        ReceiverHaptics { controlStore.preferences.hapticsEnabled }
    }

    // Streaming = connected and the video format is known.
    private var isStreaming: Bool {
        model.receiver.connected && model.receiver.videoSize != .zero
    }

    /// Whether the receiver surface stays on screen. A temporary interruption
    /// (pause, recovery, a failed recovery awaiting a manual retry) keeps the
    /// user inside the same receiver session instead of flashing back to the
    /// idle/discovery screen between retries — the geometry the surface needs
    /// (`videoSize`) deliberately survives a disconnect.
    private var showsReceiverSurface: Bool {
        model.receiver.session.retainsReceiverSurface && model.receiver.videoSize != .zero
    }

    /// Input may only leave this device while the session is genuinely live.
    /// Folded into the existing master Allow Input gate rather than added as a
    /// second one, so the established OFF-transition cleanup in `VideoView`
    /// (`clearInputStateForPause`) also runs on every session interruption.
    private var inputReachesMac: Bool {
        model.receiver.session.allowsLiveInput && controlStore.preferences.allowInput
    }

    // The floating keyboard button is offered only while keyboard input can
    // actually reach the Mac: streaming, not paused, and the connected Mac
    // is new enough to understand `keyboard` wire messages. (Allow Input off
    // isn't observable from the receiver today — same as touch/pencil, the
    // Mac silently drops the input instead.)
    private var keyboardAvailable: Bool {
        isStreaming && model.receiver.session.allowsLiveInput && model.receiver.macSupportsKeyboardWire
    }

    // Below the force floor → present the blocking gate (issue #135). The
    // fullScreenCover binding's setter is a no-op so the user can't dismiss it.
    private var requiredUpdate: VersionGate.Update? {
        if case let .required(update) = versionGate.status { return update }
        return nil
    }

    // Soft nag: shown once per launch, dismissible.
    private var recommendedUpdate: VersionGate.Update? {
        if case let .recommended(update) = versionGate.status, !nagDismissed { return update }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            let proxySafeInsets = ControlSafeInsets(
                top: geo.safeAreaInsets.top,
                leading: geo.safeAreaInsets.leading,
                bottom: geo.safeAreaInsets.bottom,
                trailing: geo.safeAreaInsets.trailing)
            let effectiveSafeInsets = ControlSafeInsets.resolved(
                proxy: proxySafeInsets, runtime: runtimeSafeInsets)
            ZStack {
                if showsReceiverSurface {
                    ReceiverSafeAreaProbe { insets, notchSide in
                        runtimeSafeInsets = insets
                        physicalNotchSide = notchSide
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    Color.black.ignoresSafeArea()
                    VideoLayerView(displayLayer: model.receiver.displayLayer,
                                   receiver: model.receiver,
                                   useMetal: metalRenderer,
                                   zoomWhileTyping: zoomWhileTyping,
                                   keyboardRequested: keyboardActive,
                                   inputMode: controlStore.preferences.inputMode,
                                   trackpadSensitivity: controlStore.preferences.trackpadSensitivity,
                                   allowInput: inputReachesMac,
                                   videoEnabled: model.receiver.videoEnabled,
                                   showSurfaceGrid: controlStore.preferences.showSurfaceGrid,
                                   pinchTarget: controlStore.preferences.pinchTarget,
                                   rotateTarget: controlStore.preferences.rotateTarget,
                                   snapRotation: controlStore.preferences.snapRotation,
                                   appGestureCommands: controlStore.preferences.appGestureCommands,
                                   safeInsets: effectiveSafeInsets,
                                   occupiedControlFrames: occupiedControlFrames,
                                   onRotationSnap: { haptics.play(.selection) },
                                   onKeyboardVisibleRectChange: { keyboardVisibleRect = $0 })
                        .id(metalRenderer)   // rebuild the layer tree on toggle
                        .ignoresSafeArea()
                        // Allow Input OFF disables ALL touch/gesture
                        // delivery to the video layer in one place — no
                        // touch reaches `VideoView` or any of its gesture
                        // recognizers to begin with, covering direct touch,
                        // trackpad, clicks, drag, scroll, pinch and system
                        // gestures together (SETTINGS / ALLOW INPUT
                        // INVARIANTS). The Settings gear lives in
                        // `ReceiverControlOverlay`, a sibling view outside
                        // this hit-testing gate, so it stays reachable.
                        .allowsHitTesting(inputReachesMac)
                    if let interruption = model.receiver.session.interruption {
                        ReceiverInterruptionOverlay(interruption: interruption) {
                            model.receiver.reconnectNow()
                        } onBackToHome: {
                            model.receiver.disconnect()
                        }
                    }
                    if showAnalytics {
                        VStack {
                            Spacer()
                            PerfOverlay(stats: model.receiver.perf,
                                        videoSize: model.receiver.videoSize)
                                .padding(.bottom, 10)
                        }
                        .allowsHitTesting(false)   // never block touch input
                    }
                    RemoteKeyboardInputView(
                        isActive: $keyboardActive,
                        onCommitText: { model.receiver.sendKeyboardText($0) },
                        onSpecialPress: { model.receiver.sendKeyboardPress(usage: $0) },
                        onHardwareKeyDown: { usage, modifiers in
                            model.receiver.sendKeyboardDown(usage: usage, modifiers: modifiers)
                        },
                        onHardwareKeyUp: { usage, modifiers in
                            model.receiver.sendKeyboardUp(usage: usage, modifiers: modifiers)
                        },
                        onRequestDismiss: { keyboardActive = false }
                    )
                    .frame(width: 1, height: 1)
                    .opacity(0)
                    .allowsHitTesting(false)
                    ReceiverControlOverlay(
                        store: controlStore,
                        receiver: model.receiver,
                        keyboardActive: $keyboardActive,
                        showSettings: $showSettings,
                        keyboardAvailable: keyboardAvailable,
                        keyboardVisibleRect: keyboardVisibleRect,
                        containerSize: geo.size,
                        safeInsets: effectiveSafeInsets,
                        notchSide: physicalNotchSide,
                        haptics: haptics,
                        onOccupiedFramesChange: { occupiedControlFrames = $0 })
                } else {
                    IdleView(receiver: model.receiver, wakeConnect: model.wakeConnect, showSettings: $showSettings)
                }
            }
            .onAppear { model.receiver.setOrientation(portrait: geo.size.height > geo.size.width) }
            .onChange(of: geo.size) { size in
                model.receiver.setOrientation(portrait: size.height > size.width)
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView { onboardingDismissed = true }
            }
        }
        .ignoresSafeArea(edges: showsReceiverSurface ? .all : [])
        .statusBarHidden(showsReceiverSurface)
        .persistentSystemOverlays(showsReceiverSurface ? .hidden : .automatic)
        .sheet(isPresented: $showSettings) {
            SettingsView(receiver: model.receiver, controlStore: controlStore, haptics: haptics)
        }
        // One sheet for the whole secure pairing ceremony on every transport
        // (LAN, USB, Remote): SAS → waiting for the other device. The Remote
        // sheet owns the waiting presentation while its own attempt is running.
        .sheet(isPresented: Binding(
            get: {
                let prompt = model.receiver.pairingPrompt
                return prompt.pending != nil
                    || (prompt.confirmedLocally != nil && model.receiver.remotePairingState != .connecting)
            },
            set: { _ in }),
               onDismiss: { model.receiver.pairingPrompt.notePresentationDismissed() }) {
            PairingConfirmationSheet(prompt: model.receiver.pairingPrompt)
        }
        .onChange(of: model.receiver.pairingSuccessCount) { _ in
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation { showPairedToast = true }
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation { showPairedToast = false }
            }
        }
        .overlay(alignment: .top) {
            if showPairedToast { PairedToast().padding(.top, 12).transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .onChange(of: model.receiver.displayModeConfirmationGeneration) { _ in
            haptics.play(.confirmation)
        }
        // Below the force floor → blocking gate. Setter is a no-op: the user
        // cannot dismiss it, only update.
        .fullScreenCover(item: Binding(get: { requiredUpdate }, set: { _ in })) { update in
            UpdateRequiredView(update: update)
        }
        // At/above the floor but behind the recommended version → soft nag.
        .alert("Update available",
               isPresented: Binding(get: { recommendedUpdate != nil },
                                    set: { if !$0 { nagDismissed = true } })) {
            Button("Update") {
                if let update = recommendedUpdate { UIApplication.shared.open(update.url) }
            }
            Button("Later", role: .cancel) { nagDismissed = true }
        } message: {
            if let update = recommendedUpdate { Text(update.message) }
        }
        // Presentable before video ever starts — a headless Mac has no
        // physical display for the receiver to fall back on, so this is
        // the only place the choice can be made. "Use Extend" sends the
        // EXISTING `displayModeRequest`; the Mac remains authoritative for
        // the actual mode change.
        .alert("Mirror isn’t available",
               isPresented: Binding(get: { model.receiver.mirrorUnavailable }, set: { _ in })) {
            Button("Cancel", role: .cancel) {
                model.receiver.declineMirrorUnavailableOffer()
            }
            Button("Use Extend") {
                model.receiver.acceptMirrorUnavailableOffer()
            }
        } message: {
            Text("This Mac has no active physical display while its lid is closed. Use Extend to create a virtual display instead?")
        }
        // Distinct from the offer above: this fires when Mirror was
        // requested while ALREADY confirmed extending — the user is
        // already using Extend, so there is nothing to offer, only to
        // explain. Purely informational (one dismiss button, no wire
        // reply) — the Mac already stayed on Extend on its own.
        .alert("Mirror isn’t available",
               isPresented: Binding(get: { model.receiver.mirrorRejectedWhileExtending }, set: { _ in })) {
            Button("OK") { model.receiver.dismissMirrorRejection() }
        } message: {
            Text("Mirror requires an active physical display.")
        }
        .task { await versionGate.check() }
        // Merge the connected Mac's compatibility signal into the same gate.
        .onReceive(model.receiver.$peerSignal) { versionGate.applyPeer($0) }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
            haptics.play(.settings)
            showSettings = true
        }
        .onChange(of: scenePhase) { phase in
            Log.info("scenePhase -> \(String(describing: phase))")
            switch phase {
            case .active: model.sceneDidActivate()
            case .background: model.sceneDidBackground()
            default: break
            }
            // M4: never hold the keyboard responder while backgrounded.
            if phase != .active { keyboardActive = false }
        }
        // M4: close the keyboard the moment it stops being usable — peer too
        // old, capture paused, or the session ended.
        .onChange(of: keyboardAvailable) { available in
            if !available { keyboardActive = false }
        }
        // Allow Input OFF must close the keyboard responder too — it's the
        // one interactive element the video-layer hit-testing gate above
        // doesn't cover (it's activated programmatically, not by a touch
        // that gate would have blocked).
        .onChange(of: inputReachesMac) { allowed in
            #if DEBUG
            // Checkpoint A (SwiftUI side) — remove once root-caused.
            Log.info("inputTrace: controlStore.preferences.allowInput -> \(allowed) "
                     + "displayState=\(model.receiver.displayState)")
            #endif
            if !allowed { keyboardActive = false }
        }
        #if DEBUG
        .onAppear {
            Log.info("inputTrace: ReceiverScreen onAppear allowInput=\(controlStore.preferences.allowInput) "
                     + "displayState=\(model.receiver.displayState) connected=\(model.receiver.connected)")
        }
        #endif
        // The deliberate "screen off" signal: locking the device makes
        // protected data unavailable (a plain app switch doesn't). This is
        // what separates "put the iPhone to sleep — end the session now"
        // from "peeked at a message — keep the session alive".
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            Log.info("protected data will become unavailable (device locking)")
            model.deviceWillLock()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            Log.info("protected data available again (device unlocked)")
            model.deviceDidUnlock()
        }
        // Swiping the app away in the switcher (while we're still running)
        // grants a ~5s notice — enough for a clean goodbye so the Mac ends
        // the session at once. A kill without notice is covered Mac-side:
        // dead apps stop accepting redials, so the silence grace fires.
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.willTerminateNotification)) { _ in
            model.appWillTerminate()
        }
        .onChange(of: model.receiver.connected) { isConnected in
            // The first valid connection retires the onboarding hint for good.
            if isConnected {
                hasConnectedBefore = true
                showOnboarding = false
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.receiver.onReceiverUIPreferences = { update in
                controlStore.applyRemote(update)
            }
            controlStore.onInputResetRequested = {
                model.receiver.sendCancelActiveInput()
            }
            // The connected Mac is authoritative for input consent (a
            // security-relevant, Mac-owned decision) — its confirmed state
            // always wins over whatever this receiver had stored, so there
            // is exactly one source of truth once connected. See
            // `ReceiverControlStore.applySessionInputState`.
            model.receiver.onAllowInputStateChange = { state in
                controlStore.applySessionInputState(state)
            }
            model.receiver.setReceiverUIPreferencesForHello(
                trayEnabled: controlStore.preferences.trayEnabled,
                keyboardButtonEnabled: controlStore.preferences.keyboardButtonEnabled)
            model.receiver.announceReceiverPreferences(controlStore.preferences)
            model.receiver.primeAudioPreference(controlStore.preferences.audioPreferred)
            model.start()
            // Show the first-run hint unless the device has connected before
            // or the user already dismissed it.
            if !hasConnectedBefore && !onboardingDismissed {
                showOnboarding = true
            }
        }
        .onChange(of: controlStore.preferences) { preferences in
            model.receiver.setReceiverUIPreferencesForHello(
                trayEnabled: preferences.trayEnabled,
                keyboardButtonEnabled: preferences.keyboardButtonEnabled)
            model.receiver.announceReceiverPreferences(preferences)
        }
    }
}

/// UIKit remains authoritative for physical window safe-area insets even
/// while the streaming SwiftUI tree deliberately renders edge-to-edge.
/// `safeAreaInsetsDidChange` makes rotation updates immediate.
private struct ReceiverSafeAreaProbe: UIViewRepresentable {
    let onChange: (ControlSafeInsets, LandscapeTraySide?) -> Void

    func makeUIView(context: Context) -> SafeAreaProbeView {
        let view = SafeAreaProbeView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: SafeAreaProbeView, context: Context) {
        view.onChange = onChange
        view.publishIfNeeded()
    }

    final class SafeAreaProbeView: UIView {
        var onChange: ((ControlSafeInsets, LandscapeTraySide?) -> Void)?
        private var lastPublished: UIEdgeInsets?
        private var lastOrientation: UIInterfaceOrientation?

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            publishIfNeeded()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishIfNeeded()
        }

        func publishIfNeeded() {
            // The probe itself may be hosted in a zero/inset SwiftUI
            // representable. The window is the authoritative public source
            // for physical screen exclusions in current interface
            // coordinates, especially after landscape-side rotation.
            let insets = window?.safeAreaInsets ?? safeAreaInsets
            let orientation = window?.windowScene?.interfaceOrientation
            guard insets != lastPublished || orientation != lastOrientation else { return }
            lastPublished = insets
            lastOrientation = orientation
            let value = ControlSafeInsets(top: insets.top,
                                          leading: insets.left,
                                          bottom: insets.bottom,
                                          trailing: insets.right)
            let landscape: LandscapeInterfaceOrientation?
            switch orientation {
            case .landscapeLeft: landscape = .landscapeLeft
            case .landscapeRight: landscape = .landscapeRight
            default: landscape = nil
            }
            let notchSide = PhysicalNotchSide.forLandscape(landscape)
            // Avoid mutating SwiftUI state during representable updates.
            DispatchQueue.main.async { [weak self] in self?.onChange?(value, notchSide) }
            #if DEBUG
            Log.info("safeAreaTrace: window=\(String(describing: window?.bounds)) "
                     + "interfaceOrientation=\(String(describing: orientation)) insets=\(insets) "
                     + "notchSide=\(notchSide.map(String.init(describing:)) ?? "none")")
            #endif
        }
    }
}

// MARK: - Session interruption overlay

/// The one interruption presentation, shared by Pause, Reconnecting and
/// Connection Lost. Same card mechanics as the original Pause overlay — the
/// receiver context stays visible underneath, the user is never thrown back
/// to the idle screen, and two overlays can never stack because the session
/// state exposes at most one interruption at a time.
struct ReceiverInterruptionOverlay: View {
    let interruption: ReceiverSessionInterruption
    let onReconnect: () -> Void
    let onBackToHome: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if interruption == .reconnecting {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .padding(.bottom, 2)
            }
            Text(interruption.title)
                .font(.headline)
            Text(interruption.message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            if interruption.offersManualReconnect {
                Button("Reconnect", action: onReconnect)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 6)
            }
            // A stuck/failed/incompatible peer must not trap the user on
            // this screen forever — this cancels recovery for the current
            // target and returns to device selection without touching
            // pairing/trust (StreamReceiver.disconnect() below).
            if interruption.offersBackToHome {
                Button(interruption == .unrecoverable ? "Choose Another Mac" : "Back to Home", action: onBackToHome)
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .padding(.top, interruption.offersManualReconnect ? 0 : 6)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        // Failed/incompatible states now have something to tap too; only
        // pause and active reconnection must not swallow touches the
        // receiver surface below might still want.
        .allowsHitTesting(interruption.offersManualReconnect || interruption.offersBackToHome)
        .animation(.snappy(duration: 0.2), value: interruption)
    }
}

// MARK: - Overflow marquee

/// One-line text that only animates when it doesn't fit: it clips, pauses,
/// slowly scrolls to reveal the end, pauses, and scrolls back. Fitting text
/// is static. With Reduce Motion, overflowing text is shrunk slightly and
/// tail-truncated instead of animating. Non-interactive, so taps pass through
/// to the enclosing Button.
struct OverflowMarqueeText: View {
    private struct WidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    let text: String
    var font: Font = .subheadline.weight(.semibold)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    init(_ text: String) { self.text = text }

    private static let fadeWidth: CGFloat = 12

    /// Masks only the text (the button's own background is untouched). While
    /// scrolling, each edge fades in proportion to how far the text has moved
    /// off it, so the resting position stays fully opaque; otherwise the mask
    /// is a plain clip.
    @ViewBuilder
    private var edgeFadeMask: some View {
        if animates {
            let fade = Self.fadeWidth
            let left = Double(min(1, max(0, -offset / fade)))
            let right = Double(min(1, max(0, (overflow + offset) / fade)))
            HStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(1 - left), .black],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: fade)
                Rectangle()
                LinearGradient(colors: [.black, .black.opacity(1 - right)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: fade)
            }
        } else {
            Rectangle()
        }
    }

    private var overflow: CGFloat { max(0, textWidth - containerWidth) }
    private var animates: Bool { overflow > 1 && !reduceMotion }

    var body: some View {
        // Flexible base: takes the space offered, one line tall.
        Text(text)
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(reduceMotion ? 0.75 : 1)
            .opacity(reduceMotion ? 1 : 0)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: WidthKey.self, value: proxy.size.width)
            }.hidden())
            .onPreferenceChange(WidthKey.self) { containerWidth = $0 }
            .overlay(alignment: .leading) {
                if !reduceMotion {
                    Text(text)
                        .font(font)
                        .lineLimit(1)
                        .fixedSize()
                        .offset(x: offset)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: TextWidthKey.self, value: proxy.size.width)
                        })
                        .onPreferenceChange(TextWidthKey.self) { textWidth = $0 }
                }
            }
            .mask { edgeFadeMask }
            .accessibilityLabel(text)
            .task(id: animates ? overflow : 0) {
                offset = 0
                guard animates else { return }
                let duration = Double(overflow) / 24
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    guard !Task.isCancelled else { break }
                    withAnimation(.linear(duration: duration)) { offset = -overflow }
                    try? await Task.sleep(nanoseconds: UInt64((duration + 1.0) * 1_000_000_000))
                    guard !Task.isCancelled else { break }
                    withAnimation(.linear(duration: duration)) { offset = 0 }
                    try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                }
            }
    }

    private struct TextWidthKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }
}

// MARK: - Idle view (no Mac connected) — regular iOS look, follows light/dark

struct IdleView: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var wakeConnect: WakeConnectCoordinator
    @Binding var showSettings: Bool
    @State private var showRemoteAccessSetup = false
    @State private var showRemotePairing = false
    /// Persisted expand/collapse state of the Connection Instructions section.
    @AppStorage("home.connectionInstructionsExpanded") private var instructionsExpanded = true
    @State private var remoteEditPeerID: String?
    /// Bumped when remote details change so the (non-observable) store is re-read.
    @State private var remoteRefresh = 0
    // Cat Mode's only effect here: a purely decorative paw accent next to
    // the MeowDisplay wordmark. Reads straight from storage rather than
    // going through `CatMode.resolveEnabled` — this value is only ever
    // written by SettingsView's already-gated toggle, so it can't be true
    // while locked.
    @AppStorage(CatMode.enabledDefaultsKey) private var catModeEnabled = false

    var body: some View {
        GeometryReader { proxy in
            Group {
                if proxy.size.width > proxy.size.height {
                    landscapeLayout
                } else {
                    portraitLayout(minHeight: proxy.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: Binding(
            get: { showRemotePairing && receiver.pairingPrompt.pending == nil },
            set: { presented in
                guard !presented else { return }
                // Swipe-down while connecting cancels the real attempt. A sheet
                // hidden only because the SAS sheet took over (pending != nil)
                // must not cancel anything.
                guard receiver.pairingPrompt.pending == nil else { return }
                if receiver.remotePairingState == .connecting { receiver.cancelRemotePairing() }
                else { receiver.acknowledgeRemotePairingResult() }
                showRemotePairing = false
            }), onDismiss: { remoteRefresh += 1 }) {
            NavigationStack { RemotePairingView(receiver: receiver) }
                .presentationDetents([.medium, .large])
        }
        .onChange(of: receiver.remotePairingState) { new in
            // Success feedback is transport-independent (see the root view);
            // this only closes the Remote sheet once pairing truly finished.
            if new == .succeeded {
                showRemotePairing = false
                receiver.acknowledgeRemotePairingResult()
            }
        }
        .sheet(isPresented: $showRemoteAccessSetup, onDismiss: { remoteRefresh += 1 }) {
            NavigationStack {
                RemoteAccessSettingsView(receiver: receiver, initialPeerID: remoteEditPeerID)
            }
        }
    }

    /// Scrolls only when the content is taller than the screen; when it fits,
    /// `minHeight` keeps the Spacers distributing exactly as before.
    private func portraitLayout(minHeight: CGFloat) -> some View {
        ScrollView(showsIndicators: false) {
            portraitContent
                .frame(minHeight: minHeight)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var portraitContent: some View {
        VStack(spacing: 24) {
            Spacer()
            logo(width: 132)
            titleAndStatus
            autoReconnectToggle
            instructionsSection
            deviceSections
            Spacer()
            settingsButton
            tip.padding(.bottom, 8)
        }
        .padding()
    }

    /// Two fixed columns for landscape. Neither column scrolls as a whole;
    /// only the device sections scroll if they outgrow the space.
    private var landscapeLayout: some View {
        HStack(alignment: .top, spacing: 24) {
            // Left: brand + setup, vertically centered in the available height.
            VStack(spacing: 12) {
                Spacer(minLength: 0)
                if instructionsExpanded {
                    HStack(spacing: 14) {
                        logo(width: 76)
                        VStack(alignment: .leading, spacing: 4) {
                            brandTitle(font: .title.bold())
                            statusLine
                        }
                        Spacer(minLength: 0)
                    }
                } else {
                    // Freed space: larger, centered branding like portrait.
                    VStack(spacing: 8) {
                        logo(width: 104)
                        titleAndStatus(font: .title.bold())
                    }
                    .frame(maxWidth: .infinity)
                }
                autoReconnectToggle
                instructionsSection
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Right: devices fill the top, Settings & tip sit at the bottom.
            VStack(spacing: 12) {
                ScrollView { deviceSections.padding(.top, 12) }
                    .scrollBounceBehavior(.basedOnSize)
                settingsButton
                tip
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private func logo(width: CGFloat) -> some View {
        Image("MeowLogo")
            .resizable()
            .scaledToFit()
            .frame(width: width, height: width)
    }

    private func brandTitle(font: Font) -> some View {
        HStack(spacing: 6) {
            Text("MeowDisplay").font(font)
            if catModeEnabled {
                Image(systemName: "pawprint.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(receiver.connected ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            Text(receiver.status)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var titleAndStatus: some View { titleAndStatus(font: .largeTitle.bold()) }

    private func titleAndStatus(font: Font) -> some View {
        VStack(spacing: 6) {
            brandTitle(font: font)
            statusLine
            if let pairingStatus = receiver.pairingPrompt.status {
                Text(pairingStatus)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var autoReconnectToggle: some View {
        Toggle("Auto-Reconnect", isOn: $receiver.autoReconnectEnabled)
            .toggleStyle(.switch)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: 420)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12))
    }

    private var instructionsSection: some View {
        VStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { instructionsExpanded.toggle() }
            } label: {
                HStack {
                    Text("Connection Instructions")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: instructionsExpanded ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                }
                .foregroundStyle(instructionsExpanded ? HierarchicalShapeStyle.primary : .secondary)
                .padding(.horizontal, 4)
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(instructionsExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Double-tap to \(instructionsExpanded ? "collapse" : "expand")")

            if instructionsExpanded {
                instructionsCard
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: 420)
    }

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            instructionRow("cable.connector", "Plug in the USB cable and start the Mac app")
            instructionRow("wifi", "Or choose this \(deviceKind) under WiFi in the Mac app")
            instructionRow("play.circle", "Keep this app open — streaming starts automatically")
        }
        .font(.footnote)
        .padding(20)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16))
    }

    /// Fixed-width icon column so every row's text starts at the same x.
    private func instructionRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 28, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Device sections (shared by portrait and landscape)

    private var deviceSections: some View {
        VStack(alignment: .leading, spacing: 16) {
            nearbyDevices
            Button {
                showRemotePairing = true
            } label: {
                Label("Pair over Remote", systemImage: "network")
            }
            .buttonStyle(.bordered)
            .padding(.horizontal, 16)
            remoteAccess
        }
        .frame(maxWidth: 420)
    }

    private var nearbyDevices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nearby Devices").font(.headline)
            if receiver.discoveredMacs.isEmpty {
                Text("No devices nearby")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(receiver.discoveredMacs, id: \.endpoint) { result in
                    HStack {
                        Text(receiver.pairingMacName(result)).lineLimit(1)
                        Spacer()
                        if receiver.pairingMacIsPaired(result) {
                            if receiver.connected {
                                Text("Connected").foregroundStyle(.secondary)
                            } else {
                                // Trust and connectivity are different: a
                                // paired-but-not-currently-connected Mac
                                // that is visible right now must offer a
                                // way back in rather than a dead-end
                                // "Paired" label. A disconnected Mac is
                                // never dialing out on its own, so this
                                // can't just rearm our own listener
                                // (reconnectNow) — it asks the Mac,
                                // which is always the dialer, to
                                // actually start a session for us.
                                connectControl(for: result)
                            }
                        } else {
                            Button("Pair") { receiver.pairWithMac(result) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// Paired Macs that have a saved Remote endpoint, with display names.
    private var remoteMacs: [(peerID: String, displayName: String)] {
        _ = remoteRefresh
        let configured = Set(RemoteEndpointStore.allPeerIDs())
        return TrustStore.shared.pinnedPeers().filter { configured.contains($0.peerID) }
    }

    private var remoteAccess: some View {
        let macs = remoteMacs
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Remote Access").font(.headline)
                Spacer()
                if !macs.isEmpty {
                    // Section-level actions only; per-remote actions live on
                    // each row's own menu.
                    Menu {
                        Button("Remote Access Settings…") { presentRemoteSettings(peerID: nil) }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                    .accessibilityLabel("Remote Access options")
                }
            }
            if macs.isEmpty {
                Button {
                    presentRemoteSettings(peerID: nil)
                } label: {
                    Label("Set Up Remote Access", systemImage: "network")
                }
                .buttonStyle(.bordered)
            } else {
                ForEach(macs, id: \.peerID) { mac in
                    remoteRow(peerID: mac.peerID, name: mac.displayName)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func presentRemoteSettings(peerID: String?) {
        remoteEditPeerID = peerID
        showRemoteAccessSetup = true
    }

    /// One configured remote: name, its Wake & Connect action, and its own
    /// menu, all on the same row. Label follows P6: "Wake & Connect" only
    /// when a local LAN wake hint exists (never claims remote WoL);
    /// otherwise plain "Connect", which — via `connectPrimary(peerID:)` —
    /// rearms the local listener/Bonjour `cr` and knocks this one Mac only.
    @ViewBuilder
    private func remoteRow(peerID: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 10) {
            Text(name)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if receiver.connected {
                Text("Connected").foregroundStyle(.secondary)
            } else if wakeConnect.isRunning(forPeerID: peerID) {
                ProgressView().controlSize(.small)
                Button("Cancel") { wakeConnect.cancel() }
                    .font(.caption)
                    .buttonStyle(.borderless)
            } else {
                Button {
                    wakeConnect.begin(peerID: peerID)
                } label: {
                    OverflowMarqueeText(wakeConnect.failed(forPeerID: peerID) ? "Try Again" : "Connect")
                        .frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
            }
            Menu {
                Button("Edit Remote Details…") { presentRemoteSettings(peerID: peerID) }
                Button("Remove Remote Details", role: .destructive) {
                    RemoteEndpointStore.removeEndpoint(forPeerID: peerID)
                    remoteRefresh += 1
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel("Options for \(name)")
        }
        if !receiver.connected {
            Text(wakeConnect.isRunning(forPeerID: peerID) ? wakeConnect.statusLabel : remoteStatusText(peerID: peerID))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Label("Settings & Help", systemImage: "gearshape")
        }
        .buttonStyle(.bordered)
    }

    private var tip: some View {
        Text("Tip: shake the \(deviceKind) to open settings anytime")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
    }

    private func remoteStatusText(peerID: String) -> String {
        if let reason = wakeConnect.failureReason(forPeerID: peerID) {
            switch reason {
            case "timedOut": return "Connection timed out"
            case "cancelled": return "Cancelled"
            case "protocolIncompatible": return "Mac requires app update"
            case "peerForgotten": return "Mac pairing removed"
            default: return "Connection failed"
            }
        }
        switch receiver.session.phase {
        case .connecting, .reconnecting: return "Connecting…"
        case .reconnectFailed, .disconnected: return "Remote Mac isn't reachable yet"
        default: return "Remote endpoint unavailable"
        }
    }

    /// One-tap Wake & Connect when this specific paired Mac has a usable
    /// saved LAN wake hint (see `WakeConnectCoordinator`); a plain Connect
    /// otherwise, unchanged.
    @ViewBuilder
    private func connectControl(for result: NWBrowser.Result) -> some View {
        if let peerID = receiver.pairingMacPeerID(result) {
            if wakeConnect.isRunning(forPeerID: peerID) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(wakeConnect.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { wakeConnect.cancel() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            } else if WakeMetadataStore.metadata(forPeerID: peerID)?.broadcastAddress != nil {
                Button {
                    wakeConnect.begin(peerID: peerID)
                } label: {
                    OverflowMarqueeText(wakeConnect.failed(forPeerID: peerID) ? "Try Again" : "Wake & Connect")
                        .frame(minWidth: 88)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Connect") { receiver.requestConnect() }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            Button("Connect") { receiver.requestConnect() }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - First-run onboarding (the Mac app is required to connect)

/// Shown on first launch / while the device has never connected: MeowDisplay
/// is two apps, and the iOS side is useless without the Mac app running.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 56, weight: .light))
                        .foregroundStyle(.tint)
                        .padding(.top, 24)

                    VStack(spacing: 10) {
                        Text("One more app to go")
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text("MeowDisplay turns this \(deviceKind) into a second screen for your Mac — but it needs the **MeowDisplay Mac app** running on a Mac connected by the same USB cable or on the same WiFi network.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Label("Install the MeowDisplay Mac app on your Mac", systemImage: "1.circle.fill")
                        Label("Connect the \(deviceKind) by USB, or join the same WiFi", systemImage: "2.circle.fill")
                        Label("Keep this app open — streaming starts on its own", systemImage: "3.circle.fill")
                    }
                    .font(.subheadline)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 16))

                    Link(destination: macAppURL) {
                        Label("Get the Mac app", systemImage: "arrow.down.circle")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)

                    Text("You can find this link again anytime in Settings — shake the \(deviceKind) to open it.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("Welcome")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        onClose()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Settings / help sheet

struct SettingsView: View {
    @ObservedObject var receiver: StreamReceiver
    @ObservedObject var controlStore: ReceiverControlStore
    let haptics: ReceiverHaptics
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("metalRenderer") private var metalRenderer = false
    @AppStorage("zoomWhileTyping") private var zoomWhileTyping = true
    #if DEBUG
    @AppStorage("notchDebugOverlay") private var notchDebugOverlayEnabled = false
    // Developer / Audio Diagnostics (receiver-side AAC investigation): a
    // physical iPhone's sandboxed UserDefaults can't receive a Mac
    // terminal's `defaults write` the way a Simulator or a Mac-native app
    // can, so these need an in-app control to be usable during a real
    // on-device retest — see `StreamReceiver`'s matching keys, all read
    // fresh (never latched) so a toggle here takes effect immediately.
    @AppStorage("audioPlaybackPath") private var audioPlaybackPath = "pcmEngine"
    @AppStorage("audioPCMSchedulingMode") private var audioPCMSchedulingMode = "continuous"
    @AppStorage("audioReceiverLocalDecode") private var audioReceiverLocalDecode = false
    @AppStorage("audioReceiverDumpEnabled") private var audioReceiverDumpEnabled = false
    @AppStorage("audioAACIntegrityLogging") private var audioAACIntegrityLogging = false
    #endif
    @State private var confirmingReset = false
    @State private var confirmingFunctionTrayReset = false
    @State private var trustRefresh = 0
    @State private var forgetConfirmation = PeerForgetPrompt()

    // Cat Mode (hidden easter egg — nine taps on the About/version row
    // below). Local-only presentation state: never synced, never on the
    // wire. `catModeTapCount` intentionally isn't persisted — a relaunch
    // mid-tapping just resets the count, it's not meant to be a puzzle
    // across sessions.
    @AppStorage(CatMode.unlockedDefaultsKey) private var catModeUnlocked = false
    @AppStorage(CatMode.enabledDefaultsKey) private var catModeEnabledStorage = false
    @AppStorage(CatMode.tapCountDefaultsKey) private var catModeTapCount = 0
    @State private var showCatModeUnlockedAlert = false

    private var catModeEnabled: Bool {
        CatMode.resolveEnabled(requestedEnabled: catModeEnabledStorage, unlocked: catModeUnlocked)
    }

    private var catModeToggleBinding: Binding<Bool> {
        Binding(
            get: { catModeEnabled },
            set: { catModeEnabledStorage = CatMode.resolveEnabled(requestedEnabled: $0, unlocked: catModeUnlocked) }
        )
    }

    private func registerCatModeTap() {
        let result = CatMode.registerTap(tapCount: catModeTapCount, alreadyUnlocked: catModeUnlocked)
        catModeTapCount = result.tapCount
        if result.justUnlocked {
            catModeUnlocked = true
            showCatModeUnlockedAlert = true
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Paired Macs") {
                    let peers = TrustStore.shared.pinnedPeers()
                    if peers.isEmpty {
                        Text("No paired Macs").foregroundStyle(.secondary)
                    } else {
                        ForEach(peers, id: \.peerID) { peer in
                            HStack {
                                Text(peer.displayName)
                                Spacer()
                                Button("Forget", role: .destructive) {
                                    forgetConfirmation.request(peerID: peer.peerID, name: peer.displayName)
                                }
                            }
                        }
                    }
                }
                .id(trustRefresh)
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
                Section {
                    NavigationLink("Remote Access") {
                        RemoteAccessSettingsView(receiver: receiver)
                    }
                    .disabled(TrustStore.shared.pinnedPeers().isEmpty)
                }
                .id(trustRefresh)
                Section("Status") {
                    LabeledContent("Connection",
                                   value: receiver.connected ? receiver.status : receiver.canonicalPhaseTitle)
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
                    Toggle("Auto-Reconnect", isOn: $receiver.autoReconnectEnabled)
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Automatically reconnect to paired devices after connection interruptions. Turning this off only stops automatic reconnecting — Connect, Reconnect, and Wake & Connect still work, and an active session stays connected. Also shown on the Home screen.")
                }

                Section("Display") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Video", isOn: Binding(
                            get: { receiver.videoEnabled },
                            set: { receiver.requestVideoEnabled($0) }))
                            .disabled(!receiver.connected || !receiver.macSupportsVideoControl)
                        Text("Turning video off keeps the connection, keyboard, controls, and selected input mode active.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Toggle("Show Surface Grid", isOn: preferenceBinding(\.showSurfaceGrid))
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Avoid Notch", isOn: preferenceBinding(\.avoidNotch))
                        Text("Keeps controls clear of the iPhone’s notch or Dynamic Island in landscape.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Experimental")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
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
                                       value: receiver.connected ? "Waiting for Mac" : "Unavailable")
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Audio", isOn: Binding(
                            get: { controlStore.preferences.audioPreferred },
                            set: { value in
                                controlStore.update { $0.audioPreferred = value }
                                receiver.requestAudioEnabled(value)
                            }))
                            .disabled(!receiver.connected || !receiver.macSupportsAudio)
                        Text("Plays a copy of what the Mac is playing. It keeps playing there too — this never changes the Mac's output device.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
                        Text("Adjust if sound plays slightly before or after the picture.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button("Resync") {
                            receiver.resync()
                        }
                        .font(.footnote)
                        .disabled(!receiver.connected || !receiver.audioEnabled)
                        Text("If audio drifts or stutters, Resync re-establishes timing without reconnecting. It doesn't change your A/V Sync adjustment above.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!controlStore.preferences.audioPreferred)
                } header: {
                    Text("Audio")
                }

                Section {
                    // Isolated from the receiver: the Status section above
                    // re-renders on every stream update, and a TextField that
                    // rebuilds mid-tap loses focus (the "tap twice to edit"
                    // bug). This subview owns its focus and doesn't observe
                    // the receiver, so it survives those rebuilds.
                    DeviceNameField { receiver.setServiceName($0) }
                } header: {
                    Text("Name")
                } footer: {
                    Text("Shown in the Mac app's WiFi connection menu. iOS hides this \(deviceKind)'s real name from apps, so set it here once.")
                }

                Section {
                    Toggle("Zoom While Typing", isOn: $zoomWhileTyping)
                } header: {
                    Text("Keyboard")
                } footer: {
                    Text("Enlarge the area you're typing in when the keyboard is open.")
                }

                Section {
                    // Never optimistic: this only ever reflects the Mac's
                    // last CONFIRMED decision (`ReceiverControlStore.
                    // sessionInputState`) — tapping Request Control does not
                    // flip this label until the Mac actually replies.
                    LabeledContent("Control", value: controlStore.sessionInputState.receiverDisplayText)
                    switch controlStore.sessionInputState {
                    case .off, .notAllowed:
                        Button("Request Control") { receiver.requestAllowInput(true) }
                    case .requesting:
                        EmptyView()
                    case .allowed:
                        Button("Turn Off", role: .destructive) { receiver.requestAllowInput(false) }
                    case .requestsDisabled:
                        Text("This Mac isn't accepting control requests from this device right now. Enable it from the Mac's Input settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Input Mode", selection: preferenceBinding(\.inputMode)) {
                        ForEach(PointerInputMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(controlStore.preferences.inputMode.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                    Slider(value: preferenceBinding(\.trackpadSensitivity),
                           in: PointerGestureConfig.trackpadSensitivityRange, step: 0.1) {
                        Text("Trackpad Sensitivity")
                    } minimumValueLabel: {
                        Text("Slow")
                    } maximumValueLabel: {
                        Text("Fast")
                    }
                    .font(.footnote)
                } header: {
                    Text("Input")
                } footer: {
                    Text("Settings always stays reachable, even with input turned off. Sensitivity only affects Trackpad mode's one-finger pointer movement.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pinch / Zoom")
                        Picker("Pinch / Zoom", selection: preferenceBinding(\.pinchTarget)) {
                            ForEach(ReceiverGestureTarget.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if controlStore.preferences.pinchTarget == .app {
                            Text("Experimental app command mode")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rotation")
                        Picker("Rotation", selection: preferenceBinding(\.rotateTarget)) {
                            ForEach(ReceiverGestureTarget.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        if controlStore.preferences.rotateTarget == .app {
                            Text("Experimental app command mode")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Snap Rotation", isOn: preferenceBinding(\.snapRotation))
                    if controlStore.preferences.pinchTarget == .app || controlStore.preferences.rotateTarget == .app {
                        NavigationLink("App Gesture Commands") {
                            AppGestureCommandsView(store: controlStore)
                        }
                    }
                } header: {
                    Text("Gestures")
                } footer: {
                    Text("Video Off temporarily routes pinch and rotate to App without changing these saved choices. App mode is experimental: instead of injecting native gestures into the foreground app, it sends the keyboard commands configured in App Gesture Commands.")
                }

                Section("Receiver Controls") {
                    Toggle("Show Control Tray", isOn: preferenceBinding(\.trayEnabled))
                        .disabled(!controlStore.preferences.allowInput)
                    Toggle("Show Keyboard Button", isOn: preferenceBinding(\.keyboardButtonEnabled))
                    Toggle("Haptics", isOn: preferenceBinding(\.hapticsEnabled))
                    Toggle("Collapse Control Tray", isOn: preferenceBinding(\.trayCollapsed))
                    landscapeTraySidePicker
                    Picker("Active Profile", selection: Binding(
                        get: { controlStore.preferences.activeControlProfile },
                        set: { profile in
                            controlStore.update { $0.activeControlProfile = profile }
                            haptics.play(.profileChange)
                        })) {
                        ForEach(ControlProfileSlot.allCases) { Text($0.title).tag($0) }
                    }
                    NavigationLink("Edit Current Profile") {
                        ControlProfileEditor(store: controlStore, haptics: haptics)
                    }
                    Button("Reset Profile to Default", role: .destructive) {
                        confirmingReset = true
                    }
                }

                streamingProfileSection
                maxFPSSection

                Section {
                    Toggle("Show Function Tray", isOn: preferenceBinding(\.functionTrayEnabled))
                        .disabled(!controlStore.preferences.allowInput)
                    Picker("Function Tray Position",
                           selection: preferenceBinding(\.functionTrayPosition)) {
                        ForEach(FunctionTrayPosition.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Function Profile", selection: Binding(
                        get: { controlStore.preferences.activeFunctionTrayProfile },
                        set: { profile in
                            controlStore.update { $0.activeFunctionTrayProfile = profile }
                            haptics.play(.profileChange)
                        })) {
                        ForEach(ControlProfileSlot.allCases) { Text($0.title).tag($0) }
                    }
                    NavigationLink("Edit Function Tray") {
                        FunctionTrayProfileEditor(store: controlStore)
                    }
                    Button("Reset Function Tray to Default", role: .destructive) {
                        confirmingFunctionTrayReset = true
                    }
                } header: {
                    Text("Function Tray")
                } footer: {
                    Text("A second, independent tray of one-tap shortcuts (Undo, Redo, …), separate from the Main Tray above. \"Same Side\" groups it with the Main Tray; \"Opposite Side\" puts it on the other edge of the screen.")
                }

                Section {
                    Toggle("Performance overlay", isOn: $showAnalytics)
                    Toggle("Metal renderer (experimental)", isOn: $metalRenderer)
                } header: {
                    Text("Analytics")
                } footer: {
                    Text("The overlay shows FPS, bitrate, frame timing, stalls, and latency graphs at the bottom of the screen while streaming. The experimental Metal renderer decodes and presents frames manually — it adds decode and true on-glass latency metrics to the overlay, but in our measurements the system video layer displays frames faster. Leave it off unless you're debugging.")
                }

                Section {
                    Button("Open iOS Settings for MeowDisplay") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("WiFi mode needs Local Network access. If your Mac can't find this \(deviceKind), enable it under Settings → Privacy & Security → Local Network → MeowDisplay. USB mode works without it.")
                }

                Section {
                    NavigationLink {
                        DiagnosticsLogView()
                    } label: {
                        Label("Connection log", systemImage: "doc.text.magnifyingglass")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("What this \(deviceKind) saw while connecting: sessions, restarts, decoder trouble. No screen content and nothing leaves the \(deviceKind) unless you share it. Attach it to a GitHub issue if a connection won't come up.")
                }

                #if DEBUG
                Section {
                    Toggle("Notch Debug Overlay", isOn: $notchDebugOverlayEnabled)
                } header: {
                    Text("Developer")
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
                    Text("Developer — Audio Diagnostics")
                } footer: {
                    Text("PCM Engine is the default production audio path: AAC is still the only thing sent over the network, decoded on this \(deviceKind) and played through AVAudioEngine. Legacy SampleBuffer Renderer is the older AVSampleBufferAudioRenderer path, kept as a fallback/reference. PCM Scheduling controls how PCM Engine schedules buffers: Continuous (default) chains them on the player's own timeline after one startup anchor; Precise Scheduled independently re-targets every buffer from its own capture timestamp — this reintroduces electrical/robotic noise and exists only for A/B comparison. Receiver Local AAC Decode independently decodes received AAC and logs decode anomalies (clipping, discontinuities, NaN/Inf). AAC Integrity Logging adds a periodic checksum you can compare against the Mac's own log for the same packet. Audio Comparison Dump writes ~5s of the locally-decoded audio to a file in this app's Documents folder (Files app → On My \(deviceKind) → MeowDisplay) once Local AAC Decode is also on. All diagnostics off by default; a fresh Audio Off→On or reconnect applies a change.")
                }
                #endif

                #if DEBUG
                Section {
                    WakeTestingView()
                } header: {
                    Text("Developer — Wake Testing")
                } footer: {
                    Text("Sends a standard Wake-on-LAN magic packet to an already-paired Mac's last-learned local network address. Same-LAN only — this never uses Remote/Tailscale.")
                }
                Section {
                    PromoteInteractiveWakeView(receiver: receiver)
                } header: {
                    Text("Developer — Promote Interactive Wake")
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
                    Text("Developer — Cat Mode")
                } footer: {
                    Text("Re-locks the About/version row's nine-tap easter egg for retesting the unlock flow.")
                }
                #endif

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

                Section {
                    Link(destination: macAppURL) {
                        Label("Get the Mac app", systemImage: "arrow.down.circle")
                    }
                } footer: {
                    Text("MeowDisplay needs the Mac app running on a Mac on the same cable or WiFi network. Download it here if you haven't yet.")
                }

                Section {
                    LabeledContent("Version", value: version)
                        // Hidden unlock gesture: nine taps here (a cat's
                        // nine lives) reveals Cat Mode below. No visible
                        // affordance before unlock — this reads like an
                        // ordinary, non-interactive detail row.
                        .contentShape(Rectangle())
                        .onTapGesture { registerCatModeTap() }
                    Link(destination: macAppURL) {
                        Label("GitHub — raiseCatError/MeowDisplay", systemImage: "link")
                    }
                    if catModeUnlocked {
                        Toggle(isOn: catModeToggleBinding) {
                            Label("Cat Mode", systemImage: "pawprint.fill")
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("About")
                        if catModeEnabled {
                            Image(systemName: "pawprint.fill")
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
            .navigationTitle("MeowDisplay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Cat Mode unlocked 🐾", isPresented: $showCatModeUnlockedAlert) {
                Button("Nice", role: .cancel) {}
            }
        }
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
                Text("No displays reported.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.displays, id: \.uuid) { display in
                    Button {
                        receiver.requestMirrorDisplaySelection(display.uuid)
                    } label: {
                        HStack {
                            Text(display.isMain ? "\(display.name) (Main)" : display.name)
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
    /// always tracks `confirmedExtendShape`/`pendingExtendShape`, the same
    /// request/confirm contract as `requestDisplayMode` above.
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
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } else {
            LabeledContent("Extend Shape", value: receiver.connected ? "Waiting for Mac" : "Unavailable")
        }
    }

    /// PART 5/6 exact user-facing text, re-sent by the Mac on every capture
    /// (re)start — including right after an Extend shape change — so this
    /// updates with the picker rather than needing a manual refresh.
    /// Derived entirely from `receiver.lastMaxFPSState` (the Mac's own
    /// `EncoderCapability`/`StreamingFPSPolicy` result for the CURRENT final
    /// encode size), never guessed from the shape/ratio alone. Nil (no text)
    /// when nothing is actually limiting the request below what was asked.
    private var fpsLimitationText: String? {
        guard let state = receiver.lastMaxFPSState else { return nil }
        if state.encoderSafeFPS >= state.requestedFPS {
            return nil
        }
        return "\(receiver.streamingProfile.label) requests \(state.requestedFPS) FPS. "
            + "Limited to \(state.encoderSafeFPS) FPS at this display size."
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
            Text(receiver.streamingProfile.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
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
            Text(receiver.streamingPriority.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// PART 2/3/4/6: receiver-enforced max-FPS control, request/confirm-aware
    /// same as `extendShapePicker` above — disabled while a request is in
    /// flight, and the picker only offers tiers `receiver.lastMaxFPSState`
    /// (the Mac's own capability/encoder calculation) says are actually
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
                    if current.enabled {
                        let tiers = receiver.lastMaxFPSState?.availableTiers ?? EncoderCapability.supportedFPSTiers
                        Picker("Maximum FPS", selection: Binding(
                            get: { current.maxFPS },
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
                    LabeledContent("Maximum FPS", value: receiver.connected ? "Waiting for Mac" : "Unavailable")
                }
            } footer: {
                Text("Caps how fast this Mac streams to this device, on top of its normal profile/display limits.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var landscapeTraySidePicker: some View {
        Picker("Landscape Tray Side", selection: preferenceBinding(\.preferredLandscapeSide)) {
            ForEach(LandscapeTraySide.allCases) { side in
                Text(side.title).tag(side)
            }
        }
        .pickerStyle(.segmented)
    }

    private func preferenceBinding<Value>(_ keyPath: WritableKeyPath<ReceiverControlPreferences, Value>) -> Binding<Value> {
        Binding(get: { controlStore.preferences[keyPath: keyPath] },
                set: { value in controlStore.update { $0[keyPath: keyPath] = value } })
    }

    private func avSyncOffsetLabel(_ ms: Int) -> String {
        ms == 0 ? "0 ms" : (ms > 0 ? "+\(ms) ms" : "\(ms) ms")
    }
}

/// The device-name editor, deliberately kept out of any high-frequency
/// @ObservedObject so streaming updates can't rebuild it and steal focus.
private struct DeviceNameField: View {
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

/// The receiver decode ceiling this build advertises via
/// `hello.maxEncodeWide/High` (PROTOCOL.md 6.5). iOS has no public API that
/// reports the VideoToolbox H.264 hardware decoder's actual pixel ceiling,
/// so this is a conservative, well-documented number rather than a measured
/// one — the same value `MacReceiver` already advertises for the same
/// reason. Every A9-or-later Apple Silicon chip (iPhone 6s onward, the
/// floor for this app's iOS 16.4 deployment target) decodes H.264 up to 4K
/// (4096x2304) reliably; this deliberately does NOT report a panel's own
/// physical resolution, which says nothing about decode headroom. Isolated
/// here so a future measured-per-device capability can replace it without
/// touching call sites.
enum iOSDecodeCeiling {
    static let maxEncodeWide = 4096
    static let maxEncodeHigh = 2304
}

// MARK: - Model

@MainActor
final class ReceiverModel: ObservableObject {
    let receiver: StreamReceiver
    let wakeConnect: WakeConnectCoordinator
    private var started = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        // maximumFramesPerSecond reports this specific screen's real
        // hardware ceiling (60 on a standard panel, up to 120 on ProMotion)
        // — never assume every iPhone is 120Hz (high-refresh milestone).
        receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                  deviceKind: deviceKind,
                                  fallbackServiceName: UIDevice.current.name,
                                  maxEncodeWide: iOSDecodeCeiling.maxEncodeWide,
                                  maxEncodeHigh: iOSDecodeCeiling.maxEncodeHigh,
                                  maxFPS: UIScreen.main.maximumFramesPerSecond)
        wakeConnect = WakeConnectCoordinator(receiver: receiver)
        // Announce the native panel size to the Mac.
        let native = UIScreen.main.nativeBounds.size   // portrait pixels
        receiver.setNativePanel(long: Int(max(native.width, native.height)),
                                short: Int(min(native.width, native.height)),
                                scale: Double(UIScreen.main.nativeScale))
        let savedName = UserDefaults.standard.string(forKey: "deviceName")
        receiver.serviceName = (savedName?.isEmpty == false) ? savedName! : UIDevice.current.name
        receiver.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func start() {
        guard !started else { return }
        started = true
        receiver.start()
    }

    // MARK: - Lock vs app switch vs app quit

    // A plain app switch keeps the session (and the Mac's virtual display,
    // and therefore the user's window arrangement) alive INDEFINITELY. The
    // assertion buys ~30s of live pings; after iOS suspends us the kernel
    // still accepts the Mac's redials, so the session survives untouched
    // until we return. Only a device lock (deliberate "screen off") or the
    // app being quit ends the session. Known hole: a lock that happens
    // after we're already suspended is undetectable — no code runs and the
    // kernel behaves identically — so the display stays up until the user
    // returns or the app dies.
    private var backgroundToken: UIBackgroundTaskIdentifier = .invalid

    func sceneDidBackground() {
        // Known limitation: lock detection rides the protected-data signal,
        // which only fires when a passcode is set AND "Require Passcode" is
        // Immediately (the Face ID default). Other configurations make a
        // lock indistinguishable from an app switch, so those keep the
        // session like a backgrounded app would.
        if !UIApplication.shared.isProtectedDataAvailable {
            // Backgrounded because the device locked, not an app switch.
            Log.info("backgrounded by device lock — sleeping now")
            goToSleep()
            return
        }
        Log.info("app switched away — keeping the session, rendering paused")
        beginBackgroundAssertion()
        receiver.setRenderingPaused(true)
        // iOS will suspend us shortly; an automatic recovery run cannot make
        // progress there, so park it rather than let it burn its budget and
        // land in Connection Lost while the phone was simply in a pocket.
        receiver.setAppActive(false)
    }

    func sceneDidActivate() {
        endBackgroundAssertion()
        receiver.setRenderingPaused(false)
        receiver.ensureListening()
        // Resume a parked recovery run from where it stopped. If the session
        // is healthy this is a no-op; if it is beyond recovery the session
        // state already settled into its failed/disconnected phase.
        receiver.setAppActive(true)
    }

    func deviceWillLock() {
        Log.info("device locking — sleeping now")
        goToSleep()
    }

    /// Unlock arrives via the protected-data notification, which also fires
    /// when the user unlocks into ANOTHER app while we sit in the background
    /// — don't re-arm the listener or unpause rendering off-screen there;
    /// the real return still comes through scenePhase.
    func deviceDidUnlock() {
        guard UIApplication.shared.applicationState == .active else {
            Log.info("unlocked while backgrounded — staying dormant")
            return
        }
        sceneDidActivate()
    }

    /// User swiped the app away (or iOS terminates us while still running):
    /// ~5s of runtime remain, plenty for the "closing" goodbye that lets the
    /// Mac end the session immediately instead of after its silence grace.
    func appWillTerminate() {
        Log.info("app terminating — closing session")
        receiver.shutDown()
    }

    private func goToSleep() {
        receiver.enterSleep { [weak self] in
            DispatchQueue.main.async { self?.endBackgroundAssertion() }
        }
    }

    private func beginBackgroundAssertion() {
        guard backgroundToken == .invalid else { return }
        backgroundToken = UIApplication.shared.beginBackgroundTask { [weak self] in
            // Suspension takes us now; the session stays up by design (the
            // kernel keeps accepting for us) — just release the assertion.
            self?.endBackgroundAssertion()
        }
    }

    private func endBackgroundAssertion() {
        guard backgroundToken != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundToken)
        backgroundToken = .invalid
    }
}

// MARK: - Touch sampling

extension UIEvent {
    /// Every position UIKit recorded for `touch` in this update, oldest first.
    ///
    /// The panel samples faster than UIKit delivers, so a single `touchesMoved`
    /// stands for several real positions. This batch is that whole history and
    /// its *last* entry is `touch` itself, so forward the list as it comes:
    /// sending `touch` alongside it puts the newest sample ahead of its own
    /// history and emits it twice, which reads as backtracking on fast strokes.
    /// Falls back to the touch alone when UIKit coalesced nothing.
    func samples(for touch: UITouch) -> [UITouch] {
        let batch = coalescedTouches(for: touch) ?? []
        return batch.isEmpty ? [touch] : batch
    }
}

// MARK: - Video layer host view

/// UIView whose backing layer is the AVSampleBufferDisplayLayer.
/// Forwards touches as normalized video-space coordinates (touchscreen mode).
struct VideoLayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer
    let receiver: StreamReceiver
    let useMetal: Bool
    /// M4: the "Zoom While Typing" preference — always enlarges around the
    /// last touch when the keyboard opens if true; pans (never zooms) if
    /// false. Either way the typing area still ends up visible.
    let zoomWhileTyping: Bool
    /// M4: mirrors `ReceiverScreen`'s `keyboardActive` — VideoView only
    /// reacts to keyboard-frame notifications while this is true, so a
    /// keyboard opened for an unrelated text field elsewhere in the app
    /// (e.g. the Settings sheet's device name field, presented over the
    /// still-live stream) can never zoom/pan the remote display.
    let keyboardRequested: Bool
    /// The primary one-finger pointer model — see `PointerInputMode`.
    let inputMode: PointerInputMode
    /// Linear multiplier on Trackpad's primary one-finger relative delta —
    /// see `PointerGestureConfig.trackpadSensitivityRange`.
    let trackpadSensitivity: Double
    /// Master remote-input gate (SETTINGS / ALLOW INPUT INVARIANTS). Belt-
    /// and-suspenders alongside the `.allowsHitTesting` gate `ReceiverScreen`
    /// applies to this whole view: that gate stops new touches from ever
    /// reaching here, but can't retroactively silence a timer already
    /// scheduled (e.g. a buffered tap-chain flush) — only an explicit
    /// cancellation on the OFF transition (see `setAllowInput`) does that.
    let allowInput: Bool
    /// Mac-confirmed capture/encode/transmit state. The UIKit host stays live
    /// while this is false because it is also the mapped input surface.
    let videoEnabled: Bool
    let showSurfaceGrid: Bool
    let pinchTarget: ReceiverGestureTarget
    let rotateTarget: ReceiverGestureTarget
    let snapRotation: Bool
    let appGestureCommands: AppGestureCommands
    let safeInsets: ControlSafeInsets
    let occupiedControlFrames: [CGRect]
    let onRotationSnap: () -> Void
    let onKeyboardVisibleRectChange: (CGRect?) -> Void

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        view.receiver = receiver
        view.setZoomWhileTyping(zoomWhileTyping)
        view.setKeyboardRequested(keyboardRequested)
        view.setInputMode(inputMode)
        view.setTrackpadSensitivity(trackpadSensitivity)
        view.setAllowInput(allowInput)
        view.setVideoEnabled(videoEnabled, showGrid: showSurfaceGrid)
        view.setSurfaceContext(safeInsets: safeInsets, occupiedControlFrames: occupiedControlFrames)
        view.setGesturePreferences(pinchTarget: pinchTarget, rotateTarget: rotateTarget,
                                   snapRotation: snapRotation, appGestureCommands: appGestureCommands,
                                   onRotationSnap: onRotationSnap)
        view.onKeyboardVisibleRectChange = onKeyboardVisibleRectChange
        receiver.onDisplayStateChange = { [weak view] state in
            if state == .paused { view?.clearInputStateForPause() }
        }
        if receiver.displayState == .paused { view.clearInputStateForPause() }

        Log.info("video view: metal=\(useMetal)")
        if useMetal, let renderer = MetalVideoRenderer() {
            Log.info("metal renderer active")
            view.metalRenderer = renderer
            view.installVideoLayer(renderer.metalLayer)
            receiver.onDecodedFrame = { [weak renderer] pixelBuffer, captureMs in
                renderer?.render(pixelBuffer, captureMs: captureMs)
            }
            renderer.onPresented = { [weak receiver] presentedTime, captureMs in
                receiver?.recordPresented(presentedTime: presentedTime, captureMs: captureMs)
            }
        } else {
            receiver.onDecodedFrame = nil   // route frames back to AVSBDL
            view.installVideoLayer(displayLayer)
        }

        view.inputEngine.normalize = { [weak view] point in view?.normalized(point) }
        view.inputEngine.onPencil = { [weak receiver, weak view] phase, x, y, pressure, azimuth, altitude in
            // M4 typing-focus anchor: a real pencil touch-down counts as a
            // meaningful primary interaction; hover does not (PRODUCT RULE).
            if phase == "down" { view?.noteAnchorFromNormalized(x: x, y: y) }
            receiver?.sendPencil(phase: phase, x: x, y: y,
                                 pressure: pressure, azimuth: azimuth,
                                 altitude: altitude)
        }
        view.inputEngine.onProximity = { [weak receiver] entering, x, y in
            receiver?.sendProximity(entering: entering, x: x, y: y)
        }
        view.inputEngine.install(on: view)

        let threeFingerPan = UIPanGestureRecognizer(
            target: view, action: #selector(VideoView.didThreeFingerSystemPan(_:)))
        threeFingerPan.minimumNumberOfTouches = 3
        threeFingerPan.maximumNumberOfTouches = 3
        threeFingerPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        threeFingerPan.cancelsTouchesInView = false
        threeFingerPan.delegate = view
        view.threeFingerPanRecognizer = threeFingerPan
        view.addGestureRecognizer(threeFingerPan)

        let threeFingerTap = ThreeFingerTapGestureRecognizer(
            target: view, action: #selector(VideoView.didThreeFingerSystemTap(_:)))
        threeFingerTap.delegate = view
        view.threeFingerTapRecognizer = threeFingerTap
        view.addGestureRecognizer(threeFingerTap)

        let pinchSpreadGesture = PinchSpreadSystemGestureRecognizer(
            target: view, action: #selector(VideoView.didPinchSpreadSystemGesture(_:)))
        pinchSpreadGesture.delegate = view
        view.pinchSpreadGestureRecognizer = pinchSpreadGesture
        view.addGestureRecognizer(pinchSpreadGesture)

        // The single owner of every two-finger gesture: remote scroll,
        // local viewport pinch-zoom, and (once a pinch/zoom session is
        // under way) local viewport pan — see the type doc for why this
        // is one recognizer rather than two racing ones.
        let twoFinger = TwoFingerViewportGestureRecognizer(
            target: view, action: #selector(VideoView.didTwoFingerGesture(_:)))
        twoFinger.delegate = view
        view.twoFingerRecognizer = twoFinger
        view.addGestureRecognizer(twoFinger)

        // Two-finger double-tap resets manual zoom/pan. `require(toFail:)`
        // isn't needed against the pan/pinch recognizer above — it needs
        // real movement to begin, which a tap by definition doesn't have —
        // but a *future* single two-finger tap (right-click) recognizer
        // should `require(toFail: viewportDoubleTap)` so a fast double-tap
        // is never swallowed as two single taps.
        let viewportDoubleTap = UITapGestureRecognizer(
            target: view, action: #selector(VideoView.didViewportDoubleTap(_:)))
        viewportDoubleTap.numberOfTapsRequired = 2
        viewportDoubleTap.numberOfTouchesRequired = 2
        viewportDoubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        viewportDoubleTap.cancelsTouchesInView = false
        viewportDoubleTap.delegate = view
        view.viewportDoubleTapRecognizer = viewportDoubleTap
        view.addGestureRecognizer(viewportDoubleTap)

        // Local cursor echo: position updates ride the ~2ms control path
        // instead of the ~30ms video path, so the pointer feels native.
        receiver.onCursor = { [weak view] x, y, visible in
            view?.moveCursor(x: x, y: y, visible: visible)
        }
        receiver.onCursorImage = { [weak view] image, anchor, normSize in
            view?.setCursorSprite(image, anchor: anchor, normSize: normSize)
        }
        // Replay the sprite/position that arrived before this view existed
        // (first frames land after the connect-time sprite) or that the
        // previous view held (metal-renderer toggle rebuilds the view tree).
        if let sprite = receiver.cursorSprite {
            view.setCursorSprite(sprite.image, anchor: sprite.anchor, normSize: sprite.normSize)
        }
        let state = receiver.cursorState
        view.moveCursor(x: state.x, y: state.y, visible: state.visible)
        return view
    }

    func updateUIView(_ uiView: VideoView, context: Context) {
        uiView.setZoomWhileTyping(zoomWhileTyping)
        uiView.setKeyboardRequested(keyboardRequested)
        uiView.setInputMode(inputMode)
        uiView.setTrackpadSensitivity(trackpadSensitivity)
        uiView.setAllowInput(allowInput)
        uiView.setVideoEnabled(videoEnabled, showGrid: showSurfaceGrid)
        uiView.setSurfaceContext(safeInsets: safeInsets, occupiedControlFrames: occupiedControlFrames)
        uiView.setGesturePreferences(pinchTarget: pinchTarget, rotateTarget: rotateTarget,
                                     snapRotation: snapRotation, appGestureCommands: appGestureCommands,
                                     onRotationSnap: onRotationSnap)
        uiView.onKeyboardVisibleRectChange = onKeyboardVisibleRectChange
        // videoSize arrives after the format description — re-fit the layers.
        uiView.setNeedsLayout()
    }

    /// The view can be torn down without an explicit pause/disconnect
    /// notification ever reaching it first (e.g. `isStreaming` itself
    /// flips false and SwiftUI removes the whole subtree). A `CADisplayLink`
    /// retains its target and keeps firing every frame until invalidated —
    /// unlike the pointer engine's one-shot `DispatchWorkItem` timers, a
    /// live momentum session left running here would leak the view AND
    /// keep sending scroll deltas into a connection nobody is using
    /// anymore, so this MUST invalidate it directly rather than rely on
    /// deinit.
    static func dismantleUIView(_ uiView: VideoView, coordinator: ()) {
        uiView.clearInputStateForPause()
    }

    final class VideoView: UIView, UIGestureRecognizerDelegate {
        weak var receiver: StreamReceiver?
        var metalRenderer: MetalVideoRenderer?
        let inputEngine = InputCaptureEngine()
        fileprivate var twoFingerRecognizer: TwoFingerViewportGestureRecognizer?
        fileprivate var threeFingerPanRecognizer: UIPanGestureRecognizer?
        fileprivate var threeFingerTapRecognizer: ThreeFingerTapGestureRecognizer?
        fileprivate var pinchSpreadGestureRecognizer: PinchSpreadSystemGestureRecognizer?
        fileprivate var viewportDoubleTapRecognizer: UITapGestureRecognizer?

        // Hosts the presentation layer so zoom/pan geometry is applied in one
        // place. Whatever the remote aspect ratio does not fill stays the
        // view's black background — no mirrored, blurred letterbox fill.
        private let videoContentView = UIView()
        private var videoLayer: CALayer?
        private let surfaceLayer = CAShapeLayer()
        private let surfaceGridLayer = CAShapeLayer()
        private var videoEnabled = true
        private var showSurfaceGrid = true
        private var surfaceSafeInsets = ControlSafeInsets.zero
        private var occupiedControlFrames: [CGRect] = []
        #if DEBUG
        private var lastLoggedTrackpadRect: CGRect?
        #endif
        private var surfaceAdmission = SurfaceTouchAdmission<ObjectIdentifier>()
        private var pinchTarget = ReceiverGestureTarget.viewport
        private var rotateTarget = ReceiverGestureTarget.viewport
        private var snapRotation = true
        private var onRotationSnap: (() -> Void)?
        private var engagedSnapQuarter: Int?
        private var appGestureCommands = AppGestureCommands.defaults
        private var appMagnifyActive = false
        private var appRotateActive = false
        private var lastAppScaleRatio: CGFloat = 1
        private var lastAppRotation: CGFloat = 0
        // Discrete App Gesture Command routing (spec H/I) — one deterministic
        // path, never alongside continuous native gesture injection. Separate
        // accumulators so pinch and rotation repeat independently.
        private var pinchCommandAccumulator = AppGestureCommandRouting.makePinchAccumulator()
        private var rotationCommandAccumulator = AppGestureCommandRouting.makeRotationAccumulator()

        private let cursorLayer: CALayer = {
            let layer = CALayer()
            layer.isHidden = true
            layer.zPosition = 10
            // Position updates arrive at 120Hz — implicit animations would
            // smear the cursor behind every move.
            layer.actions = ["position": NSNull(), "contents": NSNull(),
                             "bounds": NSNull(), "hidden": NSNull()]
            return layer
        }()
        private var cursorNormSize = CGSize.zero
        private var cursorNorm = CGPoint(x: 0.5, y: 0.5)
        private var cursorVisible = false

        private var lastLoggedLayout = ""

        // MARK: - M4 keyboard presentation

        // The authoritative transform for this layout pass — rendering
        // (content layer geometry, cursor position) and input mapping
        // (normalized()) both derive from this single value so they can
        // never independently drift out of sync.
        private var currentTransform = RemoteViewportTransform.invalid
        // The "Zoom While Typing" preference; set from SwiftUI.
        private var zoomWhileTypingEnabled = true
        // Whether *our* keyboard is the one that might be open — gates
        // keyboardWillChangeFrame so an unrelated keyboard elsewhere in the
        // app (e.g. the Settings sheet's device name field, presented over
        // the still-live stream) can never zoom/pan the remote display.
        private var keyboardRequested = false
        // Non-nil sub-rect of `bounds`, above the keyboard (including its
        // accessory view), while our keyboard is open and docked at the
        // bottom; nil whenever the keyboard is closed or not ours.
        private var keyboardVisibleRect: CGRect?
        var onKeyboardVisibleRectChange: ((CGRect?) -> Void)?
        // Most recent meaningful primary interaction, in normalized
        // remote-display coordinates — the typing-focus anchor. Never
        // updated from multi-finger/system gestures, Pencil hover, the
        // keyboard button, or a touch outside the rendered video (those
        // simply never call the note*Anchor* methods below).
        private var lastAnchor: CGPoint?
        // True only while layoutSubviews is running inside the UIView.animate
        // block a keyboard-frame change (or a live preference toggle) drives
        // — lets the content layer's geometry inherit that animation instead
        // of snapping, while ordinary layout (rotation, initial layout)
        // keeps disabling implicit actions as before.
        private var animatingKeyboardTransition = false

        // MARK: - Local manual viewport zoom/pan

        // The user's own local pinch-to-zoom/pan of the displayed remote
        // video — never sent to the Mac. Composed *on top of* whichever
        // base presentation `updateCurrentTransform` computed (normal or
        // keyboard-adjusted) each layout pass, so it automatically stays
        // valid across rotation/keyboard changes without its own geometry
        // recalculation — see `ManualViewportState.clamped(against:)`.
        fileprivate var manualZoom = ManualViewportState.identity
        // The manual state and *unzoomed* base rect captured at the start
        // of the current pinch/pan gesture — the fixed reference frame
        // `ManualViewportState.pinching(from:...)` computes from for every
        // `.changed` update in that same gesture.
        private var manualZoomGestureStart = ManualViewportState.identity
        private var manualZoomGestureBase = CGRect.zero
        // Most recent meaningful non-1x manual viewport state, remembered
        // across a two-finger-double-tap reset so a second double tap can
        // restore it — see `didViewportDoubleTap`. Instance-only, never
        // persisted across launches.
        private var manualZoomMemory: ManualViewportState?

        // MARK: - M7 pointer/click gestures

        // Pure touch-intent/session policy — see its type doc. Only driven
        // when the connected Mac speaks the pv5 `pointer` wire (checked at
        // each touch); older Macs keep the legacy click-drag `send()` path
        // below untouched.
        private let pointerEngine = PointerGestureEngine()
        private var pointerPollTimer: DispatchWorkItem?

        override init(frame: CGRect) {
            super.init(frame: frame)
            // Keyboard notifications fire globally regardless of which
            // responder triggered them — `keyboardRequested` (above) is
            // what keeps this from reacting to somebody else's keyboard.
            NotificationCenter.default.addObserver(
                self, selector: #selector(keyboardWillChangeFrame(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            // The zoomed/panned content layer can extend beyond `bounds` —
            // clip it so it never bleeds into sibling SwiftUI content.
            clipsToBounds = true
            videoContentView.backgroundColor = .clear
            videoContentView.isUserInteractionEnabled = false
            addSubview(videoContentView)
            surfaceLayer.fillColor = UIColor.secondarySystemBackground.cgColor
            surfaceLayer.strokeColor = UIColor.separator.cgColor
            surfaceLayer.lineWidth = 1
            surfaceLayer.isHidden = true
            surfaceGridLayer.fillColor = UIColor.tertiaryLabel.withAlphaComponent(0.35).cgColor
            surfaceGridLayer.isHidden = true
            layer.insertSublayer(surfaceLayer, at: 0)
            layer.insertSublayer(surfaceGridLayer, above: surfaceLayer)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unsupported") }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func installVideoLayer(_ layer: CALayer) {
            videoLayer?.removeFromSuperlayer()
            videoLayer = layer
            videoContentView.layer.addSublayer(layer)
            setNeedsLayout()
        }

        func setZoomWhileTyping(_ enabled: Bool) {
            guard enabled != zoomWhileTypingEnabled else { return }
            zoomWhileTypingEnabled = enabled
            guard keyboardVisibleRect != nil else { return }   // only matters while open
            animateTransformChange(duration: 0.25, options: .curveEaseInOut)
        }

        /// Applies a change to the primary one-finger pointer model.
        /// Guarded exactly like `setZoomWhileTyping`/`setKeyboardRequested`
        /// below — `updateUIView` calls this on EVERY SwiftUI re-render of
        /// this view (which happens at up to frame rate, e.g. on every
        /// `receiver.perf`/`fps` publish), and unlike those two cheap
        /// property assignments, the unguarded body here cancelled and
        /// rescheduled `pointerPollTimer` on every single call — main-
        /// thread timer churn dozens of times a second, competing with the
        /// two-finger scroll/pinch recognizer for touch delivery and, under
        /// load, plausibly delaying frame/socket processing far enough to
        /// trip the receiver's 5s liveness watchdog. Only do real work when
        /// the mode actually changed.
        func setInputMode(_ mode: PointerInputMode) {
            guard mode != pointerEngine.inputMode else { return }
            dispatchPointerCommands(pointerEngine.setInputMode(mode))
            schedulePointerPoll()
        }

        /// Applies a change to the Trackpad sensitivity multiplier. Guarded
        /// like `setInputMode` for the same reason (`updateUIView` runs at
        /// up to frame rate) — cheap regardless since this only assigns a
        /// stored property with no session to cancel, but there is no
        /// reason to write it redundantly every frame either.
        func setTrackpadSensitivity(_ sensitivity: Double) {
            guard sensitivity != pointerEngine.trackpadSensitivity else { return }
            pointerEngine.trackpadSensitivity = sensitivity
        }

        private var allowsInput = true

        /// Applies a change to the master remote-input gate. Only acts on
        /// the OFF transition — that's the one direction with stale state to
        /// clean up; turning input back on has nothing to undo (the next
        /// touch simply starts a fresh session normally).
        func setAllowInput(_ allowed: Bool) {
            guard allowed != allowsInput else { return }
            allowsInput = allowed
            guard !allowed else { return }
            clearInputStateForPause()
        }

        func setVideoEnabled(_ enabled: Bool, showGrid: Bool) {
            guard enabled != videoEnabled || showGrid != showSurfaceGrid else { return }
            if enabled != videoEnabled { clearInputStateForPause() }
            videoEnabled = enabled
            showSurfaceGrid = showGrid
            videoContentView.isHidden = !enabled
            surfaceLayer.isHidden = enabled
            surfaceGridLayer.isHidden = enabled || !showGrid
            backgroundColor = .black
            setNeedsLayout()
        }

        func setSurfaceContext(safeInsets: ControlSafeInsets,
                               occupiedControlFrames: [CGRect]) {
            guard safeInsets != surfaceSafeInsets || occupiedControlFrames != self.occupiedControlFrames else { return }
            surfaceSafeInsets = safeInsets
            self.occupiedControlFrames = occupiedControlFrames
            setNeedsLayout()
        }

        func setGesturePreferences(pinchTarget: ReceiverGestureTarget,
                                   rotateTarget: ReceiverGestureTarget,
                                   snapRotation: Bool,
                                   appGestureCommands: AppGestureCommands,
                                   onRotationSnap: @escaping () -> Void) {
            self.pinchTarget = pinchTarget
            self.rotateTarget = rotateTarget
            self.snapRotation = snapRotation
            self.appGestureCommands = appGestureCommands
            self.onRotationSnap = onRotationSnap
        }

        func setKeyboardRequested(_ requested: Bool) {
            guard requested != keyboardRequested else { return }
            keyboardRequested = requested
            guard !requested, keyboardVisibleRect != nil else { return }
            // Explicit close (Done / the floating button) restores normal
            // presentation immediately rather than waiting on the system's
            // hide notification, which this view now ignores anyway.
            keyboardVisibleRect = nil
            onKeyboardVisibleRectChange?(nil)
            animateTransformChange(duration: 0.25, options: .curveEaseInOut)
        }

        @objc private func keyboardWillChangeFrame(_ note: Notification) {
            guard keyboardRequested,
                  let info = note.userInfo,
                  let endFrameValue = info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue else { return }
            let duration = (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval) ?? 0.25
            let curveRaw = (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int)
                ?? UIView.AnimationCurve.easeInOut.rawValue
            let curveOption = UIView.AnimationOptions(rawValue: UInt(curveRaw << 16))
            let localFrame = convert(endFrameValue.cgRectValue, from: nil)
            // The system keyboard docks at the bottom edge; an undocked/
            // floating iPad keyboard doesn't cover our bottom edge and
            // needs no protection.
            let dockedAtBottom = localFrame.maxY >= bounds.maxY - 1 && localFrame.minY < bounds.maxY
            keyboardVisibleRect = dockedAtBottom
                ? CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, max(0, localFrame.minY)))
                : nil
            onKeyboardVisibleRectChange?(keyboardVisibleRect)
            // Diagnostic breadcrumb for a real-device-only first-activation
            // keyboard crash under investigation — cheap, no behavior
            // change. Remove once root-caused.
            Log.info("keyboard: willChangeFrame bounds=\(bounds) localFrame=\(localFrame) docked=\(dockedAtBottom)")
            animateTransformChange(duration: duration, options: curveOption)
        }

        private func animateTransformChange(duration: TimeInterval, options: UIView.AnimationOptions) {
            setNeedsLayout()
            animatingKeyboardTransition = true
            UIView.animate(withDuration: duration, delay: 0, options: [options, .beginFromCurrentState], animations: {
                self.layoutIfNeeded()
            }, completion: { [weak self] _ in self?.animatingKeyboardTransition = false })
        }

        /// Finger-primary-touch anchor updates: only from a touch that
        /// actually landed on the rendered video, never a letterbox bar.
        private func noteAnchorIfOnDisplay(viewPoint: CGPoint, normalized: CGPoint) {
            guard currentTransform.containsViewPoint(viewPoint) else { return }
            setAnchor(normalized)
        }

        /// Pencil-down anchor updates. Already-normalized coordinates come
        /// from a real touch on the glass, so no extra bounds check.
        fileprivate func noteAnchorFromNormalized(x: Double, y: Double) {
            setAnchor(CGPoint(x: x, y: y))
        }

        /// Updates the typing-focus anchor and, if the keyboard is already
        /// open, smoothly re-targets the viewport to it (tapping a
        /// different Mac field mid-session must not snap — a short,
        /// non-bouncy ease, same family as the keyboard-frame transition).
        /// While the keyboard is closed this only records the anchor for
        /// whenever it next opens; no animation is needed since nothing is
        /// visibly changing yet.
        private func setAnchor(_ normalized: CGPoint) {
            lastAnchor = normalized
            guard keyboardVisibleRect != nil else { return }
            animateTransformChange(duration: 0.25, options: .curveEaseInOut)
        }

        func clearInputStateForPause() {
            twoFingerActive = false
            discardPendingDown()
            inputEngine.cancelForDisplayPause()
            lastAnchor = nil
            resetPointerEngine()
            cancelScrollMomentum()
            activeFingerTouchIDs.removeAll()
            systemGestureOwnedTouchIDs.removeAll()
            surfaceAdmission.reset()
            endAppGestures(cancelled: true)
            recognizerResetPending = false
            // Force the two-finger recognizer to give up whatever it was
            // mid-deciding or already committed to — toggling `isEnabled`
            // is UIKit's standard way to force a recognizer to `.cancelled`
            // (same trick used elsewhere for gesture-ownership hand-off).
            twoFingerRecognizer?.isEnabled = false
            twoFingerRecognizer?.isEnabled = true
        }

        /// Releases any pointer-engine-held mouse button and forgets every
        /// tracked touch. MUST run on pause, disconnect/input-disable, and
        /// gesture-ownership takeover by the existing system/scroll/pinch
        /// recognizers — the stuck-button safety net for the M7 pointer
        /// model, mirroring `InputInjector.cancelActiveInputLocked` on the
        /// Mac side.
        private func resetPointerEngine() {
            pointerPollTimer?.cancel()
            pointerPollTimer = nil
            dispatchPointerCommands(pointerEngine.reset())
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateCurrentTransform()
            let normalRect = RemoteViewportCalculator.normal(
                viewBounds: bounds, remoteAspectSize: receiver?.videoSize ?? .zero).displayedRect
            let applyContent = {
                self.applyContentGeometry(self.videoContentView.layer,
                                          normalRect: normalRect, transform: self.currentTransform)
                self.videoLayer?.frame = self.videoContentView.bounds
            }
            if animatingKeyboardTransition {
                applyContent()
            } else {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                applyContent()
                CATransaction.commit()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if cursorLayer.superlayer == nil { layer.addSublayer(cursorLayer) }
            updateCursorLayout()
            updateSurfaceLayout()
            CATransaction.commit()
            // Rotation diagnostics — one line per layout change.
            let video = receiver?.videoSize ?? .zero
            let displayed = currentTransform.displayedRect
            let line = "layout: bounds=\(Int(bounds.width))x\(Int(bounds.height))"
                + " video=\(Int(video.width))x\(Int(video.height))"
                + " layer=\(Int(displayed.width))x\(Int(displayed.height))"
            if line != lastLoggedLayout {
                lastLoggedLayout = line
                Log.info(line)
            }
        }

        private func updateSurfaceLayout() {
            surfaceLayer.frame = bounds
            surfaceGridLayer.frame = bounds
            let rect = currentTransform.displayedRect.intersection(bounds).insetBy(dx: 0.5, dy: 0.5)
            guard !videoEnabled, !rect.isNull, rect.width > 1, rect.height > 1 else {
                surfaceLayer.path = nil
                surfaceGridLayer.path = nil
                return
            }
            surfaceLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 12).cgPath
            guard showSurfaceGrid else {
                surfaceGridLayer.path = nil
                return
            }
            let dots = UIBezierPath()
            let spacing: CGFloat = 28
            let radius: CGFloat = 1.1
            var y = rect.minY + spacing
            while y < rect.maxY - spacing / 2 {
                var x = rect.minX + spacing
                while x < rect.maxX - spacing / 2 {
                    dots.append(UIBezierPath(ovalIn: CGRect(x: x - radius, y: y - radius,
                                                           width: radius * 2, height: radius * 2)))
                    x += spacing
                }
                y += spacing
            }
            surfaceGridLayer.path = dots.cgPath
        }

        private func updateCurrentTransform() {
            let base = unzoomedBaseTransform()
            currentTransform = VideoInteractionPolicy.viewportTransform(
                base: base, state: manualZoom, videoEnabled: videoEnabled)
        }

        /// The normal or keyboard-adjusted presentation, *before* manual
        /// zoom/pan — the fixed reference frame both `updateCurrentTransform`
        /// and the live pinch/pan gesture (`manualZoomGestureBase`) compose
        /// on top of, so there is exactly one place that decides between
        /// `.normal`/`.keyboardOpen`.
        private func unzoomedBaseTransform() -> RemoteViewportTransform {
            guard let video = receiver?.videoSize, video != .zero,
                  bounds.width > 0, bounds.height > 0 else {
                return .invalid
            }
            if !videoEnabled {
                let portrait = bounds.height > bounds.width
                let rect = VideoOffSurfaceGeometry.interactionRect(
                    container: bounds,
                    safeInsets: surfaceSafeInsets,
                    occupiedControlFrames: occupiedControlFrames,
                    portrait: portrait,
                    inputMode: pointerEngine.inputMode,
                    remoteAspectSize: video)
                #if DEBUG
                // TRACKPAD REGRESSION forensics: this is the ONE call site
                // that decides between Trackpad's tall free-form portrait
                // rect and Direct Touch's aspect-locked one (see
                // `VideoOffSurfaceGeometry.interactionRect`'s `inputMode ==
                // .direct` branch). Logging every input here on the next
                // physical retest tells us immediately whether a wide/
                // landscape rect in Portrait+Video-Off+Trackpad comes from
                // `inputMode` unexpectedly reading `.direct`, from
                // `portrait` being wrong, or from `occupiedControlFrames`
                // being stale/empty — this file's own logic was audited and
                // reads correctly for the intended Trackpad case.
                if rect != lastLoggedTrackpadRect {
                    lastLoggedTrackpadRect = rect
                    Log.info("trackpadGeometry: portrait=\(portrait) inputMode=\(pointerEngine.inputMode) "
                        + "bounds=\(bounds) occupied=\(occupiedControlFrames.count) rect=\(rect)")
                }
                #endif
                return RemoteViewportTransform(
                    remoteCrop: CGRect(x: 0, y: 0, width: 1, height: 1),
                    displayedRect: rect)
            }
            if let keyboardVisibleRect {
                return RemoteViewportCalculator.keyboardOpen(
                    viewBounds: bounds, remoteAspectSize: video,
                    visibleRect: keyboardVisibleRect, anchor: lastAnchor,
                    zoomEnabled: zoomWhileTypingEnabled)
            }
            return RemoteViewportCalculator.normal(viewBounds: bounds, remoteAspectSize: video)
        }

        /// Positions a content layer (the AVSBDL sublayer or the Metal
        /// layer) using `bounds`/`anchorPoint`/`position`/`transform`
        /// rather than `frame`, because neither renderer supports drawing a
        /// cropped sub-region on its own (AVSBDL's `videoGravity` and the
        /// Metal shader's fullscreen-quad UV both always show the *whole*
        /// frame). Instead, the layer is always sized at its natural,
        /// un-zoomed (`normalRect`) size, and a `CGAffineTransform` scales
        /// it — around whatever point in its own bounds corresponds to
        /// `remoteCrop`'s origin — so only that cropped fraction ends up
        /// visible, at `displayedRect`. A pure compositing trick: neither
        /// renderer's actual drawing changes.
        private func applyContentGeometry(_ layer: CALayer, normalRect: CGRect, transform: RemoteViewportTransform) {
            guard transform.isValid, normalRect.width > 0, normalRect.height > 0 else {
                layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
                layer.bounds = CGRect(origin: .zero, size: bounds.size)
                layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
                layer.setAffineTransform(.identity)
                return
            }
            let scale = transform.displayedRect.width / max(transform.remoteCrop.width * normalRect.width, 0.0001)
            layer.bounds = CGRect(origin: .zero, size: normalRect.size)
            layer.anchorPoint = CGPoint(x: transform.remoteCrop.midX, y: transform.remoteCrop.midY)
            layer.position = transform.viewPoint(forRemote: CGPoint(x: transform.remoteCrop.midX,
                                                                     y: transform.remoteCrop.midY))
            layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale)
                .rotated(by: transform.rotationRadians))
        }

        /// View points per Mac pixel under the current transform — used to
        /// convert a finger-pan drag into `sendScroll`'s pixel deltas. `nil`
        /// when there's nothing valid to scroll against.
        private func pointsPerRemotePixel(video: CGSize) -> CGFloat? {
            guard currentTransform.isValid, video.width > 0, currentTransform.remoteCrop.width > 0 else { return nil }
            return currentTransform.displayedRect.width / (currentTransform.remoteCrop.width * video.width)
        }

        func moveCursor(x: Double, y: Double, visible: Bool) {
            cursorNorm = CGPoint(x: x, y: y)
            cursorVisible = visible
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.isHidden = !visible || cursorLayer.contents == nil
            updateCursorLayout()
            CATransaction.commit()
            #if DEBUG
            logCursorTraceIfDue(reason: "moveCursor")
            #endif
        }

        func setCursorSprite(_ image: CGImage, anchor: CGPoint, normSize: CGSize) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.contents = image
            cursorLayer.anchorPoint = anchor
            cursorNormSize = normSize
            cursorLayer.isHidden = !cursorVisible
            updateCursorLayout()
            CATransaction.commit()
            #if DEBUG
            Log.info("cursorTrace: setCursorSprite image=\(image.width)x\(image.height) "
                + "anchor=\(anchor) normSize=\(normSize) isHidden=\(cursorLayer.isHidden)")
            #endif
        }

        #if DEBUG
        private var lastCursorTraceAt = Date.distantPast
        /// Throttled to once every 2s — `moveCursor` can arrive at up to
        /// 120Hz over the cursor side channel.
        private func logCursorTraceIfDue(reason: String) {
            let now = Date()
            guard now.timeIntervalSince(lastCursorTraceAt) > 2 else { return }
            lastCursorTraceAt = now
            Log.info("cursorTrace: \(reason) norm=\(cursorNorm) visible=\(cursorVisible) "
                + "isHidden=\(cursorLayer.isHidden) hasContents=\(cursorLayer.contents != nil) "
                + "normSize=\(cursorNormSize) bounds=\(cursorLayer.bounds) position=\(cursorLayer.position) "
                + "transformValid=\(currentTransform.isValid)")
        }
        #endif

        /// Places the cursor sprite via the same `currentTransform` that
        /// positions the content layer and maps touches, so it stays
        /// correctly aligned whether the remote display is zoomed, panned,
        /// or shown normally — including scaling up while zoomed in, and
        /// (correctly) landing outside the clipped view when the Mac
        /// cursor itself is currently outside the visible crop.
        private func updateCursorLayout() {
            guard currentTransform.isValid, cursorNormSize != .zero else { return }
            let displayedRect = currentTransform.displayedRect
            let crop = currentTransform.remoteCrop
            let scaleX = displayedRect.width / crop.width
            let scaleY = displayedRect.height / crop.height
            cursorLayer.bounds = CGRect(x: 0, y: 0,
                                        width: cursorNormSize.width * scaleX,
                                        height: cursorNormSize.height * scaleY)
            cursorLayer.position = currentTransform.viewPoint(forRemote: cursorNorm)
            cursorLayer.setAffineTransform(CGAffineTransform(rotationAngle: currentTransform.rotationRadians))
        }

        // Maps a view-local point into normalized remote-display space
        // through `currentTransform` — the exact inverse of how the
        // content layer and cursor are placed, so a visible Mac control
        // tapped while zoomed/panned still receives input at that precise
        // Mac location.
        fileprivate func normalized(_ point: CGPoint) -> (x: Double, y: Double)? {
            guard let remote = currentTransform.remotePoint(forView: point) else { return nil }
            return (Double(remote.x), Double(remote.y))
        }

        private func isFinger(_ touch: UITouch) -> Bool {
            switch touch.type {
            case .direct, .indirectPointer: return true
            default: return false
            }
        }

        private func isPencil(_ touch: UITouch) -> Bool {
            touch.type == .pencil
        }

        private var twoFingerActive = false
        private var lastPan = CGPoint.zero
        private var gestureEmissionGate = GestureEmissionGate()
        private var lastNorm: (x: Double, y: Double) = (0.5, 0.5)

        // MARK: - System-gesture touch ownership
        //
        // Every finger touch currently down on this view, tracked
        // independently of which recognizer(s) also see it — the source of
        // truth `cancelTouchForGestureOwnership` snapshots from.
        private var activeFingerTouchIDs: Set<ObjectIdentifier> = []
        // The touches a system gesture (Mission Control, Spaces, App
        // Exposé, pinch/spread, viewport pinch-zoom) has claimed. The
        // three-finger and pinch/spread recognizers set `cancelsTouchesInView
        // = false` (so they can coexist with `twoFingerRecognizer` while
        // undecided — see its delegate doc), which means UIKit keeps delivering these
        // exact touches' `moved`/`ended` samples to this view for the rest
        // of their physical lifetime, well past the moment ownership was
        // taken (typically mid-swipe, long before all fingers have lifted).
        // Routing those leftover samples into `pointerEngine`/the legacy
        // touch path would let a still-lifting 3-finger sequence's
        // intermediate 2-then-1-touch states be reinterpreted as a fresh
        // right-click chord or pointer session — once a system gesture
        // claims a touch sequence, every touch in it stays consumed until
        // the whole sequence reaches zero, never returned to pointer/chord
        // recognition. `routeTouches` filters exactly this set out; only a
        // touch that begins after its own id is gone (or was never in this
        // set to begin with) may create new pointer/click state.
        private var systemGestureOwnedTouchIDs: Set<ObjectIdentifier> = []

        /// True from the moment a system gesture claims a touch sequence
        /// until every touch in it has physically ended — i.e. exactly
        /// `!systemGestureOwnedTouchIDs.isEmpty`, named for readability at
        /// its call sites. `twoFingerRecognizer`/`viewportDoubleTapRecognizer`
        /// stay attached and receive these touches like any other UIKit
        /// recognizer (see `cancelTouchForGestureOwnership`'s doc for why
        /// detaching them via `isEnabled` toggling was reverted); their
        /// *output* — `didTwoFingerGesture`/`didViewportDoubleTap` — is what
        /// this gates, at the very top of each action method.
        private var systemGestureSequenceOwned: Bool { !systemGestureOwnedTouchIDs.isEmpty }
        /// Set the instant the last owned touch ends; consumed (and the
        /// recognizers actually reset) only once `activeFingerTouchIDs` is
        /// ALSO empty — see the `ended` branch of `routeTouches` for why an
        /// overlapping fresh touch must delay this rather than let it fire
        /// while that touch is still physically down.
        private var recognizerResetPending = false

        // MARK: - Remote-scroll momentum

        // Recent velocity samples for the LIVE scroll only — reset every
        // time a fresh scroll begins, fed on every `continueScroll` tick.
        // Pure/testable estimation logic lives in `Shared/ScrollMomentum.swift`;
        // this is just the UIKit-side glue driving it off real touch/frame
        // timing, mirroring how `pointerEngine`/`schedulePointerPoll` split
        // pure policy from UIKit glue.
        private var scrollVelocityTracker = ScrollVelocityTracker()
        private var scrollMomentumSession: ScrollMomentumSession?
        private var scrollMomentumDisplayLink: CADisplayLink?

        @objc func didThreeFingerSystemPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                guard recognizer.numberOfTouches == 3 else { return }
                let translation = recognizer.translation(in: self)
                guard let gesture = ReceiverGesture.swipe(translationX: Double(translation.x),
                                                          translationY: Double(translation.y)),
                      gestureEmissionGate.claim() else { return }
                takeGestureOwnershipAndSend(gesture)
            default:
                gestureEmissionGate.reset()
            }
        }

        @objc func didThreeFingerSystemTap(_ recognizer: ThreeFingerTapGestureRecognizer) {
            guard recognizer.state == .recognized,
                  let gesture = ReceiverGesture.threeFingerTap(
                    touchCount: recognizer.recognizedTouchCount,
                    maximumMovement: recognizer.maximumMovement) else { return }
            takeGestureOwnershipAndSend(gesture)
        }

        @objc func didPinchSpreadSystemGesture(_ recognizer: PinchSpreadSystemGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard let gesture = recognizer.recognizedGesture else { return }
                guard gestureEmissionGate.claim() else { return }
                takeGestureOwnershipAndSend(gesture)
            case .ended, .cancelled, .failed:
                gestureEmissionGate.reset()
            default:
                break
            }
        }

        private func takeGestureOwnershipAndSend(_ gesture: ReceiverGesture) {
            twoFingerActive = false
            cancelTouchForGestureOwnership()
            receiver?.sendGesture(name: gesture.rawValue)
        }

        // MARK: - Two-finger gesture: remote scroll / local viewport zoom+pan

        /// The single action for `twoFingerRecognizer` — see its type doc
        /// for the full three-way arbitration model. `recognizer.intent` is
        /// fixed for the lifetime of one gesture once it leaves `.undecided`
        /// (the recognizer's own contract), so this only ever needs to
        /// branch on it, never re-decide.
        @objc func didTwoFingerGesture(_ recognizer: TwoFingerViewportGestureRecognizer) {
            // The recognizer stays attached to and receives every touch
            // normally — including a system gesture's remaining fingers as
            // they lift — so its OWN state may reflect leftovers from an
            // already-claimed sequence. Ignore its output entirely for as
            // long as that sequence hasn't fully drained; see
            // `cancelTouchForGestureOwnership`'s doc for why the touches
            // themselves are never detached from it anymore.
            #if DEBUG
            // Checkpoint F — remove once root-caused.
            Log.info("inputTrace: didTwoFingerGesture state=\(recognizer.state.rawValue) intent=\(recognizer.intent) "
                     + "systemGestureSequenceOwned=\(systemGestureSequenceOwned)")
            #endif
            guard !systemGestureSequenceOwned else { return }
            switch recognizer.state {
            case .began:
                switch recognizer.intent {
                case .scroll:
                    beginScroll(at: recognizer.midpoint)
                case .viewportZoomPan:
                    beginViewportManipulation()
                    applyViewportPinchUpdate(recognizer)
                    beginAppGesturesIfNeeded(recognizer)
                case .undecided:
                    break   // never begins while undecided — see the recognizer.
                }
            case .changed:
                switch recognizer.intent {
                case .scroll:
                    continueScroll(recognizer)
                case .viewportZoomPan:
                    applyViewportPinchUpdate(recognizer)
                    updateAppGestures(recognizer)
                case .undecided:
                    break
                }
            default:
                // `.ended`/`.cancelled`/`.failed`. Only a real `.ended`
                // scroll release (not a cancellation — another gesture or
                // system takeover already calls `cancelScrollMomentum()`
                // itself) can start momentum.
                let wasScrolling = twoFingerActive && recognizer.intent == .scroll
                twoFingerActive = false
                if recognizer.state == .ended, wasScrolling {
                    beginScrollMomentum()
                } else {
                    cancelScrollMomentum()
                }
                endAppGestures(cancelled: recognizer.state != .ended)
            }
        }

        /// Ownership hand-off for the `.viewportZoomPan` intent, mirroring
        /// the existing system gestures' `takeGestureOwnershipAndSend` —
        /// this is the *only* place remote scroll/touch gets suppressed for
        /// a viewport gesture, and it happens once, at commitment, not on
        /// every frame — there is no second recognizer racing this one to
        /// coordinate against any more.
        ///
        /// Deliberately calls `cancelPointerAndLegacyTouchState()`, NOT
        /// `cancelTouchForGestureOwnership()` — a viewport pinch/pan is a
        /// LOCAL takeover from `pointerEngine`/the legacy click path, never
        /// an external system gesture, so its own two fingers must never
        /// join `systemGestureOwnedTouchIDs`. Doing so used to silence
        /// `didTwoFingerGesture`'s own subsequent `.changed` callbacks for
        /// the rest of THIS SAME gesture (its top-level guard checks
        /// exactly that set) — a real-device trace caught pinch/pan
        /// updating once at `.began` and then going dead until the fingers
        /// lifted. `twoFingerRecognizer` keeps tracking these touches
        /// completely normally throughout — see the type doc.
        private func beginViewportManipulation() {
            twoFingerActive = false
            cancelPointerAndLegacyTouchState()   // also cancels any remote-scroll momentum — see its doc
            manualZoomGestureStart = manualZoom
            manualZoomGestureBase = unzoomedBaseTransform().displayedRect
            engagedSnapQuarter = nil
        }

        private func applyViewportPinchUpdate(_ recognizer: TwoFingerViewportGestureRecognizer) {
            guard videoEnabled else { return }
            guard manualZoomGestureBase.width > 0, manualZoomGestureBase.height > 0 else { return }
            let scaleRatio = pinchTarget == .viewport ? recognizer.scaleRatio : 1
            let rotationDelta = rotateTarget == .viewport ? recognizer.rotationDelta : 0
            var next = ManualViewportState.pinching(
                from: manualZoomGestureStart,
                initialBase: manualZoomGestureBase,
                initialMidpoint: recognizer.initialMidpoint,
                currentMidpoint: recognizer.midpoint,
                scaleRatio: scaleRatio,
                rotationDelta: rotationDelta)
            if rotateTarget == .viewport {
                let snap = ViewportRotationSnap.snappedAngle(next.rotationRadians, enabled: snapRotation)
                next.rotationRadians = snap.angle
                if let quarter = snap.targetQuarter, quarter != engagedSnapQuarter {
                    engagedSnapQuarter = quarter
                    onRotationSnap?()
                } else if snap.targetQuarter == nil {
                    engagedSnapQuarter = nil
                }
            }
            manualZoom = next
            setNeedsLayout()
            layoutIfNeeded()
        }

        private var effectivePinchTarget: ReceiverGestureTarget {
            VideoInteractionPolicy.effectiveTarget(stored: pinchTarget, videoEnabled: videoEnabled)
        }

        private var effectiveRotateTarget: ReceiverGestureTarget {
            VideoInteractionPolicy.effectiveTarget(stored: rotateTarget, videoEnabled: videoEnabled)
        }

        /// App mode is EXPERIMENTAL command routing only (spec H/I): pinch/
        /// rotation magnitude accumulates locally and fires discrete
        /// Zoom In/Out / Rotate Left/Right keyboard chords — it never
        /// mutates the local viewport, and never also injects a continuous
        /// native gesture at the same time (see
        /// `AppGestureCommandAccumulator`'s doc for why only one path runs).
        private func beginAppGesturesIfNeeded(_ recognizer: TwoFingerViewportGestureRecognizer) {
            lastAppScaleRatio = recognizer.scaleRatio
            lastAppRotation = recognizer.rotationDelta
            if effectivePinchTarget == .app {
                appMagnifyActive = true
                pinchCommandAccumulator.reset()
            }
            if effectiveRotateTarget == .app {
                appRotateActive = true
                rotationCommandAccumulator.reset()
            }
        }

        private func updateAppGestures(_ recognizer: TwoFingerViewportGestureRecognizer) {
            if appMagnifyActive {
                let previous = max(lastAppScaleRatio, 0.0001)
                let logDelta = log(Double(recognizer.scaleRatio / previous))
                lastAppScaleRatio = recognizer.scaleRatio
                let fires = pinchCommandAccumulator.advance(by: logDelta)
                fireAppGestureCommands(fires > 0 ? .zoomIn : .zoomOut, count: abs(fires))
            }
            if appRotateActive {
                let delta = ManualViewportState.normalizedAngle(recognizer.rotationDelta - lastAppRotation)
                lastAppRotation = recognizer.rotationDelta
                let fires = rotationCommandAccumulator.advance(by: Double(delta))
                fireAppGestureCommands(fires > 0 ? .rotateRight : .rotateLeft, count: abs(fires))
            }
        }

        private func endAppGestures(cancelled: Bool) {
            if appMagnifyActive { pinchCommandAccumulator.reset() }
            if appRotateActive { rotationCommandAccumulator.reset() }
            appMagnifyActive = false
            appRotateActive = false
        }

        private func fireAppGestureCommands(_ kind: AppGestureCommandKind, count: Int) {
            guard count > 0 else { return }
            let shortcut = appGestureCommands.shortcut(for: kind)
            for _ in 0..<count {
                receiver?.sendKeyboardPress(usage: shortcut.usage,
                                            modifiers: shortcut.modifiers.modifiers.map(\.rawValue))
            }
        }

        private func beginScroll(at midpoint: CGPoint) {
            guard let video = receiver?.videoSize, video != .zero else { return }
            cancelScrollMomentum()   // touching again immediately cancels any active momentum
            scrollVelocityTracker.reset()
            twoFingerActive = true
            lastPan = .zero
            // macOS delivers scroll to whatever sits under the cursor, and
            // the cursor no longer follows the fingers now that a press is
            // withheld until it commits. Put it on the gesture once, up
            // front, so the scroll lands on the window being touched. Once
            // only: a real trackpad does not drag the cursor while
            // scrolling, and moving it mid-gesture would change the target.
            // Direct Touch intentionally targets the scroll under the
            // fingers. Trackpad must never teleport the Mac cursor: this
            // legacy absolute touch message can race a right-click chord
            // and arrive immediately before its right mouseDown.
            if pointerEngine.inputMode.seedsAbsoluteScrollTarget, let n = normalized(midpoint) {
                lastNorm = n
                receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
            }
        }

        private func continueScroll(_ recognizer: TwoFingerViewportGestureRecognizer) {
            guard twoFingerActive, let video = receiver?.videoSize, video != .zero,
                  let scale = pointsPerRemotePixel(video: video) else { return }
            // Cumulative translation since the gesture started, matching
            // `UIPanGestureRecognizer.translation(in:)`'s convention (this
            // recognizer isn't one, so it's derived from the midpoint here
            // instead of read off the recognizer directly).
            let t = CGPoint(x: recognizer.midpoint.x - recognizer.initialMidpoint.x,
                            y: recognizer.midpoint.y - recognizer.initialMidpoint.y)
            // Deltas in video pixels, natural-scrolling direction.
            let stepX = t.x - lastPan.x
            let stepY = t.y - lastPan.y
            receiver?.sendScroll(dx: stepX / scale, dy: stepY / scale)
            // Recorded in view points (pre-scale), matching the domain
            // `cancelScrollMomentum`/`beginScrollMomentum` convert from —
            // see `tickScrollMomentum`.
            scrollVelocityTracker.record(dx: stepX, dy: stepY, at: CACurrentMediaTime())
            lastPan = t
        }

        /// Starts a decaying momentum phase from the velocity estimated
        /// over the just-ended scroll's recent samples — a no-op if the
        /// release was too slow to clear `ScrollMomentumConfig.minReleaseVelocity`.
        private func beginScrollMomentum() {
            let releaseTime = CACurrentMediaTime()
            defer { scrollVelocityTracker.reset() }
            guard let velocity = scrollVelocityTracker.releaseVelocity(at: releaseTime),
                  let session = ScrollMomentumSession(initialVelocity: velocity, at: releaseTime) else { return }
            scrollMomentumSession = session
            scrollMomentumDisplayLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(tickScrollMomentum))
            link.add(to: .main, forMode: .common)
            scrollMomentumDisplayLink = link
        }

        @objc private func tickScrollMomentum() {
            guard let session = scrollMomentumSession, let video = receiver?.videoSize, video != .zero,
                  let scale = pointsPerRemotePixel(video: video) else {
                cancelScrollMomentum()
                return
            }
            let (delta, alive) = session.tick(now: CACurrentMediaTime())
            if delta.dx != 0 || delta.dy != 0 {
                receiver?.sendScroll(dx: delta.dx / scale, dy: delta.dy / scale)
            }
            if !alive { cancelScrollMomentum() }
        }

        /// Stops any active/pending remote-scroll momentum immediately and
        /// forgets its velocity history. MUST be called on every ownership
        /// transition away from remote scroll (a new touch, pinch/pan,
        /// pointer interaction, system gesture, input-disable, pause, or
        /// disconnect) — see call sites.
        private func cancelScrollMomentum() {
            scrollMomentumDisplayLink?.invalidate()
            scrollMomentumDisplayLink = nil
            scrollMomentumSession = nil
        }

        /// Toggles between the normal 1x viewport and the most recent
        /// meaningful manually-zoomed/panned state: zoomed -> stores it and
        /// resets to exactly 1x; already at 1x with a remembered state ->
        /// restores it, clamped against the *current* geometry (rotation,
        /// keyboard, or receiver-size changes since it was stored). Never
        /// persisted across launches — a plain instance property.
        @objc func didViewportDoubleTap(_ recognizer: UITapGestureRecognizer) {
            // See `didTwoFingerGesture`'s matching guard doc — this
            // recognizer stays attached to a system gesture's leftover
            // touches too.
            guard !systemGestureSequenceOwned else { return }
            guard recognizer.state == .ended, videoEnabled else { return }
            let base = unzoomedBaseTransform().displayedRect
            guard let toggled = ViewportResetRestorePolicy.toggled(
                current: manualZoom, memory: manualZoomMemory, base: base) else { return }
            manualZoom = toggled.current
            manualZoomMemory = toggled.memory
            animateTransformChange(duration: 0.25, options: .curveEaseInOut)
        }

        /// True whenever the M7 pointer engine already owns this touch
        /// sequence via a *committed* anchor (an absolute-pointer/relative
        /// session, or a later chord/drag on one) — the existing
        /// system-gesture and scroll/pinch recognizers must never also
        /// claim these same touches (see GOAL: "existing pointer session +
        /// two extra fingers" must not become a fresh 3-finger system
        /// gesture).
        ///
        /// `.firstTouchPending`/`.tapBuffered` are deliberately excluded —
        /// those are still mere *arbitration*, not commitment (GOAL:
        /// "fresh 2-finger gestures can actually form before finger 1 is
        /// irrevocably claimed"): the engine hasn't decided anything yet,
        /// so the legacy recognizers must stay free to receive these same
        /// touches and race normally, exactly as before this touch
        /// sequence started. A fresh two-finger candidate not yet
        /// recognized as continuing a buffered right tap
        /// (`.twoFingerPending` without `isChordContinuation`) is excluded
        /// for the same reason.
        private var pointerEngineOwnsAnchor: Bool {
            switch pointerEngine.mode {
            case .absolutePointer, .relativePointerSession, .leftDragHeld, .chordPending, .rightDragHeld:
                return true
            case .twoFingerPending:
                return pointerEngine.isChordContinuation
            case .idle, .firstTouchPending, .tapBuffered, .deferredSystemGesture:
                return false
            }
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if pointerEngineOwnsAnchor { return false }
            if gestureRecognizer === threeFingerPanRecognizer {
                return gestureRecognizer.numberOfTouches == 3
            }
            if gestureRecognizer === threeFingerTapRecognizer {
                return threeFingerTapRecognizer?.recognizedTouchCount == 3
            }
            if gestureRecognizer === pinchSpreadGestureRecognizer {
                return (4...5).contains(gestureRecognizer.numberOfTouches)
            }
            // `twoFingerRecognizer` needs no case here: it decides its own
            // intent internally (`TwoFingerGestureClassifier`) and is
            // eligible to begin regardless of `manualZoom` — remote scroll
            // must stay available while manually zoomed (PRODUCT RULE), not
            // just at 1x.
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            if !videoEnabled && !currentTransform.containsViewPoint(touch.location(in: self)) {
                return false
            }
            if gestureRecognizer === threeFingerPanRecognizer
                || gestureRecognizer === threeFingerTapRecognizer
                || gestureRecognizer === pinchSpreadGestureRecognizer {
                return touch.type == .direct && !pointerEngineOwnsAnchor
            }
            if gestureRecognizer === twoFingerRecognizer {
                return !pointerEngineOwnsAnchor
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Let a three-finger swipe take ownership if the two-finger
            // gesture (scroll or viewport) already began before the third
            // finger landed.
            (gestureRecognizer === twoFingerRecognizer
                && otherGestureRecognizer === threeFingerPanRecognizer)
                || (gestureRecognizer === threeFingerPanRecognizer
                    && otherGestureRecognizer === twoFingerRecognizer)
                // The double-tap recognizer needs to observe the same
                // two-finger touch stream as `twoFingerRecognizer` — see its
                // doc comment on why no `require(toFail:)` is needed here.
                || gestureRecognizer === viewportDoubleTapRecognizer
                || otherGestureRecognizer === viewportDoubleTapRecognizer
        }

        /// A system gesture takes ownership from a pending or active touch press.
        /// Release a posted down; discard one that has not reached the Mac.
        /// Also claims every finger currently down for `systemGestureOwnedTouchIDs`
        /// (see its doc) — the whole point being that ownership, once taken,
        /// is never handed back to pointer/chord recognition for these same
        /// touches, no matter how many more `moved`/`ended` samples UIKit
        /// keeps delivering for them.
        ///
        /// An earlier version of this also force-detached `twoFingerRecognizer`/
        /// `viewportDoubleTapRecognizer` by toggling `isEnabled` right here,
        /// mid-sequence, on the theory that UIKit's own touch-recognizer
        /// association would otherwise let them still see these touches. A
        /// real-device trace showed that toggle is what broke drainage: the
        /// bookkeeping below got stuck holding 2 "owned" touches forever
        /// after a later gesture, with `SYSTEM DRAIN` never reaching 0 —
        /// exactly the touches whose `touchesEnded` this view stopped
        /// receiving once their recognizer had been disabled and
        /// re-enabled out from under them mid-flight. Disabling/re-enabling
        /// a recognizer while it still has physically-down touches is not
        /// something UIKit contracts to leave the VIEW's own touch delivery
        /// untouched, and evidently doesn't here.
        ///
        /// So the recognizers now stay attached and continue receiving
        /// these touches completely normally, like any other UIKit
        /// recognizer — `routeTouches`'s raw `touchesEnded`/`touchesCancelled`
        /// (never anything this function touches) is the ONLY thing that
        /// drains `activeFingerTouchIDs`/`systemGestureOwnedTouchIDs`, so it
        /// can never be starved by a recognizer-state side effect again.
        /// What's suppressed instead is their *output*:
        /// `didTwoFingerGesture`/`didViewportDoubleTap` both check
        /// `systemGestureSequenceOwned` first and no-op while it's true —
        /// whatever the recognizer privately thinks it recognized from
        /// leftover touches never reaches scroll/viewport-zoom/right-click
        /// behavior. Their own internal session state (`TwoFingerGestureSession`
        /// et al.) is reset once ownership actually ends — see the
        /// `SYSTEM RELEASE` branch in `routeTouches`.
        ///
        /// ONLY for a genuine EXTERNAL/system takeover (3/4/5-finger
        /// Mission Control/Spaces/App Exposé/Spotlight, pinch-spread) —
        /// see `cancelPointerAndLegacyTouchState()` for the shared
        /// cancellation work this also does, which a LOCAL two-finger
        /// viewport pinch/pan needs too but must reach WITHOUT marking its
        /// own fingers `systemGestureOwnedTouchIDs` (that would silence its
        /// own subsequent `didTwoFingerGesture` callbacks for the rest of
        /// the same gesture — the exact bug a real-device trace caught:
        /// `beginViewportManipulation` used to call this directly).
        private func cancelTouchForGestureOwnership() {
            systemGestureOwnedTouchIDs.formUnion(activeFingerTouchIDs)
            cancelPointerAndLegacyTouchState()
        }

        /// The shared cleanup a touch-sequence takeover needs regardless of
        /// who's taking it over: releases whatever the legacy (non-pointer-
        /// wire) click path had pending, resets `pointerEngine` (any held
        /// button, any tracked touch), and cancels remote-scroll momentum —
        /// so the outgoing owner can never keep acting on a touch stream
        /// that's no longer theirs. Deliberately does NOT touch
        /// `systemGestureOwnedTouchIDs`/`activeFingerTouchIDs` — that
        /// decision (is this an external system gesture, or a still-local
        /// viewport pinch/pan?) belongs entirely to the caller; see
        /// `cancelTouchForGestureOwnership` (external) vs
        /// `beginViewportManipulation` (local).
        private func cancelPointerAndLegacyTouchState() {
            for action in ReceiverTouchOwnership.cancellationActions(downWasSent: downSent) {
                switch action {
                case .sendCancellation:
                    receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y)
                case .discardPendingPress:
                    discardPendingDown()
                }
            }
            // A fresh scroll/pinch (or system gesture) winning ownership of
            // touches the M7 pointer engine may also have been tracking —
            // release any button it already committed and forget its
            // state, so the two systems can never both act on the same
            // touch stream.
            resetPointerEngine()
            // ...and any remote-scroll momentum from a still-coasting
            // PREVIOUS scroll — a system gesture or pointer chord taking
            // ownership now must not leave stale momentum ticking.
            cancelScrollMomentum()
        }

        // A press is only a click once we know a second finger is not coming.
        // Sending `began` on contact posted a mouse-down we then had to take
        // back, and taking it back only works when UIKit happens to deliver
        // `cancelled`; when the pan recognizer misses and we get a plain
        // `ended` instead, that down/up pair *is* a click, which is why every
        // other two-finger scroll opened whatever sat under the first finger.
        // So hold the down until the gesture commits to being one.
        private var pendingDown: (x: Double, y: Double)?
        private var downSent = false
        private var holdTimer: DispatchWorkItem?

        /// Movement (in points) that turns a held press into a drag.
        private let dragSlop: CGFloat = 10
        /// A press this long with no second finger is a deliberate hold, so
        /// commit it: press-and-hold menus and drag handles need the button.
        private let holdDelay: TimeInterval = 0.12
        private var pendingDownPoint: CGPoint = .zero

        /// Emit the withheld `began`, at the point the finger first landed so a
        /// drag starts where the user touched rather than where slop was crossed.
        private func commitPendingDown() {
            guard let p = pendingDown, !downSent else { return }
            downSent = true
            holdTimer?.cancel()
            holdTimer = nil
            // M4 typing-focus anchor: the primary single-finger press is
            // the "meaningful primary interaction" (PRODUCT/FOCUS rules).
            noteAnchorIfOnDisplay(viewPoint: pendingDownPoint, normalized: CGPoint(x: p.x, y: p.y))
            receiver?.sendTouch(phase: "began", x: p.x, y: p.y)
        }

        /// Drop the press without a trace. Nothing reached the Mac, so there is
        /// no button to release and no click to suppress.
        private func discardPendingDown() {
            pendingDown = nil
            downSent = false
            holdTimer?.cancel()
            holdTimer = nil
        }

        private func send(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            let fingers = touches.filter { isFinger($0) }
            guard !fingers.isEmpty else { return }
            // Ignore single-finger events while a two-finger gesture runs,
            // and end the click if a second finger joins mid-press.
            if twoFingerActive || (event?.allTouches?.filter { isFinger($0) }.count ?? 1) > 1 {
                if downSent {
                    receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y)
                }
                discardPendingDown()
                return
            }
            guard let touch = fingers.first,
                  let norm = normalized(touch.location(in: self)) else { return }
            lastNorm = norm

            switch phase {
            case "began":
                let location = touch.location(in: self)
                pendingDown = norm
                pendingDownPoint = location
                downSent = false
                let work = DispatchWorkItem { [weak self] in self?.commitPendingDown() }
                holdTimer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + holdDelay, execute: work)
                return
            case "ended":
                // A tap: nothing was posted yet, so post the whole click now.
                if pendingDown != nil, !downSent { commitPendingDown() }
                // No down means the press was already discarded (a second
                // finger took it), so there is nothing to release.
                if downSent { receiver?.sendTouch(phase: "ended", x: norm.x, y: norm.y) }
                discardPendingDown()
                return
            case "cancelled":
                if downSent {
                    receiver?.sendTouch(phase: "cancelled", x: norm.x, y: norm.y)
                }
                discardPendingDown()
                return
            case "moved":
                if pendingDown != nil, !downSent {
                    let moved = hypot(touch.location(in: self).x - pendingDownPoint.x,
                                      touch.location(in: self).y - pendingDownPoint.y)
                    // Below slop the finger is still deciding: track the cursor
                    // (the Mac turns a move without a down into mouseMoved) but
                    // keep the button up so a second finger can still cancel.
                    if moved > dragSlop { commitPendingDown() }
                }
            default:
                break
            }

            if phase == "moved", let event {
                // Forward every coalesced sample so the Mac gets the full-rate
                // drag, then UIKit's predicted touch so the cursor leads toward
                // where the finger will be (~1 frame of perceived latency back;
                // corrected by the next real sample).
                for t in event.samples(for: touch) {
                    if let n = normalized(t.location(in: self)) {
                        lastNorm = n
                        receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                    }
                }
                if let predicted = event.predictedTouches(for: touch)?.last,
                   let n = normalized(predicted.location(in: self)) {
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
                return
            }
            receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
        }

        // MARK: - M7 pointer/click gestures

        /// Feeds every finger touch in this batch to `pointerEngine` and
        /// dispatches whatever commands come back. Only called when the
        /// connected Mac speaks the pv5 `pointer` wire — see
        /// `routeTouches`.
        private func handlePointerFingerTouches(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            #if DEBUG
            // Checkpoint C — remove once root-caused.
            Log.info("inputTrace: handlePointerFingerTouches phase=\(phase) touches=\(touches.count) "
                     + "engineMode=\(pointerEngine.mode) inputMode=\(pointerEngine.inputMode)")
            #endif
            for touch in touches {
                let viewPoint = touch.location(in: self)
                let norm = normalized(viewPoint).map { CGPoint(x: $0.x, y: $0.y) }
                let enginePhase: PointerTouchSample.Phase
                switch phase {
                case "began": enginePhase = .began
                case "moved": enginePhase = .moved
                case "ended": enginePhase = .ended
                case "cancelled": enginePhase = .cancelled
                default: return
                }
                let sample = PointerTouchSample(id: AnyHashable(ObjectIdentifier(touch)), phase: enginePhase,
                                                viewPoint: viewPoint, normalized: norm, time: touch.timestamp)
                let commands = pointerEngine.handle(sample)
                dispatchPointerCommands(commands)
                // The single-finger primary press is the M4 typing-focus
                // anchor, same as the legacy path's `commitPendingDown`.
                if (phase == "began" || phase == "moved"), let n = norm,
                   (event?.allTouches?.filter { isFinger($0) }.count ?? 1) == 1 {
                    noteAnchorIfOnDisplay(viewPoint: viewPoint, normalized: n)
                }
            }
            schedulePointerPoll()
        }

        private func dispatchPointerCommands(_ commands: [PointerCommand]) {
            #if DEBUG
            // Checkpoint D — remove once root-caused.
            if !commands.isEmpty {
                Log.info("inputTrace: dispatchPointerCommands count=\(commands.count) hasReceiver=\(receiver != nil)")
            }
            #endif
            guard !commands.isEmpty, let receiver else { return }
            // Only `.moveRelative` needs a valid video size (to convert
            // through the viewport scale) — button down/up MUST still post
            // even if it's momentarily unknown, so this isn't a guard on
            // the whole function (a dropped mouseUp would leave the Mac
            // with a stuck button).
            let video = receiver.videoSize
            for command in commands {
                switch command {
                case .moveAbsolute(let x, let y):
                    receiver.sendPointerMove(x: x, y: y)
                case .moveRelative(let dx, let dy):
                    guard let scale = pointsPerRemotePixel(video: video) else { continue }
                    receiver.sendPointerMoveRelative(dx: dx / scale, dy: dy / scale)
                case .mouseDown(let button, let clickCount):
                    receiver.sendPointerDown(button: button, clickCount: clickCount)
                    if button == .right {
                        // Preempt the legacy scroll/pinch recognizer from
                        // also claiming these same two touches — see
                        // `PointerGestureEngine.isChordContinuation`'s doc.
                        twoFingerRecognizer?.isEnabled = false
                        twoFingerRecognizer?.isEnabled = true
                    }
                case .mouseUp(let button, let clickCount):
                    receiver.sendPointerUp(button: button, clickCount: clickCount)
                }
            }
        }

        /// Re-polls for the next engine deadline. The engine reports pending
        /// work independently from pointer-session ownership, so click
        /// chains still resolve while their anchor remains on screen and
        /// right taps still resolve after the chord returns to idle.
        private func schedulePointerPoll() {
            pointerPollTimer?.cancel()
            guard let delay = pointerEngine.pollDelay(now: CACurrentMediaTime()) else {
                pointerPollTimer = nil
                return
            }
            let work = DispatchWorkItem { [weak self] in self?.runPointerPoll() }
            pointerPollTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func runPointerPoll() {
            dispatchPointerCommands(pointerEngine.poll(now: CACurrentMediaTime()))
            schedulePointerPoll()
        }

        private func sendPencilAsTouch(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?) {
            guard let touch = touches.first,
                  let norm = normalized(touch.location(in: self)) else { return }
            lastNorm = norm
            // Pre-pv3-pencil-wire fallback: "began" is this path's down.
            if phase == "began" { noteAnchorFromNormalized(x: norm.x, y: norm.y) }
            if phase == "moved", let event {
                for t in event.samples(for: touch) {
                    if let n = normalized(t.location(in: self)) {
                        lastNorm = n
                        receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                    }
                }
                if let predicted = event.predictedTouches(for: touch)?.last,
                   let n = normalized(predicted.location(in: self)) {
                    receiver?.sendTouch(phase: "moved", x: n.x, y: n.y)
                }
                return
            }
            receiver?.sendTouch(phase: phase, x: norm.x, y: norm.y)
        }

        private func routeTouches(_ phase: String, _ touches: Set<UITouch>, _ event: UIEvent?, ended: Bool) {
            #if DEBUG
            // TEMP diagnostic for the "all input dead" regression report —
            // remove once root-caused. Checkpoint A/B: confirms touches are
            // physically reaching VideoView and being routed, plus the
            // gating state that decides whether anything downstream can
            // act on them.
            Log.info("inputTrace: routeTouches phase=\(phase) touches=\(touches.count) "
                     + "allowsInput=\(allowsInput) macSupportsPointerWire=\(receiver?.macSupportsPointerWire ?? false) "
                     + "displayState=\(String(describing: receiver?.displayState)) connected=\(receiver?.connected ?? false)")
            #endif
            if phase == "began" {
                let admitted = touches.filter {
                    (videoEnabled && pointerEngine.inputMode != .direct)
                        || currentTransform.containsViewPoint($0.location(in: self))
                }
                for touch in touches {
                    surfaceAdmission.begin(ObjectIdentifier(touch), inside: admitted.contains(touch))
                }
            }
            let routedTouches = touches.filter {
                surfaceAdmission.contains(ObjectIdentifier($0))
            }
            let pencil = routedTouches.filter { isPencil($0) }
            let allFingers = routedTouches.filter { isFinger($0) }
            let usePencilWire = receiver?.macSupportsPencilWire ?? false

            if !pencil.isEmpty {
                if usePencilWire {
                    inputEngine.handle(pencil, event: event, ended: ended)
                } else {
                    sendPencilAsTouch(phase, pencil, event)
                }
            }

            if phase == "began" {
                activeFingerTouchIDs.formUnion(allFingers.map(ObjectIdentifier.init))
            }
            // A touch a system gesture already claimed stays consumed for
            // the rest of its physical lifetime, including this final
            // `ended`/`cancelled` sample — see `systemGestureOwnedTouchIDs`.
            let finger = allFingers.filter { !systemGestureOwnedTouchIDs.contains(ObjectIdentifier($0)) }
            if ended {
                for touch in allFingers {
                    let id = ObjectIdentifier(touch)
                    activeFingerTouchIDs.remove(id)
                    let wasOwned = systemGestureOwnedTouchIDs.remove(id) != nil
                    let releasedNow = wasOwned && systemGestureOwnedTouchIDs.isEmpty
                    // The last owned touch ending is what makes it SAFE to
                    // reset `twoFingerRecognizer`/`viewportDoubleTapRecognizer`'s
                    // own session (below) — but only once no touch of ANY
                    // kind, owned or not, is still physically down. A fresh
                    // (unowned) touch can genuinely overlap the tail of a
                    // draining system sequence — it's routed to
                    // `pointerEngine` completely normally the moment it
                    // isn't owned, and that's already correct — but toggling
                    // `isEnabled` while THAT touch is still live would
                    // reintroduce the exact bug this replaced, just for the
                    // overlapping sequence instead of the drained one.
                    // `recognizerResetPending` defers the toggle until a
                    // later touch end (of the overlapping touch itself, or
                    // whatever ends last) actually brings `activeFingerTouchIDs`
                    // to zero too — never sooner.
                    if releasedNow { recognizerResetPending = true }
                }
                if recognizerResetPending, activeFingerTouchIDs.isEmpty {
                    recognizerResetPending = false
                    twoFingerRecognizer?.isEnabled = false
                    twoFingerRecognizer?.isEnabled = true
                    viewportDoubleTapRecognizer?.isEnabled = false
                    viewportDoubleTapRecognizer?.isEnabled = true
                }
                for touch in touches { surfaceAdmission.end(ObjectIdentifier(touch)) }
            }

            // Palm rejection: ignore resting fingers while the pen is down.
            if !finger.isEmpty && !inputEngine.hasActivePen {
                if receiver?.macSupportsPointerWire ?? false {
                    handlePointerFingerTouches(phase, finger, event)
                } else {
                    send(phase, finger, event)
                }
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            // Any new touch beginning — pointer, chord, pinch, system
            // gesture, or a fresh scroll's own first samples — cancels a
            // still-coasting momentum phase immediately (PRODUCT RULE:
            // "touching again immediately cancels any active momentum").
            // `beginScroll` also cancels it explicitly for the specific
            // fresh-scroll case; this is the catch-all for every other one.
            cancelScrollMomentum()
            routeTouches("began", touches, event, ended: false)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("moved", touches, event, ended: false)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("ended", touches, event, ended: true)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            routeTouches("cancelled", touches, event, ended: true)
        }
    }
}

/// Recognizes a three-finger tap and fails as soon as any contact moves beyond
/// the shared threshold, allowing the existing three-finger pan to take over.
final class ThreeFingerTapGestureRecognizer: UIGestureRecognizer {
    private var initialLocations: [ObjectIdentifier: CGPoint] = [:]
    private var activeTouches = Set<ObjectIdentifier>()
    private(set) var maximumMovement = 0.0
    var recognizedTouchCount: Int { initialLocations.count }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard state == .possible,
              touches.allSatisfy({ $0.type == .direct }),
              let view else {
            state = .failed
            return
        }
        for touch in touches {
            let identifier = ObjectIdentifier(touch)
            initialLocations[identifier] = touch.location(in: view)
            activeTouches.insert(identifier)
        }
        if initialLocations.count > 3 { state = .failed }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard state == .possible, let view else { return }
        updateMovement(for: touches, in: view)
        if maximumMovement > ReceiverGesture.threeFingerTapMaximumMovement {
            state = .failed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard state == .possible, let view else { return }
        updateMovement(for: touches, in: view)
        guard maximumMovement <= ReceiverGesture.threeFingerTapMaximumMovement else {
            state = .failed
            return
        }
        for touch in touches { activeTouches.remove(ObjectIdentifier(touch)) }
        guard activeTouches.isEmpty else { return }
        if ReceiverGesture.threeFingerTap(touchCount: initialLocations.count,
                                          maximumMovement: maximumMovement) != nil {
            state = .recognized
        } else {
            state = .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        initialLocations.removeAll()
        activeTouches.removeAll()
        maximumMovement = 0
    }

    private func updateMovement(for touches: Set<UITouch>, in view: UIView) {
        for touch in touches {
            guard let start = initialLocations[ObjectIdentifier(touch)] else { continue }
            let current = touch.location(in: view)
            let dx = Double(current.x - start.x)
            let dy = Double(current.y - start.y)
            maximumMovement = max(maximumMovement, (dx * dx + dy * dy).squareRoot())
        }
    }
}

/// Recognizes deliberate pinch/spread gestures made with four or five direct
/// contacts. The receiver measures every active fingertip pair and preserves
/// one gesture session when the active count changes between four and five.
final class PinchSpreadSystemGestureRecognizer: UIGestureRecognizer {
    private var activeTouches: [ObjectIdentifier: UITouch] = [:]
    private var spreadSession = ReceiverGestureSpreadSession()
    private(set) var recognizedGesture: ReceiverGesture?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touches.allSatisfy({ $0.type == .direct }) else {
            state = .failed
            return
        }
        for touch in touches { activeTouches[ObjectIdentifier(touch)] = touch }
        updateSpreadSession()
        if activeTouches.count > 5 {
            finishWithoutActionIfNeeded()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { activeTouches[ObjectIdentifier(touch)] = touch }
        updateSpreadSession()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { activeTouches.removeValue(forKey: ObjectIdentifier(touch)) }
        guard activeTouches.count >= 4 else {
            updateSpreadSession()
            finishWithoutActionIfNeeded()
            return
        }
        updateSpreadSession()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        state = .cancelled
    }

    override func reset() {
        super.reset()
        activeTouches.removeAll()
        spreadSession.reset()
        recognizedGesture = nil
    }

    private func updateSpreadSession() {
        let touchCount = activeTouches.count
        guard let spread = currentSpread() else {
            if touchCount < 4 { _ = spreadSession.update(touchCount: touchCount, spread: 0) }
            if touchCount > 5 { _ = spreadSession.update(touchCount: touchCount, spread: 0) }
            return
        }
        let gesture = spreadSession.update(touchCount: touchCount, spread: spread)
        if let gesture {
            recognizedGesture = gesture
            state = .began
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    private func finishWithoutActionIfNeeded() {
        if state == .began || state == .changed {
            state = .ended
        } else {
            state = .failed
        }
    }

    private func currentSpread() -> Double? {
        guard let view else { return nil }
        let points = activeTouches.values.map { touch in
            let point = touch.location(in: view)
            return (x: Double(point.x), y: Double(point.y))
        }
        return ReceiverGestureGeometry.meanPairwiseDistance(points)
    }
}

/// The single owner of every two-finger gesture on the video view: ordinary
/// remote-Mac scroll, local viewport pinch-zoom, and (once a pinch/zoom
/// session is already under way) local viewport pan.
///
/// An earlier version used *two* independent recognizers — a plain
/// `UIPanGestureRecognizer` for scroll and a separate custom one for
/// viewport pinch/pan — racing each other and reconciled with `isEnabled`
/// toggling. That produced exactly the failure mode this replaces:
/// unreliable scrolling at 1x (whichever recognizer happened to win a given
/// frame), and, worse, a rule that treated *any* small two-finger movement
/// while already manually zoomed as viewport pan, which made remote
/// scrolling effectively impossible whenever zoomed in.
///
/// This recognizer instead makes the three-way choice exactly once per
/// touch-down sequence and then holds it: `intent` starts `.undecided` and,
/// once `TwoFingerGestureClassifier.classify` returns a real answer, is
/// fixed for the rest of the gesture — the state transitions to `.began`
/// only at that moment, so `VideoView`'s action method never has to
/// re-decide anything, only branch on `intent` (see
/// `VideoView.didTwoFingerGesture`). "Viewport pan while already zoomed" is
/// not a separate state: once `intent == .viewportZoomPan`, every
/// subsequent `.changed` sample (whether it looks like more pinching or
/// pure dragging) is fed through the same `ManualViewportState.pinching`
/// math, which already degrades to pure pan when the distance ratio stops
/// changing — so a pinch-then-drag-without-lifting session naturally zooms
/// and then pans within one continuous, single-owner gesture, and lifting
/// fingers (`reset()`) is the only thing that returns to `.undecided` for
/// the next fresh two-finger touch.
final class TwoFingerViewportGestureRecognizer: UIGestureRecognizer {
    private var activeTouches: [ObjectIdentifier: UITouch] = [:]
    private var orderedTouchIDs: [ObjectIdentifier] = []
    private(set) var initialMidpoint: CGPoint = .zero
    private var initialDistance: CGFloat = 0
    private(set) var midpoint: CGPoint = .zero
    private var distance: CGFloat = 0
    private var initialAngle: CGFloat = 0
    private var angle: CGFloat = 0

    /// Fixed for the lifetime of a gesture once it leaves `.undecided` —
    /// see the type doc's "acquire ownership and keep it" contract. Backed
    /// by the pure, independently-testable `TwoFingerGestureSession` rather
    /// than duplicating its commit-once logic here.
    private var session = TwoFingerGestureSession()
    var intent: TwoFingerGestureIntent { session.intent }

    /// `distance / initialDistance`, i.e. how much the two fingers have
    /// spread or pinched since the gesture started; `1` (no-op) until
    /// there is a valid baseline to compare against.
    var scaleRatio: CGFloat {
        guard initialDistance > 0 else { return 1 }
        return distance / initialDistance
    }

    var rotationDelta: CGFloat {
        ManualViewportState.normalizedAngle(angle - initialAngle)
    }

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let view, touches.allSatisfy({ $0.type == .direct }) else {
            state = .failed
            return
        }
        for touch in touches {
            let id = ObjectIdentifier(touch)
            activeTouches[id] = touch
            if !orderedTouchIDs.contains(id) { orderedTouchIDs.append(id) }
        }
        // A third touch landing means this is not (or is no longer) a
        // two-finger gesture — cleanly hand off to 3+-finger system
        // gestures. `.failed` is only a legal transition from `.possible`;
        // once already committed (`.began`/`.changed`) use `.cancelled`
        // instead so a mid-scroll or mid-viewport-manipulation third finger
        // doesn't hit an invalid state transition.
        guard activeTouches.count <= 2 else {
            state = (state == .began || state == .changed) ? .cancelled : .failed
            return
        }
        guard activeTouches.count == 2 else { return }
        let points = orderedTouchIDs.compactMap { activeTouches[$0]?.location(in: view) }
        initialMidpoint = Self.midpoint(points)
        initialDistance = Self.distance(points)
        initialAngle = Self.angle(points)
        midpoint = initialMidpoint
        distance = initialDistance
        angle = initialAngle
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard state == .possible || state == .began || state == .changed,
              activeTouches.count == 2, let view else { return }
        let points = orderedTouchIDs.compactMap { activeTouches[$0]?.location(in: view) }
        midpoint = Self.midpoint(points)
        distance = Self.distance(points)
        angle = Self.angle(points)
        guard distance.isFinite else { return }
        if state == .possible {
            let classified = session.update(
                initialDistance: initialDistance, currentDistance: distance,
                initialMidpoint: initialMidpoint, currentMidpoint: midpoint,
                rotationDelta: rotationDelta)
            guard classified != .undecided else { return }
            state = .began
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { activeTouches.removeValue(forKey: ObjectIdentifier(touch)) }
        state = (state == .began || state == .changed) ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { activeTouches.removeValue(forKey: ObjectIdentifier(touch)) }
        state = .cancelled
    }

    override func reset() {
        super.reset()
        activeTouches.removeAll()
        orderedTouchIDs.removeAll()
        initialMidpoint = .zero
        initialDistance = 0
        midpoint = .zero
        distance = 0
        initialAngle = 0
        angle = 0
        session = TwoFingerGestureSession()
    }

    private static func midpoint(_ points: [CGPoint]) -> CGPoint {
        guard points.count == 2 else { return .zero }
        return CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2)
    }

    private static func distance(_ points: [CGPoint]) -> CGFloat {
        guard points.count == 2 else { return 0 }
        return hypot(points[0].x - points[1].x, points[0].y - points[1].y)
    }

    private static func angle(_ points: [CGPoint]) -> CGFloat {
        guard points.count == 2 else { return 0 }
        return atan2(points[1].y - points[0].y, points[1].x - points[0].x)
    }
}

// MARK: - Apple Pencil capture

/// Captures Apple Pencil hover and stroke on a host view.
/// Finger touches stay on VideoView's existing `touch` wire path.
///
/// TODO: Capture Apple Pencil Pro barrel roll (UIKit rollAngle, iOS 17.5+) once
/// hardware is available for testing.
@MainActor
final class InputCaptureEngine: NSObject {
    var onPencil: ((_ phase: String, _ x: Double, _ y: Double,
                    _ pressure: Double, _ azimuth: Double, _ altitude: Double) -> Void)?
    var onProximity: ((_ entering: Bool, _ x: Double, _ y: Double) -> Void)?

    /// True while at least one pen contact is on the glass (palm rejection).
    var hasActivePen: Bool { !activePens.isEmpty }

    /// Map a point in the host view to normalized video coordinates.
    var normalize: ((CGPoint) -> (x: Double, y: Double)?)?

    private weak var hostView: UIView?
    private var activePens: Set<UInt64> = []
    private var proximityActive = false

    func install(on view: UIView) {
        hostView = view
        view.isMultipleTouchEnabled = true

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
        hover.allowedTouchTypes = [UITouch.TouchType.pencil.rawValue as NSNumber]
        view.addGestureRecognizer(hover)
    }

    func cancelForDisplayPause() {
        activePens.removeAll()
        proximityActive = false
    }

    @objc private func hoverChanged(_ gr: UIHoverGestureRecognizer) {
        guard activePens.isEmpty, let view = hostView else { return }
        guard let n = normalize?(gr.location(in: view)) else { return }
        switch gr.state {
        case .began:
            openProximity(x: n.x, y: n.y)
            fallthrough
        case .changed:
            let azimuth = Double(gr.azimuthAngle(in: view))
            let altitude = Double(gr.altitudeAngle)
            onPencil?("hover", n.x, n.y, 0, azimuth, altitude)
        case .ended, .cancelled, .failed:
            guard activePens.isEmpty else { return }
            closeProximity(x: n.x, y: n.y)
        default:
            break
        }
    }

    func handle(_ touches: Set<UITouch>, event: UIEvent?, ended: Bool) {
        guard hostView != nil else { return }
        for touch in touches where touch.type == .pencil {
            emitPen(touch, event: event, ended: ended)
        }
    }

    private func openProximity(x: Double, y: Double) {
        guard !proximityActive else { return }
        proximityActive = true
        onProximity?(true, x, y)
    }

    private func closeProximity(x: Double, y: Double) {
        guard proximityActive else { return }
        proximityActive = false
        onProximity?(false, x, y)
    }

    private func emitPen(_ touch: UITouch, event: UIEvent?, ended: Bool) {
        guard let view = hostView else { return }
        let id = UInt64(bitPattern: Int64(ObjectIdentifier(touch).hashValue))
        let loc = touch.location(in: view)
        guard let n = normalize?(loc) else { return }
        let (nx, ny) = (n.x, n.y)

        let pressure = min(Double(touch.force), 1.0)
        let azimuth = Double(touch.azimuthAngle(in: view))
        let altitude = Double(touch.altitudeAngle)

        if !ended && !activePens.contains(id) {
            activePens.insert(id)
            openProximity(x: nx, y: ny)
            emitPencil("down", x: nx, y: ny, pressure: pressure,
                       azimuth: azimuth, altitude: altitude)
            return
        }

        if !ended {
            for c in event?.samples(for: touch) ?? [touch] {
                guard let cn = normalize?(c.location(in: view)) else { continue }
                emitPencil("move", x: cn.x, y: cn.y,
                           pressure: min(Double(c.force), 1.0),
                           azimuth: Double(c.azimuthAngle(in: view)),
                           altitude: Double(c.altitudeAngle))
            }
            return
        }

        defer { activePens.remove(id) }
        emitPencil("up", x: nx, y: ny, pressure: 0,
                   azimuth: azimuth, altitude: altitude)
        closeProximity(x: nx, y: ny)
    }

    private func emitPencil(_ phase: String, x: Double, y: Double,
                            pressure: Double, azimuth: Double, altitude: Double) {
        onPencil?(phase, x, y, pressure, azimuth, altitude)
    }
}
