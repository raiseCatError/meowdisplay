package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.crypto.uint32BE
import com.raisecaterror.meowdisplay.core.session.HelloFields
import com.raisecaterror.meowdisplay.core.session.InMemorySessionPolicyStore
import com.raisecaterror.meowdisplay.core.session.MediaListener
import com.raisecaterror.meowdisplay.core.session.ReceiverSession
import com.raisecaterror.meowdisplay.core.session.SessionEvent
import com.raisecaterror.meowdisplay.core.session.SessionLossReason
import com.raisecaterror.meowdisplay.core.tls.PinnedTls
import com.raisecaterror.meowdisplay.core.wire.WireFraming
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.Closeable
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.SSLSocket

/**
 * The media listener over loopback with real pinned mutual TLS 1.3: who gets
 * a session, who never does, and that bad bytes end only their own connection.
 */
class MediaListenerTest {
    private val receiver = TestIdentity("receiver")
    private val macA = TestIdentity("mac-a")
    private val macB = TestIdentity("mac-b")
    private val pins = ConcurrentHashMap(mapOf(MAC_A to macA.spki, MAC_B to macB.spki))
    private val policies = InMemorySessionPolicyStore()
    private val events: MutableList<SessionEvent> = Collections.synchronizedList(mutableListOf())
    private val skew = AtomicLong()
    private val session = ReceiverSession(
        policies, { pins.toMap() }, { HelloFields(1080, 2400, 3.0, RECEIVER_ID) }, { events += it },
        { System.currentTimeMillis() + skew.get() },
    )
    private val listener = MediaListener(
        PinnedTls.context(receiver.keyManager) { pins.values.toList() }, { pins.toMap() }, session,
        port = 0, handshakeTimeoutMs = 600, maxPendingHandshakes = 2,
    ).apply { start() }

    @After
    fun tearDown() = listener.close()

    /** The Mac's side: dials the receiver and pins it, like MacSender does. */
    private inner class Mac(identity: TestIdentity, pinnedReceiver: ByteArray = receiver.spki, protocols: Array<String>? = null) : Closeable {
        val socket: SSLSocket = PinnedTls.clientSocket(
            PinnedTls.context(identity.keyManager) { listOf(pinnedReceiver) },
            InetSocketAddress(InetAddress.getLoopbackAddress(), listener.localPort), 5_000,
        ).apply {
            protocols?.let { enabledProtocols = it }
            soTimeout = 5_000
            startHandshake()
        }
        private val input = WireFraming.reader(socket.inputStream)

        fun sendRaw(bytes: ByteArray) {
            socket.outputStream.write(bytes)
            socket.outputStream.flush()
        }

        fun send(json: String) = json.toByteArray().let { sendRaw(uint32BE(it.size.toLong()) + it) }

        fun read(): JsonObject? = WireFraming.read(input)?.let { Json.parseToJsonElement(String(it)).jsonObject }

        /** The next message of [type], skipping liveness pings. */
        fun expect(type: String): JsonObject {
            while (true) {
                val message = read() ?: fail("connection closed waiting for $type") as Nothing
                if (message["type"]!!.jsonPrimitive.content == type) return message
            }
        }

        /** True once the receiver has closed this connection. */
        fun closedByReceiver(): Boolean = try {
            while (read() != null) Unit
            true
        } catch (_: IOException) {
            true
        }

        fun admit(id: String = "session-1") {
            expect("hello")
            send("{\"type\":\"welcome\",\"pv\":22,\"min\":1}")
            send("{\"type\":\"sessionInvite\",\"id\":\"$id\",\"initiator\":\"sender\",\"intent\":\"automatic\",\"mode\":\"extend\",\"awaitingSender\":false}")
            // As in Swift: admission asks for a keyframe, then answers.
            expect("kf")
            assertEquals("accepted", expect("sessionInviteResponse")["result"]!!.jsonPrimitive.content)
        }

        override fun close() = socket.close()
    }

    private fun eventually(what: String, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (!condition()) {
            if (System.currentTimeMillis() > deadline) fail("timed out: $what")
            Thread.sleep(10)
        }
    }

    /** The receiver ended a connection that never completed TLS: EOF, at most after one TLS alert record. */
    private fun endsWithoutTls(socket: Socket): Boolean {
        val bytes = runCatching { socket.getInputStream().readBytes() }.getOrElse { return true }
        return bytes.isEmpty() || bytes[0] == 0x15.toByte()
    }

    private fun connectedPeers() = synchronized(events) { events.filterIsInstance<SessionEvent.Connected>().map { it.peerID } }

