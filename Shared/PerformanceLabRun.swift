// Performance Lab (#123): trial collection and the run bundle.
//
// A trial is made of whole diagnostics windows: the first window that
// starts after the warm-up ends, and the next `trialWindows − 1` windows.
// Warm-up data can never leak into a trial, and the numbers cover exactly
// the windows listed. Sender histograms are merged bucket by bucket, so the
// trial's percentiles are exact to the bucket (same rule as
// DiagnosticsHistogram). The receiver side comes from the optional `diag`
// summaries the receiver sent during the trial (its own 5 s windows, not
// aligned with the sender's), kept as received.
//
// A run bundle is a folder: manifest.json + trial-NN.json, every trial
// written whatever its status. Pure Foundation, compiled into every app
// target and into MacTests.

import Foundation

enum PerformanceLabTrialStatus: String, Codable, Sendable {
    case complete, incomplete, failed, cancelled
}

/// Why a trial is not `complete`. Fixed values, no free text.
enum PerformanceLabTrialIssue: String, Codable, Sendable, CaseIterable {
    /// Fewer windows than requested were collected.
    case missingWindows
    /// A window was skipped between two reads or windows were not contiguous.
    case windowGap
    /// Capture/presentation restarted in a scenario that does not expect it.
    case unexpectedRestart
    /// The receiver sent no diagnostics summary during the trial.
    case noReceiverSummary
    /// No streaming session (or it ended).
    case noSession
    /// Diagnostics were off on this Mac.
    case diagnosticsOff
    /// No new window for three window lengths: the stream stopped.
    case stalled
    case cancelledByOperator
    /// The fixture window was not open in this app during the trial.
    case fixtureNotOpen
}

/// A merged histogram: exact counts per fixed bucket over the trial.
struct PerformanceLabHistogramRecord: Codable, Equatable, Sendable {
    var id: String
    var count: Int
    var sum: Double
    var min: Double
    var max: Double
    /// Counts per bucket; edges in the manifest's `histogramUpperEdgesMs` plus an overflow bucket.
    var buckets: [Int]
    /// Same rule as DiagnosticsHistogram: bucket upper edge, clamped to [min, max].
    var p50: Double
    var p95: Double
    var p99: Double

    init(id: String, merging histograms: [DiagnosticsHistogram]) {
        self.id = id
        var buckets = [Int](repeating: 0, count: DiagnosticsHistogram.bucketCount)
        var count = 0, sum = 0.0, lo = Double.infinity, hi = 0.0
        for h in histograms where h.count > 0 {
            for (i, n) in h.buckets.enumerated() { buckets[i] += Int(n) }
            count += h.count
            sum += h.sum
            lo = Swift.min(lo, h.min)
            hi = Swift.max(hi, h.max)
        }
        self.buckets = buckets
        self.count = count
        self.sum = sum
        min = count > 0 ? lo : 0
        max = hi
        p50 = Self.percentile(0.5, buckets: buckets, count: count, min: min, max: max)
        p95 = Self.percentile(0.95, buckets: buckets, count: count, min: min, max: max)
        p99 = Self.percentile(0.99, buckets: buckets, count: count, min: min, max: max)
    }

    static func percentile(_ p: Double, buckets: [Int], count: Int, min: Double, max: Double) -> Double {
        guard count > 0 else { return 0 }
        let rank = Swift.max(1, Int((Double(count) * Swift.min(Swift.max(p, 0), 1)).rounded(.up)))
        var seen = 0
        let edges = DiagnosticsHistogram.upperEdgesMs
        for (i, n) in buckets.enumerated() {
            seen += n
            if seen >= rank {
                let edge = i < edges.count ? edges[i] : max
                return Swift.max(Swift.min(edge, max), min)
            }
        }
        return max
    }
}

struct PerformanceLabWindowRecord: Codable, Equatable, Sendable {
    var sequence: Int
    /// Window start relative to the trial's first window (s).
    var offsetSeconds: Double
    var durationSeconds: Double
    var snapshot: StreamDiagnosticsSnapshot
    var verdict: StreamDiagnosticsVerdict
}

