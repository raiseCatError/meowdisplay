import XCTest

/// `ReceiverInputAuthorizationStore` is the permanent per-device record for
/// "may this receiver enable Mac input without a fresh confirmation" — see
/// the security invariant in `SenderController`'s `onAllowInputRequest`
/// wiring (out of reach for this hostless test bundle; this exercises the
/// store-level contract it relies on, mirroring `WakeMetadataStoreTests`).
final class ReceiverInputAuthorizationStoreTests: XCTestCase {
    private func peerID() -> String { "input-auth-test-peer-\(UUID().uuidString)" }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "receiverInputAuthorization.v1")
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
}
