import XCTest

final class PreAuthSlotsTests: XCTestCase {
    func testSlotsAreBoundedAndReusable() {
        let slots = PreAuthSlots(limit: 2)
        XCTAssertTrue(slots.tryAcquire())
        XCTAssertTrue(slots.tryAcquire())
        XCTAssertFalse(slots.tryAcquire(), "every slot taken: the newcomer is refused")
        slots.release()
        XCTAssertTrue(slots.tryAcquire(), "a freed slot is usable again")
        slots.release(); slots.release(); slots.release()
        XCTAssertEqual(slots.inUse, 0, "never below zero")
    }

    func testAOneShotReleaseRunsOnce() {
        let slots = PreAuthSlots(limit: 1)
        XCTAssertTrue(slots.tryAcquire())
        let once = OneShotRelease { slots.release() }
        XCTAssertTrue(once.isHeld)
        once.release()
        once.release()   // the deadline firing after the handshake finished
        XCTAssertFalse(once.isHeld)
        XCTAssertEqual(slots.inUse, 0)
        XCTAssertTrue(slots.tryAcquire())
        XCTAssertFalse(slots.tryAcquire(), "a second release didn't free a slot it never held")
    }

}
