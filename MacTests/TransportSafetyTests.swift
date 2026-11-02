import XCTest

final class TransportSafetyTests: XCTestCase {

    // MARK: - pendingSends clamp (M2a)

    func testPendingCountDecrementsNormally() {
        XCTAssertEqual(TransportSafety.decrementedPendingCount(3), 2)
        XCTAssertEqual(TransportSafety.decrementedPendingCount(1), 0)
    }

    func testPendingCountCannotGoNegative() {
        // A late send completion arriving after switchTransport/
        // scheduleReconnect has already reset the counter to zero must not
        // drive it negative.
        XCTAssertEqual(TransportSafety.decrementedPendingCount(0), 0)
        // Repeated late completions stay clamped rather than compounding.
        var count = 0
        for _ in 0..<5 {
            count = TransportSafety.decrementedPendingCount(count)
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: - direct-link classification (M2b)

    func testUSBAndWiredEthernetStillClassifyAsDirectLink() {
        // usbmux-forwarded and Thunderbolt/Ethernet paths report no WiFi/
        // loopback/cellular interface and carry ordinary interface names —
        // existing cable behavior must be unaffected.
        XCTAssertTrue(TransportSafety.isWiredDirectLinkPath(
            usesWiFi: false, usesLoopback: false, usesCellular: false,
            interfaceNames: ["en5"]))
        XCTAssertTrue(TransportSafety.isWiredDirectLinkPath(
            usesWiFi: false, usesLoopback: false, usesCellular: false,
            interfaceNames: ["en10"]))
    }

    func testWiFiLoopbackAndCellularAreNeverDirectLink() {
        XCTAssertFalse(TransportSafety.isWiredDirectLinkPath(
            usesWiFi: true, usesLoopback: false, usesCellular: false,
            interfaceNames: ["en0"]))
        XCTAssertFalse(TransportSafety.isWiredDirectLinkPath(
            usesWiFi: false, usesLoopback: true, usesCellular: false,
            interfaceNames: ["lo0"]))
        XCTAssertFalse(TransportSafety.isWiredDirectLinkPath(
            usesWiFi: false, usesLoopback: false, usesCellular: true,
            interfaceNames: ["pdp_ip0"]))
    }

    func testAWDLLikeNonWiFiPathIsNotClassifiedAsDirectLink() {
        // AWDL does not report as .wifi on macOS, so the old "not WiFi/
        // loopback/cellular" exclusion alone would have classified this as
        // a wired cable. It must not be, or losing the AWDL path would be
        // treated as an unplug and end the session (MacSender.linkDied).
        XCTAssertFalse(TransportSafety.isWiredDirectLinkPath(
            usesWiFi: false, usesLoopback: false, usesCellular: false,
            interfaceNames: ["awdl0"]))
        XCTAssertFalse(TransportSafety.isWiredDirectLinkPath(
            usesWiFi: false, usesLoopback: false, usesCellular: false,
            interfaceNames: ["llw0"]))
        // A path reporting several interfaces is excluded if any of them
        // is AWDL.
        XCTAssertFalse(TransportSafety.isWiredDirectLinkPath(
            usesWiFi: false, usesLoopback: false, usesCellular: false,
            interfaceNames: ["en0", "awdl0"]))
    }
}
