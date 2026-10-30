package com.raisecaterror.meowdisplay.core.remote

import com.raisecaterror.meowdisplay.core.pairing.PeerDirectory
import com.raisecaterror.meowdisplay.core.tls.PinnedTls
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.security.cert.CertificateException
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLException
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509KeyManager

/**
 * How one knock ended. Every value is something that really happened on the wire; nothing is
 * guessed. A security failure ([IdentityMismatch], [NotAccepted]) is final: it is never retried
 * with another address and never falls back to anything.
 */
sealed interface KnockResult {
    /** The pinned handshake completed and the frame went out. The Mac decides what happens next. */
    data object Delivered : KnockResult

    /** The name did not resolve (or resolving took too long). */
    data object DnsFailed : KnockResult

    /** Nothing answered in time. */
    data object TimedOut : KnockResult

    /** A host answered, but nothing listens on that port. */
    data object Refused : KnockResult

    /** There is no route to the address. */
    data object Unreachable : KnockResult

    /**
     * The address answered with a key that is not this Mac's pin. [otherPeerID] names another paired
     * Mac that holds the key it presented, so the user can be told; it is never connected to or trusted.
     */
    data class IdentityMismatch(val otherPeerID: String?) : KnockResult

    /** Our side of the handshake passed, but the Mac ended the TLS session itself: it does not accept this device. */
    data object NotAccepted : KnockResult

    data object Cancelled : KnockResult

    /** Anything else: not TLS, or an I/O error. */
    data object Failed : KnockResult

    val isSecurityFailure: Boolean get() = this is IdentityMismatch || this == NotAccepted
}

/** Resolves a host name. Blocking; throws (an `UnknownHostException`) when it can't. */
fun interface HostResolver {
    fun resolve(host: String): List<InetAddress>
}

object SystemHostResolver : HostResolver {
    override fun resolve(host: String): List<InetAddress> = InetAddress.getAllByName(host).toList()
}

/** Opens a connected TLS client socket. The default is [PinnedTls.clientSocket]. */
fun interface TlsDialer {
    fun dial(context: SSLContext, address: InetSocketAddress, timeoutMs: Int): SSLSocket
}

object PinnedTlsDialer : TlsDialer {
    override fun dial(context: SSLContext, address: InetSocketAddress, timeoutMs: Int): SSLSocket =
        PinnedTls.clientSocket(context, address, timeoutMs)
}

/** One knock, as the coordinator sees it (a seam for tests). */
fun interface KnockTransport {
    suspend fun send(peerID: String, endpoint: RemoteEndpoint, intent: KnockIntent): KnockResult
}

/**
 * The receiver's side of Remote Wake & Connect (PROTOCOL.md 6.9): a pinned-mutual-TLS client
 * connection to the Mac's request port that sends ONE intent frame and closes. The device's own
 * Keystore identity is the client certificate and ONLY the expected Mac's pinned SPKI is trusted,
 * then re-confirmed after the handshake. Reachability proves nothing: tailnet membership or a
 * reachable port never becomes trust.
 *
 * The host is resolved off the main thread under a timeout, and every resolved address (IPv6 and
 * IPv4) is tried within one overall [budgetMs].
 */
