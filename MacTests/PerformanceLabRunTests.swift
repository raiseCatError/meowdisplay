import XCTest

/// Trial collection, the run controller and the run bundle (#123), plus the
/// SYNTHETIC self-test against its golden bundle.
@MainActor
final class PerformanceLabRunTests: XCTestCase {

    private func recorder(at ms: Double = 0) -> StreamDiagnosticsRecorder {
        StreamDiagnosticsRecorder(side: .sender, windowSeconds: 5, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
                                  resourceSampler: nil, nowMs: ms)
    }

    private func scenario(windows: Int = 3, restarts: Bool = false) -> PerformanceLabScenario {
        var s = PerformanceLabScenarioCatalog.synthetic
        s.trialWindows = windows
        s.expectsRestarts = restarts
        return s
    }

    // MARK: Recorder hook

    func testCompletedWindowsAreNumberedContiguousAndCarryRawHistograms() throws {
        let r = recorder()
        XCTAssertNil(r.completedWindowForLab(at: 1000))
        r.recordDuration(.encode, ms: 7, at: 1000)
        let first = try XCTUnwrap(r.completedWindowForLab(at: 5000))
        XCTAssertEqual(first.sequence, 1)
        XCTAssertEqual(first.startMs, 0)
        XCTAssertEqual(first.durationMs, 5000)
        XCTAssertEqual(first.histograms[DiagnosticsStage.encode.rawValue].count, 1)
        XCTAssertEqual(first.snapshot.stage(.encode)?.count, 1)
        XCTAssertEqual(r.completedWindowForLab(at: 6000)?.sequence, 1, "reading does not rotate early")
        let second = try XCTUnwrap(r.completedWindowForLab(at: 10_100))
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(second.startMs, first.startMs + first.durationMs)
        XCTAssertEqual(r.snapshot(at: 10_200), second.snapshot, "snapshot(at:) unchanged by the lab accessor")
    }

    // MARK: Collector

    func testWarmUpWindowsNeverEnterATrial() throws {
        let r = recorder()
        var c = PerformanceLabTrialCollector(scenario: scenario(), trialIndex: 1, synthetic: true, armedAtMs: 7000)
        var t = 0.0
        while !c.isDone, t < 60_000 {
            t += 100
            r.recordSendCompletion(durationMs: t < 7000 ? 900 : 2, bytes: 1000, error: false, at: t)
            c.ingest(r.completedWindowForLab(at: t), at: t)
        }
        XCTAssertTrue(c.isDone)
        let rec = c.record(fixture: nil)
        XCTAssertEqual(rec.windows.map(\.sequence), [3, 4, 5], "window 2 started at 5 s, before the 7 s arm")
        XCTAssertEqual(rec.windows.first?.offsetSeconds, 0)
        let send = try XCTUnwrap(rec.stages.first { $0.id == "sender.send_ms" })
        XCTAssertEqual(send.max, 2, "no warm-up sample (900 ms) in the trial")
        XCTAssertEqual(rec.measuredSeconds, 15, accuracy: 0.2)
        XCTAssertEqual(rec.counters["sender.send.completed"], Int64(send.count))
    }

    func testMergedPercentilesEqualOneHistogramOfAllValues() {
        var a = DiagnosticsHistogram(), b = DiagnosticsHistogram(), all = DiagnosticsHistogram()
        for i in 0..<500 {
            let v = Double(i % 37) * 0.7
            if i % 3 == 0 { a.record(v) } else { b.record(v) }
            all.record(v)
        }
        let merged = PerformanceLabHistogramRecord(id: "x", merging: [a, b])
        XCTAssertEqual(merged.count, all.count)
        XCTAssertEqual(merged.p50, all.percentile(0.5))
        XCTAssertEqual(merged.p95, all.percentile(0.95))
        XCTAssertEqual(merged.p99, all.percentile(0.99))
        XCTAssertEqual(merged.max, all.max)
        XCTAssertEqual(merged.min, all.min)
        XCTAssertEqual(merged.sum, all.sum, accuracy: 1e-9)
    }

