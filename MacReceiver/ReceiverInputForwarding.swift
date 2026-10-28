import CoreGraphics
import Foundation

// Mac-to-Mac input (issue #12): the receiving Mac's own trackpad, mouse and
// keyboard drive the sending Mac while its video window is in front. This
// file is the decision layer — where a point lands, which key a key code is,
// and what may be forwarded right now — kept free of AppKit so every rule is
// unit testable. `ReceiverVideoView` feeds it AppKit events and sends what it
// returns through the existing `StreamReceiver` input messages; no new wire
// message exists for any of it.
//
// Input is never captured globally: only events AppKit delivers to the video
// window while it is key reach this, so the receiving Mac's system shortcuts
// (Command-Tab, Command-Option-Escape, Mission Control, Spotlight, screenshots,
// lock screen) never leave it. The sending Mac stays the authority — nothing
// is forwarded without its per-session grant, and it drops input itself the
// moment that grant ends.

/// Where the stream sits inside the video view: aspect-fit, centered, in view
/// points with AppKit's bottom-left origin.
struct ReceiverVideoGeometry: Equatable {
    let viewSize: CGSize
    /// The stream's pixel size (from its SPS).
    let videoSize: CGSize

    /// `nil` until both sizes are known.
    var fittedRect: CGRect? {
        guard videoSize.width > 0, videoSize.height > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        let scale = min(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// A view point as normalized video coordinates (PROTOCOL.md section 7:
    /// top-left origin, 0...1), clamped onto the video so a drag that leaves
    /// the picture (into a letterbox bar, or outside the window) pins to its
    /// edge instead of reaching another display on the sending Mac.
    /// `inside` reports whether the unclamped point was on the picture.
    func normalized(_ viewPoint: CGPoint) -> (point: CGPoint, inside: Bool)? {
        guard let rect = fittedRect else { return nil }
        let x = (viewPoint.x - rect.minX) / rect.width
        let y = (rect.maxY - viewPoint.y) / rect.height
        let inside = (0...1).contains(x) && (0...1).contains(y)
        return (CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1)), inside)
    }

    /// Video pixels per view point — scroll deltas travel in video pixels.
    var videoPixelsPerPoint: Double? {
        guard let rect = fittedRect else { return nil }
        return Double(videoSize.width / rect.width)
    }
}

// MARK: - Keys

/// macOS virtual key codes (`kVK_*`, physical key positions) to USB HID
/// keyboard-page usages, the vocabulary `keyboard` messages carry. Both name
/// the physical key, so the sending Mac's own keyboard layout decides what
/// gets typed — exactly as if this keyboard were plugged into it.
/// Modifier keys are not here: they travel as `modifierDown`/`modifierUp`.
enum MacVirtualKeyMap {
    static func hidUsage(forKeyCode keyCode: UInt16) -> Int? { table[keyCode] }

    static var mappedKeyCodes: [UInt16] { Array(table.keys).sorted() }

    private static let table: [UInt16: Int] = [
        // Letters
        0x00: 4, 0x0B: 5, 0x08: 6, 0x02: 7, 0x0E: 8, 0x03: 9, 0x05: 10, 0x04: 11, 0x22: 12,
        0x26: 13, 0x28: 14, 0x25: 15, 0x2E: 16, 0x2D: 17, 0x1F: 18, 0x23: 19, 0x0C: 20,
        0x0F: 21, 0x01: 22, 0x11: 23, 0x20: 24, 0x09: 25, 0x0D: 26, 0x07: 27, 0x10: 28, 0x06: 29,
        // Digits row
        0x12: 30, 0x13: 31, 0x14: 32, 0x15: 33, 0x17: 34, 0x16: 35, 0x1A: 36, 0x1C: 37, 0x19: 38, 0x1D: 39,
        // Return, Escape, Delete, Tab, Space
        0x24: 40, 0x35: 41, 0x33: 42, 0x30: 43, 0x31: 44,
        // Punctuation
        0x1B: 45, 0x18: 46, 0x21: 47, 0x1E: 48, 0x2A: 49, 0x29: 51, 0x27: 52, 0x32: 53,
        0x2B: 54, 0x2F: 55, 0x2C: 56,
        // ISO key left of Z (§ / <), JIS ¥ and _ and keypad comma, Eisū and Kana
        0x0A: 100, 0x5D: 137, 0x5E: 135, 0x5F: 133, 0x66: 145, 0x68: 144,
        // F1–F20
        0x7A: 58, 0x78: 59, 0x63: 60, 0x76: 61, 0x60: 62, 0x61: 63, 0x62: 64, 0x64: 65,
        0x65: 66, 0x6D: 67, 0x67: 68, 0x6F: 69, 0x69: 104, 0x6B: 105, 0x71: 106, 0x6A: 107,
        0x40: 108, 0x4F: 109, 0x50: 110, 0x5A: 111,
        // Help/Insert, Home, Page Up, Forward Delete, End, Page Down, arrows
        0x72: 73, 0x73: 74, 0x74: 75, 0x75: 76, 0x77: 77, 0x79: 78,
        0x7C: 79, 0x7B: 80, 0x7D: 81, 0x7E: 82,
        // Keypad
        0x47: 83, 0x4B: 84, 0x43: 85, 0x4E: 86, 0x45: 87, 0x4C: 88, 0x53: 89, 0x54: 90, 0x55: 91,
        0x56: 92, 0x57: 93, 0x58: 94, 0x59: 95, 0x5B: 96, 0x5C: 97, 0x52: 98, 0x41: 99, 0x51: 103,
    ]

