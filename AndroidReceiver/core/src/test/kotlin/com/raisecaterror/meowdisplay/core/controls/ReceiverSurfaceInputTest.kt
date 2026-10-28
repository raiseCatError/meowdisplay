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

/** The surface's touch arbitration against a real, granted session: what reaches the Mac and what stays local. */
class ReceiverSurfaceInputTest {
    private class FakeLink : MediaLink {
        override val peerID = "mac-a"
        val sent = mutableListOf<JsonObject>()
        override fun send(payload: ByteArray): Boolean {
            sent += Json.parseToJsonElement(String(payload)).jsonObject
            return true
        }
        override fun close() {}
    }

    private class Effects : ReceiverSurfaceEffects {
        val holdArmed = mutableListOf<Double>()
        override fun threeFingerHoldArmed(delaySeconds: Double) { holdArmed += delaySeconds }
        val blocked = mutableListOf<Int>()
        val viewports = mutableListOf<ManualViewportState>()
        override fun blockedAttempt(maximumTouchCount: Int) {
            blocked += maximumTouchCount
        }
        override fun viewportChanged(state: ManualViewportState, animated: Boolean) {
            viewports += state
        }
    }

    private val link = FakeLink()
    private val session = ReceiverSession(InMemorySessionPolicyStore(), { mapOf("mac-a" to byteArrayOf(1)) }, { HelloFields(1080, 2400, 3.0, "r") }, {})
    private val effects = Effects()
    private val surface = ReceiverSurfaceInput(session.input, effects)
    private val video = CGSize(1920.0, 1080.0)
    private val view = CGRect(0.0, 0.0, 1000.0, 600.0)

    private fun say(json: String) = session.onFrame(link, json.toByteArray())

    @Before
    fun connect() {
        session.adopt(link)
        say("""{"type":"welcome","pv":22,"min":1}""")
        say("""{"type":"sessionInvite","id":"s1","initiator":"sender","intent":"automatic","mode":"extend","awaitingSender":false}""")
        say("""{"type":"allowInputState","allowed":true,"state":"allowed"}""")
        surface.updateBase(RemoteViewportCalculator.normal(view, video), video)
        surface.updateConfig(SurfaceInputConfig(allowsInput = true, senderPV = 22, smartTouchEnabled = false))
    }

    private fun finger(id: Int, x: Double, y: Double) = SurfaceTouch(id, CGPoint(x, y))
    private fun inputTypes() = link.sent.map { it["type"]!!.jsonPrimitive.content to (it["action"]?.jsonPrimitive?.content ?: it["name"]?.jsonPrimitive?.content) }
        .filter { it.first in setOf("pointer", "scroll", "gesture", "keyboard", "touch") }
    private fun scrolls() = link.sent.filter { it["type"]!!.jsonPrimitive.content == "scroll" }
    private fun JsonObject.num(key: String) = this[key]!!.jsonPrimitive.content.toDouble()

    private fun tap(x: Double, y: Double, t: Double) {
        surface.touches(SurfaceTouchPhase.Began, listOf(finger(1, x, y)), t)
        surface.touches(SurfaceTouchPhase.Ended, listOf(finger(1, x, y)), t + 0.05)
    }

    private fun twoFingerMove(from: Pair<CGPoint, CGPoint>, to: Pair<CGPoint, CGPoint>, steps: Int = 6, t0: Double = 0.0) {
        surface.touches(SurfaceTouchPhase.Began, listOf(finger(1, from.first.x, from.first.y), finger(2, from.second.x, from.second.y)), t0)
        for (i in 1..steps) {
            val f = i.toDouble() / steps
            val a = CGPoint(from.first.x + (to.first.x - from.first.x) * f, from.first.y + (to.first.y - from.first.y) * f)
            val b = CGPoint(from.second.x + (to.second.x - from.second.x) * f, from.second.y + (to.second.y - from.second.y) * f)
            surface.touches(SurfaceTouchPhase.Moved, listOf(finger(1, a.x, a.y), finger(2, b.x, b.y)), t0 + 0.016 * i)
        }
        surface.touches(SurfaceTouchPhase.Ended, listOf(finger(1, to.first.x, to.first.y), finger(2, to.second.x, to.second.y)), t0 + 0.016 * (steps + 1))
    }

