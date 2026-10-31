package com.raisecaterror.meowdisplay.core.session

import com.raisecaterror.meowdisplay.core.remote.RemoteEndpointsWire
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Automatic Remote Access in the session (PROTOCOL.md 6.17): when this device reports and what it keeps. */
class ReceiverSessionRemoteEndpointsTest {
    private class FakeLink(override val peerID: String) : MediaLink {
        override val remoteAddress: java.net.InetAddress? = null
        override val localAddress: java.net.InetAddress? = null
        val sent = mutableListOf<JsonObject>()
        override fun send(payload: ByteArray): Boolean {
            sent += Json.parseToJsonElement(String(payload)).jsonObject
            return true
        }
        override fun close() = Unit
        fun reports() = sent.filter { it["type"]!!.jsonPrimitive.content == RemoteEndpointsWire.TYPE }
    }

    private class Host : RemoteEndpointsHost {
        var own = RemoteEndpointsWire.Report(ips = listOf("100.64.0.9"))
        val received = mutableListOf<Pair<String, RemoteEndpointsWire.Report>>()
        override fun ownReport() = own
        override fun received(peerID: String, report: RemoteEndpointsWire.Report) {
            received += peerID to report
        }
    }

    private var clock = 1_000_000L
    private val host = Host()
    private fun session(host: RemoteEndpointsHost?) = ReceiverSession(
        InMemorySessionPolicyStore(), { mapOf(MAC to byteArrayOf(1)) }, { HelloFields(1080, 2400, 3.0, "r") }, {}, { clock }, host,
    )

    private fun ReceiverSession.say(link: MediaLink, json: String) = onFrame(link, json.toByteArray())
    private fun welcome(offered: Boolean) =
        "{\"type\":\"welcome\",\"pv\":22,\"min\":1,\"features\":[${if (offered) "\"remoteEndpoints\"" else ""}]}"
    private val invite = "{\"type\":\"sessionInvite\",\"id\":\"s1\",\"initiator\":\"sender\",\"intent\":\"automatic\",\"mode\":\"extend\",\"awaitingSender\":false}"
    private val macReport = "{\"type\":\"remoteEndpoints\",\"names\":[\"mac.tail1.ts.net\"],\"ips\":[\"100.64.0.1\",\"192.168.1.2\"]}"

    @Test
    fun helloDeclaresItOnlyWithAHost() {
        val link = FakeLink(MAC)
        session(host).adopt(link)
        assertEquals(1, link.sent.first()["remoteEndpoints"]!!.jsonPrimitive.content.toInt())
        val demo = FakeLink(MAC)
        session(null).adopt(demo)
        assertNull("demo and tests never declare it", demo.sent.first()["remoteEndpoints"])
    }

    @Test
    fun theReportGoesOutOnceAdmittedAndOfferedOncePerConnection() {
        val s = session(host)
        val link = FakeLink(MAC)
        s.adopt(link)
        s.say(link, welcome(offered = true))
        assertTrue("nothing before admission", link.reports().isEmpty())
        s.say(link, invite)
        assertEquals(1, link.reports().size)
        assertEquals(listOf("100.64.0.9"), link.reports().single()["ips"]!!.jsonArray.map { it.jsonPrimitive.content })
        s.say(link, welcome(offered = true))
        assertEquals("a re-welcome on the same connection sends nothing", 1, link.reports().size)

        clock += 5_000
        val again = FakeLink(MAC)
        s.adopt(again)
        s.say(again, welcome(offered = true))
        s.say(again, invite)
        assertTrue("within 10 s of the last one: the Mac would drop it", again.reports().isEmpty())
        clock += 10_000
        val later = FakeLink(MAC)
        s.adopt(later)
        s.say(later, welcome(offered = true))
        s.say(later, invite)
        assertEquals(1, later.reports().size)
    }

    @Test
    fun aMacThatDoesNotOfferItHearsNothing() {
        val s = session(host)
        val link = FakeLink(MAC)
        s.adopt(link)
        s.say(link, welcome(offered = false))
        s.say(link, invite)
        assertTrue(link.reports().isEmpty())
    }

    @Test
    fun theMacsReportIsKeptOnlyFromTheAdmittedSessionFilteredAndRateLimited() {
        val s = session(host)
        val link = FakeLink(MAC)
        s.adopt(link)
        s.say(link, welcome(offered = true))
        s.say(link, macReport)
        assertTrue("not before admission", host.received.isEmpty())
        s.say(link, invite)
        s.say(link, macReport)
        assertEquals(listOf(MAC to RemoteEndpointsWire.Report(listOf("mac.tail1.ts.net"), listOf("100.64.0.1"))), host.received)
        clock += 2_000
        s.say(link, macReport)
        assertEquals("one per 10 s", 1, host.received.size)
        clock += 10_000
        s.say(link, "{\"type\":\"remoteEndpoints\",\"ips\":[1]}")
        assertEquals("malformed is dropped whole", 1, host.received.size)
        s.say(link, "{\"type\":\"remoteEndpoints\"}")
        assertEquals("an empty report goes through: the Mac has nothing (or turned it off)", RemoteEndpointsWire.Report(), host.received.last().second)
    }

    private companion object {
        const val MAC = "AAAAAAAA-0000-0000-0000-000000000001"
    }
}
