import XCTest

/// The Tailscale endpoint filter against the vectors Android's TailnetEndpointFilterTest runs too
/// (fixtures/remote/tailnet-endpoint-vectors.json).
final class TailnetEndpointFilterTests: XCTestCase {
    private func vectors() throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/remote/tailnet-endpoint-vectors.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return try XCTUnwrap(root["cases"] as? [[String: Any]])
    }

    func testTheFilterMatchesTheSharedVectors() throws {
        let cases = try vectors()
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        for c in cases {
            let name = try XCTUnwrap(c["name"] as? String)
            let expect = try XCTUnwrap(c["expect"] as? [String: Any])
            let result = TailnetEndpointFilter.filter(
                names: try XCTUnwrap(c["names"] as? [String]),
                addresses: try XCTUnwrap(c["ips"] as? [String]),
                tailnet: c["tailnet"] as? String)
            XCTAssertEqual(result.names, expect["names"] as? [String], name)
            XCTAssertEqual(result.addresses, expect["ips"] as? [String], name)
            let rejected = try XCTUnwrap(expect["rejected"] as? [[String: String]])
            XCTAssertEqual(result.rejected.map { [$0.value, $0.reason.rawValue] },
                           rejected.map { [$0["value"] ?? "", $0["reason"] ?? ""] }, name)
        }
    }

    func testIPv6IsWrittenInRFC5952Form() {
        func format(_ text: String) -> String? {
            TailnetEndpointFilter.parseIPv6(text).map(TailnetEndpointFilter.formatIPv6)
        }
        XCTAssertEqual(format("2001:0db8:0000:0000:0001:0000:0000:0001"), "2001:db8::1:0:0:1", "the first of two equal runs")
        XCTAssertEqual(format("2001:db8:0:1:1:1:1:1"), "2001:db8:0:1:1:1:1:1", "a single zero group is not shortened")
        XCTAssertEqual(format("::"), "::")
        XCTAssertEqual(format("::1"), "::1")
        XCTAssertEqual(format("fd7a:115c:a1e0::"), "fd7a:115c:a1e0::")
        XCTAssertEqual(format("0:0:1:0:0:0:1:0"), "0:0:1::1:0", "the longer run wins")
        XCTAssertNil(format("1::2::3"))
        XCTAssertNil(format("::ffff:100.064.0.1"), "an embedded IPv4 follows the dotted-quad rules")
    }
}
