// Performance Lab (#123): the run controller on the Mac.
//
// start → (operator setup, "Ready") → for each trial: (operator steps,
// "Ready") → warm-up → whole diagnostics windows → trial record → … →
// manifest + trials written as a run bundle.
//
// It only reads: the session's diagnostics recorder (whole completed
// windows), the receiver's `diag` summaries that recorder already holds, and
// the fixture window's own draw counts. It never sends input, changes a
// display, the stream or power state: steps that need a person are shown
// as prompts. `tick()` is driven by a timer in the app and directly by tests
// and the synthetic self-test (injected clock).

import Foundation

/// The fixture window's own measurement, if it is open in this app.
@MainActor
protocol PerformanceLabFixtureMeasuring: AnyObject {
    func beginMeasurement()
    func endMeasurement() -> PerformanceLabFixtureRecord?
}

@MainActor
final class PerformanceLabRunController: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// Waiting for "Ready" after the shown steps (before the run or a trial).
        case waitingForOperator(trial: Int?, steps: [String])
        case warmingUp(trial: Int, remainingSeconds: Int)
        case measuring(trial: Int, windows: Int, of: Int)
        case finished(folder: URL)
        case failed(PerformanceLabRunFailure)
        case cancelled(folder: URL?)
    }

    struct Dependencies {
        /// The streaming session's sender recorder; nil when nothing streams.
        var recorder: @MainActor () -> StreamDiagnosticsRecorder?
        var diagnosticsEnabled: @MainActor () -> Bool
        var nowMs: @MainActor () -> Double
        var now: @MainActor () -> Date
        var build: StreamDiagnosticsBuildInfo
        var commit: String?
        var outputParent: URL
        var fixture: @MainActor () -> PerformanceLabFixtureMeasuring?
    }

    @Published private(set) var phase: Phase = .idle
    /// During-trial prompts that are due now (newest last).
    @Published private(set) var prompts: [String] = []
    @Published private(set) var completedTrials: [PerformanceLabTrialRecord] = []

    private(set) var plan: PerformanceLabRunPlan?
    private let deps: Dependencies
    private var trialIndex = 0
    private var warmUpEndsMs: Double?
    private var collector: PerformanceLabTrialCollector?
    private var fixtureMeasuring = false
    private var environmentContext: StreamDiagnosticsContext?

    init(dependencies: Dependencies) {
        deps = dependencies
    }

    var isRunning: Bool {
        switch phase {
        case .waitingForOperator, .warmingUp, .measuring: return true
        default: return false
        }
    }

    func start(_ plan: PerformanceLabRunPlan) {
        guard !isRunning else { return }
        self.plan = plan
        trialIndex = 0
        completedTrials = []
        prompts = []
        environmentContext = nil
        collector = nil
        warmUpEndsMs = nil
        let setup = plan.scenario.steps(.beforeRun).map(\.instruction)
        phase = .waitingForOperator(trial: nil, steps: setup)
    }

    /// The operator pressed Ready.
    func operatorReady() {
        guard case .waitingForOperator(let trial, _) = phase, let plan else { return }
        if trial == nil {
            beginTrial(1, plan: plan)
        } else {
            startWarmUp()
        }
    }

    func cancel() {
        guard isRunning, let plan else { return }
        if let collector {
            completedTrials.append(collector.record(forcedStatus: .cancelled, fixture: endFixture()))
            completedTrials[completedTrials.count - 1].issues.append(.cancelledByOperator)
        }
        collector = nil
        let folder = completedTrials.isEmpty ? nil : try? writeBundle(plan)
        phase = .cancelled(folder: folder)
    }

    private func beginTrial(_ index: Int, plan: PerformanceLabRunPlan) {
        trialIndex = index
        prompts = []
        let steps = plan.scenario.steps(.beforeEachTrial).map(\.instruction)
        if steps.isEmpty {
            startWarmUp()
        } else {
            phase = .waitingForOperator(trial: index, steps: steps)
        }
    }

    private func startWarmUp() {
        guard let plan else { return }
        warmUpEndsMs = deps.nowMs() + plan.scenario.warmUpSeconds * 1000
        phase = .warmingUp(trial: trialIndex, remainingSeconds: Int(plan.scenario.warmUpSeconds.rounded(.up)))
    }

    /// Called about twice a second while a run is active.
    func tick() {
        guard let plan else { return }
        let now = deps.nowMs()
        switch phase {
        case .warmingUp:
            guard let ends = warmUpEndsMs else { return }
            if failTrialIfUnavailable(plan) { return }
            if now >= ends {
                collector = PerformanceLabTrialCollector(scenario: plan.scenario, trialIndex: trialIndex,
                                                         synthetic: plan.synthetic, armedAtMs: ends)
                if let fixture = deps.fixture() {
                    fixture.beginMeasurement()
                    fixtureMeasuring = true
                }
                phase = .measuring(trial: trialIndex, windows: 0, of: plan.scenario.trialWindows)
                tick()
            } else {
                phase = .warmingUp(trial: trialIndex, remainingSeconds: Int(((ends - now) / 1000).rounded(.up)))
            }
        case .measuring:
            guard var collector else { return }
            if failTrialIfUnavailable(plan) { return }
            collector.ingest(deps.recorder()?.completedWindowForLab(at: now), at: now)
            if environmentContext == nil, let first = collector.windows.first {
                environmentContext = first.snapshot.context
            }
            updatePrompts(collector: collector, plan: plan, nowMs: now)
            self.collector = collector
            if collector.isDone {
                finishTrial(collector.record(fixture: endFixture()), plan: plan)
            } else if collector.hasStalled(at: now) {
                var stalled = collector
                stalled.note(.stalled)
                finishTrial(stalled.record(fixture: endFixture()), plan: plan)
            } else {
                phase = .measuring(trial: trialIndex, windows: collector.windows.count, of: plan.scenario.trialWindows)
            }
        default:
            return
        }
    }

    /// Diagnostics off or no session: this trial fails, the run goes on.
    private func failTrialIfUnavailable(_ plan: PerformanceLabRunPlan) -> Bool {
        let issue: PerformanceLabTrialIssue
        if !deps.diagnosticsEnabled() {
            issue = .diagnosticsOff
        } else if deps.recorder() == nil {
            issue = .noSession
        } else {
            return false
        }
        var failed = collector ?? PerformanceLabTrialCollector(scenario: plan.scenario, trialIndex: trialIndex,
                                                               synthetic: plan.synthetic, armedAtMs: deps.nowMs())
        failed.note(issue)
        finishTrial(failed.record(forcedStatus: .failed, fixture: endFixture()), plan: plan)
        return true
    }

    private func updatePrompts(collector: PerformanceLabTrialCollector, plan: PerformanceLabRunPlan, nowMs: Double) {
        // During-trial prompts count from the end of the warm-up.
        let elapsed = (nowMs - collector.armedAtMs) / 1000
        prompts = plan.scenario.steps(.duringTrial).filter { ($0.atSecond ?? 0) <= elapsed }.map(\.instruction)
    }

    private func endFixture() -> PerformanceLabFixtureRecord? {
        guard fixtureMeasuring else { return nil }
        fixtureMeasuring = false
        return deps.fixture()?.endMeasurement()
    }

    private func finishTrial(_ record: PerformanceLabTrialRecord, plan: PerformanceLabRunPlan) {
        var record = record
        if record.fixture == nil, !plan.synthetic, !record.issues.contains(.fixtureNotOpen) {
            // Informational: frame IDs on the receiver still work if the
            // fixture runs elsewhere, but this app could not count draws.
            record.issues.append(.fixtureNotOpen)
            record.issues = PerformanceLabTrialIssue.allCases.filter { record.issues.contains($0) }
        }
        completedTrials.append(record)
        collector = nil
        warmUpEndsMs = nil
        prompts = []
        if trialIndex < plan.trials {
            beginTrial(trialIndex + 1, plan: plan)
        } else {
            do {
                phase = .finished(folder: try writeBundle(plan))
            } catch {
                phase = .failed(.couldNotWrite)
            }
        }
    }

    private func writeBundle(_ plan: PerformanceLabRunPlan) throws -> URL {
        let environment = PerformanceLabEnvironment(sender: deps.build, commit: PerformanceLabRunPlan.sanitizedCommit(deps.commit),
                                                    context: environmentContext)
        let manifest = PerformanceLabRunManifest(plan: plan, environment: environment, trials: completedTrials, createdAt: deps.now())
        return try PerformanceLabBundle.write(manifest: manifest, trials: completedTrials, under: deps.outputParent)
    }
}

