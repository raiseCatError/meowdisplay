package com.raisecaterror.meowdisplay.core.controls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Stage Peek's rules (MacTests/StagePeekTests): hold to open, scrub only browses, lift never selects, a tap on any visible card selects exactly that window. */
class StagePeekRulesTest {
    private val ids = listOf(101L, 102L, 103L, 104L, 105L, 106L)
    private val phone = CGRect(0.0, 47.0, 393.0, 771.0)
    private val tick = StagePeekEffect.Haptic(StagePeekHaptic.Tick)
    private val select = StagePeekEffect.Haptic(StagePeekHaptic.Select)

    private fun machine(current: Long? = 103): StagePeekMachine = StagePeekMachine().also { it.naturalScrolling = false; it.setItems(ids, current) }

    private fun pt(x: Double, y: Double) = CGPoint(x, y)

    /** Holds on the left strip until Stage Peek opens. */
    private fun opened(m: StagePeekMachine, at: CGPoint = pt(8.0, 430.0)): List<StagePeekEffect> {
        assertTrue(m.touchBegan(1, at, 0.0, onStrip = true))
        assertEquals("not before the hold delay", emptyList<StagePeekEffect>(), m.poll(StagePeekConfig.holdDelay - 0.01))
        return m.poll(StagePeekConfig.holdDelay)
    }

    private fun cards(m: StagePeekMachine) =
        StagePeekLayout.cards(ids.map { 1.5 }, m.position, m.expansion, StagePeekEdge.Left, phone, isPad = false, reduceMotion = false)

    private fun cardAt(m: StagePeekMachine): (CGPoint) -> Int? { val c = cards(m); return { StagePeekLayout.hit(it, c) } }

    @Test
    fun edgeHoldOpensWithOneActivationHapticOnTheCurrentWindow() {
        val m = machine()
        assertEquals(listOf(StagePeekEffect.Opened, StagePeekEffect.Haptic(StagePeekHaptic.Activate)), opened(m))
        assertEquals(StagePeekMachine.Phase.Scrubbing, m.phase)
        assertEquals("starts on the window shown now", 103L, m.highlightedID)
        assertEquals("opens once", emptyList<StagePeekEffect>(), m.poll(1.0))
    }

    @Test
    fun touchesOffTheStripAndAnEmptyCatalogNeverOpen() {
        val m = machine()
        assertFalse(m.touchBegan(1, pt(200.0, 400.0), 0.0, onStrip = false))
        assertEquals(StagePeekMachine.Phase.Closed, m.phase)
        assertFalse(StagePeekMachine().touchBegan(1, pt(8.0, 400.0), 0.0, onStrip = true))
    }

    @Test
    fun anInwardFlickFromTheEdgeOpensAndNeverReachesTheMac() {
        val m = machine()
        assertTrue("owned: never forwarded", m.touchBegan(1, pt(8.0, 400.0), 0.0, onStrip = true))
        assertEquals(listOf(StagePeekEffect.Opened, StagePeekEffect.Haptic(StagePeekHaptic.Activate)), m.touchMoved(1, pt(40.0, 400.0), 0.1, StagePeekEdge.Left))
        assertEquals(StagePeekMachine.Phase.Open, m.phase)
        assertEquals("lifting never selects", emptyList<StagePeekEffect>(), m.touchEnded(1, pt(60.0, 400.0), 0.2) { 0 })
        assertEquals(StagePeekMachine.Phase.Open, m.phase)
    }

    @Test
    fun aVerticalSwipeOnTheEdgeOpensNothing() {
        val m = machine()
        m.touchBegan(1, pt(8.0, 400.0), 0.0, onStrip = true)
        assertEquals(emptyList<StagePeekEffect>(), m.touchMoved(1, pt(10.0, 460.0), 0.1, StagePeekEdge.Left))
        assertEquals(StagePeekMachine.Phase.Closed, m.phase)
    }

    @Test
    fun naturalScrollingSwipeUpRevealsTheWindowsBelow() {
        val m = machine().also { it.naturalScrolling = true }
        m.openDirectly()
        m.touchBegan(2, pt(120.0, 500.0), 1.0, onStrip = false)
        m.touchMoved(2, pt(120.0, 500.0 - StagePeekConfig.scrubPitch * 2), 1.2, StagePeekEdge.Left)
        assertEquals("swipe up two windows: the highlight moves down the stack", 105L, m.highlightedID)
    }

