import Foundation

/// Pure state logic for the hidden Cat Mode easter egg — nine taps on the
/// About/version row (a cat's nine lives) reveals a purely cosmetic
/// presentation toggle. Deliberately just two tiny static functions: this
/// has nothing to do with streaming/transport/pairing/protocol, so it stays
/// out of anything else in `Shared` and carries no state of its own —
/// persistence lives in each platform's `AppStorage`/`UserDefaults`, local
/// to that device only (never synced, never sent on the wire).
enum CatMode {
    static let requiredTaps = 9

    static let unlockedDefaultsKey = "catModeUnlocked"
    static let enabledDefaultsKey = "catModeEnabled"
    /// Not required to persist across relaunch (only unlocked/enabled are),
    /// but kept in defaults anyway so a Debug "Reset Cat Mode" action can
    /// clear it in one shot rather than needing view-local state plumbed
    /// through to the developer screen.
    static let tapCountDefaultsKey = "catModeTapCount"

    /// One tap on the About/version row. `tapCount` is the count *before*
    /// this tap. Returns the count after this tap, and whether this exact
    /// tap is the one crossing the unlock threshold — so the "Cat Mode
    /// unlocked" confirmation fires once, not on every tap after unlock.
    static func registerTap(tapCount: Int, alreadyUnlocked: Bool) -> (tapCount: Int, justUnlocked: Bool) {
        guard !alreadyUnlocked else { return (tapCount, false) }
        let next = tapCount + 1
        return (next, next >= requiredTaps)
    }

    /// The single choke point for the Settings toggle: a locked user can
    /// never end up with Cat Mode enabled, even if `catModeEnabled` already
    /// holds true in UserDefaults (e.g. a stale value from before a reset).
    static func resolveEnabled(requestedEnabled: Bool, unlocked: Bool) -> Bool {
        unlocked && requestedEnabled
    }
}
