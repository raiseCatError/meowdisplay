package com.raisecaterror.meowdisplay.core.remote

import com.raisecaterror.meowdisplay.core.TestIdentity
import com.raisecaterror.meowdisplay.core.tls.PinnedTls
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.Closeable
import java.io.DataInputStream
import java.io.IOException
import java.net.ConnectException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.UnknownHostException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import javax.net.ssl.SSLSocket
import kotlin.concurrent.thread

/** The knock client against real pinned-mTLS servers on loopback, with test identities. */
class RemoteKnockTest {
    private val phone = TestIdentity("phone")
    private val macA = TestIdentity("mac-a")
    private val macB = TestIdentity("mac-b")
    private val stranger = TestIdentity("stranger")
    private val open = mutableListOf<Closeable>()

    @After
    fun closeServers() = open.forEach { runCatching { it.close() } }

    /** The Mac's request listener: pinned mutual TLS, reads one frame, closes. */
    private inner class Mac(identity: TestIdentity, private val trusted: List<ByteArray> = listOf(phone.spki), private val handshakeDelayMs: Long = 0) : Closeable {
        private val server = PinnedTls.serverSocket(PinnedTls.context(identity.keyManager) { trusted }, 0)
        val port = server.localPort
        val frames = LinkedBlockingQueue<ByteArray>()
        val accepted = AtomicInteger()
        val refusedHandshakes = AtomicInteger()

        init {
            open += this
            thread(isDaemon = true) {
                while (!server.isClosed) {
                    val socket = try { server.accept() as SSLSocket } catch (_: IOException) { break }
                    accepted.incrementAndGet()
                    thread(isDaemon = true) { handle(socket) }
                }
            }
        }

        private fun handle(socket: SSLSocket) {
            socket.use {
                try {
                    socket.soTimeout = 5_000
                    if (handshakeDelayMs > 0) Thread.sleep(handshakeDelayMs)
                    socket.startHandshake()
                    if (PinnedTls.verifiedPeerSPKI(socket, trusted) == null) {
                        refusedHandshakes.incrementAndGet()
                    } else {
                        val input = DataInputStream(socket.inputStream)
                        val body = ByteArray(input.readInt())
                        input.readFully(body)
                        frames.add(byteArrayOf(0, 0, 0, body.size.toByte()) + body)
                    }
                } catch (_: Exception) {
                    refusedHandshakes.incrementAndGet()
                }
            }
        }

        fun intent(): KnockIntent = KnockFrame.intent(frames.poll(5, TimeUnit.SECONDS))

        override fun close() { runCatching { server.close() } }
    }

    /** A port where something accepts TCP and then never says a word. */
    private inner class Silent : Closeable {
        private val server = ServerSocket(0)
        val port = server.localPort
        val closedByClient = CountDownLatch(1)
        private val sockets = mutableListOf<Socket>()

        init {
            open += this
            thread(isDaemon = true) {
                while (!server.isClosed) {
                    val socket = try { server.accept() } catch (_: IOException) { break }
                    sockets += socket
                    thread(isDaemon = true) {
                        try { while (socket.getInputStream().read() >= 0) Unit } catch (_: IOException) { }
                        closedByClient.countDown()
                    }
                }
            }
        }

        override fun close() { runCatching { server.close() }; sockets.forEach { runCatching { it.close() } } }
    }

    private val loopback = HostResolver { listOf(InetAddress.getLoopbackAddress()) }
    private fun client(
        resolver: HostResolver = loopback, dialer: TlsDialer = PinnedTlsDialer, budgetMs: Long = 4_000, dnsTimeoutMs: Long = 4_000,
    ) = RemoteKnockClient(
        identity = phone.keyManager,
        pins = { mapOf("A" to macA.spki, "B" to macB.spki) },
        resolver = resolver, dialer = dialer, budgetMs = budgetMs, dnsTimeoutMs = dnsTimeoutMs,
    )

    private fun knock(client: RemoteKnockClient, port: Int, intent: KnockIntent = KnockIntent.Manual, host: String = "127.0.0.1", peer: String = "A"): KnockResult =
        runBlocking { withTimeout(20_000) { client.send(peer, RemoteEndpoint(host, port), intent) } }

    @Test
    fun theMacGetsExactlyOneManualFrameOverPinnedTls() {
        val mac = Mac(macA)
        assertEquals(KnockResult.Delivered, knock(client(), mac.port, KnockIntent.Manual))
        assertEquals(KnockIntent.Manual, mac.intent())
        assertEquals(1, mac.accepted.get())
    }

    @Test
    fun anAutomaticKnockSaysAutomatic() {
        val mac = Mac(macA)
        assertEquals(KnockResult.Delivered, knock(client(), mac.port, KnockIntent.Automatic))
        assertEquals(KnockIntent.Automatic, mac.intent())
    }

