package com.raisecaterror.meowdisplay.core.controls

import com.raisecaterror.meowdisplay.core.controls.PointerTouchSample.Phase
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.hypot

class PointerGestureEngineTests {
    private fun sample(
        id: Int, phase: Phase, view: CGPoint,
        norm: CGPoint? = CGPoint(0.5, 0.5), t: Double,
    ) = PointerTouchSample(id = id, phase = phase, viewPoint = view, normalized = norm, time = t)

    private fun isMoveAbsolute(command: PointerCommand) = command is PointerCommand.MoveAbsolute

    private fun isMouseDown(command: PointerCommand) = command is PointerCommand.MouseDown

    private fun <T> unwrap(value: T?): T = requireNotNull(value)

    /** Settles an already-begun touch `id` into `AbsolutePointer` via movement evidence, well past `dragSlop`. */
    private fun settleAsAnchor(
        engine: PointerGestureEngine, id: Int, to: CGPoint, norm: CGPoint, t: Double,
    ): List<PointerCommand> = engine.handle(sample(id, Phase.Moved, view = to, norm = norm, t = t))


    @Test
    fun testOnlyDirectTouchSeedsAnAbsoluteScrollTarget() {
        assertTrue(PointerInputMode.Direct.seedsAbsoluteScrollTarget)
        assertFalse(PointerInputMode.Trackpad.seedsAbsoluteScrollTarget)
    }


    // MARK: - First-touch arbitration

    @Test
    fun testFirstTouchEmitsNothingUntilCommitted() {
        val engine = PointerGestureEngine()
        val down = engine.handle(sample(1, Phase.Began, view = CGPoint(100.0, 100.0), norm = CGPoint(0.2, 0.2), t = 0.0))
        assertEquals(emptyList<PointerCommand>(), down)   // withheld — still arbitrating
        assertEquals(PointerEngineMode.FirstTouchPending, engine.mode)
    }


