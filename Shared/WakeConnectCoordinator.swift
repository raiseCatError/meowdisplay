// WakeConnectCoordinator — drives `WakeConnectAttempt` (the pure state/timing
// policy) against a real `StreamReceiver`: WoL, the receiver Connect-request
// token, and Promote Interactive Wake, in the order and with the bounded
// retries described in the orchestration spec. Release feature, like every
// piece it touches (`InteractiveWakePromotion`,
// `WireMessage.promoteInteractiveWake`) — the manual test surfaces that
// exercise those by hand (`WakeTestingView`, `RouteOverrides`) remain
// Debug-only diagnostics.
//
// This is a UI/workflow projection layered on top of the canonical
// `ReceiverSessionState` connection state machine — it never dials, never
// authenticates, and never replaces any transport/reconnect logic. It only
// watches `StreamReceiver`'s already-published state and calls its already-
// public request methods (`requestConnect`, `refreshConnectRequest`,
// `requestPromoteInteractiveWake`) at the right moments.
//
// AUTHENTICATED TARGET-PEER BINDING: `applicationAuthenticated` below is
// called with `receiver.authenticatedPeerID` — the pinned peerID that
// actually completed mutual TLS for the current session, derived from the
// connection's own certificate (SPKI → `TrustStore.peerID(forSPKI:)`; see
// `StreamReceiver.resolveAuthenticatedPeerID`) — never with this attempt's
// own requested/target peerID. `WakeConnectAttempt.applicationAuthenticated`
// then requires that to equal the attempt's target peerID before treating
// the session as having satisfied this specific wake attempt. A different
// already-paired Mac dialing in mid-attempt, a stale previous-peer session
// still settling, a Bonjour peerID, a hostname, or wake metadata are all
// insufficient on their own — only the cryptographically-verified identity
// counts. A `nil` `authenticatedPeerID` (no TLS metadata — the loopback-only
// USB path) can never satisfy an attempt either, since `nil` cannot equal a
// non-nil target peerID.
//
// TRUST REVOCATION (P13): if `Forget` is pressed against the peer this
// attempt is targeting, `receiver.lastForgottenPeerID` fires and the attempt
// is failed immediately — a late/stale authentication arriving after Forget
// must never complete it.
import Foundation
import Combine
import Network

@MainActor
final class WakeConnectCoordinator: ObservableObject {
    @Published private(set) var attempt = WakeConnectAttempt()

    private let receiver: StreamReceiver
    private var activePeerID: String?
    private var cancellables = Set<AnyCancellable>()
    private var wolTimer: DispatchSourceTimer?
    private var tokenRefreshTimer: DispatchSourceTimer?
    private var promoteRetryTimer: DispatchSourceTimer?
    private var overallTimeoutTimer: DispatchSourceTimer?

    init(receiver: StreamReceiver) {
        self.receiver = receiver
    }

    var isActive: Bool { attempt.isActive }

    func isRunning(forPeerID peerID: String) -> Bool {
        activePeerID == peerID && attempt.isActive
    }

    func failed(forPeerID peerID: String) -> Bool {
        guard activePeerID == peerID else { return false }
        if case .failed = attempt.stage { return true }
        return false
    }

    func failureReason(forPeerID peerID: String) -> String? {
        guard activePeerID == peerID else { return nil }
        if case .failed(let reason) = attempt.stage { return reason }
        return nil
    }

    var statusLabel: String {
        switch attempt.stage {
        case .idle, .failed: return ""
        case .preparing, .waking, .waitingForConnection: return String(localized: "Waking…")
        case .authenticating: return String(localized: "Connecting…")
        case .promoting: return String(localized: "Waking display…")
        case .waitingForVideo: return String(localized: "Starting video…")
        case .connected: return String(localized: "Connected")
        }
    }

    // MARK: - Entry points

