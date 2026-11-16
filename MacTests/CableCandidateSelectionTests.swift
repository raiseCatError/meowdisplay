import XCTest

/// The cable upgrade's two caps (PROTOCOL.md 6.4): unchanged under the cap,
/// and over it a cable's entries are not the ones dropped.
final class CableCandidateSelectionTests: XCTestCase {
    private typealias Address = CableCandidateSelection.AdvertisedAddress
    private typealias Probe = CableCandidateSelection.ProbeCandidate

    /// The old receiver loop: dedupe, stop at 12.
    private func oldAdvertised(_ candidates: [Address]) -> [String] {
        var result: [String] = []
        for candidate in candidates {
            if !result.contains(candidate.address) { result.append(candidate.address) }
            if result.count >= 12 { break }
        }
        return result
    }

    private func ipv6Temporaries(_ interface: String, _ count: Int) -> [Address] {
        (0..<count).map { Address(interface: interface, address: "2001:db8::\($0 + 1)") }
    }

    // MARK: - hello.addrs

    func testUnderTheCapTheAddressListIsUnchangedIncludingOrder() {
        let candidates = [
            Address(interface: "en0", address: "192.168.1.20"),
            Address(interface: "en0", address: "fe80::1"),
            Address(interface: "bridge0", address: "fe80::2"),
            Address(interface: "en0", address: "fe80::1"),   // duplicate
            Address(interface: "bridge0", address: "169.254.3.4"),
        ] + ipv6Temporaries("en0", 4)
        XCTAssertEqual(CableCandidateSelection.advertisedAddresses(candidates), oldAdvertised(candidates))
        XCTAssertEqual(CableCandidateSelection.advertisedAddresses(candidates).count, 8)
    }

    func testExactlyTwelveUniqueIsUnchanged() {
        let candidates = ipv6Temporaries("en7", 11) + [Address(interface: "bridge0", address: "fe80::b")]
        XCTAssertEqual(CableCandidateSelection.advertisedAddresses(candidates), oldAdvertised(candidates))
    }

    func testOverTheCapTheBridgeAddressesSurvive() {
        // A USB Ethernet on an IPv6 LAN enumerated before the bridge: the
        // old cut kept only en7's addresses and dropped the cable.
        let candidates = ipv6Temporaries("en7", 12) + [
            Address(interface: "bridge0", address: "fe80::b"),
            Address(interface: "bridge0", address: "169.254.9.9"),
            Address(interface: "en0", address: "192.168.1.20"),
        ]
        XCTAssertFalse(oldAdvertised(candidates).contains("fe80::b"), "the defect being fixed")
        let kept = CableCandidateSelection.advertisedAddresses(candidates)
        XCTAssertEqual(kept.count, 12)
        XCTAssertTrue(kept.contains("fe80::b"))
        XCTAssertTrue(kept.contains("169.254.9.9"))
        // Kept entries stay in their original order.
        XCTAssertEqual(kept, candidates.map(\.address).filter(kept.contains))
    }

    func testOverTheCapLinkLocalComesBeforeRoutable() {
        // A bare Thunderbolt port (no bridge) has only a link-local address.
        let candidates = ipv6Temporaries("en7", 12) + [Address(interface: "en1", address: "fe80::c")]
        XCTAssertTrue(CableCandidateSelection.advertisedAddresses(candidates).contains("fe80::c"))
    }

    func testOverTheCapDuplicatesStillCollapse() {
        let candidates = ipv6Temporaries("en7", 12) + ipv6Temporaries("en7", 3)
            + [Address(interface: "bridge0", address: "fe80::b")]
        let kept = CableCandidateSelection.advertisedAddresses(candidates)
        XCTAssertEqual(kept.count, 12)
        XCTAssertEqual(Set(kept).count, 12)
        XCTAssertEqual(kept.last, "fe80::b")
    }

    // MARK: - Probe dials

    private func probes(direct: Int, fe80: [String], scopes: [String]) -> [Probe] {
        let directs = (0..<direct).map { Probe(host: "2001:db8::\($0 + 1)", scope: nil) }
        let linkLocal = fe80.flatMap { addr in scopes.map { Probe(host: "\(addr)%\($0)", scope: $0) } }
        return directs + linkLocal
    }

    func testUnderTheProbeCapTheListIsUntouched() {
        var list = probes(direct: 3, fe80: ["fe80::a", "fe80::b"], scopes: ["en0", "bridge0"])
        list.append(list[0])   // even a duplicate stays, as before
        var asked = false
        let selected = CableCandidateSelection.probeCandidates(list) { asked = true; return ["en0"] }
        XCTAssertEqual(selected, list)
        XCTAssertFalse(asked, "the Wi-Fi inventory is not consulted under the cap")
    }

    func testOverTheProbeCapWiFiScopedDialsGiveWay() {
        // 8 direct + 3 receiver fe80 × 3 local scopes = 17; the old prefix(16)
        // dropped the last one, the bridge-scoped dial to the cable address.
        let list = probes(direct: 8, fe80: ["fe80::a", "fe80::n", "fe80::b"], scopes: ["en0", "nan0", "bridge0"])
        XCTAssertEqual(list.count, 17)
        XCTAssertFalse(list.prefix(16).contains(Probe(host: "fe80::b%bridge0", scope: "bridge0")))
        let selected = CableCandidateSelection.probeCandidates(list) { ["en0"] }
        XCTAssertEqual(selected.count, 16)
        XCTAssertTrue(selected.contains(Probe(host: "fe80::b%bridge0", scope: "bridge0")))
        XCTAssertFalse(selected.contains(Probe(host: "fe80::b%en0", scope: "en0")))
        XCTAssertEqual(selected, list.filter(selected.contains), "original order kept")
    }

    func testOverTheProbeCapDuplicatesGoFirst() {
        var list = probes(direct: 2, fe80: ["fe80::b"], scopes: ["bridge0"])
        list += Array(repeating: list[0], count: 15)
        let selected = CableCandidateSelection.probeCandidates(list) { [] }
        XCTAssertEqual(selected, probes(direct: 2, fe80: ["fe80::b"], scopes: ["bridge0"]))
    }

    func testOverTheProbeCapNonWiFiLinkLocalBeatsDirect() {
        let list = probes(direct: 16, fe80: ["fe80::b"], scopes: ["bridge0"])
        let selected = CableCandidateSelection.probeCandidates(list) { [] }
        XCTAssertEqual(selected.count, 16)
        XCTAssertTrue(selected.contains(Probe(host: "fe80::b%bridge0", scope: "bridge0")))
        XCTAssertFalse(selected.contains(Probe(host: "2001:db8::16", scope: nil)))
    }

    func testLinkLocalText() {
        for text in ["fe80::1", "FEBF::2", "169.254.0.1"] {
            XCTAssertTrue(CableCandidateSelection.isLinkLocal(text), text)
        }
        for text in ["fec0::1", "2001:db8::1", "192.168.1.1", "fe8"] {
            XCTAssertFalse(CableCandidateSelection.isLinkLocal(text), text)
        }
    }
}
