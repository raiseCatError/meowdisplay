// iPad-only control presentation: Strip / Overlay edge geometry, control
// scale, rail composition and palette placement.
// CoreGraphics + Foundation only, so the hostless Mac test target covers
// all of it (see MacTests/PadControlLayoutTests.swift). The iPhone keeps
// `ControlTrayGeometry` and never reads anything here.

import CoreGraphics
import Foundation

/// The iPad `Control Layout` setting.
enum PadControlLayoutMode: String, Codable, CaseIterable, Identifiable {
    /// A solid edge rail; the Mac canvas fits beside it.
    case strip
    /// Controls float over a full-screen Mac canvas.
    case overlay
    /// The active user-built layout — see `CustomControlLayout`.
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .strip: return String(localized: "Strip", comment: "iPad control layout: an edge rail beside the Mac display.")
        case .overlay: return String(localized: "Overlay", comment: "iPad control layout: controls float over the Mac display.")
        case .custom: return String(localized: "Custom", comment: "iPad control layout: a user-built layout.")
        }
    }
}

/// A screen edge for the iPad Main or Function controls.
enum ControlEdge: String, Codable, CaseIterable, Identifiable {
    case leading
    case trailing
    case top
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leading: return String(localized: "Left")
        case .trailing: return String(localized: "Right")
        case .top: return String(localized: "Top")
        case .bottom: return String(localized: "Bottom")
        }
    }

    /// Controls along a left/right edge stack vertically.
    var stacksVertically: Bool { self == .leading || self == .trailing }
}

/// Bounded iPad `Control Size`. The floor keeps a control's hit target
/// (`PadControlMetrics.baseItem` × scale, plus touch slack) around 40 pt;
/// the ceiling keeps a full Main cluster on a portrait 11" edge.
enum PadControlScale {
    static let range: ClosedRange<Double> = 0.85...1.4
    static let defaultValue = 1.0

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

/// Point sizes for one scale/hints combination.
struct PadControlMetrics: Equatable {
    static let baseItem: CGFloat = 44
    static let baseGap: CGFloat = 8
    static let baseGroupGap: CGFloat = 20
    static let hintHeight: CGFloat = 12
    static let hintWidthAllowance: CGFloat = 18
    static let stripPadding: CGFloat = 10
    static let edgeMargin: CGFloat = 12

    let scale: CGFloat
    let showsHints: Bool

    init(scale: Double = PadControlScale.defaultValue, showsHints: Bool = false) {
        self.scale = CGFloat(PadControlScale.clamped(scale))
        self.showsHints = showsHints
    }

    var item: CGFloat { (Self.baseItem * scale).rounded() }
    var gap: CGFloat { Self.baseGap * scale }
    var groupGap: CGFloat { Self.baseGroupGap * scale }

    /// One control's footprint: its circle, plus a caption line below it
    /// (and room for the caption's width) while hints show.
    var cell: CGSize {
        showsHints
            ? CGSize(width: item + Self.hintWidthAllowance, height: item + Self.hintHeight + 2)
            : CGSize(width: item, height: item)
    }

    /// Cross-edge thickness of a cluster on `edge`.
    func clusterThickness(on edge: ControlEdge) -> CGFloat {
        edge.stacksVertically ? cell.width : cell.height
    }

    /// Along-edge length of `count` controls.
    func clusterLength(count: Int, on edge: ControlEdge) -> CGFloat {
        guard count > 0 else { return 0 }
        let along = edge.stacksVertically ? cell.height : cell.width
        return CGFloat(count) * along + CGFloat(count - 1) * gap
    }

    func clusterSize(count: Int, on edge: ControlEdge) -> CGSize {
        let along = clusterLength(count: count, on: edge)
        let thickness = clusterThickness(on: edge)
        return edge.stacksVertically
            ? CGSize(width: thickness, height: along)
            : CGSize(width: along, height: thickness)
    }

