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

    /// iPhone (and narrow windows): the entry button in the upper-left
    /// usable region. It starts in the top-left corner with the same edge
    /// margin as the trays, then moves along the top edge past anything in
    /// the way, then down the left edge; each spot clears the notch or
    /// Dynamic Island band (with Avoid Notch), system-reserved regions
    /// (hinge, camera) and every frame in `occupied` (the Main Tray,
    /// Function groups, an open palette) by `spacing`. The other controls
    /// never move for it.
    static func phoneButtonFrame(container: CGRect, safeInsets: ControlSafeInsets,
                                 keyboardVisibleRect: CGRect?, portrait: Bool,
                                 diameter: CGFloat, occupied: [CGRect], avoidNotch: Bool,
                                 notchSide: LandscapeTraySide? = nil,
                                 reservedRegions: [ControlReservedRegion] = []) -> CGRect {
        var visible = container
        if let keyboardVisibleRect { visible = visible.intersection(keyboardVisibleRect) }
        guard !visible.isNull, !visible.isEmpty, diameter > 0 else { return .zero }
        let bounds = visible.insetBy(dx: margin, dy: margin)
        let size = CGSize(width: diameter, height: diameter)
        let blockers = occupied.filter { !$0.isNull && !$0.isEmpty }
        let obstacles = ControlTrayGeometry.reservedObstacles(reservedRegions, avoidNotch: avoidNotch)
        let xs = ([bounds.minX] + blockers.map { $0.maxX + spacing }).filter { $0 >= bounds.minX }.sorted()
        let ys = ([bounds.minY] + blockers.map { $0.maxY + spacing }).filter { $0 >= bounds.minY }.sorted()
        let candidates: [CGPoint] = xs.filter { $0 + diameter <= bounds.midX }.map { CGPoint(x: $0, y: bounds.minY) }
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
