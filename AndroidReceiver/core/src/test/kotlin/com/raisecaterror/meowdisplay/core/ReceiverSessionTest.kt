package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.session.HelloFields
import com.raisecaterror.meowdisplay.core.session.InMemorySessionPolicyStore
import com.raisecaterror.meowdisplay.core.session.MediaLink
import com.raisecaterror.meowdisplay.core.session.PeerSessionPolicy
import com.raisecaterror.meowdisplay.core.session.ReceiverApprovalDecision
import com.raisecaterror.meowdisplay.core.session.ReceiverSession
import com.raisecaterror.meowdisplay.core.session.SessionEvent
import com.raisecaterror.meowdisplay.core.session.SessionLossReason
import com.raisecaterror.meowdisplay.core.session.SessionPhase
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The session state machine against in-memory links: admission, input, identity and liveness rules. */
class ReceiverSessionTest {
    private class FakeLink(
        override val peerID: String,
        override val remoteAddress: java.net.InetAddress? = null,
        override val localAddress: java.net.InetAddress? = null,
    ) : MediaLink {
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

        fun types() = sent.map { it["type"]!!.jsonPrimitive.content }
        fun responses() = sent.filter { it["type"]!!.jsonPrimitive.content == "sessionInviteResponse" }
            .map { it["id"]!!.jsonPrimitive.content to it["result"]!!.jsonPrimitive.content }
    }

    private var clock = 1_000_000L
    private val pins = mutableMapOf(MAC_A to byteArrayOf(1), MAC_B to byteArrayOf(2))
    private val policies = InMemorySessionPolicyStore()
    private val events = mutableListOf<SessionEvent>()
    private var panel = HelloFields(1080, 2400, 3.0, "receiver-id")
    private val session = ReceiverSession(policies, { pins.toMap() }, { panel }, { events += it }, { clock })

    private fun frame(json: String) = json.toByteArray()
    private fun ReceiverSession.say(link: MediaLink, json: String) = onFrame(link, frame(json))
    private fun invite(id: String, intent: String = "automatic", initiator: String = "sender") =
        "{\"type\":\"sessionInvite\",\"id\":\"$id\",\"initiator\":\"$initiator\",\"intent\":\"$intent\",\"mode\":\"extend\",\"awaitingSender\":false}"
    private fun connect(peer: String, pv: Int = 22, remote: String? = null, local: String? = null): FakeLink =
        FakeLink(peer, remote?.let(java.net.InetAddress::getByName), local?.let(java.net.InetAddress::getByName)).also {
        session.adopt(it)
        session.say(it, "{\"type\":\"welcome\",\"pv\":$pv,\"min\":1}")
    }
    private fun keyframe() = START + byteArrayOf(0x67, 1) + START + byteArrayOf(0x68, 2) + START + byteArrayOf(0x65, 3)
    private fun videoEvents() = events.count { it is SessionEvent.Video }
    private val tap = buildJsonObject { put("type", "touch"); put("phase", "began"); put("x", 0.5); put("y", 0.5) }

    @Test
    fun helloIsTheFirstMessageOnEveryConnection() {
        val link = FakeLink(MAC_A)
        session.adopt(link)
        assertEquals("hello", link.types().first())
        assertEquals("receiver-id", link.sent.first()["id"]!!.jsonPrimitive.content)
    }

    @Test
    fun onlyAChangedPanelIsReannouncedAndEveryConnectionAnnouncesIt() {
        val link = connect(MAC_A)
        session.resendHello()
        assertEquals("an unchanged panel (a resized window) sends nothing", 1, link.types().count { it == "hello" })
        panel = HelloFields(2400, 1080, 3.0, "receiver-id")
        session.resendHello()
        assertEquals(2, link.types().count { it == "hello" })
        assertEquals(2400, link.sent.last { it["type"]!!.jsonPrimitive.content == "hello" }["pixelsWide"]!!.jsonPrimitive.content.toInt())
        val next = connect(MAC_A)
        assertEquals("a new connection always hears the panel", "hello", next.types().first())
    }

