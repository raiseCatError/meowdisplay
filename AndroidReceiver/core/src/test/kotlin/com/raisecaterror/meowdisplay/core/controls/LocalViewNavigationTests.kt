package com.raisecaterror.meowdisplay.core.controls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Local View Navigation tests from MacTests/PadControlLayoutTests.swift and
 * CustomLayoutRefinementTests.swift that needed the viewport port (ported after it).
 */
class LocalViewNavigationTests {
    private val everything = PadRailComposition.Availability(ControlModifier.entries, keyboardAvailable = true, moveViewAvailable = true)

    @Test
    fun testMoveViewCanBeHiddenAndNeedsLocalNavigation() {
        val visibility = PadStandardControlVisibility()
        visibility.setVisible(false, PadStandardControl.MoveView)
        assertFalse(PadRailComposition.mainGroups(visibility, everything).flatten().contains(CustomControlKind.MoveView))
        val unavailable = everything.copy(moveViewAvailable = false)
        assertFalse(
            "showing the button never bypasses Local View Navigation",
            PadRailComposition.mainGroups(PadStandardControlVisibility(), unavailable).flatten().contains(CustomControlKind.MoveView),
        )
        assertFalse(LocalViewNavigationPolicy.showsMoveView(controlVisible = true, localNavigationAllowed = false, videoEnabled = true))
        assertTrue(LocalViewNavigationPolicy.showsMoveView(controlVisible = true, localNavigationAllowed = true, videoEnabled = true))
    }

    @Test
    fun testLocalNavigationWorksWithInputOff() {
        assertTrue(LocalViewNavigationPolicy.surfaceAcceptsTouches(remoteInputAllowed = false, localNavigationAllowed = true, videoEnabled = true))
        assertFalse(
            "both off: the view is locked",
            LocalViewNavigationPolicy.surfaceAcceptsTouches(remoteInputAllowed = false, localNavigationAllowed = false, videoEnabled = true),
        )
        assertTrue(LocalViewNavigationPolicy.surfaceAcceptsTouches(remoteInputAllowed = true, localNavigationAllowed = false, videoEnabled = true))
        val gate = ReceiverMultiFingerGestureGate(voiceOverRunning = false)
        assertTrue(gate.update(remoteInputAllowed = false, localNavigationAllowed = true))
        assertTrue(gate.isEnabled(ReceiverMultiFingerRecognizer.TwoFingerViewport))
        assertTrue(gate.isEnabled(ReceiverMultiFingerRecognizer.ViewportDoubleTap))
        assertFalse(gate.isEnabled(ReceiverMultiFingerRecognizer.ThreeFingerSwipe))
        assertFalse(gate.isEnabled(ReceiverMultiFingerRecognizer.ThreeFingerTap))
        assertFalse(gate.isEnabled(ReceiverMultiFingerRecognizer.PinchSpread))
        gate.update(remoteInputAllowed = false, localNavigationAllowed = false)
        for (kind in ReceiverMultiFingerRecognizer.entries) assertFalse(gate.isEnabled(kind))
        gate.update(remoteInputAllowed = true, localNavigationAllowed = false)
        assertFalse(gate.isEnabled(ReceiverMultiFingerRecognizer.ViewportDoubleTap))
        assertTrue("remote scrolling still works", gate.isEnabled(ReceiverMultiFingerRecognizer.TwoFingerViewport))
    }

    @Test
    fun testLocalNavigationNeverRoutesAnythingToTheMac() {
        for (intent in TwoFingerGestureIntent.entries) {
            for (localNavigation in listOf(true, false)) {
                for (video in listOf(true, false)) {
                    for (pinch in ReceiverGestureTarget.entries) {
                        for (rotate in ReceiverGestureTarget.entries) {
                            val routes = TwoFingerRoutingPolicy.routes(intent, false, localNavigation, video, pinch, rotate)
                            assertTrue(setOf(TwoFingerRoute.Viewport).containsAll(routes))
                        }
                    }
                }
            }
        }
        assertEquals(
            setOf(TwoFingerRoute.Viewport),
            TwoFingerRoutingPolicy.routes(TwoFingerGestureIntent.ViewportZoomPan, false, true, true, ReceiverGestureTarget.Viewport, ReceiverGestureTarget.Disabled),
        )
    }

    @Test
    fun testDisabledLocalNavigationLeavesRemoteRoutesIntact() {
        assertEquals(
            emptySet<TwoFingerRoute>(),
            TwoFingerRoutingPolicy.routes(TwoFingerGestureIntent.ViewportZoomPan, true, false, true, ReceiverGestureTarget.Viewport, ReceiverGestureTarget.Disabled),
        )
        assertEquals(
            setOf(TwoFingerRoute.AppCommands),
            TwoFingerRoutingPolicy.routes(TwoFingerGestureIntent.ViewportZoomPan, true, false, true, ReceiverGestureTarget.App, ReceiverGestureTarget.Disabled),
        )
        assertEquals(
            setOf(TwoFingerRoute.RemoteScroll),
            TwoFingerRoutingPolicy.routes(TwoFingerGestureIntent.Scroll, true, false, true, ReceiverGestureTarget.Viewport, ReceiverGestureTarget.Disabled),
        )
        assertFalse(LocalViewNavigationPolicy.allowsViewportChanges(localNavigationAllowed = true, videoEnabled = false))
    }
}
