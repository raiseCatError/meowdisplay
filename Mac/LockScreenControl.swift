import Foundation

// Lock screen control (SECURITY.md "Lock screen control"): while the Mac is locked, a receiver
// this Mac already trusts with input may ask to see and operate macOS's own lock screen, to type
// the login password there and unlock the session it is connected to. macOS does the
// authentication; MeowDisplay never sees, checks, stores or logs a password. Everything else stays
// as `MacPrivacyGate` keeps it while locked: no windows, listings, sound, clipboard or files, and
// only the input the login window needs.

/// Why a receiver can't operate the lock screen now. The raw value goes on the wire.
enum LockScreenDenial: String, Equatable, Sendable, CaseIterable {
    /// The session isn't admitted (not paired, blocked or revoked).
    case notAdmitted
    /// The Mac's Allow Input is off.
    case inputOff
    /// Another user's session is on the console (Fast User Switching), or it can't be told.
    case otherUser
    /// The Mac isn't locked (or its state is unknown).
    case notLocked
    /// This device is set to Never Allow input.
    case neverAllow
    /// Allow Lock Screen Control is off for this device.
    case turnedOff
    /// Always Allow device without a grant on this connection yet: a control request is granted
    /// without a prompt, then the lock screen can be shown.
    case needsControl
    /// Ask device without control granted before the Mac locked: nothing is asked while locked.
    case controlBeforeLock
    /// In Window view or Extend, which can't show the lock screen, on a device that isn't set to
    /// Always Allow: Mirror is a new connection, whose control an Ask device can't get while locked.
    /// (Extend reuses this word: its display shows only wallpaper, never the login window.)
    case windowView
}

/// Who may operate the lock screen: a device the Mac's owner already trusts with input, on the
/// login session it is connected to, with this Mac's switches on. Never widens anything:
/// - Never Allow, Allow Input off, another user on the console, not admitted: no.
/// - Allow Lock Screen Control off for the device: no.
/// - Always Allow: yes, with this connection's grant (granted on request without a prompt).
/// - Ask: only with control granted on this connection before the Mac locked (requests while
///   locked are refused, `InputControlRequestRoute`): no silent elevation.
enum LockScreenEligibility {
    struct Inputs: Equatable, Sendable {
        var admitted: Bool
        var masterInput: Bool
        var onConsole: Bool
        var privacy: MacScreenPrivacy
        var policy: PeerInputRequestPolicy
        var lockScreenControlAllowed: Bool
        var sessionGranted: Bool
        /// The session is in Window view (the lock screen shows only in Full Desktop).
        var windowView = false
        /// The session is in Extend: its virtual display shows wallpaper, never macOS's login
        /// window, which is on the main display. Treated as Window view: Mirror first.
        var extend = false

        /// An Ask device's control, granted by a person before the Mac locked, will be carried
        /// across this Mac's own switch to Mirror (`LockScreenGrantHandoffs`): asking for control
        /// on the new connection is granted once, without a prompt.
        var handoffPending = false

        /// Not Mirror: the lock screen can't be shown on this connection.
        var needsMirror: Bool { windowView || extend }
    }

    /// Nil: allowed.
    static func denial(_ i: Inputs) -> LockScreenDenial? {
        guard i.admitted else { return .notAdmitted }
        guard i.masterInput else { return .inputOff }
        guard i.onConsole, i.privacy != .switchedOut else { return .otherUser }
        guard i.privacy == .locked else { return .notLocked }
        guard i.policy != .neverAllow else { return .neverAllow }
        guard i.lockScreenControlAllowed else { return .turnedOff }
        guard i.sessionGranted else {
            let regainsWithoutPrompt = i.policy == .alwaysAllow || (i.policy == .ask && i.handoffPending)
            return regainsWithoutPrompt ? .needsControl : .controlBeforeLock
        }
        return i.needsMirror ? .windowView : nil
    }

