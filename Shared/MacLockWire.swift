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

    /// `view`: the lock screen view this device shows (`lockScreen` `active` only); its input
    /// carries it back (`LockScreenInputTag`).
    static func message(_ state: MacScreenPrivacy, lockScreen: LockScreenOffer = .unavailable(nil),
                        view: Int? = nil) -> [String: Any] {
        var m: [String: Any] = ["type": type, "state": state.rawValue, "remoteUnlock": lockScreen.offered]
        if state != .unlocked {
            m["lockScreen"] = lockScreen.wire
            if lockScreen == .active, let view, view > 0 { m[LockScreenWire.viewKey] = view }
        }
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

    /// Receiver -> Mac, on every input message (`LockScreenInputTag.messageTypes`) sent while this
    /// device sees the Mac locked: `"lockScreen":true`, plus `"lockScreenView":V` while it shows
    /// view V. Additive: a Mac that doesn't know them ignores them.
    static let inputTag = "lockScreen"
    /// Mac -> receiver in `macLockState` (with `lockScreen` `active`), and receiver -> Mac on
    /// tagged input: the lock screen view the input is for. A positive integer, never reused.
    static let viewKey = "lockScreenView"

    /// Mac -> receiver: `{"type":"lockScreenInputRefused","count":N,"clicks":C,"reason":R}`: N
    /// keystrokes and C clicks (presses) weren't delivered. R: `unlocked` (meant for the lock
    /// screen, but the Mac had unlocked), `notShown` (meant for the lock screen, which isn't shown
    /// on this connection), `untagged` (not meant for the lock screen, while it is shown).
    static let inputRefused = "lockScreenInputRefused"

    static func inputRefused(count: Int, clicks: Int = 0, reason: String) -> [String: Any] {
        ["type": inputRefused, "count": count, "clicks": clicks, "reason": reason]
    }
}

/// Which lock episode a piece of input was made in (PROTOCOL.md 6.19). The receiver tags every
/// input message it sends while it sees the Mac locked; the Mac delivers tagged input only to the
/// live lock screen view it names, and untagged input only when no view is live. Anything else is
/// refused, so input typed or pressed for the lock screen never operates the desktop after an
/// unlock, and desktop input never reaches the lock screen.
struct LockScreenInputTag: Equatable, Sendable {
    /// The lock screen view this input was made in. Nil: the device saw the Mac locked without
    /// showing its lock screen (or an older receiver's bare tag): never delivered.
    var view: Int?

    init(view: Int?) {
        self.view = view.flatMap { $0 > 0 ? $0 : nil }
    }

    /// Nil: untagged. Any `lockScreen` or `lockScreenView` field tags the message, whatever its
    /// value (fail closed: a malformed tag is a tag that names no view).
    init?(message: [String: Any]) {
        let marker = message[LockScreenWire.inputTag]
        let view = message[LockScreenWire.viewKey]
        guard marker != nil || view != nil else { return nil }
        self.init(view: Self.positiveInteger(view))
    }

    func apply(to message: inout [String: Any]) {
        message[LockScreenWire.inputTag] = true
        if let view { message[LockScreenWire.viewKey] = view }
    }

    /// A JSON integer, never a boolean (`true` would otherwise read as 1).
    static func positiveInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let int = Int(exactly: number.doubleValue), int > 0 else { return nil }
        return int
    }

    /// Every message type that operates the Mac. The receiver tags each of them; the Mac checks
    /// each against the tag rule.
    static let messageTypes: Set<String> = lockScreenTypes.union(otherTypes)
    /// What the lock screen can take at all (`LockScreenInputFilter`).
    static let lockScreenTypes: Set<String> = ["touch", "pointer", "keyboard"]
    /// Never on the lock screen: refused while a view is live, and dropped whenever tagged.
    static let otherTypes: Set<String> = [
        "scroll", "pencil", "proximity", "gesture",
        WireMessage.nativeAppGesture, WireMessage.smartTouchProbe,
        WireMessage.windowAction, WireMessage.workspaceFocus, WireMessage.menuPress,
        WireMessage.appLaunch, WireMessage.windowClose,
    ]
}

/// The receiver's side: what its input is tagged with now. `locked`: the Mac said it's locked
/// (any state but `unlocked`); `view`: the lock screen view this device shows.
struct LockScreenInputTagState: Equatable, Sendable {
    var locked = false
    var view: Int?

    /// Nil: untagged (the Mac isn't locked as far as this device knows).
    var tag: LockScreenInputTag? { locked ? LockScreenInputTag(view: view) : nil }

    func tagged(_ message: [String: Any]) -> [String: Any] {
        guard let tag, let type = message["type"] as? String,
              LockScreenInputTag.messageTypes.contains(type) else { return message }
        var message = message
        tag.apply(to: &message)
        return message
    }
}

/// The receiver's copy of `lockScreenInputRefused`.
struct LockScreenInputRefusal: Equatable, Sendable {
    var count: Int
    var clicks: Int
    var reason: String

    init(count: Int, clicks: Int = 0, reason: String) {
        self.count = count
        self.clicks = clicks
        self.reason = reason
    }

    /// Nil for anything malformed (nothing counted, or nonsense numbers).
    init?(message: [String: Any]) {
        guard message["type"] as? String == LockScreenWire.inputRefused else { return nil }
        let count = message["count"] as? Int ?? 0
        let clicks = message["clicks"] as? Int ?? 0
        guard count >= 0, clicks >= 0, count + clicks > 0, count <= 100_000, clicks <= 100_000 else { return nil }
        self.count = count
        self.clicks = clicks
        reason = String((message["reason"] as? String ?? "").prefix(32))
    }

