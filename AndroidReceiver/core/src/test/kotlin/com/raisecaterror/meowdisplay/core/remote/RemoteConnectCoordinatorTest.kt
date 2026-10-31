package com.raisecaterror.meowdisplay.core.remote

import com.raisecaterror.meowdisplay.core.session.DisplayMode
import com.raisecaterror.meowdisplay.core.session.SessionLossReason
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Connect and recovery against a scripted knock transport, on virtual time. */
@OptIn(ExperimentalCoroutinesApi::class)
class RemoteConnectCoordinatorTest {
    private class Call(val peerID: String, val endpoint: RemoteEndpoint, val intent: KnockIntent, val at: Long)

    private class FakeTransport(private val now: () -> Long) : KnockTransport {
        val calls = mutableListOf<Call>()
        var result: KnockResult = KnockResult.Delivered
        var hold: CompletableDeferred<KnockResult>? = null
        var takes = 100L

        override suspend fun send(peerID: String, endpoint: RemoteEndpoint, intent: KnockIntent): KnockResult {
            calls += Call(peerID, endpoint, intent, now())
            hold?.let { return it.await() }
            delay(takes)
            return result
        }
    }

    private class FakeHost : RemoteConnectCoordinator.Host {
        val paired = mutableSetOf("A", "B")
        val nearby = mutableSetOf<String>()
        var autoReconnect = true
        var live: String? = null
        val pending = mutableMapOf<String, DisplayMode?>()
        val logs = mutableListOf<String>()

        override fun isPaired(peerID: String) = peerID in paired
        override fun isNearby(peerID: String) = peerID in nearby
        override fun autoReconnectEnabled() = autoReconnect
        override fun liveSessionPeer() = live
        override fun markConnectPending(peerID: String, mode: DisplayMode?) { pending[peerID] = mode }
        override fun clearConnectPending(peerID: String) { pending.remove(peerID) }
        override fun log(message: String) { logs += message }
    }

    private val endpointA = RemoteEndpoint("mac.tailnet.ts.net", 9003)

    private class Rig(scope: TestScope) {
        val host = FakeHost()
        val store = RemoteMacStore(InMemoryRemoteMacStorage())
        val transport = FakeTransport { scope.currentTime }
        val reported = mutableMapOf<String, RemoteEndpoint>()
        val coordinator = RemoteConnectCoordinator(
            scope.backgroundScope, { scope.currentTime }, store, RemoteKnocker(transport, scope.backgroundScope), host,
            automaticEndpoint = { reported[it] },
        )
        fun attempt(peerID: String = "A") = coordinator.attempts.value[peerID]
    }

    private fun TestScope.rig(save: Boolean = true) = Rig(this).also { if (save) it.store.save("A", endpointA) }

    // MARK: - Connect

    @Test
    fun aReportedAddressIsUsedOnlyWhenNoneWasTyped() = runTest {
        val rig = rig(save = false)
        assertEquals(RemoteConnectCoordinator.ConnectOutcome.NoSavedAddress, rig.coordinator.connect("A"))
        val reported = RemoteEndpoint("100.101.1.5", RemotePorts.CONNECT_REQUEST)
        rig.reported["A"] = reported
        assertEquals(RemoteConnectCoordinator.ConnectOutcome.Started, rig.coordinator.connect("A"))
        runCurrent()
        assertEquals(reported, rig.transport.calls.last().endpoint)
        advanceTimeBy(150)
        rig.store.save("A", endpointA)
        rig.coordinator.connect("A")
        runCurrent()
        assertEquals("the typed address wins", endpointA, rig.transport.calls.last().endpoint)
    }

    @Test
    fun connectSendsOneManualKnockAndMarksTheExistingConnectPending() = runTest {
        val rig = rig()
        assertEquals(RemoteConnectCoordinator.ConnectOutcome.Started, rig.coordinator.connect("A", DisplayMode.Extend))
        assertEquals(RemoteAttempt.Knocking(automatic = false), rig.attempt())
        assertEquals("the hello will carry the requested mode, like the local Connect", DisplayMode.Extend, rig.host.pending["A"])
        runCurrent()
        assertEquals(listOf(KnockIntent.Manual), rig.transport.calls.map { it.intent })
        assertEquals(endpointA, rig.transport.calls.single().endpoint)
        advanceTimeBy(150)
        runCurrent()
        assertEquals(RemoteAttempt.WaitingForDialBack, rig.attempt())
        assertTrue("still pending while the Mac is asked", "A" in rig.host.pending)
    }