    func testGapsRestartsAndMissingReceiverAreFlagged() {
        let r = recorder()
        var c = PerformanceLabTrialCollector(scenario: scenario(windows: 3), trialIndex: 2, synthetic: true, armedAtMs: 0)
        var t = 0.0
        r.noteGeneration(1, at: 0)
        while t < 6000 { t += 100; r.markInterval(.submitInterval, at: t); c.ingest(r.completedWindowForLab(at: t), at: t) }
        // Changed with the B5 fix (a silence no longer makes the recorder
        // drop a window): no read for 11 s while it keeps recording, so a
        // whole window completes between two reads.
        while t < 17_000 { t += 100; r.markInterval(.submitInterval, at: t) }
        c.ingest(r.completedWindowForLab(at: t), at: t)
        r.noteGeneration(2, at: t)
        let rec = c.record(fixture: nil)
        XCTAssertEqual(rec.status, .incomplete)
        XCTAssertTrue(rec.issues.contains(.windowGap))
        XCTAssertTrue(rec.issues.contains(.missingWindows))
        XCTAssertTrue(rec.issues.contains(.noReceiverSummary))
    }

    /// An older receiver (no window numbers): kept by arrival time, at least
    /// two windows into the trial (B2), equal repeats merged, and the trial
    /// says its receiver sums are possibly double counted (B1).
    func testLegacyReceiverSummariesAreKeptByArrivalAndFlagged() {
        let r = recorder()
        var c = PerformanceLabTrialCollector(scenario: scenario(windows: 4), trialIndex: 1, synthetic: true, armedAtMs: 0)
        var t = 0.0
        var arrival = 50.0
        var s = StreamDiagnosticsPeerSummary(side: .receiver)
        s.arrivalFPS = arrival
        r.updatePeer(s, at: 0)   // before the trial: never kept (the old isEmpty override is gone)
        while !c.isDone, t < 40_000 {
            t += 500
            r.markInterval(.submitInterval, at: t)
            if t.truncatingRemainder(dividingBy: 2500) == 0 {
                arrival += 1
                s.arrivalFPS = arrival
                r.updatePeer(s, at: t)
            }
            c.ingest(r.completedWindowForLab(at: t), at: t)
        }
        let rec = c.record(fixture: nil)
        XCTAssertFalse(rec.receiverSummaries.isEmpty)
        XCTAssertTrue(rec.receiverSummaries.allSatisfy { $0.offsetSeconds >= 10 }, "arrived two windows after the trial began")
        XCTAssertFalse(rec.receiverSummaries.contains { $0.summary.arrivalFPS == 50 })
        XCTAssertEqual(Set(rec.receiverSummaries.map { $0.summary.arrivalFPS }).count, rec.receiverSummaries.count, "no repeats")
        XCTAssertFalse(rec.issues.contains(.noReceiverSummary))
        XCTAssertEqual(rec.receiverCounting, .possiblyDoubleCounted)
        XCTAssertEqual(rec.receiverAlignment, .partial)
        XCTAssertNil(rec.receiverWindowsMissed)
    }

    /// Replaces the single-window version, which could never see a gap
    /// (B3): a capture restart in the middle of a multi-window trial.
    func testExpectedRestartsDoNotMakeATrialIncomplete() throws {
        for restarts in [false, true] {
            scriptedReceivers = [:]
            let r = recorder()
            r.noteGeneration(1, at: 0)
            var c = PerformanceLabTrialCollector(scenario: scenario(windows: 3, restarts: restarts), trialIndex: 1,
                                                 synthetic: true, armedAtMs: 0)
            var t = 0.0
            while !c.isDone, t < 60_000 {
                t += 100
                if t == 7_000 { r.noteGeneration(2, at: t) }   // mid-window: the recorder restarts its window
                if t < 6_200 || t >= 7_000 {
                    r.recordSubmit(origin: .live, sourceKey: Int64(t), sourceAgeMs: nil, pendingEncodes: 1, at: t)
                }
                feedAlignedReceiver(into: r, at: t)
                c.ingest(r.completedWindowForLab(at: t), at: t)
            }
            while !c.isFinished(at: t), t < 80_000 {
                t += 100
                feedAlignedReceiver(into: r, at: t)
                c.ingest(r.completedWindowForLab(at: t), at: t)
            }
            let rec = c.record(fixture: nil)
            XCTAssertEqual(rec.windows.count, 3)
            XCTAssertEqual(rec.issues.contains(.unexpectedRestart), !restarts)
            XCTAssertEqual(rec.issues.contains(.windowGap), !restarts, "an expected restart is recorded, not a gap")
            if restarts {
                XCTAssertEqual(rec.status, .complete)
                XCTAssertEqual(rec.expectedRestarts, 1)
                XCTAssertEqual(try XCTUnwrap(rec.restartUnmeasuredSeconds), 2, accuracy: 0.05, "window 2 ran 5–7 s, then restarted")
                XCTAssertEqual(rec.stages.first { $0.id == "sender.restart.frame_gap_ms" }?.max ?? 0, 900, accuracy: 1e-6,
                               "last frame at 6.1 s, first after the restart at 7 s")
            } else {
                XCTAssertEqual(rec.status, .incomplete)
                XCTAssertNil(rec.expectedRestarts)
            }
        }
    }

