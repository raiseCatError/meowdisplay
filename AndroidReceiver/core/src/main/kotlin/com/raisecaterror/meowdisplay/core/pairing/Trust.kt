package com.raisecaterror.meowdisplay.core.pairing

/** Pure pin policy (Shared/Pairing.swift `TrustPinPolicy`). */
object TrustPinPolicy {
    enum class Decision { New, Match, IdentityChanged }

    fun decision(existing: ByteArray?, presented: ByteArray): Decision = when {
        existing == null -> Decision.New
        existing.contentEquals(presented) -> Decision.Match
        else -> Decision.IdentityChanged
    }
}

interface PeerTrustStore {
    fun pin(peerID: String): ByteArray?

    /** Every pin, peer ID to SPKI: an in-memory snapshot. */
    fun pinnedPeers(): Map<String, ByteArray>

    /**
     * `allowIdentityChange` replaces a differing pin instead of refusing it.
     * Only ever true after a fresh handshake in which both sides confirmed
     * the same SAS for the changed identity, never on a matching peer id alone.
     */
    fun setPin(peerID: String, spki: ByteArray, displayName: String, allowIdentityChange: Boolean = false): Boolean
    fun forget(peerID: String)
}

class InMemoryPeerTrustStore : PeerTrustStore {
    val pins = mutableMapOf<String, ByteArray>()

    override fun pin(peerID: String): ByteArray? = pins[peerID]

    override fun pinnedPeers(): Map<String, ByteArray> = pins.toMap()

    override fun setPin(peerID: String, spki: ByteArray, displayName: String, allowIdentityChange: Boolean): Boolean =
        if (PeerDirectory.isHeldByAnotherPeer(pins, peerID, spki)) false else when (TrustPinPolicy.decision(pins[peerID], spki)) {
            TrustPinPolicy.Decision.New, TrustPinPolicy.Decision.Match -> {
                pins[peerID] = spki
                true
            }
            TrustPinPolicy.Decision.IdentityChanged -> {
                if (allowIdentityChange) pins[peerID] = spki
                allowIdentityChange
            }
        }

    override fun forget(peerID: String) {
        pins.remove(peerID)
    }
}

/**
 * Who an authenticated key belongs to. A key is a peer only when exactly one
 * peer ID holds it: the media session derives the Mac's identity from its
 * certificate alone, so an ambiguous key would let one Mac's connection be
 * judged by another entry's name, policy or admission.
 */
object PeerDirectory {
    fun uniquePeerID(pins: Map<String, ByteArray>, spki: ByteArray): String? =
        pins.entries.filter { it.value.contentEquals(spki) }.singleOrNull()?.key

    fun isHeldByAnotherPeer(pins: Map<String, ByteArray>, peerID: String, spki: ByteArray): Boolean =
        pins.any { (id, pin) -> id != peerID && pin.contentEquals(spki) }
}

object PairingClassifier {
    fun classify(pending: PendingPairing, existingPin: ByteArray?): PendingPairing =
        pending.copy(
            classification = when (TrustPinPolicy.decision(existingPin, pending.peerSPKI)) {
                TrustPinPolicy.Decision.New -> PairingClassification.NewPeer
                TrustPinPolicy.Decision.Match -> PairingClassification.RePairSameKey
                TrustPinPolicy.Decision.IdentityChanged -> PairingClassification.IdentityChanged
            },
        )

    fun check(pending: PendingPairing, allowIdentityChange: Boolean) {
        if (pending.classification == PairingClassification.IdentityChanged && !allowIdentityChange) {
            fail(PairingError.IdentityChanged)
        }
    }
}

/**
 * The only place trust is written after a handshake: strictly after the
 * peer's authenticated confirmation verified, never for a stale attempt.
 */
object PairingFinalizer {
    fun complete(
        result: PairingResult,
        pending: PendingPairing,
        peerConfirmation: PairingConfirmation,
        store: PeerTrustStore,
        isCurrent: () -> Boolean = { true },
    ) {
        result.verify(peerConfirmation)
        if (!isCurrent()) fail(PairingError.Rejected)
        // A same-key re-pair whose pin vanished since the SAS was shown would
        // silently recreate trust from a stale classification.
        if (pending.classification == PairingClassification.RePairSameKey &&
            store.pin(pending.peerID)?.contentEquals(pending.peerSPKI) != true
        ) fail(PairingError.TrustStateChanged)
        // Pairing never proves possession of the identity key (TLS does), so
        // a peer could claim a key another paired Mac already holds.
        if (PeerDirectory.isHeldByAnotherPeer(store.pinnedPeers(), pending.peerID, pending.peerSPKI)) {
            fail(PairingError.IdentityChanged)
        }
        val stored = store.setPin(
            pending.peerID, pending.peerSPKI, pending.peerName,
            allowIdentityChange = pending.classification == PairingClassification.IdentityChanged,
        )
        if (!stored) fail(PairingError.IdentityChanged)
    }
}
