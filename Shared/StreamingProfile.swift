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

    /// `receiverMaxFPS`: the receiver's advertised maximum display refresh
    /// rate in Hz, or nil when unknown/unreported (older peer, or a peer
    /// that hasn't sent hello yet).
    /// `requestedFPS`: only consulted for `.custom` — the manually selected
    /// rate, or nil for Custom's own Auto.
    static func effectiveFPS(profile: StreamingProfile, requestedFPS: Int?, receiverMaxFPS: Int?) -> Int {
        let receiverCap = min(max(receiverMaxFPS ?? defaultReceiverMaxFPS, 1), hardCapFPS)
        switch profile {
        case .efficiency:
            return min(efficiencyCapFPS, receiverCap)
        case .performance:
            return min(hardCapFPS, receiverCap)
        case .custom:
            let requested = min(max(requestedFPS ?? hardCapFPS, 1), hardCapFPS)
            return min(requested, receiverCap)
        }
    }
}
