import Foundation

enum ControlModifier: String, Codable, CaseIterable, Hashable, Identifiable {
    case command
    case option
    case control
    case shift

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }

    var title: String { rawValue.capitalized }
}

/// A stable, order-independent key for a modifier combination.
struct ModifierChord: Codable, Hashable, Identifiable {
    private(set) var modifiers: Set<ControlModifier>

    init(_ modifiers: Set<ControlModifier> = []) {
        self.modifiers = modifiers
    }

    init(_ modifiers: [ControlModifier]) {
        self.modifiers = Set(modifiers)
    }

    var id: String {
        ControlModifier.allCases.filter(modifiers.contains).map(\.rawValue).joined(separator: "+")
    }

    var displayName: String {
        let ordered = ControlModifier.allCases.filter(modifiers.contains)
        return ordered.isEmpty ? "No Modifiers" : ordered.map(\.title).joined(separator: " + ")
    }

    var symbols: String {
        ControlModifier.allCases.filter(modifiers.contains).map(\.symbol).joined()
    }

    /// Compact keycap form for the heads-up display: `⌘C`, `⌘⌥V`, `⌘⇧4`.
    func hudText(for key: String) -> String {
        symbols + key
    }

    func contains(_ modifier: ControlModifier) -> Bool { modifiers.contains(modifier) }
}

enum ControlTrayItem: String, Codable, CaseIterable, Identifiable {
    case command
    case option
    case control
    case shift
    case escape
    case tab
    case keyboard
    /// Opens receiver Settings. The raw value stays `"more"` so profiles
    /// persisted before it became a gear still decode.
    case settings = "more"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        case .shift: return "Shift"
        case .escape: return "Escape"
        case .tab: return "Tab"
        case .keyboard: return "Keyboard"
        case .settings: return "Settings"
        }
    }

    var displayLabel: String {
        switch self {
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        case .escape: return "esc"
        case .tab: return "tab"
        case .keyboard: return "keyboard"
        case .settings: return "gearshape.fill"
        }
    }

    var modifier: ControlModifier? {
        switch self {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        default: return nil
        }
    }
}

struct TrayItemConfiguration: Codable, Equatable, Identifiable {
    var item: ControlTrayItem
    var isVisible: Bool
    var id: ControlTrayItem { item }
}

struct KeyboardShortcut: Codable, Equatable {
    var usage: Int
    var modifiers: ModifierChord
}

enum ControlAction: Codable, Equatable {
    case keyboardShortcut(KeyboardShortcut)
}

struct ShortcutItem: Codable, Equatable, Identifiable {
    var id: String
    var title: String
    var displayKey: String
    var action: ControlAction

    init(id: String = UUID().uuidString, title: String, displayKey: String,
         usage: Int, modifiers: ModifierChord) {
        self.id = id
        self.title = title
        self.displayKey = displayKey
        action = .keyboardShortcut(KeyboardShortcut(usage: usage, modifiers: modifiers))
    }
}

struct ChordPalette: Codable, Equatable, Identifiable {
    var chord: ModifierChord
    var actions: [ShortcutItem]
    var id: String { chord.id }
}

enum ControlProfileSlot: String, Codable, CaseIterable, Identifiable {
    case `default`
    case profile1
    case profile2

    var id: String { rawValue }
    var title: String {
        switch self {
        case .default: return "Default"
        case .profile1: return "Profile 1"
        case .profile2: return "Profile 2"
        }
    }
}

struct ControlProfile: Codable, Equatable, Identifiable {
    var slot: ControlProfileSlot
    var trayItems: [TrayItemConfiguration]
    var palettes: [ChordPalette]
    var id: String { slot.rawValue }

    var visibleTrayItems: [ControlTrayItem] {
        trayItems.filter(\.isVisible).map(\.item)
    }

    func actions(for chord: ModifierChord) -> [ShortcutItem] {
        palettes.first(where: { $0.chord == chord })?.actions ?? []
    }

    mutating func setActions(_ actions: [ShortcutItem], for chord: ModifierChord) {
        if let index = palettes.firstIndex(where: { $0.chord == chord }) {
            palettes[index].actions = actions
        } else {
            palettes.append(ChordPalette(chord: chord, actions: actions))
        }
    }

    mutating func moveTrayItems(from source: IndexSet, to destination: Int) {
        trayItems.moveItems(from: source, to: destination)
    }

