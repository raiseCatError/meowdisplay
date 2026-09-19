import SwiftUI
import Network
import Combine
import Sparkle
import Security
import CryptoKit

// `AppPresentation` lives in its own file (Mac/AppPresentation.swift) — a
// pure, dependency-free policy type, same shape as `ReconnectPolicy`/
// `AutoConnectPolicy`, kept separate so `AppPresentationTests` can compile it
// into MacTests without dragging this whole app-lifecycle file (Sparkle,
// SenderController, NSApplicationDelegateAdaptor, `@main`) into the test
// target.

@main
struct OpenSidecarMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SenderController.shared

    // No SwiftUI WindowGroup/MenuBarExtra: the Settings window is a manually
    // managed NSWindow (`MacSettingsWindow`) and the menu-bar icon is a
    // manually managed NSStatusItem (`MenuBarPresenceController`) — see that
    // type's doc for why the icon is no longer a `MenuBarExtra`. SwiftUI
    // still requires at least one Scene; `Settings` contributes no window or
    // Dock presence of its own and is never shown (Cmd+, is rebound below).
    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { MacSettingsWindow.show() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
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
        // Hand the updater to the settings window, which is built outside
        // the SwiftUI App scene (NSHostingView), so it can offer the same
        // button.
        MacSettingsWindow.updater = updater
        let controller = SenderController.shared
        let presentation = controller.presentation
        NSApp.setActivationPolicy(presentation.showsDockIcon ? .regular : .accessory)
        // Cold-launch presence: the menu-bar icon (if any) must appear
        // immediately, not only after the user later toggles the setting.
        MenuBarPresenceController.shared.apply(presentation, controller: controller)
        // A login-launch (Start at Login) must be quiet — no Settings window
        // popping up unasked. Only an interactive launch opens it, and only
        // for the modes that need it to avoid stranding the user without a
        // menu-bar icon or Dock icon to bring the UI back.
        if !StartAtLoginPolicy.wasLaunchedAsLoginItem(), !presentation.showsMenuBarIcon {
            MacSettingsWindow.show()
        }
    }

    // Background/Dock modes: opening the app again (Spotlight, Finder, Dock
    // click) brings up the Settings window — Hammerspoon-style. Also handles
    // a Dock click while the window already exists: it focuses the same
    // logical window rather than creating a duplicate.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        MacSettingsWindow.show()
        return false
    }
}

/// The Settings window — the app's PRIMARY GUI, not a secondary dashboard.
/// One identifiable `NSWindow` instance (`isReleasedWhenClosed = false`, so
/// closing hides rather than destroys it): Dock click, Cmd+,, and the menu
/// bar's "Open Settings…" all focus this same window, never a duplicate.
@MainActor
enum MacSettingsWindow {
    private static var window: NSWindow?
    // Set once at launch by AppDelegate so the settings window can share the
    // app's single Sparkle updater.
    static var updater: SPUStandardUpdaterController?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            w.title = "MeowDisplay Settings"
            w.minSize = NSSize(width: 700, height: 500)
            w.contentView = NSHostingView(
                rootView: MacSettingsView(controller: SenderController.shared,
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
    /// Reached over Tailscale using a host/port resolved from an
    /// authenticated remote connect-request "knock" rather than a persisted
    /// hint — see `SenderController.handleRemoteConnectRequest`. Shares
    /// `.remote`'s sessionID/logicalID/route so it can never coexist with
    /// (or duplicate) a `.remote` session for the same peer.
    case remoteCallback(peerID: String, host: String, port: UInt16)

    /// Stable identity for sessions and persistence — survives Bonjour
    /// re-discovery (fresh NWBrowser.Result) and USB replugs (new DeviceID).
    var sessionID: String {
        switch self {
        case .usb(let udid): return "usb:\(udid ?? "first")"
        case .wifi(let result):
            if case .service(let name, _, _, _) = result.endpoint { return "wifi:\(name)" }
            return "wifi:unknown"
        case .remote(let peerID): return "remote:\(peerID)"
        case .remoteCallback(let peerID, _, _): return "remote:\(peerID)"
        }
    }
}

struct ForgetConfirmation: Identifiable, Equatable {
    let peerID: String
    let name: String
    var id: String { peerID }
}

/// One connected (or connecting) device: its target, its sender pipeline,
/// and the per-device status the UI shows. Each session owns a full pipeline
/// — virtual display, capture, encoder, socket — so devices are independent:
/// one disconnecting never stalls the others.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let logicalID: String
    /// Stable peer selected before dialing. Unlike `deviceID`, this exists
    /// while the application hello is still pending.
    let intendedPeerID: String?
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
    // Mac's live cache of the connected receiver's OWN preferences — the
    // receiver remains the authoritative store (see `PhoneInfo`/
    // `StreamReceiver.announceReceiverPreferences`); this is only what Mac
    // last saw reported, refreshed on every hello. Defaults mirror
    // `ReceiverControlPreferences`'s own defaults so a pre-report UI never
    // shows a manufactured zero/false value.
    @Published var receiverFunctionTrayEnabled = true
    @Published var receiverInputMode = "direct"
    @Published var receiverTrackpadSensitivity = 1.0
    @Published var receiverHapticsEnabled = true
    @Published var receiverAvoidNotch = true
    @Published var receiverPinchTarget = "viewport"
    @Published var receiverRotateTarget = "viewport"
    @Published var receiverSnapRotation = true
    @Published var receiverAppGestureCommands = AppGestureCommands.defaults
    @Published var receiverAVSyncOffsetMs = 0
    // This peer's live Extend shape (PROTOCOL.md 6.7). Unlike the
    // receiver-reported fields above, MEOW's own `MacSender` is the
    // authoritative store for this one — mirrored here via
    // `onExtendShapeChanged` purely for `ReceiverDeviceDetailView` display.
    @Published var extendShapePreference = ExtendDisplayShapePreference.standard
    // This peer's live receiver-enforced max-FPS preference (PART 2/3/4) —
    // same "MacSender is authoritative, mirrored here for display" pattern
    // as `extendShapePreference`, via `onMaxFPSChanged`.
    @Published var maxFPSPreference = ReceiverMaxFPSPreference.standard
    // This peer's advertised HARDWARE max refresh rate (`hello.maxFPS`) —
    // nil until the first hello reports it, exactly
    // like `receiverPreferencesReported` distinguishes "unknown" from
    // "reported and low". Used to filter the Maximum FPS picker.
    @Published var receiverMaxFPS: Int?
    // Nil until the first hello with these fields arrives (protocol 6+) —
    // distinguishes "not yet reported" from "reported and off/default" so
    // device detail can show "No compatible device connected" honestly
    // instead of presenting the defaults above as if they were live.
    @Published var receiverPreferencesReported = false
    @Published var receiverProtocolVersion = WireProtocol.assumedWhenAbsent
    // True only once the MEOW application handshake (hello/welcome) has
    // completed on the live connection — never inferred from Bonjour
    // presence, TrustStore, or a merely-open socket. This, not discovery, is
    // what "Active Display" is authoritative on.
    @Published var applicationAuthenticated = false
    // This session's current media activity/geometry, refreshed on the same
    // cadence as `mbps`/`framesSent` (see MacSender.onMediaState) — the
    // source Overview/Active Display read for "Video/Audio Streaming" and
    // resolution, rather than each re-deriving it independently.
    @Published var videoActive = false
    @Published var audioActive = false
    // Mirrors `MacSender.sessionInputGrant` for display only — the
    // authoritative bit lives on `sender`, updated via `onSessionInputGrantChanged`.
    // Never itself grants anything; see `SenderController.
    // handleInputControlRequested` for the only path that actually grants.
    @Published var sessionInputGranted = false
    // This session's control-request dedup/cooldown/timeout — MainActor-
    // confined (unlike the grant bit) since it's only ever touched from
    // `SenderController`'s consent-flow methods, all MainActor.
    var inputControlRequest = InputControlRequestLifecycle()
    @Published var videoWidth = 0
    @Published var videoHeight = 0
    @Published var videoFPS = 0

    var statusWithRoute: String {
        route.map { "\(status) · \($0.rawValue)" } ?? status
    }

    // Single source for every surface's Pause/Resume affordance (Devices →
    // Active Display's SessionRow, Overview, Streaming, the menu bar quick
    // view) — matches MacSender.pauseDisplay/resumeDisplay's own guarded
    // capture-lifecycle phases, so no surface invents its own gating.
    var isPaused: Bool { capturePhase == .paused }
    var canPauseOrResume: Bool {
        capturePhase == .running || capturePhase == .recovering || capturePhase == .paused
    }

    init(id: String, logicalID: String, intendedPeerID: String?, attempt: AutoConnectPolicy.Attempt,
         target: ConnectionTarget, name: String, sender: MacSender) {
        self.id = id
        self.logicalID = logicalID
        self.intendedPeerID = intendedPeerID
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
            guard presentation != oldValue else { return }
            UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
            NSApp.setActivationPolicy(presentation.showsDockIcon ? .regular : .accessory)
            // Live switch: create/destroy the single status item right here,
            // rather than only reading the setting at launch — this is the
            // fix for the mode never actually gaining a menu-bar icon.
            MenuBarPresenceController.shared.apply(presentation, controller: self)
            // Never strand the user without UI: switching to a mode with no
            // menu-bar icon opens the Settings window immediately.
            if !presentation.showsMenuBarIcon { MacSettingsWindow.show() }
        }
    }

    /// Start at Login (Mac Sender only): backed by `SMAppService.mainApp`,
    /// never a stored boolean pretending to be the real state — reading
    /// `.status` on init means Settings always shows what's actually
    /// registered, including `.requiresApproval` after a Login Items change.
    @Published var startAtLoginEnabled = StartAtLoginPolicy.isEnabled() {
        didSet {
            guard startAtLoginEnabled != oldValue else { return }
            do {
                try StartAtLoginPolicy.setEnabled(startAtLoginEnabled)
                startAtLoginStatusMessage = StartAtLoginPolicy.statusMessage()
            } catch {
                // Registration failed: reflect reality rather than the
                // toggle the user just tapped.
                startAtLoginStatusMessage = "Couldn't update Start at Login: \(error.localizedDescription)"
                startAtLoginEnabled = StartAtLoginPolicy.isEnabled()
            }
        }
    }
    @Published var startAtLoginStatusMessage: String? = StartAtLoginPolicy.statusMessage()

