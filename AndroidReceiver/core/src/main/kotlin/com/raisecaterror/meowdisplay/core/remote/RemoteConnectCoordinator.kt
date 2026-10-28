package com.raisecaterror.meowdisplay.core.remote

import com.raisecaterror.meowdisplay.core.session.DisplayMode
import com.raisecaterror.meowdisplay.core.session.SessionLossReason
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Remote Access for the receiver: what a Connect does when the Mac isn't on this network, and how
 * a dropped remote session is recovered. It sends knocks (see [RemoteKnocker]) and tracks their
 * REAL outcomes for the home rows; it never connects anything itself (the Mac dials this device,
 * which then admits it through the normal pinned-TLS listener and session invitation), grants
 * nothing, and trusts nothing: an address is a hint, the pin decides.
 *
 * Stale work is ignored. Every explicit action, Forget, cancel and admitted session bumps the
 * Mac's generation, so a knock result or dial-back timer that arrives afterwards changes nothing.
 */
class RemoteConnectCoordinator(
    private val scope: CoroutineScope,
    private val nowMs: () -> Long,
    private val store: RemoteMacStore,
    private val knocker: RemoteKnocker,
    private val host: Host,
    private val policy: RemoteRecoveryPolicy = RemoteRecoveryPolicy(),
) {
    /** What the coordinator needs to know about the rest of the app. */
    interface Host {
        fun isPaired(peerID: String): Boolean

        /** Bonjour currently shows this Mac on the local network. */
        fun isNearby(peerID: String): Boolean

        fun autoReconnectEnabled(): Boolean

        /** The peer of the admitted session, or null. */
        fun liveSessionPeer(): String?

        /** Marks the existing Connect request pending for [peerID] (so `hello.requestedMode` and the UI follow it), without advertising a token. */
        fun markConnectPending(peerID: String, mode: DisplayMode?)

        fun clearConnectPending(peerID: String)

        /** Never receives an address, a key or a code: host kinds only. */
        fun log(message: String)
    }

    enum class ConnectOutcome { Started, NoSavedAddress, NotPaired }

    private val lock = Any()
    private val state = MutableStateFlow<Map<String, RemoteAttempt>>(emptyMap())

    /** The last remote attempt per Mac, for the home rows. */
    val attempts: StateFlow<Map<String, RemoteAttempt>> = state.asStateFlow()

    private val generations = HashMap<String, Long>()
    private val dialBackTimers = HashMap<String, Job>()
    private val remoteSessions = HashSet<String>()
    private val wakeups = Channel<Unit>(Channel.CONFLATED)
    private var recovery: Job? = null
    private var recoveryGeneration = 0L
    private var recoveryFailure: RemoteAttempt? = null
    private var deliveredAt: Long? = null
    private var foreground = true
    private var backgrounding = false
    private var resume: Pair<String, Long>? = null

    // MARK: - Connect

    /**
     * An explicit Connect for a Mac that isn't nearby: one `manual` knock to its saved address, and
     * the existing Connect request marked pending so the hello and the UI follow it.
     */
    fun connect(peerID: String, mode: DisplayMode? = null): ConnectOutcome {
        if (!host.isPaired(peerID)) return ConnectOutcome.NotPaired
        val endpoint = store.endpoint(peerID) ?: return ConnectOutcome.NoSavedAddress
        val generation: Long
        synchronized(lock) {
            generation = bump(peerID)
            stopRecoveryLocked()
            resume = null
            set(peerID, RemoteAttempt.Knocking(automatic = false))
        }
        host.markConnectPending(peerID, mode)
        host.log("remote connect: manual knock, host=${IpLiteral.logKind(endpoint.host)}")
        val result = knocker.knock(peerID, endpoint, KnockIntent.Manual)
        scope.launch { deliver(peerID, generation, result.await()) }
        return ConnectOutcome.Started
    }

    private fun deliver(peerID: String, generation: Long, result: KnockResult) {
        var clearPending = false
        synchronized(lock) {
            // Forgotten, cancelled, answered or retried in the meantime: this result is history.
            if (generations[peerID] != generation || !host.isPaired(peerID)) return
            host.log("remote connect: knock ${describe(result)}")
            when (result) {
                KnockResult.Delivered -> {
                    set(peerID, RemoteAttempt.WaitingForDialBack)
                    startDialBackTimer(peerID, generation)
                }
                KnockResult.Cancelled -> {
                    clear(peerID)
                    clearPending = true
                }
                else -> {
                    set(peerID, failure(result))
                    clearPending = true
                }
            }
        }
        if (clearPending) host.clearConnectPending(peerID)
    }

    private fun startDialBackTimer(peerID: String, generation: Long) {
        dialBackTimers.remove(peerID)?.cancel()
        dialBackTimers[peerID] = scope.launch {
            delay(DIAL_BACK_MS)
            var missed = false
            synchronized(lock) {
                if (generations[peerID] == generation && state.value[peerID] == RemoteAttempt.WaitingForDialBack) {
                    set(peerID, RemoteAttempt.DialBackMissed)
                    dialBackTimers.remove(peerID)
                    missed = true
                }
            }
            if (missed) {
                host.log("remote connect: no dial-back within ${DIAL_BACK_MS / 1000}s")
                host.clearConnectPending(peerID)
            }
        }
    }

    private fun failure(result: KnockResult): RemoteAttempt = when (result) {
        KnockResult.DnsFailed -> RemoteAttempt.Offline(OfflineReason.Dns)
        KnockResult.TimedOut -> RemoteAttempt.Offline(OfflineReason.TimedOut)
        KnockResult.Refused -> RemoteAttempt.Offline(OfflineReason.Refused)
        KnockResult.Unreachable -> RemoteAttempt.Offline(OfflineReason.Unreachable)
        is KnockResult.IdentityMismatch -> RemoteAttempt.DifferentMac(result.otherPeerID)
        KnockResult.NotAccepted -> RemoteAttempt.NotAccepted
        else -> RemoteAttempt.Offline(OfflineReason.Failed)
    }

    private fun describe(result: KnockResult) = when (result) {
        is KnockResult.IdentityMismatch -> "IdentityMismatch"
        else -> result.toString().removePrefix("KnockResult.")
    }

    /** The user's Cancel (or leaving the attempt): the knock stops and nothing it did is waited for. */
    fun cancel(peerID: String) {
        synchronized(lock) {
            bump(peerID)
            stopRecoveryLocked()
            resume = null
            clear(peerID)
        }
        knocker.cancel(peerID)
        host.clearConnectPending(peerID)
    }

    /** Forget: everything about the Mac's remote attempts ends, and its saved address goes. */
    fun onForget(peerID: String) {
        synchronized(lock) {
            bump(peerID)
            if (recovery != null && policy.run?.peerID == peerID) stopRecoveryLocked()
            if (resume?.first == peerID) resume = null
            remoteSessions.remove(peerID)
            clear(peerID)
        }
        knocker.cancel(peerID)
        store.forget(peerID)
        host.clearConnectPending(peerID)
    }

    // MARK: - Session events

    /** This Mac's session was admitted. [remote]: it came over Remote Access (see RouteClassifier). */
    fun onAdmitted(peerID: String, remote: Boolean) {
        synchronized(lock) {
            bump(peerID)
            // A live session ends every recovery: this Mac's is answered, another Mac's must not compete.
            stopRecoveryLocked()
            resume = null
            clear(peerID)
            if (remote) remoteSessions += peerID else remoteSessions -= peerID
        }
        knocker.cancel(peerID)
    }

    /** True while a knock this device sent is still being answered (used to label the session Remote). */
    fun isKnockPending(peerID: String): Boolean = state.value[peerID].let {
        it is RemoteAttempt.Knocking || it == RemoteAttempt.WaitingForDialBack || it == RemoteAttempt.Recovering
    }

    /** The live session for [peerID] ended. A dropped remote session starts bounded automatic recovery. */
    fun onSessionLost(peerID: String, reason: SessionLossReason) {
        val context: RemoteRecoveryPolicy.DropContext
        synchronized(lock) {
            val wasRemote = remoteSessions.remove(peerID)
            if (reason == SessionLossReason.ExplicitDisconnect && !backgrounding) {
                // The user's Disconnect (or a Forget/Block revoke): never recovered.
                resume = null
            }
            context = RemoteRecoveryPolicy.DropContext(
                reason = reason, wasRemote = wasRemote, autoReconnectEnabled = host.autoReconnectEnabled(),
                foreground = foreground, hasSavedAddress = store.endpoint(peerID) != null, stillPaired = host.isPaired(peerID),
                nearby = host.isNearby(peerID), otherSessionLive = host.liveSessionPeer()?.let { it != peerID } == true,
            )
            if (!policy.shouldStart(context)) return
            startRecoveryLocked(peerID)
        }
    }

    // MARK: - Lifecycle and environment

    /** The app left the foreground. Recovery stops; a live remote session is remembered for the way back. */
    fun onBackground(liveRemotePeer: String?) {
        synchronized(lock) {
            foreground = false
            backgrounding = true
            stopRecoveryLocked()
            if (liveRemotePeer != null) resume = liveRemotePeer to nowMs()
        }
    }

    /** Back in front: a remote session that was running when the app left gets one bounded recovery. */
    fun onForeground() {
        synchronized(lock) {
            foreground = true
            backgrounding = false
            val (peerID, since) = resume ?: return
            resume = null
            if (nowMs() - since > RESUME_WINDOW_MS || host.liveSessionPeer() != null) return
            val context = RemoteRecoveryPolicy.DropContext(
                reason = SessionLossReason.TransportLost, wasRemote = true, autoReconnectEnabled = host.autoReconnectEnabled(),
                foreground = true, hasSavedAddress = store.endpoint(peerID) != null, stillPaired = host.isPaired(peerID),
                nearby = host.isNearby(peerID), otherSessionLive = false,
            )
            if (policy.shouldStart(context)) startRecoveryLocked(peerID)
        }
    }

    /** The default network appeared or changed. Brings one recovery attempt forward; otherwise does nothing. */
    fun onNetworkChanged() {
        synchronized(lock) {
            if (!foreground) return
            if (policy.networkChanged(nowMs())) wakeups.trySend(Unit)
        }
    }

    /** Bonjour's current view: a Mac that shows up locally lets the normal local path take over, with no knock. */
    fun onNearbyChanged() {
        synchronized(lock) {
            val peerID = policy.run?.peerID ?: return
            if (host.isNearby(peerID)) {
                stopRecoveryLocked()
                if (state.value[peerID] == RemoteAttempt.Recovering) clear(peerID)
            }
        }
    }

    // MARK: - Recovery

    private fun startRecoveryLocked(peerID: String) {
        stopRecoveryLocked()
        val mine = ++recoveryGeneration
        recoveryFailure = null
        deliveredAt = null
        policy.start(peerID, nowMs())
        set(peerID, RemoteAttempt.Recovering)
        host.log("remote recovery: started")
        recovery = scope.launch { recoveryLoop(peerID, mine) }
    }

    private fun stopRecoveryLocked() {
        val peerID = policy.run?.peerID
        recoveryGeneration++
        recovery?.cancel()
        recovery = null
        policy.stop()
        if (peerID != null) {
            val attempt = state.value[peerID]
            if (attempt == RemoteAttempt.Recovering || (attempt as? RemoteAttempt.Knocking)?.automatic == true) {
                clear(peerID)
                knocker.cancel(peerID)
            }
        }
    }

    private suspend fun recoveryLoop(peerID: String, mine: Long) {
        while (scope.isActive) {
            val step = synchronized(lock) { if (recoveryGeneration != mine) return else policy.next(nowMs()) }
            when (step) {
                RemoteRecoveryPolicy.Step.Idle -> return endRecovery(peerID, mine)
                is RemoteRecoveryPolicy.Step.Dormant -> {
                    // Out of scheduled attempts. A delivered knock still gets its dial-back time before the row says it failed.
                    val settle = deliveredAt?.let { it + DIAL_BACK_MS - nowMs() } ?: 0L
                    if (settle > 0) {
                        withTimeoutOrNull(settle) { wakeups.receive() }
                        continue
                    }
                    publishRecoveryEnd(peerID, mine)
                    // Until the window closes only a network change can bring one more attempt.
                    withTimeoutOrNull((step.untilMs - nowMs()).coerceAtLeast(1)) { wakeups.receive() } ?: return endRecovery(peerID, mine)
                }
                is RemoteRecoveryPolicy.Step.Wait -> {
                    val wait = step.atMs - nowMs()
                    if (wait > 0) {
                        withTimeoutOrNull(wait) { wakeups.receive() }
                        continue
                    }
                    if (!knockOnce(peerID, mine)) return
                }
            }
        }
    }

    /** One automatic knock. False when the run is over. */
    private suspend fun knockOnce(peerID: String, mine: Long): Boolean {
        val endpoint: RemoteEndpoint
        synchronized(lock) {
            if (recoveryGeneration != mine) return false
            val saved = store.endpoint(peerID)
            if (saved == null || !host.isPaired(peerID) || !foreground || !host.autoReconnectEnabled() ||
                host.isNearby(peerID) || host.liveSessionPeer() != null
            ) {
                stopRecoveryLocked()
                return false
            }
            endpoint = saved
            policy.knockStarted(nowMs())
            set(peerID, RemoteAttempt.Knocking(automatic = true))
        }
        host.log("remote recovery: automatic knock, host=${IpLiteral.logKind(endpoint.host)}")
        val result = knocker.knock(peerID, endpoint, KnockIntent.Automatic).await()
        synchronized(lock) {
            if (recoveryGeneration != mine) return false
            policy.knockFinished(nowMs(), result)
            if (result.isSecurityFailure) {
                // Final: no other address, no retry. The row says what happened.
                set(peerID, failure(result))
                host.log("remote recovery: stopped, ${describe(result)}")
                recoveryGeneration++
                recovery = null
                policy.stop()
                return false
            }
            deliveredAt = if (result == KnockResult.Delivered) nowMs() else null
            recoveryFailure = if (result == KnockResult.Delivered) RemoteAttempt.DialBackMissed else failure(result)
            set(peerID, RemoteAttempt.Recovering)
        }
        return true
    }

    private fun endRecovery(peerID: String, mine: Long) = synchronized(lock) {
        if (recoveryGeneration != mine) return@synchronized
        publishRecoveryEnd(peerID, mine)
        recovery = null
        policy.stop()
        recoveryGeneration++
    }

    /** The scheduled attempts are used up: the row shows why the last one failed, once, instead of "Reconnecting…" forever. */
    private fun publishRecoveryEnd(peerID: String, mine: Long) = synchronized(lock) {
        if (recoveryGeneration != mine || state.value[peerID] != RemoteAttempt.Recovering) return@synchronized
        recoveryFailure?.let { set(peerID, it) } ?: clear(peerID)
        host.clearConnectPending(peerID)
    }

    // MARK: - State

    private fun bump(peerID: String): Long {
        val next = (generations[peerID] ?: 0L) + 1
        generations[peerID] = next
        dialBackTimers.remove(peerID)?.cancel()
        return next
    }

    private fun set(peerID: String, attempt: RemoteAttempt) = state.update { it + (peerID to attempt) }

    private fun clear(peerID: String) = state.update { it - peerID }

    companion object {
        /** How long the Mac gets to dial back after a delivered knock (then: "The Mac didn't connect back"). */
        const val DIAL_BACK_MS = 20_000L

        /** A remote session that was running when the app left the foreground is resumed only within this time. */
        const val RESUME_WINDOW_MS = 600_000L
    }
}
