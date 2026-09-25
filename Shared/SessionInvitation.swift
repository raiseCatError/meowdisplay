import Foundation

// Trusted-device session invitations (pv 21). Pure, platform-neutral logic
// shared by the Mac Sender, the iPhone/iPad Receiver and the Mac Receiver so
// the hostless test target can cover all of it.
//
// Two distinctions this file exists to keep explicit:
//
// * **Session initiator != stream sender.** Either endpoint may ask for a
//   session, but the Mac Sender is always the video/audio source and the
//   receiver always consumes it. `SessionInvitation.initiator` records who
//   asked; it never decides stream direction.
// * **Connection approval != input approval.** Nothing here grants remote
//   input. Every session still starts with input OFF and the Mac Sender's
//   own per-session "Allow Input" consent (`Mac/InputControlConsent.swift`)
//   is the only way to turn it on.

/// One endpoint's part in a single display session.
enum SessionRole: String, Codable, Equatable, Sendable {
    /// The Mac Sender: produces display video, audio, and owns Mirror/Extend.
    case sender
    /// iPhone, iPad, or Mac Receiver: shows the stream and may send input.
    case receiver
}

/// Whether a session attempt came from an explicit user action or from
/// background behavior (Auto-Connect, Auto-Reconnect, a transport redial).
/// Carried explicitly on the wire — never inferred from timing — because it
/// decides whether a manual-approval policy may show a prompt at all.
enum SessionInvitationIntent: String, Codable, Equatable, Sendable {
    case manual
    case automatic
}

/// The receiving endpoint's answer to a `sessionInvite`.
enum SessionInvitationResult: String, Codable, Equatable, Sendable {
    /// The receiver will display this session.
    case accepted
    /// The receiver is asking its user; a final answer follows.
    case pending
    /// Rejected for this attempt only (user choice, timeout, or a background
    /// attempt that would have needed a prompt).
    case declined
    /// This paired sender's invitations are blocked on the receiver. Carries
    /// no more detail than `declined` needs to, beyond telling the sender to
    /// stop retrying automatically.
    case blocked
    /// The receiver-side initiator withdrew its own request.
    case cancelled
}

/// A display session invitation. Sent by the Mac Sender (the only dialer,
/// PROTOCOL.md §1) on every application handshake with a pv 21+ receiver,
/// whichever side initiated. The `id` is unique per logical session and is
/// reused unchanged across in-place reconnects so the receiver can recognize
/// a session it already accepted.
struct SessionInvitation: Equatable, Sendable {
    let id: String
    let initiator: SessionRole
    var intent: SessionInvitationIntent
    /// The Mac Sender's intended display mode. The Sender owns Mirror/Extend;
    /// the receiver only sees it as context.
    var mode: ReceiverDisplayMode
    /// True while a receiver-initiated request is still waiting for the Mac
    /// Sender's own user to approve it — the receiver shows a waiting state.
    var awaitingSenderApproval: Bool

    init(id: String = UUID().uuidString, initiator: SessionRole, intent: SessionInvitationIntent,
         mode: ReceiverDisplayMode, awaitingSenderApproval: Bool = false) {
        self.id = id
        self.initiator = initiator
        self.intent = intent
        self.mode = mode
        self.awaitingSenderApproval = awaitingSenderApproval
    }

    /// Stream direction is fixed by role, never by who initiated.
    static let streamSource: SessionRole = .sender
    static let streamDestination: SessionRole = .receiver

    var message: [String: Any] {
        [
            "type": WireMessage.sessionInvite,
            "id": id,
            "initiator": initiator.rawValue,
            "intent": intent.rawValue,
            "mode": mode.rawValue,
            "awaitingSender": awaitingSenderApproval,
        ]
    }

    init?(message: [String: Any]) {
        guard message["type"] as? String == WireMessage.sessionInvite,
              let id = message["id"] as? String, !id.isEmpty, id.count <= 64,
              let initiator = (message["initiator"] as? String).flatMap(SessionRole.init(rawValue:)),
              let intent = (message["intent"] as? String).flatMap(SessionInvitationIntent.init(rawValue:)),
              let mode = (message["mode"] as? String).flatMap(ReceiverDisplayMode.init(rawValue:)) else {
            return nil
        }
        self.init(id: id, initiator: initiator, intent: intent, mode: mode,
                  awaitingSenderApproval: message["awaitingSender"] as? Bool ?? false)
    }
}

/// `sessionInviteResponse` (receiver -> Mac Sender).
struct SessionInvitationResponse: Equatable, Sendable {
    let id: String
    let result: SessionInvitationResult

