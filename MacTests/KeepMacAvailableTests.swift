import XCTest
import IOKit.pwr_mgt

private final class FakePowerProvider: PowerAssertionProviding {
    var succeeds = true
    var created = 0
    var released: [IOPMAssertionID] = []
    func create(reason: String) -> IOPMAssertionID? {
        guard succeeds else { return nil }
        created += 1
        return IOPMAssertionID(100 + created)
    }
    func release(_ id: IOPMAssertionID) { released.append(id) }
}

final class KeepMacAvailableTests: XCTestCase {
    func testEnableAcquiresAndReportsActive() {
        let p = FakePowerProvider()
        let a = KeepMacAvailableAssertion(provider: p)
        XCTAssertTrue(a.enable())
        XCTAssertTrue(a.isActive)
        XCTAssertEqual(p.created, 1)
    }

    func testDisableReleases() {
        let p = FakePowerProvider()
        let a = KeepMacAvailableAssertion(provider: p)
        a.enable()
        a.disable()
        XCTAssertFalse(a.isActive)
        XCTAssertEqual(p.released, [101])
    }

    func testFailedAcquisitionNeverReportsActive() {
        let p = FakePowerProvider()
        p.succeeds = false
        let a = KeepMacAvailableAssertion(provider: p)
        XCTAssertFalse(a.enable())
        XCTAssertFalse(a.isActive)
    }

    func testRepeatedEnableDoesNotDuplicate() {
        let p = FakePowerProvider()
        let a = KeepMacAvailableAssertion(provider: p)
        a.enable(); a.enable()
        XCTAssertEqual(p.created, 1)
    }

    func testRepeatedDisableIsSafe() {
        let p = FakePowerProvider()
        let a = KeepMacAvailableAssertion(provider: p)
        a.disable()
        a.enable()
        a.disable(); a.disable()
        XCTAssertEqual(p.released.count, 1)
    }

    func testFailedThenRetrySucceeds() {
        let p = FakePowerProvider()
        p.succeeds = false
        let a = KeepMacAvailableAssertion(provider: p)
        a.enable()
        p.succeeds = true
        XCTAssertTrue(a.enable())
    }

    func testFreshInstanceReacquiresAtLaunch() {
        let p = FakePowerProvider()
        let launch = KeepMacAvailableAssertion(provider: p)
        XCTAssertTrue(launch.enable())
        XCTAssertEqual(p.created, 1)
    }
}
