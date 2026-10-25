import AppKit
import Combine
import SwiftUI

/// The AppKit side of Mac-to-Mac input (issue #12): owns one session's
/// `ReceiverInputForwarder`, turns the video window's events into its calls,
/// and sends what it returns through `StreamReceiver`'s existing input
/// messages. Lives exactly as long as the `StreamReceiver` it serves.
@MainActor
final class ReceiverInputController: ObservableObject {
    @Published private(set) var status: ReceiverControlStatus = .unavailable
    /// The transient line over the video (`ReceiverControlStatus.hint`).
    @Published private(set) var hint: String?

    private weak var receiver: StreamReceiver?
    private var forwarder = ReceiverInputForwarder()
    private var cancellables = Set<AnyCancellable>()
    private var keyMonitor: Any?
    private weak var window: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
    private var hintToken = 0

    /// Only while controlling: the view draws the streamed cursor at the
    /// local pointer (see `CursorEchoPolicy`).
    var echoesCursor: Bool { status == .controlling }

    init(receiver: StreamReceiver) {
        self.receiver = receiver
        receiver.onAllowInputStateChange = { [weak self] state in
            guard let self else { return }
            Log.info("receiverInput: grant \(state.rawValue)")
            self.perform(self.forwarder.grantChanged(state))
        }
        receiver.$connected.combineLatest(receiver.$macProtocolVersion)
            .removeDuplicates { $0 == $1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected, version in
                guard let self else { return }
                // `allowInputRequest` (pv 8) is the newest message this
                // needs; pointer (5) and keyboard (4) predate it.
                self.forwarder.setConnected(connected,
                                            inputSupported: version >= WireProtocol.allowInputWireVersion)
                self.refreshStatus()
            }
            .store(in: &cancellables)
        receiver.$inputResetGeneration.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.forwarder.senderReset() }
            .store(in: &cancellables)
    }

    /// Stops listening and releases anything still held. Called when the
    /// receiver it serves goes away.
    func invalidate() {
        detachWindow()
        receiver?.onAllowInputStateChange = nil
        cancellables.removeAll()
    }

    // MARK: Window

    /// The video window. Its key state gates forwarding, and only its key
    /// events are ever looked at.
    func attach(to window: NSWindow) {
        detachWindow()
        self.window = window
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowKeyChanged(true) }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowKeyChanged(false) }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.detachWindow() }
            },
        ]
        // App-local: sees only events already addressed to this app, never
        // other apps' input. Needed because AppKit never delivers a key-up
        // while Command is held to a view, and menu key equivalents would
        // otherwise win over the sending Mac's shortcuts.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.consumeKeyEvent(event) ?? false }
            return consumed ? nil : event
        }
        windowKeyChanged(window.isKeyWindow)
    }

    private func detachWindow() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window = nil
        windowKeyChanged(false)
    }

    private func windowKeyChanged(_ isKey: Bool) {
        perform(forwarder.windowKeyChanged(isKey))
    }

    // MARK: Actions

    func requestControl() { perform(forwarder.requestControl()) }
    func releaseControl() { perform(forwarder.releaseControl()) }
    func pauseControl() { perform(forwarder.pause()) }

    func performStatusAction() {
        switch status.action {
        case .request: requestControl()
        case .release: releaseControl()
        case nil: break
        }
    }

    // MARK: Pointer (from ReceiverVideoView)

    func mouseMoved(_ event: NSEvent, geometry: ReceiverVideoGeometry, in view: NSView) {
        guard let (point, inside) = locate(event, geometry: geometry, in: view) else { return }
        perform(forwarder.pointerMoved(point, inside: inside))
    }

    func mouseDown(_ event: NSEvent, button: PointerButton, geometry: ReceiverVideoGeometry, in view: NSView) {
        guard let (point, inside) = locate(event, geometry: geometry, in: view) else { return }
        let wasPaused = forwarder.paused
        perform(forwarder.pointerDown(button, clickCount: event.clickCount, at: point, inside: inside))
        if wasPaused, !forwarder.paused { refreshStatus() }
    }

    func mouseUp(_ event: NSEvent, button: PointerButton, geometry: ReceiverVideoGeometry, in view: NSView) {
        let point = locate(event, geometry: geometry, in: view)?.point
        perform(forwarder.pointerUp(button, at: point))
    }

    func scrollWheel(_ event: NSEvent, geometry: ReceiverVideoGeometry, in view: NSView) {
        guard let (_, inside) = locate(event, geometry: geometry, in: view),
              let pixelsPerPoint = geometry.videoPixelsPerPoint else { return }
        // A wheel mouse reports lines; one line is about ten points of
        // trackpad travel, which is how macOS itself converts.
        let lineScale = event.hasPreciseScrollingDeltas ? 1.0 : 10.0
        perform(forwarder.scrolled(dxPoints: Double(event.scrollingDeltaX) * lineScale,
                                   dyPoints: Double(event.scrollingDeltaY) * lineScale,
                                   inside: inside, videoPixelsPerPoint: pixelsPerPoint))
    }

    func magnify(_ event: NSEvent) {
        guard let phase = Self.gesturePhase(event.phase) else { return }
        perform(forwarder.gesture(.magnify, phase: phase, delta: Double(event.magnification)))
    }

    func rotate(_ event: NSEvent) {
        guard let phase = Self.gesturePhase(event.phase) else { return }
        // AppKit reports degrees counterclockwise; the wire carries radians.
        perform(forwarder.gesture(.rotate, phase: phase, delta: Double(event.rotation) * .pi / 180))
    }

    private static func gesturePhase(_ phase: NSEvent.Phase) -> NativeAppGesturePhase? {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return nil
    }

    private func locate(_ event: NSEvent, geometry: ReceiverVideoGeometry,
                        in view: NSView) -> (point: CGPoint, inside: Bool)? {
        geometry.normalized(view.convert(event.locationInWindow, from: nil))
    }

    // MARK: Keyboard (app-local monitor)

    /// `false` lets AppKit handle the event here; `true` once it was sent to
    /// the other Mac (or consumed, like the pause shortcut).
    private func consumeKeyEvent(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let modifiers = ReceiverModifierState(rawFlags: event.modifierFlags.rawValue)
        let commands: [ReceiverInputCommand]?
        switch event.type {
        case .keyDown:
            commands = forwarder.keyDown(keyCode: event.keyCode, isRepeat: event.isARepeat, modifiers: modifiers)
        case .keyUp:
            commands = forwarder.keyUp(keyCode: event.keyCode)
        case .flagsChanged:
            perform(forwarder.modifiersChanged(modifiers))
            // Modifier changes also reach AppKit, so its own key handling
            // stays in sync.
            return false
        default:
            return false
        }
        guard let commands else { return false }
        perform(commands)
        return true
    }

    // MARK: Sending

    private func perform(_ commands: [ReceiverInputCommand]) {
        if let receiver {
            for command in commands { send(command, through: receiver) }
        }
        refreshStatus()
    }

    private func send(_ command: ReceiverInputCommand, through receiver: StreamReceiver) {
        switch command {
        case .pointerMove(let x, let y): receiver.sendPointerMove(x: x, y: y)
        case .pointerDown(let button, let count): receiver.sendPointerDown(button: button, clickCount: count)
        case .pointerUp(let button, let count): receiver.sendPointerUp(button: button, clickCount: count)
        case .scroll(let dx, let dy): receiver.sendScroll(dx: dx, dy: dy)
        case .keyDown(let usage, let modifiers, let isRepeat):
            receiver.sendKeyboardDown(usage: usage, modifiers: modifiers, isRepeat: isRepeat)
        case .keyUp(let usage, let modifiers): receiver.sendKeyboardUp(usage: usage, modifiers: modifiers)
        case .modifierDown(let modifier): receiver.sendModifier(modifier, down: true)
        case .modifierUp(let modifier): receiver.sendModifier(modifier, down: false)
        case .gesture(let kind, let phase, let delta): receiver.sendNativeAppGesture(kind: kind, phase: phase, delta: delta)
        case .cancelAll: receiver.sendCancelActiveInput()
        case .requestControl(let allowed): receiver.requestAllowInput(allowed)
        }
    }

    private func refreshStatus() {
        let next = forwarder.status
        guard next != status else { return }
        status = next
        showHint(next.hint)
    }

    private func showHint(_ text: String?) {
        hintToken &+= 1
        hint = text
        guard text != nil else { return }
        let token = hintToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            guard let self, self.hintToken == token else { return }
            self.hint = nil
        }
    }
}