    /// What this device is told (`macLockState`). In Window view or Extend: Full Desktop (Mirror)
    /// first when the new connection will get control back without a prompt: Always Allow, or an
    /// Ask device whose control a person granted on this connection before the lock (carried by
    /// a one-time handoff). An Ask device without that grant isn't offered it (`controlBeforeLock`).
    static func offer(_ i: Inputs, active: Bool) -> LockScreenOffer {
        if active { return .active }
        if i.needsMirror {
            var fullDesktop = i
            fullDesktop.windowView = false
            fullDesktop.extend = false
            fullDesktop.handoffPending = i.sessionGranted || i.handoffPending
            fullDesktop.sessionGranted = false
            switch denial(fullDesktop) {
            case .needsControl?, nil: return .needsFullDesktop
            case let d?: return .unavailable(d.rawValue)
            }
        }
        switch denial(i) {
        case nil: return .available
        case .needsControl?: return .needsControl
        case let d?: return .unavailable(d.rawValue)
        }
    }
}

/// One piece of input, as the lock screen gate sees it.
enum LockScreenInputEvent: Equatable, Sendable {
    case touch
    case pointerMove
    case pointerButton(PointerButton)
    case key(HIDKeyUsage, modifiers: [String])
    case modifier(String)
    case text(String)
    /// A key or button release, or a cancel: only ever ends input, so always let through.
    case release
    /// Scroll, Pencil, proximity, gestures, Smart Touch, menus, macros, window and app actions.
    case other
}

/// What typing a password needs, and nothing more: pointer moves and primary clicks (a touch is
/// one), character keys with Shift or Option, Space, Return and Delete. No Tab, arrows, Escape or
/// Forward Delete (they only move focus to the login window's Switch User, power and accessibility
/// controls), no Command or Control, no function, navigation, input-source or media keys, no
/// right-click, scrolling or gestures. `InputInjector` enforces the same filter again.
enum LockScreenInputFilter {
    /// Held modifiers (`modifierDown`): Shift and Option. Caps Lock also rides on typed keys.
    static let allowedModifiers: Set<String> = [ControlModifier.shift.rawValue, ControlModifier.option.rawValue]
    static let allowedKeyFlags: Set<String> = allowedModifiers.union(["capsLock"])

    static let allowedKeys: Set<HIDKeyUsage> = {
        var keys: Set<HIDKeyUsage> = [
            .returnOrEnter, .deleteOrBackspace, .spacebar,
            .minus, .equal, .leftBracket, .rightBracket, .backslash, .semicolon, .quote, .comma, .period, .slash, .grave,
            // Character keys of other layouts and of a numeric keypad (a hardware keyboard).
            .nonUSBackslash, .international1, .international3,
            .keypadSlash, .keypadAsterisk, .keypadMinus, .keypadPlus, .keypadEnter, .keypadPeriod, .keypadEqual, .keypadComma,
            .keypad0, .keypad1, .keypad2, .keypad3, .keypad4, .keypad5, .keypad6, .keypad7, .keypad8, .keypad9,
        ]
        for k in HIDKeyUsage.allCases where (HIDKeyUsage.keyA.rawValue...HIDKeyUsage.digit0.rawValue).contains(k.rawValue) {
            keys.insert(k)
        }
        return keys
    }()

    /// Typed text: printable characters only (no control characters or line breaks), bounded.
    static let maxTextLength = 128

    static func allows(_ e: LockScreenInputEvent) -> Bool {
        switch e {
        case .touch, .pointerMove, .release: return true
        case .pointerButton(let b): return b == .left
        case .key(let usage, let modifiers):
            return allowedKeys.contains(usage) && modifiers.allSatisfy(allowedKeyFlags.contains)
        case .modifier(let name): return allowedModifiers.contains(name)
        case .text(let t):
            return !t.isEmpty && t.count <= maxTextLength
                && !t.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
        case .other: return false
        }
    }
}

/// Video while a receiver shows the lock screen: only frames encoded after it asked (a frame held
/// from before, even replayed, is never one), and a keyframe first, so nothing refers to a picture
/// from before the lock. `MacSender` also drops its held frame when the view starts.
struct LockScreenFrameGate: Equatable, Sendable {
    private(set) var since: Int64?
    private(set) var keyframeSent = false

    mutating func start(nowMs: Int64) {
        since = nowMs
        keyframeSent = false
    }

    mutating func stop() {
        since = nil
        keyframeSent = false
    }

    var isOpen: Bool { since != nil }

