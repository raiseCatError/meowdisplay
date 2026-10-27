package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.tls.PinnedTls
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.InetAddress
import java.net.InetSocketAddress
import java.security.cert.X509Certificate
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509KeyManager

/** Pinned mutual TLS 1.3 over loopback, both roles, with persistent self-signed P-256 identities. */
class PinnedTlsTest {
    private val receiver = TestIdentity("receiver")
    private val mac = TestIdentity("mac")
    private val pool = Executors.newCachedThreadPool()

    /** What the listener saw: the admitted peer's SPKI (re-checked against current pins), or the failure. */
    private class Outcome(val admittedSPKI: ByteArray?, val error: Throwable?, val echoed: Int?)

    private fun serve(context: SSLContext, currentPins: () -> Collection<ByteArray>, connections: Int = 1): Pair<Int, List<java.util.concurrent.Future<Outcome>>> {
        val server = PinnedTls.serverSocket(context, 0)
        val futures = (0 until connections).map {
            pool.submit(Callable {
                try {
                    (server.accept() as SSLSocket).use { socket ->
                        socket.soTimeout = 5_000
                        socket.startHandshake()
                        val admitted = PinnedTls.verifiedPeerSPKI(socket, currentPins())
                        val echoed = if (admitted != null) socket.inputStream.read().also { socket.outputStream.write(it); socket.outputStream.flush() } else null
                        Outcome(admitted, null, echoed)
                    }
                } catch (e: Exception) {
                    Outcome(null, e, null)
                } finally {
                    if (it == connections - 1) server.close()
                }
            })
        }
        return server.localPort to futures
    }

    private fun dial(context: SSLContext, port: Int): Result<Int> = runCatching {
        PinnedTls.clientSocket(context, InetSocketAddress(InetAddress.getLoopbackAddress(), port), 5_000).use { socket ->
            socket.soTimeout = 5_000
            socket.startHandshake()
            socket.outputStream.write(42)
            socket.outputStream.flush()
            socket.inputStream.read().also { check(it == 42) { "echo $it" } }
        }
    }

    @Test
    fun pinnedPeersConnectWithTls13AndSeeEachOthersPin() {
        val (port, outcomes) = serve(PinnedTls.context(receiver.keyManager) { listOf(mac.spki) }, { listOf(mac.spki) })
        assertEquals(42, dial(PinnedTls.context(mac.keyManager) { listOf(receiver.spki) }, port).getOrThrow())
        val outcome = outcomes.single().get(10, TimeUnit.SECONDS)
        assertArrayEquals(mac.spki, outcome.admittedSPKI)
        assertEquals(42, outcome.echoed)
    }

    @Test
    fun anUnpinnedSenderIsRefusedByTheReceiver() {
        val stranger = TestIdentity("stranger")
        val (port, outcomes) = serve(PinnedTls.context(receiver.keyManager) { listOf(mac.spki) }, { listOf(mac.spki) })
        assertTrue(dial(PinnedTls.context(stranger.keyManager) { listOf(receiver.spki) }, port).isFailure)
        val outcome = outcomes.single().get(10, TimeUnit.SECONDS)
        assertNull(outcome.admittedSPKI)
        assertTrue(outcome.error != null)
    }

    @Test
    fun aSenderRefusesAReceiverItHasNotPinned() {
        val impostor = TestIdentity("impostor")
        val (port, outcomes) = serve(PinnedTls.context(impostor.keyManager) { listOf(mac.spki) }, { listOf(mac.spki) })
        assertTrue(dial(PinnedTls.context(mac.keyManager) { listOf(receiver.spki) }, port).isFailure)
        assertNull(outcomes.single().get(10, TimeUnit.SECONDS).admittedSPKI)
    }

    @Test
    fun aClientWithoutACertificateIsRefused() {
        val (port, outcomes) = serve(PinnedTls.context(receiver.keyManager) { listOf(mac.spki) }, { listOf(mac.spki) })
        val anonymous = SSLContext.getInstance("TLSv1.3").apply {
            init(null, arrayOf(trustAll), null)
        }
        assertTrue(dial(anonymous, port).isFailure)
        assertNull(outcomes.single().get(10, TimeUnit.SECONDS).admittedSPKI)
    }

    @Test
    fun aTls12OnlyPeerIsRefused() {
        val (port, outcomes) = serve(PinnedTls.context(receiver.keyManager) { listOf(mac.spki) }, { listOf(mac.spki) })
        val old = SSLContext.getInstance("TLSv1.2").apply { init(arrayOf(mac.keyManager), arrayOf(trustAll), null) }
        val result = runCatching {
            (old.socketFactory.createSocket(InetAddress.getLoopbackAddress(), port) as SSLSocket).use { socket ->
                socket.enabledProtocols = arrayOf("TLSv1.2")
                socket.soTimeout = 5_000
                socket.startHandshake()
            }
        }
        assertTrue(result.isFailure)
        assertNull(outcomes.single().get(10, TimeUnit.SECONDS).admittedSPKI)
    }

    @Test
    fun aNonP256IdentityIsNeverPinnable() {
        val rsa = TestIdentity("rsa", keyAlgorithm = "RSA")
        assertNull(PinnedTls.spki(rsa.certificate))
        val (port, outcomes) = serve(PinnedTls.context(receiver.keyManager) { listOf(rsa.spki) }, { listOf(rsa.spki) })
        assertTrue(dial(PinnedTls.context(rsa.keyManager) { listOf(receiver.spki) }, port).isFailure)
        assertNull(outcomes.single().get(10, TimeUnit.SECONDS).admittedSPKI)
    }

    /**
     * Forgetting a sender takes effect on its next connection even if TLS
     * resumes the earlier session (which skips the trust manager): admission
     * re-checks the peer against the current pins.
     */
    @Test
    fun aForgottenSenderIsRefusedEvenOnAResumedSession() {
        val pins = java.util.concurrent.CopyOnWriteArrayList(listOf(mac.spki))
        val (port, outcomes) = serve(PinnedTls.context(receiver.keyManager) { pins }, { pins }, connections = 2)
        val client = PinnedTls.context(mac.keyManager) { listOf(receiver.spki) }
        assertEquals(42, dial(client, port).getOrThrow())
        assertArrayEquals(mac.spki, outcomes[0].get(10, TimeUnit.SECONDS).admittedSPKI)

        pins.clear()
        dial(client, port)
        assertNull(outcomes[1].get(10, TimeUnit.SECONDS).admittedSPKI)
    }

    private val trustAll = object : javax.net.ssl.X509TrustManager {
        override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
        override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }
}
