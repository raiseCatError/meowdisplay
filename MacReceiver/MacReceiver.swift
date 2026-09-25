// The receiver (issues #82/#17): this Mac listens exactly like the iPhone
// does — Bonjour-advertised TCP listener, hello with its own panel size — and
// renders the incoming stream, so a spare Mac becomes a display for another
// Mac. The pipeline is the shared StreamReceiver core; this file is only the
// AppKit shell around it: lifecycle, the video window, cursor drawing, and
// keeping the machine awake while it serves as a screen. It ships as its own
// app (OpenSidecarMacReceiver target, macOS 12+) so old Macs can be displays.
//
// Display-only for now: the receiving Mac's keyboard/trackpad are not
// forwarded to the sender (KVM-style input is a follow-up).

import AppKit
import AVFoundation
import Combine
import IOKit.pwr_mgt
import SwiftUI

@MainActor
final class ReceiverController: ObservableObject {
    static let shared = ReceiverController()

    // A fresh StreamReceiver per activation: stop() tears the old one down
    // and drops it, so listener/decoder state can't leak across mode flips.
    // Nil whenever receiver mode is off.
    @Published private(set) var receiver: StreamReceiver?
    // Summaries for views that don't observe the receiver itself (menu bar
    // icon, status bar): a sender is connected / frames are on screen.
    @Published private(set) var connected = false
    @Published private(set) var streaming = false
    // The one canonical status presentation — republished from the
    // receiver's `session` (phase/interruption), the same state iOS's
    // interruption overlay already reads. Every status-bearing surface in
    // this app (the toolbar status badge and the Overview status row)
    // reads this pair instead of each independently re-deriving "Connected"/
    // "Waiting for a Mac…" from `connected`, which could otherwise drift.
    @Published private(set) var statusTitle = "Waiting for a Mac…"
    @Published private(set) var statusColor: Color = .secondary
    // The sender has no usable physical display for Mirror (pv 17). Mirrors
    // `receiver.mirrorUnavailable` so Settings can present the Cancel /
    // Use Extend alert; the sender stays authoritative for the actual mode.
    @Published private(set) var mirrorUnavailableOffer = false
    /// Wake & Connect for a paired Mac (the same shared coordinator the
    /// iPhone app drives). Lives exactly as long as `receiver`.
    @Published private(set) var wakeConnect: WakeConnectCoordinator?
    /// The receiver-local manual A/V Sync offset (`AVSyncOffset.range`),
    /// persisted here and applied to the shared receiver's
    /// `avSyncPreference` — the one value its audio scheduling and video
    /// delay read. Never sent to the other Mac.
    @Published private(set) var avSyncOffsetMs = AVSyncOffset.clamped(
        UserDefaults.standard.integer(forKey: ReceiverController.avSyncOffsetKey))
    /// Fired when something needs the user's answer while the Settings
    /// window may be closed (the headless-Mirror offer) — the app delegate
    /// brings it up.
    var onNeedsAttention: (() -> Void)?

    var active: Bool { receiver != nil }

    private var window: NSWindow?
    private var retiringReceiver: StreamReceiver?
    private var cancellables = Set<AnyCancellable>()
    private var sleepActivity: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var screenSleepObservers: [NSObjectProtocol] = []
    private var windowLifecycle = ReceiverWindowLifecycle()
    private var windowObservers: [NSObjectProtocol] = []

    private var fallbackName: String { Host.current().localizedName ?? "Mac" }

    func start() {
        guard receiver == nil else { return }
        // 4096x2304 is H.264's practical hardware-decode ceiling: end-to-end
        // playback stops below 5120 wide on every Mac measured, including an
        // M4 Pro — a format limit, not an age one. A 5K/6K panel still gets
        // its full desktop; the stream is capped and upscaled. Revisit when
        // an HEVC path lands (HEVC decodes 5K fine even on a 2017 iMac).
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                      deviceKind: "Mac",
                                      fallbackServiceName: fallbackName,
                                      maxEncodeWide: 4096, maxEncodeHigh: 2304,
                                      maxFPS: NSScreen.screens.first?.maximumFramesPerSecond)
        let saved = UserDefaults.standard.string(forKey: "receiverName")
        receiver.serviceName = (saved?.isEmpty == false) ? saved! : fallbackName
        announcePanel(to: receiver)
        // Audio stays a per-receiver opt-in; the shared receiver resends it on
        // every welcome, so reconnects and migrations restore it.
        receiver.primeAudioPreference(UserDefaults.standard.bool(forKey: Self.audioPreferredKey))
        receiver.avSyncPreference.set(avSyncOffsetMs)
        self.receiver = receiver
        wakeConnect = WakeConnectCoordinator(receiver: receiver)
        receiver.start()

