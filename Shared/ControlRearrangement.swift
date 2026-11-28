import Foundation

// Rearrange Controls (iPhone/iPad): chosen from Session Actions (touch and
// hold the Settings gear). A sheet of reorderable lists, one per run of
// buttons: the Main Tray, the Function Tray, and each modifier's or chord's
// shortcut palette. Pure values only, unit-tested on macOS
// (ControlRearrangementTests); `iOS/ControlRearrangeMode.swift` draws it.
// Nothing here reaches the wire, and the order is stored in the existing
// profile fields (`ControlProfile.trayItems`, `ControlProfile.palettes`,
// `FunctionTrayProfile.items`) plus each orientation's own order, so no new
// preference key exists to migrate.

enum ControlRearrangePolicy {
    /// Offered when there is a strip of buttons to put in order: the Main
    /// Tray (shown and not collapsed to its gear) or the Function Tray. Not
    /// for an iPad Custom layout, whose controls are placed freely in its
    /// own editor.
    static func available(trayShown: Bool, functionTrayShown: Bool, customLayout: Bool) -> Bool {
        !customLayout && (trayShown || functionTrayShown)
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

    /// Where an assistive "Move Up" (`delta` -1) or "Move Down" (+1) takes
    /// the item at `index`; nil at either end.
    static func step(from index: Int, by delta: Int, count: Int) -> Int? {
        let target = index + delta
        guard (0..<count).contains(index), (0..<count).contains(target), target != index else { return nil }
        return target
    }

    /// A list row's move (`List.onMove`: the rows at `source`, dropped before
    /// row `destination`) as one item's index `from` and its final index
    /// `to`; nil for anything but a single row that actually moves.
    static func listMove(from source: IndexSet, to destination: Int, count: Int) -> (from: Int, to: Int)? {
        guard source.count == 1, let from = source.first, (0..<count).contains(from),
              (0...count).contains(destination) else { return nil }
        let to = destination > from ? destination - 1 : destination
        return to == from ? nil : (from, to)
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
            let moved = ControlRearrangement.reorderingShown(trayItems, id: \.item, shown: shown, from: from, to: to)
            guard moved != trayItems else { return }
            // Landscape follows portrait until it has an order of its own: it keeps
            // the one it showed, so rearranging portrait never changes it.
            if landscapeTrayOrder == nil { landscapeTrayOrder = trayItems.map(\.item) }
            trayItems = moved
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
            // As for the Main Tray: landscape keeps what it showed.
            if landscapeOrder == nil { landscapeOrder = items.map { FunctionTrayOrderEntry(id: $0.id, group: $0.group) } }
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
