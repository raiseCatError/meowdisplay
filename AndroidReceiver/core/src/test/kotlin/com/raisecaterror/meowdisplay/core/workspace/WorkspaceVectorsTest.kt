package com.raisecaterror.meowdisplay.core.workspace

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
import org.junit.Test
import java.io.File

/** The Android port against the Swift engine's own outputs (fixtures/workspace/vectors.json). */
class WorkspaceVectorsTest {
    private val vectors: JsonObject by lazy {
        val dir = System.getProperty("meow.workspaceFixtures") ?: error("meow.workspaceFixtures not set")
        Json.parseToJsonElement(File(dir, "vectors.json").readText()).jsonObject
    }

    private fun rect(a: JsonArray) = WRect(a[0].jsonPrimitive.double, a[1].jsonPrimitive.double, a[2].jsonPrimitive.double, a[3].jsonPrimitive.double)

    private fun assertRect(expected: WRect, actual: WRect?, what: String) {
        requireNotNull(actual) { "$what missing" }
        assertEquals("$what x", expected.x, actual.x, 1e-9)
        assertEquals("$what y", expected.y, actual.y, 1e-9)
        assertEquals("$what w", expected.width, actual.width, 1e-9)
        assertEquals("$what h", expected.height, actual.height, 1e-9)
    }

    private fun hinge(e: kotlinx.serialization.json.JsonElement?): WHinge? {
        if (e == null || e is JsonNull) return null
        val o = e.jsonObject
        return WHinge(rect(o.getValue("rect").jsonArray), WAxis.of(o.getValue("orientation").jsonPrimitive.content)!!)
    }

    /** Same tree, tiles and maximized; ratios equal within float rounding. */
    private fun assertSameLayout(name: String, expected: WLayout?, actual: WLayout) {
        requireNotNull(expected)
        assertEquals("$name tiles", expected.tiles, actual.tiles)
        assertEquals("$name maximized", expected.maximized, actual.maximized)
        fun same(a: WNode, b: WNode) {
            when (a) {
                is WNode.Slot -> assertEquals("$name slot", a, b)
                is WNode.Split -> {
                    check(b is WNode.Split && a.axis == b.axis && a.children.size == b.children.size) { "$name tree differs: $a vs $b" }
                    a.ratios.zip(b.ratios).forEach { (x, y) -> assertEquals("$name ratio", x, y, 1e-12) }
                    a.children.zip(b.children).forEach { (x, y) -> same(x, y) }
                }
            }
        }
        same(expected.root, actual.root)
    }

    private fun size(a: JsonArray) = WSize(a[0].jsonPrimitive.double, a[1].jsonPrimitive.double)

    private fun checkFrames(name: String, layout: WLayout, size: WSize, h: WHinge?, expected: JsonObject) {
        val f = WGeometry.frames(layout, size, h)
        val tiles = expected.getValue("tiles").jsonObject
        assertEquals("$name tile count", tiles.size, f.tiles.size)
        for ((id, r) in tiles) assertRect(rect(r.jsonArray), f.tiles[id], "$name tile $id")
        val slots = expected.getValue("slots").jsonArray
        assertEquals("$name slots", slots.size, f.slots.size)
        slots.forEachIndexed { i, r -> assertRect(rect(r.jsonArray), f.slots[i], "$name slot $i") }
        val dividers = expected.getValue("dividers").jsonArray
        assertEquals("$name dividers", dividers.size, f.dividers.size)
        dividers.forEachIndexed { i, d ->
            val o = d.jsonObject
            assertEquals(o.getValue("path").jsonArray.map { it.jsonPrimitive.int }, f.dividers[i].path)
            assertEquals(o.getValue("index").jsonPrimitive.int, f.dividers[i].index)
            assertRect(rect(o.getValue("hit").jsonArray), f.dividers[i].hitRect, "$name divider $i")
        }
    }