        receiver.$connected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                self?.connected = connected
            }
            .store(in: &cancellables)
        receiver.$session
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.statusTitle = receiver.canonicalPhaseTitle
                self?.statusColor = Self.statusColor(for: session.phase)
            }
            .store(in: &cancellables)
        receiver.$mirrorUnavailable
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] offered in
                self?.mirrorUnavailableOffer = offered
                if offered { self?.onNeedsAttention?() }
            }
            .store(in: &cancellables)
        // A sender asking to pair (or this Mac pairing with a nearby one)
        // needs the code confirmed here before any trust is written.
        receiver.pairingPrompt.$pending
            .map { $0 != nil }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak receiver] pending in
                guard pending, let prompt = receiver?.pairingPrompt else { return }
                ReceiverPairingPanel.present(prompt: prompt)
            }
            .store(in: &cancellables)
        // Streaming = connected and the video format is known — that's when
        // the window has something to show (and when to take it down again).
        receiver.$connected.combineLatest(receiver.$videoSize)
            .map { $0 && $1 != .zero }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] streaming in
                self?.streaming = streaming
                self?.updateSleepAssertion(streaming)
                if streaming { self?.showWindow() } else { self?.scheduleCloseWindow() }
            }
            .store(in: &cancellables)

        // The receiving Mac's own panel went dark (idle sleep, lid) — nobody
        // can see the stream, so tell the sender exactly like a locked
        // iPhone does; it drops its display and arms a reconnect. On wake
        // the listener comes back and the sender redials.
        let workspace = NSWorkspace.shared.notificationCenter
        screenSleepObservers = [
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                  object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    Log.info("screens slept — announcing sleeping to the sender")
                    self?.receiver?.enterSleep()
                }
            },
            workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                  object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.receiver?.ensureListening() }
            },
        ]

        // Display-mode changes move the goalposts mid-session (the announced
        // panel is the sender's virtual-display size) — re-announce, the
        // sender rebuilds. The Mac analogue of iPhone rotation.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let receiver = self.receiver else { return }
                self.announcePanel(to: receiver)
            }
        }
        Log.info("receiver mode started (advertising \"\(receiver.serviceName)\")")
    }

    /// Leave receiver mode. `completion` fires once "closing" has gone out
    /// to a live sender (or a second has passed) — the quit path waits on it
    /// so the sender ends its session instead of retrying a dead peer.
    func stop(completion: (@Sendable () -> Void)? = nil) {
        guard let receiver else { completion?(); return }
        cancellables.removeAll()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        let workspace = NSWorkspace.shared.notificationCenter
        screenSleepObservers.forEach { workspace.removeObserver($0) }
        screenSleepObservers = []
        wakeConnect?.cancel()
        wakeConnect = nil
        // The receiver finishes its teardown on its own queue and only calls
        // back while it still exists, so keep it alive until it has — views
        // observing it are released as soon as `receiver` goes nil below.
        retiringReceiver = receiver
        receiver.stop { [weak self] in
            Task { @MainActor in self?.retiringReceiver = nil }
            completion?()
        }
        self.receiver = nil
        connected = false
        streaming = false
        statusTitle = "Waiting for a Mac…"
        statusColor = .secondary
        mirrorUnavailableOffer = false
        closeWindow()
        updateSleepAssertion(false)
        Log.info("receiver mode stopped")
    }

    static let audioPreferredKey = "audioPreferred"

    func setAudioPreferred(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.audioPreferredKey)
        receiver?.requestAudioEnabled(enabled)
    }

    static let avSyncOffsetKey = "avSyncOffsetMs"

    /// Snaps to `AVSyncOffset.stepMs` and clamps, exactly like the iPhone
    /// app's A/V Sync slider, then applies it to the live receiver.
    func setAVSyncOffset(_ milliseconds: Int) {
        let step = AVSyncOffset.stepMs
        let snapped = AVSyncOffset.clamped(Int((Double(milliseconds) / Double(step)).rounded()) * step)
        guard snapped != avSyncOffsetMs else { return }
        avSyncOffsetMs = snapped
        UserDefaults.standard.set(snapped, forKey: Self.avSyncOffsetKey)
        receiver?.avSyncPreference.set(snapped)
    }

    /// "Use Extend" on the Mirror-unavailable alert — the shared receiver
    /// sends the existing `displayModeRequest`; nothing is faked locally.
    func acceptMirrorUnavailableOffer() { receiver?.acceptMirrorUnavailableOffer() }

    /// "Cancel" — ends this attempt exactly like Disconnect (trust stays).
    func declineMirrorUnavailableOffer() { receiver?.declineMirrorUnavailableOffer() }

    /// Re-published name from the System page's name field. Empty falls back to the
    /// computer name (mirrors the iOS Settings behavior).
    func setAdvertisedName(_ name: String) {
        UserDefaults.standard.set(name, forKey: "receiverName")
        receiver?.setServiceName(name)
    }

    /// The panel this Mac offers as a display: the primary screen's current
    /// framebuffer. A Retina panel announces its @2x pixels, which maps 1:1
    /// onto the sender's @2x HiDPI virtual display.
    ///
    /// Minus the menu-bar/notch strip: native full screen never covers it on
    /// notched panels (the fullscreen window is the screen shrunk by
    /// safeAreaInsets.top — zero on notch-less displays). Announcing the
    /// full panel would letterbox full screen on every side AND render the
    /// remote menu bar physically behind the notch; announcing the safe
    /// rect makes full screen exactly 1:1.
    ///
    /// Non-Retina panels (scale 1, the legacy-Mac case): the sender always
    /// builds an @2x HiDPI display of half the announced pixels, so
    /// announcing the raw framebuffer would give a display with half the
    /// points and comically large UI. Announce the panel's *point* size at
    /// 2x instead: the sender's display then has the same point geometry as
    /// the panel and the receiver scales the stream down 2:1 on the way in.
    /// Costs encode bandwidth (the quality presets scale capture down
    /// anyway), buys a correct-looking desktop.
    private func announcePanel(to receiver: StreamReceiver) {
        guard let screen = NSScreen.screens.first else { return }
        let scale = max(screen.backingScaleFactor, 2)
        let height = screen.frame.height - screen.safeAreaInsets.top
        if screen.backingScaleFactor < 2 {
            Log.info("non-Retina panel (\(screen.backingScaleFactor)x) — announcing points at 2x")
        }
        receiver.setPanel(pixelsWide: Int(screen.frame.width * scale),
                          pixelsHigh: Int(height * scale),
                          scale: Double(scale))
    }

    // MARK: - Video window

    /// Bring the video window (back) up — also bound to Show Window in Settings for
    /// when the user closed the window while the stream keeps running.
    func showWindow() {
        guard let receiver, streaming || window != nil else { return }
        // Streaming again within the grace period keeps this window, in
        // whatever full screen state it's already in.
        if streaming { windowLifecycle.cancelPendingClose() }
        var enterFullscreen = false
        if window == nil {
            let w = NSWindow(contentRect: initialContentRect(video: receiver.videoSize),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "MeowDisplay"
            w.contentView = ReceiverVideoView(receiver: receiver)
            w.isReleasedWhenClosed = false
            w.collectionBehavior.insert(.fullScreenPrimary)
            w.center()
            window = w
            observeWindow(w)
            enterFullscreen = windowLifecycle.windowCreated()
        }
        // Resizes keep the stream's shape; re-set on every show because a
        // reconnect can arrive with new dimensions in the same window.
        if receiver.videoSize != .zero { window?.contentAspectRatio = receiver.videoSize }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Only a freshly built window takes the preference, so a reused
        // window is never toggled mid-transition.
        if enterFullscreen { window?.toggleFullScreen(nil) }
    }

    /// Streaming stopped: take the window down after a short grace, in case
    /// the sender is only moving the session to another transport.
    private func scheduleCloseWindow() {
        guard window != nil else { return }
        let token = windowLifecycle.scheduleClose()
        DispatchQueue.main.asyncAfter(deadline: .now() + ReceiverWindowLifecycle.closeGrace) { [weak self] in
            guard let self, self.windowLifecycle.consumeClose(token) else { return }
            self.closeWindow()
        }
    }

    private func closeWindow() {
        // Our own teardown is not the user's choice: stop recording before
        // closing a full screen window reports its exit.
        windowLifecycle.windowClosing()
        stopObservingWindow()
        window?.close()
        window = nil
    }

    /// Records the user's green-button choice, and forgets the window when
    /// the user closes it; Show Window (or the next stream) then builds a
    /// fresh one with the preference.
    private func observeWindow(_ window: NSWindow) {
        let center = NotificationCenter.default
        // Synchronous on .main: a close must stop recording before the full
        // screen exit it causes is delivered.
        func observe(_ name: Notification.Name,
                     _ apply: @escaping @MainActor (ReceiverController) -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { apply(self) } }
            }
        }
        windowObservers = [
            observe(NSWindow.didEnterFullScreenNotification) { $0.windowLifecycle.fullscreenChanged(entered: true) },
            observe(NSWindow.didExitFullScreenNotification) { $0.windowLifecycle.fullscreenChanged(entered: false) },
            observe(NSWindow.willCloseNotification) {
                $0.windowLifecycle.windowClosing()
                $0.stopObservingWindow()
                $0.window = nil
            },
        ]
    }

    private func stopObservingWindow() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
    }

    /// Windowed at ~70% of the screen; full screen returns here when the
    /// user leaves it.
    private func initialContentRect(video: CGSize) -> NSRect {
        let visible = NSScreen.screens.first?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
        let size = video == .zero ? CGSize(width: 960, height: 600) : video
        let scale = min(0.7 * visible.width / size.width,
                        0.7 * visible.height / size.height, 1)
        return NSRect(x: 0, y: 0,
                      width: size.width * scale, height: size.height * scale)
    }

    // MARK: - Stay awake

    /// This Mac *is* the display while a sender streams — never let it doze,
    /// and wake it up when the stream starts. beginActivity only prevents
    /// *future* idle sleep; a spare Mac with no keyboard has usually gone
    /// dark by the time a sender connects, and frames into a black panel
    /// looked like nothing worked at all. Declaring user activity is what
    /// actually lights the display again.
    private static func statusColor(for phase: ReceiverSessionPhase) -> Color {
        switch phase {
        case .connected: return .green
        case .reconnectFailed, .unrecoverable: return .red
        case .connecting, .reconnecting, .paused: return .orange
        case .disconnected, .peerDisconnected: return .secondary
        }
    }

    private func updateSleepAssertion(_ receiving: Bool) {
        if receiving, sleepActivity == nil {
            var assertionID = IOPMAssertionID(0)
            IOPMAssertionDeclareUserActivity(
                "MeowDisplay stream started" as CFString,
                kIOPMUserActiveLocal, &assertionID)
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "MeowDisplay is receiving a display stream")
        } else if !receiving, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }
}

