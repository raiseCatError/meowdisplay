// Compiled into every app target and MacTests (see project.yml `sources`).
// Pure, Foundation-only refresh/FPS negotiation for the adaptive Automatic
// streaming controller (issue #123, 2026-11-14 research addendum). Nothing
// here touches ScreenCaptureKit, VideoToolbox or the wire: phase 2 feeds it
// numbers the pipeline already has (or reads from optional hello keys).

import Foundation

/// Decides how fast a stream is ALLOWED to run (the capability ceiling) and
/// where it STARTS (the configured target), from every stage that can limit
/// a frame rate. It never looks at observed performance: whether the session
/// actually sustains a rate is `AdaptiveStreamingController`'s job, fed by
/// measured samples. Keeping the two apart is what stops a nominal "120"
/// advertised by a receiver from turning into a 120 FPS target on its own.
///
/// Rules:
/// - Never target above the source's distinct-frame cadence: a 60 Hz Mac
///   display cannot produce 120 new frames per second, so 120 from it is
///   duplicate frames for twice the encode/decode cost.
/// - 60 first. 90/120 are offered only when every stage supports them, the
///   source cadence is known, and the tier divides the source cadence evenly
///   (90 from a 120 Hz source would judder).
/// - A peer that sends no effective-refresh information is a legacy peer: it
///   gets exactly today's `StreamingFPSPolicy` result from this negotiation,
///   with no source cap and no 60-first start. (With the Mac's Adaptive
///   Automatic (Beta) switch on, the coordinator still caps every receiver,
///   legacy ones included, at the Mirror/Extend source refresh, outside this
///   function: PROTOCOL.md 6.20. With the switch off nothing does.)
/// - Mirror, Extend and Window view each describe their own source: the
///   physical display's active mode, the virtual display's supported
///   refresh, or the window compositor's frame budget.
enum RefreshNegotiation {
    /// The three supported display modes. Mirrors the Mac's `CaptureMode`
    /// without depending on Mac-only code.
    enum DisplayMode: String, Sendable, Codable, CaseIterable {
        case mirror
        case extend
        case window
    }

    /// Every stage that can bound the frame rate.
    enum Stage: String, Sendable, Codable, CaseIterable {
        case productCeiling
        case profile
        case source
        case receiverMaximum
        case receiverEffective
        case senderEncoder
        case receiverDecoder
        case userLimit
    }

    struct StageLimit: Equatable, Sendable {
        let stage: Stage
        let fps: Int
    }

    struct Input: Equatable, Sendable {
        var mode: DisplayMode
        /// The effective profile (Automatic resolves to Performance).
        var profile: StreamingProfile
        /// Custom profile's explicit pick; nil = Auto.
        var customFPS: Int?
        /// Distinct-frame cadence of the source in Hz: the physical
        /// display's active mode refresh (Mirror), the virtual display's
        /// supported refresh (Extend) or the window compositor's frame
        /// budget (Window view). nil = unknown.
        var sourceRefreshHz: Int?
        /// `hello.maxFPS`: the receiver screen's maximum refresh. nil on
        /// receivers that predate the field.
        var receiverMaxFPS: Int?
        /// The receiver's CURRENT effective refresh (ProMotion can be held
        /// at 60 by Low Power Mode or a user setting). nil = the receiver
        /// does not report it, which makes this a legacy negotiation.
        var receiverEffectiveRefreshHz: Int?
        /// The receiver's enforced user ceiling (`ReceiverMaxFPSPreference`).
        var userMaxFPS: Int?
        /// The FINAL encode raster (after `DecodeCeiling`), in pixels.
        var encodeWidth: Int
        var encodeHeight: Int
        /// The codec the session negotiated.
        var codec: StreamCodec
        /// Receiver decoder pixel throughput, pixels per second, when the
        /// receiver reports one. nil = no FPS bound from the decoder (the
        /// legacy `maxEncodeWide/High` raster ceiling is already applied to
        /// `encodeWidth/Height`).
        var receiverDecodePixelsPerSecond: Int?

        init(mode: DisplayMode, profile: StreamingProfile = StreamingModePolicy.automaticProfile,
             customFPS: Int? = nil, sourceRefreshHz: Int?, receiverMaxFPS: Int?,
             receiverEffectiveRefreshHz: Int?, userMaxFPS: Int? = nil,
             encodeWidth: Int, encodeHeight: Int, codec: StreamCodec,
             receiverDecodePixelsPerSecond: Int? = nil) {
            self.mode = mode
            self.profile = profile
            self.customFPS = customFPS
            self.sourceRefreshHz = sourceRefreshHz
            self.receiverMaxFPS = receiverMaxFPS
            self.receiverEffectiveRefreshHz = receiverEffectiveRefreshHz
            self.userMaxFPS = userMaxFPS
            self.encodeWidth = encodeWidth
            self.encodeHeight = encodeHeight
            self.codec = codec
            self.receiverDecodePixelsPerSecond = receiverDecodePixelsPerSecond
        }
    }