    mutating func moveActions(for chord: ModifierChord, from source: IndexSet, to destination: Int) {
        var values = actions(for: chord)
        values.moveItems(from: source, to: destination)
        setActions(values, for: chord)
    }
}

private extension Array {
    mutating func moveItems(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { self[$0] }
        for index in source.sorted(by: >) { remove(at: index) }
        let removedBeforeDestination = source.filter { $0 < destination }.count
        insert(contentsOf: moving, at: Swift.max(0, destination - removedBeforeDestination))
    }
}

extension ControlProfile {
    static func canonical(slot: ControlProfileSlot = .default) -> ControlProfile {
        let tray = ControlTrayItem.allCases.map { TrayItemConfiguration(item: $0, isVisible: true) }
        let command = ModifierChord([.command])
        let commandOption = ModifierChord([.command, .option])
        let commandShift = ModifierChord([.command, .shift])
        return ControlProfile(slot: slot, trayItems: tray, palettes: [
            ChordPalette(chord: command, actions: [
                shortcut("copy", "Copy", "C", 6, command),
                shortcut("paste", "Paste", "V", 25, command),
                shortcut("cut", "Cut", "X", 27, command),
                shortcut("undo", "Undo", "Z", 29, command),
                shortcut("select-all", "Select All", "A", 4, command),
                shortcut("close", "Close", "W", 26, command),
                shortcut("spotlight", "Spotlight", "Space", 44, command),
            ]),
            ChordPalette(chord: commandOption, actions: [
                shortcut("move-here", "Move Item Here", "V", 25, commandOption),
                shortcut("force-quit", "Force Quit", "Esc", 41, commandOption),
                shortcut("dock", "Show/Hide Dock", "D", 7, commandOption),
                shortcut("hide-others", "Hide Others", "H", 11, commandOption),
                shortcut("close-all", "Close All Windows", "W", 26, commandOption),
            ]),
            ChordPalette(chord: commandShift, actions: [
                shortcut("redo", "Redo", "Z", 29, commandShift),
                shortcut("new-folder", "New Folder", "N", 17, commandShift),
                shortcut("reopen-tab", "Reopen Closed Tab", "T", 23, commandShift),
                shortcut("screenshot", "Screenshot", "3", 32, commandShift),
                shortcut("screenshot-selection", "Screenshot Selection", "4", 33, commandShift),
                shortcut("screenshot-controls", "Screenshot Controls", "5", 34, commandShift),
            ]),
        ])
    }

    private static func shortcut(_ id: String, _ title: String, _ key: String,
                                 _ usage: Int, _ chord: ModifierChord) -> ShortcutItem {
        ShortcutItem(id: id, title: title, displayKey: key, usage: usage, modifiers: chord)
    }
}

/// Which side of the screen the tray hugs in landscape. Portrait is always
/// bottom-centered, so this only applies to landscape.
enum LandscapeTraySide: String, Codable, CaseIterable, Identifiable {
    case leading
    case trailing

    var id: String { rawValue }
    var title: String { self == .leading ? "Left" : "Right" }
}

/// Superseded by `LandscapeTraySide`. Decoded only to migrate schema-2
/// preferences; never written.
enum LandscapeTrayCorner: String, Codable, CaseIterable, Identifiable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeading: return "Top Left"
        case .topTrailing: return "Top Right"
        case .bottomLeading: return "Bottom Left"
        case .bottomTrailing: return "Bottom Right"
        }
    }

    var side: LandscapeTraySide {
        self == .topLeading || self == .bottomLeading ? .leading : .trailing
    }
}

struct ReceiverControlPreferences: Codable, Equatable {
    static let schemaVersion = 3

    var version = schemaVersion
    var trayEnabled = true
    var keyboardButtonEnabled = true
    var hapticsEnabled = true
    var preferredLandscapeSide = LandscapeTraySide.trailing
    var activeControlProfile = ControlProfileSlot.default
    var trayCollapsed = false
    /// Master remote-input gate, receiver-local and (once connected to a
    /// Mac speaking `allowInputWireVersion`) kept in sync with the Mac's own
    /// Allow Input toggle — see `StreamReceiver.requestAllowInput` /
    /// `onAllowInputStateChange`. Settings/the gear are never gated by this;
    /// only remote touch/pointer/keyboard/gesture output is.
    var allowInput = true
    var profiles: [ControlProfile]

    init(profiles: [ControlProfile] = ControlProfileSlot.allCases.map { ControlProfile.canonical(slot: $0) }) {
        self.profiles = profiles
    }