struct PerformanceLabReceiverObservation: Codable, Equatable, Sendable {
    /// When the summary arrived, relative to the trial's first window (s).
    var offsetSeconds: Double
    var summary: StreamDiagnosticsPeerSummary
}

/// What the fixture window itself drew while the trial measured.
struct PerformanceLabFixtureRecord: Codable, Equatable, Sendable {
    var workloadSignature: String
    var seconds: Double
    var drawnFrames: Int
    /// Interval between drawn (changed) frames.
    var drawInterval: PerformanceLabHistogramRecord
}

struct PerformanceLabTrialRecord: Codable, Equatable, Sendable {
    static let format = "meowdisplay-performance-lab-trial"
    static let currentSchemaVersion = 1

    var format: String = Self.format
    var schemaVersion: Int = Self.currentSchemaVersion
    var synthetic: Bool
    var scenarioID: String
    var trialIndex: Int
    var status: PerformanceLabTrialStatus
    var issues: [PerformanceLabTrialIssue]
    var warmUpSeconds: Double
    var requestedWindows: Int
    /// Sum of the listed windows' durations.
    var measuredSeconds: Double
    var windows: [PerformanceLabWindowRecord]
    /// Sender stages with at least one sample, merged over the windows.
    var stages: [PerformanceLabHistogramRecord]
    /// Sender counters summed over the windows, by metric id.
    var counters: [String: Int64]
    /// Interval-stage gaps over 100/250/500 ms summed over the windows.
    var gaps: [String: [Int]]
    var receiverSummaries: [PerformanceLabReceiverObservation]
    var fixture: PerformanceLabFixtureRecord?

    static func fileName(index: Int) -> String { String(format: "trial-%02d.json", index) }
}

// MARK: - Collector

/// Builds one trial from successive `completedWindowForLab` reads. Pure:
/// the caller supplies every read and the time.
struct PerformanceLabTrialCollector: Sendable {
    let scenario: PerformanceLabScenario
    let trialIndex: Int
    let synthetic: Bool
    /// Warm-up end on the recorder's clock: windows starting earlier are ignored.
    let armedAtMs: Double

    private(set) var windows: [StreamDiagnosticsCompletedWindow] = []
    private(set) var issues: Set<PerformanceLabTrialIssue> = []
    private(set) var observations: [PerformanceLabReceiverObservation] = []
    private var lastSequence: UInt64?
    private var lastPeer: StreamDiagnosticsPeerSummary?
    private var lastProgressMs: Double

    init(scenario: PerformanceLabScenario, trialIndex: Int, synthetic: Bool, armedAtMs: Double) {
        self.scenario = scenario
        self.trialIndex = trialIndex
        self.synthetic = synthetic
        self.armedAtMs = armedAtMs
        lastProgressMs = armedAtMs
    }

    var isDone: Bool { windows.count >= scenario.trialWindows }
    var firstWindowStartMs: Double? { windows.first?.startMs }

    /// No new window for this long = the stream stopped.
    var stallLimitMs: Double { 3 * PerformanceLabScenarioCatalog.windowSeconds * 1000 + armedWindowSlackMs }
    private var armedWindowSlackMs: Double { PerformanceLabScenarioCatalog.windowSeconds * 1000 }

    func hasStalled(at nowMs: Double) -> Bool { !isDone && nowMs - lastProgressMs > stallLimitMs }

    /// One read (poll). `window` is nil before the recorder completed one.
    mutating func ingest(_ window: StreamDiagnosticsCompletedWindow?, at nowMs: Double) {
        guard !isDone, let window else { return }
        // Receiver summaries: only once the trial's first window has run a
        // full window length, so a summary cannot describe warm-up alone.
        // Identical consecutive summaries are kept once (the first one even
        // if it equals the last warm-up summary): the receiver sends one per
        // window, but the app cannot tell two equal windows apart.
        if let first = windows.first?.startMs, let peer = window.snapshot.peer,
           peer != lastPeer || observations.isEmpty {
            let offset = (nowMs - first) / 1000
            if offset >= PerformanceLabScenarioCatalog.windowSeconds {
                observations.append(.init(offsetSeconds: offset, summary: peer))
                lastPeer = peer
            } else if peer != lastPeer {
                lastPeer = peer
            }
        } else if windows.isEmpty {
            lastPeer = window.snapshot.peer
        }
        guard window.sequence != lastSequence else { return }
        defer { lastSequence = window.sequence }
        guard window.startMs >= armedAtMs else { return }
        if let lastSequence, !windows.isEmpty, window.sequence != lastSequence &+ 1 {
            issues.insert(.windowGap)
        }
        if let previous = windows.last, abs(previous.startMs + previous.durationMs - window.startMs) > 1 {
            issues.insert(.windowGap)
        }
        windows.append(window)
        lastProgressMs = nowMs
    }

