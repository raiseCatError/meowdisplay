import XCTest

/// The recovery schedule on a fake clock: the same cases as Android's RemoteRecoveryPolicyTest.
final class RemoteRecoveryPolicyTests: XCTestCase {
    private var policy = RemoteRecoveryPolicy()
    private let context = RemoteRecoveryPolicy.DropContext(
        automaticallyRecoverable: true, wasRemote: true, autoReconnectEnabled: true, foreground: true,
        hasSavedAddress: true, stillPaired: true, nearby: false, otherSessionLive: false)

    override func setUp() { policy = RemoteRecoveryPolicy() }

    private func with(_ change: (inout RemoteRecoveryPolicy.DropContext) -> Void) -> RemoteRecoveryPolicy.DropContext {
        var c = context
        change(&c)
        return c
    }

    /// Walks the policy: every knock "takes" `knockMs` and ends with `result`. Returns when each started.
    private func simulate(until: Int64, result: RemoteKnockResult = .timedOut, knockMs: Int64 = 100) -> [Int64] {
        var starts: [Int64] = []
        var now: Int64 = 0
        while now <= until {
            switch policy.next(now: now) {
            case .idle, .dormant: return starts
            case .wait(let at):
                if at > now { now = at; continue }
                starts.append(now)
                policy.knockStarted(now: now)
                now += knockMs
                policy.knockFinished(now: now, result: result)
            }
        }
        return starts
    }

    func testOnlyARecoverableDropWithAutoReconnectOnStartsRecovery() {
        XCTAssertTrue(policy.shouldStart(context))
        XCTAssertFalse(policy.shouldStart(with { $0.automaticallyRecoverable = false }))
        XCTAssertTrue(policy.shouldStart(with { $0.wasRemote = false }), "a local session with a saved address falls back to Remote")
        XCTAssertTrue(policy.shouldStart(with { $0.wasRemote = false; $0.nearby = true }), "even while the Mac is still listed (it waits)")
        XCTAssertFalse(policy.shouldStart(with { $0.wasRemote = false; $0.hasSavedAddress = false }))
        XCTAssertFalse(policy.shouldStart(with { $0.autoReconnectEnabled = false }))
        XCTAssertFalse(policy.shouldStart(with { $0.foreground = false }), "foreground only")
        XCTAssertFalse(policy.shouldStart(with { $0.hasSavedAddress = false }))
        XCTAssertFalse(policy.shouldStart(with { $0.stillPaired = false }), "a forgotten Mac")
        XCTAssertFalse(policy.shouldStart(with { $0.nearby = true }), "visible locally: the local path takes over")
        XCTAssertFalse(policy.shouldStart(with { $0.otherSessionLive = true }))
    }

