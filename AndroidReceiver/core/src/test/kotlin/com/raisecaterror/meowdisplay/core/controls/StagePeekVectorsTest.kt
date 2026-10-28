package com.raisecaterror.meowdisplay.core.controls

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The Kotlin Stage Peek against the Swift one's vectors (fixtures/stage-peek/vectors.json, MacTests/StagePeekTests). */
class StagePeekVectorsTest {
    private val root: JsonObject by lazy {
        val dir = System.getProperty("meow.stagePeekFixtures") ?: error("meow.stagePeekFixtures not set")
        Json.parseToJsonElement(File(dir, "vectors.json").readText()).jsonObject
    }

    private fun JsonElement.num() = jsonPrimitive.double
    private fun rect(a: JsonArray) = CGRect(a[0].num(), a[1].num(), a[2].num(), a[3].num())
    private fun near(expected: Double, actual: Double, what: String) = assertEquals(what, expected, actual, 1e-6)

    private fun render(effects: List<StagePeekEffect>): List<String> = effects.map {
        when (it) {
            StagePeekEffect.Opened -> "opened"
            is StagePeekEffect.Haptic -> "haptic ${it.haptic.raw}"
            is StagePeekEffect.Select -> "select ${it.id}"
            StagePeekEffect.Dismissed -> "dismissed"
        }
    }

    @Test
    fun configMatchesTheSwiftThresholds() {
        val config = root.getValue("config").jsonObject
        fun c(key: String) = config.getValue(key).num()
        near(c("holdDelay"), StagePeekConfig.holdDelay, "holdDelay")
        near(c("holdSlop"), StagePeekConfig.holdSlop, "holdSlop")
        near(c("scrubPitch"), StagePeekConfig.scrubPitch, "scrubPitch")
        near(c("expandStart"), StagePeekConfig.expandStart, "expandStart")
        near(c("expandFull"), StagePeekConfig.expandFull, "expandFull")
        near(c("expandKeep"), StagePeekConfig.expandKeep, "expandKeep")
        near(c("tickSpacing"), StagePeekConfig.tickSpacing, "tickSpacing")
        near(c("perspective"), StagePeekConfig.perspective, "perspective")
    }

    @Test
    fun scriptedMachineSessionMatchesStepByStep() {
        val session = root.getValue("machine").jsonObject
        val ids = session.getValue("ids").jsonArray.map { it.jsonPrimitive.long }
        val safe = rect(session.getValue("safe").jsonArray)
        val aspect = session.getValue("aspect").num()
        val machine = StagePeekMachine()
        machine.setItems(ids, session.getValue("current").jsonPrimitive.long)
        val steps = session.getValue("steps").jsonArray
        assertTrue(steps.size >= 20)
        val allEffects = mutableListOf<String>()
        for ((n, element) in steps.withIndex()) {
            val step = element.jsonObject
            val op = step.getValue("op").jsonPrimitive.content
            val label = "step $n ($op)"
            val point = CGPoint(step["x"]?.num() ?: 0.0, step["y"]?.num() ?: 0.0)
            val time = step.getValue("t").num()
            val touch = step["id"]?.jsonPrimitive?.int
            val effects: List<StagePeekEffect> = when (op) {
                "began" -> {
                    val owned = machine.touchBegan(touch!!, point, time, step.getValue("onStrip").jsonPrimitive.boolean)
                    assertEquals("$label owned", step.getValue("owned").jsonPrimitive.boolean, owned)
                    emptyList()
                }
                "moved" -> machine.touchMoved(touch!!, point, time, StagePeekEdge.Left)
                "ended" -> {
                    // Hit testing uses the cards as drawn when the finger lifts: laid out from the state before the call.
                    val drawn = StagePeekLayout.cards(ids.map { aspect }, machine.position, machine.expansion, StagePeekEdge.Left, safe, isPad = false, reduceMotion = false)
                    machine.touchEnded(touch!!, point, time) { StagePeekLayout.hit(it, drawn) }
                }
                "poll" -> machine.poll(time)
                else -> error("unknown op $op")
            }
            val rendered = render(effects)
            allEffects += rendered
            assertEquals("$label effects", step.getValue("effects").jsonArray.map { it.jsonPrimitive.content }, rendered)
            assertEquals("$label phase", step.getValue("phase").jsonPrimitive.content, machine.phase.raw)
            assertEquals("$label highlighted", step.getValue("highlighted").jsonPrimitive.int.toLong(), machine.highlightedID ?: -1L)
            near(step.getValue("position").num(), machine.position, "$label position")
            near(step.getValue("expansion").num(), machine.expansion, "$label expansion")
            assertEquals("$label expanded", step.getValue("expanded").jsonPrimitive.boolean, machine.expanded)
        }
        assertEquals("exactly one selection: the tap", 1, allEffects.count { it.startsWith("select") })
        assertEquals("the tap outside", 1, allEffects.count { it == "dismissed" })
    }

    @Test
    fun layoutsMatchCardsHitsAndStrips() {
        val layouts = root.getValue("layouts").jsonArray
        assertEquals(15, layouts.size)
        for (element in layouts) {
            val layout = element.jsonObject
            val name = layout.getValue("name").jsonPrimitive.content
            val position = layout.getValue("position").num()
            val expansion = layout.getValue("expansion").num()
            val edge = StagePeekEdge.of(layout.getValue("edge").jsonPrimitive.content)!!
            val label = "$name position=$position expansion=$expansion edge=${edge.raw}"
            val safe = rect(layout.getValue("safe").jsonArray)
            val cards = StagePeekLayout.cards(
                layout.getValue("aspects").jsonArray.map { it.num() }, position, expansion, edge, safe,
                layout.getValue("isPad").jsonPrimitive.boolean, layout.getValue("reduceMotion").jsonPrimitive.boolean,
            )
            val expectedCards = layout.getValue("cards").jsonArray
            assertEquals("$label card count", expectedCards.size, cards.size)
            for ((card, expected) in cards.zip(expectedCards)) {
                val e = expected.jsonObject
                val at = "$label card ${card.index}"
                assertEquals("$at index", e.getValue("index").jsonPrimitive.int, card.index)
                near(e.getValue("cx").num(), card.center.x, "$at cx")
                near(e.getValue("cy").num(), card.center.y, "$at cy")
                near(e.getValue("w").num(), card.size.width, "$at w")
                near(e.getValue("h").num(), card.size.height, "$at h")
                near(e.getValue("tilt").num(), card.tilt, "$at tilt")
                near(e.getValue("z").num(), card.z, "$at z")
                near(e.getValue("opacity").num(), card.opacity, "$at opacity")
                assertEquals("$at highlighted", e.getValue("highlighted").jsonPrimitive.boolean, card.highlighted)
            }
            val hits = layout.getValue("hits").jsonArray
            assertTrue(hits.isNotEmpty())
            for (hit in hits) {
                val h = hit.jsonObject
                val p = CGPoint(h.getValue("x").num(), h.getValue("y").num())
                assertEquals("$label hit at $p", h.getValue("card").jsonPrimitive.int, StagePeekLayout.hit(p, cards) ?: -1)
            }
            val s = layout.getValue("strip").jsonArray
            val strip = StagePeekLayout.strip(edge, safe)!!
            near(s[0].num(), strip.minX, "$label strip x")
            near(s[1].num(), strip.minY, "$label strip y")
            near(s[2].num(), strip.width, "$label strip w")
            near(s[3].num(), strip.height, "$label strip h")
        }
    }
}