    @Test
    fun withoutASavedAddressOrAPairingNothingIsSent() = runTest {
        val rig = rig(save = false)
        assertEquals(RemoteConnectCoordinator.ConnectOutcome.NoSavedAddress, rig.coordinator.connect("A"))
        rig.store.save("B", endpointA)
        rig.host.paired.remove("B")
        assertEquals(RemoteConnectCoordinator.ConnectOutcome.NotPaired, rig.coordinator.connect("B"))
        runCurrent()
        assertTrue(rig.transport.calls.isEmpty())
        assertTrue(rig.coordinator.attempts.value.isEmpty())
        assertTrue(rig.host.pending.isEmpty())
    }

    @Test
    fun aDialBackThatNeverArrivesIsReportedAfterTwentySeconds() = runTest {
        val rig = rig()
        rig.coordinator.connect("A")
        advanceTimeBy(200)
        runCurrent()
        assertEquals(RemoteAttempt.WaitingForDialBack, rig.attempt())
        advanceTimeBy(RemoteConnectCoordinator.DIAL_BACK_MS - 500)
        runCurrent()
        assertEquals("not yet", RemoteAttempt.WaitingForDialBack, rig.attempt())
        advanceTimeBy(600)
        runCurrent()
        assertEquals(RemoteAttempt.DialBackMissed, rig.attempt())
        assertTrue("the Connect request is no longer pending", rig.host.pending.isEmpty())
    }

    @Test
    fun aDialBackThatArrivesEndsTheAttemptAndTheTimerChangesNothing() = runTest {
        val rig = rig()
        rig.coordinator.connect("A")
        advanceTimeBy(5_000)
        runCurrent()
        rig.coordinator.onAdmitted("A", remote = true)
        assertNull(rig.attempt())
        advanceTimeBy(60_000)
        runCurrent()
        assertNull("the old timer must not mark a live session as failed", rig.attempt())
    }

    @Test
    fun eachKnockFailureBecomesItsOwnStatus() = runTest {
        val expected = mapOf(
            KnockResult.DnsFailed to RemoteAttempt.Offline(OfflineReason.Dns),
            KnockResult.TimedOut to RemoteAttempt.Offline(OfflineReason.TimedOut),
            KnockResult.Refused to RemoteAttempt.Offline(OfflineReason.Refused),
            KnockResult.Unreachable to RemoteAttempt.Offline(OfflineReason.Unreachable),
            KnockResult.Failed to RemoteAttempt.Offline(OfflineReason.Failed),
            KnockResult.NotAccepted to RemoteAttempt.NotAccepted,
            KnockResult.IdentityMismatch("B") to RemoteAttempt.DifferentMac("B"),
            KnockResult.IdentityMismatch(null) to RemoteAttempt.DifferentMac(null),
        )
        for ((result, attempt) in expected) {
            val rig = rig()
            rig.transport.result = result
            rig.coordinator.connect("A")
            advanceTimeBy(200)
            runCurrent()
            assertEquals("$result", attempt, rig.attempt())
            assertTrue("a failed attempt is not pending any more", rig.host.pending.isEmpty())
            assertEquals("a security failure is never retried: one knock only", 1, rig.transport.calls.size)
            advanceTimeBy(120_000)
            runCurrent()
            assertEquals(1, rig.transport.calls.size)
        }
    }

    @Test
    fun aKnockResultAfterForgetIsIgnored() = runTest {
        val rig = rig()
        rig.transport.hold = CompletableDeferred()
        rig.coordinator.connect("A")
        runCurrent()
        rig.host.paired.remove("A")
        rig.coordinator.onForget("A")
        assertNull("Forget cleared the attempt", rig.attempt())
        assertNull("and the saved address", rig.store.endpoint("A"))
        rig.transport.hold!!.complete(KnockResult.Delivered)
        advanceTimeBy(RemoteConnectCoordinator.DIAL_BACK_MS * 2)
        runCurrent()
        assertNull("a late Delivered must not resurrect the row", rig.attempt())
        assertTrue(rig.host.pending.isEmpty())
    }

