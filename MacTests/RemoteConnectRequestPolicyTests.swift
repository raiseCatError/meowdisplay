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
}
