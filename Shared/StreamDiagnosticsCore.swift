// Streaming diagnostics (#123): the recorder.
//
// Opt-in, off by default. When the switch is off every recording entry point
// returns after one flag read under an os_unfair_lock (no NSLock, no clock
// read, no allocation, no counter touched). When on, each hook is O(1): a binary search over a
// fixed bucket table and a few integer adds under one uncontended lock. All
// storage is allocated once, at init; a window rotation (every 5 s) copies
// the fixed-size arrays once.
//
// Measurement only. Nothing here feeds back into capture cadence, queue
// depths, the frame-rate limiter or presenter buffering.
//
// Pure Foundation (no UIKit/AppKit). Compiled into every app target and MacTests.

import Foundation
import os

// MARK: - Switch and clock

/// A value behind an `os_unfair_lock`. `OSAllocatedUnfairLock` needs macOS 13
/// and the Mac Receiver deploys to macOS 12, so this is the small portable
/// equivalent: the lock lives in its own stable allocation (never inside a
/// Swift property, which may move), and the state is only touched under it.
final class StreamDiagnosticsUnfairLock<State>: @unchecked Sendable {
    private let lockPointer: UnsafeMutablePointer<os_unfair_lock>
    private var state: State

    init(_ initial: State) {
        state = initial
        lockPointer = .allocate(capacity: 1)
        lockPointer.initialize(to: os_unfair_lock())
    }

    deinit {
        lockPointer.deinitialize(count: 1)
        lockPointer.deallocate()
    }

    func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        os_unfair_lock_lock(lockPointer)
        defer { os_unfair_lock_unlock(lockPointer) }
        return try body(&state)
    }
}

/// The process-wide opt-in. Persisted so a QA build can be switched on with
/// one command (`defaults write <bundle id> streamDiagnosticsEnabled -bool YES`).
/// Read on every frame: an unfair lock around two words, never an NSLock.
final class StreamDiagnosticsSwitch: @unchecked Sendable {
    static let defaultsKey = "streamDiagnosticsEnabled"
    static let shared = StreamDiagnosticsSwitch(enabled: UserDefaults.standard.bool(forKey: defaultsKey))

    private struct State {
        var enabled: Bool
        /// Bumped on every off → on change, so a recorder can tell that the
        /// time since its last event includes an off period.
        var enableEpoch: UInt64 = 0
    }

    private let state: StreamDiagnosticsUnfairLock<State>

    init(enabled: Bool = false) {
        state = StreamDiagnosticsUnfairLock(State(enabled: enabled))
    }

    var isEnabled: Bool {
        state.withLock { $0.enabled }
    }

    /// Changes on every off → on transition.
    var enableEpoch: UInt64 {
        state.withLock { $0.enableEpoch }
    }

    /// `persist`: also writes the preference (the shared switch only).
    func set(_ on: Bool, persist: Bool = false) {
        state.withLock { s in
            if on, !s.enabled { s.enableEpoch &+= 1 }
            s.enabled = on
        }
        if persist { UserDefaults.standard.set(on, forKey: Self.defaultsKey) }
    }
}

enum StreamDiagnosticsClock {
    /// Monotonic milliseconds on this device (mach uptime; stops in sleep).
    static func nowMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000
    }

    /// The same clock in seconds: the time base of the adaptive receiver
    /// state. Shared code compiled into iOS uses this rather than
    /// `ProcessInfo.systemUptime`, a required-reason API (system boot time)
    /// that the iOS privacy manifest does not declare.
    static func nowSeconds() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

// MARK: - Histogram

/// Fixed-bucket histogram for millisecond values. Percentiles are reported as
/// the upper edge of the bucket holding the rank, clamped to the observed
/// maximum: the true value lies in (lower edge, reported value]. Between 4
/// and 18 ms (the 120 and 60 FPS frame budgets) buckets are 1 ms or finer.
struct DiagnosticsHistogram: Equatable, Sendable {
    /// Upper bucket edges in ms. One more bucket holds everything above the last.
    static let upperEdgesMs: [Double] = [
        0.25, 0.5, 0.75, 1, 1.5, 2, 2.5, 3, 3.5, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        20, 22, 25, 28, 30, 33, 36, 40, 45, 50, 60, 70, 80, 90, 100, 125, 150, 175, 200, 250, 300,
        400, 500, 750, 1000, 1500, 2000, 3000, 5000, 10000,
    ]
    static var bucketCount: Int { upperEdgesMs.count + 1 }