    @Test
    fun aKnockResultForAMacThatWasUnpairedWithoutTheCallbackIsIgnoredToo() = runTest {
        val rig = rig()
        rig.transport.hold = CompletableDeferred()
        rig.coordinator.connect("A")
        runCurrent()
        rig.host.paired.remove("A")
        rig.transport.hold!!.complete(KnockResult.Delivered)
        advanceTimeBy(1_000)
        runCurrent()
        assertEquals("still the in-flight state, never a result for a Mac that isn't paired", RemoteAttempt.Knocking(false), rig.attempt())
        advanceTimeBy(RemoteConnectCoordinator.DIAL_BACK_MS * 2)
        assertEquals(RemoteAttempt.Knocking(false), rig.attempt())
    }

    @Test
    fun cancelStopsTheKnockAndALateResultChangesNothing() = runTest {
        val rig = rig()
        rig.transport.hold = CompletableDeferred()
        rig.coordinator.connect("A")
        runCurrent()
        rig.coordinator.cancel("A")
        runCurrent()
        assertNull(rig.attempt())
        assertTrue(rig.host.pending.isEmpty())
        assertTrue("the saved address stays: cancelling is not removing", rig.store.endpoint("A") != null)
        advanceTimeBy(100_000)
        runCurrent()
        assertNull(rig.attempt())
    }

    @Test
    fun tappingConnectAgainJoinsTheKnockInFlightAndOnlyTheLatestTapCounts() = runTest {
        val rig = rig()
        rig.transport.hold = CompletableDeferred()
        rig.coordinator.connect("A")
        rig.coordinator.connect("A")
        rig.coordinator.connect("A")
        runCurrent()
        assertEquals("one knock for three taps", 1, rig.transport.calls.size)
        rig.transport.hold!!.complete(KnockResult.Delivered)
        runCurrent()
        assertEquals(RemoteAttempt.WaitingForDialBack, rig.attempt())
    }

    @Test
    fun retryAfterAFailureSendsAFreshManualKnock() = runTest {
        val rig = rig()
        rig.transport.result = KnockResult.TimedOut
        rig.coordinator.connect("A")
        advanceTimeBy(200)
        runCurrent()
        assertEquals(RemoteAttempt.Offline(OfflineReason.TimedOut), rig.attempt())
        rig.transport.result = KnockResult.Delivered
        rig.coordinator.connect("A")
        assertEquals(RemoteAttempt.Knocking(false), rig.attempt())
        advanceTimeBy(200)
        runCurrent()
        assertEquals(2, rig.transport.calls.size)
        assertEquals(setOf(KnockIntent.Manual), rig.transport.calls.map { it.intent }.toSet())
        assertEquals(RemoteAttempt.WaitingForDialBack, rig.attempt())
    }

    @Test
    fun logsNameTheKindOfAddressNeverTheAddress() = runTest {
        val rig = rig()
        rig.coordinator.connect("A")
        advanceTimeBy(200)
        runCurrent()
        assertTrue(rig.host.logs.isNotEmpty())
        assertTrue(rig.host.logs.none { "tailnet" in it || "mac." in it || "9003" in it })
        assertTrue(rig.host.logs.any { "host=dns" in it })
    }

    // MARK: - Recovery

    private fun TestScope.dropRemoteSession(rig: Rig, peerID: String = "A", reason: SessionLossReason = SessionLossReason.TransportLost) {
        rig.coordinator.onAdmitted(peerID, remote = true)
        rig.coordinator.onSessionLost(peerID, reason)
        runCurrent()
    }