    /// Whether the normal (non-collapsed-to-gear) control tray is allowed to
    /// render at all: `trayEnabled` is the user's stored preference, but it
    /// can never show while `allowInput` is off — PRODUCT RULE: the tray
    /// only ever drives remote input, and the stored preference is
    /// deliberately preserved (not zeroed) so it comes back automatically
    /// once input is re-allowed.
    var trayCanBeShown: Bool { allowInput && trayEnabled }

    /// Hand-written so a key added by a later schema does not make the whole
    /// blob undecodable — synthesized `Codable` ignores property defaults when
    /// a key is missing, which would silently reset every preference the user
    /// had set instead of migrating them.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = ReceiverControlPreferences()
        func value<T: Decodable>(_ key: CodingKeys, _ default: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? `default`
        }
        // Absent means "written before versioning existed", i.e. schema 1.
        version = try value(.version, 1)
        trayEnabled = try value(.trayEnabled, fallback.trayEnabled)
        keyboardButtonEnabled = try value(.keyboardButtonEnabled, fallback.keyboardButtonEnabled)
        hapticsEnabled = try value(.hapticsEnabled, fallback.hapticsEnabled)
        preferredLandscapeSide = try value(.preferredLandscapeSide, fallback.preferredLandscapeSide)
        activeControlProfile = try value(.activeControlProfile, fallback.activeControlProfile)
        trayCollapsed = try value(.trayCollapsed, fallback.trayCollapsed)
        // Absent (schema < 4) means "written before either preference
        // existed" — default both to their pre-feature-equivalent behavior:
        // input was always allowed, and touch was always direct/absolute.
        allowInput = try value(.allowInput, fallback.allowInput)
        profiles = try value(.profiles, fallback.profiles)
    }

    func profile(for slot: ControlProfileSlot) -> ControlProfile {
        profiles.first(where: { $0.slot == slot }) ?? .canonical(slot: slot)
    }

    mutating func updateProfile(_ profile: ControlProfile) {
        if let index = profiles.firstIndex(where: { $0.slot == profile.slot }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
    }

    mutating func resetProfile(_ slot: ControlProfileSlot) {
        updateProfile(.canonical(slot: slot))
    }
}

struct ReceiverControlPreferencesRepository {
    static let defaultsKey = "receiverControlPreferences.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> ReceiverControlPreferences {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              var value = try? JSONDecoder().decode(ReceiverControlPreferences.self, from: data),
              value.version <= ReceiverControlPreferences.schemaVersion else {
            return ReceiverControlPreferences()
        }
        if value.version < 2 {
            for index in value.profiles.indices
                where !value.profiles[index].trayItems.contains(where: { $0.item == .tab }) {
                let keyboardIndex = value.profiles[index].trayItems.firstIndex(where: { $0.item == .keyboard })
                    ?? value.profiles[index].trayItems.endIndex
                value.profiles[index].trayItems.insert(
                    TrayItemConfiguration(item: .tab, isVisible: true), at: keyboardIndex)
            }
            value.version = 2
        }
        if value.version < 3 {
            // Schema 2 stored a four-corner landscape anchor; the tray is now
            // side-anchored and vertically centered. Carry the left/right half
            // of the old choice over so a left-handed layout survives.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let raw = object["preferredLandscapeCorner"] as? String,
               let corner = LandscapeTrayCorner(rawValue: raw) {
                value.preferredLandscapeSide = corner.side
            }
            value.version = 3
        }
        // Schema 3 predates both `allowInput` and `inputMode`; the custom
        // decoder above already defaulted them (input always allowed,
        // always direct/absolute) — nothing to transform, just record it.
        if value.version < 4 {
            value.version = 4
        }
        return value
    }

    func save(_ preferences: ReceiverControlPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

struct ReceiverUIPreferenceUpdate: Equatable {
    var trayEnabled: Bool?
    var keyboardButtonEnabled: Bool?

    init?(message: [String: Any]) {
        guard message["type"] as? String == WireMessage.receiverUI else { return nil }
        trayEnabled = message["trayEnabled"] as? Bool
        keyboardButtonEnabled = message["keyboardButtonEnabled"] as? Bool
        guard trayEnabled != nil || keyboardButtonEnabled != nil else { return nil }
    }

    func apply(to preferences: inout ReceiverControlPreferences) {
        if let trayEnabled { preferences.trayEnabled = trayEnabled }
        if let keyboardButtonEnabled { preferences.keyboardButtonEnabled = keyboardButtonEnabled }
    }
}