    static let escapeKeyCode: UInt16 = 0x35
}

/// The receiving Mac's modifier-key state, reduced to what the wire names.
struct ReceiverModifierState: Equatable {
    var held: Set<ControlModifier> = []
    var capsLock = false

    /// From raw `NSEvent.ModifierFlags` bits, so this file stays AppKit-free.
    init(rawFlags: UInt) {
        if rawFlags & (1 << 17) != 0 { held.insert(.shift) }
        if rawFlags & (1 << 18) != 0 { held.insert(.control) }
        if rawFlags & (1 << 19) != 0 { held.insert(.option) }
        if rawFlags & (1 << 20) != 0 { held.insert(.command) }
        capsLock = rawFlags & (1 << 16) != 0
    }

    init(held: Set<ControlModifier> = [], capsLock: Bool = false) {
        self.held = held
        self.capsLock = capsLock
    }
}

// MARK: - Forwarding

/// What `ReceiverVideoView` sends, in order. Each maps onto one existing
/// `StreamReceiver` send call.
enum ReceiverInputCommand: Equatable {
    case pointerMove(x: Double, y: Double)
    case pointerDown(PointerButton, clickCount: Int)
    case pointerUp(PointerButton, clickCount: Int)
    case scroll(dx: Double, dy: Double)
    case keyDown(usage: Int, modifiers: [String], isRepeat: Bool)
    case keyUp(usage: Int, modifiers: [String])
    case modifierDown(ControlModifier)
    case modifierUp(ControlModifier)
    case gesture(NativeAppGestureKind, NativeAppGesturePhase, delta: Double)
    /// `keyboard` `cancel`: the sending Mac releases everything it holds for
    /// this session. Sent after the explicit releases, as a safety net.
    case cancelAll
    /// `allowInputRequest`.
    case requestControl(Bool)
}

/// What the control indicator shows.
enum ReceiverControlStatus: Equatable {
    /// No session, or a sending Mac too old for input requests.
    case unavailable
    /// View only; Request Control is offered.
    case viewOnly
    case requesting
    /// The sending Mac's owner declined, or the prompt timed out.
    case declined
    /// The sending Mac doesn't accept control requests from this Mac.
    case requestsDisabled
    /// Granted, but this window isn't key (another app or window is in front).
    case inactive
    /// Granted and paused here with the release shortcut; a click resumes.
    case paused
    /// This Mac's keyboard and pointer are driving the sending Mac.
    case controlling
}

/// The receiver's half of the input contract. Forwards only while the
/// sending Mac granted this session control, the video window is key, and
/// the user hasn't paused it; and it remembers every key, modifier and button
/// it sent down so that ANY way forwarding ends — focus loss, the release
/// shortcut, Release Control, revocation, the window closing — releases them
/// on the sending Mac. A modifier or key already held when forwarding began
/// (Command still down from the Command-Tab that brought this window forward)
/// is never sent: only presses that started while forwarding are.
struct ReceiverInputForwarder {
    /// Control-Option-Escape: pauses forwarding without giving up the grant.
    /// Not a system shortcut on macOS (Command-Option-Escape is Force Quit).
    static let releaseShortcutModifiers: Set<ControlModifier> = [.control, .option]
    static let releaseShortcutLabel = "⌃⌥⎋"

