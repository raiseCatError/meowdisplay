package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.session.CustomFrameRate
import com.raisecaterror.meowdisplay.core.session.ExtendShape
import com.raisecaterror.meowdisplay.core.session.ExtendShapePreference
import com.raisecaterror.meowdisplay.core.session.HelloFields
import com.raisecaterror.meowdisplay.core.session.InMemorySessionPolicyStore
import com.raisecaterror.meowdisplay.core.session.MaxFPSPreference
import com.raisecaterror.meowdisplay.core.session.MediaLink
import com.raisecaterror.meowdisplay.core.session.ReceiverSession
import com.raisecaterror.meowdisplay.core.session.SessionEvent
import com.raisecaterror.meowdisplay.core.session.StreamSettings
import com.raisecaterror.meowdisplay.core.session.StreamSettingsModel
import com.raisecaterror.meowdisplay.core.session.StreamSettingsUpdate
import com.raisecaterror.meowdisplay.core.session.StreamSettingsWire
import com.raisecaterror.meowdisplay.core.session.StreamingPriority
import com.raisecaterror.meowdisplay.core.session.StreamingProfile
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Streaming Profile, Priority, Maximum FPS, Mirror Display, Extend Shape and Video (PROTOCOL.md
 * 6.6–6.8): the Mac's exact wire shapes, its protocol-version gates, the admission gate, and the
 * request/confirm/expire cycle.
 */
class StreamSettingsTest {
    private class FakeLink(override val peerID: String) : MediaLink {
        override val remoteAddress: java.net.InetAddress? = null
        override val localAddress: java.net.InetAddress? = null
        val sent = mutableListOf<JsonObject>()
        var closed = false
        override fun send(payload: ByteArray): Boolean {
            if (closed) return false
            sent += Json.parseToJsonElement(String(payload)).jsonObject
            return true
        }
        override fun close() { closed = true }
        fun last(type: String) = sent.last { it["type"]!!.jsonPrimitive.content == type }
        fun count(type: String) = sent.count { it["type"]!!.jsonPrimitive.content == type }
    }

    private var clock = 1_000_000L
    private val events = mutableListOf<SessionEvent>()
    private val session = ReceiverSession(
        InMemorySessionPolicyStore(), { mapOf(MAC to byteArrayOf(1)) }, { HelloFields(1080, 2400, 3.0, "receiver-id") }, { events += it }, { clock },
    )
    private val settings get() = session.streamSettings.value

    private fun ReceiverSession.say(link: MediaLink, json: String) = onFrame(link, json.toByteArray())
    private fun connect(pv: Int = 22, admit: Boolean = true) = FakeLink(MAC).also {
        session.adopt(it)
        session.say(it, "{\"type\":\"welcome\",\"pv\":$pv,\"min\":1}")
        if (admit) {
            session.say(it, "{\"type\":\"sessionInvite\",\"id\":\"s1\",\"initiator\":\"sender\",\"intent\":\"automatic\",\"mode\":\"mirror\",\"awaitingSender\":false}")
        }
    }

    // The exact JSON MacSender builds (sendMaxFPSState / sendMirrorDisplayState / sendExtendShapeState).
    private val maxFPSState = "{\"type\":\"maxFPSState\",\"enabled\":true,\"maxFPS\":60,\"availableTiers\":[1,5,10,24,30,60],\"encoderSafeFPS\":60,\"requestedFPS\":120,\"effectiveFPS\":60,\"reason\":\"encoderThroughput\"}"
    private val mirrorState = "{\"type\":\"mirrorDisplayState\",\"displays\":[{\"uuid\":\"08F2\",\"name\":\"BenQ GW2780\",\"isMain\":true,\"logicalWidth\":1920,\"logicalHeight\":1080,\"pixelWidth\":1920,\"pixelHeight\":1080,\"likelyVirtual\":false},{\"uuid\":\"A1\",\"name\":\"Built-in Retina Display\",\"isMain\":false,\"pixelWidth\":2560,\"pixelHeight\":1664,\"likelyVirtual\":false}],\"selectedUUID\":\"A1\"}"

