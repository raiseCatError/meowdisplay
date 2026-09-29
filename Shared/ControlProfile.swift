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

    var title: String {
        switch self {
        case .command: return String(localized: "Command", comment: "Keyboard modifier key.")
        case .option: return String(localized: "Option", comment: "Keyboard modifier key.")
        case .control: return String(localized: "Control", comment: "Keyboard modifier key.")
        case .shift: return String(localized: "Shift", comment: "Keyboard modifier key.")
        }
    }
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
    case dock
    case keyboard
    /// Opens receiver Settings. The raw value stays `"more"` so profiles
    /// persisted before it became a gear still decode.
    case settings = "more"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .command: return String(localized: "Command")
        case .option: return String(localized: "Option")
        case .control: return String(localized: "Control")
        case .shift: return String(localized: "Shift")
        case .escape: return String(localized: "Escape")
        case .tab: return String(localized: "Tab")
        case .dock: return String(localized: "Toggle Dock")
        case .keyboard: return String(localized: "Keyboard")
        case .settings: return String(localized: "Settings")
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
        case .dock: return "dock.rectangle"
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

struct KeyboardShortcut: Codable, Hashable {
    var usage: Int
    var modifiers: ModifierChord
    /// Further ordinary keys held together with `usage` (e.g. K + 3). Empty
    /// for every ordinary shortcut, and then never encoded, so the wire and
    /// stored form of existing shortcuts is unchanged.
    var additionalUsages: [Int] = []

    /// Every ordinary key in the chord, in press order.
    var usages: [Int] { [usage] + additionalUsages }

    /// USB HID keyboard-page usages a chord may use (modifier keys excluded:
    /// those travel as `modifiers`).
    static let validUsages: ClosedRange<Int> = 4...221
    static let maximumKeys = 4

    var isValid: Bool {
        usages.count <= Self.maximumKeys && usages.allSatisfy(Self.validUsages.contains)
            && Set(usages).count == usages.count
    }
}

extension KeyboardShortcut {
    private enum CodingKeys: String, CodingKey { case usage, modifiers, additionalUsages }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = try container.decode(Int.self, forKey: .usage)
        modifiers = try container.decode(ModifierChord.self, forKey: .modifiers)
        additionalUsages = try container.decodeIfPresent([Int].self, forKey: .additionalUsages) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(usage, forKey: .usage)
        try container.encode(modifiers, forKey: .modifiers)
        if !additionalUsages.isEmpty { try container.encode(additionalUsages, forKey: .additionalUsages) }
    }
}

/// One key transition of a one-tap chord.
struct KeyboardChordEvent: Equatable {
    enum Phase: Equatable { case down, up }
    var phase: Phase
    var usage: Int
    var modifiers: [String]
}

/// How a one-tap shortcut reaches the Mac over the existing `keyboard`
/// messages: a single key uses the atomic `press` (unchanged behavior); a
/// multi-key chord presses every key down in order, then releases them in
/// reverse, so nothing is ever left held.
enum KeyboardChordPlan {
    static func events(for shortcut: KeyboardShortcut) -> [KeyboardChordEvent] {
        let modifiers = ControlModifier.allCases.filter(shortcut.modifiers.contains).map(\.rawValue)
        let keys = shortcut.usages
        return keys.map { KeyboardChordEvent(phase: .down, usage: $0, modifiers: modifiers) }
            + keys.reversed().map { KeyboardChordEvent(phase: .up, usage: $0, modifiers: modifiers) }
    }
}

indirect enum ControlAction: Codable, Hashable, Sendable {
    case keyboardShortcut(KeyboardShortcut)
    /// A semantic `ReceiverGesture` (its raw value) sent as the existing
    /// `gesture` message — for Mac actions that have no reliable keyboard
    /// shortcut (Launchpad, Show Desktop), so they stay reachable if the
    /// 4/5-finger pinch collides with iPadOS's multitasking gestures.
    case receiverGesture(String)
    /// A bounded macro: existing keyboard/semantic actions run in order —
    /// never scripts, never nested sequences. See `ControlActionPlan`.
    case sequence([ControlActionStep])

    static let maximumSequenceSteps = 8
    static let maximumStepDelayMs = 2000

    /// Sequences are 1…`maximumSequenceSteps` flat steps; shortcuts must be
    /// valid chords; gestures must be known semantic actions.
    var isValid: Bool {
        switch self {
        case .keyboardShortcut(let shortcut):
            return shortcut.isValid
        case .receiverGesture(let name):
            return ReceiverGesture(rawValue: name) != nil
        case .sequence(let steps):
            return (1...Self.maximumSequenceSteps).contains(steps.count) && steps.allSatisfy { step in
                if case .sequence = step.action { return false }
                return step.action.isValid && (0...Self.maximumStepDelayMs).contains(step.delayMs)
            }
        }
    }
}

/// One step of a `ControlAction.sequence`, and the pause after it.
struct ControlActionStep: Codable, Hashable, Sendable {
    static let defaultDelayMs = 150
    var action: ControlAction
    var delayMs: Int = ControlActionStep.defaultDelayMs
}

/// One thing a one-tap control does on the existing wire.
enum ControlActionOperation: Equatable {
    /// The atomic `keyboard` press (a single key with its modifiers).
    case press(usage: Int, modifiers: [String])
    /// One half of a multi-key chord.
    case key(KeyboardChordEvent)
    /// The semantic `gesture` message.
    case gesture(String)
    /// A pause between sequence steps.
    case pause(milliseconds: Int)
}

/// The ordered wire operations for a one-tap action. Deterministic; every
/// key that goes down comes back up within its own step, so a sequence can
/// never leave a key held between steps.
enum ControlActionPlan {
    static func operations(for action: ControlAction) -> [ControlActionOperation] {
        guard action.isValid else { return [] }
        switch action {
        case .keyboardShortcut(let shortcut):
            let modifiers = ControlModifier.allCases.filter(shortcut.modifiers.contains).map(\.rawValue)
            if shortcut.additionalUsages.isEmpty { return [.press(usage: shortcut.usage, modifiers: modifiers)] }
            return KeyboardChordPlan.events(for: shortcut).map(ControlActionOperation.key)
        case .receiverGesture(let name):
            return [.gesture(name)]
        case .sequence(let steps):
            return steps.enumerated().flatMap { index, step -> [ControlActionOperation] in
                operations(for: step.action)
                    + (index < steps.count - 1 && step.delayMs > 0 ? [.pause(milliseconds: step.delayMs)] : [])
            }
        }
    }
}

