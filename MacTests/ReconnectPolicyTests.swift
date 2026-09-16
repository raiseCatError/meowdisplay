import XCTest

final class ReconnectPolicyTests: XCTestCase {
    func testAutomaticRetryAllowedWhenPreferenceOn() {
        XCTAssertTrue(ReconnectPolicy.automaticRetryAllowed(
            autoReconnectEnabled: true, everConnected: true))
    }

    func testAutomaticRetrySuppressedAfterOrdinaryLossWhenPreferenceOff() {
        XCTAssertFalse(ReconnectPolicy.automaticRetryAllowed(
            autoReconnectEnabled: false, everConnected: true))
    }

    /// A session that has never connected yet keeps redialing regardless of
    /// the preference — its first connection was already gated at creation
    /// (an explicit user action, or SenderController.autoConnect()'s own
    /// AutoConnectPolicy check), and this is what lets Wake & Connect redial
    /// a Mac that is still waking up even with the preference off.
    func testInitialDialKeepsRetryingRegardlessOfPreference() {
        XCTAssertTrue(ReconnectPolicy.automaticRetryAllowed(
            autoReconnectEnabled: false, everConnected: false))
        XCTAssertTrue(ReconnectPolicy.automaticRetryAllowed(
            autoReconnectEnabled: true, everConnected: false))
    }
}
