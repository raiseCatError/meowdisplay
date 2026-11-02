package com.raisecaterror.meowdisplay.core.controls

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** The Kotlin Spatial Overview against the Swift one's vectors (fixtures/stage-peek/spatial.json, MacTests/SpatialOverviewTests). */
class SpatialOverviewVectorsTest {
    private val root: JsonObject by lazy {
        val dir = System.getProperty("meow.stagePeekFixtures") ?: error("meow.stagePeekFixtures not set")
        Json.parseToJsonElement(File(dir, "spatial.json").readText()).jsonObject
    }

    @Test fun matchesSwift() {
        val cases = root["cases"]!!.jsonArray
        assertEquals(20, cases.size)
        for (c in cases) {
            val o = c.jsonObject
            val items = o["items"]!!.jsonArray.map { val a = it.jsonArray; SpatialOverviewLayout.Item(a[0].jsonPrimitive.double, a[1].jsonPrimitive.double) }
            val got = SpatialOverviewLayout.layout(items, o["width"]!!.jsonPrimitive.double, o["height"]!!.jsonPrimitive.double)
            val want = o["placements"]!!.jsonArray
            assertEquals(want.size, got.size)
            want.forEachIndexed { i, p ->
                val a = p.jsonArray.map { it.jsonPrimitive.double }
                val label = "${o["width"]}x${o["height"]} n=${items.size} #$i"
                assertEquals(label, a[0].toInt(), got[i].page)
                assertEquals(label, a[1], got[i].rect.minX, 1e-6)
                assertEquals(label, a[2], got[i].rect.minY, 1e-6)
                assertEquals(label, a[3], got[i].rect.width, 1e-6)
                assertEquals(label, a[4], got[i].rect.height, 1e-6)
            }
        }
    }
}
