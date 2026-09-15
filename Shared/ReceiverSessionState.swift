// ReceiverSessionState — the receiver's single, authoritative answer to
// "what is happening to my connection right now?".
//
// The receiver LISTENS; the Mac dials (see StreamReceiver). So a receiver-side
// "reconnect attempt" is not a dial: it is re-arming the listening side and
// waiting out a bounded window for the Mac's own redial (MacSender's
// scheduleReconnect + its 10s disconnect grace). That asymmetry is why this
// lives here as a pure policy object rather than as a second connection stack:
// there is exactly one transport implementation, and this only decides what
// the session *means* and what the UI must show.
//
// Deliberately pure and platform-free so the whole lifecycle is unit-testable
// (same shape as StreamListenerRestartState and CaptureLifecycleState).

import Foundation

/// Why a receiver session stopped being usable. Only some of these are worth
/// recovering from automatically — see `isAutomaticallyRecoverable`.
enum ReceiverSessionLossReason: String, Equatable {
    /// The socket died, the watchdog fired, or the peer vanished mid-session.
    case transportLost
    /// The listener itself could not be (re)established.
    case listenerFailed
    /// The Mac deliberately closed the session (quit, user disconnect).
    case peerClosed
    /// This device ended the session (stop, lock/sleep, app termination).
    case explicitDisconnect
    /// The peer speaks a protocol version we cannot work with.
    case protocolIncompatible

    /// Transport-shaped failures recover; intent and incompatibility do not.
    var isAutomaticallyRecoverable: Bool {
        switch self {
        case .transportLost, .listenerFailed: return true
        case .peerClosed, .explicitDisconnect, .protocolIncompatible: return false
        }
    }
}

/// The user-visible session phase. `paused` is intentional (the Mac paused
/// capture), `reconnecting` is automatic recovery, `reconnectFailed` is
/// recovery that gave up. They share a presentation, never a meaning.
enum ReceiverSessionPhase: String, Equatable {
    case disconnected
    case connecting
    case connected
    case paused
    case reconnecting
    case reconnectFailed
    case unrecoverable
}

/// What an interruption overlay should say. One presentation model for the
/// pause overlay and both reconnect states, so there is no second overlay
/// system and the two can never stack.
enum ReceiverSessionInterruption: Equatable {
    case paused
    case reconnecting
    case reconnectFailed
    case unrecoverable

    var title: String {
        switch self {
        case .paused: return "Display Paused"
        case .reconnecting: return "Reconnecting…"
        case .reconnectFailed: return "Connection Lost"
        case .unrecoverable: return "Can't Connect"
        }
    }

    var message: String {
        switch self {
        case .paused: return "Resume from OpenDisplay on your Mac."
        case .reconnecting: return "Trying to restore the connection to your Mac."
        case .reconnectFailed: return "We couldn't restore the connection."
        case .unrecoverable: return "This Mac and this device can't work together yet."
        }
    }

    /// Only a failed recovery offers a manual retry. Pause is the Mac's call,
    /// and an incompatible peer will never become compatible by retrying.
    var offersManualReconnect: Bool { self == .reconnectFailed }
}

struct ReceiverSessionState: Equatable {

    // Bounded recovery: 0.5 + 1 + 2 + 4 + 8 + 8 ≈ 23.5s of trying, which
    // comfortably outlives MacSender's own 10s disconnect grace and its 1s
    // redial cadence, and then stops rather than retrying forever.
    static let maximumReconnectAttempts = 6
    static let baseReconnectDelay: TimeInterval = 0.5
    static let maximumReconnectDelay: TimeInterval = 8

    private(set) var phase: ReceiverSessionPhase = .disconnected
    private(set) var lossReason: ReceiverSessionLossReason?
    /// Completed automatic attempts in the current recovery run.
    private(set) var reconnectAttempt = 0
    /// Bumped on every session replacement and every loss. Async work captures
    /// it and drops itself when it no longer matches — see StreamReceiver.
    private(set) var generation = 0
    private(set) var hasEverConnected = false
    /// Cleared by an explicit disconnect; re-armed by connecting or by a
    /// manual Reconnect. Stops a retry that is already scheduled from winning
    /// after the user deliberately ended the session.
    private(set) var automaticReconnectEnabled = true
    /// Guards against two simultaneous attempts for one recovery run.
    private(set) var reconnectAttemptInFlight = false

    // MARK: - Derived presentation

    /// True while the receiver surface (video, cursor, controls chrome) must
    /// stay on screen. Recovery must never flash back to the idle/discovery
    /// screen between retries.
    var retainsReceiverSurface: Bool {
        switch phase {
        case .connected, .paused, .reconnecting, .reconnectFailed, .unrecoverable:
            return true
        case .connecting:
            // A USB/AWDL/LAN migration replaces the connection underneath a
            // live logical session (MacSender.migrate / switchTransport): the
            // receiver adopts the newcomer and passes back through
            // `connecting`. That must not flash the idle screen. A genuine
            // first connect has never connected before — and has no video
            // geometry yet either — so it still shows the idle screen.
            return hasEverConnected
        case .disconnected:
            return false
        }
    }