    /// The Strip rail's thickness before any safe-area inset on its edge.
    func stripThickness(on edge: ControlEdge) -> CGFloat {
        clusterThickness(on: edge) + Self.stripPadding * 2
    }
}

struct PadStrip: Equatable {
    var edge: ControlEdge
    /// The solid rail, including the part under the edge's safe-area inset.
    var frame: CGRect
}

/// One placed run of controls: a whole group, or the part of one that had
/// to continue in another lane.
struct PadSegment: Equatable {
    var group: Int
    var cells: [CGRect]
    var frame: CGRect {
        cells.dropFirst().reduce(cells.first ?? .null) { $0.union($1) }
    }
}

/// One Strip/Overlay layout pass.
struct PadEdgeLayout: Equatable {
    /// Where the Mac display is presented: the container minus any Strip
    /// rails in Strip mode, the whole container in Overlay.
    var canvas: CGRect
    var strips: [PadStrip]
    var mainSegments: [PadSegment]
    var functionSegments: [PadSegment]
    /// Lanes per used edge (more than one only when an edge overflows).
    var laneCounts: [ControlEdge: Int]

    /// Main control cells, in item order.
    var mainCells: [CGRect] { mainSegments.flatMap(\.cells) }
    /// Function control cells, in item order.
    var functionCells: [CGRect] { functionSegments.flatMap(\.cells) }
    var mainFrame: CGRect? {
        let frames = mainSegments.map(\.frame)
        return frames.isEmpty ? nil : frames.dropFirst().reduce(frames[0]) { $0.union($1) }
    }

