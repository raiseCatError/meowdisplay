package com.raisecaterror.meowdisplay.core.demo

import com.raisecaterror.meowdisplay.core.session.DisplayMode
import com.raisecaterror.meowdisplay.core.session.HelloFields
import com.raisecaterror.meowdisplay.core.session.InMemorySessionPolicyStore
import com.raisecaterror.meowdisplay.core.session.InputWireState
import com.raisecaterror.meowdisplay.core.session.ReceiverSession
import com.raisecaterror.meowdisplay.core.session.SessionEvent
import com.raisecaterror.meowdisplay.core.workspace.TileTransform
import com.raisecaterror.meowdisplay.core.workspace.WPaneZoom
import com.raisecaterror.meowdisplay.core.workspace.WSize
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceBackdrop
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceViewEcho
import com.raisecaterror.meowdisplay.core.workspace.WorkspaceWire
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Explore Demo: the receiver's real session, admission and input gate against the in-process demo Mac. */
class DemoMacTest {
    private val queue = ArrayDeque<() -> Unit>()
    private val events = mutableListOf<SessionEvent>()
    private val mac = DemoMac(post = { queue.addLast(it) }, thumbnail = { kind, _ -> "jpeg-${kind.name}" })
    private var workspaceVersion: Int? = 1
    private val session = ReceiverSession(
        InMemorySessionPolicyStore(automaticallyAllow = true),
        { mapOf(DemoMac.PEER_ID to byteArrayOf(1)) },
        { HelloFields(1920, 1080, 2.0, "demo-test-install", windowWorkspace = workspaceVersion) },
        { events += it },
    )

    private fun drain() {
        var steps = 0
        while (queue.isNotEmpty()) {
            check(++steps < 10_000) { "demo Mac never went quiet" }
            queue.removeFirst()()
        }
    }

    private fun connect() {
        mac.attach { bytes -> session.onFrame(mac.link, bytes) }
        session.adopt(mac.link)
        drain()
    }

    /** Moves the Mac pointer to a desktop point and clicks there through the receiver's gated input sender. */
    private fun clickAt(x: Double, y: Double, clicks: Int = 1) {
        val size = mac.scene.value.size
        session.input.pointerMove(x / size.width, y / size.height)
        session.input.pointerDown("left", clicks)
        session.input.pointerUp("left", clicks)
        drain()
    }

    @Test
    fun admitsAndAllowsControlLikeAMacThatSaidYes() {
        connect()
        assertTrue(events.any { it is SessionEvent.Admitted && it.peerID == DemoMac.PEER_ID })
        assertTrue(events.any { it is SessionEvent.InputState && it.state == InputWireState.Allowed && it.allowed })
        assertTrue(events.any { it is SessionEvent.DisplayModeConfirmed && it.mode == DisplayMode.Mirror })
        val video = events.filterIsInstance<SessionEvent.VideoState>().last()
        assertTrue(video.enabled)
        assertTrue(session.inputAllowed)
        assertTrue(events.any { it is SessionEvent.MacFeatures && WorkspaceWire.WELCOME_FEATURE in it.features })
    }

    @Test
    fun clickingNotesThenTypingWritesIntoNotes() {
        connect()
        val notes = mac.scene.value.windows.first { it.kind == DemoWindowKind.Notes }
        clickAt(notes.frame.midX, notes.frame.midY)
        assertEquals(DemoWindowKind.Notes, mac.scene.value.focused)
        session.input.keyboardText(" Hello")
        drain()
        assertTrue(mac.scene.value.notes.endsWith(" Hello"))
        // ⌘Z undoes it, on the sample desktop only.
        session.input.keyboardPress(29, listOf("command"))
        drain()
        assertFalse(mac.scene.value.notes.endsWith(" Hello"))
    }

    @Test
    fun dragByTheTitleBarMovesTheWindow() {
        connect()
        val files = mac.scene.value.windows.first { it.kind == DemoWindowKind.Files }
        val size = mac.scene.value.size
        session.input.pointerMove((files.frame.midX) / size.width, (files.frame.minY + 10) / size.height)
        session.input.pointerDown("left", 1)
        session.input.pointerMove((files.frame.midX - 100) / size.width, (files.frame.minY + 60) / size.height)
        session.input.pointerUp("left", 1)
        drain()
        val moved = mac.scene.value.windows.first { it.kind == DemoWindowKind.Files }
        assertEquals(files.frame.minX - 100, moved.frame.minX, 1.0)
        assertEquals(files.frame.minY + 50, moved.frame.minY, 1.0)
    }

    @Test
    fun viewOnlySendsNothingAndChangesNothing() {
        connect()
        session.requestAllowInput(false)
        drain()
        assertFalse(session.inputAllowed)
        val before = mac.scene.value
        val notes = before.windows.first { it.kind == DemoWindowKind.Notes }
        assertFalse(session.input.pointerMove(notes.frame.midX / before.size.width, notes.frame.midY / before.size.height))
        assertFalse(session.input.keyboardText("x"))
        drain()
        assertEquals(before.notes, mac.scene.value.notes)
        // Request Control again: the demo Mac grants it.
        session.requestAllowInput(true)
        drain()
        assertTrue(session.inputAllowed)
    }

    @Test
    fun displayModesSwitchAndExtendTakesThisDevicesShape() {
        connect()
        session.requestDisplayMode(DisplayMode.Extend)
        drain()
        assertEquals(DisplayMode.Extend, events.filterIsInstance<SessionEvent.DisplayModeConfirmed>().last().mode)
        val video = events.filterIsInstance<SessionEvent.VideoState>().last()
        assertEquals(1920, video.width)
        assertEquals(1080, video.height)
        assertEquals(DemoWindowKind.Displays, mac.scene.value.windows.first().kind)
    }

