// Compiled into every app target and MacTests (see project.yml `sources`).
// The adaptive Automatic streaming controller (issue #123). Pure,
// Foundation-only, deterministic: the caller supplies every timestamp, there
// are no timers or globals, and each receiver owns its own value-type
// instance, so controllers can never share mutable state.
//
// Phase 2 wires it per receiver through `AdaptiveStreamingCoordinator`
// (Mac/AdaptiveStreamingSession.swift), behind the Adaptive Automatic (Beta)
// switch; see docs/performance/adaptive-streaming.md for the ladder and
// thresholds.

import Foundation

/// A per-receiver state machine over an operating-point ladder (encoded
/// raster scale, bitrate target, FPS target; the codec stays as negotiated).
///
/// Goals, in order: a readable, sharp image at a sustained 60 unique FPS;
/// then more quality; then 90/120 only with demonstrated headroom and a
/// negotiation ceiling that allows it.
///
/// Causes are told apart before acting:
/// - network backpressure lowers the bitrate (then the raster), keeping FPS;
/// - encoder/decoder overload lowers pixel throughput (raster and/or FPS),
///   never the bitrate;
/// - an idle or low-motion source is not congestion: no downshift and no
///   upshift credit;
/// - serious/critical thermal state takes a protective step and clamps the
///   ladder top.
///
/// Stability: measurement windows, confirmation streaks, minimum dwell,
/// one change per window, bounded single-rung steps, fast protective
/// downshifts, slow upshifts that are probes (confirmed or reverted), a
/// per-dimension probe back-off and an oscillation guard.
struct AdaptiveStreamingController: Sendable {
    typealias Decision = AdaptiveStreamingDecision
    typealias Dimension = AdaptiveStreamingDecision.Dimension
    typealias Reason = AdaptiveStreamingDecision.Reason
    typealias Cause = AdaptiveStreamingDecision.Cause

    struct Configuration: Equatable, Sendable {
        /// Custom bypasses the controller entirely.
        var streamingMode: StreamingMode
        var mode: RefreshNegotiation.DisplayMode
        var negotiation: RefreshNegotiation.Result
        /// The raster at scale 1.0 (today's Best), BEFORE the receiver's
        /// decode ceiling: ladder steps are fractions of this size (#123 A4).
        var nativeEncodeWidth: Int
        var nativeEncodeHeight: Int
        /// The receiver's decode ceiling (`hello.maxEncodeWide/High`), if
        /// any: the encoded raster of a step is clamped to it, like the
        /// sender's capture size.
        var maxEncodeWidth: Int?
        var maxEncodeHeight: Int?
        /// nil = unknown receiver: the conservative fixed floor applies.
        var receiver: AdaptiveReceiverDisplay?
        /// False for a peer that cannot report the windowed receiver
        /// telemetry: the controller then returns today's fixed policy.
        var receiverTelemetryAvailable: Bool
        /// An explicit user choice of operating point; wins over everything.
        var explicitOverride: AdaptiveOperatingPoint?
        var ladder: AdaptiveStreamingLadder
        var thresholds: AdaptiveStreamingThresholds

        init(streamingMode: StreamingMode = .automatic, mode: RefreshNegotiation.DisplayMode,
             negotiation: RefreshNegotiation.Result, nativeEncodeWidth: Int, nativeEncodeHeight: Int,
             receiver: AdaptiveReceiverDisplay?, receiverTelemetryAvailable: Bool,
             explicitOverride: AdaptiveOperatingPoint? = nil,
             ladder: AdaptiveStreamingLadder = .standard,
             thresholds: AdaptiveStreamingThresholds = .standard,
             maxEncodeWidth: Int? = nil, maxEncodeHeight: Int? = nil) {
            self.streamingMode = streamingMode
            self.mode = mode
            self.negotiation = negotiation
            self.nativeEncodeWidth = nativeEncodeWidth
            self.nativeEncodeHeight = nativeEncodeHeight
            self.receiver = receiver
            self.receiverTelemetryAvailable = receiverTelemetryAvailable
            self.explicitOverride = explicitOverride
            self.ladder = ladder
            self.thresholds = thresholds
            self.maxEncodeWidth = maxEncodeWidth
            self.maxEncodeHeight = maxEncodeHeight
        }

        /// The encoded raster for `point`: the ladder fraction of the native
        /// size, then the decode ceiling (as the sender sizes its capture).
        func encodedRaster(_ point: AdaptiveOperatingPoint) -> (width: Int, height: Int) {
            let raster = point.raster(nativeWidth: nativeEncodeWidth, nativeHeight: nativeEncodeHeight)
            return DecodeCeiling.clamp(width: raster.width, height: raster.height,
                                       maxWide: maxEncodeWidth, maxHigh: maxEncodeHeight)
        }
    }

    private enum Direction: Equatable, Sendable {
        case up
        case down
    }

    private struct Probe: Equatable, Sendable {
        let dimension: Dimension
        let previous: AdaptiveOperatingPoint
        var remaining: Int
    }

    private struct Tops: Equatable {
        var raster: Double
        var rasterReason: Reason
        var bitrate: Int
        var bitrateReason: Reason
        var fps: Int
        var fpsReason: Reason
        var allowedFPS: [Int]
    }

    private struct Assessment {
        var cause: Cause
        var severe: Bool
        var evidence: AdaptiveStreamingEvidence
    }

    private struct Step {
        let point: AdaptiveOperatingPoint
        let dimension: Dimension
        let reason: Reason
    }

    private(set) var configuration: Configuration
    /// The managed point (what Automatic runs while managed).
    private(set) var point: AdaptiveOperatingPoint
    private(set) var generation: UInt64
    private(set) var routeEpoch: UInt64