    var message: [String: Any] {
        ["type": WireMessage.sessionInviteResponse, "id": id, "result": result.rawValue]
    }

    init(id: String, result: SessionInvitationResult) {
        self.id = id
        self.result = result
    }

    init?(message: [String: Any]) {
        guard message["type"] as? String == WireMessage.sessionInviteResponse,
              let id = message["id"] as? String,
              let result = (message["result"] as? String).flatMap(SessionInvitationResult.init(rawValue:)) else {
            return nil
        }
        self.init(id: id, result: result)
    }
}

// MARK: - Incoming policy

/// Persistent per-peer override of the global incoming-invitation preference.
/// Absent means "Default" (inherit the global preference).
enum IncomingSessionPeerPolicy: String, Codable, Equatable, Sendable {
    case alwaysAllow
    case blocked
}

/// What the endpoint receiving an invitation should do with it.
enum IncomingSessionDecision: Equatable, Sendable {
    case accept
    /// Explicit request that needs this endpoint's user to decide.
    case askUser
    /// Background attempt that would have needed a prompt: decline quietly.
    case decline
    case block
}

enum IncomingSessionPolicy {
    /// The required policy matrix: Blocked always rejects; Always Allow always
    /// accepts; Default follows the global preference, and with the global
    /// preference off only an explicit request may prompt — a background
    /// attempt never manufactures a prompt.
    static func resolve(peerPolicy: IncomingSessionPeerPolicy?, automaticallyAllow: Bool,
                        intent: SessionInvitationIntent) -> IncomingSessionDecision {
        switch peerPolicy {
        case .blocked: return .block
        case .alwaysAllow: return .accept
        case nil:
            if automaticallyAllow { return .accept }
            return intent == .manual ? .askUser : .decline
        }
    }
}

/// Persistent incoming-invitation policy, keyed only by the stable peer
/// install ID `TrustStore` pins (never a name, address, or unauthenticated
/// claim). Stores exactly two things: the global "Automatically Allow
/// Connections" preference and per-peer overrides. Pending requests, one-off
/// rejections, chosen display modes and input permission are deliberately
/// never stored here. Forget/unpair must call `removePolicy(peerID:)`.
enum IncomingSessionPolicyStore {
    static let automaticallyAllowKey = "incomingSessionAutomaticallyAllow"
    private static let policiesKey = "incomingSessionPeerPolicy.v1"

    /// Defaults to ON.
    static func automaticallyAllow(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticallyAllowKey) as? Bool ?? true
    }

    static func setAutomaticallyAllow(_ value: Bool, defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: automaticallyAllowKey)
    }

    static func policy(peerID: String, defaults: UserDefaults = .standard) -> IncomingSessionPeerPolicy? {
        (defaults.dictionary(forKey: policiesKey)?[peerID] as? String).flatMap(IncomingSessionPeerPolicy.init(rawValue:))
    }

    /// `nil` returns the peer to Default.
    static func setPolicy(_ policy: IncomingSessionPeerPolicy?, peerID: String, defaults: UserDefaults = .standard) {
        var policies = defaults.dictionary(forKey: policiesKey) as? [String: String] ?? [:]
        policies[peerID] = policy?.rawValue
        defaults.set(policies, forKey: policiesKey)
    }

    static func removePolicy(peerID: String, defaults: UserDefaults = .standard) {
        setPolicy(nil, peerID: peerID, defaults: defaults)
    }

    static func decision(peerID: String?, intent: SessionInvitationIntent,
                         defaults: UserDefaults = .standard) -> IncomingSessionDecision {
        let decision = IncomingSessionPolicy.resolve(
            peerPolicy: peerID.flatMap { policy(peerID: $0, defaults: defaults) },
            automaticallyAllow: automaticallyAllow(defaults: defaults), intent: intent)
        // Without an authenticated identity there is nobody to name in a
        // prompt and no per-device policy to apply: never ask.
        if peerID == nil, decision == .askUser { return .decline }
        return decision
    }
}

// MARK: - Approval decisions

/// Actions when the Mac Sender approves a receiver-initiated request.
enum SenderApprovalDecision: Equatable, Sendable {
    case rejectPermanently
    case rejectForSession
    case allowMirror
    case allowExtend
    case allowPermanently
}

/// Actions when a receiver approves a Sender-initiated invitation. No mode
/// choice: the Sender already chose it.
enum ReceiverApprovalDecision: Equatable, Sendable {
    case rejectPermanently
    case rejectForSession
    case allow
    case allowPermanently
}

