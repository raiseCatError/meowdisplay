import CoreGraphics

/// Keeping the receiver's own controls and overlays off a fold: the iPhone
/// Duo's crease, or any division the system reports. Pure, so it is
/// unit-tested on macOS. Without a division every function returns what it
/// was given, so ordinary iPhones and iPads lay out exactly as before.
enum ControlFoldGeometry {
    /// The usable pieces of `visible` once every division crossing it is
    /// removed, in reading order. Just `[visible]` without a division.
    static func pieces(of visible: CGRect, divisions: [CGRect]) -> [CGRect] {
        let cuts = divisions.map { $0.intersection(visible) }.filter { !$0.isNull && !$0.isEmpty }
        guard !cuts.isEmpty else { return [visible] }
        let columns = ControlPlacementArea.segments(of: visible, removing: cuts.filter { $0.height >= $0.width },
                                                    horizontal: true)
        let rows = ControlPlacementArea.segments(of: visible, removing: cuts.filter { $0.height < $0.width },
                                                 horizontal: false)
        return rows.flatMap { row in columns.map { $0.intersection(row) } }
            .filter { !$0.isNull && !$0.isEmpty }
    }

    /// A centred overlay (a prompt, a hint, a card, a banner) moved wholly
    /// into one piece when it would straddle a fold: the piece holding most
    /// of it, ties going to the lower piece (laptop pose: the flat half
    /// under the thumbs), then the trailing one. Unchanged when it touches
    /// no division.
    static func clearOfFolds(_ frame: CGRect, in visible: CGRect, divisions: [CGRect],
                             gap: CGFloat = 8) -> CGRect {
        let bands = divisions.filter { !$0.isNull && !$0.isEmpty }
        guard bands.contains(where: { $0.insetBy(dx: -gap, dy: -gap).intersects(frame) }) else { return frame }
        let candidates = pieces(of: visible, divisions: bands).map { $0.insetBy(dx: gap, dy: gap) }
            .filter { $0.width > 0 && $0.height > 0 }
        func overlap(_ piece: CGRect) -> CGFloat {
            let shared = piece.intersection(frame)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        guard let best = candidates.max(by: { a, b in
            let (oa, ob) = (overlap(a), overlap(b))
            if abs(oa - ob) > 0.5 { return oa < ob }
            if abs(a.midY - b.midY) > 0.5 { return a.midY < b.midY }
            return a.midX < b.midX
        }) else { return frame }
        var moved = frame
        moved.origin.x = min(max(frame.minX, best.minX), max(best.minX, best.maxX - frame.width))
        moved.origin.y = min(max(frame.minY, best.minY), max(best.minY, best.maxY - frame.height))
        return moved
    }

    /// The keyboard companion bar on a fold.
    struct KeyboardBar: Equatable {
        /// One bar, or two when a vertical fold splits it.
        var bars: [CGRect]
        /// One cell per item, in item order.
        var cells: [CGRect]
        /// Key size after fitting.
        var item: CGFloat
        /// Where the shortcut palette may open: the piece of the bar that
        /// holds the modifiers. The whole container without a fold.
        var paletteArea: CGRect
    }

    /// Lays out `count` bar keys centred above the keyboard.
    ///
    /// - Book pose (a vertical fold through the bar): two groups, the first
    ///   `leadingCount` keys (the modifiers) centred in the left piece and
    ///   the rest centred in the right, like the split keyboard below them.
    /// - Laptop pose (a horizontal fold the bar would cross): the bar sits
    ///   just above the fold, since the gap between the fold and the
    ///   keyboard can't hold it.
    static func keyboardBar(count: Int, leadingCount: Int, item preferredItem: CGFloat, gap: CGFloat,
                            padding: CGFloat, container: CGRect, keyboardTop: CGFloat,
                            divisions: [CGRect], spacing: CGFloat = 8) -> KeyboardBar {
        let margin: CGFloat = 12
        func width(_ n: Int, _ item: CGFloat) -> CGFloat {
            CGFloat(n) * item + CGFloat(max(0, n - 1)) * gap + padding * 2
        }
        func row(_ n: Int, item: CGFloat, centreX: CGFloat, y: CGFloat) -> (CGRect, [CGRect]) {
            let bar = CGRect(x: centreX - width(n, item) / 2, y: y, width: width(n, item), height: item + padding * 2)
            let cells = (0..<n).map { index in
                CGRect(x: bar.minX + padding + CGFloat(index) * (item + gap), y: bar.minY + padding,
                       width: item, height: item)
            }
            return (bar, cells)
        }
        let height = preferredItem + padding * 2
        var y = keyboardTop - spacing - height
        var lifted = false
        let bands = divisions.map { $0.intersection(container) }.filter { !$0.isNull && !$0.isEmpty }
        let plain = row(count, item: preferredItem, centreX: container.midX, y: y)

        // Laptop: a horizontal band the bar would touch lifts it above the band.
        if let band = bands.filter({ $0.width > $0.height })
            .first(where: { $0.insetBy(dx: 0, dy: -spacing).intersects(plain.0) }) {
            y = band.minY - spacing - height
            lifted = true
        }
        let barBand = CGRect(x: container.minX, y: y, width: container.width, height: height)
        // Book: a vertical band crossing the bar splits it in two.
        let vertical = bands.filter { $0.height >= $0.width && $0.intersects(barBand) }
        guard let fold = vertical.first, leadingCount > 0, leadingCount < count,
              plain.0.offsetBy(dx: 0, dy: y - plain.0.minY).insetBy(dx: -spacing, dy: 0).intersects(fold) else {
            let (bar, cells) = row(count, item: preferredItem, centreX: container.midX, y: y)
            return KeyboardBar(bars: [bar], cells: cells, item: preferredItem, paletteArea: container)
        }
        let left = CGRect(x: container.minX, y: container.minY, width: max(0, fold.minX - container.minX),
                          height: container.height)
        let right = CGRect(x: fold.maxX, y: container.minY, width: max(0, container.maxX - fold.maxX),
                           height: container.height)
        let trailingCount = count - leadingCount
        // Shrink both groups alike only if one wouldn't fit its piece.
        func fitted(_ n: Int, in piece: CGRect) -> CGFloat {
            ControlTrayGeometry.fittedChipDiameter(count: n, length: piece.width, preferred: preferredItem,
                                                   gap: gap, slack: padding * 2, margin: margin)
        }
        let item = min(fitted(leadingCount, in: left), fitted(trailingCount, in: right))
        let startY = lifted ? y : keyboardTop - spacing - (item + padding * 2)
        let first = row(leadingCount, item: item, centreX: left.midX, y: startY)
        let second = row(trailingCount, item: item, centreX: right.midX, y: startY)
        return KeyboardBar(bars: [first.0, second.0], cells: first.1 + second.1, item: item, paletteArea: left)
    }

    // MARK: - Compact phone tray

    /// The vertical divisions that cross a horizontal band, clipped to `container`.
    private static func verticalCuts(crossing band: CGRect, in container: CGRect, divisions: [CGRect]) -> [CGRect] {
        divisions.map { $0.intersection(container) }
            .filter { !$0.isNull && !$0.isEmpty && $0.height >= $0.width && $0.intersects(band) }
    }

    /// The compact phone tray's chips split around a vertical fold.
    struct TrayRow: Equatable {
        /// The row as drawn: from the first chip to the last, fold included.
        var frame: CGRect
        /// One touch region per piece the chips sit in, left to right.
        var groups: [CGRect]
        /// One chip per item, in item order.
        var cells: [CGRect]
        /// Chips in each group, left to right.
        var counts: [Int]
        /// Empty width to leave between a group and the next, left to right,
        /// once the stack's own spacing on both sides of it is counted.
        var spacers: [CGFloat]
        /// Chip diameter after fitting.
        var item: CGFloat

        /// The item indexes each group holds.
        var itemRanges: [Range<Int>] {
            var start = 0
            var ranges: [Range<Int>] = []
            for count in counts {
                ranges.append(start..<(start + count))
                start += count
            }
            return ranges
        }
    }

    /// Splits a bottom-aligned row of `count` chips around the vertical folds
    /// that cross it, for a row that is too wide for the piece it would
    /// otherwise be squeezed into. Chips keep their order; each piece gets as
    /// many as fit it best and they are centred in it, all at one chip size
    /// (shrunk, down to `minimumItem`, only as far as the fullest piece needs).
    /// `nil` when the row was not squeezed (`placed`, where the layout put it,
    /// is as wide as the `wantedWidth` it asked for) or no vertical fold
    /// crosses it, so the caller keeps its own placement.
    ///
    /// - Parameters:
    ///   - placed: the frame the layout gave the row as one piece; the split
    ///     row keeps its bottom edge.
    ///   - wantedWidth: the width that row asked for.
    ///   - slack: the touch slack the row's frame adds around the chips.
    ///   - container: the visible area the row lives in.
    static func trayRow(count: Int, item preferredItem: CGFloat, gap: CGFloat, slack: CGFloat,
                        placed: CGRect, wantedWidth: CGFloat, container: CGRect, divisions: [CGRect],
                        margin: CGFloat = 12, minimumItem: CGFloat = 24) -> TrayRow? {
        guard count > 1, placed.width + 0.5 < wantedWidth else { return nil }
        let bottom = placed.maxY
        let preferredBand = CGRect(x: container.minX, y: bottom - preferredItem - slack,
                                   width: container.width, height: preferredItem + slack)
        let cuts = verticalCuts(crossing: preferredBand, in: container, divisions: divisions)
        guard !cuts.isEmpty else { return nil }
        let pieces = ControlPlacementArea.segments(of: container, removing: cuts, horizontal: true)
            .filter { $0.width - margin * 2 - slack >= minimumItem }
        guard !pieces.isEmpty else { return nil }

        // The chip size `n` chips could have in a piece.
        func capacity(_ piece: CGRect, _ n: Int) -> CGFloat {
            (piece.width - margin * 2 - slack - CGFloat(n - 1) * gap) / CGFloat(n)
        }
        // Each chip goes to the piece where the chips would stay largest.
        var counts = Array(repeating: 0, count: pieces.count)
        for _ in 0..<count {
            var best = 0
            for index in pieces.indices
            where capacity(pieces[index], counts[index] + 1) > capacity(pieces[best], counts[best] + 1) + 0.001 {
                best = index
            }
            counts[best] += 1
        }
        let used = pieces.indices.filter { counts[$0] > 0 }
        let item = used.map { index in
            ControlTrayGeometry.fittedChipDiameter(count: counts[index], length: pieces[index].width,
                                                   preferred: preferredItem, gap: gap, slack: slack,
                                                   margin: margin, minimum: minimumItem)
        }.min() ?? preferredItem

        let thickness = item + slack
        var cells: [CGRect] = []
        var groups: [CGRect] = []
        var spacers: [CGFloat] = []
        for index in used {
            let n = counts[index]
            let width = CGFloat(n) * item + CGFloat(n - 1) * gap
            let startX = pieces[index].midX - width / 2
            let row = (0..<n).map { step in
                CGRect(x: startX + CGFloat(step) * (item + gap), y: bottom - slack / 2 - item,
                       width: item, height: item)
            }
            if let previous = cells.last, let first = row.first {
                spacers.append(first.minX - previous.maxX - gap * 2)
            }
            cells += row
            groups.append(CGRect(x: startX - slack / 2, y: bottom - thickness, width: width + slack,
                                 height: thickness))
        }
        guard let first = groups.first else { return nil }
        let frame = groups.dropFirst().reduce(first) { $0.union($1) }
        return TrayRow(frame: frame, groups: groups, cells: cells, counts: used.map { counts[$0] },
                       spacers: spacers, item: item)
    }

    /// Function Tray groups placed along one row around the vertical folds
    /// that cross it. Each group stays whole; groups go in order into the
    /// first piece with room left, and each piece's groups are centred in it.
    struct GroupRow: Equatable {
        /// One frame per group, in group order.
        var frames: [CGRect]
        /// The pieces the groups sit in; each frame lies inside one of them.
        var pieces: [CGRect]
    }

    /// `nil` when no vertical fold crosses the row `y ..< y + height`.
    static func groupRow(sizes: [CGSize], groupGap: CGFloat, y: CGFloat, height: CGFloat, container: CGRect,
                         divisions: [CGRect], margin: CGFloat = 12) -> GroupRow? {
        guard let narrowest = sizes.map(\.width).min() else { return nil }
        let band = CGRect(x: container.minX, y: y, width: container.width, height: height)
        let cuts = verticalCuts(crossing: band, in: container, divisions: divisions)
        guard !cuts.isEmpty else { return nil }
        let pieces = ControlPlacementArea.segments(of: container, removing: cuts, horizontal: true)
            .filter { $0.width - margin * 2 >= narrowest }
        guard !pieces.isEmpty else { return nil }

        var assigned = Array(repeating: [Int](), count: pieces.count)
        var column = 0
        var used: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let needed = assigned[column].isEmpty ? size.width : used + groupGap + size.width
            if needed > pieces[column].width - margin * 2, !assigned[column].isEmpty, column < pieces.count - 1 {
                column += 1
                used = size.width
            } else {
                used = needed
            }
            assigned[column].append(index)
        }
        var frames = Array(repeating: CGRect.zero, count: sizes.count)
        for (index, members) in assigned.enumerated() where !members.isEmpty {
            let room = max(0, pieces[index].width - margin * 2)
            let widths = members.map { min(sizes[$0].width, room) }
            let total = widths.reduce(0, +) + CGFloat(members.count - 1) * groupGap
            var x = pieces[index].midX - total / 2
            for (member, width) in zip(members, widths) {
                frames[member] = CGRect(x: x, y: y, width: width, height: sizes[member].height)
                x += width + groupGap
            }
        }
        return GroupRow(frames: frames, pieces: pieces.indices.filter { !assigned[$0].isEmpty }.map { pieces[$0] })
    }
}

extension ControlTrayLayout {
    /// The same layout drawing its tray in `frame`.
    func replacingTrayFrame(_ frame: CGRect) -> ControlTrayLayout {
        var copy = self
        copy.trayFrame = frame
        return copy
    }
}
