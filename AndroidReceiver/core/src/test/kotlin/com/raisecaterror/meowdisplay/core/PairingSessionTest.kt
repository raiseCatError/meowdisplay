package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.Fixtures.b64
import com.raisecaterror.meowdisplay.core.Fixtures.obj
import com.raisecaterror.meowdisplay.core.Fixtures.str
import com.raisecaterror.meowdisplay.core.pairing.InMemoryPeerTrustStore
import com.raisecaterror.meowdisplay.core.pairing.PairingAttempt
import com.raisecaterror.meowdisplay.core.pairing.PairingClassification
import com.raisecaterror.meowdisplay.core.pairing.PairingCommitThrottle
import com.raisecaterror.meowdisplay.core.pairing.PairingEnvelope
import com.raisecaterror.meowdisplay.core.pairing.PairingError
import com.raisecaterror.meowdisplay.core.pairing.PairingException
import com.raisecaterror.meowdisplay.core.pairing.PairingFraming
import com.raisecaterror.meowdisplay.core.pairing.PairingHandshake
import com.raisecaterror.meowdisplay.core.pairing.PairingHelloCommitment
import com.raisecaterror.meowdisplay.core.pairing.PairingRole
import com.raisecaterror.meowdisplay.core.pairing.PairingTransport
import com.raisecaterror.meowdisplay.core.pairing.SocketPairingTransport
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket

/** Both roles in-process, over in-memory pipes and over a real loopback socket. */
class PairingSessionTest {
    /** One end of an in-memory duplex pipe; frames go through the real JSON encoding. */
    private class PipeEnd(private val outgoing: Channel<String>, private val incoming: Channel<String>) : PairingTransport {
        val sent = mutableListOf<PairingEnvelope.Kind>()

        override suspend fun send(envelope: PairingEnvelope) {
            sent += envelope.kind
            runCatching { outgoing.send(envelope.encode()) }.getOrElse { throw PairingException(PairingError.MalformedMessage) }
        }

        override suspend fun receive(): PairingEnvelope {
            val text = incoming.receiveCatching().getOrNull() ?: throw PairingException(PairingError.MalformedMessage)
            return PairingEnvelope.decode(text)
        }

        override fun sendLastAndClose(envelope: PairingEnvelope?) {
            envelope?.let { outgoing.trySend(it.encode()) }
            outgoing.close()
        }
    }

    private fun pipe(): Pair<PipeEnd, PipeEnd> {
        val a = Channel<String>(Channel.UNLIMITED)
        val b = Channel<String>(Channel.UNLIMITED)
        return PipeEnd(a, b) to PipeEnd(b, a)
    }

    /** Like the socket owner in the app: whatever happens, the connection closes afterwards. */
    private suspend fun <T> PipeEnd.session(block: suspend () -> T): Result<T> =
        runCatching { block() }.also { sendLastAndClose(null) }

    private val Result<*>.pairingError get() = (exceptionOrNull() as? PairingException)?.error

    private val case = Fixtures.pairingCases.first()
    private val mac = case.obj("initiator")
    private val android = case.obj("responder")

    private fun attempt(
        transport: PairingTransport,
        party: JsonObject,
        store: InMemoryPeerTrustStore,
        allowIdentityChange: Boolean = false,
    ) = PairingAttempt(
        transport = transport, store = store,
        localID = party.str("deviceID"), localName = party.str("displayName"), identitySPKI = party.b64("identitySPKI"),
        allowIdentityChange = allowIdentityChange,
        handshakeFactory = { role -> Fixtures.handshake(party, role) },
    )

    @Test
    fun bothAcceptAndBothPinTheOtherWithTheSwiftSas() = runBlocking {
        val (macEnd, androidEnd) = pipe()
        val macStore = InMemoryPeerTrustStore()
        val androidStore = InMemoryPeerTrustStore()
        val shown = mutableListOf<String>()
        val responder = async {
            androidEnd.session { attempt(androidEnd, android, androidStore).runResponder(PairingCommitThrottle(), decide = { shown += it.sas; true }) }
        }
        val initiated = macEnd.session { attempt(macEnd, mac, macStore).runInitiator(decide = { shown += it.sas; true }) }.getOrThrow()
        val responded = responder.await().getOrThrow()

        assertEquals(listOf(case.str("sas"), case.str("sas")), shown)
        assertEquals(android.str("deviceID"), initiated.peerID)
        assertEquals(mac.str("deviceID"), responded.peerID)
        assertArrayEquals(android.b64("identitySPKI"), macStore.pin(android.str("deviceID")))
        assertArrayEquals(mac.b64("identitySPKI"), androidStore.pin(mac.str("deviceID")))
        assertEquals(
            listOf(PairingEnvelope.Kind.HelloCommit, PairingEnvelope.Kind.HelloReveal, PairingEnvelope.Kind.Confirmation, PairingEnvelope.Kind.Commit),
            macEnd.sent,
        )
        assertEquals(listOf(PairingEnvelope.Kind.Hello, PairingEnvelope.Kind.Confirmation, PairingEnvelope.Kind.CommitAck), androidEnd.sent)
    }

