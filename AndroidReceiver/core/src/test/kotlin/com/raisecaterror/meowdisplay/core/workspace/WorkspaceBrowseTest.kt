package com.raisecaterror.meowdisplay.core.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Stage Peek search and still scheduling: same vectors as the Swift receiver (fixtures/workspace/search-vectors.json). */
class WorkspaceBrowseTest {
    @Test fun searchVectorsRankAppsAndWindowsLikeSwift() {
        val dir = System.getProperty("meow.workspaceFixtures") ?: error("meow.workspaceFixtures not set")
        val v = Json.parseToJsonElement(File(dir, "search-vectors.json").readText()).jsonObject
        val apps = v["apps"]!!.jsonArray.map { it.jsonObject }.map {
            MacApp(it["bundle"]!!.jsonPrimitive.content, it["name"]!!.jsonPrimitive.content,
                it["running"]?.jsonPrimitive?.booleanOrNull ?: false, it["windows"]?.jsonPrimitive?.intOrNull ?: 0)
        }
        val windows = v["windows"]!!.jsonArray.map { it.jsonObject }.map {
            CatalogWindow(it["id"]!!.jsonPrimitive.long, 1, it["bundle"]!!.jsonPrimitive.content, it["app"]!!.jsonPrimitive.content,
                it["title"]!!.jsonPrimitive.content, 800, 600, WindowAvailability.Visible, false)
        }
        for (c in v["cases"]!!.jsonArray.map { it.jsonObject }) {
            val q = c["q"]!!.jsonPrimitive.content
            val r = WorkspaceSearch.search(q, apps, windows)
            assertEquals("apps for $q", c["apps"]!!.jsonArray.map { it.jsonPrimitive.content }, r.apps.map { it.bundleID })
            assertEquals("windows for $q", c["windows"]!!.jsonArray.map { it.jsonPrimitive.long }, r.windows.map { it.id })
        }
    }

    @Test fun finderLeadsAndInstalledAppsWithoutWindowsAreFound() {
        val apps = listOf(MacApp("b.zed", "Zed", true, 1), MacApp("a.notes", "Notes", false, 0), MacApp(MacApp.FINDER, "Finder", true, 0))
        assertEquals(listOf("Finder", "Zed", "Notes"), WorkspaceSearch.carouselOrder(apps).map { it.name })
        assertEquals(listOf("Notes"), WorkspaceSearch.search("not", apps, emptyList()).apps.map { it.name })
    }

    @Test fun plannerAsksVisibleFirstNeverStarvesAndBacksOffFailures() {
        val p = ThumbnailRequestPlanner()
        val all = (1L..40L).toList()
        assertEquals(listOf(35L, 36L, 1L), p.plan(listOf(35L, 36L), all, 0).take(3))
        val second = p.plan(listOf(35L), all, 1_000)
        assertFalse(35L in second); assertTrue(40L in second)
        p.failed(2, 1_000)
        assertFalse(2L in p.plan(listOf(2L), listOf(2L), 5_000))
        assertEquals(listOf(2L), p.plan(listOf(2L), listOf(2L), 1_000 + ThumbnailRequestPlanner.FAILURE_BACKOFF_MS + 100))
    }

    @Test fun appCatalogParsesAndSameRevisionMeansNoList() {
        val full = Json.parseToJsonElement("""{"type":"appCatalog","rev":3,"apps":[{"bundle":"com.apple.finder","name":"Finder","running":true},{"bundle":"x.y","name":"Y","used":1700000000}]}""").jsonObject
        val m = AppCatalogMessage.parse(full)!!
        assertEquals(3, m.revision); assertEquals(2, m.apps!!.size); assertEquals(1_700_000_000L, m.apps!![1].lastUsed)
        val same = AppCatalogMessage.parse(Json.parseToJsonElement("""{"type":"appCatalog","rev":3,"same":true}""").jsonObject)!!
        assertEquals(null, same.apps)
    }
}
