import Combine
import Foundation

/// UI-facing pairing prompt, intentionally separate from connection state.
/// Only explicit user actions or the defined timeout resolve a confirmation;
/// SwiftUI presentation lifecycle events are observational and never decide.
@MainActor
final class PairingPromptModel: ObservableObject {
    @Published private(set) var pending: PendingPairing?
    @Published private(set) var status: String?
    /// Set once THIS device accepted the SAS, until the attempt ends. Purely
    /// presentational ("Waiting for confirmation…"): it never means trust was
    /// written or the pairing completed.
    @Published private(set) var confirmedLocally: PendingPairing?
    private var decision: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let timeoutNanoseconds: UInt64

    var onPending: ((PendingPairing) -> Void)?

    // MARK: Attempt ownership
    //
    // Every real pairing attempt has a token. Exactly one attempt owns the
    // visible prompt at a time; only the owner's token can change, cancel or
    // clear the on-screen state, and each attempt keeps its own cancel
    // callback. A second/duplicate/malformed attempt is refused instead of
    // replacing or clearing the owner's state.

    /// The attempt that currently owns the prompt/waiting state.
    private(set) var owner: UUID?
    private var cancelHandlers: [UUID: () -> Bool] = [:]
    private var abortedTokens: Set<UUID> = []

    /// True once the owning attempt passed its commit point: Cancel is no
    /// longer valid.
    @Published private(set) var isCommitting = false

    /// `cancel` tears down that attempt's own connection through its commit
    /// gate and returns `false` when it is too late (already committed).
    func registerAttempt(_ token: UUID, cancel: @escaping () -> Bool) { cancelHandlers[token] = cancel }

    func markCommitting(token: UUID) {
        guard owner == token else { return }
        isCommitting = true
    }

    /// Cancels one attempt's real connection. `false` = too late, nothing changed.
    func cancelAttempt(token: UUID) -> Bool {
        guard let handler = cancelHandlers[token] else { return true }
        return handler()
    }

    /// The user cancelled (or closed the panel) after confirming locally, while
    /// the other device has not confirmed yet: terminate the owning attempt.
    func cancelWaiting() {
        guard let token = owner, confirmedLocally != nil, !isCommitting else { return }
        guard cancelAttempt(token: token) else {
            Log.info("pairDebug: waitingForPeer cancel too late (committed)")
            return
        }
        confirmedLocally = nil
        Log.info("pairDebug: waitingForPeer cancelled by user")
    }

    /// An authenticated abort arrived for `token`'s own attempt. It only ends
    /// that attempt's prompt; a token that doesn't own the prompt changes
    /// nothing, and is remembered so it can never show a SAS afterwards.
    func peerAborted(token: UUID) {
        abortedTokens.insert(token)
        guard owner == token else { return }
        resolve(false, reason: "peerAbort")
        confirmedLocally = nil
        status = nil
    }

    /// Programmatic teardown of `token`'s own prompt state only.
    func cancel(ownedBy token: UUID) {
        guard owner == token else { return }
        cancel()
    }

    /// The attempt is over (success, failure, cancel, timeout, disconnect).
    /// Clears only what `token` owns; for any other token this is a no-op
    /// against a live prompt.
    func attemptEnded(token: UUID) {
        cancelHandlers[token] = nil
        abortedTokens.remove(token)
        outcomeErrors[token] = nil
        guard owner == token else { return }
        // A dead attempt must not leave its SAS on screen.
        if decision != nil { resolve(false, reason: "attemptEnded") }
        owner = nil
        isCommitting = false
        confirmedLocally = nil
    }

