import Foundation

/// What a Known Devices row says about this Mac's sessions for that device
/// (issue #128). Active Display lists only sessions that completed the
/// application hello, so before this a dial that never got that far had no
/// row, no status and no Cancel, and the device's row kept offering a
/// Connect that the pending session silently absorbed.
enum KnownDeviceConnection: Equatable, Sendable {
    case idle
    /// Dialing, before the application hello. `status` is the sender's own
    /// progress text ("Waiting for receiver…", "open the MeowDisplay app",
    /// the Local Network hint). `automatic`: an attempt this Mac started on
    /// its own (Auto-Connect), not one somebody asked for.
    case connecting(sessionID: String, status: String, automatic: Bool)
    /// Hello done; the invitation still waits for an answer.
    case awaitingApproval(sessionID: String)
    case connected(sessionID: String)
    /// The last attempt ended without a session: declined, blocked, timed
    /// out or a startup failure. Connect is offered again.
    case failed(sessionID: String, status: String)

    /// The session that holds this device's row. While there is one the row
    /// offers no plain Connect (it would only be absorbed); `connecting`
    /// offers Cancel instead, and an automatic attempt also a Connect that
    /// replaces it (`KnownDeviceRowActions`).
    var occupyingSessionID: String? {
        switch self {
        case .connecting(let id, _, _), .awaitingApproval(let id), .connected(let id): return id
        case .idle, .failed: return nil
        }
    }
}

/// Which actions a Known Devices row offers for its `KnownDeviceConnection`
/// (issue #128). An automatic attempt is still dialing on its own, so the
/// user's explicit Connect must stay reachable: `explicitConnect(to:)` replaces
/// it (`ExplicitConnectAdmission`). An explicit attempt in progress offers
/// only Cancel, so a second Connect can't duplicate its prompt.
struct KnownDeviceRowActions: Equatable, Sendable {
    /// The Connect control (with its Mirror/Extend menu) is shown.
    let offersConnect: Bool
    /// That Connect replaces an automatic attempt still in progress.
    let connectReplacesAutomaticAttempt: Bool
    /// Cancel for the dial in progress is shown.
    let offersCancel: Bool

    /// - Parameter hasTarget: a route to the device is currently resolvable;
    ///   without one there is nothing to connect to.
    static func actions(for connection: KnownDeviceConnection, hasTarget: Bool) -> KnownDeviceRowActions {
        switch connection {
        case .idle, .failed:
            return .init(offersConnect: hasTarget, connectReplacesAutomaticAttempt: false, offersCancel: false)
        case .connecting(_, _, let automatic):
            return .init(offersConnect: automatic && hasTarget, connectReplacesAutomaticAttempt: automatic && hasTarget,
                         offersCancel: true)
        case .awaitingApproval, .connected:
            return .init(offersConnect: false, connectReplacesAutomaticAttempt: false, offersCancel: false)
        }
    }

    /// Whether the row needs its resolved route: it is not held by a session,
    /// or the session holding it is an automatic attempt Connect may replace.
    static func needsTarget(for connection: KnownDeviceConnection) -> Bool {
        switch connection {
        case .idle, .failed: return true
        case .connecting(_, _, let automatic): return automatic
        case .awaitingApproval, .connected: return false
        }
    }
}

enum PendingConnectPolicy {
    /// What the policy needs from one `DeviceSession`.
    struct SessionSnapshot: Equatable, Sendable {
        let id: String
        /// Proven by the hello; nil before it.
        let deviceID: String?
        /// The pinned peer the dial was aimed at. Only used to place the
        /// pending attempt on that peer's row, never for trust: the dial
        /// itself still has to pass that peer's pinned TLS.
        let intendedPeerID: String?
        let authenticated: Bool
        let admitted: Bool
        let failed: Bool
        let status: String
        /// An attempt this Mac started on its own that an explicit Connect
        /// replaces (`replacedByExplicitConnect`). Only then does the row
        /// offer Connect Now.
        let automatic: Bool

        /// The row's `automatic`, from the same rule the tap goes through
        /// (`ExplicitConnectAdmission`): a sender-initiated `automatic`
        /// invitation that isn't admitted, failed or a continuation. A
        /// continuation of such an attempt (a Mac-wide rebuild) still carries
        /// the automatic invitation, but the admission keeps it, so a Connect
        /// Now there would be absorbed and do nothing.
        static func replacedByExplicitConnect(failed: Bool, admitted: Bool, invitation: SessionInvitation,
                                              isContinuation: Bool) -> Bool {
            ExplicitConnectAdmission.decide(existing: .init(failed: failed, admitted: admitted, invitation: invitation,
                                                            isContinuation: isContinuation)) == .replace
        }
    }

    /// The row state for `peerID`. A working session wins over a pending
    /// one, and either over a failed corpse; among failures the newest one
    /// (latest in `sessions`) speaks.
    static func connection(forPeerID peerID: String, sessions: [SessionSnapshot]) -> KnownDeviceConnection {
        let mine = sessions.filter { session in
            if let deviceID = session.deviceID { return deviceID == peerID }
            return session.intendedPeerID == peerID
        }
        if let live = mine.first(where: { !$0.failed && $0.authenticated && $0.admitted }) {
            return .connected(sessionID: live.id)
        }
        if let waiting = mine.first(where: { !$0.failed && $0.authenticated }) {
            return .awaitingApproval(sessionID: waiting.id)
        }
        if let dialing = mine.first(where: { !$0.failed }) {
            return .connecting(sessionID: dialing.id, status: dialing.status, automatic: dialing.automatic)
        }
        if let failed = mine.last {
            return .failed(sessionID: failed.id, status: failed.status)
        }
        return .idle
    }

    /// How long an explicit Connect may dial before giving up when it never
    /// reaches the hello. Each dial already has its own 5 s deadline
    /// (`MacSender.connectTCP`) and redials back off to 10 s, so this is
    /// several attempts: enough to unlock the iPhone or bring the app
    /// forward, short enough that a dead address stops being retried.
    static let explicitFirstConnectLimit: TimeInterval = 45

    /// Only an explicit attempt is bounded. Wake & Connect must keep
    /// redialing while the Mac wakes, and an automatic attempt is already
    /// replaced or cancelled from its row.
    static func boundsFirstConnect(userInitiated: Bool, awaitingWake: Bool) -> Bool {
        userInitiated && !awaitingWake
    }

    /// At the deadline: give up only on a session that is still before the
    /// hello and hasn't already failed for its own reason.
    static func shouldGiveUp(authenticated: Bool, failed: Bool) -> Bool {
        !authenticated && !failed
    }

    static func timeoutStatus(name: String, lastStatus: String) -> String {
        let detail = lastStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = String(localized: "Couldn't reach \(name). Make sure MeowDisplay is open on it, then try again.")
        guard !detail.isEmpty, detail != "Starting…" else { return base }
        return base + " " + String(localized: "Last status: \(detail)")
    }
}
