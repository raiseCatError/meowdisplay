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
            is StagePeekEffect.RevealClose -> "revealClose ${it.id?.toString() ?: "none"}"
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
        val machine = StagePeekMachine().apply { naturalScrolling = false }
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

    @Test
    fun closeSwipeSessionMatchesStepByStep() {
        val session = root.getValue("machine").jsonObject
        val ids = session.getValue("ids").jsonArray.map { it.jsonPrimitive.long }
        val machine = StagePeekMachine().apply { naturalScrolling = false }
        machine.setItems(ids, session.getValue("current").jsonPrimitive.long)
        machine.openDirectly()
        val steps = root.getValue("closeSwipe").jsonArray
        assertTrue(steps.size >= 10)
        for ((n, element) in steps.withIndex()) {
            val step = element.jsonObject
            val op = step.getValue("op").jsonPrimitive.content
            val label = "close step $n ($op)"
            val point = CGPoint(step.getValue("x").num(), step.getValue("y").num())
            val time = step.getValue("t").num()
            val touch = step.getValue("id").jsonPrimitive.int
            val card = step["card"]?.jsonPrimitive?.int?.takeIf { it >= 0 }
            val effects = when (op) {
                "began" -> { machine.touchBegan(touch, point, time, onStrip = false, closableCard = card); emptyList() }
                "moved" -> machine.touchMoved(touch, point, time, StagePeekEdge.Left)
                "ended" -> machine.touchEnded(touch, point, time) { card }
                "open" -> machine.openDirectly()
                else -> error("unknown op $op")
            }
            assertEquals("$label effects", step.getValue("effects").jsonArray.map { it.jsonPrimitive.content }, render(effects))
            assertEquals("$label phase", step.getValue("phase").jsonPrimitive.content, machine.phase.raw)
            assertEquals("$label revealed", step.getValue("revealed").jsonPrimitive.long, machine.closeRevealed ?: -1L)
            assertEquals("$label expanded", step.getValue("expanded").jsonPrimitive.boolean, machine.expanded)
        }
    }

    @Test
    fun compactDocksMatchRegionCardsAndHits() {
        val docks = root.getValue("docks").jsonArray
        assertEquals(3, docks.size)
        for (element in docks) {
            val dock = element.jsonObject
            val name = dock.getValue("name").jsonPrimitive.content
            val safe = rect(dock.getValue("safe").jsonArray)
            val region = StagePeekLayout.dockRegion(safe, dock.getValue("above").num(), dock.getValue("below").num())
            val r = dock.getValue("region").jsonArray
            near(r[0].num(), region.minX, "$name region x"); near(r[1].num(), region.minY, "$name region y")
            near(r[2].num(), region.width, "$name region w"); near(r[3].num(), region.height, "$name region h")
            val cards = StagePeekLayout.cards(listOf(1.6, 0.75, 1.33, 2.0, 1.0, 1.78), 2.0, 0.0, StagePeekEdge.Left, safe,
                dock.getValue("isPad").jsonPrimitive.boolean, reduceMotion = false, region = region)
            val expected = dock.getValue("cards").jsonArray
            assertEquals("$name card count", expected.size, cards.size)
            for ((card, e) in cards.zip(expected)) {
                near(e.jsonObject.getValue("cx").num(), card.center.x, "$name card ${card.index} cx")
                near(e.jsonObject.getValue("cy").num(), card.center.y, "$name card ${card.index} cy")
                near(e.jsonObject.getValue("h").num(), card.size.height, "$name card ${card.index} h")
            }
            for (hit in dock.getValue("hits").jsonArray) {
                val h = hit.jsonObject
                val p = CGPoint(h.getValue("x").num(), h.getValue("y").num())
                assertEquals("$name hit at $p", h.getValue("card").jsonPrimitive.int, StagePeekLayout.hit(p, cards, region) ?: -1)
            }
        }
    }

    @Test
    fun galleryColumnsMatch() {
        val rows = root.getValue("galleryColumns").jsonArray
        assertTrue(rows.size >= 10)
        for (row in rows) {
            val o = row.jsonObject
            val width = o.getValue("width").num()
            val compact = o.getValue("compact").jsonPrimitive.boolean
            val scale = o.getValue("textScale").num()
            assertEquals("width=$width compact=$compact scale=$scale", o.getValue("columns").jsonPrimitive.int,
                StagePeekGalleryLayout.columns(width, compact, scale))
        }
    }
}
