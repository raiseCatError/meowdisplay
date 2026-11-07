import Foundation

/// The Mac's lock screen as receivers are told it (PROTOCOL.md 6.18). Additive: a Mac that never
/// sends it simply never shows the locked screen, and a receiver that doesn't know it still gets
/// no content while the Mac is locked (the Mac stops it at the source and says video is off).
enum MacLockWire {
    /// Mac -> receiver: `{"type":"macLockState","state":S,"remoteUnlock":false}`.
    static let type = "macLockState"
    static let welcomeFeature = "macLockState"

    static func message(_ state: MacScreenPrivacy) -> [String: Any] {
        // Unlocking from a device isn't offered: macOS's lock screen takes the password at the Mac.
        ["type": type, "state": state.rawValue, "remoteUnlock": false]
    }
}

/// What this Mac's login session shows, for privacy. Only `.unlocked` lets content (picture,
/// sound, window lists, titles, stills, icons, Files, Clipboard) and input through; every other
/// state counts as locked.
enum MacScreenPrivacy: String, Equatable, Sendable {
    case unlocked
    /// macOS shows its lock screen.
    case locked
    /// Fast User Switching: another login session is on the console.
    case switchedOut
    /// The session couldn't be read: counted as locked, never as unlocked.
    case unknown

    var allowsContent: Bool { self == .unlocked }
}

/// The receiver's copy of `macLockState`.
struct MacLockNotice: Equatable, Sendable {
    var state: MacScreenPrivacy
    /// Whether this device could unlock it from here. Always false in this version.
    var remoteUnlock: Bool

    var isLocked: Bool { !state.allowsContent }

    init(state: MacScreenPrivacy, remoteUnlock: Bool = false) {
        self.state = state
        self.remoteUnlock = remoteUnlock
    }

    /// Nil for anything malformed. An unknown future state counts as locked.
    init?(message: [String: Any]) {
        guard message["type"] as? String == MacLockWire.type, let raw = message["state"] as? String, !raw.isEmpty else { return nil }
        state = MacScreenPrivacy(rawValue: String(raw.prefix(32))) ?? .unknown
        remoteUnlock = message["remoteUnlock"] as? Bool ?? false
    }
}