/// How a one-tap button looks — separate from what it does.
enum ShortcutButtonDisplay: Codable, Hashable, Sendable {
    case symbol(String)
    case text(String)
    case emoji(String)
    /// The keys it sends, e.g. `⌃U`.
    case keys

    static let maximumTextLength = 4
}

/// What a button face actually draws.
enum ShortcutButtonFace: Equatable {
    case symbol(String)
    case text(String)
}

struct ShortcutItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var displayKey: String
    var action: ControlAction
    /// Optional SF Symbol name for a native icon (e.g. Function Tray
    /// buttons) — `nil` for the Main Tray's palette shortcuts, which keep
    /// showing `displayKey`'s plain keycap text. Never required: any
    /// renderer can fall back to `displayKey` when this is `nil`.
    var systemImage: String?
    /// The user's chosen face (symbol, text, emoji or keys); `nil` keeps the
    /// default of `systemImage`, else `displayKey`.
    var display: ShortcutButtonDisplay?

    /// What to draw on this button.
    var face: ShortcutButtonFace {
        switch display {
        case .symbol(let name) where !name.isEmpty: return .symbol(name)
        case .text(let text) where !text.isEmpty: return .text(String(text.prefix(ShortcutButtonDisplay.maximumTextLength)))
        case .emoji(let emoji) where !emoji.isEmpty: return .text(String(emoji.prefix(2)))
        case .keys: return .text(keysDescription)
        default: return systemImage.map(ShortcutButtonFace.symbol) ?? .text(displayKey)
        }
    }

    /// The keys this sends, e.g. `⌘⇧P` or `K+3`; a sequence shows its steps.
    var keysDescription: String {
        func describe(_ action: ControlAction) -> String {
            switch action {
            case .keyboardShortcut(let shortcut):
                return shortcut.modifiers.symbols + shortcut.usages.map(appGestureCommandKeyLabel(for:)).joined(separator: "+")
            case .receiverGesture:
                return title
            case .sequence(let steps):
                return steps.map { describe($0.action) }.joined(separator: " → ")
            }
        }
        return describe(action)
    }

    init(id: String = UUID().uuidString, title: String, displayKey: String,
         usage: Int, modifiers: ModifierChord, systemImage: String? = nil) {
        self.id = id
        self.title = title
        self.displayKey = displayKey
        action = .keyboardShortcut(KeyboardShortcut(usage: usage, modifiers: modifiers))
        self.systemImage = systemImage
    }

    init(id: String, title: String, gesture: ReceiverGesture, systemImage: String) {
        self.id = id
        self.title = title
        displayKey = title
        action = .receiverGesture(gesture.rawValue)
        self.systemImage = systemImage
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
        case .default: return String(localized: "Default")
        case .profile1: return String(localized: "Profile 1")
        case .profile2: return String(localized: "Profile 2")
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
                shortcut("dock", "Toggle Dock", "D", 7, commandOption),
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
    var title: String { self == .leading ? String(localized: "Left") : String(localized: "Right") }
    var opposite: LandscapeTraySide { self == .leading ? .trailing : .leading }
}

/// Receiver-local destination for a two-finger pinch or rotation gesture.
/// The stored choice is preserved while video is off; the receiver applies
/// the temporary App override at routing time instead of rewriting it.
enum ReceiverGestureTarget: String, Codable, CaseIterable, Identifiable {
    case viewport
    case app
    // Added after `viewport`/`app` shipped — a String-backed enum, so this is
    // purely additive: previously persisted "viewport"/"app" raw values
    // still decode to the same cases. A true no-op: never zooms/rotates the
    // viewport and never fires an App Gesture Command (see
    // `VideoInteractionPolicy.effectiveTarget`, which must never promote a
    // stored `.disabled` into `.app` the way it does for `.viewport` when
    // video is off).
    case disabled

    var id: String { rawValue }
    var title: String {
        switch self {
        case .viewport: return String(localized: "Viewport", comment: "Gesture target: zoom or rotate the displayed picture.")
        case .app: return String(localized: "App", comment: "Gesture target: send the gesture to the Mac app.")
        case .disabled: return String(localized: "Disabled")
        }
    }
}

/// One configurable App-mode gesture command — see the App Gesture Commands
/// spec. Editable on iPhone via modifier toggles + a key picker; never
/// physical-shortcut recording (that is reserved for a future Mac-side
/// editor).
enum AppGestureCommandKind: String, Codable, CaseIterable, Identifiable {
    case zoomIn
    case zoomOut
    case rotateLeft
    case rotateRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .zoomIn: return String(localized: "Zoom In")
        case .zoomOut: return String(localized: "Zoom Out")
        case .rotateLeft: return String(localized: "Rotate Left")
        case .rotateRight: return String(localized: "Rotate Right")
        }
    }
}

/// Persisted defaults: Cmd+= / Cmd+- / Cmd+[ / Cmd+]. Reuses the existing
/// `KeyboardShortcut`/`ModifierChord` model shared with Main Tray shortcuts
/// (no duplicate key/chord representation). The raw HID usage numbers here
/// are the same USB HID keyboard-page values as `Mac/InputRouting.swift`'s
/// `HIDKeyUsage`, duplicated as literals because `Shared/` also compiles
/// into the iOS target, which never builds Mac-only sources.
struct AppGestureCommands: Codable, Equatable {
    var zoomIn = KeyboardShortcut(usage: 46, modifiers: ModifierChord([.command]))      // Cmd+=
    var zoomOut = KeyboardShortcut(usage: 45, modifiers: ModifierChord([.command]))     // Cmd+-
    var rotateLeft = KeyboardShortcut(usage: 47, modifiers: ModifierChord([.command]))  // Cmd+[
    var rotateRight = KeyboardShortcut(usage: 48, modifiers: ModifierChord([.command])) // Cmd+]

    static let defaults = AppGestureCommands()

    func shortcut(for kind: AppGestureCommandKind) -> KeyboardShortcut {
        switch kind {
        case .zoomIn: return zoomIn
        case .zoomOut: return zoomOut
        case .rotateLeft: return rotateLeft
        case .rotateRight: return rotateRight
        }
    }

