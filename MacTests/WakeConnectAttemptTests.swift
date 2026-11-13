import XCTest

/// Pure-state tests for `WakeConnectAttempt` (the Wake & Connect one-tap
/// orchestration's timing/state policy, now a Release feature). Timer-driven
/// behavior that lives in `WakeConnectCoordinator` instead (bounded WoL
/// bursts actually firing on a real timer, connect-token refresh cadence,
/// retry-timer cancellation on success/timeout, the "no duplicate concurrent
/// attempt" and "already-connected skips the attempt" guards, and the live
/// `StreamReceiver.authenticatedPeerID`/`lastForgottenPeerID` wiring) has no
/// pure seam in the hostless test bundle — `StreamReceiver` pulls in the
/// full TLS/ScreenCaptureKit/WireMessage dependency graph, which is out of
/// scope to add here — and is exercised by the physical retest instead; see
/// the DEFINITION OF DONE report. The peer-matching and burst-counting LOGIC
/// itself — the actual security/correctness property in both cases — is
/// fully covered below, since the coordinator does nothing more than plumb
/// `receiver.authenticatedPeerID` into `applicationAuthenticated(peerID:)`.
final class WakeConnectAttemptTests: XCTestCase {

    // MARK: - Idle -> begin

    func testIdleBeginsAPreparingAttempt() {
        var attempt = WakeConnectAttempt()
        XCTAssertEqual(attempt.stage, .idle)
        XCTAssertFalse(attempt.isActive)
        let id = attempt.begin(peerID: "peer-1")
        XCTAssertEqual(id, 1)
        XCTAssertEqual(attempt.stage, .preparing)
        XCTAssertTrue(attempt.isActive)
    }

    func testSecondAttemptAfterFailureGetsAFreshAttemptIDAndResetsCounters() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.recordWOLSent()
        XCTAssertTrue(attempt.fail("timedOut"))
        guard case .failed = attempt.stage else { return XCTFail("expected .failed") }

