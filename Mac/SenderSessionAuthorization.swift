import Foundation

// The Mac Sender's authority over ONE receiver pipeline, kept free of
// Network/ScreenCaptureKit so the rules `MacSender` enforces are directly
// testable. Four distinctions this file exists to keep explicit:
//
// * An authenticated transport is not an admitted session. Pinned TLS only
//   proves which key is on the other end; media, capture, input and
//   Mac-wide changes additionally need the session to be admitted.
// * Admission belongs to a connection, not to the logical session. Every
//   new transport/application generation (reconnect, route migration) must
//   prove the intended peer against its CURRENT pin again, and a pv 21+
//   receiver must accept the invitation again on that connection before
//   anything flows.
// * An input grant belongs to the connection it was granted on. Connection
//   B never inherits connection A's grant; the receiver has to ask again.
// * USB is only a route. A USB hello is held to exactly the same identity
//   and current-pin rule as TCP.

/// Identity check for an application `hello`, identical for every route.
enum SenderHelloVerification {
    enum Verdict: Equatable, Sendable {
        case verified
        /// The authenticated key is not (or no longer) the current pin of
        /// the peer this pipeline was built for.
        case trustRevokedOrChanged
        /// A pinned key claimed a different application identity (for
        /// example P's certificate announcing Q's install ID).
        case identityMismatch
    }

    static func verify(intendedPeerID: String, claimedPeerID: String?,
                       authenticatedSPKI: Data?, currentPinnedSPKI: Data?) -> Verdict {
        guard let claimedPeerID, claimedPeerID == intendedPeerID else { return .identityMismatch }
        return SenderApplicationAuthorization.isAllowed(
            intendedPeerID: intendedPeerID, authenticatedPeerID: claimedPeerID,
            authenticatedSPKI: authenticatedSPKI, currentPinnedSPKI: currentPinnedSPKI)
            ? .verified : .trustRevokedOrChanged
    }
}

/// What a receiver control message needs before the Mac acts on it.
enum SenderControlAuthority {
    enum Requirement: Equatable, Sendable {
        /// Handshake, liveness and teardown traffic, answered on any
        /// verified connection.
        case verifiedConnection
        /// Everything that changes what this Mac does for the receiver:
        /// input, display mode, video, streaming settings, Mirror source,
        /// Extend shape, frame-rate caps, wake promotion.
        case admittedSession
    }

    /// Deliberately an allow-list: a message type this build doesn't list
    /// (including any added later) needs an admitted session.
    private static let beforeAdmission: Set<String> = [
        "hello", "ping", "stats", "kf",
        WireMessage.sessionInviteResponse,
        WireMessage.sleeping,
        WireMessage.closing,
        // Answered with "not scrollable" until input is actually allowed,
        // so the receiver never waits out its fallback window.
        WireMessage.smartTouchProbe,
        // Only records the receiver's audio preference; audio frames are
        // gated like every other media frame.
        WireMessage.audioRequest,
    ]

    static func requirement(for type: String) -> Requirement {
        beforeAdmission.contains(type) ? .verifiedConnection : .admittedSession
    }
}

/// Pure state behind `SenderSessionAuthorization`. Generations are the
/// `AuthenticatedSessionState` transport generations `MacSender` already
/// stamps every connection with.
struct SenderSessionAuthorizationState: Equatable, Sendable {
    enum HelloOutcome: Equatable, Sendable {
        /// The hello proved the intended peer on the first connection of
        /// this logical session.
        case firstConnection
        /// The hello proved the intended peer on a later connection: the
        /// receiver must accept again before anything is admitted.
        case newConnection
        /// Another hello on an already verified connection (rotation,
        /// address change) — changes nothing.
        case sameConnection
        case rejected(SenderHelloVerification.Verdict)
        /// Not the live transport generation.
        case stale
    }

    /// Logical-session admission: the Sender's own decision and any
    /// refusal carry across connections; the receiver's acceptance does not
    /// (`SessionAdmissionGate.beginConnection`).
    private(set) var gate: SessionAdmissionGate?
    /// The Sender's decision when it arrived before the first hello.
    private var earlySenderDecision: Bool?
    /// The transport generation that is live right now, if any.
    private(set) var transportGeneration: UInt64?
    /// The live generation whose hello proved the intended peer.
    private(set) var verifiedGeneration: UInt64?
    private(set) var inputGrantGeneration: UInt64?
    /// Last generation reported by `consumeNewAdmission`.
    private var announcedAdmissionGeneration: UInt64?
    /// Whether any connection of this logical session was ever admitted —
    /// a re-sent invitation is then a background attempt.
    private(set) var everAdmitted = false