/// What a resolved approval must do. `persistPolicy` only ever records the
/// connection policy — never a display mode and never input permission.
struct SessionApprovalPlan: Equatable, Sendable {
    let accept: Bool
    let persistPolicy: IncomingSessionPeerPolicy?
    /// `nil` keeps the invitation's requested mode.
    let mode: ReceiverDisplayMode?
    let result: SessionInvitationResult

    static func plan(for decision: SenderApprovalDecision) -> SessionApprovalPlan {
        switch decision {
        case .rejectPermanently:
            return SessionApprovalPlan(accept: false, persistPolicy: .blocked, mode: nil, result: .blocked)
        case .rejectForSession:
            return SessionApprovalPlan(accept: false, persistPolicy: nil, mode: nil, result: .declined)
        case .allowMirror:
            return SessionApprovalPlan(accept: true, persistPolicy: nil, mode: .mirror, result: .accepted)
        case .allowExtend:
            return SessionApprovalPlan(accept: true, persistPolicy: nil, mode: .extend, result: .accepted)
        case .allowPermanently:
            return SessionApprovalPlan(accept: true, persistPolicy: .alwaysAllow, mode: nil, result: .accepted)
        }
    }

    static func plan(for decision: ReceiverApprovalDecision) -> SessionApprovalPlan {
        switch decision {
        case .rejectPermanently:
            return SessionApprovalPlan(accept: false, persistPolicy: .blocked, mode: nil, result: .blocked)
        case .rejectForSession:
            return SessionApprovalPlan(accept: false, persistPolicy: nil, mode: nil, result: .declined)
        case .allow:
            return SessionApprovalPlan(accept: true, persistPolicy: nil, mode: nil, result: .accepted)
        case .allowPermanently:
            return SessionApprovalPlan(accept: true, persistPolicy: .alwaysAllow, mode: nil, result: .accepted)
        }
    }
}

// MARK: - Display mode planning

/// Which Mirror/Extend a session uses. The Mac Sender is the final authority:
/// its user's explicit approval choice wins, then the receiver's requested
/// mode, then the Mac's current mode (older receivers never send one). Never
/// persisted with Always Allow.
enum SessionModePlanning {
    static func mode(senderChoice: ReceiverDisplayMode?, receiverRequested: ReceiverDisplayMode?,
                     current: ReceiverDisplayMode) -> ReceiverDisplayMode {
        senderChoice ?? receiverRequested ?? current
    }

    /// Parses `hello.requestedMode`; anything unknown is ignored.
    static func requestedMode(_ raw: String?) -> ReceiverDisplayMode? {
        raw.flatMap(ReceiverDisplayMode.init(rawValue:))
    }
}

// MARK: - Pending lifecycle

/// A prompt waiting on this endpoint's user.
struct PendingSessionApproval: Identifiable, Equatable, Sendable {
    /// The invitation/request id.
    let id: String
    let peerID: String
    let peerName: String
    /// The role of this endpoint in the requested session.
    let localRole: SessionRole
    /// Requested/intended mode — context and the prompt's default choice.
    var mode: ReceiverDisplayMode
    let createdAt: Date
}

/// Single owner of every pending approval on one endpoint. Keyed by request
/// id so a stale or cancelled answer can never resolve a newer request; at
/// most one pending request per peer (a newer request from the same peer
/// supersedes the old one), while different peers can wait simultaneously.
/// Not thread-safe by itself: the owning isolation domain (MainActor on the
/// Mac Sender, the receiver's control queue) confines it.
struct PendingSessionApprovals: Equatable, Sendable {
    static let timeout: TimeInterval = 60

    private(set) var entries: [PendingSessionApproval] = []

    /// Returns false for a duplicate id (a repeated packet or double tap
    /// coalesces into the existing prompt). A newer request from the same
    /// peer replaces the older one, whose id is returned in `superseded`.
    @discardableResult
    mutating func begin(_ approval: PendingSessionApproval) -> (started: Bool, superseded: String?) {
        guard !entries.contains(where: { $0.id == approval.id }) else { return (false, nil) }
        let superseded = entries.first { $0.peerID == approval.peerID }?.id
        entries.removeAll { $0.peerID == approval.peerID }
        entries.append(approval)
        return (true, superseded)
    }

