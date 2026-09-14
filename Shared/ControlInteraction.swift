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
}

enum ControlHapticPolicy {
    static func shouldPlay(_ event: ControlHapticEvent, enabled: Bool) -> Bool {
        _ = event
        return enabled
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