    private(set) var connected = false
    /// The sending Mac supports `allowInputRequest` and input messages.
    private(set) var inputSupported = false
    private(set) var grant: SessionInputWireState = .off
    private(set) var windowIsKey = false
    private(set) var paused = false

    private(set) var heldKeys: [Int: [String]] = [:]
    private(set) var heldModifiers: Set<ControlModifier> = []
    private(set) var heldButton: (button: PointerButton, clickCount: Int)?
    private var activeGestures: Set<NativeAppGestureKind> = []
    private var lastMove: CGPoint?

    var isForwarding: Bool { connected && inputSupported && grant == .allowed && windowIsKey && !paused }

    var status: ReceiverControlStatus {
        guard connected, inputSupported else { return .unavailable }
        switch grant {
        case .off: return .viewOnly
        case .requesting: return .requesting
        case .notAllowed: return .declined
        case .requestsDisabled: return .requestsDisabled
        case .allowed:
            if paused { return .paused }
            return windowIsKey ? .controlling : .inactive
        }
    }

    var holdsInput: Bool { !heldKeys.isEmpty || !heldModifiers.isEmpty || heldButton != nil || !activeGestures.isEmpty }

    // MARK: Session and focus

    /// A session started or ended. A lost connection takes the sender's
    /// state with it (it releases everything itself on session loss), so
    /// nothing is sent — local tracking just resets.
    mutating func setConnected(_ live: Bool, inputSupported supported: Bool) {
        if connected != live || !live { resetTracking() }
        connected = live
        inputSupported = live && supported
        if !live {
            grant = .off
            paused = false
        }
    }

    /// The sending Mac's confirmed state. Anything but `.allowed` ends
    /// forwarding; the sender has already dropped this session's input, and
    /// the explicit releases make sure it holds nothing.
    mutating func grantChanged(_ state: SessionInputWireState) -> [ReceiverInputCommand] {
        let wasAllowed = grant == .allowed
        grant = state
        if state == .allowed, !wasAllowed { paused = false }
        return state == .allowed ? [] : releaseAll()
    }

    /// The sending Mac reset input (`inputReset`): it already released
    /// everything, so only local tracking clears.
    mutating func senderReset() {
        resetTracking()
    }

    mutating func windowKeyChanged(_ isKey: Bool) -> [ReceiverInputCommand] {
        windowIsKey = isKey
        return isKey ? [] : releaseAll()
    }

    /// The release shortcut (or the indicator's Pause): stop forwarding but
    /// keep the grant. A click on the picture resumes.
    mutating func pause() -> [ReceiverInputCommand] {
        guard grant == .allowed, !paused else { return [] }
        paused = true
        return releaseAll()
    }

    mutating func resume() {
        paused = false
    }

    mutating func requestControl() -> [ReceiverInputCommand] {
        guard connected, inputSupported, grant != .allowed, grant != .requesting, grant != .requestsDisabled else {
            return []
        }
        return [.requestControl(true)]
    }

    /// Release Control: give the grant back. Effective immediately on the
    /// sending Mac — narrowing never needs its owner's decision.
    mutating func releaseControl() -> [ReceiverInputCommand] {
        guard connected, inputSupported, grant == .allowed || grant == .requesting else { return [] }
        let releases = releaseAll()
        paused = false
        return releases + [.requestControl(false)]
    }

    // MARK: Pointer

    mutating func pointerMoved(_ normalized: CGPoint, inside: Bool) -> [ReceiverInputCommand] {
        guard isForwarding, inside || heldButton != nil else { return [] }
        guard normalized != lastMove else { return [] }
        lastMove = normalized
        return [.pointerMove(x: Double(normalized.x), y: Double(normalized.y))]
    }

    /// A press on the video. While paused, a press on the picture resumes
    /// forwarding and is consumed (it was a "click back in", not a click on
    /// the sending Mac). Presses outside the picture (letterbox) do nothing.
    mutating func pointerDown(_ button: PointerButton, clickCount: Int, at normalized: CGPoint,
                              inside: Bool) -> [ReceiverInputCommand] {
        guard inside else { return [] }
        if paused, connected, grant == .allowed, windowIsKey {
            paused = false
            return []
        }
        guard isForwarding, heldButton == nil else { return [] }
        heldButton = (button, max(clickCount, 1))
        lastMove = normalized
        // Position first: the sending Mac clicks at its own cursor.
        return [.pointerMove(x: Double(normalized.x), y: Double(normalized.y)),
                .pointerDown(button, clickCount: max(clickCount, 1))]
    }

