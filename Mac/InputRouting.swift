import CoreGraphics
import Foundation

enum InputTargetMode {
    case mirror
    case extend
}

/// Selects the display whose pixels are represented by normalized video input.
enum InputTargetResolver {
    static func displayID(mode: InputTargetMode,
                          mirrorDisplayID: CGDirectDisplayID,
                          virtualDisplayID: CGDirectDisplayID?) -> CGDirectDisplayID? {
        switch mode {
        case .mirror: return mirrorDisplayID
        case .extend: return virtualDisplayID
        }
    }
}

enum InputCoordinateMapper {
    /// Map top-left-origin normalized video coordinates into global CG bounds.
    static func point(x: Double, y: Double, in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.minX + x * bounds.width,
                y: bounds.minY + y * bounds.height)
    }
}

enum InputPolicy {
    static let defaultsKey = "allowInput"

    /// Missing preference means enabled, preserving behavior for existing installs.
    static func allowsInput(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }
}

/// USB HID keyboard-page (0x07) usage numbers the wire protocol accepts for
/// special/raw key events (M4). Values match the USB HID Usage Tables spec,
/// which is also what UIKit's `UIKeyboardHIDUsage` uses, so a receiver can
/// send a hardware key's `UIKey.keyCode.rawValue` unmodified.
enum HIDKeyUsage: Int, CaseIterable {
    case keyA = 4
    case keyB = 5
    case keyC = 6
    case keyD = 7
    case keyE = 8
    case keyF = 9
    case keyG = 10
    case keyH = 11
    case keyI = 12
    case keyJ = 13
    case keyK = 14
    case keyL = 15
    case keyM = 16
    case keyN = 17
    case keyO = 18
    case keyP = 19
    case keyQ = 20
    case keyR = 21
    case keyS = 22
    case keyT = 23
    case keyU = 24
    case keyV = 25
    case keyW = 26
    case keyX = 27
    case keyY = 28
    case keyZ = 29
    case digit1 = 30
    case digit2 = 31
    case digit3 = 32
    case digit4 = 33
    case digit5 = 34
    case digit6 = 35
    case digit7 = 36
    case digit8 = 37
    case digit9 = 38
    case digit0 = 39
    case minus = 45
    case equal = 46
    case leftBracket = 47
    case rightBracket = 48
    case backslash = 49
    case semicolon = 51
    case quote = 52
    case comma = 54
    case period = 55
    case slash = 56
    case returnOrEnter = 40
    case escape = 41
    case deleteOrBackspace = 42
    case tab = 43
    case spacebar = 44
    case forwardDelete = 76
    case rightArrow = 79
    case leftArrow = 80
    case downArrow = 81
    case upArrow = 82
    // A physical keyboard on a receiving Mac (issue #12) names every key;
    // older senders ignore these, as an unrecognized usage must be.
    case grave = 53
    case f1 = 58
    case f2 = 59
    case f3 = 60
    case f4 = 61
    case f5 = 62
    case f6 = 63
    case f7 = 64
    case f8 = 65
    case f9 = 66
    case f10 = 67
    case f11 = 68
    case f12 = 69
    case f13 = 104
    case f14 = 105
    case f15 = 106
    case f16 = 107
    case f17 = 108
    case f18 = 109
    case f19 = 110
    case f20 = 111
    case insertOrHelp = 73
    case home = 74
    case pageUp = 75
    case end = 77
    case pageDown = 78
    case nonUSBackslash = 100
    case international1 = 135
    case international3 = 137
    case lang1 = 144
    case lang2 = 145
    case keypadNumLockOrClear = 83
    case keypadSlash = 84
    case keypadAsterisk = 85
    case keypadMinus = 86
    case keypadPlus = 87
    case keypadEnter = 88
    case keypad1 = 89
    case keypad2 = 90
    case keypad3 = 91
    case keypad4 = 92
    case keypad5 = 93
    case keypad6 = 94
    case keypad7 = 95
    case keypad8 = 96
    case keypad9 = 97
    case keypad0 = 98
    case keypadPeriod = 99
    case keypadEqual = 103
    case keypadComma = 133

