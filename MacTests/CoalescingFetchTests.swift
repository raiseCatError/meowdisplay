import os
import XCTest

/// Capture discovery under a backed-up macOS capture service (replayd): sessions starting at the
/// same time share one request, a caller's wait is bounded and cancellable, and a slow request
/// never leaves anyone waiting on a stale answer.
final class CoalescingFetchTests: XCTestCase {
    /// A stand-in for replayd: each request takes `delay` and answers with its own number.
    private final class SlowService: @unchecked Sendable {
        let delay: Duration
        let calls = OSAllocatedUnfairLock(initialState: 0)
        /// Requests out at once now, and the most ever.
        let out = OSAllocatedUnfairLock(initialState: (now: 0, peak: 0))
        var failNext = OSAllocatedUnfairLock(initialState: false)
        init(delay: Duration) { self.delay = delay }
        func fetch() async throws -> Int {
            let n = calls.withLock { $0 += 1; return $0 }
            out.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
            defer { out.withLock { $0.now -= 1 } }
            try await Task.sleep(for: delay)
            if failNext.withLock({ let f = $0; $0 = false; return f }) { throw URLError(.timedOut) }
            return n
        }
    }

    private func make(_ delay: Duration) -> (CoalescingFetch<Int>, SlowService) {
        let service = SlowService(delay: delay)
        return (CoalescingFetch<Int> { try await service.fetch() }, service)
    }

    func testSessionsStartingTogetherShareOneRequest() async throws {
        let (fetcher, service) = make(.milliseconds(300))
        let clock = ContinuousClock.now
        let answers = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 { group.addTask { try await fetcher.value(.cachedWithin(.seconds(1))).value } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(answers, [1, 1, 1, 1, 1])
        XCTAssertEqual(service.calls.withLock { $0 }, 1, "one request for every session")
        XCTAssertLessThan(ContinuousClock.now - clock, .milliseconds(900), "not five requests one after another")
    }

    func testARecentAnswerIsReusedUntilInvalidated() async throws {
        let (fetcher, service) = make(.milliseconds(20))
        _ = try await fetcher.value(.cachedWithin(.seconds(5)))
        let reused = try await fetcher.value(.cachedWithin(.seconds(5)))
        XCTAssertFalse(reused.waited)
        XCTAssertEqual(service.calls.withLock { $0 }, 1)
        fetcher.invalidate()   // a display was added
        let fresh = try await fetcher.value(.cachedWithin(.seconds(5)))
        XCTAssertEqual(fresh.value, 2, "an answer from before the change is never reused")
    }

    func testAnInvalidationDuringARequestWaitsForTheNextOne() async throws {
        let (fetcher, service) = make(.milliseconds(200))
        async let early = fetcher.value(.cachedWithin(.seconds(5)))
        try await Task.sleep(for: .milliseconds(50))
        fetcher.invalidate()   // the virtual display appeared while the request was out
        let late = try await fetcher.value(.cachedWithin(.seconds(5)))
        let first = try await early
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(late.value, 2, "the request that started before the display existed can't list it")
        XCTAssertEqual(service.calls.withLock { $0 }, 2)
    }

    func testStartedAfterNowGetsANewRequestSharedByLateCallers() async throws {
        let (fetcher, service) = make(.milliseconds(600))
        async let a = fetcher.value(.cachedWithin(.seconds(5)))
        // Wait for a's request to be out (a busy runner can start it late), then let more
        // than `sameMoment` pass, well before it answers.
        while service.calls.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: CoalescingFetch<Int>.sameMoment + .milliseconds(50))
        async let b = fetcher.value(.startedAfterNow)
        async let c = fetcher.value(.startedAfterNow)
        let (ra, rb, rc) = try await (a, b, c)
        XCTAssertEqual(ra.value, 1)
        XCTAssertEqual([rb.value, rc.value], [2, 2], "both late callers share the follow-up request")
        XCTAssertEqual(service.calls.withLock { $0 }, 2)
    }

