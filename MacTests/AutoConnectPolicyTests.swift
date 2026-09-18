import XCTest

final class AutoConnectPolicyTests: XCTestCase {
    private let receiver = "install:receiver-a"
    private let wifi = "wifi:Alice's iPhone"
    private let usb = "usb:00008110"

    func testKnownDeviceAppearingStartsAutomaticAttempt() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        policy.updateAvailableIdentifiers([receiver, wifi])

        XCTAssertNotNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false))
    }

    func testUnknownDeviceDoesNotStartAutomaticAttempt() {
        var policy = AutoConnectPolicy()
        policy.updateAvailableIdentifiers([receiver, wifi])

        XCTAssertNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false))
    }

    func testConnectedDeviceDoesNotRedial() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])

        XCTAssertNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver], hasSessionOwner: true))
    }

    func testConnectingDeviceDoesNotGetDuplicateAttempt() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        let first = policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false)

        XCTAssertNotNil(first)
        XCTAssertNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false))
    }

    func testTwoTransportsForLogicalReceiverShareAttemptOwnership() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        XCTAssertNotNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false))

        XCTAssertNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, usb], hasSessionOwner: false))
    }

    func testManualDisconnectSuppressesDiscoveryUpdates() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        policy.suppress([receiver, wifi])
        policy.updateAvailableIdentifiers([receiver, wifi])

        XCTAssertNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false))
    }

    /// Reused by `SenderController`'s headless-Mirror-offer-timeout handling
    /// (`MacSender.mirrorUnavailableTimeoutErrorCode`): once a "Use Extend?"
    /// offer times out with no answer, the Mac suppresses that peer exactly
    /// like a receiver-initiated `closing` goodbye — otherwise the very next
    /// automatic auto-connect scan would see no session owner for this peer
    /// (the failed attempt already ended) and immediately redial it into
    /// another doomed offer/timeout cycle. A future explicit Connect must
    /// still work.
    func testMirrorOfferTimeoutSuppressionBlocksImmediateAutoRetry() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        // The failed attempt already finished; there is no session owner by
        // the time the next automatic scan runs.
        policy.suppress([receiver, wifi])

        XCTAssertNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false),
            "auto-connect must not immediately re-offer the same peer after a Mirror-offer timeout")

        XCTAssertNotNil(policy.beginExplicitAttempt(logicalID: receiver, identifiers: [receiver, wifi]),
            "an explicit Connect must still be allowed after the timeout suppression")
    }

    func testExplicitConnectClearsSuppression() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        policy.suppress([receiver, wifi])

        let attempt = policy.beginExplicitAttempt(
            logicalID: receiver, identifiers: [receiver, wifi])

        XCTAssertTrue(policy.isCurrent(attempt))
        XCTAssertTrue(policy.suppressedIdentifiers.isDisjoint(with: [receiver, wifi]))
    }

    func testDisappearanceAndReappearanceClearsSuppression() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        policy.suppress([receiver, wifi])
        policy.updateAvailableIdentifiers([])
        policy.updateAvailableIdentifiers([receiver, wifi])

        XCTAssertNotNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false))
    }

    func testMigrationDoesNotCreateSecondLogicalAttempt() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        let attempt = policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false)!

        XCTAssertTrue(policy.isCurrent(attempt))
        XCTAssertNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, usb], hasSessionOwner: true))
    }

    func testStaleAttemptCannotRegainOwnership() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        let old = policy.beginExplicitAttempt(logicalID: receiver, identifiers: [receiver])
        let current = policy.beginExplicitAttempt(logicalID: receiver, identifiers: [receiver])

        XCTAssertFalse(policy.isCurrent(old))
        XCTAssertTrue(policy.isCurrent(current))
        policy.finish(old)
        XCTAssertTrue(policy.isCurrent(current))
    }

    func testOrdinaryLossCanStartFreshAttemptAfterOwnerEnds() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        let first = policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver], hasSessionOwner: false)!
        policy.finish(first)

        XCTAssertNotNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver], hasSessionOwner: false))
    }

    func testExplicitPairingSuppressesAutomaticAttemptForSamePeer() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        policy.beginPairing([receiver])

        XCTAssertNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false))
    }

    func testPairingFailureReleasesSuppression() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        policy.beginPairing([receiver])
        policy.finishPairing([receiver])

        XCTAssertNotNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false))
    }

    func testSuccessfulPairingReleasesSuppressionBeforeExplicitConnect() {
        var policy = AutoConnectPolicy()
        policy.beginPairing([receiver])
        policy.finishPairing([receiver])

        let attempt = policy.beginExplicitAttempt(
            logicalID: receiver, identifiers: [receiver, wifi])
        XCTAssertTrue(policy.isCurrent(attempt))
        XCTAssertFalse(policy.isPairing([receiver]))
    }

    // MARK: - Auto-Reconnect preference (Settings toggle)

    func testAutoReconnectEnabledByDefault() {
        let policy = AutoConnectPolicy()
        XCTAssertTrue(policy.autoReconnectEnabled)
    }

    func testDisablingAutoReconnectSuppressesAutomaticAttempts() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        policy.setAutoReconnectEnabled(false)

        XCTAssertNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false))
    }

    func testDisablingAutoReconnectDoesNotAffectExplicitAttempts() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        policy.setAutoReconnectEnabled(false)

        let attempt = policy.beginExplicitAttempt(logicalID: receiver, identifiers: [receiver])
        XCTAssertTrue(policy.isCurrent(attempt))
    }

    func testDisablingAutoReconnectDoesNotAffectContinuationAttempts() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        policy.setAutoReconnectEnabled(false)

        let attempt = policy.beginContinuationAttempt(logicalID: receiver)
        XCTAssertTrue(policy.isCurrent(attempt))
    }

    func testReenablingAutoReconnectRestoresAutomaticAttempts() {
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        policy.setAutoReconnectEnabled(false)
        XCTAssertNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false))

        policy.setAutoReconnectEnabled(true)
        XCTAssertNotNil(policy.beginAutomaticAttempt(
            logicalID: receiver, identifiers: [receiver, wifi], hasSessionOwner: false))
    }
}