    /// The macOS virtual key code (`CGKeyCode`, US ANSI layout) this usage
    /// injects as.
    var keyCode: CGKeyCode {
        switch self {
        case .keyA: return 0
        case .keyB: return 11
        case .keyC: return 8
        case .keyD: return 2
        case .keyE: return 14
        case .keyF: return 3
        case .keyG: return 5
        case .keyH: return 4
        case .keyI: return 34
        case .keyJ: return 38
        case .keyK: return 40
        case .keyL: return 37
        case .keyM: return 46
        case .keyN: return 45
        case .keyO: return 31
        case .keyP: return 35
        case .keyQ: return 12
        case .keyR: return 15
        case .keyS: return 1
        case .keyT: return 17
        case .keyU: return 32
        case .keyV: return 9
        case .keyW: return 13
        case .keyX: return 7
        case .keyY: return 16
        case .keyZ: return 6
        case .digit1: return 18
        case .digit2: return 19
        case .digit3: return 20
        case .digit4: return 21
        case .digit5: return 23
        case .digit6: return 22
        case .digit7: return 26
        case .digit8: return 28
        case .digit9: return 25
        case .digit0: return 29
        case .minus: return 27
        case .equal: return 24
        case .leftBracket: return 33
        case .rightBracket: return 30
        case .backslash: return 42
        case .semicolon: return 41
        case .quote: return 39
        case .comma: return 43
        case .period: return 47
        case .slash: return 44
        case .returnOrEnter: return 36
        case .escape: return 53
        case .deleteOrBackspace: return 51
        case .tab: return 48
        case .spacebar: return 49
        case .forwardDelete: return 117
        case .rightArrow: return 124
        case .leftArrow: return 123
        case .downArrow: return 125
        case .upArrow: return 126
        case .grave: return 50
        case .f1: return 122
        case .f2: return 120
        case .f3: return 99
        case .f4: return 118
        case .f5: return 96
        case .f6: return 97
        case .f7: return 98
        case .f8: return 100
        case .f9: return 101
        case .f10: return 109
        case .f11: return 103
        case .f12: return 111
        case .f13: return 105
        case .f14: return 107
        case .f15: return 113
        case .f16: return 106
        case .f17: return 64
        case .f18: return 79
        case .f19: return 80
        case .f20: return 90
        case .insertOrHelp: return 114
        case .home: return 115
        case .pageUp: return 116
        case .end: return 119
        case .pageDown: return 121
        case .nonUSBackslash: return 10
        case .international1: return 94
        case .international3: return 93
        case .lang1: return 104
        case .lang2: return 102
        case .keypadNumLockOrClear: return 71
        case .keypadSlash: return 75
        case .keypadAsterisk: return 67
        case .keypadMinus: return 78
        case .keypadPlus: return 69
        case .keypadEnter: return 76
        case .keypad1: return 83
        case .keypad2: return 84
        case .keypad3: return 85
        case .keypad4: return 86
        case .keypad5: return 87
        case .keypad6: return 88
        case .keypad7: return 89
        case .keypad8: return 91
        case .keypad9: return 92
        case .keypad0: return 82
        case .keypadPeriod: return 65
        case .keypadEqual: return 81
        case .keypadComma: return 95
        }
    }

    /// Parses a wire `usage` value — an arbitrary, untrusted JSON number —
    /// into a known HID usage, rejecting anything non-integral, negative, or
    /// out of the 16-bit HID usage range before it can reach an unchecked
    /// conversion. Also the single place an unrecognized (but validly
    /// formed) usage is rejected.
    static func parse(_ value: Any?) -> HIDKeyUsage? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(),
              double >= 0, double <= 65535 else { return nil }
        return HIDKeyUsage(rawValue: Int(double))
    }
}

extension ControlModifier {
    var keyCode: CGKeyCode {
        switch self {
        case .command: return 55
        case .shift: return 56
        case .option: return 58
        case .control: return 59
        }
    }

    var eventFlag: CGEventFlags {
        switch self {
        case .command: return .maskCommand
        case .shift: return .maskShift
        case .option: return .maskAlternate
        case .control: return .maskControl
        }
    }
}

struct HeldModifierTracker {
    private(set) var held: Set<ControlModifier> = []

    mutating func down(_ modifier: ControlModifier) -> Bool {
        held.insert(modifier).inserted
    }

