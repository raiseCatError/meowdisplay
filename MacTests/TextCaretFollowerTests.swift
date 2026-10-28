import CoreGraphics
import XCTest

/// The Mac's caret reader without Accessibility: a fake provider stands in
/// for the target app, so normalization, throttling and the permission and
/// keyboard gates are covered hostlessly.
final class TextCaretFollowerTests: XCTestCase {
    // MARK: - Normalization

    func testNormalizesRelativeToTheStreamedDisplay() throws {
        let display = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let n = try XCTUnwrap(TextCaretNormalizer.normalized(CGRect(x: 500, y: 250, width: 2, height: 20), in: display))
        XCTAssertEqual(n.minX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(n.minY, 0.25, accuracy: 1e-9)
        XCTAssertEqual(n.width, 0.001, accuracy: 1e-9)
        XCTAssertEqual(n.height, 0.02, accuracy: 1e-9)
    }

    func testNormalizationUsesTheDisplaysOwnOrigin() throws {
        // A second display to the left of the main one has a negative origin.
        let left = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
        let n = try XCTUnwrap(TextCaretNormalizer.normalized(CGRect(x: -960, y: 640, width: 0, height: 20), in: left))
        XCTAssertEqual(n.minX, 0.5, accuracy: 1e-9)
        XCTAssertEqual(n.minY, 0.5, accuracy: 1e-9)
    }

    func testACaretOnAnotherDisplayIsNotSent() {
        let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertNil(TextCaretNormalizer.normalized(CGRect(x: 2500, y: 300, width: 0, height: 20), in: main))
        XCTAssertNil(TextCaretNormalizer.normalized(CGRect(x: -40, y: 300, width: 0, height: 20), in: main))
        XCTAssertNil(TextCaretNormalizer.normalized(CGRect(x: 100, y: 1200, width: 0, height: 20), in: main))
    }

    func testImplausibleRectanglesAreNotCarets() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertNil(TextCaretNormalizer.normalized(.zero, in: display), "an app's empty answer")
        XCTAssertNil(TextCaretNormalizer.normalized(CGRect(x: 10, y: 10, width: 300, height: 900), in: display), "a whole field")
        XCTAssertNil(TextCaretNormalizer.normalized(CGRect(x: CGFloat.nan, y: 10, width: 0, height: 20), in: display))
        XCTAssertNil(TextCaretNormalizer.normalized(.null, in: display))
        XCTAssertNil(TextCaretNormalizer.normalized(CGRect(x: 10, y: 10, width: 0, height: 20), in: .zero))
    }

    func testAWideRangeRectangleIsReducedToCaretWidth() throws {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let n = try XCTUnwrap(TextCaretNormalizer.normalized(CGRect(x: 100, y: 100, width: 60, height: 20), in: display))
        XCTAssertEqual(n.width, TextCaretNormalizer.maxCaretWidth / 1000, accuracy: 1e-9)
    }

    // MARK: - Resolving the caret from ranges

    func testZeroLengthRangeIsPreferred() {
        var asked: [[Int]] = []
        let rect = CaretRectStrategy.caretRect(location: 12, length: 0) { l, n in
            asked.append([l, n])
            return CGRect(x: 40, y: 50, width: 1, height: 18)
        }
        XCTAssertEqual(rect, CGRect(x: 40, y: 50, width: 1, height: 18))
        XCTAssertEqual(asked, [[12, 0]], "one Accessibility call when the app answers the first time")
    }

    func testFallsBackToTheFollowingThenThePrecedingCharacter() {
        // No zero-length support; the character after the caret answers.
        var rect = CaretRectStrategy.caretRect(location: 5, length: 0) { l, n in
            n == 1 && l == 5 ? CGRect(x: 100, y: 20, width: 9, height: 16) : nil
        }
        XCTAssertEqual(rect, CGRect(x: 100, y: 20, width: 0, height: 16), "its leading edge")
        // End of the text: nothing follows, the character before answers.
        rect = CaretRectStrategy.caretRect(location: 5, length: 0) { l, n in
            n == 1 && l == 4 ? CGRect(x: 90, y: 20, width: 9, height: 16) : nil
        }
        XCTAssertEqual(rect, CGRect(x: 99, y: 20, width: 0, height: 16), "its trailing edge")
    }

    func testASelectionsCaretIsItsEnd() {
        var first: [Int]?
        _ = CaretRectStrategy.caretRect(location: 3, length: 4) { l, n in
            if first == nil { first = [l, n] }
            return CGRect(x: 1, y: 1, width: 0, height: 10)
        }
        XCTAssertEqual(first, [7, 0])
    }

    func testNoAnswerMeansNoCaret() {
        XCTAssertNil(CaretRectStrategy.caretRect(location: 0, length: 0) { _, _ in nil })
        XCTAssertNil(CaretRectStrategy.caretRect(location: 4, length: 0) { _, _ in .zero })
        XCTAssertNil(CaretRectStrategy.caretRect(location: -1, length: 0) { _, _ in CGRect(x: 1, y: 1, width: 1, height: 1) })
    }

