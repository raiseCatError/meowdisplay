import XCTest

/// SIMULATION tests: properties of `AdaptiveStreamingController` over the
/// scripted plant in `AdaptiveStreamingSimulation.swift`, plus the
/// comparison report. None of this is hardware evidence.
final class AdaptiveStreamingSimulationTests: XCTestCase {
    private static let seeds: [UInt64] = [1, 2, 3, 4]

    private func scenariosWithSeeds() -> [AdaptiveSimulationScenario] {
        AdaptiveSimulationScenario.all.flatMap { scenario in
            Self.seeds.map { seed in
                var copy = scenario
                copy.noiseSeed = seed &+ scenario.noiseSeed
                return copy
            }
        }
    }

    // MARK: - Properties over every scenario

    func testAtMostOneAdaptationChangePerWindow() {
        for scenario in scenariosWithSeeds() {
            let run = AdaptiveSimulation.run(scenario, policy: .adaptive)
            XCTAssertLessThanOrEqual(run.adaptationChangesPerWindow.max() ?? 0, 1, scenario.name)
        }
    }

    func testNoOscillation() {
        for scenario in scenariosWithSeeds() {
            let run = AdaptiveSimulation.run(scenario, policy: .adaptive)
            // 300 s runs: a handful of direction flips at most (each failed
            // probe is two), never a thrash.
            XCTAssertLessThanOrEqual(run.metrics.flips, 8, "\(scenario.name) seed \(scenario.noiseSeed)")
            XCTAssertLessThanOrEqual(run.metrics.changes, 30, "\(scenario.name) seed \(scenario.noiseSeed)")
            XCTAssertLessThanOrEqual(Double(run.metrics.restartClassChanges),
                                     scenario.duration / AdaptiveStreamingThresholds.standard.protectiveRestartIntervalSeconds,
                                     scenario.name)
        }
    }

    func testNeverExceedsTheNegotiatedCeilingOrTheSourceCadence() {
        for scenario in scenariosWithSeeds() {
            let run = AdaptiveSimulation.run(scenario, policy: .adaptive)
            let ceiling = scenario.negotiation.capabilityCeilingFPS
            for point in run.points {
                XCTAssertLessThanOrEqual(point.fps, ceiling, scenario.name)
                XCTAssertLessThanOrEqual(point.fps, scenario.sourceHz, scenario.name)
            }
        }
    }

    func testSaverWindowsStayInsideTheSaverLadder() {
        let ladder = AdaptiveStreamingLadder.standard
        for scenario in scenariosWithSeeds() {
            let run = AdaptiveSimulation.run(scenario, policy: .adaptive)
            let floor = AdaptiveStreamingController(configuration: scenario.controllerConfiguration).rasterFloor
            for (index, point) in run.points.enumerated() where index > 0 {
                let previous = Double(index - 1) * scenario.window
                let now = Double(index) * scenario.window
                guard scenario.dataPolicy(previous) == .saver, scenario.dataPolicy(now) == .saver else { continue }
                XCTAssertLessThanOrEqual(point.bitrate, ladder.saverBitrateTop, scenario.name)
                XCTAssertLessThanOrEqual(point.rasterScale, max(floor, ladder.saverRasterTop) + 1e-9, scenario.name)
                XCTAssertLessThanOrEqual(point.fps, ladder.saverFPSTop, scenario.name)
            }
        }
    }

    func testRasterBelowFloorOnlyAsLastResort() {
        for scenario in scenariosWithSeeds() {
            let run = AdaptiveSimulation.run(scenario, policy: .adaptive)
            let floor = AdaptiveStreamingController(configuration: scenario.controllerConfiguration).rasterFloor
            for decision in run.decisions where decision.isChange {
                guard let point = decision.point, point.rasterScale < floor - 1e-9,
                      decision.changed.contains(.raster),
                      (decision.previous?.rasterScale ?? 1) > point.rasterScale else { continue }
                XCTAssertEqual(decision.reason, .lastResortRasterBelowFloor, scenario.name)
            }
        }
    }

    func testSimulationIsDeterministic() {
        for scenario in AdaptiveSimulationScenario.all {
            for policy in [AdaptiveSimulationPolicy.adaptive, .fixed] {
                let a = AdaptiveSimulation.run(scenario, policy: policy)
                let b = AdaptiveSimulation.run(scenario, policy: policy)
                XCTAssertEqual(a.metrics, b.metrics, scenario.name)
                XCTAssertEqual(a.decisions, b.decisions, scenario.name)
                XCTAssertEqual(a.points, b.points, scenario.name)
            }
        }
    }