    mutating func setShortcut(_ shortcut: KeyboardShortcut, for kind: AppGestureCommandKind) {
        switch kind {
        case .zoomIn: zoomIn = shortcut
        case .zoomOut: zoomOut = shortcut
        case .rotateLeft: rotateLeft = shortcut
        case .rotateRight: rotateRight = shortcut
        }
    }
}

/// Full key list for App Gesture Commands editing (spec section E) —
/// letters, 0-9, the listed symbol keys, and the listed special keys.
/// Deliberately a separate list from `editableShortcutKeys` (Main Tray
/// shortcuts): that one predates this feature and keeps its own smaller,
/// unrelated key set. "+" is not a distinct physical key — it is Shift
/// held with "=" — so it is not listed separately; toggling Shift on the
/// "=" key produces it. Lives in `Shared` (not iOS-only) so Mac Sender's
/// per-device App Gesture Commands section can reuse the exact same key
/// list/labeling instead of a parallel one.
let appGestureCommandEditableKeys: [(String, Int)] = {
    let letters = zip(Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ"), 4...29).map { (String($0), $1) }
    let digits: [(String, Int)] = [("1", 30), ("2", 31), ("3", 32), ("4", 33), ("5", 34),
                                   ("6", 35), ("7", 36), ("8", 37), ("9", 38), ("0", 39)]
    let symbols: [(String, Int)] = [("=", 46), ("-", 45), ("[", 47), ("]", 48),
                                    ("/", 56), ("\\", 49), (",", 54), (".", 55),
                                    (";", 51), ("'", 52)]
    let special: [(String, Int)] = [("Space", 44), ("Return", 40), ("Tab", 43), ("Escape", 41),
                                    ("Delete", 42), ("↑", 82), ("↓", 81), ("←", 80), ("→", 79)]
    return letters + digits + symbols + special
}()

func appGestureCommandKeyLabel(for usage: Int) -> String {
    appGestureCommandEditableKeys.first(where: { $0.1 == usage })?.0 ?? "?"
}

func appGestureCommandDisplayText(for shortcut: KeyboardShortcut) -> String {
    shortcut.modifiers.symbols + appGestureCommandKeyLabel(for: shortcut.usage)
}

// MARK: - Function Tray

/// One Function Tray button. Reuses `ShortcutItem`/`ControlAction` exactly
/// as the Main Tray's chord palettes do — no separate shortcut-injection
/// system — but fires immediately on tap rather than opening a palette.
///
/// `group` is a deliberately generic visual-clustering key — NOT a fixed
/// "zoom group"/"edit group" taxonomy baked into the type — so consecutive
/// items sharing a `group` value render as one small bubble cluster with a
/// gap before the next one (see `FunctionTrayProfile.visibleGroups`),
/// without the architecture assuming there are ever exactly two of them or
/// what they contain. Ordinary `Int`s rather than a named enum for the same
/// reason: adding a new one is just a new integer, not a schema change.
struct FunctionTrayItemConfiguration: Codable, Equatable, Identifiable {
    var item: ShortcutItem
    var isVisible: Bool
    var group: Int
    /// The user's name for a built-in action (custom items rename `item`
    /// itself). Survives canonical metadata refreshes.
    var customTitle: String?
    /// The user's face for a built-in action — see `ShortcutButtonDisplay`.
    var customDisplay: ShortcutButtonDisplay?
    var id: String { item.id }

    /// `item` with the user's name and face applied.
    var resolvedItem: ShortcutItem {
        var resolved = item
        if let customTitle, !customTitle.isEmpty { resolved.title = customTitle }
        if let customDisplay { resolved.display = customDisplay }
        return resolved
    }
}

/// Independent of `ControlProfile` (the Main Tray's profile type) even
/// though it reuses the same `ControlProfileSlot` (Default/Profile 1/
/// Profile 2) naming — Main Tray and Function Tray profiles are selected,
/// stored, and switched completely separately (see
/// `ReceiverControlPreferences.activeFunctionTrayProfile`). Still exactly
/// ONE tray/profile system — `group` (see `FunctionTrayItemConfiguration`)
/// is presentation metadata on top of one flat, ordered item list, not a
/// second parallel tray.
struct FunctionTrayProfile: Codable, Equatable, Identifiable {
    var slot: ControlProfileSlot
    var items: [FunctionTrayItemConfiguration]
    var id: String { slot.rawValue }

    var visibleItems: [ShortcutItem] {
        items.filter(\.isVisible).map(\.resolvedItem)
    }

    /// Every action, visible or not, as it should appear.
    var allItems: [ShortcutItem] { items.map(\.resolvedItem) }

    /// `visibleItems` clustered into consecutive runs of the same `group`
    /// value, in tray order — the rendering seam between one small bubble
    /// cluster and the next. A profile with every item in the same group
    /// (or with grouping never customized) renders as a single cluster;
    /// nothing here requires exactly two.
    var visibleGroups: [[ShortcutItem]] {
        var groups: [[ShortcutItem]] = []
        var currentGroup: Int?
        for configuration in items where configuration.isVisible {
            if currentGroup != configuration.group {
                groups.append([])
                currentGroup = configuration.group
            }
            groups[groups.count - 1].append(configuration.resolvedItem)
        }
        return groups
    }

    mutating func moveItems(from source: IndexSet, to destination: Int) {
        items.moveItems(from: source, to: destination)
    }

    /// Refreshes presentation and shortcut metadata by stable action ID.
    /// Visibility, ordering, and grouping remain entirely user-owned. A
    /// canonical item a saved profile predates is appended HIDDEN, so the
    /// editor can offer it without changing the tray the user already has.
    func resolvingCanonicalMetadata() -> FunctionTrayProfile {
        let canonical = Self.canonical(slot: slot).items
        let canonicalByID = Dictionary(uniqueKeysWithValues: canonical.map { ($0.id, $0.item) })
        let savedIDs = Set(items.map(\.id))
        let resolved: [FunctionTrayItemConfiguration] = items.map { configuration in
            guard let item = canonicalByID[configuration.id] else { return configuration }
            return FunctionTrayItemConfiguration(item: item,
                                                 isVisible: configuration.isVisible,
                                                 group: configuration.group,
                                                 customTitle: configuration.customTitle,
                                                 customDisplay: configuration.customDisplay)
        }
        let added = canonical.filter { !savedIDs.contains($0.id) }.map {
            FunctionTrayItemConfiguration(item: $0.item, isVisible: false, group: $0.group)
        }
        return FunctionTrayProfile(slot: slot, items: resolved + added)
    }
}

extension FunctionTrayProfile {
    /// Modeled generically as "Function Tray" — not hardcoded as an
    /// "Undo/Redo tray" or "Zoom tray" — so future actions (Disconnect,
    /// Paste, contextual app actions, …) are just more items (and,
    /// optionally, groups) in this one list.
    static let canonicalIDs: Set<String> = Set(canonical().items.map(\.id))

    static func isBuiltIn(_ id: String) -> Bool { canonicalIDs.contains(id) }

    static let maximumCustomItems = 24

    /// Adds a user-made action (a shortcut or a sequence), visible, in its
    /// own group at the end. `false` when it isn't valid or the tray is full.
    @discardableResult
    mutating func addCustomItem(_ item: ShortcutItem) -> Bool {
        guard item.action.isValid, !items.contains(where: { $0.id == item.id }),
              items.filter({ !Self.isBuiltIn($0.id) }).count < Self.maximumCustomItems else { return false }
        let group = (items.map(\.group).max() ?? 0) + 1
        items.append(FunctionTrayItemConfiguration(item: item, isVisible: true, group: group))
        return true
    }

    /// Replaces a custom action's definition (its name, keys, face).
    mutating func updateCustomItem(_ item: ShortcutItem) {
        guard item.action.isValid, !Self.isBuiltIn(item.id),
              let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].item = item
    }

    /// Built-in actions can't be deleted — they come back hidden on the
    /// next refresh — so removing one hides it; custom actions are deleted.
    mutating func removeItem(id: String) {
        if Self.isBuiltIn(id) {
            if let index = items.firstIndex(where: { $0.id == id }) { items[index].isVisible = false }
        } else {
            items.removeAll { $0.id == id }
        }
    }

    mutating func rename(id: String, to title: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if Self.isBuiltIn(id) {
            items[index].customTitle = trimmed.isEmpty ? nil : trimmed
        } else if !trimmed.isEmpty {
            items[index].item.title = trimmed
        }
    }

    mutating func setDisplay(id: String, _ display: ShortcutButtonDisplay?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if Self.isBuiltIn(id) { items[index].customDisplay = display } else { items[index].item.display = display }
    }

    static func canonical(slot: ControlProfileSlot = .default) -> FunctionTrayProfile {
        let command = ModifierChord([.command])
        let commandShift = ModifierChord([.command, .shift])
        // Two default visual clusters: an app-level zoom group (asks the
        // Mac's foreground app to zoom its own content via the standard
        // ⌘+/⌘− shortcut — entirely separate from MeowDisplay's own local
        // two-finger viewport pinch/zoom, which never touches this) and an
        // edit group. Both are just `group` values — nothing about
        // `FunctionTrayProfile` itself knows "zoom" or "edit".
        let zoomGroup = 0
        let editGroup = 1
        let systemGroup = 2
        let items: [(ShortcutItem, Int)] = [
            (ShortcutItem(id: "zoom-in", title: "Zoom In", displayKey: "+", usage: 46, modifiers: command,
                         systemImage: "plus.magnifyingglass"), zoomGroup),
            (ShortcutItem(id: "zoom-out", title: "Zoom Out", displayKey: "−", usage: 45, modifiers: command,
                         systemImage: "minus.magnifyingglass"), zoomGroup),
            (ShortcutItem(id: "undo", title: "Undo", displayKey: "Z", usage: 29, modifiers: command,
                         systemImage: "arrow.uturn.backward"), editGroup),
            (ShortcutItem(id: "redo", title: "Redo", displayKey: "Z", usage: 29, modifiers: commandShift,
                         systemImage: "arrow.uturn.forward"), editGroup),
        ]
        // Opt-in (hidden by default): the only routes to Launchpad and Show
        // Desktop besides the 4/5-finger pinch/spread, which can collide
        // with iPadOS's own multitasking gestures.
        let systemItems: [(ShortcutItem, Int)] = [
            (ShortcutItem(id: "menu-bar", title: "Menu Bar", gesture: .menuBar,
                          systemImage: "menubar.rectangle"), systemGroup),
            (ShortcutItem(id: "launchpad", title: "Launchpad", gesture: .launchpad,
                          systemImage: "square.grid.3x3"), systemGroup),
            (ShortcutItem(id: "show-desktop", title: "Show Desktop", gesture: .showDesktop,
                          systemImage: "rectangle.dashed"), systemGroup),
            (ShortcutItem(id: "control-center", title: "Control Center", gesture: .controlCenter,
                          systemImage: "switch.2"), systemGroup),
        ]
        return FunctionTrayProfile(slot: slot, items: items.map {
            FunctionTrayItemConfiguration(item: $0.0, isVisible: true, group: $0.1)
        } + systemItems.map {
            FunctionTrayItemConfiguration(item: $0.0, isVisible: false, group: $0.1)
        })
    }
}

