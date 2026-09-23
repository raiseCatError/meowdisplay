import XCTest

final class ReceiverSessionStateTests: XCTestCase {

    // MARK: - Helpers

    /// A state that has already completed one successful session, which is
    /// the precondition for any automatic recovery.
    private func connectedSession() -> ReceiverSessionState {
        var state = ReceiverSessionState()
        XCTAssertTrue(state.connectionAdopted())
        XCTAssertTrue(state.connectionEstablished())
        return state
    }

    /// Runs the automatic recovery budget to exhaustion the way
    /// `StreamReceiver.armReconnect` does.
    private func exhaustRecovery(_ state: inout ReceiverSessionState) {
        while state.beginReconnectAttempt() != nil {
            XCTAssertTrue(state.endReconnectAttempt())
        }
        XCTAssertTrue(state.exhaustRecovery())
    }

    // MARK: - Happy path

    func testTransientLossRecoversBackToConnected() {
        var state = connectedSession()
        XCTAssertTrue(state.connectionLost(reason: .transportLost))
        XCTAssertEqual(state.phase, .reconnecting)
        XCTAssertTrue(state.connectionAdopted())
        XCTAssertTrue(state.connectionEstablished())
        XCTAssertEqual(state.phase, .connected)
        XCTAssertNil(state.lossReason)
        XCTAssertEqual(state.reconnectAttempt, 0)
    }