    static let empty = PadEdgeLayout(canvas: .zero, strips: [], mainSegments: [], functionSegments: [],
                                     laneCounts: [:])
}

enum PadEdgeGeometry {
    /// The iPad Strip/Overlay layout, as lanes of control groups along each
    /// used edge.
    ///
    /// - Main groups (system, keys, view — see `PadRailComposition`) keep
    ///   their order with a group gap between them and sit centered on
    ///   their edge.
    /// - Function groups split in two: the first half toward the start of
    ///   their edge (top, or left), the rest toward the end.
    /// - On a shared edge, Function groups take the two ends and the Main
    ///   run shifts off center as far as needed to clear them.
    /// - Nothing ever overlaps. When an edge can't hold everything in one
    ///   lane, the overflow moves to the next lane inward, deterministically:
    ///   Main groups wrap at group boundaries (a group longer than the edge
    ///   wraps at the last control that fits), and Function groups that
    ///   don't fit beside the Main run get a lane of their own. A Strip
    ///   widens to hold every lane.
    ///
    /// - Parameter keyboardTop: the docked software keyboard's top edge in
    ///   `container` coordinates, if one is open. Bottom lanes rise above it
    ///   and side lanes stop short of it; Strip rails don't move.
    static func layout(container: CGRect,
                       safeInsets: ControlSafeInsets,
                       reservesStrips: Bool,
                       mainEdge: ControlEdge,
                       functionEdge: ControlEdge,
                       mainGroupCounts: [Int],
                       mainGroupAlignments: [PadGroupAlignment] = [],
                       functionGroupCounts: [Int],
                       metrics: PadControlMetrics,
                       keyboardTop: CGFloat? = nil) -> PadEdgeLayout {
        guard container.width > 0, container.height > 0 else {
            return PadEdgeLayout(canvas: container, strips: [], mainSegments: [], functionSegments: [], laneCounts: [:])
        }
        let mainAlignments = mainGroupCounts.indices.filter { mainGroupCounts[$0] > 0 }.map {
            $0 < mainGroupAlignments.count ? mainGroupAlignments[$0] : PadGroupAlignment.center
        }
        let main = mainGroupCounts.filter { $0 > 0 }
        let function = functionGroupCounts.filter { $0 > 0 }
        var usedEdges: [ControlEdge] = []
        if !main.isEmpty { usedEdges.append(mainEdge) }
        if !function.isEmpty, !usedEdges.contains(functionEdge) { usedEdges.append(functionEdge) }

        // Rails depend on the lanes of perpendicular edges and vice versa;
        // settle lane counts with a few deterministic passes.
        var lanes = Dictionary(uniqueKeysWithValues: usedEdges.map { ($0, 1) })
        var packed: [ControlEdge: [PlacedBlock]] = [:]
        for _ in 0..<4 {
            var next: [ControlEdge: Int] = [:]
            for edge in usedEdges {
                let range = alongRange(edge: edge, container: container, safeInsets: safeInsets,
                                       reservesStrips: reservesStrips, lanes: lanes, metrics: metrics,
                                       keyboardTop: keyboardTop)
                let blocks = pack(length: range.upperBound - range.lowerBound, edge: edge, metrics: metrics,
                                  main: edge == mainEdge ? main : [], alignments: mainAlignments,
                                  function: edge == functionEdge ? function : [])
                packed[edge] = blocks
                next[edge] = max(1, (blocks.map(\.lane).max() ?? 0) + 1)
            }
            if next == lanes { break }
            lanes = next
        }

        let strips = reservesStrips
            ? stripFrames(container: container, safeInsets: safeInsets, lanes: lanes, metrics: metrics)
            : []
        var mainSegments: [PadSegment] = []
        var functionSegments: [PadSegment] = []
        for edge in usedEdges {
            let range = alongRange(edge: edge, container: container, safeInsets: safeInsets,
                                   reservesStrips: reservesStrips, lanes: lanes, metrics: metrics,
                                   keyboardTop: keyboardTop)
            for block in packed[edge] ?? [] {
                let cross = laneCenter(edge: edge, lane: block.lane, container: container, safeInsets: safeInsets,
                                       reservesStrips: reservesStrips, metrics: metrics, keyboardTop: keyboardTop)
                let cells = (0..<block.count).map { index -> CGRect in
                    let along = range.lowerBound + block.start
                        + CGFloat(index) * ((edge.stacksVertically ? metrics.cell.height : metrics.cell.width) + metrics.gap)
                    return edge.stacksVertically
                        ? CGRect(x: cross - metrics.cell.width / 2, y: along,
                                 width: metrics.cell.width, height: metrics.cell.height)
                        : CGRect(x: along, y: cross - metrics.cell.height / 2,
                                 width: metrics.cell.width, height: metrics.cell.height)
                }
                let segment = PadSegment(group: block.group, cells: cells)
                if block.isMain { mainSegments.append(segment) } else { functionSegments.append(segment) }
            }
        }
        // Item order: by group, then by the order the runs were placed.
        mainSegments = mainSegments.enumerated().sorted { ($0.element.group, $0.offset) < ($1.element.group, $1.offset) }
            .map(\.element)
        functionSegments = functionSegments.enumerated()
            .sorted { ($0.element.group, $0.offset) < ($1.element.group, $1.offset) }.map(\.element)
        return PadEdgeLayout(canvas: canvasRect(container: container, strips: strips), strips: strips,
                             mainSegments: mainSegments, functionSegments: functionSegments, laneCounts: lanes)
    }

    /// Where a palette opens: beyond everything on the Main edge.
    static func paletteAnchor(for layout: PadEdgeLayout, mainEdge: ControlEdge, functionEdge: ControlEdge) -> CGRect? {
        let frames = layout.mainSegments.map(\.frame)
            + (functionEdge == mainEdge ? layout.functionSegments.map(\.frame) : [])
        return frames.isEmpty ? nil : frames.dropFirst().reduce(frames[0]) { $0.union($1) }
    }

    // MARK: Packing

    private struct PlacedBlock {
        var isMain: Bool
        var group: Int
        var count: Int
        var lane: Int
        /// Along-edge offset from the start of the rail.
        var start: CGFloat
    }

    private struct Run {
        var isMain: Bool
        var group: Int
        var count: Int
    }

