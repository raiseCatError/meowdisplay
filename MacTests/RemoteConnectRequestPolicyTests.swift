import XCTest

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
}
