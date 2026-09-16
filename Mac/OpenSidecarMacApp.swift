import SwiftUI
import Network
import Combine
import Sparkle

/// How the app presents itself. One bundle, switched at runtime via the
/// activation policy — like Raycast/Hammerspoon style background agents.
enum AppPresentation: String, CaseIterable {
    case menuBar, dock, background

    var label: String {
        switch self {
        case .menuBar: return "Menu bar"
        case .dock: return "Dock"
        case .background: return "Background only"
        }
    }
}

@main
struct OpenSidecarMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SenderController.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { controller.presentation == .menuBar },
            set: { _ in }
        )) {
            ContentView(controller: controller, updater: appDelegate.updater)
        } label: {
            Image(systemName: controller.running
                  ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Sparkle's standard updater. `startingUpdater: true` boots the updater
    // immediately so scheduled background checks (SUEnableAutomaticChecks)
    // run; the menu item drives manual "Check for Updates…". Held for the
    // app's lifetime here so every window (menu bar + control window) shares
    // one updater instance.
    let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hand the updater to the control window, which is built outside the
        // SwiftUI App scene (NSHostingView), so it can offer the same button.
        MainWindow.updater = updater
        let presentation = SenderController.shared.presentation
        NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
        if presentation != .menuBar {
            MainWindow.show()
        }
    }

    // Background/Dock modes: opening the app again (Spotlight, Finder, Dock
    // click) brings up the control window — Hammerspoon-style.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        MainWindow.show()
        return false
    }
}

/// The control panel as a regular window, for Dock/background presentation.
@MainActor
enum MainWindow {
    private static var window: NSWindow?
    // Set once at launch by AppDelegate so the control window can share the
    // app's single Sparkle updater.
    static var updater: SPUStandardUpdaterController?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "OpenDisplay"
            w.contentView = NSHostingView(
                rootView: ContentView(controller: SenderController.shared,
                                      updater: updater))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum ConnectionTarget: Hashable {
    case usb(udid: String?)           // wired via built-in usbmuxd; nil = first device
    case wifi(NWBrowser.Result)       // discovered via Bonjour
    case remote(peerID: String)       // reached over Tailscale via a persisted endpoint hint

    /// Stable identity for sessions and persistence — survives Bonjour
    /// re-discovery (fresh NWBrowser.Result) and USB replugs (new DeviceID).
    var sessionID: String {
        switch self {
        case .usb(let udid): return "usb:\(udid ?? "first")"
        case .wifi(let result):
            if case .service(let name, _, _, _) = result.endpoint { return "wifi:\(name)" }
            return "wifi:unknown"
        case .remote(let peerID): return "remote:\(peerID)"
        }
    }
}

/// One connected (or connecting) device: its target, its sender pipeline,
/// and the per-device status the UI shows. Each session owns a full pipeline
/// — virtual display, capture, encoder, socket — so devices are independent:
/// one disconnecting never stalls the others.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let logicalID: String
    let attempt: AutoConnectPolicy.Attempt
    let target: ConnectionTarget
    let name: String
    let sender: MacSender

    @Published var status = "Starting…"
    @Published var framesSent = 0
    @Published var mbps = 0.0
    // The sender's start() threw: the pipeline is freed, only this row's
    // error text remains. A failed session must never swallow a fresh
    // connect for its device the way a live one does.
    @Published var failed = false
    @Published var capturePhase: CaptureLifecyclePhase = .recovering
    // Receiver's per-install identity (from hello) — the key for recognizing
    // the same physical device across USB and WiFi.
    var deviceID: String?
    // "iPhone" / "iPad" from hello — naming fallback while (or in case)
    // lockdown hasn't resolved the device's real name.
    var deviceKind: String?
    // `target` names the identity the session was created for; the live
    // transport can migrate (cable-in upgrade, unplug failover) — these
    // track where the sender actually is right now.
    @Published var onUSB: Bool
    // The udid the session is (or was last) cabled through, so a usbmuxd
    // detach can be matched back to this session for failover.
    var usbUDID: String?
    // The Bonjour service name this session was started from or failed over
    // to. Kept because browse results routinely arrive without their TXT
    // record (no install id to match on) and the USB device is detached
    // after a failover — the name is then the only link between the session
    // and its service row.
    var wifiServiceName: String?
    var usbPairingAttempted = false

    // The actual established route, reported from NWConnection.currentPath.
    // Nil while dialing so the UI never presents a requested target as the
    // route that Network.framework actually selected.
    @Published var route: ConnectionRoute?
    @Published var receiverTrayEnabled = true
    @Published var receiverKeyboardButtonEnabled = true
    @Published var receiverProtocolVersion = WireProtocol.assumedWhenAbsent

    var statusWithRoute: String {
        route.map { "\(status) · \($0.rawValue)" } ?? status
    }

    init(id: String, logicalID: String, attempt: AutoConnectPolicy.Attempt,
         target: ConnectionTarget, name: String, sender: MacSender) {
        self.id = id
        self.logicalID = logicalID
        self.attempt = attempt
        self.target = target
        self.name = name
        self.sender = sender
        if case .usb(let udid) = target {
            onUSB = true
            usbUDID = udid
        } else {
            onUSB = false
        }
    }
}

@MainActor
final class SenderController: ObservableObject {
    static let shared = SenderController()

    @Published var presentation = AppPresentation(
        rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "") ?? .menuBar {
        didSet {
            UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
            NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
            // Never strand the user without UI: leaving menu-bar mode opens
            // the window immediately.
            if presentation != .menuBar { MainWindow.show() }
        }
    }