    mutating func note(_ issue: PerformanceLabTrialIssue) { issues.insert(issue) }

    /// The record, whatever happened. `forcedStatus`: failed / cancelled.
    func record(forcedStatus: PerformanceLabTrialStatus? = nil, fixture: PerformanceLabFixtureRecord?) -> PerformanceLabTrialRecord {
        var issues = self.issues
        let first = windows.first?.startMs ?? 0
        var counters: [String: Int64] = [:]
        var gaps: [String: [Int]] = [:]
        for w in windows {
            for (id, n) in w.snapshot.counters { counters[id, default: 0] += n }
            for s in w.snapshot.stages {
                guard let g100 = s.gapsOver100ms, let g250 = s.gapsOver250ms, let g500 = s.gapsOver500ms else { continue }
                let old = gaps[s.id] ?? [0, 0, 0]
                gaps[s.id] = [old[0] + g100, old[1] + g250, old[2] + g500]
            }
        }
        let stages = DiagnosticsStage.allCases.compactMap { stage -> PerformanceLabHistogramRecord? in
            let merged = PerformanceLabHistogramRecord(id: stage.definition.id, merging: windows.map { $0.histograms[stage.rawValue] })
            return merged.count > 0 ? merged : nil
        }
        if windows.count < scenario.trialWindows { issues.insert(.missingWindows) }
        if !scenario.expectsRestarts, (counters[DiagnosticsCounter.generationResets.definition.id] ?? 0) > 0 {
            issues.insert(.unexpectedRestart)
        }
        if observations.isEmpty { issues.insert(.noReceiverSummary) }
        let status: PerformanceLabTrialStatus = forcedStatus ?? (issues.isEmpty ? .complete : .incomplete)
        return PerformanceLabTrialRecord(
            synthetic: synthetic,
            scenarioID: scenario.id,
            trialIndex: trialIndex,
            status: status,
            issues: PerformanceLabTrialIssue.allCases.filter { issues.contains($0) },
            warmUpSeconds: scenario.warmUpSeconds,
            requestedWindows: scenario.trialWindows,
            measuredSeconds: windows.reduce(0) { $0 + $1.durationMs } / 1000,
            windows: windows.map {
                PerformanceLabWindowRecord(sequence: Int($0.sequence), offsetSeconds: ($0.startMs - first) / 1000,
                                           durationSeconds: $0.durationMs / 1000, snapshot: $0.snapshot,
                                           verdict: StreamBottleneckClassifier.classify($0.snapshot))
            },
            stages: stages,
            counters: counters,
            gaps: gaps,
            receiverSummaries: observations,
            fixture: fixture)
    }
}

// MARK: - Manifest and bundle

struct PerformanceLabEnvironment: Codable, Equatable, Sendable {
    /// Sender app version, OS and device class (redacted export type).
    var sender: StreamDiagnosticsBuildInfo
    /// Git commit of the build when the operator supplied one (hex only).
    var commit: String?
    /// The sender's session context at the first measured window: mode,
    /// codec, raster, target FPS, encoder in-flight limit, route class,
    /// protocol and the live path's cost flags.
    var context: StreamDiagnosticsContext?
}

struct PerformanceLabMetricEntry: Codable, Equatable, Sendable {
    var id: String
    var unit: String
    var side: StreamDiagnosticsSide?
    var timebase: StreamDiagnosticsTimebase
    var source: String
    var caveat: String
}

struct PerformanceLabTrialEntry: Codable, Equatable, Sendable {
    var index: Int
    var status: PerformanceLabTrialStatus
    var issues: [PerformanceLabTrialIssue]
}

