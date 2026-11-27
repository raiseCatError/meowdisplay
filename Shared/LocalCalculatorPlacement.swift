// Where the receiver's local calculator (`LocalCalculator`) appears: its
// entry button and its panel. CoreGraphics + Foundation only, so the
// geometry is hostless-testable. Nothing here decides what reaches the Mac:
// the calculator never sends anything.

import CoreGraphics
import Foundation

/// When the calculator's entry button and panel show.
enum LocalCalculatorPolicy {
    /// The entry button shows once the person has added it, whatever the
    /// session's input state: View Only, a pending Request Control or a
    /// revoked grant don't gate it, because it never reaches the Mac. It
    /// leaves with the rest of the controls when the tray is collapsed to
    /// Settings, and while the keyboard bar replaces the controls.
    static func showsButton(added: Bool, trayCollapsed: Bool, keyboardBarShown: Bool) -> Bool {
        added && !trayCollapsed && !keyboardBarShown
    }

    /// An open panel stays up (its own Close and the button close it), and
    /// steps aside while the keyboard bar is up, keeping its calculation.
    static func showsPanel(open: Bool, keyboardBarShown: Bool) -> Bool {
        open && !keyboardBarShown
    }
}

/// The panel's size: 4 × 5 round keys under a header (Close, Copy Result)
/// and the display. Keys shrink to fit the space, never below
/// `minimumKey`.
struct LocalCalculatorPanelMetrics: Equatable {
    static let columns = 4
    static let rows = 5
    static let padding: CGFloat = 8
    static let gap: CGFloat = 6
    static let headerHeight: CGFloat = 30
    static let displayHeight: CGFloat = 46
    static let minimumKey: CGFloat = 36
    static let maximumKey: CGFloat = 76

    var key: CGFloat

    var size: CGSize {
        CGSize(width: Self.padding * 2 + CGFloat(Self.columns) * key + CGFloat(Self.columns - 1) * Self.gap,
               height: Self.chromeHeight + CGFloat(Self.rows) * key)
    }

    /// Everything but the keys, vertically.
    static var chromeHeight: CGFloat {
        padding * 2 + headerHeight + gap + displayHeight + gap + CGFloat(rows - 1) * gap
    }

    static var chromeWidth: CGFloat { padding * 2 + CGFloat(columns - 1) * gap }

    /// The largest key up to `preferredKey` that fits `available`.
    static func fitting(_ available: CGSize, preferredKey: CGFloat) -> LocalCalculatorPanelMetrics {
        let byHeight = (available.height - chromeHeight) / CGFloat(rows)
        let byWidth = (available.width - chromeWidth) / CGFloat(columns)
        let preferred = min(max(preferredKey, minimumKey), maximumKey)
        let key = min(preferred, byHeight, byWidth).rounded(.down)
        return LocalCalculatorPanelMetrics(key: max(minimumKey, key.isFinite ? key : minimumKey))
    }
}

enum LocalCalculatorPlacement {
    static let margin: CGFloat = 12
    static let spacing: CGFloat = 10

