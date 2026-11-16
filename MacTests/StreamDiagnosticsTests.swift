import AVFoundation
import XCTest

/// Streaming diagnostics (#123): recorder math, accounting, reset, overflow,
/// the disabled no-op, thread safety and the presenter queue measurement.
/// Deterministic: every time is injected except in the presenter test.
final class StreamDiagnosticsTests: XCTestCase {

    private func makeRecorder(_ side: StreamDiagnosticsSide = .sender, enabled: Bool = true,
                              window: Double = 5) -> (StreamDiagnosticsRecorder, StreamDiagnosticsSwitch) {
        let sw = StreamDiagnosticsSwitch(enabled: enabled)
        return (StreamDiagnosticsRecorder(side: side, windowSeconds: window, diagnosticsSwitch: sw,
                                          resourceSampler: nil, nowMs: 0), sw)
    }

    // MARK: - Histogram

    func testBucketIndexBoundaries() {
        XCTAssertEqual(DiagnosticsHistogram.bucketIndex(for: 0), 0)
        XCTAssertEqual(DiagnosticsHistogram.bucketIndex(for: 0.25), 0)
        XCTAssertEqual(DiagnosticsHistogram.bucketIndex(for: 0.26), 1)
        XCTAssertEqual(DiagnosticsHistogram.bucketIndex(for: 16.7), DiagnosticsHistogram.upperEdgesMs.firstIndex(of: 17))
        XCTAssertEqual(DiagnosticsHistogram.bucketIndex(for: 10_000), DiagnosticsHistogram.upperEdgesMs.count - 1)
        XCTAssertEqual(DiagnosticsHistogram.bucketIndex(for: 10_001), DiagnosticsHistogram.upperEdgesMs.count)
        XCTAssertEqual(DiagnosticsHistogram.upperEdgesMs, DiagnosticsHistogram.upperEdgesMs.sorted())
    }

