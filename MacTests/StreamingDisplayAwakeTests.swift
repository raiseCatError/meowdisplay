import IOKit.pwr_mgt
import XCTest

/// The display stays awake exactly while a device watches: one assertion, released when nobody
/// watches and when the sender goes away.
final class StreamingDisplayAwakeTests: XCTestCase {
    func testHoldsOneAssertionWhileWatchingAndReleasesIt() {
        var created = 0, released: [IOPMAssertionID] = []
        var awake: StreamingDisplayAwake? = StreamingDisplayAwake(create: { _ in created += 1; return IOPMAssertionID(40 + created) },
                                                                  release: { released.append($0) })
        awake?.set(watching: true)
        awake?.set(watching: true)
        XCTAssertEqual(created, 1, "idempotent")
        XCTAssertTrue(awake?.isHeld ?? false)
        awake?.set(watching: false)
        XCTAssertEqual(released, [41])
        XCTAssertFalse(awake?.isHeld ?? true)
        awake?.set(watching: true)
        awake = nil
        XCTAssertEqual(released, [41, 42], "released when the sender goes away")
    }

    func testARefusedAssertionIsNotHeld() {
        let awake = StreamingDisplayAwake(create: { _ in nil }, release: { _ in XCTFail("nothing to release") })
        awake.set(watching: true)
        XCTAssertFalse(awake.isHeld)
        awake.set(watching: false)
    }
}
