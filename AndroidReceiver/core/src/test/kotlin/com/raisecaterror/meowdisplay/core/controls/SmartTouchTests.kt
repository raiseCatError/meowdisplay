package com.raisecaterror.meowdisplay.core.controls

import com.raisecaterror.meowdisplay.core.controls.PointerTouchSample.Phase
import org.junit.Assert.*
import org.junit.Test
import kotlin.math.hypot

class SmartTouchTests {
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

    private fun smartEngine(): PointerGestureEngine {
        val engine = PointerGestureEngine()
        engine.smartTouchEnabled = true
        return engine
    }

    /** Touch down at (100,100) and return the probe id it asked for. */
    private fun beginProbedTouch(engine: PointerGestureEngine, id: Int = 1, t: Double = 0.0): Int? {
        val out = engine.handle(sample(id, Phase.Began, view = CGPoint(100.0, 100.0), norm = CGPoint(0.2, 0.2), t = t))
        if (out.size != 1) return null
        val cmd = out[0] as? PointerCommand.ProbeScrollTarget ?: return null
        assertEquals(0.2, cmd.x, 1e-9)
        assertEquals(0.2, cmd.y, 1e-9)
        return cmd.id
    }

    private val holdDeadline = PointerGestureConfig.smartTouchTitleBarHoldDelay

