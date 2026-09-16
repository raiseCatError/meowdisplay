import XCTest

final class AuthenticatedSessionStateTests: XCTestCase {
    func testTransportReadyIsNotApplicationReady() {
        let state = AuthenticatedSessionState()
        let generation = state.beginTransport()

        XCTAssertFalse(state.isLive(generation: generation))
        XCTAssertNil(state.liveGeneration)
    }

    func testApplicationHandshakeMakesCurrentGenerationLive() {
        let state = AuthenticatedSessionState()
        let generation = state.beginTransport()

        XCTAssertTrue(state.markApplicationReady(generation: generation))
        XCTAssertTrue(state.isLive(generation: generation))
    }

    func testFailureInvalidatesAuthenticatedGeneration() {
        let state = AuthenticatedSessionState()
        let generation = state.beginTransport()
        XCTAssertTrue(state.markApplicationReady(generation: generation))

        state.invalidate(generation: generation)

        XCTAssertFalse(state.isLive(generation: generation))
        XCTAssertNil(state.liveGeneration)
    }

    func testCertificateRejectionCannotProduceConnectedOrAllowCapture() {
        let state = AuthenticatedSessionState()
        let generation = state.beginTransport()

        state.invalidate(generation: generation)

        XCTAssertNil(state.liveGeneration)
        XCTAssertFalse(state.isLive(generation: generation))
    }

    func testStaleGenerationCannotBecomeReadyOrStartWork() {
        let state = AuthenticatedSessionState()
        let stale = state.beginTransport()
        let current = state.beginTransport()

        XCTAssertFalse(state.markApplicationReady(generation: stale))
        XCTAssertFalse(state.isLive(generation: stale))
        XCTAssertTrue(state.markApplicationReady(generation: current))
        XCTAssertTrue(state.isLive(generation: current))
    }
}