    /// Packs Main and Function runs into lanes along a rail `length` long.
    ///
    /// Lane 0 reads, from the rail's start: start-aligned Main groups, the
    /// first half of the Function groups, the centered Main groups, the
    /// other Function half, and the end-aligned Main groups (e.g. Settings
    /// last). What doesn't fit moves inward, Function first.
    private static func pack(length: CGFloat, edge: ControlEdge, metrics: PadControlMetrics,
                             main: [Int], alignments: [PadGroupAlignment], function: [Int]) -> [PlacedBlock] {
        guard length > 0 else { return [] }
        let along = edge.stacksVertically ? metrics.cell.height : metrics.cell.width
        let perLane = max(1, Int((length + metrics.gap) / (along + metrics.gap)))
        let gap = metrics.groupGap
        func runLength(_ run: Run) -> CGFloat { metrics.clusterLength(count: run.count, on: edge) }
        func span(_ runs: [Run]) -> CGFloat {
            runs.isEmpty ? 0 : runs.map(runLength).reduce(0, +) + CGFloat(runs.count - 1) * gap
        }
        func chunks(_ counts: [Int], isMain: Bool, groupOffset: Int = 0) -> [Run] {
            counts.enumerated().flatMap { index, count -> [Run] in
                stride(from: 0, to: count, by: perLane).map {
                    Run(isMain: isMain, group: groupOffset + index, count: min(perLane, count - $0))
                }
            }
        }
        // Greedy lanes, in order, never splitting a run.
        func lanesOf(_ runs: [Run]) -> [[Run]] {
            var lanes: [[Run]] = []
            for run in runs {
                if let last = lanes.last, span(last) + gap + runLength(run) <= length + 0.001 {
                    lanes[lanes.count - 1].append(run)
                } else {
                    lanes.append([run])
                }
            }
            return lanes
        }
        func placed(_ runs: [Run], lane: Int, from start: CGFloat) -> [PlacedBlock] {
            var cursor = start
            return runs.map { run in
                defer { cursor += runLength(run) + gap }
                return PlacedBlock(isMain: run.isMain, group: run.group, count: run.count, lane: lane, start: cursor)
            }
        }
        func joined(_ parts: [[Run]]) -> [Run] { parts.flatMap { $0 } }
        /// Places head at the start, tail at the end, and middle centered
        /// between them; `false` if they don't fit.
        func fits(head: [Run], middle: [Run], tail: [Run]) -> Bool {
            let pieces = [head, middle, tail].filter { !$0.isEmpty }
            return pieces.map(span).reduce(0, +) + CGFloat(max(0, pieces.count - 1)) * gap <= length + 0.001
        }
        func place(head: [Run], middle: [Run], tail: [Run], lane: Int) -> [PlacedBlock] {
            let headSpan = span(head)
            let tailSpan = span(tail)
            let middleSpan = span(middle)
            let lower = head.isEmpty ? 0 : headSpan + gap
            let upper = length - middleSpan - (tail.isEmpty ? 0 : tailSpan + gap)
            let centered = (length - middleSpan) / 2
            return placed(head, lane: lane, from: 0)
                + placed(middle, lane: lane, from: min(max(centered, lower), max(lower, upper)))
                + placed(tail, lane: lane, from: length - tailSpan)
        }

        let mainRuns = chunks(main, isMain: true)
        let alignment = { (run: Run) -> PadGroupAlignment in
            run.group < alignments.count ? alignments[run.group] : .center
        }
        let mainStart = mainRuns.filter { alignment($0) == .start }
        let mainCenter = mainRuns.filter { alignment($0) == .center }
        let mainEnd = mainRuns.filter { alignment($0) == .end }
        let startCount = (function.count + 1) / 2
        let startRuns = chunks(Array(function.prefix(startCount)), isMain: false)
        let endRuns = chunks(Array(function.dropFirst(startCount)), isMain: false, groupOffset: startCount)

        if fits(head: mainStart + startRuns, middle: mainCenter, tail: endRuns + mainEnd) {
            return place(head: mainStart + startRuns, middle: mainCenter, tail: endRuns + mainEnd, lane: 0)
        }
        var result: [PlacedBlock] = []
        var nextLane = 0
        if !mainRuns.isEmpty {
            if fits(head: mainStart, middle: mainCenter, tail: mainEnd) {
                result = place(head: mainStart, middle: mainCenter, tail: mainEnd, lane: 0)
                nextLane = 1
            } else if !mainCenter.isEmpty, fits(head: mainStart, middle: [], tail: mainEnd) {
                // Anchored groups keep the outer lane's ends (system actions
                // first, Settings last); the centered groups move inward.
                result = place(head: mainStart, middle: [], tail: mainEnd, lane: 0)
                let lanes = lanesOf(mainCenter)
                for (offset, runs) in lanes.enumerated() {
                    result += placed(runs, lane: 1 + offset, from: (length - span(runs)) / 2)
                }
                nextLane = 1 + lanes.count
            } else {
                let lanes = lanesOf(joined([mainStart, mainCenter, mainEnd]))
                for (lane, runs) in lanes.enumerated() {
                    result += placed(runs, lane: lane, from: (length - span(runs)) / 2)
                }
                nextLane = lanes.count
            }
        }
        if !function.isEmpty {
            // Lanes of their own: ends first, then plain wrapping.
            if fits(head: startRuns, middle: [], tail: endRuns) {
                result += place(head: startRuns, middle: [], tail: endRuns, lane: nextLane)
            } else {
                for (offset, runs) in lanesOf(startRuns + endRuns).enumerated() {
                    result += placed(runs, lane: nextLane + offset, from: 0)
                }
            }
        }
        return result
    }

