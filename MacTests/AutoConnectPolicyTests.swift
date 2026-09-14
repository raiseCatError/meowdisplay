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
}
