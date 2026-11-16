// Streaming diagnostics (#123): bottleneck classification.
//
// Evidence, not guesses. A verdict needs its primary signal plus at least one
// independent supporting signal, each read from a metric with enough samples
// in a long-enough window. One high number never names a cause. When the
// data is thin, or nothing qualifies, the answer says so ("unknown" or "no
// bottleneck evident"). Every threshold is a named constant below and is
// reported with the verdict.

import Foundation

enum StreamBottleneckCause: String, Codable, Sendable, CaseIterable {
    case senderCaptureLimited
    case sourceRefreshLimited
    case windowCompositionLimited
    case encoderOverloaded
    case networkDeliveryLimited
    case receiverDecoderOverloaded
    case presentationSchedulingLimited
    /// Enough data, and no cause's evidence qualified.
    case noBottleneckEvident
    /// Not enough data to say anything.
    case unknownInsufficientData
}

enum StreamVerdictConfidence: String, Codable, Sendable { case none, low, medium, high }

/// Why an `unknownInsufficientData` verdict was returned.
enum StreamVerdictReason: String, Codable, Sendable {
    case windowTooShort
    case noTargetFrameRate
    case tooFewSamples
    case sourceIdle
    case conflictingEvidence
}

struct StreamVerdictEvidence: Codable, Equatable, Sendable {
    enum Comparison: String, Codable, Sendable { case atLeast, below }
    /// A metric id from the dictionary, or a derived name listed in `derivedIDs`.
    var metric: String
    var value: Double
    var comparison: Comparison
    var threshold: Double
    var met: Bool
    var fromPeer: Bool
}

struct StreamDiagnosticsVerdict: Codable, Equatable, Sendable {
    var cause: StreamBottleneckCause
    var confidence: StreamVerdictConfidence
    var reason: StreamVerdictReason?
    /// The signals of the chosen cause (met and unmet).
    var evidence: [StreamVerdictEvidence]
    /// Other causes whose evidence also qualified.
    var alternatives: [StreamBottleneckCause]
    var frameBudgetMs: Double?
}

/// The numbers the classifier reads, each from this side's snapshot or the
/// peer's summary. Built by `init(snapshot:)`; tests may build one directly.
struct StreamClassifierInputs: Equatable, Sendable {
    var windowSeconds: Double = 0
    var targetFPS: Double = 0
    var isWindowMode = false
    var sourceRefreshHz: Double?
    // Sender
    var captureCompleteFPS: Double?
    var captureSamples = 0
    var captureIdleShare: Double?
    var submitFPS: Double?
    var encodeP50Ms: Double?
    var encodeP95Ms: Double?
    var encodeSamples = 0
    var encoderBusyShare: Double?
    var sendBackpressureShare: Double?
    var admittedSamples = 0
    var sendP95Ms: Double?
    var sendSamples = 0
    var composeP50Ms: Double?
    var composeP95Ms: Double?
    var composeSamples = 0
    // Receiver
    var arrivalFPS: Double?
    var arrivalP50Ms: Double?
    var arrivalP95Ms: Double?
    var arrivalSamples = 0
    var enqueueFPS: Double?
    var presenterQueueAgeP95Ms: Double?
    var presenterQueueSamples = 0
    var decodeP95Ms: Double?
    var decodeSamples = 0
    var rttJitterMs: Double?
    /// Which fields came from the peer (for the evidence's `fromPeer`).
    var senderFromPeer = false
    var receiverFromPeer = false
}

