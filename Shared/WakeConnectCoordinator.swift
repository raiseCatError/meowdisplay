// WakeConnectCoordinator — drives `WakeConnectAttempt` (the pure state/timing
// policy) against a real `StreamReceiver`: WoL, the receiver Connect-request
// token, and Promote Interactive Wake, in the order and with the bounded
// retries described in the orchestration spec. DEBUG-only, like every piece
// it touches (`InteractiveWakePromotion`, `WireMessage.promoteInteractiveWake`,
// `WakeTestingView`) — see that milestone note for why.
//
// This is a UI/workflow projection layered on top of the canonical
// `ReceiverSessionState` connection state machine — it never dials, never
// authenticates, and never replaces any transport/reconnect logic. It only
// watches `StreamReceiver`'s already-published state and calls its already-
// public request methods (`requestConnect`, `refreshConnectRequest`,
// `requestPromoteInteractiveWake`) at the right moments.
//
// KNOWN LIMITATION (evaluated, deliberately deferred — not a small/local
// change): `StreamReceiver` does not currently expose which pinned peer
// actually authenticated a given session. `TLSConfigurator`'s verify block
// (Shared/TLSConfigurator.swift) only returns accept/reject — it never
// surfaces which pinned SPKI matched. On the Mac (dialer) side, `peerID` is
// known a priori (it chose who to dial — see `TLSSessionConfig.peerID`); the
// receiver is the TLS *listener*, so it has no such a priori identity and
// would need genuinely new code to recover one: extracting the completed
// connection's peer certificate via `sec_protocol_metadata` (a pattern not
// used anywhere in this codebase today), re-deriving its SPKI the same way
// `TLSConfigurator` does, resolving it through `TrustStore.peerID(forSPKI:)`,
// and threading a new published, lifecycle-managed identity through
// `adopt()`/reconnect/forget. That is real security-adjacent surface, not a
// local tweak — left deferred rather than rushed. `applicationAuthenticated`
// below is therefore called with the attempt's own target peer ID rather
// than a verified one; with more than one paired Mac, a different already-
// paired Mac dialing in mid-attempt could in principle be mistaken for the
// one this attempt woke. `WakeConnectAttempt` itself does check the peer ID
// it's given, so this narrows to exactly that one gap rather than having no
// check at all.
#if DEBUG
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

    var statusLabel: String {
        switch attempt.stage {
        case .idle, .failed: return ""
        case .preparing, .waking, .waitingForConnection: return "Waking…"
        case .authenticating: return "Connecting…"
        case .promoting: return "Waking display…"
        case .waitingForVideo: return "Starting video…"
        case .connected: return "Connected"
        }
    }

    // MARK: - Entry points

    func begin(peerID: String) {
        guard !receiver.connected else { return }
        guard !isRunning(forPeerID: peerID) else { return }   // no duplicate concurrent attempts
        stopAllTimers()
        subscribeIfNeeded()
        activePeerID = peerID
        let id = attempt.begin(peerID: peerID)
        Log.info("wakeConnect: begin peer=\(peerID) attempt=\(id)")

        // Listener ready + connect-request published: `requestConnect()`
        // does both (ensures the TLS listener is armed, rebinds the
        // plaintext listener, publishes the first one-shot token) and also
        // clears explicit-disconnect suppression — exactly what "IDLE AFTER
        // EXPLICIT DISCONNECT" needs.
        receiver.requestConnect()
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
    }

    private func handleSessionChange(_ session: ReceiverSessionState) {
        guard attempt.isActive, let peerID = activePeerID else { return }
        switch session.phase {
        case .connecting:
            if attempt.transportReady() {
                Log.info("wakeConnect: transportReady")
            }
        case .connected:
            if attempt.applicationAuthenticated(generation: session.generation, peerID: peerID) {
                Log.info("wakeConnect: applicationAuthenticated generation=\(session.generation)")
                tokenRefreshTimer?.cancel(); tokenRefreshTimer = nil
                if attempt.stage == .waitingForVideo {
                    Log.info("wakeConnect: waitingForVideo")
                    checkVideoAlreadyReady()
                } else {
                    sendPromoteIfNeeded()
                }
            }
        case .reconnecting, .reconnectFailed, .disconnected:
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

    // MARK: - Promote (authenticated-only, bounded, generation-scoped)

    private func sendPromoteIfNeeded() {
        guard attempt.shouldSendPromote(), let generation = attempt.promoteGeneration else { return }
        Log.info("wakeConnect: promoteSent generation=\(generation) attempt=\(attempt.promoteAttemptsThisGeneration)")
        receiver.requestPromoteInteractiveWake()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + WakeConnectAttempt.promoteRetryInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.attempt.stage == .promoting else { return }
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
#endif