// MARK: - Video view (AppKit sibling of the iOS VideoLayerView)

/// NSView hosting the AVSampleBufferDisplayLayer plus the local cursor-echo
/// layer. The sender hides the real cursor from capture and streams its
/// position/sprite on the control channel — without drawing it here the
/// extended desktop would have no visible pointer.
final class ReceiverVideoView: NSView {
    private weak var receiver: StreamReceiver?
    private let displayLayer: AVSampleBufferDisplayLayer
    private var videoSizeObserver: AnyCancellable?

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

    init(receiver: StreamReceiver) {
        self.receiver = receiver
        self.displayLayer = receiver.displayLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        // AVSBDL aspect-fits internally (videoGravity) — give it full bounds.
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
        layer?.addSublayer(cursorLayer)

        receiver.onCursor = { [weak self] x, y, visible in
            self?.moveCursor(x: x, y: y, visible: visible)
        }
        receiver.onCursorImage = { [weak self] image, anchor, normSize in
            self?.setCursorSprite(image, anchor: anchor, normSize: normSize)
        }
        // Replay the sprite/position that arrived before this view existed —
        // the sender re-sends them only on change, so without this the
        // cursor stays invisible until it happens to change shape.
        if let sprite = receiver.cursorSprite {
            setCursorSprite(sprite.image, anchor: sprite.anchor, normSize: sprite.normSize)
        }
        let state = receiver.cursorState
        moveCursor(x: state.x, y: state.y, visible: state.visible)
        // videoSize arrives after the format description — re-fit the layers.
        videoSizeObserver = receiver.$videoSize
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.needsLayout = true }