    @Test
    fun aTapIsOneLeftClickAtTheTouchedPoint() {
        tap(500.0, 300.0, 1.0)
        surface.poll(1.5)
        val pointer = link.sent.filter { it["type"]!!.jsonPrimitive.content == "pointer" }
        assertEquals(listOf("move", "down", "up"), pointer.map { it["action"]!!.jsonPrimitive.content })
        assertEquals(0.5, pointer[0].num("x"), 1e-9)
        assertEquals(0.5, pointer[0].num("y"), 1e-9)
        assertEquals("left", pointer[1]["button"]!!.jsonPrimitive.content)
        assertFalse(session.input.holdsInput)
    }

    @Test
    fun twoFingerScrollSendsMacPixelsWithNaturalSignAndSeedsTheCursorInDirectTouch() {
        twoFingerMove(CGPoint(400.0, 300.0) to CGPoint(600.0, 300.0), CGPoint(400.0, 330.0) to CGPoint(600.0, 330.0))
        assertEquals("touch", link.sent.first { it["type"]!!.jsonPrimitive.content in setOf("touch", "scroll") }["type"]!!.jsonPrimitive.content)
        val totalDy = scrolls().sumOf { it.num("dy") }
        // 30 pt of finger travel at 1000 pt across a 1920 px picture.
        assertEquals(30.0 * 1920 / 1000, totalDy, 1e-6)
        assertEquals(0.0, scrolls().sumOf { it.num("dx") }, 1e-9)
        assertTrue(effects.viewports.isEmpty())
    }

    @Test
    fun scrollDirectionFollowsThePerAxisPreference() {
        surface.updateConfig(surface.config.copy(invertVerticalScroll = false, inputMode = PointerInputMode.Trackpad))
        twoFingerMove(CGPoint(400.0, 300.0) to CGPoint(600.0, 300.0), CGPoint(400.0, 330.0) to CGPoint(600.0, 330.0))
        assertTrue(scrolls().sumOf { it.num("dy") } < 0)
        assertTrue("Trackpad never teleports the cursor", link.sent.none { it["type"]!!.jsonPrimitive.content == "touch" })
    }

    @Test
    fun aPinchZoomsTheLocalViewOnlyAndStopsAtEightTimes() {
        twoFingerMove(CGPoint(400.0, 300.0) to CGPoint(600.0, 300.0), CGPoint(300.0, 300.0) to CGPoint(700.0, 300.0))
        assertEquals(2.0, surface.manualZoom.scale, 0.05)
        assertTrue("a pinch never reaches the Mac", inputTypes().none { it.first == "scroll" || it.first == "keyboard" })
        twoFingerMove(CGPoint(495.0, 300.0) to CGPoint(505.0, 300.0), CGPoint(0.0, 300.0) to CGPoint(1000.0, 300.0), t0 = 1.0)
        assertEquals(8.0, surface.manualZoom.scale, 1e-9)
        // The centre of the zoomed picture is still the centre of the Mac's display.
        val center = surface.currentTransform.displayedRect.let { CGPoint(it.midX, it.midY) }
        val mapped = surface.currentTransform.remotePoint(center)!!
        assertEquals(0.5, mapped.x, 0.01)
        assertEquals(0.5, mapped.y, 0.01)
    }

    @Test
    fun withoutInputNothingLeavesButTheViewStillZoomsAndTheAttemptIsReported() {
        surface.updateConfig(surface.config.copy(allowsInput = false))
        tap(500.0, 300.0, 1.0)
        surface.poll(1.5)
        assertEquals(emptyList<Pair<String, String?>>(), inputTypes())
        assertEquals(listOf(1), effects.blocked)
        twoFingerMove(CGPoint(400.0, 300.0) to CGPoint(600.0, 300.0), CGPoint(300.0, 300.0) to CGPoint(700.0, 300.0), t0 = 2.0)
        assertTrue(surface.manualZoom.scale > 1.5)
        assertEquals("two fingers are view navigation, not a request", listOf(1), effects.blocked)
        assertEquals(emptyList<Pair<String, String?>>(), inputTypes())
    }

