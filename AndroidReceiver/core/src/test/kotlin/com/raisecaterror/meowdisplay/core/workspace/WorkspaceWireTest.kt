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
}
