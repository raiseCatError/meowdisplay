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
/// Plain toggles: touching a modifier turns it on or off at once (on touch
/// down, not on lift), and it stays that way until it is touched again or
/// the keypad closes (`clear`). Any number can be on together; the next
/// arrow carries exactly the ones that are on. There is no hold mode: a
/// touch never depends on what another finger does, so a quick ⇧ then →
/// with two thumbs can't silently fail to latch.
struct ArrowKeypadModifiers: Equatable {
    /// Reading order: left to right, then top to bottom.
    static let keys: [ControlModifier] = [.shift, .option, .command]

    private(set) var latched: Set<ControlModifier> = []

    /// What an arrow going down now carries (while `isAvailable`).
    var active: Set<ControlModifier> { latched }

    var isEmpty: Bool { latched.isEmpty }

    /// A Mac that takes exact modifiers keeps the two sets apart. An older
    /// Mac adds whatever the tray holds down to every key, so there the
    /// keypad's modifiers work only while the tray holds none; otherwise an
    /// arrow would carry both.
    static func isAvailable(macSupportsExactModifiers: Bool, trayChord: Set<ControlModifier>) -> Bool {
        macSupportsExactModifiers || trayChord.isEmpty
    }

    /// A touch (or an assistive tap) on `modifier`: turns it on, or off if
    /// it was on. Returns whether anything changed.
    @discardableResult
    mutating func toggle(_ modifier: ControlModifier) -> Bool {
        guard Self.keys.contains(modifier) else { return false }
        if latched.remove(modifier) == nil { latched.insert(modifier) }
        return true
    }

    /// An arrow goes down now: the modifiers it carries (none while the
    /// keypad's modifiers are unavailable).
    func keyDown(available: Bool) -> Set<ControlModifier> {
        available ? latched : []
    }