    private var lastChangeAt: TimeInterval?
    private var lastRestartAt: TimeInterval?
    private var lastSampleEnd: TimeInterval?
    private var routeHoldUntil: TimeInterval?
    private var badCause: Cause?
    private var badStreak = 0
    private var healthyStreak = 0
    private var baselineRttMs: Double?
    private var probe: Probe?
    private var dimensionBackoffUntil: [Dimension: TimeInterval] = [:]
    private var dimensionBackoffSeconds: [Dimension: TimeInterval] = [:]
    private var lastDirection: Direction?
    private var flipTimes: [TimeInterval] = []
    private var oscillationBackoffUntil: TimeInterval?
    private var oscillationBackoffSeconds: TimeInterval
    private var thermal: AdaptiveThermalLevel = .nominal
    private var power: AdaptivePowerState = .normal
    private var dataPolicy: NetworkCost.DataPolicy
    private var visiblePanes = 1

    init(configuration: Configuration, generation: UInt64 = 0, routeEpoch: UInt64 = 0,
         dataPolicy: NetworkCost.DataPolicy = .normal) {
        self.configuration = configuration
        self.generation = generation
        self.routeEpoch = routeEpoch
        self.dataPolicy = dataPolicy
        self.oscillationBackoffSeconds = configuration.thresholds.oscillationBackoffBaseSeconds
        self.point = AdaptiveOperatingPoint(rasterScale: 1, bitrate: configuration.ladder.startBitrate, fps: 60)
        self.point = initialPoint()
    }

    // MARK: - Public API

    /// Today's fixed Automatic policy for this negotiation: Best quality
    /// (native raster, 18 Mbps) at today's frame rate.
    static func fixedAutomaticPoint(_ negotiation: RefreshNegotiation.Result) -> AdaptiveOperatingPoint {
        AdaptiveOperatingPoint(rasterScale: AdaptiveStreamingLadder.fixedPolicyRaster,
                               bitrate: AdaptiveStreamingLadder.fixedPolicyBitrate,
                               fps: negotiation.legacyFPS)
    }

    /// The point the pipeline should run now, or nil in Custom mode.
    var effectivePoint: AdaptiveOperatingPoint? {
        if let decision = unmanagedDecision() { return decision.point }
        return point
    }

    /// The lowest raster the controller uses while a lower FPS or bitrate
    /// option remains, from the receiver's physical size and density.
    var rasterFloor: Double {
        let t = configuration.thresholds
        let steps = configuration.ladder.rasterSteps
        guard let receiver = configuration.receiver, receiver.pointsWide > 0, receiver.pointsHigh > 0,
              configuration.nativeEncodeWidth > 0, configuration.nativeEncodeHeight > 0 else {
            return Self.stepAtOrAbove(t.unknownReceiverRasterFloor, in: steps)
        }
        let classPPP: Double
        switch receiver.sizeClass {
        case .phone: classPPP = t.phonePixelsPerPoint
        case .tablet: classPPP = t.tabletPixelsPerPoint
        case .desktop: classPPP = t.desktopPixelsPerPoint
        }
        // More pixels per point than the screen has can't add legibility.
        let pixelsPerPoint = min(classPPP, max(receiver.scale, 1))
        let aspect = Double(configuration.nativeEncodeWidth) / Double(configuration.nativeEncodeHeight)
        let displayedWidthPoints = min(Double(receiver.pointsWide), Double(receiver.pointsHigh) * aspect)
        let needed = pixelsPerPoint * displayedWidthPoints / Double(configuration.nativeEncodeWidth)
        return Self.stepAtOrAbove(needed, in: steps)
    }

    /// The decision for a freshly created controller.
    func initialDecision() -> Decision {
        if let decision = unmanagedDecision() { return decision }
        return Decision(action: .initial, point: point, previous: nil, changed: [], cost: .none,
                        reason: .initialPoint, cause: .none, evidence: baseEvidence())
    }

    /// Feeds one measurement window. Returns at most one change.
    mutating func ingest(_ sample: AdaptiveStreamingSample) -> Decision {
        if let decision = unmanagedDecision() { return decision }
        let t = configuration.thresholds

        if sample.generation < generation { return hold(.staleGeneration, cause: .stale) }
        if sample.generation > generation {
            return reset(generation: sample.generation, routeEpoch: max(routeEpoch, sample.routeEpoch),
                         now: sample.windowEnd)
        }
        if sample.routeEpoch < routeEpoch { return hold(.staleRouteEpoch, cause: .stale) }
        if sample.routeEpoch > routeEpoch {
            let routeDecision = routeDidChange(epoch: sample.routeEpoch, now: sample.windowEnd)
            lastSampleEnd = sample.windowEnd
            return routeDecision
        }
        guard sample.mode == configuration.mode,
              sample.duration >= t.minWindowSeconds, sample.duration <= t.maxWindowSeconds,
              lastSampleEnd.map({ sample.windowEnd > $0 }) ?? true else {
            return hold(.insufficientData, cause: .insufficientData)
        }
        if let last = lastSampleEnd, sample.windowStart - last >= t.dropoutResetSeconds {
            clearStreaks()
        }
        lastSampleEnd = sample.windowEnd
        let now = sample.windowEnd

        thermal = max(sample.senderThermal ?? .nominal, sample.receiverThermal ?? .nominal)
        power = sample.power
        dataPolicy = sample.dataPolicy
        visiblePanes = max(sample.activePaneCount, 0) + max(sample.floatingPaneCount, 0)

        if let clamp = clampToTops(now: now) { return clamp }
        if let until = routeHoldUntil, now < until { return hold(.routeChangeSettling, cause: .stale) }
        routeHoldUntil = nil

        let assessment = classify(sample)
        updateBaseline(sample, cause: assessment.cause)

        if let decision = handleProbe(assessment, now: now) { return decision }

        switch assessment.cause {
        case .thermal, .encoder, .decoder, .network:
            return handleProblem(assessment, now: now)
        case .sourceLimited:
            badCause = nil
            badStreak = 0
            return hold(.sourceLimited, cause: .sourceLimited, evidence: assessment.evidence)
        case .healthy:
            return handleHealthy(assessment, sample: sample, now: now)
        case .none:
            badCause = nil
            badStreak = 0
            return hold(.noHeadroom, cause: .none, evidence: assessment.evidence)
        case .insufficientData, .stale:
            return hold(.insufficientData, cause: assessment.cause, evidence: assessment.evidence)
        }
    }