extension StreamClassifierInputs {
    /// Peer-reported values have no sample counts on the wire; a reported
    /// percentile is trusted as one window's worth of data when the peer's
    /// rate shows at least the minimum number of events in our window.
    init(snapshot: StreamDiagnosticsSnapshot) {
        var i = StreamClassifierInputs()
        i.windowSeconds = snapshot.windowSeconds
        i.isWindowMode = snapshot.context.displayMode == .window
        i.sourceRefreshHz = snapshot.context.sourceRefreshHz
        let w = snapshot.windowSeconds
        func st(_ s: DiagnosticsStage) -> StreamDiagnosticsStageSummary? { snapshot.stage(s) }
        func pct(_ s: DiagnosticsStage, _ k: KeyPath<StreamDiagnosticsStageSummary, Double>) -> Double? {
            st(s).flatMap { $0.count > 0 ? $0[keyPath: k] : nil }
        }
        // Peer values: bounded before any Int conversion (#123 F1).
        func peerCount(_ fps: Double?) -> Int {
            PeerNumber.int(((fps ?? 0) * w).rounded(), in: 0...1_000_000_000) ?? 0
        }

        if snapshot.side == .sender {
            i.targetFPS = Double(snapshot.context.targetFPS)
            let callbacks = snapshot.count(.captureComplete) + snapshot.count(.captureIdle) + snapshot.count(.captureOtherStatus)
            i.captureSamples = Int(callbacks)
            i.captureCompleteFPS = callbacks > 0 ? snapshot.rate(.captureComplete) : nil
            i.captureIdleShare = callbacks > 0 ? Double(snapshot.count(.captureIdle)) / Double(callbacks) : nil
            i.submitFPS = st(.submitInterval)?.ratePerSecond
            i.encodeP50Ms = pct(.encode, \.p50)
            i.encodeP95Ms = pct(.encode, \.p95)
            i.encodeSamples = st(.encode)?.count ?? 0
            let admitted = snapshot.count(.admittedLive)
            i.admittedSamples = Int(admitted)
            i.encoderBusyShare = admitted > 0 ? Double(snapshot.count(.heldEncoderBusy)) / Double(admitted) : nil
            i.sendBackpressureShare = admitted > 0 ? Double(snapshot.count(.droppedPendingSends)) / Double(admitted) : nil
            i.sendP95Ms = pct(.send, \.p95)
            i.sendSamples = st(.send)?.count ?? 0
            i.composeP50Ms = pct(.compose, \.p50)
            i.composeP95Ms = pct(.compose, \.p95)
            i.composeSamples = st(.compose)?.count ?? 0
            if let peer = snapshot.peer, peer.side == .receiver {
                i.receiverFromPeer = true
                i.arrivalFPS = peer.arrivalFPS
                i.arrivalP50Ms = peer.arrivalP50Ms
                i.arrivalP95Ms = peer.arrivalP95Ms
                i.arrivalSamples = peerCount(peer.arrivalFPS)
                i.enqueueFPS = peer.enqueueFPS
                i.presenterQueueAgeP95Ms = peer.presenterQueueAgeP95Ms
                i.presenterQueueSamples = peerCount(peer.enqueueFPS)
                i.decodeP95Ms = peer.decodeP95Ms
                i.decodeSamples = PeerNumber.int(peer.decodeSamples ?? 0, in: 0...1_000_000_000, integral: false) ?? 0
                i.rttJitterMs = peer.rttJitterMs
            }
        } else {
            i.arrivalFPS = snapshot.count(.arrivedFrames) > 0 ? snapshot.rate(.arrivedFrames) : nil
            i.arrivalP50Ms = pct(.arrivalInterval, \.p50)
            i.arrivalP95Ms = pct(.arrivalInterval, \.p95)
            i.arrivalSamples = st(.arrivalInterval)?.count ?? 0
            i.enqueueFPS = snapshot.count(.enqueuedForPresentation) > 0 ? snapshot.rate(.enqueuedForPresentation) : nil
            i.presenterQueueAgeP95Ms = pct(.presenterQueueAge, \.p95)
            i.presenterQueueSamples = st(.presenterQueueAge)?.count ?? 0
            i.decodeP95Ms = pct(.decode, \.p95)
            i.decodeSamples = st(.decode)?.count ?? 0
            i.rttJitterMs = snapshot.rttJitterMs
            if let peer = snapshot.peer, peer.side == .sender {
                i.senderFromPeer = true
                i.targetFPS = peer.targetFPS ?? 0
                i.sourceRefreshHz = i.sourceRefreshHz ?? peer.sourceRefreshHz
                i.captureCompleteFPS = peer.captureCompleteFPS
                i.captureSamples = peerCount(peer.captureCompleteFPS)
                i.captureIdleShare = peer.captureIdleShare
                i.submitFPS = peer.submitFPS
                i.encodeP50Ms = peer.encodeP50Ms
                i.encodeP95Ms = peer.encodeP95Ms
                i.encodeSamples = peerCount(peer.submitFPS)
                i.encoderBusyShare = peer.encoderBusyShare
                i.sendBackpressureShare = peer.sendBackpressureShare
                i.admittedSamples = peerCount(peer.submitFPS)
                i.sendP95Ms = peer.sendP95Ms
                i.sendSamples = peerCount(peer.submitFPS)
                i.composeP95Ms = peer.composeP95Ms
                i.composeSamples = peerCount(peer.composeFPS)
            }
        }
        self = i
    }
}