    func testTwoReceiversAreIsolated() {
        let (a, b) = AdaptiveSimulationScenario.twoReceivers
        let (pairA, pairB) = AdaptiveSimulation.runPair(a, b)
        let soloA = AdaptiveSimulation.run(a, policy: .adaptive)
        let soloB = AdaptiveSimulation.run(b, policy: .adaptive)
        XCTAssertEqual(pairA.decisions, soloA.decisions)
        XCTAssertEqual(pairB.decisions, soloB.decisions)
        XCTAssertEqual(pairA.metrics, soloA.metrics)
        XCTAssertEqual(pairB.metrics, soloB.metrics)
        // The congested receiver moved down; the healthy one never did.
        XCTAssertTrue(pairB.decisions.contains { $0.action == .downshift })
        XCTAssertFalse(pairA.decisions.contains { $0.action == .downshift })
    }

    // MARK: - Design expectations (directional, model-relative)

    func testSixtyHzSourceIsNeverStreamedAboveSixty() {
        let scenario = AdaptiveSimulationScenario.advertised120Source60
        XCTAssertEqual(AdaptiveSimulation.run(scenario, policy: .adaptive).metrics.secondsAbove60, 0)
        XCTAssertEqual(AdaptiveSimulation.run(scenario, policy: .fixed).metrics.secondsAbove60, scenario.duration,
                       "today's fixed policy targets 120 from a 60 Hz source")
        let window = AdaptiveSimulationScenario.windowViewMultiPane
        XCTAssertEqual(AdaptiveSimulation.run(window, policy: .adaptive).metrics.secondsAbove60, 0)
    }

    func testHighRefreshIsReachedOnlyWithHeadroom() {
        let run = AdaptiveSimulation.run(.proMotion120WithHeadroom, policy: .adaptive)
        XCTAssertGreaterThan(run.metrics.secondsAbove60, 0)
        XCTAssertEqual(run.points.first?.fps, 60, "60 first")
    }

    func testIdleSourceCausesNoDownshift() {
        let scenario = AdaptiveSimulationScenario.idleToMotion
        let run = AdaptiveSimulation.run(scenario, policy: .adaptive)
        let idleWindows = Int(200 / scenario.window)
        XCTAssertEqual(Set(run.points.prefix(idleWindows)), [run.points[0]])
    }

    func testStaleRouteCallbacksAndDropoutsAreHeld() {
        let flap = AdaptiveSimulation.run(.routeFlap, policy: .adaptive)
        XCTAssertEqual(flap.decisions.filter { $0.reason == .staleRouteEpoch }.count, 2)
        XCTAssertTrue(flap.decisions.contains { $0.reason == .routeChangeSettling })
        let dropout = AdaptiveSimulation.run(.telemetryDropout, policy: .adaptive)
        XCTAssertTrue(dropout.decisions.contains { $0.reason == .staleTelemetry })
    }

    func testMeteredPathUsesLessDataThanTheFixedPolicy() {
        let adaptive = AdaptiveSimulation.run(.meteredPath, policy: .adaptive)
        let fixed = AdaptiveSimulation.run(.meteredPath, policy: .fixed)
        XCTAssertLessThan(adaptive.metrics.megabytes, fixed.metrics.megabytes)
    }

    // MARK: - Report

