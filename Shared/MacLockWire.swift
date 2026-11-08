import Foundation

/// The Mac's lock screen as receivers are told it (PROTOCOL.md 6.18). Additive: a Mac that never
/// sends it simply never shows the locked screen, and a receiver that doesn't know it still gets
/// no content while the Mac is locked (the Mac stops it at the source and says video is off).
enum MacLockWire {
    /// Mac -> receiver: `{"type":"macLockState","state":S,"remoteUnlock":Bool,"lockScreen":L}`.
    /// `remoteUnlock`: this device may show and operate macOS's own lock screen (now, or after
    /// the step `lockScreen` names); `lockScreen`: `LockScreenOffer` (6.19). Older Macs send
    /// `remoteUnlock: false` and no `lockScreen`.
    static let type = "macLockState"
    static let welcomeFeature = "macLockState"

    static func message(_ state: MacScreenPrivacy, lockScreen: LockScreenOffer = .unavailable(nil)) -> [String: Any] {
        var m: [String: Any] = ["type": type, "state": state.rawValue, "remoteUnlock": lockScreen.offered]
        if state != .unlocked { m["lockScreen"] = lockScreen.wire }
        return m
    }
}

/// Lock screen control (PROTOCOL.md 6.19): a device the Mac already trusts with input shows
/// macOS's own lock screen and types the login password there; macOS authenticates. The Mac
/// decides who may (SECURITY.md "Lock screen control"); a receiver only asks.
enum LockScreenWire {
    /// Receiver -> Mac: `{"type":"lockScreenRequest","show":Bool}`. Answered with `macLockState`.
    static let request = "lockScreenRequest"
    static let welcomeFeature = "lockScreenControl"

    static func request(show: Bool) -> [String: Any] { ["type": request, "show": show] }
}

/// What the Mac offers this device for its lock screen while it's locked.
enum LockScreenOffer: Equatable, Sendable {
    /// The lock screen is shown on this device and takes its restricted input.
    case active
    /// Show Lock Screen works now.
    case available
    /// It works once this device has control: a request is granted without a prompt.
    case needsControl
    /// It works in Full Desktop (Window view can't show the lock screen); after switching, control
    /// is asked for again and granted without a prompt.
    case needsFullDesktop
    /// Not for this device now; the Mac's reason, when it gives one.
    case unavailable(String?)

    var offered: Bool {
        switch self {
        case .active, .available, .needsControl, .needsFullDesktop: return true
        case .unavailable: return false
        }
    }

    var wire: String {
        switch self {
        case .active: return "active"
        case .available: return "available"
        case .needsControl: return "needsControl"
        case .needsFullDesktop: return "needsFullDesktop"
        case .unavailable(let why): return why.map { String($0.prefix(32)) } ?? "unavailable"
        }
    }

    /// Unknown words (a newer Mac's reason) are reasons it isn't offered.
    init(wire: String?, offered: Bool) {
        switch wire {
        case "active"?: self = .active
        case "available"?: self = .available
        case "needsControl"?: self = .needsControl
        case "needsFullDesktop"?: self = .needsFullDesktop
        case "unavailable"?: self = .unavailable(nil)
        case let w?: self = .unavailable(String(w.prefix(32)))
        case nil: self = offered ? .available : .unavailable(nil)
        }
        if !offered, self.offered { self = .unavailable(nil) }
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
    /// Whether this device may show the Mac's lock screen (now or after `lockScreen`'s step).
    var remoteUnlock: Bool
    var lockScreen: LockScreenOffer

    var isLocked: Bool { !state.allowsContent }

    init(state: MacScreenPrivacy, remoteUnlock: Bool = false, lockScreen: LockScreenOffer? = nil) {
        self.state = state
        self.remoteUnlock = remoteUnlock
        self.lockScreen = lockScreen ?? (remoteUnlock ? .available : .unavailable(nil))
    }

    /// Nil for anything malformed. An unknown future state counts as locked.
    init?(message: [String: Any]) {
        guard message["type"] as? String == MacLockWire.type, let raw = message["state"] as? String, !raw.isEmpty else { return nil }
        state = MacScreenPrivacy(rawValue: String(raw.prefix(32))) ?? .unknown
        remoteUnlock = message["remoteUnlock"] as? Bool ?? false
        lockScreen = LockScreenOffer(wire: message["lockScreen"] as? String, offered: remoteUnlock)
    }
}