    // MARK: Receiver windows (B1, B2)

    /// A scripted receiver for collector tests: 5 s windows, one summary
    /// every 2 s for the last completed window, start marker = the sender
    /// window number the last ping (every 2 s) carried.
    private final class ScriptedReceiver {
        let recorder: StreamDiagnosticsRecorder
        let offsetMs: Double
        init(offsetMs: Double) {
            self.offsetMs = offsetMs
            recorder = StreamDiagnosticsRecorder(side: .receiver, windowSeconds: 5, diagnosticsSwitch: StreamDiagnosticsSwitch(enabled: true),
                                                 resourceSampler: nil, nowMs: offsetMs)
        }
    }

    private var scriptedReceivers: [ObjectIdentifier: ScriptedReceiver] = [:]

    /// One step of a real receiver recorder on its own clock (offset from
    /// the Mac's by a large amount: no clock is compared across devices),
    /// exchanging pings and stats with the sender recorder `mac`.
    private func feedAlignedReceiver(into mac: StreamDiagnosticsRecorder, at t: Double, stallAt: Double? = nil,
                                     statsEveryMs: Double = 2_000) {
        let receiver = scriptedReceivers[ObjectIdentifier(mac)] ?? ScriptedReceiver(offsetMs: 987_654_321)
        scriptedReceivers[ObjectIdentifier(mac)] = receiver
        let rt = t + receiver.offsetMs
        if stallAt.map({ t >= $0 && t < $0 + 400 }) != true {
            receiver.recorder.recordArrival(bytes: 1, wireSubmitToSendMs: nil, mappedSubmitToReceiveMs: nil, at: rt)
        }
        if t.truncatingRemainder(dividingBy: 2_000) == 0 {
            // Mac ping → receiver, and the receiver's own ping/pong RTT
            // (its jitter is a session value that changes every time).
            receiver.recorder.updatePeer(StreamDiagnosticsPeerSummary.from(mac.snapshot(at: t)), at: rt)
            receiver.recorder.recordRTT(4 + (t / 2_000).truncatingRemainder(dividingBy: 3), at: rt)
        }
        if (t + 1_000).truncatingRemainder(dividingBy: statsEveryMs) == 0 {
            // Receiver stats → Mac.
            mac.updatePeer(StreamDiagnosticsPeerSummary.from(receiver.recorder.snapshot(at: rt)), at: t)
        }
    }

    func testReceiverWindowsAreCountedOnceAtTheTwoSecondCadenceAndOnlyFromInsideTheTrial() throws {
        let r = recorder()
        var c = PerformanceLabTrialCollector(scenario: scenario(windows: 4), trialIndex: 1, synthetic: true, armedAtMs: 7_000)
        var t = 0.0
        var seenSummaries: [StreamDiagnosticsPeerSummary] = []
        var arrivals: Set<Double> = []
        while !c.isFinished(at: t), t < 80_000 {
            t += 100
            r.markInterval(.submitInterval, at: t)
            feedAlignedReceiver(into: r, at: t, stallAt: 16_000)
            let w = r.completedWindowForLab(at: t)
            if let p = w?.snapshot.peer, p != seenSummaries.last { seenSummaries.append(p) }
            if let at = w?.peerUpdatedMs, at >= 15_000 { arrivals.insert(at) }
            c.ingest(w, at: t)
        }
        let rec = c.record(fixture: nil)
        XCTAssertEqual(rec.receiverCounting, .perWindow)
        XCTAssertEqual(rec.receiverAlignment, .aligned)
        let keys = rec.receiverSummaries.map { [$0.summary.windowSeriesID, $0.summary.windowSequence] }
        XCTAssertEqual(Set(keys).count, keys.count, "each receiver window once")
        XCTAssertGreaterThan(arrivals.count, rec.receiverSummaries.count + 2,
                             "the receiver sent every window two or three times")
        // The single 400 ms stall is counted once, however often its window was sent.
        XCTAssertEqual(rec.receiverSummaries.reduce(0) { $0 + ($1.summary.arrivalGapsOver250ms ?? 0) }, 1)
        // Only windows that began after the trial's first sender window began.
        let first = try XCTUnwrap(rec.windows.first)
        let threshold = Double(first.sequence - 1)
        XCTAssertTrue(rec.receiverSummaries.allSatisfy { ($0.summary.peerWindowSequenceAtStart ?? -1) >= threshold })
        XCTAssertTrue(seenSummaries.contains { ($0.peerWindowSequenceAtStart ?? -1) < threshold && $0.windowSequence != nil },
                      "pre-trial receiver windows were reported during the trial and left out")
        XCTAssertGreaterThanOrEqual(rec.receiverSummaries.count, 3, "the grace after the last sender window keeps late windows")
        XCTAssertEqual(rec.receiverWindowsMissed, 0)
        XCTAssertEqual(rec.status, .complete)
    }