    /// Writes the comparison table when `ADAPTIVE_SIM_REPORT` names a file
    /// (pass `TEST_RUNNER_ADAPTIVE_SIM_REPORT=<path>` to xcodebuild).
    func testWriteComparisonReport() throws {
        let report = Self.comparisonReport()
        XCTAssertTrue(report.contains("SIMULATION"))
        guard let path = ProcessInfo.processInfo.environment["ADAPTIVE_SIM_REPORT"], !path.isEmpty else { return }
        try report.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func comparisonReport() -> String {
        func row(_ name: String, _ policy: String, _ m: AdaptiveSimulationMetrics) -> String {
            let final = m.finalPoint
            return "| \(name) | \(policy) | \(String(format: "%.1f", m.deliveredUniqueFPS)) | "
                + "\(String(format: "%.1f", m.stallSeconds)) | \(String(format: "%.0f", m.megabytes)) | "
                + "\(String(format: "%.2f", m.meanRaster)) | \(String(format: "%.0f", m.secondsAbove60)) | "
                + "\(String(format: "%.2f", final.rasterScale))/\(final.bitrate / 1_000_000)/\(final.fps) | "
                + "\(m.changes) | \(m.restartClassChanges) | \(m.flips) |"
        }
        var lines: [String] = []
        lines.append("# Adaptive Automatic streaming: SIMULATION comparison (issue #123)")
        lines.append("")
        lines.append("**SIMULATION, NOT HARDWARE EVIDENCE.** Every number below comes from the deterministic plant")
        lines.append("model in `MacTests/AdaptiveStreamingSimulation.swift`, generated by")
        lines.append("`AdaptiveStreamingSimulationTests.testWriteComparisonReport`. The model's capacities, curves and")
        lines.append("costs are assumptions chosen to make each scenario legible. They are not measurements of any Mac,")
        lines.append("receiver or network, and the table makes no claim about real-world gains.")
        lines.append("")
        lines.append("## Model assumptions")
        lines.append("")
        lines.append("- One step per 2 s window, 300 s per scenario, fixed-seed noise (±3 % capacity and RTT).")
        lines.append("- Source: distinct frames per second never above its refresh; the stream encodes min(target, source).")
        lines.append("- Encoder and decoder: pixel-throughput ceilings (Mpx/s). Above the ceiling, the frame rate falls")
        lines.append("  proportionally and queue age / decode time grow. Thermal `critical` throttles the encoder to 60 %.")
        lines.append("- Link: capacity C(t); the encoder emits bitrate × motion (motion = encoded fps / 60, min 10 %).")
        lines.append("  Demand above C drops frames proportionally, sets send backpressure and inflates RTT; jitter grows")
        lines.append("  with utilisation; frames later than one frame interval are not presented.")
        lines.append("- Thermal: heat rises with encoder utilisation above an equilibrium (nominal < 0.4 ≤ fair < 0.6 ≤")
        lines.append("  serious < 0.8 ≤ critical).")
        lines.append("- Fixed policy = today's Automatic: native raster (1.0), 18 Mbps, today's FPS (`StreamingFPSPolicy`);")
        lines.append("  it ignores data saver and conditions.")
        lines.append("")
        lines.append("Columns: delivered unique FPS (mean, presented distinct frames); stall s (window × share of")
        lines.append("expected unique frames not presented); MB (delivered payload, not billed bytes); mean raster;")
        lines.append("s > 60 FPS; final raster/Mbps/FPS; changes; restart-class (raster) changes; direction flips.")
        lines.append("")
        lines.append("| Scenario | Policy | Uniq FPS | Stall s | MB | Raster | s>60 | Final | Changes | Restarts | Flips |")
        lines.append("|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|")
        for scenario in AdaptiveSimulationScenario.all {
            let adaptive = AdaptiveSimulation.run(scenario, policy: .adaptive)
            let fixed = AdaptiveSimulation.run(scenario, policy: .fixed)
            lines.append(row(scenario.name, "adaptive", adaptive.metrics))
            lines.append(row(scenario.name, "fixed", fixed.metrics))
        }
        let (a, b) = AdaptiveSimulationScenario.twoReceivers
        let (pairA, pairB) = AdaptiveSimulation.runPair(a, b)
        lines.append(row(a.name, "adaptive", pairA.metrics))
        lines.append(row(a.name, "fixed", AdaptiveSimulation.run(a, policy: .fixed).metrics))
        lines.append(row(b.name, "adaptive", pairB.metrics))
        lines.append(row(b.name, "fixed", AdaptiveSimulation.run(b, policy: .fixed).metrics))
        lines.append("")
        lines.append("## Scenarios")
        lines.append("")
        for scenario in AdaptiveSimulationScenario.all + [a, b] {
            lines.append("- **\(scenario.name)**: \(scenario.summary).")
        }
        lines.append("")
        lines.append("## Reading the table")
        lines.append("")
        lines.append("- The adaptive controller starts at today's quality at 60 FPS and only moves on evidence, so on")
        lines.append("  healthy paths the two rows should match (or differ only by confirmed probes).")
        lines.append("- Where the plant is constrained, the adaptive row shows the controller's bounded response; the")
        lines.append("  size of any difference is a property of this model, not a prediction for real devices.")
        lines.append("- Hardware validation is PENDING (see `docs/performance/adaptive-streaming.md`).")
        return lines.joined(separator: "\n") + "\n"
    }
}