    /// The keypad closed, or input was reset: nothing on.
    mutating func clear() {
        latched.removeAll()
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

/// The small label above the keypad. One visual language with the shortcut
/// HUD (same capsule), but it says what was *sent*, never that the Mac did
/// anything: the keyboard protocol has no acknowledgement.
enum ArrowKeyPreview: Equatable {
    /// Modifiers are on and no arrow is down: what the next arrow will carry.
    /// Drawn subdued, ending in an open slot ("⇧ ⌘ ·").
    case armed(Set<ControlModifier>)
    /// An arrow went down with these modifiers (and repeats while held).
    case sent(ArrowKeyDirection, Set<ControlModifier>)

    /// macOS menu order: ⌃ ⌥ ⇧ ⌘.
    static let displayOrder: [ControlModifier] = [.control, .option, .shift, .command]

    var text: String {
        switch self {
        case .armed(let modifiers):
            return (Self.symbols(modifiers) + ["·"]).joined(separator: " ")
        case .sent(let direction, let modifiers):
            return (Self.symbols(modifiers) + [direction.glyph]).joined(separator: " ")
        }
    }

    var isSent: Bool { if case .sent = self { return true } else { return false } }

    /// What VoiceOver hears, e.g. "Shift Command Down Arrow".
    var spokenText: String {
        let names = Self.displayOrder.filter(modifiers.contains).map(\.title)
        switch self {
        case .armed: return names.joined(separator: " ")
        case .sent(let direction, _): return (names + [direction.title]).joined(separator: " ")
        }
    }

    private var modifiers: Set<ControlModifier> {
        switch self {
        case .armed(let m), .sent(_, let m): return m
        }
    }

    private static func symbols(_ modifiers: Set<ControlModifier>) -> [String] {
        displayOrder.filter(modifiers.contains).map(\.symbol)
    }

    /// The preview to show: the held arrow wins; else the armed modifiers;
    /// else the arrow just released while it lingers; else nothing.
    static func current(held: ArrowKeyDirection?, heldModifiers: Set<ControlModifier>,
                        lingering: ArrowKeyPreview?, armed: Set<ControlModifier>) -> ArrowKeyPreview? {
        if let held { return .sent(held, heldModifiers) }
        if let lingering, lingering.isSent { return lingering }
        return armed.isEmpty ? nil : .armed(armed)
    }

    /// How long a sent arrow stays readable after its key goes up, so a
    /// quick tap is still seen.
    static let linger: TimeInterval = 0.7
}

extension ArrowKeyDirection {
    /// The arrow as text, for the preview.
    var glyph: String {
        switch self {
        case .up: return "↑"
        case .left: return "←"
        case .down: return "↓"
        case .right: return "→"
        }
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

/// Where the keypad's own ⇧ ⌥ ⌘ sit against the T. Every placement keeps
/// them the size of an arrow key; only the block's shape changes.
enum ArrowKeypadModifierPlacement: Equatable, CaseIterable {
    /// A row over the T, filling its width (the T's empty top corners sit
    /// under ⇧ and ⌘): a 134×134 block. Preferred: modifiers are set before
    /// an arrow, the arrows stay nearest the thumb, and the row never
    /// borders the button.
    case above
    /// A 2×2 grid (⇧ ⌥ / ⌘) left of the T: a wide, T-high block for when
    /// there's no height to spare (iPhone landscape with the keyboard up).
    case leading
    /// The same grid right of the T.
    case trailing
    /// A row under the T, between it and the button: last resort.
    case below

    /// Beside the T (a grid) rather than over or under it (a row).
    var isBeside: Bool { self == .leading || self == .trailing }
}

extension ArrowKeypadGeometry {
    /// One modifier key: the same square as an arrow key, so it gets the
    /// same touch area (key plus the gap), never a sliver.
    static func modifierKeySize(key: CGFloat) -> CGSize {
        CGSize(width: key, height: key)
    }

    /// The touch area of one key: the key plus half the gap on each side.
    static func touchSize(key: CGFloat, gap: CGFloat) -> CGSize {
        CGSize(width: key + gap, height: key + gap)
    }

    /// The three modifier keys: a row spanning the T's width, or a 2×2 grid
    /// as high as the T.
    static func modifierStripSize(_ placement: ArrowKeypadModifierPlacement, key: CGFloat, gap: CGFloat) -> CGSize {
        placement.isBeside ? CGSize(width: key * 2 + gap, height: key * 2 + gap)
                           : CGSize(width: key * 3 + gap * 2, height: key)
    }

    /// The T and its modifiers as one block, `gap` apart: what the placement
    /// code moves around the other controls.
    static func blockSize(_ placement: ArrowKeypadModifierPlacement, key: CGFloat, gap: CGFloat) -> CGSize {
        let keypad = size(key: key, gap: gap)
        let strip = modifierStripSize(placement, key: key, gap: gap)
        return placement.isBeside
            ? CGSize(width: keypad.width + gap + strip.width, height: keypad.height)
            : CGSize(width: keypad.width, height: keypad.height + gap + strip.height)
    }

    /// A placed block, split into the T and the modifiers.
    static func split(_ block: CGRect, placement: ArrowKeypadModifierPlacement,
                      key: CGFloat, gap: CGFloat) -> (keypad: CGRect, modifiers: CGRect) {
        let keypad = size(key: key, gap: gap)
        let strip = modifierStripSize(placement, key: key, gap: gap)
        switch placement {
        case .above:
            return (CGRect(x: block.minX, y: block.maxY - keypad.height, width: keypad.width, height: keypad.height),
                    CGRect(x: block.minX, y: block.minY, width: strip.width, height: strip.height))
        case .below:
            return (CGRect(x: block.minX, y: block.minY, width: keypad.width, height: keypad.height),
                    CGRect(x: block.minX, y: block.maxY - strip.height, width: strip.width, height: strip.height))
        case .leading:
            return (CGRect(x: block.maxX - keypad.width, y: block.minY, width: keypad.width, height: keypad.height),
                    CGRect(x: block.minX, y: block.minY, width: strip.width, height: strip.height))
        case .trailing:
            return (CGRect(x: block.minX, y: block.minY, width: keypad.width, height: keypad.height),
                    CGRect(x: block.maxX - strip.width, y: block.minY, width: strip.width, height: strip.height))
        }
    }

    /// Each modifier key's frame inside the modifiers' frame `strip`: ⇧ ⌥ ⌘
    /// left to right in a row; ⇧ ⌥ over ⌘ in a grid, with ⌘ on the side
    /// nearest the T's ← or →.
    static func modifierKeyFrames(in strip: CGRect, placement: ArrowKeypadModifierPlacement,
                                  key: CGFloat, gap: CGFloat) -> [ControlModifier: CGRect] {
        let step = key + gap
        func cell(_ column: Int, _ row: Int) -> CGRect {
            CGRect(x: strip.minX + CGFloat(column) * step, y: strip.minY + CGFloat(row) * step, width: key, height: key)
        }
        switch placement {
        case .above, .below:
            return [.shift: cell(0, 0), .option: cell(1, 0), .command: cell(2, 0)]
        case .leading:
            return [.shift: cell(0, 0), .option: cell(1, 0), .command: cell(1, 1)]
        case .trailing:
            return [.shift: cell(0, 0), .option: cell(1, 0), .command: cell(0, 1)]
        }
    }
}

/// Where the compact arrow button and its keypad sit.
struct ArrowKeysLayout: Equatable {
    var toggle: CGRect
    /// The T; nil while the keypad is closed.
    var keypad: CGRect?
    /// The keypad's own ⇧ ⌥ ⌘ over, beside or under the T; nil while it is closed.
    var modifiers: CGRect? = nil
    var modifierPlacement: ArrowKeypadModifierPlacement? = nil
    /// The key size the keypad was laid out with when it isn't the standard
    /// one (only the keyboard bar shrinks it, when nothing else fits).
    var key: CGFloat? = nil

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
    /// Where the keypad's modifiers are tried, best first: a row over the T
    /// (134×134 at the default sizes), then a grid on the side with room
    /// (toward the middle of the screen from the button, so the T stays
    /// over the button near an edge; 226×88, for when height is short), a
    /// grid on the other side, and last a row under the T.
    static func arrowKeypadModifierPlacements(toggle: CGRect, container: CGRect) -> [ArrowKeypadModifierPlacement] {
        let towardMiddle: ArrowKeypadModifierPlacement = toggle.midX > container.midX ? .leading : .trailing
        return [.above, towardMiddle, towardMiddle == .leading ? .trailing : .leading, .below]
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
        // iPhone landscape with the keyboard up leaves ~121 pt beside the bar:
        // no full-size block fits, so try once more with keys just small
        // enough for a row block there (never under 34 pt), rather than
        // overlapping the safe area or shrinking the modifiers alone.
        let fitting = ((bar.maxY - bounds.minY - 2 * gap) / 3).rounded(.down)
        let sizes = fitting < key ? [key, max(34, fitting)] : [key]
        var fallback: ArrowKeysLayout?
        for size in sizes {
            for placement in arrowKeypadModifierPlacements(toggle: item, container: safe) {
                let block = keyboardBarKeypadFrame(safe: safe, bar: bar, item: item,
                                                   keypadSize: ArrowKeypadGeometry.blockSize(placement, key: size, gap: gap),
                                                   palette: palette, spacing: spacing)
                let parts = ArrowKeypadGeometry.split(block, placement: placement, key: size, gap: gap)
                let layout = ArrowKeysLayout(toggle: item, keypad: parts.keypad, modifiers: parts.modifiers,
                                             modifierPlacement: placement, key: size == key ? nil : size)
                if fallback == nil { fallback = layout }
                if bounds.contains(block), !block.intersects(bar), !(palette?.intersects(block) ?? false) {
                    return layout
                }
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
