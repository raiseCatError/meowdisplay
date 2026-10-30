import XCTest

final class WakeOnLANTests: XCTestCase {
    func testMagicPacketIsSixBytesOfFFFollowedBySixteenMACRepeats() {
        guard let packet = WakeOnLAN.magicPacket(macAddress: "aa:bb:cc:dd:ee:ff") else {
            return XCTFail("expected a packet")
        }
        XCTAssertEqual(packet.count, 6 + 16 * 6)
        XCTAssertEqual(Array(packet.prefix(6)), [UInt8](repeating: 0xFF, count: 6))
        let macBytes: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        for i in 0..<16 {
            let start = 6 + i * 6
            XCTAssertEqual(Array(packet[start..<start + 6]), macBytes, "repeat \(i)")
        }
    }

    func testMagicPacketAcceptsHyphenSeparatedMAC() {
        XCTAssertNotNil(WakeOnLAN.magicPacket(macAddress: "aa-bb-cc-dd-ee-ff"))
    }

    func testMagicPacketRejectsMalformedMAC() {
        XCTAssertNil(WakeOnLAN.magicPacket(macAddress: "not-a-mac"))
        XCTAssertNil(WakeOnLAN.magicPacket(macAddress: "aa:bb:cc:dd:ee"))
        XCTAssertNil(WakeOnLAN.magicPacket(macAddress: ""))
    }

    func testSendRejectsInvalidBroadcastAddressBeforeTouchingTheNetwork() {
        let result = WakeOnLAN.send(macAddress: "aa:bb:cc:dd:ee:ff", broadcastAddress: "not-an-ip")
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .invalidBroadcastAddress)
    }

    func testSendRejectsInvalidMACBeforeTouchingTheNetwork() {
        let result = WakeOnLAN.send(macAddress: "bogus", broadcastAddress: "192.168.1.255")
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .invalidMACAddress)
    }
}

final class WakeMetadataStoreTests: XCTestCase {
    private func peerID() -> String { "wake-test-peer-\(UUID().uuidString)" }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "wakeMetadataHints.v1")
        super.tearDown()
    }

    func testRoundTripsMetadata() {
        let peer = peerID()
        let metadata = WakeMetadata(macAddress: "aa:bb:cc:dd:ee:ff", interfaceName: "en0",
                                    ipv4: "192.168.1.5", subnetMask: "255.255.255.0",
                                    broadcastAddress: "192.168.1.255", updatedAt: Date())
        XCTAssertNil(WakeMetadataStore.metadata(forPeerID: peer, role: .sender))
        WakeMetadataStore.setMetadata(metadata, forPeerID: peer, role: .sender)
        XCTAssertEqual(WakeMetadataStore.metadata(forPeerID: peer, role: .sender)?.macAddress, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(WakeMetadataStore.metadata(forPeerID: peer, role: .sender)?.broadcastAddress, "192.168.1.255")
    }

    func testChangedAddressOverwritesOnlyTheHintForThatPeer() {
        let peer = peerID()
        let first = WakeMetadata(macAddress: "aa:aa:aa:aa:aa:aa", interfaceName: "en0",
                                 ipv4: "192.168.1.5", subnetMask: nil, broadcastAddress: nil,
                                 updatedAt: Date())
        let second = WakeMetadata(macAddress: "bb:bb:bb:bb:bb:bb", interfaceName: "en1",
                                  ipv4: "10.0.0.5", subnetMask: nil, broadcastAddress: nil,
                                  updatedAt: Date())
        WakeMetadataStore.setMetadata(first, forPeerID: peer, role: .sender)
        WakeMetadataStore.setMetadata(second, forPeerID: peer, role: .sender)
        XCTAssertEqual(WakeMetadataStore.metadata(forPeerID: peer, role: .sender)?.macAddress, "bb:bb:bb:bb:bb:bb")
    }

    func testRemoveMetadataClearsOnlyThatPeer() {
        let peerA = peerID()
        let peerB = peerID()
        let metadata = WakeMetadata(macAddress: "aa:aa:aa:aa:aa:aa", interfaceName: "en0",
                                    ipv4: nil, subnetMask: nil, broadcastAddress: nil, updatedAt: Date())
        WakeMetadataStore.setMetadata(metadata, forPeerID: peerA, role: .sender)
        WakeMetadataStore.setMetadata(metadata, forPeerID: peerB, role: .sender)
        WakeMetadataStore.removeMetadata(forPeerID: peerA, role: .sender)
        XCTAssertNil(WakeMetadataStore.metadata(forPeerID: peerA, role: .sender))
        XCTAssertNotNil(WakeMetadataStore.metadata(forPeerID: peerB, role: .sender))
    }
}

final class WakeInspectorTests: XCTestCase {
    func testComputedBroadcastForOrdinarySlash24Subnet() {
        XCTAssertEqual(WakeInspector.computedBroadcast(ipv4: "192.168.1.42", subnetMask: "255.255.255.0"),
                       "192.168.1.255")
    }

    func testComputedBroadcastForSlash16Subnet() {
        XCTAssertEqual(WakeInspector.computedBroadcast(ipv4: "10.0.5.9", subnetMask: "255.255.0.0"),
                       "10.0.255.255")
    }

    func testComputedBroadcastRejectsMalformedInput() {
        XCTAssertNil(WakeInspector.computedBroadcast(ipv4: "not-an-ip", subnetMask: "255.255.255.0"))
    }

    // A paired Mac's wake information is stored under the Mac that authenticated the connection;
    // a message naming any other peer is dropped (it would replace that Mac's wake target).
    func testWakeInfoIsKeyedByTheAuthenticatedMac() {
        XCTAssertEqual(WakeMetadataStore.storageKey(claimedPeerID: "mac-a", authenticatedPeerID: "mac-a"), "mac-a")
        XCTAssertEqual(WakeMetadataStore.storageKey(claimedPeerID: nil, authenticatedPeerID: "mac-a"), "mac-a")
        XCTAssertNil(WakeMetadataStore.storageKey(claimedPeerID: "mac-b", authenticatedPeerID: "mac-a"), "can't write another Mac's entry")
        XCTAssertNil(WakeMetadataStore.storageKey(claimedPeerID: "mac-a", authenticatedPeerID: nil), "nothing before authentication")
    }

}
