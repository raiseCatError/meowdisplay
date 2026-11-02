package com.raisecaterror.meowdisplay.core.tls

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/** Same vector as MacShortIDTests: Android and Apple devices show the same ID for a Mac. */
class PinnedTlsShortIdTest {
    @Test fun knownVectorMatchesApple() {
        assertEquals("1764", PinnedTls.shortId(ByteArray(64) { it.toByte() }))
    }

    @Test fun differentKeysDiffer() {
        assertNotEquals(PinnedTls.shortId(ByteArray(64) { it.toByte() }), PinnedTls.shortId(ByteArray(64) { (it xor 0x5A).toByte() }))
    }
}
