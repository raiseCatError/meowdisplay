package com.raisecaterror.meowdisplay.core.tls

import com.raisecaterror.meowdisplay.core.crypto.Hkdf
import com.raisecaterror.meowdisplay.core.crypto.P256
import com.raisecaterror.meowdisplay.core.crypto.utf8
import java.net.InetSocketAddress
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509KeyManager
import javax.net.ssl.X509TrustManager

/**
 * Pinned mutual TLS 1.3 (Shared/TLSConfigurator.swift). Both sides present
 * persistent self-signed P-256 certificates; pinning REPLACES chain trust:
 * the peer's leaf SubjectPublicKeyInfo DER must equal a stored pin byte for
 * byte. TLS 1.3 only (downgrade-proof), the listener requires a client
 * certificate, and there is never a plaintext fallback.
 */
object PinnedTls {
    const val PROTOCOL = "TLSv1.3"

    /** The pinning representation of a certificate's key: SPKI DER of a P-256 key, else null. */
    fun spki(certificate: X509Certificate): ByteArray? =
        P256.publicKeyFromSpki(certificate.publicKey.encoded)?.encoded

    /**
     * A fresh context per connection or listener: no session cache is shared
     * with another trust decision. `pinnedSPKIs` is read during each handshake
     * and must be an in-memory snapshot. `onPeerKey` only OBSERVES the key the
     * peer presented (null when it is not a P-256 key), before the pin check
     * decides; it can name who answered a failed dial, and never trusts it.
     */
    fun context(
        identity: X509KeyManager,
        onPeerKey: ((ByteArray?) -> Unit)? = null,
        pinnedSPKIs: () -> Collection<ByteArray>,
    ): SSLContext =
        SSLContext.getInstance(PROTOCOL).apply {
            init(arrayOf(identity), arrayOf(PinTrustManager(pinnedSPKIs, onPeerKey)), SecureRandom())
        }

    fun clientSocket(context: SSLContext, address: InetSocketAddress, timeoutMs: Int): SSLSocket {
        val raw = java.net.Socket().apply {
            tcpNoDelay = true
            connect(address, timeoutMs)
        }
        val socket = context.socketFactory.createSocket(raw, address.hostString, address.port, true) as SSLSocket
        return socket.apply {
            enabledProtocols = arrayOf(PROTOCOL)
            useClientMode = true
        }
    }

    fun serverSocket(context: SSLContext, port: Int, backlog: Int = 4): SSLServerSocket =
        (context.serverSocketFactory.createServerSocket(port, backlog) as SSLServerSocket).apply {
            enabledProtocols = arrayOf(PROTOCOL)
            // Without this the listener silently degrades to one-way server auth.
            needClientAuth = true
        }

    /**
     * The authenticated peer's SPKI after the handshake, checked again against
     * the CURRENT pins. A resumed session skips the trust manager, so this,
     * not the handshake alone, is what admission relies on: a peer forgotten
     * since its last connection is refused here.
     */
    fun verifiedPeerSPKI(socket: SSLSocket, currentPins: Collection<ByteArray>): ByteArray? {
        val session = socket.session ?: return null
        if (session.protocol != PROTOCOL) return null
        val leaf = runCatching { session.peerCertificates.firstOrNull() as? X509Certificate }.getOrNull() ?: return null
        val spki = spki(leaf) ?: return null
        return spki.takeIf { pin -> currentPins.any { it.contentEquals(pin) } }
    }

    /**
     * Human-comparable grouped digits (TrustStore.fingerprint): HKDF-SHA256 of
     * the SPKI, five big-endian u16 values mod 10000, zero-padded, space-joined.
     */
    fun fingerprint(spki: ByteArray): String {
        val bytes = Hkdf.derive(spki, salt = "OpenDisplay-TLS-Pairing-v1".utf8, info = "fingerprint".utf8, length = 10)
        return (0 until 10 step 2).joinToString(" ") { i ->
            val value = ((bytes[i].toInt() and 0xFF) shl 8) or (bytes[i + 1].toInt() and 0xFF)
            "%04d".format(java.util.Locale.ROOT, value % 10000)
        }
    }

    private class PinTrustManager(
        private val pinnedSPKIs: () -> Collection<ByteArray>,
        private val onPeerKey: ((ByteArray?) -> Unit)?,
    ) : X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = check(chain)
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = check(chain)
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

        private fun check(chain: Array<out X509Certificate>?) {
            val leaf = chain?.firstOrNull() ?: throw CertificateException("no peer certificate")
            val spki = spki(leaf)
            onPeerKey?.invoke(spki)
            if (spki == null) throw CertificateException("peer key is not P-256")
            if (pinnedSPKIs().none { it.contentEquals(spki) }) throw CertificateException("peer is not pinned")
        }
    }
}
