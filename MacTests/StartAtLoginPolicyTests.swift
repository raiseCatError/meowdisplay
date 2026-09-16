import XCTest
import ServiceManagement

/// Covers only the pure status→message mapping — the seam
/// `StartAtLoginPolicy` exposes specifically so this doesn't have to touch
/// real `SMAppService` side effects (registering/unregistering a login item
/// in a unit test would be both slow and environment-dependent).
final class StartAtLoginPolicyTests: XCTestCase {
    func testEnabledAndNotRegisteredHaveNoMessage() {
        XCTAssertNil(StartAtLoginPolicy.message(for: .enabled))
        XCTAssertNil(StartAtLoginPolicy.message(for: .notRegistered))
    }

    func testRequiresApprovalSurfacesAConciseMessage() {
        XCTAssertNotNil(StartAtLoginPolicy.message(for: .requiresApproval))
    }

    func testNotFoundSurfacesAConciseMessage() {
        XCTAssertNotNil(StartAtLoginPolicy.message(for: .notFound))
    }
}
