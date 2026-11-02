import XCTest

final class ConnectionRouteTests: XCTestCase {
    func testExplicitUSBAlwaysWins() {
        XCTAssertEqual(ConnectionRoute.classify(
            isUSB: true,
            interfaceNames: ["en0", "awdl0"],
            remoteEndpointDescription: "[fe80::1%awdl0]:9000"), .usb)
    }

    func testScopedAWDLAndLLWEndpointsArePeerToPeer() {
        for scope in ["awdl0", "llw0"] {
            XCTAssertEqual(ConnectionRoute.classify(
                isUSB: false,
                interfaceNames: ["en0", scope],
                remoteEndpointDescription: "[fe80::1%\(scope)]:9000"), .awdl)
        }
    }

    func testNonWiFiAWDLAndLLWInterfacesArePeerToPeer() {
        for name in ["awdl0", "llw0"] {
            XCTAssertEqual(ConnectionRoute.classify(
                isUSB: false,
                interfaceNames: [name],
                remoteEndpointDescription: nil), .awdl)
        }
    }

    func testWiFiPathWithLANAndPeerToPeerInterfacesRemainsLAN() {
        XCTAssertEqual(ConnectionRoute.classify(
            isUSB: false,
            interfaceNames: ["en0", "awdl0", "llw0"],
            remoteEndpointDescription: "192.168.1.20:9000"), .lan)
    }

    func testNonWiFiPathWithEthernetAndAWDLInterfacesRemainsLAN() {
        XCTAssertEqual(ConnectionRoute.classify(
            isUSB: false,
            interfaceNames: ["en5", "awdl0"],
            remoteEndpointDescription: "10.0.0.20:9000"), .lan)
    }

    func testOrdinaryWiFiAndEthernetPathsAreLAN() {
        XCTAssertEqual(ConnectionRoute.classify(
            isUSB: false,
            interfaceNames: ["en0"],
            remoteEndpointDescription: "192.168.1.20:9000"), .lan)
        XCTAssertEqual(ConnectionRoute.classify(
            isUSB: false,
            interfaceNames: ["en5"],
            remoteEndpointDescription: "10.0.0.20:9000"), .lan)
    }

    func testUtunInterfaceClassifiesAsRemote() {
        XCTAssertEqual(ConnectionRoute.classify(
            isUSB: false,
            interfaceNames: ["utun3"],
            remoteEndpointDescription: "100.101.102.103:9001"), .remote)
    }

    func testTailscaleCGNATAddressClassifiesAsRemoteEvenWithoutUtunName() {
        XCTAssertEqual(ConnectionRoute.classify(
            isUSB: false,
            interfaceNames: ["en0"],
            remoteEndpointDescription: "100.64.1.2:9001"), .remote)
    }

    func testOrdinary100DotAddressOutsideCGNATRangeIsNotRemote() {
        // 100.200.x.x has second octet 200 — outside the 100.64.0.0/10 CGNAT
        // block Tailscale actually assigns from, so this must stay LAN.
        XCTAssertEqual(ConnectionRoute.classify(
            isUSB: false,
            interfaceNames: ["en0"],
            remoteEndpointDescription: "100.200.1.2:9001"), .lan)
    }

    func testTailscaleIPv6ULAClassifiesAsRemote() {
        XCTAssertEqual(ConnectionRoute.classify(
            isUSB: false,
            interfaceNames: ["en0"],
            remoteEndpointDescription: "[fd7a:115c:a1e0::1]:9001"), .remote)
    }

    func testUSBStillWinsOverATailscaleLookingEndpoint() {
        XCTAssertEqual(ConnectionRoute.classify(
            isUSB: true,
            interfaceNames: ["utun3"],
            remoteEndpointDescription: "100.64.1.2:9001"), .usb)
    }
}