    func testBackoffIsBoundedAndStopsAfterAboutThreeMinutes() {
        policy.start(peerID: "A", now: 0)
        let starts = simulate(until: 600_000)
        XCTAssertEqual(starts.first, 2_000, "first knock after the first backoff")
        let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }
        XCTAssertTrue(gaps.allSatisfy { $0 >= 5_000 }, "never closer than the Mac's 5 s limit")
        XCTAssertEqual(Array(gaps.map { $0 - 100 }.prefix(5)), [5_000, 10_000, 20_000, 30_000, 30_000])
        XCTAssertTrue(starts.allSatisfy { $0 < 180_000 }, "nothing starts after three minutes")
        XCTAssertTrue((5...12).contains(starts.count), "and it is not endless")
        if case .dormant = policy.next(now: 200_000) {} else { XCTFail("dormant after the backoff") }
    }

    func testADeliveredKnockGivesTheMacTimeToDialBackBeforeAskingAgain() {
        policy.start(peerID: "A", now: 0)
        let starts = simulate(until: 100_000, result: .delivered)
        XCTAssertTrue(zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 >= 20_000 })
    }

    func testANetworkChangeBringsOneAttemptForwardAndABurstIsOne() {
        policy.start(peerID: "A", now: 0)
        _ = simulate(until: 400_000)
        if case .dormant = policy.next(now: 400_000) {} else { XCTFail("the backoff is over") }
        XCTAssertTrue(policy.networkChanged(now: 400_000))
        XCTAssertFalse(policy.networkChanged(now: 400_050), "a burst of callbacks is one attempt")
        guard case .wait(let at) = policy.next(now: 400_100) else { return XCTFail("an attempt is due") }
        XCTAssertLessThanOrEqual(at, 400_100 + 5_000)
        policy.knockStarted(now: at)
        policy.knockFinished(now: at + 100, result: .timedOut)
        if case .dormant = policy.next(now: at + 200) {} else { XCTFail("one attempt, not a schedule") }
    }

    func testANetworkChangeDuringTheBackoffPullsTheNextAttemptIn() {
        policy.start(peerID: "A", now: 0)
        XCTAssertEqual(policy.next(now: 0), .wait(atMs: 2_000))
        policy.knockStarted(now: 2_000)
        policy.knockFinished(now: 2_100, result: .timedOut)
        XCTAssertEqual(policy.next(now: 2_100), .wait(atMs: 7_100))
        XCTAssertTrue(policy.networkChanged(now: 3_000))
        XCTAssertEqual(policy.next(now: 3_000), .wait(atMs: 7_000), "pulled in, never closer than 5 s to the last knock")
        XCTAssertFalse(policy.networkChanged(now: 3_000))
    }

    func testNetworkChangesAreIgnoredOutsideTheWindowAndCapped() {
        policy.start(peerID: "A", now: 0)
        XCTAssertFalse(policy.networkChanged(now: 600_000))
        policy.start(peerID: "A", now: 0)
        _ = simulate(until: 300_000)
        var accepted = 0
        var now: Int64 = 300_000
        for _ in 0..<6 {
            if policy.networkChanged(now: now) {
                accepted += 1
                if case .wait(let at) = policy.next(now: now) { now = max(now, at) }
                policy.knockStarted(now: now)
                now += 100
                policy.knockFinished(now: now, result: .timedOut)
            }
            now += 6_000
        }
        XCTAssertEqual(accepted, 3, "at most three network attempts per drop")
    }

    func testASecurityFailureEndsTheRunForGood() {
        for failure: RemoteKnockResult in [.identityMismatch(otherPeerID: "B"), .identityMismatch(otherPeerID: nil), .notAccepted] {
            policy.start(peerID: "A", now: 0)
            policy.knockStarted(now: 2_000)
            policy.knockFinished(now: 2_100, result: failure)
            XCTAssertEqual(policy.next(now: 2_200), .idle, "\(failure)")
            XCTAssertFalse(policy.networkChanged(now: 2_300), "not even a network change retries it")
        }
    }

    func testOtherFailuresKeepGoingWithinTheBounds() {
        for result: RemoteKnockResult in [.dnsFailed, .refused, .unreachable, .failed, .timedOut] {
            policy.start(peerID: "A", now: 0)
            policy.knockStarted(now: 2_000)
            policy.knockFinished(now: 2_100, result: result)
            if case .wait = policy.next(now: 2_200) {} else { XCTFail("\(result)") }
        }
    }

    func testStoppingOrACancelledKnockEndsTheRun() {
        policy.start(peerID: "A", now: 0)
        policy.stop()
        XCTAssertEqual(policy.next(now: 5_000), .idle)
        XCTAssertNil(policy.run)
        policy.start(peerID: "A", now: 0)
        policy.knockStarted(now: 2_000)
        policy.knockFinished(now: 2_050, result: .cancelled)
        XCTAssertEqual(policy.next(now: 2_100), .idle)
    }

    func testAnAttemptSkippedWhileNearbyFollowsTheBackoffAndSendsNothing() {
        let run = policy.start(peerID: "A", now: 0, fromLocal: true)
        XCTAssertEqual(policy.next(now: 0), .wait(atMs: 2_000))
        policy.skippedWhileNearby(now: 2_000)
        XCTAssertNil(run.lastKnockAt, "no knock was sent")
        XCTAssertEqual(policy.next(now: 2_000), .wait(atMs: 7_000))
        policy.skippedWhileNearby(now: 7_000)
        XCTAssertEqual(policy.next(now: 7_000), .wait(atMs: 17_000))
        XCTAssertTrue(policy.networkChanged(now: 8_000))
        policy.skippedWhileNearby(now: 8_000)
        if case .wait = policy.next(now: 8_000) {} else { XCTFail("still scheduled") }
        XCTAssertEqual(policy.next(now: 600_000), .idle, "still bounded by the window")
    }
}
