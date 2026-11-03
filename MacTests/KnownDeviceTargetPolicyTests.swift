import XCTest

/// Issue #128: a Known Devices Connect must never dial a USB cable that
/// isn't plugged in just because the device was cabled once.
final class KnownDeviceTargetPolicyTests: XCTestCase {
    private let peer = "install:phone"
    private let otherPeer = "install:tablet"

    private func resolve(map: [String: String], attached: Set<String>,
                         discovered: [String]) -> KnownDeviceTargetPolicy.Route<String>? {
        KnownDeviceTargetPolicy.resolve(peerID: peer, installIDByUDID: map, attachedUDIDs: attached,
                                        discovered: discovered, txtID: { $0 })
    }

    func testUnpluggedButOnceCabledDeviceConnectsOverWiFi() {
        let route = resolve(map: ["udid-1": peer], attached: [], discovered: [otherPeer, peer])
        guard case .wifi(let result)? = route else { return XCTFail("expected Wi-Fi, got \(String(describing: route))") }
        XCTAssertEqual(result, peer)
    }

    func testAttachedDevicePrefersUSB() {
        let route = resolve(map: ["udid-1": peer], attached: ["udid-1"], discovered: [peer])
        guard case .usb(let udid)? = route else { return XCTFail("expected USB, got \(String(describing: route))") }
        XCTAssertEqual(udid, "udid-1")
    }

    func testUnpluggedAndNotNearbyIsUnreachable() {
        XCTAssertNil(resolve(map: ["udid-1": peer], attached: [], discovered: [otherPeer]))
    }

    func testAnotherDevicesCableDoesNotCount() {
        let route = resolve(map: ["udid-1": peer, "udid-2": otherPeer], attached: ["udid-2"], discovered: [])
        XCTAssertNil(route)
    }

    func testSeveralMappedCablesResolveToAnAttachedOneDeterministically() {
        let map = ["udid-c": peer, "udid-a": peer, "udid-b": peer]
        for _ in 0..<20 {
            guard case .usb(let udid)? = resolve(map: map, attached: ["udid-c", "udid-b"], discovered: []) else {
                return XCTFail("expected USB")
            }
            XCTAssertEqual(udid, "udid-b")
        }
    }
}
