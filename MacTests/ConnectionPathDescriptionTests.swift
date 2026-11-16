import Network
import XCTest

/// `ConnectionPathDescription` (#291): the "Direct Cable" wording for a
/// verified Mac-to-Mac Thunderbolt link, and everything that must keep its
/// plain route label. Display only — the route, its tier and its rawValue
/// are unchanged.
final class ConnectionPathDescriptionTests: XCTestCase {
    /// Answers yes only for the interfaces it is given.
    private struct FakeCableInterfaces: HostToHostCableInterfaceChecking {
        let cables: Set<String>
        func isHostToHostCableInterface(_ name: String) -> Bool { cables.contains(name) }
    }

    private let thunderboltBridge = FakeCableInterfaces(cables: ["bridge0"])

    private func evidence(
        interfaces: [String] = ["bridge0"], wifi: Bool = false, cellular: Bool = false,
        loopback: Bool = false, linkLocal: Bool = true, zone: String? = "bridge0", peerIsMac: Bool = true
    ) -> ConnectionPathEvidence {
        ConnectionPathEvidence(interfaceNames: interfaces, usesWiFi: wifi, usesCellular: cellular,
                               usesLoopback: loopback, remoteIsLinkLocal: linkLocal,
                               remoteScopeInterface: zone, peerIsMac: peerIsMac)
    }

    private func label(_ route: ConnectionRoute, _ evidence: ConnectionPathEvidence,
                       cables: HostToHostCableInterfaceChecking? = nil) -> String {
        ConnectionPathDescription(route: route, evidence: evidence,
                                  cableInterfaces: cables ?? thunderboltBridge).label
    }

    // MARK: - Direct cable

    func testDirectThunderboltLinkReadsDirectCable() {
        let description = ConnectionPathDescription(route: .lan, evidence: evidence(),
                                                    cableInterfaces: thunderboltBridge)
        XCTAssertTrue(description.isDirectCable)
        XCTAssertEqual(description.label, "Direct Cable")
        XCTAssertEqual(description.route, .lan, "the route itself stays LAN")
    }

    func testUnscopedLinkLocalUsesThePathsFirstInterface() {
        // 169.254/16 carries no zone: the path's own interface decides.
        XCTAssertEqual(label(.lan, evidence(interfaces: ["bridge0"], zone: nil)), "Direct Cable")
        XCTAssertEqual(label(.lan, evidence(interfaces: ["en7", "bridge0"], zone: nil)), "LAN")
    }

    func testThunderboltPortWithoutABridgeReadsDirectCable() {
        let ports = FakeCableInterfaces(cables: ["en1"])
        XCTAssertEqual(label(.lan, evidence(interfaces: ["en1"], zone: "en1"), cables: ports), "Direct Cable")
    }

    // MARK: - Ordinary Ethernet stays LAN

    func testOrdinaryEthernetWithRoutablePeerReadsLAN() {
        XCTAssertEqual(label(.lan, evidence(interfaces: ["en7"], linkLocal: false, zone: nil)), "LAN")
        // Even an interface the check accepts needs a link-local peer.
        let permissive = FakeCableInterfaces(cables: ["en7"])
        XCTAssertEqual(label(.lan, evidence(interfaces: ["en7"], linkLocal: false, zone: nil),
                             cables: permissive), "LAN")
    }

    func testOrdinaryEthernetWithLinkLocalPeerReadsLAN() {
        // The false-positive case: Bonjour resolved an fe80 peer on a
        // switched Ethernet LAN. Wired + link-local is not a cable.
        XCTAssertEqual(label(.lan, evidence(interfaces: ["en7"], zone: "en7")), "LAN")
    }

    func testWiFiZoneWithBridgeAlsoAvailableReadsLAN() {
        XCTAssertEqual(label(.lan, evidence(interfaces: ["en0", "bridge0"], wifi: true, zone: "en0")), "LAN")
        // The zone decides even if the path were not flagged as Wi-Fi.
        XCTAssertEqual(label(.lan, evidence(interfaces: ["bridge0", "en0"], zone: "en0")), "LAN")
    }