    /// Call between samples (e.g. on the caller's own stats tick). Holds,
    /// reporting stale telemetry once no sample has arrived for
    /// `staleAfterSeconds`; a long dropout also discards streaks so old
    /// evidence can't earn an upshift.
    mutating func tick(now: TimeInterval) -> Decision {
        if let decision = unmanagedDecision() { return decision }
        let t = configuration.thresholds
        guard let last = lastSampleEnd else { return hold(.insufficientData, cause: .insufficientData) }
        let gap = now - last
        if gap >= t.dropoutResetSeconds { clearStreaks() }
        if gap >= t.staleAfterSeconds { return hold(.staleTelemetry, cause: .stale) }
        return hold(.insufficientData, cause: .none)
    }

    /// A route change from the transport. Older or equal epochs are stale
    /// callbacks and change nothing. A newer epoch starts a short
    /// re-evaluation hold, forgets route-specific evidence, and reverts an
    /// unconfirmed probe.
    mutating func routeDidChange(epoch: UInt64, now: TimeInterval) -> Decision {
        if let decision = unmanagedDecision() { return decision }
        guard epoch > routeEpoch else { return hold(.staleRouteEpoch, cause: .stale) }
        routeEpoch = epoch
        routeHoldUntil = now + configuration.thresholds.routeChangeHoldSeconds
        clearStreaks()
        baselineRttMs = nil
        if let pending = probe {
            probe = nil
            return change(to: pending.previous, dimensions: [pending.dimension], action: .probeRevert,
                          reason: .routeChangeSettling, cause: .stale, now: now, evidence: baseEvidence(),
                          direction: nil)
        }
        return hold(.routeChangeSettling, cause: .stale)
    }

    /// Reconnect or a new stream generation: back to the initial point with
    /// no history. The returned decision rides on the restart that caused
    /// it, so its cost is `.none`.
    mutating func reset(generation: UInt64, routeEpoch: UInt64? = nil, now: TimeInterval) -> Decision {
        self.generation = generation
        if let routeEpoch { self.routeEpoch = routeEpoch }
        lastChangeAt = nil
        lastRestartAt = now
        lastSampleEnd = nil
        routeHoldUntil = nil
        clearStreaks()
        baselineRttMs = nil
        probe = nil
        dimensionBackoffUntil = [:]
        dimensionBackoffSeconds = [:]
        lastDirection = nil
        flipTimes = []
        oscillationBackoffUntil = nil
        oscillationBackoffSeconds = configuration.thresholds.oscillationBackoffBaseSeconds
        if let decision = unmanagedDecision() { return decision }
        let previous = point
        point = initialPoint()
        return Decision(action: .reset, point: point, previous: previous,
                        changed: Self.changedDimensions(previous, point), cost: .none,
                        reason: .generationReset, cause: .none, evidence: baseEvidence())
    }

    /// A data-policy change from outside the samples ("Use less data", Low
    /// Data Mode). Keeps every bit of history (restart time, backoffs,
    /// streaks); turning saver on clamps the point to the saver tops at
    /// once, turning it off lifts the tops and leaves the point where it is
    /// (upshifts then follow the usual rules).
    mutating func setDataPolicy(_ policy: NetworkCost.DataPolicy, now: TimeInterval) -> Decision {
        dataPolicy = policy
        if let decision = unmanagedDecision() { return decision }
        if let clamp = clampToTops(now: now) { return clamp }
        return hold(.healthy, cause: .none)
    }

    /// New configuration (negotiation, Custom/Automatic, override, receiver).
    /// Going from unmanaged to managed starts again from the initial point;
    /// otherwise the current point is clamped to the new ladder top.
    mutating func reconfigure(_ newConfiguration: Configuration, now: TimeInterval) -> Decision {
        let wasManaged = unmanagedDecision() == nil
        configuration = newConfiguration
        if let decision = unmanagedDecision() { return decision }
        if !wasManaged { return reset(generation: generation, now: now) }
        if let clamp = clampToTops(now: now) { return clamp }
        return hold(.healthy, cause: .none)
    }

    // MARK: - Management

    private func unmanagedDecision() -> Decision? {
        if configuration.streamingMode == .custom {
            return Decision(action: .bypass, point: nil, previous: nil, changed: [], cost: .none,
                            reason: .customModeBypass, cause: .none, evidence: AdaptiveStreamingEvidence())
        }
        if let override = configuration.explicitOverride {
            return Decision(action: .bypass, point: override, previous: nil, changed: [], cost: .none,
                            reason: .userOverride, cause: .none, evidence: AdaptiveStreamingEvidence())
        }
        if !configuration.receiverTelemetryAvailable {
            return Decision(action: .fixedPolicy, point: Self.fixedAutomaticPoint(configuration.negotiation),
                            previous: nil, changed: [], cost: .none, reason: .legacyPeerFixedPolicy,
                            cause: .none, evidence: AdaptiveStreamingEvidence())
        }
        return nil
    }

