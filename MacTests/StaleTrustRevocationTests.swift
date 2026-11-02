import XCTest

final class StaleTrustRevocationTests: XCTestCase {
    private let k1 = Data([1])
    private let k2 = Data([2])

    func testForgottenPendingPeerCannotBecomeReady() {
        XCTAssertFalse(SenderApplicationAuthorization.isAllowed(
            intendedPeerID: "P", authenticatedPeerID: "P",
            authenticatedSPKI: k1, currentPinnedSPKI: nil))
    }

    func testRepairedPeerRejectsOldKey() {
        XCTAssertFalse(SenderApplicationAuthorization.isAllowed(
            intendedPeerID: "P", authenticatedPeerID: "P",
            authenticatedSPKI: k1, currentPinnedSPKI: k2))
    }

    func testUnrelatedPeerRemainsAuthorized() {
        XCTAssertTrue(SenderApplicationAuthorization.isAllowed(
            intendedPeerID: "Q", authenticatedPeerID: "Q",
            authenticatedSPKI: k1, currentPinnedSPKI: k1))
    }

    func testPeerIdentityMismatchIsRejected() {
        XCTAssertFalse(SenderApplicationAuthorization.isAllowed(
            intendedPeerID: "P", authenticatedPeerID: "Q",
            authenticatedSPKI: k1, currentPinnedSPKI: k1))
    }

    func testRevokedGenerationCannotMarkReady() {
        let state = AuthenticatedSessionState()
        let generation = state.beginTransport()
        _ = state.invalidate(generation: generation)
        XCTAssertFalse(state.markApplicationReady(generation: generation))
    }
}
