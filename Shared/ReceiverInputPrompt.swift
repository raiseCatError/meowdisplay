import Foundation

/// The lightweight on-surface "Request Control" affordance: when a touch was
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
    /// How long a live session must stay view only before Request Control is offered unasked:
    /// an Always Allow grant arrives well within it, so it never flashes up for nothing.
    static let viewOnlyOfferDelay: TimeInterval = 1.5

    /// Whether a live session is in the state that gets the unasked offer: a Mac that reports its
    /// decision (pv 8+, older Macs say nothing to answer), no decision yet (`off`: not declined,
    /// not requesting, not Never Allow), not locked (the locked cover has its own steps), and this
    /// device didn't turn input off itself.
    static func offersViewOnly(sessionLive: Bool, macPV: Int, macState: SessionInputWireState,
                               macLocked: Bool, userTurnedOff: Bool) -> Bool {
        sessionLive && !macLocked && !userTurnedOff
            && macPV >= WireProtocol.allowInputWireVersion && macState == .off
    }

    private(set) var kind: Kind?
    private(set) var visibleUntil: TimeInterval = 0
    private(set) var lastRequestAt: TimeInterval?
    private var state: SessionInputWireState = .off
    private var sessionLive = false
    /// Request Control was already offered on this live session without a blocked touch.
    private var offeredForViewOnly = false

    /// Shown until the first blocked touch, a tap or the Mac's next answer (`offerForViewOnlySession`).
    var isUntilAnswered: Bool { kind != nil && visibleUntil == .infinity }

    func isVisible(at now: TimeInterval) -> Bool { kind != nil && now < visibleUntil }

    /// The live session came or went. No prompt without a live session.
    mutating func setSessionLive(_ live: Bool) {
        sessionLive = live
        if !live {
            kind = nil
            offeredForViewOnly = false
        }
    }

    /// The live session settled view only, with no decision yet (#255): offer Request Control
    /// once, before the user has to discover it by touching. It stays until the first blocked
    /// touch (which then fades it as usual), a tap, or the Mac's answer. Never sends anything:
    /// only a tap (or Request Control Automatically on a blocked touch) asks. Not after the Mac
    /// declined, while a request waits, under Never Allow, or when this device turned input off.
    @discardableResult
    mutating func offerForViewOnlySession(userTurnedOff: Bool) -> Bool {
        guard sessionLive, state == .off, kind == nil, !offeredForViewOnly, !userTurnedOff else { return false }
        offeredForViewOnly = true
        kind = .requestInput
        visibleUntil = .infinity
        return true
    }

    /// The Mac-confirmed input state changed.
    mutating func inputStateChanged(_ newState: SessionInputWireState, now: TimeInterval) {
        let previous = state
        state = newState
        guard kind != nil, now < visibleUntil || kind == .requesting else { return }
        // An offer that waited for an answer now fades like any other prompt.
        if visibleUntil == .infinity, newState != .off { visibleUntil = now + Self.visibleDuration }
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

    /// The user tapped Request Control.
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
    /// `selectedPane`: the touch only chose another Window-mode pane (local, never for the Mac).
    /// Two fingers are this device's own pan and zoom, never an attempt at the Mac.
    static func isRemoteIntent(maximumTouchCount: Int, moveViewActive: Bool, selectedPane: Bool = false) -> Bool {
        guard !moveViewActive, !selectedPane, maximumTouchCount > 0 else { return false }
        return maximumTouchCount != 2
    }

    /// Whether remote input may leave this device. A Mac that reports its control decision
    /// (pv 8+) must have granted it: View Only forwards nothing, and a touch meant for the Mac
    /// offers Request Control instead (found 2026-10-30: in Window mode the touch went out, the
    /// Mac dropped it, and no prompt appeared). Older Macs never report it, so only the live
    /// session and this device's own switch count there. `surfaceInteractive` is false while
    /// Home covers a kept session (#121): nothing on that hidden surface may reach the Mac.
    static func inputReachesMac(sessionLive: Bool, localAllow: Bool, macPV: Int, macState: SessionInputWireState,
                                surfaceInteractive: Bool = true) -> Bool {
        guard sessionLive, localAllow, surfaceInteractive else { return false }
        return macPV < WireProtocol.allowInputWireVersion || macState == .allowed
    }
}

/// What a delayed remote action, such as a later step of a one-tap sequence,
/// was started under. It may go on only while the receiver still reports
/// the same ticket:
/// - `controlGeneration` moves on every reset of local control state: Home,
///   Session Actions, a display-mode switch, the surface closing (the app
///   not active, Picture in Picture), or the session pausing or ending.
/// - `connectionGeneration` moves with every new connection: another Mac,
///   or the same one reconnecting.
///
/// There is no ticket while input can't leave this device. The permission
/// at the moment the action started is never enough on its own.
struct RemoteInputTicket: Equatable, Sendable {
    let controlGeneration: Int
    let connectionGeneration: Int

    static func current(surfaceOpen: Bool, displayRunning: Bool, sessionLive: Bool,
                        controlGeneration: Int, connectionGeneration: Int?) -> RemoteInputTicket? {
        guard surfaceOpen, displayRunning, sessionLive, let connectionGeneration else { return nil }
        return RemoteInputTicket(controlGeneration: controlGeneration, connectionGeneration: connectionGeneration)
    }
}

/// The last check before input leaves this device. While the receiver
/// surface is closed (Home over a kept session, Session Actions, Picture in
/// Picture, or the app not active), only releases go out. That way nothing
/// new starts on the Mac, and nothing already pressed stays pressed.
enum RemoteInputTransmission {
    /// A touch or Pencil phase that ends contact rather than starting or moving it.
    static func isRelease(phase: String) -> Bool {
        phase == "ended" || phase == "cancelled"
    }

    static func mayLeave(surfaceOpen: Bool, isRelease: Bool) -> Bool {
        surfaceOpen || isRelease
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

/// The per-Mac "Request Control Automatically" opt-in, keyed by the pinned
/// peer ID like `IncomingSessionPolicyStore`. Off unless the user turns it
/// on; forgetting the Mac removes it.
enum InputAutoRequestStore {
    // Receiver-only; scoped like every receiver-role key in the unified app.
    static let defaultsKey = ReceiverRoleConfiguration.defaultsKey("inputAutoRequestPeers.v1")

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
    /// One Return press, beside Escape and Tab for ⌘↵ and ⇧↵.
    case returnKey
    /// Opens the arrow keypad (#179); shown only while the arrow keys are.
    case arrowKeys
    /// Dismisses the software keyboard.
    case dismissKeyboard

    static let defaultItems: [KeyboardBarItem] = ControlModifier.allCases.map(KeyboardBarItem.modifier)
        + [.escape, .tab, .returnKey, .arrowKeys, .dismissKeyboard]

    /// Points between keys. A ninth key tightens it a little, so a 375pt
    /// iPhone keeps 32pt keys instead of dropping to the 30pt floor.
    static func gap(count: Int) -> CGFloat { count > 8 ? 6 : 8 }
}


/// Window mode, two fingers on a pane: scroll the Mac, or move the pane on this device?
enum WorkspaceTwoFingerPolicy {
    /// A pinch always zooms/moves the pane locally; a plain drag scrolls the Mac when input
    /// reaches it and Move View is off; otherwise (View Only) the pane moves locally.
    static func scrollsMac(isPinch: Bool, inputReachesMac: Bool, moveViewActive: Bool) -> Bool {
        !isPinch && inputReachesMac && !moveViewActive
    }
}
