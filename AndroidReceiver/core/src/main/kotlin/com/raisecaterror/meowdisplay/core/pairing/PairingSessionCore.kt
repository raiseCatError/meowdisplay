package com.raisecaterror.meowdisplay.core.pairing

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * The linearization point of an attempt: open -> committed or cancelled,
 * decided atomically. Cancel wins only while open; a commit begins only while open.
 */
class PairingCommitGate {
    private enum class State { Open, Committed, Cancelled }

    private var state = State.Open

    val isCancelled: Boolean @Synchronized get() = state == State.Cancelled
    val isCommitted: Boolean @Synchronized get() = state == State.Committed

    @Synchronized
    fun beginCommit(): Boolean {
        if (state != State.Open) return false
        state = State.Committed
        return true
    }

    /** False when it is too late (already committed). */
    @Synchronized
    fun cancel(): Boolean {
        if (state == State.Committed) return false
        state = State.Cancelled
        return true
    }
}

class PairingAbortSlot {
    private val value = AtomicReference<PairingEnvelope?>(null)
    val envelope: PairingEnvelope? get() = value.get()
    fun set(envelope: PairingEnvelope) = value.set(envelope)
}

/**
 * Reads peer frames concurrently with the local SAS prompt, so an
 * authenticated abort ends the attempt at once, even while the code is on
 * screen. An abort that fails authentication ends it as malformed.
 */
internal class PairingFramePump(
    transport: PairingTransport,
    result: PairingResult,
    onPeerAbort: () -> Unit,
) {
    val peerAborted = AtomicBoolean(false)
    private val frames = Channel<Result<PairingEnvelope>>(Channel.UNLIMITED)

    // Detached: a blocking socket read ends only when the caller closes the
    // socket, and run() must not wait for that.
    private val job: Job = CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
        try {
            while (true) {
                val envelope = transport.receive()
                if (envelope.kind == PairingEnvelope.Kind.Abort) {
                    val authentic = envelope.authenticator?.let {
                        runCatching { result.verifyStep(PairingResult.Step.Abort, it) }.isSuccess
                    } == true
                    if (authentic) {
                        peerAborted.set(true)
                        onPeerAbort()
                        frames.send(Result.failure(PairingException(PairingError.CancelledByPeer)))
                    } else {
                        frames.send(Result.failure(PairingException(PairingError.MalformedMessage)))
                    }
                    return@launch
                }
                frames.send(Result.success(envelope))
            }
        } catch (e: Exception) {
            frames.trySend(Result.failure(e))
        }
    }

    suspend fun next(): PairingEnvelope = frames.receive().getOrThrow()

    fun stop() = job.cancel()
}

/**
 * Post-hello state machine (Shared/PairingSession.swift `PairingSessionCore`),
 * independent of sockets and storage so both roles run in-process in tests.
 *
 * After both hellos (SAS on both screens):
 *  1. each side: local decision -> `confirmation(accepted)` (provisional);
 *  2. initiator, once it accepted and verified the responder's accept: `commit`
 *     (its linearization point);
 *  3. responder, having accepted and verified the initiator's accept, receives
 *     `commit`: persists trust, replies `commitAck` (its linearization point);
 *  4. initiator receives `commitAck`: persists trust.
 * A dropped abort still completes nothing: the missing commit/ack never arrives.
 */
object PairingSessionCore {
    fun cancelAttempt(gate: PairingCommitGate, slot: PairingAbortSlot, transport: PairingTransport): Boolean {
        if (!gate.cancel()) return false
        transport.sendLastAndClose(slot.envelope)
        return true
    }

    suspend fun run(
        role: PairingRole,
        result: PairingResult,
        pending: PendingPairing,
        transport: PairingTransport,
        gate: PairingCommitGate,
        abortSlot: PairingAbortSlot,
        decide: suspend (PendingPairing) -> Boolean,
        onPeerAbort: () -> Unit = {},
        onCommitting: () -> Unit = {},
        store: PeerTrustStore,
        isCurrent: () -> Boolean = { true },
    ) {
        abortSlot.set(PairingEnvelope.step(PairingEnvelope.Kind.Abort, result.stepAuthenticator(PairingResult.Step.Abort)))
        val pump = PairingFramePump(transport, result, onPeerAbort)
        try {
            if (pump.peerAborted.get()) fail(PairingError.CancelledByPeer)
            val accepted = decide(pending)
            if (pump.peerAborted.get()) fail(PairingError.CancelledByPeer)
            if (gate.isCancelled) fail(PairingError.Rejected)
            transport.send(PairingEnvelope.confirmation(result.confirmation(accepted)))
            if (!accepted) fail(PairingError.Rejected)

            fun finalize(peerConfirmation: PairingConfirmation) =
                PairingFinalizer.complete(result, pending, peerConfirmation, store, isCurrent)

            when (role) {
                PairingRole.Initiator -> {
                    val reply = pump.next()
                    val confirmation = reply.confirmation
                    if (reply.kind != PairingEnvelope.Kind.Confirmation || confirmation == null) {
                        fail(PairingError.MalformedMessage)
                    }
                    result.verify(confirmation)
                    if (!gate.beginCommit()) fail(PairingError.Rejected)
                    onCommitting()
                    transport.send(PairingEnvelope.step(PairingEnvelope.Kind.Commit, result.stepAuthenticator(PairingResult.Step.Commit)))
                    val ack = pump.next()
                    val auth = ack.authenticator
                    if (ack.kind != PairingEnvelope.Kind.CommitAck || auth == null) fail(PairingError.MalformedMessage)
                    result.verifyStep(PairingResult.Step.CommitAck, auth)
                    finalize(confirmation)
                }
                PairingRole.Responder -> {
                    var peerConfirmation: PairingConfirmation? = null
                    while (true) {
                        val frame = pump.next()
                        when (frame.kind) {
                            PairingEnvelope.Kind.Confirmation -> {
                                val confirmation = frame.confirmation ?: fail(PairingError.MalformedMessage)
                                result.verify(confirmation)
                                peerConfirmation = confirmation
                            }
                            PairingEnvelope.Kind.Commit -> {
                                val confirmation = peerConfirmation ?: fail(PairingError.MalformedMessage)
                                val auth = frame.authenticator ?: fail(PairingError.MalformedMessage)
                                result.verifyStep(PairingResult.Step.Commit, auth)
                                if (!gate.beginCommit()) fail(PairingError.Rejected)
                                onCommitting()
                                finalize(confirmation)
                                // Already committed and persisted: a lost ack cannot undo it.
                                runCatching {
                                    transport.send(PairingEnvelope.step(PairingEnvelope.Kind.CommitAck, result.stepAuthenticator(PairingResult.Step.CommitAck)))
                                }
                                return
                            }
                            else -> fail(PairingError.MalformedMessage)
                        }
                    }
                }
            }
        } finally {
            pump.stop()
        }
    }
}
