package com.raisecaterror.meowdisplay.core.session

import kotlin.math.min
import kotlin.math.pow

// The receiver's one answer to "what is happening to my connection?"
// (Shared/ReceiverSessionState.swift). The receiver listens and the Mac
// dials, so a "reconnect attempt" here is a bounded window waiting for the
// Mac's own redial, not a dial.

enum class SessionLossReason(val automaticallyRecoverable: Boolean) {
    /** The socket died, the watchdog fired, or the peer vanished. */
    TransportLost(true),
    /** The listener itself could not be (re)established. */
    ListenerFailed(true),
    /** The Mac deliberately closed the session. */
    PeerClosed(false),
    /** This device ended the session (stop, lock, quit). */
    ExplicitDisconnect(false),
    /** The peer speaks a protocol version we cannot work with. */
    ProtocolIncompatible(false),
}

enum class SessionPhase { Disconnected, Connecting, Connected, Paused, Reconnecting, ReconnectFailed, Unrecoverable, PeerDisconnected }

class ReceiverSessionState {
    var phase = SessionPhase.Disconnected
        private set
    var lossReason: SessionLossReason? = null
        private set
    var reconnectAttempt = 0
        private set

    /** Bumped on every replacement and loss; late work for an older generation drops itself. */
    var generation = 0
        private set
    var hasEverConnected = false
        private set
    var automaticReconnectEnabled = true
        private set
    var reconnectAttemptInFlight = false
        private set

    /** Live input may only reach the Mac on a fully established session. */
    val allowsLiveInput: Boolean get() = phase == SessionPhase.Connected

    /** Recovery must never flash back to the home screen between retries. */
    val retainsReceiverSurface: Boolean
        get() = when (phase) {
            SessionPhase.Connected, SessionPhase.Paused, SessionPhase.Reconnecting, SessionPhase.ReconnectFailed,
            SessionPhase.Unrecoverable, SessionPhase.PeerDisconnected -> true
            SessionPhase.Connecting -> hasEverConnected
            SessionPhase.Disconnected -> false
        }

    val nextReconnectDelayMs: Long
        get() = min(BASE_DELAY_MS * 2.0.pow(reconnectAttempt), MAX_DELAY_MS.toDouble()).toLong()

    val hasExhaustedReconnectAttempts: Boolean get() = reconnectAttempt >= MAX_ATTEMPTS

    fun connectionAdopted(): Boolean {
        if (phase == SessionPhase.Connecting) return false
        phase = SessionPhase.Connecting
        lossReason = null
        generation++
        reconnectAttemptInFlight = false
        return true
    }

    fun connectionEstablished(): Boolean {
        val changed = phase != SessionPhase.Connected
        phase = SessionPhase.Connected
        lossReason = null
        reconnectAttempt = 0
        reconnectAttemptInFlight = false
        automaticReconnectEnabled = true
        hasEverConnected = true
        return changed
    }

    /** The Mac paused capture: intentional, never starts recovery. */
    fun displayPaused(): Boolean {
        if (phase != SessionPhase.Connected) return false
        phase = SessionPhase.Paused
        return true
    }

    fun displayResumed(): Boolean {
        if (phase != SessionPhase.Paused) return false
        phase = SessionPhase.Connected
        return true
    }

    fun connectionLost(reason: SessionLossReason, autoReconnectPreferenceEnabled: Boolean = true): Boolean {
        // A late or duplicate report never restarts a run or re-enters a terminal state.
        if (reason.automaticallyRecoverable &&
            phase in setOf(SessionPhase.ReconnectFailed, SessionPhase.Unrecoverable, SessionPhase.Reconnecting)
        ) return false
        // The EOF after a deliberate close is the same teardown, not a fresh loss.
        if (reason.automaticallyRecoverable &&
            (phase == SessionPhase.Disconnected || phase == SessionPhase.PeerDisconnected) &&
            (lossReason == SessionLossReason.ExplicitDisconnect || lossReason == SessionLossReason.PeerClosed)
        ) return false
        val previous = phase
        generation++
        reconnectAttemptInFlight = false
        phase = when (reason) {
            SessionLossReason.ExplicitDisconnect -> {
                automaticReconnectEnabled = false
                reconnectAttempt = 0
                SessionPhase.Disconnected
            }
            SessionLossReason.ProtocolIncompatible -> SessionPhase.Unrecoverable
            SessionLossReason.PeerClosed -> {
                reconnectAttempt = 0
                automaticReconnectEnabled = false
                SessionPhase.PeerDisconnected
            }
            SessionLossReason.TransportLost, SessionLossReason.ListenerFailed ->
                if (hasEverConnected && automaticReconnectEnabled && autoReconnectPreferenceEnabled) {
                    reconnectAttempt = 0
                    SessionPhase.Reconnecting
                } else {
                    SessionPhase.Disconnected
                }
        }
        lossReason = reason
        return phase != previous
    }

    /** The 1-based attempt number, or null when recovery is over, disabled, or already in flight. */
    fun beginReconnectAttempt(): Int? {
        if (phase != SessionPhase.Reconnecting || !automaticReconnectEnabled || reconnectAttemptInFlight ||
            hasExhaustedReconnectAttempts
        ) return null
        reconnectAttemptInFlight = true
        return ++reconnectAttempt
    }

    fun endReconnectAttempt(): Boolean {
        if (!reconnectAttemptInFlight) return false
        reconnectAttemptInFlight = false
        return true
    }

    fun exhaustRecovery(): Boolean {
        if (phase != SessionPhase.Reconnecting) return false
        phase = SessionPhase.ReconnectFailed
        reconnectAttemptInFlight = false
        return true
    }

    fun requestManualReconnect(): Boolean {
        if (phase !in setOf(SessionPhase.ReconnectFailed, SessionPhase.Disconnected, SessionPhase.PeerDisconnected)) return false
        phase = SessionPhase.Reconnecting
        lossReason = SessionLossReason.TransportLost
        reconnectAttempt = 0
        reconnectAttemptInFlight = false
        automaticReconnectEnabled = true
        generation++
        return true
    }

    companion object {
        // 0.5 + 1 + 2 + 4 + 8 + 8 s outlives the Mac's 10 s grace and 1 s redial, then stops.
        const val MAX_ATTEMPTS = 6
        const val BASE_DELAY_MS = 500L
        const val MAX_DELAY_MS = 8_000L
    }
}
