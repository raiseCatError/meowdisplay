// iPad-only control presentation: Strip / Overlay edge geometry, control
// scale, palette placement, and the display-overlap backdrop policy.
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

/// One Strip/Overlay layout pass.
struct PadEdgeLayout: Equatable {
    /// Where the Mac display is presented: the container minus any Strip
    /// rails in Strip mode, the whole container in Overlay.
    var canvas: CGRect
    var strips: [PadStrip]
    /// `nil` when no Main controls show.
    var mainFrame: CGRect?
    /// One frame per Function group, in group order.
    var functionFrames: [CGRect]
}

enum PadEdgeGeometry {
    /// The iPad Strip/Overlay layout. Main controls are centered along
    /// their edge and grow outward from the center. Function groups split
    /// in two: the first half toward the start of their edge (top, or
    /// left), the rest toward the end (bottom, or right). On the Main edge
    /// they continue outward from the Main cluster; on any other edge they
    /// sit at that edge's two ends.
    ///
    /// - Parameter keyboardTop: the docked software keyboard's top edge in
    ///   `container` coordinates, if one is open. Bottom controls rise above
    ///   it and side controls stop short of it; Strip rails don't move, so
    ///   the canvas never jumps while typing.
    static func layout(container: CGRect,
                       safeInsets: ControlSafeInsets,
                       reservesStrips: Bool,
                       mainEdge: ControlEdge,
                       functionEdge: ControlEdge,
                       mainCount: Int,
                       functionGroupCounts: [Int],
                       metrics: PadControlMetrics,
                       keyboardTop: CGFloat? = nil) -> PadEdgeLayout {
        guard container.width > 0, container.height > 0 else {
            return PadEdgeLayout(canvas: container, strips: [], mainFrame: nil, functionFrames: [])
        }
        let groups = functionGroupCounts.filter { $0 > 0 }
        var usedEdges: [ControlEdge] = []
        if mainCount > 0 { usedEdges.append(mainEdge) }
        if !groups.isEmpty, !usedEdges.contains(functionEdge) { usedEdges.append(functionEdge) }

        let strips = reservesStrips
            ? stripFrames(container: container, safeInsets: safeInsets, edges: usedEdges, metrics: metrics)
            : []
        let canvas = canvasRect(container: container, strips: strips)

        func rail(for edge: ControlEdge) -> CGRect {
            var rail = railRect(edge: edge, container: container, safeInsets: safeInsets,
                                strip: strips.first { $0.edge == edge }, metrics: metrics)
            // Keep a corner shared with another used edge for that edge.
            for other in usedEdges where other != edge && other.stacksVertically != edge.stacksVertically {
                let clearance = metrics.clusterThickness(on: other) + metrics.gap
                switch other {
                case .leading: rail = trimStart(rail, by: clearance, vertical: false)
                case .trailing: rail = trimEnd(rail, by: clearance, vertical: false)
                case .top: rail = trimStart(rail, by: clearance, vertical: true)
                case .bottom: rail = trimEnd(rail, by: clearance, vertical: true)
                }
            }
            return avoidingKeyboard(rail, edge: edge, keyboardTop: keyboardTop, metrics: metrics)
        }

        var mainFrame: CGRect?
        if mainCount > 0 {
            let mainRail = rail(for: mainEdge)
            let size = metrics.clusterSize(count: mainCount, on: mainEdge)
            mainFrame = clamped(CGRect(x: mainRail.midX - size.width / 2, y: mainRail.midY - size.height / 2,
                                       width: size.width, height: size.height),
                                into: mainRail)
        }

        var functionFrames: [CGRect] = []
        if !groups.isEmpty {
            let functionRail = rail(for: functionEdge)
            let vertical = functionEdge.stacksVertically
            let startCount = (groups.count + 1) / 2
            let startGroups = Array(groups.prefix(startCount))
            let endGroups = Array(groups.dropFirst(startCount))
            let sizes = groups.map { metrics.clusterSize(count: $0, on: functionEdge) }
            func along(_ size: CGSize) -> CGFloat { vertical ? size.height : size.width }
            func frame(start: CGFloat, size: CGSize) -> CGRect {
                vertical
                    ? CGRect(x: functionRail.midX - size.width / 2, y: start, width: size.width, height: size.height)
                    : CGRect(x: start, y: functionRail.midY - size.height / 2, width: size.width, height: size.height)
            }
            var startFrames: [CGRect] = []
            var endFrames: [CGRect] = []
            let railStart = vertical ? functionRail.minY : functionRail.minX
            let railEnd = vertical ? functionRail.maxY : functionRail.maxX
            if let mainFrame, functionEdge == mainEdge {
                var cursor = (vertical ? mainFrame.minY : mainFrame.minX) - metrics.groupGap
                for index in startGroups.indices.reversed() {
                    cursor -= along(sizes[index])
                    startFrames.insert(frame(start: cursor, size: sizes[index]), at: 0)
                    cursor -= metrics.groupGap
                }
                cursor = (vertical ? mainFrame.maxY : mainFrame.maxX) + metrics.groupGap
                for offset in endGroups.indices {
                    let size = sizes[startCount + offset]
                    endFrames.append(frame(start: cursor, size: size))
                    cursor += along(size) + metrics.groupGap
                }
            } else {
                var cursor = railStart
                for index in startGroups.indices {
                    startFrames.append(frame(start: cursor, size: sizes[index]))
                    cursor += along(sizes[index]) + metrics.groupGap
                }
                cursor = railEnd
                for offset in endGroups.indices.reversed() {
                    let size = sizes[startCount + offset]
                    cursor -= along(size)
                    endFrames.insert(frame(start: cursor, size: size), at: 0)
                    cursor -= metrics.groupGap
                }
            }
            functionFrames = (startFrames + endFrames).map { clamped($0, into: functionRail) }
        }

        return PadEdgeLayout(canvas: canvas, strips: strips, mainFrame: mainFrame, functionFrames: functionFrames)
    }