    @Test
    fun mediaIsDroppedUntilAdmittedThenAKeyframeIsRequested() {
        val link = connect(MAC_A)
        session.onFrame(link, keyframe())
        session.onFrame(link, byteArrayOf(0x01, 0x02) + ByteArray(20))
        assertEquals(0, videoEvents())
        assertFalse(session.isAdmitted)
        session.say(link, invite("s1"))
        assertEquals(listOf("s1" to "accepted"), link.responses())
        assertTrue(session.isAdmitted)
        assertEquals("a keyframe request, then the answer", listOf("kf", "sessionInviteResponse"), link.types().takeLast(2))
        session.onFrame(link, keyframe())
        assertEquals(1, videoEvents())
    }

    @Test
    fun inputStartsOffAndOnlyTheGrantOnThisAdmittedConnectionTurnsItOn() {
        val link = connect(MAC_A)
        assertFalse(session.sendInput(tap))
        session.say(link, "{\"type\":\"allowInputState\",\"allowed\":true,\"state\":\"allowed\"}")
        assertFalse("a grant before admission is not a grant", session.inputAllowed)
        session.say(link, invite("s1"))
        assertFalse("admission is not input approval", session.inputAllowed)
        session.say(link, "{\"type\":\"allowInputState\",\"allowed\":true,\"state\":\"requesting\"}")
        assertFalse("inconsistent state is not a grant", session.inputAllowed)
        session.say(link, "{\"type\":\"allowInputState\",\"allowed\":true,\"state\":\"allowed\"}")
        assertTrue(session.sendInput(tap))
        session.say(link, "{\"type\":\"displayState\",\"state\":\"paused\"}")
        assertFalse("no input while paused", session.sendInput(tap))
        session.say(link, "{\"type\":\"displayState\",\"state\":\"running\"}")
        assertTrue(session.sendInput(tap))
        session.say(link, "{\"type\":\"allowInputState\",\"allowed\":false,\"state\":\"off\"}")
        assertFalse(session.sendInput(tap))
    }

    @Test
    fun aGrantNeverSurvivesReconnectionOrAnotherMac() {
        val first = connect(MAC_A)
        session.say(first, invite("s1"))
        session.say(first, "{\"type\":\"allowInputState\",\"allowed\":true}")
        assertTrue(session.inputAllowed)
        val again = connect(MAC_A)
        assertTrue("the old connection is replaced", first.closed)
        session.say(again, invite("s1"))
        assertTrue("same session continues without a prompt", session.isAdmitted)
        assertFalse("but input is off until granted on this connection", session.inputAllowed)
        session.say(first, "{\"type\":\"allowInputState\",\"allowed\":true}")
        assertFalse("a grant read off an earlier connection never applies", session.inputAllowed)
        session.onClosed(again)
        assertFalse(session.inputAllowed)
        assertFalse(session.isAdmitted)
    }

    @Test
    fun anotherPairedMacCannotReuseAnAcceptedInvitation() {
        policies.automaticallyAllow = false
        policies.setPolicy(MAC_A, PeerSessionPolicy.AlwaysAllow)
        val a = connect(MAC_A)
        session.say(a, invite("shared-id"))
        assertTrue(session.isAdmitted)
        // Mac B presents A's invitation id: judged afresh by B's own policy.
        val b = connect(MAC_B)
        session.say(b, invite("shared-id"))
        assertEquals(listOf("shared-id" to "declined"), b.responses())
        assertTrue(b.closed)
        session.onFrame(b, keyframe())
        assertEquals(0, videoEvents())
        // ...and A, which it would have replaced, never noticed.
        assertFalse(a.closed)
        assertEquals(MAC_A, session.peerID)
        assertTrue(session.isAdmitted)
    }

    // MARK: Make-before-break (F2): another Mac waits until its own invitation is accepted

    private fun streamingA(): FakeLink {
        policies.automaticallyAllow = false
        policies.setPolicy(MAC_A, PeerSessionPolicy.AlwaysAllow)
        return connect(MAC_A).also { session.say(it, invite("a1")); assertTrue(session.isAdmitted) }
    }

