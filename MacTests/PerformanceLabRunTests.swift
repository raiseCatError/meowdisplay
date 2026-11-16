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
        // Quiet for over two windows: the recorder reports an empty window, not contiguous.
        t += 11_000
        c.ingest(r.completedWindowForLab(at: t), at: t)
        r.noteGeneration(2, at: t)
        let rec = c.record(fixture: nil)
        XCTAssertEqual(rec.status, .incomplete)
        XCTAssertTrue(rec.issues.contains(.windowGap))
        XCTAssertTrue(rec.issues.contains(.missingWindows))
        XCTAssertTrue(rec.issues.contains(.noReceiverSummary))
    }

    func testReceiverSummariesAreKeptOnlyOnceAFullWindowIntoTheTrial() {
        let r = recorder()
        var c = PerformanceLabTrialCollector(scenario: scenario(windows: 4), trialIndex: 1, synthetic: true, armedAtMs: 0)
        var t = 0.0
        var arrival = 50.0
        while !c.isDone, t < 40_000 {
            t += 500
            r.markInterval(.submitInterval, at: t)
            if t.truncatingRemainder(dividingBy: 2500) == 0 {
                var s = StreamDiagnosticsPeerSummary(side: .receiver)
                arrival += 1
                s.arrivalFPS = arrival
                r.updatePeer(s)
            }
            c.ingest(r.completedWindowForLab(at: t), at: t)
        }
        let rec = c.record(fixture: nil)
        XCTAssertFalse(rec.receiverSummaries.isEmpty)
        XCTAssertTrue(rec.receiverSummaries.allSatisfy { $0.offsetSeconds >= 5 })
        XCTAssertEqual(Set(rec.receiverSummaries.map { $0.summary.arrivalFPS }).count, rec.receiverSummaries.count, "no repeats")
        XCTAssertFalse(rec.issues.contains(.noReceiverSummary))
    }

    func testExpectedRestartsDoNotMakeATrialIncomplete() {
        for restarts in [false, true] {
            let r = recorder()
            r.noteGeneration(1, at: 0)
            var c = PerformanceLabTrialCollector(scenario: scenario(windows: 1, restarts: restarts), trialIndex: 1, synthetic: true, armedAtMs: 0)
            r.noteGeneration(2, at: 1000)
            r.markInterval(.submitInterval, at: 1500)
            c.ingest(r.completedWindowForLab(at: 6100), at: 6100)
            XCTAssertEqual(c.record(fixture: nil).issues.contains(.unexpectedRestart), !restarts)
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
        XCTAssertEqual(trial3.windows.count, 3)
        XCTAssertGreaterThanOrEqual(trial3.receiverSummaries.count, 1)
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
        "drawnFrames", "drawInterval", "sum", "min", "buckets", "frameIDReadCount", "frameIDUniqueFPS",
        "frameIDDuplicates", "frameIDMissing", "frameIDUnreadable", "frameIDIntervalP95Ms",
    ]
    private static let exportKeys: Set<String> = [
        "appVersion", "osMajor", "osMinor", "osPatch", "platform", "deviceClass", "windowIsPartial", "sessionCounters",
        "rttJitterMs", "peer", "resources", "gauges", "id", "count", "ratePerSecond", "p50", "p95", "p99", "max", "mean",
        "gapsOver100ms", "gapsOver250ms", "gapsOver500ms", "last", "samples", "displayMode", "codec", "rasterWidth",
        "rasterHeight", "targetFPS", "sourceRefreshHz", "encoderInFlightLimit", "route", "networkProtocol",
        "pathExpensive", "pathConstrained", "presentationPath", "clockOffsetKnown", "cause", "confidence", "reason",
        "evidence", "alternatives", "frameBudgetMs", "metric", "value", "comparison", "threshold", "met", "fromPeer",
        "captureCompleteFPS", "captureIdleShare", "submitFPS", "duplicateSubmitFPS", "encodeP50Ms", "encodeP95Ms",
        "sourceAgeP95Ms", "sendP95Ms", "encoderBusyShare", "sendBackpressureShare", "composeP95Ms", "composeFPS",
        "arrivalFPS", "arrivalP50Ms", "arrivalP95Ms", "arrivalGapsOver250ms", "enqueueFPS", "presenterQueueAgeP95Ms",
        "presenterQueueDepthMax", "decodeP95Ms", "decodeSamples", "rttMs", "processCPUPercent", "memoryFootprintMB",
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
        // Every string a bundle may hold is a constant from code.
        let scenarios = PerformanceLabScenarioCatalog.all + [PerformanceLabScenarioCatalog.synthetic]
        var constants = Set(scenarios.flatMap { [$0.id, $0.caption, $0.purpose, $0.mode.rawValue, $0.panes.rawValue, $0.workload.rawValue]
            + $0.steps.flatMap { [$0.instruction, $0.timing.rawValue] } + $0.primaryMetrics.map(\.rawValue) })
        constants.formUnion(PerformanceLabWorkload.catalog.flatMap { [$0.signature, $0.id.rawValue] + $0.cycle.map(\.kind.rawValue) })
        constants.formUnion(StreamDiagnosticsMetricDictionary.all.flatMap { [$0.id, $0.unit, $0.source, $0.caveat, $0.timebase.rawValue] })
        constants.formUnion(PerformanceLabRunManifest.limitationsText)
        constants.formUnion(PerformanceLabTrialIssue.allCases.map(\.rawValue))
        constants.formUnion(["complete", "incomplete", "failed", "cancelled", PerformanceLabRunManifest.format, PerformanceLabTrialRecord.format,
                             "synthetic", "2026-11-17T00:00:00Z"])
        constants.formUnion(["sender", "receiver", "mirror", "extend", "window", "unknown", "h264", "hevc", "usb", "awdl", "lan", "remote",
                             "tcp", "quic", "displayLayer", "metal", "nominal", "fair", "serious", "critical", "unplugged", "charging",
                             "full", "none", "low", "medium", "high", "atLeast", "below", "macOS", "iOS", "mac", "iPhone", "iPad",
                             "windowTooShort", "noTargetFrameRate", "tooFewSamples", "sourceIdle", "conflictingEvidence"])
        constants.formUnion(StreamBottleneckCause.allCases.map(\.rawValue))
        constants.formUnion(metricIDs.union(StreamBottleneckClassifier.derivedIDs).union(metricIDs.map { $0 + ".p50" }))

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
