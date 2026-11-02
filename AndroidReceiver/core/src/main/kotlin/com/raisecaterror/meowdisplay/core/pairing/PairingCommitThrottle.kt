package com.raisecaterror.meowdisplay.core.pairing

/**
 * Responder-side anti-reroll throttle for the commit/reveal phase
 * (Shared/RemotePairing.swift `PairingCommitThrottle`). Scoped to the
 * listener, never to a source address: one commitment in flight, and three
 * failed reveals in a row cool the listener down for 30 seconds. Only a fully
 * authenticated pairing forgives earlier failures.
 */
class PairingCommitThrottle(private val now: () -> Long = System::currentTimeMillis) {
    companion object {
        const val REVEAL_DEADLINE_MS = 5_000L
        const val FAILURES_BEFORE_COOLDOWN = 3
        const val COOLDOWN_MS = 30_000L
    }

    sealed interface Admission {
        data class Admitted(val token: Long) : Admission
        data object Busy : Admission
        data object CoolingDown : Admission
    }

    private var unrevealedInProgress = false
    private var consecutiveFailures = 0
    private var cooldownUntil: Long? = null
    private var generation = 0L

    @Synchronized
    fun admitCommitment(): Admission {
        cooldownUntil?.let { if (now() < it) return Admission.CoolingDown }
        if (unrevealedInProgress) return Admission.Busy
        unrevealedInProgress = true
        generation += 1
        return Admission.Admitted(generation)
    }

    /** A valid reveal arrived. Deliberately keeps the failure count. */
    @Synchronized
    fun revealSucceeded() {
        unrevealedInProgress = false
    }

    @Synchronized
    fun revealFailed() {
        unrevealedInProgress = false
        consecutiveFailures += 1
        if (consecutiveFailures >= FAILURES_BEFORE_COOLDOWN) {
            consecutiveFailures = 0
            cooldownUntil = now() + COOLDOWN_MS
        }
    }

    /**
     * A code was shown and nothing was paired (declined, timed out, aborted by the peer or
     * failed later): counts toward the cooldown like a failed reveal, so a peer can't raise
     * prompt after prompt by aborting and starting over. Shared/RemotePairing.swift twin.
     */
    @Synchronized
    fun codeShownWithoutPairing() {
        consecutiveFailures += 1
        if (consecutiveFailures >= FAILURES_BEFORE_COOLDOWN) {
            consecutiveFailures = 0
            cooldownUntil = now() + COOLDOWN_MS
        }
    }

    /** Only the admission that just completed pairing may clear the history. */
    @Synchronized
    fun pairingSucceeded(token: Long) {
        if (token != generation) return
        consecutiveFailures = 0
        cooldownUntil = null
    }
}