    /** The decoder asks for a keyframe on every refused P-frame: the Mac hears it once a second. */
    @Test
    fun decoderKeyframeRequestsAreThrottled() {
        val link = streamingA()
        assertFalse("admission's own request counts toward the interval", session.requestKeyframeThrottled())
        clock += ReceiverSession.KEYFRAME_REQUEST_INTERVAL_MS
        val before = link.types().count { it == "kf" }
        repeat(30) { session.requestKeyframeThrottled() }
        assertEquals(before + 1, link.types().count { it == "kf" })
        clock += ReceiverSession.KEYFRAME_REQUEST_INTERVAL_MS
        session.requestKeyframeThrottled()
        assertEquals(before + 2, link.types().count { it == "kf" })
    }

    @Test
    fun anotherMacWaitsGreetedUntilTheUserLetsItIn() {
        val a = streamingA()
        val b = connect(MAC_B)
        assertEquals("greeted while it waits", "hello", b.types().first())
        session.say(b, invite("b1", intent = "manual"))
        assertEquals(listOf("b1" to "pending"), b.responses())
        assertTrue(events.any { it is SessionEvent.ApprovalRequested })
        // A keeps streaming while the prompt is up; B's media goes nowhere.
        session.onFrame(b, keyframe())
        assertEquals(0, videoEvents())
        session.onFrame(a, keyframe())
        assertEquals(1, videoEvents())
        assertFalse(a.closed)
        assertEquals(MAC_A, session.peerID)
        session.answerInvitation("b1", ReceiverApprovalDecision.Allow)
        assertTrue("only an accepted invitation ends the session it replaces", a.closed)
        assertEquals(MAC_B, session.peerID)
        assertTrue(session.isAdmitted)
        assertEquals("b1" to "accepted", b.responses().last())
        assertEquals("not greeted twice", 1, b.types().count { it == "hello" })
    }

    @Test
    fun aDeclinedSilentOrUnansweredMacNeverInterruptsTheSession() {
        val a = streamingA()
        fun stillStreaming() {
            assertFalse(a.closed)
            assertEquals(MAC_A, session.peerID)
            assertTrue(session.isAdmitted)
        }
        val declined = connect(MAC_B)
        session.say(declined, invite("b1", intent = "manual"))
        session.answerInvitation("b1", ReceiverApprovalDecision.RejectForSession)
        assertEquals("b1" to "declined", declined.responses().last())
        assertTrue(declined.closed)
        stillStreaming()

        val withdrawn = connect(MAC_B)
        session.say(withdrawn, invite("b2", intent = "manual"))
        session.say(withdrawn, "{\"type\":\"sessionInviteCancel\",\"id\":\"b2\"}")
        assertTrue(withdrawn.closed)
        assertTrue(events.last() is SessionEvent.ApprovalDismissed)
        stillStreaming()

        val silent = FakeLink(MAC_B).also { session.adopt(it) }
        clock += 6_000
        session.say(a, "{\"type\":\"ping\"}")
        session.tick()
        assertTrue("a waiting Mac that says nothing is dropped", silent.closed)
        stillStreaming()

        val unanswered = connect(MAC_B)
        session.say(unanswered, invite("b3", intent = "manual"))
        repeat(31) {
            clock += 2_000
            session.say(a, "{\"type\":\"ping\"}")
            session.say(unanswered, "{\"type\":\"ping\"}")
            session.tick()
        }
        assertTrue("pinged while it waits", unanswered.types().count { it == "ping" } >= 25)
        assertEquals("b3" to "declined", unanswered.responses().last())
        assertTrue(unanswered.closed)
        stillStreaming()
    }

    @Test
    fun anAllowedMacReplacesTheSessionAtOnceAndTheSameMacAlwaysDoes() {
        val a = streamingA()
        policies.setPolicy(MAC_B, PeerSessionPolicy.AlwaysAllow)
        val b = connect(MAC_B)
        session.say(b, invite("b1"))
        assertTrue(a.closed)
        assertEquals(MAC_B, session.peerID)
        assertEquals(listOf("b1" to "accepted"), b.responses())
        // A reconnect from the same Mac is never held back.
        val again = connect(MAC_B)
        assertTrue(b.closed)
        assertEquals(MAC_B, session.peerID)
        session.say(again, invite("b1"))
        assertTrue(session.isAdmitted)
    }

