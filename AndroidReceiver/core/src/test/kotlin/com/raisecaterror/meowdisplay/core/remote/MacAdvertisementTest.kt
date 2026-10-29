package com.raisecaterror.meowdisplay.core.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The Mac's discovery TXT (Shared/MacSessionDiscovery.swift) and the Switched Out row it drives. */
class MacAdvertisementTest {
    @Test
    fun parsesTheMacsSessionHints() {
        val advert = MacAdvertisement.parse(mapOf("id" to "MAC-1", "hg" to "a1b2c3d4e5f60718", "hn" to "Family MacBook", "sl" to "Jai", "ss" to "i"))
        assertEquals("MAC-1", advert.installID)
        assertTrue(advert.switchedOut)
        assertEquals("Family MacBook · Jai", advert.sessionTitle)
        assertFalse(MacAdvertisement.parse(mapOf("id" to "MAC-1", "ss" to "a")).switchedOut)
    }

    @Test
    fun aMacWithoutSessionsHasNoLabelAndLabelsNeedAGroup() {
        val plain = MacAdvertisement.parse(mapOf("id" to "MAC-1", "pv" to "22"))
        assertNull(plain.sessionTitle)
        assertFalse(plain.switchedOut)
        val stray = MacAdvertisement.parse(mapOf("sl" to "Jai", "hn" to "Mac"))
        assertNull("a label without a host group is ignored", stray.sessionTitle)
        val hostile = MacAdvertisement.parse(mapOf("hg" to "not hex!", "sl" to "x".repeat(500), "id" to "   "))
        assertNull(hostile.hostGroup)
        assertNull(hostile.installID)
        val long = MacAdvertisement.parse(mapOf("hg" to "ab12", "sl" to "x".repeat(500), "hn" to "y".repeat(500)))
        assertEquals(MacAdvertisement.MAX_LABEL, long.sessionLabel!!.length)
        assertEquals(MacAdvertisement.MAX_HOST_NAME, long.hostName!!.length)
    }

    @Test
    fun aSwitchedOutNearbyMacOffersNothingToTap() {
        val status = MacStatusReducer.reduce(MacFacts(peerID = "MAC-1", name = "Mac", nearby = true, switchedOut = true))
        assertEquals(MacStatus.SwitchedOut, status)
        assertEquals(RowAction.None, status.action)
        assertTrue(status.hint!!.contains("switches back"))
        assertEquals("a live session still wins", RowAction.Show,
            MacStatusReducer.reduce(MacFacts(peerID = "MAC-1", name = "Mac", nearby = true, switchedOut = true, connected = true)).action)
        assertEquals("not nearby: the switched-out hint is stale", MacStatus.NotFound,
            MacStatusReducer.reduce(MacFacts(peerID = "MAC-1", name = "Mac", nearby = false, switchedOut = true)))
    }

    @Test
    fun nearbyMacsMatchPairedOnesByInstallIDBeforeName() {
        val paired = listOf(HomeRows.Paired("MAC-1", "Family MacBook"))
        // Two sessions of one Mac share the Bonjour name; only one is the paired one.
        val nearby = listOf(
            HomeRows.Nearby("Family MacBook", MacAdvertisement(installID = "MAC-2", hostGroup = "ab", sessionLabel = "Guest")),
            HomeRows.Nearby("Family MacBook (2)", MacAdvertisement(installID = "MAC-1", hostGroup = "ab", sessionLabel = "Jai")),
        )
        val rows = HomeRows.buildFromNearby(paired, nearby)
        assertEquals("the other session is offered for pairing, not hidden by the shared name", listOf("Family MacBook"), rows.toPair)
        assertEquals("Family MacBook (2)", HomeRows.nearbyEntry("MAC-1", "Family MacBook", nearby)?.serviceName)
        // An entry whose TXT isn't known yet falls back to the old name match.
        val unresolved = listOf(HomeRows.Nearby("Family MacBook"))
        assertEquals(emptyList<String>(), HomeRows.buildFromNearby(paired, unresolved).toPair)
        assertEquals("Family MacBook", HomeRows.nearbyEntry("MAC-1", "Family MacBook", unresolved)?.serviceName)
        assertNull("another Mac with the same name is not this one", HomeRows.nearbyEntry("MAC-1", "Family MacBook", nearby.take(1)))
    }

    @Test
    fun aConflictingSwitchedOutClaimNeverHidesAPairedMac() {
        // TXT is unauthenticated: a second service claiming MAC-1 as switched out must not win.
        val nearby = listOf(
            HomeRows.Nearby("Family MacBook", MacAdvertisement(installID = "MAC-1", switchedOut = true)),
            HomeRows.Nearby("Family MacBook (2)", MacAdvertisement(installID = "MAC-1")),
        )
        assertEquals("Family MacBook (2)", HomeRows.nearbyEntry("MAC-1", "Family MacBook", nearby)?.serviceName)
        val twins = listOf(
            HomeRows.Nearby("Imposter", MacAdvertisement(installID = "MAC-1")),
            HomeRows.Nearby("Family MacBook", MacAdvertisement(installID = "MAC-1")),
        )
        assertEquals("among equal claims the paired name wins", "Family MacBook", HomeRows.nearbyEntry("MAC-1", "Family MacBook", twins)?.serviceName)
    }
}