    // MARK: Rails and lanes

    private static func laneThickness(edge: ControlEdge, lanes: Int, metrics: PadControlMetrics) -> CGFloat {
        let one = metrics.clusterThickness(on: edge)
        return CGFloat(lanes) * one + CGFloat(max(0, lanes - 1)) * metrics.gap
    }

    /// The along-edge range controls may occupy on `edge`.
    private static func alongRange(edge: ControlEdge, container: CGRect, safeInsets: ControlSafeInsets,
                                   reservesStrips: Bool, lanes: [ControlEdge: Int], metrics: PadControlMetrics,
                                   keyboardTop: CGFloat?) -> ClosedRange<CGFloat> {
        let margin = PadControlMetrics.edgeMargin
        func band(_ other: ControlEdge) -> CGFloat {
            guard let count = lanes[other] else { return 0 }
            return reservesStrips
                ? laneThickness(edge: other, lanes: count, metrics: metrics) + PadControlMetrics.stripPadding * 2
                    + inset(safeInsets, other)
                : laneThickness(edge: other, lanes: count, metrics: metrics) + metrics.gap
        }
        var lower: CGFloat
        var upper: CGFloat
        if edge.stacksVertically {
            lower = container.minY + safeInsets.top + margin
            upper = container.maxY - safeInsets.bottom - margin
            if !reservesStrips {
                // Clear the corners any top/bottom lanes occupy.
                lower += band(.top)
                upper -= band(.bottom)
            }
            if let keyboardTop, keyboardTop.isFinite { upper = min(upper, keyboardTop - margin) }
        } else {
            lower = container.minX + safeInsets.leading + margin
            upper = container.maxX - safeInsets.trailing - margin
            if reservesStrips {
                // Top/bottom strips run between the side strips.
                if lanes[.leading] != nil { lower = max(lower, container.minX + band(.leading) + margin) }
                if lanes[.trailing] != nil { upper = min(upper, container.maxX - band(.trailing) - margin) }
            } else {
                lower += band(.leading)
                upper -= band(.trailing)
            }
        }
        return lower...max(lower, upper)
    }

    /// Cross-edge center of `lane` (0 = outermost).
    private static func laneCenter(edge: ControlEdge, lane: Int, container: CGRect, safeInsets: ControlSafeInsets,
                                   reservesStrips: Bool, metrics: PadControlMetrics, keyboardTop: CGFloat?) -> CGFloat {
        let one = metrics.clusterThickness(on: edge)
        let offset = (reservesStrips ? PadControlMetrics.stripPadding : PadControlMetrics.edgeMargin)
            + CGFloat(lane) * (one + metrics.gap) + one / 2
        switch edge {
        case .leading: return container.minX + safeInsets.leading + offset
        case .trailing: return container.maxX - safeInsets.trailing - offset
        case .top: return container.minY + safeInsets.top + offset
        case .bottom:
            var outer = container.maxY - safeInsets.bottom
            if let keyboardTop, keyboardTop.isFinite {
                outer = min(outer, keyboardTop)
            }
            return outer - offset
        }
    }