    @Test
    fun whenTheSessionEndsFirstTheWaitingMacIsJudgedAsANewConnection() {
        val a = streamingA()
        val b = connect(MAC_B)
        session.say(b, invite("b1", intent = "manual"))
        session.onClosed(a)
        assertEquals(MAC_B, session.peerID)
        assertFalse(session.isAdmitted)
        assertTrue("its prompt comes back", events.last() is SessionEvent.ApprovalRequested)
        session.answerInvitation("b1", ReceiverApprovalDecision.Allow)
        assertTrue(session.isAdmitted)
        assertEquals(MAC_B, session.peerID)
    }

    @Test
    fun forgettingOrBlockingTheWaitingMacClosesOnlyIt() {
        val a = streamingA()
        val b = connect(MAC_B)
        session.say(b, invite("b1", intent = "manual"))
        session.revoke(MAC_B, blocked = true)
        assertEquals("b1" to "blocked", b.responses().last())
        assertTrue(b.closed)
        assertFalse(a.closed)
        assertTrue(session.isAdmitted)
    }

    @Test
    fun theMacsIdentityComesFromItsCertificateNotFromWhatItSays() {
        policies.automaticallyAllow = false
        policies.setPolicy(MAC_A, PeerSessionPolicy.AlwaysAllow)
        val b = connect(MAC_B)
        // In-band claims of another identity change nothing.
        session.say(b, "{\"type\":\"welcome\",\"pv\":22,\"min\":1,\"id\":\"$MAC_A\",\"peer\":\"$MAC_A\"}")
        session.say(b, invite("s1"))
        assertEquals(MAC_B, session.peerID)
        assertEquals(listOf("s1" to "declined"), b.responses())
        assertFalse(session.isAdmitted)
    }

    @Test
    fun aBlockedMacCannotDisturbTheLiveSession() {
        val a = connect(MAC_A)
        session.say(a, invite("s1"))
        policies.setPolicy(MAC_B, PeerSessionPolicy.Blocked)
        val b = FakeLink(MAC_B)
        assertFalse(session.adopt(b))
        assertTrue(b.closed)
        assertTrue("never even greeted", b.sent.isEmpty())
        assertFalse(a.closed)
        assertEquals(MAC_A, session.peerID)
        assertTrue(session.isAdmitted)
    }

    @Test
    fun anUnadmittedMacDrivesNoUiButItsStateArrivesAtAdmission() {
        policies.automaticallyAllow = false
        val a = connect(MAC_A)
        session.say(a, invite("s1", intent = "manual"))
        events.clear()
        session.say(a, "{\"type\":\"streamCodecState\",\"codec\":\"hevc\",\"reason\":\"x\"}")
        session.say(a, "{\"type\":\"videoState\",\"enabled\":true,\"width\":99999,\"height\":1080}")
        session.say(a, "{\"type\":\"cursor\",\"x\":0.5,\"y\":0.5,\"v\":1}")
        session.say(a, "{\"type\":\"cursorImg\",\"png\":\"\",\"nw\":0.1,\"nh\":0.1}")
        session.say(a, "{\"type\":\"inputReset\"}")
        session.say(a, "{\"type\":\"allowInputState\",\"allowed\":true,\"state\":\"allowed\"}")
        assertEquals(emptyList<SessionEvent>(), events)
        session.answerInvitation("s1", ReceiverApprovalDecision.Allow)
        val admitted = events.indexOfFirst { it is SessionEvent.Admitted }
        val codec = events.indexOf(SessionEvent.CodecChanged(com.raisecaterror.meowdisplay.core.session.StreamCodec.Hevc))
        assertTrue("held state follows admission: $events", admitted >= 0 && codec > admitted)
        assertTrue("an absurd width is dropped", events.contains(SessionEvent.VideoState(true, null, 1080)))
        assertTrue(events.any { it is SessionEvent.Control && it.type == "cursorImg" })
        assertFalse(events.any { it is SessionEvent.Cursor || it is SessionEvent.InputReset })
        assertFalse("no grant from before admission", session.inputAllowed)
    }