    @Published var sessions: [DeviceSession] = []
    private var suppressModeRestart = false
    @Published var discovered: [NWBrowser.Result] = []
    @Published var usbDevices: [UsbmuxDevice] = []
    let pairingPrompt = PairingPromptModel()
    @Published var pairingMessage: String?
    @Published private(set) var pendingForget: ForgetConfirmation?
    /// Per-device/per-session input consent milestone: the single shared
    /// native-prompt surface for "<Device Name> wants to control this
    /// Mac" — see `InputControlRequestPromptModel`'s doc comment for why
    /// only one prompt is ever live at a time.
    let inputControlPrompt = InputControlRequestPromptModel()
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
    // Mirror's authoritative availability signal — Extend has no such
    // requirement. UI-facing only (`DisplaysSettingsView` disables the
    // Mirror option and explains why); `requestMode` never trusts this
    // cached value, it always re-checks live. Refreshed on every
    // `didChangeScreenParametersNotification` (the same topology-change
    // notification `MacSender`'s own headless detection already uses) —
    // see `startObservingPhysicalDisplayAvailability`.
    @Published private(set) var hasUsablePhysicalDisplay = true
    private var displayTopologyObserver: NSObjectProtocol?

    private func startObservingPhysicalDisplayAvailability() {
        refreshPhysicalDisplayAvailability()
        displayTopologyObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // `queue: .main` already guarantees this runs on the main thread;
            // the explicit hop is only to give the Swift 6 checker something
            // it can verify statically (it can't infer isolation from the
            // OperationQueue argument alone).
            Task { @MainActor in self?.refreshPhysicalDisplayAvailability() }
        }
    }

    private func refreshPhysicalDisplayAvailability() {
        hasUsablePhysicalDisplay = hasUsablePhysicalDisplayNow()
    }

    /// Live (never cached) check for whether a genuinely usable PHYSICAL
    /// display exists right now — excludes every current session's own
    /// MEOW virtual display, since a healthy VD otherwise reads as
    /// "usable" through the same CoreGraphics checks.
    private func hasUsablePhysicalDisplayNow() -> Bool {
        let virtualDisplayIDs = Set(sessions.compactMap { $0.sender.virtualDisplayID })
        return DisplayHealth.hasUsablePhysicalDisplay(excludingAny: virtualDisplayIDs)
    }

    @Published var quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .best {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    // Streaming Profile (high-refresh milestone). Default Performance: the
    // pre-milestone behavior already requested 120 from SCK and encoded at
    // an unconditional 60fps — Performance (capped by receiver capability)
    // is the closer match for every existing install than Efficiency would
    // be, and it's what most users installing this update want anyway.
    @Published var streamingProfile = StreamingProfile(rawValue: UserDefaults.standard.string(forKey: "streamingProfile") ?? "") ?? .performance {
        didSet { UserDefaults.standard.set(streamingProfile.rawValue, forKey: "streamingProfile") }
    }
    // Custom profile's manual frame-rate pick. Irrelevant outside `.custom`,
    // same as `mirrorDisplayUUID` is irrelevant outside `.mirror`.
    @Published var customFrameRate = CustomFrameRateSelection(rawValue: UserDefaults.standard.string(forKey: "customFrameRate") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(customFrameRate.rawValue, forKey: "customFrameRate") }
    }
    // Streaming Priority: bounded encoder-pipelining depth (Auto/Prefer FPS/
    // Prefer Latency — see StreamingPriorityPolicy). Default Auto so an
    // existing user with no stored value keeps today's balanced 2-deep
    // pipeline exactly as before this feature existed.
    @Published var streamingPriority = StreamingPriority(rawValue: UserDefaults.standard.string(forKey: "streamingPriority") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(streamingPriority.rawValue, forKey: "streamingPriority") }
    }
    // Codec preference (HEVC milestone): Auto/H.264/HEVC, same persistence
    // shape as `streamingProfile`/`streamingPriority`. Default Auto so an
    // existing user with no stored value gets today's H.264-only behavior
    // unless Auto's own policy (`CodecSelectionPolicy`) decides HEVC is
    // actually needed to satisfy the requested stream.
    @Published var codecPreference = CodecPreference(rawValue: UserDefaults.standard.string(forKey: "codecPreference") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(codecPreference.rawValue, forKey: "codecPreference") }
    }
    // Automatic/Custom streaming settings milestone. Default Automatic —
    // normal users get MEOW's existing default policy with no knobs shown;
    // `streamingProfile`/`streamingPriority`/`codecPreference`/`quality`/
    // `customFrameRate` above are left untouched by mode switches (see the
    // `effective*` properties below), so a user's prior Custom values are
    // still there, unmodified, the moment they switch back to Custom.
    @Published var streamingMode = StreamingMode(rawValue: UserDefaults.standard.string(forKey: "streamingMode") ?? "") ?? .automatic {
        didSet {
            guard streamingMode != oldValue else { return }
            UserDefaults.standard.set(streamingMode.rawValue, forKey: "streamingMode")
            restartAll()
        }
    }
    // What a session actually gets built with — `StreamingModePolicy`/
    // `StreamQuality.effective` fold in Automatic's fixed default policy;
    // only these (never the raw stored properties above) may reach
    // `MacSender.init`.
    var effectiveStreamingProfile: StreamingProfile {
        StreamingModePolicy.effectiveProfile(mode: streamingMode, stored: streamingProfile)
    }
    var effectiveCustomFPS: Int? {
        StreamingModePolicy.effectiveCustomFPS(mode: streamingMode, storedProfile: streamingProfile,
                                                storedCustomFPS: customFrameRate.requestedFPS)
    }
    var effectiveStreamingPriority: StreamingPriority {
        StreamingModePolicy.effectivePriority(mode: streamingMode, stored: streamingPriority)
    }
    var effectiveCodecPreference: CodecPreference {
        StreamingModePolicy.effectiveCodec(mode: streamingMode, stored: codecPreference)
    }
    var effectiveQuality: StreamQuality {
        StreamQuality.effective(mode: streamingMode, stored: quality)
    }
    // Mirror-mode's explicit display choice: a stable UUID (never a raw
    // CGDirectDisplayID — see MirrorDisplaySelection.swift), or nil for
    // Automatic. Irrelevant to Extend, which always uses its own virtual
    // display.
    // Default Extend shape for any peer with no per-peer stored preference of
    // its own yet (see `ExtendDisplayShapeStore`). Not itself pushed to
    // active sessions on change — that would make an already-customized
    // peer's shape bleed from whichever device this Mac-wide default last
    // changed for, which is exactly what per-peer persistence exists to
    // avoid. New connections pick it up naturally.
    @Published var extendShapeDefault = (UserDefaults.standard.dictionary(forKey: "extendShapeDefault")).flatMap {
        (raw: [String: Any]) -> ExtendDisplayShapePreference? in
        guard let rawShape = raw["shape"] as? String, let shape = ExtendDisplayShape(rawValue: rawShape) else { return nil }
        return ExtendDisplayShapePreference(shape: shape, useFullDisplay: raw["useFullDisplay"] as? Bool ?? false)
    } ?? .standard {
        didSet {
            UserDefaults.standard.set(["shape": extendShapeDefault.shape.rawValue,
                                        "useFullDisplay": extendShapeDefault.useFullDisplay],
                                       forKey: "extendShapeDefault")
        }
    }
    @Published var mirrorDisplayUUID = UserDefaults.standard.string(forKey: "mirrorDisplayUUID") {
        didSet {
            guard mirrorDisplayUUID != oldValue else { return }
            UserDefaults.standard.set(mirrorDisplayUUID, forKey: "mirrorDisplayUUID")
            if mode == .mirror { restartAll() }
        }
    }
    @Published var allowInput = InputPolicy.allowsInput() {
        didSet {
            guard allowInput != oldValue else { return }
            UserDefaults.standard.set(allowInput, forKey: InputPolicy.defaultsKey)
            sessions.forEach { session in
                // The master is a global kill switch: turning it off must
                // cancel every session's held input immediately, regardless
                // of that session's own grant (which is left untouched —
                // see the milestone's MAC MASTER INPUT SWITCH section:
                // turning the master back on during the same session may
                // resume a previously granted session with no fresh
                // request).
                if !allowInput { session.sender.resetReceiverInputState() }
                // Each session computes its OWN effective state from its
                // own grant — this is no longer one broadcast value shared
                // by every receiver.
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
        // Mirror requires a genuinely usable PHYSICAL display; Extend does
        // not. Re-checked LIVE here — never from the cached `@Published`
        // UI signal below — so a stale/racing request (the Mac-local
        // picker, or a receiver's `displayModeRequest` arriving just as the
        // Mac goes headless) can never push this Mac into an impossible
        // Mirror state. Reject and push the still-current mode back rather
        // than ever calling `restartAll()`/tearing down a working Extend
        // session for a mode this Mac cannot actually enter.
        guard requested != .mirror
            || MirrorUnavailableOfferPolicy.canEnterMirror(hasUsablePhysicalDisplay: hasUsablePhysicalDisplayNow())
        else {
            Log.info("routeDebug: rejected Mirror request — no usable physical display")
            sessions.forEach {
                $0.sender.pushDisplayModeState()
                $0.sender.pushMirrorUnavailable()
            }
            return
        }
        // `DisplaysSettingsView`'s Mode picker is a segmented control, whose
        // Binding(set:) AppKit invokes synchronously as part of SwiftUI's
        // current view-update transaction — this function's caller there,
        // not something under our control. Assigning `mode` in that same
        // frame cascades through its own `didSet` (`restartAll()` — tears
        // down and reconnects every session, `@Published`-mutating each one
        // along the way) still nested inside that transaction, which is
        // exactly "publishing changes from within view updates". Yielding
        // to the next main-actor turn lets SwiftUI finish committing the
        // picker's own update first; every other caller of `requestMode`
        // (a receiver's `displayModeRequest`) already runs on its own async
        // hop, so this adds at most one harmless extra turn there.
        Task { @MainActor in self.mode = requested }
    }

    func requestVideoEnabled(_ enabled: Bool) {
        guard enabled != videoEnabled else { return }
        // Mirror is established through the existing authoritative mode
        // transition before capture is stopped — this reclaims the virtual
        // display's system resources by handing input/capture off to a
        // physical display. Headless has nowhere for that hand-off to go:
        // becoming Mirror here would be exactly as impossible as if the
        // user had requested it directly (see `requestMode`'s guard), so
        // this stays in Extend and only stops capture — the VD survives to
        // resume into, exactly like the existing "stream survives for
        // audio" case inside `applyVideoEnabled` already does. Turning
        // video back on never restores Extend implicitly (that comment
        // still applies to the Mirror path below); staying in Extend here
        // means there is nothing to "restore" — it never left.
        if !enabled, mode == .extend,
           !MirrorUnavailableOfferPolicy.canEnterMirror(hasUsablePhysicalDisplay: hasUsablePhysicalDisplayNow()) {
            let transitioning = sessions
            guard !transitioning.isEmpty else {
                videoEnabled = false
                return
            }
            var remaining = transitioning.count
            for session in transitioning {
                session.sender.disableVideoKeepingExtend { [weak self] in
                    guard let self else { return }
                    remaining -= 1
                    if remaining == 0 { self.videoEnabled = false }
                }
            }
            return
        }
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
    // Last receiver-originated Connect token handled per peer id, so a
    // browse re-fire with the same still-published token (mDNS is noisy)
    // doesn't redial a session that's already coming up.
    private var handledConnectRequestTokens: [String: String] = [:]
    private var receiverPairingBrowser: NWBrowser?
    private var receiverPairingResults: [NWBrowser.Result] = []
    private var pairingListener: NWListener?
    /// "Pair over Remote": a fixed-port pairing listener that exists only
    /// while the user has explicitly opened the window (`RemotePairingWindow`).
    /// Reachability only; SAS confirmation and TrustStore pinning are unchanged.
    @Published private(set) var remotePairingWindow = RemotePairingWindow()
    private var remotePairingListener: NWListener?
    private var remotePairingExpiryTask: Task<Void, Never>?
    private var remotePairingConnection: NWConnection?
    private var remotePairingValidity: PairingAttemptValidity?
    private var remotePairingToken: UUID?
    /// Pinned-mutual-TLS listener a paired peer's authenticated remote
    /// connect-request "knock" arrives on — see `WireCrypto.remoteRequestPort`
    /// and `handleRemoteConnectRequest`.
    private var remoteConnectRequestListener: NWListener?
    /// Last time an accepted knock from each peer triggered a dial-back —
    /// `RemoteConnectRequestPolicy`'s rate-limit input.
    private var remoteConnectRequestAccepted: [String: Date] = [:]
    private var usbWatcher: UsbmuxDeviceWatcher?
    private var activePairingPeerIDs: Set<String> = []
    // Forwards each live session's own @Published changes (status, route,
    // applicationAuthenticated) into this controller's objectWillChange —
    // a DeviceSession is a separate ObservableObject, so without this a
    // SwiftUI view observing only `controller` would never re-render when a
    // session's authentication/route changes, and Active Display would show
    // stale state until some unrelated controller-level change (e.g. a
    // Bonjour update) happened to force a redraw.
    private var sessionObservations: [ObjectIdentifier: AnyCancellable] = [:]

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
    // UDIDs a proactive USB pairing attempt has already been made for this
    // process lifetime — mirrors `DeviceSession.usbPairingAttempted`'s
    // per-attach dedupe, but keyed by hardware rather than by session, since
    // an unpaired device never gets a `DeviceSession` at all (buildTransport
    // refuses to construct a transport with no pin — see below).
    private var usbPairingAttemptedUDIDs: Set<String> = []
    private let autoConnectEnabled = UserDefaults.standard.object(forKey: "autostart") == nil
        || UserDefaults.standard.bool(forKey: "autostart")
    /// Auto-Reconnect (Settings toggle, System category): gates only
    /// automatic connection attempts/retries — `AutoConnectPolicy.
    /// beginAutomaticAttempt` (discovery/startup auto-connect),
    /// `onPeerSleeping`'s automatic post-sleep reconnect, and each live
    /// `MacSender`'s in-place retry after ordinary transport loss
    /// (`ReconnectPolicy`). Explicit Connect/Reconnect/Wake & Connect always
    /// bypass it. Default true preserves existing behavior for installs with
    /// no stored value.
    @Published var autoReconnectEnabled = UserDefaults.standard.object(forKey: "autoReconnectEnabled") == nil
        || UserDefaults.standard.bool(forKey: "autoReconnectEnabled") {
        didSet {
            guard autoReconnectEnabled != oldValue else { return }
            UserDefaults.standard.set(autoReconnectEnabled, forKey: "autoReconnectEnabled")
            Log.info("reconnectPolicy: autoReconnect enabled=\(autoReconnectEnabled)")
            autoConnectPolicy.setAutoReconnectEnabled(autoReconnectEnabled)
            sessions.forEach { $0.sender.applyAutoReconnectPreferenceChange(enabled: autoReconnectEnabled) }
            if autoReconnectEnabled {
                Log.info("reconnectPolicy: reenabled reevaluatingAvailability")
                scheduleAutoConnect()
            }
        }
    }

    init() {
        _ = TrustStore.shared.ownIdentity()
        pairingPrompt.ownerAuthenticator = LocalOwnerAuthenticator()
        pairingPrompt.trustPinLookup = { TrustStore.shared.pin(peerID: $0) }
        autoConnectPolicy.setAutoReconnectEnabled(autoReconnectEnabled)
        startObservingPhysicalDisplayAvailability()
        pairingObservation = pairingPrompt.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // An explicit pairing request (new pair, re-pair, or identity-change)
        // must be seen regardless of Menu Bar/Background presentation or
        // whether the control window happens to be open — it cannot depend
        // on the user already having the Devices list in view.
        pairingPrompt.onPending = { [weak self] pending in
            guard let self else { return }
            Log.info("pairDebug: onPending peerID=\(pending.peerID)")
            Log.info("pairDebug: presenting classification=\(String(describing: pending.classification))")
            self.beginExplicitPairing(peerID: pending.peerID)
            // The confirmation panel is a stable AppKit object owned by the
            // coordinator, not a SwiftUI sheet on a settings page that may
            // not currently exist (Menu Bar presentation with the window
            // closed) — it must be seen and stay visible regardless.
            SecurityPresentationCoordinator.presentPairing(prompt: self.pairingPrompt)
            Log.info("pairDebug: pairingPanelPresented")
        }
        inputControlPrompt.onPending = { [weak self] pending in
            guard let self else { return }
            Log.info("inputConsentDebug: onPending peerID=\(pending.peerID)")
            SecurityPresentationCoordinator.presentInputControlRequest(prompt: self.inputControlPrompt)
        }
        persistKnownIdentifiers()
        startBrowsing()
        startReceiverPairingBrowsing()
        startPairingListener()
        startRemoteConnectRequestListener()
        usbWatcher = UsbmuxDeviceWatcher { [weak self] devices in
            guard let self else { return }
            let detached = Set(self.usbDevices.map(\.udid)).subtracting(devices.map(\.udid))
            self.usbPairingAttemptedUDIDs.subtract(detached)
            self.usbDevices = devices
            self.failover(detachedUDIDs: detached)
            self.attemptUSBPairingIfNeeded(devices: devices)
            self.scheduleAutoConnect()
        }
        #if DEBUG
        RouteOverrides.shared.onChange = { [weak self] in self?.enforceRouteOverrides() }
        PowerLifecycleLogger.start()
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
                self.handleReceiverConnectRequests(in: self.discovered)
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
                        self.finishExplicitPairing(peerID: paired.peerID, success: true)
                        self.pairingMessage = "Paired with \(paired.peerName)"
                        if let result = self.discovered.first(where: { self.txtID(of: $0) == paired.peerID }) {
                            self.connect(to: .wifi(result), userInitiated: true)
                        }
                    } catch {
                        if self.pairingPrompt.pending == nil {
                            self.finishAllExplicitPairing(success: false)
                            self.pairingMessage = error.localizedDescription
                        } else {
                            Log.info("pairDebug: duplicate responder ended without disturbing pending confirmation")
                        }
                    }
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

    var remotePairingPhase: RemotePairingPhase {
        .derive(windowOpen: remotePairingWindow.isOpen(now: Date()),
                attemptInProgress: remotePairingWindow.attemptInProgress,
                awaitingConfirmation: pairingPrompt.pending != nil)
    }

    func openRemotePairing() {
        guard let localID = TrustStore.shared.installID() else {
            pairingMessage = "Pairing unavailable — secure identity could not be loaded"
            return
        }
        closeRemotePairing(reason: "reopen")
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters,
                                          on: NWEndpoint.Port(rawValue: WireCrypto.remotePairingPort)!)
            remotePairingListener = listener
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, self.remotePairingListener === listener else {
                        connection.cancel(); return
                    }
                    await self.runRemotePairingAttempt(connection, localID: localID)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, self.remotePairingListener === listener else { return }
                    if case .failed(let error) = state {
                        Log.info("remotePairing: listener failed: \(error)")
                        self.closeRemotePairing(reason: "listenerFailed")
                        self.pairingMessage = "Couldn't start Pair over Remote"
                    }
                }
            }
            remotePairingWindow.open(now: Date())
            listener.start(queue: .main)
            remotePairingExpiryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(RemotePairingWindow.openDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.closeRemotePairing(reason: "expired")
            }
            pairingMessage = "Pair over Remote is on"
            Log.info("remotePairing: window opened")
        } catch {
            Log.info("remotePairing: listener could not be created: \(error)")
            pairingMessage = "Couldn't start Pair over Remote"
        }
    }

    func closeRemotePairing(reason: String = "userClosed") {
        let wasActive = remotePairingListener != nil
        remotePairingExpiryTask?.cancel(); remotePairingExpiryTask = nil
        remotePairingListener?.cancel(); remotePairingListener = nil
        remotePairingValidity?.invalidate(); remotePairingValidity = nil
        if remotePairingWindow.attemptInProgress {
            remotePairingConnection?.cancel()
            if let token = remotePairingToken { pairingPrompt.cancel(ownedBy: token) }
        }
        remotePairingWindow.close()
        if wasActive {
            Log.info("remotePairing: window closed reason=\(reason)")
            if reason != "reopen" && reason != "success", pairingMessage == "Pair over Remote is on" {
                pairingMessage = reason == "expired" ? "Pair over Remote turned off" : nil
            }
        }
    }

    private func runRemotePairingAttempt(_ connection: NWConnection, localID: String) async {
        let admission = remotePairingWindow.admit(now: Date())
        guard admission == .admitted else {
            Log.info("remotePairing: attempt rejected admission=\(admission)")
            connection.cancel(); return
        }
        Log.info("remotePairing: handshake started")
        let validity = PairingAttemptValidity()
        remotePairingValidity = validity
        remotePairingConnection = connection
        let token = UUID()
        remotePairingToken = token
        let deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RemotePairingWindow.attemptDeadline * 1_000_000_000))
            guard !Task.isCancelled else { return }
            Log.info("remotePairing: attempt deadline reached")
            validity.invalidate()
            connection.cancel()
            self?.pairingPrompt.cancel(ownedBy: token)
        }
        var success = false
        do {
            let paired = try await PairingNetwork.runResponder(
                connection: connection, localID: localID,
                localName: Host.current().localizedName ?? "Mac",
                prompt: pairingPrompt, allowIdentityChange: false,
                isCurrent: { validity.isValid }, attemptToken: token)
            success = true
            finishExplicitPairing(peerID: paired.peerID, success: true)
            pairingMessage = "Paired with \(paired.peerName)"
            Log.info("remotePairing: completed")
        } catch {
            Log.info("remotePairing: failed error=\(error)")
            if pairingPrompt.pending == nil {
                finishAllExplicitPairing(success: false)
                pairingMessage = RemotePairingFailure.message(for: error)
            }
        }
        deadline.cancel()
        connection.cancel()
        if remotePairingValidity === validity {
            remotePairingConnection = nil
            remotePairingToken = nil
            remotePairingWindow.finishAttempt(success: success, now: Date())
            if success { closeRemotePairing(reason: "success") }
            objectWillChange.send()
        }
    }

    /// Pinned-mutual-TLS listener for authenticated remote connect-request
    /// "knocks" (see `WireCrypto.remoteRequestPort`). Unlike the pairing
    /// listener above, this never runs an unauthenticated bootstrap — it
    /// reuses the exact same `TLSConfigurator.mutualTLSOptions` construction
    /// as `StreamReceiver`'s own TLS listener, so only an already-pinned
    /// peer's client certificate can complete the handshake at all.
    private func startRemoteConnectRequestListener() {
        guard remoteConnectRequestListener == nil,
              let identity = TrustStore.shared.ownIdentity(),
              let tls = TLSConfigurator.mutualTLSOptions(
                identity: identity,
                pinnedSPKIs: { TrustStore.shared.allPinnedPeerSPKIs() },
                isListener: true, queue: .main) else {
            Log.info("remote connect-request listener unavailable — no identity/pins yet")
            return
        }
        do {
            let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
            let params = NWParameters(tls: tls, tcp: tcp)
            params.includePeerToPeer = true
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params,
                on: NWEndpoint.Port(rawValue: WireCrypto.remoteRequestPort)!)
            remoteConnectRequestListener = listener
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                Task { @MainActor [weak self, weak listener] in
                    guard let self, self.remoteConnectRequestListener === listener else {
                        connection.cancel(); return
                    }
                    self.acceptRemoteConnectRequest(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor [weak self, weak listener] in
                    switch state {
                    case .ready:
                        Log.info("remote connect-request listener ready: port=\(WireCrypto.remoteRequestPort)")
                    case .failed(let error):
                        Log.info("remote connect-request listener failed: \(error)")
                        guard let self, self.remoteConnectRequestListener === listener else { return }
                        self.remoteConnectRequestListener = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                            self?.startRemoteConnectRequestListener()
                        }
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        } catch {
            Log.info("remote connect-request listener could not be created: \(error)")
        }
    }

    /// Rebuilds the remote connect-request listener after a trust change
    /// (specifically Forget/revocation). `TLSConfigurator`'s verify block
    /// already re-reads `TrustStore`'s live pin snapshot on every full
    /// handshake — closures, not captured values — so a forgotten peer's
    /// next *new* handshake is rejected without this. This exists as
    /// defense-in-depth against TLS-layer session-resumption state (session
    /// tickets) potentially outliving the listener socket that issued them,
    /// mirroring the exact rebuild `StreamReceiver.scheduleTLSListenerRefresh`
    /// already performs on its own TLS listener after a trust change.
    private func scheduleRemoteConnectRequestListenerRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.remoteConnectRequestListener?.cancel()
            self.remoteConnectRequestListener = nil
            self.startRemoteConnectRequestListener()
        }
    }

    /// Accepts one knock connection, resolves the caller's pinned peerID
    /// from its TLS client certificate, and closes it — the connection's
    /// mere completion (as an already-pinned peer) is the entire request; no
    /// payload from it is ever trusted. A caller whose certificate isn't
    /// currently pinned never completes the handshake at all (see
    /// `TLSConfigurator`'s verify block), so failure to resolve a peerID
    /// here only happens if the pin set changed between handshake and
    /// resolution — treated as a reject, never a crash.
    private func acceptRemoteConnectRequest(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { connection.cancel(); return }
                switch state {
                case .ready:
                    let observedHost = Self.hostString(from: connection.currentPath?.remoteEndpoint ?? connection.endpoint)
                    let peerID = Self.resolvePinnedPeerID(from: connection)
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    guard let peerID else {
                        Log.info("SECURITY: remote connect-request from unresolvable/unpinned peer rejected")
                        return
                    }
                    self.handleRemoteConnectRequest(peerID: peerID, observedHost: observedHost)
                case .failed, .cancelled:
                    connection.stateUpdateHandler = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }

    /// Extracts the completed handshake's leaf certificate SPKI (same
    /// same-source re-encode `TrustStore`/`TLSConfigurator` use elsewhere)
    /// and resolves it to a pinned peerID. Returns nil if the connection has
    /// no TLS metadata or the SPKI matches no current pin.
    private static func resolvePinnedPeerID(from connection: NWConnection) -> String? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        var resolved: String?
        sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            guard resolved == nil else { return }
            let secCert = sec_certificate_copy_ref(certificate).takeRetainedValue()
            guard let key = SecCertificateCopyKey(secCert),
                  let x963 = SecKeyCopyExternalRepresentation(key, nil) as Data?,
                  let pub = try? P256.Signing.PublicKey(x963Representation: x963) else { return }
            resolved = TrustStore.shared.peerID(forSPKI: pub.derRepresentation)
        }
        return resolved
    }

    /// Host-only string (no port) for an inbound knock's observed network
    /// source — used only as a last-resort dial-back candidate, and only
    /// after the peer's identity is already authenticated (see
    /// `handleRemoteConnectRequest`). Never used for identity.
    private static func hostString(from endpoint: NWEndpoint?) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        return String(describing: host)
    }

    /// Routes an authenticated remote connect-request to the best available
    /// path, in the same preference order as the rest of unified Connect: a
    /// currently visible local peer wins outright (no unnecessary Remote
    /// takeover), then a persisted Remote Access hint the user configured
    /// for this peer, then the network source address the authenticated
    /// knock itself arrived from — safe because it comes from a connection
    /// that has already passed pinned mutual TLS, never a claimed or
    /// unauthenticated value. `RemoteConnectRequestPolicy` bounds how often
    /// repeated knocks from the same peer can trigger a fresh dial.
    private func handleRemoteConnectRequest(peerID: String, observedHost: String?) {
        let now = Date()
        guard RemoteConnectRequestPolicy.shouldHandle(
            peerID: peerID, now: now, lastAccepted: remoteConnectRequestAccepted) else {
            Log.info("routeDebug: remote connect-request peer=\(peerID) ignored (rate-limited)")
            return
        }
        remoteConnectRequestAccepted[peerID] = now

        func dial(_ target: ConnectionTarget, via routeDescription: String) -> Bool {
            if let existing = session(for: target.sessionID), !existing.failed {
                Log.info("routeDebug: remote connect-request peer=\(peerID) already connecting/connected via \(routeDescription)")
                return true
            }
            Log.info("routeDebug: remote connect-request peer=\(peerID) resolved via \(routeDescription)")
            return connect(to: target, userInitiated: true)
        }

        if let localResult = discovered.first(where: { txtID(of: $0) == peerID }) {
            if dial(.wifi(localResult), via: "local Bonjour") { return }
        }
        if RemoteEndpointStore.endpoint(forPeerID: peerID) != nil {
            if dial(.remote(peerID: peerID), via: "persisted Remote hint") { return }
        }
        guard let observedHost else {
            Log.info("routeDebug: remote connect-request peer=\(peerID) has no usable route")
            return
        }
        _ = dial(.remoteCallback(peerID: peerID, host: observedHost, port: WireCrypto.tlsPort),
             via: "observed source \(observedHost)")
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

    private func connectRequestToken(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata { return txt["cr"] }
        return nil
    }

    /// Handles a trusted receiver's explicit Connect tap (see
    /// `StreamReceiver.requestConnect`). The token itself proves nothing —
    /// it's discovery metadata, as unauthenticated as the rest of the
    /// Bonjour TXT record — so this only ever funnels into the same
    /// `connect(to:userInitiated:)` a Mac-side Connect button uses. That
    /// path checks the peer against TrustStore's pinned identifiers before
    /// dialing, and the dial itself still runs full pinned mutual TLS + the
    /// MEOW hello/welcome handshake, so a spoofed or replayed token can, at
    /// worst, provoke a dial that then fails trust/TLS — it can never skip
    /// authentication or connect to the wrong device.
    private func handleReceiverConnectRequests(in results: [NWBrowser.Result]) {
        for result in results {
            guard let token = connectRequestToken(of: result) else { continue }
            guard let peerID = txtID(of: result) else { continue }
            guard handledConnectRequestTokens[peerID] != token else { continue }
            handledConnectRequestTokens[peerID] = token
            guard isPaired(result) else {
                Log.info("connectDebug: receiverConnectRequestRejected reason=untrustedPeer")
                continue
            }
            Log.info("connectDebug: receiverConnectRequestAccepted peer=\(peerID)")
            let target = ConnectionTarget.wifi(result)
            if let existing = session(for: target.sessionID), !existing.failed {
                Log.info("connectDebug: senderStartRequested peer=\(peerID) alreadyConnecting=true")
                continue
            }
            let localStarted = connect(to: target, userInitiated: true)
            if localStarted { continue }
            // A present-but-blocked/unusable local record must not end
            // route evaluation: fall through to a configured Remote hint.
            let endpointFound = RemoteEndpointStore.endpoint(forPeerID: peerID) != nil
            guard endpointFound else { continue }
            connect(to: .remote(peerID: peerID), userInitiated: true)
        }
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
    /// either a persisted Tailscale connection hint or, when
    /// `hostOverride`/`portOverride` are given (an authenticated remote
    /// connect-request's observed source — see `handleRemoteConnectRequest`),
    /// that address instead. Either way the endpoint is only ever a hint —
    /// `TLSConfigurator`'s SPKI check is what actually authorizes the
    /// connection.
    private func secureRemoteTransport(forPeerID peerID: String,
                                       hostOverride: String? = nil,
                                       portOverride: UInt16? = nil) -> SenderTransport? {
        let resolvedHost: String
        let resolvedPort: UInt16
        if let hostOverride, let portOverride {
            resolvedHost = hostOverride
            resolvedPort = portOverride
        } else if let hint = RemoteEndpointStore.endpoint(forPeerID: peerID) {
            resolvedHost = hint.host
            resolvedPort = hint.port
        } else {
            Log.info("routeDebug: Remote unavailable for peer=\(peerID) — no persisted endpoint hint")
            return nil
        }
        guard let port = NWEndpoint.Port(rawValue: resolvedPort) else {
            Log.info("routeDebug: Remote unavailable for peer=\(peerID) — invalid port \(resolvedPort)")
            return nil
        }
        guard let pin = TrustStore.shared.pin(peerID: peerID),
              let identity = TrustStore.shared.ownIdentity() else {
            // A forgotten/unpaired peer must never be dialed over Remote —
            // an endpoint hint alone never implies trust.
            Log.info("routeDebug: Remote refused for peer=\(peerID) — no local trust/pin for this peer")
            return nil
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(resolvedHost), port: port)
        Log.info("routeDebug: dialing Remote candidate peer=\(peerID) endpoint=\(resolvedHost):\(resolvedPort)")
        return .tcp(endpoint,
                    tls: TLSSessionConfig(identity: identity,
                                          pinnedPeerSPKI: pin,
                                          peerID: peerID))
    }

    func pair(_ result: NWBrowser.Result) {
        if case .bonjour(let txt) = result.metadata,
           let raw = txt["pv"], let version = Int(raw),
           version < WireProtocol.securePairingWireVersion {
            pairingMessage = "Update MeowDisplay on this device to pair securely"
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
        beginExplicitPairing(peerID: expected!)
        Task { @MainActor in
            let endpoint = await waitForPairingEndpoint(stableID: expected, timeout: 3)
            guard let endpoint else {
                Log.info("pair unavailable: no _opendisplay-pair._tcp result matched id=\(expected ?? "missing")")
                pairingMessage = "Pairing unavailable — pairing service was not found"
                finishExplicitPairing(peerID: expected!, success: false)
                return
            }
            let connection = NWConnection(to: endpoint, using: .tcp)
            defer { connection.cancel() }
            do {
                let paired = try await PairingNetwork.runInitiator(
                    connection: connection, localID: localID,
                    localName: Host.current().localizedName ?? "Mac",
                    prompt: pairingPrompt, expectedPeerID: expected)
                finishExplicitPairing(peerID: paired.peerID, success: true)
                pairingMessage = "Paired with \(paired.peerName)"
                objectWillChange.send()
                connect(to: .wifi(result), userInitiated: true)
            } catch {
                if pairingPrompt.pending == nil {
                    finishExplicitPairing(peerID: expected!, success: false)
                    pairingMessage = error.localizedDescription
                } else {
                    Log.info("pairDebug: duplicate initiator ended without disturbing pending confirmation")
                }
            }
        }
    }

    private func beginExplicitPairing(peerID: String) {
        guard activePairingPeerIDs.insert(peerID).inserted else { return }
        Log.info("pairDebug: explicit pairing started peerID=\(peerID)")
        let identifiers = Set(["install:\(peerID)"])
        autoConnectPolicy.beginPairing(identifiers)
        autoConnectWorkItem?.cancel()
        for session in sessions where session.deviceID == peerID {
            end(session)
        }
    }

    private func finishExplicitPairing(peerID: String, success: Bool) {
        guard activePairingPeerIDs.remove(peerID) != nil else { return }
        autoConnectPolicy.finishPairing(["install:\(peerID)"])
        Log.info("pairDebug: pairing finished success=\(success)")
        if !success { scheduleAutoConnect() }
    }

    /// USB media is now gated by a TrustStore pin (see `buildTransport`), so
    /// an unpaired/never-seen device never reaches a live session and can
    /// therefore never self-report an identity to trigger pairing reactively
    /// — pairing must instead be offered as soon as the hardware attaches.
    /// Dials the pairing ceremony directly over usbmux (port
    /// `WireCrypto.pairingPort`), independent of any media session; the
    /// ceremony itself discovers the peer's identity (`expectedPeerID` is
    /// only supplied when one is already known, e.g. a previously-paired
    /// UDID whose pin was later forgotten — same semantics as the reactive
    /// hello-triggered path this mirrors).
    private func attemptUSBPairingIfNeeded(devices: [UsbmuxDevice]) {
        for device in devices {
            let udid = device.udid
            let knownPeerID = installIDByUDID[udid]
            let hasPin = knownPeerID.map { TrustStore.shared.hasPin(peerID: $0) } ?? false
            guard USBPairingPolicy.shouldBeginPairing(
                hasPin: hasPin, alreadyAttemptedThisSession: usbPairingAttemptedUDIDs.contains(udid)
            ) else { continue }
            usbPairingAttemptedUDIDs.insert(udid)
            Task { [weak self] in
                guard let self else { return }
                do {
                    let connection = try await Usbmux.dial(
                        udid: udid, port: WireCrypto.pairingPort,
                        queue: DispatchQueue(label: "pairing.usb.proactive"))
                    defer { connection.cancel() }
                    guard let localID = TrustStore.shared.installID() else {
                        throw PairingError.invalidKey
                    }
                    let paired = try await PairingNetwork.runInitiator(
                        connection: connection, localID: localID,
                        localName: Host.current().localizedName ?? "Mac",
                        prompt: self.pairingPrompt, expectedPeerID: knownPeerID,
                        allowIdentityChange: USBPairingPolicy.allowIdentityChange)
                    self.installIDByUDID[udid] = paired.peerID
                    self.pairingMessage = "Paired with \(paired.peerName)"
                    self.scheduleAutoConnect()   // the fresh pin makes buildTransport succeed now
                } catch {
                    self.pairingMessage = "USB pairing failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func finishAllExplicitPairing(success: Bool) {
        let peerIDs = activePairingPeerIDs
        for peerID in peerIDs { finishExplicitPairing(peerID: peerID, success: success) }
    }

    func forgetPairing(peerID: String) {
        Log.info("trustDebug: forgetPairingCalled peerID=\(peerID)")
        Log.info("trustDebug: trustBefore=\(TrustStore.shared.hasPin(peerID: peerID))")
        Log.info("trustDebug: remoteEndpointBefore=\(RemoteEndpointStore.endpoint(forPeerID: peerID) != nil)")
        Log.info("trustDebug: wakeMetadataBefore=\(WakeMetadataStore.metadata(forPeerID: peerID) != nil)")
        ForgetDeviceAction.perform(
            peerID: peerID,
            forgetTrust: { TrustStore.shared.forget(peerID: $0) },
            removeRemoteEndpoint: { RemoteEndpointStore.removeEndpoint(forPeerID: $0) },
            removeWakeMetadata: { WakeMetadataStore.removeMetadata(forPeerID: $0) },
            removeInputAuthorization: { ReceiverInputAuthorizationStore.removePolicy(peerID: $0) })
        // Forget must take effect immediately for a still-open listener
        // socket, not just for the next connection this process happens to
        // build fresh TLS options for — see `scheduleRemoteConnectRequestListenerRefresh`.
        scheduleRemoteConnectRequestListenerRefresh()
        installIDByUDID = installIDByUDID.filter { $0.value != peerID }
        // Suppress immediate reconnect before anything discovered can beat
        // the user to it, then end the live session (which also suppresses
        // its own route aliases).
        autoConnectPolicy.suppress(["install:\(peerID)"])
        let matchingSessions = sessions.filter {
            $0.deviceID == peerID || $0.intendedPeerID == peerID
        }
        for session in matchingSessions {
            autoConnectPolicy.suppress(identifiers(for: session))
            end(session)   // also dismisses any pending input-control prompt — see `end`'s doc comment
        }
        Log.info("trustDebug: sessionsTerminated=\(matchingSessions.count)")
        let trustAfter = TrustStore.shared.hasPin(peerID: peerID)
        Log.info("trustDebug: trustDeleteResult=\(!trustAfter)")
        Log.info("trustDebug: trustAfter=\(trustAfter)")
        Log.info("trustDebug: pinnedPeersContainsAfter=\(TrustStore.shared.pinnedPeers().contains { $0.peerID == peerID })")
        Log.info("trustDebug: remoteEndpointAfter=\(RemoteEndpointStore.endpoint(forPeerID: peerID) != nil)")
        Log.info("trustDebug: wakeMetadataAfter=\(WakeMetadataStore.metadata(forPeerID: peerID) != nil)")
        Log.info("deviceUI: knownPeer removed peerID=\(peerID)")
        pairingMessage = "Device forgotten"
        objectWillChange.send()
        Log.info("trustDebug: uiRefreshTriggered")
    }

    func requestForget(peerID: String, name: String) {
        Log.info("trustDebug: forgetButtonTapped peerID=\(peerID)")
        let request = ForgetConfirmation(peerID: peerID, name: name)
        pendingForget = request
        Log.info("trustDebug: confirmationPresented peerID=\(peerID)")
        // Same rationale as pairing: a destructive trust decision must not
        // depend on a transient settings page's `.alert` — it is presented
        // through the stable coordinator instead.
        SecurityPresentationCoordinator.presentForget(request, controller: self)
    }

    func confirmForget(_ request: ForgetConfirmation) {
        guard pendingForget?.peerID == request.peerID else { return }
        pendingForget = nil
        Log.info("trustDebug: confirmationAccepted peerID=\(request.peerID)")
        forgetPairing(peerID: request.peerID)
    }

    func cancelForget(_ request: ForgetConfirmation) {
        guard pendingForget?.peerID == request.peerID else { return }
        pendingForget = nil
        Log.info("trustDebug: confirmationCancelled peerID=\(request.peerID)")
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
        case .remote(let peerID), .remoteCallback(let peerID, _, _):
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
        candidates += RemoteEndpointStore.allPeerIDs().compactMap { peerID -> AutoConnectCandidate? in
            guard TrustStore.shared.hasPin(peerID: peerID) else { return nil }
            let target = ConnectionTarget.remote(peerID: peerID)
            let logicalID = logicalID(for: target)
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

    /// Best-effort route classification *before* a connection exists, using
    /// only what discovery already told us (Bonjour interfaces) — used both
    /// for the DEBUG override gate's label and, unconditionally, as the
    /// route-tier fallback in `startSession`'s peer-ownership/migration
    /// check before a live path exists. The real route a live session
    /// reports (`DeviceSession.route`) still comes from
    /// `NWConnection.currentPath` and is unaffected by this.
    private func preConnectRoute(for target: ConnectionTarget) -> ConnectionRoute {
        switch target {
        case .usb: return .usb
        case .remote, .remoteCallback: return .remote
        case .wifi(let result):
            let names = result.interfaces.map(\.name)
            return ConnectionRoute.classify(isUSB: false, interfaceNames: names,
                                            remoteEndpointDescription: nil)
        }
    }

    #if DEBUG
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
        var successfullyStartedLogicalIDs = Set<String>()
        for candidate in candidates {
            if successfullyStartedLogicalIDs.contains(candidate.logicalID) { continue }
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
                successfullyStartedLogicalIDs.insert(candidate.logicalID)
                continue
            }
            let hasOwner = covering != nil || sessions.contains {
                !$0.failed && !identifiers(for: $0).isDisjoint(with: candidate.identifiers)
            }
            if !autoConnectPolicy.suppressedIdentifiers.isDisjoint(with: candidate.identifiers) {
                Log.info("connectDebug: autoConnect skipped suppressed peer=\(candidate.logicalID)")
            }
            guard let attempt = autoConnectPolicy.beginAutomaticAttempt(
                logicalID: candidate.logicalID, identifiers: candidate.identifiers,
                hasSessionOwner: hasOwner) else {
                if autoConnectPolicy.isPairing(candidate.identifiers) {
                    Log.info("pairDebug: media auto-connect suppressed reason=pairingInProgress")
                } else if !autoConnectPolicy.autoReconnectEnabled {
                    Log.info("reconnectPolicy: automaticAttempt suppressed reason=disabled peer=\(candidate.logicalID)")
                }
                // Suppressed or already owned — skip all lower-priority
                // candidates for this device too.
                successfullyStartedLogicalIDs.insert(candidate.logicalID)
                continue
            }
            if startSession(to: candidate.target, logicalID: candidate.logicalID,
                         attempt: attempt) {
                successfullyStartedLogicalIDs.insert(candidate.logicalID)
            }
        }
    }

    /// Cable plugged in while the device streams over WiFi: migrate the live
    /// session onto USB. No-op when the session is already cabled.
    private func upgradeToUSB(_ session: DeviceSession, device: UsbmuxDevice) {
        guard !session.onUSB else { return }
        #if DEBUG
        guard routeAdmission(for: .usb(udid: device.udid)) else { return }
        #endif
        // The match may have been by name only — pin the strong identity so
        // future matching (and the next launch) recognizes the pair, and so
        // buildTransport below can find this peer's TrustStore pin.
        if let id = session.deviceID { installIDByUDID[device.udid] = id }
        guard let transport = buildTransport(for: .usb(udid: device.udid)) else {
            // No trusted pin for this hardware (yet) — stay on the current
            // route rather than attempting an unauthenticated USB session.
            return
        }
        Log.info("cable attached for \(session.id) — migrating to USB")
        session.onUSB = true
        session.usbUDID = device.udid
        session.sender.switchTransport(to: transport)
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
        case .remote(let peerID), .remoteCallback(let peerID, _, _):
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

    @discardableResult
    func connect(to target: ConnectionTarget, userInitiated: Bool = false,
                 awaitingWake: Bool = false) -> Bool {
        if let existing = session(for: target.sessionID), !existing.failed { return true }
        let logicalID = logicalID(for: target)
        let targetIdentifiers = identifiers(for: target)
        let attempt: AutoConnectPolicy.Attempt
        if userInitiated {
            if !autoConnectPolicy.suppressedIdentifiers.isDisjoint(with: targetIdentifiers) {
                Log.info("connectDebug: explicitConnectClearedSuppression peer=\(logicalID)")
            }
            attempt = autoConnectPolicy.beginExplicitAttempt(
                logicalID: logicalID, identifiers: targetIdentifiers)
            persistKnownIdentifiers()
        } else {
            attempt = autoConnectPolicy.beginContinuationAttempt(logicalID: logicalID)
        }
        return startSession(to: target, logicalID: logicalID, attempt: attempt,
                            userInitiated: userInitiated, awaitingWake: awaitingWake)
    }

    /// The live session (any route) that already owns this logical peer, if
    /// any — the single central peer-ownership check. A failed session owns
    /// nothing, matching `activeSession(coveringUSB/WiFi:)`'s prior behavior.
    private func owningSession(for target: ConnectionTarget) -> DeviceSession? {
        let targetIdentifiers = identifiers(for: target)
        return sessions.first { !$0.failed && !identifiers(for: $0).isDisjoint(with: targetIdentifiers) }
    }

    private func routeTier(for target: ConnectionTarget) -> Int {
        RoutePriority.tier(preConnectRoute(for: target))
    }

    /// Prefers the route Network.framework actually reported
    /// (`DeviceSession.route`) over the pre-connection guess — accurate for
    /// LAN vs AWDL, which `preConnectRoute` cannot always distinguish before
    /// a path exists.
    private func routeTier(for session: DeviceSession) -> Int {
        RoutePriority.tier(session.route ?? preConnectRoute(for: session.target))
    }

    /// Builds the transport for a connection target — shared by fresh
    /// session creation and in-place route migration so both build it
    /// identically. `nil` means the target isn't dialable right now (e.g. no
    /// pin yet); callers treat that as attempt failure.
    private func buildTransport(for target: ConnectionTarget) -> SenderTransport? {
        switch target {
        case .usb(let udid):
            if UserDefaults.standard.object(forKey: "host") != nil, udid == nil {
                // Manual override: dial a plain TCP endpoint instead of usbmuxd.
                // Explicit local-debugging escape hatch only — untouched by
                // the secure-USB path below.
                guard let portNum = UInt16(port) else { return nil }
                return .tcp(.hostPort(host: NWEndpoint.Host(host),
                                      port: NWEndpoint.Port(rawValue: portNum)!), tls: nil)
            }
            // USB is only a ROUTE — media must be gated by the same pinned
            // cryptographic identity as LAN/Remote. No pin (unknown/never-
            // paired hardware, or a forgotten peer) means no transport at
            // all: nil here is exactly the existing "not dialable right
            // now" contract this function already documents, so callers
            // fail closed automatically rather than falling back to
            // anything unauthenticated.
            guard let udid,
                  let resolved = USBSecureTransportPolicy.resolve(
                    udid: udid, installIDByUDID: installIDByUDID,
                    pin: { TrustStore.shared.pin(peerID: $0) }),
                  let identity = TrustStore.shared.ownIdentity() else { return nil }
            return .usb(udid: udid, tls: TLSSessionConfig(identity: identity,
                                                            pinnedPeerSPKI: resolved.pin,
                                                            peerID: resolved.peerID))
        case .wifi(let result):
            return secureWiFiTransport(for: result)
        case .remote(let peerID):
            return secureRemoteTransport(forPeerID: peerID)
        case .remoteCallback(let peerID, let host, let port):
            return secureRemoteTransport(forPeerID: peerID, hostOverride: host, portOverride: port)
        }
    }

    /// Migrates a live session to a better route for the same peer without
    /// tearing down capture — the same mechanism `upgradeToUSB`/`failover`
    /// already use for their specific directions, generalized here to also
    /// cover LAN/AWDL <-> Remote.
    private func migrateSession(_ session: DeviceSession, to target: ConnectionTarget,
                                transport: SenderTransport) {
        switch target {
        case .usb(let udid):
            session.onUSB = true
            session.usbUDID = udid
            if let id = session.deviceID, let udid { installIDByUDID[udid] = id }
        case .wifi(let result):
            session.onUSB = false
            session.wifiServiceName = serviceName(of: result)
        case .remote, .remoteCallback:
            session.onUSB = false
        }
        session.sender.switchTransport(to: transport)
    }

    private func startSession(to target: ConnectionTarget, logicalID: String,
                              attempt: AutoConnectPolicy.Attempt,
                              userInitiated: Bool = false,
                              awaitingWake: Bool = false) -> Bool {
        let targetIdentifiers = identifiers(for: target)
        guard !autoConnectPolicy.isPairing(targetIdentifiers) else {
            Log.info("pairDebug: media auto-connect suppressed reason=pairingInProgress")
            autoConnectPolicy.finish(attempt)
            return false
        }
        #if DEBUG
        // Central hard gate: every path that can start a session — auto-
        // connect, explicit user taps, and pairing's immediate connect —
        // funnels through here, so this single check is authoritative.
        guard routeAdmission(for: target) else {
            autoConnectPolicy.finish(attempt)
            return false
        }
        #endif
        let id = target.sessionID
        if let existing = session(for: id) {
            // A failed session holds no pipeline — replace the corpse
            // instead of letting it swallow the fresh attempt.
            guard existing.failed else {
                autoConnectPolicy.finish(attempt)
                return false
            }
            end(existing)
        }

        // One logical peer = one live session, on ANY route (USB/WiFi/Remote
        // alike) — the receiver holds one connection, so a twin would steal
        // it. `owningSession` is the single central check every entry point
        // (explicit Connect, receiver Connect-request, remote knock,
        // auto-connect) funnels through here, replacing the old USB/WiFi-only
        // `covering` check that let a Remote target slip past unchecked and
        // spin up a second sender for a peer already live on LAN/AWDL.
        if let owner = owningSession(for: target) {
            // `userInitiated` deliberately never factors into this decision:
            // a single Connect/Wake & Connect action fans out into BOTH a
            // local Bonjour connect request and a Remote connect request
            // when Remote is configured, so both arrive here as
            // user-initiated attempts for the same peer — letting either one
            // "replace" an equal/worse-route owner re-creates the exact
            // thrash this check exists to prevent (see
            // `RouteArbitrationDecision`'s doc comment).
            let decision = RouteArbitration.decide(
                ownerTier: routeTier(for: owner), targetTier: routeTier(for: target))
            switch decision {
            case .proceed:
                break   // unreachable when `owner` is non-nil, kept exhaustive
            case .migrate:
                // A genuinely better route appeared (Remote -> LAN/AWDL,
                // LAN/AWDL -> USB) — migrate the existing sender through
                // `switchTransport` instead of creating a second one.
                guard let transport = buildTransport(for: target) else {
                    autoConnectPolicy.finish(attempt)
                    return false
                }
                Log.info("routeDebug: better route available for \(owner.logicalID) — "
                    + "migrating \(owner.id) to \(id)")
                migrateSession(owner, to: target, transport: transport)
                autoConnectPolicy.finish(attempt)
                return true
            case .ignore:
                // Same-or-worse route than the current owner (including
                // LAN<->AWDL, which are the same tier, and a second
                // user-initiated request for a different route arriving
                // after migration already happened): never steal, and never
                // bounce. Also covers a stale/retired route's own redial
                // callback firing after another route already won.
                Log.info("routeDebug: connect attempt to \(id) ignored — "
                    + "\(owner.id) already owns \(owner.logicalID) at an equal/better route")
                autoConnectPolicy.finish(attempt)
                return false
            }
        }

        guard let transport = buildTransport(for: target) else {
            autoConnectPolicy.finish(attempt)
            return false
        }

        let name = label(for: target)
        let sender = MacSender(transport: transport, name: name, mode: mode,
                               quality: effectiveQuality, displaySerial: Self.displaySerial(for: id),
                               identityOffset: identityOffset(for: id),
                               awaitingWake: awaitingWake,
                               videoEnabled: videoEnabled,
                               mirrorDisplayUUID: mirrorDisplayUUID,
                               streamingProfile: effectiveStreamingProfile,
                               customFPS: effectiveCustomFPS,
                               extendShapePreference: extendShapeDefault,
                               streamingPriority: effectiveStreamingPriority,
                               codecPreference: effectiveCodecPreference)
        sender.autoReconnectEnabled = autoReconnectEnabled
        let intendedPeerID: String? = {
            if logicalID.hasPrefix("install:") { return String(logicalID.dropFirst("install:".count)) }
            if case .wifi(let result) = target { return txtID(of: result) }
            return nil
        }()
        let session = DeviceSession(id: id, logicalID: logicalID, intendedPeerID: intendedPeerID,
                                    attempt: attempt,
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
            // Only ever fires for `requested == true` — see the closure's
            // doc comment on `MacSender.onAllowInputRequest`; a release
            // (`false`) is applied immediately by `MacSender` itself and
            // never reaches here.
            guard requested, let self, let session, self.owns(session) else { return }
            self.handleInputControlRequested(session: session)
        }
        sender.onSessionInputGrantChanged = { [weak session] granted in
            session?.sessionInputGranted = granted
        }
        sender.onVideoEnabledRequest = { [weak self, weak session] requested in
            guard let self, let session, self.owns(session) else { return }
            self.requestVideoEnabled(requested)
        }
        sender.onStreamingProfileRequest = { [weak self, weak session] profile, custom in
            guard let self, let session, self.owns(session) else { return }
            self.streamingProfile = profile
            self.customFrameRate = custom
            self.restartAll()
        }
        sender.onStreamingPriorityRequest = { [weak self, weak session] priority in
            guard let self, let session, self.owns(session) else { return }
            self.streamingPriority = priority
            self.restartAll()
        }
        sender.onMirrorDisplayRequest = { [weak self, weak session] requestedUUID in
            guard let self, let session, self.owns(session) else { return }
            // Same authoritative setter the Mac's own MirrorDisplayPickerView
            // writes — its didSet persists the choice and restarts capture
            // when Mirror is active, so both surfaces stay one source of truth.
            self.mirrorDisplayUUID = requestedUUID
        }
        sender.onExtendShapeChanged = { [weak session] preference in
            session?.extendShapePreference = preference
        }
        sender.onMaxFPSChanged = { [weak session] preference in
            session?.maxFPSPreference = preference
        }
        sender.onHello = { [weak self, weak session] info in
            guard let self, let session, self.owns(session) else { return }
            session.deviceID = info.id
            session.deviceKind = info.device
            // The MEOW application handshake just completed on this live
            // connection — this, not Bonjour or a merely-open socket, is
            // what makes the device an Active Display.
            session.applicationAuthenticated = true
            Log.info("deviceUI: activeSession added peerID=\(info.id ?? "unknown") route=\(session.route?.rawValue ?? "pending")")
            session.receiverProtocolVersion = info.protocolVersion
            session.receiverMaxFPS = info.maxFPS
            if let value = info.trayEnabled { session.receiverTrayEnabled = value }
            if let value = info.keyboardButtonEnabled {
                session.receiverKeyboardButtonEnabled = value
            }
            // Per-device receiver-controls report (protocol 6+) — see
            // `PhoneInfo`. All additive/optional: an older receiver simply
            // never sends these and the device detail's defaults stand in.
            if let value = info.functionTrayEnabled { session.receiverFunctionTrayEnabled = value }
            if let value = info.inputMode { session.receiverInputMode = value }
            if let value = info.trackpadSensitivity { session.receiverTrackpadSensitivity = value }
            if let value = info.hapticsEnabled { session.receiverHapticsEnabled = value }
            if let value = info.avoidNotch { session.receiverAvoidNotch = value }
            if let value = info.pinchTarget { session.receiverPinchTarget = value }
            if let value = info.rotateTarget { session.receiverRotateTarget = value }
            if let value = info.snapRotation { session.receiverSnapRotation = value }
            if let value = info.appGestureCommands { session.receiverAppGestureCommands = value }
            if let value = info.avSyncOffsetMs { session.receiverAVSyncOffsetMs = value }
            if info.functionTrayEnabled != nil || info.inputMode != nil {
                session.receiverPreferencesReported = true
            }
            if let installID = info.id {
                self.autoConnectPolicy.remember(["install:\(installID)"])
                self.persistKnownIdentifiers()
            }
            if case .usb(let udid?) = session.target, let installID = info.id {
                self.installIDByUDID[udid] = installID
            }
            // USB discovery and dialing are automatic; trust is not. A peer that
            // is already pinned just connects (pinned TLS decides; a changed
            // key fails there). Only an unpinned peer runs the normal SAS
            // ceremony, and it can never replace an existing pin.
            if session.onUSB,
               let udid = session.usbUDID, let peerID = info.id,
               info.protocolVersion >= WireProtocol.securePairingWireVersion,
               USBPairingPolicy.shouldBeginPairing(
                   hasPin: TrustStore.shared.hasPin(peerID: peerID),
                   alreadyAttemptedThisSession: session.usbPairingAttempted) {
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
                            allowIdentityChange: USBPairingPolicy.allowIdentityChange)
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
        sender.onMediaState = { [weak session] videoActive, audioActive, width, height, fps in
            guard let session else { return }
            session.videoActive = videoActive
            session.audioActive = audioActive
            session.videoWidth = width
            session.videoHeight = height
            session.videoFPS = fps
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
            guard self.autoReconnectEnabled else {
                Log.info("reconnectPolicy: automaticAttempt suppressed reason=disabled peer=\(session.logicalID)")
                return
            }
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
            Log.info("connectDebug: peerExplicitDisconnect peer=\(session.logicalID)")
            self.autoConnectPolicy.suppress(self.identifiers(for: session))
            Log.info("connectDebug: autoConnectSuppressed peer=\(session.logicalID)")
            self.end(session)
        }
        sender.onTrustFailure = { [weak self, weak session] message in
            guard let self, let session, self.owns(session) else { return }
            session.failed = true
            session.status = message
            session.sender.stop()
        }
        sessions.append(session)
        sessionObservations[ObjectIdentifier(session)] = session.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
        Task {
            do {
                try await sender.start()
            } catch is CancellationError {
                // stopped by the user while waiting — nothing to report
            } catch {
                guard self.owns(session) else { return }
                Log.info("sender failed to start: \(error)")
                session.status = "Failed: \(error.localizedDescription)"
                let nsError = error as NSError
                if nsError.domain == "MacSender",
                   nsError.code == MacSender.mirrorUnavailableTimeoutErrorCode {
                    // The receiver never answered the headless-Mirror "Use
                    // Extend?" offer within its bounded window. Without this,
                    // the very next auto-connect scan would see no owning
                    // session for this peer and immediately dial it again —
                    // offer, timeout, retry, forever. Reuses the exact same
                    // suppression `onPeerClosed` already applies for a
                    // deliberate receiver-side goodbye; an explicit Connect
                    // still clears it (`allowExplicitConnection`), same as
                    // any other suppression.
                    self.autoConnectPolicy.suppress(self.identifiers(for: session))
                }
                // Free the half-built pipeline: a leaked virtual display
                // would keep holding this device's serial, and a parked
                // live-looking session would swallow every future connect.
                session.failed = true
                sender.stop()
            }
        }
        return true
    }

    /// User-initiated disconnect: also opt the device out of auto-connect.
    func disconnect(_ session: DeviceSession) {
        Log.info("connectDebug: explicitDisconnect peer=\(session.logicalID)")
        autoConnectPolicy.suppress(identifiers(for: session))
        Log.info("connectDebug: reconnectSuppressed peer=\(session.logicalID)")
        session.sender.disconnect { [weak self, weak session] in
            guard let self, let session else { return }
            self.end(session)
        }
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
        // Input-consent milestone: a true session end (this is the single
        // choke point every teardown path — disconnect, sleeping's
        // replacement session, Forget, restartAll — already goes through)
        // must never leave a stale prompt or request lifecycle behind for a
        // session that no longer exists. The session's own ephemeral input
        // grant needs no explicit clearing here: it lives in `MacSender.
        // sessionInputGrant`, which is deallocated with this `MacSender`
        // instance — a brand-new logical session always gets a fresh one.
        inputControlPrompt.cancelForEndedSession(id: session.id)
        session.inputControlRequest.reset()
        session.sender.stop()
        if session.applicationAuthenticated {
            Log.info("deviceUI: activeSession removed peerID=\(session.deviceID ?? "unknown") sessionID=\(session.id)")
        }
        sessionObservations.removeValue(forKey: ObjectIdentifier(session))
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

    // MARK: - Active Display (runtime) / Known Devices (persistent trust)
    //
    // Two independent sources of truth, never conflated: Active Display
    // comes only from `sessions` that completed the application handshake
    // (`applicationAuthenticated`), and Known Devices comes only from
    // TrustStore. A peer can be known-but-offline, known-and-active, or
    // (transiently, before the first pairing) neither.

    // The one canonical observable runtime projection for a live session —
    // Overview, Devices → Active Display, the toolbar/menu-bar status, and
    // the ReceiverPanel-equivalent status on the sender side all read this
    // (via `activeDisplayEntries`/`canonicalStatus` below) instead of each
    // re-deriving "connected" from sessions/applicationAuthenticated on
    // their own.
    struct ActiveDisplayEntry: Identifiable {
        let id: String
        let peerID: String?
        let name: String
        let statusText: String
        let route: ConnectionRoute?
        let mode: CaptureMode
        let videoActive: Bool
        let audioActive: Bool
        let allowInput: Bool
        let videoWidth: Int
        let videoHeight: Int
        let videoFPS: Int
        let bitrateBps: Int
        // The two existing capture-lifecycle signals a session already
        // tracks (see `DeviceSession.capturePhase`/`.failed`), carried
        // through so every status surface can derive the same
        // `CanonicalConnectionPhase` instead of guessing from `statusText`.
        let capturePhase: CaptureLifecyclePhase
        let failed: Bool

        var phase: CanonicalConnectionPhase {
            CanonicalRuntimeStatus.phase(capturePhase: capturePhase, failed: failed)
        }
    }

    var activeDisplayEntries: [ActiveDisplayEntry] {
        sessions
            .filter(\.applicationAuthenticated)
            .map { session in
                ActiveDisplayEntry(id: session.id, peerID: session.deviceID, name: session.name,
                                   statusText: session.statusWithRoute, route: session.route,
                                   mode: mode, videoActive: session.videoActive,
                                   audioActive: session.audioActive,
                                   allowInput: EffectiveInputAuthorization.allowed(
                                       masterEnabled: allowInput, sessionGranted: session.sender.hasSessionInputGrant),
                                   videoWidth: session.videoWidth, videoHeight: session.videoHeight,
                                   videoFPS: session.videoFPS,
                                   bitrateBps: quality.bitrate, capturePhase: session.capturePhase,
                                   failed: session.failed)
            }
    }

    /// The single global status string every status-bearing surface (main
    /// window toolbar, menu bar icon/label) must read — gated on the same
    /// application-authenticated source as Active Display, never on
    /// `sessions.isEmpty` alone (a dialing/pre-hello session is not yet a
    /// connected device), AND phase-aware, so a session that's actually
    /// paused/reconnecting/lost is never reported as plain "connected" —
    /// the canonical fix for the toolbar staying on "1 device connected"
    /// through a reconnect.
    var canonicalStatusText: String {
        CanonicalRuntimeStatus.aggregateStatusText(
            entries: activeDisplayEntries.map { (mode: $0.mode, route: $0.route, phase: $0.phase) })
    }

    var canonicalPhase: CanonicalConnectionPhase {
        CanonicalRuntimeStatus.aggregatePhase(entryPhases: activeDisplayEntries.map(\.phase))
    }

    var hasActiveDisplay: Bool { !activeDisplayEntries.isEmpty }

    struct KnownDeviceEntry: Identifiable {
        let id: String   // peerID
        let name: String
        let activeSessionID: String?
        let resolvedTarget: ConnectionTarget?
        let inputPolicy: PeerInputRequestPolicy
    }

    var knownDeviceEntries: [KnownDeviceEntry] {
        TrustStore.shared.pinnedPeers().map { peer in
            let active = sessions.first { $0.deviceID == peer.peerID && $0.applicationAuthenticated }
            return KnownDeviceEntry(
                id: peer.peerID, name: peer.displayName, activeSessionID: active?.id,
                resolvedTarget: active == nil ? resolvedTarget(forPeerID: peer.peerID) : nil,
                inputPolicy: ReceiverInputAuthorizationStore.policy(peerID: peer.peerID))
        }
    }

    /// `peerID`'s persisted policy for how the Mac responds to a future
    /// control request — never a live grant (see `PeerInputRequestPolicy`).
    func inputPolicy(peerID: String) -> PeerInputRequestPolicy {
        ReceiverInputAuthorizationStore.policy(peerID: peerID)
    }

    /// True while ANY connected session currently has effective input — the
    /// self-authorization guard's condition (see `ReceiverInputAuthorizationStore`'s
    /// doc comment): a remote peer with live screen control could otherwise
    /// click any device's row in Settings to widen its own or another
    /// peer's permanent policy.
    var anySessionHasEffectiveInput: Bool {
        sessions.contains { EffectiveInputAuthorization.allowed(masterEnabled: allowInput, sessionGranted: $0.sender.hasSessionInputGrant) }
    }

    /// Whether `policy` can be set for `peerID` right now. Narrowing
    /// (`.ask`/`.neverAllow`) is always editable; widening to `.alwaysAllow`
    /// is not while `anySessionHasEffectiveInput` — see
    /// `ReceiverInputAuthorizationStore.setPolicy`'s enforcement, which this
    /// mirrors for the UI's `.disabled` state.
    func canSetInputPolicy(_ policy: PeerInputRequestPolicy, peerID: String) -> Bool {
        policy != .alwaysAllow || !anySessionHasEffectiveInput
    }

    /// Returns whether the change actually took effect — see
    /// `ReceiverInputAuthorizationStore.setPolicy`.
    @discardableResult
    func setInputPolicy(_ policy: PeerInputRequestPolicy, peerID: String) -> Bool {
        let applied = ReceiverInputAuthorizationStore.setPolicy(
            policy, peerID: peerID, anySessionHasEffectiveInput: anySessionHasEffectiveInput)
        if applied { objectWillChange.send() }
        return applied
    }

    /// Mac owner manually revokes an active session's control grant from
    /// Settings/device detail. Immediate: no confirmation, since narrowing
    /// is always safe.
    func revokeSessionInput(peerID: String) {
        guard let session = sessions.first(where: { $0.deviceID == peerID && $0.applicationAuthenticated }) else { return }
        session.sender.revokeSessionInput()
    }

    // MARK: - Input control-request consent flow

    /// A receiver requested control of `session`. Every new logical session
    /// starts input OFF regardless of trust/pairing (the milestone's core
    /// invariant) — this is the ONLY path that can turn it on, and it never
    /// widens anything beyond `session` itself.
    func handleInputControlRequested(session: DeviceSession) {
        guard let peerID = session.deviceID else { return }
        guard allowInput else {
            // Mac-wide master is off — the owner already said no globally;
            // never surface a prompt for a request that can't succeed.
            session.sender.denySessionInput(state: .notAllowed)
            return
        }
        switch ReceiverInputAuthorizationStore.policy(peerID: peerID) {
        case .neverAllow:
            session.sender.denySessionInput(state: .requestsDisabled)
        case .alwaysAllow:
            session.sender.grantSessionInput()
        case .ask:
            presentInputControlPrompt(session: session, peerID: peerID)
        }
    }

    private func presentInputControlPrompt(session: DeviceSession, peerID: String) {
        guard let generation = session.inputControlRequest.beginRequest() else {
            // Duplicate while pending (coalesced into the existing prompt)
            // or within the post-decision cooldown — no new prompt, no
            // reply needed: the receiver is already showing "Requesting…"
            // for the pending one, or should be in its own local cooldown.
            return
        }
        session.sender.notifyInputRequestPending()
        let request = PendingInputControlRequest(id: session.id, peerID: peerID, name: session.name, generation: generation)
        Task { [weak self, weak session] in
            let decision = await self?.inputControlPrompt.request(request) ?? .notNow
            guard let self, let session else { return }
            self.resolveInputControlRequest(session: session, peerID: peerID, generation: generation, decision: decision)
        }
    }

    private func resolveInputControlRequest(session: DeviceSession, peerID: String, generation: Int,
                                             decision: InputControlRequestDecision) {
        guard session.inputControlRequest.resolve(generation: generation, decision: decision) else {
            // Stale: this generation was already superseded (session ended
            // and a replacement began, or a duplicate resolution raced in).
            return
        }
        // `InputControlRequestPlan` fixes a real ordering bug: persisting
        // BEFORE granting means `.alwaysAllowDevice`'s widening is judged
        // by whatever OTHER sessions currently have effective input, never
        // by the grant this very decision is about to create — see the
        // plan type's doc comment. Applying `grantSession`/`denyState`
        // before computing the plan (or before persisting) would silently
        // reintroduce that bug.
        let plan = InputControlRequestPlan.plan(for: decision)
        if let policy = plan.persistPolicy {
            let persisted = setInputPolicy(policy, peerID: peerID)
            if policy == .alwaysAllow, !persisted {
                // SECURITY CRITICAL: refused because some OTHER session
                // currently has effective input — never silently pretend
                // this succeeded. Fails closed to the existing `.ask`
                // policy; the session grant below still proceeds, since
                // that reflects the owner's explicit local decision at the
                // Mac just now, not anything the remote peer did.
                Log.info("inputConsent: refused to persist Always Allow for peer \(peerID) — another session already has effective input")
            }
        }
        if plan.grantSession {
            session.sender.grantSessionInput()
        } else if let denyState = plan.denyState {
            session.sender.denySessionInput(state: denyState)
        }
    }


    /// A currently reachable (but not yet connected) target for a known
    /// peer, so its row can offer Connect without waiting for it to also
    /// appear as a Nearby row.
    private func resolvedTarget(forPeerID peerID: String) -> ConnectionTarget? {
        if let udid = installIDByUDID.first(where: { $0.value == peerID })?.key {
            return .usb(udid: udid)
        }
        if let result = discovered.first(where: { txtID(of: $0) == peerID }) {
            return .wifi(result)
        }
        return nil
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


    #if DEBUG
    // MARK: - Debug diagnostics
    struct PeerDiagnostic: Identifiable {
        let id: String
        let name: String
        let trusted: Bool
        let normalDiscovered: Bool
        let pairingDiscovered: Bool
        let connected: Bool
        let route: String
        let sessionGeneration: String
        let normalEndpoint: String
        let pairingEndpoint: String
    }

    /// Per-peer diagnostic snapshot merging all independent sources of truth
    /// (pinned trust, normal/pairing Bonjour discovery, live sessions) by
    /// stable peer ID, for Developer / Diagnostics. Never used to derive UI
    /// state elsewhere — this is read-only introspection.
    var peerDiagnostics: [PeerDiagnostic] {
        let pinned = TrustStore.shared.pinnedPeers()
        var peerIDs = Set(pinned.map(\.peerID))
        for r in discovered { if let id = txtID(of: r) { peerIDs.insert(id) } }
        for r in receiverPairingResults { if let id = txtID(of: r) { peerIDs.insert(id) } }
        for s in sessions { if let id = s.deviceID { peerIDs.insert(id) } }
        return peerIDs.sorted().map { peerID in
            let pinnedName = pinned.first { $0.peerID == peerID }?.displayName
            let normalResult = discovered.first { txtID(of: $0) == peerID }
            let pairingResult = receiverPairingResults.first { txtID(of: $0) == peerID }
            let session = sessions.first { $0.deviceID == peerID }
            return PeerDiagnostic(
                id: peerID,
                name: pinnedName ?? session?.name ?? normalResult.flatMap(serviceName) ?? peerID,
                trusted: TrustStore.shared.hasPin(peerID: peerID),
                normalDiscovered: normalResult != nil,
                pairingDiscovered: pairingResult != nil,
                connected: session != nil,
                route: session?.route?.rawValue ?? "-",
                sessionGeneration: session.map { "\($0.attempt.generation)" } ?? "-",
                normalEndpoint: normalResult.map { "\($0.endpoint)" } ?? "-",
                pairingEndpoint: pairingResult.map { "\($0.endpoint)" } ?? "-")
        }
    }
    #endif
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