    @Test
    fun aPairedMacGetsHelloFirstAndAnAdmittedSession() {
        Mac(macA).use { mac ->
            val hello = mac.read()!!
            assertEquals("hello", hello["type"]!!.jsonPrimitive.content)
            assertEquals(RECEIVER_ID, hello["id"]!!.jsonPrimitive.content)
            assertEquals("TLSv1.3", mac.socket.session.protocol)
            mac.send("{\"type\":\"welcome\",\"pv\":22,\"min\":1}")
            mac.send("{\"type\":\"sessionInvite\",\"id\":\"s1\",\"initiator\":\"sender\",\"intent\":\"automatic\",\"mode\":\"extend\",\"awaitingSender\":false}")
            mac.expect("kf")
            assertEquals("accepted", mac.expect("sessionInviteResponse")["result"]!!.jsonPrimitive.content)
            assertEquals(MAC_A, session.peerID)
            assertTrue(session.isAdmitted)
        }
    }

    @Test
    fun anUnpairedMacNeverReachesTheSession() {
        val stranger = TestIdentity("stranger")
        assertTrue(runCatching { Mac(stranger).use { it.read() } }.isFailure)
        Thread.sleep(100)
        assertEquals(emptyList<String>(), connectedPeers())
    }

    @Test
    fun plaintextIsRefusedWithoutFallback() {
        Socket(InetAddress.getLoopbackAddress(), listener.localPort).use { raw ->
            raw.soTimeout = 5_000
            val hello = "{\"type\":\"welcome\",\"pv\":22}".toByteArray()
            raw.getOutputStream().write(uint32BE(hello.size.toLong()) + hello)
            val reply = runCatching { raw.getInputStream().readBytes() }.getOrDefault(ByteArray(0))
            assertFalse("nothing in the clear", String(reply).contains("hello"))
        }
        assertEquals(emptyList<String>(), connectedPeers())
    }

    @Test
    fun tls12IsRefused() {
        assertTrue(runCatching { Mac(macA, protocols = arrayOf("TLSv1.2")).use { it.read() } }.isFailure)
        assertEquals(emptyList<String>(), connectedPeers())
    }

    @Test
    fun aForgottenMacIsRefusedAndRevokingEndsItsLiveSession() {
        Mac(macA).use { mac ->
            mac.admit()
            pins.remove(MAC_A)
            session.revoke(MAC_A, blocked = false)
            assertTrue(mac.closedByReceiver())
        }
        assertTrue(runCatching { Mac(macA).use { it.read() } }.isFailure)
        assertEquals(listOf(MAC_A), connectedPeers())
    }

    @Test
    fun aKeyHeldByTwoPairedMacsIdentifiesNeither() {
        pins[MAC_B] = macA.spki
        Mac(macA).use { assertTrue(it.closedByReceiver()) }
        assertEquals(emptyList<String>(), connectedPeers())
    }

    @Test
    fun aPairedMacCannotTakeOverAnotherMacsSession() {
        policies.automaticallyAllow = false
        policies.setPolicy(MAC_A, com.raisecaterror.meowdisplay.core.session.PeerSessionPolicy.AlwaysAllow)
        Mac(macA).use { it.admit("shared") }
        Mac(macB).use { mac ->
            mac.expect("hello")
            // Mac B claims Mac A's identity and replays its invitation.
            mac.send("{\"type\":\"welcome\",\"pv\":22,\"min\":1,\"id\":\"$MAC_A\"}")
            mac.send("{\"type\":\"sessionInvite\",\"id\":\"shared\",\"initiator\":\"sender\",\"intent\":\"automatic\",\"mode\":\"extend\",\"awaitingSender\":false}")
            assertEquals("declined", mac.expect("sessionInviteResponse")["result"]!!.jsonPrimitive.content)
            assertEquals(MAC_B, session.peerID)
            assertFalse(session.isAdmitted)
        }
    }

    @Test
    fun aBlockedMacIsClosedWithoutDisturbingTheLiveSession() {
        Mac(macA).use { a ->
            a.admit()
            policies.setPolicy(MAC_B, com.raisecaterror.meowdisplay.core.session.PeerSessionPolicy.Blocked)
            Mac(macB).use { b -> assertTrue(b.closedByReceiver()) }
            assertEquals(MAC_A, session.peerID)
            assertTrue(session.isAdmitted)
            a.send("{\"type\":\"ping\"}")
            a.send("{\"type\":\"pong\",\"t\":${System.currentTimeMillis()},\"mt\":1}")
            eventually("still served") { session.rttMs != null }
        }
    }

    @Test
    fun sendsNeverBlockTheCallerAndKeepTheirOrder() {
        Mac(macA).use { mac ->
            mac.admit()
            // The Mac reads nothing while 500 messages are sent: the caller must not wait on the socket.
            val started = System.nanoTime()
            repeat(500) { session.sendStats(mapOf("n" to it)) }
            assertTrue("sending blocked the caller", System.nanoTime() - started < 1_000_000_000L)
            repeat(500) { assertEquals(it, mac.expect("stats")["n"]!!.jsonPrimitive.content.toInt()) }
        }
    }

