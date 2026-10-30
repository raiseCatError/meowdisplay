package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.session.PairedMacUser
import com.raisecaterror.meowdisplay.core.session.SenderMessage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Who uses a paired Mac comes only in its welcome; cleaned, capped and absent when hidden. */
class PairedMacUserTest {
    @Test fun welcomeCarriesTheMacsUser() {
        val w = SenderMessage.parse("""{"type":"welcome","pv":2,"min":2,"user":"Jai Sukka"}""") as SenderMessage.Welcome
        assertEquals("Jai Sukka", w.user)
    }

    @Test fun aWelcomeWithoutItMeansHidden() {
        val w = SenderMessage.parse("""{"type":"welcome","pv":2,"min":2}""") as SenderMessage.Welcome
        assertNull(w.user)
        val notText = SenderMessage.parse("""{"type":"welcome","pv":2,"min":2,"user":42}""") as SenderMessage.Welcome
        assertNull(notText.user)
    }

    @Test fun namesAreCleanedAndCapped() {
        assertEquals("JaiSukka", PairedMacUser.clean("  Jai\nSukka\u0007 "))
        assertNull(PairedMacUser.clean("   "))
        assertEquals(PairedMacUser.MAX, PairedMacUser.clean("x".repeat(200))?.length)
    }
}
