import CoreGraphics
import Foundation

// On-screen arrow keys (#179). Pure decisions only, so they're unit-tested on
// macOS; the receiver controls draw the button and keypad and send through
// the existing keyboard path.

/// One arrow key, as the HID usage the existing keyboard path sends.
enum ArrowKeyDirection: String, CaseIterable, Identifiable, Sendable {
    case up, left, down, right

    var id: String { rawValue }

    /// HID keyboard usages (Keyboard/Keypad page): Right 79, Left 80, Down 81, Up 82.
    var usage: Int {
        switch self {
        case .right: return 79
        case .left: return 80
        case .down: return 81
        case .up: return 82
        }
    }

    var symbol: String {
        switch self {
        case .up: return "arrow.up"
        case .left: return "arrow.left"
        case .down: return "arrow.down"
        case .right: return "arrow.right"
        }
    }

    /// What VoiceOver reads and Voice Control answers to.
    var title: String {
        switch self {
        case .up: return String(localized: "Up Arrow")
        case .left: return String(localized: "Left Arrow")
        case .down: return String(localized: "Down Arrow")
        case .right: return String(localized: "Right Arrow")
        }
    }
}

/// When the arrow button is offered: the user hasn't turned it off, input
/// reaches the Mac, and the Mac understands keyboard messages. Same gates
/// as the keyboard button; the Mac enforces the grant again on its side.
enum ArrowKeysAvailability {
    static func isShown(enabled: Bool, allowInput: Bool, keyboardAvailable: Bool) -> Bool {
        enabled && allowInput && keyboardAvailable
    }
}

/// What a touch on the compact arrow button meant, decided on release.
///
/// A tap opens or closes the keypad. A deliberate swipe sends one arrow press
/// and leaves the keypad alone. Anything in between (a small wobble past tap
/// range, a diagonal, a cancelled touch) sends nothing, because remote input
/// must never come from a guess.
enum ArrowButtonGesture {
    /// Movement still counted as a tap (a finger wobbles a little).
    static let tapSlop: CGFloat = 10
    /// Movement that makes a swipe.
    static let swipeDistance: CGFloat = 24
    /// The main axis must beat the other by this much; diagonals send nothing.
    static let dominance: CGFloat = 1.6

    enum Outcome: Equatable {
        case toggleKeypad
        case press(ArrowKeyDirection)
        case nothing
    }

    static func outcome(translation: CGSize, cancelled: Bool) -> Outcome {
        guard !cancelled else { return .nothing }
        let distance = (translation.width * translation.width + translation.height * translation.height).squareRoot()
        if distance <= tapSlop { return .toggleKeypad }
        return direction(of: translation).map(Outcome.press) ?? .nothing
    }

    /// The direction a release here would send, for the live preview while
    /// dragging; nil while it would send nothing.
    static func direction(of translation: CGSize) -> ArrowKeyDirection? {
        let dx = translation.width, dy = translation.height
        let horizontal = abs(dx), vertical = abs(dy)
        if horizontal >= swipeDistance, horizontal >= vertical * dominance {
            return dx > 0 ? .right : .left
        }
        if vertical >= swipeDistance, vertical >= horizontal * dominance {
            return dy > 0 ? .down : .up   // screen coordinates: +y is down
        }
        return nil
    }
}

/// One message for the Mac's existing keyboard path. `modifiers` are the
/// keypad's own (`ArrowKeypadModifiers`), fixed when the key went down.
enum ArrowKeyEvent: Equatable {
    /// Key down (`action: "down"`).
    case down(ArrowKeyDirection, modifiers: Set<ControlModifier> = [])
    /// A repeat of the key still held (`action: "down"`, `repeat: true`). The
    /// Mac posts it as an autorepeat key-down only while the key is held, so
    /// a late repeat after `up` or a cancel can never become a new press.
    case `repeat`(ArrowKeyDirection, modifiers: Set<ControlModifier> = [])
    /// Key up (`action: "up"`).
    case up(ArrowKeyDirection, modifiers: Set<ControlModifier> = [])
}