    @Test
    fun aForgottenMacIsDeclinedAndRevocationEndsItsSession() {
        val a = connect(MAC_A)
        pins.remove(MAC_A)
        session.say(a, invite("s1"))
        assertEquals(listOf("s1" to "declined"), a.responses())
        assertFalse(session.isAdmitted)

        pins[MAC_A] = byteArrayOf(1)
        val again = connect(MAC_A)
        session.say(again, invite("s2"))
        assertTrue(session.isAdmitted)
        pins.remove(MAC_A)
        session.revoke(MAC_A, blocked = false)
        assertTrue(again.closed)
        assertNull(session.peerID)
        assertEquals(SessionPhase.Disconnected, session.phase)
    }

    @Test
    fun manualInvitationsAskTheUserAndStaleOrRevokedAnswersAreInert() {
        policies.automaticallyAllow = false
        val a = connect(MAC_A)
        session.say(a, invite("s1", intent = "automatic"))
        session.say(a, invite("s2", intent = "manual"))
        assertEquals(listOf("s1" to "declined", "s2" to "pending"), a.responses())
        assertTrue(events.any { it is SessionEvent.ApprovalRequested })
        session.answerInvitation("s2", ReceiverApprovalDecision.Allow)
        assertTrue(session.isAdmitted)
        assertEquals("s2" to "accepted", a.responses().last())
        assertNull("allow once persists nothing", policies.policy(MAC_A))

        val again = connect(MAC_A)
        session.say(again, invite("s3", intent = "manual"))
        policies.setPolicy(MAC_A, PeerSessionPolicy.Blocked)
        session.answerInvitation("s3", ReceiverApprovalDecision.AllowPermanently)
        assertEquals("s3" to "blocked", again.responses().last())
        assertFalse(session.isAdmitted)
        assertEquals(PeerSessionPolicy.Blocked, policies.policy(MAC_A))
    }

    @Test
    fun anUnansweredPromptDeclinesAfterSixtySeconds() {
        policies.automaticallyAllow = false
        val a = connect(MAC_A)
        session.say(a, invite("s1", intent = "manual"))
        clock += 59_000
        session.say(a, "{\"type\":\"ping\"}")
        session.tick()
        assertEquals(listOf("s1" to "pending"), a.responses())
        clock += 1_000
        session.say(a, "{\"type\":\"ping\"}")
        session.tick()
        assertEquals("s1" to "declined", a.responses().last())
        session.answerInvitation("s1", ReceiverApprovalDecision.Allow)
        assertFalse("a late answer admits nothing", session.isAdmitted)
    }

    @Test
    fun aPreInvitationMacIsAdmittedOnlyWhenAnAutomaticInvitationWouldBe() {
        val legacy = connect(MAC_A, pv = 20)
        assertTrue(session.isAdmitted)
        assertFalse(legacy.closed)

        policies.automaticallyAllow = false
        val refused = connect(MAC_A, pv = 20)
        assertTrue("fails closed: an old Mac cannot bypass the approval preference", refused.closed)
        assertFalse(session.isAdmitted)
    }

    @Test
    fun updateRequiredIsTerminalAndOnlyAnHttpsLinkIsKept() {
        val a = connect(MAC_A)
        session.say(a, invite("s1"))
        session.say(a, "{\"type\":\"updateRequired\",\"target\":\"android\",\"store\":\"javascript:alert(1)\",\"message\":\"Update\"}")
        assertNull((events.last() as SessionEvent.UpdateRequired).storeUrl)
        session.say(a, "{\"type\":\"updateRequired\",\"store\":\"https://meowdisplay.app/android\"}")
        assertEquals("https://meowdisplay.app/android", (events.last() as SessionEvent.UpdateRequired).storeUrl)
        session.onFrame(a, keyframe())
        assertEquals("no media once incompatible", 0, videoEvents())
        session.onClosed(a)
        assertEquals(SessionPhase.Unrecoverable, session.phase)
    }