    private(set) var buckets: [UInt32]
    private(set) var count = 0
    private(set) var sum = 0.0
    private(set) var max = 0.0
    private(set) var min = Double.infinity

    init() {
        buckets = [UInt32](repeating: 0, count: Self.bucketCount)
    }

    static func bucketIndex(for ms: Double) -> Int {
        var lo = 0, hi = upperEdgesMs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if ms <= upperEdgesMs[mid] { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// Negative values (clock mapping error) count as 0; non-finite ones are ignored.
    mutating func record(_ value: Double) {
        guard value.isFinite else { return }
        let ms = Swift.max(value, 0)
        let i = Self.bucketIndex(for: ms)
        if buckets[i] < UInt32.max { buckets[i] += 1 }
        count += 1
        sum += ms
        if ms > max { max = ms }
        if ms < min { min = ms }
    }

    mutating func reset() {
        for i in buckets.indices { buckets[i] = 0 }
        count = 0
        sum = 0
        max = 0
        min = .infinity
    }

    var mean: Double { count > 0 ? sum / Double(count) : 0 }

    /// `p` in 0...1. nil when empty.
    func percentile(_ p: Double) -> Double? {
        guard count > 0 else { return nil }
        let rank = Swift.max(1, Int((Double(count) * Swift.min(Swift.max(p, 0), 1)).rounded(.up)))
        var seen = 0
        for (i, n) in buckets.enumerated() {
            seen += Int(n)
            if seen >= rank {
                let edge = i < Self.upperEdgesMs.count ? Self.upperEdgesMs[i] : max
                return Swift.max(Swift.min(edge, max), min)
            }
        }
        return max
    }
}

/// Last/max/mean of a sampled level.
struct DiagnosticsGaugeAccumulator: Equatable, Sendable {
    private(set) var last = 0.0
    private(set) var max = 0.0
    private(set) var sum = 0.0
    private(set) var samples = 0

    mutating func observe(_ value: Double) {
        guard value.isFinite else { return }
        last = value
        if samples == 0 || value > max { max = value }
        sum += value
        samples += 1
    }

    var mean: Double { samples > 0 ? sum / Double(samples) : 0 }
}

/// One measurement window: fixed-size arrays indexed by the metric enums.
struct DiagnosticsWindow: Equatable, Sendable {
    var startMs: Double
    var histograms: [DiagnosticsHistogram]
    var counters: [Int64]
    var gauges: [DiagnosticsGaugeAccumulator]
    /// Per stage: gaps over 100, 250, 500 ms (interval stages only).
    var gaps: [[Int]]

    init(startMs: Double) {
        self.startMs = startMs
        histograms = [DiagnosticsHistogram](repeating: DiagnosticsHistogram(), count: DiagnosticsStage.allCases.count)
        counters = [Int64](repeating: 0, count: DiagnosticsCounter.allCases.count)
        gauges = [DiagnosticsGaugeAccumulator](repeating: DiagnosticsGaugeAccumulator(), count: DiagnosticsGauge.allCases.count)
        gaps = [[Int]](repeating: [0, 0, 0], count: DiagnosticsStage.allCases.count)
    }

    /// Stall/freeze thresholds for interval stages, in ms.
    static let gapThresholdsMs: [Double] = [100, 250, 500]

    mutating func clear(startMs: Double) {
        self.startMs = startMs
        for i in histograms.indices { histograms[i].reset() }
        for i in counters.indices { counters[i] = 0 }
        for i in gauges.indices { gauges[i] = DiagnosticsGaugeAccumulator() }
        for i in gaps.indices { gaps[i][0] = 0; gaps[i][1] = 0; gaps[i][2] = 0 }
    }
}

// MARK: - Context (typed: nothing free-form from the session)

enum DiagnosticsDisplayMode: String, Codable, Sendable { case mirror, extend, window, unknown }
enum DiagnosticsCodec: String, Codable, Sendable { case h264, hevc, unknown }
enum DiagnosticsRouteClass: String, Codable, Sendable {
    case usb, awdl, lan, remote, unknown

    init(_ route: ConnectionRoute?) {
        switch route {
        case .usb: self = .usb
        case .awdl: self = .awdl
        case .lan: self = .lan
        case .remote: self = .remote
        case nil: self = .unknown
        }
    }

    /// From the receiver's display label ("USB", "AWDL", "LAN", "Remote", "—").
    init(label: String) {
        self.init(ConnectionRoute(rawValue: label))
    }
}
enum DiagnosticsNetworkProtocol: String, Codable, Sendable { case tcp, quic, unknown }
enum DiagnosticsPresentationPath: String, Codable, Sendable { case displayLayer, metal, unknown }

/// What a session was configured as. Every field is an enum, number or bool.
struct StreamDiagnosticsContext: Codable, Equatable, Sendable {
    var displayMode: DiagnosticsDisplayMode = .unknown
    var codec: DiagnosticsCodec = .unknown
    var rasterWidth = 0
    var rasterHeight = 0
    var targetFPS = 0
    /// Refresh of the source when known: the mirrored display's mode, the
    /// virtual display's refresh, or the Window view composition budget.
    var sourceRefreshHz: Double?
    /// Encoder in-flight limit (StreamingPriority 1/2/3).
    var encoderInFlightLimit: Int?
    var route: DiagnosticsRouteClass = .unknown
    var networkProtocol: DiagnosticsNetworkProtocol = .unknown
    var pathExpensive: Bool?
    var pathConstrained: Bool?
    var presentationPath: DiagnosticsPresentationPath = .unknown
    var clockOffsetKnown: Bool?
}

// MARK: - Snapshot

struct StreamDiagnosticsStageSummary: Codable, Equatable, Sendable {
    var id: String
    var count: Int
    var ratePerSecond: Double
    var p50: Double
    var p95: Double
    var p99: Double
    var max: Double
    var mean: Double
    var gapsOver100ms: Int?
    var gapsOver250ms: Int?
    var gapsOver500ms: Int?
}

struct StreamDiagnosticsGaugeSummary: Codable, Equatable, Sendable {
    var id: String
    var last: Double
    var max: Double
    var mean: Double
    var samples: Int
}

/// A windowed, Sendable picture of one session on one side. This is the
/// stable surface for the Performance Lab harness and for a future adaptive
/// controller: read it, never the recorder's internals.
struct StreamDiagnosticsSnapshot: Codable, Equatable, Sendable {
    var side: StreamDiagnosticsSide
    /// Length of the window the numbers cover.
    var windowSeconds: Double
    /// True when no full window has completed yet (numbers cover less time).
    var windowIsPartial: Bool
    var stages: [StreamDiagnosticsStageSummary]
    /// Counts in the window, by metric id.
    var counters: [String: Int64]
    /// Counts since the session (recorder) was reset, by metric id.
    var sessionCounters: [String: Int64]
    var gauges: [StreamDiagnosticsGaugeSummary]
    var rttJitterMs: Double?
    var context: StreamDiagnosticsContext
    /// What the other end last reported (optional wire keys), if anything.
    var peer: StreamDiagnosticsPeerSummary?
    var resources: StreamDiagnosticsResourceSample?
    /// Adaptive Automatic controller decisions (phase 2), newest last; nil
    /// when none were recorded (the controller is off, or diagnostics were).
    var adaptiveDecisions: [StreamDiagnosticsAdaptiveDecision]? = nil
    /// Colour metadata sampled in the pipeline (#241); nil until sampled.
    var colour: StreamDiagnosticsColourSection?

    func stage(_ stage: DiagnosticsStage) -> StreamDiagnosticsStageSummary? {
        stages.first { $0.id == stage.definition.id }
    }

    func count(_ counter: DiagnosticsCounter) -> Int64 {
        counters[counter.definition.id] ?? 0
    }

    func rate(_ counter: DiagnosticsCounter) -> Double {
        windowSeconds > 0 ? Double(count(counter)) / windowSeconds : 0
    }

    func gauge(_ gauge: DiagnosticsGauge) -> StreamDiagnosticsGaugeSummary? {
        gauges.first { $0.id == gauge.definition.id }
    }
}

/// One completed recorder window as the Performance Lab reads it: whole
/// windows only, so a lab trial covers exactly the windows it lists.
struct StreamDiagnosticsCompletedWindow: Equatable, Sendable {
    var sequence: UInt64
    /// Window start on the recording device's monotonic clock (ms).
    var startMs: Double
    var durationMs: Double
    /// Indexed by `DiagnosticsStage.rawValue`.
    var histograms: [DiagnosticsHistogram]
    var snapshot: StreamDiagnosticsSnapshot
}

/// The narrow, numbers-only view a streaming policy may read. Values are nil
/// when this side does not measure them and the peer did not report them.
struct StreamDiagnosticsControllerInputs: Equatable, Sendable {
    var windowSeconds: Double
    var targetFPS: Int
    /// Display capture: complete ScreenCaptureKit frames per second.
    var sourceUniqueFPS: Double?
    var submittedFPS: Double?
    var arrivedFPS: Double?
    var enqueuedForPresentationFPS: Double?
    var frameIntervalP95Ms: Double?
    var encodeP95Ms: Double?
    var presenterQueueAgeP95Ms: Double?
    var encoderBusyPerSecond: Double?
    var sendBackpressurePerSecond: Double?
    var rttP50Ms: Double?
    var rttJitterMs: Double?
    var payloadBytesPerSecond: Double?
    var thermalState: DiagnosticsThermalState?
}

extension StreamDiagnosticsSnapshot {
    var controllerInputs: StreamDiagnosticsControllerInputs {
        func p95(_ s: DiagnosticsStage) -> Double? { stage(s).flatMap { $0.count > 0 ? $0.p95 : nil } }
        let sender = side == .sender
        let peer = self.peer
        return StreamDiagnosticsControllerInputs(
            windowSeconds: windowSeconds,
            targetFPS: context.targetFPS,
            sourceUniqueFPS: sender ? rate(.captureComplete) : peer?.captureCompleteFPS,
            submittedFPS: sender ? stage(.submitInterval).map { $0.ratePerSecond } : peer?.submitFPS,
            arrivedFPS: sender ? peer?.arrivalFPS : rate(.arrivedFrames),
            enqueuedForPresentationFPS: sender ? peer?.enqueueFPS : rate(.enqueuedForPresentation),
            frameIntervalP95Ms: sender ? peer?.arrivalP95Ms : p95(.arrivalInterval),
            encodeP95Ms: sender ? p95(.encode) : peer?.encodeP95Ms,
            presenterQueueAgeP95Ms: sender ? peer?.presenterQueueAgeP95Ms : p95(.presenterQueueAge),
            encoderBusyPerSecond: sender ? rate(.heldEncoderBusy) : nil,
            sendBackpressurePerSecond: sender ? rate(.droppedPendingSends) : nil,
            rttP50Ms: sender ? peer?.rttMs : stage(.rtt).flatMap { $0.count > 0 ? $0.p50 : nil },
            rttJitterMs: sender ? peer?.rttJitterMs : rttJitterMs,
            payloadBytesPerSecond: sender ? rate(.sentBytes) : rate(.arrivedBytes),
            thermalState: resources?.thermalState)
    }
}

// MARK: - Recorder

/// Where an encoder submission came from.
enum DiagnosticsSubmitOrigin: Sendable {
    case live, heldRetry, dropReplay, reconnectReplay, workspace

    var counter: DiagnosticsCounter {
        switch self {
        case .live: return .submitLive
        case .heldRetry: return .submitHeldRetry
        case .dropReplay: return .submitDropReplay
        case .reconnectReplay: return .submitReconnectReplay
        case .workspace: return .submitWorkspace
        }
    }
}

enum DiagnosticsCaptureStatus: Sendable { case complete, idle, other }

/// One session's recorder on one side. Thread-safe; every method takes the
/// lock at most once. Call sites read `isEnabled` before doing any work of
/// their own (reading a clock, building a value).
final class StreamDiagnosticsRecorder: @unchecked Sendable {
    let side: StreamDiagnosticsSide
    let windowMs: Double
    private let diagnosticsSwitch: StreamDiagnosticsSwitch
    private let resourceSampler: StreamDiagnosticsResourceSampler?

    private let lock = NSLock()
    private var current: DiagnosticsWindow
    private var completed: DiagnosticsWindow?
    private var completedDurationMs: Double = 0
    private var session: [Int64]
    private var lastMarkMs: [Double?]
    private var lastSourceKey: Int64?
    private var lastRTTMs: Double?
    private var rttJitter: Double?
    private var context = StreamDiagnosticsContext()
    private var peer: StreamDiagnosticsPeerSummary?
    /// When `peer` last arrived (this device's clock); it expires after
    /// `peerExpiryWindows` windows without an update.
    private var peerUpdatedMs: Double?
    private var resources: StreamDiagnosticsResourceSample?
    /// A window completed under the lock: the resource sample is taken
    /// after the lock is released (`unlockAndSampleResources`).
    private var needsResourceSample = false
    /// The switch's `enableEpoch` this recorder last saw: a change means
    /// diagnostics were off in between.
    private var seenEnableEpoch: UInt64
    private var generation: UInt64?
    private var presenterInFlight = 0
    private var adaptiveDecisions: [StreamDiagnosticsAdaptiveDecision] = []
    /// Counts completed windows (Performance Lab reads it; nothing else does).
    private var completedSequence: UInt64 = 0
    /// Colour metadata per pipeline stage (#241). Own lock; see StreamDiagnosticsColour.swift.
    let colourStore = DiagnosticsColourStore()

    init(side: StreamDiagnosticsSide,
         windowSeconds: Double = 5,
         diagnosticsSwitch: StreamDiagnosticsSwitch = .shared,
         resourceSampler: StreamDiagnosticsResourceSampler? = StreamDiagnosticsResourceSampler(),
         nowMs: Double = StreamDiagnosticsClock.nowMs()) {
        self.side = side
        self.windowMs = windowSeconds * 1000
        self.diagnosticsSwitch = diagnosticsSwitch
        self.resourceSampler = resourceSampler
        current = DiagnosticsWindow(startMs: nowMs)
        session = [Int64](repeating: 0, count: DiagnosticsCounter.allCases.count)
        lastMarkMs = [Double?](repeating: nil, count: DiagnosticsStage.allCases.count)
        seenEnableEpoch = diagnosticsSwitch.enableEpoch
    }

    /// A peer summary older than this many windows is dropped (the peer
    /// stopped reporting: diagnostics off there, or an old build).
    static let peerExpiryWindows = 2.0

    var isEnabled: Bool { diagnosticsSwitch.isEnabled }

    // MARK: Generic entry points

    func recordDuration(_ stage: DiagnosticsStage, ms: Double, at nowMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { unlockAndSampleResources() }
        rotateIfNeeded(nowMs)
        current.histograms[stage.rawValue].record(ms)
    }

    /// An event on an interval stage: records the time since the previous one.
    func markInterval(_ stage: DiagnosticsStage, at nowMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { unlockAndSampleResources() }
        rotateIfNeeded(nowMs)
        markLocked(stage, nowMs)
    }

    func increment(_ counter: DiagnosticsCounter, by amount: Int64 = 1, at nowMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { unlockAndSampleResources() }
        rotateIfNeeded(nowMs)
        addLocked(counter, amount)
    }

    func observeGauge(_ gauge: DiagnosticsGauge, _ value: Double, at nowMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { unlockAndSampleResources() }
        rotateIfNeeded(nowMs)
        current.gauges[gauge.rawValue].observe(value)
    }

    // MARK: Sender hooks

    func recordCapture(_ status: DiagnosticsCaptureStatus, at nowMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { unlockAndSampleResources() }
        rotateIfNeeded(nowMs)
        switch status {
        case .complete:
            addLocked(.captureComplete, 1)
            markLocked(.captureInterval, nowMs)
        case .idle:
            addLocked(.captureIdle, 1)
        case .other:
            addLocked(.captureOtherStatus, 1)
        }
    }

    /// `sourceKey`: the capture PTS of the submitted pixels (any stable
    /// integer encoding); nil when unknown. Equal to the previous
    /// submission's key = a duplicate.
    func recordSubmit(origin: DiagnosticsSubmitOrigin, sourceKey: Int64?, sourceAgeMs: Double?,
                      pendingEncodes: Int, at nowMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { unlockAndSampleResources() }
        rotateIfNeeded(nowMs)
        addLocked(origin.counter, 1)
        if let sourceKey {
            addLocked(sourceKey == lastSourceKey ? .submitDuplicate : .submitSourceUnique, 1)
            lastSourceKey = sourceKey
        } else {
            addLocked(.submitUniquenessUnknown, 1)
        }
        if let sourceAgeMs { current.histograms[DiagnosticsStage.sourceAgeAtSubmit.rawValue].record(sourceAgeMs) }
        current.gauges[DiagnosticsGauge.pendingEncodes.rawValue].observe(Double(pendingEncodes))
        markLocked(.submitInterval, nowMs)
    }

    func recordEncodeOutput(durationMs: Double?, bytes: Int, keyframe: Bool, outcome: EncodeOutcome, at nowMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { unlockAndSampleResources() }
        rotateIfNeeded(nowMs)
        if let durationMs { current.histograms[DiagnosticsStage.encode.rawValue].record(durationMs) }
        switch outcome {
        case .sent:
            addLocked(.encodeCompleted, 1)
            addLocked(.encodedBytes, Int64(bytes))
            if keyframe { addLocked(.keyframes, 1) }
        case .stale:
            addLocked(.encodeCompleted, 1)
            addLocked(.encodeStaleDiscarded, 1)
        case .failed:
            addLocked(.encodeFailed, 1)
        }
    }

    enum EncodeOutcome: Sendable { case sent, stale, failed }

    func recordSendCompletion(durationMs: Double, bytes: Int, error: Bool, at nowMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { unlockAndSampleResources() }
        rotateIfNeeded(nowMs)
        current.histograms[DiagnosticsStage.send.rawValue].record(durationMs)
        if error {
            addLocked(.sendErrors, 1)
        } else {
            addLocked(.sendCompleted, 1)
            addLocked(.sentBytes, Int64(bytes))
        }
    }

    func recordCompose(durationMs: Double, staticResend: Bool, tiles: Int, floats: Int, dimmed: Int,
                       withFrame: Int, at nowMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { unlockAndSampleResources() }
        rotateIfNeeded(nowMs)
        current.histograms[DiagnosticsStage.compose.rawValue].record(durationMs)
        addLocked(.composeFrames, 1)
        if staticResend { addLocked(.composeStaticResends, 1) }
        markLocked(.composeInterval, nowMs)
        current.gauges[DiagnosticsGauge.windowTiles.rawValue].observe(Double(tiles))
        current.gauges[DiagnosticsGauge.windowFloats.rawValue].observe(Double(floats))
        current.gauges[DiagnosticsGauge.windowCoveredTiles.rawValue].observe(Double(dimmed))
        current.gauges[DiagnosticsGauge.windowTilesWithFrame.rawValue].observe(Double(withFrame))
    }

    // MARK: Receiver hooks

    func recordArrival(bytes: Int, wireSubmitToSendMs: Double?, mappedSubmitToReceiveMs: Double?, at nowMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { unlockAndSampleResources() }
        rotateIfNeeded(nowMs)
        addLocked(.arrivedFrames, 1)
        addLocked(.arrivedBytes, Int64(bytes))
        markLocked(.arrivalInterval, nowMs)
        if let wireSubmitToSendMs { current.histograms[DiagnosticsStage.wireSubmitToSend.rawValue].record(wireSubmitToSendMs) }
        if let mappedSubmitToReceiveMs { current.histograms[DiagnosticsStage.mappedSubmitToReceive.rawValue].record(mappedSubmitToReceiveMs) }
    }

    /// A presenter command was yielded. Returns its stamp (0 = not tracked,
    /// diagnostics were off), to hand back to `presenterCommandProcessed`.
    func presenterCommandEnqueued() -> UInt64 {
        guard isEnabled else { return 0 }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        presenterInFlight += 1
        current.gauges[DiagnosticsGauge.presenterQueueDepth.rawValue].observe(Double(presenterInFlight))
        return Swift.max(now, 1)
    }

    /// The pump took a command off the queue. A tracked command always
    /// leaves the in-flight count (even if diagnostics were switched off
    /// since), so the depth never drifts.
    func presenterCommandProcessed(stamp: UInt64) {
        guard stamp != 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let enabled = isEnabled
        lock.lock(); defer { unlockAndSampleResources() }
        presenterInFlight = Swift.max(0, presenterInFlight - 1)
        guard enabled else { return }
        let nowMs = Double(now) / 1_000_000
        rotateIfNeeded(nowMs)
        current.histograms[DiagnosticsStage.presenterQueueAge.rawValue].record(Double(now &- stamp) / 1_000_000)
    }

    func recordPresentationEnqueue(at nowMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { unlockAndSampleResources() }
        rotateIfNeeded(nowMs)
        addLocked(.enqueuedForPresentation, 1)
        markLocked(.presentationEnqueueInterval, nowMs)
    }

    func recordRTT(_ ms: Double, at nowMs: Double) {
        guard isEnabled, ms.isFinite else { return }
        lock.lock(); defer { unlockAndSampleResources() }
        rotateIfNeeded(nowMs)
        current.histograms[DiagnosticsStage.rtt.rawValue].record(ms)
        if let last = lastRTTMs {
            let d = abs(ms - last)
            let j = rttJitter ?? d
            rttJitter = j + (d - j) / 16
        }
        lastRTTMs = ms
    }

    // MARK: Session state

    /// A new capture/presentation generation: interval baselines restart
    /// (a reconnect gap is not a stall) and the in-progress window starts over.
    func noteGeneration(_ newGeneration: UInt64, at nowMs: Double) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        guard generation != newGeneration else { return }
        let first = generation == nil
        generation = newGeneration
        guard !first else { return }
        for i in lastMarkMs.indices { lastMarkMs[i] = nil }
        lastSourceKey = nil
        current.clear(startMs: nowMs)
        addLocked(.generationResets, 1)
    }

    func updateContext(_ mutate: (inout StreamDiagnosticsContext) -> Void) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        let before = context.route
        mutate(&context)
        if before != .unknown, context.route != before {
            addLocked(.routeChanges, 1)
        }
    }

