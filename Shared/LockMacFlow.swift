import Foundation

// Lock Mac from the receiver: decides which path a tap on "Lock Mac" takes,
// including asking the Mac for control first. Pure values, so every decision is
// unit-tested on macOS (LockMacFlowTests); WorkspaceModel acts on the effects.
// The lock request is only ever an effect of a granted control state the Mac
// itself reported (`controlGranted` + `.allowed`); a pending or unknown state
// never counts. The Mac still enforces control for locking on its own side.

struct LockMacFlow: Equatable, Sendable {
    /// What the flow reads from the session.
    struct Inputs: Equatable, Sendable {
        /// The Mac advertised Lock This Mac (cleared on disconnect).
        var canLock: Bool
        /// A live session (not paused, reconnecting or gone).
        var connected: Bool
        /// `WorkspaceModel.canControlMac`.
        var controlGranted: Bool
        var inputState: SessionInputWireState
    }

    enum Unavailable: Equatable, Sendable { case notSupported, notConnected, requestsDisabled }

    /// How a confirmed tap would go, given the inputs right now.
    enum Path: Equatable, Sendable {
        case lockNow
        /// Send Request Control, wait for the Mac's answer, then lock.
        case requestThenLock
        /// A request is already up on the Mac (made elsewhere): wait, don't send another.
        case waitForRequest
        case unavailable(Unavailable)
    }

    /// Why the flow stopped without locking.
    enum Notice: Equatable, Sendable {
        case unavailable(Unavailable)
        case declined, disconnected, timedOut
    }

    enum Phase: Equatable, Sendable {
        case idle
        case confirming(Path)
        /// `baseline` is the state when waiting began; a terminal state only counts once it
        /// differs from it or `.requesting` was seen, so a stale "declined" is never mistaken
        /// for the answer to this request.
        case awaitingControl(baseline: SessionInputWireState, sawRequesting: Bool)
        case notice(Notice)
    }

    enum Effect: Equatable, Sendable { case requestControl, lock }

    /// The Mac's own prompt gives up after 45 s; this is a little longer.
    static let timeout: TimeInterval = 50

    private(set) var phase: Phase = .idle

    var isConfirming: Bool { if case .confirming = phase { return true } else { return false } }
    var isAwaiting: Bool { if case .awaitingControl = phase { return true } else { return false } }
    var notice: Notice? { if case .notice(let n) = phase { return n } else { return nil } }
    var confirmingPath: Path? { if case .confirming(let p) = phase { return p } else { return nil } }

    static func path(for i: Inputs) -> Path {
        if !i.canLock { return .unavailable(.notSupported) }
        if !i.connected { return .unavailable(.notConnected) }
        if i.controlGranted, i.inputState == .allowed { return .lockNow }
        switch i.inputState {
        case .requestsDisabled: return .unavailable(.requestsDisabled)
        case .requesting: return .waitForRequest
        case .off, .notAllowed: return .requestThenLock
        case .allowed: return .unavailable(.notConnected)   // allowed but no live control: not requestable
        }
    }

    // MARK: Transitions

    /// The user tapped Lock Mac. Nothing is sent yet.
    mutating func begin(_ i: Inputs) {
        guard !isAwaiting else { return }
        enter(Self.path(for: i))
    }

    /// The user confirmed the dialog that was showing. If the situation changed under the
    /// dialog, the new path is shown for a fresh confirmation instead of acting on the old one.
    mutating func confirm(_ i: Inputs) -> [Effect] {
        guard case .confirming(let shown) = phase else { return [] }
        let now = Self.path(for: i)
        guard now == shown else { enter(now); return [] }
        switch now {
        case .lockNow:
            phase = .idle
            return [.lock]
        case .requestThenLock:
            phase = .awaitingControl(baseline: i.inputState, sawRequesting: false)
            return [.requestControl]
        case .waitForRequest:
            phase = .awaitingControl(baseline: .requesting, sawRequesting: true)
            return []
        case .unavailable(let why):
            phase = .notice(.unavailable(why))
            return []
        }
    }

    /// Cancel, dismiss, or stop waiting. Sends nothing.
    mutating func cancel() { phase = .idle }

    /// The session or control state changed.
    mutating func inputsChanged(_ i: Inputs) -> [Effect] {
        switch phase {
        case .confirming(let shown):
            let now = Self.path(for: i)
            if now != shown { enter(now) }
            return []
        case .awaitingControl(let baseline, let saw):
            guard i.canLock, i.connected else { phase = .notice(.disconnected); return [] }
            if i.controlGranted, i.inputState == .allowed {
                phase = .idle
                return [.lock]
            }
            switch i.inputState {
            case .requestsDisabled:
                phase = .notice(.declined)
            case .requesting:
                phase = .awaitingControl(baseline: baseline, sawRequesting: true)
            case .off, .notAllowed:
                if saw || i.inputState != baseline { phase = .notice(.declined) }
            case .allowed:
                break
            }
            return []
        case .idle, .notice:
            return []
        }
    }

    mutating func timedOut() {
        if isAwaiting { phase = .notice(.timedOut) }
    }

    private mutating func enter(_ path: Path) {
        if case .unavailable(let why) = path { phase = .notice(.unavailable(why)) } else { phase = .confirming(path) }
    }

    // MARK: Words

    var confirmTitle: String {
        switch confirmingPath {
        case .lockNow?: String(localized: "Lock the Mac?")
        case .requestThenLock?: String(localized: "Request Control and lock the Mac?")
        default: String(localized: "Lock the Mac when control is allowed?")
        }
    }

    var confirmMessage: String {
        switch confirmingPath {
        case .lockNow?:
            String(localized: "Anyone at the Mac will need its login password.")
        case .requestThenLock?:
            String(localized: "The Mac will ask to allow control from this device first. It locks only if you allow it there; anyone at the Mac will then need its login password.")
        default:
            String(localized: "A control request is already waiting on the Mac. It locks only if control is allowed there; anyone at the Mac will then need its login password.")
        }
    }

    var confirmButtonTitle: String {
        switch confirmingPath {
        case .lockNow?: String(localized: "Lock Mac")
        case .requestThenLock?: String(localized: "Request Control & Lock Mac")
        default: String(localized: "Lock Mac When Allowed")
        }
    }

    static func text(_ notice: Notice) -> String {
        switch notice {
        case .declined: String(localized: "The Mac didn't allow control. Nothing was locked.")
        case .disconnected: String(localized: "The connection ended before the Mac allowed control. Nothing was locked.")
        case .timedOut: String(localized: "The Mac didn't answer in time. Nothing was locked.")
        case .unavailable(.requestsDisabled):
            String(localized: "This Mac isn't accepting control requests from this device. Turn them on in the Mac's Input settings.")
        case .unavailable(.notConnected): String(localized: "Connect to a Mac first.")
        case .unavailable(.notSupported): String(localized: "This Mac can't be locked from here.")
        }
    }

    static let awaitingText = String(localized: "Waiting for the Mac to allow control…")
}
