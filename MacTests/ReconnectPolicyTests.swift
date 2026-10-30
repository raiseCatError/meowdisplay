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

    /// Inside its disconnect grace a session that was connected redials every second.
    func testAConnectedSessionRedialsEverySecond() {
        for attempt in 1...20 {
            XCTAssertEqual(ReconnectPolicy.retryDelay(attempt: attempt, everConnected: true), 1)
        }
    }

    /// A session that never connected backs off to every 10 seconds instead of
    /// dialing every second forever.
    func testANeverConnectedSessionBacksOff() {
        let delays = (1...8).map { ReconnectPolicy.retryDelay(attempt: $0, everConnected: false) }
        XCTAssertEqual(delays, [1, 2, 4, 8, 10, 10, 10, 10])
        XCTAssertEqual(ReconnectPolicy.retryDelay(attempt: 10_000, everConnected: false), ReconnectPolicy.maxRetryDelay)
        XCTAssertEqual(ReconnectPolicy.retryDelay(attempt: 0, everConnected: false), 1)
    }
}