    @Test
    fun aDroppedRemoteSessionIsRecoveredWithBoundedAutomaticKnocks() = runTest {
        val rig = rig()
        rig.transport.result = KnockResult.TimedOut
        dropRemoteSession(rig)
        assertEquals(RemoteAttempt.Recovering, rig.attempt())
        advanceTimeBy(1_900)
        runCurrent()
        assertTrue("nothing before the first backoff", rig.transport.calls.isEmpty())
        advanceTimeBy(200)
        runCurrent()
        assertEquals(listOf(2_000L), rig.transport.calls.map { it.at })
        advanceTimeBy(400_000)
        runCurrent()
        assertTrue("only automatic knocks, never manual", rig.transport.calls.all { it.intent == KnockIntent.Automatic })
        assertTrue("bounded", rig.transport.calls.size in 5..12)
        assertTrue("none after three minutes", rig.transport.calls.all { it.at < 180_000 })
        assertTrue(rig.transport.calls.zipWithNext().all { (a, b) -> b.at - a.at >= 5_000 })
        assertEquals("the row ends on the real reason, not Reconnecting forever", RemoteAttempt.Offline(OfflineReason.TimedOut), rig.attempt())
    }

    @Test
    fun theMacDialingBackEndsRecoveryAtOnce() = runTest {
        val rig = rig()
        rig.transport.result = KnockResult.Delivered
        dropRemoteSession(rig)
        advanceTimeBy(3_000)
        runCurrent()
        assertEquals(1, rig.transport.calls.size)
        rig.coordinator.onAdmitted("A", remote = true)
        advanceTimeBy(300_000)
        runCurrent()
        assertEquals("no more knocks once the session is back", 1, rig.transport.calls.size)
        assertNull(rig.attempt())
    }

    @Test
    fun nothingIsRecoveredAfterADisconnectAForgetOrALocalSessionWithNoSavedAddress() = runTest {
        val disconnect = rig()
        dropRemoteSession(disconnect, reason = SessionLossReason.ExplicitDisconnect)
        val closed = rig()
        dropRemoteSession(closed, reason = SessionLossReason.PeerClosed)
        // A local session falls back to Remote only with a saved address (see the Wi-Fi fallback tests below).
        val local = rig(save = false)
        local.coordinator.onAdmitted("A", remote = false)
        local.coordinator.onSessionLost("A", SessionLossReason.TransportLost)
        val autoOff = rig().also { it.host.autoReconnect = false }
        dropRemoteSession(autoOff)
        val forgotten = rig().also { it.host.paired.remove("A") }
        dropRemoteSession(forgotten)
        advanceTimeBy(300_000)
        runCurrent()
        for (rig in listOf(disconnect, closed, local, autoOff, forgotten)) {
            assertTrue(rig.transport.calls.isEmpty())
            assertNull(rig.attempt())
        }
    }

    @Test
    fun forgetCancelAndALocalSessionStopARunningRecovery() = runTest {
        for (stop in listOf<(Rig) -> Unit>(
            { it.host.paired.remove("A"); it.coordinator.onForget("A") },
            { it.coordinator.cancel("A") },
            { it.coordinator.onAdmitted("B", remote = false) },
            { it.coordinator.onBackground(null) },
        )) {
            val rig = rig()
            rig.transport.result = KnockResult.TimedOut
            dropRemoteSession(rig)
            advanceTimeBy(8_000)
            runCurrent()
            val before = rig.transport.calls.size
            assertTrue(before >= 1)
            stop(rig)
            advanceTimeBy(300_000)
            runCurrent()
            assertEquals(before, rig.transport.calls.size)
            assertFalse(rig.attempt() == RemoteAttempt.Recovering)
        }
    }

    @Test
    fun recoveryIsForegroundOnlyAndResumesOnceOnTheWayBack() = runTest {
        val rig = rig()
        rig.coordinator.onAdmitted("A", remote = true)
        rig.coordinator.onBackground(liveRemotePeer = "A")
        rig.coordinator.onSessionLost("A", SessionLossReason.ExplicitDisconnect)
        advanceTimeBy(60_000)
        runCurrent()
        assertTrue("nothing while in the background", rig.transport.calls.isEmpty())
        rig.coordinator.onForeground()
        advanceTimeBy(3_000)
        runCurrent()
        assertEquals(listOf(KnockIntent.Automatic), rig.transport.calls.map { it.intent })
    }