    /// `encodedAtMs`: when the frame was handed to the encoder.
    mutating func accepts(encodedAtMs: Int64, keyframe: Bool) -> Bool {
        guard let since, encodedAtMs >= since else { return false }
        if !keyframeSent {
            guard keyframe else { return false }
            keyframeSent = true
        }
        return true
    }
}

/// The pointer's position and sprite (`cursor`, `cursorImg`) are screen content. Unlocked: sent as
/// always. Locked: only to the connection showing the lock screen, and only while macOS shows it
/// (the condition `MacSender.sendFramed` admits that view's frames on). Another user, unknown, or
/// locked without the view: never.
enum LockScreenCursorPolicy {
    static func allows(privacy: MacScreenPrivacy, lockScreenActive: Bool) -> Bool {
        privacy.allowsContent || (lockScreenActive && privacy == .locked)
    }
}

/// The lock screen view's on/off, read by the injector for every event on any thread.
final class LockScreenInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    var isActive: Bool { lock.withLock { on } }
    func set(_ value: Bool) { lock.withLock { on = value } }
}

enum LockScreenSessionPolicy {
    /// Without input for this long the lock screen view ends (the cover stays; asking again
    /// starts a new one). Bounded so a forgotten device doesn't keep the Mac's lock screen lit.
    static let idleTimeout: TimeInterval = 120
    /// A connection may start the view at most this often; a quicker `show:true` is answered with
    /// the current state and wakes nothing (F7).
    static let showInterval: TimeInterval = 5
}

/// `show:true` rate limit for one connection: the first is admitted, then none until
/// `showInterval` has passed since the last one admitted. Reset for a new connection.
struct LockScreenShowRateLimit: Equatable, Sendable {
    private var lastAdmitted: TimeInterval?

    mutating func admits(now: TimeInterval) -> Bool {
        if let last = lastAdmitted, now - last < LockScreenSessionPolicy.showInterval, now >= last { return false }
        lastAdmitted = now
        return true
    }

    mutating func reset() { lastAdmitted = nil }
}


/// An Ask device's pre-lock control, carried across this Mac's own switch from Window view or
/// Extend to Mirror for the lock screen (the switch rebuilds the session on a new connection,
/// which would otherwise start without control, and nobody can approve a prompt behind the lock).
///
/// Mac-internal: nothing goes on the wire, the receiver can't present or forge it. A ticket is
/// issued only from a live grant a person gave this device before the lock, and only for the
/// Mirror switch; it is bound to the device's peer id and pinned key, this login session being on
/// the console, and the lock episode (any unlock, user switch or relock voids it); it lasts at
/// most `lifetime` and is spent by the first request for control, granted or not. It never
/// creates a grant that didn't exist, never applies to Never Allow or Always Allow, and never
/// changes the device's policy.
struct LockScreenGrantHandoffs: Sendable {
    struct Ticket: Equatable, Sendable {
        var peerID: String
        var pinnedKey: Data
        var lockEpisode: UInt64
        var issuedAt: TimeInterval
    }

    static let lifetime: TimeInterval = 10

    private(set) var tickets: [String: Ticket] = [:]

    /// Where the ticket is checked: the device as proven now, and the Mac's state now.
    struct Check: Equatable, Sendable {
        var peerID: String
        var pinnedKey: Data?
        var lockEpisode: UInt64
        var privacy: MacScreenPrivacy
        var onConsole: Bool
        var now: TimeInterval
    }

    /// The device asked to switch to Mirror while locked. Issued only when every condition holds;
    /// returns whether it was.
    @discardableResult
    mutating func issue(_ c: Check, policy: PeerInputRequestPolicy, lockScreenControlAllowed: Bool,
                        sessionGranted: Bool) -> Bool {
        tickets.removeValue(forKey: c.peerID)
        guard let key = c.pinnedKey, !key.isEmpty, c.privacy == .locked, c.onConsole,
              policy == .ask, lockScreenControlAllowed, sessionGranted else { return false }
        tickets[c.peerID] = Ticket(peerID: c.peerID, pinnedKey: key, lockEpisode: c.lockEpisode, issuedAt: c.now)
        return true
    }

