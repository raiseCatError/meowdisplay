import CoreGraphics
import Foundation

// Rearrange Controls (iPhone/iPad): chosen from Session Actions (touch and
// hold the Settings gear). The live Main Tray and Function Tray buttons
// wiggle like Home Screen icons and are dragged into a new order; tapping a
// modifier with a shortcut palette rearranges that palette's keys the same
// way. Pure values only, unit-tested on macOS (ControlRearrangementTests);
// `iOS/ControlRearrangeMode.swift` draws it. Nothing here reaches the wire,
// and the order is stored in the existing profile fields
// (`ControlProfile.trayItems`, `ControlProfile.palettes`,
// `FunctionTrayProfile.items`), so no new preference key exists to migrate.

enum ControlRearrangePolicy {
    /// Offered when there is a strip of buttons to put in order: the Main
    /// Tray (shown and not collapsed to its gear) or the Function Tray. Not
    /// for an iPad Custom layout, whose controls are placed freely in its
    /// own editor.
    static func available(trayShown: Bool, functionTrayShown: Bool, customLayout: Bool) -> Bool {
        !customLayout && (trayShown || functionTrayShown)
    }

    /// The palette a tap on `item` opens for rearranging: its own modifier's
    /// palette, empty or not. Other tray items have none.
    static func paletteChord(for item: ControlTrayItem, in profile: ControlProfile) -> ModifierChord? {
        item.modifier.map { ModifierChord([$0]) }
    }

    /// The palette open after tapping `modifier` while `open` is: taps
    /// build a chord as the live tray latches one (⌘ then ⌥ opens ⌘⌥), and
    /// tapping a modifier already in it takes it out again.
    static func palette(after open: ModifierChord?, tapping modifier: ControlModifier) -> ModifierChord? {
        guard var modifiers = open?.modifiers else { return ModifierChord([modifier]) }
        if modifiers.contains(modifier) { modifiers.remove(modifier) } else { modifiers.insert(modifier) }
        return modifiers.isEmpty ? nil : ModifierChord(modifiers)
    }
}

enum ControlRearrangement {
    /// `values` with the element at `from` taken out and put back so it ends
    /// at index `to`. Out-of-range indexes change nothing.
    static func moving<T>(_ values: [T], from: Int, to: Int) -> [T] {
        guard values.indices.contains(from), values.indices.contains(to), from != to else { return values }
        var result = values
        let element = result.remove(at: from)
        result.insert(element, at: to)
        return result
    }

    /// Reorders only the elements whose ids are in `shown` (what is on
    /// screen, in screen order), as `moving(shown, from:to:)` does, and
    /// writes them back into the positions those elements already held.
    /// Everything else (hidden items, items this device can't show) keeps
    /// its exact position, so they come back where they were.
    static func reorderingShown<T, ID: Hashable>(_ all: [T], id: (T) -> ID, shown: [ID],
                                                from: Int, to: Int) -> [T] {
        guard shown.indices.contains(from), shown.indices.contains(to), from != to else { return all }
        let positions = shown.compactMap { wanted in all.firstIndex { id($0) == wanted } }
        guard positions.count == shown.count, Set(positions).count == positions.count else { return all }
        let reordered = moving(positions.map { all[$0] }, from: from, to: to)
        var result = all
        for (slot, position) in positions.sorted().enumerated() { result[position] = reordered[slot] }
        return result
    }