    @Published var sessions: [DeviceSession] = []
    private var suppressModeRestart = false
    @Published var discovered: [NWBrowser.Result] = []
    @Published var usbDevices: [UsbmuxDevice] = []
    let pairingPrompt = PairingPromptModel()
    @Published var pairingMessage: String?
    private var pairingObservation: AnyCancellable?
    // `-host x.x.x.x` / `-port n` bypass usbmuxd with a manual TCP endpoint
    // (debugging escape hatch, e.g. an iproxy or SSH tunnel).
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "127.0.0.1"
    @Published var port = UserDefaults.standard.string(forKey: "port") ?? "9000"
    // `-mode mirror` / `-mode extend` launch argument also works.
    // Mode/quality apply per-pipeline at construction, so a change rebuilds
    // every session. Doing that here — rather than in the Settings picker's
    // onChange — keeps one authoritative transition path shared by the Mac's
    // own picker and a receiver's `displayModeRequest`.
    @Published var mode = VideoModePolicy.normalized(
        mode: CaptureMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .extend,
        videoEnabled: UserDefaults.standard.object(forKey: "videoEnabled") == nil
            || UserDefaults.standard.bool(forKey: "videoEnabled")) {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            if !suppressModeRestart { restartAll() }
        }
    }
    @Published var quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .best {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    @Published var allowInput = InputPolicy.allowsInput() {
        didSet {
            guard allowInput != oldValue else { return }
            UserDefaults.standard.set(allowInput, forKey: InputPolicy.defaultsKey)
            sessions.forEach { session in
                if !allowInput { session.sender.resetReceiverInputState() }
                // Every connected receiver gets the new state, not just
                // whichever one may have requested it — Allow Input is one
                // global Mac-wide gate, never per-receiver.
                session.sender.pushAllowInputState()
            }
        }
    }
    @Published var videoEnabled = UserDefaults.standard.object(forKey: "videoEnabled") == nil
        || UserDefaults.standard.bool(forKey: "videoEnabled") {
        didSet {
            guard videoEnabled != oldValue else { return }
            UserDefaults.standard.set(videoEnabled, forKey: "videoEnabled")
            sessions.forEach { $0.sender.setVideoEnabled(videoEnabled) }
        }
    }

    var running: Bool { !sessions.isEmpty }

    func requestMode(_ requested: CaptureMode) {
        guard VideoModePolicy.allows(requested, videoEnabled: videoEnabled) else {
            sessions.forEach { $0.sender.pushDisplayModeState() }
            return
        }
        mode = requested
    }

    func requestVideoEnabled(_ enabled: Bool) {
        guard enabled != videoEnabled else { return }
        // Mirror is established through the existing authoritative mode
        // transition before capture is stopped. Turning video back on never
        // restores Extend implicitly.
        if !enabled, mode == .extend {
            suppressModeRestart = true
            mode = .mirror
            suppressModeRestart = false
            let transitioning = sessions
            guard !transitioning.isEmpty else {
                videoEnabled = false
                return
            }
            var remaining = transitioning.count
            for session in transitioning {
                session.sender.transitionToMirrorAndDisableVideo { [weak self] in
                    guard let self else { return }
                    remaining -= 1
                    if remaining == 0 { self.videoEnabled = false }
                }
            }
            return
        }
        videoEnabled = enabled
    }

    private var browser: NWBrowser?
    private var receiverPairingBrowser: NWBrowser?
    private var receiverPairingResults: [NWBrowser.Result] = []
    private var pairingListener: NWListener?
    private var usbWatcher: UsbmuxDeviceWatcher?

    // Connection policy — one session per physical device, and the cable
    // wins whenever it's available (lower, steadier latency than WiFi):
    //
    //  - Known devices connect whenever they become available. New devices
    //    wait for an explicit Connect, which records trust for next time.
    //  - Plugging the cable in while the device streams over WiFi migrates
    //    the live session onto USB; unplugging it fails over to WiFi when
    //    the device's service is visible — otherwise the session ends after
    //    the usual grace. Migrations swap only the socket (switchTransport):
    //    the virtual display survives, so no screen flash, no window
    //    reshuffle — the earlier no-switching policy existed because
    //    migration used to mean destroying and recreating the session.
    // `-autostart NO` disables all auto-connecting, including migrations.
    private var autoConnectPolicy = AutoConnectPolicy(knownIdentifiers: {
        let defaults = UserDefaults.standard
        let current = Set(defaults.stringArray(forKey: "knownReceiverIdentifiers") ?? [])
        // Migrate the old WiFi-only preference without changing its contents.
        let legacyWiFi = Set(defaults.stringArray(forKey: "wifiRemembered") ?? [])
        let learnedInstallIDs = Set(
            (defaults.dictionary(forKey: "installIDByUDID") as? [String: String] ?? [:])
                .values.map { "install:\($0)" })
        return current.union(legacyWiFi).union(learnedInstallIDs)
    }())
    private var autoConnectWorkItem: DispatchWorkItem?
    // Install id learned from each USB device's hello, persisted, so the
    // same hardware is recognized across transports even when the user
    // renamed the advertised service. @Published so the device list regroups
    // the moment an identity is learned.
    @Published private var installIDByUDID: [String: String] =
        UserDefaults.standard.dictionary(forKey: "installIDByUDID") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(installIDByUDID, forKey: "installIDByUDID") }
    }
    private let autoConnectEnabled = UserDefaults.standard.object(forKey: "autostart") == nil
        || UserDefaults.standard.bool(forKey: "autostart")

    init() {
        _ = TrustStore.shared.ownIdentity()
        pairingObservation = pairingPrompt.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        persistKnownIdentifiers()
        startBrowsing()
        startReceiverPairingBrowsing()
        startPairingListener()
        usbWatcher = UsbmuxDeviceWatcher { [weak self] devices in
            guard let self else { return }
            let detached = Set(self.usbDevices.map(\.udid)).subtracting(devices.map(\.udid))
            self.usbDevices = devices
            self.failover(detachedUDIDs: detached)
            self.scheduleAutoConnect()
        }
        #if DEBUG
        RouteOverrides.shared.onChange = { [weak self] in self?.enforceRouteOverrides() }
        #endif
    }

    private func startBrowsing() {
        // TXT records carry the receiver's install id (new receivers).
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_opensidecar._tcp", domain: nil),
                                using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.discovered = Array(results)
                self.failoverPendingSessions()
                self.endSessionsWhoseServiceVanished()
                self.scheduleAutoConnect()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func startPairingListener() {
        guard let localID = TrustStore.shared.installID() else {
            Log.info("pairing listener not started: local Keychain identity/install ID unavailable")
            pairingMessage = "Pairing listener unavailable"
            return
        }
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            var txt = NWTXTRecord()
            txt["id"] = localID
            txt["pv"] = String(WireProtocol.version)
            listener.service = NWListener.Service(
                name: Host.current().localizedName ?? "Mac",
                type: "_opendisplay-mac-pair._tcp", txtRecord: txt)
            pairingListener = listener
            #if DEBUG
            Log.info("pairing listener starting: type=_opendisplay-mac-pair._tcp id=\(txt["id"] ?? "missing") peerToPeer=true")
            #endif
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, self.pairingListener === listener,
                          TrustStore.shared.installID() == localID else {
                        connection.cancel(); return
                    }
                    defer { connection.cancel() }
                    do {
                        let paired = try await PairingNetwork.runResponder(
                            connection: connection, localID: localID,
                            localName: Host.current().localizedName ?? "Mac",
                            prompt: self.pairingPrompt)
                        self.pairingMessage = "Paired with \(paired.peerName)"
                        if let result = self.discovered.first(where: { self.txtID(of: $0) == paired.peerID }) {
                            self.connect(to: .wifi(result), userInitiated: true)
                        }
                    } catch { self.pairingMessage = error.localizedDescription }
                }
            }
            listener.stateUpdateHandler = { state in
                #if DEBUG
                switch state {
                case .ready:
                    Log.info("pairing listener ready: endpoint=\(String(describing: listener.port)) type=_opendisplay-mac-pair._tcp")
                case .failed(let error): Log.info("pairing listener failed: \(error)")
                case .waiting(let error): Log.info("pairing listener waiting: \(error)")
                case .cancelled: Log.info("pairing listener cancelled")
                default: break
                }
                #endif
            }
            listener.start(queue: .main)
        } catch {
            pairingMessage = "Pairing listener unavailable"
        }
    }

    private func startReceiverPairingBrowsing() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(
            type: "_opendisplay-pair._tcp", domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.receiverPairingResults = Array(results)
                #if DEBUG
                Log.info("pairing browser changed: results=\(results.count) changes=\(changes.count)")
                for result in results {
                    Log.info("pairing browser result: endpoint=\(result.endpoint) id=\(self.txtID(of: result) ?? "missing")")
                }
                #endif
            }
        }
        browser.stateUpdateHandler = { state in
            #if DEBUG
            Log.info("pairing browser state: \(state)")
            #endif
        }
        browser.start(queue: .main)
        receiverPairingBrowser = browser
    }

    // MARK: - Physical-device identity

    private func serviceName(of result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func txtID(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata { return txt["id"] }
        return nil
    }

    func txtIDForUI(_ result: NWBrowser.Result) -> String? { txtID(of: result) }

    func isPaired(_ result: NWBrowser.Result) -> Bool {
        txtID(of: result).map { TrustStore.shared.hasPin(peerID: $0) } ?? false
    }

    private func secureWiFiTransport(for result: NWBrowser.Result,
                                     knownPeerID: String? = nil) -> SenderTransport? {
        guard let peerID = txtID(of: result) ?? knownPeerID,
              let pin = TrustStore.shared.pin(peerID: peerID),
              let identity = TrustStore.shared.ownIdentity() else { return nil }
        return .tcp(result.endpoint,
                    tls: TLSSessionConfig(identity: identity,
                                          pinnedPeerSPKI: pin,
                                          peerID: peerID))
    }

    /// Same pinned-mutual-TLS construction as `secureWiFiTransport`, dialing
    /// a persisted Tailscale connection hint instead of a Bonjour result.
    /// The endpoint is only ever a hint — `TLSConfigurator`'s SPKI check is
    /// what actually authorizes the connection.
    private func secureRemoteTransport(forPeerID peerID: String) -> SenderTransport? {
        guard let hint = RemoteEndpointStore.endpoint(forPeerID: peerID),
              let port = NWEndpoint.Port(rawValue: hint.port) else {
            Log.info("routeDebug: Remote unavailable for peer=\(peerID) — no persisted endpoint hint")
            return nil
        }
        guard let pin = TrustStore.shared.pin(peerID: peerID),
              let identity = TrustStore.shared.ownIdentity() else {
            // A forgotten/unpaired peer must never be dialed over Remote —
            // an endpoint hint alone never implies trust.
            Log.info("routeDebug: Remote refused for peer=\(peerID) — no local trust/pin for this peer")
            return nil
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(hint.host), port: port)
        Log.info("routeDebug: dialing Remote candidate peer=\(peerID) endpoint=\(hint.host):\(hint.port)")
        return .tcp(endpoint,
                    tls: TLSSessionConfig(identity: identity,
                                          pinnedPeerSPKI: pin,
                                          peerID: peerID))
    }

    func pair(_ result: NWBrowser.Result) {
        if case .bonjour(let txt) = result.metadata,
           let raw = txt["pv"], let version = Int(raw),
           version < WireProtocol.securePairingWireVersion {
            pairingMessage = "Update OpenDisplay on this device to pair securely"
            return
        }
        guard let localID = TrustStore.shared.installID() else {
            Log.info("pair unavailable: local Keychain identity/install ID unavailable")
            pairingMessage = "Pairing unavailable — secure identity could not be loaded"
            return
        }
        pairingMessage = "Starting pairing…"
        let expected = txtID(of: result)
        guard expected != nil else {
            Log.info("pair unavailable: normal discovery result has no stable TXT id endpoint=\(result.endpoint)")
            pairingMessage = "Pairing unavailable — device identity is missing"
            return
        }
        Task { @MainActor in
            let endpoint = await waitForPairingEndpoint(stableID: expected, timeout: 3)
            guard let endpoint else {
                Log.info("pair unavailable: no _opendisplay-pair._tcp result matched id=\(expected ?? "missing")")
                pairingMessage = "Pairing unavailable — pairing service was not found"
                return
            }
            let connection = NWConnection(to: endpoint, using: .tcp)
            defer { connection.cancel() }
            do {
                let paired = try await PairingNetwork.runInitiator(
                    connection: connection, localID: localID,
                    localName: Host.current().localizedName ?? "Mac",
                    prompt: pairingPrompt, expectedPeerID: expected)
                pairingMessage = "Paired with \(paired.peerName)"
                objectWillChange.send()
                connect(to: .wifi(result), userInitiated: true)
            } catch {
                pairingMessage = error.localizedDescription
            }
        }
    }

    func forgetPairing(peerID: String) {
        TrustStore.shared.forget(peerID: peerID)
        for session in sessions where session.deviceID == peerID { end(session) }
        pairingMessage = "Device forgotten"
        objectWillChange.send()
    }

    private func pairingEndpoint(stableID: String?) -> NWEndpoint? {
        let records = receiverPairingResults.compactMap { result -> PairingServiceRecord<NWEndpoint>? in
            guard let id = txtID(of: result) else { return nil }
            return PairingServiceRecord(stableID: id,
                displayName: serviceName(of: result) ?? "Device", endpoint: result.endpoint)
        }
        return PairingServiceAssociation.endpoint(forStableID: stableID, in: records)
    }

    private func waitForPairingEndpoint(stableID: String?, timeout: TimeInterval) async -> NWEndpoint? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let endpoint = pairingEndpoint(stableID: stableID) {
                #if DEBUG
                Log.info("paired discovery association: normal id=\(stableID ?? "missing") endpoint=\(endpoint)")
                #endif
                return endpoint
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        } while Date() < deadline
        return nil
    }

    /// Same hardware? Strong match: the service's install id equals the id
    /// this USB device announced in a (past or present) hello. Fallback for
    /// old receivers: lockdown device name equals the service name.
    private func sameDevice(_ result: NWBrowser.Result, _ device: UsbmuxDevice) -> Bool {
        if let id = txtID(of: result), installIDByUDID[device.udid] == id { return true }
        if let name = serviceName(of: result), let usbName = device.name,
           usbName == name { return true }
        return false
    }

    /// The session (over either transport) already serving this USB device.
    /// A failed session serves nothing — it must not block auto-connecting
    /// the same physical device over the other transport.
    private func activeSession(coveringUSB device: UsbmuxDevice) -> DeviceSession? {
        if let direct = session(for: "usb:\(device.udid)"), !direct.failed { return direct }
        return sessions.first { s in
            guard !s.failed, case .wifi(let result) = s.target else { return false }
            if let id = installIDByUDID[device.udid],
               s.deviceID == id || txtID(of: result) == id { return true }
            return serviceName(of: result) != nil && device.name == serviceName(of: result)
        }
    }

    /// The session (over either transport) already serving this WiFi service.
    /// Failed sessions are excluded for the same reason as above.
    private func activeSession(coveringWiFi result: NWBrowser.Result) -> DeviceSession? {
        if let name = serviceName(of: result), let direct = session(for: "wifi:\(name)"),
           !direct.failed {
            return direct
        }
        return sessions.first { s in
            guard !s.failed, case .usb(let udid) = s.target else { return false }
            if let id = txtID(of: result), s.deviceID == id { return true }
            if let udid, let device = usbDevices.first(where: { $0.udid == udid }),
               sameDevice(result, device) { return true }
            // Browse results routinely lack their TXT record and the USB
            // device is gone after a failover — the service name is then
            // the only remaining link to the session.
            let name = serviceName(of: result)
            return name != nil && (name == s.wifiServiceName || name == s.name)
        }
    }

    // MARK: - Connection policy

    private func persistKnownIdentifiers() {
        UserDefaults.standard.set(Array(autoConnectPolicy.knownIdentifiers),
                                  forKey: "knownReceiverIdentifiers")
    }

    private struct AutoConnectCandidate {
        let target: ConnectionTarget
        let logicalID: String
        let identifiers: Set<String>
        let priority: Int
    }

    private func logicalID(for target: ConnectionTarget) -> String {
        switch target {
        case .usb(let udid?):
            if let installID = installIDByUDID[udid] { return "install:\(installID)" }
        case .wifi(let result):
            if let installID = txtID(of: result) { return "install:\(installID)" }
        case .remote(let peerID):
            return "install:\(peerID)"
        default:
            break
        }
        return target.sessionID
    }

    private func identifiers(for target: ConnectionTarget) -> Set<String> {
        [logicalID(for: target), target.sessionID]
    }

    private func identifiers(for session: DeviceSession) -> Set<String> {
        var identifiers: Set<String> = [session.logicalID, session.target.sessionID]
        if let id = session.deviceID { identifiers.insert("install:\(id)") }
        if let udid = session.usbUDID { identifiers.insert("usb:\(udid)") }
        if let name = session.wifiServiceName { identifiers.insert("wifi:\(name)") }
        return identifiers
    }

    private var autoConnectCandidates: [AutoConnectCandidate] {
        var candidates = usbDevices.map { device in
            let target = ConnectionTarget.usb(udid: device.udid)
            return AutoConnectCandidate(target: target, logicalID: logicalID(for: target),
                                        identifiers: identifiers(for: target), priority: 0)
        }
        candidates += discovered.map { result in
            let target = ConnectionTarget.wifi(result)
            return AutoConnectCandidate(target: target, logicalID: logicalID(for: target),
                                        identifiers: identifiers(for: target), priority: 1)
        }
        // Remote (Tailscale) is the lowest-priority tier: only a candidate
        // for peers we're already paired with and have a persisted endpoint
        // hint for, and only when no better local candidate for the same
        // logical device exists (the priority sort + de-dupe in autoConnect()
        // handles that).
        let localLogicalIDs = Set(candidates.map(\.logicalID))
        candidates += RemoteEndpointStore.allPeerIDs().compactMap { peerID -> AutoConnectCandidate? in
            guard TrustStore.shared.hasPin(peerID: peerID) else { return nil }
            let target = ConnectionTarget.remote(peerID: peerID)
            let logicalID = logicalID(for: target)
            guard !localLogicalIDs.contains(logicalID) else { return nil }
            return AutoConnectCandidate(target: target, logicalID: logicalID,
                                        identifiers: identifiers(for: target), priority: 2)
        }
        #if DEBUG
        candidates = candidates.filter { candidate in
            let route = preConnectRoute(for: candidate.target)
            let allowed = RouteOverrides.shared.isAllowed(route)
            if !allowed {
                Log.info("routeDebug: skipped \(route.rawValue) candidate because \(route.rawValue) is disabled")
            }
            return allowed
        }
        #endif
        return candidates.sorted {
            ($0.priority, $0.target.sessionID) < ($1.priority, $1.target.sessionID)
        }
    }

    #if DEBUG
    /// Best-effort route classification *before* a connection exists, using
    /// only what discovery already told us (Bonjour interfaces) — used
    /// solely to label a route for the DEBUG override gate. The real route
    /// a live session reports (`DeviceSession.route`) still comes from
    /// `NWConnection.currentPath` and is unaffected by this.
    private func preConnectRoute(for target: ConnectionTarget) -> ConnectionRoute {
        switch target {
        case .usb: return .usb
        case .remote: return .remote
        case .wifi(let result):
            let names = result.interfaces.map(\.name)
            return ConnectionRoute.classify(isUSB: false, interfaceNames: names,
                                            remoteEndpointDescription: nil)
        }
    }

    /// The single authoritative admission check every dial site must pass
    /// through immediately before starting a connection. Never cache this
    /// result — re-check right at the dial, since a candidate may have been
    /// built before the override changed.
    private func routeAdmission(for target: ConnectionTarget) -> Bool {
        let route = preConnectRoute(for: target)
        let allowed = RouteOverrides.shared.isAllowed(route)
        Log.info("routeDebug: candidate route=\(route.rawValue)")
        Log.info("routeDebug: allowed=\(allowed)")
        if !allowed {
            Log.info("routeDebug: BLOCKED connection attempt route=\(route.rawValue) reason=overrideDisabled")
        }
        return allowed
    }

    /// Called immediately after any override toggle changes. Tears down any
    /// session whose route is no longer allowed rather than waiting for it
    /// to drop on its own, and lets a still-enabled route take over.
    private func enforceRouteOverrides() {
        for session in sessions {
            let route = session.route ?? preConnectRoute(for: session.target)
            guard !RouteOverrides.shared.isAllowed(route) else { continue }
            Log.info("routeDebug: disconnecting active route=\(route.rawValue) because override disabled")
            // A manual disconnect, not a drop — suppress so autoConnect()
            // doesn't immediately try to resurrect the same disabled route,
            // while still leaving it free to try a different, allowed one.
            autoConnectPolicy.suppress(identifiers(for: session))
            end(session)
        }
        scheduleAutoConnect()
    }
    #endif

    /// Discovery is noisy. Coalescing it for half a second both prefers an
    /// arriving USB route and makes disappearance/reappearance suppression
    /// clearing correspond to a genuine availability cycle rather than an
    /// mDNS flicker.
    private func scheduleAutoConnect() {
        autoConnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.autoConnect() }
        autoConnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func autoConnect() {
        guard autoConnectEnabled else { return }
        dedupeSessions()
        let candidates = autoConnectCandidates
        autoConnectPolicy.updateAvailableIdentifiers(
            candidates.reduce(into: Set<String>()) { $0.formUnion($1.identifiers) })
        // The -host/-port escape hatch is an explicit choice — dial it like
        // the wired devices (it joins them, not replaces them).
        if UserDefaults.standard.object(forKey: "host") != nil,
           session(for: "usb:first") == nil {
            connect(to: .usb(udid: nil))
        }
        var consideredLogicalIDs = Set<String>()
        for candidate in candidates where consideredLogicalIDs.insert(candidate.logicalID).inserted {
            let covering: DeviceSession?
            switch candidate.target {
            case .usb(let udid?):
                covering = usbDevices.first(where: { $0.udid == udid })
                    .flatMap { activeSession(coveringUSB: $0) }
            case .wifi(let result):
                covering = activeSession(coveringWiFi: result)
            default:
                covering = nil
            }
            if let covering, case .usb(let udid?) = candidate.target,
               let device = usbDevices.first(where: { $0.udid == udid }) {
                // Trust gates creating a session, not improving a session the
                // user deliberately has running. The cable is better: take it.
                upgradeToUSB(covering, device: device)
                continue
            }
            let hasOwner = covering != nil || sessions.contains {
                !$0.failed && !identifiers(for: $0).isDisjoint(with: candidate.identifiers)
            }
            guard let attempt = autoConnectPolicy.beginAutomaticAttempt(
                logicalID: candidate.logicalID, identifiers: candidate.identifiers,
                hasSessionOwner: hasOwner) else { continue }
            startSession(to: candidate.target, logicalID: candidate.logicalID,
                         attempt: attempt)
        }
    }

    /// Cable plugged in while the device streams over WiFi: migrate the live
    /// session onto USB. No-op when the session is already cabled.
    private func upgradeToUSB(_ session: DeviceSession, device: UsbmuxDevice) {
        guard !session.onUSB, let portNum = UInt16(port) else { return }
        #if DEBUG
        guard routeAdmission(for: .usb(udid: device.udid)) else { return }
        #endif
        Log.info("cable attached for \(session.id) — migrating to USB")
        session.onUSB = true
        session.usbUDID = device.udid
        // The match may have been by name only — pin the strong identity so
        // future matching (and the next launch) recognizes the pair.
        if let id = session.deviceID { installIDByUDID[device.udid] = id }
        session.sender.switchTransport(to: .usb(udid: device.udid, port: portNum))
    }

    /// Cable unplugged under a live session: fail over to the device's WiFi
    /// service if one is visible. Without one the session keeps its normal
    /// fate — retry over USB through the grace period, then end.
    private func failover(detachedUDIDs: Set<String>) {
        guard autoConnectEnabled, !detachedUDIDs.isEmpty else { return }
        for session in sessions where session.onUSB {
            guard let udid = session.usbUDID, detachedUDIDs.contains(udid),
                  let result = wifiService(for: session) else { continue }
            #if DEBUG
            guard routeAdmission(for: .wifi(result)) else { continue }
            #endif
            Log.info("cable detached for \(session.id) — failing over to WiFi")
            session.onUSB = false
            session.wifiServiceName = serviceName(of: result)
            guard let transport = secureWiFiTransport(for: result, knownPeerID: session.deviceID) else {
                session.status = "Pair this device before connecting wirelessly"
                return
            }
            session.sender.switchTransport(to: transport)
        }
    }

    /// Re-evaluate a USB session still retrying inside its disconnect grace
    /// when the equivalent WiFi Bonjour service appears after the detach.
    private func failoverPendingSessions() {
        guard autoConnectEnabled else { return }
        let attachedUDIDs = Set(usbDevices.map(\.udid))
        for session in sessions where session.onUSB {
            guard let udid = session.usbUDID, !attachedUDIDs.contains(udid),
                  let result = wifiService(for: session) else { continue }
            #if DEBUG
            guard routeAdmission(for: .wifi(result)) else { continue }
            #endif
            Log.info("WiFi appeared for detached USB session \(session.id) — failing over")
            session.onUSB = false
            session.wifiServiceName = serviceName(of: result)
            guard let transport = secureWiFiTransport(for: result, knownPeerID: session.deviceID) else {
                session.status = "Pair this device before connecting wirelessly"
                continue
            }
            session.sender.switchTransport(to: transport)
        }
    }

    /// A quit receiver app loses its Bonjour advertisement within ~1s, far
    /// faster than WiFi dial timeouts can notice (dials to a withdrawn
    /// service stall rather than getting refused). Report the withdrawal to
    /// each live WiFi session's sender; it only acts if its connection is
    /// already down too, which together proves the app is gone. Debounced
    /// 3s: an mDNS record can drop briefly during a WiFi roam — only a
    /// withdrawal that persists counts. One-shot, guarded re-check, so
    /// overlapping browse events at worst repeat an idempotent call.
    private func endSessionsWhoseServiceVanished() {
        for session in sessions where !session.onUSB {
            guard wifiService(for: session) == nil else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
                guard let self, let session,
                      self.sessions.contains(where: { $0 === session }),
                      self.wifiService(for: session) == nil else { return }
                session.sender.peerServiceWithdrawn()
            }
        }
    }

    /// The discovered WiFi service belonging to this session's device.
    private func wifiService(for session: DeviceSession) -> NWBrowser.Result? {
        discovered.first { result in
            if let id = txtID(of: result), let deviceID = session.deviceID {
                return id == deviceID
            }
            let name = serviceName(of: result)
            return name != nil && (name == session.wifiServiceName || name == session.name)
        }
    }

    /// Safety net, not a feature: if identity was learned too late (old
    /// receiver, renamed service) and one physical device ended up with two
    /// sessions, the transports steal the receiver's single connection from
    /// each other forever. Keep the cable, drop the WiFi twin.
    private func dedupeSessions() {
        // Failed sessions hold no pipeline: a USB corpse must never win the
        // "keep the cable" rule against a working WiFi session.
        let usbSessionIDs = Set(sessions.compactMap { s -> String? in
            if case .usb = s.target, !s.failed { return s.deviceID }
            return nil
        })
        let cabledNames = Set(usbDevices.compactMap { device -> String? in
            guard let s = session(for: "usb:\(device.udid)"), !s.failed else { return nil }
            return device.name
        })
        for s in sessions {
            guard case .wifi(let result) = s.target else { continue }
            let matchingUSB = usbDevices.first { sameDevice(result, $0) }
            if let matchingUSB, !s.onUSB, !s.failed {
                // A USB session may already have been created before its
                // hello supplied the strong install-ID match. It is the
                // disposable twin; preserve the older WiFi session and its
                // capture, then move that session onto the cable.
                if let usbTwin = session(for: "usb:\(matchingUSB.udid)"), usbTwin !== s {
                    Log.info("ending newly matched USB twin \(usbTwin.id) before migration")
                    end(usbTwin)
                }
                Log.info("cable attached for \(s.id) — preserving session while migrating to USB")
                upgradeToUSB(s, device: matchingUSB)
            } else {
                let duplicate = (s.deviceID.map { usbSessionIDs.contains($0) } ?? false)
                    || (txtID(of: result).map { usbSessionIDs.contains($0) } ?? false)
                    || (serviceName(of: result).map { cabledNames.contains($0) } ?? false)
                if duplicate {
                    Log.info("two sessions for one device — keeping the cable, dropping \(s.id)")
                    end(s)
                }
            }
        }
    }

    /// Human-readable device name for a target (no transport suffix — the
    /// UI shows transports separately).
    func label(for target: ConnectionTarget) -> String {
        switch target {
        case .usb(let udid):
            if let device = usbDevices.first(where: { $0.udid == udid }), let name = device.name {
                return name
            }
            return udid == nil ? "Manual (\(host):\(port))" : "iPhone / iPad"
        case .wifi(let result):
            return serviceName(of: result) ?? "WiFi device"
        case .remote(let peerID):
            let pinned = TrustStore.shared.pinnedPeers().first { $0.peerID == peerID }
            return pinned?.displayName ?? "Remote device"
        }
    }

    func session(for id: String) -> DeviceSession? {
        sessions.first { $0.id == id }
    }

    /// Derive a stable, per-device display serial from the session identity.
    /// FNV-1a over the id string; macOS keys saved display arrangement on
    /// vendor/product/serial, so each device keeps its screen position.
    private static func displaySerial(for id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    // A display identity macOS saved hostile state for (see
    // MacSender.setupExtend) is abandoned permanently: the validated offset
    // from the device's base identity is persisted per session id and every
    // future session starts from it.
    private static func identityOffsetKey(for id: String) -> String { "displaySerialBump.\(id)" }
    private func identityOffset(for id: String) -> UInt32 {
        UInt32(clamping: UserDefaults.standard.integer(forKey: Self.identityOffsetKey(for: id)))
    }

    func connect(to target: ConnectionTarget, userInitiated: Bool = false,
                 awaitingWake: Bool = false) {
        if let existing = session(for: target.sessionID), !existing.failed { return }
        let logicalID = logicalID(for: target)
        let targetIdentifiers = identifiers(for: target)
        let attempt: AutoConnectPolicy.Attempt
        if userInitiated {
            attempt = autoConnectPolicy.beginExplicitAttempt(
                logicalID: logicalID, identifiers: targetIdentifiers)
            persistKnownIdentifiers()
        } else {
            attempt = autoConnectPolicy.beginContinuationAttempt(logicalID: logicalID)
        }
        startSession(to: target, logicalID: logicalID, attempt: attempt,
                     userInitiated: userInitiated, awaitingWake: awaitingWake)
    }

    private func startSession(to target: ConnectionTarget, logicalID: String,
                              attempt: AutoConnectPolicy.Attempt,
                              userInitiated: Bool = false,
                              awaitingWake: Bool = false) {
        #if DEBUG
        // Central hard gate: every path that can start a session — auto-
        // connect, explicit user taps, and pairing's immediate connect —
        // funnels through here, so this single check is authoritative.
        guard routeAdmission(for: target) else {
            autoConnectPolicy.finish(attempt)
            return
        }
        #endif
        let id = target.sessionID
        if let existing = session(for: id) {
            // A failed session holds no pipeline — replace the corpse
            // instead of letting it swallow the fresh attempt.
            guard existing.failed else {
                autoConnectPolicy.finish(attempt)
                return
            }
            end(existing)
        }

        // Never create a second session for the same physical device — the
        // receiver holds one connection, so a twin would steal it. But an
        // explicit user click overrides: e.g. right after unplugging the
        // cable, the dying USB session sits in its 10s reconnect grace and
        // would otherwise swallow the tap on the WiFi row.
        let covering: DeviceSession?
        switch target {
        case .usb(let udid?):
            covering = usbDevices.first(where: { $0.udid == udid })
                .flatMap { activeSession(coveringUSB: $0) }
        case .wifi(let result):
            covering = activeSession(coveringWiFi: result)
        default:
            covering = nil
        }
        if let covering {
            guard userInitiated else {
                autoConnectPolicy.finish(attempt)
                return
            }
            Log.info("user chose \(id) — taking over from \(covering.id)")
            end(covering)
        }

        let transport: SenderTransport
        switch target {
        case .usb(let udid):
            guard let portNum = UInt16(port) else {
                autoConnectPolicy.finish(attempt)
                return
            }
            if UserDefaults.standard.object(forKey: "host") != nil, udid == nil {
                // Manual override: dial a plain TCP endpoint instead of usbmuxd.
                transport = .tcp(.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: portNum)!), tls: nil)
            } else {
                transport = .usb(udid: udid, port: portNum)
            }
        case .wifi(let result):
            guard let secure = secureWiFiTransport(for: result) else { return }
            transport = secure
        case .remote(let peerID):
            guard let secure = secureRemoteTransport(forPeerID: peerID) else { return }
            transport = secure
        }

        let name = label(for: target)
        let sender = MacSender(transport: transport, name: name, mode: mode,
                               quality: quality, displaySerial: Self.displaySerial(for: id),
                               identityOffset: identityOffset(for: id),
                               awaitingWake: awaitingWake,
                               videoEnabled: videoEnabled)
        let session = DeviceSession(id: id, logicalID: logicalID, attempt: attempt,
                                    target: target, name: name, sender: sender)
        if case .wifi(let result) = target {
            session.wifiServiceName = serviceName(of: result)
        }
        sender.onStatus = { [weak session] text in
            // Retry loops re-announce the same status every second (e.g. the
            // asleep wait) — only a change is worth the UI churn and the log line.
            guard let session, session.status != text else { return }
            session.status = text
            Log.info("status[\(id)]: \(text)")
        }
        sender.onCaptureLifecycleChanged = { [weak session] phase in
            session?.capturePhase = phase
        }
        sender.onDisplayModeRequest = { [weak self, weak session] requestedMode in
            guard let self, let session, self.owns(session) else { return }
            self.requestMode(CaptureMode(requestedMode))
        }
        sender.onAllowInputRequest = { [weak self, weak session] requested in
            guard let self, let session, self.owns(session) else { return }
            self.allowInput = requested
        }
        sender.onVideoEnabledRequest = { [weak self, weak session] requested in
            guard let self, let session, self.owns(session) else { return }
            self.requestVideoEnabled(requested)
        }
        sender.onHello = { [weak self, weak session] info in
            guard let self, let session, self.owns(session) else { return }
            session.deviceID = info.id
            session.deviceKind = info.device
            session.receiverProtocolVersion = info.protocolVersion
            if let value = info.trayEnabled { session.receiverTrayEnabled = value }
            if let value = info.keyboardButtonEnabled {
                session.receiverKeyboardButtonEnabled = value
            }
            if let installID = info.id {
                self.autoConnectPolicy.remember(["install:\(installID)"])
                self.persistKnownIdentifiers()
            }
            if case .usb(let udid?) = session.target, let installID = info.id {
                self.installIDByUDID[udid] = installID
            }
            if session.onUSB, !session.usbPairingAttempted,
               let udid = session.usbUDID, let peerID = info.id,
               info.protocolVersion >= WireProtocol.securePairingWireVersion {
                session.usbPairingAttempted = true
                Task { [weak self, weak session] in
                    guard let self, let session else { return }
                    do {
                        let connection = try await Usbmux.dial(
                            udid: udid, port: WireCrypto.pairingPort,
                            queue: DispatchQueue(label: "pairing.usb"))
                        defer { connection.cancel() }
                        guard let localID = TrustStore.shared.installID() else {
                            throw PairingError.invalidKey
                        }
                        let paired = try await PairingNetwork.runInitiator(
                            connection: connection, localID: localID,
                            localName: Host.current().localizedName ?? "Mac",
                            prompt: self.pairingPrompt, expectedPeerID: peerID,
                            autoConfirm: true)
                        guard self.owns(session) else { return }
                        self.pairingMessage = "Paired with \(paired.peerName)"
                    } catch {
                        guard self.owns(session) else { return }
                        self.pairingMessage = "USB pairing failed: \(error.localizedDescription)"
                    }
                }
            }
            self.dedupeSessions()
            // The learned identity may reveal that this WiFi session's device
            // is cabled — take the upgrade opportunity right away.
            self.scheduleAutoConnect()
        }
        sender.onStats = { [weak session] frames, mbps in
            session?.framesSent = frames
            session?.mbps = mbps
        }
        sender.onDisconnected = { [weak self, weak session] in
            // MacSender already exhausted its in-place reconnect grace. End
            // the pipeline, then let current discovery start a fresh known-
            // device attempt without waiting for another browse callback.
            guard let self, let session, self.owns(session) else { return }
            Log.info("device disconnected — session \(session.id) stopped")
            self.end(session)
            self.scheduleAutoConnect()
        }
        sender.onPeerSleeping = { [weak self, weak session] in
            // The device locked. Unlike a plain disconnect this is a
            // known-temporary state announced by the receiver, so ending
            // the session (which frees the cursor from the now-invisible
            // display) is paired with a replacement session that dials
            // patiently until the device wakes and accepts again.
            guard let self, let session, self.owns(session) else { return }
            let target = session.target
            Log.info("session \(session.id) asleep — display down, waiting for wake")
            self.end(session)
            self.connect(to: target, awaitingWake: true)
        }
        sender.onCaptureStoppedByUser = { [weak self, weak session] in
            // The user stopped the capture in the system UI — same intent as
            // the in-app Disconnect, so it also opts the device out of
            // auto-connect (or the next browse event would resurrect it).
            guard let self, let session, self.owns(session) else { return }
            Log.info("session \(session.id) capture stopped via the system UI — honoring as disconnect")
            self.disconnect(session)
        }
        sender.onDisplayIdentityBumped = { [weak self, weak session] totalOffset in
            // The sender reports the validated absolute offset — store it
            // as-is. Adding would double-count when a rotation rebuild
            // re-discovers the same poisoned identity within one session.
            guard let self, let session, self.owns(session) else { return }
            UserDefaults.standard.set(Int(totalOffset), forKey: Self.identityOffsetKey(for: session.id))
            Log.info("display identity for \(session.id) moved to offset \(totalOffset) — "
                + "macOS saved hostile state for the old one")
        }
        sender.onTransportPath = { [weak session] route in
            session?.route = route
        }
        sender.onPeerClosed = { [weak self, weak session] in
            // The receiver app quit — a deliberate goodbye, so no reconnect
            // waits around. Reopening the app is a fresh start handled by
            // the normal discovery/auto-connect paths.
            guard let self, let session, self.owns(session) else { return }
            Log.info("session \(session.id) closed by the receiver — ending")
            self.autoConnectPolicy.suppress(self.identifiers(for: session))
            self.end(session)
        }
        sender.onTrustFailure = { [weak self, weak session] message in
            guard let self, let session, self.owns(session) else { return }
            session.failed = true
            session.status = message
        }
        sessions.append(session)
        Task {
            do {
                try await sender.start()
            } catch is CancellationError {
                // stopped by the user while waiting — nothing to report
            } catch {
                guard self.owns(session) else { return }
                Log.info("sender failed to start: \(error)")
                session.status = "Failed: \(error.localizedDescription)"
                // Free the half-built pipeline: a leaked virtual display
                // would keep holding this device's serial, and a parked
                // live-looking session would swallow every future connect.
                session.failed = true
                sender.stop()
            }
        }
    }

    /// User-initiated disconnect: also opt the device out of auto-connect.
    func disconnect(_ session: DeviceSession) {
        autoConnectPolicy.suppress(identifiers(for: session))
        end(session)
    }

    func disconnectAll() {
        sessions.forEach { disconnect($0) }
    }

    /// Restart a session that failed to start (its pipeline is already
    /// freed): tear the corpse out and dial the same target fresh. The
    /// socket-only Reconnect can't help there — nothing was ever built.
    func retry(_ session: DeviceSession) {
        let target = session.target
        end(session)
        connect(to: target, userInitiated: true)
    }

    private func end(_ session: DeviceSession) {
        autoConnectPolicy.finish(session.attempt)
        session.sender.stop()
        // Identity comparison prevents a late callback from an old attempt
        // removing its newer replacement, which can have the same route id.
        sessions.removeAll { $0 === session }
    }

    private func owns(_ session: DeviceSession) -> Bool {
        sessions.contains { $0 === session } && autoConnectPolicy.isCurrent(session.attempt)
    }

    /// Mode/quality apply per-pipeline at construction — rebuild every session.
    func restartAll() {
        guard running else { return }
        let targets = sessions.map(\.target)
        sessions.forEach { $0.sender.stop() }
        sessions.removeAll()
        targets.forEach { connect(to: $0) }
        autoConnect()   // a rebuilt WiFi session may deserve its cable back
    }

    // MARK: - Device list (one row per physical device)

    struct DeviceEntry: Identifiable {
        let id: String
        let name: String
        let usbTarget: ConnectionTarget?
        let wifiTarget: ConnectionTarget?

        var transportLabel: String {
            switch (usbTarget != nil, wifiTarget != nil) {
            case (true, true): return "USB · WiFi"
            case (true, false): return "USB"
            case (false, true): return "WiFi"
            default: return ""
            }
        }
        /// Lowest latency first.
        var preferredTarget: ConnectionTarget? { usbTarget ?? wifiTarget }
    }

    var deviceEntries: [DeviceEntry] {
        var entries: [DeviceEntry] = []
        var mergedServices = Set<String>()
        var coveredSessionIDs = Set<String>()

        for device in usbDevices {
            // A discovered WiFi service for the same hardware folds into
            // this row instead of appearing as a second device.
            let twin = discovered.first { sameDevice($0, device) }
            if let twin, let name = serviceName(of: twin) { mergedServices.insert(name) }
            let usbTarget = ConnectionTarget.usb(udid: device.udid)
            coveredSessionIDs.insert(usbTarget.sessionID)
            if let twin { coveredSessionIDs.insert(ConnectionTarget.wifi(twin).sessionID) }
            // A WiFi-identity session migrated onto this cable serves the
            // device even when its service is no longer advertised.
            if let covering = activeSession(coveringUSB: device) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(
                id: "device:\(device.udid)",
                name: device.name
                    ?? twin.flatMap(serviceName)
                    ?? session(for: usbTarget.sessionID)?.deviceKind
                    ?? "iPhone / iPad",
                usbTarget: usbTarget,
                wifiTarget: twin.map { .wifi($0) }))
        }
        if UserDefaults.standard.object(forKey: "host") != nil {
            let target = ConnectionTarget.usb(udid: nil)
            coveredSessionIDs.insert(target.sessionID)
            entries.append(DeviceEntry(id: target.sessionID, name: label(for: target),
                                       usbTarget: target, wifiTarget: nil))
        }
        for result in discovered {
            guard let name = serviceName(of: result), !mergedServices.contains(name)
            else { continue }
            let target = ConnectionTarget.wifi(result)
            coveredSessionIDs.insert(target.sessionID)
            // A USB-identity session that failed over to WiFi serves this
            // service — claim it, or it would dangle as a second row and
            // this one would offer a Connect that steals the receiver.
            if let covering = activeSession(coveringWiFi: result) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(id: "service:\(name)", name: name,
                                       usbTarget: nil, wifiTarget: target))
        }
        // Sessions whose device vanished from discovery (e.g. Bonjour record
        // gone while the stream is still alive) keep a row to disconnect.
        for session in sessions where !coveredSessionIDs.contains(session.id) {
            entries.append(DeviceEntry(id: session.id, name: session.name,
                                       usbTarget: nil, wifiTarget: nil))
        }
        return entries
    }

    func session(for entry: DeviceEntry) -> DeviceSession? {
        if let target = entry.usbTarget {
            if let s = session(for: target.sessionID) { return s }
            if case .usb(let udid?) = target,
               let device = usbDevices.first(where: { $0.udid == udid }),
               let s = activeSession(coveringUSB: device) { return s }
        }
        if let target = entry.wifiTarget {
            if let s = session(for: target.sessionID) { return s }
            // Transport-migrated sessions keep their original identity — a
            // USB-identity session failed over to WiFi still owns this row.
            if case .wifi(let result) = target,
               let s = activeSession(coveringWiFi: result) { return s }
        }
        return session(for: entry.id)   // dangling-session rows
    }

    func pairedPeerID(for entry: DeviceEntry) -> String? {
        if let id = session(for: entry)?.deviceID, TrustStore.shared.hasPin(peerID: id) { return id }
        if let target = entry.wifiTarget, case .wifi(let result) = target,
           let id = txtID(of: result), TrustStore.shared.hasPin(peerID: id) { return id }
        if let target = entry.usbTarget, case .usb(let udid?) = target,
           let id = installIDByUDID[udid], TrustStore.shared.hasPin(peerID: id) { return id }
        return nil
    }
}