    /// Regression (2026-10-30 22:39, AltTab flooding replayd): the request out had started just
    /// before the virtual display existed; holding the fresh one back until it answered put it
    /// behind 14 s of other apps' requests.
    func testAStaleRequestOutDoesNotHoldBackAFreshOne() async throws {
        let (fetcher, service) = make(.milliseconds(300))
        async let stale = fetcher.value(.cachedWithin(.seconds(5)))
        try await Task.sleep(for: .milliseconds(50))
        fetcher.invalidate()
        let clock = ContinuousClock.now
        let fresh = try await fetcher.value(.cachedWithin(.seconds(5)))
        XCTAssertEqual(fresh.value, 2)
        XCTAssertLessThan(ContinuousClock.now - clock, .milliseconds(450), "sent at once, not after the stale one")
        _ = try await stale
        XCTAssertEqual(service.calls.withLock { $0 }, 2)
    }

    /// Regression (2026-10-30 22:50): the display was created, a request went out, then macOS's
    /// reconfiguration notice invalidated answers; the start threw that request's answer away and
    /// waited 20 s for another instead of 5 s.
    func testAnAnswerStartedAfterTheCallersOwnChangeIsKeptThroughLaterInvalidations() async throws {
        let (fetcher, service) = make(.milliseconds(200))
        fetcher.invalidate()               // the display was just created
        let since = fetcher.epoch
        async let listed = fetcher.value(.startedSince(since))
        try await Task.sleep(for: .milliseconds(50))
        fetcher.invalidate()               // macOS's own notice for the same change
        let first = try await listed
        XCTAssertEqual(first.value, 1)
        XCTAssertEqual(service.calls.withLock { $0 }, 1)
        // A wait that timed out and asks again still takes that answer.
        let again = try await fetcher.value(.startedSince(since))
        XCTAssertEqual(again.value, 1)
        XCTAssertFalse(again.waited)
    }

    func testNoMoreThanTwoRequestsAreOut() async throws {
        let (fetcher, service) = make(.milliseconds(200))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<6 {
                group.addTask { _ = try await fetcher.value(.startedAfterNow) }
                try await Task.sleep(for: .milliseconds(10 * (i + 1)))
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(service.out.withLock { $0.peak }, 2)
        XCTAssertLessThan(service.calls.withLock { $0 }, 6, "late callers share follow-up requests")
    }

    func testAWaitIsBoundedAndTheRequestCarriesOnForOthers() async throws {
        let (fetcher, service) = make(.milliseconds(400))
        async let patient = fetcher.value(.cachedWithin(.seconds(5)))
        let clock = ContinuousClock.now
        do {
            _ = try await fetcher.value(.cachedWithin(.seconds(5)), timeout: .milliseconds(50))
            XCTFail("should time out")
        } catch let error as CoalescingFetch<Int>.TimedOut {
            XCTAssertEqual(error.after, .milliseconds(50))
        }
        XCTAssertLessThan(ContinuousClock.now - clock, .milliseconds(300))
        let answer = try await patient
        XCTAssertEqual(answer.value, 1)
        XCTAssertEqual(service.calls.withLock { $0 }, 1, "giving up never sends a second request")
    }

    func testCancellingAStartEndsItsWaitPromptly() async throws {
        let (fetcher, _) = make(.milliseconds(500))
        let start = Task { try await fetcher.value(.cachedWithin(.seconds(5))) }
        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock.now
        start.cancel()
        do {
            _ = try await start.value
            XCTFail("should be cancelled")
        } catch is CancellationError {}
        XCTAssertLessThan(ContinuousClock.now - clock, .milliseconds(200))
    }

    func testAFailureReachesItsWaitersAndIsNotCached() async throws {
        let (fetcher, service) = make(.milliseconds(20))
        service.failNext.withLock { $0 = true }
        do {
            _ = try await fetcher.value(.cachedWithin(.seconds(5)))
            XCTFail("should fail")
        } catch is URLError {}
        let retry = try await fetcher.value(.cachedWithin(.seconds(5)))
        XCTAssertEqual(retry.value, 2)
    }

    func testASlowRequestIsReported() async throws {
        let reported = OSAllocatedUnfairLock(initialState: [Duration]())
        let service = SlowService(delay: .milliseconds(120))
        let fetcher = CoalescingFetch<Int>(slowFetch: .milliseconds(100), onSlowFetch: { d in reported.withLock { $0.append(d) } }) {
            try await service.fetch()
        }
        _ = try await fetcher.value(.startedAfterNow)
        XCTAssertEqual(reported.withLock { $0.count }, 1)
    }
}