    struct Result: Equatable, Sendable {
        /// True when the receiver sent no effective-refresh information:
        /// every field below then reproduces today's `StreamingFPSPolicy`.
        let isLegacy: Bool
        /// The highest rate every stage supports. Never a promise that the
        /// session sustains it.
        let capabilityCeilingFPS: Int
        /// Where a stream starts: 60 (or the ceiling when lower). Legacy:
        /// today's rate.
        let initialTargetFPS: Int
        /// Every frame rate the controller may choose, ascending. Legacy:
        /// only today's rate.
        let allowedTargets: [Int]
        /// The stage that set `capabilityCeilingFPS`.
        let limitingStage: Stage
        /// Each stage's own bound, for diagnostics.
        let stageLimits: [StageLimit]
        /// Today's fixed result for the same inputs, always computed so the
        /// controller can fall back to it exactly.
        let legacyFPS: Int
    }

    /// The product ceiling (shared with `StreamingFPSPolicy.hardCapFPS`).
    static let productCeilingFPS = StreamingFPSPolicy.hardCapFPS
    /// The first target for every non-legacy stream.
    static let firstTargetFPS = 60
    /// Rates above 60 that need every stage to agree.
    static let highRefreshTiers = [90, 120]
    /// Rates below 60 the controller may step down to. Both divide 60 and
    /// 120 evenly.
    static let lowTiers = [20, 30]
    /// Assumed source cadence when the source is unknown: 60 is what every
    /// supported Mac display and the virtual display default to.
    static let unknownSourceAssumedHz = 60

    /// Exactly today's computation (`MacSender.effectiveFPS` for an already
    /// chosen codec).
    static func legacyFPS(_ input: Input) -> StreamingFPSPolicy.Result {
        let common = StreamingFPSPolicy.commonTargetFPS(
            profile: input.profile, requestedFPS: input.customFPS,
            receiverMaxFPS: input.receiverMaxFPS, userMaxFPS: input.userMaxFPS)
        return StreamingFPSPolicy.codecEffectiveFPS(
            commonTarget: common, codec: input.codec,
            encoderSafeFPS: EncoderCapability.codecSafeFPS(width: input.encodeWidth, height: input.encodeHeight))
    }

    static func negotiate(_ input: Input) -> Result {
        let legacy = legacyFPS(input)
        guard let effective = input.receiverEffectiveRefreshHz else {
            return Result(isLegacy: true, capabilityCeilingFPS: legacy.fps, initialTargetFPS: legacy.fps,
                          allowedTargets: [legacy.fps], limitingStage: stage(for: legacy.reason),
                          stageLimits: [StageLimit(stage: stage(for: legacy.reason), fps: legacy.fps)],
                          legacyFPS: legacy.fps)
        }

        // Ordered by how actionable each explanation is: ties report the
        // first stage in this list.
        var limits: [StageLimit] = []
        if let user = input.userMaxFPS { limits.append(StageLimit(stage: .userLimit, fps: max(user, 1))) }
        limits.append(StageLimit(stage: .source, fps: max(input.sourceRefreshHz ?? unknownSourceAssumedHz, 1)))
        limits.append(StageLimit(stage: .receiverEffective, fps: max(effective, 1)))
        limits.append(StageLimit(stage: .receiverMaximum,
                                 fps: max(input.receiverMaxFPS ?? StreamingFPSPolicy.defaultReceiverMaxFPS, 1)))
        if input.codec == .h264 {
            limits.append(StageLimit(stage: .senderEncoder,
                                     fps: EncoderCapability.codecSafeFPS(width: input.encodeWidth, height: input.encodeHeight)))
        }
        if let decode = input.receiverDecodePixelsPerSecond {
            let pixels = max(input.encodeWidth, 1) * max(input.encodeHeight, 1)
            limits.append(StageLimit(stage: .receiverDecoder, fps: max(decode / pixels, 1)))
        }
        limits.append(StageLimit(stage: .profile,
                                 fps: StreamingFPSPolicy.profileRequestedFPS(profile: input.profile, requestedFPS: input.customFPS)))
        limits.append(StageLimit(stage: .productCeiling, fps: productCeilingFPS))

        let ceiling = limits.map(\.fps).min() ?? firstTargetFPS
        let limiting = limits.first { $0.fps == ceiling }?.stage ?? .productCeiling

        var allowed = Set(lowTiers.filter { $0 < ceiling })
        if ceiling >= firstTargetFPS { allowed.insert(firstTargetFPS) } else { allowed.insert(ceiling) }
        if let source = input.sourceRefreshHz {
            for tier in highRefreshTiers where tier <= ceiling && source % tier == 0 {
                allowed.insert(tier)
            }
        }
        let sorted = allowed.sorted()
        let initial = sorted.last { $0 <= firstTargetFPS } ?? sorted.first ?? ceiling
        return Result(isLegacy: false, capabilityCeilingFPS: ceiling, initialTargetFPS: initial,
                      allowedTargets: sorted, limitingStage: limiting, stageLimits: limits,
                      legacyFPS: legacy.fps)
    }

    private static func stage(for reason: StreamingFPSPolicy.LimitReason) -> Stage {
        switch reason {
        case .requested: return .profile
        case .receiverCapability: return .receiverMaximum
        case .encoderThroughput: return .senderEncoder
        case .userCeiling: return .userLimit
        }
    }
}
