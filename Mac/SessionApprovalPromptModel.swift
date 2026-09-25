import Combine
import Foundation

/// Mac Sender prompt for receiver-initiated session requests that this Mac's
/// incoming policy sends to manual approval. Owns every pending request in
/// one `PendingSessionApprovals` value on the main actor, so requests from
/// different receivers can wait side by side (shown one at a time) and a
/// stale, cancelled or superseded answer can never resolve a newer request.
@MainActor
final class SessionApprovalPromptModel: ObservableObject {
    @Published private(set) var approvals = PendingSessionApprovals()
    private var timeoutTask: Task<Void, Never>?

    var current: PendingSessionApproval? { approvals.first }

    /// Called with each resolved request, including timeouts
    /// (`.rejectForSession`).
    var onDecision: ((PendingSessionApproval, SenderApprovalDecision) -> Void)?
    var onPending: (() -> Void)?

    func request(_ approval: PendingSessionApproval) {
        guard approvals.begin(approval).started else { return }
        scheduleExpiry()
        onPending?()
    }

    func updateRequestedMode(id: String, mode: ReceiverDisplayMode) {
        approvals.updateMode(id: id, mode: mode)
    }

    func decide(_ decision: SenderApprovalDecision, for id: String) {
        guard let approval = approvals.resolve(id: id) else {
            Log.info("sessionInvite: ignored stale approval id=\(id)")
            return
        }
        onDecision?(approval, decision)
    }

    /// The window was closed without choosing: Reject for This Session.
    func windowClosedByUser() {
        guard let current else { return }
        decide(.rejectForSession, for: current.id)
    }

    /// The request's session ended (receiver cancelled, disconnected, peer
    /// forgotten). No decision is reported.
    func cancel(id: String) {
        _ = approvals.resolve(id: id)
    }

    func cancelAll(peerID: String) {
        approvals.removeAll(peerID: peerID)
    }

    private func scheduleExpiry() {
        timeoutTask?.cancel()
        guard let oldest = approvals.entries.map(\.createdAt).min() else { return }
        let delay = max(0, PendingSessionApprovals.timeout - Date().timeIntervalSince(oldest))
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            for approval in self.approvals.expire() {
                self.onDecision?(approval, .rejectForSession)
            }
            self.scheduleExpiry()
        }
    }
}
