// Performance Lab (#123): trial collection and the run bundle.
//
// A trial is made of whole diagnostics windows: the first window that
// starts after the warm-up ends, and the next `trialWindows − 1` windows.
// Warm-up data can never leak into the sender side, and the numbers cover
// exactly the windows listed. Sender histograms are merged bucket by bucket,
// so the trial's percentiles are exact to the bucket (same rule as
// DiagnosticsHistogram).
//
// The receiver side comes from the optional `diag` summaries the receiver
// sent (its own 5 s windows, not aligned with the sender's). Each receiver
// window is kept once, by (series, sequence), however often it was sent. A
// window is kept only if it provably began inside the trial: the receiver
// reports the sender window sequence it had heard when the window began
// (`wps`), and a sequence the sender completed no earlier than the trial's
// first window began proves it, by causality alone (no clock is compared
// across devices). Receivers that do not report it are kept by arrival
// time, and the trial's receiver side is marked partial.
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
    /// The run was cancelled before this planned trial began.
    case notStarted
}

/// How the receiver windows of a trial were tied to it.
enum PerformanceLabReceiverAlignment: String, Codable, Sendable, CaseIterable {
    /// Every kept window provably began after the trial's first sender
    /// window began.
    case aligned
    /// Some kept windows could not be tied to the trial (the receiver sent
    /// no start marker); they were kept by arrival time and may include up
    /// to one window from before the trial.
    case partial
}

/// How repeated receiver summaries were counted.
enum PerformanceLabReceiverCounting: String, Codable, Sendable, CaseIterable {
    /// Each receiver window once, by its (series, sequence).
    case perWindow
    /// The receiver sent no window sequence (an older build): only equal
    /// consecutive summaries were merged, so sums over the summaries are
    /// possibly double counted.
    case possiblyDoubleCounted
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
    /// When the summary arrived on the Mac, relative to the start of the
    /// trial's first window (s, Mac clock).
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
    /// Gaps over 100/250/500 ms of this side's interval stages, summed over
    /// the windows (stages the other side measures are not listed).
    var gaps: [String: [Int]]
    /// One per receiver window kept (see the file header).
    var receiverSummaries: [PerformanceLabReceiverObservation]
    var fixture: PerformanceLabFixtureRecord?
    /// nil when no receiver summary was kept.
    var receiverAlignment: PerformanceLabReceiverAlignment? = nil
    var receiverCounting: PerformanceLabReceiverCounting? = nil
    /// Receiver window numbers missing between kept windows of one series
    /// (never reported, or reported between two reads); nil without
    /// window numbers.
    var receiverWindowsMissed: Int? = nil
    /// Window discontinuities caused by a restart the scenario expects
    /// (recorded, not an issue), and the time between those windows that
    /// no window covers (the recorder restarts its window at a restart).
    var expectedRestarts: Int? = nil
    var restartUnmeasuredSeconds: Double? = nil

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
    /// End of the last window read before the trial's first window.
    private var lastWindowEnd: (sequence: UInt64, endMs: Double)?
    /// The sender window sequence a receiver window's start marker must
    /// reach to prove it began inside the trial.
    private var alignmentThreshold: UInt64?
    private var lastProgressMs: Double
    private var keptReceiverWindows: Set<ReceiverWindowKey> = []
    private var lastLegacyPeer: StreamDiagnosticsPeerSummary?
    private var receiverUnaligned = false
    private var receiverLegacy = false
    /// A receiver that reports start markers was seen: worth waiting after
    /// the last sender window for the receiver windows still in flight.
    private var receiverReportsMarkers = false
    /// The receiver started a window after it heard that the trial's last
    /// sender window completed: every in-trial receiver window was reported.
    private var receiverMovedOn = false
    private var doneAtMs: Double?
    private var expectedRestartCount = 0
    private var restartUnmeasuredMs = 0.0

    private struct ReceiverWindowKey: Hashable, Sendable {
        let series: Double
        let sequence: Double
    }

    init(scenario: PerformanceLabScenario, trialIndex: Int, synthetic: Bool, armedAtMs: Double) {
        self.scenario = scenario
        self.trialIndex = trialIndex
        self.synthetic = synthetic
        self.armedAtMs = armedAtMs
        lastProgressMs = armedAtMs
    }

    /// Every sender window of the trial was collected.
    var isDone: Bool { windows.count >= scenario.trialWindows }
    var firstWindowStartMs: Double? { windows.first?.startMs }

    private var windowMs: Double { PerformanceLabScenarioCatalog.windowSeconds * 1000 }

    /// After the last sender window, receiver windows that began inside the
    /// trial are still being reported for up to this long.
    var receiverGraceMs: Double { 2 * windowMs }

    /// The trial can be recorded: sender windows done, and no receiver
    /// window that began inside the trial is still expected.
    func isFinished(at nowMs: Double) -> Bool {
        guard isDone, let doneAtMs else { return false }
        return !receiverReportsMarkers || receiverMovedOn || nowMs - doneAtMs >= receiverGraceMs
    }

    /// No new window for this long = the stream stopped.
    var stallLimitMs: Double { 3 * PerformanceLabScenarioCatalog.windowSeconds * 1000 + armedWindowSlackMs }
    private var armedWindowSlackMs: Double { PerformanceLabScenarioCatalog.windowSeconds * 1000 }

