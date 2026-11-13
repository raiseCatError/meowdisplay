import XCTest

/// Pure-logic tests for the wake/lid/topology-churn debounce used by
/// `MacSender.offerExtendOrFailMirror` before cancelling a pending
/// Mirror-unavailable offer and resuming Mirror.
final class DisplayStabilityTrackerTests: XCTestCase {

    /// A single transient "usable" sample (exactly the wake-transition
    /// false-positive blip reported on real hardware) must NOT be enough to
    /// declare the display stably back.
    func testTransientSingleUsableSampleDoesNotDeclareStable() {
        var tracker = DisplayStabilityTracker()
        XCTAssertFalse(tracker.recordSample(usable: true),
            "one usable sample must not cancel a pending offer by itself")
    }

    /// Consecutive usable samples reaching the required threshold (~1s at
    /// the existing poll cadence) DO declare the display stable.
    func testConsecutiveUsableSamplesDeclareStable() {
        var tracker = DisplayStabilityTracker()
        for i in 0..<(DisplayStabilityTracker.requiredConsecutiveSamples - 1) {
            XCTAssertFalse(tracker.recordSample(usable: true), "sample \(i) alone must not be enough")
        }
        XCTAssertTrue(tracker.recordSample(usable: true),
            "reaching \(DisplayStabilityTracker.requiredConsecutiveSamples) consecutive usable samples must declare stable")
    }

    /// Any unusable sample resets the streak immediately — no partial
    /// credit survives a blip going the other way either.
    func testUnusableSampleResetsTheStreakImmediately() {
        var tracker = DisplayStabilityTracker()
        _ = tracker.recordSample(usable: true)
        XCTAssertFalse(tracker.recordSample(usable: false))
        XCTAssertEqual(tracker.consecutiveUsableSamples, 0)
        // Must start counting fully over — one more usable sample alone is
        // still not enough.
        XCTAssertFalse(tracker.recordSample(usable: true))
    }

    /// A blip-then-recovery sequence — exactly wake/lid churn — must not
    /// short-circuit into "stable" by accumulating samples across the gap.
    func testBlipThenRecoveryRequiresAFreshFullStreak() {
        var tracker = DisplayStabilityTracker()
        XCTAssertFalse(tracker.recordSample(usable: true))   // transient positive
        XCTAssertFalse(tracker.recordSample(usable: false))  // settles back to unusable
        for i in 0..<(DisplayStabilityTracker.requiredConsecutiveSamples - 1) {
            XCTAssertFalse(tracker.recordSample(usable: true), "post-blip sample \(i) alone must not be enough")
        }
        XCTAssertTrue(tracker.recordSample(usable: true))
    }

    // MARK: - DisplayReadinessWait (#255: Window mode reached while displays sleep)

    /// Counts what a wait did, with a display that is listed from the
    /// `readyAtProbe`-th probe on (nil: never).
    private final class Recorder {
        var probes = 0, wakes = 0, pauses = 0
        var wanted = true
        var endSessionAtPause: Int?
        let readyAtProbe: Int?
        init(readyAtProbe: Int?) { self.readyAtProbe = readyAtProbe }

        func run(polls: Int) async throws -> String? {
            try await DisplayReadinessWait.firstAvailable(
                polls: polls,
                wake: { self.wakes += 1 },
                probe: {
                    self.probes += 1
                    guard let ready = self.readyAtProbe, self.probes >= ready else { return nil }
                    return "display"
                },
                pause: {
                    self.pauses += 1
                    if self.pauses == self.endSessionAtPause { self.wanted = false }
                },
                stillWanted: { self.wanted })
        }
    }

    /// An awake Mac pays nothing: no wake call, no wait.
    func testAListedDisplayIsUsedAtOnceWithoutWakingOrWaiting() async throws {
        let recorder = Recorder(readyAtProbe: 1)
        let value = try await recorder.run(polls: 16)
        XCTAssertEqual(value, "display")
        XCTAssertEqual(recorder.wakes, 0)
        XCTAssertEqual(recorder.pauses, 0)
    }

