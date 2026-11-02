import XCTest

/// Covers `AVSyncPreference` (`Shared/StreamReceiver.swift`) — the Receiver
/// Swift6-Hello-Final lock-protected sole authority for the receiver-local
/// manual A/V sync offset (`avSyncOffsetMs`), replacing the old plain
/// `StreamReceiver` stored property. State-equivalence tests only — no
/// queue/thread races that would violate its documented single-queue
/// invariant.
final class AVSyncPreferenceTests: XCTestCase {

    func testDefaultIsZero() {
        let preference = AVSyncPreference()
        XCTAssertEqual(preference.get(), 0)
    }

    func testNormalSetAndGetRoundTrips() {
        let preference = AVSyncPreference()
        preference.set(250)
        XCTAssertEqual(preference.get(), 250)
    }

    func testSetClampsBelowLowerBound() {
        let preference = AVSyncPreference()
        preference.set(AVSyncOffset.range.lowerBound - 500)
        XCTAssertEqual(preference.get(), AVSyncOffset.range.lowerBound)
    }

    func testSetClampsAboveUpperBound() {
        let preference = AVSyncPreference()
        preference.set(AVSyncOffset.range.upperBound + 500)
        XCTAssertEqual(preference.get(), AVSyncOffset.range.upperBound)
    }
}
