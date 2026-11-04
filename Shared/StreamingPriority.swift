import Foundation

/// Streaming Priority: a small, bounded knob for how the encoder pipeline
/// trades sustained frame rate against latency. Foundation-only and
/// platform-neutral like `StreamingProfile.swift` — pure enough to unit test
/// without ScreenCaptureKit/VideoToolbox, and mirrors `StreamingProfile`'s
/// wire/persistence shape (Mac-authoritative, request/state pair).
///
/// This is deliberately NOT an adaptive controller (see #287) — each case
/// maps to one fixed, small encoder-pipelining depth, chosen once at session
/// start. A future evidence-driven LAN-pacing feature can layer on top of
/// this enum without the UI or wire protocol changing.
enum StreamingPriority: String, CaseIterable, Codable, Identifiable {
    case auto
    case preferFPS
    case preferLatency

    var id: String { rawValue }

    /// What the pickers call it. The raw values (wire and saved settings)
    /// keep their original names: `auto` is Balanced, `preferFPS` is
    /// Smoothness, `preferLatency` is Latency.
    var label: String {
        switch self {
        case .auto: return String(localized: "Balanced")
        case .preferFPS: return String(localized: "Smoothness")
        case .preferLatency: return String(localized: "Latency")
        }
    }

    /// The order every picker shows, from lowest delay to smoothest motion.
    static let pickerOrder: [StreamingPriority] = [.preferLatency, .auto, .preferFPS]

    var explanation: String {
        switch self {
        case .auto: return String(localized: "The default: a balance of smooth motion and low delay.")
        case .preferFPS: return String(localized: "Favors a smooth, steady frame rate, keeping a little more work in flight at a small cost in delay.")
        case .preferLatency: return String(localized: "Favors the newest frame and the lowest delay, accepting a lower frame rate under load.")
        }
    }
}

/// Pure policy mapping `StreamingPriority` to the encoder's bounded
/// parallelism depth. See MacSender's "Encoder parallelism limiter" comment
/// for why these are small, fixed admission ceilings rather than an
/// unbounded or adaptive queue.
enum StreamingPriorityPolicy {
    static func maxPendingEncodes(for priority: StreamingPriority) -> Int {
        switch priority {
        case .preferLatency: return 1
        case .auto: return 2
        case .preferFPS: return 3
        }
    }
}