    @Test
    fun aFlickWhileOpenExpandsThenCompacts() {
        val m = machine()
        m.openDirectly()
        m.touchBegan(2, pt(120.0, 500.0), 1.0, onStrip = false)
        assertEquals(listOf(select), m.touchMoved(2, pt(200.0, 505.0), 1.1, StagePeekEdge.Left))
        assertTrue(m.expanded)
        m.touchEnded(2, pt(200.0, 505.0), 1.2) { null }
        m.touchBegan(3, pt(200.0, 500.0), 2.0, onStrip = false)
        assertEquals(listOf(select), m.touchMoved(3, pt(120.0, 500.0), 2.1, StagePeekEdge.Left))
        assertFalse(m.expanded)
        assertEquals(StagePeekMachine.Phase.Open, m.phase)
    }

    @Test
    fun aTapOnTheEdgeBarOpens() {
        val m = machine()
        m.touchBegan(1, pt(8.0, 400.0), 0.0, onStrip = true)
        assertEquals(listOf(StagePeekEffect.Opened, StagePeekEffect.Haptic(StagePeekHaptic.Activate)), m.touchEnded(1, pt(8.0, 400.0), 0.1) { 0 })
        assertEquals(StagePeekMachine.Phase.Open, m.phase)
    }

    @Test
    fun scrubChangesOnlyTheHighlightWithOneTickPerChange() {
        val m = machine()
        opened(m)
        val effects = mutableListOf<StagePeekEffect>()
        effects += m.touchMoved(1, pt(8.0, 460.0), 0.4, StagePeekEdge.Left)
        assertEquals(104L, m.highlightedID)
        effects += m.touchMoved(1, pt(8.0, 470.0), 0.45, StagePeekEdge.Left)
        assertEquals("same window: no tick", 104L, m.highlightedID)
        effects += m.touchMoved(1, pt(8.0, 512.0), 0.5, StagePeekEdge.Left)
        assertEquals(105L, m.highlightedID)
        assertEquals(listOf(tick, tick), effects)
    }

    @Test
    fun fastScrubTicksAreRateLimitedButTheHighlightKeepsUp() {
        val m = machine(current = 101)
        opened(m)
        var ticks = 0
        for (step in 1..5) { // five windows in 20 ms
            ticks += m.touchMoved(1, pt(8.0, 430.0 + step * 52.0), 0.4 + step * 0.004, StagePeekEdge.Left).count { it == tick }
        }
        assertEquals(106L, m.highlightedID)
        assertEquals(1, ticks)
    }

    @Test
    fun overrunPlaysOneBoundaryHapticPerExcursion() {
        val m = machine(current = 101)
        opened(m)
        val boundary = StagePeekEffect.Haptic(StagePeekHaptic.Boundary)
        val effects = m.touchMoved(1, pt(8.0, 400.0), 0.4, StagePeekEdge.Left) + m.touchMoved(1, pt(8.0, 370.0), 0.5, StagePeekEdge.Left)
        assertEquals(listOf(boundary), effects)
        assertTrue("rubber band", m.position > -StagePeekConfig.maxOverrun - 1e-9)
        assertEquals(101L, m.highlightedID)
        m.touchMoved(1, pt(8.0, 430.0), 0.6, StagePeekEdge.Left)
        assertEquals(listOf(boundary), m.touchMoved(1, pt(8.0, 390.0), 0.7, StagePeekEdge.Left))
    }

    @Test
    fun liftNeverSelectsAndStagePeekStaysOpen() {
        val m = machine()
        opened(m)
        m.touchMoved(1, pt(8.0, 534.0), 0.5, StagePeekEdge.Left)
        assertEquals(emptyList<StagePeekEffect>(), m.touchEnded(1, pt(8.0, 534.0), 0.6, cardAt(m)))
        assertEquals(StagePeekMachine.Phase.Open, m.phase)
        assertEquals(105L, m.highlightedID)
        assertEquals("settles on the highlighted window, no jump", 4.0, m.position, 0.0)
        assertEquals("no selection when time passes either", emptyList<StagePeekEffect>(), m.poll(5.0))
    }