    /// A release is forwarded only for a press this forwarder sent — never
    /// gated on forwarding, so a release always matches its press.
    mutating func pointerUp(_ button: PointerButton, at normalized: CGPoint?) -> [ReceiverInputCommand] {
        guard let held = heldButton, held.button == button else { return [] }
        heldButton = nil
        var commands: [ReceiverInputCommand] = []
        if isForwarding, let normalized, normalized != lastMove {
            lastMove = normalized
            commands.append(.pointerMove(x: Double(normalized.x), y: Double(normalized.y)))
        }
        commands.append(.pointerUp(button, clickCount: held.clickCount))
        return commands
    }

    /// Scroll deltas in view points with the receiving Mac's own scroll
    /// direction already applied (`NSEvent.scrollingDelta*`), so this Mac's
    /// natural-scrolling setting is what its user feels.
    mutating func scrolled(dxPoints: Double, dyPoints: Double, inside: Bool,
                           videoPixelsPerPoint: Double) -> [ReceiverInputCommand] {
        guard isForwarding, inside, dxPoints != 0 || dyPoints != 0 else { return [] }
        return [.scroll(dx: dxPoints * videoPixelsPerPoint, dy: dyPoints * videoPixelsPerPoint)]
    }

    /// Trackpad pinch/rotate, as the existing `nativeAppGesture` lifecycle.
    mutating func gesture(_ kind: NativeAppGestureKind, phase: NativeAppGesturePhase,
                          delta: Double) -> [ReceiverInputCommand] {
        switch phase {
        case .began:
            guard isForwarding, !activeGestures.contains(kind) else { return [] }
            activeGestures.insert(kind)
        case .changed:
            guard isForwarding, activeGestures.contains(kind) else { return [] }
        case .ended, .cancelled:
            guard activeGestures.remove(kind) != nil else { return [] }
        }
        return [.gesture(kind, phase, delta: delta)]
    }

    // MARK: Keyboard

    /// A key press. Returns `nil` when the event is NOT for the sending Mac
    /// and AppKit should handle it locally (not forwarding, or a key the
    /// wire can't name); an empty array when it was consumed here (the
    /// release shortcut, a repeat of a key that was never sent).
    mutating func keyDown(keyCode: UInt16, isRepeat: Bool,
                          modifiers: ReceiverModifierState) -> [ReceiverInputCommand]? {
        if keyCode == MacVirtualKeyMap.escapeKeyCode, modifiers.held == Self.releaseShortcutModifiers {
            return grant == .allowed && connected ? pause() : nil
        }
        guard isForwarding else { return nil }
        guard let usage = MacVirtualKeyMap.hidUsage(forKeyCode: keyCode) else { return [] }
        let names = wireModifiers(capsLock: modifiers.capsLock)
        if isRepeat {
            // Only repeat what this forwarder pressed.
            guard heldKeys[usage] != nil else { return [] }
            return [.keyDown(usage: usage, modifiers: names, isRepeat: true)]
        }
        guard heldKeys[usage] == nil else { return [] }
        heldKeys[usage] = names
        return [.keyDown(usage: usage, modifiers: names, isRepeat: false)]
    }

    /// A key release: forwarded only for a key this forwarder pressed, and
    /// never gated on forwarding, so every press gets its release.
    mutating func keyUp(keyCode: UInt16) -> [ReceiverInputCommand]? {
        guard let usage = MacVirtualKeyMap.hidUsage(forKeyCode: keyCode),
              let names = heldKeys.removeValue(forKey: usage) else {
            return isForwarding ? [] : nil
        }
        return [.keyUp(usage: usage, modifiers: names)]
    }