    /// iPhone (and narrow windows): the entry button beside the controls it
    /// belongs with, so it never takes the top of the screen, where pane
    /// tabs, menus and Stage Peek live (owner QA, 2.2 round 4: in the top-left
    /// corner it pushed the top lane aside). With `tray` (the Main Tray as
    /// drawn), it tries, in order: the ends of the tray's own row (or column),
    /// the spot just inside the tray's end (not the arrow button's end,
    /// `arrowSide`; nil while arrows are hidden), then the ends of each of
    /// `beside` (the Function groups). Without room there, the upper-left
    /// usable region as before: the top-left corner, along the top edge,
    /// then down the left edge. Each spot clears the notch or Dynamic Island
    /// band (with Avoid Notch), system-reserved regions (hinge, camera) and
    /// every frame in `occupied` (the Main Tray, Function groups, an open
    /// palette) by `spacing`. The other controls never move for it.
    static func phoneButtonFrame(container: CGRect, safeInsets: ControlSafeInsets,
                                 keyboardVisibleRect: CGRect?, portrait: Bool,
                                 diameter: CGFloat, occupied: [CGRect], avoidNotch: Bool,
                                 notchSide: LandscapeTraySide? = nil,
                                 reservedRegions: [ControlReservedRegion] = [],
                                 tray: CGRect? = nil, trayHorizontal: Bool = true, beside: [CGRect] = [],
                                 arrowSide: LandscapeTraySide? = nil) -> CGRect {
        var visible = container
        if let keyboardVisibleRect { visible = visible.intersection(keyboardVisibleRect) }
        guard !visible.isNull, !visible.isEmpty, diameter > 0 else { return .zero }
        let bounds = visible.insetBy(dx: margin, dy: margin)
        let size = CGSize(width: diameter, height: diameter)
        let blockers = occupied.filter { !$0.isNull && !$0.isEmpty }
        let obstacles = ControlTrayGeometry.reservedObstacles(reservedRegions, avoidNotch: avoidNotch)
        let xs = ([bounds.minX] + blockers.map { $0.maxX + spacing }).filter { $0 >= bounds.minX }.sorted()
        let ys = ([bounds.minY] + blockers.map { $0.maxY + spacing }).filter { $0 >= bounds.minY }.sorted()
        let nearTrays = trayCandidates(tray: tray, horizontal: trayHorizontal, beside: beside,
                                       diameter: diameter, container: container, arrowSide: arrowSide)
        let candidates: [CGPoint] = nearTrays
            + xs.filter { $0 + diameter <= bounds.midX }.map { CGPoint(x: $0, y: bounds.minY) }
            + ys.map { CGPoint(x: bounds.minX, y: $0) }
            + xs.map { CGPoint(x: $0, y: bounds.minY) }
        func settled(_ origin: CGPoint) -> CGRect {
            let frame = ControlTrayGeometry.avoidingUnsafeRegion(CGRect(origin: origin, size: size), in: container,
                                                                 safeInsets: safeInsets, enabled: avoidNotch,
                                                                 portrait: portrait, notchSide: notchSide)
            return ControlTrayGeometry.avoidingReservedRegions(frame, obstacles: obstacles, within: bounds)
        }
        func isClear(_ frame: CGRect) -> Bool {
            let padded = frame.insetBy(dx: -(spacing - 0.5), dy: -(spacing - 0.5))
            return bounds.contains(frame)
                && !blockers.contains { $0.intersects(padded) }
                && !obstacles.contains { $0.intersects(frame) }
        }
        for origin in candidates {
            let frame = settled(origin)
            if isClear(frame) { return frame }
        }
        return settled(CGPoint(x: bounds.minX, y: bounds.minY))
    }

    /// Spots by the trays, best first (see `phoneButtonFrame`): origins of a
    /// `diameter` button.
    static func trayCandidates(tray: CGRect?, horizontal: Bool, beside: [CGRect], diameter d: CGFloat,
                               container: CGRect, arrowSide: LandscapeTraySide?) -> [CGPoint] {
        let g = spacing
        func ends(_ frame: CGRect) -> [CGPoint] {
            horizontal
                ? [CGPoint(x: frame.maxX + g, y: frame.midY - d / 2), CGPoint(x: frame.minX - g - d, y: frame.midY - d / 2)]
                // Below first: away from the top of the screen.
                : [CGPoint(x: frame.midX - d / 2, y: frame.maxY + g), CGPoint(x: frame.midX - d / 2, y: frame.minY - g - d)]
        }
        let groups = beside.filter { !$0.isNull && !$0.isEmpty }.flatMap(ends)
        // No Main Tray shown (Show Control Tray off): beside the Function groups alone.
        guard let tray, !tray.isNull, !tray.isEmpty else { return groups }
        var spots = horizontal ? ends(tray) : [ends(tray)[0]]
        if horizontal {
            // Just above the row's ends; the arrow button takes its own side's.
            let y = tray.minY - g - d
            let right = CGPoint(x: tray.maxX - d, y: y), left = CGPoint(x: tray.minX, y: y)
            spots += arrowSide == .trailing ? [left, right] : [right, left]
        } else {
            // Beside the column's bottom end, toward the middle of the screen.
            let inwardLeft = tray.midX > container.midX
            spots.append(CGPoint(x: inwardLeft ? tray.minX - g - d : tray.maxX + g, y: tray.maxY - d))
            spots.append(ends(tray)[1])
        }
        return spots + groups
    }

