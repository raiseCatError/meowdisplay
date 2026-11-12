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

// MARK: - Receiver requests (issue #142)

/// What the Mac does with a receiver's request to change a Mac-wide
/// streaming setting. Automatic applies a fixed policy, so a manual profile
/// or priority picked on a receiver could never take effect there; storing it
/// and restarting every device's stream only to report the same Automatic
/// value back is what made the receiver's picker flicker and snap back.
enum RemoteStreamingSettingOutcome<Value: Equatable>: Equatable {
    /// The Mac is in Automatic: nothing is stored or restarted, and the Mac
    /// re-reports its state so the receiver can show why.
    case rejectedAutomatic
    /// Already what the Mac uses: nothing to restart.
    case unchanged
    /// Store this and rebuild the streams.
    case apply(Value)
}

/// A stored profile together with the Custom profile's frame-rate pick.
struct StreamingProfileSetting: Equatable {
    var profile: StreamingProfile
    var customFrameRate: CustomFrameRateSelection
}

extension StreamingModePolicy {
    /// `requestedCustomFrameRate` is nil when the receiver sent none. The
    /// frame rate only belongs to the Custom profile: a request for any other
    /// profile keeps the stored pick, so choosing Performance on a receiver
    /// no longer resets a Mac's custom 90 FPS to Auto.
    static func remoteProfileRequest(
        mode: StreamingMode,
        stored: StreamingProfileSetting,
        requestedProfile: StreamingProfile,
        requestedCustomFrameRate: CustomFrameRateSelection?
    ) -> RemoteStreamingSettingOutcome<StreamingProfileSetting> {
        guard mode == .custom else { return .rejectedAutomatic }
        let requested = StreamingProfileSetting(
            profile: requestedProfile,
            customFrameRate: requestedProfile == .custom
                ? (requestedCustomFrameRate ?? stored.customFrameRate) : stored.customFrameRate)
        return requested == stored ? .unchanged : .apply(requested)
    }

    static func remotePriorityRequest(
        mode: StreamingMode, stored: StreamingPriority, requested: StreamingPriority
    ) -> RemoteStreamingSettingOutcome<StreamingPriority> {
        guard mode == .custom else { return .rejectedAutomatic }
        return requested == stored ? .unchanged : .apply(requested)
    }
}

/// `streamingProfileState`: the profile the Mac applies, plus (from Macs
/// with this change) its Streaming Mode and, in Custom, the Custom profile's
/// frame-rate pick. Both additions are optional keys: older receivers ignore
/// them, and a receiver talking to an older Mac sees `mode == nil` and keeps
/// its controls as before.
struct StreamingProfileStateUpdate: Equatable {
    let profile: StreamingProfile
    let mode: StreamingMode?
    let customFrameRate: CustomFrameRateSelection?

    init(profile: StreamingProfile, mode: StreamingMode?, customFrameRate: CustomFrameRateSelection?) {
        self.profile = profile
        self.mode = mode
        self.customFrameRate = customFrameRate
    }

    init?(message: [String: Any]) {
        guard let raw = message["profile"] as? String, let profile = StreamingProfile(rawValue: raw) else { return nil }
        self.profile = profile
        mode = (message["mode"] as? String).flatMap(StreamingMode.init(rawValue:))
        customFrameRate = (message["customFrameRate"] as? String).flatMap(CustomFrameRateSelection.init(rawValue:))
    }

    /// The frame's JSON. Every value is a fixed enum raw value, so no escaping is needed.
    var wireJSON: String {
        var json = "{\"type\":\"\(WireMessage.streamingProfileState)\",\"profile\":\"\(profile.rawValue)\""
        if let mode { json += ",\"mode\":\"\(mode.rawValue)\"" }
        if let customFrameRate { json += ",\"customFrameRate\":\"\(customFrameRate.rawValue)\"" }
        return json + "}"
    }
}

/// The receiver's note under its streaming pickers, from the Mac's reported
/// mode. nil when the Mac doesn't report one (older Macs): the controls stay
/// as they were.
enum ReceiverStreamingModeNote {
    static func text(for mode: StreamingMode?) -> String? {
        switch mode {
        case .automatic?:
            return String(localized: "Streaming Mode is Automatic on the Mac. To choose a profile or priority here, switch it to Custom in MeowDisplay on the Mac.",
                          comment: "Receiver streaming settings footer while the sender Mac's Streaming Mode is Automatic.")
        case .custom?:
            return String(localized: "These settings belong to the Mac and apply to every device connected to it.",
                          comment: "Receiver streaming settings footer while the sender Mac's Streaming Mode is Custom.")
        case nil:
            return nil
        }
    }
}