    private func initialPoint() -> AdaptiveOperatingPoint {
        let tops = currentTops()
        let ladder = configuration.ladder
        let fps = tops.allowedFPS.last { $0 <= configuration.negotiation.initialTargetFPS }
            ?? tops.allowedFPS.first ?? configuration.negotiation.initialTargetFPS
        let raster = Self.stepAtOrBelow(min(ladder.startRaster, tops.raster), in: ladder.rasterSteps)
        let bitrate = Self.stepAtOrBelow(min(ladder.startBitrate, tops.bitrate), in: ladder.bitrateSteps)
        return AdaptiveOperatingPoint(rasterScale: raster, bitrate: bitrate, fps: fps)
    }

    // MARK: - Ladder tops (data saver, thermal, power, panes, negotiation)

    private func currentTops() -> Tops {
        let t = configuration.thresholds
        let ladder = configuration.ladder
        let floor = rasterFloor
        var tops = Tops(raster: ladder.rasterSteps.last ?? 1, rasterReason: .ceilingClamp,
                        bitrate: ladder.bitrateSteps.last ?? ladder.startBitrate, bitrateReason: .ceilingClamp,
                        fps: configuration.negotiation.capabilityCeilingFPS, fpsReason: .ceilingClamp,
                        allowedFPS: [])
        func lowerFPS(_ value: Int, _ reason: Reason) {
            if value < tops.fps { tops.fps = value; tops.fpsReason = reason }
        }
        func lowerRaster(_ value: Double, _ reason: Reason) {
            if value < tops.raster - 1e-9 { tops.raster = value; tops.rasterReason = reason }
        }
        if dataPolicy == .saver {
            lowerRaster(max(floor, ladder.saverRasterTop), .dataSaverClamp)
            if ladder.saverBitrateTop < tops.bitrate {
                tops.bitrate = ladder.saverBitrateTop
                tops.bitrateReason = .dataSaverClamp
            }
            lowerFPS(ladder.saverFPSTop, .dataSaverClamp)
        }
        if thermal >= .serious {
            lowerFPS(thermal == .critical ? t.thermalCriticalFPSTop : t.thermalSeriousFPSTop, .thermalClamp)
        }
        if thermal == .critical { lowerRaster(max(floor, t.thermalCriticalRasterTop), .thermalClamp) }
        if power == .lowPower { lowerFPS(t.lowPowerFPSTop, .powerClamp) }
        if configuration.mode == .window, visiblePanes > t.windowMaxPanesForHighRefresh {
            lowerFPS(RefreshNegotiation.firstTargetFPS, .paneClamp)
        }
        let allowed = configuration.negotiation.allowedTargets
        tops.allowedFPS = allowed.filter { $0 <= tops.fps }
        if tops.allowedFPS.isEmpty, let lowest = allowed.first { tops.allowedFPS = [lowest] }
        return tops
    }

    private mutating func clampToTops(now: TimeInterval) -> Decision? {
        let tops = currentTops()
        var clamped = point
        var reasons: [Reason] = []
        if clamped.fps > (tops.allowedFPS.last ?? clamped.fps) || !tops.allowedFPS.contains(clamped.fps) {
            clamped.fps = tops.allowedFPS.last { $0 <= clamped.fps } ?? tops.allowedFPS.first ?? clamped.fps
            if clamped.fps != point.fps { reasons.append(tops.fpsReason) }
        }
        if clamped.rasterScale > tops.raster + 1e-9 {
            clamped.rasterScale = Self.stepAtOrBelow(tops.raster, in: configuration.ladder.rasterSteps)
            reasons.append(tops.rasterReason)
        }
        if clamped.bitrate > tops.bitrate {
            clamped.bitrate = Self.stepAtOrBelow(tops.bitrate, in: configuration.ladder.bitrateSteps)
            reasons.append(tops.bitrateReason)
        }
        guard clamped != point else { return nil }
        let priority: [Reason] = [.thermalClamp, .dataSaverClamp, .powerClamp, .paneClamp, .ceilingClamp]
        let reason = priority.first { reasons.contains($0) } ?? .ceilingClamp
        probe = nil
        clearStreaks()
        // A clamp only ever lowers the point: it counts as a downward move
        // for the oscillation guard (#123 A3), and a raster clamp records the
        // restart time in `change`.
        return change(to: clamped, dimensions: Self.changedDimensions(point, clamped), action: .policyClamp,
                      reason: reason, cause: thermal >= .serious ? .thermal : .none, now: now,
                      evidence: baseEvidence(), direction: .down)
    }

    // MARK: - Classification