    private func window(_ sequence: UInt64, startMs: Double, peer: StreamDiagnosticsPeerSummary?, peerAtMs: Double? = nil) -> StreamDiagnosticsCompletedWindow {
        var snapshot = recorder().snapshot(at: 0)
        snapshot.peer = peer
        return StreamDiagnosticsCompletedWindow(sequence: sequence, startMs: startMs, durationMs: 5_000,
                                                histograms: [DiagnosticsHistogram](repeating: .init(), count: DiagnosticsStage.allCases.count),
                                                snapshot: snapshot, peerUpdatedMs: peerAtMs)
    }

    private func receiverSummary(series: Double?, sequence: Double?, marker: Double?, jitter: Double = 1) -> StreamDiagnosticsPeerSummary {
        var s = StreamDiagnosticsPeerSummary(side: .receiver)
        s.windowSeriesID = series
        s.windowSequence = sequence
        s.peerWindowSequenceAtStart = marker
        s.arrivalGapsOver250ms = 1
        s.rttJitterMs = jitter
        return s
    }

    func testReconnectOutOfOrderRepeatedAndPartialReceiverSummaries() {
        var c = PerformanceLabTrialCollector(scenario: scenario(windows: 6), trialIndex: 1, synthetic: true, armedAtMs: 10_000)
        // Warm-up window 1 (5–10 s), then the trial's window 2 starts at 10 s exactly.
        c.ingest(window(1, startMs: 5_000, peer: nil), at: 10_100)
        let feed: [(UInt64, StreamDiagnosticsPeerSummary)] = [
            (2, receiverSummary(series: 7, sequence: 40, marker: 0)),             // began before the trial: out
            (2, receiverSummary(series: 7, sequence: 41, marker: 1)),             // began once window 1 completed: in
            (3, receiverSummary(series: 7, sequence: 41, marker: 1, jitter: 2)),  // repeated, other jitter: once
            (3, receiverSummary(series: 7, sequence: 43, marker: 3)),             // out of order ...
            (4, receiverSummary(series: 7, sequence: 42, marker: 2)),             // ... both kept
            (4, receiverSummary(series: 7, sequence: nil, marker: nil)),          // partial window: not whole
            (5, receiverSummary(series: 9, sequence: 1, marker: 4)),              // reconnect: new series, restarts at 1
            (5, receiverSummary(series: 9, sequence: 3, marker: 5)),              // series 9 window 2 never seen
            (6, receiverSummary(series: 9, sequence: 1, marker: 4, jitter: 3)),   // repeated after others
        ]
        var t = 10_100.0
        for (sequence, summary) in feed {
            t += 1_000
            c.ingest(window(sequence, startMs: 10_000 + Double(sequence - 2) * 5_000, peer: summary, peerAtMs: t - 10), at: t)
        }
        let rec = c.record(fixture: nil)
        XCTAssertEqual(rec.receiverSummaries.map { $0.summary.windowSequence }, [41, 43, 42, 1, 3])
        XCTAssertEqual(rec.receiverSummaries.reduce(0) { $0 + ($1.summary.arrivalGapsOver250ms ?? 0) }, 5)
        XCTAssertEqual(rec.receiverWindowsMissed, 1, "series 9, window 2")
        XCTAssertEqual(rec.receiverAlignment, .aligned)
        XCTAssertEqual(rec.receiverCounting, .perWindow)
        XCTAssertEqual(rec.receiverSummaries.first?.offsetSeconds ?? 0, 2.09, accuracy: 1e-9, "arrival time, not poll time")

        // A receiver that numbers its windows but sends no start marker:
        // kept by arrival time, and the receiver side is partial.
        var u = PerformanceLabTrialCollector(scenario: scenario(windows: 6), trialIndex: 1, synthetic: true, armedAtMs: 0)
        u.ingest(window(1, startMs: 0, peer: receiverSummary(series: 7, sequence: 5, marker: nil), peerAtMs: 4_000), at: 5_000)
        u.ingest(window(2, startMs: 5_000, peer: receiverSummary(series: 7, sequence: 6, marker: nil), peerAtMs: 10_500), at: 10_600)
        let partial = u.record(fixture: nil)
        XCTAssertEqual(partial.receiverSummaries.map { $0.summary.windowSequence }, [6])
        XCTAssertEqual(partial.receiverAlignment, .partial)
    }

