package com.raisecaterror.meowdisplay.core.remote

import com.raisecaterror.meowdisplay.core.pairing.PairingAttempt
import com.raisecaterror.meowdisplay.core.pairing.PairingError
import com.raisecaterror.meowdisplay.core.pairing.PairingException
import com.raisecaterror.meowdisplay.core.pairing.PendingPairing
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicReference

// Pair over Remote (Shared/RemotePairing.swift): the same initiator as pairing with a nearby Mac,
// dialing an address the user typed. The address is a routing hint only. The trust boundary is the
// pairing ceremony itself (ECDH, a code confirmed on BOTH devices) and the pin store, whose rules
// are unchanged: a pin is never replaced by a different key.

/** Why a remote pairing did not finish, in words that tell the truth about what happened. */
enum class RemotePairingFailureKind(val title: String, val detail: String?, val retryable: Boolean = true) {
    DnsFailed("Can't find that address", "Check the address, and that Tailscale is on for both devices."),
    NoRoute("No route to that address", "This device can't reach it. Is Tailscale or the VPN on for both devices?"),
    NoAnswer("No answer from that address", "Is your Mac awake and online? Is Tailscale on for both devices?"),
    Refused("The Mac refused the connection", "On your Mac, open MeowDisplay → Pair over Remote (it stays open for 3 minutes), then try again."),
    Unreachable("Couldn't reach the Mac", "Make sure the address is correct and Pair over Remote is open on your Mac."),
    TimedOut("Pairing timed out", null),
    Rejected("Pairing was rejected", null),
    CancelledByPeer("Pairing was cancelled on your Mac", null),
    KeyChanged("This Mac is already paired with a different key", "Forget the Mac on this device first, then pair again.", retryable = false),
    CodesDidNotMatch("The codes did not match", "Nothing was paired. Try again."),
    UpdateRequired("Update MeowDisplay on both devices to pair", null, retryable = false),
    TooManyAttempts("Too many pairing attempts", "Wait 30 seconds and try again."),
    Failed("Pairing failed", null),
}

object RemotePairingFailure {
    /**
     * `null` means the user cancelled: return quietly. "Rejected" is only used when a handshake
     * really took place; a deadline with no handshake is "couldn't reach".
     */
    fun classify(error: Throwable, cancelledByUser: Boolean, deadlineFired: Boolean, handshakeReached: Boolean): RemotePairingFailureKind? {
        if (cancelledByUser) return null
        if (error is PairingException) {
            return when (error.error) {
                PairingError.IdentityChanged -> RemotePairingFailureKind.KeyChanged
                PairingError.CancelledByPeer -> RemotePairingFailureKind.CancelledByPeer
                PairingError.CancelledLocally -> null
                PairingError.TrustStateChanged -> RemotePairingFailureKind.Failed
                PairingError.InvalidKey, PairingError.InvalidConfirmation, PairingError.CommitmentMismatch -> RemotePairingFailureKind.CodesDidNotMatch
                PairingError.UnsupportedVersion -> RemotePairingFailureKind.UpdateRequired
                PairingError.TooManyAttempts -> RemotePairingFailureKind.TooManyAttempts
                PairingError.Rejected -> if (handshakeReached) {
                    if (deadlineFired) RemotePairingFailureKind.TimedOut else RemotePairingFailureKind.Rejected
                } else {
                    if (deadlineFired) RemotePairingFailureKind.Unreachable else RemotePairingFailureKind.Failed
                }
                PairingError.MalformedMessage -> if (handshakeReached) RemotePairingFailureKind.Failed else RemotePairingFailureKind.Unreachable
            }
        }
        return if (handshakeReached) {
            if (deadlineFired) RemotePairingFailureKind.TimedOut else RemotePairingFailureKind.Failed
        } else {
            RemotePairingFailureKind.Unreachable
        }
    }

    fun fromDial(failure: DialFailure): RemotePairingFailureKind = when (failure) {
        DialFailure.Dns -> RemotePairingFailureKind.DnsFailed
        DialFailure.TimedOut -> RemotePairingFailureKind.NoAnswer
        DialFailure.Refused -> RemotePairingFailureKind.Refused
        DialFailure.Unreachable -> RemotePairingFailureKind.NoRoute
        DialFailure.Other -> RemotePairingFailureKind.Unreachable
    }
}

sealed interface RemotePairingOutcome {
    /** Both people confirmed the code and the pin is stored (by the pairing core, not by this class). */
    class Paired(val pairing: PendingPairing) : RemotePairingOutcome

    data class Failed(val kind: RemotePairingFailureKind) : RemotePairingOutcome

    /** The user said the codes don't match, or backed out. Quiet. */
    data object Cancelled : RemotePairingOutcome
}