    func testAnyWiFiCellularOrLoopbackOnThePathReadsLAN() {
        XCTAssertEqual(label(.lan, evidence(wifi: true)), "LAN")
        XCTAssertEqual(label(.lan, evidence(cellular: true)), "LAN")
        XCTAssertEqual(label(.lan, evidence(loopback: true)), "LAN")
        XCTAssertEqual(label(.lan, evidence(interfaces: ["lo0", "bridge0"])), "LAN")
    }

    func testPeerToPeerOrTunnelInterfaceOnThePathReadsLAN() {
        XCTAssertEqual(label(.lan, evidence(interfaces: ["bridge0", "awdl0"])), "LAN")
        XCTAssertEqual(label(.lan, evidence(interfaces: ["bridge0", "llw0"])), "LAN")
        XCTAssertEqual(label(.lan, evidence(interfaces: ["bridge0", "utun3"])), "LAN")
    }

    func testPeerThatIsNotAMacReadsLAN() {
        XCTAssertEqual(label(.lan, evidence(peerIsMac: false)), "LAN")
    }

    func testNoInterfaceToCheckReadsLAN() {
        XCTAssertEqual(label(.lan, evidence(interfaces: [], zone: nil)), "LAN")
    }

    func testNoEvidenceOrNoCableCheckReadsTheRoute() {
        XCTAssertEqual(ConnectionPathDescription(route: .lan).label, "LAN")
        XCTAssertEqual(ConnectionPathDescription(route: .lan, evidence: nil,
                                                 cableInterfaces: thunderboltBridge).label, "LAN")
        XCTAssertEqual(label(.lan, evidence(), cables: NoHostToHostCableInterfaces()), "LAN")
    }

    // MARK: - Other routes unchanged

    func testUSBAWDLAndRemoteKeepTheirLabelsWhateverTheEvidence() {
        let cableLooking = evidence()
        XCTAssertEqual(label(.usb, cableLooking), "USB")
        XCTAssertEqual(label(.awdl, cableLooking), "AWDL")
        XCTAssertEqual(label(.remote, cableLooking), "Remote")
        XCTAssertEqual(ConnectionPathDescription(route: .usb).label, "USB")
    }

    func testRouteOfACablePathIsStillLANWithTheLANTier() {
        let route = ConnectionRoute.classify(isUSB: false, interfaceNames: ["bridge0"],
                                             remoteEndpointDescription: "fe80::1%bridge0.7000")
        XCTAssertEqual(route, .lan)
        XCTAssertEqual(route.rawValue, "LAN", "diagnostics keep the route label")
        XCTAssertEqual(RoutePriority.tier(route), RoutePriority.tier(.lan))
        XCTAssertEqual(RoutePriority.tier(route), RoutePriority.tier(.awdl))
        XCTAssertEqual(RouteArbitration.decide(ownerTier: RoutePriority.tier(route),
                                               targetTier: RoutePriority.tier(.usb)), .migrate)
        XCTAssertEqual(RouteArbitration.decide(ownerTier: RoutePriority.tier(route),
                                               targetTier: RoutePriority.tier(.awdl)), .ignore)
        XCTAssertEqual(RouteArbitration.decide(ownerTier: RoutePriority.tier(route),
                                               targetTier: RoutePriority.tier(.remote)), .ignore)
    }

    // MARK: - Surface label

    func testSurfaceLabelUsesTheDescriptionOnlyForItsOwnRoute() {
        let cable = ConnectionPathDescription(route: .lan, evidence: evidence(), cableInterfaces: thunderboltBridge)
        XCTAssertEqual(ConnectionPathDescription.label(route: .lan, description: cable), "Direct Cable")
        XCTAssertEqual(ConnectionPathDescription.label(route: .remote, description: cable), "Remote")
        XCTAssertEqual(ConnectionPathDescription.label(route: .lan, description: nil), "LAN")
        XCTAssertNil(ConnectionPathDescription.label(route: nil, description: cable))
    }