    @Test
    fun tapOnTheHighlightedCardSelectsIt() {
        val m = machine()
        opened(m)
        m.touchEnded(1, pt(8.0, 430.0), 0.5, cardAt(m))
        val focus = cards(m).first { it.highlighted }
        assertTrue(m.touchBegan(2, focus.center, 1.0, onStrip = false))
        assertEquals(listOf(select, StagePeekEffect.Select(103)), m.touchEnded(2, focus.center, 1.1, cardAt(m)))
        assertEquals(StagePeekMachine.Phase.Closed, m.phase)
    }

    @Test
    fun tapOnANeighbourSelectsExactlyThatWindow() {
        val m = machine()
        opened(m)
        m.touchEnded(1, pt(8.0, 430.0), 0.5, cardAt(m))
        val all = cards(m)
        val focus = all.first { it.highlighted }
        val below = all.first { it.index == focus.index + 1 }
        val above = all.first { it.index == focus.index - 1 }
        // Points on the neighbours' visible parts, outside the front card.
        val belowPoint = pt(below.center.x, below.center.y + below.size.height * 0.4)
        val abovePoint = pt(above.center.x, above.center.y - above.size.height * 0.4)
        assertEquals(focus.index + 1, StagePeekLayout.hit(belowPoint, all))
        assertEquals(focus.index - 1, StagePeekLayout.hit(abovePoint, all))
        m.touchBegan(2, belowPoint, 1.0, onStrip = false)
        assertEquals(listOf(select, StagePeekEffect.Select(104)), m.touchEnded(2, belowPoint, 1.1, cardAt(m)))
    }

    @Test
    fun whereCardsOverlapTheFrontOneWins() {
        // Cards overlap in the expanded (Cover Flow) stack; compact Dock cards never do.
        val all = StagePeekLayout.cards(listOf(1.5, 1.5, 1.5), 1.0, 1.0, StagePeekEdge.Left, phone, isPad = false, reduceMotion = false)
        val focus = all.first { it.highlighted }
        val below = all.first { it.index == 2 }
        val shared = pt(focus.center.x, (focus.center.y + focus.size.height / 2 + below.center.y - below.size.height / 2) / 2)
        assertTrue("the cards overlap", focus.center.y + focus.size.height / 2 > below.center.y - below.size.height / 2)
        assertEquals(1, StagePeekLayout.hit(shared, all))
    }

    @Test
    fun tapOutsideDismissesWithoutSwitching() {
        val m = machine()
        opened(m)
        m.touchEnded(1, pt(8.0, 430.0), 0.5, cardAt(m))
        val outside = pt(360.0, 200.0)
        assertNull(StagePeekLayout.hit(outside, cards(m)))
        assertTrue("owned: never a click on the Mac", m.touchBegan(2, outside, 1.0, onStrip = false))
        assertEquals(listOf<StagePeekEffect>(StagePeekEffect.Dismissed), m.touchEnded(2, outside, 1.1, cardAt(m)))
        assertEquals(StagePeekMachine.Phase.Closed, m.phase)
    }

    @Test
    fun aHeldPressWhileOpenIsNotATapAndDraggingScrubsAgain() {
        val m = machine()
        opened(m)
        m.touchEnded(1, pt(8.0, 430.0), 0.5, cardAt(m))
        val focus = cards(m).first { it.highlighted }
        m.touchBegan(2, focus.center, 1.0, onStrip = false)
        assertEquals(emptyList<StagePeekEffect>(), m.touchEnded(2, focus.center, 2.0, cardAt(m)))
        assertEquals(StagePeekMachine.Phase.Open, m.phase)
        m.touchBegan(3, focus.center, 3.0, onStrip = false)
        m.touchMoved(3, pt(focus.center.x, focus.center.y - 60), 3.1, StagePeekEdge.Left)
        assertEquals(102L, m.highlightedID)
        assertEquals(emptyList<StagePeekEffect>(), m.touchEnded(3, pt(focus.center.x, focus.center.y - 60), 3.2, cardAt(m)))
        assertEquals(StagePeekMachine.Phase.Open, m.phase)
    }