enum StreamBottleneckClassifier {
    // MARK: Thresholds (named, reported with every verdict)

    /// A window shorter than this says too little about cadence.
    static let minimumWindowSeconds = 2.0
    /// A percentile from fewer samples than this is not used.
    static let minimumSamples = 30
    /// Frames turned away at a stage, as a share of admitted frames, that
    /// counts as that stage refusing work (5%: occasional single drops are normal).
    static let backpressureShare = 0.05
    /// Below this share a stage counts as having headroom.
    static let headroomShare = 0.02
    /// Encode p95 above 1.5 frame budgets: with 2-3 frames in flight one
    /// budget can be exceeded and still keep up; 1.5 cannot for long.
    static let encodeBudgetFactor = 1.5
    /// Delivery or send p95 above two frame budgets.
    static let deliveryBudgetFactor = 2.0
    /// A rate under 90% of what was expected.
    static let rateShortfall = 0.9
    /// Capture under 80% of the source or target rate.
    static let captureShortfall = 0.8
    /// Control-channel jitter that disturbs a 60 FPS cadence.
    static let rttJitterMs = 20.0
    /// Source idle share below which the content counts as changing.
    static let activeSourceIdleShare = 0.1
    /// Below this the source is idle and cadence says nothing.
    static let idleFPS = 1.0
    /// Refresh within 10% of the capture rate: capture follows the display.
    static let refreshMatchTolerance = 0.1

    /// Derived evidence names (not dictionary metrics).
    static let derivedIDs: Set<String> = [
        "derived.encoder_busy_share", "derived.send_backpressure_share", "derived.capture_idle_share",
        "derived.target_fps", "derived.source_refresh_hz", "derived.expected_capture_fps",
    ]

    static func classify(_ snapshot: StreamDiagnosticsSnapshot) -> StreamDiagnosticsVerdict {
        classify(StreamClassifierInputs(snapshot: snapshot))
    }