/// A finger on the keypad, as the keyboard messages it means.
///
/// Touching a key sends its key down; holding it sends repeats like a
/// physical key, after an initial delay and at a bounded rate; lifting,
/// sliding off or any reset sends exactly one key up. The receiver times the
/// repeats because the Mac never repeats a key on its own. A tick that comes
/// late sends one repeat, never a burst of owed ones, so a stalled app can't
/// queue a backlog on the Mac.
struct ArrowKeyHold: Equatable {
    /// Close to macOS's default "Delay until repeat".
    static let initialDelay: TimeInterval = 0.4
    /// 12.5 repeats a second: quick through text, and slow enough that a
    /// busy Wi-Fi link never builds a queue.
    static let interval: TimeInterval = 0.08

    private(set) var held: ArrowKeyDirection?
    /// When the next repeat is due; nil while nothing is held.
    private(set) var nextRepeatAt: TimeInterval?
    /// The modifiers the held key went down with. Its repeats and its up
    /// carry exactly these, so toggling a keypad modifier mid-hold can't
    /// change a key that is already down.
    private(set) var heldModifiers: Set<ControlModifier> = []

    var isHolding: Bool { held != nil }

    /// The finger is now on `direction`, or on no key (nil). Moving to
    /// another key releases the first (with its own modifiers), then presses
    /// the new one with `modifiers`.
    mutating func move(to direction: ArrowKeyDirection?, now: TimeInterval,
                       modifiers: Set<ControlModifier> = []) -> [ArrowKeyEvent] {
        guard direction != held else { return [] }
        var events: [ArrowKeyEvent] = []
        if let held { events.append(.up(held, modifiers: heldModifiers)) }
        held = direction
        if let direction {
            heldModifiers = modifiers
            events.append(.down(direction, modifiers: modifiers))
            nextRepeatAt = now + Self.initialDelay
        } else {
            heldModifiers = []
            nextRepeatAt = nil
        }
        return events
    }

    /// A timer tick: one repeat when it's due, else nil. Never more than one
    /// per tick.
    mutating func tick(now: TimeInterval) -> ArrowKeyEvent? {
        guard let held, let due = nextRepeatAt, now >= due else { return nil }
        var next = due + Self.interval
        if next <= now { next = now + Self.interval }   // came late: no catching up
        nextRepeatAt = next
        return .repeat(held, modifiers: heldModifiers)
    }

    /// Lift, cancel or reset: the key up for a held key, or nil. Safe to call
    /// any number of times.
    mutating func release() -> ArrowKeyEvent? {
        move(to: nil, now: 0).first
    }
}

/// The arrow keypad's own Shift, Option and Command, kept apart from the
/// tray's chord: keypad arrows carry only these, and the tray's latch keeps
/// working for every other control exactly as before. Pure state, never sent
/// as `modifierDown`, so nothing it does can stay held on the Mac; each arrow
/// names them in its own key messages, marked `exactModifiers`.
///
/// Touching a modifier applies it at once. Lifting it toggles its latch,
/// unless an arrow went down while it was touched: then it was a hold, and
/// it ends with the finger. A latch lasts until it is tapped again or the
/// keypad closes (`clear`).
struct ArrowKeypadModifiers: Equatable {
    /// Top to bottom in a column, left to right in a row.
    static let keys: [ControlModifier] = [.shift, .option, .command]

    private(set) var latched: Set<ControlModifier> = []
    /// Modifiers a finger is on, each with whether an arrow went down since.
    private(set) var touched: [ControlModifier: Bool] = [:]

    /// What an arrow going down now carries (while `isAvailable`).
    var active: Set<ControlModifier> { latched.union(touched.keys) }

    var isEmpty: Bool { latched.isEmpty && touched.isEmpty }

    /// A Mac that takes exact modifiers keeps the two sets apart. An older
    /// Mac adds whatever the tray holds down to every key, so there the
    /// keypad's modifiers work only while the tray holds none; otherwise an
    /// arrow would carry both.
    static func isAvailable(macSupportsExactModifiers: Bool, trayChord: Set<ControlModifier>) -> Bool {
        macSupportsExactModifiers || trayChord.isEmpty
    }