    // MARK: - Schedule

    func testScheduleNeverReadsMoreThanTenTimesASecond() {
        var schedule = TextCaretSchedule()
        var reads = 0
        var t: TimeInterval = 0
        // Typing hard for 3 seconds, ticking every 10 ms, a key every 20 ms.
        while t < 3 {
            if Int((t * 1000).rounded()) % 20 == 0 { schedule.noteInput(now: t) }
            if schedule.shouldRead(now: t) { reads += 1 }
            t += 0.01
        }
        XCTAssertLessThanOrEqual(reads, 31, "10 Hz over 3 seconds, plus the first immediate read")
        XCTAssertGreaterThanOrEqual(reads, 25, "it does keep up with typing")
    }

    func testScheduleReadsImmediatelyThenPollsSlowlyWhenIdle() {
        var schedule = TextCaretSchedule()
        XCTAssertTrue(schedule.shouldRead(now: 10))
        XCTAssertFalse(schedule.shouldRead(now: 10.05))
        XCTAssertFalse(schedule.shouldRead(now: 10.2))
        XCTAssertTrue(schedule.shouldRead(now: 10.3))
        XCTAssertFalse(schedule.shouldRead(now: 10.5))
        XCTAssertTrue(schedule.shouldRead(now: 10.7))
    }

    func testAKeyEventTriggersAReadSoonAndThenPollsFasterForASecond() {
        var schedule = TextCaretSchedule()
        _ = schedule.shouldRead(now: 0)
        XCTAssertTrue(schedule.shouldRead(now: 0.3), "the idle poll")
        schedule.noteInput(now: 0.35)
        XCTAssertFalse(schedule.shouldRead(now: 0.37), "inside the 10 Hz floor")
        XCTAssertTrue(schedule.shouldRead(now: 0.41), "shortly after the key, long before the next idle poll")
        XCTAssertFalse(schedule.shouldRead(now: 0.45))
        XCTAssertTrue(schedule.shouldRead(now: 0.52), "10 Hz while typing")
        XCTAssertTrue(schedule.shouldRead(now: 0.63))
        // A second after the last key it is back to the slow poll.
        XCTAssertTrue(schedule.shouldRead(now: 1.5))
        XCTAssertFalse(schedule.shouldRead(now: 1.65))
        XCTAssertTrue(schedule.shouldRead(now: 1.8))
    }

    func testAKeyRightAfterAReadWaitsForTheTenHertzFloor() {
        var schedule = TextCaretSchedule()
        _ = schedule.shouldRead(now: 1.0)
        schedule.noteInput(now: 1.01)
        XCTAssertFalse(schedule.shouldRead(now: 1.07))
        XCTAssertTrue(schedule.shouldRead(now: 1.1))
    }

    // MARK: - Follower

