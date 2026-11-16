import XCTest

/// Golden files under tools/perf-lab/tests/golden and tools/perf-lab.
/// `PERF_LAB_UPDATE_GOLDEN=1` rewrites them (review the diff before committing).
enum PerformanceLabGolden {
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let toolDir = repoRoot.appendingPathComponent("tools/perf-lab")
    static let goldenDir = toolDir.appendingPathComponent("tests/golden")
    static var updating: Bool { ProcessInfo.processInfo.environment["PERF_LAB_UPDATE_GOLDEN"] == "1" }

    static func check(_ data: Data, against url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        if updating {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return
        }
        let expected = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), String(decoding: expected, as: UTF8.self),
                       "\(url.lastPathComponent) differs from the golden file; if intended, rerun with PERF_LAB_UPDATE_GOLDEN=1",
                       file: file, line: line)
    }
}

/// Workload schedule determinism and the scenario/run model (#123).
final class PerformanceLabScenarioTests: XCTestCase {

    // MARK: Workloads

    func testWorkloadSignaturesArePinned() {
        // A change here changes the pixels: bump the workload version.
        XCTAssertEqual(PerformanceLabWorkload.catalog.map(\.signature), [
            "frame-counter@1:counter/60",
            "static-to-motion@1:still/4,highMotion/4",
            "scrolling-text@1:scrollingText/60",
            "high-motion@1:highMotion/60",
            "cursor-target@1:cursorTarget/60",
            "idle@1:still/60",
        ])
        XCTAssertEqual(Set(PerformanceLabWorkload.catalog.map(\.id)), Set(PerformanceLabWorkloadID.allCases))
    }

    func testScheduleIsDeterministicAndFollowsTheCycle() {
        let w = PerformanceLabWorkload.workload(.staticToMotion)
        XCTAssertEqual(w.plan(atSeconds: 0).kind, .still)
        XCTAssertFalse(w.plan(atSeconds: 3.99).animates)
        XCTAssertEqual(w.plan(atSeconds: 4).kind, .highMotion)
        XCTAssertEqual(w.plan(atSeconds: 4).segmentOrdinal, 1)
        XCTAssertEqual(w.plan(atSeconds: 8).kind, .still)
        XCTAssertEqual(w.plan(atSeconds: 8).segmentOrdinal, 2)
        XCTAssertEqual(w.plan(atSeconds: 803.5).segmentOrdinal, 200)
        for t in stride(from: 0.0, to: 30, by: 0.37) {
            XCTAssertEqual(w.plan(atSeconds: t), w.plan(atSeconds: t))
        }
    }

    func testScrollingAndTargetMotionAreFixedFunctionsOfTime() {
        let text = PerformanceLabWorkload.workload(.scrollingText)
        XCTAssertEqual(text.plan(atSeconds: 2).scrollOffsetPoints, 240, accuracy: 1e-9)
        XCTAssertEqual(text.plan(atSeconds: 62).scrollOffsetPoints, 240, accuracy: 1e-9, "restarts each lap")
        let cursor = PerformanceLabWorkload.workload(.cursorTarget)
        for t in stride(from: 0.0, to: 8, by: 0.1) {
            let p = cursor.plan(atSeconds: t)
            XCTAssertTrue((0.0999...0.9001).contains(p.targetX) && (0.0999...0.9001).contains(p.targetY))
        }
        XCTAssertEqual(cursor.plan(atSeconds: 1).targetX, cursor.plan(atSeconds: 5).targetX, accuracy: 1e-9, "4 s lap")
    }