    /// A finger touched `modifier`: on until it lifts.
    mutating func touchDown(_ modifier: ControlModifier) {
        guard Self.keys.contains(modifier), touched[modifier] == nil else { return }
        touched[modifier] = false
    }

    /// The finger lifted on `modifier`: a tap toggles its latch, a hold that
    /// carried an arrow just ends. Returns whether the latch changed.
    @discardableResult
    mutating func lift(_ modifier: ControlModifier) -> Bool {
        guard let carriedAnArrow = touched.removeValue(forKey: modifier) else { return false }
        guard !carriedAnArrow else { return false }
        return toggle(modifier)
    }

    /// The system took the touch, or the finger slid off: nothing toggles.
    mutating func cancelTouch(_ modifier: ControlModifier) {
        touched[modifier] = nil
    }

    /// A tap from VoiceOver, Voice Control or Switch Control: toggles the latch.
    @discardableResult
    mutating func toggle(_ modifier: ControlModifier) -> Bool {
        guard Self.keys.contains(modifier) else { return false }
        if latched.remove(modifier) == nil { latched.insert(modifier) }
        return true
    }

    /// An arrow goes down now: the modifiers it carries (none while the
    /// keypad's modifiers are unavailable), and every touched modifier
    /// becomes a hold that ends with its finger.
    mutating func keyDown(available: Bool) -> Set<ControlModifier> {
        let modifiers = available ? active : []
        for modifier in touched.keys { touched[modifier] = true }
        return modifiers
    }

    /// The keypad closed, or input was reset: nothing latched, nothing touched.
    mutating func clear() {
        latched.removeAll()
        touched.removeAll()
    }

    /// Unavailable now (an older Mac and a tray modifier on): everything is
    /// dropped rather than kept hidden, so nothing comes back unannounced
    /// when the tray's modifier goes. Returns whether anything was dropped.
    @discardableResult
    mutating func reconcile(available: Bool) -> Bool {
        guard !available, !isEmpty else { return false }
        clear()
        return true
    }

    /// Wire names, in the protocol's usual order.
    static func wireNames(_ modifiers: Set<ControlModifier>) -> [String] {
        ControlModifier.allCases.filter(modifiers.contains).map(\.rawValue)
    }
}

/// The inverted-T keypad: ↑ above ← ↓ →.
enum ArrowKeypadGeometry {
    static func size(key: CGFloat, gap: CGFloat) -> CGSize {
        CGSize(width: key * 3 + gap * 2, height: key * 2 + gap)
    }

    /// Each key's drawn frame inside a keypad of `size(key:gap:)` at `origin`.
    static func keyFrames(origin: CGPoint = .zero, key: CGFloat, gap: CGFloat) -> [ArrowKeyDirection: CGRect] {
        let step = key + gap
        func frame(column: Int, row: Int) -> CGRect {
            CGRect(x: origin.x + CGFloat(column) * step, y: origin.y + CGFloat(row) * step, width: key, height: key)
        }
        return [.up: frame(column: 1, row: 0), .left: frame(column: 0, row: 1),
                .down: frame(column: 1, row: 1), .right: frame(column: 2, row: 1)]
    }

    /// The key under `point` (keypad coordinates). Each key owns half the
    /// gap around it, so sliding between keys never drops out; the two
    /// empty top corners and anything outside the T are no key.
    static func direction(at point: CGPoint, key: CGFloat, gap: CGFloat) -> ArrowKeyDirection? {
        let half = gap / 2
        let frames = keyFrames(key: key, gap: gap)
        return ArrowKeyDirection.allCases.first { direction in
            frames[direction]!.insetBy(dx: -half, dy: -half).contains(point)
        }
    }
}

/// Where the keypad's own ⇧ ⌥ ⌘ sit against the T.
enum ArrowKeypadModifierPlacement: Equatable, CaseIterable {
    /// A column left of the T.
    case leading
    /// A column right of the T.
    case trailing
    /// A row under the T, between it and the button.
    case below

