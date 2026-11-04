import Foundation

/// What a Mac-side Connect tap (Known Devices, Overview, Remote Access, the
/// Connect with Mirror/Extend menu) does with a session this Mac already has
/// for that device (issue #128).
///
/// An attempt this Mac started on its own (Auto-Connect) carries an
/// `automatic` invitation. A receiver that doesn't automatically allow this
/// Mac declines such an invitation quietly instead of asking its user
/// (`IncomingSessionPolicy`), so a Connect tap absorbed by it would end in
/// "declined" without the iPhone ever asking. The tap replaces such an
/// attempt with a fresh explicit one, the same rule
/// `ReceiverRequestAdmission` applies to a receiver's own Connect request.
///
/// Anything else is kept: an explicit attempt still in progress, a session
/// the receiver already admitted, a receiver-initiated session, or the
/// continuation of an admitted session (a Mac-wide rebuild or the wait for
/// a locked device to wake), which the receiver recognizes without a new
/// prompt. Replacing those would duplicate prompts or tear down a working
/// session.
enum ExplicitConnectAdmission {
    struct Existing: Equatable, Sendable {
        let failed: Bool
        let admitted: Bool
        let invitation: SessionInvitation
        /// Started from another session's invitation (`SessionContinuation`).
        let isContinuation: Bool
    }

    enum Action: Equatable, Sendable {
        /// Nothing usable exists: start the explicit attempt.
        case start
        /// End the existing automatic attempt, then start the explicit one.
        case replace
        /// The existing session already covers the tap.
        case keep
    }

    static func decide(existing: Existing?) -> Action {
        guard let existing, !existing.failed else { return .start }
        if !existing.admitted, !existing.isContinuation,
           existing.invitation.initiator == .sender, existing.invitation.intent == .automatic {
            return .replace
        }
        return .keep
    }
}
