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
}