    /// Property: repeating reads (the poll runs faster than anything
    /// changes) never changes the trial. Fixed seed.
    func testCollectorIsIdempotentUnderRepeatedReads() {
        var rng = PerformanceLabRandom(seed: 0x5EED_1234)
        for _ in 0..<20 {
            scriptedReceivers = [:]
            let r = recorder()
            var reads: [(StreamDiagnosticsCompletedWindow?, Double)] = []
            var t = 0.0
            while t < 40_000 {
                t += 100
                r.markInterval(.submitInterval, at: t)
                r.recordDuration(.encode, ms: Double(rng.next() % 4000) / 100, at: t)
                feedAlignedReceiver(into: r, at: t)
                if t.truncatingRemainder(dividingBy: 500) == 0 { reads.append((r.completedWindowForLab(at: t), t)) }
            }
            var once = PerformanceLabTrialCollector(scenario: scenario(windows: 4), trialIndex: 1, synthetic: true, armedAtMs: 6_000)
            var repeated = once
            for (w, at) in reads {
                once.ingest(w, at: at)
                for _ in 0..<(1 + Int(rng.next() % 4)) { repeated.ingest(w, at: at) }
            }
            XCTAssertEqual(once.record(fixture: nil), repeated.record(fixture: nil))
        }
    }

    /// Property: merged percentiles are monotone and bounded, and bucket
    /// counts are conserved by merging. Fixed seed.
    func testHistogramPercentileAndMergeInvariants() {
        var rng = PerformanceLabRandom(seed: 42)
        for _ in 0..<200 {
            var parts = [DiagnosticsHistogram](repeating: .init(), count: 1 + Int(rng.next() % 5))
            var all = DiagnosticsHistogram()
            for _ in 0..<(1 + Int(rng.next() % 400)) {
                let v = Double(rng.next() % 2_000_000) / 100 * (rng.next() % 7 == 0 ? 10 : 1)
                parts[Int(rng.next() % UInt64(parts.count))].record(v)
                all.record(v)
            }
            let merged = PerformanceLabHistogramRecord(id: "x", merging: parts)
            XCTAssertEqual(merged.count, all.count)
            XCTAssertEqual(merged.buckets.reduce(0, +), merged.count, "count conservation")
            XCTAssertEqual(merged.buckets, all.buckets.map(Int.init))
            XCTAssertLessThanOrEqual(merged.min, merged.p50)
            XCTAssertLessThanOrEqual(merged.p50, merged.p95)
            XCTAssertLessThanOrEqual(merged.p95, merged.p99)
            XCTAssertLessThanOrEqual(merged.p99, merged.max)
            XCTAssertEqual(merged.p95, all.percentile(0.95))
            var last = 0.0
            for p in stride(from: 0.0, through: 1.0, by: 0.05) {
                let v = all.percentile(p) ?? 0
                XCTAssertGreaterThanOrEqual(v, last, "monotone in p")
                last = v
            }
        }
    }

    // MARK: Controller

    private final class Clock { var ms = 0.0 }

    private func controller(recorder: StreamDiagnosticsRecorder?, clock: Clock, parent: URL,
                            diagnostics: Bool = true) -> PerformanceLabRunController {
        PerformanceLabRunController(dependencies: .init(
            recorder: { recorder }, diagnosticsEnabled: { diagnostics }, nowMs: { clock.ms },
            now: { PerformanceLabSyntheticRun.createdAt }, build: PerformanceLabSyntheticRun.build,
            commit: "4C0E8067", outputParent: parent, fixture: { nil }))
    }

