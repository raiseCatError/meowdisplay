import XCTest
import Network

final class RemoteConnectRequestPolicyTests: XCTestCase {
    func testFirstKnockFromAPeerIsAlwaysHandled() {
        let now = Date()
        XCTAssertTrue(RemoteConnectRequestPolicy.shouldHandle(peerID: "peer-a", now: now, lastAccepted: [:]))
    }

    func testRepeatedKnockWithinTheCooldownIsIgnored() {
        let now = Date()
        let last = now.addingTimeInterval(-1)
        XCTAssertFalse(RemoteConnectRequestPolicy.shouldHandle(
            peerID: "peer-a", now: now, lastAccepted: ["peer-a": last]))
    }

    func testKnockAfterTheCooldownElapsedIsHandledAgain() {
        let now = Date()
        let last = now.addingTimeInterval(-(RemoteConnectRequestPolicy.minimumInterval + 0.1))
        XCTAssertTrue(RemoteConnectRequestPolicy.shouldHandle(
            peerID: "peer-a", now: now, lastAccepted: ["peer-a": last]))
    }

    func testCooldownIsPerPeerNotGlobal() {
        let now = Date()
        // peer-a knocked a moment ago; peer-b never has — a busy/rate-limited
        // peer must never suppress a different peer's legitimate request.
        let lastAccepted = ["peer-a": now.addingTimeInterval(-1)]
        XCTAssertFalse(RemoteConnectRequestPolicy.shouldHandle(peerID: "peer-a", now: now, lastAccepted: lastAccepted))
        XCTAssertTrue(RemoteConnectRequestPolicy.shouldHandle(peerID: "peer-b", now: now, lastAccepted: lastAccepted))
    }

    // A knock over Tailscale/VPN answers on that route first: a stale Bonjour
    // result (the phone left the Wi-Fi without a goodbye) must not shadow it.
    func testKnockOverTunnelDialsTheObservedSourceFirst() {
        XCTAssertEqual(RemoteConnectRequestPolicy.dialOrder(arrivedOverTunnel: true),
                       [.observedSource, .savedHint, .localBonjour])
    }

    // On the local network nothing changes: Bonjour, then the saved hint,
    // then the knock's source as a last resort.
    func testKnockOnTheLocalNetworkKeepsBonjourFirst() {
        XCTAssertEqual(RemoteConnectRequestPolicy.dialOrder(arrivedOverTunnel: false),
                       [.localBonjour, .savedHint, .observedSource])
    }

    // Tailscale and other VPNs surface as utun/ipsec interfaces of type .other.
    func testTunnelInterfacesAreRecognised() {
        XCTAssertTrue(RemoteConnectRequestPolicy.arrivedOverTunnel(interfaceType: .other, interfaceName: "utun4"))
        XCTAssertTrue(RemoteConnectRequestPolicy.arrivedOverTunnel(interfaceType: .other, interfaceName: "ipsec0"))
    }

    // The local network, loopback, other virtual interfaces and an unknown
    // path keep the local order.
    func testLocalAndUnknownInterfacesAreNotTunnels() {
        XCTAssertFalse(RemoteConnectRequestPolicy.arrivedOverTunnel(interfaceType: .wifi, interfaceName: "en0"))
        XCTAssertFalse(RemoteConnectRequestPolicy.arrivedOverTunnel(interfaceType: .wiredEthernet, interfaceName: "en5"))
        XCTAssertFalse(RemoteConnectRequestPolicy.arrivedOverTunnel(interfaceType: .loopback, interfaceName: "lo0"))
        XCTAssertFalse(RemoteConnectRequestPolicy.arrivedOverTunnel(interfaceType: .other, interfaceName: "bridge0"))
        XCTAssertFalse(RemoteConnectRequestPolicy.arrivedOverTunnel(interfaceType: .wifi, interfaceName: "utun4"))
        XCTAssertFalse(RemoteConnectRequestPolicy.arrivedOverTunnel(interfaceType: nil, interfaceName: nil))
    }

    // MARK: - Local first (LocalFirstKnockPolicy)

    // At home on the same Wi-Fi (or in AWDL range) the Remote knock waits, so
    // the local dial gets there first instead of a Tailscale knock winning.
    func testMacVisibleLocallyHoldsTheKnockForTheHeadStart() {
        XCTAssertEqual(LocalFirstKnockPolicy.decide(macVisibleLocally: true, elapsedSinceRunStart: 0),
                       .knockAfter(LocalFirstKnockPolicy.localHeadStart))
        XCTAssertEqual(LocalFirstKnockPolicy.decide(macVisibleLocally: true, elapsedSinceRunStart: 1, headStart: 3),
                       .knockAfter(2))
    }

    // Away from home nothing waits: Remote is the only route.
    func testMacNotVisibleLocallyIsKnockedAtOnce() {
        XCTAssertEqual(LocalFirstKnockPolicy.decide(macVisibleLocally: false, elapsedSinceRunStart: 0), .knockNow)
    }

    // A stale or failing local result costs only the head start: Remote is the fallback.
    func testKnockGoesOutOnceTheHeadStartIsOver() {
        XCTAssertEqual(LocalFirstKnockPolicy.decide(macVisibleLocally: true, elapsedSinceRunStart: 3, headStart: 3),
                       .knockNow)
        XCTAssertEqual(LocalFirstKnockPolicy.decide(macVisibleLocally: true, elapsedSinceRunStart: 20, headStart: 3),
                       .knockNow)
    }

    // A clock that runs backwards never stretches the wait beyond the head start.
    func testNegativeElapsedTimeNeverExceedsTheHeadStart() {
        XCTAssertEqual(LocalFirstKnockPolicy.decide(macVisibleLocally: true, elapsedSinceRunStart: -5, headStart: 3),
                       .knockAfter(3))
    }

    func testHeadStartIsShortButNonZero() {
        XCTAssertGreaterThan(LocalFirstKnockPolicy.localHeadStart, 0)
        XCTAssertLessThanOrEqual(LocalFirstKnockPolicy.localHeadStart, 5)
    }

    func testVisibilityIsPerPeer() {
        let ids: Set<String> = ["mac-a"]
        XCTAssertTrue(LocalFirstKnockPolicy.isVisibleLocally(peerID: "mac-a", discoveredIDs: ids))
        XCTAssertFalse(LocalFirstKnockPolicy.isVisibleLocally(peerID: "mac-b", discoveredIDs: ids))
        XCTAssertFalse(LocalFirstKnockPolicy.isVisibleLocally(peerID: "mac-a", discoveredIDs: []))
    }
}
