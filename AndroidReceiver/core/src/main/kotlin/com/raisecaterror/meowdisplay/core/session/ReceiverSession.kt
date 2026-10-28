package com.raisecaterror.meowdisplay.core.session

import com.raisecaterror.meowdisplay.core.video.AccessUnit
import com.raisecaterror.meowdisplay.core.video.DecodableSample
import com.raisecaterror.meowdisplay.core.video.ParameterSetTracker
import com.raisecaterror.meowdisplay.core.wire.AudioMediaFrame
import com.raisecaterror.meowdisplay.core.wire.IncomingFrame
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/** One authenticated media connection, as the session sees it. */
interface MediaLink {
    /**
     * The pinned peer the connection's certificate resolves to. It is the
     * session's only notion of who the Mac is: nothing the Mac says in-band
     * can change it.
     */
    val peerID: String

    /** The peer's network address and this device's own address on the connection, for describing the route. Never trust. */
    val remoteAddress: java.net.InetAddress? get() = null
    val localAddress: java.net.InetAddress? get() = null

    /** Frames and sends one control message; false once the link is closed. */
    fun send(payload: ByteArray): Boolean
    fun close()
}

sealed interface SessionEvent {
    data class Phase(val phase: SessionPhase) : SessionEvent
    data class Connected(
        val peerID: String,
        val remoteAddress: java.net.InetAddress? = null,
        val localAddress: java.net.InetAddress? = null,
    ) : SessionEvent
    data class Disconnected(val peerID: String, val reason: SessionLossReason) : SessionEvent
    data class Admitted(val peerID: String) : SessionEvent
    data object AdmissionWithdrawn : SessionEvent

    /**
     * This device's own Connect was accepted but the Mac's user has not approved it yet
     * (`sessionInvite.awaitingSender`); `false` once the Mac starts sending, or the request ends.
     */
    data class SenderApproval(val pending: Boolean) : SessionEvent
    data class ApprovalRequested(val approval: PendingSessionApproval) : SessionEvent
    data class ApprovalDismissed(val id: String) : SessionEvent
    data class InputState(val state: InputWireState, val allowed: Boolean) : SessionEvent
    data object InputReset : SessionEvent
    data class Video(val sample: DecodableSample, val captureLocalMs: Double?) : SessionEvent
    data class Audio(val frame: AudioMediaFrame) : SessionEvent
    data class VideoState(val enabled: Boolean, val width: Int?, val height: Int?) : SessionEvent
    data class AudioState(val enabled: Boolean) : SessionEvent
    data class CodecChanged(val codec: StreamCodec) : SessionEvent
    data class DisplayPaused(val paused: Boolean) : SessionEvent
    data class DisplayModeConfirmed(val mode: DisplayMode) : SessionEvent
    /** What the Mac offers beyond its protocol version (welcome `features`), e.g. "window". */
    data class MacFeatures(val features: Set<String>) : SessionEvent
    data class Cursor(val x: Double, val y: Double, val visible: Boolean) : SessionEvent
    /** The Mac's focused text caret, normalized to the streamed display (`visible` false: none). */
    data class TextCaret(val x: Double, val y: Double, val width: Double, val height: Double, val visible: Boolean) : SessionEvent
    data class UpdateRequired(val message: String?, val storeUrl: String?) : SessionEvent
    data object UpdateMac : SessionEvent
    data class Control(val type: String, val body: JsonObject) : SessionEvent
}

/**
 * The receiver's media session (Shared/StreamReceiver.swift, PROTOCOL.md 6,
 * 8, 9). Serves one sender at a time; a newly adopted connection replaces
 * the old one, except that another Mac arriving while a session is admitted
 * waits until its own invitation is accepted (make-before-break, PROTOCOL.md
 * 1). Per connection: `hello` first, nothing admitted, input off.
 * Media is dropped until the session is admitted on that same connection,
 * and input leaves only while the Mac's grant for that connection stands.
 *
 * Thread-safe: socket readers, the liveness ticker and the UI all call in.
 */