    @Test
    fun silenceOverFiveSecondsDropsTheConnectionAndStartsRecovery() {
        val a = connect(MAC_A)
        session.say(a, invite("s1"))
        clock += 2_000
        session.tick()
        assertEquals("ping", a.types().last())
        clock += 3_000
        session.tick()
        assertFalse("exactly 5 s is still alive", a.closed)
        clock += 1
        session.tick()
        assertTrue(a.closed)
        assertEquals(SessionPhase.Reconnecting, session.phase)
        assertEquals(SessionLossReason.TransportLost, (events.last { it is SessionEvent.Disconnected } as SessionEvent.Disconnected).reason)
        repeat(30) { clock += 1_000; session.tick() }
        assertEquals("the Mac never came back", SessionPhase.ReconnectFailed, session.phase)
    }

    @Test
    fun withAutoReconnectOffALostConnectionIsNotRetried() {
        session.autoReconnectEnabled = false
        val a = connect(MAC_A)
        session.say(a, invite("s1"))
        clock += 5_001
        session.tick()
        assertTrue(a.closed)
        assertFalse("no recovery run", session.phase == SessionPhase.Reconnecting)
    }

    @Test
    fun bytesWithinAFrameKeepTheConnectionAlive() {
        val a = connect(MAC_A)
        repeat(4) { clock += 4_000; session.onBytes(a); session.tick() }
        assertFalse(a.closed)
    }

    @Test
    fun theMacClosingEndsTheSessionWithoutRecovery() {
        val a = connect(MAC_A)
        session.say(a, "{\"type\":\"closing\"}")
        assertTrue(a.closed)
        assertEquals(SessionPhase.PeerDisconnected, session.phase)
        session.onClosed(a)
        assertEquals(SessionPhase.PeerDisconnected, session.phase)
    }

    @Test
    fun pongsFeedTheClockAndCursorSequencesNeverGoBackwards() {
        val a = connect(MAC_A)
        session.say(a, invite("s1"))
        session.say(a, "{\"type\":\"pong\",\"t\":${clock - 40},\"mt\":${clock + 10_000}}")
        assertEquals(40.0, session.rttMs!!, 0.0)
        assertEquals(10_020.0, session.clockOffsetMs!!, 0.0)
        session.say(a, "{\"type\":\"cursor\",\"x\":0.1,\"y\":0.1,\"v\":1,\"s\":5}")
        session.say(a, "{\"type\":\"cursor\",\"x\":0.9,\"y\":0.9,\"v\":1,\"s\":4}")
        session.say(a, "{\"type\":\"cursor\",\"x\":0.2,\"y\":0.2,\"v\":0}")
        assertEquals(listOf(0.1, 0.2), events.filterIsInstance<SessionEvent.Cursor>().map { it.x })
    }

    @Test
    fun textCaretsReachTheAppOnlyAfterAdmissionAndNeverGoBackwards() {
        policies.automaticallyAllow = false
        val a = connect(MAC_A)
        session.say(a, invite("s1", intent = "manual"))
        events.clear()
        session.say(a, """{"type":"textCaret","v":1,"x":0.5,"y":0.5,"w":0.002,"h":0.02,"s":1}""")
        assertEquals("no caret before admission", emptyList<SessionEvent>(), events)
        session.answerInvitation("s1", ReceiverApprovalDecision.Allow)
        events.clear()
        session.say(a, """{"type":"textCaret","v":1,"x":0.1,"y":0.2,"w":0.002,"h":0.02,"s":5}""")
        session.say(a, """{"type":"textCaret","v":1,"x":0.9,"y":0.9,"w":0.002,"h":0.02,"s":4}""")
        session.say(a, """{"type":"textCaret","v":0,"s":6}""")
        assertEquals(
            listOf(
                SessionEvent.TextCaret(0.1, 0.2, 0.002, 0.02, visible = true),
                SessionEvent.TextCaret(0.0, 0.0, 0.0, 0.0, visible = false),
            ),
            events.filterIsInstance<SessionEvent.TextCaret>(),
        )
    }