class RemoteKnockClient(
    private val identity: X509KeyManager,
    private val pins: () -> Map<String, ByteArray>,
    private val resolver: HostResolver = SystemHostResolver,
    private val dialer: TlsDialer = PinnedTlsDialer,
    private val io: CoroutineDispatcher = Dispatchers.IO,
    private val budgetMs: Long = 8_000,
    private val dnsTimeoutMs: Long = 4_000,
    private val ackWaitMs: Long = 1_000,
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
) : KnockTransport {
    private val lookup = HostLookup(resolver, io, dnsTimeoutMs, nowMs)

    override suspend fun send(peerID: String, endpoint: RemoteEndpoint, intent: KnockIntent): KnockResult {
        val expected = pins()[peerID] ?: return KnockResult.Failed
        val deadline = nowMs() + budgetMs
        val addresses = lookup.lookup(endpoint.host, deadline) ?: return KnockResult.DnsFailed
        return coroutineScope {
            val open = AtomicReference<Closeable?>()
            // Blocking socket calls ignore cancellation: closing the socket is what ends them.
            val guard = launch(io) {
                try {
                    awaitCancellation()
                } finally {
                    runCatching { open.get()?.close() }
                }
            }
            try {
                withContext(io) { dialAll(addresses, endpoint.port, peerID, expected, intent, deadline, open) }
            } finally {
                guard.cancel()
            }
        }
    }

    private fun dialAll(
        addresses: List<InetAddress>, port: Int, peerID: String, expected: ByteArray,
        intent: KnockIntent, deadline: Long, open: AtomicReference<Closeable?>,
    ): KnockResult {
        val failures = mutableListOf<KnockResult>()
        for ((index, address) in addresses.withIndex()) {
            val remaining = deadline - nowMs()
            if (remaining <= 0) break
            // Share what is left among the addresses still to try, so a dead IPv6 route can't eat the budget.
            val share = maxOf(MIN_ATTEMPT_MS, remaining / (addresses.size - index)).coerceAtMost(remaining)
            when (val result = attempt(address, port, peerID, expected, intent, share.toInt(), open)) {
                KnockResult.Delivered, KnockResult.NotAccepted, is KnockResult.IdentityMismatch -> return result
                else -> failures += result
            }
        }
        return failures.minByOrNull { rank(it) } ?: KnockResult.TimedOut
    }

    /** When every address failed, the most informative reason wins: someone answered, then slow, then no route. */
    private fun rank(result: KnockResult): Int = when (result) {
        KnockResult.Refused -> 0
        KnockResult.TimedOut -> 1
        KnockResult.Unreachable -> 2
        else -> 3
    }

    private fun attempt(
        address: InetAddress, port: Int, peerID: String, expected: ByteArray, intent: KnockIntent,
        timeoutMs: Int, open: AtomicReference<Closeable?>,
    ): KnockResult {
        val presented = AtomicReference<ByteArray?>()
        val context = PinnedTls.context(identity, onPeerKey = presented::set) { listOf(expected) }
        var socket: SSLSocket? = null
        try {
            socket = dialer.dial(context, InetSocketAddress(address, port), timeoutMs)
            open.set(socket)
            socket.soTimeout = timeoutMs
            socket.startHandshake()
            // A resumed session skips the trust manager: confirm the key again against the one pin.
            val verified = PinnedTls.verifiedPeerSPKI(socket, listOf(expected))
            if (verified == null || !verified.contentEquals(expected)) {
                return KnockResult.IdentityMismatch(other(peerID, presented.get() ?: socket.peerKey()))
            }
            try {
                socket.outputStream.write(KnockFrame.encode(intent))
                socket.outputStream.flush()
            } catch (e: IOException) {
                // Our side of the pinned handshake passed, then the Mac hung up before reading a byte:
                // it is not accepting this device (typically because it forgot it).
                if (hungUp(e)) return KnockResult.NotAccepted
                throw e
            }
            return afterWrite(socket)
        } catch (e: Exception) {
            return classify(e, expected, presented.get(), peerID)
        } finally {
            open.set(null)
            runCatching { socket?.close() }
        }
    }

    /**
     * TLS 1.3 reports a client certificate the Mac refuses only after our side has finished, as an
     * alert on the next read. Wait briefly for the Mac to close (it does, right after reading the
     * frame) so that a Mac which no longer trusts this device is not reported as Delivered.
     */
    private fun afterWrite(socket: SSLSocket): KnockResult {
        socket.soTimeout = ackWaitMs.toInt().coerceAtLeast(1)
        return try {
            socket.inputStream.read()
            KnockResult.Delivered
        } catch (_: SocketTimeoutException) {
            KnockResult.Delivered
        } catch (e: SSLException) {
            if (e.message.orEmpty().contains("alert", ignoreCase = true)) KnockResult.NotAccepted else KnockResult.Delivered
        } catch (_: IOException) {
            KnockResult.Delivered
        }
    }

    private fun classify(error: Exception, expected: ByteArray, presented: ByteArray?, peerID: String): KnockResult {
        val chain = generateSequence<Throwable>(error) { it.cause }.take(6).toList()
        if (chain.any { it is SocketTimeoutException }) return KnockResult.TimedOut
        // The Mac's key was the pin, then it hung up on us while we presented ours: it does not accept this device.
        if (presented != null && presented.contentEquals(expected) && chain.any(::hungUp)) return KnockResult.NotAccepted
        if (chain.any { it is SSLException || it is CertificateException }) {
            return when {
                presented != null && !presented.contentEquals(expected) -> KnockResult.IdentityMismatch(other(peerID, presented))
                presented != null -> KnockResult.NotAccepted
                else -> KnockResult.Failed
            }
        }
        return when (DialErrors.classify(error)) {
            DialFailure.Dns -> KnockResult.DnsFailed
            DialFailure.TimedOut -> KnockResult.TimedOut
            DialFailure.Refused -> KnockResult.Refused
            DialFailure.Unreachable -> KnockResult.Unreachable
            DialFailure.Other -> KnockResult.Failed
        }
    }

    /** The other end ended the connection (as opposed to a timeout, an unreachable network or our own close). */
    private fun hungUp(error: Throwable): Boolean {
        val text = error.message.orEmpty().lowercase()
        return "broken pipe" in text || "connection reset" in text || "reset by peer" in text
    }

    /** Another paired Mac that holds the presented key. Used only to tell the user; never to connect. */
    private fun other(expectedPeerID: String, presented: ByteArray?): String? {
        presented ?: return null
        return PeerDirectory.uniquePeerID(pins().filterKeys { it != expectedPeerID }, presented)
    }

    private fun SSLSocket.peerKey(): ByteArray? = runCatching {
        PinnedTls.spki(session.peerCertificates.first() as java.security.cert.X509Certificate)
    }.getOrNull()

    private companion object {
        const val MIN_ATTEMPT_MS = 1_000L
    }
}

