import XCTest

final class RemoteEndpointValidationTests: XCTestCase {
    func testAcceptsTailscaleIPv4() {
        XCTAssertTrue(RemoteEndpointValidation.isSyntacticallyValidHost("100.101.102.103"))
    }

    func testAcceptsTailscaleIPv6() {
        XCTAssertTrue(RemoteEndpointValidation.isSyntacticallyValidHost("fd7a:115c:a1e0::1"))
    }

    func testAcceptsMagicDNSHostname() {
        XCTAssertTrue(RemoteEndpointValidation.isSyntacticallyValidHost("mac-mini.tailnet-name.ts.net"))
    }

    func testAcceptsOrdinaryHostname() {
        XCTAssertTrue(RemoteEndpointValidation.isSyntacticallyValidHost("my-mac.local"))
    }

    func testRejectsEmptyHost() {
        XCTAssertFalse(RemoteEndpointValidation.isSyntacticallyValidHost(""))
    }

    func testRejectsGarbageHost() {
        XCTAssertFalse(RemoteEndpointValidation.isSyntacticallyValidHost("not a host!"))
        XCTAssertFalse(RemoteEndpointValidation.isSyntacticallyValidHost("-leading-hyphen.com"))
    }

    func testDoesNotRequireTailscaleAddressSpace() {
        // Tailscale is networking, not trust — a 192.168.x address or any
        // other reachable host is equally valid here.
        XCTAssertTrue(RemoteEndpointValidation.isSyntacticallyValidHost("192.168.1.50"))
    }

    func testValidatePortRange() {
        switch RemoteEndpointValidation.validate(host: "100.1.1.1", port: "0") {
        case .failure(.invalidPort): break
        default: XCTFail("port 0 should be rejected")
        }
        switch RemoteEndpointValidation.validate(host: "100.1.1.1", port: "9001") {
        case .success(let value): XCTAssertEqual(value.port, 9001)
        default: XCTFail("valid port should succeed")
        }
        switch RemoteEndpointValidation.validate(host: "100.1.1.1", port: "70000") {
        case .failure(.invalidPort): break
        default: XCTFail("out-of-range port should be rejected")
        }
    }

    func testValidateTrimsWhitespaceWithoutRewritingContent() {
        switch RemoteEndpointValidation.validate(host: "  100.1.1.1  ", port: " 9001 ") {
        case .success(let value):
            XCTAssertEqual(value.host, "100.1.1.1")
            XCTAssertEqual(value.port, 9001)
        default: XCTFail("whitespace-padded input should still validate")
        }
    }

    func testValidateDoesNotRequireDNSResolution() {
        // A host that can't be resolved right now (machine asleep/offline)
        // must still be accepted syntactically — Save must not block on
        // reachability.
        switch RemoteEndpointValidation.validate(host: "some-mac.tailnet.ts.net", port: "9001") {
        case .success: break
        default: XCTFail("unresolvable-but-syntactically-valid host should validate")
        }
    }
}
