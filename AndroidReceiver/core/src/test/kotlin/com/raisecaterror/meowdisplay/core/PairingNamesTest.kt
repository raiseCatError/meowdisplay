package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.pairing.PairingNames
import org.junit.Assert.assertEquals
import org.junit.Test

/** The same cases as MacTests/PairingTests `testPeerNamesAreCleanedForDisplay`. */
class PairingNamesTest {
    @Test
    fun peerNamesAreCleanedForDisplay() {
        assertEquals("Jaimoc.elppa", PairingNames.display("Jai\u202Emoc.elppa"))
        assertEquals("MacApproved", PairingNames.display("Mac\u2028Approved\u0007"))
        assertEquals("emoji outside the BMP stay", "Jai's iPhone \uD83D\uDC31", PairingNames.display("Jai's iPhone \uD83D\uDC31"))
        assertEquals("Device", PairingNames.display("\u202E\u2066\u0001"))
        assertEquals("x".repeat(40), PairingNames.display("x".repeat(60)))
    }
}