    /// One plain line for the receiver: "1 click wasn't sent: the Mac unlocked."
    var notice: String {
        var parts: [String] = []
        if count > 0 {
            parts.append(count == 1 ? String(localized: "1 keystroke") : String(localized: "\(count) keystrokes"))
        }
        if clicks > 0 {
            parts.append(clicks == 1 ? String(localized: "1 click") : String(localized: "\(clicks) clicks"))
        }
        let what = parts.joined(separator: String(localized: " and "))
        let single = count + clicks == 1
        switch reason {
        case "unlocked":
            return single ? String(localized: "\(what) wasn’t sent: the Mac unlocked.")
                          : String(localized: "\(what) weren’t sent: the Mac unlocked.")
        case "untagged":
            return single ? String(localized: "\(what) wasn’t sent: use the lock screen’s keyboard and touches.")
                          : String(localized: "\(what) weren’t sent: use the lock screen’s keyboard and touches.")
        default:
            return single ? String(localized: "\(what) wasn’t sent: the lock screen isn’t shown.")
                          : String(localized: "\(what) weren’t sent: the lock screen isn’t shown.")
        }
    }

    /// Several refusals close together read as one notice when the reason is the same.
    func adding(_ other: LockScreenInputRefusal) -> LockScreenInputRefusal {
        other.reason == reason
            ? LockScreenInputRefusal(count: count + other.count, clicks: clicks + other.clicks, reason: reason)
            : other
    }
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
    /// The lock screen view this device shows (`active` only), for its input's tag. Nil from a
    /// Mac that doesn't number views.
    var lockScreenView: Int?

    var isLocked: Bool { !state.allowsContent }

    init(state: MacScreenPrivacy, remoteUnlock: Bool = false, lockScreen: LockScreenOffer? = nil,
         lockScreenView: Int? = nil) {
        self.state = state
        self.remoteUnlock = remoteUnlock
        self.lockScreen = lockScreen ?? (remoteUnlock ? .available : .unavailable(nil))
        self.lockScreenView = self.lockScreen == .active ? lockScreenView.flatMap { $0 > 0 ? $0 : nil } : nil
    }

    /// Nil for anything malformed. An unknown future state counts as locked.
    init?(message: [String: Any]) {
        guard message["type"] as? String == MacLockWire.type, let raw = message["state"] as? String, !raw.isEmpty else { return nil }
        state = MacScreenPrivacy(rawValue: String(raw.prefix(32))) ?? .unknown
        remoteUnlock = message["remoteUnlock"] as? Bool ?? false
        lockScreen = LockScreenOffer(wire: message["lockScreen"] as? String, offered: remoteUnlock)
        lockScreenView = lockScreen == .active ? LockScreenInputTag.positiveInteger(message[LockScreenWire.viewKey]) : nil
    }
}

/// Display sleep (#255). A session can outlive the Mac's displays going to sleep: the transport
/// stays up or reconnects in a dark wake, but there is nothing to capture. The Mac says so, and a
/// receiver shows that instead of a frozen or black picture, with one explicit action to wake it.
/// The Mac never wakes itself for a connected viewer: someone put it to sleep.
enum MacDisplaySleepWire {
    /// Mac -> receiver: `{"type":"macDisplaySleep","asleep":Bool}`. Sent when the displays go to
    /// sleep or wake during an admitted session, and on a re-admission while they are asleep.
    /// Additive: a receiver that doesn't know it ignores it.
    static let type = "macDisplaySleep"

    static func message(asleep: Bool) -> [String: Any] { ["type": type, "asleep": asleep] }

    /// Nil for anything malformed: the receiver then keeps what it last knew.
    static func asleep(from message: [String: Any]) -> Bool? {
        guard message["type"] as? String == type else { return nil }
        return message["asleep"] as? Bool
    }
}

/// The receiver's one explicit "Wake Mac" request while the Mac's displays sleep. One request at
/// a time, answered by the Mac reporting its displays awake, or failed after `timeout`. Nothing
/// retries by itself: a Mac that stays asleep is asked again only by another tap.
struct MacWakeRequest: Equatable {
    enum Phase: Equatable { case idle, waiting, failed }
    static let timeout: TimeInterval = 12

    private(set) var phase = Phase.idle
    private(set) var requestID = 0

    /// A tap on Wake Mac. Returns the id its timeout must present, or nil while one is waiting.
    mutating func begin() -> Int? {
        guard phase != .waiting else { return nil }
        requestID &+= 1
        phase = .waiting
        return requestID
    }

    /// The timeout of request `id` fired. Only the request still waiting can fail.
    @discardableResult
    mutating func timedOut(_ id: Int) -> Bool {
        guard phase == .waiting, id == requestID else { return false }
        phase = .failed
        return true
    }

    /// The Mac reported its displays: awake ends the request (and clears a failure); asleep
    /// again leaves a waiting request waiting.
    mutating func displayReported(asleep: Bool) {
        if !asleep { phase = .idle }
    }
}

/// Where the "Mac is asleep" cover shows (#255).
enum MacAsleepCoverPolicy {
    /// Only over the session itself. Home is opaque and shows nothing of the Mac, so it replaces
    /// the cover; coming back (Resume) shows the cover again while the Mac still sleeps. Settings
    /// is presented above the cover, which stays up beneath it.
    static func showsCover(asleep: Bool, sessionOnScreen: Bool) -> Bool {
        asleep && sessionOnScreen
    }
}
