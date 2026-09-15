import XCTest

final class CursorTransportPolicyTests: XCTestCase {
    func testSecureNetworkSessionDoesNotOpenUDP() {
        XCTAssertFalse(CursorTransportPolicy.shouldOpenUDP(
            isSecureNetworkSession: true, advertisedPort: 9001))
    }

    func testDisabledUDPKeepsCursorOnPrimaryTLSConnection() {
        XCTAssertTrue(CursorTransportPolicy.shouldSendOnPrimary(
            udpAvailable: false, udpConfirmed: false))
    }

    func testUnconfirmedUDPStillMirrorsCursorOnPrimaryConnection() {
        XCTAssertTrue(CursorTransportPolicy.shouldSendOnPrimary(
            udpAvailable: true, udpConfirmed: false))
        XCTAssertFalse(CursorTransportPolicy.shouldSendOnPrimary(
            udpAvailable: true, udpConfirmed: true))
    }
}