        // The shared perf HUD (same as iOS), toggled by "showAnalytics".
        // Sized with autoresizing, not Auto Layout: an NSHostingView reports
        // its SwiftUI content's intrinsic size, and pinned edge-to-edge with
        // required constraints that size drove the *window*, which collapsed
        // to 0 × titlebar with the HUD hidden. Springs and struts never feed
        // back into the window, on any macOS the app supports.
        let overlay = OverlayHostingView(rootView: ReceiverPerfOverlay(receiver: receiver))
        overlay.frame = bounds
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: blankCursor)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        updateCursorLayout()
        CATransaction.commit()
    }

    /// Aspect-fit rect of the video inside the view (same math as iOS).
    private func videoRect() -> CGRect? {
        guard let video = receiver?.videoSize, video != .zero,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(bounds.width / video.width, bounds.height / video.height)
        let size = CGSize(width: video.width * scale, height: video.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2,
                      y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private func moveCursor(x: Double, y: Double, visible: Bool) {
        cursorNorm = CGPoint(x: x, y: y)
        cursorVisible = visible
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = !visible || cursorLayer.contents == nil
        updateCursorLayout()
        CATransaction.commit()
    }

    private func setCursorSprite(_ image: CGImage, anchor: CGPoint, normSize: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.contents = image
        // The wire anchor is the hotspot from the image's TOP-left; AppKit
        // layer unit coords run bottom-up — flip y once here.
        cursorLayer.anchorPoint = CGPoint(x: anchor.x, y: 1 - anchor.y)
        cursorNormSize = normSize
        cursorLayer.isHidden = !cursorVisible
        updateCursorLayout()
        CATransaction.commit()
    }

    private func updateCursorLayout() {
        guard let rect = videoRect(), cursorNormSize != .zero else { return }
        cursorLayer.bounds = CGRect(x: 0, y: 0,
                                    width: cursorNormSize.width * rect.width,
                                    height: cursorNormSize.height * rect.height)
        // Video-space y grows downward, view coords grow upward — flip.
        cursorLayer.position = CGPoint(x: rect.minX + cursorNorm.x * rect.width,
                                       y: rect.maxY - cursorNorm.y * rect.height)
    }
}

// MARK: - Performance overlay host

// This Mac's own pointer over the video reads as a second, dead cursor on
// what acts as a monitor — blank it there. The streamed sender cursor
// (cursorLayer) is the pointer that matters. File-scope so both the video
// view and the overlay above it use the same cursor.
@MainActor private let blankCursor: NSCursor = {
    let size = NSSize(width: 1, height: 1)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.clear.set()
    NSRect(origin: .zero, size: size).fill()
    image.unlockFocus()
    return NSCursor(image: image, hotSpot: .zero)
}()

/// The shared PerfOverlay pinned to the bottom of the video, driven by the
/// same "showAnalytics" default the iOS app uses (Settings → System).
struct ReceiverPerfOverlay: View {
    @ObservedObject var receiver: StreamReceiver
    @AppStorage("showAnalytics") private var showAnalytics = false

    var body: some View {
        if showAnalytics {
            VStack {
                Spacer()
                PerfOverlay(stats: receiver.perf, videoSize: receiver.videoSize)
                    .padding(.bottom, 10)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Full-bleed, non-interactive layer above the video. Subclassed only so the
/// blank-cursor rect covers the HUD area too.
private final class OverlayHostingView: NSHostingView<ReceiverPerfOverlay> {
    required init(rootView: ReceiverPerfOverlay) {
        super.init(rootView: rootView)
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: blankCursor)
    }
}
