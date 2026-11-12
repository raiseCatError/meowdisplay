import Foundation

/// The Streaming settings a restart last built every session with, so one
/// change restarts streaming once. A receiver's profile or priority request
/// applies the change and restarts on its own; with Settings ▸ Streaming
/// open, the window's `.onChange` then sees the same change (twice for a
/// profile, which also sets the frame rate) and used to restart again,
/// tearing the rebuilt sessions down: the same double restart the Streaming
/// Mode picker's comment describes.
struct StreamingRestartLedger {
    struct Settings: Equatable {
        var mode: StreamingMode
        var profile: StreamingProfile
        var customFrameRate: CustomFrameRateSelection
        var priority: StreamingPriority
        var codec: CodecPreference
        var quality: StreamQuality
    }

    private(set) var built: Settings?

    /// Every session was just rebuilt with `settings`.
    mutating func restarted(with settings: Settings) {
        built = settings
    }

    /// A setting changed in the Streaming window: whether streaming must
    /// restart for it (false when the running sessions already use it).
    func needsRestart(for settings: Settings) -> Bool {
        settings != built
    }
}