    @Test
    fun presetFramesMatchSwiftOnEverySizeAndHinge() {
        val cases = vectors.getValue("layouts").jsonArray
        check(cases.size > 100)
        for (c in cases) {
            val o = c.jsonObject
            val layout = WLayoutRecord.decode(o.getValue("layout").jsonObject)!!
            checkFrames(o.getValue("name").jsonPrimitive.content, layout, size(o.getValue("size").jsonArray), hinge(o["hinge"]), o.getValue("frames").jsonObject)
        }
    }

    @Test
    fun operationsProduceTheSameTreeAsSwift() {
        val ops = vectors.getValue("operations").jsonArray.map { it.jsonObject }
        val size = WSize(1366.0, 1024.0)
        val tiles = (0 until 9).map { WTile("t$it", WSource("mac-a", 100L + it)) }
        var layout = WLayout.preset(WPreset.Grid3x3, tiles)
        fun expect(name: String, l: WLayout, at: WSize = size) {
            val o = ops.first { it.getValue("name").jsonPrimitive.content == name }
            assertSameLayout(name, WLayoutRecord.decode(o.getValue("layout").jsonObject), l)
            checkFrames(name, l, at, null, o.getValue("frames").jsonObject)
        }
        expect("start", layout)
        layout = layout.swapping("t0", "t8"); expect("swap t0 t8", layout)
        layout = layout.moving("t4", WDropTarget.Split(0, WEdge.Left, WRect.UNIT)); expect("move t4 split slot0 left", layout)
        layout = layout.removing("t2"); expect("remove t2", layout)
        val div = WGeometry.frames(layout, size).dividers[0]
        layout = WGeometry.resizing(layout, div, 0.07, size); expect("resize divider0 +0.07", layout)
        layout = layout.rotating("t1").settingFit(WFit.Fill, "t3"); expect("rotate t1 fill t3", layout)
        layout = layout.adding(WTile("n1"), landscape = true); expect("add n1", layout)
        layout = layout.applying(WPreset.Grid2x2).first; expect("apply grid2x2", layout)
        val adapted = WAdaptation.adapt(WLayout.preset(WPreset.Grid3x3, tiles), WSize(360.0, 780.0), active = "t7")
        val o = ops.first { it.getValue("name").jsonPrimitive.content == "adapt 9 -> compact active t7" }
        assertSameLayout("adapt", WLayoutRecord.decode(o.getValue("layout").jsonObject), adapted.visible)
        assertEquals(o.getValue("stacked").jsonArray.map { it.jsonPrimitive.content }, adapted.stacked)
    }

    @Test
    fun capacityAndTransformsMatchSwift() {
        for (c in vectors.getValue("capacities").jsonArray) {
            val o = c.jsonObject
            assertEquals(o.toString(), o.getValue("capacity").jsonPrimitive.int, WGeometry.capacity(size(o.getValue("size").jsonArray), hinge(o["hinge"])))
        }
        for (c in vectors.getValue("transforms").jsonArray) {
            val o = c.jsonObject
            val t = TileTransform(rect(o.getValue("tile").jsonArray), size(o.getValue("source").jsonArray),
                WRotation.of(o.getValue("rotation").jsonPrimitive.int), WFit.of(o.getValue("fit").jsonPrimitive.content))
            val pts = o.getValue("points").jsonArray; val canvas = o.getValue("canvas").jsonArray
            pts.forEachIndexed { i, p ->
                val q = t.canvasPoint(WPoint(p.jsonArray[0].jsonPrimitive.double, p.jsonArray[1].jsonPrimitive.double))
                assertEquals(canvas[i].jsonArray[0].jsonPrimitive.double, q.x, 1e-9)
                assertEquals(canvas[i].jsonArray[1].jsonPrimitive.double, q.y, 1e-9)
                val visible = t.visibleRect
                if (visible != null && visible.contains(q)) {
                    val back = t.sourcePoint(q)!!
                    assertEquals(p.jsonArray[0].jsonPrimitive.double, back.x, 1e-6)
                    assertEquals(p.jsonArray[1].jsonPrimitive.double, back.y, 1e-6)
                }
            }
        }
    }
}
