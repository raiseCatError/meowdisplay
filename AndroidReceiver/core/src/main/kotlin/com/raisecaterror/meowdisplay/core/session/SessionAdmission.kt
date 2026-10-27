package com.raisecaterror.meowdisplay.core.session

import kotlinx.serialization.json.JsonObject

// Session invitations (pv 21, PROTOCOL.md 6.9; Shared/SessionInvitation.swift).
// Two distinctions stay explicit: the session initiator is not the stream
// sender, and connection approval is not input approval. Nothing here grants
// input.

enum class SessionRole(val wire: String) {
    Sender("sender"), Receiver("receiver");

    companion object {
        fun of(wire: String?) = entries.firstOrNull { it.wire == wire }
    }
}

enum class InvitationIntent(val wire: String) {
    Manual("manual"), Automatic("automatic");

    companion object {
        fun of(wire: String?) = entries.firstOrNull { it.wire == wire }
    }
}

enum class InvitationResult(val wire: String) {
    Accepted("accepted"), Pending("pending"), Declined("declined"), Blocked("blocked"), Cancelled("cancelled")
}

data class SessionInvitation(
    val id: String,
    val initiator: SessionRole,
    val intent: InvitationIntent,
    val mode: DisplayMode,
    val awaitingSender: Boolean,
) {
    companion object {
        const val MAX_ID_LENGTH = 64

        fun parse(message: JsonObject): SessionInvitation? {
            val id = message.string("id")?.takeIf { it.isNotEmpty() && it.length <= MAX_ID_LENGTH } ?: return null
            return SessionInvitation(
                id = id,
                initiator = SessionRole.of(message.string("initiator")) ?: return null,
                intent = InvitationIntent.of(message.string("intent")) ?: return null,
                mode = DisplayMode.of(message.string("mode")) ?: return null,
                awaitingSender = message.bool("awaitingSender") ?: false,
            )
        }
    }
}

enum class PeerSessionPolicy { AlwaysAllow, Blocked }

enum class IncomingDecision { Accept, AskUser, Decline, Block }

/** Per-Mac connection policy, keyed by the pinned peer ID. Never a display mode or input. */
interface SessionPolicyStore {
    /** "Automatically Allow Connections"; on by default for a phone or tablet receiver. */
    val automaticallyAllow: Boolean
    fun policy(peerID: String): PeerSessionPolicy?
    fun setPolicy(peerID: String, policy: PeerSessionPolicy?)
}

class InMemorySessionPolicyStore(override var automaticallyAllow: Boolean = true) : SessionPolicyStore {
    val policies = mutableMapOf<String, PeerSessionPolicy>()

    override fun policy(peerID: String) = policies[peerID]

    override fun setPolicy(peerID: String, policy: PeerSessionPolicy?) {
        if (policy == null) policies.remove(peerID) else policies[peerID] = policy
    }
}

object IncomingSessionPolicy {
    fun resolve(peerPolicy: PeerSessionPolicy?, automaticallyAllow: Boolean, intent: InvitationIntent): IncomingDecision =
        when (peerPolicy) {
            PeerSessionPolicy.Blocked -> IncomingDecision.Block
            PeerSessionPolicy.AlwaysAllow -> IncomingDecision.Accept
            null -> when {
                automaticallyAllow -> IncomingDecision.Accept
                intent == InvitationIntent.Manual -> IncomingDecision.AskUser
                else -> IncomingDecision.Decline
            }
        }

    /** Without an authenticated identity there is nobody to name in a prompt: never ask. */
    fun decision(peerID: String?, intent: InvitationIntent, store: SessionPolicyStore): IncomingDecision {
        val decision = resolve(peerID?.let(store::policy), store.automaticallyAllow, intent)
        return if (peerID == null && decision == IncomingDecision.AskUser) IncomingDecision.Decline else decision
    }
}

enum class ReceiverApprovalDecision(val accept: Boolean, val persist: PeerSessionPolicy?, val result: InvitationResult) {
    RejectPermanently(false, PeerSessionPolicy.Blocked, InvitationResult.Blocked),
    RejectForSession(false, null, InvitationResult.Declined),
    Allow(true, null, InvitationResult.Accepted),
    AllowPermanently(true, PeerSessionPolicy.AlwaysAllow, InvitationResult.Accepted),
}

/**
 * Admission is per connection; the accepted invitation is remembered across
 * connections so a reconnect of the same session is accepted without a
 * prompt, but only from the same peer.
 */
class ReceiverSessionAdmission {
    var admitted = false
        private set
    var acceptedInvitationID: String? = null
        private set
    var acceptedPeerID: String? = null
        private set

    fun beginConnection() {
        admitted = false
    }

    fun admit(invitationID: String?, peerID: String) {
        admitted = true
        if (invitationID != null) {
            acceptedInvitationID = invitationID
            acceptedPeerID = peerID
        }
    }

    fun revoke() {
        admitted = false
        acceptedInvitationID = null
        acceptedPeerID = null
    }

    /** Forget or Block of [peerID]; another Mac's live admission is left alone. */
    fun revoke(peerID: String, currentPeerID: String?): Boolean {
        var changed = false
        if (currentPeerID == peerID && admitted) {
            admitted = false
            changed = true
        }
        if (acceptedPeerID == peerID) {
            acceptedInvitationID = null
            acceptedPeerID = null
            changed = true
        }
        return changed
    }

    fun isContinuation(invitation: SessionInvitation, peerID: String): Boolean =
        invitation.id == acceptedInvitationID && peerID == acceptedPeerID
}

data class PendingSessionApproval(
    val id: String,
    val peerID: String,
    val mode: DisplayMode,
    val createdAtMs: Long,
)

/** Prompts waiting for this device's user; at most one per Mac, each for at most 60 s. */
class PendingSessionApprovals {
    private val entries = mutableListOf<PendingSessionApproval>()

    val first: PendingSessionApproval? get() = entries.firstOrNull()

    /** Started, and the id of the same Mac's prompt it replaced, if any. */
    fun begin(approval: PendingSessionApproval): Pair<Boolean, String?> {
        if (entries.any { it.id == approval.id }) return false to null
        val superseded = entries.firstOrNull { it.peerID == approval.peerID }?.id
        entries.removeAll { it.peerID == approval.peerID }
        entries += approval
        return true to superseded
    }

    fun resolve(id: String): PendingSessionApproval? =
        entries.firstOrNull { it.id == id }?.also { entries.remove(it) }

    fun removeAll(peerID: String): List<PendingSessionApproval> =
        entries.filter { it.peerID == peerID }.also { entries.removeAll(it) }

    fun clear(): List<PendingSessionApproval> = entries.toList().also { entries.clear() }

    fun expire(nowMs: Long): List<PendingSessionApproval> =
        entries.filter { nowMs - it.createdAtMs >= TIMEOUT_MS }.also { entries.removeAll(it) }

    companion object {
        const val TIMEOUT_MS = 60_000L
    }
}
