import XCTest

final class USBSecureTransportPolicyTests: XCTestCase {
    private let somePin = Data([1, 2, 3])

    func testUnknownUDIDFailsClosed() {
        // Never-seen hardware: no learned peerID at all — must not resolve,
        // regardless of what pins exist for other peers.
        let resolved = USBSecureTransportPolicy.resolve(
            udid: "udid-unknown", installIDByUDID: [:], pin: { _ in self.somePin })
        XCTAssertNil(resolved)
    }

    func testKnownUDIDWithNoPinFailsClosed() {
        // A udid whose identity is known (e.g. from a prior hello) but that
        // identity was forgotten/never paired — still must not resolve.
        let resolved = USBSecureTransportPolicy.resolve(
            udid: "udid-1", installIDByUDID: ["udid-1": "peer-1"], pin: { _ in nil })
        XCTAssertNil(resolved)
    }

    func testMatchingPinResolves() {
        let resolved = USBSecureTransportPolicy.resolve(
            udid: "udid-1", installIDByUDID: ["udid-1": "peer-1"],
            pin: { peerID in peerID == "peer-1" ? self.somePin : nil })
        XCTAssertEqual(resolved, .init(peerID: "peer-1", pin: somePin))
    }

    func testSelfReportedIdentityIsNeverConsulted() {
        // The resolver only ever reads the Mac's OWN previously-learned
        // installIDByUDID mapping and the TrustStore pin closure — there is
        // no parameter through which a peer could supply its own identity at
        // resolution time. A wrong entry in installIDByUDID (simulating a
        // stale/incorrect mapping) resolves to whatever pin THAT peerID has,
        // never bypassing the pin check.
        let resolved = USBSecureTransportPolicy.resolve(
            udid: "udid-1", installIDByUDID: ["udid-1": "peer-attacker"],
            pin: { peerID in peerID == "peer-real" ? self.somePin : nil })
        XCTAssertNil(resolved)
    }

    func testDifferentUDIDsAreIndependent() {
        let installIDByUDID = ["udid-1": "peer-1", "udid-2": "peer-2"]
        let pins: [String: Data] = ["peer-1": somePin]
        let resolvedFirst = USBSecureTransportPolicy.resolve(
            udid: "udid-1", installIDByUDID: installIDByUDID, pin: { pins[$0] })
        let resolvedSecond = USBSecureTransportPolicy.resolve(
            udid: "udid-2", installIDByUDID: installIDByUDID, pin: { pins[$0] })
        XCTAssertEqual(resolvedFirst?.peerID, "peer-1")
        XCTAssertNil(resolvedSecond)
    }
}