    @Test
    fun threeFingerSwipeUpIsMissionControlOnce() {
        val start = listOf(finger(1, 400.0, 400.0), finger(2, 500.0, 400.0), finger(3, 600.0, 400.0))
        surface.touches(SurfaceTouchPhase.Began, start, 0.0)
        for (i in 1..10) surface.touches(SurfaceTouchPhase.Moved, start.map { it.copy(point = CGPoint(it.point.x, 400.0 - 15.0 * i)) }, 0.016 * i)
        surface.touches(SurfaceTouchPhase.Ended, start.map { it.copy(point = CGPoint(it.point.x, 250.0)) }, 0.2)
        assertEquals(listOf("gesture" to "missionControl"), inputTypes().filter { it.first == "gesture" })
    }

    @Test
    fun threeFingerTapIsSpotlight() {
        val touches = listOf(finger(1, 400.0, 400.0), finger(2, 500.0, 400.0), finger(3, 600.0, 400.0))
        surface.touches(SurfaceTouchPhase.Began, touches, 0.0)
        surface.touches(SurfaceTouchPhase.Ended, touches, 0.1)
        assertEquals(listOf("gesture" to "spotlight"), inputTypes().filter { it.first == "gesture" })
    }

    @Test
    fun aTwoFingerDoubleTapResetsAndRestoresTheView() {
        twoFingerMove(CGPoint(400.0, 300.0) to CGPoint(600.0, 300.0), CGPoint(300.0, 300.0) to CGPoint(700.0, 300.0))
        val zoomed = surface.manualZoom
        fun twoFingerTap(t: Double) {
            surface.touches(SurfaceTouchPhase.Began, listOf(finger(5, 450.0, 300.0), finger(6, 550.0, 300.0)), t)
            surface.touches(SurfaceTouchPhase.Ended, listOf(finger(5, 450.0, 300.0), finger(6, 550.0, 300.0)), t + 0.08)
        }
        twoFingerTap(2.0)
        twoFingerTap(2.2)
        assertTrue(surface.manualZoom.isIdentity)
        twoFingerTap(4.0)
        twoFingerTap(4.2)
        assertEquals(zoomed, surface.manualZoom)
    }

    @Test
    fun moveViewPansLocallyAndSendsNothing() {
        twoFingerMove(CGPoint(400.0, 300.0) to CGPoint(600.0, 300.0), CGPoint(300.0, 300.0) to CGPoint(700.0, 300.0))
        val before = link.sent.size
        surface.updateConfig(surface.config.copy(moveViewActive = true))
        val panX = surface.manualZoom.panX
        surface.touches(SurfaceTouchPhase.Began, listOf(finger(9, 500.0, 300.0)), 3.0)
        surface.touches(SurfaceTouchPhase.Moved, listOf(finger(9, 560.0, 300.0)), 3.05)
        surface.touches(SurfaceTouchPhase.Ended, listOf(finger(9, 560.0, 300.0)), 3.1)
        assertEquals(panX + 60.0, surface.manualZoom.panX, 1e-6)
        assertEquals(before, link.sent.size)
    }

    @Test
    fun aTapHoldDragIsReleasedWhenEverythingIsCancelled() {
        tap(500.0, 300.0, 1.0)
        surface.touches(SurfaceTouchPhase.Began, listOf(finger(2, 502.0, 301.0)), 1.12)
        surface.poll(1.5)
        assertEquals(setOf("left"), session.input.heldButtonNames())
        surface.cancelAll()
        assertFalse(session.input.holdsInput)
        assertEquals("up", link.sent.last { it["type"]!!.jsonPrimitive.content == "pointer" }["action"]!!.jsonPrimitive.content)
        // The cancelled finger stays consumed until it lifts: nothing more is sent for it.
        val count = link.sent.size
        surface.touches(SurfaceTouchPhase.Moved, listOf(finger(2, 600.0, 350.0)), 1.6)
        surface.touches(SurfaceTouchPhase.Ended, listOf(finger(2, 600.0, 350.0)), 1.7)
        surface.poll(2.5)
        assertEquals(count, link.sent.size)
    }