    mutating func up(_ modifier: ControlModifier) -> Bool {
        held.remove(modifier) != nil
    }

    var flags: CGEventFlags {
        held.reduce(into: CGEventFlags()) { $0.insert($1.eventFlag) }
    }

    mutating func releaseAll() -> [ControlModifier] {
        let values = ControlModifier.allCases.reversed().filter(held.contains)
        held.removeAll()
        return values
    }
}

/// Named protocol keyboard modifiers. The wire carries these strings, never
/// raw UIKit modifier bit masks.
enum KeyModifier: String {
    case shift
    case control
    case option
    case command
    case capsLock

    var flag: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        case .capsLock: return .maskAlphaShift
        }
    }

    /// Decodes wire modifier names into event flags, silently ignoring
    /// unrecognized names (an additive future modifier from a newer peer).
    static func flags(named names: [String]) -> CGEventFlags {
        names.reduce(into: CGEventFlags()) { flags, name in
            guard let modifier = KeyModifier(rawValue: name) else { return }
            flags.insert(modifier.flag)
        }
    }
}

/// The event flags a committed-text keyboard event must carry: none, always.
/// A stray or ambient modifier flag on a text-commit event reads to the
/// receiving app as a shortcut instead of typed text — e.g. plain "t" firing
/// Chrome's Cmd+T (observed on a real device: a modified hardware key event
/// left `.hidSystemState` reporting Command down, and the text path's
/// CGEvents inherited that ambient flag because they never set `.flags`
/// explicitly). Named and tested in isolation so the invariant "text is
/// never modified" stays visible and can't silently regress.
enum KeyboardTextFlags {
    static let committed: CGEventFlags = []
}

/// The same invariant as `KeyboardTextFlags`, applied to every synthetic
/// mouse event `InputInjector` posts (touch taps, scroll, pointer moves,
/// and pointer down/up): a left-unset `.flags` field doesn't mean "no
/// modifiers" — it means "inherit whatever the shared `.hidSystemState`
/// event source's current combined modifier flags happen to be," which
/// any other synthetic event (this app's own, or anyone else's) can leave
/// non-empty. A real-device incident showed exactly that: `SystemGestureInvoker`
/// stamps `.maskControl` on the arrow-key events it posts to simulate
/// Control+Up/Down/Left/Right (Mission Control/App Exposé/Spaces — a
/// faithful reproduction of the real shortcut, since a physically-held
/// Control key's own keyDown truly does precede the arrow's), and Quartz's
/// combined-session modifier state absorbed that flag from the key events
/// with nothing ever asserting it should be cleared again (no real Control
/// keyDown/keyUp pair was ever posted to release it). Every following
/// mouse click, having never stated its own flags, silently inherited that
/// stuck Control flag — and macOS reads a Control-clicked left button as a
/// secondary/right click, which is exactly the "next tap becomes a right
/// click" bug this fixes. Command+Space (Spotlight) never reproduced it
/// because a stray Command flag on a click has no such special meaning.
///
/// The fix is NOT "always clear all mouse flags": the receiver's control
/// tray can legitimately latch a modifier (`InputInjector.handleModifier`)
/// that a subsequent click is supposed to carry (Cmd-click, Shift-click,
/// …), tracked in `heldModifiers`. So every mouse event explicitly sets
/// `.flags = heldModifiers.flags` — MeowDisplay's own intentionally-held
/// modifiers, exactly, never more (ambient/stale) and never less (a real
/// latched one silently dropped).
enum MouseEventFlags {}

/// Prepares committed keyboard text for Unicode injection, rejecting empty
/// or unreasonably large payloads before they reach a CGEvent.
enum KeyboardTextPlanner {
    static let maxUTF16Length = 4096

    static func plan(_ text: String) -> [unichar]? {
        guard !text.isEmpty else { return nil }
        let units = Array(text.utf16)
        guard !units.isEmpty, units.count <= maxUTF16Length else { return nil }
        return units
    }
}

/// Tracks which hardware keys are currently held, deciding whether a
/// down/up message should produce a synthetic event or be ignored as a
/// duplicate/spurious transition. Pure state, no CGEvent side effects, so
/// it can be exercised directly by tests without touching real input.
struct HeldKeyTracker {
    private(set) var held: Set<HIDKeyUsage> = []