    @Test
    fun testQuickSecondTouchFormsFreshChordWithNoAbsoluteMoveEver() {
        val engine = PointerGestureEngine()
        val down1 = engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), norm = CGPoint(0.2, 0.2), t = 0.0))
        assertEquals(emptyList<PointerCommand>(), down1)
        // Second finger lands promptly, well inside the arbitration window.
        val down2 = engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), norm = CGPoint(0.3, 0.2), t = 0.02))
        assertEquals(emptyList<PointerCommand>(), down2)   // CRITICAL: no moveAbsolute to finger 1's location, ever
        assertEquals(PointerEngineMode.TwoFingerPending, engine.mode)

        // Confirm nothing was silently queued while the fingers are still
        // down (nothing resolved yet — both are still on-screen).
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 5.0))
    }


    @Test
    fun testGenuineSingleFingerCommitsToAbsolutePointerViaMovement() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(100.0, 100.0), norm = CGPoint(0.2, 0.2), t = 0.0))
        // Movement well beyond dragSlop, inside the arbitration window —
        // commits immediately without waiting the window out.
        val moved = engine.handle(sample(1, Phase.Moved, view = CGPoint(150.0, 100.0), norm = CGPoint(0.4, 0.2), t = 0.01))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.4, 0.2)), moved)
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
    }


    @Test
    fun testGenuineSingleFingerCommitsToAbsolutePointerViaWindowExpiry() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(100.0, 100.0), norm = CGPoint(0.2, 0.2), t = 0.0))
        // Held still — no second finger, no movement.
        val stillArbitrating = engine.poll(now = PointerGestureConfig.firstTouchArbitrationWindow - 0.01)
        assertEquals(emptyList<PointerCommand>(), stillArbitrating)
        assertEquals(PointerEngineMode.FirstTouchPending, engine.mode)

        val committed = engine.poll(now = PointerGestureConfig.firstTouchArbitrationWindow + 0.005)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2)), committed)
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
    }


    @Test
    fun testPlainMovementNeverImpliesMouseDown() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(0.0, 0.0), t = 0.0))
        // Move well beyond drag slop, then release — no click, no drag.
        val moved = engine.handle(sample(1, Phase.Moved, view = CGPoint(200.0, 200.0), t = 0.05))
        assertFalse(moved.any { isMouseDown(it) })
        val up = engine.handle(sample(1, Phase.Ended, view = CGPoint(200.0, 200.0), t = 0.1))
        assertEquals(emptyList<PointerCommand>(), up)
        assertEquals(PointerEngineMode.Idle, engine.mode)
    }


    // MARK: - Left click / tap counting

    @Test
    fun testSingleTapClicksOnceAfterChainWindowExpires() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), norm = CGPoint(0.3, 0.3), t = 0.0))
        val up = engine.handle(sample(1, Phase.Ended, view = CGPoint(11.0, 10.0), norm = CGPoint(0.31, 0.3), t = 0.02))
        // The tap's own resolution moves the cursor there exactly once
        // (safe — no second finger ever joined) so the buffered click
        // lands at the right place.
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.31, 0.3)), up)
        assertEquals(PointerEngineMode.TapBuffered, engine.mode)
        val flushed = engine.poll(now = 0.02 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 1), PointerCommand.MouseUp(PointerButton.Left, 1)), flushed)
        assertEquals(PointerEngineMode.Idle, engine.mode)
    }


    @Test
    fun testDoubleTapProducesClickCountTwo() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(10.0, 10.0), t = 0.02))
        engine.handle(sample(2, Phase.Began, view = CGPoint(12.0, 11.0), t = 0.08))
        val up = engine.handle(sample(2, Phase.Ended, view = CGPoint(12.0, 11.0), t = 0.1))
        assertFalse(up.any { isMouseDown(it) })
        val flushed = engine.poll(now = 0.1 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 2), PointerCommand.MouseUp(PointerButton.Left, 2)), flushed)
    }


    @Test
    fun testTripleTapProducesClickCountThree() {
        val engine = PointerGestureEngine()
        var t: Double = 0.0
        for (id in 1..3) {
            engine.handle(sample(id, Phase.Began, view = CGPoint(10.0, 10.0), t = t))
            engine.handle(sample(id, Phase.Ended, view = CGPoint(10.0, 10.0), t = t + 0.02))
            t += 0.08
        }
        val flushed = engine.poll(now = t + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 3), PointerCommand.MouseUp(PointerButton.Left, 3)), flushed)
    }


    @Test
    fun testMovementBeyondTapThresholdEmitsNoClick() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(0.0, 0.0), t = 0.0))
        engine.handle(sample(1, Phase.Moved, view = CGPoint(40.0, 0.0), t = 0.02))
        val up = engine.handle(sample(1, Phase.Ended, view = CGPoint(40.0, 0.0), t = 0.04))
        assertEquals(emptyList<PointerCommand>(), up)
        val flushed = engine.poll(now = 1.0)
        assertEquals(emptyList<PointerCommand>(), flushed)   // nothing buffered — moved too far to be a tap
    }


    // MARK: - Left drag (tap-then-hold)

    @Test
    fun testTapThenHeldTouchProducesOnlyDragNoStrayClick() {
        val engine = PointerGestureEngine()
        // Tap 1.
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(10.0, 10.0), t = 0.02))
        assertEquals(PointerEngineMode.TapBuffered, engine.mode)

        // A second touchdown arrives quickly and is held (not released).
        val down2 = engine.handle(sample(2, Phase.Began, view = CGPoint(11.0, 9.0), norm = CGPoint(0.3, 0.3), t = 0.1))
        assertEquals(emptyList<PointerCommand>(), down2)   // still arbitrating — nothing emitted yet
        assertFalse(down2.any { isMouseDown(it) })

        // Movement beyond drag slop commits the drag — exactly one
        // mouseDown, carrying the tap chain's count (1), no bare click.
        val moved = engine.handle(sample(2, Phase.Moved, view = CGPoint(40.0, 9.0), norm = CGPoint(0.5, 0.3), t = 0.15))
        assertTrue(moved.contains(PointerCommand.MouseDown(PointerButton.Left, 1)))
        assertEquals(PointerEngineMode.LeftDragHeld, engine.mode)
        // Pressed where the finger came down, then dragged to where it is now.
        assertEquals(
            listOf(PointerCommand.MoveAbsolute(0.3, 0.3), PointerCommand.MouseDown(PointerButton.Left, 1), PointerCommand.MoveAbsolute(0.5, 0.3)),
            moved,
        )

        val dragged = engine.handle(sample(2, Phase.Moved, view = CGPoint(60.0, 9.0), norm = CGPoint(0.6, 0.3), t = 0.2))
        assertFalse(dragged.any { isMouseDown(it) })

        val up = engine.handle(sample(2, Phase.Ended, view = CGPoint(60.0, 9.0), t = 0.25))
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Left, 0)), up)
        assertEquals(PointerEngineMode.Idle, engine.mode)

        // Flushing the (now-consumed) chain later must not double-fire.
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 10.0))
    }


    @Test
    fun testTapThenStationaryHoldStillCommitsDragViaHoldDelay() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(10.0, 10.0), t = 0.02))
        engine.handle(sample(2, Phase.Began, view = CGPoint(11.0, 9.0), t = 0.1))

        // Held with no movement at all — the hold-commit delay alone
        // should still start the drag (mirrors a real tap-and-hold with a
        // perfectly steady finger).
        val committed = engine.poll(now = 0.1 + PointerGestureConfig.holdCommitDelay + 0.01)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.5, 0.5), PointerCommand.MouseDown(PointerButton.Left, 1)), committed)
        assertEquals(PointerEngineMode.LeftDragHeld, engine.mode)
    }


    // MARK: - Precision / relative session

    @Test
    fun testAbsoluteToRelativeSessionTransition() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, norm = CGPoint(0.2, 0.2), t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(300.0, 0.0), norm = CGPoint(0.6, 0.2), t = 0.02)
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)

        val down2 = engine.handle(sample(2, Phase.Began, view = CGPoint(20.0, 20.0), t = 0.1))
        assertEquals(emptyList<PointerCommand>(), down2)   // no jump to finger 2's location
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)
    }


    @Test
    fun testOriginalAnchorCanNoLongerEmitAbsoluteMovementAfterRelativeTransition() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, norm = CGPoint(0.2, 0.2), t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(300.0, 0.0), norm = CGPoint(0.6, 0.2), t = 0.02)
        engine.handle(sample(2, Phase.Began, view = CGPoint(20.0, 20.0), t = 0.1))
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)

        // Finger 1 (the original anchor) moves — this is the regression:
        // it must NEVER snap the Mac cursor back underneath itself again.
        val anchorMoved = engine.handle(sample(1, Phase.Moved, view = CGPoint(305.0, 3.0), norm = CGPoint(0.61, 0.21), t = 0.12))
        assertFalse(anchorMoved.any { isMoveAbsolute(it) })
        assertEquals(listOf(PointerCommand.MoveRelative(5.0, 3.0)), anchorMoved)
    }


    @Test
    fun testBothRelativeFingersProduceDeltasWithoutSnapBack() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(300.0, 0.0), norm = CGPoint(0.6, 0.2), t = 0.02)
        engine.handle(sample(2, Phase.Began, view = CGPoint(20.0, 20.0), t = 0.1))

        val anchorMoved = engine.handle(sample(1, Phase.Moved, view = CGPoint(310.0, 5.0), t = 0.12))
        assertEquals(listOf(PointerCommand.MoveRelative(10.0, 5.0)), anchorMoved)

        val precisionMoved = engine.handle(sample(2, Phase.Moved, view = CGPoint(25.0, 24.0), t = 0.13))
        assertEquals(listOf(PointerCommand.MoveRelative(5.0, 4.0)), precisionMoved)

        // Alternating movement never re-jumps either finger's baseline.
        val anchorMovedAgain = engine.handle(sample(1, Phase.Moved, view = CGPoint(312.0, 5.0), t = 0.14))
        assertEquals(listOf(PointerCommand.MoveRelative(2.0, 0.0)), anchorMovedAgain)
    }


    @Test
    fun testRelativeFingerLiftAndRetouchResetsItsOwnBaseline() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(300.0, 0.0), norm = CGPoint(0.6, 0.2), t = 0.02)
        engine.handle(sample(2, Phase.Began, view = CGPoint(20.0, 20.0), t = 0.1))
        engine.handle(sample(2, Phase.Moved, view = CGPoint(30.0, 20.0), t = 0.12))
        // Held too long / moved too far by release to read as a tap.
        engine.handle(sample(2, Phase.Moved, view = CGPoint(60.0, 20.0), t = 0.2))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(60.0, 20.0), t = 0.9))
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)   // session continues (anchor still down)

        // Re-touch at a new location: origin resets there, not a jump —
        // and the anchor is still untouched/unaffected throughout.
        val down3 = engine.handle(sample(3, Phase.Began, view = CGPoint(200.0, 200.0), t = 0.95))
        assertEquals(emptyList<PointerCommand>(), down3)
        val moved3 = engine.handle(sample(3, Phase.Moved, view = CGPoint(210.0, 205.0), t = 0.97))
        assertEquals(listOf(PointerCommand.MoveRelative(10.0, 5.0)), moved3)
    }


    @Test
    fun testQuickLaterFingerTapClicksAtCurrentCursorPositionAfterChainWindow() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, norm = CGPoint(0.1, 0.1), t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.1), t = 0.02)
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)

        engine.handle(sample(2, Phase.Began, view = CGPoint(300.0, 300.0), t = 0.1))
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)
        val up = engine.handle(sample(2, Phase.Ended, view = CGPoint(301.0, 299.0), t = 0.12))
        // Withheld — might still become a chain/drag (same tap-chain
        // buffering the anchor's own solo click already uses).
        assertEquals(emptyList<PointerCommand>(), up)
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)   // anchor session continues
        assertEquals(PointerGestureConfig.tapChainWindow, engine.pollDelay(now = 0.12) ?: -1.0, 0.000_001)

        // Left click — carries no coordinates, so the caller sends it at
        // whatever the Mac's current cursor position already is.
        val flushed = engine.poll(now = 0.12 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 1), PointerCommand.MouseUp(PointerButton.Left, 1)), flushed)
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)
        assertNull(engine.pollDelay(now = 0.12 + PointerGestureConfig.tapChainWindow + 0.01))

        // A long, slow drift (many small per-frame moves, large total
        // displacement) must NOT still read as a tap on release — the tap
        // check uses total displacement from touchdown, not the last
        // frame's delta.
        engine.handle(sample(4, Phase.Began, view = CGPoint(0.0, 0.0), t = 0.2))
        for (i in 1..20) {
            engine.handle(sample(4, Phase.Moved, view = CGPoint(i.toDouble(), 0.0), t = 0.2 + i.toDouble() * 0.01))
        }
        val driftUp = engine.handle(sample(4, Phase.Ended, view = CGPoint(20.0, 0.0), t = 0.45))
        assertFalse(driftUp.any { isMouseDown(it) })
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 10.0))   // the drift never buffered a tap either
    }


    // MARK: - Relative-session left tap-chain / drag (GOAL: generalize to any participant)

    @Test
    fun testRelativeSecondaryFingerDoubleTapEmitsClickCountTwo() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 0.02)
        engine.handle(sample(2, Phase.Began, view = CGPoint(300.0, 300.0), t = 0.1))
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)

        val up1 = engine.handle(sample(2, Phase.Ended, view = CGPoint(301.0, 299.0), t = 0.12))
        assertEquals(emptyList<PointerCommand>(), up1)   // withheld — awaiting a possible continuation

        // A second touchdown near the first tap, soon after.
        val down2 = engine.handle(sample(3, Phase.Began, view = CGPoint(302.0, 300.0), t = 0.18))
        assertEquals(emptyList<PointerCommand>(), down2)
        val up2 = engine.handle(sample(3, Phase.Ended, view = CGPoint(302.0, 300.0), t = 0.2))
        assertEquals(emptyList<PointerCommand>(), up2)
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)   // anchor session never left

        val flushed = engine.poll(now = 0.2 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 2), PointerCommand.MouseUp(PointerButton.Left, 2)), flushed)
    }


    @Test
    fun testRelativeSecondaryFingerTripleTapReachesClickCountThree() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 0.02)
        var t: Double = 0.1
        for (id in 2..4) {
            engine.handle(sample(id, Phase.Began, view = CGPoint(300.0, 300.0), t = t))
            engine.handle(sample(id, Phase.Ended, view = CGPoint(300.0, 300.0), t = t + 0.02))
            t += 0.08
        }
        val flushed = engine.poll(now = t + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 3), PointerCommand.MouseUp(PointerButton.Left, 3)), flushed)
    }


    @Test
    fun testRelativeSecondaryFingerTapThenHeldEntersLeftDragWithNoStandaloneClick() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 0.02)
        engine.handle(sample(2, Phase.Began, view = CGPoint(300.0, 300.0), t = 0.1))
        val tapUp = engine.handle(sample(2, Phase.Ended, view = CGPoint(300.0, 300.0), t = 0.12))
        assertEquals(emptyList<PointerCommand>(), tapUp)

        // A second touchdown near the tap, held (not released quickly).
        val down3 = engine.handle(sample(3, Phase.Began, view = CGPoint(301.0, 300.0), t = 0.18))
        assertEquals(emptyList<PointerCommand>(), down3)
        assertFalse(down3.any { isMoveAbsolute(it) })   // never switches back to absolute

        val moved = engine.handle(sample(3, Phase.Moved, view = CGPoint(330.0, 300.0), t = 0.22))
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 1)), moved)   // no bare click, no move command
        assertFalse(moved.any { isMoveAbsolute(it) })

        // Further movement is relative, never absolute — this is the
        // regression under test (GOAL: "do not switch back to absolute").
        val dragged = engine.handle(sample(3, Phase.Moved, view = CGPoint(335.0, 302.0), t = 0.25))
        assertEquals(listOf(PointerCommand.MoveRelative(5.0, 2.0)), dragged)

        val up = engine.handle(sample(3, Phase.Ended, view = CGPoint(335.0, 302.0), t = 0.3))
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Left, 0)), up)
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)   // anchor session survives

        // The anchor itself is untouched throughout and can keep moving.
        val anchorMoved = engine.handle(sample(1, Phase.Moved, view = CGPoint(205.0, 3.0), t = 0.32))
        assertEquals(listOf(PointerCommand.MoveRelative(5.0, 3.0)), anchorMoved)

        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 10.0))   // no stray click left buffered
    }


    @Test
    fun testRelativeSecondaryFingerTapThenStationaryHoldStillCommitsDrag() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 0.02)
        engine.handle(sample(2, Phase.Began, view = CGPoint(300.0, 300.0), t = 0.1))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(300.0, 300.0), t = 0.12))
        engine.handle(sample(3, Phase.Began, view = CGPoint(301.0, 300.0), t = 0.18))

        val committed = engine.poll(now = 0.18 + PointerGestureConfig.holdCommitDelay + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 1)), committed)
    }


    @Test
    fun testEitherRelativePointerParticipantCanPerformClickChain() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 0.02)
        engine.handle(sample(2, Phase.Began, view = CGPoint(300.0, 300.0), t = 0.1))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(300.0, 300.0), t = 0.12))
        engine.handle(sample(3, Phase.Began, view = CGPoint(301.0, 300.0), t = 0.18))
        engine.handle(sample(3, Phase.Ended, view = CGPoint(301.0, 300.0), t = 0.2))
        val flushed = engine.poll(now = 0.2 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 2), PointerCommand.MouseUp(PointerButton.Left, 2)), flushed)
    }


    @Test
    fun testRelativeClickAndDragNeverEmitMoveAbsolute() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 0.02)
        val allCommands = mutableListOf<PointerCommand>()
        allCommands += engine.handle(sample(2, Phase.Began, view = CGPoint(300.0, 300.0), t = 0.1))
        allCommands += engine.handle(sample(2, Phase.Ended, view = CGPoint(300.0, 300.0), t = 0.12))
        allCommands += engine.handle(sample(3, Phase.Began, view = CGPoint(301.0, 300.0), t = 0.18))
        allCommands += engine.handle(sample(3, Phase.Moved, view = CGPoint(330.0, 300.0), t = 0.22))
        allCommands += engine.handle(sample(3, Phase.Moved, view = CGPoint(335.0, 305.0), t = 0.25))
        allCommands += engine.handle(sample(3, Phase.Ended, view = CGPoint(335.0, 305.0), t = 0.3))
        allCommands += engine.poll(now = 10.0)
        assertFalse(allCommands.any { isMoveAbsolute(it) })
    }


    // MARK: - Right click / right drag

    @Test
    fun testFreshTwoFingerTapIsRightClickWithNoPrecedingAbsoluteMove() {
        val engine = PointerGestureEngine()
        val down1 = engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        assertEquals(emptyList<PointerCommand>(), down1)
        val down2 = engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        assertEquals(emptyList<PointerCommand>(), down2)
        assertEquals(PointerEngineMode.TwoFingerPending, engine.mode)
        val up1 = engine.handle(sample(1, Phase.Ended, view = CGPoint(51.0, 50.0), t = 0.05))
        assertEquals(emptyList<PointerCommand>(), up1)
        val up2 = engine.handle(sample(2, Phase.Ended, view = CGPoint(71.0, 51.0), t = 0.06))
        assertEquals(emptyList<PointerCommand>(), up2)   // withheld for the double-tap/hold window
        assertEquals(PointerEngineMode.Idle, engine.mode)
        assertEquals(PointerGestureConfig.tapChainWindow, engine.pollDelay(now = 0.06) ?: -1.0, 0.000_001)
        val flushed = engine.poll(now = 0.06 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1), PointerCommand.MouseUp(PointerButton.Right, 1)), flushed)
        assertNull(engine.heldMouseButton)
    }


    /// GOAL: "fresh two-finger right click is still broken/finicky — first
    /// attempt often does nothing." Root cause: a second ordinary
    /// two-finger tap landing within the first's continuation window was
    /// being silently swallowed (both dropped) instead of flushing the
    /// first and re-arming for a possible third. Two ordinary right-clicks
    /// in a row, close together in time, must both fire.
    @Test
    fun testRepeatedOrdinaryTwoFingerRightClicksBothFireNotOnlyEveryOther() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(51.0, 50.0), t = 0.05))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(71.0, 51.0), t = 0.06))

        // A second, ordinary (not held) two-finger tap arrives well within
        // the first's continuation window.
        engine.handle(sample(3, Phase.Began, view = CGPoint(52.0, 52.0), t = 0.1))
        engine.handle(sample(4, Phase.Began, view = CGPoint(72.0, 52.0), t = 0.11))
        val up3 = engine.handle(sample(3, Phase.Ended, view = CGPoint(52.0, 52.0), t = 0.14))
        assertEquals(emptyList<PointerCommand>(), up3)   // one of the pair still down
        val up4 = engine.handle(sample(4, Phase.Ended, view = CGPoint(72.0, 52.0), t = 0.15))
        // The FIRST tap is now confirmed final (this one didn't hold into
        // a drag either) and flushes immediately; the second tap is
        // itself now buffered.
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1), PointerCommand.MouseUp(PointerButton.Right, 1)), up4)

        // With nothing to continue it, the second tap flushes too.
        val flushed = engine.poll(now = 0.15 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1), PointerCommand.MouseUp(PointerButton.Right, 1)), flushed)
    }


    @Test
    fun testEstablishedPointerPlusTwoLaterFingersUsesChordSemantics() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 0.02)
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)

        engine.handle(sample(2, Phase.Began, view = CGPoint(300.0, 300.0), t = 0.1))
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)   // solo precision — not yet a chord
        engine.handle(sample(3, Phase.Began, view = CGPoint(320.0, 300.0), t = 0.12))
        // Promoted to a 2-finger chord — no Mission Control takeover.
        assertEquals(PointerEngineMode.ChordPending, engine.mode)

        engine.handle(sample(2, Phase.Ended, view = CGPoint(301.0, 300.0), t = 0.15))
        val upLast = engine.handle(sample(3, Phase.Ended, view = CGPoint(321.0, 301.0), t = 0.16))
        assertEquals(emptyList<PointerCommand>(), upLast)
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)   // anchor session survives the chord
        val flushed = engine.poll(now = 0.16 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1), PointerCommand.MouseUp(PointerButton.Right, 1)), flushed)

        // The anchor's relative tracking resumed from its live position —
        // no jump on the next move.
        val resumed = engine.handle(sample(1, Phase.Moved, view = CGPoint(205.0, 2.0), t = 0.2))
        assertEquals(listOf(PointerCommand.MoveRelative(5.0, 2.0)), resumed)
    }


    @Test
    fun testRightTapThenSecondChordHoldProducesOnlyRightDownDragUp() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(51.0, 50.0), t = 0.05))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(71.0, 51.0), t = 0.06))
        assertEquals(PointerEngineMode.Idle, engine.mode)

        // A second two-finger touchdown arrives quickly, close to the
        // first tap, and is held.
        val down3 = engine.handle(sample(3, Phase.Began, view = CGPoint(52.0, 52.0), t = 0.15))
        assertEquals(emptyList<PointerCommand>(), down3)
        val down4 = engine.handle(sample(4, Phase.Began, view = CGPoint(72.0, 52.0), t = 0.16))
        assertEquals(emptyList<PointerCommand>(), down4)
        assertEquals(PointerEngineMode.TwoFingerPending, engine.mode)

        // Held past the commit delay with no release — commits to a right
        // drag with NO preceding right click.
        val committed = engine.poll(now = 0.16 + PointerGestureConfig.holdCommitDelay + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1)), committed)
        assertEquals(PointerEngineMode.RightDragHeld, engine.mode)
        assertEquals(PointerButton.Right, engine.heldMouseButton)

        val moved = engine.handle(sample(3, Phase.Moved, view = CGPoint(62.0, 52.0), t = 0.35))
        assertEquals(listOf(PointerCommand.MoveRelative(5.0, 0.0)), moved)   // centroid moved by (5,0)

        val up3 = engine.handle(sample(3, Phase.Ended, view = CGPoint(62.0, 52.0), t = 0.4))
        assertEquals(emptyList<PointerCommand>(), up3)   // one of two still down
        val up4 = engine.handle(sample(4, Phase.Ended, view = CGPoint(72.0, 52.0), t = 0.41))
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Right, 0)), up4)
        assertEquals(PointerEngineMode.Idle, engine.mode)
        assertNull(engine.heldMouseButton)

        // No stray right click was ever buffered/flushed for this sequence.
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 10.0))
    }


    @Test
    fun testFreshRightChordCanContinueWhenPartnerFingerArrivesAfterTapDeadline() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(51.0, 50.0), t = 0.05))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(71.0, 51.0), t = 0.06))

        // The next chord's first finger lands just inside the continuation
        // window. Polling at the old tap deadline must keep waiting for its
        // partner instead of posting the standalone right click.
        engine.handle(sample(3, Phase.Began, view = CGPoint(52.0, 52.0), t = 0.27))
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 0.28))
        engine.handle(sample(4, Phase.Began, view = CGPoint(72.0, 52.0), t = 0.30))

        val committed = engine.poll(now = 0.30 + PointerGestureConfig.holdCommitDelay + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1)), committed)
        assertEquals(PointerButton.Right, engine.heldMouseButton)

        assertEquals(listOf(PointerCommand.MoveRelative(5.0, 0.0)), engine.handle(sample(3, Phase.Moved, view = CGPoint(62.0, 52.0), t = 0.47)))
        engine.handle(sample(3, Phase.Ended, view = CGPoint(62.0, 52.0), t = 0.50))
        val released = engine.handle(sample(4, Phase.Ended, view = CGPoint(72.0, 52.0), t = 0.51))
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Right, 0)), released)
        assertNull(engine.heldMouseButton)
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 10.0))
    }


    @Test
    fun testFreshRightChordMovementCommitsDragBeforeHoldDelay() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(51.0, 50.0), t = 0.05))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(71.0, 51.0), t = 0.06))
        engine.handle(sample(3, Phase.Began, view = CGPoint(52.0, 52.0), t = 0.15))
        engine.handle(sample(4, Phase.Began, view = CGPoint(72.0, 52.0), t = 0.16))

        val committed = engine.handle(sample(3, Phase.Moved, view = CGPoint(74.0, 52.0), t = 0.18))
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1)), committed)
        assertEquals(PointerButton.Right, engine.heldMouseButton)
        assertFalse(committed.any { isMoveAbsolute(it) })

        val moved = engine.handle(sample(3, Phase.Moved, view = CGPoint(80.0, 52.0), t = 0.19))
        assertEquals(listOf(PointerCommand.MoveRelative(3.0, 0.0)), moved)
        engine.handle(sample(3, Phase.Ended, view = CGPoint(80.0, 52.0), t = 0.20))
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Right, 0)), engine.handle(sample(4, Phase.Ended, view = CGPoint(72.0, 52.0), t = 0.21)))
        assertNull(engine.heldMouseButton)
    }


    @Test
    fun testExistingPointerRightChordContinuesIntoStationaryHeldDrag() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 0.02)

        // First right chord buffers its tap while the pointer anchor remains.
        engine.handle(sample(2, Phase.Began, view = CGPoint(300.0, 300.0), t = 0.10))
        engine.handle(sample(3, Phase.Began, view = CGPoint(320.0, 300.0), t = 0.12))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(301.0, 300.0), t = 0.15))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(3, Phase.Ended, view = CGPoint(321.0, 301.0), t = 0.16)))
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)

        // The first added finger lands just before the candidate deadline;
        // the partner follows just after it. The pending click stays
        // undecided until the shared chord classifier sees both fingers.
        engine.handle(sample(4, Phase.Began, view = CGPoint(310.0, 300.0), t = 0.37))
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 0.38))
        engine.handle(sample(5, Phase.Began, view = CGPoint(320.0, 300.0), t = 0.40))
        assertEquals(PointerEngineMode.ChordPending, engine.mode)

        val committed = engine.poll(now = 0.40 + PointerGestureConfig.holdCommitDelay + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1)), committed)
        assertEquals(PointerButton.Right, engine.heldMouseButton)
        assertEquals(listOf(PointerCommand.MoveRelative(5.0, 0.0)), engine.handle(sample(4, Phase.Moved, view = CGPoint(320.0, 300.0), t = 0.57)))
        engine.handle(sample(4, Phase.Ended, view = CGPoint(320.0, 300.0), t = 0.60))
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Right, 0)), engine.handle(sample(5, Phase.Ended, view = CGPoint(320.0, 300.0), t = 0.61)))
        assertNull(engine.heldMouseButton)
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)

        // The anchor resumes from the position at which it was paused.
        assertEquals(listOf(PointerCommand.MoveRelative(5.0, 2.0)), engine.handle(sample(1, Phase.Moved, view = CGPoint(205.0, 2.0), t = 0.62)))
    }


    /// GOAL: "the two fingers are acting as a BUTTON CHORD, not as
    /// pointing inputs" — no command from any point in a full
    /// tap/hold/drag/resume chord lifecycle may ever reposition the
    /// cursor, for either the fresh-chord path or the existing-pointer-
    /// session path.
    @Test
    fun testRightChordCoordinatesNeverRepositionCursor() {
        val engine = PointerGestureEngine()
        val all = mutableListOf<PointerCommand>()
        // Fresh two-finger tap.
        all += engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        all += engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        all += engine.handle(sample(1, Phase.Ended, view = CGPoint(51.0, 50.0), t = 0.05))
        all += engine.handle(sample(2, Phase.Ended, view = CGPoint(71.0, 51.0), t = 0.06))
        all += engine.poll(now = 0.06 + PointerGestureConfig.tapChainWindow + 0.01)

        // Existing pointer session + two later fingers, tap and hold-drag.
        all += engine.handle(sample(3, Phase.Began, view = CGPoint.zero, t = 1.0))
        all += settleAsAnchor(engine, id = 3, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 1.02)
        all += engine.handle(sample(4, Phase.Began, view = CGPoint(300.0, 300.0), t = 1.1))
        all += engine.handle(sample(5, Phase.Began, view = CGPoint(320.0, 300.0), t = 1.12))
        all += engine.handle(sample(4, Phase.Ended, view = CGPoint(301.0, 300.0), t = 1.15))
        all += engine.handle(sample(5, Phase.Ended, view = CGPoint(321.0, 301.0), t = 1.16))
        all += engine.poll(now = 1.16 + PointerGestureConfig.tapChainWindow + 0.01)
        all += engine.handle(sample(6, Phase.Began, view = CGPoint(300.0, 300.0), t = 1.3))
        all += engine.handle(sample(7, Phase.Began, view = CGPoint(320.0, 300.0), t = 1.31))
        all += engine.poll(now = 1.31 + PointerGestureConfig.holdCommitDelay + 0.01)
        all += engine.handle(sample(6, Phase.Moved, view = CGPoint(340.0, 300.0), t = 1.5))
        all += engine.handle(sample(6, Phase.Ended, view = CGPoint(340.0, 300.0), t = 1.6))
        all += engine.handle(sample(7, Phase.Ended, view = CGPoint(320.0, 300.0), t = 1.61))

        // Exactly one `moveAbsolute` in this whole sequence: touch 3
        // legitimately establishing itself as the solo pointer anchor.
        // Nothing from either chord (fresh, or on the established
        // session) may ever reposition the cursor.
        val absoluteMoves = all.filter { isMoveAbsolute(it) }
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.5, 0.2)), absoluteMoves)
    }


    // MARK: - Ownership / system gestures

    @Test
    fun testFreshThreeFingerGestureDefersEntirely() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(30.0, 10.0), t = 0.01))
        val third = engine.handle(sample(3, Phase.Began, view = CGPoint(50.0, 10.0), t = 0.02))
        assertEquals(emptyList<PointerCommand>(), third)
        assertEquals(PointerEngineMode.DeferredSystemGesture, engine.mode)

        // Movement/release of any of these touches produces nothing —
        // the existing system-gesture recognizers own the sequence.
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Moved, view = CGPoint(10.0, 100.0), t = 0.1)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Ended, view = CGPoint(10.0, 100.0), t = 0.2)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(2, Phase.Ended, view = CGPoint(30.0, 100.0), t = 0.2)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(3, Phase.Ended, view = CGPoint(50.0, 100.0), t = 0.2)))
    }


    /// The exact real-device failure: a fresh 3-finger system gesture defers
    /// entirely (as `testFreshThreeFingerGestureDefersEntirely` verifies),
    /// `VideoView.cancelTouchForGestureOwnership` then calls `reset()` (as
    /// soon as the gesture is recognized — typically well before all three
    /// fingers have physically lifted, since `cancelsTouchesInView = false`
    /// keeps delivering their trailing `moved`/`ended` samples to the
    /// engine), and only once every one of those three touches has actually
    /// ended does a genuinely fresh single-finger tap begin. That tap must
    /// resolve as a LEFT click, never a right click.
    @Test
    fun testFreshTapAfterThreeFingerGestureDeferAndResetIsALeftClickNotARightClick() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(30.0, 10.0), t = 0.01))
        engine.handle(sample(3, Phase.Began, view = CGPoint(50.0, 10.0), t = 0.02))
        assertEquals(PointerEngineMode.DeferredSystemGesture, engine.mode)

        // Ownership taken mid-swipe, well before any finger has lifted.
        assertEquals(emptyList<PointerCommand>(), engine.reset())
        assertEquals(PointerEngineMode.Idle, engine.mode)

        // The three fingers keep moving and then lift one at a time —
        // still delivered to the engine (no UIKit-level cancellation) —
        // interleaved with the fresh tap that starts once they're gone.
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Moved, view = CGPoint(10.0, 120.0), t = 0.1)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(2, Phase.Moved, view = CGPoint(30.0, 120.0), t = 0.1)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(3, Phase.Moved, view = CGPoint(50.0, 120.0), t = 0.1)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Ended, view = CGPoint(10.0, 120.0), t = 0.2)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(2, Phase.Ended, view = CGPoint(30.0, 120.0), t = 0.21)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(3, Phase.Ended, view = CGPoint(50.0, 120.0), t = 0.22)))
        assertEquals(PointerEngineMode.Idle, engine.mode)

        // A genuinely fresh single-finger tap.
        val began = engine.handle(sample(4, Phase.Began, view = CGPoint(200.0, 200.0),
                                         norm = CGPoint(0.7, 0.7), t = 0.4))
        assertEquals(emptyList<PointerCommand>(), began)
        assertEquals(PointerEngineMode.FirstTouchPending, engine.mode)
        val ended = engine.handle(sample(4, Phase.Ended, view = CGPoint(200.0, 200.0),
                                         norm = CGPoint(0.7, 0.7), t = 0.42))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.7, 0.7)), ended)
        assertEquals(PointerEngineMode.TapBuffered, engine.mode)

        val flushed = engine.poll(now = 0.42 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 1),
                                 PointerCommand.MouseUp(PointerButton.Left, 1)), flushed)
    }


    /// Same as above for a 4-finger pinch/spread system gesture (the
    /// already-working comparison case) — confirms the engine treats both
    /// group sizes identically once deferred and reset.
    @Test
    fun testFreshTapAfterFourFingerGestureDeferAndResetIsALeftClick() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(30.0, 10.0), t = 0.01))
        engine.handle(sample(3, Phase.Began, view = CGPoint(50.0, 10.0), t = 0.02))
        engine.handle(sample(4, Phase.Began, view = CGPoint(70.0, 10.0), t = 0.03))
        assertEquals(PointerEngineMode.DeferredSystemGesture, engine.mode)

        assertEquals(emptyList<PointerCommand>(), engine.reset())
        assertEquals(PointerEngineMode.Idle, engine.mode)

        for ((id, x) in listOf(Pair(1, 10.0), Pair(2, 30.0), Pair(3, 50.0), Pair(4, 70.0))) {
            assertEquals(emptyList<PointerCommand>(), engine.handle(sample(id, Phase.Moved, view = CGPoint(x, 120.0), t = 0.1)))
        }
        for ((id, x, t) in listOf(Triple(1, 10.0, 0.2), Triple(2, 30.0, 0.21), Triple(3, 50.0, 0.22), Triple(4, 70.0, 0.23))) {
            assertEquals(emptyList<PointerCommand>(), engine.handle(sample(id, Phase.Ended, view = CGPoint(x, 120.0), t = t)))
        }
        assertEquals(PointerEngineMode.Idle, engine.mode)

        val began = engine.handle(sample(5, Phase.Began, view = CGPoint(200.0, 200.0),
                                         norm = CGPoint(0.7, 0.7), t = 0.4))
        assertEquals(emptyList<PointerCommand>(), began)
        val ended = engine.handle(sample(5, Phase.Ended, view = CGPoint(200.0, 200.0),
                                         norm = CGPoint(0.7, 0.7), t = 0.42))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.7, 0.7)), ended)
        val flushed = engine.poll(now = 0.42 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 1),
                                 PointerCommand.MouseUp(PointerButton.Left, 1)), flushed)
    }


    /// After a deferred-and-reset 3-finger gesture, a fresh DOUBLE tap must
    /// still count correctly (clickCount 2) — the reset must not leave any
    /// residual tap-chain state, but must also not block ordinary chaining
    /// for the genuinely new sequence.
    @Test
    fun testFreshDoubleTapAfterThreeFingerGestureCountsCorrectly() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(30.0, 10.0), t = 0.01))
        engine.handle(sample(3, Phase.Began, view = CGPoint(50.0, 10.0), t = 0.02))
        assertEquals(emptyList<PointerCommand>(), engine.reset())
        for (id in listOf(1, 2, 3)) {
            engine.handle(sample(id, Phase.Ended, view = CGPoint(id.toDouble() * 20.0, 120.0), t = 0.2))
        }

        engine.handle(sample(10, Phase.Began, view = CGPoint(200.0, 200.0), t = 0.4))
        engine.handle(sample(10, Phase.Ended, view = CGPoint(200.0, 200.0), t = 0.41))
        engine.handle(sample(11, Phase.Began, view = CGPoint(201.0, 200.0), t = 0.45))
        // Each tap in the chain also repositions the cursor to its own tap
        // location (see `PointerEngineMode.FirstTouchPending`'s `ended()` case) — only the
        // click itself stays buffered, waiting out the chain window.
        val secondTapUp = engine.handle(sample(11, Phase.Ended, view = CGPoint(201.0, 200.0), t = 0.46))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.5, 0.5)), secondTapUp)
        val flushed = engine.poll(now = 0.46 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 2),
                                 PointerCommand.MouseUp(PointerButton.Left, 2)), flushed)
    }


    /// A fresh pointer *drag* (not a tap) after a deferred-and-reset
    /// 3-finger gesture must also start clean: exactly one `moveAbsolute`
    /// from the new anchor, no leftover chord/right-click output.
    @Test
    fun testFreshPointerMovementAfterThreeFingerGestureStartsClean() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(30.0, 10.0), t = 0.01))
        engine.handle(sample(3, Phase.Began, view = CGPoint(50.0, 10.0), t = 0.02))
        assertEquals(emptyList<PointerCommand>(), engine.reset())
        for (id in listOf(1, 2, 3)) {
            engine.handle(sample(id, Phase.Ended, view = CGPoint(id.toDouble() * 20.0, 120.0), t = 0.2))
        }

        engine.handle(sample(20, Phase.Began, view = CGPoint(200.0, 200.0), t = 0.4))
        val moved = engine.handle(sample(20, Phase.Moved, view = CGPoint(260.0, 200.0),
                                         norm = CGPoint(0.8, 0.5), t = 0.42))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.8, 0.5)), moved)
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
        assertTrue(moved.none { isMouseDown(it) })
    }


    /// A fresh, genuine two-finger right-click chord after a deferred-and-
    /// reset 3-finger gesture must still work — the fix must not suppress
    /// legitimate right-clicks going forward, only the stale leftovers of
    /// the claimed sequence.
    @Test
    fun testFreshTwoFingerRightClickAfterThreeFingerGestureStillWorks() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(30.0, 10.0), t = 0.01))
        engine.handle(sample(3, Phase.Began, view = CGPoint(50.0, 10.0), t = 0.02))
        assertEquals(emptyList<PointerCommand>(), engine.reset())
        for (id in listOf(1, 2, 3)) {
            engine.handle(sample(id, Phase.Ended, view = CGPoint(id.toDouble() * 20.0, 120.0), t = 0.2))
        }

        engine.handle(sample(30, Phase.Began, view = CGPoint(200.0, 200.0), t = 0.4))
        engine.handle(sample(31, Phase.Began, view = CGPoint(220.0, 200.0), t = 0.41))
        assertEquals(PointerEngineMode.TwoFingerPending, engine.mode)
        engine.handle(sample(30, Phase.Ended, view = CGPoint(200.0, 200.0), t = 0.44))
        engine.handle(sample(31, Phase.Ended, view = CGPoint(220.0, 200.0), t = 0.45))
        // A quick fresh chord tap buffers a right tap, only flushed if
        // nothing continues it — poll past the window to confirm it
        // actually resolves as a right click, not silently dropped.
        engine.poll(now = 0.45 + PointerGestureConfig.tapChainWindow + 0.01)

        // Continue it into a drag with a second chord to force the
        // right-click through unambiguously (mirrors
        // `testCancellingRightDragReleasesTheButtonExactlyOnce`'s pattern).
        val engine2 = PointerGestureEngine()
        engine2.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine2.handle(sample(2, Phase.Began, view = CGPoint(30.0, 10.0), t = 0.01))
        engine2.handle(sample(3, Phase.Began, view = CGPoint(50.0, 10.0), t = 0.02))
        assertEquals(emptyList<PointerCommand>(), engine2.reset())
        for (id in listOf(1, 2, 3)) {
            engine2.handle(sample(id, Phase.Ended, view = CGPoint(id.toDouble() * 20.0, 120.0), t = 0.2))
        }
        engine2.handle(sample(30, Phase.Began, view = CGPoint(200.0, 200.0), t = 0.4))
        engine2.handle(sample(31, Phase.Began, view = CGPoint(220.0, 200.0), t = 0.41))
        engine2.handle(sample(30, Phase.Ended, view = CGPoint(200.0, 200.0), t = 0.44))
        engine2.handle(sample(31, Phase.Ended, view = CGPoint(220.0, 200.0), t = 0.45))
        engine2.handle(sample(32, Phase.Began, view = CGPoint(202.0, 202.0), t = 0.5))
        engine2.handle(sample(33, Phase.Began, view = CGPoint(222.0, 202.0), t = 0.51))
        val rightDown = engine2.poll(now = 0.51 + PointerGestureConfig.holdCommitDelay + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1)), rightDown)
    }


    @Test
    fun testEstablishedPointerPlusTwoLaterFingersNeverDefersToSystemGesture() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 0.02)
        engine.handle(sample(2, Phase.Began, view = CGPoint(300.0, 300.0), t = 0.1))
        engine.handle(sample(3, Phase.Began, view = CGPoint(320.0, 300.0), t = 0.12))
        assertNotEquals(PointerEngineMode.DeferredSystemGesture, engine.mode)
        assertEquals(PointerEngineMode.ChordPending, engine.mode)
    }


    /// Simulates the legacy scroll/pinch recognizer winning a race for a
    /// fresh two-finger sequence the engine was also tracking as a
    /// right-click candidate — `VideoView.cancelTouchForGestureOwnership`
    /// calls `reset()` on exactly this kind of win, and after that no
    /// right-click output must ever reach the wire for these touches.
    @Test
    fun testScrollPinchOwnershipWinSuppressesPointerOutput() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        assertEquals(PointerEngineMode.TwoFingerPending, engine.mode)

        val released = engine.reset()
        assertEquals(emptyList<PointerCommand>(), released)   // no button was held — nothing to release
        assertEquals(PointerEngineMode.Idle, engine.mode)

        // The same physical touches continuing to move/lift produce
        // nothing further — the engine has fully val go of them.
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0, 90.0), t = 0.05)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Ended, view = CGPoint(100.0, 90.0), t = 0.1)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(2, Phase.Ended, view = CGPoint(120.0, 90.0), t = 0.1)))
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 10.0))
    }


    // MARK: - Safety / cleanup

    @Test
    fun testReleaseHeldEndsAnOpenLeftDrag() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(10.0, 10.0), t = 0.02))
        engine.handle(sample(2, Phase.Began, view = CGPoint(11.0, 9.0), t = 0.1))
        engine.handle(sample(2, Phase.Moved, view = CGPoint(40.0, 9.0), t = 0.15))
        assertEquals(PointerEngineMode.LeftDragHeld, engine.mode)

        val released = engine.releaseHeld()
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Left, 0)), released)
        assertEquals(emptyList<PointerCommand>(), engine.releaseHeld())   // idempotent
    }


    @Test
    fun testReleaseHeldEndsAnOpenRightDrag() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(51.0, 50.0), t = 0.05))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(71.0, 51.0), t = 0.06))
        engine.handle(sample(3, Phase.Began, view = CGPoint(52.0, 52.0), t = 0.15))
        engine.handle(sample(4, Phase.Began, view = CGPoint(72.0, 52.0), t = 0.16))
        engine.poll(now = 0.16 + PointerGestureConfig.holdCommitDelay + 0.01)
        assertEquals(PointerEngineMode.RightDragHeld, engine.mode)

        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Right, 0)), engine.releaseHeld())
        assertNull(engine.heldMouseButton)
    }


    @Test
    fun testCancelledFreshRightChordDoesNotLeaveAButtonHeld() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        engine.handle(sample(1, Phase.Cancelled, view = CGPoint(50.0, 50.0), t = 0.05))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(2, Phase.Cancelled, view = CGPoint(70.0, 50.0), t = 0.06)))

        assertNull(engine.heldMouseButton)
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 10.0))
    }


    @Test
    fun testCancellingRightDragReleasesTheButtonExactlyOnce() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(51.0, 50.0), t = 0.05))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(71.0, 51.0), t = 0.06))
        engine.handle(sample(3, Phase.Began, view = CGPoint(52.0, 52.0), t = 0.15))
        engine.handle(sample(4, Phase.Began, view = CGPoint(72.0, 52.0), t = 0.16))
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1)), engine.poll(now = 0.32))

        val firstCancel = engine.handle(sample(3, Phase.Cancelled, view = CGPoint(52.0, 52.0), t = 0.35))
        assertEquals(emptyList<PointerCommand>(), firstCancel)
        val lastCancel = engine.handle(sample(4, Phase.Cancelled, view = CGPoint(72.0, 52.0), t = 0.36))
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Right, 0)), lastCancel)
        assertNull(engine.heldMouseButton)
        assertEquals(emptyList<PointerCommand>(), engine.reset())
    }


    @Test
    fun testResetReleasesHeldButtonAndForgetsAllTouches() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(10.0, 10.0), t = 0.02))
        engine.handle(sample(2, Phase.Began, view = CGPoint(11.0, 9.0), t = 0.1))
        engine.handle(sample(2, Phase.Moved, view = CGPoint(40.0, 9.0), t = 0.15))
        assertEquals(PointerEngineMode.LeftDragHeld, engine.mode)

        val out = engine.reset()
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Left, 0)), out)
        assertEquals(PointerEngineMode.Idle, engine.mode)
        // A stray sample for the now-forgotten touch is a no-op, not a crash.
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(2, Phase.Moved, view = CGPoint(50.0, 9.0), t = 0.2)))
    }


    @Test
    fun testResetDuringRelativeSessionReleasesNothingHeldAndForgetsBothFingers() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 0.02)
        engine.handle(sample(2, Phase.Began, view = CGPoint(20.0, 20.0), t = 0.1))
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)

        assertEquals(emptyList<PointerCommand>(), engine.reset())   // no button held during precision
        assertEquals(PointerEngineMode.Idle, engine.mode)
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Moved, view = CGPoint(205.0, 2.0), t = 0.2)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(2, Phase.Moved, view = CGPoint(25.0, 24.0), t = 0.2)))
    }


    // MARK: - Trackpad input mode

    @Test
    fun testDefaultInputModeIsDirect() {
        assertEquals(PointerInputMode.Direct, PointerGestureEngine().inputMode)
    }


    @Test
    fun testTrackpadTouchDownNeverMovesCursor() {
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        val down = engine.handle(sample(1, Phase.Began, view = CGPoint(100.0, 100.0), norm = CGPoint(0.2, 0.2), t = 0.0))
        assertEquals(emptyList<PointerCommand>(), down)
        // Movement well beyond dragSlop commits the session — still no
        // absolute move, ever, in trackpad mode.
        val moved = engine.handle(sample(1, Phase.Moved, view = CGPoint(150.0, 100.0), norm = CGPoint(0.4, 0.2), t = 0.01))
        assertFalse(moved.any { isMoveAbsolute(it) })
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)
    }


    @Test
    fun testTrackpadOneFingerMovementProducesRelativeDeltas() {
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        engine.handle(sample(1, Phase.Began, view = CGPoint(100.0, 100.0), t = 0.0))
        val committed = engine.handle(sample(1, Phase.Moved, view = CGPoint(150.0, 100.0), t = 0.01))
        assertEquals(emptyList<PointerCommand>(), committed)   // the crossing movement itself is absorbed, not replayed
        val moved = engine.handle(sample(1, Phase.Moved, view = CGPoint(160.0, 105.0), t = 0.02))
        assertEquals(listOf(PointerCommand.MoveRelative(10.0, 5.0)), moved)
    }


    @Test
    fun testTrackpadWindowExpiryCommitsWithoutMovingCursorThenTracksRelatively() {
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        engine.handle(sample(1, Phase.Began, view = CGPoint(100.0, 100.0), norm = CGPoint(0.2, 0.2), t = 0.0))
        val committed = engine.poll(now = PointerGestureConfig.firstTouchArbitrationWindow + 0.005)
        assertEquals(emptyList<PointerCommand>(), committed)
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)
        val moved = engine.handle(sample(1, Phase.Moved, view = CGPoint(108.0, 100.0),
                                         t = PointerGestureConfig.firstTouchArbitrationWindow + 0.02))
        assertEquals(listOf(PointerCommand.MoveRelative(8.0, 0.0)), moved)
    }


    @Test
    fun testTrackpadTapClicksAtCurrentCursorLocationNotTouchLocation() {
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), norm = CGPoint(0.3, 0.3), t = 0.0))
        val up = engine.handle(sample(1, Phase.Ended, view = CGPoint(11.0, 10.0), norm = CGPoint(0.31, 0.3), t = 0.02))
        // Unlike direct mode, nothing moves the cursor — the click must
        // land wherever the Mac's cursor already is.
        assertEquals(emptyList<PointerCommand>(), up)
        assertEquals(PointerEngineMode.TapBuffered, engine.mode)
        val flushed = engine.poll(now = 0.02 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 1), PointerCommand.MouseUp(PointerButton.Left, 1)), flushed)
    }


    @Test
    fun testTrackpadTapHoldThenMoveDragsRelativelyAndReleaseCleansUp() {
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        // A quick tap, buffered...
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(10.0, 10.0), t = 0.02))
        assertEquals(PointerEngineMode.TapBuffered, engine.mode)
        // ...then a fresh touch continues the chain and holds past the
        // hold-commit delay with real movement — commits to a drag with NO
        // absolute move (button posts at the cursor's current position).
        engine.handle(sample(2, Phase.Began, view = CGPoint(11.0, 11.0), t = 0.08))
        val dragStart = engine.handle(sample(2, Phase.Moved, view = CGPoint(25.0, 11.0), t = 0.1))
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 1)), dragStart)
        assertFalse(dragStart.any { isMoveAbsolute(it) })
        assertEquals(PointerButton.Left, engine.heldMouseButton)

        val dragMove = engine.handle(sample(2, Phase.Moved, view = CGPoint(40.0, 11.0), t = 0.12))
        assertEquals(listOf(PointerCommand.MoveRelative(15.0, 0.0)), dragMove)

        val release = engine.handle(sample(2, Phase.Ended, view = CGPoint(40.0, 11.0), t = 0.14))
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Left, 0)), release)
        assertNull(engine.heldMouseButton)
        assertEquals(PointerEngineMode.Idle, engine.mode)
    }


    /// Regression: the STATIONARY-hold commit path (via `poll()`, when a
    /// continuing touch holds past `holdCommitDelay` without ever crossing
    /// `dragSlop`) must never jump the cursor either — only the
    /// movement-triggered commit path (`moved()`) was originally fixed;
    /// this covers the "tap → hold (stay still) → then move" sequence that
    /// only `poll()`'s timer branch resolves.
    @Test
    fun testTrackpadTapHoldStationaryThenMoveNeverEmitsAbsoluteMove() {
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), norm = CGPoint(0.3, 0.3), t = 0.0))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(10.0, 10.0), norm = CGPoint(0.3, 0.3), t = 0.02))
        assertEquals(PointerEngineMode.TapBuffered, engine.mode)

        // A fresh touch continues the chain and holds PERFECTLY STILL past
        // holdCommitDelay — never crosses dragSlop, so only `poll()`
        // resolves it, not `moved()`.
        engine.handle(sample(2, Phase.Began, view = CGPoint(11.0, 11.0), norm = CGPoint(0.31, 0.31), t = 0.08))
        val commands = engine.poll(now = 0.08 + PointerGestureConfig.holdCommitDelay + 0.01)
        assertFalse(commands.any { isMoveAbsolute(it) })
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 1)), commands)
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)
        assertEquals(PointerButton.Left, engine.heldMouseButton)

        // Subsequent movement is relative, from wherever the cursor
        // actually is — never replayed as an absolute jump.
        val moved = engine.handle(sample(2, Phase.Moved, view = CGPoint(21.0, 11.0),
                                         t = 0.08 + PointerGestureConfig.holdCommitDelay + 0.02))
        assertEquals(listOf(PointerCommand.MoveRelative(10.0, 0.0)), moved)
    }


    // MARK: - Trackpad sensitivity

    @Test
    fun testDefaultTrackpadSensitivityPreservesUnscaledDelta() {
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        assertEquals(PointerGestureConfig.defaultTrackpadSensitivity, engine.trackpadSensitivity, 0.0)
        engine.handle(sample(1, Phase.Began, view = CGPoint(100.0, 100.0), t = 0.0))
        engine.handle(sample(1, Phase.Moved, view = CGPoint(150.0, 100.0), t = 0.01))
        val moved = engine.handle(sample(1, Phase.Moved, view = CGPoint(160.0, 105.0), t = 0.02))
        assertEquals(listOf(PointerCommand.MoveRelative(10.0, 5.0)), moved)
    }


    @Test
    fun testTrackpadSensitivityScalesOneFingerRelativeDelta() {
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        engine.trackpadSensitivity = 2.0
        engine.handle(sample(1, Phase.Began, view = CGPoint(100.0, 100.0), t = 0.0))
        engine.handle(sample(1, Phase.Moved, view = CGPoint(150.0, 100.0), t = 0.01))
        val moved = engine.handle(sample(1, Phase.Moved, view = CGPoint(160.0, 105.0), t = 0.02))
        assertEquals(listOf(PointerCommand.MoveRelative(20.0, 10.0)), moved)
    }


    @Test
    fun testTrackpadSensitivityIsClampedToConfiguredRange() {
        val engine = PointerGestureEngine()
        engine.trackpadSensitivity = 999.0
        assertEquals(PointerGestureConfig.trackpadSensitivityRange.endInclusive, engine.trackpadSensitivity, 0.0)
        engine.trackpadSensitivity = -5.0
        assertEquals(PointerGestureConfig.trackpadSensitivityRange.start, engine.trackpadSensitivity, 0.0)
    }


    @Test
    fun testTrackpadSensitivityNeverAffectsDirectModeHybridPrecisionMove() {
        val engine = PointerGestureEngine()
        // Direct mode (default) — sensitivity set high, must be ignored.
        engine.trackpadSensitivity = 2.0
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 0.02)
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
        engine.handle(sample(2, Phase.Began, view = CGPoint(300.0, 300.0), t = 0.1))
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)   // hybrid precision, still Direct mode
        val moved = engine.handle(sample(2, Phase.Moved, view = CGPoint(310.0, 305.0), t = 0.12))
        assertEquals(listOf(PointerCommand.MoveRelative(10.0, 5.0)), moved)   // unscaled
    }


    @Test
    fun testTrackpadSensitivityNeverAffectsTwoFingerRightDrag() {
        // Same sequence as testRightTapThenSecondChordHoldProducesOnlyRightDownDragUp,
        // but in Trackpad mode with sensitivity maxed — the right-drag delta
        // must come out identical regardless.
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        engine.trackpadSensitivity = 2.0
        engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(51.0, 50.0), t = 0.05))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(71.0, 51.0), t = 0.06))

        engine.handle(sample(3, Phase.Began, view = CGPoint(52.0, 52.0), t = 0.15))
        engine.handle(sample(4, Phase.Began, view = CGPoint(72.0, 52.0), t = 0.16))
        val committed = engine.poll(now = 0.16 + PointerGestureConfig.holdCommitDelay + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1)), committed)
        assertEquals(PointerEngineMode.RightDragHeld, engine.mode)

        val moved = engine.handle(sample(3, Phase.Moved, view = CGPoint(62.0, 52.0), t = 0.35))
        assertEquals(listOf(PointerCommand.MoveRelative(5.0, 0.0)), moved)   // unscaled centroid delta
    }


    /// Regression for the real-device "right click → hold → drag" report.
    /// The exact physical flow: cursor already somewhere, first finger
    /// down, second finger joins STAGGERED (past the 150ms arbitration
    /// window — the timing that used to get the first finger swallowed
    /// into its own solo Trackpad session instead of forming the
    /// continuation chord), the chord commits, is held, dragged, released.
    @Test
    fun testTrackpadRightClickChordHoldDragNeverJumpsAbsolutelyEvenWithStaggeredFingerArrival() {
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)

        // First right click: quick two-finger tap, buffers a pending right
        // tap for the second attempt to continue.
        engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(51.0, 50.0), t = 0.05))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(71.0, 51.0), t = 0.06))

        val allCommands = mutableListOf<PointerCommand>()

        // Second attempt: finger 3 lands ALONE and sits past the 150ms
        // arbitration window before its partner joins.
        allCommands += engine.handle(sample(3, Phase.Began, view = CGPoint(52.0, 52.0), t = 0.1))
        allCommands += engine.poll(now = 0.1 + PointerGestureConfig.firstTouchArbitrationWindow + 0.02)
        // Must still be withheld, arbitrating — NOT solo-committed to its
        // own relative session (which would swallow the pending chord).
        assertEquals(PointerEngineMode.FirstTouchPending, engine.mode)

        // The partner now joins, well after the 150ms window but still
        // within the buffered tap's own continuation window.
        allCommands += engine.handle(sample(4, Phase.Began, view = CGPoint(72.0, 52.0), t = 0.28))
        assertEquals(PointerEngineMode.TwoFingerPending, engine.mode)
        assertTrue(engine.isChordContinuation)

        // Held past the commit delay with no movement — right mouseDown,
        // no move of any kind.
        val committed = engine.poll(now = 0.28 + PointerGestureConfig.holdCommitDelay + 0.01)
        allCommands += committed
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1)), committed)
        assertEquals(PointerEngineMode.RightDragHeld, engine.mode)
        assertEquals(PointerButton.Right, engine.heldMouseButton)

        // Drag: relative centroid deltas only.
        val dragMove = engine.handle(sample(3, Phase.Moved, view = CGPoint(67.0, 52.0),
                                            t = 0.28 + PointerGestureConfig.holdCommitDelay + 0.05))
        allCommands += dragMove
        assertEquals(listOf(PointerCommand.MoveRelative(7.5, 0.0)), dragMove)

        // Release both fingers — clean right mouseUp.
        allCommands += engine.handle(sample(3, Phase.Ended, view = CGPoint(67.0, 52.0), t = 1.0))
        val release = engine.handle(sample(4, Phase.Ended, view = CGPoint(72.0, 52.0), t = 1.01))
        allCommands += release
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Right, 0)), release)
        assertNull(engine.heldMouseButton)
        assertEquals(PointerEngineMode.Idle, engine.mode)

        assertFalse(allCommands.any { isMoveAbsolute(it) })
    }


    @Test
    fun testTrackpadStaggeredLoneFingerEventuallyCommitsSoloIfNoPartnerEverArrives() {
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(51.0, 50.0), t = 0.05))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(71.0, 51.0), t = 0.06))

        engine.handle(sample(3, Phase.Began, view = CGPoint(52.0, 52.0), t = 0.1))
        // Nobody ever joins — well past both the arbitration window AND
        // the buffered tap's own continuation window.
        val committed = engine.poll(now = 0.1 + PointerGestureConfig.tapChainWindow + 0.05)
        assertFalse(committed.any { isMoveAbsolute(it) })
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)   // committed solo, as a normal Trackpad session
    }


    @Test
    fun testTrackpadHigherFingerGesturesShareDirectModeSemantics() {
        // Two-finger/right-click chord arbitration is unmodified by input
        // mode — a fresh two-finger tap still right-clicks in trackpad mode.
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        engine.handle(sample(1, Phase.Began, view = CGPoint(50.0, 50.0), t = 0.0))
        engine.handle(sample(2, Phase.Began, view = CGPoint(70.0, 50.0), t = 0.01))
        assertEquals(PointerEngineMode.TwoFingerPending, engine.mode)
        engine.handle(sample(1, Phase.Ended, view = CGPoint(51.0, 50.0), t = 0.05))
        engine.handle(sample(2, Phase.Ended, view = CGPoint(71.0, 51.0), t = 0.06))
        val flushed = engine.poll(now = 0.06 + PointerGestureConfig.tapChainWindow + 0.01)
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Right, 1), PointerCommand.MouseUp(PointerButton.Right, 1)), flushed)
    }


    // MARK: - Input mode switching

    @Test
    fun testSetInputModeIsNoOpWhenUnchanged() {
        val engine = PointerGestureEngine()
        engine.handle(sample(1, Phase.Began, view = CGPoint.zero, t = 0.0))
        settleAsAnchor(engine, id = 1, to = CGPoint(200.0, 0.0), norm = CGPoint(0.5, 0.2), t = 0.02)
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
        assertEquals(emptyList<PointerCommand>(), engine.setInputMode(PointerInputMode.Direct))
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)   // untouched — same mode requested
    }


    @Test
    fun testSwitchingModeMidLeftDragReleasesTheHeldButtonAndReturnsToIdle() {
        val engine = PointerGestureEngine()
        // Tap-then-hold-drag in direct mode.
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(10.0, 10.0), t = 0.02))
        engine.handle(sample(2, Phase.Began, view = CGPoint(11.0, 11.0), norm = CGPoint(0.3, 0.3), t = 0.08))
        engine.handle(sample(2, Phase.Moved, view = CGPoint(30.0, 11.0), norm = CGPoint(0.5, 0.3), t = 0.1))
        assertEquals(PointerEngineMode.LeftDragHeld, engine.mode)
        assertEquals(PointerButton.Left, engine.heldMouseButton)

        val cleanup = engine.setInputMode(PointerInputMode.Trackpad)
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Left, 0)), cleanup)
        assertNull(engine.heldMouseButton)
        assertEquals(PointerEngineMode.Idle, engine.mode)
        assertEquals(PointerInputMode.Trackpad, engine.inputMode)

        // The next gesture starts completely clean under the new mode.
        engine.handle(sample(3, Phase.Began, view = CGPoint(0.0, 0.0), t = 0.5))
        val fresh = engine.handle(sample(3, Phase.Moved, view = CGPoint(20.0, 0.0), t = 0.51))
        assertEquals(emptyList<PointerCommand>(), fresh)   // trackpad: crossing movement absorbed, no jump
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)
    }


    @Test
    fun testSwitchingModeMidRelativeSessionReleasesHeldButtonAndForgetsFingers() {
        val engine = PointerGestureEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        engine.handle(sample(1, Phase.Began, view = CGPoint(10.0, 10.0), t = 0.0))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(10.0, 10.0), t = 0.02))
        engine.handle(sample(2, Phase.Began, view = CGPoint(11.0, 11.0), t = 0.08))
        engine.handle(sample(2, Phase.Moved, view = CGPoint(30.0, 11.0), t = 0.1))
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)
        assertEquals(PointerButton.Left, engine.heldMouseButton)

        val cleanup = engine.setInputMode(PointerInputMode.Direct)
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Left, 0)), cleanup)
        assertNull(engine.heldMouseButton)
        assertEquals(PointerEngineMode.Idle, engine.mode)

        // No stuck touch: the same finger id starting a brand-new sequence
        // afterward is treated as fresh, not a continuation.
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(2, Phase.Began, view = CGPoint(60.0, 60.0), t = 1.0)))
        assertEquals(PointerEngineMode.FirstTouchPending, engine.mode)
    }
}