    /// One adaptive controller decision (reason code + evidence). Bounded.
    func recordAdaptiveDecision(_ decision: StreamDiagnosticsAdaptiveDecision) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        adaptiveDecisions.append(decision)
        if adaptiveDecisions.count > StreamDiagnosticsAdaptiveDecision.maxRecorded {
            adaptiveDecisions.removeFirst(adaptiveDecisions.count - StreamDiagnosticsAdaptiveDecision.maxRecorded)
        }
    }

    func updatePeer(_ summary: StreamDiagnosticsPeerSummary, at nowMs: Double = StreamDiagnosticsClock.nowMs()) {
        guard isEnabled else { return }
        lock.lock(); defer { lock.unlock() }
        peer = summary
        peerUpdatedMs = nowMs
    }

    /// Clears everything (a new session).
    func reset(at nowMs: Double = StreamDiagnosticsClock.nowMs()) {
        lock.lock(); defer { lock.unlock() }
        current.clear(startMs: nowMs)
        completed = nil
        completedDurationMs = 0
        for i in session.indices { session[i] = 0 }
        for i in lastMarkMs.indices { lastMarkMs[i] = nil }
        lastSourceKey = nil
        lastRTTMs = nil
        rttJitter = nil
        peer = nil
        peerUpdatedMs = nil
        resources = nil
        generation = nil
        context = StreamDiagnosticsContext()
        adaptiveDecisions = []
        colourStore.clear()
    }

    /// The last completed window, or the in-progress one before any completed.
    func snapshot(at nowMs: Double = StreamDiagnosticsClock.nowMs()) -> StreamDiagnosticsSnapshot {
        lockRotatedAndSampled(nowMs)
        defer { lock.unlock() }
        return snapshotLocked(nowMs)
    }

    /// Performance Lab (read-only): the last completed window with its
    /// sequence number (1, 2, … for this recorder, never reused), its start
    /// on this device's monotonic clock, its raw histograms and the snapshot
    /// built from it. nil before the first window completes. Rotates exactly
    /// like `snapshot(at:)` and records nothing.
    func completedWindowForLab(at nowMs: Double = StreamDiagnosticsClock.nowMs()) -> StreamDiagnosticsCompletedWindow? {
        lockRotatedAndSampled(nowMs)
        defer { lock.unlock() }
        guard let completed else { return nil }
        return StreamDiagnosticsCompletedWindow(
            sequence: completedSequence, startMs: completed.startMs, durationMs: completedDurationMs,
            histograms: completed.histograms, snapshot: snapshotLocked(nowMs))
    }

    private func snapshotLocked(_ nowMs: Double) -> StreamDiagnosticsSnapshot {
        let window: DiagnosticsWindow
        let durationMs: Double
        let partial: Bool
        if let completed {
            window = completed
            durationMs = completedDurationMs
            partial = false
        } else {
            window = current
            durationMs = Swift.max(nowMs - current.startMs, 0)
            partial = true
        }
        let seconds = durationMs / 1000
        let stages = DiagnosticsStage.allCases.map { stage -> StreamDiagnosticsStageSummary in
            let h = window.histograms[stage.rawValue]
            let gaps = window.gaps[stage.rawValue]
            return StreamDiagnosticsStageSummary(
                id: stage.definition.id,
                count: h.count,
                ratePerSecond: seconds > 0 ? Double(h.count) / seconds : 0,
                p50: h.percentile(0.5) ?? 0,
                p95: h.percentile(0.95) ?? 0,
                p99: h.percentile(0.99) ?? 0,
                max: h.max,
                mean: h.mean,
                gapsOver100ms: stage.isInterval ? gaps[0] : nil,
                gapsOver250ms: stage.isInterval ? gaps[1] : nil,
                gapsOver500ms: stage.isInterval ? gaps[2] : nil)
        }
        var counters: [String: Int64] = [:]
        var sessionCounters: [String: Int64] = [:]
        for c in DiagnosticsCounter.allCases {
            counters[c.definition.id] = window.counters[c.rawValue]
            sessionCounters[c.definition.id] = session[c.rawValue]
        }
        let gauges = DiagnosticsGauge.allCases.map { g -> StreamDiagnosticsGaugeSummary in
            let a = window.gauges[g.rawValue]
            return StreamDiagnosticsGaugeSummary(id: g.definition.id, last: a.last, max: a.max, mean: a.mean, samples: a.samples)
        }
        return StreamDiagnosticsSnapshot(
            side: side, windowSeconds: seconds, windowIsPartial: partial, stages: stages,
            counters: counters, sessionCounters: sessionCounters, gauges: gauges,
            rttJitterMs: rttJitter, context: context, peer: peer, resources: resources,
            adaptiveDecisions: adaptiveDecisions.isEmpty ? nil : adaptiveDecisions,
            colour: colourStore.section())
    }

    // MARK: Locked helpers

    private func addLocked(_ counter: DiagnosticsCounter, _ amount: Int64) {
        current.counters[counter.rawValue] &+= amount
        session[counter.rawValue] &+= amount
    }

    private func markLocked(_ stage: DiagnosticsStage, _ nowMs: Double) {
        if let last = lastMarkMs[stage.rawValue] {
            let interval = nowMs - last
            current.histograms[stage.rawValue].record(interval)
            for (i, threshold) in DiagnosticsWindow.gapThresholdsMs.enumerated() where interval > threshold {
                current.gaps[stage.rawValue][i] += 1
            }
        }
        lastMarkMs[stage.rawValue] = nowMs
    }

    /// Releases the lock, then takes a pending resource sample with the
    /// recorder lock NOT held (the sampler reads task info and battery
    /// state), and stores it under the lock again.
    private func unlockAndSampleResources() {
        let sample = needsResourceSample
        needsResourceSample = false
        lock.unlock()
        guard sample, let resourceSampler else { return }
        let value = resourceSampler.sample()
        lock.lock()
        resources = value
        lock.unlock()
    }

    /// Takes the lock, rotates, and (if a window just completed) takes the
    /// resource sample outside the lock before re-locking, so the returned
    /// view includes it. Returns with the lock held.
    private func lockRotatedAndSampled(_ nowMs: Double) {
        lock.lock()
        rotateIfNeeded(nowMs)
        guard needsResourceSample else { return }
        unlockAndSampleResources()
        lock.lock()
    }

    private func clearIntervalBaselines() {
        for i in lastMarkMs.indices { lastMarkMs[i] = nil }
    }

    /// Completes the window once it is `windowMs` old. After a long quiet
    /// spell (two windows or more) the completed window is an empty one: the
    /// last window really had nothing in it.
    ///
    /// Interval baselines restart when diagnostics were switched off and on
    /// again, or after two or more windows with nothing recorded, so the off
    /// (or idle) period is never recorded as one long freeze. A peer summary
    /// with no update for `peerExpiryWindows` windows is dropped.
    private func rotateIfNeeded(_ nowMs: Double) {
        let epoch = diagnosticsSwitch.enableEpoch
        if epoch != seenEnableEpoch {
            seenEnableEpoch = epoch
            clearIntervalBaselines()
        }
        if let updated = peerUpdatedMs, nowMs - updated > Self.peerExpiryWindows * windowMs {
            peer = nil
            peerUpdatedMs = nil
        }
        let age = nowMs - current.startMs
        guard age >= windowMs else { return }
        completedSequence &+= 1
        if age >= 2 * windowMs {
            var empty = current
            empty.clear(startMs: nowMs - windowMs)
            completed = empty
            completedDurationMs = windowMs
            clearIntervalBaselines()
        } else {
            completed = current
            completedDurationMs = age
        }
        current.clear(startMs: nowMs)
        if resourceSampler != nil { needsResourceSample = true }
    }
}
