package com.raisecaterror.meowdisplay.core.remote

import com.raisecaterror.meowdisplay.core.session.SessionLossReason

/**
 * When this device may knock again after a remote session dropped. Pure (the caller supplies the
 * clock, in milliseconds), so it is tested with a fake one. It only ever schedules `automatic`
 * knocks; an explicit Connect is a separate, `manual` request.
 *
 * Bounded for the battery and for the Mac: backoff attempts for about three minutes, one extra
 * immediate attempt per network change within ten minutes of the drop, never closer together than
 * the Mac's own 5 s limit, one at a time.
 */
class RemoteRecoveryPolicy(private val config: Config = Config()) {
    data class Config(
        val backoffMs: List<Long> = listOf(2_000, 5_000, 10_000, 20_000, 30_000),
        val backoffWindowMs: Long = 180_000,
        val networkWindowMs: Long = 600_000,
        /** The Mac ignores knocks closer than this (RemoteConnectRequestPolicy.minimumInterval). */
        val minSpacingMs: Long = 5_000,
        val maxNetworkAttempts: Int = 3,
        /** After a delivered knock the Mac gets this long to dial back before it is asked again. */
        val afterDeliveredMs: Long = 20_000,
    )

    /** Everything that decides whether a dropped session starts recovery. */
    data class DropContext(
        val reason: SessionLossReason,
        /** The session that dropped came over Remote Access (a knock, a VPN/Tailscale/cellular path or a non-local address). */
        val wasRemote: Boolean,
        val autoReconnectEnabled: Boolean,
        val foreground: Boolean,
        val hasSavedAddress: Boolean,
        val stillPaired: Boolean,
        /** Bonjour shows the Mac locally: the normal local path takes over, no knock. */
        val nearby: Boolean,
        /** Another Mac's session is live: recovery must not compete with it. */
        val otherSessionLive: Boolean,
    )

    sealed interface Step {
        /** Nothing more to do; the run is over (or none was started). */
        data object Idle : Step

        /** Knock again at [atMs] (not before). */
        data class Wait(val atMs: Long) : Step

        /** Nothing is scheduled but a network change can still trigger one until [untilMs]. */
        data class Dormant(val untilMs: Long) : Step
    }

    class Run internal constructor(val peerID: String, val startedAt: Long) {
        internal var attempts = 0
        internal var nextBackoffAt: Long? = null
        internal var kickAt: Long? = null
        internal var networkAttempts = 0
        internal var lastKnockAt: Long? = null
        internal var inFlight = false
        internal var stopped = false
    }

    var run: Run? = null
        private set

    fun shouldStart(context: DropContext): Boolean = with(context) {
        reason.automaticallyRecoverable && wasRemote && autoReconnectEnabled && foreground &&
            hasSavedAddress && stillPaired && !nearby && !otherSessionLive
    }

    /** Begins a run for [peerID]; any earlier run is replaced. The first knock is due after the first backoff. */
    fun start(peerID: String, now: Long): Run {
        val started = Run(peerID, now)
        started.nextBackoffAt = now + config.backoffMs.first()
        run = started
        return started
    }

    fun stop() {
        run?.stopped = true
        run = null
    }

    /** What to do now. A knock in flight is never joined by another. */
    fun next(now: Long): Step {
        val current = run ?: return Step.Idle
        if (current.stopped) return Step.Idle
        val windowEnd = current.startedAt + config.networkWindowMs
        if (now >= windowEnd) {
            stop()
            return Step.Idle
        }
        if (current.inFlight) return Step.Wait(now + 250)
        val backoff = current.nextBackoffAt?.takeIf { it < current.startedAt + config.backoffWindowMs }
        val due = listOfNotNull(backoff, current.kickAt).minOrNull()
            ?: return Step.Dormant(windowEnd)
        return Step.Wait(maxOf(due, current.lastKnockAt?.plus(config.minSpacingMs) ?: due))
    }

    fun knockStarted(now: Long) {
        val current = run ?: return
        current.inFlight = true
        current.lastKnockAt = now
        current.attempts++
        val kick = current.kickAt
        if (kick != null && now >= kick) {
            current.kickAt = null
            current.networkAttempts++
        }
    }

    /** A knock ended. A security failure ends the run; everything else schedules the next backoff attempt. */
    fun knockFinished(now: Long, result: KnockResult) {
        val current = run ?: return
        current.inFlight = false
        if (result.isSecurityFailure || result == KnockResult.Cancelled) {
            stop()
            return
        }
        val index = minOf(current.attempts, config.backoffMs.size - 1)
        val delay = config.backoffMs[index]
        current.nextBackoffAt = now + if (result == KnockResult.Delivered) maxOf(delay, config.afterDeliveredMs) else delay
    }

    /**
     * The default network changed (or its link properties did). Within the window this brings the
     * next attempt forward to now (never closer to the last knock than the Mac allows). A burst of
     * changes is one attempt, and the number per run is capped.
     */
    fun networkChanged(now: Long): Boolean {
        val current = run ?: return false
        if (current.stopped || now >= current.startedAt + config.networkWindowMs) return false
        if (current.kickAt != null || current.networkAttempts >= config.maxNetworkAttempts) return false
        current.kickAt = now
        return true
    }
}