    func testGeneratedContentIsDeterministic() {
        XCTAssertEqual(PerformanceLabWorkload.textLines(count: 50), PerformanceLabWorkload.textLines(count: 50))
        XCTAssertEqual(PerformanceLabWorkload.textLines(count: 3).first?.prefix(6), "0000  ")
        let a = (0..<144).map { PerformanceLabWorkload.motionCell(frameID: 41, cell: $0, palette: 8) }
        let b = (0..<144).map { PerformanceLabWorkload.motionCell(frameID: 41, cell: $0, palette: 8) }
        let c = (0..<144).map { PerformanceLabWorkload.motionCell(frameID: 42, cell: $0, palette: 8) }
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c, "every frame differs")
        var rng = PerformanceLabRandom(seed: 1)
        XCTAssertEqual(rng.next(), 0x910A_2DEC_8902_5CC1, "SplitMix64 reference value")
    }

    // MARK: Scenarios and plans

    func testCatalogIsCompleteAndWellFormed() {
        let all = PerformanceLabScenarioCatalog.all
        XCTAssertEqual(Set(all.map(\.id)).count, all.count, "unique ids")
        XCTAssertEqual(Set(all.map(\.mode)), Set(PerformanceLabMode.allCases))
        XCTAssertEqual(Set(all.filter { $0.mode == .window }.map(\.panes)), [.single, .multiple, .floating])
        for s in all + [PerformanceLabScenarioCatalog.synthetic] {
            XCTAssertGreaterThan(s.warmUpSeconds, 0, s.id)
            XCTAssertGreaterThanOrEqual(s.trialWindows, 3, s.id)
            XCTAssertFalse(s.primaryMetrics.isEmpty, s.id)
            XCTAssertFalse(s.steps(.beforeRun).isEmpty, s.id)
            for step in s.steps(.duringTrial) {
                let at = try? XCTUnwrap(step.atSecond)
                XCTAssertNotNil(at)
                XCTAssertLessThan(at ?? .infinity, s.measuredSeconds, "\(s.id): prompt after the trial ends")
            }
        }
        XCTAssertGreaterThanOrEqual(all.first { $0.id == "extend.sustained" }?.measuredSeconds ?? 0, 600)
        // Scenarios the brief requires.
        for id in ["mirror.frame-counter", "extend.frame-counter", "window.single-pane", "window.multiple-panes",
                   "window.floating-pane", "mirror.static-to-motion", "extend.scrolling-text", "mirror.high-motion",
                   "extend.rapid-interaction", "extend.reconnection", "extend.capture-retune",
                   "extend.transition-cleanup", "extend.sustained"] {
            XCTAssertNotNil(PerformanceLabScenarioCatalog.scenario(id: id), id)
        }
    }

    func testRunPlanEnforcesTheMinimumTrials() throws {
        XCTAssertThrowsError(try PerformanceLabRunPlan.make(scenarioID: "mirror.frame-counter", trials: 2)) {
            XCTAssertEqual($0 as? PerformanceLabRunPlan.ValidationError, .tooFewTrials(minimum: 3))
        }
        XCTAssertThrowsError(try PerformanceLabRunPlan.make(scenarioID: "mirror.frame-counter", trials: 21))
        XCTAssertThrowsError(try PerformanceLabRunPlan.make(scenarioID: "no.such"))
        let plan = try PerformanceLabRunPlan.make(scenarioID: "mirror.frame-counter")
        XCTAssertEqual(plan.trials, 3)
        XCTAssertFalse(plan.synthetic)
        XCTAssertTrue(try PerformanceLabRunPlan.make(scenarioID: PerformanceLabScenarioCatalog.synthetic.id).synthetic)
    }

    func testVariantAndCommitAreSanitized() {
        XCTAssertEqual(PerformanceLabRunPlan.sanitizedVariant("Beta ON!"), "betaon")
        XCTAssertEqual(PerformanceLabRunPlan.sanitizedVariant("/Users/me/x"), "usersmex")
        XCTAssertNil(PerformanceLabRunPlan.sanitizedVariant("!!!"))
        XCTAssertEqual(PerformanceLabRunPlan.sanitizedVariant(String(repeating: "a", count: 40))?.count, 24)
        XCTAssertEqual(PerformanceLabRunPlan.sanitizedCommit("4C0E8067"), "4c0e8067")
        XCTAssertNil(PerformanceLabRunPlan.sanitizedCommit("main"))
        XCTAssertNil(PerformanceLabRunPlan.sanitizedCommit("abc"))
        XCTAssertNil(PerformanceLabRunPlan.sanitizedCommit(String(repeating: "a", count: 41)))
    }

    @MainActor
    func testStartRequestParsingIsStrict() {
        let ok = PerformanceLabStartRequest.parse("scenario=extend.idle;trials=4;variant=beta-on;commit=4c0e8067")
        XCTAssertEqual(ok?.plan.scenario.id, "extend.idle")
        XCTAssertEqual(ok?.plan.trials, 4)
        XCTAssertEqual(ok?.plan.variant, "beta-on")
        XCTAssertEqual(ok?.commit, "4c0e8067")
        XCTAssertEqual(PerformanceLabStartRequest.parse("scenario=extend.idle")?.plan.trials, 3)
        XCTAssertNil(PerformanceLabStartRequest.parse("scenario=extend.idle;trials=2"), "below the minimum")
        XCTAssertNil(PerformanceLabStartRequest.parse("scenario=nope"))
        XCTAssertNil(PerformanceLabStartRequest.parse("scenario=extend.idle;host=x"), "unknown key")
        XCTAssertNil(PerformanceLabStartRequest.parse("scenario=extend.idle;scenario=mirror.high-motion"))
        XCTAssertNil(PerformanceLabStartRequest.parse("scenario=extend.idle;commit=main"))
        XCTAssertNil(PerformanceLabStartRequest.parse(String(repeating: "x", count: 300)))
    }

    /// tools/perf-lab/scenarios.json: what the analysis tool and its `start`
    /// command read. Generated from the Swift catalog; checked here.
    func testScenarioCatalogJSONMatchesTheTool() throws {
        struct FrameIDLayout: Codable {
            var version = PerformanceLabFrameIDCodec.version
            var stripModules = PerformanceLabFrameIDCodec.stripModules
            var codeModules = PerformanceLabFrameIDCodec.codeModules
            var counterBits = PerformanceLabFrameIDCodec.counterBits
        }
        struct Catalog: Codable {
            var catalogVersion = PerformanceLabScenarioCatalog.version
            var windowSeconds = PerformanceLabScenarioCatalog.windowSeconds
            var minimumTrials = PerformanceLabRunPlan.minimumTrials
            var analysisMetrics = PerformanceLabAnalysisMetric.allCases.map(\.rawValue)
            var scenarios = PerformanceLabScenarioCatalog.all
            var synthetic = PerformanceLabScenarioCatalog.synthetic
            var workloads = PerformanceLabWorkload.catalog
            var workloadSignatures = PerformanceLabWorkload.catalog.map(\.signature)
            var frameID = FrameIDLayout()
        }
        let data = try PerformanceLabBundle.encoder().encode(Catalog())
        try PerformanceLabGolden.check(data + Data("\n".utf8), against: PerformanceLabGolden.toolDir.appendingPathComponent("scenarios.json"))
    }
}