    @Test
    fun aDisconnectStillDeliversClosingBeforeTheSocketCloses() {
        Mac(macA).use { mac ->
            mac.admit()
            session.disconnect()
            mac.expect("closing")
            assertTrue(mac.closedByReceiver())
        }
    }

    /** Audit C6: stopping the listener (the app going to the background) still says goodbye. */
    @Test
    fun closingTheListenerStillDeliversSleepingBeforeTheSocketCloses() {
        Mac(macA).use { mac ->
            mac.admit()
            listener.close(sleeping = true)
            mac.expect("sleeping")
            assertTrue(mac.closedByReceiver())
        }
    }

    @Test
    fun aNewConnectionReplacesTheOldOne() {
        Mac(macA).use { first ->
            first.admit()
            Mac(macA).use { second ->
                second.expect("hello")
                assertTrue(first.closedByReceiver())
                assertFalse("the replacement starts unadmitted", session.isAdmitted)
            }
        }
    }

    @Test
    fun malformedControlIsIgnoredButOversizedOrEmptyFramesEndTheConnection() {
        Mac(macA).use { mac ->
            mac.admit()
            mac.send("{not json")
            mac.send("{\"type\":\"pong\",\"t\":\"x\"}")
            mac.sendRaw(uint32BE(3) + byteArrayOf(0x7B, 0, 0x7D))
            mac.send("{\"type\":\"sessionInvite\",\"id\":\"s2\",\"initiator\":\"sender\",\"intent\":\"automatic\",\"mode\":\"extend\",\"awaitingSender\":false}")
            assertEquals("still served", "accepted", mac.expect("sessionInviteResponse")["result"]!!.jsonPrimitive.content)
            mac.sendRaw(uint32BE(WireFraming.MAX_INCOMING_BYTES + 1L))
            assertTrue(mac.closedByReceiver())
        }
        eventually("disconnect") { session.peerID == null }
        Mac(macA).use { mac ->
            mac.expect("hello")
            mac.sendRaw(uint32BE(0))
            assertTrue(mac.closedByReceiver())
        }
    }

    @Test
    fun aFrameCutShortEndsOnlyThatConnection() {
        Mac(macA).use { mac ->
            mac.admit()
            mac.sendRaw(uint32BE(1000) + ByteArray(10))
        }
        eventually("transport loss") {
            synchronized(events) { events.any { it is SessionEvent.Disconnected && it.reason == SessionLossReason.TransportLost } }
        }
        Mac(macA).use { it.admit("session-2") }
    }

    @Test
    fun aSilentMacIsDroppedByTheWatchdog() {
        Mac(macA).use { mac ->
            mac.admit()
            skew.set(6_000)
            assertTrue(mac.closedByReceiver())
        }
        assertNull(session.peerID)
    }

    @Test
    fun stalledHandshakesAreBoundedAndTimedOut() {
        val idle = (1..2).map { Socket(InetAddress.getLoopbackAddress(), listener.localPort).apply { soTimeout = 5_000 } }
        Thread.sleep(100)
        Socket(InetAddress.getLoopbackAddress(), listener.localPort).use { over ->
            over.soTimeout = 5_000
            assertTrue("over the bound: closed at once", endsWithoutTls(over))
        }
        idle.forEach { socket -> socket.use { assertTrue("handshake deadline", endsWithoutTls(it)) } }
        // The listener frees a slot just after it closes the socket, on its worker thread.
        eventually("the stalled handshakes' slots are free") { listener.pendingHandshakes == 0 }
        Mac(macA).use { it.admit() }
    }

    /** Audit F-3: one address can't hold every handshake slot. */
    @Test
    fun oneHostCannotTakeEveryHandshakeSlot() {
        val wide = MediaListener(
            PinnedTls.context(receiver.keyManager) { pins.values.toList() }, { pins.toMap() }, session,
            port = 0, handshakeTimeoutMs = 5_000, maxPendingHandshakes = 4, maxPendingPerHost = 2,
        ).apply { start() }
        try {
            val one = InetAddress.getByName("127.0.0.1")
            val other = InetAddress.getByName("127.0.0.2")
            fun from(local: InetAddress) = Socket(InetAddress.getLoopbackAddress(), wide.localPort, local, 0)
            val held = (1..2).map { from(one) }
            eventually("both held") { wide.pendingHandshakes == 2 }
            from(one).use { third ->
                third.soTimeout = 5_000
                assertTrue("a third from the same address is closed at once", endsWithoutTls(third))
            }
            from(other).use { elsewhere ->
                eventually("another address still gets a slot") { wide.pendingHandshakes == 3 }
            }
            held.forEach { it.close() }
        } finally {
            wide.close()
        }
    }

    private companion object {
        const val RECEIVER_ID = "11111111-2222-3333-4444-555555555555"
        const val MAC_A = "AAAAAAAA-0000-0000-0000-000000000001"
        const val MAC_B = "BBBBBBBB-0000-0000-0000-000000000002"
    }
}