        let secondID = attempt.begin(peerID: "peer-1")
        XCTAssertEqual(secondID, 2)
        XCTAssertEqual(attempt.stage, .preparing)
        XCTAssertEqual(attempt.wolBurstsSent, 0)
    }

    // MARK: - WoL precedes authenticated Promote

    func testWOLOccursBeforeAuthenticatedPromote() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        XCTAssertEqual(attempt.stage, .waking)
        XCTAssertTrue(attempt.recordWOLSent())
        XCTAssertEqual(attempt.wolBurstsSent, 1)
        // Promote cannot be armed yet — no generation has authenticated.
        XCTAssertFalse(attempt.shouldSendPromote())
        XCTAssertTrue(attempt.beginWaitingForConnection())
        XCTAssertTrue(attempt.transportReady())
        XCTAssertEqual(attempt.stage, .authenticating)
        XCTAssertFalse(attempt.shouldSendPromote())
    }

    func testWOLBurstsAreBoundedAcrossTheWholeAttempt() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        for _ in 0..<10 { _ = attempt.recordWOLSent() }
        XCTAssertEqual(attempt.wolBurstsSent, WakeConnectAttempt.maxWOLBursts)
    }

    /// Regression test for the burst bug: `WakeConnectCoordinator.sendOne()`
    /// calls `recordWOLSent()` then immediately `beginWaitingForConnection()`
    /// on the very first send, so every packet after the first is recorded
    /// from `.waitingForConnection`, not `.waking`. Requiring `.waking` alone
    /// in `recordWOLSent()` silently capped every burst at 1 packet instead
    /// of the intended 3 — this reproduces the coordinator's exact call
    /// sequence and asserts the full burst actually lands.
    /// #255: with no saved wake details the coordinator sends no packet.
    /// The attempt must still connect to an awake Mac (and its label then
    /// says Connecting…, from `wolBurstsSent == 0`), never wait out the timeout.
    func testNoWakePacketStillConnects() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        XCTAssertEqual(attempt.wolBurstsSent, 0)
        XCTAssertTrue(attempt.transportReady(), "a Mac that dials in is adopted without any wake packet")
        XCTAssertEqual(attempt.stage, .authenticating)
        XCTAssertTrue(attempt.applicationAuthenticated(generation: 1, peerID: "peer-1"))
        XCTAssertEqual(attempt.stage, .promoting, "the display is still asked to wake after authentication")
    }

    func testWOLBurstSendsTheFullBoundedBurstAcrossTheStageTransition() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        XCTAssertEqual(attempt.stage, .waking)

        // Packet 1: sent from `.waking`, then the coordinator immediately
        // transitions to `.waitingForConnection`.
        XCTAssertTrue(attempt.recordWOLSent())
        XCTAssertEqual(attempt.wolBurstsSent, 1)
        XCTAssertTrue(attempt.beginWaitingForConnection())
        XCTAssertEqual(attempt.stage, .waitingForConnection)

        // Packets 2 and 3: the burst timer's later ticks fire while the
        // stage is still `.waitingForConnection` — these must still count.
        XCTAssertTrue(attempt.recordWOLSent())
        XCTAssertEqual(attempt.wolBurstsSent, 2)
        XCTAssertTrue(attempt.recordWOLSent())
        XCTAssertEqual(attempt.wolBurstsSent, 3)

        // The burst is still bounded: a 4th tick sends nothing further.
        XCTAssertFalse(attempt.recordWOLSent())
        XCTAssertEqual(attempt.wolBurstsSent, WakeConnectAttempt.maxWOLBursts)
    }

    // MARK: - Promote cannot be sent before authentication

    func testPromoteCannotBeSentBeforeAuthentication() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        XCTAssertFalse(attempt.shouldSendPromote())
        _ = attempt.connectRequestPublished()
        XCTAssertFalse(attempt.shouldSendPromote())
        _ = attempt.recordWOLSent()
        _ = attempt.beginWaitingForConnection()
        XCTAssertFalse(attempt.shouldSendPromote())
        _ = attempt.transportReady()
        XCTAssertEqual(attempt.stage, .authenticating)
        XCTAssertFalse(attempt.shouldSendPromote())
    }

    // MARK: - Authenticated target-peer binding (P4)
    //
    // `WakeConnectCoordinator` passes `receiver.authenticatedPeerID` — the
    // pinned peerID that actually completed mutual TLS, derived from the
    // connection's certificate (SPKI → TrustStore.peerID(forSPKI:)) — into
    // `peerID` below, never the attempt's own requested/target peerID. These
    // tests exercise that binding at the point it's actually enforced.

    /// Another already-paired Mac dialing in mid-attempt (a real, valid,
    /// currently-authenticated peer — just not the one this attempt woke)
    /// must not be mistaken for the wake target.
    func testWrongAuthenticatedPeerCannotSatisfyTheAttempt() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.transportReady()
        XCTAssertFalse(attempt.applicationAuthenticated(generation: 1, peerID: "peer-2"))
        XCTAssertEqual(attempt.stage, .authenticating)
    }

    /// The actual wake target's authenticated peerID satisfies the attempt.
    func testCorrectAuthenticatedPeerSatisfiesTheAttempt() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.transportReady()
        XCTAssertTrue(attempt.applicationAuthenticated(generation: 1, peerID: "peer-1"))
        XCTAssertEqual(attempt.stage, .promoting)
    }

    /// A stale previous-peer callback arriving after a fresh attempt has
    /// begun (for a different target) must be ignored — `begin()` resets
    /// `peerID` for the new attempt, so an old, differently-targeted
    /// authentication can never complete it.
    func testStalePreviousPeerCallbackIsIgnoredAfterANewAttemptTargetsSomeoneElse() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.fail("cancelled")
        _ = attempt.begin(peerID: "peer-2")
        _ = attempt.connectRequestPublished()
        _ = attempt.transportReady()
        // A late authentication for the OLD target must not satisfy the NEW attempt.
        XCTAssertFalse(attempt.applicationAuthenticated(generation: 1, peerID: "peer-1"))
        XCTAssertEqual(attempt.stage, .authenticating)
        XCTAssertTrue(attempt.applicationAuthenticated(generation: 1, peerID: "peer-2"))
    }

    // MARK: - Promote once per generation, generation-safe retries

    func testPromoteSentOncePerGenerationUnlessRetryIsRequired() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.transportReady()
        _ = attempt.applicationAuthenticated(generation: 1, peerID: "peer-1")

        XCTAssertTrue(attempt.shouldSendPromote())
        XCTAssertEqual(attempt.promoteAttemptsThisGeneration, 1)
        // A lost reply / transient failure allows a bounded retry, same
        // generation, without exceeding the cap.
        XCTAssertTrue(attempt.shouldSendPromote())
        XCTAssertEqual(attempt.promoteAttemptsThisGeneration, 2)

        XCTAssertTrue(attempt.promoteSucceeded(generation: 1))
        XCTAssertEqual(attempt.stage, .waitingForVideo)
        // DO NOT SPAM PROMOTE: no further sends for this generation, even
        // if somehow re-armed into .promoting.
        XCTAssertFalse(attempt.shouldSendPromote())
    }

    func testPromoteRetryIsBoundedByMaxAttempts() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.transportReady()
        _ = attempt.applicationAuthenticated(generation: 1, peerID: "peer-1")
        for _ in 0..<(WakeConnectAttempt.maxPromoteAttempts + 5) { _ = attempt.shouldSendPromote() }
        XCTAssertEqual(attempt.promoteAttemptsThisGeneration, WakeConnectAttempt.maxPromoteAttempts)
    }

    func testNewGenerationResetsThePromoteRetryBudget() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.transportReady()
        _ = attempt.applicationAuthenticated(generation: 1, peerID: "peer-1")
        _ = attempt.shouldSendPromote()
        _ = attempt.shouldSendPromote()
        XCTAssertEqual(attempt.promoteAttemptsThisGeneration, 2)

        // Connection dropped before Promote resolved; a fresh authenticated
        // generation appears — Promote is allowed once for the NEW generation.
        _ = attempt.connectionLost()
        _ = attempt.beginWaitingForConnection()
        _ = attempt.transportReady()
        XCTAssertTrue(attempt.applicationAuthenticated(generation: 2, peerID: "peer-1"))
        XCTAssertEqual(attempt.promoteAttemptsThisGeneration, 0)
        XCTAssertTrue(attempt.shouldSendPromote())
        XCTAssertEqual(attempt.promoteAttemptsThisGeneration, 1)
    }

    /// Regression test for a generation-safety gap in
    /// `WakeConnectCoordinator.sendPromoteIfNeeded()`'s retry timer: its
    /// event handler used to check only `attempt.stage == .promoting`, not
    /// which generation it was scheduled for. `DispatchSourceTimer.cancel()`
    /// does not retroactively withdraw a handler GCD has already handed to
    /// the queue, so a fast reconnect racing the 3s retry deadline could let
    /// a stale generation-1 timer fire AFTER generation 2 had already
    /// re-entered `.promoting` — and, since the guard didn't check
    /// generation, it would be mistaken for generation 2's own scheduled
    /// retry and consume its retry budget. The fix captures the generation
    /// at schedule time and additionally requires
    /// `self.attempt.promoteGeneration == generation` before calling back
    /// into `shouldSendPromote()`.
    ///
    /// `WakeConnectCoordinator` itself isn't reachable from this hostless
    /// test bundle (it requires `StreamReceiver`'s full TLS/CryptoKit/
    /// ScreenCaptureKit dependency graph, which is out of scope to add for
    /// this fix), so this test proves the pure-state invariant the fix
    /// relies on: a generation captured when a retry is scheduled is a
    /// distinct, comparable value from `promoteGeneration` by the time a
    /// delayed callback actually runs, so a caller that compares the two —
    /// as the real timer closure now does — always correctly identifies a
    /// stale generation and refuses it.
    func testCapturedGenerationDiffersFromCurrentAfterAReconnectToANewGeneration() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.transportReady()
        _ = attempt.applicationAuthenticated(generation: 1, peerID: "peer-1")
        _ = attempt.shouldSendPromote()
        // What a retry timer scheduled right now would capture as `generation`.
        let scheduledGeneration = attempt.promoteGeneration
        XCTAssertEqual(scheduledGeneration, 1)

        // Connection drops before Promote resolves, then a fresh generation
        // authenticates — simulating the fast-reconnect race.
        _ = attempt.connectionLost()
        _ = attempt.beginWaitingForConnection()
        _ = attempt.transportReady()
        _ = attempt.applicationAuthenticated(generation: 2, peerID: "peer-1")

        // The stale timer's captured generation no longer matches current
        // state — a guard comparing the two (as the real fix does) refuses it.
        XCTAssertNotEqual(attempt.promoteGeneration, scheduledGeneration)
        XCTAssertEqual(attempt.promoteGeneration, 2)
    }

    func testSucceededGenerationIsRememberedAcrossABriefReauthentication() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.transportReady()
        _ = attempt.applicationAuthenticated(generation: 1, peerID: "peer-1")
        _ = attempt.shouldSendPromote()
        _ = attempt.promoteSucceeded(generation: 1)
        XCTAssertEqual(attempt.stage, .waitingForVideo)

        // A brief transport blip that re-authenticates the SAME generation
        // (no new dial) must not re-promote.
        XCTAssertTrue(attempt.applicationAuthenticated(generation: 1, peerID: "peer-1"))
        XCTAssertEqual(attempt.stage, .waitingForVideo)
        XCTAssertFalse(attempt.shouldSendPromote())
    }

    // MARK: - Video readiness / connected

    func testVideoReadyCompletesTheAttempt() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.transportReady()
        _ = attempt.applicationAuthenticated(generation: 1, peerID: "peer-1")
        XCTAssertTrue(attempt.videoReady())
        XCTAssertEqual(attempt.stage, .connected)
        XCTAssertFalse(attempt.isActive)
    }

    // MARK: - Timeout / cancellation

    func testTimeoutFailsAnActiveAttempt() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        XCTAssertTrue(attempt.fail("timedOut"))
        guard case .failed(let reason) = attempt.stage else { return XCTFail("expected .failed") }
        XCTAssertEqual(reason, "timedOut")
        XCTAssertFalse(attempt.isActive)
    }

    func testCancelFailsAnActiveAttemptButNotAnIdleOne() {
        var idle = WakeConnectAttempt()
        XCTAssertFalse(idle.fail("cancelled"))

        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        XCTAssertTrue(attempt.fail("cancelled"))
        // Already terminal: a second cancel is a no-op, not a double transition.
        XCTAssertFalse(attempt.fail("cancelled"))
    }

    func testTimeoutOrCancelDoesNotAffectAnAlreadyConnectedAttempt() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.transportReady()
        _ = attempt.applicationAuthenticated(generation: 1, peerID: "peer-1")
        _ = attempt.videoReady()
        XCTAssertEqual(attempt.stage, .connected)
        XCTAssertFalse(attempt.fail("timedOut"))
        XCTAssertEqual(attempt.stage, .connected)
    }

    // MARK: - Connection lost mid-wake (Mac hasn't finished waking yet)

    func testConnectionLostFallsBackToWakingWithoutResettingWOLBudget() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.recordWOLSent()
        _ = attempt.recordWOLSent()
        _ = attempt.beginWaitingForConnection()
        _ = attempt.transportReady()

        XCTAssertTrue(attempt.connectionLost())
        XCTAssertEqual(attempt.stage, .waking)
        XCTAssertEqual(attempt.wolBurstsSent, 2)   // not reset — the attempt stays bounded
    }

    // MARK: - Connect request renewal after a lost session (#255)

    /// The Mac dialed in from a dark wake, was admitted, and dropped because
    /// it could not start yet. Its arrival answered the Connect request, so
    /// the attempt must ask again or the Mac (the only dialer) never returns.
    private func attemptWithAnAuthenticatedSession() -> WakeConnectAttempt {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.transportReady()
        _ = attempt.applicationAuthenticated(generation: 2, peerID: "peer-1")
        return attempt
    }

    func testALostSessionRenewsTheConnectRequestOnce() {
        var attempt = attemptWithAnAuthenticatedSession()
        XCTAssertFalse(attempt.shouldRenewConnectRequest(), "nothing to renew while the session is live")

        XCTAssertTrue(attempt.connectionLost())
        XCTAssertTrue(attempt.shouldRenewConnectRequest())
        XCTAssertEqual(attempt.connectRequestRenewals, 1)

        // The recovery run the renewed request starts reports the loss again.
        XCTAssertTrue(attempt.connectionLost())
        XCTAssertFalse(attempt.shouldRenewConnectRequest(), "one lost session asks once")
        XCTAssertEqual(attempt.connectRequestRenewals, 1)
    }

    func testALossBeforeAnySessionDoesNotRenew() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.beginWaitingForConnection()

        XCTAssertTrue(attempt.connectionLost())
        XCTAssertFalse(attempt.shouldRenewConnectRequest(), "the first request still stands and is refreshed")
    }

    func testConnectRequestRenewalsAreBoundedPerAttempt() {
        var attempt = attemptWithAnAuthenticatedSession()
        for generation in 0..<WakeConnectAttempt.maxConnectRequestRenewals {
            XCTAssertTrue(attempt.connectionLost())
            XCTAssertTrue(attempt.shouldRenewConnectRequest())
            _ = attempt.transportReady()
            _ = attempt.applicationAuthenticated(generation: 10 + generation, peerID: "peer-1")
        }
        XCTAssertTrue(attempt.connectionLost())
        XCTAssertFalse(attempt.shouldRenewConnectRequest(), "the budget is spent")
        XCTAssertEqual(attempt.connectRequestRenewals, WakeConnectAttempt.maxConnectRequestRenewals)

        _ = attempt.fail("timedOut")
        _ = attempt.begin(peerID: "peer-1")
        XCTAssertEqual(attempt.connectRequestRenewals, 0, "a new attempt gets a fresh budget")
    }

    func testAFinishedAttemptNeverRenews() {
        var attempt = attemptWithAnAuthenticatedSession()
        XCTAssertTrue(attempt.connectionLost())
        _ = attempt.fail("cancelled")
        XCTAssertFalse(attempt.shouldRenewConnectRequest())
    }
    /// `connectionLost()` marks the Connect request answered only when a
    /// session had actually reached the attempt.
    func testHasSessionOnlyBetweenTransportAndVideo() {
        var attempt = WakeConnectAttempt()
        XCTAssertFalse(attempt.hasSession)
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        XCTAssertFalse(attempt.hasSession)
        _ = attempt.transportReady()
        XCTAssertTrue(attempt.hasSession)
        _ = attempt.applicationAuthenticated(generation: 2, peerID: "peer-1")
        XCTAssertTrue(attempt.hasSession)
        _ = attempt.videoReady()
        XCTAssertFalse(attempt.hasSession, "a finished attempt is not ended by a later Disconnect")
    }

    // MARK: - What a lost session means for the attempt

    private func attemptAt(_ stage: WakeConnectStage) -> WakeConnectAttempt {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        switch stage {
        case .preparing:
            break
        case .waking:
            _ = attempt.connectRequestPublished()
        case .waitingForConnection:
            _ = attempt.connectRequestPublished()
            _ = attempt.beginWaitingForConnection()
        case .authenticating:
            _ = attempt.connectRequestPublished()
            _ = attempt.transportReady()
        case .promoting:
            _ = attempt.connectRequestPublished()
            _ = attempt.transportReady()
            _ = attempt.applicationAuthenticated(generation: 1, peerID: "peer-1")
        case .waitingForVideo:
            _ = attempt.connectRequestPublished()
            _ = attempt.transportReady()
            _ = attempt.applicationAuthenticated(generation: 1, peerID: "peer-1")
            _ = attempt.promoteSucceeded(generation: 1)
        default:
            XCTFail("not an active stage")
        }
        XCTAssertEqual(attempt.stage, stage)
        return attempt
    }

    func testExplicitDisconnectEndsTheAttemptInEveryActiveStage() {
        let stages: [WakeConnectStage] = [.preparing, .waking, .waitingForConnection,
                                          .authenticating, .promoting, .waitingForVideo]
        for stage in stages {
            let attempt = attemptAt(stage)
            XCTAssertEqual(attempt.lossAction(phase: .disconnected, lossReason: .explicitDisconnect),
                           .endAttempt, "stage \(stage)")
        }
    }

    func testExplicitDisconnectAfterARenewalStillEndsTheAttempt() {
        var attempt = attemptAt(.authenticating)
        XCTAssertEqual(attempt.lossAction(phase: .disconnected, lossReason: .transportLost),
                       .connectionLostAndRenew)
        XCTAssertTrue(attempt.connectionLost())
        XCTAssertTrue(attempt.shouldRenewConnectRequest())
        XCTAssertEqual(attempt.stage, .waking)
        // The user's own Disconnect now finds the attempt back at `.waking`.
        XCTAssertEqual(attempt.lossAction(phase: .disconnected, lossReason: .explicitDisconnect),
                       .endAttempt)
    }

    func testADroppedTransportReadAsDisconnectedRenewsTheRequestAndKeepsTheAttempt() {
        // Auto-Reconnect off, or no connection yet since launch: the receiver
        // reports `.disconnected` with a transport loss, not `.reconnecting`.
        let reasons: [ReceiverSessionLossReason?] = [.transportLost, .listenerFailed, nil]
        for reason in reasons {
            var attempt = attemptAt(.authenticating)
            XCTAssertEqual(attempt.lossAction(phase: .disconnected, lossReason: reason),
                           .connectionLostAndRenew, "reason \(String(describing: reason))")
            XCTAssertTrue(attempt.connectionLost())
            XCTAssertTrue(attempt.isActive)
            XCTAssertTrue(attempt.shouldRenewConnectRequest())
            XCTAssertEqual(attempt.connectRequestRenewals, 1)
        }
    }

    func testDisconnectedRenewalStaysBoundedPerAttempt() {
        var attempt = attemptAt(.waking)
        for _ in 0..<WakeConnectAttempt.maxConnectRequestRenewals {
            XCTAssertTrue(attempt.transportReady())
            XCTAssertEqual(attempt.lossAction(phase: .disconnected, lossReason: .transportLost),
                           .connectionLostAndRenew)
            XCTAssertTrue(attempt.connectionLost())
            XCTAssertTrue(attempt.shouldRenewConnectRequest())
        }
        XCTAssertTrue(attempt.transportReady())
        XCTAssertTrue(attempt.connectionLost())
        XCTAssertFalse(attempt.shouldRenewConnectRequest())
        XCTAssertTrue(attempt.isActive)
    }

    func testReconnectingStillRenewsAndGivenUpStatesOnlyFallBackToWaking() {
        let attempt = attemptAt(.authenticating)
        XCTAssertEqual(attempt.lossAction(phase: .reconnecting, lossReason: .transportLost),
                       .connectionLostAndRenew)
        XCTAssertEqual(attempt.lossAction(phase: .reconnectFailed, lossReason: .transportLost),
                       .connectionLost)
        XCTAssertEqual(attempt.lossAction(phase: .peerDisconnected, lossReason: .peerClosed),
                       .connectionLost)
    }

    func testNonLossPhasesAndFinishedAttemptsHaveNoLossAction() {
        let attempt = attemptAt(.waking)
        let phases: [ReceiverSessionPhase] = [.connecting, .connected, .paused, .unrecoverable]
        for phase in phases {
            XCTAssertNil(attempt.lossAction(phase: phase, lossReason: nil), "phase \(phase)")
        }
        var finished = attemptAt(.waking)
        _ = finished.fail("cancelled")
        XCTAssertNil(finished.lossAction(phase: .disconnected, lossReason: .explicitDisconnect))
    }
}