    // MARK: - Endpoint parsing

    func testLinkLocalAddressText() {
        for text in ["fe80::1", "FE80::abcd", "[fe80::1%en1]:7000", "febf::1", "169.254.3.4"] {
            XCTAssertTrue(ConnectionPathDescription.isLinkLocalAddressText(text), text)
        }
        for text in ["fec0::1", "fe00::1", "fd7a:115c:a1e0::1", "192.168.1.4", "10.0.0.1", "2001:db8::1", "fe8"] {
            XCTAssertFalse(ConnectionPathDescription.isLinkLocalAddressText(text), text)
        }
    }

    func testScopeZoneParsing() {
        XCTAssertEqual(ConnectionPathDescription.scopeZone(inEndpointText: "fe80::1%bridge0"), "bridge0")
        XCTAssertEqual(ConnectionPathDescription.scopeZone(inEndpointText: "[fe80::1%en1]:7000"), "en1")
        XCTAssertEqual(ConnectionPathDescription.scopeZone(inEndpointText: "fe80::1%bridge0.7000"), "bridge0")
        XCTAssertNil(ConnectionPathDescription.scopeZone(inEndpointText: "192.168.1.4:7000"))
        XCTAssertNil(ConnectionPathDescription.scopeZone(inEndpointText: "fe80::1%"))
    }

    func testRemoteFactsFromEndpoints() {
        let port = NWEndpoint.Port(rawValue: 7000)!
        let unscoped = ConnectionPathEvidence.remoteFacts(.hostPort(host: .ipv6(IPv6Address("fe80::1")!), port: port))
        XCTAssertTrue(unscoped.isLinkLocal)
        XCTAssertNil(unscoped.zone)

        let routable = ConnectionPathEvidence.remoteFacts(.hostPort(host: .ipv4(IPv4Address("192.168.1.4")!), port: port))
        XCTAssertFalse(routable.isLinkLocal)

        let selfAssigned = ConnectionPathEvidence.remoteFacts(.hostPort(host: .ipv4(IPv4Address("169.254.7.8")!), port: port))
        XCTAssertTrue(selfAssigned.isLinkLocal)

        let text = ConnectionPathEvidence.remoteFacts(.hostPort(host: .name("fe80::1%bridge0", nil), port: port))
        XCTAssertTrue(text.isLinkLocal)
        XCTAssertEqual(text.zone, "bridge0")

        XCTAssertFalse(ConnectionPathEvidence.remoteFacts(nil).isLinkLocal)
        XCTAssertFalse(ConnectionPathEvidence.remoteFacts(.service(name: "x", type: "_opensidecar._tcp",
                                                                  domain: "local.", interface: nil)).isLinkLocal)
    }

    // MARK: - macOS lookup: safe answers for what is never a cable

    func testThunderboltLookupRejectsInterfacesThatCannotBeACable() {
        let lookup = ThunderboltIPInterfaces()
        for name in ["lo0", "", "nosuchif9", "bridge-not-there", String(repeating: "x", count: 40)] {
            XCTAssertFalse(lookup.isHostToHostCableInterface(name), name)
        }
        XCTAssertNil(ThunderboltIPInterfaces.bridgeMembers(of: "lo0"), "lo0 is not a bridge")
    }

    func testBridgeMembersParseTheSystemConfigurationShape() {
        let preferences: [String: Any] = ["Bridge": ["bridge0": [
            "Interfaces": ["en1", "en2"], "Options": ["__AUTO__": "thunderbolt-bridge"]]]]
        XCTAssertEqual(ThunderboltIPInterfaces.bridgeMembers(of: "bridge0", virtualNetworkInterfaces: preferences),
                       ["en1", "en2"])
    }

