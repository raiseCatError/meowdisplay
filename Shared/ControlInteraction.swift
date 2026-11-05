import CoreGraphics
import Foundation

enum ControlInteractionPhase: Equatable {
    case idle
    case pressed(ControlModifier)
    case latched(ModifierChord)
    case palette(active: ModifierChord, selectedActionID: String?)
    case executing
    case cancelled
}

enum ControlInteractionEffect: Equatable {
    case modifierDown(ControlModifier)
    case modifierUp(ControlModifier)
    case execute(ShortcutItem)
    case haptic(ControlHapticEvent)
}

enum ControlHapticEvent: String, Equatable {
    case selection
    case latch
    case confirmation
    case expandCollapse
    case profileChange
    case reset
    case settings
    /// A touch and hold on Settings opened Session Actions.
    case sessionActions
}

enum ControlHapticPolicy {
    static func shouldPlay(_ event: ControlHapticEvent, enabled: Bool) -> Bool {
        _ = event
        return enabled
    }
}

/// Smart Touch hold haptics (the Direct Touch override and the title bar
/// build-up and confirmation) play only while both the global Haptics
/// setting and Smart Touch Haptics are on. Either switch only silences
/// feedback — the gestures themselves never change.
enum SmartTouchHapticPolicy {
    static func isEnabled(haptics: Bool, smartTouchHaptics: Bool) -> Bool {
        haptics && smartTouchHaptics
    }
}

/// How long a modifier (⌘ ⌥ ⌃ ⇧) is touched before its shortcut palette
/// opens (#131). Only this hold: Stage Peek, Window view and Natural Touch
/// keep their own timings, which mean different things. A lift before it is
/// a tap and latches the modifier, so a shorter hold leaves less time for a
/// slow tap.
enum ModifierHoldResponse: String, Codable, CaseIterable, Identifiable {
    case fast
    case standard
    case deliberate

    var id: String { rawValue }

    /// Seconds. Standard was 0.35 before #131.
    var delay: TimeInterval {
        switch self {
        case .fast: return 0.18
        case .standard: return 0.25
        case .deliberate: return 0.4
        }
    }

    var title: String {
        switch self {
        case .fast: return String(localized: "Fast")
        case .standard: return String(localized: "Standard")
        case .deliberate: return String(localized: "Deliberate")
        }
    }
}

/// When a press on a modifier stops waiting for the hold.
enum ModifierPressPolicy {
    /// A finger that slides this far from where it touched down is reaching
    /// for the palette: open it now rather than wait out the hold, and never
    /// treat the lift as a latching tap.
    static let slideDistance: CGFloat = 10

    static func slideOpensPalette(translation: CGSize) -> Bool {
        (translation.width * translation.width + translation.height * translation.height).squareRoot() > slideDistance
    }
}

/// Pure state machine for tap-to-latch and hold/slide shortcut chords.
struct ControlInteractionState: Equatable {
    private(set) var phase: ControlInteractionPhase = .idle
    private(set) var latchedModifiers: Set<ControlModifier> = []
    private(set) var temporaryModifiers: Set<ControlModifier> = []
    private(set) var selectedActionID: String?

    var activeChord: ModifierChord {
        ModifierChord(latchedModifiers.union(temporaryModifiers))
    }

    /// The palette is persistent for a latched chord and transient for a
    /// hold/slide chord. Keeping this derived from state (rather than a view
    /// timer) prevents a harmless finger-up from dismissing a latched menu.
    var paletteChord: ModifierChord? {
        switch phase {
        case .latched(let chord): return chord
        case .pressed where !latchedModifiers.isEmpty: return ModifierChord(latchedModifiers)
        case .palette(let chord, _): return chord
        default: return nil
        }
    }

    mutating func press(_ modifier: ControlModifier) {
        phase = .pressed(modifier)
    }

    mutating func tap(_ modifier: ControlModifier) -> [ControlInteractionEffect] {
        temporaryModifiers.removeAll()
        selectedActionID = nil
        let effect: ControlInteractionEffect
        if latchedModifiers.remove(modifier) != nil {
            effect = .modifierUp(modifier)
        } else {
            latchedModifiers.insert(modifier)
            effect = .modifierDown(modifier)
        }
        phase = latchedModifiers.isEmpty ? .idle : .latched(ModifierChord(latchedModifiers))
        return [effect, .haptic(.latch)]
    }