    /// Strip rails for `edges`. Left/right rails run the full height; top/
    /// bottom rails run between them. Each includes its edge's safe inset.
    static func stripFrames(container: CGRect, safeInsets: ControlSafeInsets,
                            edges: [ControlEdge], metrics: PadControlMetrics) -> [PadStrip] {
        func thickness(_ edge: ControlEdge) -> CGFloat {
            metrics.stripThickness(on: edge) + inset(safeInsets, edge)
        }
        let leading = edges.contains(.leading) ? thickness(.leading) : 0
        let trailing = edges.contains(.trailing) ? thickness(.trailing) : 0
        return edges.map { edge in
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

    /// The band a cluster on `edge` is centered in: inside its Strip rail
    /// (clear of the safe inset), or — in Overlay — a margin inside the
    /// safe area.
    private static func railRect(edge: ControlEdge, container: CGRect, safeInsets: ControlSafeInsets,
                                 strip: PadStrip?, metrics: PadControlMetrics) -> CGRect {
        let safe = CGRect(x: container.minX + safeInsets.leading,
                          y: container.minY + safeInsets.top,
                          width: max(0, container.width - safeInsets.leading - safeInsets.trailing),
                          height: max(0, container.height - safeInsets.top - safeInsets.bottom))
        let thickness = metrics.clusterThickness(on: edge)
        let margin = PadControlMetrics.edgeMargin
        if let strip {
            let frame = strip.frame
            switch edge {
            case .leading:
                return CGRect(x: frame.minX + safeInsets.leading, y: safe.minY + margin,
                              width: frame.width - safeInsets.leading, height: max(0, safe.height - margin * 2))
            case .trailing:
                return CGRect(x: frame.minX, y: safe.minY + margin,
                              width: frame.width - safeInsets.trailing, height: max(0, safe.height - margin * 2))
            case .top:
                return CGRect(x: frame.minX + margin, y: frame.minY + safeInsets.top,
                              width: max(0, frame.width - margin * 2), height: frame.height - safeInsets.top)
            case .bottom:
                return CGRect(x: frame.minX + margin, y: frame.minY,
                              width: max(0, frame.width - margin * 2), height: frame.height - safeInsets.bottom)
            }
        }
        let area = safe.insetBy(dx: margin, dy: margin)
        switch edge {
        case .leading: return CGRect(x: area.minX, y: area.minY, width: thickness, height: area.height)
        case .trailing: return CGRect(x: area.maxX - thickness, y: area.minY, width: thickness, height: area.height)
        case .top: return CGRect(x: area.minX, y: area.minY, width: area.width, height: thickness)
        case .bottom: return CGRect(x: area.minX, y: area.maxY - thickness, width: area.width, height: thickness)
        }
    }

    private static func avoidingKeyboard(_ rail: CGRect, edge: ControlEdge, keyboardTop: CGFloat?,
                                         metrics: PadControlMetrics) -> CGRect {
        guard let keyboardTop, keyboardTop.isFinite, keyboardTop < rail.maxY else { return rail }
        let limit = keyboardTop - PadControlMetrics.edgeMargin
        switch edge {
        case .bottom:
            let height = rail.height
            return CGRect(x: rail.minX, y: max(rail.minY - (rail.maxY - limit), 0), width: rail.width, height: height)
        case .leading, .trailing:
            return CGRect(x: rail.minX, y: rail.minY, width: rail.width, height: max(0, limit - rail.minY))
        case .top:
            return rail
        }
    }

    private static func trimStart(_ rect: CGRect, by amount: CGFloat, vertical: Bool) -> CGRect {
        vertical
            ? CGRect(x: rect.minX, y: rect.minY + amount, width: rect.width, height: max(0, rect.height - amount))
            : CGRect(x: rect.minX + amount, y: rect.minY, width: max(0, rect.width - amount), height: rect.height)
    }

    private static func trimEnd(_ rect: CGRect, by amount: CGFloat, vertical: Bool) -> CGRect {
        vertical
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, rect.height - amount))
            : CGRect(x: rect.minX, y: rect.minY, width: max(0, rect.width - amount), height: rect.height)
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

// MARK: - Display-aware control backdrop

/// Where the Mac is actually drawn, in the controls' coordinate space: the
/// receiver surface's live `RemoteViewportTransform` (the same one input
/// mapping uses), the surface's origin in that space, and its size (the
/// video view clips to its bounds).
struct DisplayFootprint: Equatable {
    var transform: RemoteViewportTransform
    var surfaceOrigin: CGPoint
    var surfaceSize: CGSize

    static let none = DisplayFootprint(transform: .invalid, surfaceOrigin: .zero, surfaceSize: .zero)

    func contains(_ point: CGPoint) -> Bool {
        let local = CGPoint(x: point.x - surfaceOrigin.x, y: point.y - surfaceOrigin.y)
        guard local.x >= 0, local.y >= 0, local.x <= surfaceSize.width, local.y <= surfaceSize.height else {
            return false
        }
        return transform.containsViewPoint(local)
    }
}

/// Whether (and how strongly) a floating control gets its small material
/// halo: only where it actually covers rendered Mac content — never over
/// letterboxing, empty canvas, or a Strip rail.
enum ControlBackdropPolicy {
    /// Below this much coverage the halo is skipped entirely.
    static let minimumCoverage: CGFloat = 0.05
    /// Coverage at which the halo reaches full strength.
    static let fullCoverage: CGFloat = 0.5

    /// Fraction of `rect` over the rendered display, sampled on a grid so
    /// rotation and partial overlap need no polygon clipping.
    static func coverage(of rect: CGRect, footprint: DisplayFootprint, samples: Int = 5) -> CGFloat {
        guard rect.width > 0, rect.height > 0, samples > 0, footprint.transform.isValid else { return 0 }
        var inside = 0
        for row in 0..<samples {
            for column in 0..<samples {
                let point = CGPoint(x: rect.minX + (CGFloat(column) + 0.5) / CGFloat(samples) * rect.width,
                                    y: rect.minY + (CGFloat(row) + 0.5) / CGFloat(samples) * rect.height)
                if footprint.contains(point) { inside += 1 }
            }
        }
        return CGFloat(inside) / CGFloat(samples * samples)
    }

    /// Halo strength for a coverage fraction: none below
    /// `minimumCoverage`, then rising linearly to 1 at `fullCoverage`.
    static func haloStrength(coverage: CGFloat) -> Double {
        guard coverage >= minimumCoverage else { return 0 }
        let t = (coverage - minimumCoverage) / (fullCoverage - minimumCoverage)
        return Double(min(max(t, 0), 1))
    }

    static func haloStrength(for rect: CGRect, footprint: DisplayFootprint) -> Double {
        haloStrength(coverage: coverage(of: rect, footprint: footprint))
    }
}

/// Auto-hide never applies to the iPad Strip: its rail is reserved space,
/// and fading the controls would leave an empty black band.
enum ControlAutoHidePolicy {
    static func applies(isPad: Bool, layout: PadControlLayoutMode) -> Bool {
        !(isPad && layout == .strip)
    }
}
