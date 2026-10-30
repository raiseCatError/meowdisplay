import XCTest

/// `Mac/TailscaleDiscovery.swift`: parsing `tailscale status --json` and
/// ranking peers for a paired device. Pure — never runs the CLI.
final class TailscaleDiscoveryTests: XCTestCase {
    private let sample = """
    {
      "BackendState": "Running",
      "MagicDNSSuffix": "tail0000.ts.net",
      "Self": {"HostName": "Studio", "DNSName": "studio.tail0000.ts.net.", "OS": "macOS",
               "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"], "Online": true},
      "Peer": {
        "k1": {"HostName": "Pixel Phone", "DNSName": "pixel-phone.tail0000.ts.net.", "OS": "android",
               "TailscaleIPs": ["100.64.0.2"], "Online": false},
        "k2": {"HostName": "localhost", "DNSName": "family-iphone.tail0000.ts.net.", "OS": "iOS",
               "TailscaleIPs": ["100.64.0.3", "fd7a:115c:a1e0::3"], "Online": true},
        "k3": {"HostName": "nas", "DNSName": "nas.tail0000.ts.net.", "OS": "linux",
               "TailscaleIPs": ["100.64.0.4"], "Online": true},
        "k4": {"HostName": "broken", "DNSName": "bad name;rm -rf", "OS": "android", "TailscaleIPs": ["not-an-ip"]}
      }
    }
    """

    func testParsesSelfAndPeersWithoutTrailingDots() throws {
        let status = try XCTUnwrap(TailscaleStatus.parse(Data(sample.utf8)))
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.selfNode?.dnsName, "studio.tail0000.ts.net")
        XCTAssertEqual(status.selfNode?.ipv4, "100.64.0.1")
        XCTAssertEqual(status.selfNode?.ipv6, "fd7a:115c:a1e0::1")
        XCTAssertEqual(status.selfNode?.preferredHost, "studio.tail0000.ts.net", "MagicDNS survives IP changes")
        XCTAssertEqual(status.peers.count, 3, "a peer with no valid name or address is dropped")
        XCTAssertTrue(status.peers.first?.online == true, "online peers first")
    }

    func testRankingPrefersTheNamedDeviceAndSkipsServers() throws {
        let status = try XCTUnwrap(TailscaleStatus.parse(Data(sample.utf8)))
        let forPixel = status.candidates(forDeviceNamed: "Pixel Phone")
        XCTAssertEqual(forPixel.first?.hostName, "Pixel Phone", "a name match wins over being online")
        XCTAssertFalse(forPixel.contains { $0.os == "linux" }, "only phones, tablets and Macs are offered")
        // iOS reports "localhost" as its host name; the MagicDNS label still matches.
        XCTAssertEqual(status.candidates(forDeviceNamed: "Family iPhone").first?.dnsName, "family-iphone.tail0000.ts.net")
        XCTAssertEqual(TailscaleStatus.normalized("Moto G (5S) Plus"), TailscaleStatus.normalized("moto-g-5s-plus"))
    }

    func testStoppedOrGarbageOutputIsNotUsable() {
        XCTAssertEqual(TailscaleStatus.parse(Data(#"{"BackendState":"Stopped","Peer":{}}"#.utf8))?.running, false)
        XCTAssertNil(TailscaleStatus.parse(Data("not json".utf8)))
        XCTAssertNil(TailscaleStatus.parse(Data(repeating: 0x20, count: TailscaleStatus.maximumOutputBytes + 1)))
    }

    func testCLIPathsAreTheDocumentedInstalls() {
        XCTAssertEqual(TailscaleCLI.candidatePaths.first, "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        XCTAssertTrue(TailscaleCLI.candidatePaths.allSatisfy { $0.hasPrefix("/") }, "never resolved through PATH")
    }
}
