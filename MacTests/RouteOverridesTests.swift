import XCTest

@MainActor
final class RouteOverridesTests: XCTestCase {
    override func tearDown() {
        RouteOverrides.shared.onChange = nil
        RouteOverrides.shared.reset()
        super.tearDown()
    }

    func testAllRoutesAllowedByDefault() {
        RouteOverrides.shared.reset()
        for route: ConnectionRoute in [.usb, .lan, .awdl, .remote] {
            XCTAssertTrue(RouteOverrides.shared.isAllowed(route))
        }
    }

    func testForceRemoteOnlyDisablesEveryOtherRoute() {
        RouteOverrides.shared.forceRemoteOnly()
        XCTAssertFalse(RouteOverrides.shared.isAllowed(.usb))
        XCTAssertFalse(RouteOverrides.shared.isAllowed(.lan))
        XCTAssertFalse(RouteOverrides.shared.isAllowed(.awdl))
        XCTAssertTrue(RouteOverrides.shared.isAllowed(.remote))
    }

    func testResetRestoresAllRoutesAfterForceRemoteOnly() {
        RouteOverrides.shared.forceRemoteOnly()
        RouteOverrides.shared.reset()
        for route: ConnectionRoute in [.usb, .lan, .awdl, .remote] {
            XCTAssertTrue(RouteOverrides.shared.isAllowed(route))
        }
    }

    func testTogglingAnyRouteInvokesOnChangeImmediately() {
        var changeCount = 0
        RouteOverrides.shared.onChange = { changeCount += 1 }
        RouteOverrides.shared.awdlEnabled = false
        XCTAssertEqual(changeCount, 1)
        // The disabled route must already read as disallowed by the time
        // onChange fires — SenderController.enforceRouteOverrides() relies
        // on this ordering to tear down a now-forbidden active session.
        XCTAssertFalse(RouteOverrides.shared.isAllowed(.awdl))
    }
}
