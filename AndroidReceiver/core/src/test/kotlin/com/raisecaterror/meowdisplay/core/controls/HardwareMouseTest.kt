package com.raisecaterror.meowdisplay.core.controls

import com.raisecaterror.meowdisplay.core.session.HelloFields
import com.raisecaterror.meowdisplay.core.session.InMemorySessionPolicyStore
import com.raisecaterror.meowdisplay.core.session.MediaLink
import com.raisecaterror.meowdisplay.core.session.ReceiverSession
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** HID-A: a physical mouse against a real, granted session. */
class HardwareMouseTest {
    private class FakeLink : MediaLink {
        override val peerID = "mac-a"
        val sent = mutableListOf<JsonObject>()
        override fun send(payload: ByteArray): Boolean { sent += Json.parseToJsonElement(String(payload)).jsonObject; return true }
        override fun close() {}
    }

    private val link = FakeLink()
    private val session = ReceiverSession(InMemorySessionPolicyStore(), { mapOf("mac-a" to byteArrayOf(1)) }, { HelloFields(1080, 2400, 3.0, "r") }, {})
    private val mouse = HardwareMouse(session.input)

    private fun say(json: String) = session.onFrame(link, json.toByteArray())
    private fun pointer() = link.sent.filter { it["type"]!!.jsonPrimitive.content == "pointer" }
        .map { listOfNotNull(it["action"]!!.jsonPrimitive.content, it["button"]?.jsonPrimitive?.content, it["clickCount"]?.jsonPrimitive?.content) }

    @Before
    fun connect() {
        session.adopt(link)
        say("""{"type":"welcome","pv":22,"min":1}""")
        say("""{"type":"sessionInvite","id":"s1","initiator":"sender","intent":"automatic","mode":"extend","awaitingSender":false}""")
        say("""{"type":"allowInputState","allowed":true,"state":"allowed"}""")
        link.sent.clear()
    }

    @Test
    fun hoverMovesClickPressesAndReleasesAtThePointer() {
        mouse.event(CGPoint(0.2, 0.3), 0, 0.0)
        mouse.event(CGPoint(0.25, 0.3), 1, 0.1)
        mouse.event(CGPoint(0.4, 0.5), 1, 0.2)   // drag with the button held
        mouse.event(CGPoint(0.4, 0.5), 0, 0.3)
        assertEquals(listOf(listOf("move"), listOf("move"), listOf("down", "left", "1"), listOf("move"), listOf("up", "left", "1")), pointer())
    }

    @Test
    fun rightClickIsARightClickAndMiddleOrBackAreNeverSent() {
        mouse.event(CGPoint(0.5, 0.5), 2, 0.0)
        mouse.event(CGPoint(0.5, 0.5), 0, 0.05)
        mouse.event(CGPoint(0.5, 0.5), 4, 0.5)
        mouse.event(CGPoint(0.5, 0.5), 8 or 16, 0.6)
        mouse.event(CGPoint(0.5, 0.5), 0, 0.7)
        assertEquals(listOf(listOf("move"), listOf("down", "right", "1"), listOf("up", "right", "1")), pointer())
    }

    @Test
    fun doubleAndTripleClicksCountOnlyWhenQuickAndClose() {
        for ((i, t) in listOf(0.0, 0.2, 0.4).withIndex()) { mouse.event(CGPoint(0.5, 0.5), 1, t); mouse.event(CGPoint(0.5, 0.5), 0, t + 0.05); assertEquals(i + 1, i + 1) }
        val counts = pointer().filter { it[0] == "down" }.map { it[2] }
        assertEquals(listOf("1", "2", "3"), counts)
        link.sent.clear()
        mouse.event(CGPoint(0.5, 0.5), 1, 2.0); mouse.event(CGPoint(0.5, 0.5), 0, 2.05)
        mouse.event(CGPoint(0.6, 0.5), 1, 2.1); mouse.event(CGPoint(0.6, 0.5), 0, 2.15)
        assertEquals("moved away: a new single click", listOf("1", "1"), pointer().filter { it[0] == "down" }.map { it[2] })
    }

    @Test
    fun aDragLeavingThePictureStaysAndReleasesAndPressesOutsideAreIgnored() {
        mouse.event(CGPoint(0.9, 0.5), 1, 0.0)
        assertTrue(mouse.event(null, 1, 0.1))
        mouse.event(null, 0, 0.2)
        assertEquals(listOf(listOf("move"), listOf("down", "left", "1"), listOf("up", "left", "1")), pointer())
        link.sent.clear()
        assertFalse(mouse.event(null, 1, 1.0))
        mouse.event(null, 0, 1.1)
        assertTrue("outside the picture nothing reaches the Mac", pointer().isEmpty())
    }

    @Test
    fun releaseAllLetsGoOfHeldButtonsAndRevocationStopsEverything() {
        mouse.event(CGPoint(0.5, 0.5), 1 or 2, 0.0)
        assertTrue(mouse.holdsButton)
        mouse.releaseAll()
        assertFalse(mouse.holdsButton)
        assertEquals(listOf("up", "up"), pointer().filter { it[0] == "up" }.map { it[0] })
        say("""{"type":"allowInputState","allowed":false,"state":"off"}""")
        link.sent.clear()
        mouse.event(CGPoint(0.2, 0.2), 1, 5.0)
        mouse.event(CGPoint(0.2, 0.2), 0, 5.1)
        assertTrue("View Only: nothing is sent", pointer().isEmpty())
    }
}
