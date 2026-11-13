// WakeConnectAttempt — pure state/timing policy for the iOS "Wake & Connect"
// one-tap orchestration (WoL + receiver Connect request + authenticated
// reconnect + Promote Interactive Wake). Release feature: it drives
// `WakeConnectCoordinator` (Shared/WakeConnectCoordinator.swift), and every
// wire message it eventually triggers (`promoteInteractiveWake`) ships in
// Release too — see PROTOCOL.md. The manual test surfaces that exercise it
// by hand (WakeTestingView, RouteOverrides) remain Debug-only diagnostics.
//
// This is a UI/workflow projection layered ON TOP OF the canonical
// `ReceiverSessionState` connection state machine, never a replacement for
// it — see the coordinator for how the two are kept in sync. Deliberately
// pure and platform-free (same shape as `ReceiverSessionState`) so the whole
// lifecycle is unit-testable without real WoL/Bonjour/WindowServer networking.
import Foundation

/// The one-tap flow's own bounded stages — see RTK/`WakeConnectCoordinator`
/// doc comments for how each stage maps to real network/session events.
enum WakeConnectStage: Equatable {
    case idle
    case preparing
    case waking
    case waitingForConnection
    case authenticating
    case promoting
    case waitingForVideo
    case connected
    case failed(String)

    var isActive: Bool {
        switch self {
        case .idle, .connected, .failed: return false
        default: return true
        }
    }
}

/// What the coordinator does when the receiver session reports a phase that
/// means the connection is gone (see `WakeConnectAttempt.lossAction`).
enum WakeConnectLossAction: Equatable {
    /// This device ended the session: the attempt is over and its Connect
    /// request is withdrawn.
    case endAttempt
    /// The transport dropped: fall back to waking and ask the Mac again.
    case connectionLostAndRenew
    /// The session gave up or the Mac closed it: fall back to waking.
    case connectionLost
}

struct WakeConnectAttempt: Equatable {
    // Send a short burst rather than a single packet or an unbounded loop —
    // "a few magic packets over roughly 1–2 seconds" per the orchestration spec.
    static let maxWOLBursts = 3
    static let wolBurstInterval: TimeInterval = 0.6
    // The underlying one-shot `cr` receiver-connect token expires after ~8s
    // (see `StreamReceiver.signalConnectRequest`); refresh comfortably before
    // that so a Mac that takes longer than one token lifetime to return from
    // sleep still sees a live request once its Bonjour browser comes back.
    static let connectTokenRefreshInterval: TimeInterval = 5
    // Promote is tied to authenticated readiness and must never be spammed
    // once it has succeeded for a generation — bounded retries only guard
    // against a lost reply/transient failure while waking.
    static let maxPromoteAttempts = 3
    static let promoteRetryInterval: TimeInterval = 3
    static let overallTimeout: TimeInterval = 40
    // A Mac that dialed in answers (and so ends) this device's Connect
    // request. If that session then drops while the attempt is still running
    // (the Mac was reachable but could not start yet, #255), the request is
    // asked again, at most this many times per attempt.
    static let maxConnectRequestRenewals = 3

    private(set) var stage: WakeConnectStage = .idle
    private(set) var attemptID: UInt64 = 0
    private(set) var peerID: String?
    private(set) var wolBurstsSent = 0
    private(set) var connectRequestRenewals = 0
    /// A session reached this attempt and was then lost: the Connect request
    /// it answered is gone and may be asked again (`shouldRenewConnectRequest`).
    private(set) var connectRequestAnswered = false
    /// The `ReceiverSessionState.generation` Promote is currently armed for.
    /// Reset whenever a new generation authenticates so a stale generation's
    /// leftover attempt count can never suppress a fresh one's first attempt.
    private(set) var promoteGeneration: Int?
    private(set) var promoteAttemptsThisGeneration = 0
    /// The generation Promote has already succeeded for — once set, Promote
    /// is never sent again for that same generation (DO NOT SPAM PROMOTE).
    private(set) var promoteSucceededGeneration: Int?

    var isActive: Bool { stage.isActive }

    /// A session has reached this attempt (transport adopted or beyond) and
    /// the attempt is still working on it.
    var hasSession: Bool {
        switch stage {
        case .authenticating, .promoting, .waitingForVideo: return true
        default: return false
        }
    }

    /// How an active attempt reacts to a session that is gone. `nil` for phases
    /// that are not a loss, or when the attempt is not active.
    func lossAction(phase: ReceiverSessionPhase,
                    lossReason: ReceiverSessionLossReason?) -> WakeConnectLossAction? {
        guard isActive else { return nil }
        switch phase {
        case .disconnected:
            return hasSession ? .endAttempt : .connectionLost
        case .reconnecting:
            return .connectionLostAndRenew
        case .reconnectFailed, .peerDisconnected:
            return .connectionLost
        case .connecting, .connected, .paused, .unrecoverable:
            return nil
        }
    }

