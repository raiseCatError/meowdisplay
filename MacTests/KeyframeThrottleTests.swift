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