    @Test
    fun inwardDragExpandsOnlyPastTheDeliberateThresholdAndKeepsOnlyWhenDeep() {
        val m = machine()
        opened(m)
        m.touchMoved(1, pt(8.0 + StagePeekConfig.expandStart - 1, 430.0), 0.4, StagePeekEdge.Left)
        assertEquals("a small inward wobble does nothing", 0.0, m.expansion, 0.0)
        m.touchMoved(1, pt(8.0 + (StagePeekConfig.expandStart + StagePeekConfig.expandFull) / 2, 430.0), 0.5, StagePeekEdge.Left)
        assertEquals("progressive, following the finger", 0.5, m.expansion, 1e-9)
        assertEquals("lift after expanding never selects", emptyList<StagePeekEffect>(), m.touchEnded(1, CGPoint.zero, 0.6) { 2 })
        assertFalse("under the keep share: springs back to compact", m.expanded)
        assertEquals(0.0, m.expansion, 0.0)

        val deep = machine()
        opened(deep)
        deep.touchMoved(1, pt(8.0 + StagePeekConfig.expandFull + 10, 470.0), 0.5, StagePeekEdge.Left)
        assertEquals(1.0, deep.expansion, 0.0)
        assertEquals(emptyList<StagePeekEffect>(), deep.touchEnded(1, CGPoint.zero, 0.6) { 2 })
        assertTrue(deep.expanded)
        assertEquals(StagePeekMachine.Phase.Open, deep.phase)
    }

    @Test
    fun rightEdgeExpandsLeftward() {
        val m = machine()
        m.touchBegan(1, pt(385.0, 430.0), 0.0, onStrip = true)
        m.poll(1.0)
        m.touchMoved(1, pt(385.0 - StagePeekConfig.expandFull, 430.0), 1.1, StagePeekEdge.Right)
        assertEquals(1.0, m.expansion, 0.0)
        m.touchMoved(1, pt(485.0, 430.0), 1.2, StagePeekEdge.Right)
        assertEquals("moving toward the edge never expands", 0.0, m.expansion, 0.0)
    }

    @Test
    fun cancellationAndFoldNeverSelect() {
        val m = machine()
        opened(m)
        m.touchMoved(1, pt(8.0, 530.0), 0.5, StagePeekEdge.Left)
        m.touchCancelled(1)
        assertEquals(StagePeekMachine.Phase.Open, m.phase)
        m.cancelAll()
        assertEquals(StagePeekMachine.Phase.Closed, m.phase)
        assertEquals(emptyList<StagePeekEffect>(), m.dismiss())
    }

    @Test
    fun aCatalogReorderWhileScrubbingKeepsTheHighlightedWindow() {
        val m = machine()
        opened(m)
        m.touchMoved(1, pt(8.0, 482.0), 0.5, StagePeekEdge.Left)
        assertEquals(104L, m.highlightedID)
        m.setItems(listOf(106, 104, 101, 103), 103)
        assertEquals("same window, new index", 104L, m.highlightedID)
        m.setItems(listOf(106, 101), 103)
        assertNotNull("a closed window: clamped onto a listed one, no crash", m.highlightedID)
        assertTrue(m.highlightedID in listOf(106L, 101L))
        m.setItems(emptyList(), null)
        assertEquals("nothing left: closes without selecting", StagePeekMachine.Phase.Closed, m.phase)
    }

    @Test
    fun highlightedCardIsStraightLargestAndInFrontAndReduceMotionRemovesTheTilt() {
        for ((safe, pad) in listOf(phone to false, CGRect(59.0, 0.0, 734.0, 372.0) to false, CGRect(0.0, 24.0, 1032.0, 1342.0) to true)) {
            val all = StagePeekLayout.cards(ids.map { 1.6 }, 2.0, 0.0, StagePeekEdge.Left, safe, pad, reduceMotion = false)
            val focus = all.first { it.highlighted }
            assertTrue(focus.tilt == 0.0)
            assertEquals("drawn last: in front", focus, all.last())
            // Compact is Dock magnification: smaller, upright, edge-aligned, never overlapping.
            for (c in all.filter { it != focus }) {
                assertTrue(c.size.width < focus.size.width)
                assertTrue("compact cards stay upright", c.tilt == 0.0)
                assertEquals("left-aligned to the edge", safe.minX + 16, c.center.x - c.size.width / 2, 0.5)
            }
            val byIndex = all.sortedBy { it.index }
            byIndex.zipWithNext().forEach { (a, b) ->
                assertTrue("no overlap", a.center.y + a.size.height / 2 <= b.center.y - b.size.height / 2 + 0.5)
            }
            assertTrue("the highlighted card pops out", focus.center.x - focus.size.width / 2 > safe.minX + 16)
            assertTrue("compact: hugs the edge, the Mac stays visible", focus.center.x + focus.size.width / 2 < safe.midX + 1)
            // Expanded is the layered Cover Flow stack.
            val flow = StagePeekLayout.cards(ids.map { 1.6 }, 2.0, 1.0, StagePeekEdge.Left, safe, pad, reduceMotion = false)
            val flowFocus = flow.first { it.highlighted }
            assertTrue(flowFocus.tilt == 0.0)
            for (c in flow.filter { it != flowFocus }) {
                assertTrue(c.tilt != 0.0)
                assertEquals("cards above tip their top away", (c.index < flowFocus.index), (c.tilt > 0))
            }
        }
        val still = StagePeekLayout.cards(listOf(1.0, 1.0, 1.0), 1.0, 0.0, StagePeekEdge.Right, phone, isPad = false, reduceMotion = true)
        assertTrue(still.all { it.tilt == 0.0 })
        assertTrue("right edge", still.first { it.highlighted }.center.x > phone.midX)
    }