/// Global (not profile-specific) placement of the Function Tray relative
/// to the Main Tray in landscape — see `ControlTrayGeometry.functionTrayLayout`.
enum FunctionTrayPosition: String, Codable, CaseIterable, Identifiable {
    case sameSide
    case oppositeSide

    var id: String { rawValue }
    var title: String { self == .sameSide ? String(localized: "Same Side") : String(localized: "Opposite Side") }
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
        case .topLeading: return String(localized: "Top Left")
        case .topTrailing: return String(localized: "Top Right")
        case .bottomLeading: return String(localized: "Bottom Left")
        case .bottomTrailing: return String(localized: "Bottom Right")
        }
    }

    var side: LandscapeTraySide {
        self == .topLeading || self == .bottomLeading ? .leading : .trailing
    }
}

struct ReceiverControlPreferences: Codable, Equatable {
    static let schemaVersion = 18

    var version = schemaVersion
    var trayEnabled = true
    var keyboardButtonEnabled = true
    var hapticsEnabled = true
    var preferredLandscapeSide = LandscapeTraySide.trailing
    var activeControlProfile = ControlProfileSlot.default
    var trayCollapsed = false
    /// Whether the control trays retreat after a short period of inactivity.
    /// This only enables the *behavior* — the actual moment-to-moment
    /// "is a tray auto-hidden right now" state is transient, tracked by
    /// `ReceiverControlOverlay` itself, and never persisted here, so a
    /// relaunch always starts visible according to `trayCollapsed`/
    /// `trayEnabled` as normal. Independent of `trayCollapsed`, which stays
    /// the user's manual, persisted collapse choice. Defaults on (schema 16:
    /// the Mac display is the canvas, so controls get out of its way); the
    /// iPad Strip layout keeps its reserved rail visible regardless — see
    /// `ControlAutoHidePolicy`.
    var autoHideEnabled = true
    /// Whether THIS session currently has effective input, mirrored from the
    /// Mac's per-session consent decision once connected (see
    /// `ReceiverControlStore.sessionInputState`/`applySessionInputState`,
    /// `StreamReceiver.requestAllowInput`/`onAllowInputStateChange`).
    /// Defaults true only so a brand-new install with no connection yet
    /// never shows a manufactured "denied" state; the Mac's own hello
    /// reply always overwrites it before any input could actually be sent.
    /// Settings/the gear are never gated by this; only remote touch/
    /// pointer/keyboard/gesture output is.
    var allowInput = true
    /// The primary one-finger pointer model — see `PointerInputMode`.
    /// Editable regardless of `allowInput`: choosing a mode never itself
    /// generates remote input.
    var inputMode = PointerInputMode.direct
    /// Linear multiplier on Trackpad's primary one-finger relative delta —
    /// see `PointerGestureConfig.trackpadSensitivityRange`/
    /// `defaultTrackpadSensitivity`. Never affects Direct Touch or any
    /// multi-finger gesture.
    var trackpadSensitivity = PointerGestureConfig.defaultTrackpadSensitivity
    /// Smart Touch (Experimental): lets a one-finger Direct Touch swipe
    /// scroll when the Mac confirms the touched element is scrollable.
    /// No effect in Trackpad mode. Defaults on (schema 16).
    var smartTouchEnabled = true
    /// Smart Touch Haptics: every Smart Touch hold haptic — the long press
    /// that switches a touch into plain Direct Touch, and the title bar
    /// hold's build-up and confirmation. Also silenced whenever
    /// `hapticsEnabled` is off; never changes the gestures themselves.
    /// Defaults on. Keeps its original persisted name so existing choices
    /// carry over.
    var smartTouchLongPressHapticEnabled = true
    var profiles: [ControlProfile]
    /// Independent second tray of immediate-fire shortcut buttons (Undo/
    /// Redo initially) — see `FunctionTrayProfile`. Its own
    /// enabled/profile/position state is entirely separate from the Main
    /// Tray's; only `allowInput` gates both.
    var functionTrayEnabled = true
    var activeFunctionTrayProfile = ControlProfileSlot.default
    var functionTrayPosition = FunctionTrayPosition.sameSide
    var functionTrayProfiles: [FunctionTrayProfile]
    /// Global (never profile-specific) layout preference: whether tray/
    /// control geometry conditionally shifts inward to clear the notch/
    /// Dynamic Island/home-indicator strip when a frame would actually
    /// intersect it — see `ControlTrayGeometry.avoidingUnsafeRegion`. Never
    /// a permanent margin; OFF lets controls sit at the literal screen edge.
    var avoidNotch = true
    /// Purely visual decoration for the mapped interaction surface shown
    /// while video production is off. It never participates in hit-testing.
    var showSurfaceGrid = true
    var pinchTarget = ReceiverGestureTarget.viewport
    /// Defaults to Disabled (schema 16): an accidental twist while pinching
    /// should never tilt the Mac display. Viewport rotation stays one
    /// setting away.
    var rotateTarget = ReceiverGestureTarget.disabled
    var snapRotation = true
    /// Remote scroll direction per axis. On (the default) is natural
    /// scrolling: content follows the fingers. Diagonal scrolls apply both.
    /// Never affects local viewport panning. See `ScrollDirectionPolicy`.
    var invertVerticalScroll = true
    var invertHorizontalScroll = true
    /// Prefer MeowDisplay Gestures: while the receiver surface controls the
    /// Mac, ask iPadOS/iOS to defer its screen-edge gestures and opt the
    /// surface out of UIKit's three-finger editing interactions. Only public
    /// API, so system-owned gestures (VoiceOver, 4/5-finger multitasking)
    /// still win — see `ReceiverSystemGesturePolicy`.
    var preferMeowDisplayGestures = true
    /// App-mode command chords — see App Gesture Commands (spec section D).
    /// Independent of `pinchTarget`/`rotateTarget`: changing a binding never
    /// changes which target is active, and "Reset to Defaults" on this page
    /// touches only this value.
    var appGestureCommands = AppGestureCommands.defaults
    /// The receiver's own "I want Mac system audio" preference — resent as
    /// `audioRequest` on every connection/reconnection so it survives
    /// transport migration and Forget Device re-pairing without the user
    /// re-enabling it. Defaults off: capturing system audio is a deliberate
    /// opt-in, not an ambient default. See `StreamReceiver.requestAudioEnabled`.
    var audioPreferred = false
    /// Receiver-local A/V sync offset in milliseconds, clamped to
    /// `AVSyncOffset.range`. Positive delays audio, negative delays video.
    /// Never sent to the Mac — it only ever affects local playback timing.
    var avSyncOffsetMs = 0
    /// Picture in Picture: while on, leaving the app during a live session
    /// moves the view-only picture into the system floating window, and
    /// Settings offers a manual start. Off means Picture in Picture never
    /// starts. Defaults on.
    var pictureInPictureEnabled = true