    func isValid(_ c: Check) -> Bool {
        guard let t = tickets[c.peerID], let key = c.pinnedKey else { return false }
        return t.pinnedKey == key && t.lockEpisode == c.lockEpisode && c.privacy == .locked && c.onConsole
            && c.now >= t.issuedAt && c.now - t.issuedAt <= Self.lifetime
    }

    /// The device's first request for control on the new connection: spends the ticket whatever
    /// the answer. True only when it was valid.
    mutating func redeem(_ c: Check) -> Bool {
        let valid = isValid(c)
        tickets.removeValue(forKey: c.peerID)
        return valid
    }

    /// Forget, Never Allow, the switch off: no ticket survives.
    mutating func revoke(peerID: String) { tickets.removeValue(forKey: peerID) }
}

/// Keyboard input the receiver sends while it shows the lock screen carries `"lockScreen":true`
/// (PROTOCOL.md 6.19). The Mac delivers it only while that connection's view is live; after the
/// view ended (an unlock in between, a hide, a reconnect) it never reaches the desktop, and the
/// receiver is told how many keystrokes didn't go (`lockScreenInputRefused`). Untagged keyboard
/// input while the view is live is refused and reported too; untagged input otherwise is ordinary
/// input (while locked without the view, the privacy gate drops it as before). Releases always go.
/// Touches and clicks follow the same rule: a press is refused and reported as a click, a move is
/// dropped quietly (`pointerDecision`).
enum LockScreenTaggedInput {
    enum Refusal: String, Equatable, Sendable {
        /// Tagged, but the Mac is unlocked now.
        case unlocked
        /// Tagged, but this connection isn't showing the lock screen.
        case notShown
        /// Not tagged while the lock screen is shown: not typed for it.
        case untagged
    }

    static let releaseActions: Set<String> = ["up", "modifierUp", "cancel"]

    static func refusal(action: String, tagged: Bool, viewLive: Bool, unlocked: Bool) -> Refusal? {
        guard !releaseActions.contains(action) else { return nil }
        if tagged { return viewLive ? nil : (unlocked ? .unlocked : .notShown) }
        return viewLive ? .untagged : nil
    }

    /// What a `touch` or `pointer` message is, for the tag rule.
    enum PointerKind: Equatable, Sendable {
        /// `touch` `began`, `pointer` `down`.
        case press
        /// `touch` `moved` (a drag or hover), `pointer` `move`/`moveRelative`.
        case move
        /// `touch` `ended`/`cancelled`, `pointer` `up`.
        case release
        case other
    }

    static func pointerKind(type: String, phaseOrAction: String?) -> PointerKind {
        switch (type, phaseOrAction) {
        case ("touch", "began"?), ("pointer", "down"?): return .press
        case ("touch", "moved"?), ("pointer", "move"?), ("pointer", "moveRelative"?): return .move
        case ("touch", "ended"?), ("touch", "cancelled"?), ("pointer", "up"?): return .release
        default: return .other
        }
    }

    enum PointerDecision: Equatable, Sendable {
        /// On to the usual gates (and, while locked, the lock screen filter).
        case deliver
        /// A move that isn't for a live view: dropped without a word (it isn't input anyone typed).
        case drop
        /// A press that can't go: never posted, reported as a click.
        case refuse(Refusal)
    }

    /// Presses and moves follow the keyboard's rule; releases always go (the injector releases
    /// only what it pressed, so a release whose press was refused posts nothing).
    static func pointerDecision(_ kind: PointerKind, tagged: Bool, viewLive: Bool, unlocked: Bool) -> PointerDecision {
        switch kind {
        case .release, .other:
            return .deliver
        case .press:
            if tagged { return viewLive ? .deliver : .refuse(unlocked ? .unlocked : .notShown) }
            return viewLive ? .refuse(.untagged) : .deliver
        case .move:
            if tagged { return viewLive ? .deliver : .drop }
            return viewLive ? .drop : .deliver
        }
    }

    /// Keystrokes a refused `keyboard` message held: a press or down is one, text one per character.
    static func keystrokes(action: String, text: String?) -> Int {
        switch action {
        case "press", "down": return 1
        case "text": return text?.count ?? 0
        default: return 0
        }
    }
}