class AppGestureCommandAccumulatorTests {
    @Test
    fun testJitterBelowThresholdSendsNothing() {
        val accumulator = AppGestureCommandAccumulator(threshold = 1.0, step = 0.5)
        assertEquals(0, accumulator.advance(0.1))
        assertEquals(0, accumulator.advance(0.2))
        assertEquals(0, accumulator.advance(-0.05))   // still absorbed as jitter after reversal
    }

    @Test
    fun testOutwardCrossingThresholdFiresOnce() {
        val accumulator = AppGestureCommandAccumulator(threshold = 1.0, step = 0.5)
        assertEquals(1, accumulator.advance(1.2))
    }

    @Test
    fun testInwardCrossingThresholdFiresNegative() {
        val accumulator = AppGestureCommandAccumulator(threshold = 1.0, step = 0.5)
        assertEquals(-1, accumulator.advance(-1.2))
    }

    @Test
    fun testContinuedMovementRepeatsProportionally() {
        val accumulator = AppGestureCommandAccumulator(threshold = 1.0, step = 0.5)
        assertEquals(1, accumulator.advance(1.0))     // exactly at threshold
        assertEquals(1, accumulator.advance(0.5))     // one more full step
        assertEquals(0, accumulator.advance(0.24))    // under a step: no repeat yet
        assertEquals(1, accumulator.advance(0.26))    // completes the step
    }

