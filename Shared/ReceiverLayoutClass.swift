// The one rule for "roomy" receiver windows, plus the small pure decisions
// that hang off it: the Settings presentation latch, first-run defaults on a
// roomy window, and the table that keeps every control reachable in both
// layouts. Foundation only, so the hostless Mac test target covers it.
//
// Size classes (never the device idiom or orientation) decide the layout: an
// iPhone Duo window can be regular in both directions when unfolded, and a
// fold resizes the window mid-session.

import Foundation

enum ReceiverLayoutClass {
    /// The iPad-style presentation (Strip/Overlay/Custom, Control Size, …)
    /// applies only when the window is regular in BOTH directions, so a phone
    /// in landscape (regular width, compact height) stays compact.
    static func isRoomy(horizontalRegular: Bool, verticalRegular: Bool) -> Bool {
        horizontalRegular && verticalRegular
    }

    /// What a window with no saved control preferences starts with when the
    /// first layout class it ever reports is roomy although the device
    /// started compact (an iPhone idiom that unfolded onto a roomy window):
    /// the existing iPad initial defaults. `nil` for everything else, so
    /// saved preferences are never replaced, and neither is a later fold.
    static func firstRunPreferences(hasSavedPreferences: Bool, isFirstLayoutClass: Bool,
                                    roomy: Bool, startedRoomy: Bool) -> ReceiverControlPreferences? {
        guard !hasSavedPreferences, isFirstLayoutClass, roomy, !startedRoomy else { return nil }
        return .initial(isPad: true)
    }
}

/// What one control store knows about its window's layout class. Every
/// store (the live one and Demo Mode's own) feeds its window's size classes
/// through one of these, so they decide roomy and first-run defaults alike.
struct ReceiverLayoutClassState: Equatable {
    private(set) var isRoomy: Bool
    /// Whether a size-class report has arrived yet; only the first may adopt
    /// first-run defaults.
    private(set) var hasSeenLayoutClass = false

    struct Change: Equatable {
        /// `isRoomy` flipped with this report.
        var roomyChanged: Bool
        /// Preferences to adopt in place of the starting ones, on a first
        /// report only (see `ReceiverLayoutClass.firstRunPreferences`).
        var adoptedPreferences: ReceiverControlPreferences?
    }

    /// `startsRoomy`: the device's own starting guess, before any window
    /// has reported (an iPad idiom starts roomy).
    init(startsRoomy: Bool) { isRoomy = startsRoomy }

    mutating func update(horizontalRegular: Bool, verticalRegular: Bool, hasSavedPreferences: Bool) -> Change {
        let roomy = ReceiverLayoutClass.isRoomy(horizontalRegular: horizontalRegular,
                                                verticalRegular: verticalRegular)
        let adopted = ReceiverLayoutClass.firstRunPreferences(
            hasSavedPreferences: hasSavedPreferences, isFirstLayoutClass: !hasSeenLayoutClass,
            roomy: roomy, startedRoomy: isRoomy)
        hasSeenLayoutClass = true
        let changed = roomy != isRoomy
        isRoomy = roomy
        return Change(roomyChanged: changed, adoptedPreferences: adopted)
    }
}

/// How Settings is presented over the receiver: a sheet on compact windows,
/// full screen on roomy ones (a form sheet would collapse the split view).
enum SettingsPresentationStyle: Equatable {
    case sheet
    case fullScreen

    static func style(roomy: Bool) -> SettingsPresentationStyle { roomy ? .fullScreen : .sheet }

    /// The style to present with: the one decided when Settings opened
    /// (`latched`) while it is open, else the current window's. A fold while
    /// Settings is open therefore cannot dismiss one presentation while
    /// presenting the other.
    static func resolved(latched: SettingsPresentationStyle?, roomyNow: Bool) -> SettingsPresentationStyle {
        latched ?? style(roomy: roomyNow)
    }
}

/// Where a control of the other layout can be reached.
///
/// Every roomy standard control has a compact counterpart (or a documented
/// exception) and every compact control has a roomy one, so folding or
/// unfolding never removes a capability. Adding a case to either enum fails
/// to compile here until its counterpart is decided.
enum CompactCounterpart: Equatable {
    /// A Main Tray item.
    case trayItem(ControlTrayItem)
    /// A built-in Function Tray action by id, off by default and switched on
    /// in the Function Tray editor.
    case functionTrayAction(String)
    /// The compact arrow button and its keypad.
    case arrowKeysButton
    /// Deliberately not offered; the reason is documented.
    case documentedException(String)
}

enum RoomyCounterpart: Equatable {
    /// A rail/Custom standard control.
    case standardControl(PadStandardControl)
    /// Modifiers come from the Control Profile on the rail's key group.
    case profileModifier
    /// The permanent Settings gear.
    case permanentSettings
}

extension PadStandardControl {
    var compactCounterpart: CompactCounterpart {
        switch self {
        case .menuBar: return .functionTrayAction("menu-bar")
        case .dock: return .trayItem(.dock)
        case .showDesktop: return .functionTrayAction("show-desktop")
        case .controlCenter: return .functionTrayAction("control-center")
        case .escape: return .trayItem(.escape)
        case .tab: return .trayItem(.tab)
        case .keyboard: return .trayItem(.keyboard)
        case .arrowKeys: return .arrowKeysButton
        case .moveView:
            return .documentedException("Move View is a one-finger mode toggle that needs the roomy rail's banner; "
                + "the compact layout keeps two-finger pan, pinch and rotate for the same view navigation.")
        }
    }
}

extension ControlTrayItem {
    var roomyCounterpart: RoomyCounterpart {
        switch self {
        case .command, .option, .control, .shift: return .profileModifier
        case .escape: return .standardControl(.escape)
        case .tab: return .standardControl(.tab)
        case .dock: return .standardControl(.dock)
        case .keyboard: return .standardControl(.keyboard)
        case .settings: return .permanentSettings
        }
    }
}