    @Test
    fun windowModeServesTheCatalogTilesAndKeyboardToTheActiveTile() {
        connect()
        session.requestDisplayMode(DisplayMode.Window)
        drain()
        assertEquals(DisplayMode.Window, events.filterIsInstance<SessionEvent.DisplayModeConfirmed>().last().mode)
        session.sendWorkspace(WorkspaceWire.catalogRequest())
        drain()
        val catalog = events.filterIsInstance<SessionEvent.Control>().last { it.type == WorkspaceWire.CATALOG }
        assertEquals(4, catalog.body["windows"]!!.jsonArray.size)
        session.sendWorkspace(WorkspaceWire.thumbnailRequest(listOf(DemoWindowKind.Notes.windowID), 160))
        drain()
        assertNotNull(events.filterIsInstance<SessionEvent.Control>().lastOrNull { it.type == WorkspaceWire.THUMBNAIL })

        session.sendWorkspace(buildJsonObject {
            put("type", WorkspaceWire.WORKSPACE_REQUEST)
            put("tiles", buildJsonArray {
                add(tile("a", DemoWindowKind.Files, 0.0))
                add(tile("b", DemoWindowKind.Notes, 0.5))
                add(tile("c", DemoWindowKind.Notes, 0.75)) // duplicate window: rejected
            })
        })
        drain()
        val state = events.filterIsInstance<SessionEvent.Control>().last { it.type == WorkspaceWire.WORKSPACE_STATE }
        assertEquals(2, state.body["tiles"]!!.jsonArray.size)
        assertEquals("duplicate", (state.body["rejected"] as kotlinx.serialization.json.JsonObject)["c"]!!.toString().trim('"'))
        assertEquals(2, mac.scene.value.tiles.size)

        // A press in the Notes tile makes it active; typing then lands in Notes.
        session.input.pointerMove(0.6, 0.5)
        session.input.pointerDown("left", 1)
        session.input.pointerUp("left", 1)
        session.input.keyboardText("!")
        drain()
        assertEquals("b", mac.scene.value.activeTile)
        assertTrue(mac.scene.value.notes.endsWith("!"))
    }

    /** P1: a pane's zoom is drawn by the demo Mac, its view echoed, its whole window sent as a still, Retry answered. */
    @Test
    fun aZoomedPaneIsDrawnEchoedAndItsStillSent() {
        connect()
        session.requestDisplayMode(DisplayMode.Window)
        drain()
        session.sendWorkspace(buildJsonObject {
            put("type", WorkspaceWire.WORKSPACE_REQUEST)
            put("tiles", buildJsonArray {
                add(buildJsonObject {
                    put("id", "a"); put("host", DemoMac.PEER_ID); put("x", 0.0); put("y", 0.0); put("w", 1.0); put("h", 1.0)
                    put("window", DemoWindowKind.Notes.windowID); put("gen", 1); put("fit", "fit"); put("view", 5)
                    put("zoom", buildJsonArray { add(JsonPrimitive(0.7)); add(JsonPrimitive(0.5)); add(JsonPrimitive(0.5)) })
                })
            })
        })
        drain()
        val tile = mac.scene.value.tiles.single()
        assertEquals(WPaneZoom.of(0.7, 0.5, 0.5), tile.zoom)
        val fit = TileTransform(tile.frame.scaled(WSize(mac.scene.value.size.width, mac.scene.value.size.height)),
            WSize(DemoWindowKind.Notes.nativeWidth, DemoWindowKind.Notes.nativeHeight), tile.rotation, tile.fit)
        assertEquals(fit.scale * 0.7, mac.transform(tile).scale, 1e-9)
        val echo = events.filterIsInstance<SessionEvent.Control>().last { it.type == WorkspaceWire.WORKSPACE_VIEW }
        assertEquals(mapOf("a" to 5), WorkspaceViewEcho.parse(echo.body).tiles)

        session.sendWorkspace(WorkspaceWire.backdrop("a", 1280, 3))
        drain()
        val still = WorkspaceBackdrop.parse(events.filterIsInstance<SessionEvent.Control>().last { it.type == WorkspaceWire.WORKSPACE_BACKDROP }.body)
        assertEquals("a", still?.tile)
        assertEquals(DemoWindowKind.Notes.windowID, still?.windowID)
        assertEquals("jpeg-Notes", still?.jpegBase64)

        val states = events.count { it is SessionEvent.Control && it.type == WorkspaceWire.WORKSPACE_STATE }
        session.sendWorkspace(WorkspaceWire.retry("a"))
        drain()
        assertEquals(states + 1, events.count { it is SessionEvent.Control && it.type == WorkspaceWire.WORKSPACE_STATE })
    }

    @Test
    fun windowModeNeedsAReceiverThatSpeaksWorkspaces() {
        workspaceVersion = null
        connect()
        session.requestDisplayMode(DisplayMode.Window)
        drain()
        assertEquals(DisplayMode.Mirror, events.filterIsInstance<SessionEvent.DisplayModeConfirmed>().last().mode)
    }

    @Test
    fun aClosedLinkDeliversNothingMore() {
        connect()
        val before = events.size
        session.disconnect()
        drain()
        mac.link.send("""{"type":"ping","t":1}""".toByteArray())
        drain()
        assertTrue(events.drop(before).none { it is SessionEvent.Admitted })
    }

    private fun tile(id: String, kind: DemoWindowKind, x: Double) = buildJsonObject {
        put("id", id); put("host", DemoMac.PEER_ID)
        put("x", x); put("y", 0.0); put("w", if (x == 0.0) 0.5 else 0.25); put("h", 1.0)
        put("window", kind.windowID); put("gen", 1); put("follow", "window"); put("rotation", 0); put("fit", "fit")
    }
}