    /// The 9000042 failure: no display listed at admission (displays asleep).
    /// The start must wake them once and use the display when it appears,
    /// instead of failing on the first empty listing.
    func testASleepingDisplayIsWokenOnceAndAwaited() async throws {
        let recorder = Recorder(readyAtProbe: 4)
        let value = try await recorder.run(polls: 16)
        XCTAssertEqual(value, "display")
        XCTAssertEqual(recorder.wakes, 1, "one wake request, never a loop of them")
        XCTAssertEqual(recorder.pauses, 3)
    }

    /// A Mac with truly no display still fails, after a bounded wait.
    func testTheWaitIsBoundedWhenNoDisplayAppears() async throws {
        let recorder = Recorder(readyAtProbe: nil)
        let value = try await recorder.run(polls: 16)
        XCTAssertNil(value)
        XCTAssertEqual(recorder.wakes, 1)
        XCTAssertEqual(recorder.pauses, 16)
        XCTAssertEqual(recorder.probes, 17)
    }

    /// A session that ended while waiting gets no capture started for it.
    func testTheWaitStopsWhenTheSessionEnds() async {
        let recorder = Recorder(readyAtProbe: 5)
        recorder.endSessionAtPause = 2
        do {
            _ = try await recorder.run(polls: 16)
            XCTFail("a wait for an ended session must be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recorder.probes, 2, "no probe after the session ended")
    }

    func testASessionAlreadyEndedNeitherProbesNorWakes() async {
        let recorder = Recorder(readyAtProbe: 1)
        recorder.wanted = false
        do {
            _ = try await recorder.run(polls: 16)
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(recorder.probes, 0)
        XCTAssertEqual(recorder.wakes, 0)
    }

    func testPollCountCoversTheGraceAndIsNeverZero() {
        XCTAssertEqual(DisplayReadinessWait.polls(grace: 8, interval: 0.5), 16)
        XCTAssertEqual(DisplayReadinessWait.polls(grace: 0.1, interval: 0.5), 1)
        XCTAssertEqual(DisplayReadinessWait.polls(grace: 8, interval: 0), 1)
    }

    /// QA 9000043 on hardware: the wake a waiting Window-mode start asked for
    /// also rebuilt the carrier stream, the two starts collided and the
    /// session ended. Only one of them may start it.
    func testAWakeDoesNotRebuildTheCarrierWhileAStartWaitsForIt() {
        XCTAssertFalse(DisplayReadinessWait.wakeMayRebuildCarrier(startAwaitingDisplay: true))
        XCTAssertTrue(DisplayReadinessWait.wakeMayRebuildCarrier(startAwaitingDisplay: false))
    }

    // MARK: - The start's hold on the carrier (PR #260 review: stuck flag)

    /// Records the order of a hold's begin, body and end.
    private final class HoldLog {
        var events: [String] = []
        var held = false
        func begin() async throws { events.append("begin"); held = true }
        func end() { events.append("end"); held = false }
    }

    func testTheHoldIsTakenBeforeTheBodyAndReleasedAfterIt() async throws {
        let log = HoldLog()
        let value = try await DisplayReadinessWait.whileAwaitingDisplay(
            begin: { try await log.begin() }, end: { log.end() },
            body: { log.events.append("body"); XCTAssertTrue(log.held); return 7 })
        XCTAssertEqual(value, 7)
        XCTAssertEqual(log.events, ["begin", "body", "end"])
        XCTAssertFalse(log.held)
    }

    /// The defect: a throw from the readiness wait (session generation no
    /// longer live, sender stopped) left the hold set for the life of the
    /// sender, so every later wake rebuild of the carrier was skipped.
    func testTheHoldIsReleasedWhenTheReadinessWaitThrows() async {
        let log = HoldLog()
        do {
            try await DisplayReadinessWait.whileAwaitingDisplay(
                begin: { try await log.begin() }, end: { log.end() },
                body: {
                    _ = try await DisplayReadinessWait.firstAvailable(
                        polls: 4, wake: {}, probe: { () async -> String? in nil },
                        pause: {}, stillWanted: { false })
                })
            XCTFail("a wait for a superseded session must throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(log.held, "a stuck hold blocks every later wake rebuild")
        XCTAssertEqual(log.events, ["begin", "end"])
    }

    func testTheHoldIsReleasedWhenTheBodyFailsForAnyOtherReason() async {
        struct Failure: Error {}
        let log = HoldLog()
        do {
            try await DisplayReadinessWait.whileAwaitingDisplay(
                begin: { try await log.begin() }, end: { log.end() }, body: { throw Failure() })
            XCTFail("expected the body's error")
        } catch {
            XCTAssertTrue(error is Failure)
        }
        XCTAssertFalse(log.held)
    }

    func testTheHoldIsReleasedWhenTakingItThrows() async {
        let log = HoldLog()
        do {
            try await DisplayReadinessWait.whileAwaitingDisplay(
                begin: { throw CancellationError() }, end: { log.end() }, body: { XCTFail("body must not run") })
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(log.held)
        XCTAssertEqual(log.events, ["end"])
    }

    // MARK: - A readiness wait cancelled mid-start

    /// A stopped sender has nothing left to start.
    func testAStoppedSenderEndsTheStartQuietly() {
        XCTAssertEqual(DisplayReadinessWait.afterCancelledWait(stopped: true, follows: 0), .endQuietly)
        XCTAssertEqual(DisplayReadinessWait.afterCancelledWait(stopped: true, follows: 99), .endQuietly)
    }

    /// The defect: a superseded generation was treated as a user stop, which
    /// left a running Window sender with no workspace engine. It is followed
    /// to the next admitted connection instead.
    func testASupersededGenerationIsFollowedNotTreatedAsAUserStop() {
        for follows in 0..<DisplayReadinessWait.maxFollows {
            XCTAssertEqual(DisplayReadinessWait.afterCancelledWait(stopped: false, follows: follows), .follow)
        }
    }

    /// A session that keeps changing fails the start (which stops the sender)
    /// rather than waiting forever or running without an engine.
    func testASessionThatKeepsChangingFailsTheStart() {
        XCTAssertEqual(
            DisplayReadinessWait.afterCancelledWait(stopped: false, follows: DisplayReadinessWait.maxFollows), .fail)
    }

    // MARK: - StartWakePolicy (#255, #260: only an explicitly requested session wakes the Mac)

    private func mayWake(_ intent: SessionInvitationIntent?, recordedFor recorded: UInt64 = 7,
                         admitted: Bool = true, generation: UInt64 = 7) -> Bool {
        StartWakePolicy.mayWake(
            admittedGeneration: generation, sessionIsAdmitted: admitted,
            recorded: intent.map { AdmittedSessionIntent(generation: recorded, intent: $0) })
    }

    func testAManualAdmittedSessionMayWakeTheMac() {
        XCTAssertTrue(mayWake(.manual))
    }

    func testAnAutomaticAdmittedSessionNeverWakesTheMac() {
        XCTAssertFalse(mayWake(.automatic))
    }

    func testMissingStateMeansNoWake() {
        XCTAssertFalse(mayWake(nil), "no recorded intent is never a yes")
    }

    func testAnUnauthenticatedOrUnadmittedConnectionNeverWakesTheMac() {
        XCTAssertFalse(mayWake(.manual, admitted: false),
                       "a manual intent on a connection that is not admitted authorizes nothing")
    }

    /// A manual intent from an earlier connection must not authorize a wake
    /// for a later, automatic one (an in-place redial, a route migration).
    func testAnEarlierConnectionsManualIntentDoesNotAuthorizeALaterGeneration() {
        XCTAssertFalse(mayWake(.manual, recordedFor: 7, generation: 8))
        XCTAssertFalse(mayWake(.manual, recordedFor: 8, generation: 7))
    }

    /// The session's later admission is recorded as automatic and replaces the
    /// earlier manual record, so the first generation's manual start cannot be
    /// replayed for the later one.
    func testALaterAutomaticAdmissionReplacesTheManualRecord() {
        var recorded = AdmittedSessionIntent(generation: 1, intent: .manual)
        XCTAssertTrue(StartWakePolicy.mayWake(admittedGeneration: 1, sessionIsAdmitted: true, recorded: recorded))
        recorded = AdmittedSessionIntent(generation: 2, intent: .automatic)
        XCTAssertFalse(StartWakePolicy.mayWake(admittedGeneration: 2, sessionIsAdmitted: true, recorded: recorded))
        XCTAssertFalse(StartWakePolicy.mayWake(admittedGeneration: 1, sessionIsAdmitted: true, recorded: recorded))
    }

    func testASessionThatMayNotWakeKeepsWaitingOnlyWhileTheDisplaysSleep() {
        XCTAssertTrue(StartWakePolicy.keepsWaitingAfterGrace(mayWake: false, displaysAsleep: true),
                      "an asleep Mac must not end the session after the grace")
        XCTAssertFalse(StartWakePolicy.keepsWaitingAfterGrace(mayWake: false, displaysAsleep: false),
                       "an awake Mac with no display fails as before")
        XCTAssertFalse(StartWakePolicy.keepsWaitingAfterGrace(mayWake: true, displaysAsleep: true),
                       "a session that woke the Mac keeps today's bounded wait")
    }

    /// The wiring the readiness waits use: the wake call is made only when the
    /// policy allows it, and the display is still awaited either way.
    func testAnAutomaticStartWaitsForTheDisplayWithoutWaking() async throws {
        let recorder = Recorder(readyAtProbe: 4)
        let allowed = mayWake(.automatic)
        let value = try await DisplayReadinessWait.firstAvailable(
            polls: 16,
            wake: { if allowed { recorder.wakes += 1 } },
            probe: {
                recorder.probes += 1
                return recorder.probes >= 4 ? "display" : nil
            },
            pause: { recorder.pauses += 1 },
            stillWanted: { true })
        XCTAssertEqual(value, "display", "the display is used when it wakes by itself")
        XCTAssertEqual(recorder.wakes, 0, "an automatic start never calls InteractiveWakePromotion")
    }

    func testAManualStartStillWakesTheMacOnce() async throws {
        let recorder = Recorder(readyAtProbe: nil)
        let allowed = mayWake(.manual)
        let value: String? = try await DisplayReadinessWait.firstAvailable(
            polls: 3, wake: { if allowed { recorder.wakes += 1 } },
            probe: { nil }, pause: {}, stillWanted: { true })
        XCTAssertNil(value)
        XCTAssertEqual(recorder.wakes, 1)
    }

    /// Final #260 review, finding 3: a manual first admission must not make later re-admissions
    /// manual, even when the invitation is never re-sent (an older receiver).
    func testOnlyTheFirstAdmissionCarriesTheInvitationsManualIntent() {
        XCTAssertEqual(StartWakePolicy.recordedIntent(invitation: .manual, first: true), .manual)
        XCTAssertEqual(StartWakePolicy.recordedIntent(invitation: .manual, first: false), .automatic)
        XCTAssertEqual(StartWakePolicy.recordedIntent(invitation: .automatic, first: true), .automatic)
        let later = AdmittedSessionIntent(generation: 7, intent: StartWakePolicy.recordedIntent(invitation: .manual, first: false))
        XCTAssertFalse(StartWakePolicy.mayWake(admittedGeneration: 7, sessionIsAdmitted: true, recorded: later))
    }
}
