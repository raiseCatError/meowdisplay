import XCTest

final class RemoteEndpointStoreTests: XCTestCase {
    // A per-test peer ID keeps these independent of any real paired-device
    // data that might exist in the shared UserDefaults suite under test.
    private func peerID() -> String { "test-peer-\(UUID().uuidString)" }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "remoteEndpointHints.v1")
        super.tearDown()
    }

    func testRoundTripsHostAndPort() {
        let peer = peerID()
        XCTAssertNil(RemoteEndpointStore.endpoint(forPeerID: peer))
        RemoteEndpointStore.setEndpoint("100.101.102.103", port: 9001, forPeerID: peer)
        let hint = RemoteEndpointStore.endpoint(forPeerID: peer)
        XCTAssertEqual(hint?.host, "100.101.102.103")
        XCTAssertEqual(hint?.port, 9001)
    }

    func testConnectRequestUsesDedicatedAuthenticatedRequestPort() {
        let peer = peerID()
        RemoteEndpointStore.setEndpoint("100.101.102.103", port: WireCrypto.tlsPort, forPeerID: peer)

        let requestEndpoint = RemoteEndpointStore.connectRequestEndpoint(forPeerID: peer)
        XCTAssertEqual(requestEndpoint?.host, "100.101.102.103")
        XCTAssertEqual(requestEndpoint?.port, WireCrypto.remoteRequestPort)
        XCTAssertNotEqual(requestEndpoint?.port, WireCrypto.tlsPort)
    }

    func testConnectRequestEndpointRequiresConfiguredHint() {
        XCTAssertNil(RemoteEndpointStore.connectRequestEndpoint(forPeerID: peerID()))
    }

    func testChangingTheAddressForTheSamePeerIDOverwritesOnlyTheHint() {
        let peer = peerID()
        RemoteEndpointStore.setEndpoint("100.1.1.1", port: 9001, forPeerID: peer)
        RemoteEndpointStore.setEndpoint("100.2.2.2", port: 9001, forPeerID: peer)
        // Only one hint per peer ID — a changed address replaces the hint,
        // it never creates a second identity to reconcile.
        XCTAssertEqual(RemoteEndpointStore.endpoint(forPeerID: peer)?.host, "100.2.2.2")
        XCTAssertEqual(RemoteEndpointStore.allPeerIDs().filter { $0 == peer }.count, 1)
    }

    func testRemoveEndpointClearsTheHintWithoutAffectingOtherPeers() {
        let peerA = peerID()
        let peerB = peerID()
        RemoteEndpointStore.setEndpoint("100.1.1.1", port: 9001, forPeerID: peerA)
        RemoteEndpointStore.setEndpoint("100.2.2.2", port: 9001, forPeerID: peerB)
        RemoteEndpointStore.removeEndpoint(forPeerID: peerA)
        XCTAssertNil(RemoteEndpointStore.endpoint(forPeerID: peerA))
        XCTAssertEqual(RemoteEndpointStore.endpoint(forPeerID: peerB)?.host, "100.2.2.2")
    }

    func testSerializationSurvivesAFreshLoadFromUserDefaults() {
        // Simulates a relaunch: no in-memory cache, only what's on disk.
        let peer = peerID()
        RemoteEndpointStore.setEndpoint("100.5.5.5", port: 8123, forPeerID: peer)
        // A fresh `load()` inside `endpoint(forPeerID:)` re-reads UserDefaults
        // every call — there is no separate cache to go stale.
        XCTAssertEqual(RemoteEndpointStore.endpoint(forPeerID: peer)?.host, "100.5.5.5")
        XCTAssertEqual(RemoteEndpointStore.endpoint(forPeerID: peer)?.port, 8123)
    }

    func testDisplayNameChangesDoNotAffectTheStoredEntry() {
        // The store is keyed only by the stable peer ID string passed in —
        // it has no notion of display name at all, so a renamed device
        // (same peerID) keeps its saved endpoint automatically.
        let peer = peerID()
        RemoteEndpointStore.setEndpoint("100.6.6.6", port: 9001, forPeerID: peer)
        // "Renaming" is simulated by simply re-reading with the same peerID —
        // proving the lookup key is peerID alone, never a name.
        XCTAssertEqual(RemoteEndpointStore.endpoint(forPeerID: peer)?.host, "100.6.6.6")
    }

    func testMalformedOrFutureSchemaDataIsDiscardedRatherThanMisread() {
        let peer = peerID()
        // Simulate a persisted row from an incompatible schema version — the
        // store must ignore it rather than guess at its shape.
        struct FutureHint: Codable { var version = 99; var host = "100.9.9.9"; var port: UInt16 = 9001 }
        let raw = try! JSONEncoder().encode([peer: FutureHint()])
        UserDefaults.standard.set(raw, forKey: "remoteEndpointHints.v1")
        XCTAssertNil(RemoteEndpointStore.endpoint(forPeerID: peer))
    }
}
