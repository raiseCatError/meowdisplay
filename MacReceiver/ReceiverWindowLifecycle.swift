import Foundation

/// Whether a newly created receiver video window enters native full screen.
/// A receiver Mac acts as a display, so the default is on. The panel's
/// "Open in Full Screen" toggle and the window's green button both write
/// this one value, and it survives stream restarts and relaunches.
struct FullscreenPreference {
    static let key = "receiverFullscreen"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var wantsFullscreen: Bool {
        get { defaults.object(forKey: Self.key) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// The receiver video window's lifetime rules, kept free of AppKit so they
/// can be tested: when a fresh window takes the full screen preference,
/// which native full screen transitions count as the user's choice, and
/// the short grace before a stopped stream takes the window down.
struct ReceiverWindowLifecycle {
    /// How long a window outlives a stopped stream. A sender moving the
    /// session to another transport (Wi-Fi to cable) can drop the old link
    /// a moment before the new one is adopted; keeping the window avoids
    /// rebuilding it and replaying the full screen transition.
    static let closeGrace: TimeInterval = 2

    let preference: FullscreenPreference

    /// True only between a window's creation and the start of its
    /// teardown. A programmatic close of a full screen window reports a
    /// full screen exit that must not be recorded as "windowed".
    private(set) var isTrackingUserChoice = false
    /// Identifies the one delayed close that may still act. Anything that
    /// keeps or replaces the window bumps it, so an older timer finds a
    /// mismatch and does nothing.
    private(set) var pendingClose: Int?
    private var generation = 0

    init(preference: FullscreenPreference = FullscreenPreference()) {
        self.preference = preference
    }

    /// A new window was built. Returns whether to enter full screen now —
    /// only fresh windows take the preference; a reused one stays exactly
    /// as the user left it.
    mutating func windowCreated() -> Bool {
        isTrackingUserChoice = true
        return preference.wantsFullscreen
    }

    /// The window finished a native full screen transition.
    func fullscreenChanged(entered: Bool) {
        guard isTrackingUserChoice else { return }
        preference.wantsFullscreen = entered
    }

    /// The window is going away (our close, or the user's). Stop recording
    /// before the close's own full screen exit arrives.
    mutating func windowClosing() {
        isTrackingUserChoice = false
        cancelPendingClose()
    }

    /// Streaming stopped: returns the token for a close scheduled
    /// `closeGrace` later.
    mutating func scheduleClose() -> Int {
        generation &+= 1
        pendingClose = generation
        return generation
    }

    /// Streaming resumed (or the window is being shown on request): any
    /// scheduled close is void.
    mutating func cancelPendingClose() {
        generation &+= 1
        pendingClose = nil
    }

    /// A scheduled close fired. True only if it is still the current one.
    mutating func consumeClose(_ token: Int) -> Bool {
        guard pendingClose == token else { return false }
        pendingClose = nil
        return true
    }
}
