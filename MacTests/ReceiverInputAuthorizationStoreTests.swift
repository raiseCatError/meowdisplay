import XCTest

/// `ReceiverInputAuthorizationStore` is the permanent per-device record for
/// "may this receiver enable Mac input without a fresh confirmation" — see
/// the security invariant in `SenderController`'s `onAllowInputRequest`
/// wiring (out of reach for this hostless test bundle; this exercises the
/// store-level contract it relies on, mirroring `WakeMetadataStoreTests`).
final class ReceiverInputAuthorizationStoreTests: XCTestCase {
    private func peerID() -> String { "input-auth-test-peer-\(UUID().uuidString)" }

    // The store now refuses every write while Allow Input reads true (see
    // "Permanent authorization can only change while Allow Input is off"
    // below), and a fresh/untouched UserDefaults.standard defaults to true
    // (`InputPolicy.allowsInput`'s "missing means enabled"). These
    // grant/revoke-mechanics tests predate that gate and are about the set
    // membership logic, not the gate itself, so pin Allow Input off for
    // their duration exactly like a real Mac session would have it while
    // the user edits permanent device permissions.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(false, forKey: InputPolicy.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "receiverInputAuthorization.v1")
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        super.tearDown()
    }

    func testAPeerIsUnauthorizedByDefault() {
        XCTAssertFalse(ReceiverInputAuthorizationStore.isAuthorized(peerID: peerID()))
    }

    func testAuthorizingAPeerPersists() {
        let id = peerID()
        ReceiverInputAuthorizationStore.setAuthorized(true, peerID: id)
        XCTAssertTrue(ReceiverInputAuthorizationStore.isAuthorized(peerID: id))
    }

    func testRevokingAuthorizationTakesEffectImmediately() {
        let id = peerID()
        ReceiverInputAuthorizationStore.setAuthorized(true, peerID: id)
        ReceiverInputAuthorizationStore.setAuthorized(false, peerID: id)
        XCTAssertFalse(ReceiverInputAuthorizationStore.isAuthorized(peerID: id))
    }

    func testRemoveAuthorizationClearsOnlyThatPeer() {
        let revoked = peerID()
        let kept = peerID()
        ReceiverInputAuthorizationStore.setAuthorized(true, peerID: revoked)
        ReceiverInputAuthorizationStore.setAuthorized(true, peerID: kept)

        ReceiverInputAuthorizationStore.removeAuthorization(peerID: revoked)

        XCTAssertFalse(ReceiverInputAuthorizationStore.isAuthorized(peerID: revoked))
        XCTAssertTrue(ReceiverInputAuthorizationStore.isAuthorized(peerID: kept))
    }

    func testMultiplePeerRecordsDoNotCollide() {
        let first = peerID()
        let second = peerID()
        ReceiverInputAuthorizationStore.setAuthorized(true, peerID: first)

        XCTAssertTrue(ReceiverInputAuthorizationStore.isAuthorized(peerID: first))
        XCTAssertFalse(ReceiverInputAuthorizationStore.isAuthorized(peerID: second))
        XCTAssertEqual(ReceiverInputAuthorizationStore.allAuthorizedPeerIDs(), [first])
    }

    func testARepairedIdentityNeverInheritsAnOldPeersAuthorization() {
        let old = peerID()
        ReceiverInputAuthorizationStore.setAuthorized(true, peerID: old)
        ReceiverInputAuthorizationStore.removeAuthorization(peerID: old)   // Forget, then re-pair

        // Re-pairing mints a brand-new install-ID-derived peerID (see
        // TrustStore) — it is never the same string as the forgotten one,
        // so it starts with no record at all, not merely a "false" one.
        let repaired = peerID()
        XCTAssertFalse(ReceiverInputAuthorizationStore.isAuthorized(peerID: repaired))
    }

    // MARK: - Permanent authorization can only change while Allow Input is off

    private func isolatedDefaults() -> UserDefaults {
        let suite = "ReceiverInputAuthorizationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testGrantingPermanentAuthorizationSucceedsWhileAllowInputIsOff() {
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: InputPolicy.defaultsKey)
        let id = peerID()

        let applied = ReceiverInputAuthorizationStore.setAuthorized(true, peerID: id, defaults: defaults)

        XCTAssertTrue(applied)
        XCTAssertTrue(ReceiverInputAuthorizationStore.isAuthorized(peerID: id, defaults: defaults))
    }

    func testGrantingPermanentAuthorizationFailsWhileAllowInputIsOn() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: InputPolicy.defaultsKey)
        let id = peerID()

        let applied = ReceiverInputAuthorizationStore.setAuthorized(true, peerID: id, defaults: defaults)

        XCTAssertFalse(applied, "the model/store layer must reject the change, not just the UI")
        XCTAssertFalse(ReceiverInputAuthorizationStore.isAuthorized(peerID: id, defaults: defaults))
    }

    func testRevokingPermanentAuthorizationAlsoFailsWhileAllowInputIsOn() {
        // A peer already holding a permanent grant must not be able to keep
        // it stuck, nor have it silently edited, mid-session either — the
        // whole store is frozen, not just the "turn on" direction.
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: InputPolicy.defaultsKey)
        let id = peerID()
        XCTAssertTrue(ReceiverInputAuthorizationStore.setAuthorized(true, peerID: id, defaults: defaults))

        defaults.set(true, forKey: InputPolicy.defaultsKey)
        let applied = ReceiverInputAuthorizationStore.setAuthorized(false, peerID: id, defaults: defaults)

        XCTAssertFalse(applied)
        XCTAssertTrue(ReceiverInputAuthorizationStore.isAuthorized(peerID: id, defaults: defaults))
    }

    func testTurningAllowInputBackOffRestoresTheAbilityToEditPermanentAuthorization() {
        let defaults = isolatedDefaults()
        defaults.set(true, forKey: InputPolicy.defaultsKey)
        let id = peerID()
        XCTAssertFalse(ReceiverInputAuthorizationStore.setAuthorized(true, peerID: id, defaults: defaults))

        defaults.set(false, forKey: InputPolicy.defaultsKey)

        XCTAssertTrue(ReceiverInputAuthorizationStore.setAuthorized(true, peerID: id, defaults: defaults))
        XCTAssertTrue(ReceiverInputAuthorizationStore.isAuthorized(peerID: id, defaults: defaults))
    }

    func testRemovingAuthorizationAlwaysSucceedsEvenWhileAllowInputIsOn() {
        // Forget/revoke must never be blocked by the same gate that blocks
        // granting — it only narrows capability, like relinquishing a live
        // session, so it can't be the thing an attacker exploits by turning
        // input on to "lock in" its own grant.
        let defaults = isolatedDefaults()
        defaults.set(false, forKey: InputPolicy.defaultsKey)
        let id = peerID()
        XCTAssertTrue(ReceiverInputAuthorizationStore.setAuthorized(true, peerID: id, defaults: defaults))

        defaults.set(true, forKey: InputPolicy.defaultsKey)
        ReceiverInputAuthorizationStore.removeAuthorization(peerID: id, defaults: defaults)

        XCTAssertFalse(ReceiverInputAuthorizationStore.isAuthorized(peerID: id, defaults: defaults))
    }
}