/// Polls the permission states the app depends on so the UI can surface
/// exactly what's missing instead of failing silently.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published var screenRecording = false
    @Published var accessibility = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    /// Fire the system permission dialog on demand. macOS only shows each
    /// dialog once per reset — after that the call just (re)registers the
    /// app in System Settings, so the row exists to toggle manually.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestAccessibility() {
        _ = InputInjector.ensureAccessibilityPermission()
        refresh()
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: SenderController
    @StateObject private var permissions = PermissionMonitor()
    // Optional so the view still compiles/previews without an updater (e.g.
    // if Sparkle ever fails to start); the button just disables itself then.
    let updater: SPUStandardUpdaterController?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenDisplay")
                        .font(.title3.bold())
                    Text("Your iPads, iPhones and Macs as extra displays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.running {
                    Button("Disconnect All") { controller.disconnectAll() }
                        .controlSize(.large)
                }
            }
            .padding(16)

            Divider()

            // Settings
            Form {
                Section("Devices") {
                    if let message = controller.pairingMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if controller.deviceEntries.isEmpty {
                        Text("No devices found — plug one in via USB, or open the OpenDisplay app on a device on this WiFi network.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(controller.deviceEntries) { entry in
                        if let session = controller.session(for: entry) {
                            // Title from the entry, not the session: the
                            // session name was snapshotted at connect time,
                            // often before lockdown resolved the real name.
                            SessionRow(title: entry.name, session: session,
                                       controller: controller)
                                .contextMenu {
                                    if let peerID = controller.pairedPeerID(for: entry) {
                                        Button("Forget Device", role: .destructive) {
                                            controller.forgetPairing(peerID: peerID)
                                        }
                                    }
                                }
                        } else {
                            HStack(alignment: .firstTextBaseline) {
                                Circle()
                                    .fill(.secondary.opacity(0.5))
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                    Text(entry.transportLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let target = entry.preferredTarget {
                                    if case .wifi(let result) = target,
                                       !controller.isPaired(result) {
                                        Button("Pair") { controller.pair(result) }
                                            .controlSize(.small)
                                    } else {
                                        Button("Connect") {
                                            controller.connect(to: target, userInitiated: true)
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                            .contextMenu {
                                if let peerID = controller.pairedPeerID(for: entry) {
                                    Button("Forget Device", role: .destructive) {
                                        controller.forgetPairing(peerID: peerID)
                                    }
                                }
                            }
                        }
                    }
                }

                Picker("Mode", selection: Binding(
                    get: { controller.mode },
                    set: { controller.requestMode($0) })) {
                    Text("Extend").tag(CaptureMode.extend)
                        .disabled(!controller.videoEnabled)
                    Text("Mirror").tag(CaptureMode.mirror)
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Video", isOn: Binding(
                        get: { controller.videoEnabled },
                        set: { controller.requestVideoEnabled($0) }))
                    Text("Stop screen capture and streaming while keeping connected-device controls active.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Allow Input", isOn: $controller.allowInput)
                    Text("Allow touch, scrolling, and pointer input from the connected device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Show app in", selection: $controller.presentation) {
                        ForEach(AppPresentation.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    if controller.presentation == .background {
                        Text("No menu bar or Dock icon — streaming keeps running. Open the OpenDisplay app again (Spotlight/Finder) to show this window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Display layout") {
                    Button("Arrange Displays…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .help("Opens System Settings → Displays, where you can position the extended displays relative to your Mac screen (Arrange…). Each device shows up as its own display, named after the device.")

                Section("Permissions") {
                    permissionRow(
                        "Screen Recording",
                        granted: permissions.screenRecording,
                        help: "Required to capture the display.",
                        anchor: "Privacy_ScreenCapture",
                        request: { permissions.requestScreenRecording() }
                    )
                    permissionRow(
                        "Accessibility",
                        granted: permissions.accessibility,
                        help: "Required for touch input from the device.",
                        anchor: "Privacy_Accessibility",
                        request: { permissions.requestAccessibility() }
                    )
                    // macOS offers no API to query Local Network access, so
                    // infer from discovery results and let the user check.
                    permissionRow(
                        "Local Network",
                        granted: !controller.discovered.isEmpty,
                        uncertain: controller.discovered.isEmpty,
                        help: "Required for WiFi mode. If no device appears in the Devices list, allow OpenDisplay under Privacy & Security → Local Network on this Mac AND on the device — and keep the OpenDisplay app open there.",
                        anchor: "Privacy_LocalNetwork"
                    )
                }

                #if DEBUG
                Section("Developer / Diagnostics") {
                    DisclosureGroup("Route Overrides (DEBUG)") {
                        RouteOverridesView()
                    }
                    DisclosureGroup("Remote Endpoint (DEBUG)") {
                        RemoteEndpointDebugView(controller: controller)
                    }
                }
                #endif
            }
            .formStyle(.grouped)
            // Scrollable + fixed panel height: MenuBarExtra windows mis-measure
            // grouped Forms (clipping on small displays), so size explicitly
            // and let the form scroll when it doesn't fit.

            Divider()

            // Status bar
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.running ? .green : .secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                Text(controller.running
                     ? "\(controller.sessions.count) device\(controller.sessions.count == 1 ? "" : "s") connected"
                     : "Idle")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                // Support affordance: bug reports are much easier to act on
                // with the log attached, and users shouldn't have to be told a
                // filesystem path to find it.
                Button("Logs") { Log.revealInFinder() }
                    .controlSize(.small)
                    .help("Reveal the OpenDisplay log files in Finder")
                if let updater {
                    CheckForUpdatesView(updater: updater)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .sheet(item: Binding(get: { controller.pairingPrompt.pending },
                             set: { if $0 == nil { controller.pairingPrompt.decide(accept: false) } })) { pending in
            VStack(spacing: 16) {
                Text("Pair with \(pending.peerName)?").font(.headline)
                Text(pending.sas).font(.system(.title, design: .monospaced)).bold()
                Text("Confirm only if this code matches on both devices.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Cancel", role: .cancel) { controller.pairingPrompt.decide(accept: false) }
                    Button("Codes Match") { controller.pairingPrompt.decide(accept: true) }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24).frame(minWidth: 360)
        }
        .frame(width: 440, height: 540)
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, uncertain: Bool = false,
                               help: String, anchor: String,
                               request: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: uncertain ? "questionmark.circle.fill"
                            : granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(uncertain ? .orange : granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if uncertain || !granted {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if uncertain || !granted {
                if let request {
                    Button("Grant…") { request() }
                        .controlSize(.small)
                        .help("Ask macOS for this permission. If the system dialog was already dismissed once, this registers the app under \(title) in System Settings — flip the toggle there.")
                }
                Button("Open Settings") {
                    PermissionMonitor.openPrivacyPane(anchor)
                }
                .controlSize(.small)
            }
        }
    }
}

/// One connected device: live status, throughput, reconnect + disconnect.
@MainActor
struct SessionRow: View {
    let title: String
    @ObservedObject var session: DeviceSession
    let controller: SenderController

    private var statusColor: Color {
        if session.status.hasPrefix("Extending") || session.status.hasPrefix("Mirroring")
            || session.status.hasPrefix("Connected") || session.status.hasPrefix("Video off") {
            return .green
        }
        if session.status.hasPrefix("Failed") || session.status.contains("stopped") {
            return .red
        }
        return .orange
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(session.statusWithRoute)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if session.mbps > 0 {
                Text("\(String(format: "%.1f", session.mbps)) Mbit/s")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button {
                if session.failed {
                    controller.retry(session)
                } else {
                    session.sender.forceReconnect()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .help(session.failed
                ? "Start this connection over"
                : "Drop the connection and pair with the device again")
            Button(session.capturePhase == .paused ? "Resume" : "Pause") {
                if session.capturePhase == .paused {
                    session.sender.resumeDisplay()
                } else {
                    session.sender.pauseDisplay()
                }
            }
            .controlSize(.small)
            .disabled(session.capturePhase != .running
                && session.capturePhase != .recovering
                && session.capturePhase != .paused)
            if session.deviceKind != "Mac",
               session.receiverProtocolVersion >= WireProtocol.receiverControlsWireVersion {
                Menu {
                    Toggle("Show Control Tray", isOn: Binding(
                        get: { session.receiverTrayEnabled },
                        set: { value in
                            session.receiverTrayEnabled = value
                            session.sender.setReceiverUIPreferences(
                                trayEnabled: value,
                                keyboardButtonEnabled: session.receiverKeyboardButtonEnabled)
                        }))
                    Toggle("Show Keyboard Button", isOn: Binding(
                        get: { session.receiverKeyboardButtonEnabled },
                        set: { value in
                            session.receiverKeyboardButtonEnabled = value
                            session.sender.setReceiverUIPreferences(
                                trayEnabled: session.receiverTrayEnabled,
                                keyboardButtonEnabled: value)
                        }))
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .controlSize(.small)
                .help("Receiver controls")
            }
            Button("Disconnect") { controller.disconnect(session) }
                .controlSize(.small)
        }
    }
}
