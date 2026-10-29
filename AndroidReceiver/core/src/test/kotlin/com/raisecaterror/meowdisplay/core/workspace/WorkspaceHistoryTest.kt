package com.raisecaterror.meowdisplay.core.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class WorkspaceHistoryTest {
    private fun layout(n: Int) = WLayout.preset(WPreset.Grid2x2, (0 until n).map { WTile("t$it") })

    @Test fun `a divider drag is one undo step`() {
        val history = WHistory()
        val a = layout(4)
        val b = a.rotating("t0"); val c = b.rotating("t1"); val d = c.rotating("t2")
        history.record(a)
        history.beginGroup()
        history.record(b); history.record(c)
        history.beginGroup() // repeated begins stay in the same group
        history.record(d)
        history.endGroup()
        assertEquals(b, history.undo())
        assertEquals(a, history.undo())
        assertNull(history.undo())
    }

    @Test fun `after a group ends every change records again`() {
        val history = WHistory()
        val a = layout(2); val b = a.rotating("t0"); val c = b.rotating("t1")
        history.beginGroup(); history.record(a); history.endGroup()
        history.record(b); history.record(c)
        assertEquals(c, history.undo())
        assertEquals(b, history.undo())
        assertEquals(a, history.undo())
    }

    @Test fun `redo brings back what was undone until a new change`() {
        val history = WHistory()
        val a = layout(4)
        val b = a.swapping("t0", "t1")
        val c = b.swapping("t2", "t3")
        history.record(a); history.record(b)
        assertEquals(b, history.undo(c))
        assertEquals(a, history.undo(b))
        assertEquals(b, history.redo(a))
        assertEquals(c, history.redo(b))
        assertEquals(false, history.canRedo)
        assertEquals(b, history.undo(c))
        history.record(b)
        assertEquals(false, history.canRedo)
    }

    @Test fun `a saved layout finds today's windows of the same app`() {
        val zed = WSource("mac-a", 10, bundleID = "dev.zed.Zed")
        val chrome = WSource("mac-a", 11, bundleID = "com.google.Chrome")
        val desktop = WSource("mac-a", WSource.displayKey(1))
        val l = WLayout.preset(WPreset.ThreeColumns, listOf(WTile("t0", zed), WTile("t1", chrome), WTile("t2", desktop)))
        val rebound = l.rebinding(listOf(40L to "com.apple.Safari", 41L to "dev.zed.Zed", 11L to "com.google.Chrome"))
        assertEquals(41L, rebound.tiles["t0"]?.source?.windowID)
        assertEquals(11L, rebound.tiles["t1"]?.source?.windowID)
        assertEquals(desktop, rebound.tiles["t2"]?.source)
        assertEquals(10L, l.rebinding(listOf(40L to "com.apple.Safari")).tiles["t0"]?.source?.windowID)
        val back = WSavedLayout.decodeList(WSavedLayout.encodeList(listOf(WSavedLayout("s1", "Coding", l))))
        assertEquals("Coding", back.single().name)
        assertEquals(3, back.single().layout.tiles.size)
        assertEquals(emptyList<WSavedLayout>(), WSavedLayout.decodeList("not json"))
    }
}
