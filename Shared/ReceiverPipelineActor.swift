// ReceiverPipelineActor — RC-3 Stage C1.
//
// The sole authoritative owner of the coherent connection/session/generation
// cluster that used to live as plain `queue`-confined stored properties on
// `StreamReceiver`: the live `NWConnection`, newcomer `pendingConnections`
// racing to replace it, the `ReceiverSessionState` (phase/generation/loss
// reason), and the one reconnect timer plus the three liveness timers whose
// correctness is inseparable from that same state (see `armLivenessTimers`).
//
// Everything else — frame assembly, decode, audio, presentation, the TLS/
// pairing listener machinery itself — stays on `StreamReceiver`, still
// confined to its own `queue`. This actor never touches any of that
// directly: instead it calls two small, fixed sets of `@Sendable` host
// callbacks — `UIEffects` (permanent facade/UI-mirror outputs) and
// `HostControlEffects` (transitional bridge back onto `queue`-confined
// listener/adoption/hello/reconnect-target work) — for every side effect
// outside its own state. Each callback is itself responsible for hopping
// back onto `queue` (or `DispatchQueue.main`) before touching queue-/
// MainActor-confined state, and every closure in both sets captures
// `StreamReceiver` only weakly, so nothing here extends its lifetime.
//
import Foundation
import Network

// Bridging model: external callback -> `Task { await pipeline.handleX() }`.
// Every actor-isolated method below runs to completion with no internal
// `await`, so once entered it executes atomically — the only place two
// calls can race is at the Task-bridge entry points themselves, which is
// exactly why every decision here is generation-guarded, matching the
// staleness-check idiom already used throughout this file before C1.

/// A narrow, `NSLock`-protected snapshot of the low-frequency, HOST-owned
/// values this actor's reconnect logic needs to read but does not own:
/// the manual-Connect target, whether the peer is known-incompatible, the
/// user's Auto-Reconnect preference, and — as a reconnect-destination HINT
/// ONLY, never a trust decision — the authenticated peer ID. Every write
/// site on `StreamReceiver` updates this box synchronously at the same
/// point it would otherwise mutate its own field, so `ReceiverPipelineActor`
/// never reads `StreamReceiver` state directly off its own isolation
/// domain (an earlier revision did this via plain `@Sendable` getter
/// closures, which is unsynchronized access to state the actor does not
/// own and was rejected in review).
///
/// Invariant: `snapshot` is a value type touched only inside `lock`/
/// `unlock`; `update`/`current` never call out to anything else (no
/// dialing, no other lock, no network callback) while holding the lock, so
/// there is no reentrancy or ordering hazard from holding it.
final class ReconnectContext: @unchecked Sendable {
    struct Snapshot: Sendable {
        var manualConnectPeerID: String?
        var peerIsIncompatible: Bool = false
        var autoReconnectPreferenceEnabled: Bool = true
        /// Reconnect-destination hint only — mirrors `StreamReceiver.
        /// authenticatedPeerID` but carries none of its trust meaning.
        /// `TrustStore`/SPKI pinning/identity-change rejection are
        /// untouched and remain the only source of truth for trust.
        var authenticatedPeerIDHint: String?
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()

    func update(_ mutate: (inout Snapshot) -> Void) {
        lock.lock(); defer { lock.unlock() }
        mutate(&snapshot)
    }

    func current() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }
}

