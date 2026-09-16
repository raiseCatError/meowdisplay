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