    @Test
    fun aHostNameIsResolvedByTheInjectedResolverAndALiteralNeverIs() {
        val mac = Mac(macA)
        val asked = mutableListOf<String>()
        val resolver = HostResolver { host -> asked += host; listOf(InetAddress.getLoopbackAddress()) }
        assertEquals(KnockResult.Delivered, knock(client(resolver), mac.port, host = "mac.tailnet.ts.net"))
        assertEquals(KnockResult.Delivered, knock(client(resolver), mac.port, host = "127.0.0.1"))
        assertEquals(listOf("mac.tailnet.ts.net"), asked)
    }

    @Test
    fun anotherPairedMacsKeyIsAMismatchThatNamesItAndNeverConnects() {
        val impostor = Mac(macB)
        val result = knock(client(), impostor.port, peer = "A")
        assertEquals(KnockResult.IdentityMismatch("B"), result)
        assertTrue("no frame went to a Mac we did not mean", impostor.frames.isEmpty())
    }

    @Test
    fun anUnpinnedKeyIsAMismatchThatNamesNobody() {
        val unknown = Mac(stranger)
        assertEquals(KnockResult.IdentityMismatch(null), knock(client(), unknown.port))
        assertTrue(unknown.frames.isEmpty())
    }

    @Test
    fun aMismatchIsFinalAndNoOtherAddressIsTried() {
        val impostor = Mac(macB)
        var dials = 0
        val dialer = TlsDialer { context, address, timeout -> dials++; PinnedTlsDialer.dial(context, address, timeout) }
        val twoAddresses = HostResolver { listOf(InetAddress.getLoopbackAddress(), InetAddress.getByName("127.0.0.1")) }
        // distinctBy hostAddress collapses these; use two distinct loopback addresses where available.
        val second = runCatching { InetAddress.getByName("::1") }.getOrNull()
        val resolver = if (second != null) HostResolver { listOf(InetAddress.getByName("127.0.0.1"), second) } else twoAddresses
        assertEquals(KnockResult.IdentityMismatch("B"), knock(client(resolver, dialer), impostor.port, host = "mac.test"))
        assertEquals(1, dials)
    }

    @Test
    fun aMacThatNoLongerTrustsThisDeviceIsNotAcceptedNotDelivered() {
        val mac = Mac(macA, trusted = emptyList())
        assertEquals(KnockResult.NotAccepted, knock(client(), mac.port))
        assertTrue(mac.frames.isEmpty())
    }

    @Test
    fun nothingListeningIsRefused() {
        val port = ServerSocket(0).use { it.localPort }
        assertEquals(KnockResult.Refused, knock(client(), port))
    }

    @Test
    fun aServerThatNeverHandshakesTimesOutWithinTheBudget() {
        val silent = Silent()
        val started = System.nanoTime()
        assertEquals(KnockResult.TimedOut, knock(client(budgetMs = 700), silent.port))
        val tookMs = (System.nanoTime() - started) / 1_000_000
        assertTrue("took $tookMs ms", tookMs in 500..4_000)
    }

    @Test
    fun dnsFailureComesFromTheResolver() {
        assertEquals(KnockResult.DnsFailed, knock(client(HostResolver { throw UnknownHostException(it) }), 9003, host = "nope.ts.net"))
        assertEquals(KnockResult.DnsFailed, knock(client(HostResolver { emptyList() }), 9003, host = "nope.ts.net"))
    }

    @Test
    fun aResolverThatNeverAnswersTimesOutAsDnsFailure() {
        val stuck = HostResolver { Thread.sleep(15_000); emptyList() }
        val started = System.nanoTime()
        assertEquals(KnockResult.DnsFailed, knock(client(stuck, dnsTimeoutMs = 300), 9003, host = "slow.ts.net"))
        assertTrue((System.nanoTime() - started) / 1_000_000 < 5_000)
    }

    @Test
    fun aKnockForAMacThatIsNotPairedSendsNothing() {
        val mac = Mac(macA)
        assertEquals(KnockResult.Failed, knock(client(), mac.port, peer = "nobody"))
        assertEquals(0, mac.accepted.get())
    }

    @Test
    fun theNextAddressIsTriedWhenTheFirstIsRefused() {
        val mac = Mac(macA)
        var dials = 0
        // Whatever address it is handed, the second dial reaches the Mac on loopback.
        val dialer = TlsDialer { context, address, timeout ->
            if (dials++ == 0) throw ConnectException("Connection refused")
            PinnedTlsDialer.dial(context, InetSocketAddress(InetAddress.getLoopbackAddress(), address.port), timeout)
        }
        val two = HostResolver { listOf(InetAddress.getByName("127.0.0.1"), InetAddress.getByName("127.0.0.2")) }
        assertEquals(KnockResult.Delivered, knock(client(two, dialer), mac.port, host = "mac.test"))
        assertEquals(2, dials)
        assertEquals(KnockIntent.Manual, mac.intent())
    }