    mutating func beginPalette(with modifier: ControlModifier) -> [ControlInteractionEffect] {
        selectedActionID = nil
        var effects: [ControlInteractionEffect] = []
        if !latchedModifiers.contains(modifier) {
            temporaryModifiers.insert(modifier)
            effects.append(.modifierDown(modifier))
        }
        phase = .palette(active: activeChord, selectedActionID: nil)
        effects.append(.haptic(.selection))
        return effects
    }

    /// A key from elsewhere (an on-screen arrow) while a modifier is still in
    /// its first moments of being pressed: nothing is down on the Mac yet, so
    /// hold it now, exactly as a long press would, rather than send the key
    /// unmodified and latch the modifier on lift. A no-op otherwise.
    mutating func promotePressedModifier() -> [ControlInteractionEffect] {
        guard case .pressed(let modifier) = phase else { return [] }
        return beginPalette(with: modifier)
    }

    mutating func updateTemporaryChord(_ touched: Set<ControlModifier>) -> [ControlInteractionEffect] {
        let desired = touched.subtracting(latchedModifiers)
        var effects = ordered(temporaryModifiers.subtracting(desired)).map(ControlInteractionEffect.modifierUp)
        effects += ordered(desired.subtracting(temporaryModifiers)).map(ControlInteractionEffect.modifierDown)
        if desired != temporaryModifiers { effects.append(.haptic(.selection)) }
        temporaryModifiers = desired
        phase = .palette(active: activeChord, selectedActionID: selectedActionID)
        return effects
    }

    /// Adds a modifier crossed by the same continuous hold gesture. This is
    /// intentionally idempotent so stationary drag samples cannot build up
    /// haptics or duplicate modifier-down messages.
    mutating func addTemporaryModifier(_ modifier: ControlModifier) -> [ControlInteractionEffect] {
        guard !latchedModifiers.contains(modifier), !temporaryModifiers.contains(modifier) else {
            return []
        }
        temporaryModifiers.insert(modifier)
        phase = .palette(active: activeChord, selectedActionID: selectedActionID)
        return [.modifierDown(modifier), .haptic(.selection)]
    }

    mutating func selectAction(_ id: String?) -> [ControlInteractionEffect] {
        guard id != selectedActionID else { return [] }
        selectedActionID = id
        phase = .palette(active: activeChord, selectedActionID: id)
        return [.haptic(.selection)]
    }

    mutating func finish(with action: ShortcutItem?) -> [ControlInteractionEffect] {
        var effects: [ControlInteractionEffect] = []
        if let action {
            phase = .executing
            effects.append(.execute(action))
            effects.append(.haptic(.confirmation))
        }
        effects += ordered(temporaryModifiers).map(ControlInteractionEffect.modifierUp)
        temporaryModifiers.removeAll()
        selectedActionID = nil
        phase = latchedModifiers.isEmpty ? .idle : .latched(ModifierChord(latchedModifiers))
        return effects
    }

    /// The system took the touch (Control Center, a notification, an
    /// alert): a press that never became a hold or tap leaves nothing
    /// latched, and a hold lets go of what it held. Never executes.
    mutating func cancelPress() -> [ControlInteractionEffect] {
        if case .pressed = phase {
            selectedActionID = nil
            phase = latchedModifiers.isEmpty ? .idle : .latched(ModifierChord(latchedModifiers))
            return []
        }
        return cancelTemporary()
    }

    mutating func cancelTemporary() -> [ControlInteractionEffect] {
        let effects = ordered(temporaryModifiers).map(ControlInteractionEffect.modifierUp)
        temporaryModifiers.removeAll()
        selectedActionID = nil
        phase = latchedModifiers.isEmpty ? .idle : .latched(ModifierChord(latchedModifiers))
        return effects
    }

    mutating func resetAll() -> [ControlInteractionEffect] {
        let held = latchedModifiers.union(temporaryModifiers)
        latchedModifiers.removeAll()
        temporaryModifiers.removeAll()
        selectedActionID = nil
        phase = .cancelled
        let effects = ordered(held).map(ControlInteractionEffect.modifierUp)
        phase = .idle
        return effects
    }

    private func ordered(_ modifiers: Set<ControlModifier>) -> [ControlModifier] {
        ControlModifier.allCases.filter(modifiers.contains)
    }
}
