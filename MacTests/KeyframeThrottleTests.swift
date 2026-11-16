import XCTest

/// Covers `StreamReceiver.KeyframeThrottle` — the lock-backed throttle owner
/// introduced by Receiver Swift6-B2.4-E2a to let the `requestKeyframe`
/// `@Sendable` effect stop capturing `StreamReceiver`. Pure check-and-update
/// math, so every case injects an explicit `Date` rather than sleeping.
final class KeyframeThrottleTests: XCTestCase {

    func testFirstRequestIsAllowed() {
        let throttle = StreamReceiver.KeyframeThrottle()
        XCTAssertTrue(throttle.shouldSend(now: Date(), minimumInterval: 1.0))
    }

    func testRequestInsideIntervalIsRejected() {
        let throttle = StreamReceiver.KeyframeThrottle()
        let first = Date()
        XCTAssertTrue(throttle.shouldSend(now: first, minimumInterval: 1.0))
        XCTAssertFalse(throttle.shouldSend(now: first.addingTimeInterval(0.5), minimumInterval: 1.0))
    }

    func testRequestExactlyAtIntervalIsRejected() {
        // Matches the strict `>` in the original inline comparison — the
        // boundary itself must still be throttled, not just anything below it.
        let throttle = StreamReceiver.KeyframeThrottle()
        let first = Date()
        XCTAssertTrue(throttle.shouldSend(now: first, minimumInterval: 1.0))
        XCTAssertFalse(throttle.shouldSend(now: first.addingTimeInterval(1.0), minimumInterval: 1.0))
    }

    func testRequestAfterIntervalIsAllowed() {
        let throttle = StreamReceiver.KeyframeThrottle()
        let first = Date()
        XCTAssertTrue(throttle.shouldSend(now: first, minimumInterval: 1.0))
        XCTAssertTrue(throttle.shouldSend(now: first.addingTimeInterval(1.001), minimumInterval: 1.0))
    }

    /// `sendNowOrDelay` sends (and records) when the window is closed, and
    /// otherwise reports how long until a retry can pass `shouldSend`,
    /// without spending the window.
    func testSendNowOrDelayReportsRemainingWindowInsteadOfDropping() throws {
        let throttle = StreamReceiver.KeyframeThrottle()
        let first = Date()
        XCTAssertNil(throttle.sendNowOrDelay(now: first, minimumInterval: 1.0))
        let wait = try XCTUnwrap(throttle.sendNowOrDelay(now: first.addingTimeInterval(0.4), minimumInterval: 1.0))
        XCTAssertEqual(wait, 0.65, accuracy: 0.001)
        // The delayed attempt, made at that time, is allowed exactly once.
        let retryAt = first.addingTimeInterval(0.4 + wait)
        XCTAssertTrue(throttle.shouldSend(now: retryAt, minimumInterval: 1.0))
        XCTAssertFalse(throttle.shouldSend(now: retryAt, minimumInterval: 1.0))
    }

    /// A delayed request never lets two kf go out inside one interval.
    func testSendNowOrDelayDoesNotRefreshTheWindow() {
        let throttle = StreamReceiver.KeyframeThrottle()
        let first = Date()
        XCTAssertNil(throttle.sendNowOrDelay(now: first, minimumInterval: 1.0))
        XCTAssertNotNil(throttle.sendNowOrDelay(now: first.addingTimeInterval(0.9), minimumInterval: 1.0))
        XCTAssertTrue(throttle.shouldSend(now: first.addingTimeInterval(1.01), minimumInterval: 1.0))
    }

    /// Many threads race `shouldSend` around the same instant; the lock must
    /// make the check-and-update atomic so exactly one wins.
    func testConcurrentRequestsAllowExactlyOne() {
        let throttle = StreamReceiver.KeyframeThrottle()
        let now = Date()
        let allowedCount = LockedCount()
        let group = DispatchGroup()
        for _ in 0..<64 {
            group.enter()
            DispatchQueue.global().async {
                if throttle.shouldSend(now: now, minimumInterval: 1.0) {
                    allowedCount.increment()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(allowedCount.value, 1)
    }

    private final class LockedCount: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.lock(); _value += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    }
}