    private func classify(_ s: AdaptiveStreamingSample) -> Assessment {
        let t = configuration.thresholds
        let fps = Double(point.fps)
        let intervalMs = 1000 / max(fps, 1)
        let expected = min(fps, s.sourceUniqueFPS ?? fps)
        let delivered = s.enqueuedFPS ?? s.decodedFPS ?? s.deliveredFPS
        let expectedFrames = max(expected * s.duration, 1)
        let networkDrops = Double(s.drops.network) / expectedFrames
        let encoderDrops = Double(s.drops.encoder) / expectedFrames
        let maxThermal = max(s.senderThermal ?? .nominal, s.receiverThermal ?? .nominal)

        var evidence = baseEvidence()
        evidence.windowSeconds = s.duration
        evidence.expectedFPS = expected
        evidence.deliveredUniqueFPS = delivered.map { min($0, expected) }
        evidence.sourceUniqueFPS = s.sourceUniqueFPS
        evidence.rttMs = s.rttMs
        evidence.jitterMs = s.jitterMs
        evidence.sendBackpressure = s.sendBackpressure
        evidence.encodeQueueAgeMs = s.encodeQueueAgeMs
        evidence.decodeTimeP95Ms = s.decodeTimeP95Ms
        evidence.presentationQueueAgeMs = s.presentationQueueAgeMs
        evidence.networkDropFraction = networkDrops
        evidence.encoderDropFraction = encoderDrops
        evidence.thermal = maxThermal

        guard let delivered else { return Assessment(cause: .insufficientData, severe: false, evidence: evidence) }

        if maxThermal >= .serious {
            return Assessment(cause: .thermal, severe: maxThermal == .critical, evidence: evidence)
        }

        // Ratios only mean something when enough frames were expected.
        let ratiosValid = expected >= Self.minExpectedFPSForRatios
        let deliveredRatio = ratiosValid ? delivered / expected : 1
        let backpressure = s.sendBackpressure ?? 0
        let severe = backpressure >= t.severeBackpressure
            || (s.stallCount ?? 0) >= t.severeStallsPerWindow
            || (ratiosValid && deliveredRatio < t.severeDeliveryRatio)

        let encoderOverloaded = (s.encodeQueueAgeMs.map { $0 > t.encodeQueueAgeFrameIntervals * intervalMs } ?? false)
            || encoderDrops >= t.encoderDropFraction
            || (ratiosValid && backpressure < t.backpressureDownshift
                && (s.encodedFPS.map { $0 / expected < t.encodedRatio } ?? false))
        if encoderOverloaded { return Assessment(cause: .encoder, severe: severe, evidence: evidence) }

        let decodedShort: Bool
        if ratiosValid, let decoded = s.decodedFPS, let arrived = s.deliveredFPS, arrived > 0 {
            decodedShort = decoded / arrived < t.decodedRatio
        } else {
            decodedShort = false
        }
        let presentationLimit = max(t.presentationQueueFrameIntervals * intervalMs, t.presentationQueueMinMs)
        let decoderOverloaded = (s.decodeTimeP95Ms.map { $0 > t.decodeBudgetFraction * intervalMs } ?? false)
            || decodedShort
            || (s.presentationQueueAgeMs.map { $0 > presentationLimit } ?? false)
        if decoderOverloaded { return Assessment(cause: .decoder, severe: severe, evidence: evidence) }

        let lateDelivery = ratiosValid && deliveredRatio < t.lateDeliveryRatio
        let rttInflated: Bool
        if let rtt = s.rttMs, let baseline = baselineRttMs {
            rttInflated = rtt > baseline * t.rttInflationFactor && rtt - baseline > t.rttInflationMinMs
        } else {
            rttInflated = false
        }
        let jittery = s.jitterMs.map { $0 > t.jitterFrameIntervals * intervalMs } ?? false
        let networkLimited = backpressure >= t.backpressureDownshift
            || networkDrops >= t.networkDropFraction
            || (rttInflated && lateDelivery)
            || (jittery && lateDelivery)
        if networkLimited { return Assessment(cause: .network, severe: severe, evidence: evidence) }

        if let source = s.sourceUniqueFPS, source < t.sourceIdleRatio * fps {
            return Assessment(cause: .sourceLimited, severe: false, evidence: evidence)
        }
        if deliveredRatio >= t.healthyDeliveryRatio {
            return Assessment(cause: .healthy, severe: false, evidence: evidence)
        }
        // Short delivery with no attributable cause: hold, no credit.
        return Assessment(cause: .none, severe: false, evidence: evidence)
    }

    /// Below this many expected frames per second, delivery ratios are too
    /// noisy to classify on.
    static let minExpectedFPSForRatios = 10.0
    /// Healthy windows let the RTT baseline drift up by this fraction.
    static let baselineRttDriftFraction = 0.05

    private mutating func updateBaseline(_ s: AdaptiveStreamingSample, cause: Cause) {
        guard let rtt = s.rttMs, rtt > 0 else { return }
        guard let baseline = baselineRttMs else {
            if cause != .network { baselineRttMs = rtt }
            return
        }
        if rtt < baseline {
            baselineRttMs = rtt
        } else if cause == .healthy || cause == .sourceLimited {
            baselineRttMs = baseline + (rtt - baseline) * Self.baselineRttDriftFraction
        }
    }

    // MARK: - Probe, problem and healthy handling

    private mutating func handleProbe(_ assessment: Assessment, now: TimeInterval) -> Decision? {
        guard var pending = probe else { return nil }
        switch assessment.cause {
        case .thermal, .encoder, .decoder, .network, .none:
            // `.none` is short delivery with no attributable cause. Before the
            // probe the windows were healthy, so the probe is the likely
            // cause: with partial evidence (no decode time on the default
            // receiver path) this is the only sign an upshift overloaded the
            // receiver, and holding would keep the bad point forever (#123 A1).
            probe = nil
            clearStreaks()
            startBackoff(pending.dimension, now: now)
            return change(to: pending.previous, dimensions: Self.changedDimensions(point, pending.previous),
                          action: .probeRevert, reason: .probeFailedRevert, cause: assessment.cause,
                          now: now, evidence: assessment.evidence, direction: .down)
        case .healthy:
            pending.remaining -= 1
            if pending.remaining <= 0 {
                probe = nil
                dimensionBackoffSeconds[pending.dimension] = nil
                return hold(.probeConfirmed, cause: .healthy, evidence: assessment.evidence)
            }
            probe = pending
            return hold(.probeConfirming, cause: .healthy, evidence: assessment.evidence)
        case .sourceLimited, .insufficientData, .stale:
            // An idle source can't confirm a probe; keep waiting.
            return hold(.probeConfirming, cause: assessment.cause, evidence: assessment.evidence)
        }
    }