    private func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-lab-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testNoSessionFailsEveryTrialButStillWritesThemAll() throws {
        let clock = Clock()
        let parent = tempDir()
        let c = controller(recorder: nil, clock: clock, parent: parent)
        c.start(try PerformanceLabRunPlan.make(scenarioID: "mirror.frame-counter"))
        guard case .waitingForOperator(nil, let steps) = c.phase else { return XCTFail("setup first") }
        XCTAssertFalse(steps.isEmpty)
        var guardCount = 0
        while c.isRunning, guardCount < 1000 {
            guardCount += 1
            if case .waitingForOperator = c.phase { c.operatorReady() }
            clock.ms += 500
            c.tick()
        }
        guard case .finished(let folder) = c.phase else { return XCTFail("\(c.phase)") }
        XCTAssertEqual(c.completedTrials.map(\.status), [.failed, .failed, .failed])
        XCTAssertTrue(c.completedTrials.allSatisfy { $0.issues.contains(.noSession) })
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["manifest.json", "trial-01.json", "trial-02.json", "trial-03.json"])
        let manifest = try PerformanceLabBundle.decoder().decode(PerformanceLabRunManifest.self,
                                                                 from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        XCTAssertEqual(manifest.trials.map(\.status), [.failed, .failed, .failed])
        XCTAssertEqual(manifest.environment.commit, "4c0e8067")
        XCTAssertFalse(manifest.synthetic)
    }

    func testOperatorStepsGateEachTrial() throws {
        let clock = Clock()
        let c = controller(recorder: recorder(), clock: clock, parent: tempDir())
        c.start(try PerformanceLabRunPlan.make(scenarioID: "mirror.frame-counter"))
        c.operatorReady()
        guard case .waitingForOperator(1, let steps) = c.phase else { return XCTFail("per-trial step first: \(c.phase)") }
        XCTAssertEqual(steps.count, 1, "keep hands off")
        clock.ms += 30_000
        c.tick()
        guard case .waitingForOperator(1, _) = c.phase else { return XCTFail("waits for Ready") }
        c.operatorReady()
        guard case .warmingUp(1, 10) = c.phase else { return XCTFail("\(c.phase)") }
    }

    func testDuringTrialPromptsAppearOnSchedule() throws {
        let clock = Clock()
        let r = recorder()
        let c = controller(recorder: r, clock: clock, parent: tempDir())
        c.start(try PerformanceLabRunPlan.make(scenarioID: "extend.reconnection"))
        c.operatorReady()
        guard case .warmingUp(1, _) = c.phase else { return XCTFail("no per-trial step: \(c.phase)") }
        var seen: [Int: Int] = [:]
        while case .warmingUp = c.phase { clock.ms += 500; r.markInterval(.submitInterval, at: clock.ms); c.tick() }
        let armed = clock.ms
        while case .measuring(1, _, _) = c.phase, clock.ms < armed + 60_000 {
            clock.ms += 500
            r.markInterval(.submitInterval, at: clock.ms)
            c.tick()
            seen[Int((clock.ms - armed) / 1000), default: 0] = c.prompts.count
        }
        XCTAssertEqual(seen[5], 0)
        XCTAssertEqual(seen[12], 1, "disconnect prompt at 10 s")
        XCTAssertEqual(seen[16], 2, "reconnect prompt at 15 s")
    }

    func testDiagnosticsOffAndCancelAreRecordedNotDropped() throws {
        let clock = Clock()
        let c = controller(recorder: recorder(), clock: clock, parent: tempDir(), diagnostics: false)
        c.start(try PerformanceLabRunPlan.make(scenarioID: PerformanceLabScenarioCatalog.synthetic.id))
        c.operatorReady()
        clock.ms += 500
        c.tick()
        // Listed in PerformanceLabTrialIssue.allCases order.
        XCTAssertEqual(c.completedTrials.first?.issues, [.missingWindows, .noReceiverSummary, .diagnosticsOff])
        XCTAssertEqual(c.completedTrials.first?.status, .failed)
        c.cancel()
        guard case .cancelled(let folder) = c.phase else { return XCTFail("\(c.phase)") }
        XCTAssertNotNil(folder, "the failed trial is written")
        XCTAssertEqual(c.completedTrials.map(\.status), [.failed, .cancelled, .cancelled], "every planned trial is listed")
    }

