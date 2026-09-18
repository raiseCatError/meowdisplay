import Foundation

/// Persisted, per-peer policy for how the Mac responds to a receiver-
/// originated control request — the permanent half of the milestone's two-
/// layer model (see `ReceiverInputAuthorizationStore`). Never implies a
/// live grant by itself: `.alwaysAllow` only means "skip the Mac prompt and
/// auto-grant THIS SESSION when the receiver explicitly asks," never
/// "input turns on when this device connects." A brand-new logical session
/// always starts with no session grant regardless of this policy.
enum PeerInputRequestPolicy: String, Codable, Equatable {
    /// Show the Mac owner a prompt for every new session's control request.
    case ask
    /// Auto-grant a session's control request without a Mac prompt.
    case alwaysAllow
    /// Deny a session's control request without a Mac prompt.
    case neverAllow
}

/// The Mac owner's resolution of a control-request prompt.
enum InputControlRequestDecision: Equatable {
    case notNow
    case allowSession
    case neverAllowRequests
    case alwaysAllowDevice
}

/// The ordered actions a resolved decision requires, computed BEFORE any of
/// them run — this is the fix for a real bug where applying them in the
/// natural top-to-bottom order (grant the session, then persist the policy)
/// let `.alwaysAllowDevice` defeat its own self-authorization guard:
/// granting first makes THIS session's own grant satisfy `anySessionHas
/// EffectiveInput`, so `ReceiverInputAuthorizationStore.setPolicy` (correctly)
/// refused the widening it was never supposed to allow — a receiver's own
/// live input appearing to authorize itself. `persistPolicy`, when present,
/// MUST be applied first, while the requesting session's own grant is still
/// false, so the guard only ever sees whatever OTHER sessions are already
/// controlling the Mac — never this one. `grantSession` is independent of
/// whether that persistence succeeds: the decision came from an explicit
/// local action at the Mac, so this request still gets what it asked for
/// even if the permanent promotion was refused (e.g. another peer currently
/// has effective input).
struct InputControlRequestPlan: Equatable {
    let persistPolicy: PeerInputRequestPolicy?
    let grantSession: Bool
    let denyState: SessionInputWireState?

    static func plan(for decision: InputControlRequestDecision) -> InputControlRequestPlan {
        switch decision {
        case .notNow:
            return InputControlRequestPlan(persistPolicy: nil, grantSession: false, denyState: .notAllowed)
        case .allowSession:
            return InputControlRequestPlan(persistPolicy: nil, grantSession: true, denyState: nil)
        case .neverAllowRequests:
            return InputControlRequestPlan(persistPolicy: .neverAllow, grantSession: false, denyState: .requestsDisabled)
        case .alwaysAllowDevice:
            return InputControlRequestPlan(persistPolicy: .alwaysAllow, grantSession: true, denyState: nil)
        }
    }
}

/// Pure per-session request lifecycle: at most one pending request, a
/// cooldown after "Not Now"/timeout so a receiver can't spam the Mac owner
/// with prompts, and a generation counter so a stale async decision or
/// timeout (from a superseded request, or one this session already
/// resolved) can never resolve/grant a newer request. Mirrors
/// `DisplayModeRequestState`'s `pendingGeneration` pattern in
/// `Shared/Protocol.swift`.
struct InputControlRequestLifecycle: Equatable {
    static let cooldown: TimeInterval = 30
    static let timeout: TimeInterval = 45

    private(set) var isPending = false
    private(set) var generation = 0
    private(set) var cooldownUntil: Date?

    /// Returns the generation to prompt for, or nil if this request must be
    /// dropped: a duplicate packet while one is already pending coalesces
    /// into the existing prompt, and a request arriving during the post-
    /// "Not Now"/timeout cooldown is suppressed entirely (no new prompt).
    mutating func beginRequest(now: Date = Date()) -> Int? {
        guard !isPending else { return nil }
        if let cooldownUntil, now < cooldownUntil { return nil }
        generation &+= 1
        isPending = true
        return generation
    }

    /// A Mac-owner decision arrived for `generation` — including a prompt
    /// timeout, which the presenting model (`InputControlRequestPromptModel`)
    /// surfaces as `.notNow`, exactly like an explicit Not Now. Returns
    /// false — the caller must not act on it — if this isn't the generation
    /// currently pending (stale/superseded).
    @discardableResult
    mutating func resolve(generation: Int, decision: InputControlRequestDecision, now: Date = Date()) -> Bool {
        guard isPending, generation == self.generation else { return false }
        isPending = false
        if decision == .notNow {
            cooldownUntil = now.addingTimeInterval(Self.cooldown)
        }
        return true
    }

    /// True session end (disconnect, Forget, teardown): no stale request or
    /// callback may outlive it, and the very next connection starts clean.
    mutating func reset() {
        isPending = false
        generation &+= 1
        cooldownUntil = nil
    }
}

/// effectiveInput = macMasterAllowsInput AND thisSession'sGrant — the one
/// formula every input-gate choke point evaluates (`MacSender.
/// receiverInputIsAllowed`/`receiverKeyboardInputIsAllowed`, `InputInjector.
/// inputIsAllowed`). A master OFF instantly zeroes every session's
/// effective input without touching any session's own grant bit, so
/// turning the master back on during the same session can resume a
/// previously granted session with no fresh request.
enum EffectiveInputAuthorization {
    static func allowed(masterEnabled: Bool, sessionGranted: Bool) -> Bool {
        masterEnabled && sessionGranted
    }
}

/// Thread-safe box for one session's ephemeral input grant, shared between
/// `MacSender` (which owns the control-message-level gate, on its own
/// `queue`) and `InputInjector` (which re-checks under its own lock at
/// event-injection time — see `InputInjector.inputIsAllowed`'s doc comment
/// for why that duplication is deliberate). A plain `Bool` on either object
/// would let one race the other; both read/write through this single lock
/// instead. Lives exactly as long as its owning `MacSender`/`DeviceSession`
/// — there is no persistence here, and no separate teardown path is needed:
/// when the logical session ends, this box is deallocated with it.
final class SessionInputGrantBox {
    private var granted = false
    private let lock = NSLock()

    func set(_ value: Bool) {
        lock.lock()
        granted = value
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return granted
    }
}

/// Identifies one live control-request prompt so a resolution/timeout can
/// be matched back to the exact session/generation it was raised for, even
/// after the prompt panel is presented asynchronously.
struct PendingInputControlRequest: Identifiable, Equatable {
    let id: String          // DeviceSession.id
    let peerID: String
    let name: String
    let generation: Int
}