    private mutating func handleProblem(_ assessment: Assessment, now: TimeInterval) -> Decision {
        let t = configuration.thresholds
        healthyStreak = 0
        if badCause == assessment.cause {
            badStreak += 1
        } else {
            badCause = assessment.cause
            badStreak = 1
        }
        var evidence = assessment.evidence
        evidence.badStreak = badStreak
        let needed = assessment.severe ? 1 : t.downshiftConfirmWindows
        guard badStreak >= needed else {
            return hold(.confirmingDownshift, cause: assessment.cause, evidence: evidence)
        }
        switch downshiftStep(for: assessment.cause, severe: assessment.severe, now: now) {
        case .success(let step):
            badStreak = 0
            badCause = nil
            return change(to: step.point, dimensions: [step.dimension], action: .downshift, reason: step.reason,
                          cause: assessment.cause, now: now, evidence: evidence, direction: .down)
        case .failure(let failure):
            return hold(failure.reason, cause: assessment.cause, evidence: evidence)
        }
    }

    private mutating func handleHealthy(_ assessment: Assessment, sample: AdaptiveStreamingSample,
                                        now: TimeInterval) -> Decision {
        let t = configuration.thresholds
        badCause = nil
        badStreak = 0
        healthyStreak += 1
        var evidence = assessment.evidence
        evidence.healthyStreak = healthyStreak
        guard healthyStreak >= t.upshiftConfirmWindows else {
            return hold(.healthy, cause: .healthy, evidence: evidence)
        }
        if let last = lastChangeAt, now - last < t.minDwellSeconds {
            return hold(.dwell, cause: .healthy, evidence: evidence)
        }
        if let until = oscillationBackoffUntil, now < until {
            return hold(.oscillationBackoff, cause: .healthy, evidence: evidence)
        }
        switch upshiftStep(sample: sample, now: now) {
        case .success(let step):
            healthyStreak = 0
            let previous = point
            let decision = change(to: step.point, dimensions: [step.dimension], action: .upshift,
                                  reason: step.reason, cause: .healthy, now: now, evidence: evidence,
                                  direction: .up)
            probe = Probe(dimension: step.dimension, previous: previous, remaining: t.probeConfirmWindows)
            return decision
        case .failure(let failure):
            return hold(failure.reason, cause: .healthy, evidence: evidence)
        }
    }

    // MARK: - Steps

    private struct StepFailure: Error {
        let reason: Reason
    }

    private func downshiftStep(for cause: Cause, severe: Bool, now: TimeInterval) -> Result<Step, StepFailure> {
        let t = configuration.thresholds
        let floor = rasterFloor
        let tops = currentTops()
        let allowed = tops.allowedFPS
        let ladder = configuration.ladder
        var rateLimited = false

        func fpsDown(onlyAbove60: Bool, _ reason: Reason) -> Step? {
            if onlyAbove60 && point.fps <= RefreshNegotiation.firstTargetFPS { return nil }
            guard let lower = allowed.last(where: { $0 < point.fps }) else { return nil }
            if onlyAbove60 && lower < RefreshNegotiation.firstTargetFPS && allowed.contains(RefreshNegotiation.firstTargetFPS) {
                return nil
            }
            var next = point
            next.fps = lower
            return Step(point: next, dimension: .fps, reason: reason)
        }
        func rasterDown(belowFloor: Bool, _ reason: Reason) -> Step? {
            guard let lower = ladder.rasterSteps.last(where: { $0 < point.rasterScale - 1e-9 }) else { return nil }
            if !belowFloor && lower < floor - 1e-9 { return nil }
            if belowFloor && lower >= floor - 1e-9 { return nil }
            if let last = lastRestartAt,
               now - last < (severe ? t.protectiveRestartIntervalSeconds : t.minRestartIntervalSeconds) {
                rateLimited = true
                return nil
            }
            var next = point
            next.rasterScale = lower
            return Step(point: next, dimension: .raster, reason: reason)
        }
        func bitrateDown(respectBitsPerPixel: Bool, _ reason: Reason) -> Step? {
            guard let lower = ladder.bitrateSteps.last(where: { $0 < point.bitrate }) else { return nil }
            if respectBitsPerPixel {
                let raster = configuration.encodedRaster(point)
                let pixelRate = Double(raster.width) * Double(raster.height) * Double(max(point.fps, 1))
                if Double(lower) / pixelRate < t.minBitsPerPixel { return nil }
            }
            var next = point
            next.bitrate = lower
            return Step(point: next, dimension: .bitrate, reason: reason)
        }

        let candidates: [() -> Step?]
        switch cause {
        case .network:
            candidates = [
                { bitrateDown(respectBitsPerPixel: true, .networkBitrateDown) },
                { fpsDown(onlyAbove60: true, .networkFPSDown) },
                { rasterDown(belowFloor: false, .networkRasterDown) },
                { fpsDown(onlyAbove60: false, .networkFPSDown) },
                { bitrateDown(respectBitsPerPixel: false, .networkBitrateDown) },
                { rasterDown(belowFloor: true, .lastResortRasterBelowFloor) },
            ]
        case .encoder, .decoder:
            candidates = [
                { fpsDown(onlyAbove60: true, .overloadFPSDown) },
                { rasterDown(belowFloor: false, .overloadRasterDown) },
                { fpsDown(onlyAbove60: false, .overloadFPSDown) },
                { rasterDown(belowFloor: true, .lastResortRasterBelowFloor) },
            ]
        case .thermal:
            candidates = [
                { fpsDown(onlyAbove60: true, .thermalFPSDown) },
                { rasterDown(belowFloor: false, .thermalRasterDown) },
                { fpsDown(onlyAbove60: false, .thermalFPSDown) },
            ]
        default:
            candidates = []
        }
        // A rate-limited raster step holds rather than skipping ahead to a
        // costlier fallback (60 → 30 FPS) the ladder order puts after it.
        for candidate in candidates {
            if let step = candidate() { return .success(step) }
            if rateLimited { return .failure(StepFailure(reason: .restartRateLimited)) }
        }
        return .failure(StepFailure(reason: .noLowerOption))
    }