struct PerformanceLabRunManifest: Codable, Equatable, Sendable {
    static let format = "meowdisplay-performance-lab-run"
    static let currentSchemaVersion = 1

    static let limitationsText: [String] = StreamDiagnosticsExport.limitationsText + [
        "Trials cover whole 5 s diagnostics windows after the warm-up; up to one window at each end is outside the measurement.",
        "Receiver numbers are the receiver's own 5 s window summaries received during the trial, not aligned with the sender's windows.",
        "Frame-ID counts exist only on the receiver's experimental Metal path, which itself changes presentation timing.",
        "Operator steps are done by hand; their timing varies between trials.",
    ]

    var format: String = Self.format
    var schemaVersion: Int = Self.currentSchemaVersion
    var synthetic: Bool
    /// Rounded down to the minute.
    var createdAt: Date
    var plan: PerformanceLabRunPlan
    var minimumTrials: Int = PerformanceLabRunPlan.minimumTrials
    var scenarioCatalogVersion: Int = PerformanceLabScenarioCatalog.version
    var workload: PerformanceLabWorkload
    var workloadSignature: String
    var frameIDVersion: Int = PerformanceLabFrameIDCodec.version
    var environment: PerformanceLabEnvironment
    var diagnosticsSchemaVersion: Int = StreamDiagnosticsExport.currentSchemaVersion
    var metricDictionaryVersion: Int = StreamDiagnosticsMetricDictionary.version
    var windowSeconds: Double = PerformanceLabScenarioCatalog.windowSeconds
    var histogramUpperEdgesMs: [Double] = DiagnosticsHistogram.upperEdgesMs
    var trials: [PerformanceLabTrialEntry]
    var metrics: [PerformanceLabMetricEntry]
    var classifierThresholds: [String: Double] = StreamBottleneckClassifier.thresholds
    var limitations: [String] = Self.limitationsText

    init(plan: PerformanceLabRunPlan, environment: PerformanceLabEnvironment, trials: [PerformanceLabTrialRecord], createdAt: Date) {
        synthetic = plan.synthetic
        self.createdAt = Date(timeIntervalSince1970: (createdAt.timeIntervalSince1970 / 60).rounded(.down) * 60)
        self.plan = plan
        let workload = PerformanceLabWorkload.workload(plan.scenario.workload)
        self.workload = workload
        workloadSignature = workload.signature
        self.environment = environment
        self.trials = trials.map { .init(index: $0.trialIndex, status: $0.status, issues: $0.issues) }
        metrics = StreamDiagnosticsMetricDictionary.all.map {
            .init(id: $0.id, unit: $0.unit, side: $0.side, timebase: $0.timebase, source: $0.source, caveat: $0.caveat)
        }
    }
}

enum PerformanceLabBundle {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }

    /// `perf-lab-<scenario>-<yyyyMMdd-HHmm>[-<variant>][-synthetic]`: no session data.
    static func folderName(for manifest: PerformanceLabRunManifest) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        var name = "perf-lab-\(manifest.plan.scenario.id)-\(formatter.string(from: manifest.createdAt))"
        if let variant = manifest.plan.variant { name += "-\(variant)" }
        if manifest.synthetic { name += "-synthetic" }
        return name
    }

    /// Writes the bundle into a new folder under `parent` (a numeric suffix
    /// avoids overwriting an earlier run) and returns the folder.
    @discardableResult
    static func write(manifest: PerformanceLabRunManifest, trials: [PerformanceLabTrialRecord], under parent: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let base = folderName(for: manifest)
        var folder = parent.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try write(manifest: manifest, trials: trials, into: folder)
        return folder
    }

    /// Writes manifest.json and trial-NN.json into `folder` exactly (golden tests).
    static func write(manifest: PerformanceLabRunManifest, trials: [PerformanceLabTrialRecord], into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = encoder()
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        for trial in trials {
            try encoder.encode(trial).write(to: folder.appendingPathComponent(PerformanceLabTrialRecord.fileName(index: trial.trialIndex)), options: .atomic)
        }
    }

    /// The application-support default: ~/Library/Application Support/<app>/PerformanceLab.
    static func defaultParentFolder() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("MeowDisplay", isDirectory: true).appendingPathComponent("PerformanceLab", isDirectory: true)
    }
}