    /// The panel beside its entry button, inside `bounds` (the safe area
    /// above any keyboard): toward the middle of the screen, below the
    /// button first in a tall space and beside it first in a wide one. It
    /// never covers the button, so a second tap there closes it, and keeps
    /// off `obstacles` (hinge, camera) when it can.
    static func panelFrame(button: CGRect, size: CGSize, bounds: CGRect,
                           obstacles: [CGRect] = []) -> CGRect {
        guard !bounds.isNull, !bounds.isEmpty else { return .zero }
        let gap = spacing
        func clampedX(_ x: CGFloat) -> CGFloat { min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)) }
        func clampedY(_ y: CGFloat) -> CGFloat { min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - size.height)) }
        // Away from the button by at least `gap`, and no nearer the edge
        // than the bounds allow (a button in the notch margin, say).
        let beside = CGRect(x: button.midX <= bounds.midX
                                ? max(button.maxX + gap, bounds.minX)
                                : min(button.minX - gap - size.width, bounds.maxX - size.width),
                            y: clampedY(button.minY), width: size.width, height: size.height)
        let stacked = CGRect(x: clampedX(button.minX),
                             y: button.midY <= bounds.midY
                                ? max(button.maxY + gap, bounds.minY)
                                : min(button.minY - gap - size.height, bounds.maxY - size.height),
                             width: size.width, height: size.height)
        let tall = bounds.height >= bounds.width
        let ordered = tall ? [stacked, beside] : [beside, stacked]
        let usable = obstacles.filter { !$0.isNull && !$0.isEmpty }
        for candidate in ordered {
            let frame = ControlTrayGeometry.avoidingReservedRegions(candidate, obstacles: usable, within: bounds,
                                                                    alsoAvoiding: [button])
            if bounds.contains(frame), !frame.intersects(button), !usable.contains(where: { $0.intersects(frame) }) {
                return frame
            }
        }
        // No room beside it: inside the bounds, as close as possible.
        let first = ordered[0]
        return CGRect(x: clampedX(first.minX), y: clampedY(first.minY), width: size.width, height: size.height)
    }
}

extension CustomControlArrangement {
    /// Where a newly added Calculator lands in the Custom editor: the first
    /// free spot along the top edge from the left corner (in the 11"
    /// reference area the templates use), clear of every existing control;
    /// the middle when the top edge is full. Never moves anything else.
    func suggestedCalculatorPosition(portrait: Bool) -> (x: Double, y: Double) {
        let reference = portrait ? Self.referencePortrait : Self.referenceLandscape
        let diameter = Self.templateBaseDiameter * CGFloat(Self.utilitySize)
        let inset = Self.templateAnchorInset
        let spacing = Self.templateSpacing
        let taken = placements.map { placement -> CGRect in
            let side = Self.templateBaseDiameter * CGFloat(placement.size)
            return CGRect(x: CGFloat(placement.x) * reference.width - side / 2,
                          y: CGFloat(placement.y) * reference.height - side / 2, width: side, height: side)
        }
        var x = inset
        let y = inset
        while x <= reference.width - inset {
            let frame = CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)
            let padded = frame.insetBy(dx: -spacing, dy: -spacing)
            if !taken.contains(where: { $0.intersects(padded) }) {
                return (Double(x / reference.width), Double(y / reference.height))
            }
            x += diameter + spacing
        }
        return (0.5, 0.5)
    }
}

// MARK: - Stashing at an edge

/// Where a stashed calculator waits: at the left or right edge of its
/// bounds, its strip centred `offset` (0 top, 1 bottom) along that edge.
struct LocalCalculatorStash: Equatable {
    var edge: WorkspaceEdge
    var offset: Double
}

/// The calculator window flicked to an edge, as Window mode's floating
/// windows are (`WorkspaceFloatMotion`): thrown fast enough toward the left
/// or right edge, or let go with more than half of it past one, it slides
/// out of sight but for a strip of itself; a tap or a pull brings it back.
/// Only the left and right edges: the top and bottom hold the trays, pane
/// tabs and the system's own edge swipes. Points throughout.
enum LocalCalculatorStashGeometry {
    static let edges: Set<WorkspaceEdge> = [.left, .right]
    /// How much of the window shows while stashed (as a tucked float's strip).
    static let strip = CGFloat(WorkspaceFloatGeometry.stripDepth)
    /// How far in from the edge the strip takes touches: a 44 pt target.
    static let touchDepth = CGFloat(WorkspaceFloatGeometry.touchDepth)
    /// A pull on the strip this far inward (or a flick projected this far) brings it back.
    static let restorePull: CGFloat = 36

    /// While dragged, the window may hang past the left or right edge of
    /// `bounds` (all but its strip), never past the top or bottom.
    static func dragged(_ frame: CGRect, bounds: CGRect) -> CGRect {
        guard !bounds.isNull, !bounds.isEmpty else { return frame }
        let minX = bounds.minX - frame.width + strip, maxX = bounds.maxX - strip
        let y = min(max(frame.minY, bounds.minY), max(bounds.minY, bounds.maxY - frame.height))
        return CGRect(x: min(max(frame.minX, minX), maxX), y: y, width: frame.width, height: frame.height)
    }