    init() {}

    /// Admitted on the live, verified connection.
    var isAdmitted: Bool {
        guard let verifiedGeneration, verifiedGeneration == transportGeneration,
              let gate else { return false }
        return gate.state == .admitted
    }

    func isAdmitted(generation: UInt64) -> Bool {
        isAdmitted && verifiedGeneration == generation
    }

    /// The generation capture and media currently belong to, if admitted.
    var admittedGeneration: UInt64? {
        isAdmitted ? verifiedGeneration : nil
    }

    /// The connection a capture (or virtual display) start may belong to:
    /// the requested generation if that is the live admitted connection;
    /// with no request (Video On, resume, recovery act for the session) the
    /// connection admitted right now. `nil` means the start must not happen.
    func captureOwner(requested: UInt64?) -> UInt64? {
        guard let owner = requested ?? admittedGeneration, isAdmitted(generation: owner) else { return nil }
        return owner
    }

    /// Whether a media frame (video, audio, cursor) may go out on the
    /// connection with this generation.
    func mayEmitMedia(on generation: UInt64) -> Bool {
        isAdmitted(generation: generation)
    }

    var hasInputGrant: Bool {
        isAdmitted && inputGrantGeneration != nil && inputGrantGeneration == verifiedGeneration
    }

    func inputAllowed(masterEnabled: Bool) -> Bool {
        EffectiveInputAuthorization.allowed(masterEnabled: masterEnabled, sessionGranted: hasInputGrant,
                                            sessionAdmitted: isAdmitted)
    }

    /// A new transport is ready. Nothing on it is verified or admitted yet,
    /// and the previous connection's input grant is gone. Returns whether a
    /// grant was dropped.
    @discardableResult
    mutating func transportBegan(generation: UInt64) -> Bool {
        transportGeneration = generation
        verifiedGeneration = nil
        return dropInputGrant()
    }

    /// The live transport ended or was invalidated. Returns whether a grant
    /// was dropped.
    @discardableResult
    mutating func transportEnded() -> Bool {
        transportGeneration = nil
        verifiedGeneration = nil
        return dropInputGrant()
    }

    /// Verifies a hello on `generation` and, only when it proves the
    /// intended peer against its current pin, records the connection. A
    /// rejected hello changes nothing: no readiness, no admission, and
    /// nothing a policy lookup could key on.
    mutating func acceptHello(generation: UInt64, intendedPeerID: String, claimedPeerID: String?,
                              authenticatedSPKI: Data?, currentPinnedSPKI: Data?,
                              receiverSupportsInvitations: Bool,
                              needsSenderApproval: Bool) -> HelloOutcome {
        guard let transportGeneration, transportGeneration == generation else { return .stale }
        let verdict = SenderHelloVerification.verify(
            intendedPeerID: intendedPeerID, claimedPeerID: claimedPeerID,
            authenticatedSPKI: authenticatedSPKI, currentPinnedSPKI: currentPinnedSPKI)
        guard verdict == .verified else { return .rejected(verdict) }
        if verifiedGeneration == generation { return .sameConnection }
        verifiedGeneration = generation
        guard var gate else {
            var fresh = SessionAdmissionGate(
                receiverSupportsInvitations: receiverSupportsInvitations,
                needsSenderApproval: needsSenderApproval && earlySenderDecision != true)
            if earlySenderDecision == false { fresh.senderDecided(accept: false) }
            self.gate = fresh
            return .firstConnection
        }
        gate.beginConnection(receiverSupportsInvitations: receiverSupportsInvitations)
        self.gate = gate
        return .newConnection
    }

    /// A `sessionInviteResponse` read off `generation`. Ignored unless that
    /// is the live, verified connection.
    @discardableResult
    mutating func receiverResponded(_ result: SessionInvitationResult, generation: UInt64) -> Bool {
        guard var gate, verifiedGeneration == generation, transportGeneration == generation else { return false }
        gate.receiverResponded(result)
        self.gate = gate
        return true
    }

