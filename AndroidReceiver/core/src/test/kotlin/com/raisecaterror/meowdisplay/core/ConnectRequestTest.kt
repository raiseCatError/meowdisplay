package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.session.ConnectRequestState
import com.raisecaterror.meowdisplay.core.session.DisplayMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** C4 F-04: a paired Mac gets Connect (receiver-initiated), with the PROTOCOL 6.9 limits. */
class ConnectRequestTest {
    @Test
    fun tokenIsOneShotAndShortLived() {
        val s = ConnectRequestState()
        val r = s.request("mac-a", DisplayMode.Extend, now = 1_000)
        assertEquals(16, r.token.length)
        assertEquals(r.token, s.token(1_000))
        assertEquals(r.token, s.token(1_000 + ConnectRequestState.TOKEN_MS - 1))
        assertNull("withdrawn after 8 s", s.token(1_000 + ConnectRequestState.TOKEN_MS))
        val again = s.request("mac-a", null, now = 20_000)
        assertNotEquals("every Connect publishes a fresh token", r.token, again.token)
    }

    @Test
    fun requestedModeGoesOnlyToTheMacThatWasAskedWhileTheRequestStands() {
        val s = ConnectRequestState()
        s.request("mac-a", DisplayMode.Mirror, now = 0)
        assertEquals(DisplayMode.Mirror, s.requestedMode("mac-a", 1_000))
        assertNull("another Mac never gets it", s.requestedMode("mac-b", 1_000))
        assertNull("no peer yet: nothing", s.requestedMode(null, 1_000))
        assertNull("expired after 30 s", s.requestedMode("mac-a", ConnectRequestState.REQUEST_MS))
        assertTrue(s.isPending("mac-a", 29_999))
        assertFalse(s.isPending("mac-a", 30_000))
    }

    @Test
    fun clearingOneMacLeavesAnotherMacsRequest() {
        val s = ConnectRequestState()
        s.request("mac-a", DisplayMode.Extend, now = 0)
        s.clear("mac-b")
        assertTrue(s.isPending("mac-a", 1))
        s.clear("mac-a")
        assertFalse(s.isPending("mac-a", 1))
        assertNull(s.token(1))
        s.request("mac-a", null, now = 0)
        s.clear()
        assertNull(s.requestedMode("mac-a", 1))
    }
}