    @Test
    fun whenEveryAddressFailsTheMostInformativeReasonWins() {
        val reasons = listOf(ConnectException("Network is unreachable"), ConnectException("Connection refused"))
        var i = 0
        val dialer = TlsDialer { _, _, _ -> throw reasons[i++] }
        val two = HostResolver { listOf(InetAddress.getByName("127.0.0.1"), InetAddress.getByName("127.0.0.2")) }
        assertEquals("someone answered beats no route", KnockResult.Refused, knock(client(two, dialer), 9003, host = "mac.test"))
        val unreachable = TlsDialer { _, _, _ -> throw java.net.NoRouteToHostException("No route to host") }
        assertEquals(KnockResult.Unreachable, knock(client(dialer = unreachable), 9003))
    }

    @Test
    fun cancellingClosesTheConnectionAndEndsTheKnockAtOnce() = runBlocking {
        val silent = Silent()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val job: Job = scope.launch { client(budgetMs = 30_000).send("A", RemoteEndpoint("127.0.0.1", silent.port), KnockIntent.Manual) }
        delay(400)
        val started = System.nanoTime()
        withTimeout(5_000) { job.cancelAndJoin() }
        assertTrue("cancelled quickly", (System.nanoTime() - started) / 1_000_000 < 2_500)
        assertTrue("the socket was closed, not left hanging", silent.closedByClient.await(3, TimeUnit.SECONDS))
    }

    @Test
    fun concurrentKnocksForOneMacBecomeOneConnection() = runBlocking {
        val mac = Mac(macA, handshakeDelayMs = 500)
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val knocker = RemoteKnocker(client(), scope)
        val endpoint = RemoteEndpoint("127.0.0.1", mac.port)
        val results = List(4) { knocker.knock("A", endpoint, KnockIntent.Manual) }
        assertTrue("the same flight", results.all { it === results.first() })
        withTimeout(20_000) { assertEquals(KnockResult.Delivered, results.first().await()) }
        assertEquals(1, mac.accepted.get())
    }

    // MARK: - RemoteKnocker with a scripted transport

    private class Scripted : KnockTransport {
        val calls = java.util.concurrent.CopyOnWriteArrayList<KnockIntent>()
        val gate = CompletableDeferred<KnockResult>()
        override suspend fun send(peerID: String, endpoint: RemoteEndpoint, intent: KnockIntent): KnockResult {
            calls += intent
            return gate.await()
        }
    }

    @Test
    fun aManualRequestReplacesAnAutomaticKnockInFlightButNeverTheOtherWayRound() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val transport = Scripted()
        val knocker = RemoteKnocker(transport, scope)
        val endpoint = RemoteEndpoint("mac.ts.net", 9003)
        val automatic = knocker.knock("A", endpoint, KnockIntent.Automatic)
        delay(100)
        val manual = knocker.knock("A", endpoint, KnockIntent.Manual)
        assertEquals("the user's tap is never lost", KnockResult.Cancelled, withTimeout(5_000) { automatic.await() })
        val again = knocker.knock("A", endpoint, KnockIntent.Automatic)
        assertTrue("recovery joins the user's knock instead of starting a second", again === manual)
        withTimeout(5_000) { while (transport.calls.size < 2) delay(20) }
        assertEquals(listOf(KnockIntent.Automatic, KnockIntent.Manual), transport.calls)
        transport.gate.complete(KnockResult.Delivered)
        assertEquals(KnockResult.Delivered, withTimeout(5_000) { manual.await() })
    }

    @Test
    fun differentMacsKnockIndependentlyAndCancelAnswersCancelled() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val transport = Scripted()
        val knocker = RemoteKnocker(transport, scope)
        val a = knocker.knock("A", RemoteEndpoint("a.ts.net", 9003), KnockIntent.Manual)
        val b = knocker.knock("B", RemoteEndpoint("b.ts.net", 9003), KnockIntent.Manual)
        assertTrue(a !== b)
        withTimeout(5_000) { while (transport.calls.size < 2) delay(20) }
        assertEquals(2, transport.calls.size)
        assertTrue(knocker.isInFlight("A"))
        knocker.cancel("A")
        assertEquals(KnockResult.Cancelled, withTimeout(5_000) { a.await() })
        assertTrue("B is untouched", b.isActive)
        knocker.cancelAll()
        assertEquals(KnockResult.Cancelled, withTimeout(5_000) { b.await() })
    }
}
