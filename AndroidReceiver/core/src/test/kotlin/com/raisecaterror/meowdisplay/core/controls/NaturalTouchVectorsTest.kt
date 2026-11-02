package com.raisecaterror.meowdisplay.core.controls

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The Kotlin engine against the Swift engine's Natural Touch vectors (fixtures/gestures/natural-touch.json). */
class NaturalTouchVectorsTest {
    private val root: JsonObject by lazy {
        val dir = System.getProperty("meow.gestureFixtures") ?: error("meow.gestureFixtures not set")
        Json.parseToJsonElement(File(dir, "natural-touch.json").readText()).jsonObject
    }

    private fun render(c: PointerCommand): List<String> = when (c) {
        is PointerCommand.MoveAbsolute -> listOf("move", "${c.x}", "${c.y}")
        is PointerCommand.MoveRelative -> listOf("rel", "${c.dx}", "${c.dy}")
        is PointerCommand.MouseDown -> listOf("down", c.button.wireValue, "${c.clickCount}")
        is PointerCommand.MouseUp -> listOf("up", c.button.wireValue, "${c.clickCount}")
        is PointerCommand.Scroll -> listOf("scroll", "${c.dx}", "${c.dy}")
        is PointerCommand.ScrollEnded -> listOf("scrollEnd", if (c.momentum) "momentum" else "cancel")
        is PointerCommand.SmartTouchFeedback -> listOf(
            "feedback",
            when (c.feedback) {
                SmartTouchFeedback.LongPressRightClick -> "longPressRightClick"
                else -> c.feedback.toString()
            },
        )
        is PointerCommand.ProbeScrollTarget -> listOf("probe", "${c.id}")
    }

    private fun matches(actual: List<String>, expected: String): Boolean {
        val want = expected.split(" ")
        if (want.size != actual.size) return false
        return actual.zip(want).all { (a, w) ->
            val x = a.toDoubleOrNull()
            val y = w.toDoubleOrNull()
            if (x != null && y != null) kotlin.math.abs(x - y) < 1e-6 else a == w
        }
    }

    private fun pair(a: JsonArray) = CGPoint(a[0].jsonPrimitive.double, a[1].jsonPrimitive.double)

    @Test
    fun sharedVectors() {
        val cases = root.getValue("cases").jsonArray
        assertTrue(cases.size >= 20)
        for (case in cases) {
            val c = case.jsonObject
            val name = c.getValue("name").jsonPrimitive.content
            val engine = PointerGestureEngine()
            engine.setTouchStyle(DirectTouchStyle.Natural)
            val out = ArrayList<PointerCommand>()
            for (stepEl in c.getValue("steps").jsonArray) {
                val step = stepEl.jsonObject
                when {
                    "poll" in step -> out += engine.poll(step.getValue("poll").jsonPrimitive.double)
                    "style" in step -> out += engine.setTouchStyle(DirectTouchStyle.of(step.getValue("style").jsonPrimitive.content)!!)
                    "inputMode" in step -> out += engine.setInputMode(PointerInputMode.of(step.getValue("inputMode").jsonPrimitive.content)!!)
                    "reset" in step -> out += engine.reset()
                    else -> {
                        val phase = when (step.getValue("phase").jsonPrimitive.content) {
                            "began" -> PointerTouchSample.Phase.Began
                            "moved" -> PointerTouchSample.Phase.Moved
                            "ended" -> PointerTouchSample.Phase.Ended
                            else -> PointerTouchSample.Phase.Cancelled
                        }
                        val norm = step["norm"]?.takeIf { it !is JsonNull }?.let { pair(it.jsonArray) }
                        out += engine.handle(
                            PointerTouchSample(
                                id = step.getValue("id").jsonPrimitive.int,
                                phase = phase,
                                viewPoint = pair(step.getValue("view").jsonArray),
                                normalized = norm,
                                time = step.getValue("t").jsonPrimitive.double,
                            ),
                        )
                    }
                }
            }
            val expected = c.getValue("expect").jsonArray.map { it.jsonPrimitive.content }
            val rendered = out.map(::render)
            val ok = rendered.size == expected.size && rendered.zip(expected).all { (a, e) -> matches(a, e) }
            assertTrue("$name\n got: ${rendered.map { it.joinToString(" ") }}\nwant: $expected", ok)
            assertNull("$name: a button is still held", engine.heldMouseButton)
        }
    }

    @Test
    fun bareEngineStaysClassic() {
        assertEquals(DirectTouchStyle.Classic, PointerGestureEngine().touchStyle)
    }

    @Test
    fun naturalTouchIgnoresSmartTouchProbes() {
        val engine = PointerGestureEngine()
        engine.smartTouchEnabled = true
        engine.setTouchStyle(DirectTouchStyle.Natural)
        val down = engine.handle(PointerTouchSample(1, PointerTouchSample.Phase.Began, CGPoint(10.0, 10.0), CGPoint(0.1, 0.1), 0.0))
        assertEquals(emptyList<PointerCommand>(), down)
    }

    @Test
    fun longPressDeadlineIsReportedForPolling() {
        val engine = PointerGestureEngine()
        engine.setTouchStyle(DirectTouchStyle.Natural)
        engine.handle(PointerTouchSample(1, PointerTouchSample.Phase.Began, CGPoint(0.0, 0.0), CGPoint(0.5, 0.5), 10.0))
        assertEquals(PointerGestureConfig.naturalLongPressDelay, engine.pollDelay(10.0)!!, 1e-9)
    }

    @Test
    fun liftFarFromTouchDownWithoutMoveEventsDoesNotClick() {
        val engine = PointerGestureEngine()
        engine.setTouchStyle(DirectTouchStyle.Natural)
        engine.handle(PointerTouchSample(1, PointerTouchSample.Phase.Began, CGPoint(0.0, 0.0), CGPoint(0.5, 0.5), 0.0))
        val up = engine.handle(PointerTouchSample(1, PointerTouchSample.Phase.Ended, CGPoint(80.0, 0.0), CGPoint(0.6, 0.5), 0.1))
        assertEquals(emptyList<PointerCommand>(), up)
    }
}
