import CoreGraphics
import Foundation

/// Where to draw a marker that points at a Mac cursor lying outside the visible content.
///
/// When the receiver is zoomed or panned, or the Mac cursor is on a part of the Mac that is not
/// on screen, the pointer cannot be drawn where it is. The marker stands in for it: it hugs the
/// edge of the visible content on the side the cursor is on, points at the cursor, and grows the
/// farther away the cursor is, so "just past the edge" and "far across the desk" look different.
///
/// All inputs are in one view coordinate space (y grows downward). `content` is the area the
/// marker may use, with letterboxing, zoom/pan, safe areas and controls already applied by the
/// caller; `cursor` may lie arbitrarily far outside it. Nothing here touches UIKit or AppKit, so
/// the whole policy is unit tested.
///
/// - The direction is the ray from the centre of `content` to the cursor, not the middle of the
///   nearest edge. A cursor up and to the right therefore puts the marker toward the top-right
///   corner rather than on the middle of the top or right edge.
/// - The marker sits where that ray leaves `content`, then moves inward just far enough that its
///   whole circumscribed circle stays inside `content`. A circle, not the rectangle, so that the
///   marker can rotate to point at the cursor without ever poking out.
/// - The circle's radius includes the scale the marker is drawn at (the scale depends on
///   distance only, so it is known before the position is). The caller scales the marker about
///   its centre and it still fits.
/// - Content too small for the marker on an axis centres the marker on that axis: there is no
///   position that fits, and a stable one is better than one that jumps between edges.
struct OffscreenCursorLocator {
    /// The sides of `content` the cursor lies beyond. A diagonal cursor has two.
    struct Edge: OptionSet, Sendable, Hashable {
        let rawValue: Int

        static let left = Edge(rawValue: 1 << 0)
        static let right = Edge(rawValue: 1 << 1)
        static let top = Edge(rawValue: 1 << 2)
        static let bottom = Edge(rawValue: 1 << 3)
    }

    struct Placement: Equatable, Sendable {
        /// Centre of the marker, inside `content`.
        var center: CGPoint
        /// Radians from the marker toward the cursor; 0 points along +x, and since y grows
        /// downward, +π/2 points down.
        var angle: CGFloat
        /// Multiplier for the marker's size, within the requested minimum and maximum.
        var scale: CGFloat
        /// Distance from the nearest point of `content` to the cursor. Zero is never returned:
        /// a cursor on the edge counts as inside.
        var distance: CGFloat
        /// Which sides of `content` the cursor lies beyond.
        var edge: Edge
    }

    /// The scale reaches its maximum at this many content diagonals from the content. Past it
    /// there is nothing more to tell the user, and the marker must not keep growing.
    static let saturationDiagonals: CGFloat = 3
    /// Curvature of the `1 - exp(-k t)` growth: larger grows faster near the edge and flattens
    /// sooner. 3 gives about 60% of the range by one diagonal, so a cursor a short way off is
    /// already distinguishable from one just past the edge.
    private static let growthRate: CGFloat = 3

    /// The placement of the marker, or nil when no marker is wanted: the cursor is inside
    /// `content` (the edge included), `content` is empty, or any value is not finite.
    static func placement(
        cursor: CGPoint,
        content: CGRect,
        indicatorSize: CGSize,
        minimumScale: CGFloat = 0.85,
        maximumScale: CGFloat = 1.25
    ) -> Placement? {
        let values = [
            cursor.x, cursor.y,
            content.origin.x, content.origin.y, content.size.width, content.size.height,
            indicatorSize.width, indicatorSize.height,
            minimumScale, maximumScale,
        ]
        guard values.allSatisfy(\.isFinite),
              content.size.width > 0, content.size.height > 0,
              indicatorSize.width >= 0, indicatorSize.height >= 0
        else { return nil }

        var edge: Edge = []
        if cursor.x < content.minX { edge.insert(.left) }
        if cursor.x > content.maxX { edge.insert(.right) }
        if cursor.y < content.minY { edge.insert(.top) }
        if cursor.y > content.maxY { edge.insert(.bottom) }
        guard !edge.isEmpty else { return nil }

        let gapX = max(content.minX - cursor.x, 0, cursor.x - content.maxX)
        let gapY = max(content.minY - cursor.y, 0, cursor.y - content.maxY)
        let distance = hypot(gapX, gapY)
        let diagonal = hypot(content.size.width, content.size.height)
        guard distance.isFinite, diagonal.isFinite, diagonal > 0 else { return nil }

        let scale = scale(
            distance: distance, diagonal: diagonal,
            minimum: minimumScale, maximum: maximumScale
        )
        let radius = hypot(indicatorSize.width, indicatorSize.height) / 2 * scale

        // Where the ray from the content centre to the cursor leaves the content. The cursor is
        // outside, so on at least one axis it is farther out than the half extent and the
        // fraction is below 1.
        let middle = CGPoint(x: content.midX, y: content.midY)
        let deltaX = cursor.x - middle.x
        let deltaY = cursor.y - middle.y
        let fractionX = deltaX == 0 ? CGFloat.infinity : content.size.width / 2 / abs(deltaX)
        let fractionY = deltaY == 0 ? CGFloat.infinity : content.size.height / 2 / abs(deltaY)
        let fraction = min(fractionX, fractionY)
        let crossing = CGPoint(x: middle.x + deltaX * fraction, y: middle.y + deltaY * fraction)

        let center = CGPoint(
            x: inset(crossing.x, low: content.minX, high: content.maxX, radius: radius),
            y: inset(crossing.y, low: content.minY, high: content.maxY, radius: radius)
        )
        let angle = atan2(cursor.y - center.y, cursor.x - center.x)
        guard center.x.isFinite, center.y.isFinite, angle.isFinite else { return nil }
        return Placement(center: center, angle: angle, scale: scale, distance: distance, edge: edge)
    }

    /// Grows from `minimum` at the content edge to `maximum` at `saturationDiagonals` content
    /// diagonals, and stays at `maximum` beyond. Exponential saturation, not linear, so a
    /// cursor 1e7 points away looks the same as one a few screens away. A reversed range is
    /// treated as a fixed scale at `minimum`.
    private static func scale(
        distance: CGFloat, diagonal: CGFloat, minimum: CGFloat, maximum: CGFloat
    ) -> CGFloat {
        let span = max(maximum, minimum) - minimum
        let progress = min(distance / (saturationDiagonals * diagonal), 1)
        let eased = (1 - exp(-growthRate * progress)) / (1 - exp(-growthRate))
        return minimum + span * min(max(eased, 0), 1)
    }

    /// Moves `value` so a circle of `radius` around it stays within `low...high`. With no room
    /// for the circle, the middle of the range.
    private static func inset(_ value: CGFloat, low: CGFloat, high: CGFloat, radius: CGFloat) -> CGFloat {
        let lower = low + radius
        let upper = high - radius
        guard lower < upper else { return (low + high) / 2 }
        return min(max(value, lower), upper)
    }
}