    /// Strip rails for the used edges. Left/right rails run the full height;
    /// top/bottom rails run between them. Each includes its edge's safe inset
    /// and is as thick as its lanes need.
    static func stripFrames(container: CGRect, safeInsets: ControlSafeInsets,
                            lanes: [ControlEdge: Int], metrics: PadControlMetrics) -> [PadStrip] {
        func thickness(_ edge: ControlEdge) -> CGFloat {
            laneThickness(edge: edge, lanes: lanes[edge] ?? 1, metrics: metrics)
                + PadControlMetrics.stripPadding * 2 + inset(safeInsets, edge)
        }
        let leading = lanes[.leading] != nil ? thickness(.leading) : 0
        let trailing = lanes[.trailing] != nil ? thickness(.trailing) : 0
        return ControlEdge.allCases.filter { lanes[$0] != nil }.map { edge in
            let t = thickness(edge)
            let frame: CGRect
            switch edge {
            case .leading:
                frame = CGRect(x: container.minX, y: container.minY, width: t, height: container.height)
            case .trailing:
                frame = CGRect(x: container.maxX - t, y: container.minY, width: t, height: container.height)
            case .top:
                frame = CGRect(x: container.minX + leading, y: container.minY,
                               width: max(0, container.width - leading - trailing), height: t)
            case .bottom:
                frame = CGRect(x: container.minX + leading, y: container.maxY - t,
                               width: max(0, container.width - leading - trailing), height: t)
            }
            return PadStrip(edge: edge, frame: frame)
        }
    }

    static func canvasRect(container: CGRect, strips: [PadStrip]) -> CGRect {
        var canvas = container
        for strip in strips {
            switch strip.edge {
            case .leading:
                canvas = CGRect(x: strip.frame.maxX, y: canvas.minY,
                                width: max(0, canvas.maxX - strip.frame.maxX), height: canvas.height)
            case .trailing:
                canvas.size.width = max(0, strip.frame.minX - canvas.minX)
            case .top:
                canvas = CGRect(x: canvas.minX, y: strip.frame.maxY,
                                width: canvas.width, height: max(0, canvas.maxY - strip.frame.maxY))
            case .bottom:
                canvas.size.height = max(0, strip.frame.minY - canvas.minY)
            }
        }
        return canvas
    }

    /// Where a palette opens beside the Main cluster: toward the canvas,
    /// centered on `anchor` along the edge, and kept inside `bounds`.
    static func paletteFrame(size: CGSize, anchor: CGRect, edge: ControlEdge,
                             bounds: CGRect, gap: CGFloat) -> CGRect {
        var frame: CGRect
        switch edge {
        case .leading:
            frame = CGRect(x: anchor.maxX + gap, y: anchor.midY - size.height / 2,
                           width: size.width, height: size.height)
        case .trailing:
            frame = CGRect(x: anchor.minX - gap - size.width, y: anchor.midY - size.height / 2,
                           width: size.width, height: size.height)
        case .top:
            frame = CGRect(x: anchor.midX - size.width / 2, y: anchor.maxY + gap,
                           width: size.width, height: size.height)
        case .bottom:
            frame = CGRect(x: anchor.midX - size.width / 2, y: anchor.minY - gap - size.height,
                           width: size.width, height: size.height)
        }
        return clamped(frame, into: bounds)
    }