    nonisolated init(timeoutNanoseconds: UInt64 = 60_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func request(_ value: PendingPairing, token: UUID? = nil) async -> Bool {
        if let token {
            if abortedTokens.contains(token) || (owner != nil && owner != token) {
                Log.info("pairDebug: confirmationResolved value=false reason=notOwner peerID=\(value.peerID)")
                return false
            }
        }
        guard decision == nil else {
            Log.info("pairDebug: confirmationResolved value=false reason=duplicateRequest peerID=\(value.peerID)")
            return false
        }

        return await withCheckedContinuation { continuation in
            // Own the continuation before publishing. Publishing constructs
            // and reconciles SwiftUI presenters synchronously; no presenter
            // callback may race ahead of continuation ownership.
            decision = continuation
            if let token { owner = token }
            confirmedLocally = nil
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

    /// Installed by the app. Required whenever owner authentication is required:
    /// there is no fallback from "required" to "accept anyway" — with no
    /// authenticator installed, approving fails closed.
    var ownerAuthenticator: OwnerAuthenticating?
    /// Current pin for a peer, used to re-check trust at approval time. If it
    /// is not installed the pin cannot be verified and a same-key re-pair is
    /// treated as new trust.
    var trustPinLookup: ((String) -> Data?)?
    @Published private(set) var isAuthenticating = false
    private var authGeneration = 0
    private var outcomeErrors: [UUID: PairingError] = [:]

    /// The error an attempt should surface instead of "rejected" (owner-auth
    /// cancelled or failed). Consumed once.
    func takeOutcomeError(token: UUID) -> PairingError? { outcomeErrors.removeValue(forKey: token) }

    /// Proof that the local device may send its acceptance: either owner
    /// authentication just succeeded, or policy says none is needed. Only this
    /// file can create one, and `acceptLocally` is the only way to resolve the
    /// prompt as accepted.
    struct OwnerAuthorization {
        enum Basis { case authenticated, notRequired }
        let basis: Basis
        fileprivate init(_ basis: Basis) { self.basis = basis }
    }

    private func acceptLocally(_ proof: OwnerAuthorization) {
        resolve(true, reason: proof.basis == .authenticated ? "userAccept+ownerAuth" : "userAccept")
    }

    private func pinSnapshot(for peerID: String) -> PinSnapshot {
        guard let lookup = trustPinLookup else { return .unavailable }
        return lookup(peerID).map(PinSnapshot.present) ?? .absent
    }

    /// "Codes Match" for NEW trust first requires local device-owner
    /// authentication; only after it succeeds does the local acceptance
    /// resolve (and only then does the waiting state begin). Rejecting never
    /// needs authentication.
    func decide(accept: Bool) {
        guard accept else {
            resolve(false, reason: "userReject")
            return
        }
        guard decision != nil, let pending else {
            Log.info("pairDebug: confirmationResolveIgnored value=true noPendingDecision=true")
            return
        }
        let updatingEndpointOnly = pending.changesRemoteEndpoint && pending.classification == .rePairSameKey
        guard OwnerAuthPolicy.isRequired(pending, currentPin: pinSnapshot(for: pending.peerID)) else {
            acceptLocally(OwnerAuthorization(.notRequired))
            return
        }
        guard let authenticator = ownerAuthenticator else {
            Log.info("pairDebug: ownerAuth required but no authenticator installed — failing closed")
            abortAfterOwnerAuth(owner, .ownerAuthenticationFailed)
            return
        }
        guard !isAuthenticating else { return }
        isAuthenticating = true
        authGeneration += 1
        let generation = authGeneration
        let token = owner
        let peerID = pending.peerID
        Task { @MainActor [weak self] in
            let result = await authenticator.authenticate(
                reason: OwnerAuthPolicy.reason(peerName: pending.peerName,
                                               updatingEndpointOnly: updatingEndpointOnly))
            guard let self else { return }
            // A late result must never revive an attempt that ended, was
            // cancelled/aborted, timed out, or is no longer this prompt's owner.
            guard generation == self.authGeneration, self.decision != nil, self.owner == token,
                  self.pending?.peerID == peerID else {
                Log.info("pairDebug: ownerAuth result ignored (stale attempt)")
                return
            }
            self.isAuthenticating = false
            switch result {
            case .success: self.acceptLocally(OwnerAuthorization(.authenticated))
            case .cancelled: self.abortAfterOwnerAuth(token, .cancelledLocally)
            case .failed: self.abortAfterOwnerAuth(token, .ownerAuthenticationFailed)
            }
        }
    }

    private func abortAfterOwnerAuth(_ token: UUID?, _ error: PairingError) {
        Log.info("pairDebug: ownerAuth not granted (\(error)) — aborting attempt")
        if let token {
            outcomeErrors[token] = error
            _ = cancelAttempt(token: token)   // gate + authenticated abort + close
        }
        resolve(false, reason: "ownerAuthNotGranted")
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
        cancelWaiting()
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
        confirmedLocally = nil
        status = text
    }

    func cancel() {
        resolve(false, reason: "programmaticCancel")
        confirmedLocally = nil
        status = nil
    }

    private func resolve(_ value: Bool, reason: String) {
        guard let current = decision else {
            Log.info("pairDebug: confirmationResolveIgnored value=\(value) reason=\(reason) noPendingDecision=true")
            return
        }
        if isAuthenticating { ownerAuthenticator?.invalidate() }
        authGeneration += 1
        isAuthenticating = false
        timeoutTask?.cancel()
        timeoutTask = nil
        decision = nil
        confirmedLocally = value ? pending : nil
        pending = nil
        Log.info("pairDebug: confirmationResolved value=\(value) reason=\(reason)")
        current.resume(returning: value)
    }
}
