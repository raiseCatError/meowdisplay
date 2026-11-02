package com.raisecaterror.meowdisplay.core.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteStatusTest {
    private val saved = RemoteEndpoint("mac.tailnet.ts.net", 9003)
    private fun facts(
        nearby: Boolean = false, remote: RemoteEndpoint? = null, connected: Boolean = false, route: RouteInfo? = null,
        awaiting: Boolean = false, localPending: Boolean = false, attempt: RemoteAttempt? = null,
    ) = MacFacts("A", "Studio", nearby, remote, connected, route, awaiting, localPending, attempt)

    private fun status(facts: MacFacts) = MacStatusReducer.reduce(facts) { if (it == "B") "Office Mac" else null }

    @Test
    fun aMacSeenOnBonjourIsAvailableLocally() {
        val s = status(facts(nearby = true))
        assertEquals(MacStatus.AvailableLocally, s)
        assertEquals("Nearby", s.text)
        assertEquals(RowAction.Connect, s.action)
    }

    @Test
    fun aSavedAddressWithoutAnAttemptIsSavedRemote() {
        val s = status(facts(remote = saved))
        assertEquals("Saved remote · mac.tailnet.ts.net", s.text)
        assertEquals(RowAction.Connect, s.action)
        assertEquals("nothing known", MacStatus.NotFound, status(facts()))
    }

    @Test
    fun nearbyAndSavedIsOneStatusThatPrefersTheLocalPath() {
        assertEquals(MacStatus.AvailableLocally, status(facts(nearby = true, remote = saved)))
    }

    @Test
    fun aKnockInFlightOrWaitingForTheDialBackIsConnecting() {
        assertEquals("Contacting your Mac…", status(facts(remote = saved, attempt = RemoteAttempt.Knocking(false))).text)
        assertEquals("Waiting for your Mac to connect…", status(facts(remote = saved, attempt = RemoteAttempt.WaitingForDialBack)).text)
        assertEquals("Reconnecting…", status(facts(remote = saved, attempt = RemoteAttempt.Knocking(true))).text)
        assertEquals("Reconnecting…", status(facts(remote = saved, attempt = RemoteAttempt.Recovering)).text)
        assertEquals(RowAction.Cancel, status(facts(remote = saved, attempt = RemoteAttempt.WaitingForDialBack)).action)
        assertEquals("Asking it to connect…", status(facts(nearby = true, localPending = true)).text)
    }

    @Test
    fun theMacWaitingOnItsOwnUserNeedsApprovalOnTheMac() {
        val s = status(facts(awaiting = true, remote = saved))
        assertEquals("Needs approval on your Mac", s.text)
        assertEquals(RowAction.Cancel, s.action)
    }

    @Test
    fun aLiveSessionShowsItsRoute() {
        val remote = RouteInfo(RouteKind.Tailscale, remote = true)
        assertEquals("Connected · Remote · Tailscale", status(facts(connected = true, route = remote)).text)
        assertEquals("Connected · Local", status(facts(connected = true, route = RouteInfo(RouteKind.WiFi, remote = false))).text)
        assertEquals("Connected · Remote", status(facts(connected = true, route = RouteInfo(RouteKind.Other, remote = true))).text)
        assertEquals("Connected", status(facts(connected = true)).text)
        assertEquals("a live session outranks any stale attempt", "Connected · Local",
            status(facts(connected = true, route = RouteInfo(RouteKind.WiFi, false), attempt = RemoteAttempt.DialBackMissed)).text)
        assertEquals(RowAction.Show, status(facts(connected = true)).action)
    }

    @Test
    fun everyKnockFailureHasItsOwnHonestReason() {
        val texts = OfflineReason.entries.map { status(facts(remote = saved, attempt = RemoteAttempt.Offline(it))) }
        assertEquals(listOf(
            "Offline · address not found", "Offline · timed out", "Offline · connection refused", "Offline · no route", "Offline · couldn't connect",
        ), texts.map { it.text })
        assertTrue(texts.all { it.isFailure && it.action == RowAction.Retry && it.hint != null })
    }

    @Test
    fun aDifferentMacAtTheAddressIsNamedWhenItIsAnotherPairedMac() {
        val named = status(facts(remote = saved, attempt = RemoteAttempt.DifferentMac("B")))
        assertEquals("Connection failed: different Mac at this address", named.text)
        assertTrue(named.hint!!.contains("Office Mac"))
        assertTrue(named.hint!!.contains("Nothing was connected"))
        val unknown = status(facts(remote = saved, attempt = RemoteAttempt.DifferentMac(null)))
        assertTrue(!unknown.hint!!.contains("Office"))
        assertEquals(RowAction.Retry, unknown.action)
    }

    @Test
    fun aDialBackThatNeverCameSaysSoWithAHint() {
        val s = status(facts(remote = saved, attempt = RemoteAttempt.DialBackMissed))
        assertEquals("The Mac didn't connect back", s.text)
        assertTrue(s.hint!!.contains("awake"))
        assertTrue(s.hint!!.contains("Auto-Reconnect"))
        assertEquals(RowAction.Retry, s.action)
    }

    @Test
    fun aMacThatNoLongerAcceptsThisDeviceSaysSo() {
        val s = status(facts(remote = saved, attempt = RemoteAttempt.NotAccepted))
        assertEquals("This Mac doesn't accept this device", s.text)
        assertTrue(s.hint!!.contains("Forget"))
    }

    @Test
    fun aStaleFailureYieldsToTheMacAppearingLocally() {
        assertEquals(MacStatus.AvailableLocally, status(facts(nearby = true, remote = saved, attempt = RemoteAttempt.Offline(OfflineReason.TimedOut))))
        assertNull(status(facts(nearby = true)).hint)
    }

    @Test
    fun oneRowPerPeerIDHoweverTheMacWasFound() {
        val rows = HomeRows.build(
            paired = listOf(HomeRows.Paired("A", "Studio"), HomeRows.Paired("B", "Office"), HomeRows.Paired("A", "Studio")),
            nearbyNames = listOf("Studio", "Guest Mac", "Guest Mac"),
        )
        assertEquals(listOf("A", "B"), rows.paired.map { it.peerID })
        assertEquals("a nearby paired Mac is not listed again to pair", listOf("Guest Mac"), rows.toPair)
    }

    @Test
    fun `a Mac that macOS blocks from dialing back says where to fix it`() {
        val advert = MacAdvertisement.parse(mapOf("id" to "A6DEFD3A-EFF6-4BAC-8FE9-7987E8293BD1", "lnd" to "1"))
        assertTrue(advert.localNetworkBlocked)
        val status = MacStatusReducer.reduce(MacFacts(peerID = "p", name = "Mac", nearby = true, macLocalNetworkBlocked = true, localConnectPending = true))
        assertEquals(MacStatus.MacLocalNetworkBlocked, status)
        assertTrue(status.hint!!.contains("Local Network"))
        assertEquals("a live session wins", MacStatus.Connected(null),
            MacStatusReducer.reduce(MacFacts(peerID = "p", name = "Mac", nearby = true, macLocalNetworkBlocked = true, connected = true)))
        assertTrue(!MacAdvertisement.parse(mapOf("id" to "x")).localNetworkBlocked)
    }
}