enum PerformanceLabRunFailure: String, Equatable, Sendable {
    case couldNotWrite
}

/// A one-command start request (tools/perf-lab `start`, or the launch
/// argument): `scenario=<id>;trials=<n>[;variant=<label>][;commit=<sha>]`.
/// Strict: unknown keys, an unknown scenario or too few trials are rejected.
struct PerformanceLabStartRequest: Equatable, Sendable {
    var plan: PerformanceLabRunPlan
    var commit: String?

    static func parse(_ raw: String) -> PerformanceLabStartRequest? {
        guard raw.count <= 256 else { return nil }
        var fields: [String: String] = [:]
        for part in raw.split(separator: ";", omittingEmptySubsequences: true) {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, ["scenario", "trials", "variant", "commit"].contains(kv[0]), fields[kv[0]] == nil else { return nil }
            fields[kv[0]] = kv[1]
        }
        guard let scenario = fields["scenario"] else { return nil }
        var trials = PerformanceLabRunPlan.defaultTrials
        if let t = fields["trials"] {
            guard let n = Int(t) else { return nil }
            trials = n
        }
        var commit: String?
        if let c = fields["commit"] {
            guard let sanitized = PerformanceLabRunPlan.sanitizedCommit(c) else { return nil }
            commit = sanitized
        }
        guard let plan = try? PerformanceLabRunPlan.make(scenarioID: scenario, trials: trials, variant: fields["variant"]) else { return nil }
        return PerformanceLabStartRequest(plan: plan, commit: commit)
    }
}
