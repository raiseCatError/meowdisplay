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
    /// In Window view, which can't show the lock screen, on a device that isn't set to Always
    /// Allow: Full Desktop is a new connection, whose control an Ask device can't get while locked.
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
    }

    /// Nil: allowed.
    static func denial(_ i: Inputs) -> LockScreenDenial? {
        guard i.admitted else { return .notAdmitted }
        guard i.masterInput else { return .inputOff }
        guard i.onConsole, i.privacy != .switchedOut else { return .otherUser }
        guard i.privacy == .locked else { return .notLocked }
        guard i.policy != .neverAllow else { return .neverAllow }
        guard i.lockScreenControlAllowed else { return .turnedOff }
        guard i.sessionGranted else { return i.policy == .alwaysAllow ? .needsControl : .controlBeforeLock }
        return i.windowView ? .windowView : nil
    }

    /// What this device is told (`macLockState`). In Window view: Full Desktop first when the new
    /// connection will get control back without a prompt (Always Allow), else not offered.
    static func offer(_ i: Inputs, active: Bool) -> LockScreenOffer {
        if active { return .active }
        if i.windowView {
            var fullDesktop = i
            fullDesktop.windowView = false
            fullDesktop.sessionGranted = false
            switch denial(fullDesktop) {
            case .needsControl?: return .needsFullDesktop
            case .controlBeforeLock?: return .unavailable(LockScreenDenial.windowView.rawValue)
            case let d?: return .unavailable(d.rawValue)
            case nil: return .needsFullDesktop
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

/// What the login window needs, and nothing more: pointer moves and primary clicks (a touch is
/// one), character keys with Shift or Option (passwords), Return, Tab, Delete, Forward Delete,
/// Escape, Space and the arrows. No Command or Control, no function, navigation, input-source
/// or media keys, no right-click, scrolling or gestures.
enum LockScreenInputFilter {
    /// Held modifiers (`modifierDown`): Shift and Option. Caps Lock also rides on typed keys.
    static let allowedModifiers: Set<String> = [ControlModifier.shift.rawValue, ControlModifier.option.rawValue]
    static let allowedKeyFlags: Set<String> = allowedModifiers.union(["capsLock"])

    static let allowedKeys: Set<HIDKeyUsage> = {
        var keys: Set<HIDKeyUsage> = [
            .returnOrEnter, .escape, .deleteOrBackspace, .tab, .spacebar, .forwardDelete,
            .rightArrow, .leftArrow, .downArrow, .upArrow,
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
}
