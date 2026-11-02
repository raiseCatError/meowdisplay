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

    func testOnlyTailscalesTeamSatisfiesTheRequirement() {
        XCTAssertEqual(TailscaleCLI.teamID, "W5364U7YZB")
        XCTAssertEqual(TailscaleCLI.signingRequirement, #"anchor apple generic and certificate leaf[subject.OU] = "W5364U7YZB""#)
        // Apple's own binaries and an app signed by another team are real signatures, just not Tailscale's.
        XCTAssertFalse(TailscaleCLI.isSignedByTailscale(URL(fileURLWithPath: "/bin/ls")))
        XCTAssertFalse(TailscaleCLI.isSignedByTailscale(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        XCTAssertFalse(TailscaleCLI.isSignedByTailscale(URL(fileURLWithPath: "/nonexistent/tailscale")))
    }

    func testAnUnsignedScriptAtACandidatePathIsNotRun() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tailscale-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("tailscale")
        try Data("#!/bin/sh\necho '{}'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        XCTAssertFalse(TailscaleCLI.isSignedByTailscale(script))
    }

    func testTheBundleCarriesTheSignatureAndSymlinksAreResolvedFirst() throws {
        XCTAssertEqual(TailscaleCLI.signedCodeRoot(forExecutable: URL(fileURLWithPath: "/Applications/Tailscale.app/Contents/MacOS/Tailscale")).path,
                       "/Applications/Tailscale.app")
        XCTAssertEqual(TailscaleCLI.signedCodeRoot(forExecutable: URL(fileURLWithPath: "/opt/homebrew/Cellar/tailscale/1.0/bin/tailscale")).path,
                       "/opt/homebrew/Cellar/tailscale/1.0/bin/tailscale", "a bare binary signs itself")

        // A link at a candidate path is judged by what it points to.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tailscale-link-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("Fake.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = app.appendingPathComponent("Tailscale")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let link = dir.appendingPathComponent("tailscale")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
        let resolved = link.resolvingSymlinksInPath()
        XCTAssertEqual(TailscaleCLI.signedCodeRoot(forExecutable: resolved).lastPathComponent, "Fake.app")
    }

    func testResolveRunsOnlyASignedCandidateAndSaysWhyNot() {
        // No candidate on this runner passes Tailscale's signature unless Tailscale is installed.
        switch TailscaleCLI.resolve(isSigned: { _ in false }) {
        case .trusted: XCTFail("nothing passed the check")
        case .untrusted, .notInstalled: break
        }
        if case .trusted(let path) = TailscaleCLI.resolve(isSigned: { _ in true }) {
            XCTAssertTrue(path.hasPrefix("/"), "the resolved path that was checked is the one run")
        }
    }
}
