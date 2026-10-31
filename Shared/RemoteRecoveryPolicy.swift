import Foundation

/// When this device may knock again after a session dropped (Android: RemoteRecoveryPolicy.kt,
/// the same schedule and rules). Pure: the caller supplies the clock, in milliseconds, so it is
/// tested with a fake one. It only ever schedules `automatic` knocks; an explicit Connect is a
/// separate, `manual` request.
///
/// Bounded for the battery and for the Mac: backoff attempts for about three minutes, one extra
/// immediate attempt per network change within ten minutes of the drop, never closer together
/// than the Mac's own 5 s limit, one at a time.
///
/// A LOCAL session that drops is recovered the same way when the Mac has a saved Remote address
/// (Wi-Fi lost, phone now on cellular + Tailscale): the run starts, but it only knocks while the
/// local network no longer shows the Mac, so the local path (the Mac redialing over Wi-Fi) stays
/// first.
final class RemoteRecoveryPolicy {
    struct Config: Sendable {
        var backoffMs: [Int64] = [2_000, 5_000, 10_000, 20_000, 30_000]
        var backoffWindowMs: Int64 = 180_000
        var networkWindowMs: Int64 = 600_000
        /// The Mac ignores knocks closer than this (`RemoteConnectRequestPolicy.minimumInterval`).
        var minSpacingMs: Int64 = 5_000
        var maxNetworkAttempts = 3
        /// After a delivered knock the Mac gets this long to dial back before it is asked again.
        var afterDeliveredMs: Int64 = 20_000
    }

    /// Everything that decides whether a dropped session starts recovery.
    struct DropContext: Sendable {
        /// The loss is one automatic recovery applies to (not an explicit disconnect, the Mac
        /// closing, or an incompatible peer).
        var automaticallyRecoverable: Bool
        /// The session came over Remote Access (a knock, a VPN/Tailscale/cellular path or a
        /// non-local address). False for a local Wi-Fi session, which may still fall back to Remote.
        var wasRemote: Bool
        var autoReconnectEnabled: Bool
        var foreground: Bool
        var hasSavedAddress: Bool
        var stillPaired: Bool
        /// The local network shows the Mac: the normal local path takes over, no knock.
        var nearby: Bool
        /// Another Mac's session is live: recovery must not compete with it.
        var otherSessionLive: Bool
    }

    enum Step: Equatable, Sendable {
        /// Nothing more to do; the run is over (or none was started).
        case idle
        /// Knock again at `atMs` (not before).
        case wait(atMs: Int64)
        /// Nothing is scheduled, but a network change can still trigger one until `untilMs`.
        case dormant(untilMs: Int64)
    }

    /// `fromLocal`: the session that dropped was local. Such a run waits while the Mac is nearby
    /// (the local path is first) instead of ending.
    final class Run {
        let peerID: String
        let startedAt: Int64
        let fromLocal: Bool
        fileprivate(set) var attempts = 0
        fileprivate var nextBackoffAt: Int64?
        fileprivate var kickAt: Int64?
        fileprivate var networkAttempts = 0
        fileprivate(set) var lastKnockAt: Int64?
        fileprivate var inFlight = false
        fileprivate var stopped = false

        fileprivate init(peerID: String, startedAt: Int64, fromLocal: Bool) {
            self.peerID = peerID
            self.startedAt = startedAt
            self.fromLocal = fromLocal
        }
    }

    let config: Config
    private(set) var run: Run?

    init(config: Config = Config()) { self.config = config }

    func shouldStart(_ c: DropContext) -> Bool {
        // A remote drop with the Mac visible locally: the local path takes over, no run. A local
        // drop starts regardless (the network may still list a Mac this device just lost); it waits
        // while nearby.
        c.automaticallyRecoverable && c.autoReconnectEnabled && c.foreground &&
            c.hasSavedAddress && c.stillPaired && !c.otherSessionLive && (!c.wasRemote || !c.nearby)
    }

    /// Begins a run for `peerID`; any earlier run is replaced. The first knock is due after the
    /// first backoff.
    @discardableResult
    func start(peerID: String, now: Int64, fromLocal: Bool = false) -> Run {
        let started = Run(peerID: peerID, startedAt: now, fromLocal: fromLocal)
        started.nextBackoffAt = now + config.backoffMs[0]
        run = started
        return started
    }

    func stop() {
        run?.stopped = true
        run = nil
    }

    /// What to do now. A knock in flight is never joined by another.
    func next(now: Int64) -> Step {
        guard let current = run, !current.stopped else { return .idle }
        let windowEnd = current.startedAt + config.networkWindowMs
        if now >= windowEnd {
            stop()
            return .idle
        }
        if current.inFlight { return .wait(atMs: now + 250) }
        let backoff = current.nextBackoffAt.flatMap { $0 < current.startedAt + config.backoffWindowMs ? $0 : nil }
        guard let due = [backoff, current.kickAt].compactMap({ $0 }).min() else { return .dormant(untilMs: windowEnd) }
        return .wait(atMs: max(due, current.lastKnockAt.map { $0 + config.minSpacingMs } ?? due))
    }

    func knockStarted(now: Int64) {
        guard let current = run else { return }
        current.inFlight = true
        current.lastKnockAt = now
        current.attempts += 1
        if let kick = current.kickAt, now >= kick {
            current.kickAt = nil
            current.networkAttempts += 1
        }
    }

    /// A due attempt of a `fromLocal` run was not sent because the Mac is still nearby: the next
    /// one follows the backoff as if it had been tried. Nothing reaches the Mac.
    func skippedWhileNearby(now: Int64) {
        guard let current = run else { return }
        if let kick = current.kickAt, now >= kick { current.kickAt = nil }
        // Counted like a knock, so the next gap is the one knockFinished would have used.
        current.attempts += 1
        current.nextBackoffAt = now + config.backoffMs[min(current.attempts, config.backoffMs.count - 1)]
    }

    /// A knock ended. A security failure ends the run; everything else schedules the next backoff
    /// attempt.
    func knockFinished(now: Int64, result: RemoteKnockResult) {
        guard let current = run else { return }
        current.inFlight = false
        if result.isSecurityFailure || result == .cancelled {
            stop()
            return
        }
        let delay = config.backoffMs[min(current.attempts, config.backoffMs.count - 1)]
        current.nextBackoffAt = now + (result == .delivered ? max(delay, config.afterDeliveredMs) : delay)
    }

    /// The default network changed. Within the window this brings the next attempt forward to now
    /// (never closer to the last knock than the Mac allows). A burst of changes is one attempt,
    /// and the number per run is capped.
    @discardableResult
    func networkChanged(now: Int64) -> Bool {
        guard let current = run, !current.stopped, now < current.startedAt + config.networkWindowMs,
              current.kickAt == nil, current.networkAttempts < config.maxNetworkAttempts else { return false }
        current.kickAt = now
        return true
    }
}