    // MARK: - Transitions
    //
    // Every mutating transition returns whether it actually changed
    // anything, mirroring ReceiverSessionState's contract — one log line per
    // real transition, not per call.

    @discardableResult
    mutating func begin(peerID: String) -> UInt64 {
        attemptID &+= 1
        self.peerID = peerID
        stage = .preparing
        wolBurstsSent = 0
        connectRequestRenewals = 0
        connectRequestAnswered = false
        promoteGeneration = nil
        promoteAttemptsThisGeneration = 0
        promoteSucceededGeneration = nil
        return attemptID
    }

    mutating func connectRequestPublished() -> Bool {
        guard stage == .preparing else { return false }
        stage = .waking
        return true
    }

    /// Bounded: refuses once `maxWOLBursts` have been recorded for this
    /// attempt, even across a `connectionLost` fallback back to `.waking`.
    /// Accepts both `.waking` (before the first packet) and
    /// `.waitingForConnection` (after `beginWaitingForConnection()` has
    /// already fired once) — the burst's 2nd/3rd packets are sent from
    /// `.waitingForConnection`, since the very first `recordWOLSent()` call
    /// is what drives that transition. Requiring `.waking` alone here was a
    /// bug: it silently capped every burst at 1 packet instead of 3.
    @discardableResult
    mutating func recordWOLSent() -> Bool {
        guard stage == .waking || stage == .waitingForConnection,
              wolBurstsSent < Self.maxWOLBursts else { return false }
        wolBurstsSent += 1
        return true
    }

    mutating func beginWaitingForConnection() -> Bool {
        guard stage == .waking else { return false }
        stage = .waitingForConnection
        return true
    }

    /// A candidate transport connection was adopted but not yet
    /// authenticated (`ReceiverSessionState.phase == .connecting`).
    mutating func transportReady() -> Bool {
        guard stage == .waking || stage == .waitingForConnection else { return false }
        stage = .authenticating
        return true
    }

    /// The MEOW application handshake completed
    /// (`ReceiverSessionState.phase == .connected`). `peerID` must match the
    /// peer this attempt was begun for — a differently-paired Mac dialing in
    /// while this attempt is active must never be mistaken for the one it
    /// woke. Skips straight to `.waitingForVideo` if Promote already
    /// succeeded for this exact generation (e.g. a brief transport blip
    /// right after a successful Promote).
    mutating func applicationAuthenticated(generation: Int, peerID: String) -> Bool {
        guard isActive, peerID == self.peerID else { return false }
        if promoteGeneration != generation {
            promoteGeneration = generation
            promoteAttemptsThisGeneration = 0
        }
        stage = (promoteSucceededGeneration == generation) ? .waitingForVideo : .promoting
        return true
    }

    /// Bounded and generation-scoped: refuses once the current generation's
    /// retry budget is spent, or once it has already succeeded.
    @discardableResult
    mutating func shouldSendPromote() -> Bool {
        guard stage == .promoting, let generation = promoteGeneration,
              promoteSucceededGeneration != generation,
              promoteAttemptsThisGeneration < Self.maxPromoteAttempts else { return false }
        promoteAttemptsThisGeneration += 1
        return true
    }

    mutating func promoteSucceeded(generation: Int) -> Bool {
        guard stage == .promoting, promoteGeneration == generation else { return false }
        promoteSucceededGeneration = generation
        stage = .waitingForVideo
        return true
    }

    /// The existing fresh-SCK wake recovery produced a first frame (or video
    /// was already flowing — see `MAC ALREADY AWAKE`).
    mutating func videoReady() -> Bool {
        guard stage == .promoting || stage == .waitingForVideo else { return false }
        stage = .connected
        return true
    }

    /// The underlying session dropped back to reconnecting/disconnected
    /// while this attempt is still active (e.g. the Mac hasn't finished
    /// waking yet). Falls back to `.waking` so WoL/token-refresh resume —
    /// `wolBurstsSent` is NOT reset, keeping the whole attempt bounded.
    mutating func connectionLost() -> Bool {
        guard isActive else { return false }
        if hasSession { connectRequestAnswered = true }
        stage = .waking
        return true
    }

    /// Whether to ask the Mac to dial again after a session this attempt had
    /// reached was lost. Once per lost session (the recovery run the new
    /// request starts reports "reconnecting" again, which must not ask
    /// twice), and bounded by `maxConnectRequestRenewals` for the attempt.
    mutating func shouldRenewConnectRequest() -> Bool {
        guard stage == .waking, connectRequestAnswered,
              connectRequestRenewals < Self.maxConnectRequestRenewals else { return false }
        connectRequestAnswered = false
        connectRequestRenewals += 1
        return true
    }

    /// One reason string for every terminal failure (`timedOut`,
    /// `cancelled`, or a peer-reported incompatibility) — the coordinator
    /// logs the specific reason at the call site.
    mutating func fail(_ reason: String) -> Bool {
        guard isActive else { return false }
        stage = .failed(reason)
        return true
    }
}
