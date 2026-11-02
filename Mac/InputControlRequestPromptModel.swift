import Combine
import Foundation

/// UI-facing control-request prompt — the Mac-owner-facing half of the
/// milestone, mirroring `PairingPromptModel`'s exact shape (single pending
/// confirmation, `CheckedContinuation`-based, timeout races the user).
/// Deliberately supports only ONE globally pending prompt, same as pairing:
/// a second concurrent request (a different peer asking while this one is
/// still up) is refused outright rather than queued — the requesting
/// session gets treated as if it hit the post-request cooldown and may ask
/// again shortly. This keeps the model small; queuing multiple native
/// prompts is not something this milestone's spec asks for.
@MainActor
final class InputControlRequestPromptModel: ObservableObject {
    @Published private(set) var pending: PendingInputControlRequest?
    private var decision: CheckedContinuation<InputControlRequestDecision, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let timeoutNanoseconds: UInt64

    var onPending: ((PendingInputControlRequest) -> Void)?

    nonisolated init(timeoutNanoseconds: UInt64 = UInt64(InputControlRequestLifecycle.timeout * 1_000_000_000)) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    /// Returns `.notNow` immediately, without ever presenting, if another
    /// request is already up — the caller's own `InputControlRequestLifecycle`
    /// still owns per-session dedup/cooldown; this only protects the single
    /// shared presentation surface.
    func request(_ value: PendingInputControlRequest) async -> InputControlRequestDecision {
        guard decision == nil else {
            Log.info("inputConsentDebug: promptRefused reason=anotherPromptPending peerID=\(value.peerID)")
            return .notNow
        }

        return await withCheckedContinuation { continuation in
            decision = continuation
            pending = value
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.timeoutNanoseconds ?? 0)
                guard !Task.isCancelled else { return }
                self?.resolve(.notNow, reason: "timeout")
            }
            onPending?(value)
        }
    }

    func decide(_ decision: InputControlRequestDecision) {
        resolve(decision, reason: "userDecision")
    }

    /// The user closed the presentation surface itself rather than picking a
    /// button — dismissal is defined as `.notNow` (spec: "Dismissal of the
    /// prompt == Not Now").
    func windowClosedByUser() {
        resolve(.notNow, reason: "windowClosed")
    }

    /// The requesting session ended (disconnect/Forget/teardown) while its
    /// prompt was still up. Safe to call even if nothing is pending.
    func cancelForEndedSession(id: String) {
        guard pending?.id == id else { return }
        resolve(.notNow, reason: "sessionEnded")
    }

    private func resolve(_ value: InputControlRequestDecision, reason: String) {
        guard let current = decision else {
            Log.info("inputConsentDebug: promptResolveIgnored reason=\(reason) noPendingDecision=true")
            return
        }
        timeoutTask?.cancel()
        timeoutTask = nil
        decision = nil
        pending = nil
        Log.info("inputConsentDebug: promptResolved value=\(value) reason=\(reason)")
        current.resume(returning: value)
    }
}