    /// The slot whose centre is nearest `point`; nil without slots. Ties go
    /// to the earlier slot.
    static func nearestSlot(to point: CGPoint, in slots: [CGRect]) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, slot) in slots.enumerated() {
            let distance = hypot(slot.midX - point.x, slot.midY - point.y)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best?.index
    }

    /// The outlines of `slots` as drawn groups: slots closer than about
    /// half a button to a neighbour share one rectangle (a tray, a
    /// Function cluster, one half of a folded row).
    static func clusters(_ slots: [CGRect]) -> [CGRect] {
        var clusters: [CGRect] = []
        for slot in slots {
            let reach = min(slot.width, slot.height) * 0.6
            let grown = slot.insetBy(dx: -reach, dy: -reach)
            var merged = slot
            clusters.removeAll { cluster in
                guard cluster.intersects(grown) else { return false }
                merged = merged.union(cluster)
                return true
            }
            clusters.append(merged)
        }
        return clusters
    }

    /// A palette's keys as the live palette's grid draws them, centred in
    /// `frame`: along rows in portrait, down columns in landscape
    /// (`ShortcutPaletteGrid`).
    static func paletteSlots(count: Int, rows: Int, columns: Int, rowMajor: Bool,
                             key: CGSize, gap: CGFloat, in frame: CGRect) -> [CGRect] {
        guard count > 0, rows > 0, columns > 0 else { return [] }
        let width = CGFloat(columns) * key.width + CGFloat(columns - 1) * gap
        let height = CGFloat(rows) * key.height + CGFloat(rows - 1) * gap
        let origin = CGPoint(x: frame.midX - width / 2, y: frame.midY - height / 2)
        return (0..<count).map { index in
            let row = rowMajor ? index / columns : index % rows
            let column = rowMajor ? index % columns : index / rows
            return CGRect(x: origin.x + CGFloat(column) * (key.width + gap),
                          y: origin.y + CGFloat(row) * (key.height + gap), width: key.width, height: key.height)
        }
    }

    /// Where an assistive "Move Left/Up" (`delta` -1) or "Move Right/Down"
    /// (+1) takes the item at `index`; nil at either end.
    static func step(from index: Int, by delta: Int, count: Int) -> Int? {
        let target = index + delta
        guard (0..<count).contains(index), (0..<count).contains(target), target != index else { return nil }
        return target
    }

    /// Whether slots run mostly side by side (Move Left/Right) rather than
    /// one above another (Move Up/Down).
    static func runsHorizontally(_ slots: [CGRect]) -> Bool {
        guard let first = slots.first else { return true }
        let xs = slots.map(\.midX), ys = slots.map(\.midY)
        let width = (xs.max() ?? first.midX) - (xs.min() ?? first.midX)
        let height = (ys.max() ?? first.midY) - (ys.min() ?? first.midY)
        return width >= height
    }

    /// `count` chips of `item` side by side (or stacked), `spacing` apart,
    /// centred on `center`, as an HStack/VStack draws them.
    static func stackSlots(center: CGPoint, horizontal: Bool, count: Int, item: CGFloat,
                           spacing: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let length = CGFloat(count) * item + CGFloat(count - 1) * spacing
        let start = (horizontal ? center.x : center.y) - length / 2
        return (0..<count).map { index in
            let along = start + CGFloat(index) * (item + spacing)
            return horizontal
                ? CGRect(x: along, y: center.y - item / 2, width: item, height: item)
                : CGRect(x: center.x - item / 2, y: along, width: item, height: item)
        }
    }

    /// The keys of a palette being rearranged, as a centred grid of at most
    /// `maximumColumns` columns that fits `bounds`' width.
    static func gridSlots(count: Int, key: CGFloat, gap: CGFloat, maximumColumns: Int,
                          center: CGPoint, bounds: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let fitting = Int((bounds.width + gap) / (key + gap))
        let columns = max(1, min(count, maximumColumns, fitting))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let width = CGFloat(columns) * key + CGFloat(columns - 1) * gap
        let height = CGFloat(rows) * key + CGFloat(rows - 1) * gap
        let origin = CGPoint(x: center.x - width / 2, y: center.y - height / 2)
        return (0..<count).map { index in
            CGRect(x: origin.x + CGFloat(index % columns) * (key + gap),
                   y: origin.y + CGFloat(index / columns) * (key + gap), width: key, height: key)
        }
    }
}

extension ControlProfile {
    /// `trayItems` in the order of the given orientation: landscape keeps
    /// its own once it was rearranged there. Items the landscape order
    /// predates follow it in their portrait order.
    func trayItems(landscape: Bool) -> [TrayItemConfiguration] {
        guard landscape, let order = landscapeTrayOrder else { return trayItems }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return trayItems.enumerated().sorted { a, b in
            let ra = rank[a.element.item] ?? order.count + a.offset
            let rb = rank[b.element.item] ?? order.count + b.offset
            return ra < rb
        }.map(\.element)
    }

    func visibleTrayItems(landscape: Bool) -> [ControlTrayItem] {
        trayItems(landscape: landscape).filter(\.isVisible).map(\.item)
    }

    /// Moves a Main Tray item among `shown` (the tray as drawn, in order).
    /// Portrait and landscape keep separate orders.
    mutating func moveShownTrayItem(shown: [ControlTrayItem], from: Int, to: Int, landscape: Bool = false) {
        if landscape {
            let ordered = trayItems(landscape: true)
            let moved = ControlRearrangement.reorderingShown(ordered, id: \.item, shown: shown, from: from, to: to)
            if moved != ordered { landscapeTrayOrder = moved.map(\.item) }
        } else {
            trayItems = ControlRearrangement.reorderingShown(trayItems, id: \.item, shown: shown, from: from, to: to)
        }
    }

