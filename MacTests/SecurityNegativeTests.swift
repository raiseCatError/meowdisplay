import XCTest

/// Negative tests for trust and ownership invariants the 2026-11-17 review (C §12) found without
/// a test. Tests only: each drives production code and fails if the invariant breaks.
final class SecurityNegativeTests: XCTestCase {

    // MARK: A replaced attempt can't act on its replacement (#128)

    /// Connect Now replaces this Mac's own automatic attempt: the old session's attempt is
    /// finished and an explicit one takes the slot. The old session's late callbacks are gated
    /// by `isCurrent` (`SenderController.owns`), and its late end path finishes its own attempt
    /// again. Neither may release, retake or duplicate the replacement's slot.
    func testReplacedAutomaticAttemptCannotReleaseOrRetakeItsReplacement() throws {
        let receiver = "install:receiver-a"
        var policy = AutoConnectPolicy(knownIdentifiers: [receiver])
        let automatic = try XCTUnwrap(policy.beginAutomaticAttempt(logicalID: receiver, identifiers: [receiver],
                                                                   hasSessionOwner: false))
        policy.finish(automatic)   // endAutomaticAttemptForExplicitConnect → end(_:)
        let explicit = policy.beginExplicitAttempt(logicalID: receiver, identifiers: [receiver])

        XCTAssertFalse(policy.isCurrent(automatic), "the replaced session's callbacks are ignored")
        XCTAssertTrue(policy.isCurrent(explicit))

        policy.finish(automatic)   // its end path running late
        XCTAssertTrue(policy.isCurrent(explicit), "a stale finish never releases the replacement")
        XCTAssertNil(policy.beginAutomaticAttempt(logicalID: receiver, identifiers: [receiver], hasSessionOwner: false),
                     "and no new automatic attempt starts beside it")
        XCTAssertNotEqual(automatic, explicit)
    }

    // MARK: A controlling device can't widen its own clipboard access

    /// While any device has effective input, the Mac can't be clicked into giving a device more
    /// clipboard access ("Always" or another direction): the click may be that device's own
    /// injected input. Narrowing always works; widening works once nothing controls the Mac.
    func testClipboardAccessIsNeverWidenedWhileADeviceControlsThisMac() throws {
        let suite = "security-negative-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let peer = "phone-1"

        let always = ClipboardDevicePolicy(access: .always, direction: .both)
        XCTAssertFalse(ClipboardDevicePolicyStore.setPolicy(always, peerID: peer, anySessionHasEffectiveInput: true,
                                                            defaults: defaults))
        XCTAssertEqual(ClipboardDevicePolicyStore.policy(peerID: peer, defaults: defaults), .default)

        // Already "Always" for one direction: adding the other is still a widening.
        XCTAssertTrue(ClipboardDevicePolicyStore.setPolicy(ClipboardDevicePolicy(access: .always, direction: .toMac),
                                                           peerID: peer, anySessionHasEffectiveInput: false, defaults: defaults))
        XCTAssertFalse(ClipboardDevicePolicyStore.setPolicy(always, peerID: peer, anySessionHasEffectiveInput: true,
                                                            defaults: defaults))
        XCTAssertEqual(ClipboardDevicePolicyStore.policy(peerID: peer, defaults: defaults).direction, .toMac)

        // Narrowing (back to Ask, or Block) is never refused.
        for narrower in [ClipboardDevicePolicy(access: .ask), ClipboardDevicePolicy(access: .block)] {
            XCTAssertTrue(ClipboardDevicePolicyStore.setPolicy(narrower, peerID: peer, anySessionHasEffectiveInput: true,
                                                               defaults: defaults))
            XCTAssertEqual(ClipboardDevicePolicyStore.policy(peerID: peer, defaults: defaults), narrower)
        }
        XCTAssertTrue(ClipboardDevicePolicyStore.setPolicy(always, peerID: peer, anySessionHasEffectiveInput: false,
                                                           defaults: defaults))
    }
}
