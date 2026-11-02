import Foundation

/// Automatic/Custom streaming settings milestone: the outer, normal-user-
/// facing switch. `.automatic` hides every advanced streaming knob
/// (`StreamingProfile`, `StreamingPriority`, `CodecPreference`, custom FPS,
/// `StreamQuality`) and always applies today's pre-milestone default policy
/// — Performance profile, Auto priority, Auto codec, Best quality. This is
/// deliberately NOT a new optimization engine: it is a fixed policy chosen
/// once, same as every other case in this file. `.custom` is where all of
/// those existing controls (already fully built, see `StreamingSettingsView`)
/// become visible and effective again. Foundation-only and platform-neutral
/// like its siblings, so it's exhaustively unit testable.
enum StreamingMode: String, CaseIterable, Codable, Identifiable {
    case automatic
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return String(localized: "Automatic")
        case .custom: return String(localized: "Custom")
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            return String(localized: "MEOW automatically chooses the best connection, codec, quality, frame rate and streaming behavior for your devices.")
        case .custom:
            return String(localized: "Manually control streaming profile, priority, codec, frame rate and quality.")
        }
    }
}

/// Automatic mode's fixed policy, pulled out as pure functions so it's unit
/// testable without `SenderController`/`MacSender`. Matches the values every
/// existing user already defaults to today (see the `didSet` doc comments on
/// `SenderController.streamingProfile`/`streamingPriority`/`codecPreference`)
/// — Automatic does not change what "default" means, it only hides the knobs
/// that would otherwise override it. `StreamQuality` is Mac-app-only (not
/// Shared, since it's a sender/capture concept the iOS/MacReceiver targets
/// never build), so its own Automatic default lives next to its declaration
/// in `Mac/MacSender.swift` instead of here.
enum StreamingModePolicy {
    static let automaticProfile = StreamingProfile.performance
    static let automaticPriority = StreamingPriority.auto
    static let automaticCodec = CodecPreference.auto

    static func effectiveProfile(mode: StreamingMode, stored: StreamingProfile) -> StreamingProfile {
        mode == .custom ? stored : automaticProfile
    }

    static func effectiveCustomFPS(mode: StreamingMode, storedProfile: StreamingProfile, storedCustomFPS: Int?) -> Int? {
        guard mode == .custom, storedProfile == .custom else { return nil }
        return storedCustomFPS
    }

    static func effectivePriority(mode: StreamingMode, stored: StreamingPriority) -> StreamingPriority {
        mode == .custom ? stored : automaticPriority
    }

    static func effectiveCodec(mode: StreamingMode, stored: CodecPreference) -> CodecPreference {
        mode == .custom ? stored : automaticCodec
    }
}