    @Test
    fun theMacsStateMessagesParse() {
        assertEquals(StreamSettingsUpdate.Profile(StreamingProfile.Efficiency),
            StreamSettingsWire.parse("streamingProfileState", obj("{\"profile\":\"efficiency\"}")))
        assertEquals(StreamSettingsUpdate.Priority(StreamingPriority.PreferLatency),
            StreamSettingsWire.parse("streamingPriorityState", obj("{\"priority\":\"preferLatency\"}")))
        assertEquals(StreamSettingsUpdate.ExtendShapeConfirmed(ExtendShapePreference(ExtendShape.R21x9, false)),
            StreamSettingsWire.parse("extendShapeState", obj("{\"shape\":\"21:9\",\"useFullDisplay\":false}")))
        val fps = StreamSettingsWire.parse("maxFPSState", obj(maxFPSState)) as StreamSettingsUpdate.MaxFPS
        assertEquals(MaxFPSPreference(true, 60), fps.state.preference)
        assertEquals(listOf(1, 5, 10, 24, 30, 60), fps.state.availableTiers)
        val mirror = StreamSettingsWire.parse("mirrorDisplayState", obj(mirrorState)) as StreamSettingsUpdate.MirrorDisplays
        assertEquals("A1", mirror.state.selectedUUID)
        assertEquals(listOf("BenQ GW2780", "Built-in Retina Display"), mirror.state.displays.map { it.name })
        assertTrue(mirror.state.displays.first().isMain)
        assertEquals(StreamSettingsUpdate.MirrorUnavailable,
            StreamSettingsWire.parse("mirrorUnavailable", obj("{\"reason\":\"noUsablePhysicalDisplay\"}")))
    }

    @Test
    fun malformedOrHostileStatesAreBoundedOrIgnored() {
        assertNull(StreamSettingsWire.parse("streamingProfileState", obj("{\"profile\":\"turbo\"}")))
        assertNull(StreamSettingsWire.parse("extendShapeState", obj("{\"shape\":7}")))
        assertNull(StreamSettingsWire.parse("maxFPSState", obj("{\"enabled\":true,\"maxFPS\":0}")))
        assertNull(StreamSettingsWire.parse("mirrorDisplayState", obj("{\"selectedUUID\":\"x\"}")))
        assertNull(StreamSettingsWire.parse("somethingElse", obj("{}")))
        val many = (1..100).joinToString(",") { "{\"uuid\":\"u$it\",\"name\":\"${"n".repeat(500)}\"}" }
        val mirror = StreamSettingsWire.parse("mirrorDisplayState", obj("{\"displays\":[$many,{\"name\":\"no uuid\"}]}")) as StreamSettingsUpdate.MirrorDisplays
        assertEquals(StreamSettingsWire.MAX_DISPLAYS, mirror.state.displays.size)
        assertTrue(mirror.state.displays.all { it.name.length <= StreamSettingsWire.MAX_NAME_LENGTH })
        assertNull("absent selection is Auto", mirror.state.selectedUUID)
        val tiers = StreamSettingsWire.parse("maxFPSState", obj("{\"enabled\":false,\"maxFPS\":60,\"availableTiers\":[60,\"30\",-1,99999,30,60]}")) as StreamSettingsUpdate.MaxFPS
        assertEquals(listOf(30, 60), tiers.state.availableTiers)
    }

    @Test
    fun nothingShowsOrCanBeRequestedBeforeAdmission() {
        val link = connect(admit = false)
        session.say(link, "{\"type\":\"streamingProfileState\",\"profile\":\"efficiency\"}")
        session.say(link, maxFPSState)
        assertEquals("an unadmitted Mac never drives the UI", 0, settings.macProtocolVersion)
        assertNull(settings.profile)
        assertFalse(session.requestStreamingProfile(StreamingProfile.Performance))
        assertFalse(session.requestVideo(false))
        assertEquals(0, link.count("streamingProfileRequest") + link.count("videoRequest"))
        session.say(link, "{\"type\":\"sessionInvite\",\"id\":\"s1\",\"initiator\":\"sender\",\"intent\":\"automatic\",\"mode\":\"mirror\",\"awaitingSender\":false}")
        assertEquals("what the Mac said before admission shows at admission", StreamingProfile.Efficiency, settings.profile)
        assertEquals(MaxFPSPreference(true, 60), settings.maxFPS)
        assertEquals(22, settings.macProtocolVersion)
    }