    private final class FakeProvider: FocusedCaretProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var _reading: FocusedCaretReading = .unavailable
        private var _reads = 0
        var reading: FocusedCaretReading {
            get { lock.withLock { _reading } }
            set { lock.withLock { _reading = newValue } }
        }
        var reads: Int { lock.withLock { _reads } }
        func readFocusedCaret() -> FocusedCaretReading {
            lock.withLock { _reads += 1; return _reading }
        }
    }

    private final class Harness: @unchecked Sendable {
        let provider = FakeProvider()
        let owner = DispatchQueue(label: "test.owner")
        let reader = DispatchQueue(label: "test.reader")
        var now: TimeInterval = 100
        var permitted = true
        var display = CGRect(x: 0, y: 0, width: 1000, height: 500)
        var sent: [CGRect?] = []
        var follower: TextCaretFollower!

        init() {
            follower = TextCaretFollower(
                provider: provider, readQueue: reader, ownerQueue: owner,
                clock: { [unowned self] in self.now }, tickInterval: nil,
                isPermitted: { [unowned self] in self.permitted },
                normalize: { [unowned self] in TextCaretNormalizer.normalized($0, in: self.display) },
                send: { [unowned self] in self.sent.append($0) })
        }

        func open(_ open: Bool = true) { owner.sync { follower.setKeyboardOpen(open) } }
        func input() { owner.sync { follower.noteInput() } }
        /// One scheduling step plus the read it starts, flushed.
        func tick(advance: TimeInterval = 0.5) {
            now += advance
            owner.sync { follower.tick() }
            reader.sync {}
            owner.sync {}
        }
    }

    func testNothingIsReadWhileTheKeyboardIsClosed() {
        let h = Harness()
        h.provider.reading = .caret(CGRect(x: 100, y: 100, width: 0, height: 20))
        h.tick()
        h.tick()
        XCTAssertEqual(h.provider.reads, 0)
        XCTAssertTrue(h.sent.isEmpty)
    }

    func testOpeningTheKeyboardReadsAndSendsTheNormalizedCaret() throws {
        let h = Harness()
        h.provider.reading = .caret(CGRect(x: 250, y: 100, width: 1, height: 20))
        h.open()
        h.tick()
        XCTAssertEqual(h.provider.reads, 1)
        let rect = try XCTUnwrap(try XCTUnwrap(h.sent.first))
        XCTAssertEqual(rect.minX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(rect.minY, 0.2, accuracy: 1e-9)
        XCTAssertEqual(rect.height, 0.04, accuracy: 1e-9)
    }

    func testAnUnchangedCaretIsReadAgainButNotResent() {
        let h = Harness()
        h.provider.reading = .caret(CGRect(x: 250, y: 100, width: 1, height: 20))
        h.open()
        h.tick()
        h.tick()
        h.tick()
        XCTAssertEqual(h.provider.reads, 3)
        XCTAssertEqual(h.sent.count, 1, "only on change")
    }

    func testAMovedCaretIsSentAgainAndASubPixelWobbleIsNot() {
        let h = Harness()
        h.provider.reading = .caret(CGRect(x: 250, y: 100, width: 1, height: 20))
        h.open()
        h.tick()
        h.provider.reading = .caret(CGRect(x: 250.2, y: 100, width: 1, height: 20))   // 0.0002 of the width
        h.tick()
        XCTAssertEqual(h.sent.count, 1)
        h.provider.reading = .caret(CGRect(x: 300, y: 100, width: 1, height: 20))
        h.tick()
        XCTAssertEqual(h.sent.count, 2)
    }

    func testACaretOffTheStreamedDisplayIsReportedAsNoCaretOnce() {
        let h = Harness()
        h.provider.reading = .caret(CGRect(x: 250, y: 100, width: 1, height: 20))
        h.open()
        h.tick()
        h.provider.reading = .caret(CGRect(x: 4000, y: 100, width: 1, height: 20))   // on another display
        h.tick()
        h.tick()
        XCTAssertEqual(h.sent.count, 2)
        XCTAssertEqual(h.sent.last.map { $0 == nil }, true)
    }

    func testAnAppWithoutACaretSendsNothingBecauseTheReceiverStartsWithNone() {
        let h = Harness()
        h.provider.reading = .unavailable
        h.open()
        h.tick()
        h.tick()
        XCTAssertEqual(h.provider.reads, 2)
        XCTAssertTrue(h.sent.isEmpty)
    }

    func testRevokedControlStopsReadingAndTellsTheReceiverOnce() {
        let h = Harness()
        h.provider.reading = .caret(CGRect(x: 250, y: 100, width: 1, height: 20))
        h.open()
        h.tick()
        h.permitted = false
        let readsBefore = h.provider.reads
        h.tick()
        h.tick()
        XCTAssertEqual(h.provider.reads, readsBefore, "no Accessibility reads without control")
        XCTAssertEqual(h.sent.count, 2)
        XCTAssertEqual(h.sent.last.map { $0 == nil }, true)
    }

    func testReadsAreThrottledByTheScheduleNotJustTheTimer() {
        let h = Harness()
        h.provider.reading = .caret(CGRect(x: 250, y: 100, width: 1, height: 20))
        h.open()
        h.tick(advance: 0)
        for _ in 0..<5 { h.tick(advance: 0.02) }    // 100 ms of ticks
        XCTAssertEqual(h.provider.reads, 1, "ticks inside the 10 Hz floor do not read")
    }

    func testAKeyEventPullsTheNextReadForward() {
        let h = Harness()
        h.provider.reading = .caret(CGRect(x: 250, y: 100, width: 1, height: 20))
        h.open()
        h.tick(advance: 0)
        let first = h.provider.reads
        h.provider.reading = .caret(CGRect(x: 262, y: 100, width: 1, height: 20))
        h.now += 0.01
        h.input()
        h.tick(advance: 0.12)       // past the 50 ms delay and the 10 Hz floor, well before the 300 ms idle poll
        XCTAssertEqual(h.provider.reads, first + 1)
        XCTAssertEqual(h.sent.count, 2)
    }

    func testClosingTheKeyboardStopsReadingAndForgetsTheLastCaret() {
        let h = Harness()
        h.provider.reading = .caret(CGRect(x: 250, y: 100, width: 1, height: 20))
        h.open()
        h.tick()
        h.open(false)
        h.tick()
        XCTAssertEqual(h.provider.reads, 1)
        // Reopened, the same caret is sent again: the receiver cleared it on close.
        h.open()
        h.tick()
        XCTAssertEqual(h.sent.count, 2)
    }

    func testAReadFinishingAfterStopIsDropped() {
        let h = Harness()
        h.provider.reading = .caret(CGRect(x: 250, y: 100, width: 1, height: 20))
        h.open()
        h.now += 0.5
        h.owner.sync { h.follower.tick() }       // read queued
        h.owner.sync { h.follower.stop() }       // connection ended before it returned
        h.reader.sync {}
        h.owner.sync {}
        XCTAssertTrue(h.sent.isEmpty)
    }
}
