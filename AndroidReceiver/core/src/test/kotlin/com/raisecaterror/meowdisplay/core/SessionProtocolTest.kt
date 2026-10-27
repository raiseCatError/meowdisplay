package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.session.ClockSync
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import com.raisecaterror.meowdisplay.core.session.HelloFields
import com.raisecaterror.meowdisplay.core.session.InMemorySessionPolicyStore
import com.raisecaterror.meowdisplay.core.session.IncomingDecision
import com.raisecaterror.meowdisplay.core.session.IncomingSessionPolicy
import com.raisecaterror.meowdisplay.core.session.InputWireState
import com.raisecaterror.meowdisplay.core.session.InvitationIntent
import com.raisecaterror.meowdisplay.core.session.PeerSessionPolicy
import com.raisecaterror.meowdisplay.core.session.ReceiverMessages
import com.raisecaterror.meowdisplay.core.session.ReceiverSessionState
import com.raisecaterror.meowdisplay.core.session.SenderMessage
import com.raisecaterror.meowdisplay.core.session.SessionLossReason
import com.raisecaterror.meowdisplay.core.session.SessionPhase
import com.raisecaterror.meowdisplay.core.session.StreamCodec
import com.raisecaterror.meowdisplay.core.video.AccessUnit
import com.raisecaterror.meowdisplay.core.video.ParameterSetTracker
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionProtocolTest {
    @Test
    fun helloAnnouncesAnAndroidPv22TcpOnlyReceiverWithoutAddresses() {
        val hello = ReceiverMessages.hello(HelloFields(1080, 2400, 2.75, "11111111-2222-3333-4444-555555555555", maxFPS = 120))
        assertEquals("hello", hello["type"]!!.jsonPrimitive.content)
        assertEquals("Android", hello["device"]!!.jsonPrimitive.content)
        assertEquals(22, hello["pv"]!!.jsonPrimitive.content.toInt())
        assertEquals(13, hello["pp"]!!.jsonPrimitive.content.toInt())
        assertEquals(JsonArray(listOf(JsonPrimitive("tcp"))), hello["transports"])
        assertEquals(JsonArray(listOf(JsonPrimitive("h264"))), hello["codecs"])
        assertNull("phones never offer cable upgrade", hello["addrs"])
        assertNull("no QUIC listener", hello["qv"])
        assertNull(hello["requestedMode"])
    }

    @Test
    fun malformedControlMessagesAreIgnoredNeverFatal() {
        val ignored = listOf(
            "", "{", "not json", "[]", "{\"t\":1}", "{\"type\":5}", "{\"type\":null}",
            "{\"type\":\"pong\",\"t\":\"1\",\"mt\":2}", "{\"type\":\"pong\",\"t\":1}",
            "{\"type\":\"allowInputState\",\"allowed\":\"true\"}", "{\"type\":\"videoState\"}",
            "{\"type\":\"streamCodecState\",\"codec\":\"av1\"}", "{\"type\":\"displayState\",\"state\":\"gone\"}",
            "{\"type\":\"sessionInvite\",\"id\":\"\",\"initiator\":\"sender\",\"intent\":\"manual\",\"mode\":\"extend\"}",
            "{\"type\":\"sessionInvite\",\"id\":\"${"x".repeat(65)}\",\"initiator\":\"sender\",\"intent\":\"manual\",\"mode\":\"extend\"}",
            "{\"type\":\"sessionInvite\",\"id\":\"a\",\"initiator\":\"mallory\",\"intent\":\"manual\",\"mode\":\"extend\"}",
            "{\"type\":\"sessionInvite\",\"id\":\"a\",\"initiator\":\"sender\",\"intent\":\"manual\",\"mode\":\"fullscreen\"}",
            "[".repeat(10_000) + "]".repeat(10_000),
            "{\"type\":\"cursor\",\"x\":" + "[".repeat(5_000) + "]".repeat(5_000) + "}",
        )
        for (text in ignored) {
            val parsed = SenderMessage.parse(text)
            assertTrue("'${text.take(60)}' -> $parsed", parsed == null || parsed is SenderMessage.Cursor)
        }
    }

    @Test
    fun unknownTypesAndFieldsAreToleratedAndKnownOnesParse() {
        assertEquals("cursorImg", (SenderMessage.parse("{\"type\":\"cursorImg\",\"png\":\"\"}") as SenderMessage.Other).type)
        assertEquals(SenderMessage.Welcome(22, 1), SenderMessage.parse("{\"type\":\"welcome\",\"pv\":22,\"min\":1,\"transports\":[\"tcp\",\"quic\"],\"qv\":1}"))
        assertEquals("absent pv is protocol 1", SenderMessage.Welcome(1, 1), SenderMessage.parse("{\"type\":\"welcome\"}"))
        assertEquals(SenderMessage.AllowInputState(true, InputWireState.Allowed), SenderMessage.parse("{\"type\":\"allowInputState\",\"allowed\":true}"))
        assertEquals(
            SenderMessage.AllowInputState(false, InputWireState.Requesting),
            SenderMessage.parse("{\"type\":\"allowInputState\",\"allowed\":false,\"state\":\"requesting\"}"),
        )
        assertEquals(SenderMessage.Pong(10.0, 12.5), SenderMessage.parse("{\"type\":\"pong\",\"t\":10,\"mt\":12.5}"))
    }

    @Test
    fun incomingPolicyMatchesProtocolTable() {
        val cases = listOf(
            Triple(PeerSessionPolicy.Blocked, true, IncomingDecision.Block),
            Triple(PeerSessionPolicy.Blocked, false, IncomingDecision.Block),
            Triple(PeerSessionPolicy.AlwaysAllow, false, IncomingDecision.Accept),
            Triple(null, true, IncomingDecision.Accept),
        )
        for ((policy, auto, expected) in cases) {
            for (intent in InvitationIntent.entries) assertEquals(expected, IncomingSessionPolicy.resolve(policy, auto, intent))
        }
        assertEquals(IncomingDecision.Decline, IncomingSessionPolicy.resolve(null, false, InvitationIntent.Automatic))
        assertEquals(IncomingDecision.AskUser, IncomingSessionPolicy.resolve(null, false, InvitationIntent.Manual))
        assertEquals("no identity, nobody to ask", IncomingDecision.Decline,
            IncomingSessionPolicy.decision(null, InvitationIntent.Manual, InMemorySessionPolicyStore(automaticallyAllow = false)))
    }

    @Test
    fun clockSyncUsesTheMinimumRttOfTheLast15Samples() {
        val clock = ClockSync()
        assertFalse("negative rtt", clock.record(100.0, 0.0, 99.0))
        assertFalse("rtt >= 2000", clock.record(0.0, 0.0, 2000.0))
        assertNull(clock.offsetMs)
        assertTrue(clock.record(1000.0, 5050.0, 1100.0)) // rtt 100, offset 4000
        assertTrue(clock.record(2000.0, 6010.0, 2020.0)) // rtt 20, offset 4000
        assertTrue(clock.record(3000.0, 9000.0, 3500.0)) // rtt 500, offset 5750
        assertEquals(4000.0, clock.offsetMs!!, 0.0)
        repeat(15) { clock.record(10_000.0 + it, 20_000.0 + it, 10_300.0 + it) } // pushes the rtt-20 sample out
        assertEquals(9850.0, clock.offsetMs!!, 0.0)
        assertEquals("a sender timestamp on the local clock", 150.0, clock.toLocal(10_000.0)!!, 1e-9)
    }

    @Test
    fun lifecycleRecoversTransportLossAndGivesUpAfterSixWindows() {
        val state = ReceiverSessionState()
        state.connectionAdopted(); state.connectionEstablished()
        assertTrue(state.connectionLost(SessionLossReason.TransportLost))
        assertEquals(SessionPhase.Reconnecting, state.phase)
        assertFalse("duplicate loss report", state.connectionLost(SessionLossReason.TransportLost))
        val delays = mutableListOf<Long>()
        while (true) {
            val delay = state.nextReconnectDelayMs
            state.beginReconnectAttempt() ?: break
            delays += delay
            state.endReconnectAttempt()
        }
        assertEquals(listOf(500L, 1000L, 2000L, 4000L, 8000L, 8000L), delays)
        assertTrue(state.exhaustRecovery())
        assertEquals(SessionPhase.ReconnectFailed, state.phase)
    }

    @Test
    fun peerCloseAndIncompatibilityNeverAutoReconnect() {
        val state = ReceiverSessionState()
        state.connectionAdopted(); state.connectionEstablished()
        state.connectionLost(SessionLossReason.PeerClosed)
        assertEquals(SessionPhase.PeerDisconnected, state.phase)
        assertFalse("the EOF after a deliberate close", state.connectionLost(SessionLossReason.TransportLost))
        state.connectionAdopted(); state.connectionEstablished()
        state.connectionLost(SessionLossReason.ProtocolIncompatible)
        assertEquals(SessionPhase.Unrecoverable, state.phase)
        assertNull(state.beginReconnectAttempt())
    }

    @Test
    fun annexBSplitsOnFourByteStartCodesAndReadsTelemetry() {
        val sps = byteArrayOf(0x67, 1, 2)
        val pps = byteArrayOf(0x68, 3)
        val idr = byteArrayOf(0x65, 9, 9, 9)
        val payload = "{\"cap\":1000.5,\"snd\":1001}".toByteArray() + START + sps + START + pps + START + idr
        val unit = AccessUnit.parse(payload)
        assertEquals(1000.5, unit.captureMs!!, 0.0)
        assertEquals(1001.0, unit.sendMs!!, 0.0)
        assertEquals(3, unit.nalus.size)
        assertArrayEquals(idr, unit.nalus[2])
        val noPrefix = AccessUnit.parse(START + idr)
        assertNull(noPrefix.captureMs)
        assertEquals(1, noPrefix.nalus.size)
        assertEquals("garbage without start codes yields nothing to decode", 0, AccessUnit.parse(byteArrayOf(1, 2, 3)).nalus.size)
    }

    @Test
    fun nothingDecodesBeforeAKeyframeWithItsParameterSetsAndAChangedSpsRebuilds() {
        val tracker = ParameterSetTracker()
        val slice = AccessUnit.parse(START + byteArrayOf(0x41, 1))
        assertNull(tracker.accept(slice))
        assertTrue(tracker.needsKeyframe)
        val key = AccessUnit.parse(START + byteArrayOf(0x67, 1) + START + byteArrayOf(0x68, 2) + START + byteArrayOf(0x65, 3))
        val first = tracker.accept(key)
        assertNotNull(first)
        assertTrue(first!!.isKeyframe)
        assertEquals(2, first.newFormat!!.size)
        assertNull("same format: no rebuild", tracker.accept(slice)!!.newFormat)
        val rotated = AccessUnit.parse(START + byteArrayOf(0x67, 7) + START + byteArrayOf(0x68, 2) + START + byteArrayOf(0x41, 3))
        assertNull("a new SPS without a keyframe is not decodable", tracker.accept(rotated))
        tracker.reset(StreamCodec.Hevc)
        val hevcKey = AccessUnit.parse(
            START + byteArrayOf(0x40, 1) + START + byteArrayOf(0x42, 1) + START + byteArrayOf(0x44, 1) + START + byteArrayOf(0x26, 1),
        )
        val hevc = tracker.accept(hevcKey)!!
        assertTrue(hevc.isKeyframe)
        assertEquals(StreamCodec.Hevc, hevc.codec)
        assertEquals("VPS, SPS, PPS", 3, hevc.newFormat!!.size)
    }

    @Test
    fun requestedModeTravelsOnlyWhenSet() {
        val hello = ReceiverMessages.hello(HelloFields(1, 1, 1.0, "id", requestedMode = DisplayMode.Mirror))
        assertEquals("mirror", hello["requestedMode"]!!.jsonPrimitive.content)
    }

    private companion object {
        val START = byteArrayOf(0, 0, 0, 1)
    }
}
