package com.raisecaterror.meowdisplay.core.remote

import com.raisecaterror.meowdisplay.core.session.SessionLossReason
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** The recovery schedule on a fake clock. */
class RemoteRecoveryPolicyTest {
    private val policy = RemoteRecoveryPolicy()
    private val context = RemoteRecoveryPolicy.DropContext(
        reason = SessionLossReason.TransportLost, wasRemote = true, autoReconnectEnabled = true, foreground = true,
        hasSavedAddress = true, stillPaired = true, nearby = false, otherSessionLive = false,
    )

    /** Walks the policy: every knock "takes" [knockMs] and ends with [result]. Returns the times each knock started. */
    private fun simulate(until: Long, result: KnockResult = KnockResult.TimedOut, knockMs: Long = 100): List<Long> {
        val starts = mutableListOf<Long>()
        var now = 0L
        while (now <= until) {
            when (val step = policy.next(now)) {
                RemoteRecoveryPolicy.Step.Idle, is RemoteRecoveryPolicy.Step.Dormant -> break
                is RemoteRecoveryPolicy.Step.Wait -> {
                    if (step.atMs > now) { now = step.atMs; continue }
                    starts += now
                    policy.knockStarted(now)
                    now += knockMs
                    policy.knockFinished(now, result)
                }
            }
        }
        return starts
    }

    @Test
    fun onlyARecoverableRemoteDropWithAutoReconnectOnStartsRecovery() {
        assertTrue(policy.shouldStart(context))
        assertTrue(policy.shouldStart(context.copy(reason = SessionLossReason.ListenerFailed)))
        for (reason in listOf(SessionLossReason.ExplicitDisconnect, SessionLossReason.PeerClosed, SessionLossReason.ProtocolIncompatible))
            assertFalse("$reason", policy.shouldStart(context.copy(reason = reason)))
        assertFalse("a local session isn't recovered by knocking", policy.shouldStart(context.copy(wasRemote = false)))
        assertFalse(policy.shouldStart(context.copy(autoReconnectEnabled = false)))
        assertFalse("foreground only", policy.shouldStart(context.copy(foreground = false)))
        assertFalse(policy.shouldStart(context.copy(hasSavedAddress = false)))
        assertFalse("a forgotten Mac", policy.shouldStart(context.copy(stillPaired = false)))
        assertFalse("Bonjour shows it: the local path takes over", policy.shouldStart(context.copy(nearby = true)))
        assertFalse(policy.shouldStart(context.copy(otherSessionLive = true)))
    }

    @Test
    fun backoffIsBoundedAndStopsAfterAboutThreeMinutes() {
        policy.start("A", now = 0)
        val starts = simulate(until = 600_000)
        assertEquals("first knock after the first backoff", 2_000L, starts.first())
        assertTrue("every knock is later than the one before by at least the Mac's 5 s limit",
            starts.zipWithNext().all { (a, b) -> b - a >= 5_000 })
        val gaps = starts.zipWithNext().map { (a, b) -> b - a - 100 }
        assertEquals(listOf(5_000L, 10_000L, 20_000L, 30_000L, 30_000L), gaps.take(5))
        assertTrue("nothing starts after three minutes", starts.all { it < 180_000 })
        assertTrue("and it is not endless", starts.size in 5..12)
        assertTrue(policy.next(200_000) is RemoteRecoveryPolicy.Step.Dormant)
    }

    @Test
    fun aDeliveredKnockGivesTheMacTimeToDialBackBeforeAskingAgain() {
        policy.start("A", now = 0)
        val starts = simulate(until = 100_000, result = KnockResult.Delivered)
        assertTrue(starts.zipWithNext().all { (a, b) -> b - a >= 20_000 })
    }

