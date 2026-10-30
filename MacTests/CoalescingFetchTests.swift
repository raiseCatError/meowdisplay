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
        var failNext = OSAllocatedUnfairLock(initialState: false)
        init(delay: Duration) { self.delay = delay }
        func fetch() async throws -> Int {
            let n = calls.withLock { $0 += 1; return $0 }
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

    func testStartedAfterNowGetsANewRequestButStillOnlyOneAtATime() async throws {
        let (fetcher, service) = make(.milliseconds(150))
        async let a = fetcher.value(.cachedWithin(.seconds(5)))
        try await Task.sleep(for: .milliseconds(30))
        async let b = fetcher.value(.startedAfterNow)
        async let c = fetcher.value(.startedAfterNow)
        let (ra, rb, rc) = try await (a, b, c)
        XCTAssertEqual(ra.value, 1)
        XCTAssertEqual([rb.value, rc.value], [2, 2], "both late callers share the follow-up request")
        XCTAssertEqual(service.calls.withLock { $0 }, 2)
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
