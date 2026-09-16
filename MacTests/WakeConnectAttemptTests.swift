#if DEBUG
import XCTest

/// Pure-state tests for `WakeConnectAttempt` (the Wake & Connect one-tap
/// orchestration's timing/state policy). Timer-driven behavior that lives in
/// `WakeConnectCoordinator` instead (bounded WoL bursts actually firing,
/// connect-token refresh cadence, retry-timer cancellation on success/
/// timeout, the "no duplicate concurrent attempt" and "already-connected
/// skips the attempt" guards) has no pure seam and is exercised by the
/// physical retest instead — see the DEFINITION OF DONE report.
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

    // MARK: - Wrong peer cannot satisfy the attempt

    func testWrongPeerCannotSatisfyTheAttempt() {
        var attempt = WakeConnectAttempt()
        _ = attempt.begin(peerID: "peer-1")
        _ = attempt.connectRequestPublished()
        _ = attempt.transportReady()
        XCTAssertFalse(attempt.applicationAuthenticated(generation: 1, peerID: "peer-2"))
        XCTAssertEqual(attempt.stage, .authenticating)
        XCTAssertTrue(attempt.applicationAuthenticated(generation: 1, peerID: "peer-1"))
        XCTAssertEqual(attempt.stage, .promoting)
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
}
#endif