    /// B10: a trial cancelled during its warm-up, and the trials that never
    /// started, are written as cancelled, not dropped.
    func testCancelDuringWarmUpKeepsEveryPlannedTrial() throws {
        let clock = Clock()
        let c = controller(recorder: recorder(), clock: clock, parent: tempDir())
        c.start(try PerformanceLabRunPlan.make(scenarioID: PerformanceLabScenarioCatalog.synthetic.id, trials: 4))
        c.operatorReady()
        guard case .warmingUp(1, _) = c.phase else { return XCTFail("\(c.phase)") }
        clock.ms += 500
        c.tick()
        c.cancel()
        guard case .cancelled(let folder?) = c.phase else { return XCTFail("a bundle is written: \(c.phase)") }
        XCTAssertEqual(c.completedTrials.map(\.trialIndex), [1, 2, 3, 4])
        XCTAssertEqual(c.completedTrials.map(\.status), [.cancelled, .cancelled, .cancelled, .cancelled])
        XCTAssertTrue(c.completedTrials[0].issues.contains(.cancelledByOperator))
        XCTAssertFalse(c.completedTrials[0].issues.contains(.notStarted), "it was warming up")
        XCTAssertTrue(c.completedTrials.dropFirst().allSatisfy { $0.issues.contains(.notStarted) && $0.issues.contains(.cancelledByOperator) })
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["manifest.json", "trial-01.json", "trial-02.json", "trial-03.json", "trial-04.json"])