    @Test
    fun testLargeMovementFiresMultipleCappedRepeatsInOneUpdate() {
        val accumulator = AppGestureCommandAccumulator(threshold = 1.0, step = 0.5, maxFiresPerUpdate = 3)
        // 1 (threshold) + 5 * 0.5 (step) would be 6 fires; capped at 3.
        assertEquals(3, accumulator.advance(3.5))
    }

    @Test
    fun testDirectionReversalRebasesCleanly() {
        val accumulator = AppGestureCommandAccumulator(threshold = 1.0, step = 0.5)
        assertEquals(1, accumulator.advance(1.2))
        // Reversing direction with a small delta must not immediately fire
        // the opposite command - it rebases and re-accumulates from zero.
        assertEquals(0, accumulator.advance(-0.3))
        assertEquals(-1, accumulator.advance(-0.8))
    }

    @Test
    fun testResetClearsAccumulationOnGestureEndOrCancel() {
        val accumulator = AppGestureCommandAccumulator(threshold = 1.0, step = 0.5)
        assertEquals(0, accumulator.advance(0.9))
        accumulator.reset()
        assertEquals(0, accumulator.advance(0.9))   // did not carry over the prior 0.9
    }

    @Test
    fun testConfiguredPinchAndRotationRoutingHaveSaneThresholds() {
        val pinch = AppGestureCommandRouting.makePinchAccumulator()
        assertEquals(0, pinch.advance(0.05))   // small pinch jitter: nothing
        val rotation = AppGestureCommandRouting.makeRotationAccumulator()
        assertEquals(0, rotation.advance(0.05))   // a few degrees: nothing
    }
}
