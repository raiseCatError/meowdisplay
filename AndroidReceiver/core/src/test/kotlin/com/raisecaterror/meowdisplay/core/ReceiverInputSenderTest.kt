package com.raisecaterror.meowdisplay.core

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
import org.junit.Test

/**
 * Remote input leaves only under the Mac's grant on the current admitted
 * connection, in the iOS receiver's JSON shapes, and nothing this device put
 * down outlives a grant, a pause or a connection.
 */
class ReceiverInputSenderTest {
    private class FakeLink(override val peerID: String) : MediaLink {
        val sent = mutableListOf<JsonObject>()
        var closed = false

        override fun send(payload: ByteArray): Boolean {
            if (closed) return false
            sent += Json.parseToJsonElement(String(payload)).jsonObject
            return true
        }

        override fun close() {
            closed = true
        }

        fun inputSent(): List<String> = sent.filter { it.type() in INPUT_TYPES }.map { it.toString() }
    }

    private var clock = 1_000_000L
    private val pins = mutableMapOf(MAC_A to byteArrayOf(1))
    private val session = ReceiverSession(InMemorySessionPolicyStore(), { pins.toMap() }, { HelloFields(1080, 2400, 3.0, "receiver-id") }, {}, { clock })
    private val input get() = session.input

    private fun ReceiverSession.say(link: MediaLink, json: String) = onFrame(link, json.toByteArray())

    private fun admitted(pv: Int = 22): FakeLink = FakeLink(MAC_A).also {
        session.adopt(it)
        session.say(it, """{"type":"welcome","pv":$pv,"min":1}""")
        session.say(it, """{"type":"sessionInvite","id":"s1","initiator":"sender","intent":"automatic","mode":"extend","awaitingSender":false}""")
    }

    private fun grant(link: FakeLink) = session.say(link, """{"type":"allowInputState","allowed":true,"state":"allowed"}""")

    @Test
    fun nothingLeavesOrIsRememberedWithoutTheMacsGrant() {
        val link = admitted()
        assertTrue(session.isAdmitted)
        assertFalse(input.pointerDown("left", 1))
        assertFalse(input.keyboardDown(4, emptyList()))
        assertFalse(input.modifier("command", true))
        assertFalse(input.touch("began", 0.5, 0.5))
        assertFalse(input.keyboardText("hi"))
        assertFalse(input.holdsInput)
        assertEquals(emptyList<String>(), link.inputSent())
        // A Mac that asks for nothing still can't receive anything after a refused request.
        session.say(link, """{"type":"allowInputState","allowed":false,"state":"notAllowed"}""")
        assertFalse(input.scroll(0.0, 5.0))
        assertEquals(emptyList<String>(), link.inputSent())
    }

    @Test
    fun aMacThatPredatesTheGrantNeverReceivesInput() {
        val link = admitted(pv = 7)
        grant(link)
        assertFalse(input.touch("began", 0.5, 0.5))
        assertFalse(input.keyboardPress(40))
        assertEquals(emptyList<String>(), link.inputSent())
    }

    @Test
    fun messagesUseTheIOSShapesAndVersionGates() {
        val link = admitted(pv = 19)
        grant(link)
        assertTrue(input.keyboardPress(40))
        assertTrue(input.keyboardDown(80, listOf("shift")))
        assertTrue(input.keyboardDown(80, listOf("shift"), isRepeat = true))
        assertTrue(input.keyboardUp(80, listOf("shift")))
        assertTrue(input.pointerDown("right", 2))
        assertTrue(input.pointerUp("right", 2))
        assertTrue(input.pointerMoveRelative(4.0, -2.0))
        assertTrue(input.modifier("option", true))
        assertTrue(input.nativeAppGesture("magnify", "began", 0.0))
        assertTrue(input.keyboardText("é"))
        assertEquals(
            listOf(
                """{"type":"keyboard","action":"press","usage":40,"modifiers":[]}""",
                """{"type":"keyboard","action":"down","usage":80,"modifiers":["shift"]}""",
                """{"type":"keyboard","action":"down","usage":80,"modifiers":["shift"],"repeat":true}""",
                """{"type":"keyboard","action":"up","usage":80,"modifiers":["shift"]}""",
                """{"type":"pointer","action":"down","button":"right","clickCount":2}""",
                """{"type":"pointer","action":"up","button":"right","clickCount":2}""",
                """{"type":"pointer","action":"moveRelative","dx":4.0,"dy":-2.0}""",
                """{"type":"keyboard","action":"modifierDown","modifier":"option"}""",
                """{"type":"nativeAppGesture","kind":"magnify","phase":"began","delta":0.0}""",
                """{"type":"keyboard","action":"text","text":"é"}""",
            ),
            link.inputSent(),
        )
        // Smart Touch needs pv 20; unknown buttons, phases and unmatched lifecycles never leave.
        assertFalse(input.smartTouchProbe(1, 0.5, 0.5))
        assertFalse(input.pointerDown("middle", 1))
        assertFalse(input.touch("hover", 0.1, 0.1))
        assertFalse(input.nativeAppGesture("rotate", "changed", 0.1))
        assertFalse("a repeat follows only a key that went down", input.keyboardDown(4, emptyList(), isRepeat = true))
        assertFalse(input.modifier("fn", true))
    }

