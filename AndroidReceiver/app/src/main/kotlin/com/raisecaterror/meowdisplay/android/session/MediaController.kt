package com.raisecaterror.meowdisplay.android.session

import android.annotation.SuppressLint
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.raisecaterror.meowdisplay.android.discovery.Bonjour
import com.raisecaterror.meowdisplay.android.discovery.ServiceTypes
import com.raisecaterror.meowdisplay.android.identity.DeviceIdentity
import com.raisecaterror.meowdisplay.android.trust.PinStore
import com.raisecaterror.meowdisplay.core.session.ConnectRequestState
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import com.raisecaterror.meowdisplay.core.session.HelloFields
import com.raisecaterror.meowdisplay.core.session.InputWireState
import com.raisecaterror.meowdisplay.core.session.MediaListener
import com.raisecaterror.meowdisplay.core.session.PeerSessionPolicy
import com.raisecaterror.meowdisplay.core.session.PendingSessionApproval
import com.raisecaterror.meowdisplay.core.session.ReceiverApprovalDecision
import com.raisecaterror.meowdisplay.core.session.ReceiverSession
import com.raisecaterror.meowdisplay.core.session.SessionEvent
import com.raisecaterror.meowdisplay.core.session.SessionPhase
import com.raisecaterror.meowdisplay.core.session.SessionPolicyStore
import com.raisecaterror.meowdisplay.core.session.WireProtocol
import com.raisecaterror.meowdisplay.core.tls.PinnedTls
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * Per-Mac connection policy (Always Allow / Blocked) and "Automatically Allow
 * Connections". App-private and, like pins, never backed up or transferred.
 */
/**
 * The per-Mac "Request Control Automatically" opt-in (iOS `InputAutoRequestStore`): a blocked touch
 * may send the normal input request by itself for these Macs only. Off unless turned on; Forget
 * removes it. The Mac still decides.
 */
class InputAutoRequestPrefs(context: Context) {
    private val prefs = context.getSharedPreferences("inputAutoRequest", Context.MODE_PRIVATE)
    private val peers = MutableStateFlow(prefs.getStringSet(PEERS, emptySet()).orEmpty().toSet())
    val enabledPeers: StateFlow<Set<String>> = peers.asStateFlow()

    fun isEnabled(peerID: String?): Boolean = peerID != null && peerID in peers.value

    @SuppressLint("ApplySharedPref", "UseKtx")
    fun setEnabled(peerID: String, enabled: Boolean) {
        val next = if (enabled) peers.value + peerID else peers.value - peerID
        peers.value = next
        prefs.edit().putStringSet(PEERS, next).commit()
    }

    private companion object { const val PEERS = "peers" }
}

class SessionPolicyPrefs(context: Context) : SessionPolicyStore {
    private val prefs = context.getSharedPreferences("sessionPolicy", Context.MODE_PRIVATE)

    override var automaticallyAllow: Boolean
        get() = prefs.getBoolean(AUTOMATICALLY_ALLOW, true)
        @SuppressLint("ApplySharedPref", "UseKtx")
        set(value) {
            prefs.edit().putBoolean(AUTOMATICALLY_ALLOW, value).commit()
        }

    override fun policy(peerID: String): PeerSessionPolicy? =
        prefs.getString(PEER + peerID, null)?.let { stored -> PeerSessionPolicy.entries.firstOrNull { it.name == stored } }

    // commit(): a Block must hold across a crash right after it.
    @SuppressLint("ApplySharedPref", "UseKtx")
    override fun setPolicy(peerID: String, policy: PeerSessionPolicy?) {
        prefs.edit().apply { if (policy == null) remove(PEER + peerID) else putString(PEER + peerID, policy.name) }.commit()
    }

    private companion object {
        const val AUTOMATICALLY_ALLOW = "automaticallyAllow"
        const val PEER = "peer."
    }
}