        // Cancelled before the first trial began: nothing measured, nothing written.
        let early = controller(recorder: recorder(), clock: clock, parent: tempDir())
        early.start(try PerformanceLabRunPlan.make(scenarioID: PerformanceLabScenarioCatalog.synthetic.id))
        early.cancel()
        guard case .cancelled(nil) = early.phase else { return XCTFail("\(early.phase)") }
    }

    // MARK: SYNTHETIC self-test and golden bundle

    func testSyntheticRunMatchesTheGoldenBundle() throws {
        let folder = try PerformanceLabSyntheticRun.run(under: tempDir())
        XCTAssertEqual(folder.lastPathComponent, "perf-lab-synthetic.self-test-20261117-0000-synthetic")
        let golden = PerformanceLabGolden.goldenDir.appendingPathComponent("synthetic-run")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["manifest.json", "trial-01.json", "trial-02.json", "trial-03.json"])
        for name in names {
            try PerformanceLabGolden.check(Data(contentsOf: folder.appendingPathComponent(name)), against: golden.appendingPathComponent(name))
        }
        let decoder = PerformanceLabBundle.decoder()
        let manifest = try decoder.decode(PerformanceLabRunManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
        XCTAssertTrue(manifest.synthetic)
        XCTAssertEqual(manifest.trials.map(\.status), [.complete, .complete, .complete])
        let trial3 = try decoder.decode(PerformanceLabTrialRecord.self, from: Data(contentsOf: folder.appendingPathComponent("trial-03.json")))
        XCTAssertEqual(trial3.gaps["sender.submit_interval_ms"]?[1], 1, "the scripted 300 ms stall")
        XCTAssertNil(trial3.gaps["receiver.arrival_interval_ms"], "the sender lists only its own stages")
        XCTAssertEqual(trial3.windows.count, 3)
        XCTAssertGreaterThanOrEqual(trial3.receiverSummaries.count, 1)
        // The scripted receiver sends each 5 s window two or three times;
        // each is kept once, and its one stall is counted once.
        let keys = trial3.receiverSummaries.compactMap(\.summary.windowSequence)
        XCTAssertEqual(Set(keys).count, trial3.receiverSummaries.count)
        XCTAssertEqual(trial3.receiverSummaries.reduce(0) { $0 + ($1.summary.arrivalGapsOver250ms ?? 0) }, 1)
        XCTAssertEqual(trial3.receiverCounting, .perWindow)
        XCTAssertEqual(trial3.receiverAlignment, .aligned)
    }

    func testSyntheticRunIsDeterministic() throws {
        let a = try PerformanceLabSyntheticRun.run(under: tempDir())
        let b = try PerformanceLabSyntheticRun.run(under: tempDir())
        for name in ["manifest.json", "trial-01.json", "trial-02.json", "trial-03.json"] {
            XCTAssertEqual(try Data(contentsOf: a.appendingPathComponent(name)), try Data(contentsOf: b.appendingPathComponent(name)), name)
        }
    }

    // MARK: Privacy (same approach as the diagnostics export test)

    /// Lab keys beyond the diagnostics export's allowlist.
    private static let labKeys: Set<String> = [
        "format", "schemaVersion", "synthetic", "createdAt", "plan", "minimumTrials", "scenarioCatalogVersion", "workload",
        "workloadSignature", "frameIDVersion", "environment", "diagnosticsSchemaVersion", "metricDictionaryVersion",
        "windowSeconds", "histogramUpperEdgesMs", "trials", "metrics", "classifierThresholds", "limitations",
        "scenario", "variant", "caption", "purpose", "mode", "panes", "warmUpSeconds", "trialWindows", "primaryMetrics",
        "steps", "timing", "atSecond", "instruction", "expectsRestarts", "version", "seed", "cycle", "kind", "seconds",
        "sender", "commit", "context", "index", "status", "issues", "unit", "side", "timebase", "source", "caveat",
        "scenarioID", "trialIndex", "requestedWindows", "measuredSeconds", "windows", "sequence", "offsetSeconds",
        "durationSeconds", "snapshot", "verdict", "stages", "counters", "gaps", "receiverSummaries", "summary", "fixture",
        "drawnFrames", "drawInterval", "sum", "min", "buckets", "frameIDUniqueFPS",
        "frameIDDuplicates", "frameIDMissing", "frameIDUnreadable", "frameIDUnexamined", "frameIDIntervalP95Ms",
        "receiverAlignment", "receiverCounting", "receiverWindowsMissed", "expectedRestarts", "restartUnmeasuredSeconds",
        "windowSeriesID", "windowSequence", "peerWindowSequenceAtStart",
    ]
    private static let exportKeys: Set<String> = [
        "appVersion", "osMajor", "osMinor", "osPatch", "platform", "deviceClass", "windowIsPartial", "sessionCounters",
        "rttJitterMs", "peer", "resources", "gauges", "id", "count", "ratePerSecond", "p50", "p95", "p99", "max", "mean",
        "gapsOver100ms", "gapsOver250ms", "gapsOver500ms", "last", "samples", "displayMode", "codec", "rasterWidth",
        "rasterHeight", "targetFPS", "sourceRefreshHz", "encoderInFlightLimit", "route", "networkProtocol",
        "pathExpensive", "pathConstrained", "presentationPath", "clockOffsetKnown", "cause", "confidence", "reason",
        "evidence", "alternatives", "frameBudgetMs", "metric", "value", "comparison", "threshold", "met", "fromPeer",
        "captureCompleteFPS", "captureIdleShare", "submitFPS", "encodeP95Ms",
        "sendP95Ms", "encoderBusyShare", "sendBackpressureShare", "composeP95Ms", "composeFPS",
        "arrivalFPS", "arrivalP50Ms", "arrivalP95Ms", "arrivalGapsOver250ms", "enqueueFPS", "presenterQueueAgeP95Ms",
        "decodeP95Ms", "decodeSamples", "rttMs", "processCPUPercent", "memoryFootprintMB",
        "thermalState", "lowPowerMode", "batteryState", "sampleIntervalSeconds",
    ]
    private static let forbiddenKeyFragments = [
        "title", "name", "path", "file", "ssid", "host", "address", "addr", "ip", "endpoint", "serial", "pair",
        "spki", "key", "token", "secret", "screenshot", "image", "pixel", "input", "text", "url", "user", "bundle",
    ]

    func testRunBundleContainsOnlyReviewedKeysAndConstantStrings() throws {
        let folder = try PerformanceLabSyntheticRun.run(under: tempDir())
        let metricIDs = Set(StreamDiagnosticsMetricDictionary.all.map(\.id))
        let thresholdNames = Set(StreamBottleneckClassifier.thresholds.keys)
        for key in Self.labKeys {
            for bad in Self.forbiddenKeyFragments where key.lowercased().contains(bad) {
                XCTAssertTrue(["context"].contains(key), "\(key) looks like a \(bad) field")
            }
        }
        // Every string a bundle may hold is a constant from code (the same
        // set tools/perf-lab/scenarios.json ships to the analysis tool),
        // plus the synthetic build's version and creation date.
        let constants = PerformanceLabGolden.bundleStringConstants().union(["synthetic", "2026-11-17T00:00:00Z"])

        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(name)))
            var keys: Set<String> = []
            var strings: [String] = []
            func walk(_ value: Any) {
                if let dict = value as? [String: Any] {
                    for (k, v) in dict { keys.insert(k); walk(v) }
                } else if let array = value as? [Any] {
                    array.forEach(walk)
                } else if let s = value as? String {
                    strings.append(s)
                }
            }
            walk(object)
            let unexpected = keys.subtracting(Self.labKeys).subtracting(Self.exportKeys).subtracting(metricIDs).subtracting(thresholdNames)
            XCTAssertTrue(unexpected.isEmpty, "\(name): unreviewed keys \(unexpected.sorted())")
            for s in strings {
                XCTAssertTrue(constants.contains(s), "\(name): unexpected string \(s)")
            }
        }
    }
}