/** Connects a freshly created socket (a seam for tests; the pairing ceremony runs its own authentication over it). */
fun interface SocketConnector {
    fun connect(socket: Socket, address: InetSocketAddress, timeoutMs: Int)
}

object PlainSocketConnector : SocketConnector {
    override fun connect(socket: Socket, address: InetSocketAddress, timeoutMs: Int) = socket.connect(address, timeoutMs)
}

/**
 * Dials the Mac's Pair over Remote listener and runs the initiator side of the pairing ceremony.
 * Resolves and connects off the main thread, within [connectBudgetMs] across every resolved
 * address; the ceremony itself has [attemptTimeoutMs].
 */
class RemotePairingRunner(
    resolver: HostResolver = SystemHostResolver,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val connector: SocketConnector = PlainSocketConnector,
    private val connectBudgetMs: Long = 10_000,
    private val attemptTimeoutMs: Long = 65_000,
    dnsTimeoutMs: Long = 4_000,
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private val lookup = HostLookup(resolver, io, dnsTimeoutMs, nowMs)

    /**
     * [attemptFor] builds the pairing attempt on the connected socket; [decide] shows the code and
     * returns the user's answer. Never throws for a pairing or network failure.
     */
    suspend fun pair(
        endpoint: RemoteEndpoint,
        attemptFor: (Socket) -> PairingAttempt,
        decide: suspend (PendingPairing, PairingAttempt) -> Boolean,
    ): RemotePairingOutcome {
        val deadline = nowMs() + connectBudgetMs
        val addresses = lookup.lookup(endpoint.host, deadline) ?: return RemotePairingOutcome.Failed(RemotePairingFailureKind.DnsFailed)
        val socket = when (val dialed = dial(addresses, endpoint.port, deadline)) {
            is Dialed.Connected -> dialed.socket
            is Dialed.Failed -> return RemotePairingOutcome.Failed(RemotePairingFailure.fromDial(dialed.failure))
        }
        return socket.use {
            val attempt = attemptFor(socket)
            var handshakeReached = false
            var declined = false
            try {
                val pending = withTimeoutOrNull(attemptTimeoutMs) {
                    attempt.runInitiator(
                        expectedPeerID = null,
                        decide = { pending ->
                            handshakeReached = true
                            decide(pending, attempt).also { accepted -> if (!accepted) declined = true }
                        },
                    )
                }
                if (pending != null) {
                    RemotePairingOutcome.Paired(pending)
                } else {
                    outcome(RemotePairingFailure.classify(PairingException(PairingError.Rejected), declined, deadlineFired = true, handshakeReached = handshakeReached))
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: PairingException) {
                outcome(RemotePairingFailure.classify(e, declined, deadlineFired = false, handshakeReached = handshakeReached))
            } catch (e: IOException) {
                outcome(RemotePairingFailure.classify(e, declined, deadlineFired = false, handshakeReached = handshakeReached))
            }
        }
    }

    private fun outcome(kind: RemotePairingFailureKind?) =
        if (kind == null) RemotePairingOutcome.Cancelled else RemotePairingOutcome.Failed(kind)

    private sealed interface Dialed {
        class Connected(val socket: Socket) : Dialed
        class Failed(val failure: DialFailure) : Dialed
    }

    private suspend fun dial(addresses: List<java.net.InetAddress>, port: Int, deadline: Long): Dialed {
        val handedOver = AtomicReference<Socket?>()
        try {
            return coroutineScope {
                val connecting = AtomicReference<Socket?>()
                // A blocking connect ignores cancellation: closing the socket is what ends it.
                val guard = launch(io) {
                    try {
                        awaitCancellation()
                    } finally {
                        runCatching { connecting.get()?.close() }
                    }
                }
                try {
                    withContext(io) {
                        val failures = mutableListOf<DialFailure>()
                        for ((index, address) in addresses.withIndex()) {
                            val remaining = deadline - nowMs()
                            if (remaining <= 0) break
                            val share = maxOf(1_000L, remaining / (addresses.size - index)).coerceAtMost(remaining)
                            val socket = Socket().apply { tcpNoDelay = true }
                            connecting.set(socket)
                            try {
                                connector.connect(socket, InetSocketAddress(address, port), share.toInt())
                                connecting.set(null)
                                handedOver.set(socket)
                                return@withContext Dialed.Connected(socket)
                            } catch (e: IOException) {
                                connecting.set(null)
                                runCatching { socket.close() }
                                failures += DialErrors.classify(e)
                            }
                        }
                        Dialed.Failed(DialErrors.best(failures) ?: DialFailure.TimedOut)
                    }
                } finally {
                    guard.cancel()
                }
            }
        } catch (e: CancellationException) {
            // Cancelled after the connection was made: nobody else will close it.
            handedOver.get()?.let { runCatching { it.close() } }
            throw e
        }
    }
}
