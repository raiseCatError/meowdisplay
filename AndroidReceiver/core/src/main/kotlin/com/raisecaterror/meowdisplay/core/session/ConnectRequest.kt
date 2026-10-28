package com.raisecaterror.meowdisplay.core.session

import java.security.SecureRandom

/**
 * Receiver-initiated Connect (PROTOCOL.md 6.9, iOS StreamReceiver.requestConnect):
 * a paired Mac is asked to dial in by a one-shot `cr` token in this device's
 * own `_opensidecar._tcp` TXT record. The token proves nothing (the record
 * is unauthenticated); the Mac only dials a receiver it has pinned, over
 * pinned mutual TLS. A desired mode rides in `hello.requestedMode`, inside
 * the authenticated session, only to the Mac that was asked and only while
 * the request stands. Times are milliseconds on a monotonic clock.
 */
class ConnectRequestState(private val random: SecureRandom = SecureRandom()) {
    data class Request(val peerID: String, val mode: DisplayMode?, val token: String, val tokenUntil: Long, val until: Long)

    @Volatile private var current: Request? = null

    /** A new explicit Connect: a fresh token, replacing any earlier request. */
    @Synchronized
    fun request(peerID: String, mode: DisplayMode?, now: Long): Request {
        val bytes = ByteArray(8).also(random::nextBytes)
        val token = bytes.joinToString("") { "%02x".format(it) }
        return Request(peerID, mode, token, now + TOKEN_MS, now + REQUEST_MS).also { current = it }
    }

    /** The token to advertise now, if any. */
    @Synchronized
    fun token(now: Long): String? = current?.takeIf { now < it.tokenUntil }?.token

    /** The mode to put in a hello for [peerID]: only the Mac that was asked, only while the request stands. */
    @Synchronized
    fun requestedMode(peerID: String?, now: Long): DisplayMode? =
        current?.takeIf { peerID != null && it.peerID == peerID && now < it.until }?.mode

    /** True while a Connect for [peerID] is waiting (the Home row shows Connecting…). */
    @Synchronized
    fun isPending(peerID: String, now: Long): Boolean = current?.let { it.peerID == peerID && now < it.until } == true

    /** Answered (that Mac connected), cancelled, forgotten or blocked. */
    @Synchronized
    fun clear(peerID: String? = null) {
        if (peerID == null || current?.peerID == peerID) current = null
    }

    companion object {
        /** How long the TXT token stays published (iOS: 8 s). */
        const val TOKEN_MS = 8_000L
        /** How long `requestedMode` is offered (PROTOCOL.md 6.9: 30 s). */
        const val REQUEST_MS = 30_000L
    }
}
