import XCTest

/// `remoteEndpoints` decoding against the vectors Android's RemoteEndpointsWireTest runs too
/// (fixtures/remote/remote-endpoints-wire.json), the rate limit, the store and own-address selection.
final class RemoteEndpointsWireTests: XCTestCase {
    func testDecodingMatchesTheSharedVectors() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/remote/remote-endpoints-wire.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let frame = Data(try XCTUnwrap(c["frame"] as? String).utf8)
            let decoded = RemoteEndpointsWire.decode(frame: frame)
            if let expect = c["expect"] as? [String: Any] {
                XCTAssertEqual(decoded, RemoteEndpointsWire.Report(names: expect["names"] as? [String] ?? [],
                                                                   ips: expect["ips"] as? [String] ?? []), name)
            } else {
                XCTAssertNil(decoded, name)
            }
        }
    }

    func testAnEncodedReportDecodesToItself() throws {
        let report = RemoteEndpointsWire.Report(names: ["mac.tail1234.ts.net"], ips: ["100.64.0.1", "fd7a:115c:a1e0::1"])
        let frame = try JSONSerialization.data(withJSONObject: RemoteEndpointsWire.message(report))
        XCTAssertEqual(RemoteEndpointsWire.decode(frame: frame), report)
        XCTAssertNil(RemoteEndpointsWire.decode(frame: Data(#"{"type":"wakeInfo","ips":[]}"#.utf8)), "another type")
    }

    func testOneReportPerTenSeconds() {
        var gate = RemoteEndpointsRateGate()
        XCTAssertTrue(gate.admit(now: 100))
        XCTAssertFalse(gate.admit(now: 105))
        XCTAssertFalse(gate.admit(now: 109.9))
        XCTAssertTrue(gate.admit(now: 110))
        XCTAssertTrue(gate.admit(now: 50), "a clock that went back doesn't lock reports out")
    }

    func testThePinDigestIsSHA256Hex() {
        XCTAssertEqual(RemoteEndpointsWire.pinDigest(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class AutomaticRemoteEndpointStoreTests: XCTestCase {
    private var suite = ""
    private var store: AutomaticRemoteEndpointStore!
    private let pin = Data([1, 2, 3])
    private let report = RemoteEndpointsWire.Report(names: ["mac.t.ts.net"], ips: ["100.64.0.1"])

    override func setUp() {
        suite = "AutomaticRemoteEndpointStoreTests-\(UUID().uuidString)"
        store = AutomaticRemoteEndpointStore(role: .sender, defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testAReportIsKeptForThePinItCameWith() {
        let now = Date()
        store.record(report, forPeerID: "A", pin: pin, now: now)
        XCTAssertEqual(store.entry(forPeerID: "A", currentPin: pin, now: now)?.ips, ["100.64.0.1"])
        XCTAssertNil(store.entry(forPeerID: "A", currentPin: Data([9]), now: now), "re-paired with another key")
        XCTAssertNil(store.entry(forPeerID: "A", currentPin: nil, now: now), "forgotten")
        XCTAssertNil(store.entry(forPeerID: "B", currentPin: pin, now: now))
    }

    func testEntriesExpire() {
        let now = Date()
        store.record(report, forPeerID: "A", pin: pin, now: now)
        XCTAssertNotNil(store.entry(forPeerID: "A", currentPin: pin, now: now + AutomaticRemoteEndpointStore.lifetime - 1))
        XCTAssertNil(store.entry(forPeerID: "A", currentPin: pin, now: now + AutomaticRemoteEndpointStore.lifetime))
        XCTAssertNil(store.entry(forPeerID: "A", currentPin: pin, now: now - 7200), "not from the future either")
    }

    func testAnEmptyReportForgetsWhatThePeerSaid() {
        store.record(report, forPeerID: "A", pin: pin)
        store.record(RemoteEndpointsWire.Report(), forPeerID: "A", pin: pin)
        XCTAssertNil(store.entry(forPeerID: "A", currentPin: pin))
    }

    func testRolesAreSeparateAndManualAddressesUntouched() {
        let defaults = UserDefaults(suiteName: suite)!
        let receiver = AutomaticRemoteEndpointStore(role: RolePreferences(isSeparateReceiverRole: true), defaults: defaults)
        store.record(report, forPeerID: "A", pin: pin)
        XCTAssertNil(receiver.entry(forPeerID: "A", currentPin: pin))
        XCTAssertNil(defaults.data(forKey: RolePreferences.sender.key("remoteEndpointHints.v1")))
    }

    func testPruneDropsUnpairedAndExpiredPeers() {
        let now = Date()
        store.record(report, forPeerID: "A", pin: pin, now: now)
        store.record(report, forPeerID: "B", pin: pin, now: now - AutomaticRemoteEndpointStore.lifetime)
        store.record(report, forPeerID: "C", pin: pin, now: now)
        store.prune(pairedPeerIDs: ["A", "B"], now: now)
        XCTAssertNotNil(store.entry(forPeerID: "A", currentPin: pin, now: now))
        XCTAssertNil(store.entry(forPeerID: "B", currentPin: pin, now: now - 1))
        XCTAssertNil(store.entry(forPeerID: "C", currentPin: pin, now: now))
        store.remove(forPeerID: "A")
        XCTAssertNil(store.entry(forPeerID: "A", currentPin: pin, now: now))
    }
}

final class TailnetInterfacesTests: XCTestCase {
    func testOnlyTailnetAddressesOnARunningTunnel() {
        let found = TailnetInterfaces.select([
            .init(interface: "en0", up: true, address: "192.168.1.5"),
            .init(interface: "pdp_ip0", up: true, address: "100.70.1.2"),
            .init(interface: "utun4", up: true, address: "fe80::1"),
            .init(interface: "utun4", up: true, address: "fd7a:115c:a1e0::5"),
            .init(interface: "utun4", up: true, address: "100.101.1.5"),
            .init(interface: "utun7", up: false, address: "100.101.9.9"),
        ])
        XCTAssertEqual(found, ["100.101.1.5", "fd7a:115c:a1e0::5"], "IPv4 first; CGNAT on cellular isn't a tailnet")
        XCTAssertEqual(TailnetInterfaces.select([]), [])
    }
}
