package com.raisecaterror.meowdisplay.core.controls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** With TalkBack on, the Mac picture never turns TalkBack's own gestures into Mac input. */
class ScreenReaderPictureTouchTest {
    @Test fun withoutAScreenReaderThePictureTakesTouches() {
        val p = ScreenReaderPictureTouch(screenReaderRunning = false)
        assertTrue(p.picturePassesTouches)
        assertNull(p.directTouchActionTurnsOn)
    }

    @Test fun aScreenReaderBlocksTouchesUntilDirectTouch() {
        var p = ScreenReaderPictureTouch(screenReaderRunning = true)
        assertFalse(p.picturePassesTouches)
        assertEquals(true, p.directTouchActionTurnsOn)
        p = p.withDirectTouch(true)
        assertTrue(p.picturePassesTouches)
        assertEquals(false, p.directTouchActionTurnsOn)
        p = p.withDirectTouch(false)
        assertFalse(p.picturePassesTouches)
    }

    @Test fun directTouchNeverOutlivesTheScreenReader() {
        val p = ScreenReaderPictureTouch(true).withDirectTouch(true).withScreenReader(false).withScreenReader(true)
        assertFalse(p.directTouch)
        assertFalse(p.picturePassesTouches)
    }

    @Test fun directTouchNeedsAScreenReader() {
        assertFalse(ScreenReaderPictureTouch(false).withDirectTouch(true).directTouch)
    }
}
