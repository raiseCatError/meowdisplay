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
}