    @Test
    fun aRejectionOnEitherSidePinsNothing() = runBlocking {
        for (androidAccepts in listOf(true, false)) {
            val (macEnd, androidEnd) = pipe()
            val macStore = InMemoryPeerTrustStore()
            val androidStore = InMemoryPeerTrustStore()
            val responder = async {
                androidEnd.session { attempt(androidEnd, android, androidStore).runResponder(PairingCommitThrottle(), decide = { androidAccepts }) }
            }
            val initiator = macEnd.session { attempt(macEnd, mac, macStore).runInitiator(decide = { !androidAccepts }) }
            assertEquals(PairingError.Rejected, initiator.pairingError)
            assertEquals(PairingError.Rejected, responder.await().pairingError)
            assertTrue(macStore.pins.isEmpty() && androidStore.pins.isEmpty())
        }
    }

    /** Cancel while the code is on screen: the peer sees an authenticated abort and nothing is pinned. */
    @Test
    fun cancellingDuringTheSasAbortsThePeer() = runBlocking {
        val (macEnd, androidEnd) = pipe()
        val macStore = InMemoryPeerTrustStore()
        val androidStore = InMemoryPeerTrustStore()
        val androidAttempt = attempt(androidEnd, android, androidStore)
        val androidShowing = CompletableDeferred<Unit>()
        val androidAnswer = CompletableDeferred<Boolean>()
        var peerAborted = false
        val responder = async {
            androidEnd.session {
                androidAttempt.runResponder(PairingCommitThrottle(), decide = { androidShowing.complete(Unit); androidAnswer.await() })
            }
        }
        val initiated = macEnd.session {
            attempt(macEnd, mac, macStore).runInitiator(
                decide = {
                    androidShowing.await()
                    assertTrue(androidAttempt.cancel())
                    androidAnswer.complete(false)
                    true
                },
                onPeerAbort = { peerAborted = true },
            )
        }
        assertEquals(PairingError.CancelledByPeer, initiated.pairingError)
        assertEquals(PairingError.Rejected, responder.await().pairingError)
        assertTrue(peerAborted)
        assertTrue(macStore.pins.isEmpty() && androidStore.pins.isEmpty())
    }

    /** A forged abort (wrong authenticator) is never trusted as a cancellation. */
    @Test
    fun anUnauthenticatedAbortEndsTheAttemptAsMalformed() = runBlocking {
        val (macEnd, androidEnd) = pipe()
        val androidStore = InMemoryPeerTrustStore()
        val responder = async {
            androidEnd.session { attempt(androidEnd, android, androidStore).runResponder(PairingCommitThrottle(), decide = { true }) }
        }
        val forger = object : PairingTransport by macEnd {
            override suspend fun send(envelope: PairingEnvelope) = macEnd.send(
                if (envelope.kind == PairingEnvelope.Kind.Confirmation) PairingEnvelope.step(PairingEnvelope.Kind.Abort, ByteArray(32))
                else envelope,
            )
        }
        macEnd.session { attempt(forger, mac, InMemoryPeerTrustStore()).runInitiator(decide = { true }) }
        assertEquals(PairingError.MalformedMessage, responder.await().pairingError)
        assertTrue(androidStore.pins.isEmpty())
    }

    /** A reveal that doesn't match the commitment never reaches the screen and counts against the listener. */
    @Test
    fun aSwappedRevealIsACommitmentMismatchAndThreeCoolTheListenerDown() = runBlocking {
        var now = 0L
        val throttle = PairingCommitThrottle { now }
        var sasShown = false
        repeat(3) { round ->
            val (macEnd, androidEnd) = pipe()
            val responder = async {
                androidEnd.session { attempt(androidEnd, android, InMemoryPeerTrustStore()).runResponder(throttle, decide = { sasShown = true; true }) }
            }
            val honest = Fixtures.handshake(mac, PairingRole.Initiator)
            val other = PairingHandshake(PairingRole.Initiator, mac.str("deviceID"), mac.str("displayName"), mac.b64("identitySPKI"))
            macEnd.send(PairingEnvelope.helloCommit(PairingHelloCommitment.compute(honest.localHello)))
            macEnd.receive()
            macEnd.send(PairingEnvelope.helloReveal(other.localHello))
            assertEquals("round $round", PairingError.CommitmentMismatch, responder.await().pairingError)
        }
        assertTrue(!sasShown)

        // Cooling down, even on a fresh connection.
        val (macEnd, androidEnd) = pipe()
        macEnd.send(PairingEnvelope.helloCommit(ByteArray(32)))
        val refused = androidEnd.session { attempt(androidEnd, android, InMemoryPeerTrustStore()).runResponder(throttle, decide = { true }) }
        assertEquals(PairingError.TooManyAttempts, refused.pairingError)
        assertTrue(androidEnd.sent.isEmpty())

        now += PairingCommitThrottle.COOLDOWN_MS
        assertTrue(throttle.admitCommitment() is PairingCommitThrottle.Admission.Admitted)
    }

