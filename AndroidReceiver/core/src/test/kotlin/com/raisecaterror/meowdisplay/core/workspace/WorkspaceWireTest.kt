package com.raisecaterror.meowdisplay.core.workspace

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.int
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
    /** No empty panes: a window leaving a pane closes it up; one window fills the picture (WorkspaceLayout.compacted). */
    @Test
    fun emptyPanesCloseUpAndOneWindowFillsThePicture() {
        val tiles = (0 until 3).map { WTile("t$it", WSource("mac-a", 10L + it)) }
        val grid = WLayout.preset(WPreset.Grid2x2, tiles)
        assertEquals(4, grid.root.slotCount)
        val compact = grid.compacted()
        assertEquals(3, compact.root.slotCount)
        assertEquals(setOf("t0", "t1", "t2"), compact.tiles.keys)
        val frames = WGeometry.frames(compact, WSize(400.0, 800.0))
        assertEquals(1.0, frames.tiles.values.sumOf { it.width * it.height }, 1e-9)
        assertEquals(WNode.Slot("t0"), compact.removing("t1").removing("t2").compacted().root)
        assertEquals(WNode.Slot("t0"), WLayout.preset(WPreset.SideBySide, listOf(tiles[0], WTile("e"))).compacted().root)
        assertEquals(WNode.Slot(null), WLayout.of().compacted().root)
    }

    /** Full Desktop in a pane goes to the Mac as "display", never as a window number; zoom goes as "zoom", never a crop. */
    @Test
    fun aDesktopPaneIsSentAsADisplayWithItsZoom() {
        val desk = WTile("d", WSource("mac-a", WSource.displayKey(1)), zoom = WPaneZoom.of(2.0, 0.3, 0.45))
        val win = WTile("w", WSource("mac-a", 10, 5))
        val layout = WLayout.of(WNode.Split(WAxis.Vertical, listOf(WNode.Slot("d"), WNode.Slot("w")), listOf(0.5, 0.5)), mapOf("d" to desk, "w" to win))
        assertTrue(desk.source!!.isDisplay)
        val msg = WorkspaceWire.workspaceRequest(layout, WGeometry.frames(layout, WSize(400.0, 800.0)), "mac-a", null,
            displayID = { s -> if (s.windowID == WSource.displayKey(1)) 1L else null }, viewEpoch = { if (it == "d") 7 else null })
        val sent = msg.getValue("tiles").jsonArray.map { it.jsonObject }
        assertEquals(1L, sent[0].getValue("display").jsonPrimitive.long)
        assertNull(sent[0]["window"])
        assertEquals(listOf(2.0, 0.3, 0.45), sent[0].getValue("zoom").jsonArray.map { it.jsonPrimitive.double })
        assertNull(sent[0]["crop"])
        assertEquals(7, sent[0].getValue("view").jsonPrimitive.int)
        assertEquals("fit", sent[0].getValue("fit").jsonPrimitive.content)
        assertNull(sent[1]["zoom"])
        assertEquals(10L, sent[1].getValue("window").jsonPrimitive.long)
        // A display the Mac no longer lists isn't sent at all.
        val gone = WorkspaceWire.workspaceRequest(layout, WGeometry.frames(layout, WSize(400.0, 800.0)), "mac-a", null) { null }
        assertEquals(1, gone.getValue("tiles").jsonArray.size)
    }

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
              {"id":12,"gen":1,"bundle":"com.apple.Safari","app":"Safari","title":"News","state":"offscreen"},
              {"id":13,"gen":1,"bundle":"com.apple.Notes","app":"Notes","title":"List","w":560,"h":412,"state":"visible","strip":true}],
             "apps":[{"bundle":"dev.zed.Zed","name":"Zed","windows":true},{"name":"no bundle"}],
             "installed":[{"bundle":"com.apple.TextEdit","name":"TextEdit"}]}
        """).jsonObject)
        assertEquals(listOf(10L, 12L, 13L), catalog.windows.map { it.id })
        assertEquals(WindowAvailability.Offscreen, catalog.windows[1].availability)
        // Stage Manager's strip: the real size, and a badge instead of a live claim.
        assertEquals(listOf(false, false, true), catalog.windows.map { it.inStageStrip })
        assertEquals(listOf(null, "Minimized", "In Strip"), catalog.windows.map { it.pausedBadge })
        assertEquals(560, catalog.windows[2].width)
        assertEquals(1, catalog.apps.size)
        assertEquals("TextEdit", catalog.installed.single().name)
        assertEquals(listOf("Zed", "Safari", "Notes"), catalog.byApp.map { it.first })
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
    fun closeWindowFromStagePeekAndItsResults() {
        val close = WorkspaceWire.windowClose(10, 2, 5)
        assertEquals("windowClose", close.getValue("type").jsonPrimitive.content)
        assertEquals(10L, close.getValue("window").jsonPrimitive.long)
        assertEquals(2L, close.getValue("gen").jsonPrimitive.long)
        assertEquals(5L, close.getValue("req").jsonPrimitive.long)
        fun parse(json: String) = WindowCloseReply.parse(Json.parseToJsonElement(json).jsonObject)
        assertEquals(WindowCloseReply(10, WindowCloseResult.SaveDialog), parse("""{"window":10,"req":5,"result":"saveDialog"}"""))
        assertNull(parse("""{"window":10,"result":"quit"}"""))
        assertNull(parse("""{"result":"closed"}"""))
        assertNull(parse("""{"window":-1,"result":"closed"}"""))
        // Every result reads as a sentence; only closed (or already gone) removes the card.
        for (r in WindowCloseResult.entries) {
            val n = WindowCloseNotice(10, "Report.txt", r)
            assertTrue(n.message.isNotBlank())
            assertEquals(r == WindowCloseResult.Closed || r == WindowCloseResult.Stale, r.removesCard)
            assertEquals(!r.removesCard, n.isError)
        }
        assertTrue(WindowCloseNotice(10, "x", null, unsupported = true).message.contains("Update"))
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

    /** Hybrid zoom: the preview maps the picture as drawn at the start to where it belongs now (same as Swift). */
    @Test
    fun aZoomPreviewScalesThePaneAboutTheFingers() {
        val pane = WRect(0.0, 0.0, 1.0, 1.0)
        // The whole source drawn across the pane, then zoomed 2x about its centre.
        val start = WRect(0.0, 0.0, 1.0, 1.0)
        val now = WRect(-0.5, -0.5, 2.0, 2.0)
        val p = WZoomPreview.between("t", pane, start, now)!!
        assertEquals(now, p.source)
        assertEquals(start, p.from)
        assertEquals(2.0, p.scaleX, 1e-9)
        assertEquals(2.0, p.scaleY, 1e-9)
        val c = p.apply(WPoint(0.5, 0.5))
        assertEquals(0.5, c.x, 1e-9)
        assertEquals(0.5, c.y, 1e-9)
        val corner = p.apply(WPoint(0.25, 0.25))
        assertEquals(0.0, corner.x, 1e-9)
        assertEquals(0.0, corner.y, 1e-9)
        assertNull(WZoomPreview.between("t", pane, WRect(0.0, 0.0, 0.0, 1.0), now))
    }
}