    @Test
    fun aUserDisconnectBeforeLeavingMeansNothingToResume() = runTest {
        val rig = rig()
        rig.coordinator.onAdmitted("A", remote = true)
        rig.coordinator.onSessionLost("A", SessionLossReason.ExplicitDisconnect)
        rig.coordinator.onBackground(liveRemotePeer = null)
        rig.coordinator.onForeground()
        advanceTimeBy(300_000)
        runCurrent()
        assertTrue(rig.transport.calls.isEmpty())
    }

    @Test
    fun aMacThatAppearsLocallyLetsTheLocalPathTakeOverWithNoKnock() = runTest {
        val rig = rig()
        rig.transport.result = KnockResult.TimedOut
        dropRemoteSession(rig)
        advanceTimeBy(8_000)
        runCurrent()
        val before = rig.transport.calls.size
        rig.host.nearby += "A"
        rig.coordinator.onNearbyChanged()
        advanceTimeBy(300_000)
        runCurrent()
        assertEquals(before, rig.transport.calls.size)
        assertNull(rig.attempt())
        // And a drop while it is already nearby never starts.
        val near = rig().also { it.host.nearby += "A" }
        dropRemoteSession(near)
        advanceTimeBy(300_000)
        runCurrent()
        assertTrue(near.transport.calls.isEmpty())
    }

    @Test
    fun aNetworkChangeGivesOneExtraAttemptAfterTheBackoffIsOver() = runTest {
        val rig = rig()
        rig.transport.result = KnockResult.TimedOut
        dropRemoteSession(rig)
        advanceTimeBy(300_000)
        runCurrent()
        val before = rig.transport.calls.size
        rig.coordinator.onNetworkChanged()
        rig.coordinator.onNetworkChanged()
        rig.coordinator.onNetworkChanged()
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals("a burst of changes is one attempt", before + 1, rig.transport.calls.size)
        assertEquals(KnockIntent.Automatic, rig.transport.calls.last().intent)
        advanceTimeBy(120_000)
        runCurrent()
        assertEquals("and no schedule follows it", before + 1, rig.transport.calls.size)
        advanceTimeBy(400_000)
        rig.coordinator.onNetworkChanged()
        advanceTimeBy(10_000)
        runCurrent()
        assertEquals("ten minutes after the drop a network change does nothing", before + 1, rig.transport.calls.size)
    }

    @Test
    fun aNetworkChangeWithoutARecoveryDoesNothing() = runTest {
        val rig = rig()
        rig.coordinator.onNetworkChanged()
        advanceTimeBy(60_000)
        runCurrent()
        assertTrue(rig.transport.calls.isEmpty())
    }

    @Test
    fun aSecurityFailureDuringRecoveryIsFinalAndStaysOnTheRow() = runTest {
        val rig = rig()
        rig.transport.result = KnockResult.IdentityMismatch("B")
        dropRemoteSession(rig)
        advanceTimeBy(5_000)
        runCurrent()
        assertEquals(RemoteAttempt.DifferentMac("B"), rig.attempt())
        rig.coordinator.onNetworkChanged()
        advanceTimeBy(300_000)
        runCurrent()
        assertEquals("no fallback, no retry, not even on a network change", 1, rig.transport.calls.size)
        assertEquals(RemoteAttempt.DifferentMac("B"), rig.attempt())
    }

    @Test
    fun aLiveSessionOfAnotherMacKeepsRecoveryFromCompetingWithIt() = runTest {
        val rig = rig()
        rig.store.save("B", RemoteEndpoint("100.64.0.2", 9003))
        rig.transport.result = KnockResult.TimedOut
        rig.coordinator.onAdmitted("A", remote = true)
        rig.host.live = "B"
        rig.coordinator.onSessionLost("A", SessionLossReason.TransportLost)
        advanceTimeBy(300_000)
        runCurrent()
        assertTrue(rig.transport.calls.isEmpty())
    }

