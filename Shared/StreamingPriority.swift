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

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .preferFPS: return "Prefer FPS"
        case .preferLatency: return "Prefer Latency"
        }
    }

    var explanation: String {
        switch self {
        case .auto: return "Balanced default."
        case .preferFPS: return "Favors smooth, sustained frame rate, allowing a small amount of extra work in flight at a small cost to latency."
        case .preferLatency: return "Favors the newest frame and bounded latency, accepting lower frame rate under pressure."
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