    /// What the pipeline evidence says about a step's extra pixel or frame
    /// load. `unknown`: part of the evidence is missing (the default
    /// display-layer receiver path reports no decode time), which is handled
    /// explicitly rather than read as "no headroom" (#123 A1).
    private enum PipelineHeadroom {
        case yes
        case no
        case unknown
    }

    /// Ladder order: raster up to the readability floor, FPS up to 60, raster
    /// up, bitrate up, then 90/120. The first step that has headroom is
    /// taken. A raster step that can't rise (no headroom, or the restart
    /// limit) falls through to the cheaper bitrate step (#123 A1); 90/120 is
    /// only tried once nothing below it is waiting.
    private func upshiftStep(sample s: AdaptiveStreamingSample, now: TimeInterval) -> Result<Step, StepFailure> {
        let t = configuration.thresholds
        let tops = currentTops()
        let floor = rasterFloor
        let ladder = configuration.ladder
        let first = RefreshNegotiation.firstTargetFPS

        func inBackoff(_ dimension: Dimension) -> Bool {
            dimensionBackoffUntil[dimension].map { now < $0 } ?? false
        }
        func pixels(_ p: AdaptiveOperatingPoint) -> Double {
            let raster = configuration.encodedRaster(p)
            return Double(raster.width) * Double(raster.height)
        }
        func networkHeadroom(newFPS: Int) -> Bool {
            guard let backpressure = s.sendBackpressure, backpressure <= t.headroomBackpressure,
                  let rtt = s.rttMs, let baseline = baselineRttMs,
                  rtt <= baseline * t.headroomRttFactor + t.headroomRttSlackMs else { return false }
            if let jitter = s.jitterMs, jitter > t.headroomJitterFrameIntervals * 1000 / Double(newFPS) {
                return false
            }
            return true
        }
        func pipelineHeadroom(_ next: AdaptiveOperatingPoint) -> PipelineHeadroom {
            let pixelScale = pixels(next) / max(pixels(point), 1)
            let intervalMs = 1000 / Double(max(next.fps, 1))
            var unknown = false
            if let encodeAge = s.encodeQueueAgeMs {
                let budget = t.headroomPipelineFraction * t.encodeQueueAgeFrameIntervals * intervalMs
                if encodeAge * pixelScale > budget { return .no }
            } else {
                unknown = true
            }
            if let decode = s.decodeTimeP95Ms {
                if decode * pixelScale > t.headroomPipelineFraction * intervalMs { return .no }
            } else {
                unknown = true
            }
            return unknown ? .unknown : .yes
        }
        /// Full evidence: the pipeline check alone. Partial evidence: the
        /// network must also show headroom, and the longer dwell applies.
        func admits(_ next: AdaptiveOperatingPoint) -> Result<Void, StepFailure> {
            switch pipelineHeadroom(next) {
            case .yes:
                return .success(())
            case .no:
                return .failure(StepFailure(reason: .noHeadroom))
            case .unknown:
                if let last = lastChangeAt, now - last < t.minDwellSecondsWithoutPipelineEvidence {
                    return .failure(StepFailure(reason: .dwell))
                }
                return networkHeadroom(newFPS: next.fps) ? .success(()) : .failure(StepFailure(reason: .noHeadroom))
            }
        }
        func rasterUp(_ reason: Reason) -> Result<Step, StepFailure>? {
            guard !inBackoff(.raster),
                  let higher = ladder.rasterSteps.first(where: { $0 > point.rasterScale + 1e-9 }),
                  higher <= tops.raster + 1e-9 else { return nil }
            var next = point
            next.rasterScale = higher
            if let last = lastRestartAt, now - last < t.minRestartIntervalSeconds {
                return .failure(StepFailure(reason: .restartRateLimited))
            }
            guard networkHeadroom(newFPS: next.fps) else { return .failure(StepFailure(reason: .noHeadroom)) }
            if case .failure(let failure) = admits(next) { return .failure(failure) }
            return .success(Step(point: next, dimension: .raster, reason: reason))
        }
        func fpsUp(limit: Int, _ reason: Reason) -> Result<Step, StepFailure>? {
            guard !inBackoff(.fps), let higher = tops.allowedFPS.first(where: { $0 > point.fps }),
                  higher <= limit else { return nil }
            var next = point
            next.fps = higher
            // The capture is configured at the current target, so it can
            // never show more source frames than that: the evidence that
            // the source has more to give is a saturated capture (#123 A1).
            // Whether the source can reach the tier at all is already in the
            // negotiation (`allowedTargets`: 90/120 only from a source whose
            // refresh supports them).
            let saturated = { (captured: Double) in captured >= t.highRefreshSourceRatio * Double(point.fps) }
            let sourceSupports: Bool
            if higher > first {
                sourceSupports = s.sourceUniqueFPS.map(saturated) ?? false
            } else {
                sourceSupports = s.sourceUniqueFPS.map(saturated) ?? true
            }
            guard sourceSupports, higher <= first || networkHeadroom(newFPS: higher) else {
                return .failure(StepFailure(reason: .noHeadroom))
            }
            if case .failure(let failure) = admits(next) { return .failure(failure) }
            return .success(Step(point: next, dimension: .fps, reason: reason))
        }
        func bitrateUp() -> Result<Step, StepFailure>? {
            guard !inBackoff(.bitrate), let higher = ladder.bitrateSteps.first(where: { $0 > point.bitrate }),
                  higher <= tops.bitrate else { return nil }
            var next = point
            next.bitrate = higher
            guard networkHeadroom(newFPS: next.fps) else { return .failure(StepFailure(reason: .noHeadroom)) }
            return .success(Step(point: next, dimension: .bitrate, reason: .upshiftBitrate))
        }

        var firstFailure: StepFailure?
        func take(_ result: Result<Step, StepFailure>?) -> Step? {
            switch result {
            case .success(let step)?:
                return step
            case .failure(let failure)?:
                if firstFailure == nil { firstFailure = failure }
                return nil
            case nil:
                return nil
            }
        }

        // 1. Back up to the readability floor.
        if point.rasterScale < floor - 1e-9, let step = take(rasterUp(.upshiftRaster)) { return .success(step) }
        // 2. Sustained 60.
        if let step = take(fpsUp(limit: first, .upshiftFPS)) { return .success(step) }
        // 3. Sharper raster; 4. more bits (also when the raster can't rise).
        if let step = take(rasterUp(.upshiftRaster)) { return .success(step) }
        if let step = take(bitrateUp()) { return .success(step) }
        // 5. 90/120 last, and only when nothing below it is waiting.
        if firstFailure == nil, let step = take(fpsUp(limit: tops.fps, .upshiftHighRefresh)) { return .success(step) }
        return .failure(firstFailure ?? StepFailure(reason: .atTop))
    }