    var isColumn: Bool { self != .below }
}

extension ArrowKeypadGeometry {
    /// One modifier key: as wide as an arrow key and two thirds as tall, so
    /// three stack exactly the T's height and three in a row span its width.
    static func modifierKeySize(key: CGFloat) -> CGSize {
        CGSize(width: key, height: (key * 2 / 3).rounded(.down))
    }

    /// The strip of three modifier keys.
    static func modifierStripSize(_ placement: ArrowKeypadModifierPlacement, key: CGFloat, gap: CGFloat) -> CGSize {
        let keypad = size(key: key, gap: gap)
        return placement.isColumn ? CGSize(width: key, height: keypad.height)
                                  : CGSize(width: keypad.width, height: modifierKeySize(key: key).height)
    }

    /// The T and its strip as one block, `gap` apart: what the placement code
    /// moves around the other controls.
    static func blockSize(_ placement: ArrowKeypadModifierPlacement, key: CGFloat, gap: CGFloat) -> CGSize {
        let keypad = size(key: key, gap: gap)
        let strip = modifierStripSize(placement, key: key, gap: gap)
        return placement.isColumn ? CGSize(width: keypad.width + gap + strip.width, height: keypad.height)
                                  : CGSize(width: keypad.width, height: keypad.height + gap + strip.height)
    }

    /// A placed block, split into the T and the strip.
    static func split(_ block: CGRect, placement: ArrowKeypadModifierPlacement,
                      key: CGFloat, gap: CGFloat) -> (keypad: CGRect, modifiers: CGRect) {
        let keypad = size(key: key, gap: gap)
        let strip = modifierStripSize(placement, key: key, gap: gap)
        switch placement {
        case .leading:
            return (CGRect(x: block.maxX - keypad.width, y: block.minY, width: keypad.width, height: keypad.height),
                    CGRect(x: block.minX, y: block.minY, width: strip.width, height: strip.height))
        case .trailing:
            return (CGRect(x: block.minX, y: block.minY, width: keypad.width, height: keypad.height),
                    CGRect(x: block.maxX - strip.width, y: block.minY, width: strip.width, height: strip.height))
        case .below:
            return (CGRect(x: block.minX, y: block.minY, width: keypad.width, height: keypad.height),
                    CGRect(x: block.minX, y: block.maxY - strip.height, width: strip.width, height: strip.height))
        }
    }

    /// The space between two modifier keys: the arrow keys' gap in a row;
    /// in a column, whatever is left once three keys stack the T's height.
    static func modifierGap(_ placement: ArrowKeypadModifierPlacement, key: CGFloat, gap: CGFloat) -> CGFloat {
        guard placement.isColumn else { return gap }
        return max(0, (size(key: key, gap: gap).height - 3 * modifierKeySize(key: key).height) / 2)
    }

    /// Each modifier key's frame inside a strip drawn at `strip`.
    static func modifierKeyFrames(in strip: CGRect, placement: ArrowKeypadModifierPlacement,
                                  key: CGFloat, gap: CGFloat) -> [ControlModifier: CGRect] {
        let keySize = modifierKeySize(key: key)
        let between = modifierGap(placement, key: key, gap: gap)
        var frames: [ControlModifier: CGRect] = [:]
        for (index, modifier) in ArrowKeypadModifiers.keys.enumerated() {
            let step = CGFloat(index)
            frames[modifier] = placement.isColumn
                ? CGRect(x: strip.minX, y: strip.minY + step * (keySize.height + between),
                         width: keySize.width, height: keySize.height)
                : CGRect(x: strip.minX + step * (keySize.width + between), y: strip.minY,
                         width: keySize.width, height: keySize.height)
        }
        return frames
    }
}

/// Where the compact arrow button and its keypad sit.
struct ArrowKeysLayout: Equatable {
    var toggle: CGRect
    /// The T; nil while the keypad is closed.
    var keypad: CGRect?
    /// The keypad's own ⇧ ⌥ ⌘ beside or under the T; nil while it is closed.
    var modifiers: CGRect? = nil
    var modifierPlacement: ArrowKeypadModifierPlacement? = nil