    // MARK: iPad-only presentation (never shown or applied on iPhone)

    /// Strip reserves an edge rail and fits the Mac beside it; Overlay floats
    /// controls over a full-screen Mac; Custom uses `activeCustomLayoutID`.
    var padControlLayout = PadControlLayoutMode.strip
    /// Independent edges for the Main controls and the Function controls in
    /// Strip and Overlay — the iPad replacement for `functionTrayPosition`.
    var padMainEdge = ControlEdge.trailing
    var padFunctionEdge = ControlEdge.trailing
    /// Strip only: compact key/action captions beside the controls. Off by
    /// default (schema 17): the rail reads cleaner without labels.
    var padShowControlHints = false
    /// Multiplier on every iPad control, clamped to `PadControlScale.range`.
    var padControlScale = PadControlScale.defaultValue
    /// Which standard system/utility controls the Strip and Overlay rails
    /// show — see `PadRailComposition`. Custom layouts place their own.
    var padStandardControls = PadStandardControlVisibility()
    /// Local View Navigation: pan, zoom, rotate (when Rotation targets the
    /// viewport), Move View and viewport reset — purely receiver-local, so
    /// independent of Allow Input, which only gates what reaches the Mac.
    var allowLocalViewNavigation = true
    /// How Strip/Overlay chord palettes appear: separate keys, or a Wheel.
    var padOverlayPaletteStyle = PadPaletteStyle.keys
    /// At most `CustomControlLayout.maximumCount`; none exist until the user
    /// creates one — see `createCustomLayout`.
    var customLayouts: [CustomControlLayout] = []
    var activeCustomLayoutID: String?

