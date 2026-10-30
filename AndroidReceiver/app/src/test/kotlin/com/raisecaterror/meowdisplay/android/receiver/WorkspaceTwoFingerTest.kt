package com.raisecaterror.meowdisplay.android.receiver

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Owner report 2026-10-31: scrolling only panned a zoomed pane. */
class WorkspaceTwoFingerTest {
    @Test
    fun aTwoFingerDragScrollsTheMacWithControlAndMovesThePaneOtherwise() {
        assertTrue(WorkspaceTwoFinger.scrollsMac(isPinch = false, inputReachesMac = true, moveViewActive = false))
        assertFalse("a pinch zooms the pane", WorkspaceTwoFinger.scrollsMac(isPinch = true, inputReachesMac = true, moveViewActive = false))
        assertFalse("View Only: pan stays local", WorkspaceTwoFinger.scrollsMac(isPinch = false, inputReachesMac = false, moveViewActive = false))
        assertFalse("Move View moves the view", WorkspaceTwoFinger.scrollsMac(isPinch = false, inputReachesMac = true, moveViewActive = true))
    }
}