    /// Rows and columns for `count` palette keys laid along `edge`,
    /// wrapping into more lines once one line would leave `available`.
    static func paletteGrid(count: Int, key: CGSize, gap: CGFloat, edge: ControlEdge,
                            available: CGSize) -> (rows: Int, columns: Int, size: CGSize) {
        let n = max(count, 1)
        let perLine: Int
        if edge.stacksVertically {
            perLine = max(1, Int((available.height + gap) / (key.height + gap)))
        } else {
            perLine = max(1, Int((available.width + gap) / (key.width + gap)))
        }
        let lines = Int(ceil(Double(n) / Double(perLine)))
        let inLine = min(n, perLine)
        let rows = edge.stacksVertically ? inLine : lines
        let columns = edge.stacksVertically ? lines : inLine
        let size = CGSize(width: CGFloat(columns) * key.width + CGFloat(columns - 1) * gap,
                          height: CGFloat(rows) * key.height + CGFloat(rows - 1) * gap)
        return (rows, columns, size)
    }

    /// Each control's cell inside a cluster frame, in order along `edge`.
    static func cellFrames(in cluster: CGRect, count: Int, edge: ControlEdge,
                           metrics: PadControlMetrics) -> [CGRect] {
        guard count > 0 else { return [] }
        let cell = metrics.cell
        return (0..<count).map { index in
            let offset = CGFloat(index) * ((edge.stacksVertically ? cell.height : cell.width) + metrics.gap)
            return edge.stacksVertically
                ? CGRect(x: cluster.midX - cell.width / 2, y: cluster.minY + offset,
                         width: cell.width, height: cell.height)
                : CGRect(x: cluster.minX + offset, y: cluster.midY - cell.height / 2,
                         width: cell.width, height: cell.height)
        }
    }

    /// The span of a segment's control circles (captions excluded).
    static func circleRun(of segment: PadSegment, metrics: PadControlMetrics) -> CGRect {
        segment.cells.map { circleFrame(inCell: $0, metrics: metrics) }.reduce(CGRect.null) { $0.union($1) }
    }

    /// The control circle within a cell (its caption, if any, sits below).
    static func circleFrame(inCell cell: CGRect, metrics: PadControlMetrics) -> CGRect {
        CGRect(x: cell.midX - metrics.item / 2, y: cell.minY, width: metrics.item, height: metrics.item)
    }

    // MARK: - Helpers

    private static func inset(_ insets: ControlSafeInsets, _ edge: ControlEdge) -> CGFloat {
        switch edge {
        case .leading: return insets.leading
        case .trailing: return insets.trailing
        case .top: return insets.top
        case .bottom: return insets.bottom
        }
    }

    /// Shifts `frame` inside `bounds` (centering it on any axis where it is
    /// larger), never resizing it.
    static func clamped(_ frame: CGRect, into bounds: CGRect) -> CGRect {
        func axis(_ origin: CGFloat, _ length: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
            if length >= upper - lower { return lower + (upper - lower - length) / 2 }
            return min(max(origin, lower), upper - length)
        }
        return CGRect(x: axis(frame.minX, frame.width, bounds.minX, bounds.maxX),
                      y: axis(frame.minY, frame.height, bounds.minY, bounds.maxY),
                      width: frame.width, height: frame.height)
    }
}

/// Auto-hide never applies to the iPad Strip: its rail is reserved space,
/// and fading the controls would leave an empty black band.
enum ControlAutoHidePolicy {
    static func applies(isPad: Bool, layout: PadControlLayoutMode) -> Bool {
        !(isPad && layout == .strip)
    }
}

// MARK: - Standard rail controls

/// The standard system and utility controls the iPad Strip/Overlay rail can
/// show, each independently. Modifiers come from the Control Profile, and
/// Settings is permanent, so neither is listed here.
enum PadStandardControl: String, Codable, CaseIterable, Identifiable {
    case menuBar
    case dock
    case showDesktop
    case controlCenter
    case escape
    case tab
    case keyboard
    case moveView

    var id: String { rawValue }

    var title: String {
        switch self {
        case .menuBar: return String(localized: "Menu Bar")
        case .dock: return String(localized: "Dock")
        case .showDesktop: return String(localized: "Show Desktop")
        case .controlCenter: return String(localized: "Control Center")
        case .escape: return String(localized: "Escape")
        case .tab: return String(localized: "Tab")
        case .keyboard: return String(localized: "Keyboard")
        case .moveView: return String(localized: "Move View")
        }
    }