    /// What a release at `frame` (as dragged) with `velocity` (points per
    /// second) does: a stash, or nil to stay inside.
    static func release(_ frame: CGRect, velocity: CGVector, bounds: CGRect) -> LocalCalculatorStash? {
        guard bounds.width > 0, bounds.height > 0, frame.width > 0, frame.height > 0 else { return nil }
        let unit = WorkspaceRect(x: (frame.minX - bounds.minX) / bounds.width, y: (frame.minY - bounds.minY) / bounds.height,
                                 width: frame.width / bounds.width, height: frame.height / bounds.height)
        let outcome = WorkspaceFloatMotion.decide(release: unit, velocity: (Double(velocity.dx), Double(velocity.dy)),
                                                  in: WorkspaceSize(width: bounds.width, height: bounds.height),
                                                  edges: edges)
        guard case .tuck(let edge, let offset) = outcome, edges.contains(edge) else { return nil }
        return LocalCalculatorStash(edge: edge, offset: offset)
    }

    /// Longest strip: a short handle, so it never runs along controls on its edge.
    static let maximumStripLength: CGFloat = 120

    /// The whole window as it waits (its own size, all but `strip` past the
    /// edge), the strip that shows, and where the strip takes touches. The
    /// strip is at most `maximumStripLength` long, at the stash's place along
    /// the edge or the nearest place there whose touch area keeps off
    /// `obstacles` (trays, palettes, folds). `touch` is nil when no place is
    /// clear: then only the calculator button brings it back.
    static func waiting(size: CGSize, stash: LocalCalculatorStash, bounds: CGRect,
                        obstacles: [CGRect] = []) -> (window: CGRect, strip: CGRect, touch: CGRect?) {
        let length = min(size.height, bounds.height, maximumStripLength)
        let wanted = bounds.minY + CGFloat(stash.offset.isFinite ? min(max(stash.offset, 0), 1) : 0.5) * bounds.height
        let low = bounds.minY + length / 2, high = max(low, bounds.maxY - length / 2)
        func stripRect(at center: CGFloat) -> CGRect {
            CGRect(x: stash.edge == .left ? bounds.minX : bounds.maxX - Self.strip, y: center - length / 2,
                   width: Self.strip, height: length)
        }
        let blockers = obstacles.filter { !$0.isNull && !$0.isEmpty }
        func clear(_ center: CGFloat) -> Bool {
            let area = touchArea(stripRect(at: center), edge: stash.edge)
            return !blockers.contains { $0.intersects(area) }
        }
        let start = min(max(wanted, low), high)
        var center: CGFloat?
        var step: CGFloat = 0
        while center == nil, start - step >= low - 0.5 || start + step <= high + 0.5 {
            if start - step >= low - 0.5, clear(start - step) { center = start - step }
            else if start + step <= high + 0.5, clear(start + step) { center = start + step }
            step += 8
        }
        let shown = stripRect(at: center ?? start)
        // The window around its strip, inside the bounds where it can be.
        let height = min(size.height, bounds.height)
        var y = shown.midY - height / 2
        y = min(max(y, bounds.minY), max(bounds.minY, bounds.maxY - height))
        y = min(max(y, shown.maxY - height), shown.minY)
        let x = stash.edge == .left ? bounds.minX - size.width + Self.strip : bounds.maxX - Self.strip
        return (CGRect(x: x, y: y, width: size.width, height: height), shown,
                center == nil ? nil : touchArea(shown, edge: stash.edge))
    }

    /// Where a strip takes touches: `touchDepth` in from its edge, at least
    /// 44 pt tall.
    static func touchArea(_ strip: CGRect, edge: WorkspaceEdge) -> CGRect {
        let height = max(strip.height, touchDepth)
        let y = strip.midY - height / 2
        return edge == .left
            ? CGRect(x: strip.minX - 8, y: y, width: touchDepth + 8, height: height)
            : CGRect(x: strip.maxX - touchDepth, y: y, width: touchDepth + 8, height: height)
    }

    /// The frame it comes back to: `frame` (where it was before) flush with
    /// the edge it waited at, at the height it waited, inside `bounds`.
    static func restored(_ frame: CGRect, stash: LocalCalculatorStash, bounds: CGRect,
                         obstacles: [CGRect] = []) -> CGRect {
        let waiting = waiting(size: frame.size, stash: stash, bounds: bounds, obstacles: obstacles).window
        let x = stash.edge == .left ? bounds.minX : bounds.maxX - frame.width
        let width = min(frame.width, bounds.width), height = min(frame.height, bounds.height)
        return CGRect(x: min(max(x, bounds.minX), bounds.maxX - width),
                      y: min(max(waiting.minY, bounds.minY), bounds.maxY - height), width: width, height: height)
    }

    /// Whether a pull on the strip (inward points, and its projected
    /// carry) brings the window back; a tap (no travel) does too.
    static func pullRestores(inward: CGFloat, projected: CGFloat, travel: CGFloat) -> Bool {
        abs(travel) < 6 || inward >= restorePull || projected >= restorePull * 2.5
    }
}