    func testReconnectingPresentsTheInterruptionOverlay() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        XCTAssertEqual(state.interruption, .reconnecting)
        XCTAssertFalse(state.interruption!.offersManualReconnect)
    }

    func testSuccessfulReconnectDismissesTheInterruptionOverlay() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        _ = state.connectionAdopted()
        _ = state.connectionEstablished()
        XCTAssertNil(state.interruption)
    }

    func testAutomaticRetriesNeverReturnToTheDiscoveryScreen() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        for _ in 0..<ReceiverSessionState.maximumReconnectAttempts {
            XCTAssertTrue(state.retainsReceiverSurface)
            XCTAssertNotNil(state.beginReconnectAttempt())
            XCTAssertTrue(state.retainsReceiverSurface)
            XCTAssertTrue(state.endReconnectAttempt())
        }
        _ = state.exhaustRecovery()
        XCTAssertTrue(state.retainsReceiverSurface)
    }

    func testInputIsInactiveForEveryInterruptedPhase() {
        var state = connectedSession()
        XCTAssertTrue(state.allowsLiveInput)
        _ = state.displayPaused()
        XCTAssertFalse(state.allowsLiveInput)
        _ = state.displayResumed()
        _ = state.connectionLost(reason: .transportLost)
        XCTAssertFalse(state.allowsLiveInput)
        exhaustRecovery(&state)
        XCTAssertFalse(state.allowsLiveInput)
    }

    // MARK: - Transport migration

    /// USB/AWDL/LAN migration replaces the connection under a live logical
    /// session. The receiver adopts the newcomer directly, so migration never
    /// reports a loss and never enters recovery.
    func testTransportMigrationDoesNotEnterReconnecting() {
        var state = connectedSession()
        XCTAssertTrue(state.connectionAdopted())
        XCTAssertNotEqual(state.phase, .reconnecting)
        XCTAssertTrue(state.connectionEstablished())
        XCTAssertEqual(state.phase, .connected)
        XCTAssertEqual(state.reconnectAttempt, 0)
        XCTAssertNil(state.lossReason)
    }

    func testTransportMigrationKeepsTheReceiverSurfaceOnScreen() {
        var state = connectedSession()
        _ = state.connectionAdopted()
        XCTAssertEqual(state.phase, .connecting)
        XCTAssertTrue(state.retainsReceiverSurface, "migration must not flash the idle screen")
        XCTAssertFalse(state.allowsLiveInput, "input stays gated until the new link is live")
    }

    func testAFirstEverConnectStillShowsTheIdleScreen() {
        var state = ReceiverSessionState()
        _ = state.connectionAdopted()
        XCTAssertFalse(state.retainsReceiverSurface)
    }

    // MARK: - Failure and manual recovery

    func testExhaustedRecoveryExposesAManualReconnect() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        exhaustRecovery(&state)
        XCTAssertEqual(state.phase, .reconnectFailed)
        XCTAssertEqual(state.interruption, .reconnectFailed)
        XCTAssertTrue(state.interruption!.offersManualReconnect)
    }

    func testManualReconnectTransitionsBackIntoReconnecting() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        exhaustRecovery(&state)
        XCTAssertTrue(state.requestManualReconnect())
        XCTAssertEqual(state.phase, .reconnecting)
        XCTAssertEqual(state.reconnectAttempt, 0)
        XCTAssertNotNil(state.beginReconnectAttempt())
    }

    func testManualReconnectIsIgnoredWhileRecoveryIsStillRunning() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        XCTAssertFalse(state.requestManualReconnect())
        XCTAssertEqual(state.reconnectAttempt, 0)
    }

    // MARK: - Explicit disconnect

    func testExplicitDisconnectNeverAutomaticallyReconnects() {
        var state = connectedSession()
        XCTAssertTrue(state.connectionLost(reason: .explicitDisconnect))
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertFalse(state.automaticReconnectEnabled)
        XCTAssertNil(state.beginReconnectAttempt())
        XCTAssertNil(state.interruption)
        XCTAssertFalse(state.retainsReceiverSurface)
    }

    func testExplicitDisconnectCannotBeUndoneByALaterTransportLoss() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .explicitDisconnect)
        XCTAssertFalse(state.connectionLost(reason: .transportLost))
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertNil(state.beginReconnectAttempt())
    }

    // MARK: - Stale sessions

    func testEverySessionReplacementBumpsTheGeneration() {
        var state = connectedSession()
        let first = state.generation
        _ = state.connectionLost(reason: .transportLost)
        XCTAssertGreaterThan(state.generation, first)
        let lost = state.generation
        _ = state.connectionAdopted()
        XCTAssertGreaterThan(state.generation, lost)
    }

    /// The core WoL/reconnect-regression invariant: once a session has
    /// settled all the way into "Connection Lost" (reconnect budget spent),
    /// a fresh authenticated connection for the same trusted peer must still
    /// be able to become current. Connection Lost is a session state, not a
    /// refusal to ever connect again.
    func testFreshConnectionSupersedesAConnectionThatReachedLost() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        exhaustRecovery(&state)
        XCTAssertEqual(state.phase, .reconnectFailed)
        let lostGeneration = state.generation

        XCTAssertTrue(state.connectionAdopted())
        XCTAssertGreaterThan(state.generation, lostGeneration)
        XCTAssertEqual(state.phase, .connecting)

        XCTAssertTrue(state.connectionEstablished())
        XCTAssertEqual(state.phase, .connected)
        XCTAssertTrue(state.allowsLiveInput)
    }

    func testDuplicateLossReportsDoNotRestartTheRecoveryRun() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        XCTAssertNotNil(state.beginReconnectAttempt())
        XCTAssertTrue(state.endReconnectAttempt())
        let generation = state.generation
        // A dying socket reports both a failed state and an EOF.
        XCTAssertFalse(state.connectionLost(reason: .transportLost))
        XCTAssertEqual(state.generation, generation)
        XCTAssertEqual(state.reconnectAttempt, 1)
    }

    func testALateLossCannotReopenARecoveryThatAlreadyFailed() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        exhaustRecovery(&state)
        XCTAssertFalse(state.connectionLost(reason: .transportLost))
        XCTAssertEqual(state.phase, .reconnectFailed)
    }

    func testBudgetIsExhaustedExactlyOnceAndNeverLoopsForever() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        exhaustRecovery(&state)
        XCTAssertEqual(state.reconnectAttempt, ReceiverSessionState.maximumReconnectAttempts)
        XCTAssertNil(state.beginReconnectAttempt())
        XCTAssertFalse(state.exhaustRecovery())
    }

    // MARK: - Retry policy

    func testRetryDelayBacksOffAndIsCapped() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        var delays: [TimeInterval] = []
        while true {
            delays.append(state.nextReconnectDelay)
            guard state.beginReconnectAttempt() != nil else { break }
            _ = state.endReconnectAttempt()
        }
        XCTAssertEqual(Array(delays.prefix(5)), [0.5, 1, 2, 4, 8])
        for delay in delays {
            XCTAssertLessThanOrEqual(delay, ReceiverSessionState.maximumReconnectDelay)
        }
    }

    func testOnlyOneAttemptRunsAtATime() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        XCTAssertEqual(state.beginReconnectAttempt(), 1)
        XCTAssertNil(state.beginReconnectAttempt())
        XCTAssertTrue(state.endReconnectAttempt())
        XCTAssertEqual(state.beginReconnectAttempt(), 2)
    }

    // MARK: - Error classification

    func testProtocolIncompatibilityStopsRetrying() {
        var state = connectedSession()
        XCTAssertTrue(state.connectionLost(reason: .protocolIncompatible))
        XCTAssertEqual(state.phase, .unrecoverable)
        XCTAssertNil(state.beginReconnectAttempt())
        XCTAssertEqual(state.interruption, .unrecoverable)
        XCTAssertFalse(state.interruption!.offersManualReconnect)
    }

    func testADeliberatePeerCloseDoesNotEnterRecovery() {
        var state = connectedSession()
        XCTAssertTrue(state.connectionLost(reason: .peerClosed))
        XCTAssertEqual(state.phase, .peerDisconnected)
        XCTAssertNil(state.beginReconnectAttempt())
    }

    func testLossBeforeAnySuccessfulSessionJustReturnsToDisconnected() {
        var state = ReceiverSessionState()
        _ = state.connectionAdopted()
        XCTAssertTrue(state.connectionLost(reason: .transportLost))
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertNil(state.beginReconnectAttempt())
    }

    // MARK: - Auto-Reconnect preference (Settings/Home toggle)

    func testAutoReconnectPreferenceOnRecoversNormally() {
        var state = connectedSession()
        XCTAssertTrue(state.connectionLost(reason: .transportLost, autoReconnectPreferenceEnabled: true))
        XCTAssertEqual(state.phase, .reconnecting)
        XCTAssertNotNil(state.beginReconnectAttempt())
    }

    func testAutoReconnectPreferenceOffGoesStraightToDisconnected() {
        var state = connectedSession()
        XCTAssertTrue(state.connectionLost(reason: .transportLost, autoReconnectPreferenceEnabled: false))
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertNil(state.beginReconnectAttempt())
        XCTAssertNil(state.interruption)
    }

    func testAutoReconnectPreferenceOffStillOffersManualReconnect() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost, autoReconnectPreferenceEnabled: false)
        XCTAssertTrue(state.requestManualReconnect())
        XCTAssertEqual(state.phase, .reconnecting)
        XCTAssertNotNil(state.beginReconnectAttempt())
    }

    /// Explicit-disconnect suppression and the Auto-Reconnect preference are
    /// separate concepts — a disabled preference must not read as, or be
    /// confused with, an explicit Disconnect.
    func testExplicitDisconnectIsUnaffectedByTheAutoReconnectPreference() {
        var state = connectedSession()
        XCTAssertTrue(state.connectionLost(reason: .explicitDisconnect, autoReconnectPreferenceEnabled: false))
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertFalse(state.automaticReconnectEnabled)
    }

    func testDisablingAutoReconnectMidRunSettlesLikeExhaustedRecovery() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        XCTAssertEqual(state.phase, .reconnecting)
        // StreamReceiver.cancelAutomaticRecoveryIfNeeded reuses exactly this
        // transition when the preference flips off mid-run.
        XCTAssertTrue(state.exhaustRecovery())
        XCTAssertEqual(state.phase, .reconnectFailed)
        XCTAssertTrue(state.interruption!.offersManualReconnect)
    }

    // MARK: - Pause stays distinct from recovery

    func testPauseIsNotReconnectingAndStartsNoRecovery() {
        var state = connectedSession()
        XCTAssertTrue(state.displayPaused())
        XCTAssertEqual(state.phase, .paused)
        XCTAssertEqual(state.interruption, .paused)
        XCTAssertNil(state.beginReconnectAttempt())
        XCTAssertEqual(state.reconnectAttempt, 0)
        XCTAssertTrue(state.displayResumed())
        XCTAssertEqual(state.phase, .connected)
    }

    func testPauseCannotOverrideARecoveryAlreadyUnderWay() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        XCTAssertFalse(state.displayPaused())
        XCTAssertEqual(state.phase, .reconnecting)
    }

    func testPausedAndFailedShareMechanicsWithoutSharingBehavior() {
        var paused = connectedSession()
        _ = paused.displayPaused()
        var failed = connectedSession()
        _ = failed.connectionLost(reason: .transportLost)
        exhaustRecovery(&failed)
        // Same presentation mechanics: both retain the receiver surface and
        // both suppress live input.
        XCTAssertTrue(paused.retainsReceiverSurface)
        XCTAssertTrue(failed.retainsReceiverSurface)
        XCTAssertFalse(paused.allowsLiveInput)
        XCTAssertFalse(failed.allowsLiveInput)
        // Different semantics: only the failed one offers a manual retry.
        XCTAssertNotEqual(paused.interruption, failed.interruption)
        XCTAssertFalse(paused.interruption!.offersManualReconnect)
        XCTAssertTrue(failed.interruption!.offersManualReconnect)
    }

    // A stuck reconnectFailed/unrecoverable session must never trap the user
    // on the receiver surface with nothing tappable — the iOS "Back to Home"
    // escape hatch (ReceiverInterruptionOverlay) is gated on this.
    func testOnlyGaveUpStatesOfferBackToHome() {
        XCTAssertFalse(ReceiverSessionInterruption.paused.offersBackToHome)
        XCTAssertFalse(ReceiverSessionInterruption.reconnecting.offersBackToHome)
        XCTAssertTrue(ReceiverSessionInterruption.reconnectFailed.offersBackToHome)
        XCTAssertTrue(ReceiverSessionInterruption.unrecoverable.offersBackToHome)
    }

    // MARK: - Background / foreground

    func testBackgroundingParksRecoveryWithoutBurningItsBudget() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        XCTAssertEqual(state.beginReconnectAttempt(), 1)
        XCTAssertTrue(state.suspendRecoveryForBackground())
        XCTAssertEqual(state.phase, .reconnecting)
        XCTAssertEqual(state.reconnectAttempt, 1)
        // Foregrounding resumes the run rather than starting a new one.
        XCTAssertEqual(state.beginReconnectAttempt(), 2)
    }

    func testBackgroundingASettledSessionDoesNothing() {
        var state = connectedSession()
        XCTAssertFalse(state.suspendRecoveryForBackground())
        XCTAssertEqual(state.phase, .connected)
    }

    func testForegroundRecoveryStillHonorsAnExhaustedBudget() {
        var state = connectedSession()
        _ = state.connectionLost(reason: .transportLost)
        exhaustRecovery(&state)
        XCTAssertFalse(state.suspendRecoveryForBackground())
        XCTAssertNil(state.beginReconnectAttempt())
        XCTAssertEqual(state.phase, .reconnectFailed)
    }

    // MARK: - Explicit Disconnect / Reconnect

    func testManualConnectImmediatelyStartsNewAttemptAfterExplicitDisconnect() {
        var state = connectedSession()

        // 1. connected -> explicit Disconnect
        XCTAssertTrue(state.connectionLost(reason: .explicitDisconnect))
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertFalse(state.automaticReconnectEnabled)

        // -> no automatic reconnect occurs
        XCTAssertNil(state.beginReconnectAttempt())

        // 2. explicit Connect -> new remote attempt starts immediately
        XCTAssertTrue(state.requestManualReconnect())
        XCTAssertEqual(state.phase, .reconnecting)
        XCTAssertTrue(state.automaticReconnectEnabled) // Suppression is cleared for the new intent

        // -> new remote attempt starts immediately
        XCTAssertEqual(state.beginReconnectAttempt(), 1)
        XCTAssertTrue(state.reconnectAttemptInFlight)
    }

    func testExhaustedRecoveryManualConnectStartsFreshAttempt() {
        var state = connectedSession()

        // 1. peer-side/session loss -> automatic recovery
        XCTAssertTrue(state.connectionLost(reason: .transportLost))
        XCTAssertEqual(state.phase, .reconnecting)

        // 2. automatic reconnect attempts exhaust
        for i in 1...ReceiverSessionState.maximumReconnectAttempts {
            XCTAssertEqual(state.beginReconnectAttempt(), i)
            _ = state.endReconnectAttempt()
        }
        XCTAssertNil(state.beginReconnectAttempt())
        _ = state.exhaustRecovery()

        // 3. terminal reconnect-failed state
        XCTAssertEqual(state.phase, .reconnectFailed)
        XCTAssertTrue(state.hasExhaustedReconnectAttempts)

        // 4. Return to Home (disconnect)
        XCTAssertTrue(state.connectionLost(reason: .explicitDisconnect))
        XCTAssertEqual(state.phase, .disconnected)

        // 5. explicit manual Connect
        XCTAssertTrue(state.requestManualReconnect())

        // 6. fresh attempt starts -> retry budget is reset
        XCTAssertEqual(state.phase, .reconnecting)
        XCTAssertFalse(state.hasExhaustedReconnectAttempts)
        XCTAssertEqual(state.reconnectAttempt, 0)
        XCTAssertFalse(state.reconnectAttemptInFlight)

        // 7. remote connect request is eligible/fired
        XCTAssertEqual(state.beginReconnectAttempt(), 1)
        XCTAssertTrue(state.reconnectAttemptInFlight)
    }

    func testExhaustedRecoveryManualReconnectStartsFreshAttempt() {
        var state = connectedSession()

        XCTAssertTrue(state.connectionLost(reason: .transportLost))
        for _ in 1...ReceiverSessionState.maximumReconnectAttempts {
            _ = state.beginReconnectAttempt()
            _ = state.endReconnectAttempt()
        }
        _ = state.exhaustRecovery()
        XCTAssertEqual(state.phase, .reconnectFailed)

        // User taps Reconnect from the Connection Lost overlay directly
        XCTAssertTrue(state.requestManualReconnect())

        // Same fresh-attempt semantics
        XCTAssertEqual(state.phase, .reconnecting)
        XCTAssertFalse(state.hasExhaustedReconnectAttempts)
        XCTAssertEqual(state.reconnectAttempt, 0)
        XCTAssertFalse(state.reconnectAttemptInFlight)
        XCTAssertEqual(state.beginReconnectAttempt(), 1)
    }

    func testPeerDisconnectedExplicitReconnectStartsFreshAttempt() {
        var state = connectedSession()
        XCTAssertTrue(state.connectionLost(reason: .peerClosed))
        XCTAssertEqual(state.phase, .peerDisconnected)
        XCTAssertFalse(state.automaticReconnectEnabled)
        XCTAssertNil(state.beginReconnectAttempt())

        XCTAssertTrue(state.requestManualReconnect())
        XCTAssertEqual(state.phase, .reconnecting)
        XCTAssertTrue(state.automaticReconnectEnabled)
        XCTAssertEqual(state.beginReconnectAttempt(), 1)
    }

    func testStaleTransportLossAfterExplicitIntentIsIgnored() {
        for reason in [ReceiverSessionLossReason.explicitDisconnect, .peerClosed] {
            var state = connectedSession()
            XCTAssertTrue(state.connectionLost(reason: reason))
            let phase = state.phase
            let generation = state.generation
            XCTAssertFalse(state.connectionLost(reason: .transportLost))
            XCTAssertEqual(state.phase, phase)
            XCTAssertEqual(state.generation, generation)
            XCTAssertFalse(state.automaticReconnectEnabled)
            XCTAssertNil(state.beginReconnectAttempt())
        }
    }
}