    /** Touch down on a title bar the Mac recognized; returns what the probe reply emitted. */
    private fun beginTitleBarHold(engine: PointerGestureEngine, id: Int = 1, t: Double = 0.0): List<PointerCommand> {
        val probe = unwrap(beginProbedTouch(engine, id = id, t = t))
        return engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.WindowDrag)
    }



    // MARK: - Off / Trackpad: exact existing path

    @Test
    fun testDisabledSmartTouchNeverProbesAndKeepsDirectTouch() {
        val engine = PointerGestureEngine()
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Began, view = CGPoint(100.0, 100.0),
                                            norm = CGPoint(0.2, 0.2), t = 0.0)))
        val moved = engine.handle(sample(1, Phase.Moved, view = CGPoint(150.0, 100.0),
                                         norm = CGPoint(0.4, 0.2), t = 0.01))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.4, 0.2)), moved)
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
    }


    @Test
    fun testTrackpadIgnoresSmartTouch() {
        val engine = smartEngine()
        engine.setInputMode(PointerInputMode.Trackpad)
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Began, view = CGPoint(100.0, 100.0), t = 0.0)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Moved, view = CGPoint(150.0, 100.0), t = 0.01)))
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)
        // A stray reply can't change anything either.
        assertEquals(emptyList<PointerCommand>(), engine.resolveSmartTouchProbe(id = 1, target = SmartTouchTarget.Scroll))
        assertEquals(PointerEngineMode.RelativePointerSession, engine.mode)
    }


    // MARK: - Classification outcomes

    @Test
    fun testScrollableTargetTurnsOneFingerSwipeIntoScroll() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        assertEquals(emptyList<PointerCommand>(), engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll))   // no movement yet
        val first = engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0, 130.0), t = 0.03))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2), PointerCommand.Scroll(0.0, 30.0)), first)
        assertEquals(PointerEngineMode.SmartScroll, engine.mode)
        assertEquals(listOf(PointerCommand.Scroll(0.0, 20.0)), engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0, 150.0), t = 0.04)))
        assertEquals(listOf(PointerCommand.ScrollEnded(true)), engine.handle(sample(1, Phase.Ended, view = CGPoint(100.0, 150.0), t = 0.05)))
        assertEquals(PointerEngineMode.Idle, engine.mode)
        assertNull(engine.heldMouseButton)
    }


    @Test
    fun testCancelledSmartScrollEndsWithoutMomentum() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
        engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0, 130.0), t = 0.03))
        assertEquals(listOf(PointerCommand.ScrollEnded(false)), engine.handle(sample(1, Phase.Cancelled, view = CGPoint(100.0, 130.0), t = 0.04)))
    }


    @Test
    fun testNonScrollableTargetFallsBackToDirectTouch() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = null)
        val moved = engine.handle(sample(1, Phase.Moved, view = CGPoint(150.0, 100.0),
                                         norm = CGPoint(0.4, 0.2), t = 0.03))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.4, 0.2)), moved)
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
    }


    @Test
    fun testLateReplyCommitsTheWithheldMovement() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        // Crossed drag slop before the Mac answered — withheld, not committed.
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0, 130.0), t = 0.02)))
        assertEquals(PointerEngineMode.FirstTouchPending, engine.mode)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2), PointerCommand.Scroll(0.0, 30.0)), engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll))
        assertEquals(PointerEngineMode.SmartScroll, engine.mode)
    }


    @Test
    fun testLateNegativeReplyCommitsDirectTouch() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.handle(sample(1, Phase.Moved, view = CGPoint(150.0, 100.0), norm = CGPoint(0.4, 0.2), t = 0.02))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.4, 0.2)), engine.resolveSmartTouchProbe(id = probe, target = null))
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
    }


    /// No reply at all (lookup failed, Mac never answered) — the existing
    /// arbitration window commits ordinary Direct Touch.
    @Test
    fun testMissingReplyFallsBackAfterArbitrationWindow() {
        val engine = smartEngine()
        unwrap(beginProbedTouch(engine))
        engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0, 130.0), norm = CGPoint(0.2, 0.3), t = 0.02))
        val out = engine.poll(now = PointerGestureConfig.firstTouchArbitrationWindow)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.3)), out)
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
    }


    @Test
    fun testStaleReplyIsIgnored() {
        val engine = smartEngine()
        val firstProbe = unwrap(beginProbedTouch(engine, id = 1))
        engine.handle(sample(1, Phase.Ended, view = CGPoint(100.0, 100.0), t = 0.05))   // a tap
        engine.poll(now = 1.0)                                                          // flushed
        val secondProbe = unwrap(beginProbedTouch(engine, id = 2, t = 2.0))
        assertNotEquals(secondProbe, firstProbe)
        assertEquals(emptyList<PointerCommand>(), engine.resolveSmartTouchProbe(id = firstProbe, target = SmartTouchTarget.Scroll))
        val moved = engine.handle(sample(2, Phase.Moved, view = CGPoint(100.0, 130.0), t = 2.01))
        assertEquals("still waiting on its own probe", emptyList<PointerCommand>(), moved)
    }


    // MARK: - Intent lock

    @Test
    fun testScrollIntentStaysLockedUntilLift() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
        engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0, 130.0), t = 0.03))
        // A second finger, a pause, and more movement never turn it into
        // a pointer move or drag.
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(2, Phase.Began, view = CGPoint(200.0, 100.0), t = 0.1)))
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 2.0))
        assertEquals(listOf(PointerCommand.Scroll(0.0, 10.0)), engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0, 140.0), t = 2.1)))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(2, Phase.Moved, view = CGPoint(250.0, 100.0), t = 2.2)))
        assertEquals(PointerEngineMode.SmartScroll, engine.mode)
    }


    @Test
    fun testDirectIntentStaysLockedEvenIfAReplyArrivesLater() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.poll(now = PointerGestureConfig.firstTouchArbitrationWindow)   // held still: Direct Touch
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
        assertEquals(emptyList<PointerCommand>(), engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll))
        val moved = engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0, 150.0),
                                         norm = CGPoint(0.2, 0.4), t = 0.3))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.4)), moved)
    }


    // MARK: - Scroll axes

    @Test
    fun testHorizontalSwipeScrollsHorizontallyOnly() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2), PointerCommand.Scroll(-30.0, 0.0)), engine.handle(sample(1, Phase.Moved, view = CGPoint(70.0, 103.0), t = 0.03)))
        assertEquals(listOf(PointerCommand.Scroll(-20.0, 0.0)), engine.handle(sample(1, Phase.Moved, view = CGPoint(50.0, 108.0), t = 0.04)))
        // Pure vertical drift on a horizontal lock sends nothing.
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Moved, view = CGPoint(50.0, 112.0), t = 0.05)))
    }


    @Test
    fun testVerticalSwipeIgnoresSidewaysDrift() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2), PointerCommand.Scroll(0.0, 30.0)), engine.handle(sample(1, Phase.Moved, view = CGPoint(104.0, 130.0), t = 0.03)))
        assertEquals(listOf(PointerCommand.Scroll(0.0, 10.0)), engine.handle(sample(1, Phase.Moved, view = CGPoint(110.0, 140.0), t = 0.04)))
    }


    @Test
    fun testDiagonalSwipeKeepsCarryingBothAxes() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2), PointerCommand.Scroll(-15.0, -20.0)), engine.handle(sample(1, Phase.Moved, view = CGPoint(85.0, 80.0), t = 0.03)))
        assertEquals(listOf(PointerCommand.Scroll(-25.0, -30.0)), engine.handle(sample(1, Phase.Moved, view = CGPoint(60.0, 50.0), t = 0.04)))
        assertEquals(listOf(PointerCommand.ScrollEnded(true)), engine.handle(sample(1, Phase.Ended, view = CGPoint(60.0, 50.0), t = 0.05)))
    }


    @Test
    fun testDiagonalSwipePansFreely() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2), PointerCommand.Scroll(20.0, 20.0)), engine.handle(sample(1, Phase.Moved, view = CGPoint(120.0, 120.0), t = 0.03)))
        assertEquals(listOf(PointerCommand.Scroll(10.0, 0.0)), engine.handle(sample(1, Phase.Moved, view = CGPoint(130.0, 120.0), t = 0.04)))
    }


    // MARK: - Long-press override

    @Test
    fun testLongPressOnScrollableTargetSwitchesToDirectTouchWithFeedback() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
        // The arbitration window no longer commits a confidently
        // classified touch — the long press does.
        assertEquals(PointerGestureConfig.smartTouchLongPressDelay - 0.05, engine.pollDelay(now = 0.05) ?: 0.0, 1e-9)
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = PointerGestureConfig.firstTouchArbitrationWindow))
        assertEquals(PointerEngineMode.FirstTouchPending, engine.mode)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2), PointerCommand.SmartTouchFeedback(SmartTouchFeedback.DirectTouchOverride)), engine.poll(now = PointerGestureConfig.smartTouchLongPressDelay))
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
        // From here it is plain Direct Touch: movement moves the pointer.
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.4)), engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0, 150.0),
                                            norm = CGPoint(0.2, 0.4), t = 0.5)))
    }


    @Test
    fun testPauseShorterThanLongPressStillScrolls() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
        engine.poll(now = 0.3)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2), PointerCommand.Scroll(0.0, 30.0)), engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0, 130.0), t = 0.32)))
        assertEquals(PointerEngineMode.SmartScroll, engine.mode)
    }


    @Test
    fun testReleaseAfterArbitrationWindowIsStillNotAClick() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2)), engine.handle(sample(1, Phase.Ended, view = CGPoint(100.0, 100.0),
                                            norm = CGPoint(0.2, 0.2), t = 0.3)))
        assertEquals(PointerEngineMode.Idle, engine.mode)
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 1.0))
    }


    @Test
    fun testNoFeedbackWithoutAConfidentTarget() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = null)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2)), engine.poll(now = PointerGestureConfig.firstTouchArbitrationWindow))
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
    }


    @Test
    fun testRecognizedTitleBarStartsTheHoldInsteadOfDragging() {
        val engine = smartEngine()
        assertEquals(listOf(PointerCommand.SmartTouchFeedback(SmartTouchFeedback.TitleBarHoldBegan(holdDeadline))), beginTitleBarHold(engine))
        assertEquals(PointerEngineMode.FirstTouchPending, engine.mode)
        assertNull(engine.heldMouseButton)
        // Neither the arbitration window nor the generic long press
        // commits it — the title bar hold does.
        assertEquals(holdDeadline - 0.05, engine.pollDelay(now = 0.05) ?: 0.0, 1e-9)
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = PointerGestureConfig.firstTouchArbitrationWindow))
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = PointerGestureConfig.smartTouchLongPressDelay))
        assertEquals(PointerEngineMode.FirstTouchPending, engine.mode)
        assertNull(engine.heldMouseButton)
    }


    @Test
    fun testTitleBarHoldArmsTheDragThenTheWindowFollowsUntilLift() {
        val engine = smartEngine()
        beginTitleBarHold(engine)
        // Small wobble inside the slop keeps the hold alive.
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Moved, view = CGPoint(106.0, 104.0),
                                            norm = CGPoint(0.21, 0.21), t = 0.2)))
        val armed = engine.poll(now = holdDeadline)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2), PointerCommand.MouseDown(PointerButton.Left, 1),
                               PointerCommand.SmartTouchFeedback(SmartTouchFeedback.WindowDragArmed)), armed)
        assertEquals(PointerEngineMode.LeftDragHeld, engine.mode)
        assertEquals(PointerButton.Left, engine.heldMouseButton)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.4, 0.25)), engine.handle(sample(1, Phase.Moved, view = CGPoint(160.0, 110.0),
                                            norm = CGPoint(0.4, 0.25), t = 0.6)))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.5, 0.35)), engine.handle(sample(1, Phase.Moved, view = CGPoint(200.0, 150.0),
                                            norm = CGPoint(0.5, 0.35), t = 0.7)))
        assertEquals("nothing re-arms or presses again", emptyList<PointerCommand>(), engine.poll(now = 0.8))
        assertEquals(listOf(PointerCommand.MouseUp(PointerButton.Left, 0)), engine.handle(sample(1, Phase.Ended, view = CGPoint(200.0, 150.0), t = 0.9)))
        assertNull(engine.heldMouseButton)
        assertEquals(PointerEngineMode.Idle, engine.mode)
    }


    @Test
    fun testMouseDownHappensExactlyOncePerTitleBarDrag() {
        val engine = smartEngine()
        beginTitleBarHold(engine)
        var all = engine.poll(now = holdDeadline)
        for (step in 1..5) {
            all += engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0 + step.toDouble() * 20.0, 100.0),
                                        norm = CGPoint(0.2 + step.toDouble() * 0.05, 0.2),
                                        t = holdDeadline + step.toDouble() * 0.01))
            all += engine.poll(now = holdDeadline + step.toDouble() * 0.01)
        }
        all += engine.handle(sample(1, Phase.Ended, view = CGPoint(200.0, 100.0), t = 1.0))
        assertEquals(1, all.count { it == PointerCommand.MouseDown(PointerButton.Left, 1) })
        assertEquals(1, all.count { it is PointerCommand.MouseUp })
        assertEquals(1, all.count { it == PointerCommand.SmartTouchFeedback(SmartTouchFeedback.WindowDragArmed) })
    }


    @Test
    fun testMovingBeforeTheHoldArmsFallsBackToDirectTouch() {
        val engine = smartEngine()
        beginTitleBarHold(engine)
        val moved = engine.handle(sample(1, Phase.Moved, view = CGPoint(130.0, 100.0),
                                         norm = CGPoint(0.3, 0.2), t = 0.2))
        assertEquals(listOf(PointerCommand.SmartTouchFeedback(SmartTouchFeedback.TitleBarHoldCancelled), PointerCommand.MoveAbsolute(0.3, 0.2)), moved)
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
        assertNull(engine.heldMouseButton)
        // The deadline passing later changes nothing.
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 1.0))
        assertNull(engine.heldMouseButton)
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(1, Phase.Ended, view = CGPoint(130.0, 100.0), t = 1.1)))
    }


    @Test
    fun testTitleBarReplyAfterMovementNeverDrags() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.handle(sample(1, Phase.Moved, view = CGPoint(130.0, 100.0), norm = CGPoint(0.3, 0.2), t = 0.02))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.3, 0.2)), engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.WindowDrag))
        assertEquals(PointerEngineMode.AbsolutePointer, engine.mode)
        assertNull(engine.heldMouseButton)
    }


    @Test
    fun testTapOnTitleBarIsStillAClick() {
        val engine = smartEngine()
        beginTitleBarHold(engine)
        assertEquals(listOf(PointerCommand.SmartTouchFeedback(SmartTouchFeedback.TitleBarHoldCancelled), PointerCommand.MoveAbsolute(0.2, 0.2)), engine.handle(sample(1, Phase.Ended, view = CGPoint(101.0, 100.0),
                                            norm = CGPoint(0.2, 0.2), t = 0.08)))
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 1),
                                             PointerCommand.MouseUp(PointerButton.Left, 1)), engine.poll(now = 1.0))
        assertNull(engine.heldMouseButton)
    }


    @Test
    fun testReleasingMidHoldStopsTheBuildUpWithoutAClick() {
        val engine = smartEngine()
        beginTitleBarHold(engine)
        assertEquals(listOf(PointerCommand.SmartTouchFeedback(SmartTouchFeedback.TitleBarHoldCancelled), PointerCommand.MoveAbsolute(0.2, 0.2)), engine.handle(sample(1, Phase.Ended, view = CGPoint(100.0, 100.0),
                                            norm = CGPoint(0.2, 0.2), t = 0.3)))
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 1.0))
        assertNull(engine.heldMouseButton)
    }


    @Test
    fun testSecondFingerOrResetCancelsTheHold() {
        var engine = smartEngine()
        beginTitleBarHold(engine)
        assertEquals(listOf(PointerCommand.SmartTouchFeedback(SmartTouchFeedback.TitleBarHoldCancelled)), engine.handle(sample(2, Phase.Began, view = CGPoint(140.0, 100.0), t = 0.1)))
        assertEquals(PointerEngineMode.TwoFingerPending, engine.mode)

        engine = smartEngine()
        beginTitleBarHold(engine)
        assertEquals(listOf(PointerCommand.SmartTouchFeedback(SmartTouchFeedback.TitleBarHoldCancelled)), engine.reset())
        assertEquals(emptyList<PointerCommand>(), engine.poll(now = 1.0))
        assertNull(engine.heldMouseButton)
    }


    @Test
    fun testGenericLongPressStillSwitchesToDirectTouch() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        assertEquals("no title bar build-up for an ordinary target", emptyList<PointerCommand>(), engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2), PointerCommand.SmartTouchFeedback(SmartTouchFeedback.DirectTouchOverride)), engine.poll(now = PointerGestureConfig.smartTouchLongPressDelay))
        assertNull(engine.heldMouseButton)
    }


    /// Haptics settings live only on the receiver: the engine emits the same
    /// commands either way, and the policy only silences feedback.
    @Test
    fun testHapticsSettingsChangeFeedbackOnly() {
        assertTrue(SmartTouchHapticPolicy.isEnabled(haptics = true, smartTouchHaptics = true))
        assertFalse(SmartTouchHapticPolicy.isEnabled(haptics = true, smartTouchHaptics = false))
        assertFalse(SmartTouchHapticPolicy.isEnabled(haptics = false, smartTouchHaptics = true))
        assertFalse(SmartTouchHapticPolicy.isEnabled(haptics = false, smartTouchHaptics = false))
        val engine = smartEngine()
        beginTitleBarHold(engine)
        val armed = engine.poll(now = holdDeadline).filter { it !is PointerCommand.SmartTouchFeedback }
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2), PointerCommand.MouseDown(PointerButton.Left, 1)), armed)
    }


    // MARK: - Taps and tap-hold-drag

    @Test
    fun testTapOnScrollableTargetIsStillAClick() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2)), engine.handle(sample(1, Phase.Ended, view = CGPoint(102.0, 101.0),
                                            norm = CGPoint(0.2, 0.2), t = 0.08)))
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 1),
                                             PointerCommand.MouseUp(PointerButton.Left, 1)), engine.poll(now = 1.0))
    }


    @Test
    fun testDoubleAndTripleTapsKeepClickCounts() {
        val engine = smartEngine()
        for (i in 0 until 3) {
            val t = i.toDouble() * 0.15
            val out = engine.handle(sample(i + 1, Phase.Began, view = CGPoint(100.0, 100.0), t = t))
            val probe = out.filterIsInstance<PointerCommand.ProbeScrollTarget>().firstOrNull()?.id
            if (probe != null) {
                engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
            }
            engine.handle(sample(i + 1, Phase.Ended, view = CGPoint(100.0, 100.0), t = t + 0.05))
        }
        assertEquals(listOf(PointerCommand.MouseDown(PointerButton.Left, 3),
                                             PointerCommand.MouseUp(PointerButton.Left, 3)), engine.poll(now = 5.0))
    }


    @Test
    fun testTapThenHoldDragOverScrollableAreaIsStillALeftDrag() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
        engine.handle(sample(1, Phase.Ended, view = CGPoint(100.0, 100.0), t = 0.05))
        // The continuing touch does not probe — tap-then-hold is a drag.
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(2, Phase.Began, view = CGPoint(100.0, 100.0),
                                            norm = CGPoint(0.2, 0.2), t = 0.15)))
        val drag = engine.handle(sample(2, Phase.Moved, view = CGPoint(100.0, 130.0),
                                        norm = CGPoint(0.2, 0.3), t = 0.2))
        assertEquals(listOf(PointerCommand.MoveAbsolute(0.2, 0.2), PointerCommand.MouseDown(PointerButton.Left, 1), PointerCommand.MoveAbsolute(0.2, 0.3)), drag)
        assertEquals(PointerEngineMode.LeftDragHeld, engine.mode)
    }


    // MARK: - Multi-finger paths untouched

    @Test
    fun testTwoFingerStartStillFormsAFreshChord() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        assertEquals(emptyList<PointerCommand>(), engine.handle(sample(2, Phase.Began, view = CGPoint(130.0, 100.0), t = 0.02)))
        assertEquals(PointerEngineMode.TwoFingerPending, engine.mode)
        // Late reply for the first finger changes nothing — scroll, pinch
        // and rotation stay with the two-finger recognizer.
        assertEquals(emptyList<PointerCommand>(), engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll))
        assertEquals(PointerEngineMode.TwoFingerPending, engine.mode)
    }


    @Test
    fun testThreeFingerStartStillDefersToSystemGestures() {
        val engine = smartEngine()
        unwrap(beginProbedTouch(engine))
        engine.handle(sample(2, Phase.Began, view = CGPoint(130.0, 100.0), t = 0.01))
        engine.handle(sample(3, Phase.Began, view = CGPoint(160.0, 100.0), t = 0.02))
        assertEquals(PointerEngineMode.DeferredSystemGesture, engine.mode)
    }


    @Test
    fun testResetClearsSmartScroll() {
        val engine = smartEngine()
        val probe = unwrap(beginProbedTouch(engine))
        engine.resolveSmartTouchProbe(id = probe, target = SmartTouchTarget.Scroll)
        engine.handle(sample(1, Phase.Moved, view = CGPoint(100.0, 130.0), t = 0.03))
        assertEquals(emptyList<PointerCommand>(), engine.reset())
        assertEquals(PointerEngineMode.Idle, engine.mode)
    }

    @Test
    fun testSmartTouchDefaultsOnAndMigratesFromOlderSchema() {
        assertTrue(ReceiverControlPreferences().smartTouchEnabled)
        assertTrue(ReceiverControlPreferences().smartTouchLongPressHapticEnabled)
        val blobs = mutableMapOf<String, String>()
        val store = object : PreferenceBlobStore {
            override fun read(key: String) = blobs[key]
            override fun write(key: String, value: String) { blobs[key] = value }
        }
        val old = ReceiverControlPreferences()
        old.version = 13
        old.inputMode = PointerInputMode.Trackpad
        val json = kotlinx.serialization.json.JsonObject(old.toJson() - "smartTouchEnabled" - "smartTouchLongPressHapticEnabled")
        blobs[ReceiverControlPreferencesRepository.DEFAULTS_KEY] = json.toString()
        val repository = ReceiverControlPreferencesRepository(store)
        val loaded = repository.load()
        assertEquals(ReceiverControlPreferences.SCHEMA_VERSION, loaded.version)
        // Schema 16 turns Smart Touch on for pre-release installs once.
        assertTrue(loaded.smartTouchEnabled)
        assertTrue(loaded.smartTouchLongPressHapticEnabled)
        assertEquals("other preferences survive", PointerInputMode.Trackpad, loaded.inputMode)

        val disabled = loaded.deepCopy()
        disabled.smartTouchEnabled = false
        repository.save(disabled)
        assertFalse("a schema-16 choice is never re-migrated", repository.load().smartTouchEnabled)
    }
}
