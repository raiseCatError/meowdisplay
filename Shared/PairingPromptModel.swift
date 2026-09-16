import Combine
import Foundation

/// UI-facing pairing prompt, intentionally separate from connection state.
/// Only explicit user actions or the defined timeout resolve a confirmation;
/// SwiftUI presentation lifecycle events are observational and never decide.
@MainActor
final class PairingPromptModel: ObservableObject {
    @Published private(set) var pending: PendingPairing?
    @Published private(set) var status: String?
    private var decision: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let timeoutNanoseconds: UInt64

    var onPending: ((PendingPairing) -> Void)?

    nonisolated init(timeoutNanoseconds: UInt64 = 60_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func request(_ value: PendingPairing) async -> Bool {
        guard decision == nil else {
            Log.info("pairDebug: confirmationResolved value=false reason=duplicateRequest peerID=\(value.peerID)")
            return false
        }

        return await withCheckedContinuation { continuation in
            // Own the continuation before publishing. Publishing constructs
            // and reconciles SwiftUI presenters synchronously; no presenter
            // callback may race ahead of continuation ownership.
            decision = continuation
            pending = value
            status = nil
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.timeoutNanoseconds ?? 0)
                guard !Task.isCancelled else { return }
                self?.resolve(false, reason: "timeout")
            }
            onPending?(value)
        }
    }

    func decide(accept: Bool) {
        resolve(accept, reason: accept ? "userAccept" : "userReject")
    }

    /// The user closed the presentation surface itself (e.g. the pairing
    /// panel's window close button) rather than choosing Cancel/Re-pair.
    /// This is an explicit rejection of the pending confirmation — never a
    /// no-op — so the very next pairing request is free to start a fresh
    /// prompt instead of being refused as a duplicate against an invisible
    /// one. Safe to call after the confirmation already resolved some other
    /// way (e.g. the panel is being closed programmatically after Accept):
    /// `resolve` ignores a call with no pending decision.
    func windowClosedByUser() {
        resolve(false, reason: "windowClosed")
    }

    func notePresentationDismissed() {
        Log.info("pairDebug: presentationDismissed pending=\(pending != nil) action=none")
    }

    func finish(_ text: String) {
        guard decision == nil else {
            Log.info("pairDebug: finishIgnored reason=confirmationStillPending")
            return
        }
        pending = nil
        status = text
    }

    func cancel() {
        resolve(false, reason: "programmaticCancel")
        status = nil
    }

    private func resolve(_ value: Bool, reason: String) {
        guard let current = decision else {
            Log.info("pairDebug: confirmationResolveIgnored value=\(value) reason=\(reason) noPendingDecision=true")
            return
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        decision = nil
        pending = nil
        Log.info("pairDebug: confirmationResolved value=\(value) reason=\(reason)")
        current.resume(returning: value)
    }
}