    // MARK: - Bookkeeping

    private mutating func change(to next: AdaptiveOperatingPoint, dimensions: [Dimension], action: Decision.Action,
                                 reason: Reason, cause: Cause, now: TimeInterval,
                                 evidence: AdaptiveStreamingEvidence, direction: Direction?) -> Decision {
        let previous = point
        point = next
        lastChangeAt = now
        if dimensions.contains(.raster) { lastRestartAt = now }
        if let direction { recordDirection(direction, now: now) }
        let cost = dimensions.map(Decision.ChangeCost.of).max() ?? .none
        var finalEvidence = evidence
        finalEvidence.rasterFloor = rasterFloor
        finalEvidence.ceilingFPS = configuration.negotiation.capabilityCeilingFPS
        return Decision(action: action, point: next, previous: previous, changed: dimensions, cost: cost,
                        reason: reason, cause: cause, evidence: finalEvidence)
    }

    private func hold(_ reason: Reason, cause: Cause, evidence: AdaptiveStreamingEvidence? = nil) -> Decision {
        var finalEvidence = evidence ?? baseEvidence()
        finalEvidence.badStreak = badStreak
        finalEvidence.healthyStreak = healthyStreak
        return Decision(action: .hold, point: point, previous: point, changed: [], cost: .none,
                        reason: reason, cause: cause, evidence: finalEvidence)
    }

    private func baseEvidence() -> AdaptiveStreamingEvidence {
        var evidence = AdaptiveStreamingEvidence()
        evidence.baselineRttMs = baselineRttMs
        evidence.badStreak = badStreak
        evidence.healthyStreak = healthyStreak
        evidence.rasterFloor = rasterFloor
        evidence.ceilingFPS = configuration.negotiation.capabilityCeilingFPS
        evidence.dataPolicy = dataPolicy
        evidence.thermal = thermal
        return evidence
    }

    private mutating func clearStreaks() {
        badCause = nil
        badStreak = 0
        healthyStreak = 0
        if var pending = probe {
            pending.remaining = configuration.thresholds.probeConfirmWindows
            probe = pending
        }
    }

    private mutating func startBackoff(_ dimension: Dimension, now: TimeInterval) {
        let t = configuration.thresholds
        let seconds = dimensionBackoffSeconds[dimension].map { min($0 * 2, t.probeBackoffMaxSeconds) }
            ?? t.probeBackoffBaseSeconds
        dimensionBackoffSeconds[dimension] = seconds
        dimensionBackoffUntil[dimension] = now + seconds
    }

    private mutating func recordDirection(_ direction: Direction, now: TimeInterval) {
        let t = configuration.thresholds
        if let last = lastDirection, last != direction { flipTimes.append(now) }
        lastDirection = direction
        flipTimes.removeAll { now - $0 > t.flipWindowSeconds }
        if flipTimes.count >= t.maxFlipsInWindow {
            oscillationBackoffUntil = now + oscillationBackoffSeconds
            oscillationBackoffSeconds = min(oscillationBackoffSeconds * 2, t.oscillationBackoffMaxSeconds)
            flipTimes.removeAll()
        }
    }

    private static func changedDimensions(_ a: AdaptiveOperatingPoint, _ b: AdaptiveOperatingPoint) -> [Dimension] {
        var dimensions: [Dimension] = []
        if abs(a.rasterScale - b.rasterScale) > 1e-9 { dimensions.append(.raster) }
        if a.bitrate != b.bitrate { dimensions.append(.bitrate) }
        if a.fps != b.fps { dimensions.append(.fps) }
        return dimensions
    }

    private static func stepAtOrAbove(_ value: Double, in steps: [Double]) -> Double {
        steps.first { $0 >= value - 1e-9 } ?? steps.last ?? 1
    }

    private static func stepAtOrBelow(_ value: Double, in steps: [Double]) -> Double {
        steps.last { $0 <= value + 1e-9 } ?? steps.first ?? value
    }

    private static func stepAtOrBelow(_ value: Int, in steps: [Int]) -> Int {
        steps.last { $0 <= value } ?? steps.first ?? value
    }
}