/**
 * At most one knock in flight per Mac. A second request for the same Mac joins the one in flight
 * (a [KnockIntent.Manual] one is never downgraded; a manual request replaces an in-flight
 * automatic one, because the user's tap must not be lost). Cancelling completes the result with
 * [KnockResult.Cancelled].
 */
class RemoteKnocker(
    private val transport: KnockTransport,
    private val scope: CoroutineScope,
) {
    private class Flight(val intent: KnockIntent, val result: CompletableDeferred<KnockResult>, val job: Job)

    private val flights = HashMap<String, Flight>()

    @Synchronized
    fun knock(peerID: String, endpoint: RemoteEndpoint, intent: KnockIntent): Deferred<KnockResult> {
        val current = flights[peerID]
        if (current != null && current.result.isActive) {
            if (current.intent == KnockIntent.Manual || intent == KnockIntent.Automatic) return current.result
            current.job.cancel()
        }
        val result = CompletableDeferred<KnockResult>()
        val job = scope.launch {
            try {
                result.complete(transport.send(peerID, endpoint, intent))
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                result.complete(KnockResult.Failed)
            }
        }
        // A knock cancelled before it even started still ends with an answer.
        job.invokeOnCompletion { result.complete(KnockResult.Cancelled) }
        val flight = Flight(intent, result, job)
        flights[peerID] = flight
        result.invokeOnCompletion { synchronized(this) { if (flights[peerID] === flight) flights.remove(peerID) } }
        return result
    }

    @Synchronized
    fun cancel(peerID: String) {
        flights[peerID]?.job?.cancel()
    }

    @Synchronized
    fun cancelAll() {
        flights.values.toList().forEach { it.job.cancel() }
    }

    @Synchronized
    fun isInFlight(peerID: String): Boolean = flights[peerID]?.result?.isActive == true
}
