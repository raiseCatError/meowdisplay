package com.raisecaterror.meowdisplay.core

import com.raisecaterror.meowdisplay.core.pairing.PairedMacCleanup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The same cases as MacTests/KnownDeviceCleanupTests.swift. */
class PairedMacCleanupTest {
    private fun e(id: String, name: String, day: Long?, inUse: Boolean = false) =
        PairedMacCleanup.Entry(id, name, day?.let { it * 86_400_000 }, inUse)

    @Test
    fun keepsTheNewestPairingOfEachNameAndRemovesOlderCopies() {
        val old = PairedMacCleanup.superseded(listOf(e("a", "Studio Mac", 1), e("b", "studio mac ", 5), e("c", "Studio Mac", 3),
            e("d", "MacBook Air", 2), e("x", "Mac mini", null), e("y", "Mac mini", 4)))
        assertEquals(setOf("a", "c", "x"), old.map { it.id }.toSet())
    }

    @Test
    fun neverGuessesAmongPinsWithoutDates() {
        assertTrue("no dates: which is newest isn't known", PairedMacCleanup.superseded(listOf(e("a", "Mac", null), e("b", "Mac", null))).isEmpty())
        val old = PairedMacCleanup.superseded(listOf(e("a", "Mac", null), e("b", "Mac", null), e("c", "Mac", 1)))
        assertEquals("saved before dates were recorded: older than any dated pin", setOf("a", "b"), old.map { it.id }.toSet())
    }

    @Test
    fun neverRemovesAConnectedOrNearbyMac() {
        // The connected one is older: it stays, and the newer offline copy is the old entry.
        val old = PairedMacCleanup.superseded(listOf(e("a", "Mac", 1, inUse = true), e("b", "Mac", 9), e("c", "Mac", 5, inUse = true)))
        assertEquals(listOf("b"), old.map { it.id })
        assertTrue("different names are different Macs", PairedMacCleanup.superseded(listOf(e("a", "Mac", 1), e("b", "Other Mac", 2))).isEmpty())
    }
}
