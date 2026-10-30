package com.raisecaterror.meowdisplay.core.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Tabs in a pane (WindowWorkspaceTests.testEachTabKeepsItsOwnViewAndTabsReorder). */
class WorkspaceTabsTest {
    private val a = WSource("m", 1); private val b = WSource("m", 2); private val c = WSource("m", 3)
    private val z = WPaneZoom(2.0, 0.25, 0.75)

    @Test fun `each tab keeps its own view through a save and tabs reorder`() {
        var l = WLayout.preset(WPreset.Single, listOf(WTile("t", a)))
        l = l.rotating("t").settingFit(WFit.Fill, "t").zooming("t", z)
        l = l.addingTab(b, "t")
        assertEquals("a new tab starts at the default view", WRotation.None, l.tiles["t"]?.rotation)
        assertEquals(WFit.Fit, l.tiles["t"]?.fit)
        assertNull(l.tiles["t"]?.zoom)
        l = l.addingTab(c, "t").switchingTab("t", 1)
        val saved = WLayoutRecord.decode(WLayoutRecord.encode(l))!!
        for (layout in listOf(l, saved)) {
            val back = layout.switchingTab("t", 0)
            assertEquals("the first tab's view comes back", WRotation.Quarter, back.tiles["t"]?.rotation)
            assertEquals(WFit.Fill, back.tiles["t"]?.fit)
            assertEquals(z, back.tiles["t"]?.zoom)
            assertNull("the other tab kept its own (default) view", back.switchingTab("t", 1).tiles["t"]?.zoom)
        }
        val moved = l.movingTab("t", 0, 2)
        assertEquals(listOf(b, c, a), moved.tiles["t"]?.tabs)
        assertEquals(b, moved.tiles["t"]?.source)
        assertEquals(WRotation.Quarter, moved.switchingTab("t", 2).tiles["t"]?.rotation)
        assertNull(l.removingTab("t", 0).tiles["t"]?.tabViews?.get(a.tabKey))
        val mids = listOf(50.0, 150.0, 250.0)
        assertEquals(1, WTabOrder.index(0, 200.0, mids))
        assertEquals(2, WTabOrder.index(0, 300.0, mids))
        assertEquals(0, WTabOrder.index(2, 10.0, mids))
        assertEquals("dropped on itself: unchanged", 1, WTabOrder.index(1, 160.0, mids))
    }
}
