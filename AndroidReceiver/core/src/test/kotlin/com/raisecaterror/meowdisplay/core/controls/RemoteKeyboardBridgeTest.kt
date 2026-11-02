package com.raisecaterror.meowdisplay.core.controls

import com.raisecaterror.meowdisplay.core.session.HelloFields
import com.raisecaterror.meowdisplay.core.session.InMemorySessionPolicyStore
import com.raisecaterror.meowdisplay.core.session.MediaLink
import com.raisecaterror.meowdisplay.core.session.ReceiverSession
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Software and hardware typing reach the Mac exactly as the iOS receiver sends them. */
class RemoteKeyboardBridgeTest {
    private val sent = mutableListOf<String>()
    private val link = object : MediaLink {
        override val peerID = "mac-a"
        override fun send(payload: ByteArray): Boolean {
            val message = Json.parseToJsonElement(String(payload)).jsonObject
            if (message["type"]!!.jsonPrimitive.content == "keyboard") sent += message.toString()
            return true
        }
        override fun close() {}
    }
    private val session = ReceiverSession(InMemorySessionPolicyStore(), { mapOf("mac-a" to byteArrayOf(1)) }, { HelloFields(1, 1, 1.0, "r") }, {})
    private var chord = emptySet<ControlModifier>()
    private val keyboard = RemoteKeyboardBridge(session.input) { chord }

    @Before
    fun grant() {
        session.adopt(link)
        listOf(
            """{"type":"welcome","pv":22,"min":1}""",
            """{"type":"sessionInvite","id":"s","initiator":"sender","intent":"automatic","mode":"extend","awaitingSender":false}""",
            """{"type":"allowInputState","allowed":true,"state":"allowed"}""",
        ).forEach { session.onFrame(link, it.toByteArray()) }
    }

    @Test
    fun plainTextIsTextAndNewlineIsReturn() {
        keyboard.commitText("héllo 👩‍👩‍👧")
        keyboard.commitText("\n")
        keyboard.backspace(2)
        assertEquals(
            listOf(
                """{"type":"keyboard","action":"text","text":"héllo 👩‍👩‍👧"}""",
                """{"type":"keyboard","action":"press","usage":40,"modifiers":[]}""",
                """{"type":"keyboard","action":"press","usage":42,"modifiers":[]}""",
                """{"type":"keyboard","action":"press","usage":42,"modifiers":[]}""",
            ),
            sent,
        )
    }

    @Test
    fun aLatchedChordTurnsKeysIntoShortcutsAndKeepsTheRestAsText() {
        chord = setOf(ControlModifier.Command)
        keyboard.commitText("cé")
        keyboard.commitText("S")
        keyboard.returnKey()
        assertEquals(
            listOf(
                """{"type":"keyboard","action":"press","usage":6,"modifiers":["command"]}""",
                """{"type":"keyboard","action":"text","text":"é"}""",
                """{"type":"keyboard","action":"press","usage":22,"modifiers":["command","shift"]}""",
                """{"type":"keyboard","action":"press","usage":40,"modifiers":["command"]}""",
            ),
            sent,
        )
    }

    @Test
    fun onlyNavigationKeysAreHeldAndOneDownPerPressIsSent() {
        assertFalse("letters are typed, not held", keyboard.keyDown(4, emptyList()))
        assertTrue(keyboard.keyDown(RemoteKeyboardBridge.LEFT, listOf("shift")))
        assertTrue(keyboard.keyDown(RemoteKeyboardBridge.LEFT, listOf("shift")))
        assertTrue(keyboard.keyUp(RemoteKeyboardBridge.LEFT, listOf("shift")))
        assertEquals(
            listOf(
                """{"type":"keyboard","action":"down","usage":80,"modifiers":["shift"]}""",
                """{"type":"keyboard","action":"up","usage":80,"modifiers":["shift"]}""",
            ),
            sent,
        )
    }

    @Test
    fun losingFocusReleasesEveryHeldKey() {
        keyboard.keyDown(RemoteKeyboardBridge.UP, emptyList())
        keyboard.keyDown(RemoteKeyboardBridge.ESCAPE, emptyList())
        assertTrue(keyboard.holdsKeys)
        keyboard.releaseHeldKeys()
        assertFalse(keyboard.holdsKeys)
        assertFalse(session.input.holdsInput)
        assertEquals(
            listOf(
                """{"type":"keyboard","action":"up","usage":82,"modifiers":[]}""",
                """{"type":"keyboard","action":"up","usage":41,"modifiers":[]}""",
            ),
            sent.takeLast(2),
        )
    }

    @Test
    fun graphemesFollowSwiftCharacters() {
        assertEquals(listOf("a", "👩‍👩‍👧", "🇫🇷", "é"), RemoteKeyboardBridge.graphemes("a👩‍👩‍👧🇫🇷é").let { it.take(3) + it.drop(3).map { s -> java.text.Normalizer.normalize(s, java.text.Normalizer.Form.NFC) } })
        assertEquals("👍🏽!", "👍🏽!x".prefixCharacters(2))
    }

    // MARK: - The typing strip's echo

    @Test
    fun theStripMirrorsWhatWasSentIncludingDeletesAndTheComposingWord() {
        keyboard.commitText("teh")
        keyboard.setComposing("wor")
        assertEquals("tehwor", keyboard.echo.text)
        keyboard.backspace(3)
        assertEquals("", keyboard.echo.committed)
        assertEquals("the composing word is the keyboard's, not the Mac's", "wor", keyboard.echo.composing)
        keyboard.commitText("the ")
        assertEquals("the ", keyboard.echo.text)
        keyboard.commitText("\n")
        assertTrue("Return starts a fresh line", keyboard.echo.isEmpty)
    }

    @Test
    fun theStripClearsWhenTheCaretMovesOrAShortcutRuns() {
        keyboard.commitText("hello")
        keyboard.keyDown(RemoteKeyboardBridge.LEFT, emptyList())
        assertTrue(keyboard.echo.isEmpty)
        keyboard.commitText("again")
        keyboard.shortcut(6, listOf("command"))
        assertTrue(keyboard.echo.isEmpty)
        keyboard.commitText("x")
        chord = setOf(ControlModifier.Command)
        keyboard.backspace()
        assertTrue("a modified Backspace deletes more than a character", keyboard.echo.isEmpty)
        keyboard.commitText("c")
        assertTrue("a chorded key is a shortcut, not text", keyboard.echo.isEmpty)
    }

    @Test
    fun trayKeysFollowTheStripToo() {
        keyboard.commitText("ab")
        keyboard.press(RemoteKeyboardBridge.BACKSPACE)
        assertEquals("a", keyboard.echo.text)
        keyboard.press(RemoteKeyboardBridge.ESCAPE)
        assertTrue(keyboard.echo.isEmpty)
    }

    @Test
    fun textThatWasNotSentIsNotEchoed() {
        session.onFrame(link, """{"type":"allowInputState","allowed":false,"state":"off"}""".toByteArray())
        keyboard.commitText("secret")
        assertTrue("input is off: nothing left the phone, so nothing is echoed", keyboard.echo.isEmpty)
        assertTrue(sent.isEmpty())
    }

    @Test
    fun theListenerHearsEachChangeAndOnlyChanges() {
        val heard = mutableListOf<String>()
        keyboard.onEchoChanged = { heard += it.text }
        keyboard.commitText("a")
        keyboard.setComposing("b")
        keyboard.setComposing("b")
        keyboard.resetEcho()
        keyboard.resetEcho()
        assertEquals(listOf("a", "ab", ""), heard)
    }
}
