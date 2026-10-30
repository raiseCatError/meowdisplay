import Foundation

/// When an iPhone or iPad keeps its screen awake (iOS's Auto-Lock held off): only while a Mac's
/// picture (Mirror, Extend or Window mode) is being watched in the foreground. On Home, in
/// Settings, in the background, in the demo, or once a lost connection hasn't come back within
/// the grace, Auto-Lock works as usual. Matches Android, which keeps the screen on only while
/// the video surface shows. Pure, so it is tested (ScreenAwakePolicyTests).
enum ScreenAwakePolicy {
    /// Settings ▸ General ▸ Keep Screen Awake While Streaming. On by default.
    static let preferenceKey = "keepScreenAwakeWhileStreaming"
    static let defaultEnabled = true
    /// A dropped connection keeps the screen awake this long, for a quick reconnect.
    static let reconnectGrace: TimeInterval = 30

    struct Inputs: Equatable {
        var enabled: Bool
        var foreground: Bool
        /// The session's picture is on screen: not Home, Settings or the demo.
        var watching: Bool
        /// Connected, with the Mac's video arriving.
        var streaming: Bool
    }

    /// `sinceStreaming`: seconds since the picture last streamed while watched (nil: never).
    /// `recheckIn`: during the grace, when the answer changes by itself.
    static func decide(_ i: Inputs, sinceStreaming: TimeInterval?) -> (awake: Bool, recheckIn: TimeInterval?) {
        guard i.enabled, i.foreground, i.watching else { return (false, nil) }
        if i.streaming { return (true, nil) }
        if let since = sinceStreaming, since >= 0, since < reconnectGrace { return (true, reconnectGrace - since) }
        return (false, nil)
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? defaultEnabled
    }
}
