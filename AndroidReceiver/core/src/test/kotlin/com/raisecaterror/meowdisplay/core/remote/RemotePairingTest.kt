package com.raisecaterror.meowdisplay.core.remote

import com.raisecaterror.meowdisplay.core.TestIdentity
import com.raisecaterror.meowdisplay.core.pairing.InMemoryPeerTrustStore
import com.raisecaterror.meowdisplay.core.pairing.PairingAttempt
import com.raisecaterror.meowdisplay.core.pairing.PairingCommitThrottle
import com.raisecaterror.meowdisplay.core.pairing.PairingError
import com.raisecaterror.meowdisplay.core.pairing.PairingException
import com.raisecaterror.meowdisplay.core.pairing.SocketPairingTransport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/** Pair over Remote: the nearby-Mac initiator, dialing a typed address, against a real responder on loopback. */
class RemotePairingTest {
    private val macIdentity = TestIdentity("mac")
    private val phoneIdentity = TestIdentity("phone")
    private val macID = UUID.randomUUID().toString().uppercase()
    private val phoneID = UUID.randomUUID().toString().uppercase()
    private val macStore = InMemoryPeerTrustStore()
    private val phoneStore = InMemoryPeerTrustStore()
    private val open = mutableListOf<Closeable>()

    @After
    fun closeAll() = open.forEach { runCatching { it.close() } }

    private fun attempt(socket: Socket, id: String, name: String, identity: TestIdentity, store: InMemoryPeerTrustStore) =
        PairingAttempt(SocketPairingTransport(socket), store, id, name, identity.spki)

    /** The Mac's "Pair over Remote" listener: runs the responder for each connection. */
    private inner class MacListener(private val accept: Boolean = true) : Closeable {
        private val server = ServerSocket(0)
        val port = server.localPort
        val sas = java.util.concurrent.LinkedBlockingQueue<String>()
        private val throttle = PairingCommitThrottle()

        init {
            open += this
            thread(isDaemon = true) {
                while (!server.isClosed) {
                    val socket = try { server.accept() } catch (_: IOException) { break }
                    thread(isDaemon = true) {
                        socket.use {
                            runCatching {
                                runBlocking {
                                    attempt(socket, macID, "Studio", macIdentity, macStore).runResponder(throttle, decide = { sas.add(it.sas); accept })
                                }
                            }
                        }
                    }
                }
            }
        }

        override fun close() { runCatching { server.close() } }
    }

    private val loopback = HostResolver { listOf(InetAddress.getLoopbackAddress()) }

    private fun pair(
        port: Int, host: String = "mac.test", resolver: HostResolver = loopback, connector: SocketConnector = PlainSocketConnector,
        shownSas: MutableList<String> = mutableListOf(), accept: Boolean = true, attemptTimeoutMs: Long = 20_000,
    ): RemotePairingOutcome = runBlocking {
        withTimeout(30_000) {
            RemotePairingRunner(resolver, connector = connector, connectBudgetMs = 3_000, attemptTimeoutMs = attemptTimeoutMs, dnsTimeoutMs = 500).pair(
                RemoteEndpoint(host, port),
                attemptFor = { attempt(it, phoneID, "Pixel", phoneIdentity, phoneStore) },
                decide = { pending, _ -> shownSas += pending.sas; accept },
            )
        }
    }

    @Test
    fun bothConfirmTheSameCodeAndBothPinTheOther() {
        val mac = MacListener()
        val shown = mutableListOf<String>()
        val outcome = pair(mac.port, shownSas = shown)
        assertTrue("$outcome", outcome is RemotePairingOutcome.Paired)
        val paired = (outcome as RemotePairingOutcome.Paired).pairing
        assertEquals(macID, paired.peerID)
        assertArrayEquals("the pin is the key the Mac presented in the ceremony", macIdentity.spki, phoneStore.pin(macID))
        assertArrayEquals(phoneIdentity.spki, macStore.pin(phoneID))
        assertEquals("the same code on both devices", mac.sas.poll(5, TimeUnit.SECONDS), shown.single())
    }

    @Test
    fun theUserSayingTheCodesDifferPinsNothingAndIsQuiet() {
        val mac = MacListener()
        assertEquals(RemotePairingOutcome.Cancelled, pair(mac.port, accept = false))
        assertNull(phoneStore.pin(macID))
        assertNull(macStore.pin(phoneID))
    }

    @Test
    fun theMacDecliningIsARejectionAndPinsNothing() {
        val mac = MacListener(accept = false)
        val outcome = pair(mac.port)
        assertTrue("$outcome", outcome is RemotePairingOutcome.Failed)
        assertTrue((outcome as RemotePairingOutcome.Failed).kind in setOf(RemotePairingFailureKind.Rejected, RemotePairingFailureKind.CancelledByPeer))
        assertNull(phoneStore.pin(macID))
    }

    @Test
    fun aMacAlreadyPairedWithADifferentKeyNeverReplacesThePinAndSaysForgetFirst() {
        val other = TestIdentity("old-mac")
        phoneStore.setPin(macID, other.spki, "Studio")
        val mac = MacListener()
        val outcome = pair(mac.port)
        assertEquals(RemotePairingOutcome.Failed(RemotePairingFailureKind.KeyChanged), outcome)
        assertTrue(!RemotePairingFailureKind.KeyChanged.retryable)
        assertTrue(RemotePairingFailureKind.KeyChanged.detail!!.contains("Forget"))
        assertArrayEquals("the existing pin is untouched", other.spki, phoneStore.pin(macID))
    }

