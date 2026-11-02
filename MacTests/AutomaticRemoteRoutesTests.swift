import XCTest

/// Which reported address is dialed, by verified family (Android: AutomaticRemoteRoutesTest, same cases).
final class AutomaticRemoteRoutesTests: XCTestCase {
    private let names = ["mac.tail1.ts.net"]
    private let ips = ["fd7a:115c:a1e0::1", "100.64.0.1"]

    func testOnlyVerifiedFamiliesAreUsedNamesFirstThenIPv4ThenIPv6() {
        XCTAssertEqual(AutomaticRemoteRoutes.host(names: names, ips: ips, families: .android), "100.64.0.1")
        XCTAssertNil(AutomaticRemoteRoutes.host(names: names, ips: ips, families: .none))
        XCTAssertEqual(AutomaticRemoteRoutes.host(names: names, ips: ips, families: .init(ipv4: true, ipv6: true, names: true)), "mac.tail1.ts.net")
        XCTAssertEqual(AutomaticRemoteRoutes.host(names: names, ips: ips, families: .init(ipv4: false, ipv6: true, names: false)), "fd7a:115c:a1e0::1")
        XCTAssertNil(AutomaticRemoteRoutes.host(names: [], ips: ["fd7a:115c:a1e0::1"], families: .android), "no IPv4 reported")
    }

    func testOnlyAndroidDialingIsVerifiedSoFar() {
        XCTAssertEqual(TailnetFamilies.macDialing(device: "Android"), .android)
        for device in ["iPhone", "iPad", "Mac", nil] {
            XCTAssertEqual(TailnetFamilies.macDialing(device: device), .none, "\(device ?? "nil")")
        }
        XCTAssertEqual(TailnetFamilies.appleReceiverKnocking, .none)
    }

    func testTheMacRecordsWhatKindOfDeviceReported() throws {
        let suite = "AutomaticRemoteRoutesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = AutomaticRemoteEndpointStore(role: .sender, defaults: defaults)
        store.record(.init(ips: ["100.64.0.1"]), forPeerID: "A", pin: Data([1]), device: "Android")
        XCTAssertEqual(store.entry(forPeerID: "A", currentPin: Data([1]))?.device, "Android")
        XCTAssertEqual(store.peerIDs(), ["A"])
    }
}
