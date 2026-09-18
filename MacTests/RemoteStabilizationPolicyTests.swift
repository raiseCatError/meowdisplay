import XCTest

final class RemoteStabilizationPolicyTests: XCTestCase {
    func testArmsOnFirstRemoteConnection() {
        XCTAssertTrue(RemoteStabilizationPolicy.shouldArm(
            route: .remote, previouslyArmedGeneration: nil, currentGeneration: 1))
    }

    func testDoesNotReArmForRepeatedPathUpdatesInSameGeneration() {
        XCTAssertFalse(RemoteStabilizationPolicy.shouldArm(
            route: .remote, previouslyArmedGeneration: 1, currentGeneration: 1))
    }

    func testReArmsAfterANewConnectionGeneration() {
        XCTAssertTrue(RemoteStabilizationPolicy.shouldArm(
            route: .remote, previouslyArmedGeneration: 1, currentGeneration: 2))
    }

    func testNeverArmsForNonRemoteRoutes() {
        for route: ConnectionRoute in [.usb, .lan, .awdl] {
            XCTAssertFalse(RemoteStabilizationPolicy.shouldArm(
                route: route, previouslyArmedGeneration: nil, currentGeneration: 1),
                "route \(route) must never arm remote stabilization")
        }
    }
}
