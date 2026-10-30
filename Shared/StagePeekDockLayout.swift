import CoreGraphics

// Stage Peek's apps bar on iPhone and iPad; here so the Mac test suite can check it.

/// How many apps fit in a row of the bar and how many rows it can grow to (pure, tested).
struct StagePeekDockLayout: Equatable {
    static let spacing: CGFloat = 10
    /// Rows of the grown bar (Launchpad-like): wider cells with the app's name under its icon.
    static let gridCell: CGFloat = 68
    static let rowHeight: CGFloat = 78

    let perRow: Int
    let maxRows: Int
    private let total: Int

    init(apps: Int, width: CGFloat, maxHeight: CGFloat) {
        total = apps + 1   // and All Apps
        perRow = max(1, Int((width - 24 + Self.spacing) / (Self.gridCell + Self.spacing)))
        let needed = max(1, (total + perRow - 1) / perRow)
        let room = max(1, Int((maxHeight - 30) / Self.rowHeight))
        maxRows = min(needed, room)
    }

    /// More apps than the rows show: the grid scrolls.
    func needsScroll(rows: Int) -> Bool { total > perRow * rows }

    /// A swipe up that ends at one row, or a quick flick up: back to the compact bar.
    static func collapses(pulled: CGFloat, predicted: CGFloat, rows: Int) -> Bool {
        pulled < -20 && (rows <= 1 || predicted < -Self.rowHeight * 3)
    }

    /// Where the bar rests (owner, 2026-10-31): one row, four rows, then the whole screen.
    var stops: [Int] {
        var s = [1]
        if maxRows > 1 { s.append(min(4, maxRows)) }
        if maxRows > s.last! { s.append(maxRows) }
        return s
    }

    /// The handle: the next stop down, and from the last one back to a single row.
    func nextStop(after rows: Int) -> Int { stops.first { $0 > rows } ?? 1 }

    /// The stop after pulling `pulled` points down (negative: up) from `base` rows: a short
    /// pull moves one stop, a long one two.
    func rows(from base: Int, pulled: CGFloat) -> Int {
        let s = stops
        let i = s.lastIndex { $0 <= base } ?? 0
        let steps = pulled >= 0 ? Int((pulled + 50) / 140) : -Int((-pulled + 50) / 140)
        return s[min(max(i + steps, 0), s.count - 1)]
    }
}