    /// Removes and returns the pending entry for `id`, or nil when it is no
    /// longer current (already answered, cancelled, superseded, expired).
    mutating func resolve(id: String) -> PendingSessionApproval? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        return entries.remove(at: index)
    }

    /// The receiver's requested mode arrived after the prompt was raised.
    mutating func updateMode(id: String, mode: ReceiverDisplayMode) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].mode = mode
    }

    /// Peer disconnected or was forgotten.
    @discardableResult
    mutating func removeAll(peerID: String) -> [PendingSessionApproval] {
        let removed = entries.filter { $0.peerID == peerID }
        entries.removeAll { $0.peerID == peerID }
        return removed
    }

    /// Entries older than `timeout`, removed; callers treat them as
    /// Reject for This Session.
    mutating func expire(now: Date = Date()) -> [PendingSessionApproval] {
        let expired = entries.filter { now.timeIntervalSince($0.createdAt) >= Self.timeout }
        entries.removeAll { now.timeIntervalSince($0.createdAt) >= Self.timeout }
        return expired
    }

    var first: PendingSessionApproval? { entries.first }
}

/// Mac Sender-side gate for one logical session: capture may start only once
/// the receiver accepted this session's invitation AND, for a receiver-
/// initiated request that needed it, the Sender's own user approved.
struct SessionAdmissionGate: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case waiting
        case admitted
        case refused(SessionInvitationResult)
    }

    private(set) var receiverAccepted: Bool
    private(set) var receiverAskingUser = false
    private(set) var senderApproved: Bool
    private(set) var refusal: SessionInvitationResult?

    init(receiverSupportsInvitations: Bool, needsSenderApproval: Bool) {
        // A pre-pv 21 receiver has no invitation step; the Sender still owns
        // its own approval of a receiver-initiated request.
        receiverAccepted = !receiverSupportsInvitations
        senderApproved = !needsSenderApproval
    }

    var state: State {
        if let refusal { return .refused(refusal) }
        return receiverAccepted && senderApproved ? .admitted : .waiting
    }

    /// What the Sender UI should show, or nil when there is nothing to wait
    /// on visibly (e.g. before the receiver has answered at all).
    var progress: SessionInvitationProgress? {
        switch state {
        case .admitted: return .admitted
        case .refused(let result): return .refused(result)
        case .waiting:
            if !receiverAccepted, receiverAskingUser { return .waitingForReceiver }
            if receiverAccepted, !senderApproved { return .waitingForSender }
            return nil
        }
    }

    mutating func receiverResponded(_ result: SessionInvitationResult) {
        guard refusal == nil else { return }
        switch result {
        case .accepted:
            receiverAccepted = true
            receiverAskingUser = false
        case .pending:
            if !receiverAccepted { receiverAskingUser = true }
        case .declined, .blocked, .cancelled: refusal = result
        }
    }

    mutating func senderDecided(accept: Bool) {
        guard refusal == nil else { return }
        if accept { senderApproved = true } else { refusal = .declined }
    }
}

/// What the Mac Sender's UI shows for a session still being negotiated.
enum SessionInvitationProgress: Equatable, Sendable {
    /// The receiver is asking its user.
    case waitingForReceiver
    /// A receiver-initiated request waits for this Mac's user.
    case waitingForSender
    case admitted
    case refused(SessionInvitationResult)
}

/// Receiver-side admission for the current connection. Video and audio from
/// a pv 21+ sender are only presented once its invitation is accepted here.
/// `acceptedInvitationID` survives connection churn (not launches) so an
/// in-place reconnect of an already-accepted session is recognized without
/// a new prompt.
struct ReceiverSessionAdmission: Equatable, Sendable {
    private(set) var admitted = false
    private(set) var acceptedInvitationID: String?
    private(set) var acceptedPeerID: String?

    /// New connection adopted: nothing is admitted until it proves itself.
    mutating func beginConnection() { admitted = false }

    mutating func admit(invitationID: String?, peerID: String?) {
        admitted = true
        if let invitationID {
            acceptedInvitationID = invitationID
            acceptedPeerID = peerID
        }
    }

    mutating func revoke() {
        admitted = false
        acceptedInvitationID = nil
        acceptedPeerID = nil
    }

    func isContinuation(of invitation: SessionInvitation, peerID: String?) -> Bool {
        invitation.id == acceptedInvitationID && peerID == acceptedPeerID
    }

    /// A pre-pv 21 sender cannot carry intent or be declined in-band, so it is
    /// admitted only if this receiver would accept a background attempt from
    /// it anyway. Anything stricter fails closed — an older peer must never
    /// silently bypass the user's approval preference.
    static func admitsLegacySender(peerID: String?, defaults: UserDefaults = .standard) -> Bool {
        IncomingSessionPolicyStore.decision(peerID: peerID, intent: .automatic, defaults: defaults) == .accept
    }
}