    static let systemKinds: Set<CustomControlKind> = [
        PadStandardControl.menuBar.kind, PadStandardControl.dock.kind,
        PadStandardControl.showDesktop.kind, PadStandardControl.controlCenter.kind,
    ]

    /// The existing control this entry shows. Dock, Escape, Tab and Keyboard
    /// are Main tray items; Show Desktop and Control Center are the Function
    /// Tray's semantic `ReceiverGesture` actions — one action system.
    var kind: CustomControlKind {
        switch self {
        case .menuBar: return .function("menu-bar")
        case .dock: return .tray(.dock)
        case .showDesktop: return .function("show-desktop")
        case .controlCenter: return .function("control-center")
        case .escape: return .tray(.escape)
        case .tab: return .tray(.tab)
        case .keyboard: return .tray(.keyboard)
        case .moveView: return .moveView
        }
    }
}

/// Which standard controls show. Stores the *hidden* set, so a control
/// added by a later build appears by default, and decodes lossily.
struct PadStandardControlVisibility: Codable, Equatable {
    private(set) var hidden: Set<PadStandardControl> = []

    init(hidden: Set<PadStandardControl> = []) { self.hidden = hidden }

    func isVisible(_ control: PadStandardControl) -> Bool { !hidden.contains(control) }

    mutating func setVisible(_ visible: Bool, _ control: PadStandardControl) {
        if visible { hidden.remove(control) } else { hidden.insert(control) }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String].self)
        hidden = Set(raw.compactMap(PadStandardControl.init(rawValue:)))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(PadStandardControl.allCases.filter(hidden.contains).map(\.rawValue))
    }
}

/// Where a Main group sits along its rail.
enum PadGroupAlignment: Equatable {
    /// At the rail's start (the top of a side rail).
    case start
    case center
    /// At the rail's end (the bottom of a side rail).
    case end
}

/// The Strip/Overlay Main rail, as visually separate groups in a fixed,
/// Sidecar-like order: system actions at the rail's start (top-right by
/// default), modifiers and keys centered, and view controls with the
/// permanent Settings gear at the rail's end (bottom-right by default).
/// Empty groups vanish; Settings keeps the last group from ever being empty.
enum PadRailComposition {
    /// Alignment for each of `mainGroups`' groups, in the same order.
    static func alignments(for groups: [[CustomControlKind]]) -> [PadGroupAlignment] {
        groups.map { group in
            if group.contains(.tray(.settings)) { return .end }
            if group.contains(where: { PadStandardControl.systemKinds.contains($0) }) { return .start }
            return .center
        }
    }

    struct Availability: Equatable {
        /// Visible modifiers from the active Control Profile (the Mac must
        /// also understand receiver controls).
        var modifiers: [ControlModifier]
        var keyboardAvailable: Bool
        /// Move View needs live video and Local View Navigation.
        var moveViewAvailable: Bool
    }

    static func mainGroups(visibility: PadStandardControlVisibility,
                           availability: Availability) -> [[CustomControlKind]] {
        func shown(_ control: PadStandardControl) -> Bool {
            guard visibility.isVisible(control) else { return false }
            switch control {
            case .keyboard: return availability.keyboardAvailable
            case .moveView: return availability.moveViewAvailable
            default: return true
            }
        }
        let system = [PadStandardControl.menuBar, .dock, .showDesktop, .controlCenter].filter(shown).map(\.kind)
        let keys = availability.modifiers.map { CustomControlKind.tray(ControlTrayItem.item(for: $0)) }
            + [PadStandardControl.escape, .tab, .keyboard].filter(shown).map(\.kind)
        let view = [PadStandardControl.moveView].filter(shown).map(\.kind) + [.tray(.settings)]
        return [system, keys, view].filter { !$0.isEmpty }
    }
}

extension ControlTrayItem {
    static func item(for modifier: ControlModifier) -> ControlTrayItem {
        switch modifier {
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        }
    }
}
