import Foundation

/// The lightweight on-surface "Request Input" affordance: when a touch was
/// meant for the Mac but input isn't allowed, offer the existing request
/// flow right there instead of sending the user to Settings. Ephemeral —
/// it fades once the user stops trying — and never spams requests. The Mac
/// stays the only authority: this only ever sends the existing request.
struct ReceiverInputPrompt: Equatable {
    enum Kind: Equatable {
        /// The user turned input off themselves.
        case enableInput
        /// Input isn't granted for this session yet (or was declined).
        case requestInput
        /// A request is waiting for the Mac.
        case requesting
        /// Just granted — shown briefly, then gone.
        case enabled
        /// The Mac isn't accepting requests from this device.
        case unavailable
    }

    enum Effect: Equatable {
        /// Send the existing allow-input request.
        case sendRequest
    }

    /// How long the prompt lingers after the last blocked attempt.
    static let visibleDuration: TimeInterval = 3.5
    static let enabledDuration: TimeInterval = 1.6
    /// Automatic requests at most this often.
    static let minimumAutomaticInterval: TimeInterval = 8
    /// A tapped request can't be re-sent faster than this.
    static let minimumTappedInterval: TimeInterval = 1.5

    private(set) var kind: Kind?
    private(set) var visibleUntil: TimeInterval = 0
    private(set) var lastRequestAt: TimeInterval?
    private var state: SessionInputWireState = .off
    private var sessionLive = false

    func isVisible(at now: TimeInterval) -> Bool { kind != nil && now < visibleUntil }

    /// The live session came or went. No prompt without a live session.
    mutating func setSessionLive(_ live: Bool) {
        sessionLive = live
        if !live { kind = nil }
    }

    /// The Mac-confirmed input state changed.
    mutating func inputStateChanged(_ newState: SessionInputWireState, now: TimeInterval) {
        let previous = state
        state = newState
        guard kind != nil, now < visibleUntil || kind == .requesting else { return }
        switch newState {
        case .allowed where previous != .allowed:
            kind = .enabled
            visibleUntil = now + Self.enabledDuration
        case .requesting:
            kind = .requesting
        case .requestsDisabled:
            kind = .unavailable
            visibleUntil = max(visibleUntil, now + Self.visibleDuration)
        case .notAllowed, .off:
            if kind == .requesting { kind = .requestInput; visibleUntil = now + Self.visibleDuration }
        case .allowed:
            break
        }
    }

    /// A touch that would have reached the Mac was dropped. With
    /// `autoRequest` (this Mac is set to Always Allow on this device) the
    /// first attempt sends the request itself, at most once per interval.
    mutating func blockedAttempt(now: TimeInterval, userTurnedOff: Bool, autoRequest: Bool) -> [Effect] {
        guard sessionLive, state != .allowed else { return [] }
        visibleUntil = now + Self.visibleDuration
        switch state {
        case .requesting:
            kind = .requesting
            return []
        case .requestsDisabled:
            kind = .unavailable
            return []
        case .off, .notAllowed, .allowed:
            kind = userTurnedOff ? .enableInput : .requestInput
            guard autoRequest, !userTurnedOff, state != .notAllowed,
                  canRequest(now: now, interval: Self.minimumAutomaticInterval) else { return [] }
            lastRequestAt = now
            kind = .requesting
            return [.sendRequest]
        }
    }

    /// The user tapped Request/Enable Input.
    mutating func requestTapped(now: TimeInterval) -> [Effect] {
        guard sessionLive, state != .allowed, state != .requestsDisabled, state != .requesting,
              canRequest(now: now, interval: Self.minimumTappedInterval) else { return [] }
        lastRequestAt = now
        kind = .requesting
        visibleUntil = now + Self.visibleDuration
        return [.sendRequest]
    }

    /// Drops a prompt whose time is up.
    mutating func tick(now: TimeInterval) {
        if kind != nil, now >= visibleUntil { kind = nil }
    }

    private func canRequest(now: TimeInterval, interval: TimeInterval) -> Bool {
        lastRequestAt.map { now - $0 >= interval } ?? true
    }
}

/// Which dropped touch sequences count as trying to control the Mac. A
/// two-finger sequence is Local View Navigation (pan/zoom/rotate), never a
/// reason to ask for input; nor is anything in Move View.
enum BlockedInputAttemptPolicy {
    static func isRemoteIntent(maximumTouchCount: Int, moveViewActive: Bool) -> Bool {
        guard !moveViewActive, maximumTouchCount > 0 else { return false }
        return maximumTouchCount != 2
    }
}

/// Whether a blocked touch may send the input request by itself. Only an
/// explicit, per-Mac, input-specific opt-in counts — never the connection
/// policy (accepting a Mac's connections with Always Allow says nothing
/// about letting a stray touch ask for control). Even then this only sends
/// the normal request; the Mac alone grants input.
enum InputAutoRequestPolicy {
    static func shouldAutoRequest(peerOptedIn: Bool) -> Bool { peerOptedIn }
}

/// The per-Mac "Request Input Automatically" opt-in, keyed by the pinned
/// peer ID like `IncomingSessionPolicyStore`. Off unless the user turns it
/// on; forgetting the Mac removes it.
enum InputAutoRequestStore {
    static let defaultsKey = "inputAutoRequestPeers.v1"

    static func isEnabled(peerID: String?, defaults: UserDefaults = .standard) -> Bool {
        guard let peerID else { return false }
        return (defaults.stringArray(forKey: defaultsKey) ?? []).contains(peerID)
    }

    static func setEnabled(_ enabled: Bool, peerID: String, defaults: UserDefaults = .standard) {
        var peers = Set(defaults.stringArray(forKey: defaultsKey) ?? [])
        if enabled { peers.insert(peerID) } else { peers.remove(peerID) }
        defaults.set(peers.sorted(), forKey: defaultsKey)
    }

    static func remove(peerID: String, defaults: UserDefaults = .standard) {
        setEnabled(false, peerID: peerID, defaults: defaults)
    }
}

/// What the receiver's own controls show.
enum ReceiverControlPresentation: Equatable {
    /// Strip, Overlay, Custom, or the iPhone tray.
    case normal
    /// The software keyboard is up: a flat accessory bar right above it.
    case keyboardBar

    static func mode(softwareKeyboardVisible: Bool) -> ReceiverControlPresentation {
        softwareKeyboardVisible ? .keyboardBar : .normal
    }
}

/// The keyboard accessory bar's contents — keyboard companions only, never
/// the session controls (Undo, Zoom, Dock, Move View, Settings, …). Kept as
/// data so its contents can become configurable later.
enum KeyboardBarItem: Hashable {
    case modifier(ControlModifier)
    case escape
    case tab
    /// Dismisses the software keyboard.
    case dismissKeyboard

    static let defaultItems: [KeyboardBarItem] = ControlModifier.allCases.map(KeyboardBarItem.modifier)
        + [.escape, .tab, .dismissKeyboard]
}