    @Test
    fun touchAndPencilCarryTheSendersClockOnceKnown() {
        val link = admitted()
        grant(link)
        input.touch("began", 0.25, 0.75)
        assertFalse("no t before a clock offset", link.sent.last().containsKey("t"))
        session.say(link, """{"type":"pong","t":${clock - 10},"mt":${clock + 495}}""")
        input.touch("moved", 0.3, 0.75)
        assertEquals((clock + 500).toDouble(), link.sent.last()["t"]!!.jsonPrimitive.content.toDouble(), 0.001)
        input.pencil("down", 0.5, 0.5, 0.4, 1.0, 1.2)
        assertEquals("pencil", link.sent.last().type())
        assertTrue(link.sent.last().containsKey("t"))
    }

    @Test
    fun releaseAllLetsGoOfEverythingThenCancels() {
        val link = admitted()
        grant(link)
        input.nativeAppGesture("rotate", "began", 0.0)
        input.pointerDown("left", 1)
        input.keyboardDown(4, listOf("command"))
        input.keyboardDown(5, emptyList())
        input.modifier("shift", true)
        input.modifier("command", true)
        input.touch("began", 0.5, 0.5)
        assertTrue(input.holdsInput)
        val before = link.inputSent().size
        val report = input.releaseAll()
        assertTrue(report.cancelSent)
        assertEquals(
            listOf(
                """{"type":"nativeAppGesture","kind":"rotate","phase":"cancelled","delta":0}""",
                """{"type":"pointer","action":"up","button":"left","clickCount":1}""",
                """{"type":"keyboard","action":"up","usage":5,"modifiers":[]}""",
                """{"type":"keyboard","action":"up","usage":4,"modifiers":["command"]}""",
                """{"type":"keyboard","action":"modifierUp","modifier":"command"}""",
                """{"type":"keyboard","action":"modifierUp","modifier":"shift"}""",
                """{"type":"touch","phase":"cancelled","x":0.5,"y":0.5}""",
                """{"type":"keyboard","action":"cancel"}""",
            ),
            link.inputSent().drop(before),
        )
        assertFalse(input.holdsInput)
        // Idempotent: a second pass has nothing to release, only the safety net.
        assertEquals(emptyList<String>(), input.releaseAll().released)
    }

    @Test
    fun revocationForgetsHeldInputWithoutSendingAndRefusesMore() {
        val link = admitted()
        grant(link)
        input.keyboardDown(4, emptyList())
        input.modifier("control", true)
        input.pointerDown("left", 1)
        val before = link.inputSent().size
        session.say(link, """{"type":"allowInputState","allowed":false,"state":"off"}""")
        assertFalse(input.holdsInput)
        assertEquals("the Mac released on revocation; nothing more is sent", before, link.inputSent().size)
        assertFalse(input.keyboardUp(4, emptyList()))
        assertFalse(input.pointerMove(0.1, 0.1))
    }

    @Test
    fun aPauseReleasesHeldInputWhileTheGateIsStillOpen() {
        val link = admitted()
        grant(link)
        input.pointerDown("left", 1)
        input.modifier("command", true)
        session.say(link, """{"type":"displayState","state":"paused"}""")
        val sent = link.inputSent()
        assertEquals("""{"type":"keyboard","action":"cancel"}""", sent.last())
        assertTrue(sent.contains("""{"type":"pointer","action":"up","button":"left","clickCount":1}"""))
        assertTrue(sent.contains("""{"type":"keyboard","action":"modifierUp","modifier":"command"}"""))
        assertFalse(input.holdsInput)
        assertFalse("no input while paused", input.pointerDown("left", 1))
        session.say(link, """{"type":"displayState","state":"running"}""")
        assertTrue(input.pointerMove(0.5, 0.5))
    }

    @Test
    fun inputResetAndAWithdrawnAdmissionForgetHeldInput() {
        val link = admitted()
        grant(link)
        input.modifier("shift", true)
        session.say(link, """{"type":"inputReset"}""")
        assertFalse(input.holdsInput)
        input.keyboardDown(4, emptyList())
        session.say(link, """{"type":"sessionInviteCancel","id":"s1"}""")
        assertFalse(input.holdsInput)
        assertFalse(input.keyboardDown(4, emptyList()))
    }

    @Test
    fun aReconnectStartsWithNoGrantAndNothingHeld() {
        val first = admitted()
        grant(first)
        input.keyboardDown(4, emptyList())
        input.pointerDown("left", 1)
        session.onClosed(first)
        assertFalse(input.holdsInput)
        val second = admitted()
        assertFalse("the old grant never carries over", input.pointerDown("left", 1))
        assertEquals(emptyList<String>(), second.inputSent())
        grant(second)
        assertTrue(input.pointerDown("left", 1))
        assertEquals(setOf("left"), input.heldButtonNames())
        assertTrue("nothing reached the closed link", first.inputSent().none { it.contains("\"up\"") })
    }

    private companion object {
        const val MAC_A = "mac-a"
        val INPUT_TYPES = setOf("touch", "scroll", "gesture", "pencil", "proximity", "keyboard", "pointer", "nativeAppGesture", "smartTouchProbe")

        fun JsonObject.type() = this["type"]!!.jsonPrimitive.content
    }
}