    static func classify(_ i: StreamClassifierInputs) -> StreamDiagnosticsVerdict {
        func unknown(_ reason: StreamVerdictReason, budget: Double? = nil) -> StreamDiagnosticsVerdict {
            .init(cause: .unknownInsufficientData, confidence: .none, reason: reason, evidence: [], alternatives: [], frameBudgetMs: budget)
        }
        guard i.windowSeconds >= minimumWindowSeconds else { return unknown(.windowTooShort) }
        guard i.targetFPS > 0 else { return unknown(.noTargetFrameRate) }
        let budget = 1000 / i.targetFPS

        // An idle source has no cadence to judge.
        let sourceKnown = i.captureSamples >= minimumSamples || i.arrivalSamples >= minimumSamples || i.composeSamples >= minimumSamples
        let producing = (i.captureCompleteFPS ?? 0) >= idleFPS || (i.arrivalFPS ?? 0) >= idleFPS || (i.submitFPS ?? 0) >= idleFPS
        if !producing, i.captureSamples > 0 || i.arrivalSamples > 0 { return unknown(.sourceIdle, budget: budget) }
        guard sourceKnown else { return unknown(.tooFewSamples, budget: budget) }

        var candidates: [(StreamBottleneckCause, [StreamVerdictEvidence])] = []
        func consider(_ cause: StreamBottleneckCause, _ signals: [StreamVerdictEvidence?]) {
            let present = signals.compactMap { $0 }
            // signals[0] is the primary signal and must be present and met.
            guard let primary = signals.first ?? nil, primary.met else { return }
            let met = present.filter(\.met).count
            guard met >= 2 else { return }
            candidates.append((cause, present))
        }

        // Signal builders: nil when the metric is missing or under-sampled.
        func atLeast(_ id: String, _ value: Double?, _ threshold: Double, samples: Int, peer: Bool) -> StreamVerdictEvidence? {
            guard let value, samples >= minimumSamples else { return nil }
            return .init(metric: id, value: value, comparison: .atLeast, threshold: threshold, met: value >= threshold, fromPeer: peer)
        }
        func below(_ id: String, _ value: Double?, _ threshold: Double, samples: Int, peer: Bool) -> StreamVerdictEvidence? {
            guard let value, samples >= minimumSamples else { return nil }
            return .init(metric: id, value: value, comparison: .below, threshold: threshold, met: value < threshold, fromPeer: peer)
        }
        let sp = i.senderFromPeer, rp = i.receiverFromPeer
        let expectedCapture = min(i.targetFPS, i.sourceRefreshHz ?? i.targetFPS)
        let encoderHeadroom = below("derived.encoder_busy_share", i.encoderBusyShare, headroomShare, samples: i.admittedSamples, peer: sp)
        let sendHeadroom = below("derived.send_backpressure_share", i.sendBackpressureShare, headroomShare, samples: i.admittedSamples, peer: sp)
        let downstreamHeadroom: StreamVerdictEvidence? = {
            guard let e = encoderHeadroom, let s = sendHeadroom else { return nil }
            var combined = e
            combined.met = e.met && s.met
            combined.value = max(e.value, s.value)
            return combined
        }()

        // Source refresh: the captured display refreshes slower than the target.
        if let hz = i.sourceRefreshHz {
            consider(.sourceRefreshLimited, [
                below("derived.source_refresh_hz", hz, i.targetFPS * rateShortfall, samples: minimumSamples, peer: sp),
                atLeast(DiagnosticsCounter.captureComplete.definition.id, i.captureCompleteFPS, hz * (1 - refreshMatchTolerance), samples: i.captureSamples, peer: sp),
                downstreamHeadroom,
            ])
        }
        // Capture: fewer complete frames than expected while content changes
        // and every later stage has room.
        consider(.senderCaptureLimited, [
            below(DiagnosticsCounter.captureComplete.definition.id, i.captureCompleteFPS, expectedCapture * captureShortfall, samples: i.captureSamples, peer: sp),
            below("derived.capture_idle_share", i.captureIdleShare, activeSourceIdleShare, samples: i.captureSamples, peer: sp),
            downstreamHeadroom,
        ])
        // Window view composition.
        if i.isWindowMode {
            consider(.windowCompositionLimited, [
                atLeast(DiagnosticsStage.compose.definition.id, i.composeP95Ms, budget, samples: i.composeSamples, peer: sp),
                atLeast(DiagnosticsStage.compose.definition.id + ".p50", i.composeP50Ms, budget / 2, samples: i.composeSamples, peer: sp),
                // Composites fall short of the target rate.
                below(DiagnosticsCounter.composeFrames.definition.id, Double(i.composeSamples) / i.windowSeconds,
                      i.targetFPS * captureShortfall, samples: i.composeSamples, peer: sp),
            ])
        }
        // Encoder.
        consider(.encoderOverloaded, [
            atLeast("derived.encoder_busy_share", i.encoderBusyShare, backpressureShare, samples: i.admittedSamples, peer: sp),
            atLeast(DiagnosticsStage.encode.definition.id, i.encodeP95Ms, budget * encodeBudgetFactor, samples: i.encodeSamples, peer: sp),
            i.captureCompleteFPS.flatMap { cap in
                below(DiagnosticsStage.submitInterval.definition.id, i.submitFPS, min(i.targetFPS, cap) * rateShortfall, samples: i.captureSamples, peer: sp)
            },
        ])
        // Network delivery / transport backpressure.
        consider(.networkDeliveryLimited, [
            atLeast("derived.send_backpressure_share", i.sendBackpressureShare, backpressureShare, samples: i.admittedSamples, peer: sp),
            atLeast(DiagnosticsStage.send.definition.id, i.sendP95Ms, budget * deliveryBudgetFactor, samples: i.sendSamples, peer: sp),
            atLeast(DiagnosticsStage.arrivalInterval.definition.id, i.arrivalP95Ms, budget * deliveryBudgetFactor, samples: i.arrivalSamples, peer: rp),
            atLeast("receiver.rtt_jitter_ms", i.rttJitterMs, rttJitterMs, samples: i.rttJitterMs == nil ? 0 : minimumSamples, peer: rp),
        ])
        // Receiver-only view of the network: frames arrive irregularly while
        // the sender reports a steady submit rate.
        if i.sendBackpressureShare == nil {
            consider(.networkDeliveryLimited, [
                atLeast(DiagnosticsStage.arrivalInterval.definition.id, i.arrivalP95Ms, budget * deliveryBudgetFactor, samples: i.arrivalSamples, peer: rp),
                atLeast(DiagnosticsStage.submitInterval.definition.id, i.submitFPS, i.targetFPS * rateShortfall, samples: i.encodeSamples, peer: sp),
                atLeast("receiver.rtt_jitter_ms", i.rttJitterMs, rttJitterMs, samples: i.rttJitterMs == nil ? 0 : minimumSamples, peer: rp),
            ])
        }
        // Receiver decode (experimental Metal path only reports decode time).
        consider(.receiverDecoderOverloaded, [
            atLeast(DiagnosticsStage.decode.definition.id, i.decodeP95Ms, budget, samples: i.decodeSamples, peer: rp),
            atLeast(DiagnosticsStage.presenterQueueAge.definition.id, i.presenterQueueAgeP95Ms, budget, samples: i.presenterQueueSamples, peer: rp),
            i.arrivalFPS.flatMap { arr in
                below(DiagnosticsCounter.enqueuedForPresentation.definition.id, i.enqueueFPS, arr * rateShortfall, samples: i.arrivalSamples, peer: rp)
            },
        ])
        // Presentation scheduling: frames arrive on time, then wait.
        consider(.presentationSchedulingLimited, [
            atLeast(DiagnosticsStage.presenterQueueAge.definition.id, i.presenterQueueAgeP95Ms, budget, samples: i.presenterQueueSamples, peer: rp),
            below(DiagnosticsStage.arrivalInterval.definition.id + ".p50", i.arrivalP50Ms, budget * 1.25, samples: i.arrivalSamples, peer: rp),
            i.arrivalFPS.flatMap { arr in
                below(DiagnosticsCounter.enqueuedForPresentation.definition.id, i.enqueueFPS, arr * rateShortfall, samples: i.arrivalSamples, peer: rp)
            },
        ])

        guard !candidates.isEmpty else {
            return .init(cause: .noBottleneckEvident, confidence: .medium, reason: nil, evidence: [], alternatives: [], frameBudgetMs: budget)
        }
        // A decoder verdict explains presenter queueing; prefer it.
        if candidates.contains(where: { $0.0 == .receiverDecoderOverloaded }) {
            candidates.removeAll { $0.0 == .presentationSchedulingLimited }
        }
        // Merge duplicate causes (two network rules), keeping the stronger.
        var best: [StreamBottleneckCause: [StreamVerdictEvidence]] = [:]
        for (cause, ev) in candidates where (best[cause]?.filter(\.met).count ?? -1) < ev.filter(\.met).count {
            best[cause] = ev
        }
        let ranked = best.sorted { a, b in
            let ma = a.value.filter(\.met).count, mb = b.value.filter(\.met).count
            if ma != mb { return ma > mb }
            // Upstream first: a downstream symptom often follows an upstream cause.
            return StreamBottleneckCause.allCases.firstIndex(of: a.key)! < StreamBottleneckCause.allCases.firstIndex(of: b.key)!
        }
        let top = ranked[0]
        let topMet = top.value.filter(\.met).count
        let tied = ranked.dropFirst().filter { $0.value.filter(\.met).count == topMet }
        let confidence: StreamVerdictConfidence = !tied.isEmpty ? .low : (topMet >= 3 ? .high : .medium)
        return .init(cause: top.key, confidence: confidence, reason: tied.isEmpty ? nil : .conflictingEvidence,
                     evidence: top.value, alternatives: ranked.dropFirst().map(\.key), frameBudgetMs: budget)
    }

    /// All thresholds, for the export and the docs.
    static var thresholds: [String: Double] {
        [
            "minimumWindowSeconds": minimumWindowSeconds,
            "minimumSamples": Double(minimumSamples),
            "backpressureShare": backpressureShare,
            "headroomShare": headroomShare,
            "encodeBudgetFactor": encodeBudgetFactor,
            "deliveryBudgetFactor": deliveryBudgetFactor,
            "rateShortfall": rateShortfall,
            "captureShortfall": captureShortfall,
            "rttJitterMs": rttJitterMs,
            "activeSourceIdleShare": activeSourceIdleShare,
            "idleFPS": idleFPS,
            "refreshMatchTolerance": refreshMatchTolerance,
        ]
    }
}
