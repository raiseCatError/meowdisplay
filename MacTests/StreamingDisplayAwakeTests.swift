import IOKit.pwr_mgt
import XCTest

/// The display stays awake exactly while at least one device watches: one assertion for the
/// whole app, counted across viewers, released after the last one and while switched out.
final class StreamingDisplayAwakeTests: XCTestCase {
    private var created = 0
    private var released: [IOPMAssertionID] = []

    private func ledger(onConsole: Bool = true) -> DisplayAwakeLedger {
        DisplayAwakeLedger(onConsole: onConsole,
                           create: { [unowned self] _ in created += 1; return IOPMAssertionID(40 + created) },
                           release: { [unowned self] in released.append($0) })
    }

    func testOneAssertionIsSharedByEveryViewerAndReleasedAfterTheLast() {
        let ledger = ledger()
        let iPhone = StreamingDisplayAwake(ledger: ledger)
        let iPad = StreamingDisplayAwake(ledger: ledger)
        iPhone.set(watching: true)
        iPhone.set(watching: true)
        iPad.set(watching: true)
        XCTAssertEqual(created, 1, "one assertion for all viewers; repeated calls are idempotent")
        XCTAssertEqual(ledger.watcherCount, 2)
        iPhone.set(watching: false)
        XCTAssertTrue(ledger.isHeld, "the iPad still watches")
        XCTAssertEqual(released, [])
        iPad.set(watching: false)
        XCTAssertEqual(released, [41], "released with the last viewer")
        XCTAssertFalse(ledger.isHeld)
        iPhone.set(watching: false)
        XCTAssertEqual(released, [41], "no double release")
    }

    func testASenderThatGoesAwayStopsWatching() {
        let ledger = ledger()
        var sender: StreamingDisplayAwake? = StreamingDisplayAwake(ledger: ledger)
        let other = StreamingDisplayAwake(ledger: ledger)
        sender?.set(watching: true)
        other.set(watching: true)
        sender = nil
        XCTAssertEqual(ledger.watcherCount, 1)
        XCTAssertTrue(ledger.isHeld)
        other.set(watching: false)
        XCTAssertEqual(released, [41])
        var last: StreamingDisplayAwake? = StreamingDisplayAwake(ledger: ledger)
        last?.set(watching: true)
        last = nil
        XCTAssertEqual(released, [41, 42], "a torn-down sender never leaves the display held")
        XCTAssertFalse(ledger.isHeld)
    }

    func testSwitchedOutReleasesAndSwitchingBackHoldsAgain() {
        let ledger = ledger()
        let viewer = StreamingDisplayAwake(ledger: ledger)
        viewer.set(watching: true)
        ledger.setOnConsole(false)
        XCTAssertFalse(ledger.isHeld, "another user has the console")
        XCTAssertEqual(released, [41])
        XCTAssertTrue(viewer.isWatching, "the viewer is still counted")
        ledger.setOnConsole(true)
        XCTAssertTrue(ledger.isHeld)
        XCTAssertEqual(created, 2)
    }

    func testStartingSwitchedOutHoldsNothingUntilBack() {
        let ledger = ledger(onConsole: false)
        let viewer = StreamingDisplayAwake(ledger: ledger)
        viewer.set(watching: true)
        XCTAssertEqual(created, 0)
        ledger.setOnConsole(true)
        XCTAssertEqual(created, 1)
    }

    func testARefusedAssertionIsNotHeld() {
        let ledger = DisplayAwakeLedger(create: { _ in nil }, release: { _ in XCTFail("nothing to release") })
        let viewer = StreamingDisplayAwake(ledger: ledger)
        viewer.set(watching: true)
        XCTAssertFalse(ledger.isHeld)
        viewer.set(watching: false)
    }

    /// Not a mock: the real IOKit assertion appears in, and leaves, the system's list.
    func testTheRealAssertionIsCreatedAndReleased() {
        let ledger = DisplayAwakeLedger()
        let viewer = StreamingDisplayAwake(ledger: ledger)
        viewer.set(watching: true)
        XCTAssertTrue(ledger.isHeld)
        XCTAssertTrue(ownAssertionNames().contains(DisplayAwakeLedger.reason))
        viewer.set(watching: false)
        XCTAssertFalse(ownAssertionNames().contains(DisplayAwakeLedger.reason))
    }

    private func ownAssertionNames() -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let mine = byProcess[NSNumber(value: getpid())] ?? []
        return mine.compactMap { $0[kIOPMAssertionNameKey] as? String }
    }
}
