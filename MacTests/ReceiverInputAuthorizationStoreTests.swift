import XCTest

/// `ReceiverInputAuthorizationStore` is the permanent per-device policy for
/// "how should the Mac respond to this peer's control request" — see
/// `PeerInputRequestPolicy` and the security invariant in the store's own
/// doc comment. This exercises the store-level contract directly (hostless),
/// mirroring `WakeMetadataStoreTests`.
final class ReceiverInputAuthorizationStoreTests: XCTestCase {
    private func peerID() -> String { "input-auth-test-peer-\(UUID().uuidString)" }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "ReceiverInputAuthorizationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testAPeerDefaultsToAsk() {
        let defaults = isolatedDefaults()
        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: peerID(), defaults: defaults), .ask)
    }

    func testSettingAlwaysAllowPersistsWhenNoSessionHasEffectiveInput() {
        let defaults = isolatedDefaults()
        let id = peerID()

        let applied = ReceiverInputAuthorizationStore.setPolicy(
            .alwaysAllow, peerID: id, anySessionHasEffectiveInput: false, defaults: defaults)

        XCTAssertTrue(applied)
        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: id, defaults: defaults), .alwaysAllow)
    }

    func testSettingNeverAllowAlwaysSucceedsEvenWithEffectiveInputActive() {
        // Narrowing to Never is safe exactly like revocation — it can never
        // be the thing a self-authorizing remote peer exploits.
        let defaults = isolatedDefaults()
        let id = peerID()

        let applied = ReceiverInputAuthorizationStore.setPolicy(
            .neverAllow, peerID: id, anySessionHasEffectiveInput: true, defaults: defaults)

        XCTAssertTrue(applied)
        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: id, defaults: defaults), .neverAllow)
    }

    func testWideningToAlwaysAllowFailsWhileAnySessionHasEffectiveInput() {
        let defaults = isolatedDefaults()
        let id = peerID()

        let applied = ReceiverInputAuthorizationStore.setPolicy(
            .alwaysAllow, peerID: id, anySessionHasEffectiveInput: true, defaults: defaults)

        XCTAssertFalse(applied, "the store layer must reject the widening, not just the UI")
        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: id, defaults: defaults), .ask)
    }

    func testRevertingToAlwaysAllowFailsEvenIfAnotherSessionIsWhatHasInput() {
        // The guard is deliberately not scoped to "this peer's own session"
        // — ANY live session's screen control could click a different
        // peer's row, so it blocks widening for every peer while any
        // session has effective input.
        let defaults = isolatedDefaults()
        let victim = peerID()

        let applied = ReceiverInputAuthorizationStore.setPolicy(
            .alwaysAllow, peerID: victim, anySessionHasEffectiveInput: true, defaults: defaults)

        XCTAssertFalse(applied)
    }

    func testTurningEffectiveInputOffRestoresTheAbilityToWiden() {
        let defaults = isolatedDefaults()
        let id = peerID()
        XCTAssertFalse(ReceiverInputAuthorizationStore.setPolicy(
            .alwaysAllow, peerID: id, anySessionHasEffectiveInput: true, defaults: defaults))

        XCTAssertTrue(ReceiverInputAuthorizationStore.setPolicy(
            .alwaysAllow, peerID: id, anySessionHasEffectiveInput: false, defaults: defaults))
        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: id, defaults: defaults), .alwaysAllow)
    }

    func testRemovePolicyAlwaysSucceedsEvenWithEffectiveInputActive() {
        let defaults = isolatedDefaults()
        let id = peerID()
        XCTAssertTrue(ReceiverInputAuthorizationStore.setPolicy(
            .alwaysAllow, peerID: id, anySessionHasEffectiveInput: false, defaults: defaults))

        ReceiverInputAuthorizationStore.removePolicy(peerID: id, defaults: defaults)

        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: id, defaults: defaults), .ask)
    }

    func testMultiplePeerRecordsDoNotCollide() {
        let defaults = isolatedDefaults()
        let first = peerID()
        let second = peerID()
        ReceiverInputAuthorizationStore.setPolicy(.alwaysAllow, peerID: first, anySessionHasEffectiveInput: false, defaults: defaults)

        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: first, defaults: defaults), .alwaysAllow)
        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: second, defaults: defaults), .ask)
        XCTAssertEqual(ReceiverInputAuthorizationStore.allPolicies(defaults: defaults), [first: .alwaysAllow])
    }

    func testARepairedIdentityNeverInheritsAnOldPeersPolicy() {
        let defaults = isolatedDefaults()
        let old = peerID()
        ReceiverInputAuthorizationStore.setPolicy(.alwaysAllow, peerID: old, anySessionHasEffectiveInput: false, defaults: defaults)
        ReceiverInputAuthorizationStore.removePolicy(peerID: old, defaults: defaults)   // Forget, then re-pair

        // Re-pairing mints a brand-new install-ID-derived peerID (see
        // TrustStore) — it is never the same string as the forgotten one,
        // so it starts at .ask, not merely whatever the old peer left behind.
        let repaired = peerID()
        XCTAssertEqual(ReceiverInputAuthorizationStore.policy(peerID: repaired, defaults: defaults), .ask)
    }
}
