package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.pairing.InMemoryPeerTrustStore
import com.raisecaterror.meowdisplay.core.pairing.PairingAttempt
import com.raisecaterror.meowdisplay.core.pairing.PairingCommitThrottle
import com.raisecaterror.meowdisplay.core.pairing.PairingEnvelope
import com.raisecaterror.meowdisplay.core.pairing.PairingError
import com.raisecaterror.meowdisplay.core.pairing.PairingException
import com.raisecaterror.meowdisplay.core.pairing.PairingTransport
import com.raisecaterror.meowdisplay.core.pairing.PreAuthSlots
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class PreAuthSlotsTest {
    @Test
    fun slotsAreBoundedAndEachReleasesOnce() {
        val slots = PreAuthSlots(2)
        assertNotNull(slots.tryAcquire())
        val second = slots.tryAcquire()
        assertNotNull(second)
        assertNull("every slot taken: the newcomer is refused", slots.tryAcquire())
        second!!.release()
        second.release()   // the commitment arrived, then the attempt ended
        assertEquals(1, slots.inUse)
        assertNotNull("a freed slot is usable again", slots.tryAcquire())
        assertNull(slots.tryAcquire())
    }

    /** A peer that connects and never sends its commitment. */
    private class Silent : PairingTransport {
        var closed = false
        override suspend fun send(envelope: PairingEnvelope) {}
        override suspend fun receive(): PairingEnvelope = awaitCancellation()
        override fun sendLastAndClose(envelope: PairingEnvelope?) { closed = true }
    }

    @Test
    fun aSilentPeerEndsTheAttemptAtTheDeadline() = runTest {
        val attempt = PairingAttempt(
            transport = Silent(), store = InMemoryPeerTrustStore(),
            localID = "android", localName = "Android",
            identitySPKI = ByteArray(91),
        )
        var committed = false
        val error = runCatching {
            attempt.runResponder(PairingCommitThrottle(), decide = { true }, onCommitmentReceived = { committed = true })
        }.exceptionOrNull() as? PairingException
        assertEquals(PairingError.MalformedMessage, error?.error)
        assertEquals(PreAuthSlots.DEADLINE_MS, currentTime)
        assertFalse("no commitment ever arrived", committed)
    }
}