    func hasStalled(at nowMs: Double) -> Bool { !isDone && nowMs - lastProgressMs > stallLimitMs }

    /// One read (poll). `window` is nil before the recorder completed one.
    mutating func ingest(_ window: StreamDiagnosticsCompletedWindow?, at nowMs: Double) {
        guard let window else { return }
        if !isDone, window.sequence != lastSequence {
            ingestSenderWindow(window, at: nowMs)
        }
        if isDone, doneAtMs == nil { doneAtMs = nowMs }
        ingestReceiverSummary(window.snapshot.peer, arrivedAtMs: window.peerUpdatedMs ?? nowMs)
    }

    private mutating func ingestSenderWindow(_ window: StreamDiagnosticsCompletedWindow, at nowMs: Double) {
        defer { lastSequence = window.sequence }
        let endMs = window.startMs + window.durationMs
        guard window.startMs >= armedAtMs else {
            lastWindowEnd = (window.sequence, endMs)
            return
        }
        if let previous = windows.last {
            if window.sequence != previous.sequence &+ 1 {
                issues.insert(.windowGap)   // a window completed between two reads
            }
            if abs(previous.startMs + previous.durationMs - window.startMs) > 1 {
                // The recorder restarts its window at a capture/presentation
                // restart. Expected in this scenario: recorded, not a gap.
                if scenario.expectsRestarts, window.snapshot.count(.generationResets) > 0,
                   window.startMs > previous.startMs + previous.durationMs {
                    expectedRestartCount += 1
                    restartUnmeasuredMs += window.startMs - (previous.startMs + previous.durationMs)
                } else {
                    issues.insert(.windowGap)
                }
            }
        } else {
            // The trial's first window. A ping that carried the previous
            // window's number was sent once that window had completed; if the
            // first window began at that same instant, that number is enough.
            if let before = lastWindowEnd, before.sequence &+ 1 == window.sequence, abs(before.endMs - window.startMs) <= 1 {
                alignmentThreshold = before.sequence
            } else {
                alignmentThreshold = window.sequence
            }
        }
        windows.append(window)
        lastProgressMs = nowMs
    }

    private mutating func ingestReceiverSummary(_ peer: StreamDiagnosticsPeerSummary?, arrivedAtMs: Double) {
        guard let peer, peer.side == .receiver, let first = windows.first else { return }
        // Arrival rule for receivers without a start marker: a summary
        // describes a window that ended before it arrived and is about one
        // window long, so arriving two windows after the trial began keeps
        // pre-trial windows out unless windows ran long.
        let arrivedLateEnough = arrivedAtMs - 2 * windowMs >= first.startMs
        let offset = (arrivedAtMs - first.startMs) / 1000
        guard let series = peer.windowSeriesID else {
            // An older receiver: no window numbers.
            guard peer != lastLegacyPeer else { return }
            lastLegacyPeer = peer
            guard !isDone, arrivedLateEnough else { return }
            receiverLegacy = true
            receiverUnaligned = true
            observations.append(.init(offsetSeconds: offset, summary: peer))
            return
        }
        // A partial receiver window (no number yet) is not a whole window.
        guard let sequence = peer.windowSequence else { return }
        let key = ReceiverWindowKey(series: series, sequence: sequence)
        guard !keptReceiverWindows.contains(key) else { return }
        if let marker = peer.peerWindowSequenceAtStart {
            receiverReportsMarkers = true
            guard let threshold = alignmentThreshold, marker >= Double(threshold) else { return }
            if isDone, let last = windows.last, marker >= Double(last.sequence) {
                // Began after the receiver heard the trial ended.
                receiverMovedOn = true
                return
            }
        } else {
            guard !isDone, arrivedLateEnough else { return }
            receiverUnaligned = true
        }
        keptReceiverWindows.insert(key)
        observations.append(.init(offsetSeconds: offset, summary: peer))
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
            // Only stages this side measures: the other side's interval
            // stages are always 0 here and would read as "no gaps".
            let ownStages = Set(DiagnosticsStage.allCases.filter { $0.definition.side == w.snapshot.side }.map(\.definition.id))
            for s in w.snapshot.stages where ownStages.contains(s.id) {
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
        var record = PerformanceLabTrialRecord(
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
        if !observations.isEmpty {
            record.receiverAlignment = receiverUnaligned ? .partial : .aligned
            record.receiverCounting = receiverLegacy ? .possiblyDoubleCounted : .perWindow
            if !receiverLegacy { record.receiverWindowsMissed = Self.missedWindows(keptReceiverWindows) }
        }
        if expectedRestartCount > 0 {
            record.expectedRestarts = expectedRestartCount
            record.restartUnmeasuredSeconds = (restartUnmeasuredMs / 100).rounded() / 10
        }
        return record
    }

    /// Per series: numbers between the lowest and highest kept window that
    /// were not kept.
    private static func missedWindows(_ keys: Set<ReceiverWindowKey>) -> Int {
        Dictionary(grouping: keys, by: \.series).values.reduce(0) { total, group in
            let numbers = group.map(\.sequence)
            guard let lo = numbers.min(), let hi = numbers.max() else { return total }
            return total + Swift.max(Int(hi - lo) + 1 - numbers.count, 0)
        }
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
        "Receiver numbers are the receiver's own 5 s windows, each counted once, that began after the trial's first sender window began; they are not aligned with the sender's windows and the last one may end up to one window after the trial.",
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