    @Test
    fun appPinchSendsTheConfiguredKeyChordsNotNativeGestures() {
        surface.updateConfig(surface.config.copy(pinchTarget = ReceiverGestureTarget.App))
        twoFingerMove(CGPoint(450.0, 300.0) to CGPoint(550.0, 300.0), CGPoint(300.0, 300.0) to CGPoint(700.0, 300.0))
        val presses = link.sent.filter { it["type"]!!.jsonPrimitive.content == "keyboard" }
        assertTrue(presses.isNotEmpty())
        assertTrue(presses.all { it["action"]!!.jsonPrimitive.content == "press" && it["usage"]!!.jsonPrimitive.content == "46" })
        assertTrue(link.sent.none { it["type"]!!.jsonPrimitive.content == "nativeAppGesture" })
        assertTrue(surface.manualZoom.isIdentity)
    }

    // MARK: Window mode three-finger hold

    private fun three(phase: SurfaceTouchPhase, t: Double, dx: Double = 0.0) =
        surface.touches(phase, listOf(finger(1, 400.0 + dx, 300.0), finger(2, 460.0 + dx, 300.0), finger(3, 520.0 + dx, 300.0)), t)

    @Test
    fun stationaryThreeFingerHoldOpensTheOverviewAndSendsNothingToTheMac() {
        surface.threeFingerHoldEnabled = true
        link.sent.clear()
        three(SurfaceTouchPhase.Began, 0.0)
        assertEquals(listOf(ReceiverSurfaceInput.THREE_FINGER_HOLD_SECONDS), effects.holdArmed)
        three(SurfaceTouchPhase.Moved, 0.2, dx = 3.0)
        assertFalse("not yet", surface.threeFingerHoldDue(0.3))
        assertTrue(surface.threeFingerHoldDue(0.5))
        assertFalse("fires once", surface.threeFingerHoldDue(0.6))
        three(SurfaceTouchPhase.Ended, 0.7, dx = 3.0)
        assertEquals("no three-finger tap, no pointer input", emptyList<Pair<String, String?>>(), inputTypes())
    }

    @Test
    fun aQuickThreeFingerTapAndASwipeStillReachTheMac() {
        surface.threeFingerHoldEnabled = true
        link.sent.clear()
        three(SurfaceTouchPhase.Began, 0.0)
        three(SurfaceTouchPhase.Ended, 0.1)
        assertFalse(surface.threeFingerHoldDue(0.5))
        assertTrue("the tap went through", inputTypes().any { it.first == "gesture" })
        link.sent.clear()
        three(SurfaceTouchPhase.Began, 1.0)
        for (i in 1..8) three(SurfaceTouchPhase.Moved, 1.0 + i * 0.016, dx = i * 30.0)
        assertFalse("moved: no overview", surface.threeFingerHoldDue(1.6))
        three(SurfaceTouchPhase.Ended, 1.2, dx = 240.0)
        assertTrue("the swipe went through", inputTypes().any { it.first == "gesture" })
    }

    @Test
    fun holdWorksViewOnlyAndIsOffOutsideWindowMode() {
        surface.updateConfig(SurfaceInputConfig(allowsInput = false, senderPV = 22, smartTouchEnabled = false))
        surface.threeFingerHoldEnabled = true
        three(SurfaceTouchPhase.Began, 0.0)
        assertTrue("picking windows needs no control", surface.threeFingerHoldDue(0.5))
        three(SurfaceTouchPhase.Ended, 0.6)
        surface.threeFingerHoldEnabled = false
        effects.holdArmed.clear()
        three(SurfaceTouchPhase.Began, 1.0)
        assertTrue(effects.holdArmed.isEmpty())
        assertFalse(surface.threeFingerHoldDue(1.6))
        three(SurfaceTouchPhase.Ended, 1.7)
    }
}
