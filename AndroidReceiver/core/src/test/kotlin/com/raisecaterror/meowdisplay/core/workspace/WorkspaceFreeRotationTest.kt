package com.raisecaterror.meowdisplay.core.workspace

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** Panes turn to any whole-degree angle (WorkspaceFreeRotationTests on the Mac). */
class WorkspaceFreeRotationTest {
    private val tile = WRect(0.0, 0.0, 1000.0, 1000.0)
    private val source = WSize(800.0, 400.0)

    @Test fun `angles wrap round and step to the next right angle`() {
        assertEquals(10, WRotation.of(370).degrees)
        assertEquals(330, WRotation.of(-30).degrees)
        assertEquals(45, WRotation.of(44.6).degrees)
        assertEquals(WRotation.None, WRotation.of(Double.NaN))
        assertEquals(WRotation.Quarter, WRotation.of(37).clockwise)
        assertEquals(WRotation.None, WRotation.ThreeQuarter.clockwise)
        assertEquals(WRotation.None, WRotation.None.turned(4.0, snap = true))
        assertEquals(4, WRotation.None.turned(4.0, snap = false).degrees)
        assertEquals(353, WRotation.Quarter.turned(-97.0, snap = true).degrees)
        assertEquals(WRotation.Quarter, WRotation.of(80).turned(7.0, snap = true))
    }

    @Test fun `an angled pane maps both ways and its empty corners take no input`() {
        val t = TileTransform(tile, source, WRotation.of(30), WFit.Fit)
        val box = t.rotatedSource
        assertEquals(800 * cos(PI / 6) + 400 * sin(PI / 6), box.width, 1e-9)
        assertEquals(1000 / box.width, t.scale, 1e-9)
        for (p in listOf(WPoint(1.0, 1.0), WPoint(799.0, 1.0), WPoint(123.0, 321.0), WPoint(400.0, 200.0))) {
            val back = t.sourcePoint(t.canvasPoint(p))
            assertNotNull("$p", back)
            assertEquals(p.x, back!!.x, 1e-6); assertEquals(p.y, back.y, 1e-6)
        }
        val c = t.contentRect
        assertNull("the box's corner shows no window", t.sourcePoint(WPoint(c.x + 1, c.y + 1)))
    }

    @Test fun `right angles are unchanged`() {
        val t = TileTransform(tile, source, WRotation.Quarter, WFit.Fit)
        assertEquals(WSize(400.0, 800.0), t.rotatedSource)
        assertEquals(WPoint(380.0, 10.0), t.rotated(WPoint(10.0, 20.0)))
        assertEquals(WPoint(10.0, 20.0), t.unrotated(WPoint(380.0, 10.0)))
    }

    @Test fun `a twist keeps the window point under the fingers`() {
        val size = WSize(1000.0, 1000.0)
        val from = WPoint(0.3, 0.6); val to = WPoint(0.45, 0.4)
        val t0 = TileTransform(tile, source, WRotation.None, WFit.Fit)
        val anchor = t0.unclampedSourcePoint(WPoint(300.0, 600.0))!!
        val (rotation, zoom) = WZoom.turned(null, WRotation.None, 37.0, true, size, source, WFit.Fit, 1.5, from, to)
        assertEquals(37, rotation.degrees)
        val t1 = TileTransform(tile, source, rotation, WFit.Fit, zoom!!)
        val q = t1.canvasPoint(anchor)
        assertEquals(450.0, q.x, 1e-6); assertEquals(400.0, q.y, 1e-6)
        assertEquals(t0.scale * 1.5, t1.scale, 1e-9)
        val (_, plain) = WZoom.turned(null, WRotation.None, 0.0, true, size, source, WFit.Fit, 1.5, from, to)
        val pinched = WZoom.pinched(null, size, source, WRotation.None, WFit.Fit, 1.5, from, to)!!
        assertEquals(pinched.scale, plain!!.scale, 1e-9)
        assertEquals(pinched.centerX, plain.centerX, 1e-9)
        assertEquals(pinched.centerY, plain.centerY, 1e-9)
    }

    @Test fun `the preview turns the picture like the Mac will`() {
        val canvas = WSize(2000.0, 1000.0)
        val t0 = TileTransform(tile, source, WRotation.None, WFit.Fit)
        val t1 = TileTransform(tile, source, WRotation.of(50), WFit.Fit, WPaneZoom.of(2.0, 0.4, 0.55))
        val p = WZoomPreview.between("a", WRect(0.0, 0.0, 0.5, 1.0), t0, t1, canvas)!!
        for (s in listOf(WPoint(100.0, 50.0), WPoint(700.0, 390.0))) {
            val a = t0.canvasPoint(s); val b = t1.canvasPoint(s)
            val moved = p.apply(WPoint(a.x / 2000, a.y / 1000))
            assertEquals(b.x / 2000, moved.x, 1e-9); assertEquals(b.y / 1000, moved.y, 1e-9)
        }
        assertNotEquals(0.0, p.shearB)
        assertTrue(p.drawnSource != null)
    }

    @Test fun `any whole-degree turn is saved and read back`() {
        val l = WLayout.preset(WPreset.Single, listOf(WTile("t", WSource("m", 1), rotation = WRotation.of(33))))
        val back = WLayoutRecord.decode(WLayoutRecord.encode(l))
        assertEquals(33, back?.tiles?.get("t")?.rotation?.degrees)
    }
}