    @Test
    fun stripStaysInsideTheSafeAreaAvoidsControlsAndHasNoRoomNoStrip() {
        for (edge in StagePeekEdge.entries) {
            val s = StagePeekLayout.strip(edge, phone)!!
            assertTrue(phone.contains(s))
            assertTrue(s.height <= StagePeekConfig.edgeStripMaxHeight)
        }
        val landscape = CGRect(59.0, 0.0, 734.0, 372.0)
        val tray = CGRect(59.0, 100.0, 52.0, 170.0) // controls on the left, mid-height
        val s = StagePeekLayout.strip(StagePeekEdge.Left, landscape, listOf(tray))!!
        assertFalse(s.intersects(tray))
        assertTrue(s.height >= 60)
        assertNull("no room: no strip", StagePeekLayout.strip(StagePeekEdge.Left, landscape, listOf(CGRect(59.0, 0.0, 40.0, 372.0))))
        assertEquals("the other edge is unaffected", StagePeekConfig.edgeStripMaxHeight, StagePeekLayout.strip(StagePeekEdge.Right, landscape, listOf(tray))?.height)
    }

    @Test
    fun accessibilityOpenStepAndSelect() {
        val m = machine()
        assertEquals(listOf(StagePeekEffect.Opened, StagePeekEffect.Haptic(StagePeekHaptic.Activate)), m.openDirectly())
        assertEquals(StagePeekMachine.Phase.Open, m.phase)
        assertEquals(listOf(tick), m.step(1))
        assertEquals(104L, m.highlightedID)
        assertEquals(listOf(tick), m.step(10))
        assertEquals(106L, m.highlightedID)
        assertEquals(listOf(StagePeekEffect.Haptic(StagePeekHaptic.Boundary)), m.step(1))
        assertEquals(listOf(select, StagePeekEffect.Select(106)), m.selectHighlighted())
        assertEquals(StagePeekMachine.Phase.Closed, m.phase)
        assertEquals("nothing while closed", emptyList<StagePeekEffect>(), m.select(1))
        m.openDirectly()
        assertEquals(listOf(select, StagePeekEffect.Select(101)), m.select(0))
        assertEquals(StagePeekMachine.Phase.Closed, m.phase)
    }

    @Test
    fun fullDesktopIsTheFirstCardAndNeverTheStartingOne() {
        val m = StagePeekMachine()
        m.setItems(listOf(StagePeekMachine.fullDesktopID) + ids, 103)
        assertEquals(listOf(StagePeekEffect.Opened, StagePeekEffect.Haptic(StagePeekHaptic.Activate)), opened(m))
        assertEquals("opens on the window shown now, not on Full Desktop", 103L, m.highlightedID)
        m.touchEnded(1, pt(8.0, 430.0), 0.5) { null }
        assertEquals(listOf(tick), m.step(-10))
        assertEquals("Full Desktop is at the top", StagePeekMachine.fullDesktopID, m.highlightedID)
        assertEquals(listOf(select, StagePeekEffect.Select(StagePeekMachine.fullDesktopID)), m.selectHighlighted())
        val fresh = StagePeekMachine()
        fresh.setItems(listOf(StagePeekMachine.fullDesktopID) + ids, null)
        assertEquals(listOf(StagePeekEffect.Opened, StagePeekEffect.Haptic(StagePeekHaptic.Activate)), fresh.openDirectly())
        assertEquals("no tile yet: starts at the top", StagePeekMachine.fullDesktopID, fresh.highlightedID)
    }
}