    /// This Mac's user decided a receiver-initiated request. Safe before
    /// the first hello.
    mutating func senderDecided(accept: Bool) {
        guard var gate else {
            if earlySenderDecision != false { earlySenderDecision = accept }
            return
        }
        gate.senderDecided(accept: accept)
        self.gate = gate
    }

    /// Reports each newly admitted connection exactly once. `first` is true
    /// only for the first admission of the logical session.
    mutating func consumeNewAdmission() -> (generation: UInt64, first: Bool)? {
        guard let generation = admittedGeneration, announcedAdmissionGeneration != generation else { return nil }
        announcedAdmissionGeneration = generation
        let first = !everAdmitted
        everAdmitted = true
        return (generation, first)
    }

    /// Grants input to `generation` only if it is the live admitted
    /// connection — a decision made for an earlier connection is inert.
    mutating func grantInput(generation: UInt64) -> Bool {
        guard isAdmitted(generation: generation) else { return false }
        inputGrantGeneration = generation
        return true
    }

    /// Returns whether a grant was in effect.
    @discardableResult
    mutating func revokeInput() -> Bool {
        dropInputGrant()
    }

    private mutating func dropInputGrant() -> Bool {
        let had = inputGrantGeneration != nil
        inputGrantGeneration = nil
        return had
    }
}

/// Thread-safe owner of one pipeline's `SenderSessionAuthorizationState`.
/// `MacSender` reads it from its `queue`, from the ScreenCaptureKit and
/// VideoToolbox callbacks, from its capture-start tasks and from the
/// main-thread cursor poll, so every access goes through `lock` — the same
/// arrangement as `AuthenticatedSessionState`.
final class SenderSessionAuthorization {
    private let lock = NSLock()
    private var state = SenderSessionAuthorizationState()

    private func withState<T>(_ body: (inout SenderSessionAuthorizationState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    var snapshot: SenderSessionAuthorizationState { withState { $0 } }
    var isAdmitted: Bool { withState { $0.isAdmitted } }
    func isAdmitted(generation: UInt64) -> Bool { withState { $0.isAdmitted(generation: generation) } }
    var admittedGeneration: UInt64? { withState { $0.admittedGeneration } }
    func captureOwner(requested: UInt64?) -> UInt64? { withState { $0.captureOwner(requested: requested) } }
    func mayEmitMedia(on generation: UInt64) -> Bool { withState { $0.mayEmitMedia(on: generation) } }
    var hasInputGrant: Bool { withState { $0.hasInputGrant } }
    func inputAllowed(masterEnabled: Bool) -> Bool { withState { $0.inputAllowed(masterEnabled: masterEnabled) } }

    @discardableResult
    func transportBegan(generation: UInt64) -> Bool { withState { $0.transportBegan(generation: generation) } }
    @discardableResult
    func transportEnded() -> Bool { withState { $0.transportEnded() } }

    func acceptHello(generation: UInt64, intendedPeerID: String, claimedPeerID: String?,
                     authenticatedSPKI: Data?, currentPinnedSPKI: Data?,
                     receiverSupportsInvitations: Bool,
                     needsSenderApproval: Bool) -> SenderSessionAuthorizationState.HelloOutcome {
        withState {
            $0.acceptHello(generation: generation, intendedPeerID: intendedPeerID, claimedPeerID: claimedPeerID,
                           authenticatedSPKI: authenticatedSPKI, currentPinnedSPKI: currentPinnedSPKI,
                           receiverSupportsInvitations: receiverSupportsInvitations,
                           needsSenderApproval: needsSenderApproval)
        }
    }

    @discardableResult
    func receiverResponded(_ result: SessionInvitationResult, generation: UInt64) -> Bool {
        withState { $0.receiverResponded(result, generation: generation) }
    }

    func senderDecided(accept: Bool) { withState { $0.senderDecided(accept: accept) } }
    func consumeNewAdmission() -> (generation: UInt64, first: Bool)? { withState { $0.consumeNewAdmission() } }
    func grantInput(generation: UInt64) -> Bool { withState { $0.grantInput(generation: generation) } }
    @discardableResult
    func revokeInput() -> Bool { withState { $0.revokeInput() } }
}
