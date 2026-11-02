package com.raisecaterror.meowdisplay.core.remote

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withTimeoutOrNull
import java.net.ConnectException
import java.net.InetAddress
import java.net.NoRouteToHostException
import java.net.PortUnreachableException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/** Why a TCP connection to a typed address could not be made. */
enum class DialFailure { Dns, TimedOut, Refused, Unreachable, Other }

object DialErrors {
    /** What a connect-time exception means, from its type and the system's own wording. */
    fun classify(error: Throwable): DialFailure {
        val chain = generateSequence(error) { it.cause }.take(6).toList()
        if (chain.any { it is SocketTimeoutException }) return DialFailure.TimedOut
        if (chain.any { it is NoRouteToHostException || it is PortUnreachableException }) return DialFailure.Unreachable
        val text = chain.mapNotNull { it.message }.joinToString(" ").lowercase()
        return when {
            "refused" in text -> DialFailure.Refused
            "timed out" in text || "timeout" in text -> DialFailure.TimedOut
            "unreachable" in text || "no route" in text -> DialFailure.Unreachable
            chain.any { it is UnknownHostException } -> DialFailure.Dns
            chain.any { it is ConnectException } -> DialFailure.Unreachable
            else -> DialFailure.Other
        }
    }

    /** When every address failed, the most informative reason wins: someone answered, then slow, then no route. */
    fun best(failures: List<DialFailure>): DialFailure? = failures.minByOrNull {
        when (it) {
            DialFailure.Refused -> 0
            DialFailure.TimedOut -> 1
            DialFailure.Unreachable -> 2
            else -> 3
        }
    }
}

/**
 * Resolves a typed host off the calling thread, under a timeout. A literal address is never sent to
 * the resolver. An answer that arrives too late is dropped; the lookup thread finishes on its own.
 */
class HostLookup(
    private val resolver: HostResolver,
    io: CoroutineDispatcher,
    private val dnsTimeoutMs: Long = 4_000,
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private val scope = CoroutineScope(SupervisorJob() + io)

    /** Up to [MAX_ADDRESSES] distinct addresses, or null when the name doesn't resolve in time. */
    suspend fun lookup(host: String, deadline: Long): List<InetAddress>? {
        val bare = if (host.startsWith("[") && host.endsWith("]")) host.substring(1, host.length - 1) else host
        IpLiteral.parse(bare)?.let { return listOf(InetAddress.getByAddress(it)) }
        val pending = scope.async { runCatching { resolver.resolve(bare) }.getOrNull() }
        val timeout = minOf(dnsTimeoutMs, (deadline - nowMs()).coerceAtLeast(1))
        val found = try {
            withTimeoutOrNull(timeout) { pending.await() }
        } catch (e: CancellationException) {
            pending.cancel()
            throw e
        }
        if (found == null) pending.cancel()
        return found?.distinctBy { it.hostAddress }?.take(MAX_ADDRESSES)?.takeIf { it.isNotEmpty() }
    }

    companion object {
        const val MAX_ADDRESSES = 4
    }
}