    /// `flagsChanged`: modifiers pressed while forwarding go down on the
    /// sending Mac; releases of modifiers this forwarder sent go up.
    mutating func modifiersChanged(_ state: ReceiverModifierState) -> [ReceiverInputCommand] {
        var commands: [ReceiverInputCommand] = []
        for modifier in ControlModifier.allCases where heldModifiers.contains(modifier) && !state.held.contains(modifier) {
            heldModifiers.remove(modifier)
            commands.append(.modifierUp(modifier))
        }
        guard isForwarding else { return commands }
        for modifier in ControlModifier.allCases where !heldModifiers.contains(modifier) && state.held.contains(modifier) {
            heldModifiers.insert(modifier)
            commands.append(.modifierDown(modifier))
        }
        return commands
    }

    // MARK: Private

    private func wireModifiers(capsLock: Bool) -> [String] {
        var names = ControlModifier.allCases.filter(heldModifiers.contains).map(\.rawValue)
        if capsLock { names.append("capsLock") }
        return names
    }

    /// Everything this forwarder holds goes up on the sending Mac, then a
    /// `cancel` as the safety net. Nothing is sent when nothing is held.
    private mutating func releaseAll() -> [ReceiverInputCommand] {
        guard connected, holdsInput else {
            resetTracking()
            return []
        }
        var commands: [ReceiverInputCommand] = []
        for kind in NativeAppGestureKind.allCases where activeGestures.contains(kind) {
            commands.append(.gesture(kind, .cancelled, delta: 0))
        }
        if let held = heldButton {
            commands.append(.pointerUp(held.button, clickCount: held.clickCount))
        }
        for usage in heldKeys.keys.sorted() {
            commands.append(.keyUp(usage: usage, modifiers: heldKeys[usage] ?? []))
        }
        for modifier in ControlModifier.allCases where heldModifiers.contains(modifier) {
            commands.append(.modifierUp(modifier))
        }
        commands.append(.cancelAll)
        resetTracking()
        return commands
    }

    private mutating func resetTracking() {
        heldKeys = [:]
        heldModifiers = []
        heldButton = nil
        activeGestures = []
        lastMove = nil
    }
}

// MARK: - Presentation

extension ReceiverControlStatus {
    /// The indicator's short label; `nil` hides it.
    var title: String? {
        switch self {
        case .unavailable: return nil
        case .viewOnly: return String(localized: "View Only", comment: "Receiver control status: the stream can be watched but not controlled.")
        case .requesting: return String(localized: "Requesting Control…")
        case .declined: return String(localized: "Control Declined")
        case .requestsDisabled: return String(localized: "Control Not Available")
        case .inactive: return String(localized: "Control Allowed")
        case .paused: return String(localized: "Paused")
        case .controlling: return String(localized: "Controlling")
        }
    }

    /// The one action the indicator offers.
    enum Action: Equatable {
        case request
        case release
    }

    var action: Action? {
        switch self {
        case .viewOnly, .declined: return .request
        case .requesting, .inactive, .paused, .controlling: return .release
        case .unavailable, .requestsDisabled: return nil
        }
    }

    /// A short-lived line over the video when the state changes, so the way
    /// back out is never a secret.
    var hint: String? {
        switch self {
        case .controlling:
            return String(localized: "This Mac's keyboard and trackpad now control the other Mac. Press \(ReceiverInputForwarder.releaseShortcutLabel) to pause.",
                          comment: "The placeholder is a keyboard shortcut such as ⌃⌥⎋.")
        case .paused: return String(localized: "Control paused. Click the picture to resume.")
        case .declined: return String(localized: "The other Mac didn't allow control.")
        case .requestsDisabled: return String(localized: "The other Mac doesn't accept control requests from this Mac.")
        case .unavailable, .viewOnly, .requesting, .inactive: return nil
        }
    }
}

/// While this Mac drives the pointer, the streamed cursor is drawn where the
/// local pointer is right away instead of waiting a network round trip and a
/// video frame for the sending Mac to report it. The sending Mac's reports
/// take over again once local movement stops, so the two can never disagree
/// for long (the sending Mac's own trackpad, a cursor clamped at a screen
/// edge).
struct CursorEchoPolicy {
    static let holdAfterLocalMove: TimeInterval = 0.25

    private(set) var localUntil: TimeInterval = 0

    mutating func localMove(at now: TimeInterval) {
        localUntil = now + Self.holdAfterLocalMove
    }

    func appliesRemotePosition(at now: TimeInterval) -> Bool {
        now >= localUntil
    }

    mutating func reset() {
        localUntil = 0
    }
}
