import CoreGraphics
import Foundation

/// Spatial Overview: Stage Peek's optional expanded layout. Every window keeps its shape and
/// bigger Mac windows look bigger (within limits), packed in rows like Mission Control, never
/// overlapping, in a stable order. When the windows can't all be at least `minimumSide` on one
/// screen, they continue on more pages. Shared with Android through fixtures/stage-peek/spatial.json.
enum SpatialOverviewLayout {
    struct Item: Equatable { var width: Double; var height: Double }
    struct Placement: Equatable { var page: Int; var rect: CGRect }

    /// The smallest a window's shorter side may be drawn (a comfortable tap).
    static let minimumSide = 72.0
    static let spacing = 14.0
    static let margin = 16.0
    /// The smallest window is drawn at least this share of the largest one's scale.
    static let minimumProminence = 0.6
    /// Shapes beyond these are drawn as these (a very wide or tall window stays tappable).
    static let aspectRange = 0.4...3.0

    /// Unit-area box per window (its shape), scaled by how big it is on the Mac relative to the
    /// biggest, clamped to `minimumProminence...1`.
    static func normalized(_ items: [Item]) -> [(w: Double, h: Double)] {
        let areas = items.map { max($0.width, 1) * max($0.height, 1) }
        let biggest = areas.max() ?? 1
        return zip(items, areas).map { item, area in
            let aspect = min(max(max(item.width, 1) / max(item.height, 1), aspectRange.lowerBound), aspectRange.upperBound)
            let p = min(max((area / biggest).squareRoot(), minimumProminence), 1)
            return (p * aspect.squareRoot(), p / aspect.squareRoot())
        }
    }

    /// Rows at `scale`: greedy left to right in order. nil when they don't fit `size`.
    private static func rows(_ boxes: [(w: Double, h: Double)], scale k: Double, width: Double) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var x = 0.0
        for (i, b) in boxes.enumerated() {
            let w = b.w * k
            if !rows[rows.count - 1].isEmpty, x + spacing + w > width { rows.append([]); x = 0 }
            x += (rows[rows.count - 1].isEmpty ? 0 : spacing) + w
            rows[rows.count - 1].append(i)
        }
        return rows
    }

    private static func fits(_ boxes: [(w: Double, h: Double)], scale k: Double, width: Double, height: Double) -> Bool {
        if boxes.contains(where: { $0.w * k > width + 1e-9 }) { return false }
        let r = rows(boxes, scale: k, width: width)
        let total = r.reduce(0.0) { $0 + ($1.map { boxes[$0].h * k }.max() ?? 0) } + spacing * Double(max(r.count - 1, 0))
        return total <= height + 1e-9
    }

    /// The biggest scale at which these boxes fit (deterministic bisection).
    private static func bestScale(_ boxes: [(w: Double, h: Double)], width: Double, height: Double) -> Double {
        var lo = 0.0, hi = max(width, height) * 2
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            if fits(boxes, scale: mid, width: width, height: height) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// Pages of `perPage` windows in order, and the one scale they all share (so a window is the
    /// same size on every page): the smallest page's best.
    private static func paging(_ boxes: [(w: Double, h: Double)], perPage: Int, width: Double, height: Double) -> (pages: [[Int]], scale: Double) {
        let pages = stride(from: 0, to: boxes.count, by: perPage).map { Array($0..<min($0 + perPage, boxes.count)) }
        let k = pages.map { bestScale($0.map { boxes[$0] }, width: width, height: height) }.min() ?? 0
        return (pages, k)
    }

    /// Where each window goes, in input order. Pages hold the same number of windows (the last fewer).
    static func layout(_ items: [Item], in size: CGSize) -> [Placement] {
        guard !items.isEmpty else { return [] }
        let width = max(Double(size.width) - 2 * margin, 1), height = max(Double(size.height) - 2 * margin, 1)
        let boxes = normalized(items)
        let smallest = boxes.map { min($0.w, $0.h) }.min() ?? 1
        func tappable(_ perPage: Int) -> Bool { paging(boxes, perPage: perPage, width: width, height: height).scale * smallest >= minimumSide - 1e-9 }
        // The most windows a page can hold with every window at least `minimumSide` (fewer per page
        // never makes windows smaller, so bisect).
        var lo = 1, hi = items.count
        if tappable(hi) { lo = hi } else {
            while hi - lo > 1 { let mid = (lo + hi) / 2; if tappable(mid) { lo = mid } else { hi = mid } }
        }
        let (pages, k) = paging(boxes, perPage: lo, width: width, height: height)
        var out = [Placement](repeating: Placement(page: 0, rect: .zero), count: items.count)
        for (page, members) in pages.enumerated() {
            let pageBoxes = members.map { boxes[$0] }
            let r = rows(pageBoxes, scale: k, width: width)
            let heights = r.map { $0.map { pageBoxes[$0].h * k }.max() ?? 0 }
            let total = heights.reduce(0, +) + spacing * Double(max(r.count - 1, 0))
            var y = margin + (height - total) / 2
            for (row, rowHeight) in zip(r, heights) {
                let rowWidth = row.reduce(0.0) { $0 + pageBoxes[$1].w * k } + spacing * Double(max(row.count - 1, 0))
                var x = margin + (width - rowWidth) / 2
                for i in row {
                    let w = pageBoxes[i].w * k, h = pageBoxes[i].h * k
                    out[members[i]] = Placement(page: page, rect: CGRect(x: x, y: y + (rowHeight - h) / 2, width: w, height: h))
                    x += w + spacing
                }
                y += rowHeight + spacing
            }
        }
        return out
    }
}