    init(profiles: [ControlProfile] = ControlProfileSlot.allCases.map { ControlProfile.canonical(slot: $0) },
         functionTrayProfiles: [FunctionTrayProfile] = ControlProfileSlot.allCases.map { FunctionTrayProfile.canonical(slot: $0) }) {
        self.profiles = profiles
        self.functionTrayProfiles = functionTrayProfiles
    }

    /// Whether the normal (non-collapsed-to-gear) control tray is allowed to
    /// render at all: `trayEnabled` is the user's stored preference, but it
    /// can never show while `allowInput` is off — PRODUCT RULE: the tray
    /// only ever drives remote input, and the stored preference is
    /// deliberately preserved (not zeroed) so it comes back automatically
    /// once input is re-allowed.
    var trayCanBeShown: Bool { allowInput && trayEnabled }

    /// Same rule as `trayCanBeShown`, independently, for the Function Tray.
    var functionTrayCanBeShown: Bool { allowInput && functionTrayEnabled }

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
        inputMode = try value(.inputMode, fallback.inputMode)
        // Absent (schema < 5) means "written before the sensitivity
        // setting existed" — default to exactly the pre-setting movement
        // speed, never a silently different one.
        trackpadSensitivity = try value(.trackpadSensitivity, fallback.trackpadSensitivity)
        profiles = try value(.profiles, fallback.profiles)
        // Absent (schema < 6) means "written before the Function Tray
        // existed" — default to ON with canonical Undo/Redo profiles,
        // matching a brand-new install, since there is no prior state to
        // preserve for a tray that didn't exist yet.
        functionTrayEnabled = try value(.functionTrayEnabled, fallback.functionTrayEnabled)
        activeFunctionTrayProfile = try value(.activeFunctionTrayProfile, fallback.activeFunctionTrayProfile)
        functionTrayPosition = try value(.functionTrayPosition, fallback.functionTrayPosition)
        functionTrayProfiles = try value(.functionTrayProfiles, fallback.functionTrayProfiles)
        // Absent (schema < 7) means "written before Avoid Notch existed" —
        // default true, matching a brand-new install (and the explicit
        // "old settings migrate to ON" requirement).
        avoidNotch = try value(.avoidNotch, fallback.avoidNotch)
        showSurfaceGrid = try value(.showSurfaceGrid, fallback.showSurfaceGrid)
        pinchTarget = try value(.pinchTarget, fallback.pinchTarget)
        rotateTarget = try value(.rotateTarget, fallback.rotateTarget)
        snapRotation = try value(.snapRotation, fallback.snapRotation)
        // Absent (schema < 11) means "written before App Gesture Commands
        // existed" — default to the canonical Cmd+=/Cmd+-/Cmd+[/Cmd+] chords.
        appGestureCommands = try value(.appGestureCommands, fallback.appGestureCommands)
        // Absent (schema < 12) means "written before Mac system audio
        // existed" — default off/centered, matching a brand-new install.
        audioPreferred = try value(.audioPreferred, fallback.audioPreferred)
        avSyncOffsetMs = AVSyncOffset.clamped(try value(.avSyncOffsetMs, fallback.avSyncOffsetMs))
        // Absent (schema < 13) means "written before Auto-hide existed" —
        // take a brand-new install's value (the schema-16 migration below
        // then settles it).
        autoHideEnabled = try value(.autoHideEnabled, fallback.autoHideEnabled)
        // Absent (schema < 14) means "written before Smart Touch existed" —
        // take a brand-new install's value (the schema-16 migration below
        // then settles it).
        smartTouchEnabled = try value(.smartTouchEnabled, fallback.smartTouchEnabled)
        smartTouchLongPressHapticEnabled = try value(.smartTouchLongPressHapticEnabled,
                                                     fallback.smartTouchLongPressHapticEnabled)
        // Absent (schema < 15) means "written before Picture in Picture
        // existed" — default on, matching a brand-new install.
        pictureInPictureEnabled = try value(.pictureInPictureEnabled, fallback.pictureInPictureEnabled)
        // Absent (schema < 16) means "written before Prefer MeowDisplay
        // Gestures and the iPad layouts existed" — default to a brand-new
        // install's values.
        preferMeowDisplayGestures = try value(.preferMeowDisplayGestures, fallback.preferMeowDisplayGestures)
        padControlLayout = try value(.padControlLayout, fallback.padControlLayout)
        padMainEdge = try value(.padMainEdge, fallback.padMainEdge)
        padFunctionEdge = try value(.padFunctionEdge, fallback.padFunctionEdge)
        padShowControlHints = try value(.padShowControlHints, fallback.padShowControlHints)
        padControlScale = PadControlScale.clamped(try value(.padControlScale, fallback.padControlScale))
        padStandardControls = try value(.padStandardControls, fallback.padStandardControls)
        // Schema 16 stored Move View's visibility on its own.
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        if try legacy.decodeIfPresent(Bool.self, forKey: .padShowMoveViewControl) == false {
            padStandardControls.setVisible(false, .moveView)
        }
        allowLocalViewNavigation = try value(.allowLocalViewNavigation, fallback.allowLocalViewNavigation)
        // Absent (schema < 18): natural scrolling on both axes, as before.
        invertVerticalScroll = try value(.invertVerticalScroll, fallback.invertVerticalScroll)
        invertHorizontalScroll = try value(.invertHorizontalScroll, fallback.invertHorizontalScroll)
        padOverlayPaletteStyle = try value(.padOverlayPaletteStyle, fallback.padOverlayPaletteStyle)
        // Lossy: one layout written by a newer build (an unknown control
        // kind, say) is dropped on its own instead of resetting every
        // preference above.
        customLayouts = Array((try value(.customLayouts, LossyDecodableArray<CustomControlLayout>()))
            .elements.prefix(CustomControlLayout.maximumCount))
        activeCustomLayoutID = try container.decodeIfPresent(String.self, forKey: .activeCustomLayoutID)
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case padShowMoveViewControl
    }

    /// Restores only the four App Gesture Commands to their canonical
    /// defaults — never gesture targets, Snap Rotation, or anything else
    /// (spec section G).
    mutating func resetAppGestureCommands() {
        appGestureCommands = .defaults
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

    func functionTrayProfile(for slot: ControlProfileSlot) -> FunctionTrayProfile {
        (functionTrayProfiles.first(where: { $0.slot == slot }) ?? .canonical(slot: slot))
            .resolvingCanonicalMetadata()
    }

    mutating func updateFunctionTrayProfile(_ profile: FunctionTrayProfile) {
        if let index = functionTrayProfiles.firstIndex(where: { $0.slot == profile.slot }) {
            functionTrayProfiles[index] = profile
        } else {
            functionTrayProfiles.append(profile)
        }
    }

    mutating func resetFunctionTrayProfile(_ slot: ControlProfileSlot) {
        updateFunctionTrayProfile(.canonical(slot: slot))
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
        // Schema 4 predates `trackpadSensitivity`; the custom decoder above
        // already defaulted it to the pre-setting speed — nothing to
        // transform.
        if value.version < 5 {
            value.version = 5
        }
        // Schema 5 predates the Function Tray; the custom decoder above
        // already defaulted it to enabled with canonical Undo/Redo
        // profiles — nothing to transform.
        if value.version < 6 {
            value.version = 6
        }
        // Schema 6 predates Avoid Notch; the custom decoder above already
        // defaulted it to true — nothing to transform.
        if value.version < 7 {
            value.version = 7
        }
        if value.version < 8 {
            // Toggle Dock is a real Main Tray item. Insert it immediately
            // before Keyboard without disturbing any other saved ordering
            // or visibility choice. Existing custom profiles opt in through
            // the editor; the Default profile gains the new visible action.
            for index in value.profiles.indices
                where !value.profiles[index].trayItems.contains(where: { $0.item == .dock }) {
                let keyboardIndex = value.profiles[index].trayItems.firstIndex(where: { $0.item == .keyboard })
                    ?? value.profiles[index].trayItems.endIndex
                value.profiles[index].trayItems.insert(
                    TrayItemConfiguration(item: .dock,
                                          isVisible: value.profiles[index].slot == .default),
                    at: keyboardIndex)
            }
            value.version = 8
        }
        // Schema 8 predates the Video-Off surface grid. The requested default
        // is ON, so the custom decoder has already supplied the right value.
        if value.version < 9 {
            value.version = 9
        }
        // Schema 9 predates gesture targeting and viewport rotation snap.
        // Defaults preserve the old behavior: gestures manipulate the local
        // viewport, with snapping enabled once rotation is introduced.
        if value.version < 10 {
            value.version = 10
        }
        // Schema 10 predates App Gesture Commands; the custom decoder above
        // already defaulted them to the canonical Cmd+=/Cmd+-/Cmd+[/Cmd+]
        // chords — nothing to transform.
        if value.version < 11 {
            value.version = 11
        }
        // Schema 11 predates Mac system audio; the custom decoder above
        // already defaulted `audioPreferred` to off and `avSyncOffsetMs` to
        // 0 — nothing to transform.
        if value.version < 12 {
            value.version = 12
        }
        // Schema 12 predates Auto-hide; the custom decoder above already
        // defaulted `autoHideEnabled` — nothing to transform.
        if value.version < 13 {
            value.version = 13
        }
        // Schema 13 predates Smart Touch; the custom decoder above already
        // defaulted `smartTouchEnabled` — nothing to transform.
        if value.version < 14 {
            value.version = 14
        }
        // Schema 14 predates Picture in Picture; the custom decoder above
        // already defaulted `pictureInPictureEnabled` to on — nothing to
        // transform.
        if value.version < 15 {
            value.version = 15
        }
        // Schema 16 changes four pre-release defaults (Smart Touch on,
        // Auto-hide on, Pinch → Viewport, Rotation → Disabled). MeowDisplay
        // has not shipped, so existing test installs move to them once;
        // anything the user changes afterwards is saved as schema 16 and
        // never touched here again.
        if value.version < 16 {
            let defaults = ReceiverControlPreferences()
            value.smartTouchEnabled = defaults.smartTouchEnabled
            value.autoHideEnabled = defaults.autoHideEnabled
            value.pinchTarget = defaults.pinchTarget
            value.rotateTarget = defaults.rotateTarget
            value.version = 16
        }
        // Schema 17 turns Strip Control Hints off by default. Schema 16 only
        // ever existed on pre-release builds with hints on as its initial
        // value, so those installs take the new default once. Local View
        // Navigation and standard-control visibility are new keys the
        // decoder already defaulted.
        if value.version < 17 {
            value.padShowControlHints = ReceiverControlPreferences().padShowControlHints
            value.version = 17
        }
        // Schema 17 predates per-axis scroll direction and the Wheel palette;
        // the decoder already defaulted them to the unchanged behavior.
        if value.version < 18 {
            value.version = 18
        }
        // Old Function Tray profiles predate `ShortcutItem.systemImage`.
        // Resolve current canonical metadata by ID without rewriting the
        // user's visibility, order, or group choices.
        value.functionTrayProfiles = value.functionTrayProfiles.map {
            $0.resolvingCanonicalMetadata()
        }
        return value
    }

    func save(_ preferences: ReceiverControlPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Mac -> receiver control/UI preference push, carried on `WireMessage.
/// receiverUI`. Every field is optional and additive, exactly like the
/// original `trayEnabled`/`keyboardButtonEnabled` pair — an older receiver
/// simply never receives the newer keys, and a newer receiver applies only
/// whichever keys a given Mac build actually sent. Deliberately excludes
/// Audio/A-V Sync (those are receiver-owned playback preferences the Mac
/// only ever displays, never pushes — see `PhoneInfo`/`sendHello`) and the
/// Main Tray/Function Tray shortcut *editors* (out of scope for this
/// milestone; only their existing on/off + target settings are exposed).
struct ReceiverUIPreferenceUpdate: Equatable {
    var trayEnabled: Bool?
    var keyboardButtonEnabled: Bool?
    var functionTrayEnabled: Bool?
    var inputMode: PointerInputMode?
    var trackpadSensitivity: Double?
    var hapticsEnabled: Bool?
    var avoidNotch: Bool?
    var pinchTarget: ReceiverGestureTarget?
    var rotateTarget: ReceiverGestureTarget?
    var snapRotation: Bool?
    /// App-mode command chords, pushed only from a Mac's per-device
    /// Experimental App Gesture Commands section (shown when Pinch or
    /// Rotate is App) — reuses the exact same `AppGestureCommands` model
    /// the receiver's own editor writes, so this is additive storage, not a
    /// parallel one. Encoded/decoded via the model's own `Codable`
    /// conformance rather than a hand-written field list.
    var appGestureCommands: AppGestureCommands?

    init?(message: [String: Any]) {
        guard message["type"] as? String == WireMessage.receiverUI else { return nil }
        trayEnabled = message["trayEnabled"] as? Bool
        keyboardButtonEnabled = message["keyboardButtonEnabled"] as? Bool
        functionTrayEnabled = message["functionTrayEnabled"] as? Bool
        inputMode = (message["inputMode"] as? String).flatMap(PointerInputMode.init(rawValue:))
        trackpadSensitivity = message["trackpadSensitivity"] as? Double
        hapticsEnabled = message["hapticsEnabled"] as? Bool
        avoidNotch = message["avoidNotch"] as? Bool
        pinchTarget = (message["pinchTarget"] as? String).flatMap(ReceiverGestureTarget.init(rawValue:))
        rotateTarget = (message["rotateTarget"] as? String).flatMap(ReceiverGestureTarget.init(rawValue:))
        snapRotation = message["snapRotation"] as? Bool
        if let raw = message["appGestureCommands"],
           let data = try? JSONSerialization.data(withJSONObject: raw) {
            appGestureCommands = try? JSONDecoder().decode(AppGestureCommands.self, from: data)
        } else {
            appGestureCommands = nil
        }
        guard trayEnabled != nil || keyboardButtonEnabled != nil || functionTrayEnabled != nil
            || inputMode != nil || trackpadSensitivity != nil || hapticsEnabled != nil
            || avoidNotch != nil || pinchTarget != nil || rotateTarget != nil || snapRotation != nil
            || appGestureCommands != nil
        else { return nil }
    }

    func apply(to preferences: inout ReceiverControlPreferences) {
        if let trayEnabled { preferences.trayEnabled = trayEnabled }
        if let keyboardButtonEnabled { preferences.keyboardButtonEnabled = keyboardButtonEnabled }
        if let functionTrayEnabled { preferences.functionTrayEnabled = functionTrayEnabled }
        if let inputMode { preferences.inputMode = inputMode }
        if let trackpadSensitivity {
            let range = PointerGestureConfig.trackpadSensitivityRange
            preferences.trackpadSensitivity = min(max(trackpadSensitivity, range.lowerBound), range.upperBound)
        }
        if let hapticsEnabled { preferences.hapticsEnabled = hapticsEnabled }
        if let avoidNotch { preferences.avoidNotch = avoidNotch }
        if let pinchTarget { preferences.pinchTarget = pinchTarget }
        if let rotateTarget { preferences.rotateTarget = rotateTarget }
        if let snapRotation { preferences.snapRotation = snapRotation }
        if let appGestureCommands { preferences.appGestureCommands = appGestureCommands }
    }
}

/// Strip/Overlay chord palette presentation.
enum PadPaletteStyle: String, Codable, CaseIterable, Identifiable {
    /// Separate keys in a row or column beside the rail.
    case keys
    /// A segmented wheel — see `WheelPaletteGeometry`.
    case wheel

    var id: String { rawValue }
    var title: String {
        self == .keys ? String(localized: "Keys") : String(localized: "Wheel")
    }
}

/// Per-axis remote scroll direction. The gesture pipeline delivers natural
/// deltas (content follows the fingers); turning an axis's inversion off
/// flips that axis alone.
enum ScrollDirectionPolicy {
    static func apply(dx: Double, dy: Double, invertVertical: Bool, invertHorizontal: Bool) -> (dx: Double, dy: Double) {
        (invertHorizontal ? dx : -dx, invertVertical ? dy : -dy)
    }
}

/// Software-keyboard typing while a MeowDisplay modifier chord is active:
/// the typed key is sent as that chord (⌘ latched, then C → ⌘C) instead of
/// as text. The chord state stays the overlay's `ControlInteractionState`.
enum SoftwareKeyboardChordPolicy {
    /// The key press for one typed character under `modifiers`, or `nil`
    /// when no chord is active or the character has no key.
    static func press(for text: String, modifiers: Set<ControlModifier>) -> (usage: Int, modifiers: [String])? {
        guard !modifiers.isEmpty, text.count == 1, let character = text.first else { return nil }
        var chord = modifiers
        let usage: Int?
        if character == " " {
            usage = 44
        } else if character == "\n" {
            usage = 40
        } else if character.isLetter, character.isASCII, let scalar = character.lowercased().unicodeScalars.first {
            if character.isUppercase { chord.insert(.shift) }
            usage = Int(scalar.value) - 97 + 4
        } else {
            usage = appGestureCommandEditableKeys.first { $0.0 == String(character) }?.1
        }
        guard let usage else { return nil }
        return (usage, ControlModifier.allCases.filter(chord.contains).map(\.rawValue))
    }

    /// Modifier names for a special or hardware key: its own plus the chord.
    static func modifiers(_ own: [String], chord: Set<ControlModifier>) -> [String] {
        let combined = Set(own).union(chord.map(\.rawValue))
        return ControlModifier.allCases.map(\.rawValue).filter(combined.contains)
    }
}