    /// `mode` is the display mode this device asks the Mac for (pv 21
    /// `hello.requestedMode`); nil leaves the choice to the Mac.
    func begin(peerID: String, mode: ReceiverDisplayMode? = nil) {
        guard !receiver.connected else { return }
        guard !isRunning(forPeerID: peerID) else { return }   // no duplicate concurrent attempts
        stopAllTimers()
        subscribeIfNeeded()
        activePeerID = peerID
        let id = attempt.begin(peerID: peerID)
        Log.info("wakeConnect: begin peer=\(peerID) attempt=\(id)")

        // Listener ready + connect-request published: `connectPrimary()`
        // does both (ensures the TLS listener is armed, rebinds the
        // plaintext listener, publishes the first one-shot token) and also
        // clears explicit-disconnect suppression — exactly what "IDLE AFTER
        // EXPLICIT DISCONNECT" needs. It also sends the first remote knock.
        receiver.connectPrimary(peerID: peerID, mode: mode)
        Log.info("wakeConnect: listenerReady")
        if attempt.connectRequestPublished() {
            Log.info("wakeConnect: connectRequestPublished token=pending")
        }

        sendWOLBurst()
        scheduleTokenRefresh()
        scheduleOverallTimeout()
    }

    func cancel() {
        guard attempt.isActive else { return }
        if attempt.fail("cancelled") {
            Log.info("wakeConnect: cancelled")
        }
        stopAllTimers()
    }

    // MARK: - WoL