// MARK: - Indicator

/// The video window's titlebar indicator: View Only / Controlling, and the
/// one action that applies. In full screen it appears with the titlebar
/// when the pointer reaches the top of the screen.
struct ReceiverControlIndicator: View {
    @ObservedObject var input: ReceiverInputController

    var body: some View {
        if let title = input.status.title {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout)
                if let action = input.status.action {
                    Button(action == .request ? String(localized: "Request Control") : String(localized: "Release")) {
                        input.performStatusAction()
                    }
                    .controlSize(.small)
                    .help(action == .request
                          ? String(localized: "Ask the other Mac to let this Mac's keyboard and trackpad control it.")
                          : String(localized: "Give control back. The stream stays on screen."))
                }
            }
            .padding(.horizontal, 8)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .help(input.status == .controlling
                  ? String(localized: "Press \(ReceiverInputForwarder.releaseShortcutLabel) to pause control.",
                           comment: "The placeholder is a keyboard shortcut such as ⌃⌥⎋.")
                  : "")
        }
    }

    private var symbol: String {
        switch input.status {
        case .controlling: return "keyboard"
        case .paused, .inactive: return "pause.circle"
        case .requesting: return "hourglass"
        case .declined, .requestsDisabled: return "hand.raised"
        case .viewOnly, .unavailable: return "eye"
        }
    }

    private var tint: Color {
        switch input.status {
        case .controlling: return .accentColor
        case .declined, .requestsDisabled: return .orange
        default: return .secondary
        }
    }
}

/// The transient hint over the video.
struct ReceiverControlHint: View {
    @ObservedObject var input: ReceiverInputController

    var body: some View {
        VStack {
            if let hint = input.hint {
                Text(hint)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 14)
                    .transition(.opacity)
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: input.hint)
        .allowsHitTesting(false)
    }
}
