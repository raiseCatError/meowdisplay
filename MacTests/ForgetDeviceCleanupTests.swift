import XCTest

/// `SenderController.forgetPairing(peerID:)` clears trust plus every
/// per-peer network hint keyed by that same stable peer ID. The full method
/// lives in the (SwiftUI/AppKit-heavy) app target, out of reach for the
/// hostless test bundle — this exercises the same store-level contract its
/// cleanup relies on: removing one peer's `RemoteEndpointStore` and
/// `WakeMetadataStore` entries must never disturb another peer's.
final class ForgetDeviceCleanupTests: XCTestCase {
    private func peerID() -> String { "forget-test-peer-\(UUID().uuidString)" }

    // Granting permanent input authorization now requires Allow Input to be
    // off (a fresh UserDefaults.standard otherwise defaults to "on" — see
    // `InputPolicy.allowsInput`'s "missing means enabled") — pin it off so
    // these pre-existing cleanup tests can still set up their fixtures.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(false, forKey: InputPolicy.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "remoteEndpointHints.v1")
        UserDefaults.standard.removeObject(forKey: "wakeMetadataHints.v1")
        UserDefaults.standard.removeObject(forKey: InputPolicy.defaultsKey)
        super.tearDown()
    }

    func testForgettingOnePeerClearsBothHintStoresWithoutAffectingAnotherPeer() {
        let forgotten = peerID()
        let kept = peerID()

        RemoteEndpointStore.setEndpoint("100.1.1.1", port: 9001, forPeerID: forgotten)
        RemoteEndpointStore.setEndpoint("100.2.2.2", port: 9001, forPeerID: kept)
        WakeMetadataStore.setMetadata(
            WakeMetadata(macAddress: "aa:aa:aa:aa:aa:aa", interfaceName: "en0",
                         updatedAt: Date()), forPeerID: forgotten)
        WakeMetadataStore.setMetadata(
            WakeMetadata(macAddress: "bb:bb:bb:bb:bb:bb", interfaceName: "en0",
                         updatedAt: Date()), forPeerID: kept)

        // Mirrors the cleanup forgetPairing(peerID:) performs.
        RemoteEndpointStore.removeEndpoint(forPeerID: forgotten)
        WakeMetadataStore.removeMetadata(forPeerID: forgotten)

        XCTAssertNil(RemoteEndpointStore.endpoint(forPeerID: forgotten))
        XCTAssertNil(WakeMetadataStore.metadata(forPeerID: forgotten))
        XCTAssertEqual(RemoteEndpointStore.endpoint(forPeerID: kept)?.host, "100.2.2.2")
        XCTAssertEqual(WakeMetadataStore.metadata(forPeerID: kept)?.macAddress, "bb:bb:bb:bb:bb:bb")
    }

    func testForgetActionUsesTheExactStablePeerIDForEveryCleanup() {
        let expected = peerID()
        var trustIDs: [String] = []
        var remoteIDs: [String] = []
        var wakeIDs: [String] = []
        var inputAuthIDs: [String] = []

        ForgetDeviceAction.perform(
            peerID: expected,
            forgetTrust: { trustIDs.append($0) },
            removeRemoteEndpoint: { remoteIDs.append($0) },
            removeWakeMetadata: { wakeIDs.append($0) },
            removeInputAuthorization: { inputAuthIDs.append($0) })

        XCTAssertEqual(trustIDs, [expected])
        XCTAssertEqual(remoteIDs, [expected])
        XCTAssertEqual(wakeIDs, [expected])
        XCTAssertEqual(inputAuthIDs, [expected],
                        "a permanent input authorization must never survive Forget")
    }

    func testForgettingOnePeerRevokesOnlyItsOwnInputAuthorization() {
        let forgotten = peerID()
        let kept = peerID()

        ReceiverInputAuthorizationStore.setAuthorized(true, peerID: forgotten)
        ReceiverInputAuthorizationStore.setAuthorized(true, peerID: kept)
        defer {
            ReceiverInputAuthorizationStore.removeAuthorization(peerID: forgotten)
            ReceiverInputAuthorizationStore.removeAuthorization(peerID: kept)
        }

        ReceiverInputAuthorizationStore.removeAuthorization(peerID: forgotten)

        XCTAssertFalse(ReceiverInputAuthorizationStore.isAuthorized(peerID: forgotten))
        XCTAssertTrue(ReceiverInputAuthorizationStore.isAuthorized(peerID: kept))
    }
}
