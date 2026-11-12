import XCTest

/// The Mac proves a held window closed (PROTOCOL.md 6.10 `watch` / `gone`) only from the window
/// server's list of every window: missing from two reads at least a second apart, or its id now
/// owned by another process. Being left out of the window list is never proof.
final class WindowGoneTrackerTests: XCTestCase {
    private typealias Watch = WindowGoneTracker.Watch
    private let w10 = Watch(window: 10, generation: 5)
    private let w11 = Watch(window: 11, generation: 6)

    private func listed(_ entries: [UInt32: (Int32, UInt64)]) -> [UInt32: (pid: Int32, generation: UInt64)] {
        entries.mapValues { (pid: $0.0, generation: $0.1) }
    }

    /// Closed: gone after two reads without it, a second apart; never after one.
    func testMissingFromTwoReadsASecondApartIsGone() {
        var t = WindowGoneTracker()
        t.observe(watched: [w10, w11], listed: listed([10: (100, 5), 11: (100, 6)]), existing: [10: 100, 11: 100, 99: 1], now: 0)
        XCTAssertFalse(t.observe(watched: [w10, w11], listed: listed([11: (100, 6)]), existing: [11: 100, 99: 1], now: 1))
        XCTAssertTrue(t.gone.isEmpty, "one read without it proves nothing")
        XCTAssertFalse(t.observe(watched: [w10, w11], listed: listed([11: (100, 6)]), existing: [11: 100, 99: 1], now: 1.4))
        XCTAssertTrue(t.gone.isEmpty, "two reads, but less than a second apart")
        XCTAssertTrue(t.observe(watched: [w10, w11], listed: listed([11: (100, 6)]), existing: [11: 100, 99: 1], now: 2))
        XCTAssertEqual(t.gone, [w10])
    }

    /// One listing (or one window-server read) without it, then back: never gone.
    func testOneMissingReadIsForgotten() {
        var t = WindowGoneTracker()
        t.observe(watched: [w10], listed: [:], existing: [99: 1], now: 0)
        t.observe(watched: [w10], listed: listed([10: (100, 5)]), existing: [10: 100, 99: 1], now: 1)
        t.observe(watched: [w10], listed: [:], existing: [99: 1], now: 2)
        XCTAssertTrue(t.gone.isEmpty, "the absence starts over after it came back")
        t.observe(watched: [w10], listed: [:], existing: [99: 1], now: 3)
        XCTAssertEqual(t.gone, [w10])
    }

    /// Minimized (untitled ones aren't listed), hidden, on another Space, in Stage Manager's strip
    /// or behind Mission Control: still in the window server's list under its owner, so never gone,
    /// however long it stays unlisted, and even when it comes back under a new generation.
    func testUnlistedButExistingIsNeverGone() {
        var t = WindowGoneTracker()
        t.observe(watched: [w10], listed: listed([10: (100, 5)]), existing: [10: 100], now: 0)
        for second in 1...30 {
            t.observe(watched: [w10], listed: [:], existing: [10: 100], now: TimeInterval(second))
        }
        t.observe(watched: [w10], listed: listed([10: (100, 9)]), existing: [10: 100], now: 31)
        XCTAssertTrue(t.gone.isEmpty)
    }

    /// The id now belongs to another process: the window held here is gone at once.
    func testIDReusedByAnotherProcessIsGone() {
        var t = WindowGoneTracker()
        t.observe(watched: [w10], listed: listed([10: (100, 5)]), existing: [10: 100], now: 0)
        XCTAssertTrue(t.observe(watched: [w10], listed: listed([10: (200, 7)]), existing: [10: 200], now: 0.2))
        XCTAssertEqual(t.gone, [w10])
    }

    /// Never listed under the held generation (its owner unknown here): an id that exists is
    /// never taken for another process's.
    func testUnknownOwnerIsNeverGoneWhileTheIDExists() {
        var t = WindowGoneTracker()
        for second in 0...5 {
            t.observe(watched: [w10], listed: listed([10: (200, 7)]), existing: [10: 200], now: TimeInterval(second))
        }
        XCTAssertTrue(t.gone.isEmpty)
    }

    /// A read that gave nothing (no windows at all, or failed) concludes nothing.
    func testFailedReadsConcludeNothing() {
        var t = WindowGoneTracker()
        t.observe(watched: [w10], listed: listed([10: (100, 5)]), existing: [10: 100], now: 0)
        for second in 1...10 {
            t.observe(watched: [w10], listed: [:], existing: second.isMultiple(of: 2) ? nil : [:], now: TimeInterval(second))
        }
        XCTAssertTrue(t.gone.isEmpty)
    }

    /// Gone stays while the receiver holds it, and is forgotten once it doesn't.
    func testGoneStaysWhileWatchedOnly() {
        var t = WindowGoneTracker()
        t.observe(watched: [w10], listed: [:], existing: [99: 1], now: 0)
        t.observe(watched: [w10], listed: [:], existing: [99: 1], now: 1)
        XCTAssertEqual(t.gone, [w10])
        t.observe(watched: [w10], listed: listed([10: (100, 5)]), existing: [10: 100], now: 2)
        XCTAssertEqual(t.gone, [w10], "proved once: it stays gone")
        XCTAssertTrue(t.observe(watched: [w11], listed: [:], existing: [99: 1], now: 3))
        XCTAssertTrue(t.gone.isEmpty)
    }

    /// The request's `watch`: bounded, whole displays and malformed entries left out.
    func testWatchListIsBounded() {
        let many: [[String: Any]] = (1...300).map { ["window": $0, "gen": 1] }
        XCTAssertEqual(WindowWorkspaceEngine.parseWatch(many).count, WindowWorkspaceEngine.maximumWatched)
        let mixed: [[String: Any]] = [
            ["window": 10, "gen": 5], ["window": 0, "gen": 1], ["window": Int(WorkspaceSource.displayKey(1)), "gen": 1],
            ["window": "x", "gen": 1], ["gen": 2], ["window": -3, "gen": 1],
        ]
        XCTAssertEqual(WindowWorkspaceEngine.parseWatch(mixed), [Watch(window: 10, generation: 5)])
        XCTAssertTrue(WindowWorkspaceEngine.parseWatch(nil).isEmpty)
    }
}