    var occupied: [CGRect] { [toggle] + [keypad, modifiers].compactMap { $0 } }
}

extension ControlTrayGeometry {
    /// The arrow button sits in the bottom corner on `side` (landscape) or
    /// at the `side` end just above the Main Tray (portrait), stepping
    /// inward past whatever already holds that spot: the Function Tray's
    /// bottom row (so it lands beside Return when they share a side), the
    /// Main Tray column, or an open shortcut palette. The keypad opens above
    /// it and moves to clear the other controls; the button itself never
    /// moves when the keypad opens or closes.
    ///
    /// - Parameters:
    ///   - mainTrayFrame: the Main Tray as drawn.
    ///   - obstacles: every other control frame (Main Tray, Function Tray
    ///     groups, the palette).
    static func arrowKeysLayout(container: CGRect, safeInsets: ControlSafeInsets, portrait: Bool,
                                side: LandscapeTraySide, toggleSize: CGSize, keypadSize: CGSize?,
                                mainTrayFrame: CGRect, obstacles: [CGRect],
                                avoidNotch: Bool, notchSide: LandscapeTraySide? = nil,
                                reservedRegions: [ControlReservedRegion] = [],
                                spacing: CGFloat = 10) -> ArrowKeysLayout {
        let margin: CGFloat = 12
        let visible = container
        let bounds = visible.insetBy(dx: margin, dy: margin)
        let obstacles = obstacles.filter { !$0.isNull && !$0.isEmpty }
        let trailing = side == .trailing
        // Closer than `spacing` to another control (a hair of tolerance so a
        // frame placed exactly `spacing` away doesn't count).
        func hit(_ frame: CGRect, in list: [CGRect]) -> CGRect? {
            let reach = spacing - 0.5
            return list.first { $0.insetBy(dx: -reach, dy: -reach).intersects(frame) }
        }

        var toggle: CGRect
        if portrait {
            let top = min(mainTrayFrame.isEmpty ? bounds.maxY : mainTrayFrame.minY - spacing, bounds.maxY)
            toggle = CGRect(x: trailing ? bounds.maxX - toggleSize.width : bounds.minX,
                            y: top - toggleSize.height, width: toggleSize.width, height: toggleSize.height)
            // Above anything already at that end of the row.
            for _ in 0...obstacles.count {
                guard let obstacle = hit(toggle, in: obstacles) else { break }
                toggle.origin.y = obstacle.minY - spacing - toggle.height
            }
        } else {
            toggle = CGRect(x: trailing ? bounds.maxX - toggleSize.width : bounds.minX,
                            y: bounds.maxY - toggleSize.height, width: toggleSize.width, height: toggleSize.height)
            // Inward along the bottom edge, past whatever holds the corner.
            for _ in 0...obstacles.count {
                guard let obstacle = hit(toggle, in: obstacles) else { break }
                toggle.origin.x = trailing ? obstacle.minX - spacing - toggle.width : obstacle.maxX + spacing
            }
        }
        toggle.origin.x = clampValue(toggle.origin.x, bounds.minX, bounds.maxX - toggle.width)
        toggle.origin.y = clampValue(toggle.origin.y, bounds.minY, bounds.maxY - toggle.height)
        toggle = avoidingUnsafeRegion(toggle, in: container, safeInsets: safeInsets, enabled: avoidNotch,
                                      portrait: portrait, notchSide: notchSide)
        let reserved = reservedObstacles(reservedRegions, avoidNotch: avoidNotch)
        toggle = avoidingReservedRegions(toggle, obstacles: reserved, within: bounds, alsoAvoiding: obstacles)

        guard let keypadSize else { return ArrowKeysLayout(toggle: toggle, keypad: nil) }
        // Centred over the button, then pushed inward (landscape) or up
        // (portrait) until it clears the other controls.
        var keypad = CGRect(x: toggle.midX - keypadSize.width / 2, y: toggle.minY - spacing - keypadSize.height,
                            width: keypadSize.width, height: keypadSize.height)
        keypad.origin.x = clampValue(keypad.origin.x, bounds.minX, bounds.maxX - keypad.width)
        for _ in 0...obstacles.count {
            guard let obstacle = hit(keypad, in: obstacles) else { break }
            if portrait {
                keypad.origin.y = obstacle.minY - spacing - keypad.height
            } else {
                keypad.origin.x = trailing ? obstacle.minX - spacing - keypad.width : obstacle.maxX + spacing
            }
        }
        keypad.origin.x = clampValue(keypad.origin.x, bounds.minX, bounds.maxX - keypad.width)
        keypad.origin.y = clampValue(keypad.origin.y, bounds.minY, bounds.maxY - keypad.height)
        keypad = avoidingUnsafeRegion(keypad, in: container, safeInsets: safeInsets, enabled: avoidNotch,
                                      portrait: portrait, notchSide: notchSide)
        keypad = avoidingReservedRegions(keypad, obstacles: reserved, within: bounds,
                                         alsoAvoiding: obstacles + [toggle])
        return ArrowKeysLayout(toggle: toggle, keypad: keypad)
    }
}

