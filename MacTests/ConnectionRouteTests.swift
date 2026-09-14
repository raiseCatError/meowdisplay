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
}