    @Test
    fun theSameMacPairingAgainKeepsItsPin() {
        phoneStore.setPin(macID, macIdentity.spki, "Studio")
        val mac = MacListener()
        assertTrue(pair(mac.port) is RemotePairingOutcome.Paired)
        assertArrayEquals(macIdentity.spki, phoneStore.pin(macID))
    }

    @Test
    fun noAnswerRefusedAndNoRouteAndDnsEachSayWhatHappened() {
        val closedPort = ServerSocket(0).use { it.localPort }
        assertEquals(RemotePairingOutcome.Failed(RemotePairingFailureKind.Refused), pair(closedPort))
        assertEquals(RemotePairingOutcome.Failed(RemotePairingFailureKind.NoAnswer),
            pair(closedPort, connector = { _, _, _ -> throw SocketTimeoutException("connect timed out") }))
        assertEquals(RemotePairingOutcome.Failed(RemotePairingFailureKind.NoRoute),
            pair(closedPort, connector = { _, _, _ -> throw java.net.NoRouteToHostException("No route to host") }))
        assertEquals(RemotePairingOutcome.Failed(RemotePairingFailureKind.DnsFailed),
            pair(closedPort, resolver = { throw UnknownHostException(it) }))
        assertEquals(RemotePairingOutcome.Failed(RemotePairingFailureKind.DnsFailed), pair(closedPort, resolver = { emptyList() }))
        assertTrue(phoneStore.pinnedPeers().isEmpty())
    }

    @Test
    fun aMacWhosePairOverRemoteIsNotOpenAndHangsUpIsCouldntReach() {
        val server = ServerSocket(0).also { open += it }
        thread(isDaemon = true) { while (!server.isClosed) runCatching { server.accept().close() } }
        assertEquals(RemotePairingOutcome.Failed(RemotePairingFailureKind.Unreachable), pair(server.localPort))
    }

    @Test
    fun cancellingWhileConnectingClosesTheSocket() = runBlocking {
        val silent = ServerSocket(0, 1).also { open += it }
        val closed = CountDownLatch(1)
        thread(isDaemon = true) {
            val socket = silent.accept()
            runCatching { while (socket.getInputStream().read() >= 0) Unit }
            closed.countDown()
        }
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val job = scope.launch {
            RemotePairingRunner(loopback, attemptTimeoutMs = 30_000).pair(
                RemoteEndpoint("mac.test", silent.localPort),
                attemptFor = { attempt(it, phoneID, "Pixel", phoneIdentity, phoneStore) },
                decide = { _, _ -> true },
            )
        }
        delay(500)
        withTimeout(5_000) { job.cancelAndJoin() }
        assertTrue("the connection to the Mac was closed", closed.await(3, TimeUnit.SECONDS))
    }

    @Test
    fun failuresAreClassifiedTruthfully() {
        fun kind(e: Throwable, cancelled: Boolean = false, deadline: Boolean = false, reached: Boolean = false) =
            RemotePairingFailure.classify(e, cancelled, deadline, reached)
        fun p(error: PairingError) = PairingException(error)
        assertNull("a cancel is quiet", kind(p(PairingError.Rejected), cancelled = true, reached = true))
        assertNull(kind(p(PairingError.CancelledLocally)))
        assertEquals(RemotePairingFailureKind.KeyChanged, kind(p(PairingError.IdentityChanged)))
        assertEquals(RemotePairingFailureKind.CancelledByPeer, kind(p(PairingError.CancelledByPeer)))
        assertEquals(RemotePairingFailureKind.Failed, kind(p(PairingError.TrustStateChanged)))
        for (e in listOf(PairingError.InvalidKey, PairingError.InvalidConfirmation, PairingError.CommitmentMismatch))
            assertEquals(RemotePairingFailureKind.CodesDidNotMatch, kind(p(e)))
        assertEquals(RemotePairingFailureKind.UpdateRequired, kind(p(PairingError.UnsupportedVersion)))
        assertEquals(RemotePairingFailureKind.TooManyAttempts, kind(p(PairingError.TooManyAttempts)))
        assertEquals("rejection is only claimed after a handshake", RemotePairingFailureKind.Rejected, kind(p(PairingError.Rejected), reached = true))
        assertEquals(RemotePairingFailureKind.TimedOut, kind(p(PairingError.Rejected), deadline = true, reached = true))
        assertEquals("no handshake and the deadline passed: couldn't reach", RemotePairingFailureKind.Unreachable, kind(p(PairingError.Rejected), deadline = true))
        assertEquals(RemotePairingFailureKind.Failed, kind(p(PairingError.Rejected)))
        assertEquals(RemotePairingFailureKind.Unreachable, kind(p(PairingError.MalformedMessage)))
        assertEquals(RemotePairingFailureKind.Failed, kind(p(PairingError.MalformedMessage), reached = true))
        assertEquals(RemotePairingFailureKind.Unreachable, kind(IOException("reset")))
        assertEquals(RemotePairingFailureKind.TimedOut, kind(IOException("slow"), deadline = true, reached = true))
        assertTrue(RemotePairingFailureKind.entries.all { it.title.isNotBlank() })
    }
}
