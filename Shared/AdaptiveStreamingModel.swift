// Compiled into every app target and MacTests (see project.yml `sources`).
// Value types for `AdaptiveStreamingController` (issue #123). Pure,
// Foundation-only and Sendable; no clocks, timers or globals.

import Foundation

enum AdaptiveThermalLevel: Int, Sendable, Codable, CaseIterable, Comparable {
    case nominal
    case fair
    case serious
    case critical

    static func < (lhs: AdaptiveThermalLevel, rhs: AdaptiveThermalLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum AdaptivePowerState: String, Sendable, Codable, CaseIterable {
    case normal
    /// Low Power Mode on either endpoint.
    case lowPower
}

/// What the receiver shows the stream on, for the readability floor.
struct AdaptiveReceiverDisplay: Equatable, Sendable, Codable {
    enum SizeClass: String, Sendable, Codable, CaseIterable {
        /// Small physical screen: text is already shrunk, so it needs the
        /// most encoded pixels per displayed point.
        case phone
        case tablet
        /// A Mac or other large screen.
        case desktop
    }

    var pointsWide: Int
    var pointsHigh: Int
    /// Device pixels per point (2 or 3 on Apple screens).
    var scale: Double
    var sizeClass: SizeClass
}

/// One rung combination on the operating-point ladder. The codec is not part
/// of it: the controller never changes the negotiated codec.
struct AdaptiveOperatingPoint: Hashable, Sendable, Codable, CustomStringConvertible {
    /// Fraction of the native encode raster (1.0 = today's Best).
    var rasterScale: Double
    /// Encoder average bitrate target, bits per second.
    var bitrate: Int
    var fps: Int

    var description: String {
        String(format: "%.3f×/%.1fMbps/%dfps", rasterScale, Double(bitrate) / 1_000_000, fps)
    }

    /// Encoded raster for a native size, rounded down to even like the
    /// sender's capture sizes.
    func raster(nativeWidth: Int, nativeHeight: Int) -> (width: Int, height: Int) {
        (max(Int(Double(nativeWidth) * rasterScale) & ~1, 2), max(Int(Double(nativeHeight) * rasterScale) & ~1, 2))
    }
}

/// The discrete steps the controller moves between, and the data-saver
/// clamps. Every value is a named, tunable constant.
struct AdaptiveStreamingLadder: Equatable, Sendable {
    /// Ascending fractions of the native raster.
    var rasterSteps: [Double]
    /// Ascending bitrates, bits per second.
    var bitrateSteps: [Int]
    /// Today's fixed Automatic point: Best quality (`StreamQuality.best`).
    var startRaster: Double
    var startBitrate: Int
    /// Data saver ceilings.
    var saverRasterTop: Double
    var saverBitrateTop: Int
    var saverFPSTop: Int

    static let standard = AdaptiveStreamingLadder(
        rasterSteps: [0.5, 0.625, 0.75, 0.875, 1.0],
        bitrateSteps: [2_000_000, 3_000_000, 4_000_000, 6_000_000, 8_000_000, 10_000_000,
                       12_000_000, 15_000_000, 18_000_000].filter { $0 <= bitrateCeiling },
        startRaster: 1.0,
        startBitrate: 18_000_000,
        saverRasterTop: 0.75,
        saverBitrateTop: 6_000_000,
        saverFPSTop: 60)

    /// Today's fixed Automatic bitrate (`StreamQuality.best.bitrate`).
    static let fixedPolicyBitrate = 18_000_000
    /// The ladder never goes above today's Best target (lead decision,
    /// phase 2): no step above it until measured quality evidence exists.
    static let bitrateCeiling = fixedPolicyBitrate
    static let fixedPolicyRaster = 1.0
}

/// Every threshold the controller uses. Conservative defaults; all are
/// tunable and none has been validated on hardware yet.
struct AdaptiveStreamingThresholds: Equatable, Sendable {
    // Measurement windows
    var minWindowSeconds: Double = 1.0
    var maxWindowSeconds: Double = 10.0
    /// No sample for this long → hold (`staleTelemetry`).
    var staleAfterSeconds: Double = 6.0
    /// A gap this long also discards confirmation streaks.
    var dropoutResetSeconds: Double = 15.0

    // Confirmation, dwell, hysteresis
    var downshiftConfirmWindows = 2
    var upshiftConfirmWindows = 5
    var probeConfirmWindows = 3
    /// Minimum time after any change before an upshift.
    var minDwellSeconds: Double = 10.0
    /// The dwell instead of `minDwellSeconds` when part of the pipeline
    /// evidence is missing (no receiver decode time, which the default
    /// display-layer path never reports, or no sender encode latency): the
    /// upshift then rests on delivery, drops, backpressure and RTT/jitter
    /// alone, so it waits longer (#123 A1).
    var minDwellSecondsWithoutPipelineEvidence: Double = 20.0
    /// Raster changes restart capture: at most one per interval…
    var minRestartIntervalSeconds: Double = 20.0
    /// …or this one for a protective (severe) downshift.
    var protectiveRestartIntervalSeconds: Double = 6.0
    var routeChangeHoldSeconds: Double = 4.0

    // Oscillation guard
    var flipWindowSeconds: Double = 120.0
    /// This many direction flips inside the window blocks upshifts.
    var maxFlipsInWindow = 3
    var oscillationBackoffBaseSeconds: Double = 60.0
    var oscillationBackoffMaxSeconds: Double = 600.0
    /// A failed probe blocks that dimension's upshifts, doubling.
    var probeBackoffBaseSeconds: Double = 30.0
    var probeBackoffMaxSeconds: Double = 600.0

    // Health
    /// Delivered/expected unique frames at or above this is healthy.
    var healthyDeliveryRatio = 0.95
    /// Source unique cadence below this fraction of the target is source
    /// limited (idle/low motion), not congestion.
    var sourceIdleRatio = 0.5

    // Network
    var backpressureDownshift = 0.15
    var severeBackpressure = 0.5
    var networkDropFraction = 0.05
    var rttInflationFactor = 1.6
    var rttInflationMinMs = 25.0
    /// Jitter above this many frame intervals, with delivery short, is network.
    var jitterFrameIntervals = 1.0
    var lateDeliveryRatio = 0.9

    // Encoder / decoder
    var encodeQueueAgeFrameIntervals = 2.0
    var encoderDropFraction = 0.05
    var encodedRatio = 0.9
    var decodeBudgetFraction = 0.85
    var decodedRatio = 0.9
    var presentationQueueFrameIntervals = 3.0
    var presentationQueueMinMs = 50.0
    var severeStallsPerWindow = 2
    var severeDeliveryRatio = 0.5

    // Upshift headroom
    var headroomBackpressure = 0.02
    var headroomRttFactor = 1.25
    var headroomRttSlackMs = 10.0
    var headroomJitterFrameIntervals = 0.5
    /// Decode p95 must fit in this fraction of the NEW frame interval, and
    /// the encode latency in this fraction of its overload limit
    /// (`encodeQueueAgeFrameIntervals` new intervals: the sender keeps up to
    /// two encodes in flight), each scaled for the new pixel count.
    var headroomPipelineFraction = 0.6
    /// An FPS upshift needs the capture saturated: source frames at least
    /// this fraction of the CURRENT target (the capture runs at the current
    /// target, so it can't show more than that).
    var highRefreshSourceRatio = 0.9

    // Network step order
    /// Bits per pixel per frame below which a network downshift lowers the
    /// raster instead of the bitrate.
    var minBitsPerPixel = 0.02

    // Readability floor: encoded pixels per displayed receiver point.
    var phonePixelsPerPoint = 1.5
    var tabletPixelsPerPoint = 1.25
    var desktopPixelsPerPoint = 1.0
    var unknownReceiverRasterFloor = 0.75

    // Mode and power clamps
    /// Window view with more visible panes than this stays at or below 60.
    var windowMaxPanesForHighRefresh = 1
    var thermalSeriousFPSTop = 60
    var thermalCriticalFPSTop = 30
    var thermalCriticalRasterTop = 0.75
    var lowPowerFPSTop = 60

    static let standard = AdaptiveStreamingThresholds()
}

/// One measurement window for one receiver's stream. Every field the
/// pipeline cannot measure yet is optional; a window missing the fields the
/// controller needs is held, never guessed.
struct AdaptiveStreamingSample: Equatable, Sendable {
    struct Drops: Equatable, Sendable {
        /// Frames the sender dropped because the encoder was busy.
        var encoder = 0
        /// Frames the sender dropped because sends were backed up.
        var network = 0
        /// Frames the receiver dropped as late/stale.
        var receiverLate = 0
    }

    /// Stream generation this window belongs to.
    var generation: UInt64
    /// Route epoch (bumped by the transport on every path change).
    var routeEpoch: UInt64
    var mode: RefreshNegotiation.DisplayMode
    /// Monotonic seconds (caller's clock).
    var windowStart: TimeInterval
    var windowEnd: TimeInterval

    // Frame rates, frames per second.
    /// Distinct source frames (ScreenCaptureKit complete frames with
    /// content change, or compositor updates), before admission.
    var sourceUniqueFPS: Double?
    var captureFPS: Double?
    var encodedFPS: Double?
    var deliveredFPS: Double?
    var decodedFPS: Double?
    /// Handed to the display layer (not confirmed on glass).
    var enqueuedFPS: Double?

    var encodeQueueDepth: Int?
    /// The sender's measured encode latency for the window: the mean time
    /// from submitting a frame to VideoToolbox to its compressed output
    /// (which includes any wait behind the other in-flight encode).
    var encodeQueueAgeMs: Double?
    var drops = Drops()
    var rttMs: Double?
    var jitterMs: Double?
    /// Fraction of the window the sender's send path was at its pending cap.
    var sendBackpressure: Double?
    var decodeTimeP95Ms: Double?
    var presentationQueueAgeMs: Double?
    var stallCount: Int?
    /// Observed app payload bytes per second (not billed bytes).
    var payloadBytesPerSecond: Double?

    var senderThermal: AdaptiveThermalLevel?
    var receiverThermal: AdaptiveThermalLevel?
    var power: AdaptivePowerState = .normal
    var dataPolicy: NetworkCost.DataPolicy = .normal

    /// Window view only.
    var activePaneCount = 1
    var floatingPaneCount = 0

    var duration: Double { windowEnd - windowStart }

    /// How the controller depends on each field (#123 A1). A field the
    /// controller needs must be set by the production sample builder
    /// (`AdaptiveStreamingCoordinator.makeSample`); anything else must have
    /// an explicit fallback when absent. A test checks every stored property
    /// is listed here and every `.setByProduction` field is set by the real
    /// builder from the keys real receivers send, so the controller can't
    /// again wait for a field production never fills.
    enum FieldUse: Equatable, Sendable {
        /// Always set by the production builder; the controller relies on it.
        case setByProduction
        /// Read when present; absent has a stated fallback.
        case optionalWithFallback(String)
        /// Not read by the controller (diagnostics or future use).
        case unused
    }

    static let controllerFieldUse: [String: FieldUse] = [
        "generation": .setByProduction,
        "routeEpoch": .setByProduction,
        "mode": .setByProduction,
        "windowStart": .setByProduction,
        "windowEnd": .setByProduction,
        "sourceUniqueFPS": .setByProduction,
        "captureFPS": .unused,
        "encodedFPS": .setByProduction,
        "deliveredFPS": .setByProduction,
        "decodedFPS": .optionalWithFallback("delivered FPS stands in; no decoded-ratio check"),
        "enqueuedFPS": .optionalWithFallback("decoded, then delivered FPS stands in"),
        "encodeQueueDepth": .unused,
        "encodeQueueAgeMs": .optionalWithFallback(
            "no encode-latency overload check; upshift pipeline evidence is unknown (longer dwell)"),
        "drops": .setByProduction,
        "rttMs": .optionalWithFallback("no RTT baseline: no RTT-based downshift and no network headroom (hold)"),
        "jitterMs": .optionalWithFallback("no jitter check"),
        "sendBackpressure": .setByProduction,
        "decodeTimeP95Ms": .optionalWithFallback(
            "no decode overload check; upshift pipeline evidence is unknown (longer dwell)"),
        "presentationQueueAgeMs": .optionalWithFallback("no presentation-queue check"),
        "stallCount": .optionalWithFallback("counts as 0 stalls"),
        "payloadBytesPerSecond": .unused,
        "senderThermal": .setByProduction,
        "receiverThermal": .optionalWithFallback("nominal"),
        "power": .setByProduction,
        "dataPolicy": .setByProduction,
        "activePaneCount": .optionalWithFallback("1 pane: the Window view pane clamp never fires"),
        "floatingPaneCount": .optionalWithFallback("0 floats"),
    ]
}

/// The numbers a decision used, for the diagnostics view and export.
struct AdaptiveStreamingEvidence: Equatable, Sendable, Codable {
    var windowSeconds: Double?
    var expectedFPS: Double?
    var deliveredUniqueFPS: Double?
    var sourceUniqueFPS: Double?
    var rttMs: Double?
    var baselineRttMs: Double?
    var jitterMs: Double?
    var sendBackpressure: Double?
    var encodeQueueAgeMs: Double?
    var decodeTimeP95Ms: Double?
    var presentationQueueAgeMs: Double?
    var networkDropFraction: Double?
    var encoderDropFraction: Double?
    var thermal: AdaptiveThermalLevel?
    var badStreak = 0
    var healthyStreak = 0
    var rasterFloor: Double?
    var ceilingFPS: Int?
    var dataPolicy: NetworkCost.DataPolicy?
}

struct AdaptiveStreamingDecision: Equatable, Sendable {
    enum Action: String, Sendable, Codable, CaseIterable {
        /// First point for a new controller.
        case initial
        case hold
        case downshift
        /// An upshift is always a probe: it is confirmed or reverted.
        case upshift
        case probeRevert
        /// Data saver, thermal, power or pane clamp lowered the ladder top.
        case policyClamp
        /// Reconnect or a new stream generation.
        case reset
        /// Custom mode or an explicit user override: not managed.
        case bypass
        /// The peer lacks the needed telemetry: today's fixed policy.
        case fixedPolicy
    }

    enum Reason: String, Sendable, Codable, CaseIterable {
        case customModeBypass
        case userOverride
        case legacyPeerFixedPolicy
        case initialPoint
        case generationReset
        case insufficientData
        case staleTelemetry
        case staleGeneration
        case staleRouteEpoch
        case routeChangeSettling
        case confirmingDownshift
        case probeConfirming
        case probeConfirmed
        case probeFailedRevert
        case dwell
        case oscillationBackoff
        case noHeadroom
        case atTop
        case sourceLimited
        case healthy
        case noLowerOption
        case restartRateLimited
        case networkBitrateDown
        case networkFPSDown
        case networkRasterDown
        case overloadFPSDown
        case overloadRasterDown
        case thermalFPSDown
        case thermalRasterDown
        case lastResortRasterBelowFloor
        case upshiftRaster
        case upshiftFPS
        case upshiftBitrate
        case upshiftHighRefresh
        case dataSaverClamp
        case thermalClamp
        case powerClamp
        case paneClamp
        case ceilingClamp
    }

    enum Dimension: String, Sendable, Codable, CaseIterable {
        case raster
        case bitrate
        case fps
    }

    /// What applying the change costs in the real pipeline (cheapest first).
    enum ChangeCost: Int, Sendable, Codable, CaseIterable, Comparable {
        case none
        /// Bitrate: recreate the VideoToolbox session (keyframe), no
        /// capture change.
        case encoderReconfigure
        /// FPS: live `SCStream.updateConfiguration` + encoder recreate, the
        /// existing `applyEffectiveFPSChange` path.
        case liveCaptureUpdate
        /// Raster: capture size change (`reconfigure`/`startCapture`),
        /// rate-limited.
        case captureRestart

        static func < (lhs: ChangeCost, rhs: ChangeCost) -> Bool { lhs.rawValue < rhs.rawValue }

        static func of(_ dimension: Dimension) -> ChangeCost {
            switch dimension {
            case .bitrate: return .encoderReconfigure
            case .fps: return .liveCaptureUpdate
            case .raster: return .captureRestart
            }
        }
    }

    /// The bottleneck the window was classified as.
    enum Cause: String, Sendable, Codable, CaseIterable {
        case none
        case insufficientData
        case stale
        case thermal
        case encoder
        case decoder
        case network
        case sourceLimited
        case healthy
    }

    let action: Action
    /// The point to run. nil only for `bypass` in Custom mode (the user's
    /// Custom settings apply unchanged).
    let point: AdaptiveOperatingPoint?
    let previous: AdaptiveOperatingPoint?
    let changed: [Dimension]
    let cost: ChangeCost
    let reason: Reason
    let cause: Cause
    let evidence: AdaptiveStreamingEvidence

    var isChange: Bool { !changed.isEmpty }
}