    /// Returns true if this down should be posted, i.e. the key wasn't
    /// already held (a duplicate down is ignored).
    @discardableResult
    mutating func down(_ usage: HIDKeyUsage) -> Bool {
        held.insert(usage).inserted
    }

    /// Returns true if this up should be posted, i.e. the key was actually
    /// held (a spurious up is ignored).
    @discardableResult
    mutating func up(_ usage: HIDKeyUsage) -> Bool {
        held.remove(usage) != nil
    }

    /// Every currently held key, clearing tracked state — used to release
    /// everything on cancellation.
    mutating func releaseAll() -> Set<HIDKeyUsage> {
        defer { held.removeAll() }
        return held
    }

    /// A `down` marked `repeat` (a receiving Mac's own key repeat) posts an
    /// auto-repeat key-down only for a key that is actually held — never a
    /// fresh press, so a repeat can't outlive its key's release.
    func allowsRepeat(_ usage: HIDKeyUsage) -> Bool {
        held.contains(usage)
    }
}

/// Scroll arrives in video pixels and posts in whole points, so a single
/// small delta used to round away: a slow trackpad scroll from a receiving
/// Mac (fractions of a point per event) barely moved. The rounding error is
/// carried into the next event instead, so the total scrolled always matches
/// the total sent. Single events still round to nearest, as before.
struct ScrollRemainder {
    private(set) var x = 0.0
    private(set) var y = 0.0

    mutating func take(dxPoints: Double, dyPoints: Double) -> (dx: Int32, dy: Int32) {
        let totalX = x + dxPoints, totalY = y + dyPoints
        let wholeX = totalX.rounded(), wholeY = totalY.rounded()
        x = totalX - wholeX
        y = totalY - wholeY
        return (Int32(clamping: Int(wholeX)), Int32(clamping: Int(wholeY)))
    }

    mutating func reset() {
        x = 0
        y = 0
    }
}

struct SystemGestureShortcut {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

/// Maps semantic receiver actions to documented macOS keyboard shortcuts.
/// The shortcuts are defaults; macOS does not expose a public API for reading
/// user-customized Mission Control hotkeys.
enum SystemGestureShortcutMapping {
    static func shortcut(for gesture: ReceiverGesture,
                         macOSMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        -> SystemGestureShortcut {
        switch gesture {
        case .missionControl:
            // Control-Up also needs SecondaryFn in a posted CGEvent.
            return SystemGestureShortcut(keyCode: 126, flags: [.maskControl, .maskSecondaryFn])
        case .appExpose:
            return SystemGestureShortcut(keyCode: 125, flags: [.maskControl, .maskSecondaryFn])
        case .nextSpace:
            return SystemGestureShortcut(keyCode: 124, flags: [.maskControl, .maskSecondaryFn])
        case .previousSpace:
            return SystemGestureShortcut(keyCode: 123, flags: [.maskControl, .maskSecondaryFn])
        case .showDesktop:
            // Synthetic F11 needs SecondaryFn on the tested macOS setup.
            return SystemGestureShortcut(keyCode: 103, flags: .maskSecondaryFn)
        case .launchpad:
            if macOSMajorVersion >= 26 {
                // macOS Tahoe renamed Launchpad to Apps and documents Fn-Shift-A.
                return SystemGestureShortcut(keyCode: 0, flags: [.maskShift, .maskSecondaryFn])
            }
            return SystemGestureShortcut(keyCode: 118, flags: [])
        case .spotlight:
            // Command-Space opens Spotlight.
            return SystemGestureShortcut(keyCode: 49, flags: .maskCommand)
        case .controlCenter:
            // Fn/Globe-C: "Show or hide Control Center" (macOS 12+).
            return SystemGestureShortcut(keyCode: 8, flags: .maskSecondaryFn)
        case .menuBar:
            // Control-F2: "Move focus to the menu bar" — reveals it even in
            // full screen; Escape (or a click elsewhere) leaves it. F2 needs
            // SecondaryFn in a posted CGEvent, like F11 above.
            return SystemGestureShortcut(keyCode: 120, flags: [.maskControl, .maskSecondaryFn])
        }
    }
}