    func testPercentilesBoundTheTrueValueWithinOneBucket() {
        var h = DiagnosticsHistogram()
        for v in 1...100 { h.record(Double(v)) }
        XCTAssertEqual(h.count, 100)
        XCTAssertEqual(h.mean, 50.5, accuracy: 1e-9)
        XCTAssertEqual(h.max, 100)
        // True p50 = 50 sits exactly on an edge.
        XCTAssertEqual(h.percentile(0.5), 50)
        // True p95 = 95, reported as its bucket's upper edge (90, 100].
        XCTAssertEqual(h.percentile(0.95), 100)
        XCTAssertEqual(h.percentile(0.99), 100)
        // Never below the true value, never above the max.
        for p in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let reported = h.percentile(p)!
            XCTAssertGreaterThanOrEqual(reported, (Double(100) * p).rounded(.up))
            XCTAssertLessThanOrEqual(reported, 100)
        }
    }

    func testOverflowNegativeAndNonFiniteValues() {
        var h = DiagnosticsHistogram()
        XCTAssertNil(h.percentile(0.5))
        h.record(-12)            // clock-mapping error counts as 0
        h.record(.nan)           // ignored
        h.record(.infinity)      // ignored
        h.record(20_000)         // overflow bucket
        XCTAssertEqual(h.count, 2)
        // The 0 sits in the first bucket, reported as its upper edge.
        XCTAssertEqual(h.percentile(0.01), 0.25)
        XCTAssertEqual(h.percentile(1), 20_000, "the overflow bucket reports the observed max")
        h.reset()
        XCTAssertEqual(h.count, 0)
        XCTAssertNil(h.percentile(0.5))
    }

    func testPercentileOfConstantSeriesIsThatValue() {
        var h = DiagnosticsHistogram()
        for _ in 0..<500 { h.record(16.7) }
        // Clamped to the observed max, so a constant series is exact.
        XCTAssertEqual(h.percentile(0.5), 16.7)
        XCTAssertEqual(h.percentile(0.99), 16.7)
    }

    // MARK: - Windows, intervals, gaps

    func testIntervalsGapsAndWindowRotation() {
        let (r, _) = makeRecorder(.receiver)
        // 60 FPS for 2 s, then one 300 ms freeze, then 60 FPS.
        var t = 0.0
        for _ in 0..<120 { r.recordArrival(bytes: 1000, wireSubmitToSendMs: 4, mappedSubmitToReceiveMs: 20, at: t); t += 1000.0 / 60 }
        t += 300
        for _ in 0..<60 { r.recordArrival(bytes: 1000, wireSubmitToSendMs: 4, mappedSubmitToReceiveMs: 20, at: t); t += 1000.0 / 60 }
        let partial = r.snapshot(at: t)
        XCTAssertTrue(partial.windowIsPartial)
        let arrivals = partial.stage(.arrivalInterval)!
        XCTAssertEqual(arrivals.count, 179)
        XCTAssertEqual(arrivals.gapsOver100ms, 1)
        XCTAssertEqual(arrivals.gapsOver250ms, 1)
        XCTAssertEqual(arrivals.gapsOver500ms, 0)
        XCTAssertEqual(arrivals.p50, 17)
        XCTAssertEqual(partial.count(.arrivedFrames), 180)
        XCTAssertEqual(partial.count(.arrivedBytes), 180_000)

        // Crossing 5 s completes the window; the snapshot reports it.
        let completed = r.snapshot(at: 5_100)
        XCTAssertFalse(completed.windowIsPartial)
        XCTAssertEqual(completed.count(.arrivedFrames), 180)
        XCTAssertEqual(completed.windowSeconds, 5.1, accuracy: 0.001)
        XCTAssertEqual(completed.rate(.arrivedFrames), 180 / 5.1, accuracy: 0.01)

        // A long quiet spell: the window completes with its real length.
        // Changed with the B5 fix: it used to be reported as a fresh empty
        // 5 s window, hiding how long the silence lasted.
        let quiet = r.snapshot(at: 30_000)
        XCTAssertEqual(quiet.count(.arrivedFrames), 0)
        XCTAssertEqual(quiet.windowSeconds, 24.9, accuracy: 0.001)
        XCTAssertEqual(quiet.sessionCounters[DiagnosticsCounter.arrivedFrames.definition.id], 180)
    }

    func testGenerationChangeRestartsIntervalBaselinesWithoutAStall() {
        let (r, _) = makeRecorder()
        r.noteGeneration(1, at: 0)
        r.recordCapture(.complete, at: 0)
        r.recordCapture(.complete, at: 16)
        // A capture restart 2 s later must not record a 2 s capture "stall".
        r.noteGeneration(2, at: 2_000)
        r.recordCapture(.complete, at: 2_016)
        r.recordCapture(.complete, at: 2_032)
        let s = r.snapshot(at: 2_040)
        XCTAssertEqual(s.stage(.captureInterval)?.count, 1)
        XCTAssertEqual(s.stage(.captureInterval)?.gapsOver100ms, 0)
        XCTAssertEqual(s.count(.generationResets), 1)
        XCTAssertEqual(s.sessionCounters[DiagnosticsCounter.captureComplete.definition.id], 4)
        // The same generation again changes nothing.
        r.noteGeneration(2, at: 2_050)
        XCTAssertEqual(r.snapshot(at: 2_060).count(.generationResets), 1)
    }

    func testResetClearsSessionState() {
        let (r, _) = makeRecorder()
        r.recordSubmit(origin: .live, sourceKey: 1, sourceAgeMs: 3, pendingEncodes: 1, at: 0)
        r.updateContext { $0.targetFPS = 60; $0.route = .lan }
        r.updatePeer(StreamDiagnosticsPeerSummary(side: .receiver))
        r.reset(at: 100)
        let s = r.snapshot(at: 200)
        XCTAssertTrue(s.counters.values.allSatisfy { $0 == 0 })
        XCTAssertTrue(s.sessionCounters.values.allSatisfy { $0 == 0 })
        XCTAssertEqual(s.context, StreamDiagnosticsContext())
        XCTAssertNil(s.peer)
        // After a reset the first submission of an old key is unique again.
        r.recordSubmit(origin: .live, sourceKey: 1, sourceAgeMs: nil, pendingEncodes: 0, at: 300)
        XCTAssertEqual(r.snapshot(at: 400).count(.submitSourceUnique), 1)
    }

    func testRouteChangesCountOnlyRealChanges() {
        let (r, _) = makeRecorder()
        r.updateContext { $0.route = .lan }      // first known route: not a change
        r.updateContext { $0.route = .lan }
        r.updateContext { $0.route = .usb }
        r.updateContext { $0.route = .remote }
        XCTAssertEqual(r.snapshot(at: 10).count(.routeChanges), 2)
    }

    // MARK: - Frame accounting

    func testUniqueDuplicateHeldAndReplayAccounting() {
        let (r, _) = makeRecorder()
        // Capture: 3 complete, 2 idle, 1 other.
        for status in [DiagnosticsCaptureStatus.complete, .idle, .complete, .idle, .other, .complete] {
            r.recordCapture(status, at: 1)
        }
        r.increment(.admittedLive, by: 3, at: 1)
        r.increment(.heldByRateLimit, by: 2, at: 1)
        r.increment(.heldRetryFired, at: 1)
        r.recordSubmit(origin: .live, sourceKey: 100, sourceAgeMs: 5, pendingEncodes: 1, at: 2)
        r.recordSubmit(origin: .heldRetry, sourceKey: 200, sourceAgeMs: 40, pendingEncodes: 2, at: 3)
        // A drop replay of pixels already submitted: duplicate.
        r.recordSubmit(origin: .dropReplay, sourceKey: 200, sourceAgeMs: 70, pendingEncodes: 0, at: 4)
        // Reconnect replay of a newer capture: unique, still a replay by origin.
        r.recordSubmit(origin: .reconnectReplay, sourceKey: 300, sourceAgeMs: 1500, pendingEncodes: 0, at: 5)
        // Window view: uniqueness unknown from the PTS.
        r.recordSubmit(origin: .workspace, sourceKey: nil, sourceAgeMs: nil, pendingEncodes: 1, at: 6)
        r.recordEncodeOutput(durationMs: 9, bytes: 40_000, keyframe: true, outcome: .sent, at: 7)
        r.recordEncodeOutput(durationMs: 8, bytes: 9_000, keyframe: false, outcome: .stale, at: 7)
        r.recordEncodeOutput(durationMs: nil, bytes: 0, keyframe: false, outcome: .failed, at: 7)
        r.recordSendCompletion(durationMs: 3, bytes: 40_100, error: false, at: 8)
        r.recordSendCompletion(durationMs: 50, bytes: 9_100, error: true, at: 8)
        let s = r.snapshot(at: 10)
        XCTAssertEqual(s.count(.captureComplete), 3)
        XCTAssertEqual(s.count(.captureIdle), 2)
        XCTAssertEqual(s.count(.captureOtherStatus), 1)
        XCTAssertEqual(s.count(.submitSourceUnique), 3)
        XCTAssertEqual(s.count(.submitDuplicate), 1)
        XCTAssertEqual(s.count(.submitUniquenessUnknown), 1)
        XCTAssertEqual(s.count(.submitLive), 1)
        XCTAssertEqual(s.count(.submitHeldRetry), 1)
        XCTAssertEqual(s.count(.submitDropReplay), 1)
        XCTAssertEqual(s.count(.submitReconnectReplay), 1)
        XCTAssertEqual(s.count(.submitWorkspace), 1)
        XCTAssertEqual(s.count(.encodeCompleted), 2, "a stale output was encoded")
        XCTAssertEqual(s.count(.encodeStaleDiscarded), 1)
        XCTAssertEqual(s.count(.encodeFailed), 1)
        XCTAssertEqual(s.count(.encodedBytes), 40_000, "stale output never counts as payload")
        XCTAssertEqual(s.count(.keyframes), 1)
        XCTAssertEqual(s.count(.sendCompleted), 1)
        XCTAssertEqual(s.count(.sendErrors), 1)
        XCTAssertEqual(s.count(.sentBytes), 40_100)
        XCTAssertEqual(s.stage(.sourceAgeAtSubmit)?.count, 4)
        XCTAssertEqual(s.stage(.encode)?.count, 2)
        XCTAssertEqual(s.gauge(.pendingEncodes)?.max, 2)
    }

    func testReceiverEnqueuedIsNotObservedPresentation() {
        let (r, _) = makeRecorder(.receiver)
        for i in 0..<10 { r.recordPresentationEnqueue(at: Double(i) * 16) }
        let s = r.snapshot(at: 200)
        XCTAssertEqual(s.count(.enqueuedForPresentation), 10)
        XCTAssertEqual(s.count(.observedPresentations), 0)
        XCTAssertTrue(DiagnosticsCounter.enqueuedForPresentation.definition.caveat.contains("never confirmed"))
        XCTAssertFalse(StreamDiagnosticsPresentation.label(for: .presentationEnqueueInterval).lowercased().contains("presented"))
    }

    // MARK: - Disabled = no-op

    func testDisabledRecorderTouchesNothing() {
        let (r, sw) = makeRecorder(enabled: false)
        let before = r.snapshot(at: 1)
        r.recordCapture(.complete, at: 2)
        r.recordSubmit(origin: .live, sourceKey: 1, sourceAgeMs: 1, pendingEncodes: 1, at: 2)
        r.recordEncodeOutput(durationMs: 1, bytes: 1, keyframe: true, outcome: .sent, at: 2)
        r.recordSendCompletion(durationMs: 1, bytes: 1, error: false, at: 2)
        r.recordCompose(durationMs: 1, staticResend: true, tiles: 1, floats: 1, dimmed: 1, withFrame: 1, at: 2)
        r.recordArrival(bytes: 1, wireSubmitToSendMs: 1, mappedSubmitToReceiveMs: 1, at: 2)
        r.recordPresentationEnqueue(at: 2)
        r.recordRTT(5, at: 2)
        r.recordDuration(.decode, ms: 3, at: 2)
        r.markInterval(.arrivalInterval, at: 2)
        r.increment(.keyframes, at: 2)
        r.observeGauge(.pendingSends, 3, at: 2)
        r.noteGeneration(7, at: 2)
        r.updateContext { $0.targetFPS = 120 }
        r.updatePeer(StreamDiagnosticsPeerSummary(side: .receiver))
        XCTAssertEqual(r.presenterCommandEnqueued(), 0, "no stamp, no clock read, no depth change")
        r.presenterCommandProcessed(stamp: 0)
        let after = r.snapshot(at: 1)
        XCTAssertEqual(before, after)
        XCTAssertTrue(after.sessionCounters.values.allSatisfy { $0 == 0 })
        // Switching on later starts from a clean slate (no stale baselines).
        sw.set(true)
        r.recordCapture(.complete, at: 3)
        XCTAssertEqual(r.snapshot(at: 4).stage(.captureInterval)?.count, 0)
    }

    func testDisabledHookCostIsSmall() {
        let (r, _) = makeRecorder(enabled: false)
        // Not a benchmark: a guard that the disabled path stays a flag read.
        // 200k disabled calls must finish far inside a frame budget per call.
        let start = DispatchTime.now().uptimeNanoseconds
        for i in 0..<200_000 { r.recordCapture(.complete, at: Double(i)) }
        let perCallNs = Double(DispatchTime.now().uptimeNanoseconds - start) / 200_000
        XCTAssertLessThan(perCallNs, 5_000, "a disabled hook should cost well under 5 µs")
    }

    // MARK: - Thread safety

    func testConcurrentRecordingIsExact() {
        let (r, _) = makeRecorder(window: 3600)
        let threads = 8, perThread = 5_000
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            for i in 0..<perThread {
                let now = Double(t * perThread + i) * 0.001
                r.increment(.arrivedFrames, at: now)
                r.recordDuration(.decode, ms: Double(i % 20), at: now)
                _ = r.snapshot(at: now)
            }
        }
        let s = r.snapshot(at: 100)
        XCTAssertEqual(s.count(.arrivedFrames), Int64(threads * perThread))
        XCTAssertEqual(s.stage(.decode)?.count, threads * perThread)
    }

    // MARK: - Presenter command queue (measurement only)

    func testPresenterDepthNeverDriftsAcrossToggling() {
        // The presenter hooks read the real clock: start the window now.
        let sw = StreamDiagnosticsSwitch(enabled: true)
        let r = StreamDiagnosticsRecorder(side: .receiver, windowSeconds: 3600, diagnosticsSwitch: sw, resourceSampler: nil)
        let a = r.presenterCommandEnqueued()
        let b = r.presenterCommandEnqueued()
        sw.set(false)
        let c = r.presenterCommandEnqueued()          // untracked
        XCTAssertEqual(c, 0)
        r.presenterCommandProcessed(stamp: a)          // tracked: leaves the count even while off
        sw.set(true)
        r.presenterCommandProcessed(stamp: c)
        let d = r.presenterCommandEnqueued()
        XCTAssertNotEqual(d, 0)
        r.presenterCommandProcessed(stamp: b)
        r.presenterCommandProcessed(stamp: d)
        let s = r.snapshot()
        // Depth samples: 1, 2 (a, b); switching back on restarts the window
        // (B5), so this window holds 2 for d (b still queued).
        XCTAssertEqual(s.gauge(.presenterQueueDepth)?.samples, 1)
        XCTAssertEqual(s.gauge(.presenterQueueDepth)?.max, 2)
        XCTAssertEqual(s.gauge(.presenterQueueDepth)?.last, 2)
        XCTAssertEqual(s.stage(.presenterQueueAge)?.count, 2, "ages recorded only while on")
        _ = r.presenterCommandEnqueued()
        XCTAssertEqual(r.snapshot().gauge(.presenterQueueDepth)?.last, 1, "everything else was processed")
    }

    @MainActor
    func testRealPresenterReportsQueueAgeForEveryCommand() async {
        let sw = StreamDiagnosticsSwitch(enabled: true)
        let r = StreamDiagnosticsRecorder(side: .receiver, windowSeconds: 3600, diagnosticsSwitch: sw, resourceSampler: nil)
        let effects = ReceiverVideoPresenter.OutputEffects(
            decodeViaVideoDecoder: { _, _, _ in }, decodedFrameReady: { _, _ in },
            decodeFlushIncurred: {}, debugFramePresented: {})
        let presenter = ReceiverVideoPresenter(displayLayer: AVSampleBufferDisplayLayer(), outputEffects: effects, diagnostics: r)
        for _ in 0..<5 { presenter.enqueueAdvanceGeneration() }
        let deadline = Date().addingTimeInterval(2)
        while (r.snapshot().stage(.presenterQueueAge)?.count ?? 0) < 5, Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let s = r.snapshot()
        XCTAssertEqual(s.stage(.presenterQueueAge)?.count, 5)
        XCTAssertEqual(s.gauge(.presenterQueueDepth)?.samples, 5)
        XCTAssertGreaterThanOrEqual(s.gauge(.presenterQueueDepth)?.max ?? 0, 1)
    }

    // MARK: - Metric dictionary

    func testMetricDictionaryIsCompleteAndUnique() {
        let all = StreamDiagnosticsMetricDictionary.all
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "metric ids are unique")
        for d in all {
            XCTAssertFalse(d.unit.isEmpty, d.id)
            XCTAssertFalse(d.source.isEmpty, d.id)
            XCTAssertNotNil(d.id.range(of: #"^[a-z]+(\.[a-z0-9_]+)+$"#, options: .regularExpression), d.id)
        }
        // Every stage that compares two clocks says so.
        XCTAssertEqual(DiagnosticsStage.mappedSubmitToReceive.definition.timebase, .wallClockMapped)
        XCTAssertTrue(DiagnosticsStage.wireSubmitToSend.definition.caveat.contains("encoder submission"))
    }

    func testDocsListEveryMetricAndThreshold() throws {
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/performance/diagnostics.md")
        let text = try String(contentsOf: docs, encoding: .utf8)
        for d in StreamDiagnosticsMetricDictionary.all {
            XCTAssertTrue(text.contains("`\(d.id)`"), "docs/performance/diagnostics.md is missing \(d.id)")
        }
        for name in StreamBottleneckClassifier.thresholds.keys {
            XCTAssertTrue(text.contains("`\(name)`"), "docs/performance/diagnostics.md is missing threshold \(name)")
        }
        for cause in StreamBottleneckCause.allCases {
            XCTAssertTrue(text.contains("`\(cause.rawValue)`"), "docs/performance/diagnostics.md is missing verdict \(cause.rawValue)")
        }
        XCTAssertTrue(text.contains("schemaVersion"))
    }

    // MARK: - Presentation

    func testRowsShowOnlyThisSidesMeasuredStages() {
        let (r, _) = makeRecorder()
        r.recordSubmit(origin: .live, sourceKey: 1, sourceAgeMs: 4, pendingEncodes: 1, at: 0)
        r.recordEncodeOutput(durationMs: 7, bytes: 10, keyframe: false, outcome: .sent, at: 1)
        let rows = StreamDiagnosticsPresentation.rows(for: r.snapshot(at: 2))
        XCTAssertEqual(rows.map(\.id), [DiagnosticsStage.sourceAgeAtSubmit.definition.id, DiagnosticsStage.encode.definition.id])
        XCTAssertEqual(rows[1].p50, "7.0")
        XCTAssertTrue(StreamDiagnosticsPresentation.label(for: .wireSubmitToSend).contains("overlay \"encode\""))
        XCTAssertTrue(StreamDiagnosticsPresentation.label(for: .mappedSubmitToReceive).contains("overlay \"latency\""))
    }
}