    @Test
    fun requestsCarryTheMacsWireShapes() {
        val link = connect()
        assertTrue(session.requestStreamingProfile(StreamingProfile.Custom, CustomFrameRate.Fps90))
        assertEquals("custom", link.last("streamingProfileRequest")["profile"]!!.jsonPrimitive.content)
        assertEquals("fps90", link.last("streamingProfileRequest")["customFrameRate"]!!.jsonPrimitive.content)
        assertEquals(CustomFrameRate.Fps90, settings.customFrameRate)
        assertTrue(session.requestStreamingPriority(StreamingPriority.PreferFps))
        assertEquals("preferFPS", link.last("streamingPriorityRequest")["priority"]!!.jsonPrimitive.content)
        assertTrue(session.requestVideo(false))
        assertEquals("false", link.last("videoRequest")["enabled"]!!.jsonPrimitive.content)
        assertTrue(session.requestMaxFPS(MaxFPSPreference(true, 30)))
        assertEquals("30", link.last("maxFPSRequest")["maxFPS"]!!.jsonPrimitive.content)
        assertTrue(session.requestExtendShape(ExtendShapePreference(ExtendShape.Automatic, useFullDisplay = true)))
        assertEquals("automatic", link.last("extendShapeRequest")["shape"]!!.jsonPrimitive.content)
        assertEquals("true", link.last("extendShapeRequest")["useFullDisplay"]!!.jsonPrimitive.content)
    }

    @Test
    fun mirrorDisplayRequestsOnlyNameADisplayTheMacListed() {
        val link = connect()
        assertFalse("nothing listed yet", session.requestMirrorDisplay("08F2"))
        session.say(link, mirrorState)
        assertFalse(session.requestMirrorDisplay("not-a-display"))
        assertTrue(session.requestMirrorDisplay("08F2"))
        assertEquals("08F2", link.last("mirrorDisplayRequest")["selectedUUID"]!!.jsonPrimitive.content)
        assertTrue("Auto is always allowed", session.requestMirrorDisplay(null))
        assertNull(link.last("mirrorDisplayRequest")["selectedUUID"])
        session.say(link, "{\"type\":\"mirrorDisplayState\",\"displays\":[],\"selectedUUID\":\"gone\"}")
        assertTrue(settings.mirrorDisplays!!.selectionUnavailable)
    }

    @Test
    fun anOlderMacGetsOnlyWhatItUnderstands() {
        val link = connect(pv = 12)
        assertTrue("video control is pv 9", session.requestVideo(false))
        assertFalse("mirror display is pv 13", session.requestMirrorDisplay(null))
        assertFalse("extend shape is pv 14", session.requestExtendShape(ExtendShapePreference(ExtendShape.R4x3)))
        assertFalse("max FPS is pv 15", session.requestMaxFPS(MaxFPSPreference(true, 30)))
        assertFalse("priority is pv 16", session.requestStreamingPriority(StreamingPriority.PreferLatency))
        assertFalse("profile requests are pv 21", session.requestStreamingProfile(StreamingProfile.Efficiency))
        val settingRequests = setOf("videoRequest", "mirrorDisplayRequest", "extendShapeRequest", "maxFPSRequest", "streamingPriorityRequest", "streamingProfileRequest")
        assertEquals("only the video request went out", 1, link.sent.count { it["type"]!!.jsonPrimitive.content in settingRequests })
        val ancient = connect(pv = 8)
        assertFalse("no video control before pv 9", session.requestVideo(false))
        assertEquals(0, ancient.count("videoRequest"))
    }