    func testBridgeMembersAnySurpriseIsNil() {
        func members(_ value: Any?) -> [String]? {
            ThunderboltIPInterfaces.bridgeMembers(of: "bridge0", virtualNetworkInterfaces: value)
        }
        XCTAssertNil(members(nil))
        XCTAssertNil(members("not a dictionary"))
        XCTAssertNil(members(["Bond": ["bridge0": ["Interfaces": ["en1"]]]]))
        XCTAssertNil(members(["Bridge": ["bridge1": ["Interfaces": ["en1"]]]]), "another bridge")
        XCTAssertNil(members(["Bridge": ["bridge0": ["Interfaces": "en1"]]]))
        XCTAssertNil(members(["Bridge": ["bridge0": ["Interfaces": [String]()]]]), "empty")
        XCTAssertNil(members(["Bridge": ["bridge0": ["Interfaces": ["en1", 2] as [Any]]]]), "non-string entry")
        XCTAssertNil(members(["Bridge": ["bridge0": ["Interfaces": ["en1", ""]]]]))
        XCTAssertNil(members(["Bridge": ["bridge0": ["Interfaces": ["en1", "en 2"]]]]))
        XCTAssertNil(members(["Bridge": ["bridge0": ["Interfaces": [String(repeating: "e", count: 16)]]]]))
        let oversized = (0...ThunderboltIPInterfaces.maxBridgeMembers).map { "en\($0)" }
        XCTAssertNil(members(["Bridge": ["bridge0": ["Interfaces": oversized]]]))
    }

    // MARK: - Receiver display label storage

    func testReceiverTransportStateKeepsRouteAndDisplayLabelApart() {
        let state = ReceiverTransportState()
        XCTAssertEqual(state.label(), "—")
        state.set("LAN", label: "Direct Cable")
        XCTAssertEqual(state.get(), "LAN", "diagnostics keep the route")
        XCTAssertEqual(state.label(), "Direct Cable")
        state.set("USB")
        XCTAssertEqual(state.label(), "USB", "no label means the route label")
        state.set("LAN", label: "Direct Cable")
        state.clear()
        XCTAssertEqual(state.get(), "—")
        XCTAssertEqual(state.label(), "—")
    }

    // MARK: - Mac publishing and headline text

    @MainActor
    func testStatusSinkPublishesTheDescriptionEvenWhenTheRouteIsUnchanged() {
        let sink = MacSenderStatusSink()
        var routes: [ConnectionRoute?] = []
        var labels: [String?] = []
        sink.onTransportPath = { routes.append($0) }
        sink.onTransportPathDescription = { labels.append($0?.label) }
        sink.publishTransportPath(.lan, description: ConnectionPathDescription(route: .lan))
        sink.publishTransportPath(.lan, description: ConnectionPathDescription(
            route: .lan, evidence: evidence(), cableInterfaces: thunderboltBridge))
        sink.publishTransportPath(.usb)
        sink.publishTransportPath(nil)
        XCTAssertEqual(routes, [.lan, .lan, .usb, nil])
        XCTAssertEqual(labels, ["LAN", "Direct Cable", "USB", nil])
    }

    func testHeadlinesUseTheRouteLabel() {
        XCTAssertEqual(CanonicalRuntimeStatus.headline(mode: .extend, routeLabel: "Direct Cable"),
                       "Extending · Direct Cable")
        XCTAssertEqual(CanonicalRuntimeStatus.entryStatusText(mode: .mirror, routeLabel: "Direct Cable",
                                                              phase: .paused), "Paused · Direct Cable")
        XCTAssertEqual(CanonicalRuntimeStatus.aggregateStatusText(
            entries: [(mode: .extend, routeLabel: "Direct Cable", phase: .connected)]), "Extending · Direct Cable")
        // The route-taking forms are unchanged.
        XCTAssertEqual(CanonicalRuntimeStatus.headline(mode: .extend, route: .lan), "Extending · LAN")
    }
}
