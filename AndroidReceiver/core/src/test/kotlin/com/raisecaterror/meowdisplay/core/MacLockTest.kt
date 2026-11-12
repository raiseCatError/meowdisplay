package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.session.MacLockGate
import com.raisecaterror.meowdisplay.core.session.MacLockNotice
import com.raisecaterror.meowdisplay.core.session.MacLockWire
import com.raisecaterror.meowdisplay.core.session.MacScreenPrivacy
import com.raisecaterror.meowdisplay.core.session.SenderMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** `macLockState` parsing and the lock gate (PROTOCOL.md 6.18): anything but a clear "unlocked" is locked. */
class MacLockTest {
    private fun parse(json: String) = (SenderMessage.parse(json) as? SenderMessage.MacLock)?.notice

    @Test
    fun theFourWireStatesParseAndOnlyUnlockedIsUnlocked() {
        assertEquals(MacScreenPrivacy.Unlocked, parse("""{"type":"macLockState","state":"unlocked","remoteUnlock":false}""")!!.state)
        assertEquals(MacScreenPrivacy.Locked, parse("""{"type":"macLockState","state":"locked","remoteUnlock":false}""")!!.state)
        assertEquals(MacScreenPrivacy.SwitchedOut, parse("""{"type":"macLockState","state":"switchedOut"}""")!!.state)
        assertEquals(MacScreenPrivacy.Unknown, parse("""{"type":"macLockState","state":"unknown"}""")!!.state)
        assertFalse(parse("""{"type":"macLockState","state":"unlocked"}""")!!.isLocked)
        for (s in listOf("locked", "switchedOut", "unknown")) assertTrue(s, parse("""{"type":"macLockState","state":"$s"}""")!!.isLocked)
    }

    @Test
    fun anUnrecognisedOrDifferentlyCasedStateFailsClosed() {
        for (s in listOf("sleeping", "Unlocked", "UNLOCKED", " unlocked", "future-state")) {
            val n = parse("""{"type":"macLockState","state":"$s"}""")!!
            assertEquals(s, MacScreenPrivacy.Unknown, n.state)
            assertTrue(s, n.isLocked)
        }
    }

    @Test
    fun malformedNoticesAreIgnoredLikeOnIos() {
        assertNull(SenderMessage.parse("""{"type":"macLockState"}"""))
        assertNull(SenderMessage.parse("""{"type":"macLockState","state":""}"""))
        assertNull(SenderMessage.parse("""{"type":"macLockState","state":true}"""))
        assertNull(SenderMessage.parse("""{"type":"macLockState","state":5}"""))
    }

    @Test
    fun remoteUnlockIsInformationOnlyAndDefaultsToFalse() {
        assertFalse(parse("""{"type":"macLockState","state":"locked"}""")!!.remoteUnlock)
        assertFalse(parse("""{"type":"macLockState","state":"locked","remoteUnlock":"yes"}""")!!.remoteUnlock)
        assertTrue(parse("""{"type":"macLockState","state":"locked","remoteUnlock":true}""")!!.remoteUnlock)
    }

    @Test
    fun theGateStartsUnlockedLocksOnAnythingButUnlockedAndReportsChanges() {
        val gate = MacLockGate()
        assertFalse(gate.locked)
        assertTrue(gate.apply(MacLockNotice(MacScreenPrivacy.Locked)))
        assertTrue(gate.locked)
        assertFalse("locked to switched out is no change in answer", gate.apply(MacLockNotice(MacScreenPrivacy.SwitchedOut)))
        assertTrue(gate.locked)
        assertFalse(gate.apply(MacLockNotice(MacScreenPrivacy.Unknown)))
        assertTrue(gate.locked)
        assertTrue(gate.apply(MacLockNotice(MacScreenPrivacy.Unlocked)))
        assertFalse(gate.locked)
        gate.apply(MacLockNotice(MacScreenPrivacy.Locked))
        gate.reset()
        assertFalse("a new connection starts unlocked", gate.locked)
    }

    @Test
    fun onlySessionLevelControlsPassWhileLocked() {
        assertTrue(MacLockWire.passesWhileLocked("receiverUI"))
        assertTrue(MacLockWire.passesWhileLocked("lockMacResult"))
        for (t in listOf("windowCatalog", "windowThumbnail", "appIcon", "workspaceState", "workspaceView", "workspaceBackdrop",
            "appCatalog", "displayThumbnail", "files", "menu", "menuResult", "appLaunchResult", "windowCloseResult", "clip",
            "cursorImg", "smartTouchProbeResult", "somethingNew")) assertFalse(t, MacLockWire.passesWhileLocked(t))
    }
}