    @Test
    fun aShapeRequestStaysPendingUntilConfirmedOrExpired() {
        val link = connect()
        session.say(link, "{\"type\":\"extendShapeState\",\"shape\":\"automatic\",\"useFullDisplay\":false}")
        val want = ExtendShapePreference(ExtendShape.R4x3)
        assertTrue(session.requestExtendShape(want))
        assertEquals(want, settings.pendingExtendShape)
        assertEquals(want, settings.shownExtendShape)
        assertFalse("one at a time", session.requestExtendShape(ExtendShapePreference(ExtendShape.R1x1)))
        session.say(link, "{\"type\":\"extendShapeState\",\"shape\":\"4:3\",\"useFullDisplay\":false}")
        assertNull(settings.pendingExtendShape)
        assertEquals(want, settings.extendShape)
        assertFalse("asking for what is already confirmed sends nothing", session.requestExtendShape(want))
        assertTrue(session.requestExtendShape(ExtendShapePreference(ExtendShape.R1x1)))
        clock += StreamSettingsModel.PENDING_TIMEOUT_MS
        session.say(link, "{\"type\":\"ping\"}")
        session.tick()
        assertNull("an unanswered request is dropped after 15 s", settings.pendingExtendShape)
        assertEquals("the confirmed value stays", want, settings.extendShape)
    }

    @Test
    fun maxFPSConfirmationCarriesTheTiersAndLimitation() {
        val link = connect()
        session.say(link, "{\"type\":\"streamingProfileState\",\"profile\":\"performance\"}")
        session.say(link, maxFPSState)
        assertEquals(listOf(1, 5, 10, 24, 30, 60), settings.maxFPSTiers)
        assertEquals("Performance requests 120 FPS. Limited to 60 FPS at this display size.", settings.fpsLimitationText)
        assertTrue(session.requestMaxFPS(MaxFPSPreference(true, 24)))
        session.say(link, maxFPSState.replace("\"maxFPS\":60", "\"maxFPS\":24"))
        assertEquals(MaxFPSPreference(true, 24), settings.maxFPS)
        assertNull(settings.pendingMaxFPS)
        assertEquals(24, StreamSettings.tierFor(24, settings.maxFPSTiers))
        assertEquals("a stored value between tiers shows the tier below it", 60, StreamSettings.tierFor(90, settings.maxFPSTiers))
    }

    @Test
    fun aNewConnectionForgetsTheOldMacsStateButKeepsTheCustomRate() {
        val link = connect()
        session.requestStreamingProfile(StreamingProfile.Custom, CustomFrameRate.Fps30)
        session.say(link, "{\"type\":\"streamingProfileState\",\"profile\":\"custom\"}")
        session.say(link, mirrorState)
        session.say(link, "{\"type\":\"videoState\",\"enabled\":false,\"width\":1920,\"height\":1080}")
        assertEquals(false, settings.videoEnabled)
        session.onClosed(link)
        assertNull(settings.profile)
        assertNull(settings.mirrorDisplays)
        assertNull(settings.videoEnabled)
        connect()
        assertNull("the next Mac must say for itself", settings.profile)
        assertEquals(CustomFrameRate.Fps30, settings.customFrameRate)
    }

    @Test
    fun mirrorUnavailableIsAnsweredByAConfirmedMode() {
        val link = connect()
        session.say(link, "{\"type\":\"mirrorUnavailable\",\"reason\":\"noUsablePhysicalDisplay\"}")
        assertTrue(settings.mirrorUnavailable)
        session.say(link, "{\"type\":\"displayModeState\",\"mode\":\"extend\"}")
        assertFalse(settings.mirrorUnavailable)
    }

    @Test
    fun settingStatesAreNotAlsoDeliveredAsGenericControlEvents() {
        val link = connect()
        session.say(link, mirrorState)
        assertTrue(events.none { it is SessionEvent.Control && it.type == "mirrorDisplayState" })
    }

    private fun obj(json: String) = Json.parseToJsonElement(json).jsonObject

    private companion object {
        const val MAC = "mac-install-id"
    }
}