extension ControlTrayGeometry {
    /// Where the keypad's modifier strip is tried, best first: a column on
    /// the side with room (toward the middle of the screen from the button,
    /// so the T stays over the button when the button is near an edge), a
    /// column on the other side, then a row under the T.
    static func arrowKeypadModifierPlacements(toggle: CGRect, container: CGRect) -> [ArrowKeypadModifierPlacement] {
        let towardMiddle: ArrowKeypadModifierPlacement = toggle.midX > container.midX ? .leading : .trailing
        return [towardMiddle, towardMiddle == .leading ? .trailing : .leading, .below]
    }

    /// `arrowKeysLayout` for the keypad with its ⇧ ⌥ ⌘ strip: the T and the
    /// strip are placed as one block by the same obstacle-avoiding code, so
    /// the strip clears everything the T clears. The first placement (see
    /// `arrowKeypadModifierPlacements`) whose block lands clear of the other
    /// controls, the button, reserved regions and (with Avoid Notch) the
    /// unsafe edges wins; with no clear one, the first. The button never
    /// moves for the keypad.
    ///
    /// - Parameters: as `arrowKeysLayout`, with the keypad's `key` and `gap`
    ///   instead of its size; `keypadOpen` false lays out the button alone.
    static func arrowKeysLayoutWithModifiers(container: CGRect, safeInsets: ControlSafeInsets, portrait: Bool,
                                             side: LandscapeTraySide, toggleSize: CGSize,
                                             keypadOpen: Bool, key: CGFloat, gap: CGFloat,
                                             mainTrayFrame: CGRect, obstacles: [CGRect],
                                             avoidNotch: Bool, notchSide: LandscapeTraySide? = nil,
                                             reservedRegions: [ControlReservedRegion] = [],
                                             spacing: CGFloat = 10) -> ArrowKeysLayout {
        func place(_ keypadSize: CGSize?) -> ArrowKeysLayout {
            arrowKeysLayout(container: container, safeInsets: safeInsets, portrait: portrait, side: side,
                            toggleSize: toggleSize, keypadSize: keypadSize, mainTrayFrame: mainTrayFrame,
                            obstacles: obstacles, avoidNotch: avoidNotch, notchSide: notchSide,
                            reservedRegions: reservedRegions, spacing: spacing)
        }
        let closed = place(nil)
        guard keypadOpen else { return closed }
        let bounds = container.insetBy(dx: 12, dy: 12)
        let blocked = obstacles.filter { !$0.isNull && !$0.isEmpty }
            + reservedObstacles(reservedRegions, avoidNotch: avoidNotch)
            + (avoidNotch ? unsafeRegions(in: container, safeInsets: safeInsets, portrait: portrait,
                                          notchSide: notchSide) : [])
        var fallback: ArrowKeysLayout?
        for placement in arrowKeypadModifierPlacements(toggle: closed.toggle, container: container) {
            let placed = place(ArrowKeypadGeometry.blockSize(placement, key: key, gap: gap))
            guard let block = placed.keypad else { continue }
            let parts = ArrowKeypadGeometry.split(block, placement: placement, key: key, gap: gap)
            let layout = ArrowKeysLayout(toggle: placed.toggle, keypad: parts.keypad,
                                         modifiers: parts.modifiers, modifierPlacement: placement)
            if fallback == nil { fallback = layout }
            if bounds.contains(block), !block.intersects(placed.toggle),
               !blocked.contains(where: { $0.intersects(block) }) {
                return layout
            }
        }
        return fallback ?? closed
    }

