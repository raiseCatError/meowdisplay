import Foundation

/// Streaming Profile (high-refresh milestone): the user-facing knob that
/// decides how MeowDisplay trades refresh rate against power/bandwidth.
/// Foundation-only and platform-neutral like `Protocol.swift` — the Mac
/// target uses it to drive capture/encode, and it's pure enough to unit
/// test without any ScreenCaptureKit/VideoToolbox dependency.
enum StreamingProfile: String, CaseIterable, Codable, Identifiable {
    case efficiency
    case performance
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .efficiency: return "Efficiency"
        case .performance: return "Performance"
        case .custom: return "Custom"
        }
    }

    var explanation: String {
        switch self {
        case .efficiency: return "Lower power/bandwidth, up to 60 FPS."
        case .performance: return "Prioritize responsiveness, up to the receiver's supported refresh rate, capped at 120 FPS."
        case .custom: return "Manual streaming controls."
        }
    }
}

/// Custom profile's manual frame-rate picker. `.auto` requests the same
/// ceiling as Performance (receiver capability, capped at 120) — it exists
/// so Custom always has an explicit selection rather than silently reusing
/// another profile's number.
enum CustomFrameRateSelection: String, CaseIterable, Codable, Identifiable {
    case auto
    case fps30
    case fps60
    case fps90
    case fps120

    var id: String { rawValue }

    /// nil means Auto (no explicit request — defer entirely to capability).
    var requestedFPS: Int? {
        switch self {
        case .auto: return nil
        case .fps30: return 30
        case .fps60: return 60
        case .fps90: return 90
        case .fps120: return 120
        }
    }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .fps30: return "30"
        case .fps60: return "60"
        case .fps90: return "90"
        case .fps120: return "120"
        }
    }
}

/// Pure capability-aware effective-FPS policy. No ScreenCaptureKit/
/// VideoToolbox/Network types — every input is a plain number so this can
/// be exhaustively unit tested (see StreamingProfileTests).
enum StreamingFPSPolicy {
    /// Hard product ceiling for this milestone — 144/165/240 are out of
    /// scope regardless of what a receiver or Custom selection asks for.
    static let hardCapFPS = 120
    static let efficiencyCapFPS = 60
    /// Safe default receiver capability for a peer that reports none: an
    /// older receiver predates the `maxFPS` hello field entirely, and a
    /// current receiver a capability probe genuinely fails on is no more
    /// likely to be ProMotion than not. 60 is the ubiquitous floor every
    /// iPhone display (and virtually every external monitor) supports.
    static let defaultReceiverMaxFPS = 60

    /// Why `effectiveFPS` landed below the plain profile/custom request —
    /// drives both the DEBUG diagnostic line and the receiver-facing
    /// limitation text (PROTOCOL.md 6.8 / PART 5). `.requested` means
    /// nothing constrained it: the profile's own number won outright.
    enum LimitReason: String {
        case requested
        case receiverCapability
        case encoderThroughput
        case userCeiling
    }

    struct Result: Equatable {
        let fps: Int
        let reason: LimitReason
    }

    /// `receiverMaxFPS`: the receiver's advertised maximum display refresh
    /// rate in Hz, or nil when unknown/unreported (older peer, or a peer
    /// that hasn't sent hello yet).
    /// `requestedFPS`: only consulted for `.custom` — the manually selected
    /// rate, or nil for Custom's own Auto.
    /// `userMaxFPS`: the receiver's own enforced ceiling (PART 2), or nil
    /// when the receiver has that preference turned off.
    /// `encoderSafeFPS`: `EncoderCapability.codecSafeFPS` (the arbitrary-
    /// integer internal ceiling, NOT the quantized picker tier) for the CURRENT
    /// final encode dimensions — always supplied, never optional, so a
    /// caller can't accidentally skip the one check this whole system
    /// exists to enforce.
    /// The profile's own requested FPS, before any capability/ceiling is
    /// applied — what `effectiveFPS` calls `.requested`. Exposed separately
    /// so diagnostics/UI (PART 5/9) can show "Performance requests 120 FPS"
    /// without re-deriving `effectiveFPS`'s internal switch.
    static func profileRequestedFPS(profile: StreamingProfile, requestedFPS: Int?) -> Int {
        switch profile {
        case .efficiency: return min(efficiencyCapFPS, hardCapFPS)
        case .performance: return hardCapFPS
        case .custom: return min(max(requestedFPS ?? hardCapFPS, 1), hardCapFPS)
        }
    }

    static func effectiveFPS(profile: StreamingProfile, requestedFPS: Int?, receiverMaxFPS: Int?,
                              userMaxFPS: Int?, encoderSafeFPS: Int) -> Result {
        let receiverCap = min(max(receiverMaxFPS ?? defaultReceiverMaxFPS, 1), hardCapFPS)
        let profileRequested = profileRequestedFPS(profile: profile, requestedFPS: requestedFPS)
        let safeEncoderFPS = max(encoderSafeFPS, 1)

        var candidates: [(value: Int, reason: LimitReason)] = [
            (profileRequested, .requested),
            (receiverCap, .receiverCapability),
            (safeEncoderFPS, .encoderThroughput),
        ]
        if let userMaxFPS { candidates.append((max(userMaxFPS, 1), .userCeiling)) }

        let fps = candidates.map(\.value).min() ?? profileRequested
        // Ties favor the most specific/actionable explanation over the
        // generic "that's just what was requested" — a receiver capability
        // or encoder ceiling that happens to equal the request is still the
        // thing worth telling the user about if it moves.
        let reason = candidates.first { $0.value == fps && $0.reason != .requested }?.reason
            ?? candidates.first { $0.value == fps }?.reason
            ?? .requested
        return Result(fps: fps, reason: reason)
    }

    /// Tiers a receiver may pick as its enforced maximum (PART 2): filtered
    /// to what the receiver's own hardware supports AND what the current
    /// encode size can safely deliver, so a value that would immediately be
    /// overridden is never offered in the first place.
    static func availableUserCeilingTiers(receiverMaxFPS: Int?, encoderSafeFPS: Int) -> [Int] {
        let ceiling = min(max(receiverMaxFPS ?? defaultReceiverMaxFPS, 1), hardCapFPS, max(encoderSafeFPS, 1))
        return EncoderCapability.supportedFPSTiers.filter { $0 <= ceiling }
    }
}