    private func sendWOLBurst() {
        guard let peerID = activePeerID,
              let metadata = WakeMetadataStore.metadata(forPeerID: peerID),
              let broadcast = metadata.broadcastAddress else { return }
        func sendOne() {
            guard attempt.recordWOLSent() else { return }
            let result = WakeOnLAN.send(macAddress: metadata.macAddress, broadcastAddress: broadcast)
            Log.info("wakeConnect: wolSent attempt=\(attempt.wolBurstsSent) result=\(result)")
            if attempt.beginWaitingForConnection() {
                Log.info("wakeConnect: waitingForConnection")
            }
        }
        sendOne()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + WakeConnectAttempt.wolBurstInterval,
                       repeating: WakeConnectAttempt.wolBurstInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.attempt.stage == .waking || self.attempt.stage == .waitingForConnection,
                  self.attempt.wolBurstsSent < WakeConnectAttempt.maxWOLBursts else {
                self?.wolTimer?.cancel(); self?.wolTimer = nil
                return
            }
            sendOne()
        }
        timer.resume()
        wolTimer = timer
    }

    // MARK: - Connect-request token refresh

    private func scheduleTokenRefresh() {
        tokenRefreshTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + WakeConnectAttempt.connectTokenRefreshInterval,
                       repeating: WakeConnectAttempt.connectTokenRefreshInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            switch self.attempt.stage {
            case .preparing, .waking, .waitingForConnection:
                self.receiver.refreshConnectRequest()
                Log.info("wakeConnect: connectRequestRefreshed")
            default:
                self.tokenRefreshTimer?.cancel()
                self.tokenRefreshTimer = nil
            }
        }
        timer.resume()
        tokenRefreshTimer = timer
    }

    // MARK: - Session observation (transportReady / applicationAuthenticated / connectionLost)

    private func subscribeIfNeeded() {
        guard cancellables.isEmpty else { return }
        receiver.$session
            .sink { [weak self] session in self?.handleSessionChange(session) }
            .store(in: &cancellables)
        receiver.$videoSize
            .sink { [weak self] size in self?.handleVideoSizeChange(size) }
            .store(in: &cancellables)
        receiver.$promoteInteractiveWakeResult
            .sink { [weak self] result in self?.handlePromoteResult(result) }
            .store(in: &cancellables)
        // dropFirst(): Combine replays the current value on subscribe, and a
        // peer forgotten before this coordinator's first `begin()` must not
        // immediately fail a brand-new attempt for an unrelated peer.
        receiver.$lastForgottenPeerID
            .dropFirst()
            .compactMap { $0 }
            .sink { [weak self] forgottenPeerID in self?.handlePeerForgotten(forgottenPeerID) }
            .store(in: &cancellables)
    }

    private func handleSessionChange(_ session: ReceiverSessionState) {
        guard attempt.isActive, activePeerID != nil else { return }
        switch session.phase {
        case .connecting:
            if attempt.transportReady() {
                Log.info("wakeConnect: transportReady")
            }
        case .connected:
            // Authenticated target-peer binding (P4) — see the file header.
            // A `nil`/mismatched authenticatedPeerID simply fails this guard
            // and leaves the attempt exactly where it was; it does not fail
            // the attempt outright, since the real dial may still be in
            // flight on a different candidate connection.
            guard let authenticatedPeerID = receiver.authenticatedPeerID else { return }
            if attempt.applicationAuthenticated(generation: session.generation, peerID: authenticatedPeerID) {
                Log.info("wakeConnect: applicationAuthenticated generation=\(session.generation)")
                tokenRefreshTimer?.cancel(); tokenRefreshTimer = nil
                if attempt.stage == .waitingForVideo {
                    Log.info("wakeConnect: waitingForVideo")
                    checkVideoAlreadyReady()
                } else {
                    sendPromoteIfNeeded()
                }
            }
        case .reconnecting, .reconnectFailed, .disconnected, .peerDisconnected:
            if attempt.connectionLost() {
                scheduleTokenRefresh()
            }
        case .unrecoverable:
            let stageAtFailure = attempt.stage
            if attempt.fail("protocolIncompatible") {
                Log.info("wakeConnect: failed reason=protocolIncompatible stage=\(stageAtFailure)")
                stopAllTimers()
            }
        case .paused:
            break
        }
    }

    private func handleVideoSizeChange(_ size: CGSize) {
        guard attempt.isActive, size != .zero else { return }
        if attempt.videoReady() {
            Log.info("wakeConnect: connected")
            stopAllTimers()
        }
    }

    private func checkVideoAlreadyReady() {
        guard receiver.videoSize != .zero, attempt.videoReady() else { return }
        Log.info("wakeConnect: connected")
        stopAllTimers()
    }

    // MARK: - Trust revocation (P13)

    /// Forgetting the peer this attempt targets must end the attempt
    /// immediately — a late/stale authentication arriving after Forget must
    /// never be allowed to complete it. A forget for an unrelated peer (a
    /// different paired Mac) is a no-op here.
    private func handlePeerForgotten(_ peerID: String) {
        guard activePeerID == peerID, attempt.isActive else { return }
        if attempt.fail("peerForgotten") {
            Log.info("wakeConnect: failed reason=peerForgotten")
        }
        stopAllTimers()
    }

    // MARK: - Promote (authenticated-only, bounded, generation-scoped)

    private func sendPromoteIfNeeded() {
        guard attempt.shouldSendPromote(), let generation = attempt.promoteGeneration else { return }
        Log.info("wakeConnect: promoteSent generation=\(generation) attempt=\(attempt.promoteAttemptsThisGeneration)")
        receiver.requestPromoteInteractiveWake()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + WakeConnectAttempt.promoteRetryInterval)
        // Bound to the generation this retry was scheduled for, not just the
        // stage: `cancel()` on a `DispatchSourceTimer` does not retroactively
        // withdraw a handler that GCD has already handed to the queue, so a
        // stale timer from an OLD generation could otherwise still fire after
        // a NEW generation has already re-entered `.promoting` (e.g. a fast
        // reconnect racing this timer's deadline) and be mistaken for that
        // new generation's own scheduled retry — consuming its retry budget
        // without it having asked for one. Checking `promoteGeneration`
        // here, not just `stage`, closes that gap.
        timer.setEventHandler { [weak self] in
            guard let self, self.attempt.stage == .promoting,
                  self.attempt.promoteGeneration == generation else { return }
            self.sendPromoteIfNeeded()
        }
        timer.resume()
        promoteRetryTimer?.cancel()
        promoteRetryTimer = timer
    }

    private func handlePromoteResult(_ result: String?) {
        guard let result, result.hasPrefix("Success"),
              attempt.stage == .promoting, let generation = attempt.promoteGeneration else { return }
        guard attempt.promoteSucceeded(generation: generation) else { return }
        Log.info("wakeConnect: promoteSucceeded")
        Log.info("wakeConnect: waitingForVideo")
        promoteRetryTimer?.cancel(); promoteRetryTimer = nil
        checkVideoAlreadyReady()
    }

    // MARK: - Timeout / cleanup

    private func scheduleOverallTimeout() {
        overallTimeoutTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + WakeConnectAttempt.overallTimeout)
        timer.setEventHandler { [weak self] in
            guard let self, self.attempt.isActive else { return }
            let stageAtTimeout = self.attempt.stage
            if self.attempt.fail("timedOut") {
                Log.info("wakeConnect: timedOut stage=\(stageAtTimeout)")
            }
            self.stopAllTimers()
        }
        timer.resume()
        overallTimeoutTimer = timer
    }

    private func stopAllTimers() {
        wolTimer?.cancel(); wolTimer = nil
        tokenRefreshTimer?.cancel(); tokenRefreshTimer = nil
        promoteRetryTimer?.cancel(); promoteRetryTimer = nil
        overallTimeoutTimer?.cancel(); overallTimeoutTimer = nil
    }
}