    @Test
    fun theResponderSendsNothingBeforeAValidCommitment() = runBlocking {
        val (macEnd, androidEnd) = pipe()
        macEnd.send(PairingEnvelope.hello(Fixtures.handshake(mac, PairingRole.Initiator).localHello))
        val result = androidEnd.session { attempt(androidEnd, android, InMemoryPeerTrustStore()).runResponder(PairingCommitThrottle(), decide = { true }) }
        assertEquals(PairingError.MalformedMessage, result.pairingError)
        assertTrue(androidEnd.sent.isEmpty())
    }

    @Test
    fun aChangedIdentityIsRefusedUnlessExplicitlyAllowed() = runBlocking {
        for (allow in listOf(false, true)) {
            val (macEnd, androidEnd) = pipe()
            val androidStore = InMemoryPeerTrustStore().apply { pins[mac.str("deviceID")] = ByteArray(91) { 7 } }
            var classification: PairingClassification? = null
            val responder = async {
                androidEnd.session {
                    attempt(androidEnd, android, androidStore, allowIdentityChange = allow)
                        .runResponder(PairingCommitThrottle(), decide = { classification = it.classification; true })
                }
            }
            macEnd.session { attempt(macEnd, mac, InMemoryPeerTrustStore()).runInitiator(decide = { true }) }
            val result = responder.await()
            if (allow) {
                assertEquals(PairingClassification.IdentityChanged, classification)
                assertArrayEquals(mac.b64("identitySPKI"), androidStore.pin(mac.str("deviceID")))
            } else {
                assertNull("no code is shown for a changed identity", classification)
                assertEquals(PairingError.IdentityChanged, result.pairingError)
                assertArrayEquals(ByteArray(91) { 7 }, androidStore.pin(mac.str("deviceID")))
            }
        }
    }

    /** The same ceremony over a real loopback TCP connection with the production socket transport. */
    @Test
    fun aFullCeremonyOverALoopbackSocket() = runBlocking {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            val macStore = InMemoryPeerTrustStore()
            val androidStore = InMemoryPeerTrustStore()
            val responder = async(Dispatchers.IO) {
                server.accept().use { socket ->
                    attempt(SocketPairingTransport(socket), android, androidStore).runResponder(PairingCommitThrottle(), decide = { true })
                }
            }
            val pending = Socket(InetAddress.getLoopbackAddress(), server.localPort).use { socket ->
                withTimeout(10_000) { attempt(SocketPairingTransport(socket), mac, macStore).runInitiator(decide = { true }) }
            }
            withTimeout(10_000) { responder.await() }
            assertEquals(case.str("sas"), pending.sas)
            assertArrayEquals(android.b64("identitySPKI"), macStore.pin(android.str("deviceID")))
            assertArrayEquals(mac.b64("identitySPKI"), androidStore.pin(mac.str("deviceID")))
        }
    }

    /** The responder's 5-second reveal deadline fires even on a blocking socket. */
    @Test
    fun aMissingRevealTimesOutOnASocket() = runBlocking {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { server ->
            Socket(InetAddress.getLoopbackAddress(), server.localPort).use { client ->
                server.accept().use { socket ->
                    val transport = SocketPairingTransport(client)
                    transport.send(PairingEnvelope.helloCommit(ByteArray(32)))
                    val started = System.nanoTime()
                    val result = runCatching {
                        withTimeout(15_000) {
                            attempt(SocketPairingTransport(socket), android, InMemoryPeerTrustStore()).runResponder(PairingCommitThrottle(), decide = { true })
                        }
                    }
                    val elapsedMs = (System.nanoTime() - started) / 1_000_000
                    assertEquals(PairingError.MalformedMessage, result.pairingError)
                    assertTrue("took $elapsedMs ms", elapsedMs in 4_500..10_000)
                }
            }
        }
    }

    @Test
    fun framingRefusesEmptyOversizedAndTruncatedFrames() {
        fun read(bytes: ByteArray) = runCatching { PairingFraming.read(ByteArrayInputStream(bytes)) }
        for (bytes in listOf(byteArrayOf(0, 0, 0, 0), byteArrayOf(0, 1, 0, 1), byteArrayOf(0, 0, 0, 10, '{'.code.toByte()))) {
            assertEquals(PairingError.MalformedMessage, read(bytes).pairingError)
        }
        val envelope = PairingEnvelope.helloCommit(ByteArray(32) { it.toByte() })
        val decoded = PairingFraming.read(ByteArrayInputStream(PairingFraming.encode(envelope)))
        assertArrayEquals(envelope.helloCommitment, decoded.helloCommitment)
    }
}