data class MediaUiState(
    val phase: SessionPhase = SessionPhase.Disconnected,
    val peerID: String? = null,
    val admitted: Boolean = false,
    val input: InputWireState = InputWireState.Off,
    val approval: PendingSessionApproval? = null,
    val updateMessage: String? = null,
    val updateLink: String? = null,
    val listening: Boolean = false,
    val listenerError: String? = null,
    /** A Connect this device sent and is waiting on (the Mac dials in). */
    val connectingTo: String? = null,
    /** The last Connect that got no answer in time. */
    val connectFailedFor: String? = null,
    /** The Mac's confirmed source for this session: "mirror", "extend" or "window". */
    val source: String? = null,
)

/**
 * The media side of the receiver: the pinned-TLS listener on 9001, its
 * `_opensidecar._tcp` advertisement, and the session behind them. Like
 * pairing, it runs only while the app is in front.
 */
class MediaController(
    private val identity: DeviceIdentity,
    private val pins: PinStore,
    private val policies: SessionPolicyStore,
    private val bonjour: Bonjour,
    private val localName: () -> String,
    private val panel: () -> HelloFields,
    /** Per-Mac "Request Control Automatically"; null (tests, previews): never. */
    val inputAutoRequest: InputAutoRequestPrefs? = null,
) {
    private val state = MutableStateFlow(MediaUiState())
    val ui: StateFlow<MediaUiState> = state.asStateFlow()

    /** The decoders subscribe here: every session event, in order, on the thread it happened on. */
    @Volatile var mediaEvents: ((SessionEvent) -> Unit)? = null

    /** The receiver controls subscribe here, after the decoders. */
    @Volatile var controlEvents: ((SessionEvent) -> Unit)? = null

    /** A paired Mac's name for the UI ("your Mac" when unknown). */
    fun macName(peerID: String?): String = pins.paired.value.firstOrNull { it.peerID == peerID }?.name ?: "your Mac"

    val session = ReceiverSession(policies, pins::pinnedPeers, ::hello, ::onEvent)
    private var listener: MediaListener? = null
    private val connectRequests = ConnectRequestState()
    private val main = Handler(Looper.getMainLooper())

    /** The hello: the panel, plus the mode this device asked for when this is the Mac it asked. */
    private fun hello(): HelloFields =
        panel().copy(requestedMode = connectRequests.requestedMode(session.peerID, SystemClock.elapsedRealtime()))

    private fun advertiseMedia() {
        val txt = ServiceTypes.mediaTxt(identity.installID, WireProtocol.VERSION).toMutableMap()
        connectRequests.token(SystemClock.elapsedRealtime())?.let { txt["cr"] = it }
        bonjour.advertise(ServiceTypes.MEDIA, localName(), ServiceTypes.MEDIA_PORT, txt)
    }

    /**
     * Ask a paired Mac to connect (PROTOCOL.md 6.9): a one-shot token in this
     * device's own advertisement. The Mac dials only a receiver it has
     * pinned, over pinned TLS; nothing here grants input.
     */
    @Synchronized
    fun requestConnect(peerID: String, mode: DisplayMode? = null) {
        if (listener == null || pins.paired.value.none { it.peerID == peerID }) return
        val request = connectRequests.request(peerID, mode, SystemClock.elapsedRealtime())
        state.update { it.copy(connectingTo = peerID, connectFailedFor = null) }
        advertiseMedia()
        main.postDelayed({ if (connectRequests.token(SystemClock.elapsedRealtime()) == null) refreshAdvertisement() }, ConnectRequestState.TOKEN_MS + 50)
        main.postDelayed({
            if (state.value.connectingTo == peerID && !connectRequests.isPending(peerID, SystemClock.elapsedRealtime())) {
                connectRequests.clear(peerID)
                state.update { it.copy(connectingTo = null, connectFailedFor = peerID) }
            }
        }, ConnectRequestState.REQUEST_MS + 50)
        Log.i("MeowMedia", "connect request for ${peerID.take(8)} token=${request.token.take(4)}…")
    }

    @Synchronized
    fun cancelConnect() {
        connectRequests.clear()
        state.update { it.copy(connectingTo = null) }
        refreshAdvertisement()
    }

    fun dismissConnectFailure() = state.update { it.copy(connectFailedFor = null) }

    @Synchronized
    private fun refreshAdvertisement() {
        if (listener != null) advertiseMedia()
    }

    @Synchronized
    fun start() {
        if (listener != null) return
        val started = MediaListener(
            PinnedTls.context(identity.keyManager) { pins.pinnedSPKIs() }, pins::pinnedPeers, session,
            log = { Log.w("MeowMedia", it) },
        )
        try {
            started.start()
        } catch (e: Exception) {
            started.close()
            state.update { it.copy(listening = false, listenerError = "Can't listen for Macs on port ${ServiceTypes.MEDIA_PORT}") }
            return
        }
        listener = started
        advertiseMedia()
        state.update { it.copy(listening = true, listenerError = null) }
    }

    /** [sleeping]: the app went to the background and expects the Mac back. */
    @Synchronized
    fun stop(sleeping: Boolean) {
        bonjour.withdraw(ServiceTypes.MEDIA)
        listener?.close(sleeping)
        listener = null
        state.update { it.copy(listening = false) }
    }

    /** Forget: the pin, its policy and any live session for that Mac all go. */
    fun forget(peerID: String) {
        connectRequests.clear(peerID)
        state.update { if (it.connectingTo == peerID) it.copy(connectingTo = null) else it }
        pins.forget(peerID)
        policies.setPolicy(peerID, null)
        inputAutoRequest?.setEnabled(peerID, false)
        session.revoke(peerID, blocked = false)
    }

    fun block(peerID: String) {
        connectRequests.clear(peerID)
        policies.setPolicy(peerID, PeerSessionPolicy.Blocked)
        session.revoke(peerID, blocked = true)
    }

    fun answer(id: String, decision: ReceiverApprovalDecision) = session.answerInvitation(id, decision)

    private fun onEvent(event: SessionEvent) {
        mediaEvents?.invoke(event)
        controlEvents?.invoke(event)
        when (event) {
            is SessionEvent.Phase -> state.update { it.copy(phase = event.phase) }
            is SessionEvent.Connected -> state.update { it.copy(peerID = event.peerID, admitted = false, updateMessage = null, updateLink = null) }
            is SessionEvent.Disconnected -> state.update { it.copy(admitted = false, approval = null, source = null) }
            is SessionEvent.Admitted -> {
                // The Connect was answered: withdraw the token and stop offering the mode.
                if (connectRequests.isPending(event.peerID, SystemClock.elapsedRealtime())) {
                    connectRequests.clear(event.peerID)
                    main.post { refreshAdvertisement() }
                }
                state.update { it.copy(admitted = true, connectingTo = null, connectFailedFor = null) }
            }
            SessionEvent.AdmissionWithdrawn -> state.update { it.copy(admitted = false) }
            is SessionEvent.ApprovalRequested -> state.update { it.copy(approval = event.approval) }
            is SessionEvent.ApprovalDismissed -> state.update { if (it.approval?.id == event.id) it.copy(approval = null) else it }
            is SessionEvent.InputState -> state.update { it.copy(input = event.state) }
            is SessionEvent.DisplayModeConfirmed -> state.update { it.copy(source = event.mode.wire) }
            is SessionEvent.UpdateRequired -> state.update {
                it.copy(updateMessage = event.message ?: "Update MeowDisplay to keep using your second display.", updateLink = event.storeUrl)
            }
            SessionEvent.UpdateMac -> state.update { it.copy(updateMessage = "Update MeowDisplay on your Mac to reconnect.") }
            else -> Unit
        }
    }
}
