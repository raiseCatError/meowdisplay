import Network
import XCTest

/// Mac/LocalNetworkAccess.swift: telling macOS Local Network privacy apart from an absent device.
final class LocalNetworkAccessTests: XCTestCase {
    func testAProbePathSaysWhetherMacOSBlocksLocalConnections() {
        XCTAssertEqual(LocalNetworkAccess.classify(status: .satisfied, reason: .notAvailable), .allowed)
        XCTAssertEqual(LocalNetworkAccess.classify(status: .unsatisfied, reason: .localNetworkDenied), .denied)
        XCTAssertEqual(LocalNetworkAccess.classify(status: .unsatisfied, reason: .notAvailable), .unknown,
                       "no network is not a privacy block")
    }

    func testTheProbeTargetIsOnTheSubnetButNeverThisMac() {
        func ip(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }
        let mask24 = ip(255, 255, 255, 0)
        XCTAssertEqual(LocalNetworkAccess.probeAddress(address: ip(192, 168, 0, 201), netmask: mask24), ip(192, 168, 0, 1))
        XCTAssertEqual(LocalNetworkAccess.probeAddress(address: ip(192, 168, 0, 1), netmask: mask24), ip(192, 168, 0, 2))
        XCTAssertNil(LocalNetworkAccess.probeAddress(address: ip(10, 0, 0, 5), netmask: ip(255, 255, 255, 254)))
        XCTAssertNil(LocalNetworkAccess.probeAddress(address: ip(10, 0, 0, 5), netmask: 0))
    }

    /// Devices read the Mac's `lnd` hint so a paired iPhone explains the wait instead of spinning.
    func testDevicesSeeTheMacsLocalNetworkHint() {
        let id = UUID().uuidString
        let blocked = NearbyMacDirectory.groups(from: [.init(serviceName: "Mac", txt: ["id": id, "lnd": "1"])])
        XCTAssertEqual(blocked.first?.sessions.first?.localNetworkBlocked, true)
        let fine = NearbyMacDirectory.groups(from: [.init(serviceName: "Mac", txt: ["id": id])])
        XCTAssertEqual(fine.first?.sessions.first?.localNetworkBlocked, false)
    }
}
