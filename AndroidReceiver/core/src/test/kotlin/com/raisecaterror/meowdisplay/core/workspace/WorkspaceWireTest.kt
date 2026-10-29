package com.raisecaterror.meowdisplay.core.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkspaceWireTest {
    @Test
    fun requestCarriesOnlyThisHostsTilesAtTheirFrames() {
        val layout = WLayout.preset(WPreset.PrimaryPlusTwo, listOf(
            WTile("a", WSource("mac-a", 10, generation = 3)),
            WTile("b", WSource("mac-b", 10, generation = 9), rotation = WRotation.Quarter),
            WTile("c", WSource("mac-a", 11, follow = WFollow.App), fit = WFit.Fill),
        ))
        val frames = WGeometry.frames(layout, WSize(844.0, 390.0))
        val msg = WorkspaceWire.workspaceRequest(layout, frames, host = "mac-a", focus = "a")
        val tiles = msg.getValue("tiles").jsonArray.map { it.jsonObject }
        assertEquals(listOf("a", "c"), tiles.map { it.getValue("id").jsonPrimitive.content })
        assertEquals(3L, tiles[0].getValue("gen").jsonPrimitive.long)
        assertEquals(frames.tiles.getValue("a").width, tiles[0].getValue("w").jsonPrimitive.double, 1e-12)
        assertEquals("app", tiles[1].getValue("follow").jsonPrimitive.content)
        assertEquals("fill", tiles[1].getValue("fit").jsonPrimitive.content)
        assertEquals("a", msg.getValue("focus").jsonPrimitive.content)
    }

    @Test
    fun startingIsNotAListingFailure() {
        fun parse(error: String) = WindowCatalog.parse(Json.parseToJsonElement(
            """{"type":"windowCatalog","windows":[],"apps":[],"error":"$error"}""").jsonObject)
        val starting = parse("starting")
        assertTrue(starting.starting)
        assertFalse("the picker keeps asking instead of blaming Screen Recording", starting.unavailable)
        val failed = parse("unavailable")
        assertTrue(failed.unavailable)
        assertFalse(failed.starting)
    }

    @Test
    fun catalogAndStateParseDefensively() {
        val catalog = WindowCatalog.parse(Json.parseToJsonElement("""
            {"type":"windowCatalog","host":"mac-a","windows":[
              {"id":10,"gen":2,"bundle":"dev.zed.Zed","app":"Zed","title":"main.rs","w":800,"h":600,"state":"visible","active":true},
              {"id":"bad","bundle":"x"},{"id":11,"app":"no bundle"},
              {"id":12,"gen":1,"bundle":"com.apple.Safari","app":"Safari","title":"News","state":"offscreen"}],
             "apps":[{"bundle":"dev.zed.Zed","name":"Zed","windows":true},{"name":"no bundle"}],
             "installed":[{"bundle":"com.apple.TextEdit","name":"TextEdit"}]}
        """).jsonObject)
        assertEquals(listOf(10L, 12L), catalog.windows.map { it.id })
        assertEquals(WindowAvailability.Offscreen, catalog.windows[1].availability)
        assertEquals(1, catalog.apps.size)
        assertEquals("TextEdit", catalog.installed.single().name)
        assertEquals(listOf("Zed", "Safari"), catalog.byApp.map { it.first })
        assertEquals(listOf(12L), catalog.search("news").map { it.id })
        assertFalse(catalog.unavailable)

        val state = WorkspaceState.parse(Json.parseToJsonElement("""
            {"type":"workspaceState","host":"mac-a","active":"a","hostFocus":"hostFocusElsewhere",
             "tiles":[{"id":"a","window":10,"gen":2,"state":"live","app":"Zed"},{"id":"b","state":"bogus"},{"window":3}],
             "rejected":{"c":"unavailable","d":7},"limit":9}
        """).jsonObject)
        assertEquals(listOf("a", "b"), state.tiles.map { it.id })
        assertEquals(TileStatus.Waiting, state.tiles[1].state)
        assertTrue(state.hostFocus.isMismatch)
        assertEquals(mapOf("c" to "unavailable"), state.rejected)
        assertNull(WindowThumbnail.parse(Json.parseToJsonElement("""{"jpeg":"abc"}""").jsonObject))
        val huge = "A".repeat(WorkspaceWire.MAX_THUMBNAIL_BASE64 + 1)
        assertNull("oversized stills are dropped", WindowThumbnail.parse(Json.parseToJsonElement("""{"id":1,"jpeg":"$huge"}""").jsonObject)!!.jpegBase64)
    }

    @Test
    fun closingTheRemoteWindowIsItsOwnExplicitMessage() {
        val close = WorkspaceWire.closeRemoteWindow(10, 2)
        assertEquals("windowAction", close.getValue("type").jsonPrimitive.content)
        assertEquals("close", close.getValue("action").jsonPrimitive.content)
        assertEquals(2L, close.getValue("gen").jsonPrimitive.long)
        // Removing a tile never produces a window action: it is just a smaller workspace request.
        val layout = WLayout.preset(WPreset.SideBySide, listOf(WTile("a", WSource("m", 1)), WTile("b", WSource("m", 2)))).removing("b")
        val msg = WorkspaceWire.workspaceRequest(layout, WGeometry.frames(layout, WSize(800.0, 400.0)), "m", null)
        assertEquals("workspaceRequest", msg.getValue("type").jsonPrimitive.content)
        assertEquals(1, msg.getValue("tiles").jsonArray.size)
    }

    @Test
    fun aTileIsMissingOnlyWhileItsWindowIsUnlisted() {
        fun window(id: Long, bundle: String) = CatalogWindow(id, 1, bundle, bundle, "t", 800, 600, WindowAvailability.Visible, false)
        val catalog = WindowCatalog("m", listOf(window(10, "dev.zed.Zed"), window(12, "dev.qa.probe")), emptyList(), emptyList(), false)
        val layout = WLayout.preset(WPreset.ThreeColumns, listOf(
            WTile("a", WSource("m", 10, bundleID = "dev.zed.Zed")),
            WTile("b", WSource("m", 11, bundleID = "dev.qa.probe")),   // closed
            WTile("c", WSource("m", 12, bundleID = "com.apple.Safari")),   // id reused by another app
        ))
        assertEquals(setOf("b", "c"), catalog.missingTiles(layout))
        // Choosing a listed window for a missing tile clears its mark.
        assertEquals(setOf("c"), catalog.missingTiles(layout.replacingSource("b", WSource("m", 12, bundleID = "dev.qa.probe"))))
        assertEquals(setOf("b"), catalog.missingTiles(layout.removing("c")))
    }
}
