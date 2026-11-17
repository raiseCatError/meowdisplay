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

    func testOverTheProbeCapAnUnscopedLinkLocalAddressIsStillDialled() {
        // The cable's IPv4 link-local address carries no scope; sixteen
        // fe80 pairings on other interfaces must not push it out.
        let scopes = (0..<16).map { "en\($0 + 10)" }
        let list = [Probe(host: "169.254.10.20", scope: nil), Probe(host: "192.168.1.5", scope: nil)]
            + scopes.map { Probe(host: "fe80::b%\($0)", scope: $0) }
        let selected = CableCandidateSelection.probeCandidates(list) { [] }
        XCTAssertEqual(selected.count, 16)
        XCTAssertEqual(selected.first, Probe(host: "169.254.10.20", scope: nil))
        XCTAssertFalse(selected.contains(Probe(host: "192.168.1.5", scope: nil)))
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

/// The whole chain of one probe round as pure data: what the receiver
/// advertises in `hello.addrs`, how the sender pairs it with its own
/// interfaces, and which dials survive the cap. The controller dials
/// exactly `probeRound(...).dials`, in that order.
final class CableProbeRoundTests: XCTestCase {
    private typealias Address = CableCandidateSelection.AdvertisedAddress
    private typealias Probe = CableCandidateSelection.ProbeCandidate

    /// The sender before the cap was made selective: direct addresses,
    /// then each fe80 address on each scope, first sixteen.
    private func oldDials(_ peerAddrs: [String], scopes: [String]) -> [String] {
        var direct: [String] = []
        var linkLocal: [String] = []
        for addr in peerAddrs {
            if addr.lowercased().hasPrefix("fe80:") {
                for iface in scopes { linkLocal.append("\(addr)%\(iface)") }
            } else {
                direct.append(addr)
            }
        }
        return Array((direct + linkLocal).prefix(16))
    }

    /// The receiver before: dedupe, stop at twelve.
    private func oldAdvertised(_ candidates: [Address]) -> [String] {
        var result: [String] = []
        for candidate in candidates {
            if !result.contains(candidate.address) { result.append(candidate.address) }
            if result.count >= 12 { break }
        }
        return result
    }

    private func dials(_ peerAddrs: [String], scopes: [String], wifi: Set<String> = ["en0"]) -> [String] {
        CableCandidateSelection.probeRound(peerAddrs: peerAddrs, scopes: scopes) { wifi }.dials.map(\.host)
    }

    /// A small fixed-seed generator: the same cases on every run.
    private struct Generator {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private func randomReceiver(_ generator: inout Generator) -> [Address] {
        let interfaces = ["en0", "en7", "bridge0", "bridge100", "nan0", "en12"]
        var result: [Address] = []
        for interface in interfaces.prefix(1 + generator.next(interfaces.count)) {
            for index in 0..<generator.next(7) {
                let address: String
                switch generator.next(4) {
                case 0: address = "fe80::\(interface.count)\(index)"
                case 1: address = "169.254.\(interface.count).\(index + 1)"
                case 2: address = "192.168.\(interface.count).\(index + 1)"
                default: address = "2001:db8:\(interface.count)::\(index + 1)"
                }
                result.append(Address(interface: interface, address: address))
            }
        }
        return result
    }

    // MARK: - Pairing and scoping

    func testEachFe80AddressIsDialledOncePerScopeAndOtherAddressesAsTheyAre() {
        let round = CableCandidateSelection.probeRound(
            peerAddrs: ["192.168.1.20", "fe80::a", "169.254.9.9", "FE80::B", "2001:db8::1"],
            scopes: ["en0", "bridge0"]) { XCTFail("not over the cap"); return [] }
        XCTAssertEqual(round.directCount, 3)
        XCTAssertEqual(round.dials, [
            Probe(host: "192.168.1.20", scope: nil),
            Probe(host: "169.254.9.9", scope: nil),      // IPv4 link-local carries no scope
            Probe(host: "2001:db8::1", scope: nil),
            Probe(host: "fe80::a%en0", scope: "en0"),
            Probe(host: "fe80::a%bridge0", scope: "bridge0"),
            Probe(host: "FE80::B%en0", scope: "en0"),
            Probe(host: "FE80::B%bridge0", scope: "bridge0"),
        ])
    }

    func testAnFe80AddressWithNoLocalScopeIsNotDialledAndNothingMeansNoRound() {
        XCTAssertEqual(dials(["fe80::a", "192.168.1.20"], scopes: []), ["192.168.1.20"])
        XCTAssertEqual(dials(["fe80::a"], scopes: []), [])
        XCTAssertEqual(dials([], scopes: ["en0", "bridge0"]), [])
    }

    // MARK: - At and under the caps: nothing changes

    func testExactlySixteenDialsAreTheOldListDuplicatesIncluded() {
        // 4 direct (one repeated) + 4 fe80 × 3 scopes = 16.
        let peerAddrs = ["192.168.1.20", "2001:db8::1", "192.168.1.20", "10.0.0.2",
                         "fe80::a", "fe80::b", "fe80::c", "fe80::d"]
        let scopes = ["en0", "en7", "bridge0"]
        let round = CableCandidateSelection.probeRound(peerAddrs: peerAddrs, scopes: scopes) {
            XCTFail("the Wi-Fi inventory is not read at the cap"); return []
        }
        XCTAssertEqual(round.dials.count, 16)
        XCTAssertEqual(round.dials.map(\.host), oldDials(peerAddrs, scopes: scopes))
    }

    func testUnderBothCapsEveryRoundIsTheOldRoundForOrdinaryNetworks() {
        var generator = Generator(state: 0x4D656F77)
        var compared = 0
        for _ in 0..<2000 {
            let receiver = randomReceiver(&generator)
            let scopes = Array(["en0", "en7", "bridge0", "nan0"].prefix(generator.next(5)))
            let advertised = CableCandidateSelection.advertisedAddresses(receiver)
            guard Set(receiver.map(\.address)).count <= 12 else { continue }
            XCTAssertEqual(advertised, oldAdvertised(receiver))
            let old = oldDials(advertised, scopes: scopes)
            let fe80 = advertised.filter { $0.lowercased().hasPrefix("fe80:") }.count
            guard advertised.count - fe80 + fe80 * scopes.count <= 16 else { continue }
            XCTAssertEqual(dials(advertised, scopes: scopes), old)
            compared += 1
        }
        XCTAssertGreaterThan(compared, 500, "the generator must reach the under-cap cases")
    }

    func testAWiFiOnlyLANWithNoCableIsUnchanged() {
        let receiver = [
            Address(interface: "en0", address: "192.168.1.20"),
            Address(interface: "en0", address: "fe80::1c2"),
            Address(interface: "en0", address: "2001:db8::10"),
            Address(interface: "en0", address: "2001:db8::11"),
        ]
        let advertised = CableCandidateSelection.advertisedAddresses(receiver)
        XCTAssertEqual(advertised, receiver.map(\.address))
        XCTAssertEqual(dials(advertised, scopes: ["en0"]),
                       ["192.168.1.20", "2001:db8::10", "2001:db8::11", "fe80::1c2%en0"])
    }

    // MARK: - Over a cap: bounds always hold

    func testOverEitherCapTheBoundsOrderAndUniquenessHold() {
        var generator = Generator(state: 0xCAB1E)
        var overAdvertised = 0, overDials = 0, wifiGaveWayFirst = 0
        for _ in 0..<2000 {
            let receiver = randomReceiver(&generator) + randomReceiver(&generator)
            let scopes = Array(["en0", "en7", "bridge0", "nan0", "bridge100", "en12"].prefix(generator.next(7)))
            let advertised = CableCandidateSelection.advertisedAddresses(receiver)
            var seen = Set<String>()
            let unique = receiver.map(\.address).filter { seen.insert($0).inserted }
            XCTAssertLessThanOrEqual(advertised.count, 12)
            XCTAssertEqual(advertised.count, min(12, unique.count))
            XCTAssertEqual(advertised, unique.filter(advertised.contains), "a subset, in the original order")
            if unique.count > 12 { overAdvertised += 1 }

            let round = CableCandidateSelection.probeRound(peerAddrs: advertised, scopes: scopes) { ["en0"] }
            let fe80 = advertised.filter { $0.lowercased().hasPrefix("fe80:") }
            let everyDial = advertised.filter { !$0.lowercased().hasPrefix("fe80:") }
                + fe80.flatMap { addr in scopes.map { "\(addr)%\($0)" } }
            let hosts = round.dials.map(\.host)
            XCTAssertLessThanOrEqual(hosts.count, 16)
            XCTAssertEqual(hosts.count, min(16, everyDial.count))
            XCTAssertEqual(hosts, everyDial.filter(hosts.contains), "a subset, in the original order")
            XCTAssertEqual(Set(hosts).count, hosts.count)
            if everyDial.count > 16 {
                overDials += 1
                // A Wi-Fi-scoped dial is kept only when nothing else is left to drop.
                let kept = Set(hosts)
                let droppedOther = everyDial.filter { !kept.contains($0) && !$0.hasSuffix("%en0") }
                if !droppedOther.isEmpty, everyDial.contains(where: { $0.hasSuffix("%en0") }) {
                    wifiGaveWayFirst += 1
                    XCTAssertFalse(hosts.contains { $0.hasSuffix("%en0") }, "\(hosts)")
                }
            }
        }
        XCTAssertGreaterThan(overAdvertised, 100)
        XCTAssertGreaterThan(overDials, 100)
        XCTAssertGreaterThan(wifiGaveWayFirst, 20, "the Wi-Fi rule must really be exercised")
    }

    func testThirteenAdvertisedAndSeventeenDialsDropExactlyOne() {
        let receiver = (0..<12).map { Address(interface: "en7", address: "2001:db8::\($0 + 1)") }
            + [Address(interface: "bridge0", address: "fe80::b")]
        let advertised = CableCandidateSelection.advertisedAddresses(receiver)
        XCTAssertEqual(advertised, receiver.map(\.address).filter { $0 != "2001:db8::12" })

        // 11 direct + 1 fe80 × 6 scopes = 17: the Wi-Fi-scoped dial goes.
        let scopes = ["en0", "en7", "bridge0", "bridge100", "en12", "en13"]
        let hosts = dials(advertised, scopes: scopes)
        XCTAssertEqual(hosts.count, 16)
        XCTAssertFalse(hosts.contains("fe80::b%en0"))
        XCTAssertTrue(hosts.contains("fe80::b%bridge0"))
        XCTAssertEqual(hosts.filter { !$0.contains("%") }.count, 11, "every direct address is still dialled")
    }

    // MARK: - The cable, end to end

    /// A receiver on Wi-Fi and USB Ethernet (both with IPv6 temporaries)
    /// and a Thunderbolt Bridge; a sender with the same three interfaces.
    private func dockedReceiver(bridgeIPv4: Bool) -> [Address] {
        var result = [Address(interface: "en0", address: "192.168.1.20"), Address(interface: "en0", address: "fe80::e0")]
        result += (0..<5).map { Address(interface: "en0", address: "2001:db8:0::\($0 + 1)") }
        result += [Address(interface: "en7", address: "192.168.1.21"), Address(interface: "en7", address: "fe80::e7")]
        result += (0..<5).map { Address(interface: "en7", address: "2001:db8:7::\($0 + 1)") }
        result.append(Address(interface: "bridge0", address: "fe80::b"))
        if bridgeIPv4 { result.append(Address(interface: "bridge0", address: "169.254.9.9")) }
        return result
    }

    func testACableWithABridgeIPv4AddressIsAdvertisedAndBothItsDialsAreMade() {
        let receiver = dockedReceiver(bridgeIPv4: true)
        XCTAssertFalse(oldAdvertised(receiver).contains("fe80::b"), "the old receiver cut the bridge off")
        let advertised = CableCandidateSelection.advertisedAddresses(receiver)
        XCTAssertEqual(advertised.count, 12)
        XCTAssertTrue(advertised.contains("fe80::b") && advertised.contains("169.254.9.9"))
        let hosts = dials(advertised, scopes: ["en0", "en7", "bridge0"])
        XCTAssertLessThanOrEqual(hosts.count, 16)
        XCTAssertTrue(hosts.contains("fe80::b%bridge0"))
        XCTAssertTrue(hosts.contains("169.254.9.9"))
    }

    func testACableWithoutABridgeIPv4AddressIsStillDialledOnTheBridge() {
        let receiver = dockedReceiver(bridgeIPv4: false)
        let advertised = CableCandidateSelection.advertisedAddresses(receiver)
        XCTAssertTrue(advertised.contains("fe80::b"))
        XCTAssertFalse(advertised.contains { $0.hasPrefix("169.254.") })
        let hosts = dials(advertised, scopes: ["en0", "en7", "bridge0"])
        XCTAssertLessThanOrEqual(hosts.count, 16)
        XCTAssertTrue(hosts.contains("fe80::b%bridge0"))
        XCTAssertFalse(hosts.contains("fe80::b%en0"), "the Wi-Fi-scoped dial is the one given up")
    }

    // MARK: - More link-local dials than the cap (the bounded trade-off)

    /// Seventeen or more dials of the best rank cannot all fit in sixteen.
    /// The cap is kept; the earliest stay. This pins what is given up so a
    /// change to it is a decision, not an accident.
    func testMoreThanSixteenEquallyRankedLinkLocalDialsKeepTheEarliestSixteen() {
        let scopes = ["en7", "bridge0", "bridge100", "bridge101", "en12", "en13"]   // none is Wi-Fi
        let peerAddrs = ["192.168.1.20", "169.254.9.9", "fe80::a", "fe80::b", "fe80::c"]
        let hosts = dials(peerAddrs, scopes: scopes, wifi: [])
        XCTAssertEqual(hosts.count, 16)
        // The unscoped IPv4 link-local address (the cable's, when the
        // bridge has one) always survives; the routable address does not.
        XCTAssertEqual(hosts.first, "169.254.9.9")
        XCTAssertFalse(hosts.contains("192.168.1.20"))
        // 18 scoped dials for 15 places: the last address loses three scopes.
        XCTAssertEqual(Array(hosts.dropFirst()), (["fe80::a", "fe80::b"].flatMap { addr in scopes.map { "\(addr)%\($0)" } }
            + ["fe80::c%en7", "fe80::c%bridge0", "fe80::c%bridge100"]))
    }

    func testTheLastAddressOnTheLastScopeIsWhatAnOverfullBestRankGivesUp() {
        // Known limit: with no IPv4 link-local address and the cable's fe80
        // address advertised last, its pairing with a late local scope is
        // outside the sixteen. It needs seventeen or more link-local dials
        // on non-Wi-Fi interfaces; the cap is not raised for it.
        let scopes = ["en7", "bridge100", "bridge101", "en12", "en13", "bridge0"]
        let hosts = dials(["fe80::a", "fe80::c", "fe80::cable"], scopes: scopes, wifi: [])
        XCTAssertEqual(hosts.count, 16)
        XCTAssertFalse(hosts.contains("fe80::cable%bridge0"))
        XCTAssertTrue(hosts.contains("fe80::a%bridge0"))
    }

    // MARK: - No state between rounds or sessions

    func testARoundUsesOnlyTheAddressesItIsGiven() {
        // A new hello (reconnect, another receiver) replaces the list; a
        // round after it must not dial anything of the session before.
        let first = dials(dockedReceiver(bridgeIPv4: true).map(\.address), scopes: ["en0", "en7", "bridge0"])
        XCTAssertEqual(first.count, 16)
        let second = dials(["10.9.9.9", "fe80::2"], scopes: ["en0"])
        XCTAssertEqual(second, ["10.9.9.9", "fe80::2%en0"])
        // The same input gives the same round, whatever ran before.
        XCTAssertEqual(dials(dockedReceiver(bridgeIPv4: true).map(\.address), scopes: ["en0", "en7", "bridge0"]), first)
        // A scope that went away (cable unplugged) is no longer dialled.
        XCTAssertFalse(dials(["fe80::b"], scopes: ["en0"]).contains { $0.hasSuffix("%bridge0") })
    }
}