    /// Live input may only reach the Mac on a fully established session.
    var allowsLiveInput: Bool { phase == .connected }

    var interruption: ReceiverSessionInterruption? {
        switch phase {
        case .paused: return .paused
        case .reconnecting: return .reconnecting
        case .reconnectFailed: return .reconnectFailed
        case .unrecoverable: return .unrecoverable
        case .connected, .connecting, .disconnected: return nil
        }
    }

    /// Delay before the next automatic attempt: exponential, capped.
    var nextReconnectDelay: TimeInterval {
        let scaled = Self.baseReconnectDelay * pow(2, Double(reconnectAttempt))
        return min(scaled, Self.maximumReconnectDelay)
    }

    var hasExhaustedReconnectAttempts: Bool {
        reconnectAttempt >= Self.maximumReconnectAttempts
    }

    // MARK: - Transitions
    //
    // Every mutating transition returns whether it actually changed anything,
    // so callers can log exactly one line per real transition.

    /// A candidate connection was adopted but has not proved itself yet.
    mutating func connectionAdopted() -> Bool {
        guard phase != .connecting else { return false }
        phase = .connecting
        lossReason = nil
        generation &+= 1
        reconnectAttemptInFlight = false
        return true
    }

    /// The connection is ready and the session is live.
    mutating func connectionEstablished() -> Bool {
        let changed = phase != .connected
        phase = .connected
        lossReason = nil
        reconnectAttempt = 0
        reconnectAttemptInFlight = false
        automaticReconnectEnabled = true
        hasEverConnected = true
        return changed
    }

    /// The Mac paused capture. Intentional: never starts recovery, and never
    /// overrides a recovery already under way.
    mutating func displayPaused() -> Bool {
        guard phase == .connected else { return false }
        phase = .paused
        return true
    }

    mutating func displayResumed() -> Bool {
        guard phase == .paused else { return false }
        phase = .connected
        return true
    }

    mutating func connectionLost(reason: ReceiverSessionLossReason) -> Bool {
        // An already-terminal state is not re-entered by a late callback, and
        // a duplicate loss report (a dying socket reports both a failed state
        // and an EOF) must not restart the run or orphan its pending retry.
        if reason.isAutomaticallyRecoverable,
           phase == .reconnectFailed || phase == .unrecoverable || phase == .reconnecting {
            return false
        }
        let previous = phase
        generation &+= 1
        reconnectAttemptInFlight = false

        switch reason {
        case .explicitDisconnect:
            automaticReconnectEnabled = false
            reconnectAttempt = 0
            phase = .disconnected
        case .protocolIncompatible:
            phase = .unrecoverable
        case .peerClosed:
            reconnectAttempt = 0
            phase = .disconnected
        case .transportLost, .listenerFailed:
            if hasEverConnected, automaticReconnectEnabled {
                reconnectAttempt = 0
                phase = .reconnecting
            } else {
                phase = .disconnected
            }
        }
        lossReason = reason
        return phase != previous
    }

    /// Start one automatic attempt. Returns the 1-based attempt number, or
    /// nil when recovery is over, disabled, or already has one in flight.
    mutating func beginReconnectAttempt() -> Int? {
        guard phase == .reconnecting, automaticReconnectEnabled,
              !reconnectAttemptInFlight,
              !hasExhaustedReconnectAttempts else { return nil }
        reconnectAttemptInFlight = true
        reconnectAttempt += 1
        return reconnectAttempt
    }

    /// The attempt's window elapsed without the Mac coming back.
    mutating func endReconnectAttempt() -> Bool {
        guard reconnectAttemptInFlight else { return false }
        reconnectAttemptInFlight = false
        return true
    }

    /// The budget is spent: settle into the stable "Connection Lost" state
    /// that offers a manual Reconnect instead of retrying forever.
    mutating func exhaustRecovery() -> Bool {
        guard phase == .reconnecting else { return false }
        phase = .reconnectFailed
        reconnectAttemptInFlight = false
        return true
    }

    /// The user tapped Reconnect. One clean run: budget reset, automatic
    /// recovery re-armed, straight back into the reconnecting presentation.
    mutating func requestManualReconnect() -> Bool {
        guard phase == .reconnectFailed || phase == .disconnected else { return false }
        phase = .reconnecting
        lossReason = .transportLost
        reconnectAttempt = 0
        reconnectAttemptInFlight = false
        automaticReconnectEnabled = true
        generation &+= 1
        return true
    }

    /// iOS took the app away. Recovery cannot run while suspended, so the
    /// budget is parked rather than burned — foregrounding resumes it.
    mutating func suspendRecoveryForBackground() -> Bool {
        guard phase == .reconnecting, reconnectAttemptInFlight else { return false }
        reconnectAttemptInFlight = false
        return true
    }
}