class ReceiverSession(
    private val policies: SessionPolicyStore,
    private val pins: () -> Map<String, ByteArray>,
    private val helloFields: () -> HelloFields,
    private val events: (SessionEvent) -> Unit,
    private val now: () -> Long = System::currentTimeMillis,
) : InputChannel {
    private val lifecycle = ReceiverSessionState()
    private val admission = ReceiverSessionAdmission()
    private val approvals = PendingSessionApprovals()
    private val clock = ClockSync()
    private val video = ParameterSetTracker()

    private var link: MediaLink? = null

    /**
     * Another Mac that connected while a session was admitted: greeted, but only its `welcome`,
     * invitation and withdrawal are read. It replaces the session once its invitation is
     * accepted; declined, blocked, withdrawn or silent, it closes and the session carries on.
     */
    private var candidate: MediaLink? = null
    private var candidateLastMs = 0L
    private var candidatePingMs = 0L
    private var candidatePanel: HelloFields? = null
    private var candidateWelcome: SenderMessage.Welcome? = null
    private var candidateInvitation: SessionInvitation? = null
    private var macPV: Int? = null
    private var currentInvitationID: String? = null
    private var inputGranted = false
    private var senderApprovalPending = false
    private var paused = false
    private var incompatible = false
    private var lastReceivedMs = 0L
    private var lastPingMs = 0L
    private var lastKeyframeRequestMs: Long? = null
    private var lastCursorSequence = 0L
    private var lastTextCaretSequence = 0L
    private var reconnectDeadlineMs: Long? = null
    private var reportedPhase = lifecycle.phase

    /** The panel last announced on the current connection; an unchanged one is never re-sent. */
    private var announcedPanel: HelloFields? = null

    /**
     * App-facing state the Mac sent before this connection was admitted:
     * the latest per kind, delivered at admission. An unadmitted Mac never
     * drives the receiver's UI.
     */
    private val heldState = LinkedHashMap<String, SessionEvent>()

    /** This receiver's own audio preference, reasserted on every `welcome`. */
    @Volatile var audioPreferred = false

    /** Off: a lost connection is not retried by itself (the Mac can still connect again). */
    @Volatile var autoReconnectEnabled = true

    val phase: SessionPhase @Synchronized get() = lifecycle.phase
    val peerID: String? @Synchronized get() = link?.peerID
    val isAdmitted: Boolean @Synchronized get() = link != null && admission.admitted
    val senderProtocolVersion: Int? @Synchronized get() = macPV
    override val clockOffsetMs: Double? @Synchronized get() = clock.offsetMs
    val rttMs: Double? @Synchronized get() = clock.lastRttMs

    /**
     * Every remote input message goes through here, sharing this session's
     * lock. It forgets what it holds whenever the grant or the connection ends.
     */
    val input = ReceiverInputSender(this, nowMs = { now().toDouble() }, lock = this)

    /** Input may leave this device only on an admitted, live, unpaused connection the Mac granted it on. */
    val inputAllowed: Boolean
        @Synchronized get() = link != null && admission.admitted && inputGranted && !paused && !incompatible &&
            lifecycle.allowsLiveInput && (macPV ?: 0) >= WireProtocol.ALLOW_INPUT

    // MARK: - Connections

    /**
     * A new connection that completed pinned TLS and resolved to exactly one
     * peer. It replaces the current one (PROTOCOL.md 1), except that a Mac
     * this device blocked is closed before it can disturb anything, and
     * another Mac waits while a session is admitted (see [candidate]).
     */
    @Synchronized
    fun adopt(newLink: MediaLink): Boolean {
        if (policies.policy(newLink.peerID) == PeerSessionPolicy.Blocked) {
            newLink.close()
            return false
        }
        val current = link
        if (current != null && current.peerID != newLink.peerID && admission.admitted) {
            park(newLink)
            return true
        }
        promote(newLink, greetedWith = null)
        return true
    }

    private fun park(newLink: MediaLink) {
        dropCandidate()
        val t = now()
        candidate = newLink
        candidateLastMs = t
        candidatePingMs = t
        val fields = helloFields()
        candidatePanel = fields
        newLink.send(ReceiverMessages.encode(ReceiverMessages.hello(fields)))
    }

    /** Closes the waiting Mac, answering its invitation with [answer] first; its prompt goes too. */
    private fun dropCandidate(answer: InvitationResult? = null) {
        val parked = candidate ?: return
        val invitation = candidateInvitation
        candidate = null
        candidateWelcome = null
        candidateInvitation = null
        candidatePanel = null
        if (invitation != null) {
            answer?.let { parked.send(ReceiverMessages.encode(ReceiverMessages.invitationResponse(invitation.id, it))) }
            if (approvals.resolve(invitation.id) != null) emit(SessionEvent.ApprovalDismissed(invitation.id))
        }
        parked.close()
    }

    /** The waiting Mac becomes the session, with the `welcome` it already sent. */
    private fun promoteCandidate(): MediaLink? {
        val parked = candidate ?: return null
        val welcome = candidateWelcome
        val panel = candidatePanel
        candidate = null
        candidateWelcome = null
        candidateInvitation = null
        candidatePanel = null
        promote(parked, greetedWith = panel)
        welcome?.let { handle(parked, it) }
        return parked
    }

    private fun promote(newLink: MediaLink, greetedWith: HelloFields?) {
        val previous = link
        link = newLink
        if (previous != null) {
            previous.close()
            dismissApprovals(answer = null)
        }
        admission.beginConnection()
        currentInvitationID = null
        // A new connection starts with no grant and nothing held.
        input.forget()
        inputGranted = false
        paused = false
        incompatible = false
        macPV = null
        macFeatures = emptySet()
        video.reset(StreamCodec.H264)
        lastCursorSequence = 0
        lastTextCaretSequence = 0
        lastKeyframeRequestMs = null
        reconnectDeadlineMs = null
        heldState.clear()
        val t = now()
        lastReceivedMs = t
        lastPingMs = t
        lifecycle.connectionAdopted()
        lifecycle.connectionEstablished()
        reportPhase()
        senderApprovalPending = false
        emit(SessionEvent.Connected(newLink.peerID, newLink.remoteAddress, newLink.localAddress))
        emit(SessionEvent.InputState(InputWireState.Off, false))
        if (greetedWith != null) {
            // Greeted while it waited: say it again only if the panel changed since.
            announcedPanel = greetedWith
            announce(force = false)
        } else {
            announce(force = true)
        }
    }

    /** Any bytes from the Mac keep the connection alive (PROTOCOL.md 8.2), not only whole frames. */
    @Synchronized
    fun onBytes(from: MediaLink) {
        if (from === link) lastReceivedMs = now() else if (from === candidate) candidateLastMs = now()
    }

    @Synchronized
    fun onFrame(from: MediaLink, payload: ByteArray) {
        if (from === candidate) {
            candidateLastMs = now()
            handleCandidate(from, payload)
            return
        }
        if (from !== link) return
        lastReceivedMs = now()
        when (val frame = IncomingFrame.classify(payload)) {
            is IncomingFrame.Control -> SenderMessage.parse(frame.json)?.let { handle(from, it) }
            is IncomingFrame.Video -> handleVideo(payload)
            is IncomingFrame.Audio -> if (mediaAdmitted()) emit(SessionEvent.Audio(frame.frame))
            IncomingFrame.Ignored -> Unit
        }
    }

    /** The transport failed or ended. */
    @Synchronized
    fun onClosed(from: MediaLink) {
        if (from === link) closeCurrent(SessionLossReason.TransportLost) else if (from === candidate) dropCandidate()
    }

    /** This device ends the session: `closing` (quit) or `sleeping` (locked), best effort, then close. */
    @Synchronized
    fun disconnect(sleeping: Boolean = false) {
        dropCandidate(InvitationResult.Declined)
        if (link == null) return
        send(if (sleeping) ReceiverMessages.sleeping() else ReceiverMessages.closing())
        closeCurrent(SessionLossReason.ExplicitDisconnect)
    }

    /**
     * The user cancels their own Connect while the Mac's user has not decided: the Mac is told the
     * request was withdrawn (its prompt goes), then the session ends.
     */
    @Synchronized
    fun cancelOwnRequest() {
        val id = currentInvitationID
        if (id != null && senderApprovalPending) send(ReceiverMessages.invitationResponse(id, InvitationResult.Cancelled))
        disconnect()
    }

    /**
     * Forget or Block of [peerID], after the trust or policy store changed.
     * Its prompts end, its remembered admission goes, and its live connection
     * closes: a session never outlives the trust it was admitted under.
     */
    @Synchronized
    fun revoke(peerID: String, blocked: Boolean) {
        if (candidate?.peerID == peerID) dropCandidate(if (blocked) InvitationResult.Blocked else InvitationResult.Declined)
        val current = link?.peerID
        for (approval in approvals.removeAll(peerID)) {
            if (current == peerID) {
                send(ReceiverMessages.invitationResponse(approval.id, if (blocked) InvitationResult.Blocked else InvitationResult.Declined))
            }
            emit(SessionEvent.ApprovalDismissed(approval.id))
        }
        admission.revoke(peerID, current)
        if (current == peerID) closeCurrent(SessionLossReason.ExplicitDisconnect)
    }

    @Synchronized
    fun requestManualReconnect() {
        if (lifecycle.requestManualReconnect()) reportPhase()
    }

    // MARK: - Timers

    /** Liveness, ping cadence, prompt expiry and the reconnect window. Call every few hundred ms. */
    @Synchronized
    fun tick() {
        val t = now()
        if (link != null) {
            if (t - lastReceivedMs > LIVENESS_TIMEOUT_MS) {
                closeCurrent(SessionLossReason.TransportLost)
            } else if (t - lastPingMs >= PING_INTERVAL_MS) {
                lastPingMs = t
                send(ReceiverMessages.ping(t))
            }
        }
        candidate?.let { parked ->
            if (t - candidateLastMs > LIVENESS_TIMEOUT_MS) {
                dropCandidate()
            } else if (t - candidatePingMs >= PING_INTERVAL_MS) {
                candidatePingMs = t
                parked.send(ReceiverMessages.encode(ReceiverMessages.ping(t)))
            }
        }
        for (expired in approvals.expire(t)) {
            if (candidateInvitation?.id == expired.id) {
                candidateInvitation = null
                candidate?.send(ReceiverMessages.encode(ReceiverMessages.invitationResponse(expired.id, InvitationResult.Declined)))
                dropCandidate()
            } else if (link?.peerID == expired.peerID) {
                send(ReceiverMessages.invitationResponse(expired.id, InvitationResult.Declined))
            }
            emit(SessionEvent.ApprovalDismissed(expired.id))
        }
        advanceReconnect(t)
    }

    private fun advanceReconnect(t: Long) {
        if (lifecycle.phase != SessionPhase.Reconnecting) return
        val deadline = reconnectDeadlineMs
        if (deadline != null) {
            if (t < deadline) return
            lifecycle.endReconnectAttempt()
            reconnectDeadlineMs = null
        }
        if (lifecycle.hasExhaustedReconnectAttempts) {
            if (lifecycle.exhaustRecovery()) reportPhase()
            return
        }
        val delay = lifecycle.nextReconnectDelayMs
        if (lifecycle.beginReconnectAttempt() != null) reconnectDeadlineMs = t + delay
    }

    // MARK: - Outgoing

    /**
     * Re-announces the panel on the live connection when it changed (rotation,
     * fold/unfold, a hello preference). The Mac rebuilds its display for a new
     * panel, so a local change that leaves the panel as it was — a resized or
     * split-screen window, a keyboard attached — sends nothing.
     */
    @Synchronized
    fun resendHello() {
        if (link != null) announce(force = false)
    }

    private fun announce(force: Boolean) {
        val fields = helloFields()
        if (!force && fields == announcedPanel) return
        announcedPanel = fields
        send(ReceiverMessages.hello(fields))
    }

    /** Sends one input message when [inputAllowed] and the Mac speaks [minimumPV]; false when withheld. */
    @Synchronized
    override fun sendInput(message: JsonObject, minimumPV: Int): Boolean {
        if (!inputAllowed || (macPV ?: 0) < minimumPV) return false
        return send(message)
    }

    /** Features from this connection's welcome. */
    @Volatile var macFeatures: Set<String> = emptySet()
        private set

    /** Mirror / Extend / Window for this device only. The Mac decides and confirms (displayModeState). */
    @Synchronized
    fun requestDisplayMode(mode: DisplayMode): Boolean {
        if (link == null || !admission.admitted || (macPV ?: 0) < WireProtocol.DISPLAY_MODE) return false
        if (mode == DisplayMode.Window && "window" !in macFeatures) return false
        return send(ReceiverMessages.displayModeRequest(mode))
    }

    /** A window-workspace message (PROTOCOL.md 6.10): admitted sessions with a Mac that offers windows only. */
    @Synchronized
    fun sendWorkspace(message: JsonObject): Boolean {
        if (link == null || !admission.admitted || "window" !in macFeatures) return false
        return send(message)
    }

    /** Asks the Mac for (or gives back) input on this connection. Never grants anything locally. */
    @Synchronized
    fun requestAllowInput(allowed: Boolean): Boolean {
        if (link == null || !admission.admitted || (macPV ?: 0) < WireProtocol.ALLOW_INPUT) return false
        return send(ReceiverMessages.allowInputRequest(allowed))
    }

    @Synchronized
    fun requestAudio(enabled: Boolean): Boolean {
        audioPreferred = enabled
        if (link == null || (macPV ?: 0) < WireProtocol.AUDIO) return false
        return send(ReceiverMessages.audioRequest(enabled))
    }

    @Synchronized
    fun requestKeyframe(): Boolean = link != null && send(ReceiverMessages.keyframeRequest()).also { lastKeyframeRequestMs = now() }

    /** Free-form telemetry for the Mac's log (PROTOCOL.md 6.1 `stats`). */
    @Synchronized
    fun sendStats(fields: Map<String, Number>): Boolean = link != null && send(buildJsonObject {
        put("type", "stats")
        fields.forEach { (key, value) -> put(key, value) }
    })

    /** The local user's answer to an invitation prompt. */
    @Synchronized
    fun answerInvitation(id: String, decision: ReceiverApprovalDecision) {
        val approval = approvals.resolve(id) ?: return
        emit(SessionEvent.ApprovalDismissed(id))
        val parked = candidate
        if (parked != null && parked.peerID == approval.peerID && candidateInvitation?.id == id) {
            candidateInvitation = null
            val policy = policies.policy(approval.peerID)
            val revoked = approval.peerID !in pins() || policy == PeerSessionPolicy.Blocked
            if (revoked || !decision.accept) {
                if (!revoked) decision.persist?.let { policies.setPolicy(approval.peerID, it) }
                val result = when {
                    policy == PeerSessionPolicy.Blocked -> InvitationResult.Blocked
                    revoked -> InvitationResult.Declined
                    else -> decision.result
                }
                parked.send(ReceiverMessages.encode(ReceiverMessages.invitationResponse(id, result)))
                dropCandidate()
                return
            }
            // Accepted: only now does the session it replaces end.
            promoteCandidate()
        }
        // Raised on an earlier connection: it can no longer be answered.
        if (link?.peerID != approval.peerID) return
        // Forget or Block since the prompt appeared makes the answer inert.
        val currentPolicy = policies.policy(approval.peerID)
        if (approval.peerID !in pins() || currentPolicy == PeerSessionPolicy.Blocked) {
            send(ReceiverMessages.invitationResponse(id, if (currentPolicy == PeerSessionPolicy.Blocked) InvitationResult.Blocked else InvitationResult.Declined))
            return
        }
        decision.persist?.let { policies.setPolicy(approval.peerID, it) }
        if (decision.accept) admit(id, approval.peerID)
        send(ReceiverMessages.invitationResponse(id, decision.result))
    }

    // MARK: - Incoming

    private fun handle(from: MediaLink, message: SenderMessage) {
        when (message) {
            is SenderMessage.Welcome -> {
                macPV = message.pv
                macFeatures = message.features
                deliver("features", SessionEvent.MacFeatures(message.features))
                if (message.pv < WireProtocol.SESSION_INVITATION) admitLegacySenderOrClose(from)
                if (link !== from) return
                if (message.pv < WireProtocol.MIN_SUPPORTED_PEER) {
                    incompatible = true
                    emit(SessionEvent.UpdateMac)
                }
                if (message.pv >= WireProtocol.AUDIO) send(ReceiverMessages.audioRequest(audioPreferred)) else emit(SessionEvent.AudioState(false))
            }
            is SenderMessage.UpdateRequired -> {
                // Accepted unadmitted: an incompatible receiver can never be admitted. Text only, bounded.
                incompatible = true
                emit(SessionEvent.UpdateRequired(message.message?.take(MAX_NOTICE_LENGTH), message.store?.takeIf(::isSafeUpdateLink)))
            }
            is SenderMessage.Pong -> clock.record(message.t, message.mt, now().toDouble())
            SenderMessage.Ping -> Unit
            is SenderMessage.Invite -> handleInvitation(from, message.invitation)
            is SenderMessage.InviteCancel -> {
                if (approvals.resolve(message.id) != null) emit(SessionEvent.ApprovalDismissed(message.id))
                if (message.id == currentInvitationID && admission.admitted) {
                    admission.revoke()
                    input.forget()
                    inputGranted = false
                    endSenderApproval()
                    emit(SessionEvent.AdmissionWithdrawn)
                    emit(SessionEvent.InputState(InputWireState.Off, false))
                }
            }
            is SenderMessage.AllowInputState -> {
                // A grant applies only to this connection, and only while it is admitted.
                if (!admission.admitted) return
                inputGranted = message.allowed && message.state == InputWireState.Allowed
                // Revoked: the Mac has already released everything this device held.
                if (!inputGranted) input.forget()
                emit(SessionEvent.InputState(message.state, inputGranted))
            }
            is SenderMessage.VideoState -> {
                if (!message.enabled) video.reset()
                deliver("videoState", SessionEvent.VideoState(message.enabled, message.width?.takeIf(::isSaneDimension), message.height?.takeIf(::isSaneDimension)))
            }
            is SenderMessage.AudioState -> deliver("audioState", SessionEvent.AudioState(message.enabled))
            is SenderMessage.CodecState -> if (message.codec != video.codec) {
                // The decoder follows at once (it orders with the frames); the app hears at admission.
                video.reset(message.codec)
                deliver("codec", SessionEvent.CodecChanged(message.codec))
            }
            is SenderMessage.DisplayPaused -> {
                // Release while the gate is still open: nothing stays held through a pause.
                if (message.paused && !paused) input.releaseAll()
                paused = message.paused
                val changed = if (message.paused) lifecycle.displayPaused() else lifecycle.displayResumed()
                if (changed) reportPhase()
                deliver("displayState", SessionEvent.DisplayPaused(message.paused))
            }
            is SenderMessage.DisplayModeState -> deliver("displayMode", SessionEvent.DisplayModeConfirmed(message.mode))
            is SenderMessage.Cursor -> {
                // No cursor before admission (6.9): it is not state worth holding.
                if (!admission.admitted) return
                val sequence = message.sequence
                if (sequence != null) {
                    if (sequence <= lastCursorSequence) return
                    lastCursorSequence = sequence
                }
                emit(SessionEvent.Cursor(message.x, message.y, message.visible))
            }
            is SenderMessage.TextCaret -> {
                // Like the cursor: nothing before admission, and a reordered frame is dropped.
                if (!admission.admitted) return
                val sequence = message.sequence
                if (sequence != null) {
                    if (sequence <= lastTextCaretSequence) return
                    lastTextCaretSequence = sequence
                }
                emit(SessionEvent.TextCaret(message.x, message.y, message.width, message.height, message.visible))
            }
            SenderMessage.InputReset -> if (admission.admitted) {
                input.forget()
                emit(SessionEvent.InputReset)
            }
            SenderMessage.Closing -> closeCurrent(SessionLossReason.PeerClosed)
            is SenderMessage.Other -> deliver("other:" + message.type, SessionEvent.Control(message.type, message.body))
        }
    }

    /** From the waiting Mac: its `welcome`, its invitation and its withdrawal; nothing else acts. */
    private fun handleCandidate(from: MediaLink, payload: ByteArray) {
        val frame = IncomingFrame.classify(payload) as? IncomingFrame.Control ?: return
        when (val message = SenderMessage.parse(frame.json) ?: return) {
            is SenderMessage.Welcome -> {
                candidateWelcome = message
                if (message.pv < WireProtocol.SESSION_INVITATION) {
                    // Can't be asked in-band: replaces the session only when an automatic invitation would.
                    val accept = from.peerID in pins() &&
                        IncomingSessionPolicy.decision(from.peerID, InvitationIntent.Automatic, policies) == IncomingDecision.Accept
                    if (accept) promoteCandidate() else dropCandidate()
                }
            }
            is SenderMessage.Invite -> judgeCandidate(from, message.invitation)
            is SenderMessage.InviteCancel -> if (message.id == candidateInvitation?.id) dropCandidate()
            else -> Unit
        }
    }

    private fun judgeCandidate(from: MediaLink, invitation: SessionInvitation) {
        val peerID = from.peerID
        val decision = if (peerID in pins()) IncomingSessionPolicy.decision(peerID, invitation.intent, policies) else IncomingDecision.Decline
        fun answer(result: InvitationResult) = from.send(ReceiverMessages.encode(ReceiverMessages.invitationResponse(invitation.id, result)))
        when (decision) {
            IncomingDecision.Accept -> promoteCandidate()?.let { handleInvitation(it, invitation) }
            IncomingDecision.AskUser -> {
                candidateInvitation = invitation
                val approval = PendingSessionApproval(invitation.id, peerID, invitation.mode, now())
                val (started, superseded) = approvals.begin(approval)
                superseded?.let { emit(SessionEvent.ApprovalDismissed(it)) }
                if (started) emit(SessionEvent.ApprovalRequested(approval))
                answer(InvitationResult.Pending)
            }
            IncomingDecision.Decline -> { answer(InvitationResult.Declined); dropCandidate() }
            IncomingDecision.Block -> { answer(InvitationResult.Blocked); dropCandidate() }
        }
    }

    private fun handleInvitation(from: MediaLink, invitation: SessionInvitation) {
        currentInvitationID = invitation.id
        val peerID = from.peerID
        // Forgotten since the handshake: nobody to apply a policy to.
        if (peerID !in pins()) {
            send(ReceiverMessages.invitationResponse(invitation.id, InvitationResult.Declined))
            return
        }
        val policy = IncomingSessionPolicy.decision(peerID, invitation.intent, policies)
        val decision = when {
            policy == IncomingDecision.Block -> IncomingDecision.Block
            admission.isContinuation(invitation, peerID) -> IncomingDecision.Accept
            else -> policy
        }
        when (decision) {
            IncomingDecision.Accept -> {
                // Our own request, accepted here, but the Mac's user still has to say yes. Said before
                // the admission so the screen never shows an empty picture in between.
                if (invitation.awaitingSender && invitation.initiator == SessionRole.Receiver && !senderApprovalPending) {
                    senderApprovalPending = true
                    emit(SessionEvent.SenderApproval(true))
                }
                admit(invitation.id, peerID)
                for (dismissed in approvals.removeAll(peerID)) emit(SessionEvent.ApprovalDismissed(dismissed.id))
                send(ReceiverMessages.invitationResponse(invitation.id, InvitationResult.Accepted))
            }
            IncomingDecision.AskUser -> {
                val approval = PendingSessionApproval(invitation.id, peerID, invitation.mode, now())
                val (started, superseded) = approvals.begin(approval)
                superseded?.let { emit(SessionEvent.ApprovalDismissed(it)) }
                if (started) emit(SessionEvent.ApprovalRequested(approval))
                send(ReceiverMessages.invitationResponse(invitation.id, InvitationResult.Pending))
            }
            IncomingDecision.Decline -> send(ReceiverMessages.invitationResponse(invitation.id, InvitationResult.Declined))
            IncomingDecision.Block -> send(ReceiverMessages.invitationResponse(invitation.id, InvitationResult.Blocked))
        }
    }

    /** A pre-21 Mac cannot be asked in-band: admitted only when an automatic invitation would be. */
    private fun admitLegacySenderOrClose(from: MediaLink) {
        val peerID = from.peerID
        if (peerID in pins() && IncomingSessionPolicy.decision(peerID, InvitationIntent.Automatic, policies) == IncomingDecision.Accept) {
            admit(null, peerID)
        } else {
            closeCurrent(SessionLossReason.ExplicitDisconnect)
        }
    }

    private fun admit(invitationID: String?, peerID: String) {
        val wasAdmitted = admission.admitted
        admission.admit(invitationID, peerID)
        if (wasAdmitted) return
        // The decoder starts from scratch: the next keyframe carries its parameter sets again.
        video.reset()
        emit(SessionEvent.Admitted(peerID))
        heldState.values.forEach(::emit)
        heldState.clear()
        // Frames before admission were dropped: ask for a keyframe so a static screen appears at once.
        requestKeyframe()
    }

    private fun mediaAdmitted() = link != null && admission.admitted && !incompatible

    private fun deliver(kind: String, event: SessionEvent) {
        if (admission.admitted) {
            emit(event)
        } else if (kind in heldState || heldState.size < MAX_HELD_STATES) {
            heldState.remove(kind)
            heldState[kind] = event
        }
    }

    private fun handleVideo(payload: ByteArray) {
        if (!mediaAdmitted()) return
        val unit = AccessUnit.parse(payload)
        val sample = video.accept(unit)
        if (sample == null) {
            if (video.needsKeyframe) requestKeyframeThrottled()
            return
        }
        // The Mac is sending: whatever it was waiting for has been decided.
        endSenderApproval()
        emit(SessionEvent.Video(sample, unit.captureMs?.let(clock::toLocal)))
    }

    private fun endSenderApproval() {
        if (!senderApprovalPending) return
        senderApprovalPending = false
        emit(SessionEvent.SenderApproval(false))
    }

    private fun requestKeyframeThrottled() {
        val last = lastKeyframeRequestMs
        if (last == null || now() - last >= KEYFRAME_REQUEST_INTERVAL_MS) requestKeyframe()
    }

    private fun closeCurrent(reason: SessionLossReason) {
        val closing = link ?: return
        link = null
        closing.close()
        admission.beginConnection()
        // The Mac releases held input on session loss; a reconnect starts clean.
        input.forget()
        inputGranted = false
        paused = false
        heldState.clear()
        senderApprovalPending = false
        dismissApprovals(answer = null)
        val effective = if (incompatible && reason.automaticallyRecoverable) SessionLossReason.ProtocolIncompatible else reason
        lifecycle.connectionLost(effective, autoReconnectEnabled)
        reconnectDeadlineMs = null
        emit(SessionEvent.InputState(InputWireState.Off, false))
        emit(SessionEvent.Disconnected(closing.peerID, effective))
        reportPhase()
        // The session a waiting Mac would have replaced is gone: it is judged as any new
        // connection (its prompt, dismissed above, comes back). disconnect() drops it first.
        val invitation = candidateInvitation
        promoteCandidate()?.let { promoted -> invitation?.let { handleInvitation(promoted, it) } }
    }

    private fun dismissApprovals(answer: InvitationResult?) {
        for (approval in approvals.clear()) {
            answer?.let { send(ReceiverMessages.invitationResponse(approval.id, it)) }
            emit(SessionEvent.ApprovalDismissed(approval.id))
        }
    }

    private fun send(message: JsonObject): Boolean = link?.send(ReceiverMessages.encode(message)) ?: false

    private fun reportPhase() {
        if (lifecycle.phase == reportedPhase) return
        reportedPhase = lifecycle.phase
        emit(SessionEvent.Phase(reportedPhase))
    }

    private fun emit(event: SessionEvent) = events(event)

    companion object {
        const val PING_INTERVAL_MS = 2_000L
        const val LIVENESS_TIMEOUT_MS = 5_000L
        const val KEYFRAME_REQUEST_INTERVAL_MS = 1_000L
        const val MAX_HELD_STATES = 32
        const val MAX_NOTICE_LENGTH = 300
        const val MAX_DIMENSION = 16_384

        fun isSaneDimension(value: Int) = value in 1..MAX_DIMENSION

        /** Only an https link is ever opened from `updateRequired.store`. */
        fun isSafeUpdateLink(link: String): Boolean =
            runCatching { java.net.URI(link) }.getOrNull()?.let { it.scheme == "https" && !it.host.isNullOrEmpty() } == true
    }
}