    /// `keyboardBarKeypadFrame` for the keypad with its ⇧ ⌥ ⌘ strip, placed
    /// as one block: the first placement that fits inside the safe area
    /// clear of the bar and an open palette wins (in iPhone landscape that
    /// is usually the row, beside the bar); with none, the first. Never
    /// lower than the bar, so never over the keyboard. `toggle` is `item`.
    static func keyboardBarArrowKeysLayout(safe: CGRect, bar: CGRect, item: CGRect, key: CGFloat, gap: CGFloat,
                                           palette: CGRect?, spacing: CGFloat = 10) -> ArrowKeysLayout {
        let bounds = safe.insetBy(dx: 12, dy: 12)
        var fallback: ArrowKeysLayout?
        for placement in arrowKeypadModifierPlacements(toggle: item, container: safe) {
            let block = keyboardBarKeypadFrame(safe: safe, bar: bar, item: item,
                                               keypadSize: ArrowKeypadGeometry.blockSize(placement, key: key, gap: gap),
                                               palette: palette, spacing: spacing)
            let parts = ArrowKeypadGeometry.split(block, placement: placement, key: key, gap: gap)
            let layout = ArrowKeysLayout(toggle: item, keypad: parts.keypad,
                                         modifiers: parts.modifiers, modifierPlacement: placement)
            if fallback == nil { fallback = layout }
            if bounds.contains(block), !block.intersects(bar), !(palette?.intersects(block) ?? false) {
                return layout
            }
        }
        return fallback ?? ArrowKeysLayout(toggle: item, keypad: nil)
    }
}

extension ControlTrayGeometry {
    /// The keypad for the keyboard bar's Arrow Keys item: above the item
    /// (and above an open shortcut palette there), else beside the bar with
    /// bottoms aligned (iPhone landscape, where the keyboard leaves little
    /// room above), never lower than the bar, so never over the keyboard.
    ///
    /// - Parameter safe: the safe area of the container.
    static func keyboardBarKeypadFrame(safe: CGRect, bar: CGRect, item: CGRect, keypadSize: CGSize,
                                       palette: CGRect?, spacing: CGFloat = 10) -> CGRect {
        let bounds = safe.insetBy(dx: 12, dy: 12)
        let size = keypadSize
        let x = clampValue(item.midX - size.width / 2, bounds.minX, bounds.maxX - size.width)
        var ceiling = bar.minY
        if let palette, palette.minX < x + size.width + spacing, palette.maxX > x - spacing {
            ceiling = min(ceiling, palette.minY)
        }
        let above = CGRect(x: x, y: ceiling - spacing - size.height, width: size.width, height: size.height)
        if above.minY >= bounds.minY { return above }
        let beside = [
            CGRect(x: bar.maxX + spacing, y: bar.maxY - size.height, width: size.width, height: size.height),
            CGRect(x: bar.minX - spacing - size.width, y: bar.maxY - size.height, width: size.width, height: size.height),
        ]
        if let fits = beside.first(where: { bounds.contains($0) && !(palette?.intersects($0) ?? false) }) {
            return fits
        }
        // No room anywhere: as high as it goes, its bottom no lower than the bar's.
        return CGRect(x: x, y: min(bounds.minY, bar.maxY - size.height), width: size.width, height: size.height)
    }
}

private func clampValue(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
    max(lower, min(value, max(lower, upper)))
}