actor ReceiverPipelineActor {

    // MARK: - Authoritative state

    private(set) var connection: NWConnection?
    private var pendingConnections: [NWConnection] = []
    private(set) var sessionState = ReceiverSessionState()
    private var reconnectTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var addrWatchTimer: DispatchSourceTimer?
    private var watchdogTimer: DispatchSourceTimer?
    /// Stored when a connection is lost, so `armReconnect()` can knock the
    /// Mac even after `authenticatedPeerID` (a host/UI mirror) has been
    /// cleared. Moved verbatim from `StreamReceiver` — it exists only to
    /// serve this cluster's own reconnect targeting.
    private var recoveryPeerID: String?

    // MARK: - Dependencies

    /// The receiver's own serial queue. Timers created here schedule on it
    /// (unchanged cadence/semantics), and `NWConnection.start(queue:)` still
    /// uses it too, so every connection callback keeps arriving exactly
    /// where it always did — this actor merely decides what those callbacks
    /// mean, via `Task`-bridged re-entry.
    nonisolated let queue: DispatchQueue
    /// Shared with `StreamReceiver`: the single synchronous, lock-protected
    /// read path for the `@MainActor` input-send surface (Stage B/SendTarget
    /// checkpoint). This actor is now the sole writer.
    nonisolated let sendTargetBox: StreamReceiver.SendTargetBox
    /// See `ReconnectContext` — the synchronized replacement for the
    /// unsynchronized `getManualConnectPeerID`/`getAuthenticatedPeerID`/
    /// `getPeerIsIncompatible`/`getAutoReconnectPreferenceEnabled` getter
    /// closures an earlier revision used.
    nonisolated let reconnectContext: ReconnectContext
    nonisolated let uiEffects: UIEffects
    nonisolated let hostEffects: HostControlEffects

    init(queue: DispatchQueue, sendTargetBox: StreamReceiver.SendTargetBox,
         reconnectContext: ReconnectContext, uiEffects: UIEffects, hostEffects: HostControlEffects) {
        self.queue = queue
        self.sendTargetBox = sendTargetBox
        self.reconnectContext = reconnectContext
        self.uiEffects = uiEffects
        self.hostEffects = hostEffects
    }

    /// Permanent facade/UI-mirror outputs: every call here means "publish
    /// this to the UI," nothing more. Each closure hops onto
    /// `DispatchQueue.main` (via the host's `publishToUI`) before touching
    /// `@MainActor` state; `setStatusConnected` additionally reads the one
    /// piece of queue-confined host context it needs (`transport`) before
    /// composing the string it publishes, but its job — like every member
    /// here — is still "produce a UI update," not "do host work." This is
    /// the long-term shape for this half of what C1 called `HostEffects`:
    /// later stages (frame/decode/presentation/audio) add to
    /// `HostControlEffects`, if anything, never here.
    struct UIEffects: Sendable {
        var publishSessionSnapshot: @Sendable (ReceiverSessionState) -> Void
        var setStatus: @Sendable (String) -> Void
        var setStatusConnected: @Sendable () -> Void
        var applyConnectedUIMirror: @Sendable (Bool) -> Void
    }

    /// Transitional bridge back onto `queue`-confined `StreamReceiver` host
    /// state: listener control, hello/ping sends, adoption reset work, and
    /// the reconnect-target lookups that still live outside this actor.
    /// Every closure captures `StreamReceiver` weakly and is responsible for
    /// its OWN thread-safety — one that touches `queue`-confined state hops
    /// onto `queue` itself — because this actor never assumes a particular
    /// execution context on the other side of the call. This is scaffolding,
    /// not a permanent boundary: it narrows only as the listener/adoption/
    /// hello machinery it calls into gets absorbed into actors of its own in
    /// a later stage. Frame/decode/presentation/audio work must not be added
    /// here.
    struct HostControlEffects: Sendable {
        /// Clears the host's `transport` label on disconnect (it is only
        /// ever meaningful for a live connection).
        var clearTransport: @Sendable () -> Void

        // Reconnect targeting/listener control (unrelated network concerns
        // that stay host-owned; C2 territory, not duplicated here).
        var ensureTLSListening: @Sendable () -> Void
        var requestRemoteConnect: @Sendable (String) -> Void

        // `lastDataReceived`/`activeReceiveGeneration` are read together,
        // synchronously, from inside the watchdog timer's own handler —
        // which runs ON `queue` because the timer is scheduled there — so
        // this is not the same unsynchronized-getter problem as the ones
        // above: it is a plain queue-confined read from queue-confined code.
        var getLastDataReceived: @Sendable () -> Date
        var getActiveReceiveGeneration: @Sendable () -> Int
        var advertisesAddresses: @Sendable () -> Bool

        // Adoption seam (resetStreamState boundary): runs exactly once per
        // accepted adoption, strictly before the connection's own callbacks
        // can reach `queue` (see `adopt`), and strictly before the matching
        // `finishAdoption` — both are plain `queue.async` hops, never a
        // detached `Task`, so GCD's own FIFO-per-queue ordering is what
        // keeps "reset, then drain/receive" deterministic. `generation`
        // (the just-bumped `sessionState.generation`) is threaded through
        // so the host can stamp its own `activeReceiveGeneration` — see
        // `StreamReceiver.receive(on:generation:)`.
        var beginAdoption: @Sendable (NWConnection, _ generation: Int) -> Void
        var finishAdoption: @Sendable (NWConnection, _ generation: Int, _ initialData: Data?) -> Void

        // Ready-transition host work (manualConnectPeerID/lastDataReceived/
        // transport/authenticatedPeerID) and the two remaining callers of
        // `sendHello` that only ever needed to know "there is a live,
        // ready connection" — never connection identity/ownership.
        var onConnectionReady: @Sendable (NWConnection) -> Void
        var sendHello: @Sendable (NWConnection) -> Void
        var onPathUpdate: @Sendable (NWConnection, NWPath) -> Void
        var sendPing: @Sendable () -> Void
        var checkAddressChangeAndSendHello: @Sendable (NWConnection) -> Void
    }

    // MARK: - Session transition input

    // MARK: - Startup / shutdown

    func armLivenessTimers() {
        pingTimer?.cancel()
        let ping = DispatchSource.makeTimerSource(queue: queue)
        ping.schedule(deadline: .now() + 2.0, repeating: 2.0)
        ping.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.pingTick() }
        }
        ping.resume()
        pingTimer = ping

        addrWatchTimer?.cancel()
        if hostEffects.advertisesAddresses() {
            let addrWatch = DispatchSource.makeTimerSource(queue: queue)
            addrWatch.schedule(deadline: .now() + 5.0, repeating: 5.0)
            addrWatch.setEventHandler { [weak self] in
                guard let self else { return }
                Task { await self.addrWatchTick() }
            }
            addrWatch.resume()
            addrWatchTimer = addrWatch
        }

        watchdogTimer?.cancel()
        let watchdog = DispatchSource.makeTimerSource(queue: queue)
        watchdog.schedule(deadline: .now() + 2.0, repeating: 2.0)
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            // Both reads happen here, synchronously, inside the timer's own
            // handler — which runs ON `queue` because the timer itself is
            // scheduled there — so they are a consistent, queue-confined
            // snapshot, not two independent unsynchronized reads.
            let last = self.hostEffects.getLastDataReceived()
            let generation = self.hostEffects.getActiveReceiveGeneration()
            Task { await self.watchdogTick(lastDataReceived: last, generation: generation) }
        }
        watchdog.resume()
        watchdogTimer = watchdog
    }

    /// `stop()`'s teardown of everything this actor owns: the three
    /// liveness timers and any newcomer still racing to replace the
    /// session. The live `connection` itself is left to the immediately
    /// following `closeSession(...)` (routed through
    /// `disconnectCurrentConnection`), exactly as today's `stop()` defers
    /// to `closeSession` for that half of the teardown.
    func teardownForStop() {
        pingTimer?.cancel(); pingTimer = nil
        watchdogTimer?.cancel(); watchdogTimer = nil
        addrWatchTimer?.cancel(); addrWatchTimer = nil
        cancelPendingConnections()
    }

    private func pingTick() {
        guard let conn = connection, conn.state == .ready else { return }
        hostEffects.sendPing()
    }

    private func addrWatchTick() {
        guard let conn = connection, conn.state == .ready else { return }
        hostEffects.checkAddressChangeAndSendHello(conn)
    }

    /// `generation` was captured on `queue` at the same instant as
    /// `lastDataReceived` (see `armLivenessTimers`). If a fresh adoption has
    /// already superseded it by the time this actually runs, the captured
    /// `lastDataReceived` no longer describes the connection this actor
    /// currently holds — skip rather than judge a new, healthy connection
    /// by a stale timestamp that raced its own reset (see `beginAdoption`/
    /// `StreamReceiver.beginAdoptionHostWork`, which reset both
    /// `activeReceiveGeneration` and `lastDataReceived` together, and again
    /// at ready-time, so a still-current generation's timestamp is always
    /// trustworthy here).
    private func watchdogTick(lastDataReceived: Date, generation: Int) {
        guard generation == sessionState.generation else { return }
        guard let conn = connection, conn.state == .ready,
              Date().timeIntervalSince(lastDataReceived) > 5 else { return }
        Log.info("watchdog: nothing from the Mac for >5s — dropping connection")
        conn.cancel()
        connection = nil
        setConnected(false)
    }

    // MARK: - Incoming connections / adoption

    func cancelPendingConnections() {
        pendingConnections.forEach { $0.cancel() }
        pendingConnections.removeAll()
    }

    private static func isFailed(_ state: NWConnection.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    /// The TLS listener's `newConnectionHandler`: decide whether `newConnection`
    /// wins the session outright or must first prove itself against a still-
    /// live incumbent. Moved verbatim from `startTLSListener` — this decision
    /// reads/writes `connection`/`pendingConnections` and is inseparable from
    /// `adopt` itself.
    func handleIncomingConnection(_ newConnection: NWConnection) {
        if let current = connection, current.state != .cancelled, !Self.isFailed(current.state) {
            Log.info("reconnectDebug: incomingReplacement peer via TLS listener — parked pending proof")
            pendingConnections.append(newConnection)
            newConnection.stateUpdateHandler = { [weak self] state in
                guard let self, case .ready = state else { return }
                Task { await self.handlePendingConnectionReady(newConnection) }
            }
            newConnection.start(queue: queue)
        } else {
            Log.info("reconnectDebug: incomingReplacement peer via TLS listener")
            adopt(newConnection)
        }
    }

    private func handlePendingConnectionReady(_ pending: NWConnection) {
        hostEffects.sendHello(pending)
        pending.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { await self.finishPendingConnection(pending, data: data, isComplete: isComplete, error: error) }
        }
    }

    private func finishPendingConnection(_ pending: NWConnection, data: Data?, isComplete: Bool, error: NWError?) {
        // Only a still-tracked candidate may adopt — a rival that lost the
        // race (or was cancelled by a newer adoption in the meantime) must
        // not resurrect itself here.
        guard pendingConnections.contains(where: { $0 === pending }) else {
            pending.cancel()
            return
        }
        pendingConnections.removeAll { $0 === pending }
        if let data, !data.isEmpty {
            adopt(pending, greeted: true, initialData: data)
        } else {
            Log.info("ignored a stale TLS connection that closed at once"
                     + (error.map { " (\($0))" } ?? ""))
            pending.cancel()
        }
        _ = isComplete
    }

    /// Make `conn` the session: replace any existing connection and reset
    /// decoder state. `greeted` marks a newcomer that already got its hello
    /// while it proved itself, with the bytes it sent back in `initialData`.
    private func adopt(_ conn: NWConnection, greeted: Bool = false, initialData: Data? = nil) {
        if greeted { Log.info("newcomer proved itself — adopting it as the session") }
        let supersededGeneration = sessionState.generation
        let hadPriorConnection = connection != nil
        connection?.cancel()
        connection = conn
        // A new session supersedes any recovery run: retries scheduled
        // against the old generation can no longer win.
        cancelReconnect()
        mutateSession { $0.connectionAdopted() }
        if hadPriorConnection {
            Log.info("reconnectDebug: superseded oldGeneration=\(supersededGeneration)"
                     + " newGeneration=\(sessionState.generation)")
        }
        // Install synchronously, right here, as soon as the replacement and
        // its generation are both committed — matching the un-gated
        // (no `.ready` check) implicit-send behavior this checkpoint always
        // had, with no publication lag.
        sendTargetBox.install(StreamReceiver.SendTarget(connection: conn, generation: sessionState.generation))
        // The race is decided: rival candidates die here.
        for pending in pendingConnections where pending !== conn { pending.cancel() }
        pendingConnections.removeAll()

        // Host-owned reset — enqueued to `queue` now, strictly before `conn`
        // starts (or, if already started/ready, before any of its own
        // callbacks can reach `queue`), so it always runs first. The
        // generation travels with it (never merged with `videoGeneration`,
        // a distinct, decode-level counter) so `queue`-confined code can
        // gate on it directly instead of re-asking this actor per packet.
        let generation = sessionState.generation
        hostEffects.beginAdoption(conn, generation)

        conn.pathUpdateHandler = { [weak self] path in
            Task { await self?.handlePathUpdate(conn: conn, path: path) }
        }
        conn.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleStateUpdate(conn: conn, state: state) }
        }
        if conn.state == .ready {
            performOnReady(conn, greeted: greeted)   // already up: the handler will not fire again
        } else {
            conn.start(queue: queue)
        }
        hostEffects.finishAdoption(conn, generation, initialData)
    }

    private func handlePathUpdate(conn: NWConnection, path: NWPath) {
        guard conn === connection else { return }
        hostEffects.onPathUpdate(conn, path)
        if conn.state == .ready {
            uiEffects.setStatusConnected()
        }
    }

    private func handleStateUpdate(conn: NWConnection, state: NWConnection.State) {
        guard conn === connection else { return }   // replaced: stay quiet
        switch state {
        case .ready:
            // Reaching `.ready` only via this later callback (rather than
            // already-ready at `adopt` time) never happens for a `greeted`
            // newcomer — that path always adopts an already-`.ready`
            // connection synchronously in `adopt` itself.
            performOnReady(conn, greeted: false)
        case .failed, .cancelled:
            setConnected(false)
        default:
            break
        }
    }

    private func performOnReady(_ conn: NWConnection, greeted: Bool) {
        hostEffects.onConnectionReady(conn)
        setConnected(true)
        if !greeted { hostEffects.sendHello(conn) }
    }

    // MARK: - Session state + automatic recovery

    /// Apply one transition to the authoritative session state, publish it,
    /// and let the recovery driver react. Every call happens synchronously
    /// within this actor's isolation — no interleaving is possible mid-
    /// transition.
    private func mutateSession(_ transition: (inout ReceiverSessionState) -> Bool) {
        let previous = sessionState.phase
        let changed = transition(&sessionState)
        let snapshot = sessionState
        uiEffects.publishSessionSnapshot(snapshot)
        guard changed else { return }
        #if DEBUG
        Log.info("sessionState: \(previous.rawValue) -> \(snapshot.phase.rawValue)"
                 + " reason=\(snapshot.lossReason?.rawValue ?? "none")"
                 + " generation=\(snapshot.generation)"
                 + " attempt=\(snapshot.reconnectAttempt)")
        #else
        Log.info("sessionState: \(previous.rawValue) -> \(snapshot.phase.rawValue)"
                 + " reason=\(snapshot.lossReason?.rawValue ?? "none")")
        #endif
        if snapshot.phase == .reconnecting {
            armReconnect()
        } else {
            cancelReconnect()
        }
    }

    private func cancelReconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    /// Auto-Reconnect turned off mid-recovery: settle into the stable
    /// "Connection Lost" state immediately.
    func cancelAutomaticRecoveryIfNeeded() {
        guard sessionState.phase == .reconnecting else { return }
        Log.info("reconnectPolicy: automaticRetry cancelled reason=disabled")
        mutateSession { $0.exhaustRecovery() }
        uiEffects.setStatus("Connection lost")
    }

    /// One automatic recovery step. Never starts a second attempt or timer.
    private func armReconnect() {
        cancelReconnect()
        guard sessionState.phase == .reconnecting else { return }
        let delay = sessionState.nextReconnectDelay
        guard let attempt = sessionState.beginReconnectAttempt() else {
            mutateSession { $0.exhaustRecovery() }
            Log.info("reconnectDebug: retryExhausted generation=\(sessionState.generation)")
            uiEffects.setStatus("Connection lost")
            return
        }
        let generation = sessionState.generation
        uiEffects.publishSessionSnapshot(sessionState)
        Log.info("reconnect attempt \(attempt)/\(ReceiverSessionState.maximumReconnectAttempts)"
                 + " generation=\(generation) in \(delay)s")
        Log.info("reconnectDebug: attemptStarted generation=\(generation) attempt=\(attempt) delay=\(delay)")
        uiEffects.setStatus("Reconnecting…")
        hostEffects.ensureTLSListening()
        let reconnect = reconnectContext.current()
        if let peerID = reconnect.manualConnectPeerID ?? reconnect.authenticatedPeerIDHint ?? recoveryPeerID {
            hostEffects.requestRemoteConnect(peerID)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            Task { await self?.reconnectAttemptTimedOut(generation: generation) }
        }
        timer.resume()
        reconnectTimer = timer
        Log.info("reconnectDebug: retryScheduled generation=\(generation) in \(delay)s")
    }

    private func reconnectAttemptTimedOut(generation: Int) {
        guard sessionState.generation == generation else { return }
        _ = sessionState.endReconnectAttempt()
        armReconnect()
    }

    /// The user tapped Reconnect, or `requestConnect()`'s receiver-originated
    /// Connect signal. Runs one clean recovery run through exactly the same
    /// path as automatic recovery.
    func requestManualReconnectTransition() {
        mutateSession { $0.requestManualReconnect() }
    }

    /// The Mac's `displayState` pause/resume — a later-stage (control-
    /// message) concern that still needs to drive this one session
    /// transition. Pause is intentional, never a failure, so it must never
    /// start automatic recovery; `displayPaused()`/`displayResumed()`
    /// already encode that.
    func applyDisplayPauseTransition(paused: Bool) {
        mutateSession { paused ? $0.displayPaused() : $0.displayResumed() }
    }

    func suspendReconnectForBackground() {
        cancelReconnect()
        // Deliberately not through `mutateSession`: the phase is unchanged
        // (still reconnecting), and its reactive arm would immediately
        // schedule the very attempt this is parking.
        guard sessionState.suspendRecoveryForBackground() else { return }
        Log.info("sessionState: recovery parked for background"
                 + " generation=\(sessionState.generation)"
                 + " attempt=\(sessionState.reconnectAttempt)")
        uiEffects.publishSessionSnapshot(sessionState)
    }

    func resumeReconnectIfNeeded() {
        guard sessionState.phase == .reconnecting, reconnectTimer == nil else { return }
        armReconnect()
    }

    var currentPhase: ReceiverSessionPhase { sessionState.phase }

    // MARK: - Connect / disconnect funnel

    /// The single funnel for connection up/down. `reason` classifies a loss
    /// so the session state can tell an interruption worth recovering from
    /// apart from a deliberate end.
    func setConnected(_ value: Bool, reason: ReceiverSessionLossReason = .transportLost) {
        let peerID = reconnectContext.current().authenticatedPeerIDHint
        uiEffects.applyConnectedUIMirror(value)
        if !value {
            let oldGeneration = sessionState.generation
            // Clearing here, synchronously, covers every "connection went
            // away" path (explicit disconnect, watchdog drop, peer close,
            // receive error/EOF) uniformly. Guarded by generation so a clear
            // racing a newer adopt() can never remove a target that has
            // already superseded this one.
            sendTargetBox.clear(forGeneration: oldGeneration)
            hostEffects.clearTransport()
            let peerIsIncompatible = reconnectContext.current().peerIsIncompatible
            let classified: ReceiverSessionLossReason = {
                guard peerIsIncompatible, reason == .transportLost else { return reason }
                return .protocolIncompatible
            }()
            let wasConnected = sessionState.phase == .connected || sessionState.phase == .paused
            Log.info("reconnectDebug: lost reason=\(classified.rawValue) oldGeneration=\(oldGeneration)")
            let staleAfterIntent = classified == .transportLost
                && (sessionState.lossReason == .explicitDisconnect || sessionState.lossReason == .peerClosed)
                && (sessionState.phase == .disconnected || sessionState.phase == .peerDisconnected)
            if staleAfterIntent {
                Log.info("connectDebug: ignored stale transportLost after explicit disconnect generation=\(oldGeneration)")
            } else if classified == .explicitDisconnect {
                Log.info("connectDebug: localExplicitDisconnect generation=\(oldGeneration)")
                recoveryPeerID = nil
            } else {
                recoveryPeerID = peerID
            }
            mutateSession { $0.connectionLost(reason: classified,
                                              autoReconnectPreferenceEnabled: reconnectContext.current().autoReconnectPreferenceEnabled) }
            if sessionState.phase != .reconnecting {
                if classified == .peerClosed {
                    uiEffects.setStatus("Mac Disconnected")
                } else {
                    uiEffects.setStatus(wasConnected && classified != .explicitDisconnect
                        ? "Connection lost" : "Waiting for Mac")
                }
            }
        } else {
            recoveryPeerID = nil
            // The box, not `StreamReceiver` directly — this actor is one of
            // its true owners for this one field (the other is the host
            // write sites below `StreamReceiver.reconnectContext`).
            reconnectContext.update { $0.peerIsIncompatible = false }
            mutateSession { $0.connectionEstablished() }
            Log.info("reconnectDebug: authenticated generation=\(sessionState.generation)")
            uiEffects.setStatusConnected()
            if !UserDefaults.standard.bool(forKey: "hasConnectedBefore") {
                UserDefaults.standard.set(true, forKey: "hasConnectedBefore")
            }
        }
    }

    /// Explicit teardown of the live connection (Forget, Disconnect,
    /// explicit-pairing suppression, the Mac's own `closing` message, the
    /// watchdog's stale-link drop): cancel it, clear the field, cancel any
    /// scheduled retry, then run it through the same `setConnected` funnel.
    func disconnectCurrentConnection(reason: ReceiverSessionLossReason) {
        connection?.cancel()
        connection = nil
        cancelReconnect()
        setConnected(false, reason: reason)
    }
}