    @Test
    fun aManualConnectSupersedesRecoveryAndIsStillManual() = runTest {
        val rig = rig()
        rig.transport.result = KnockResult.TimedOut
        dropRemoteSession(rig)
        advanceTimeBy(2_050)
        runCurrent()
        assertEquals(KnockIntent.Automatic, rig.transport.calls.single().intent)
        rig.coordinator.connect("A")
        advanceTimeBy(200)
        runCurrent()
        assertEquals(KnockIntent.Manual, rig.transport.calls.last().intent)
        advanceTimeBy(300_000)
        runCurrent()
        assertEquals("recovery ended when the user took over", 2, rig.transport.calls.size)
    }

    // MARK: - Local Wi-Fi session falling back to Remote

    private fun TestScope.dropLocalSession(rig: Rig, reason: SessionLossReason = SessionLossReason.TransportLost) {
        rig.coordinator.onAdmitted("A", remote = false)
        rig.coordinator.onSessionLost("A", reason)
        runCurrent()
    }

    @Test
    fun aLocalDropWhileTheMacIsStillNearbyWaitsForTheLocalRedialAndKnocksNothing() = runTest {
        val rig = rig()
        rig.host.nearby += "A"
        dropLocalSession(rig)
        assertEquals(RemoteAttempt.Recovering, rig.attempt())
        assertFalse("a session arriving now is the Mac's local redial, labelled Local", rig.coordinator.isKnockPending("A"))
        advanceTimeBy(30_000)
        runCurrent()
        rig.coordinator.onNearbyChanged()
        assertTrue("nearby: no knock", rig.transport.calls.isEmpty())
        rig.coordinator.onAdmitted("A", remote = false)
        assertNull(rig.attempt())
        advanceTimeBy(600_000)
        runCurrent()
        assertTrue("the Mac's redial ended it", rig.transport.calls.isEmpty())
    }

    @Test
    fun aLocalDropFallsBackToAutomaticKnocksOnceTheMacIsNoLongerNearby() = runTest {
        val rig = rig()
        rig.transport.result = KnockResult.Delivered
        rig.host.nearby += "A"
        dropLocalSession(rig)
        advanceTimeBy(3_000)
        runCurrent()
        assertTrue(rig.transport.calls.isEmpty())
        // Wi-Fi gone: Bonjour no longer shows the Mac, the phone is on cellular + Tailscale.
        rig.host.nearby -= "A"
        rig.coordinator.onNetworkChanged()
        advanceTimeBy(6_000)
        runCurrent()
        val knock = rig.transport.calls.single()
        assertEquals(KnockIntent.Automatic, knock.intent)
        assertEquals(endpointA, knock.endpoint)
        assertTrue(rig.coordinator.isKnockPending("A"))
        rig.coordinator.onAdmitted("A", remote = true)
        assertNull(rig.attempt())
        advanceTimeBy(600_000)
        runCurrent()
        assertEquals(1, rig.transport.calls.size)
    }

    @Test
    fun aLocalDropWithoutASavedAddressOrAfterDisconnectDoesNothing() = runTest {
        val noAddress = rig(save = false)
        dropLocalSession(noAddress)
        assertNull(noAddress.attempt())
        val disconnected = rig()
        dropLocalSession(disconnected, SessionLossReason.ExplicitDisconnect)
        assertNull(disconnected.attempt())
        val off = rig().also { it.host.autoReconnect = false }
        dropLocalSession(off)
        assertNull(off.attempt())
        advanceTimeBy(600_000)
        runCurrent()
        assertTrue(noAddress.transport.calls.isEmpty() && disconnected.transport.calls.isEmpty() && off.transport.calls.isEmpty())
    }

    @Test
    fun aLocalFallbackIsBoundedLikeRemoteRecovery() = runTest {
        val rig = rig()
        rig.transport.result = KnockResult.TimedOut
        dropLocalSession(rig)
        advanceTimeBy(700_000)
        runCurrent()
        assertTrue(rig.transport.calls.isNotEmpty())
        assertTrue(rig.transport.calls.all { it.intent == KnockIntent.Automatic })
        assertTrue("same bound as remote recovery", rig.transport.calls.size in 5..12)
        assertTrue(rig.transport.calls.all { it.at < 180_000 })
    }
}