    @Test
    fun aCancelledInvitationWithdrawsAdmissionAndInput() {
        val a = connect(MAC_A)
        session.say(a, invite("s1"))
        session.say(a, "{\"type\":\"allowInputState\",\"allowed\":true}")
        session.say(a, "{\"type\":\"sessionInviteCancel\",\"id\":\"other\"}")
        assertTrue(session.inputAllowed)
        session.say(a, "{\"type\":\"sessionInviteCancel\",\"id\":\"s1\"}")
        assertFalse(session.isAdmitted)
        assertFalse(session.inputAllowed)
    }

    @Test
    fun everyAdmissionRestartsTheDecoderFromAKeyframeWithItsFormat() {
        val a = connect(MAC_A)
        session.say(a, invite("s1"))
        session.onFrame(a, keyframe())
        assertTrue((events.last { it is SessionEvent.Video } as SessionEvent.Video).sample.newFormat != null)
        session.say(a, "{\"type\":\"sessionInviteCancel\",\"id\":\"s1\"}")
        session.say(a, invite("s2"))
        assertTrue(session.isAdmitted)
        session.onFrame(a, keyframe())
        assertTrue("same SPS, yet the new admission's decoder gets it", (events.last { it is SessionEvent.Video } as SessionEvent.Video).sample.newFormat != null)
    }

    @Test
    fun audioPreferenceIsReassertedOnWelcomeOnlyToAudioCapableMacs() {
        session.audioPreferred = true
        val a = connect(MAC_A, pv = 22)
        assertTrue(a.sent.any { it["type"]!!.jsonPrimitive.content == "audioRequest" && it["enabled"]!!.jsonPrimitive.content == "true" })
        val old = connect(MAC_A, pv = 11)
        assertFalse(old.types().contains("audioRequest"))
    }

    // MARK: Remote Access: the route changes nothing about who may replace whom

    @Test
    fun aRemoteDialBackFromAnotherMacIsHeldExactlyLikeALocalOne() {
        val a = streamingA()
        // Mac B dials in over Tailscale (a 100.x address), asking for a session, while A streams.
        val b = connect(MAC_B, remote = "100.101.102.103", local = "100.64.0.9")
        session.say(b, invite("b1", intent = "manual", initiator = "receiver"))
        assertEquals("greeted, then asked to wait for the user: no silent takeover", listOf("b1" to "pending"), b.responses())
        assertTrue(events.any { it is SessionEvent.ApprovalRequested })
        session.onFrame(b, keyframe())
        assertEquals("its media goes nowhere", 0, videoEvents())
        assertFalse(a.closed)
        assertEquals(MAC_A, session.peerID)
        assertTrue(session.isAdmitted)
        session.answerInvitation("b1", ReceiverApprovalDecision.RejectForSession)
        assertTrue(b.closed)
        assertEquals(MAC_A, session.peerID)
        assertFalse(a.closed)
    }

    @Test
    fun theConnectedEventCarriesTheAddressesOfThePathForDescribingIt() {
        val link = connect(MAC_A, remote = "100.101.102.103", local = "100.64.0.9")
        val connected = events.filterIsInstance<SessionEvent.Connected>().single()
        assertEquals(MAC_A, connected.peerID)
        assertEquals("100.101.102.103", connected.remoteAddress?.hostAddress)
        assertEquals("100.64.0.9", connected.localAddress?.hostAddress)
        assertEquals(MAC_A, link.peerID)
        events.clear()
        connect(MAC_A)
        assertNull("a link that doesn't know its path says nothing", events.filterIsInstance<SessionEvent.Connected>().single().remoteAddress)
    }

