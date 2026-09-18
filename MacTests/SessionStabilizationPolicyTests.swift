import XCTest

final class SessionStabilizationPolicyTests: XCTestCase {
    func testArmsOnFirstAuthenticatedGeneration() {
        XCTAssertTrue(SessionStabilizationPolicy.shouldArm(
            previouslyArmedGeneration: nil, currentGeneration: 1))
    }

    func testDoesNotReArmForTheSameGenerationRepeatedly() {
        XCTAssertFalse(SessionStabilizationPolicy.shouldArm(
            previouslyArmedGeneration: 1, currentGeneration: 1))
    }

    func testReArmsAfterANewConnectionGeneration() {
        XCTAssertTrue(SessionStabilizationPolicy.shouldArm(
            previouslyArmedGeneration: 1, currentGeneration: 2))
    }

    /// A same-peer route migration (`switchTransport`) redials, which mints
    /// a new connection generation on the new transport — this is exactly
    /// how a migration is expected to extend/reset the stabilization window
    /// rather than needing a route-specific signal.
    func testRouteMigrationGenerationReArms() {
        XCTAssertTrue(SessionStabilizationPolicy.shouldArm(
            previouslyArmedGeneration: 3, currentGeneration: 4))
    }
}
