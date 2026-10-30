package com.raisecaterror.meowdisplay.core.pairing

import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

/**
 * One pairing attempt over a connected transport (Shared/PairingNetwork.swift).
 * The caller owns the socket, the overall attempt deadline and the UI: `decide`
 * shows the SAS and returns the user's answer.
 */
class PairingAttempt(
    val transport: PairingTransport,
    val store: PeerTrustStore,
    val localID: String,
    val localName: String,
    val identitySPKI: ByteArray,
    val allowIdentityChange: Boolean = false,
    val isCurrent: () -> Boolean = { true },
    private val handshakeFactory: (PairingRole) -> PairingHandshake = { role ->
        PairingHandshake(role, localID, localName, identitySPKI)
    },
) {
    val gate = PairingCommitGate()
    val abortSlot = PairingAbortSlot()

    /** The local Cancel: true when it took effect (before this side committed). */
    fun cancel(): Boolean = PairingSessionCore.cancelAttempt(gate, abortSlot, transport)

    /**
     * Initiator: commit to our hello, receive theirs, reveal ours. The peer
     * must have chosen its hello before it could see ours.
     */
    suspend fun runInitiator(
        expectedPeerID: String? = null,
        decide: suspend (PendingPairing) -> Boolean,
        onPeerAbort: () -> Unit = {},
        onCommitting: () -> Unit = {},
    ): PendingPairing {
        val handshake = handshakeFactory(PairingRole.Initiator)
        transport.send(PairingEnvelope.helloCommit(PairingHelloCommitment.compute(handshake.localHello)))
        val response = transport.receive()
        val peerHello = response.hello
        if (response.kind != PairingEnvelope.Kind.Hello || peerHello == null) fail(PairingError.MalformedMessage)
        if (expectedPeerID != null && peerHello.deviceID != expectedPeerID) fail(PairingError.IdentityChanged)
        transport.send(PairingEnvelope.helloReveal(handshake.localHello))
        val result = handshake.result(peerHello)
        val pending = PairingClassifier.classify(result.pending, store.pin(result.pending.peerID))
        PairingClassifier.check(pending, allowIdentityChange)
        // A cancelled or superseded attempt never shows a code.
        if (!isCurrent() || gate.isCancelled) fail(PairingError.Rejected)
        PairingSessionCore.run(
            PairingRole.Initiator, result, pending, transport, gate, abortSlot,
            decide, onPeerAbort, onCommitting, store, isCurrent,
        )
        return pending
    }

    /**
     * Responder: nothing of ours (not even our hello) goes out until a valid
     * commitment is admitted by the listener's throttle, and the code reaches
     * the screen only after the reveal matched it.
     */
    suspend fun runResponder(
        throttle: PairingCommitThrottle,
        decide: suspend (PendingPairing) -> Boolean,
        onPeerAbort: () -> Unit = {},
        onCommitting: () -> Unit = {},
    ): PendingPairing {
        val request = transport.receive()
        val commitment = request.helloCommitment
        if (request.kind != PairingEnvelope.Kind.HelloCommit || commitment == null || commitment.size != 32) {
            fail(PairingError.MalformedMessage)
        }
        val admission = throttle.admitCommitment()
        if (admission !is PairingCommitThrottle.Admission.Admitted) fail(PairingError.TooManyAttempts)
        var throttleResolved = false
        try {
            val handshake = handshakeFactory(PairingRole.Responder)
            if (!isCurrent() || gate.isCancelled) fail(PairingError.Rejected)
            transport.send(PairingEnvelope.hello(handshake.localHello))
            val reveal = try {
                withTimeout(PairingCommitThrottle.REVEAL_DEADLINE_MS) { transport.receive() }
            } catch (_: TimeoutCancellationException) {
                fail(PairingError.MalformedMessage)
            }
            val peerHello = reveal.hello
            if (reveal.kind != PairingEnvelope.Kind.HelloReveal || peerHello == null) fail(PairingError.MalformedMessage)
            if (!PairingHelloCommitment.verify(commitment, peerHello)) fail(PairingError.CommitmentMismatch)
            val result = handshake.result(peerHello)
            val pending = PairingClassifier.classify(result.pending, store.pin(result.pending.peerID))
            PairingClassifier.check(pending, allowIdentityChange)
            if (!isCurrent() || gate.isCancelled) fail(PairingError.Rejected)
            throttleResolved = true
            throttle.revealSucceeded()
            try {
                PairingSessionCore.run(
                    PairingRole.Responder, result, pending, transport, gate, abortSlot,
                    decide, onPeerAbort, onCommitting, store, isCurrent,
                )
            } catch (e: Throwable) {
                // A code was shown and nothing was paired (declined, timed out, aborted).
                throttle.codeShownWithoutPairing()
                throw e
            }
            // Authenticated trust completion for THIS admission: only now is
            // earlier failure history forgiven.
            throttle.pairingSucceeded(admission.token)
            return pending
        } finally {
            if (!throttleResolved) throttle.revealFailed()
        }
    }
}