    @Test
    fun aNetworkChangeBringsOneAttemptForwardAndABurstIsOne() {
        policy.start("A", now = 0)
        simulate(until = 400_000)   // the backoff is over
        assertTrue(policy.next(400_000) is RemoteRecoveryPolicy.Step.Dormant)
        assertTrue(policy.networkChanged(400_000))
        assertFalse("a burst of callbacks is one attempt", policy.networkChanged(400_050))
        assertFalse(policy.networkChanged(400_900))
        val step = policy.next(400_100) as RemoteRecoveryPolicy.Step.Wait
        assertTrue("immediate, but not closer to the last knock than the Mac allows", step.atMs <= 400_100 + 5_000)
        policy.knockStarted(step.atMs)
        policy.knockFinished(step.atMs + 100, KnockResult.TimedOut)
        assertTrue("one attempt, not a schedule", policy.next(step.atMs + 200) is RemoteRecoveryPolicy.Step.Dormant)
    }

    @Test
    fun aNetworkChangeDuringTheBackoffPullsTheNextAttemptIn() {
        policy.start("A", now = 0)
        assertEquals(2_000L, (policy.next(0) as RemoteRecoveryPolicy.Step.Wait).atMs)
        policy.knockStarted(2_000)
        policy.knockFinished(2_100, KnockResult.TimedOut)
        assertEquals("the next backoff attempt is 5 s away", 7_100L, (policy.next(2_100) as RemoteRecoveryPolicy.Step.Wait).atMs)
        assertTrue(policy.networkChanged(3_000))
        assertEquals("pulled in, but never closer than 5 s to the last knock", 7_000L, (policy.next(3_000) as RemoteRecoveryPolicy.Step.Wait).atMs)
        assertTrue(policy.networkChanged(3_000).not())
    }

    @Test
    fun networkChangesAreIgnoredOutsideTheTenMinuteWindowAndCapped() {
        policy.start("A", now = 0)
        assertFalse(policy.networkChanged(600_000))
        assertNull("the run is over", policy.run.takeIf { policy.next(600_001) != RemoteRecoveryPolicy.Step.Idle })
        policy.start("A", now = 0)
        simulate(until = 300_000)
        var accepted = 0
        var now = 300_000L
        repeat(6) {
            if (policy.networkChanged(now)) {
                accepted++
                val step = policy.next(now) as RemoteRecoveryPolicy.Step.Wait
                now = maxOf(now, step.atMs)
                policy.knockStarted(now)
                now += 100
                policy.knockFinished(now, KnockResult.TimedOut)
            }
            now += 6_000
        }
        assertEquals("at most three network attempts per drop", 3, accepted)
    }

    @Test
    fun aSecurityFailureEndsTheRunForGood() {
        for (failure in listOf(KnockResult.IdentityMismatch("B"), KnockResult.IdentityMismatch(null), KnockResult.NotAccepted)) {
            policy.start("A", now = 0)
            policy.knockStarted(2_000)
            policy.knockFinished(2_100, failure)
            assertEquals("$failure", RemoteRecoveryPolicy.Step.Idle, policy.next(2_200))
            assertFalse("not even a network change retries it", policy.networkChanged(2_300))
        }
    }

    @Test
    fun stoppingEndsTheRunAndNothingIsScheduled() {
        policy.start("A", now = 0)
        policy.stop()
        assertEquals(RemoteRecoveryPolicy.Step.Idle, policy.next(5_000))
        assertFalse(policy.networkChanged(5_000))
        assertNull(policy.run)
    }

    @Test
    fun otherFailuresKeepGoingWithinTheBounds() {
        for (result in listOf(KnockResult.DnsFailed, KnockResult.Refused, KnockResult.Unreachable, KnockResult.Failed, KnockResult.TimedOut)) {
            policy.start("A", now = 0)
            policy.knockStarted(2_000)
            policy.knockFinished(2_100, result)
            assertTrue("$result", policy.next(2_200) is RemoteRecoveryPolicy.Step.Wait)
        }
    }

    @Test
    fun aCancelledKnockEndsTheRun() {
        policy.start("A", now = 0)
        policy.knockStarted(2_000)
        policy.knockFinished(2_050, KnockResult.Cancelled)
        assertEquals(RemoteRecoveryPolicy.Step.Idle, policy.next(2_100))
    }
}