    @Test
    fun aRemoteSessionStartsWithInputOffAndNoGrantCarriesOver() {
        val first = connect(MAC_A, remote = "100.101.102.103", local = "100.64.0.9")
        session.say(first, invite("s1", intent = "manual", initiator = "receiver"))
        assertTrue(session.isAdmitted)
        assertFalse("admission over Remote Access is not input approval", session.inputAllowed)
        session.say(first, "{\"type\":\"allowInputState\",\"allowed\":true,\"state\":\"allowed\"}")
        assertTrue(session.inputAllowed)
        // The Mac dials back after a drop, again over Remote Access: the grant was for the old connection.
        val again = connect(MAC_A, remote = "100.101.102.103", local = "100.64.0.9")
        session.say(again, invite("s1", intent = "automatic", initiator = "receiver"))
        assertTrue(session.isAdmitted)
        assertFalse("Request Control is asked for again", session.inputAllowed)
    }

    // MARK: Waiting for the Mac's own user

    private fun inviteAwaiting(id: String) =
        "{\"type\":\"sessionInvite\",\"id\":\"$id\",\"initiator\":\"receiver\",\"intent\":\"manual\",\"mode\":\"extend\",\"awaitingSender\":true}"

    @Test
    fun aRequestTheMacsUserHasNotApprovedYetIsReportedUntilTheMacSendsPicture() {
        val a = connect(MAC_A)
        session.say(a, inviteAwaiting("r1"))
        assertEquals(
            "said before the admission, so the screen never shows an empty picture in between",
            listOf("SenderApproval", "Admitted"),
            events.filter { it is SessionEvent.SenderApproval || it is SessionEvent.Admitted }.map { it::class.simpleName },
        )
        assertEquals(SessionEvent.SenderApproval(true), events.filterIsInstance<SessionEvent.SenderApproval>().single())
        session.onFrame(a, keyframe())
        assertEquals(listOf(SessionEvent.SenderApproval(true), SessionEvent.SenderApproval(false)), events.filterIsInstance<SessionEvent.SenderApproval>())
    }

    @Test
    fun theMacRefusingOrTheSessionEndingClearsTheWait() {
        val withdrawn = connect(MAC_A)
        session.say(withdrawn, inviteAwaiting("r1"))
        session.say(withdrawn, "{\"type\":\"sessionInviteCancel\",\"id\":\"r1\"}")
        assertEquals(SessionEvent.SenderApproval(false), events.filterIsInstance<SessionEvent.SenderApproval>().last())
        events.clear()
        val dropped = connect(MAC_A)
        session.say(dropped, inviteAwaiting("r2"))
        session.onClosed(dropped)
        // A fresh connection starts with nothing pending; the next video never reports a stale wait.
        val next = connect(MAC_A)
        session.say(next, invite("r2", initiator = "receiver"))
        session.onFrame(next, keyframe())
        assertTrue(events.filterIsInstance<SessionEvent.SenderApproval>().none { !it.pending })
    }

    @Test
    fun cancellingWhileTheMacsUserHasNotDecidedWithdrawsTheRequestFirst() {
        val a = connect(MAC_A)
        session.say(a, inviteAwaiting("r1"))
        session.cancelOwnRequest()
        assertEquals("the Mac is told the request was withdrawn, then the session ends", listOf("r1" to "accepted", "r1" to "cancelled"), a.responses())
        assertEquals("sessionInviteResponse", a.types().let { it[it.indexOfLast { t -> t == "sessionInviteResponse" }] })
        assertTrue(a.closed)
        assertFalse(session.isAdmitted)
    }

    @Test
    fun anInvitationTheMacStartedNeverShowsAsWaitingForTheMac() {
        val a = connect(MAC_A)
        session.say(a, "{\"type\":\"sessionInvite\",\"id\":\"s1\",\"initiator\":\"sender\",\"intent\":\"manual\",\"mode\":\"extend\",\"awaitingSender\":true}")
        assertTrue(events.filterIsInstance<SessionEvent.SenderApproval>().isEmpty())
    }

    private companion object {
        const val MAC_A = "AAAAAAAA-0000-0000-0000-000000000001"
        const val MAC_B = "BBBBBBBB-0000-0000-0000-000000000002"
        val START = byteArrayOf(0, 0, 0, 1)
    }
}