    /// Moves one key of `chord`'s palette.
    mutating func moveAction(for chord: ModifierChord, from: Int, to: Int) {
        let actions = actions(for: chord)
        guard actions.indices.contains(from), actions.indices.contains(to), from != to else { return }
        setActions(ControlRearrangement.moving(actions, from: from, to: to), for: chord)
    }
}

extension FunctionTrayProfile {
    /// Moves a Function Tray button among `shown` (the visible buttons by
    /// id, in tray order). The clusters keep their sizes: each slot keeps
    /// the group it had, and the button landing there joins it, so the tray
    /// keeps its shape while buttons pass from one cluster to the next.
    mutating func moveShownItem(shown: [String], from: Int, to: Int, landscape: Bool = false) {
        var ordered = items(landscape: landscape)
        let positions = shown.compactMap { id in ordered.firstIndex { $0.id == id } }.sorted()
        guard positions.count == shown.count else { return }
        let slotGroups = positions.map { ordered[$0].group }
        let moved = ControlRearrangement.reorderingShown(ordered, id: \.id, shown: shown, from: from, to: to)
        guard moved != ordered else { return }
        ordered = moved
        for (slot, position) in positions.enumerated() { ordered[position].group = slotGroups[slot] }
        if landscape {
            landscapeOrder = ordered.map { FunctionTrayOrderEntry(id: $0.id, group: $0.group) }
        } else {
            items = ordered
        }
    }

    /// `items` in the order and clusters of the given orientation:
    /// landscape keeps its own once it was rearranged there. Buttons the
    /// landscape order predates follow it as they are in portrait.
    func items(landscape: Bool) -> [FunctionTrayItemConfiguration] {
        guard landscape, let order = landscapeOrder else { return items }
        var byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [FunctionTrayItemConfiguration] = []
        for entry in order {
            guard var item = byID.removeValue(forKey: entry.id) else { continue }
            item.group = entry.group
            result.append(item)
        }
        return result + items.filter { byID[$0.id] != nil }
    }

    /// `visibleGroups` in the given orientation's order.
    func visibleGroups(landscape: Bool) -> [[ShortcutItem]] {
        FunctionTrayProfile(slot: slot, items: items(landscape: landscape)).visibleGroups
    }
}

/// One icon's Home Screen style wiggle: a small rotation back and forth with
/// a slighter vertical bob, its period and phase varied per icon so a row
/// never moves in lockstep. Modelled on SpringBoard's edit mode: about ±1.5–2°
/// over roughly a quarter second (≈0.13 s a half swing), with a bob under a
/// point.
struct ControlJiggleMotion: Equatable {
    static let amplitudeRange: ClosedRange<Double> = 1.5...2.0
    static let periodRange: ClosedRange<Double> = 0.24...0.30
    static let bobRange: ClosedRange<Double> = 0.5...1.0

    /// Degrees either side of upright.
    let amplitude: Double
    /// Seconds per full swing (left, right and back).
    let period: Double
    /// Radians.
    let phase: Double
    /// Points either side of rest.
    let bob: Double
    let bobPeriod: Double
    let bobPhase: Double

    /// Deterministic per id (djb2 over its scalars, then a SplitMix64 mix),
    /// so an icon keeps its own rhythm across redraws.
    init(id: String) {
        let seed = id.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        var state = seed
        func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        func value(in range: ClosedRange<Double>) -> Double {
            range.lowerBound + next() * (range.upperBound - range.lowerBound)
        }
        amplitude = value(in: Self.amplitudeRange)
        period = value(in: Self.periodRange)
        phase = next() * 2 * .pi
        bob = value(in: Self.bobRange)
        bobPeriod = period * value(in: 1.04...1.12)
        bobPhase = next() * 2 * .pi
    }

    /// Rotation in degrees at `time` seconds.
    func angle(at time: TimeInterval) -> Double {
        amplitude * sin(2 * .pi * time / period + phase)
    }

    /// Vertical offset in points at `time` seconds.
    func offset(at time: TimeInterval) -> Double {
        bob * sin(2 * .pi * time / bobPeriod + bobPhase)
    }
}
