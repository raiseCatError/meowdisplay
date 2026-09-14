import SwiftUI
import AVFoundation
import UIKit
import Combine

/// "iPad" or "iPhone" — so UI copy names the device the user is holding.
let deviceKind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"

/// Landing page — hosts the Mac app download and explains the two-app setup.
let macAppURL = URL(string: "https://peetzweg.github.io/opendisplay/")!

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
    @State private var showSettings = false
    @State private var showOnboarding = false
    @State private var nagDismissed = false
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

    // Streaming = connected and the video format is known.
    private var isStreaming: Bool {
        model.receiver.connected && model.receiver.videoSize != .zero
    }

    // The floating keyboard button is offered only while keyboard input can
    // actually reach the Mac: streaming, not paused, and the connected Mac
    // is new enough to understand `keyboard` wire messages. (Allow Input off
    // isn't observable from the receiver today — same as touch/pencil, the
    // Mac silently drops the input instead.)
    private var keyboardAvailable: Bool {
        isStreaming && model.receiver.displayState == .running && model.receiver.macSupportsKeyboardWire
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
            ZStack {
                if isStreaming {
                    Color.black.ignoresSafeArea()
                    VideoLayerView(displayLayer: model.receiver.displayLayer,
                                   receiver: model.receiver,
                                   useMetal: metalRenderer,
                                   zoomWhileTyping: zoomWhileTyping,
                                   keyboardRequested: keyboardActive)
                        .id(metalRenderer)   // rebuild the layer tree on toggle
                        .ignoresSafeArea()
                        .allowsHitTesting(model.receiver.displayState == .running)
                    if model.receiver.displayState == .paused {
                        VStack(spacing: 8) {
                            Text("Display Paused")
                                .font(.headline)
                            Text("Resume from OpenDisplay on your Mac.")
                                .font(.subheadline)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
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
                    // M4: temporary floating keyboard button — evolves into
                    // the full M5 floating control. The responder view has
                    // no visual footprint; only the button is visible.
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
                    if keyboardAvailable {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Button {
                                    keyboardActive.toggle()
                                } label: {
                                    Image(systemName: keyboardActive
                                          ? "keyboard.chevron.compact.down" : "keyboard")
                                        .font(.title2)
                                        .foregroundStyle(.white)
                                        .padding(12)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                                .padding(.trailing, 16)
                                .padding(.bottom, 24)
                            }
                        }
                    }
                } else {
                    IdleView(receiver: model.receiver, showSettings: $showSettings)
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
        .ignoresSafeArea(edges: isStreaming ? .all : [])
        .statusBarHidden(isStreaming)
        .persistentSystemOverlays(isStreaming ? .hidden : .automatic)
        .sheet(isPresented: $showSettings) {
            SettingsView(receiver: model.receiver)
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
        .task { await versionGate.check() }
        // Merge the connected Mac's compatibility signal into the same gate.
        .onReceive(model.receiver.$peerSignal) { versionGate.applyPeer($0) }
        .onReceive(NotificationCenter.default.publisher(for: .deviceDidShake)) { _ in
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
            model.start()
            // Show the first-run hint unless the device has connected before
            // or the user already dismissed it.
            if !hasConnectedBefore && !onboardingDismissed {
                showOnboarding = true
            }
        }
    }
}

// MARK: - Idle view (no Mac connected) — regular iOS look, follows light/dark

struct IdleView: View {
    @ObservedObject var receiver: StreamReceiver
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 132)

            VStack(spacing: 6) {
                Text("OpenDisplay")
                    .font(.largeTitle.bold())
                HStack(spacing: 8) {
                    Circle()
                        .fill(receiver.connected ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(receiver.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                Label("Plug in the USB cable and start the Mac app",
                      systemImage: "cable.connector")
                Label("Or choose this \(deviceKind) under WiFi in the Mac app",
                      systemImage: "wifi")
                Label("Keep this app open — streaming starts automatically",
                      systemImage: "play.circle")
            }
            .font(.subheadline)
            .padding(20)
            .frame(maxWidth: 420)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16))

            Spacer()

            Button {
                showSettings = true
            } label: {
                Label("Settings & Help", systemImage: "gearshape")
            }
            .buttonStyle(.bordered)

            Text("Tip: shake the \(deviceKind) to open settings anytime")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

// MARK: - First-run onboarding (the Mac app is required to connect)

/// Shown on first launch / while the device has never connected: OpenDisplay
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
                        Text("OpenDisplay turns this \(deviceKind) into a second screen for your Mac — but it needs the **OpenDisplay Mac app** running on a Mac connected by the same USB cable or on the same WiFi network.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Label("Install the OpenDisplay Mac app on your Mac", systemImage: "1.circle.fill")
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
    @Environment(\.dismiss) private var dismiss
    @AppStorage("showAnalytics") private var showAnalytics = false
    @AppStorage("metalRenderer") private var metalRenderer = false
    @AppStorage("zoomWhileTyping") private var zoomWhileTyping = true

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    LabeledContent("Listening", value: "Port 9000")
                    LabeledContent("Connection",
                                   value: receiver.connected ? receiver.status : "Waiting for Mac")
                    if receiver.videoSize != .zero {
                        LabeledContent("Stream",
                                       value: "\(Int(receiver.videoSize.width))×\(Int(receiver.videoSize.height)) @ \(receiver.fps) fps")
                    }
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
                    Toggle("Performance overlay", isOn: $showAnalytics)
                    Toggle("Metal renderer (experimental)", isOn: $metalRenderer)
                } header: {
                    Text("Analytics")
                } footer: {
                    Text("The overlay shows FPS, bitrate, frame timing, stalls, and latency graphs at the bottom of the screen while streaming. The experimental Metal renderer decodes and presents frames manually — it adds decode and true on-glass latency metrics to the overlay, but in our measurements the system video layer displays frames faster. Leave it off unless you're debugging.")
                }

                Section {
                    Button("Open iOS Settings for OpenDisplay") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("Permissions")
                } footer: {
                    Text("WiFi mode needs Local Network access. If your Mac can't find this \(deviceKind), enable it under Settings → Privacy & Security → Local Network → OpenDisplay. USB mode works without it.")
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
                    Text("OpenDisplay needs the Mac app running on a Mac on the same cable or WiFi network. Download it here if you haven't yet.")
                }

                Section("About") {
                    LabeledContent("Version", value: version)
                    Link(destination: URL(string: "https://github.com/peetzweg/opendisplay")!) {
                        Label("GitHub — peetzweg/opendisplay", systemImage: "link")
                    }
                    Link(destination: macAppURL) {
                        Label("Website", systemImage: "globe")
                    }
                }
            }
            .navigationTitle("OpenDisplay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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

// MARK: - Model

@MainActor
final class ReceiverModel: ObservableObject {
    let receiver: StreamReceiver
    private var started = false
    private var cancellables = Set<AnyCancellable>()

    init() {
        receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                  deviceKind: deviceKind,
                                  fallbackServiceName: UIDevice.current.name)
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
        receiver.start(port: 9000)
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
    }

    func sceneDidActivate() {
        endBackgroundAssertion()
        receiver.setRenderingPaused(false)
        receiver.ensureListening()
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

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.backgroundColor = .black
        view.isMultipleTouchEnabled = true
        view.receiver = receiver
        view.setZoomWhileTyping(zoomWhileTyping)
        view.setKeyboardRequested(keyboardRequested)
        receiver.onDisplayStateChange = { [weak view] state in
            if state == .paused { view?.clearInputStateForPause() }
        }
        if receiver.displayState == .paused { view.clearInputStateForPause() }

        Log.info("video view: metal=\(useMetal)")
        if useMetal, let renderer = MetalVideoRenderer() {
            Log.info("metal renderer active")
            view.metalRenderer = renderer
            view.layer.addSublayer(renderer.metalLayer)
            receiver.onDecodedFrame = { [weak renderer] pixelBuffer, captureMs in
                renderer?.render(pixelBuffer, captureMs: captureMs)
            }
            renderer.onPresented = { [weak receiver] presentedTime, captureMs in
                receiver?.recordPresented(presentedTime: presentedTime, captureMs: captureMs)
            }
        } else {
            receiver.onDecodedFrame = nil   // route frames back to AVSBDL
            displayLayer.frame = view.bounds
            view.layer.addSublayer(displayLayer)
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
        // videoSize arrives after the format description — re-fit the layers.
        uiView.setNeedsLayout()
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
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unsupported") }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func setZoomWhileTyping(_ enabled: Bool) {
            guard enabled != zoomWhileTypingEnabled else { return }
            zoomWhileTypingEnabled = enabled
            guard keyboardVisibleRect != nil else { return }   // only matters while open
            animateTransformChange(duration: 0.25, options: .curveEaseInOut)
        }

        func setKeyboardRequested(_ requested: Bool) {
            guard requested != keyboardRequested else { return }
            keyboardRequested = requested
            guard !requested, keyboardVisibleRect != nil else { return }
            // Explicit close (Done / the floating button) restores normal
            // presentation immediately rather than waiting on the system's
            // hide notification, which this view now ignores anyway.
            keyboardVisibleRect = nil
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
            // Force the two-finger recognizer to give up whatever it was
            // mid-deciding or already committed to — toggling `isEnabled`
            // is UIKit's standard way to force a recognizer to `.cancelled`
            // (same trick used elsewhere for gesture-ownership hand-off).
            twoFingerRecognizer?.isEnabled = false
            twoFingerRecognizer?.isEnabled = true
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateCurrentTransform()
            let normalRect = RemoteViewportCalculator.normal(
                viewBounds: bounds, remoteAspectSize: receiver?.videoSize ?? .zero).displayedRect
            let applyContent = {
                if let renderer = self.metalRenderer {
                    self.applyContentGeometry(renderer.metalLayer, normalRect: normalRect, transform: self.currentTransform)
                } else if let first = self.layer.sublayers?.first {
                    self.applyContentGeometry(first, normalRect: normalRect, transform: self.currentTransform)
                }
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

        private func updateCurrentTransform() {
            currentTransform = RemoteViewportCalculator.applyManualZoom(to: unzoomedBaseTransform(), state: manualZoom)
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
            layer.anchorPoint = CGPoint(x: transform.remoteCrop.minX, y: transform.remoteCrop.minY)
            layer.position = transform.displayedRect.origin
            layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
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
        }

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
            switch recognizer.state {
            case .began:
                switch recognizer.intent {
                case .scroll:
                    beginScroll(at: recognizer.midpoint)
                case .viewportZoomPan:
                    beginViewportManipulation()
                    applyViewportPinchUpdate(recognizer)
                case .undecided:
                    break   // never begins while undecided — see the recognizer.
                }
            case .changed:
                switch recognizer.intent {
                case .scroll:
                    continueScroll(recognizer)
                case .viewportZoomPan:
                    applyViewportPinchUpdate(recognizer)
                case .undecided:
                    break
                }
            default:
                twoFingerActive = false
            }
        }

        /// Ownership hand-off for the `.viewportZoomPan` intent, mirroring
        /// the existing system gestures' `takeGestureOwnershipAndSend` —
        /// this is the *only* place remote scroll/touch gets suppressed for
        /// a viewport gesture, and it happens once, at commitment, not on
        /// every frame — there is no second recognizer racing this one to
        /// coordinate against any more.
        private func beginViewportManipulation() {
            twoFingerActive = false
            cancelTouchForGestureOwnership()
            manualZoomGestureStart = manualZoom
            manualZoomGestureBase = unzoomedBaseTransform().displayedRect
        }

        private func applyViewportPinchUpdate(_ recognizer: TwoFingerViewportGestureRecognizer) {
            guard manualZoomGestureBase.width > 0, manualZoomGestureBase.height > 0 else { return }
            manualZoom = ManualViewportState.pinching(
                from: manualZoomGestureStart,
                initialBase: manualZoomGestureBase,
                initialMidpoint: recognizer.initialMidpoint,
                currentMidpoint: recognizer.midpoint,
                scaleRatio: recognizer.scaleRatio)
            setNeedsLayout()
            layoutIfNeeded()
        }

        private func beginScroll(at midpoint: CGPoint) {
            guard let video = receiver?.videoSize, video != .zero else { return }
            twoFingerActive = true
            lastPan = .zero
            // macOS delivers scroll to whatever sits under the cursor, and
            // the cursor no longer follows the fingers now that a press is
            // withheld until it commits. Put it on the gesture once, up
            // front, so the scroll lands on the window being touched. Once
            // only: a real trackpad does not drag the cursor while
            // scrolling, and moving it mid-gesture would change the target.
            if let n = normalized(midpoint) {
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
            receiver?.sendScroll(dx: (t.x - lastPan.x) / scale,
                                 dy: (t.y - lastPan.y) / scale)
            lastPan = t
        }

        @objc func didViewportDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, !manualZoom.isIdentity else { return }
            manualZoom = .identity
            animateTransformChange(duration: 0.25, options: .curveEaseInOut)
        }

        override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
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
            if gestureRecognizer === threeFingerPanRecognizer
                || gestureRecognizer === threeFingerTapRecognizer
                || gestureRecognizer === pinchSpreadGestureRecognizer {
                return touch.type == .direct
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
        private func cancelTouchForGestureOwnership() {
            for action in ReceiverTouchOwnership.cancellationActions(downWasSent: downSent) {
                switch action {
                case .sendCancellation:
                    receiver?.sendTouch(phase: "cancelled", x: lastNorm.x, y: lastNorm.y)
                case .discardPendingPress:
                    discardPendingDown()
                }
            }
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
            let pencil = touches.filter { isPencil($0) }
            let finger = touches.filter { isFinger($0) }
            let usePencilWire = receiver?.macSupportsPencilWire ?? false

            if !pencil.isEmpty {
                if usePencilWire {
                    inputEngine.handle(pencil, event: event, ended: ended)
                } else {
                    sendPencilAsTouch(phase, pencil, event)
                }
            }
            // Palm rejection: ignore resting fingers while the pen is down.
            if !finger.isEmpty && !inputEngine.hasActivePen {
                send(phase, finger, event)
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
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
    private(set) var initialMidpoint: CGPoint = .zero
    private var initialDistance: CGFloat = 0
    private(set) var midpoint: CGPoint = .zero
    private var distance: CGFloat = 0

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
        for touch in touches { activeTouches[ObjectIdentifier(touch)] = touch }
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
        let points = activeTouches.values.map { $0.location(in: view) }
        initialMidpoint = Self.midpoint(points)
        initialDistance = Self.distance(points)
        midpoint = initialMidpoint
        distance = initialDistance
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard state == .possible || state == .began || state == .changed,
              activeTouches.count == 2, let view else { return }
        let points = activeTouches.values.map { $0.location(in: view) }
        midpoint = Self.midpoint(points)
        distance = Self.distance(points)
        guard distance.isFinite else { return }
        if state == .possible {
            let classified = session.update(
                initialDistance: initialDistance, currentDistance: distance,
                initialMidpoint: initialMidpoint, currentMidpoint: midpoint)
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
        initialMidpoint = .zero
        initialDistance = 0
        midpoint = .zero
        distance = 0
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
}

// MARK: - Apple Pencil capture

/// Captures Apple Pencil hover and stroke on a host view.
/// Finger touches stay on VideoView's existing `touch` wire path.
///
/// TODO: Capture Apple Pencil Pro barrel roll (UIKit rollAngle, iOS 17.5+) once
/// hardware is available for testing.
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
