// Pure layout for the arrangement map in the receiver's Stage Peek gallery:
// the Mac's displays in their real arrangement, fitted into a small view.
//
// Compiled into the iOS/Mac receiver targets (presentation) and the hostless
// Mac test target (see MacTests/DisplayArrangementLayoutTests.swift).
// Foundation + CoreGraphics only. No UI here.

import CoreGraphics
import Foundation

/// Where each drawn display of a `DisplayOverviewModel` goes in a view of a given size.
/// The scale is uniform (`OverviewCamera.fitAll`, no rotation), so proportions and gaps
/// between displays are those of the Mac's arrangement.
struct DisplayArrangementLayout {
    /// One drawn rectangle of the map.
    struct Tile: Equatable {
        enum Kind: Equatable {
            /// A real Mac display.
            case display
            /// The virtual display this device itself shows (never captured).
            case thisDevice
            /// A MeowDisplay virtual display of another session (never captured).
            case otherMeow
        }

        /// The drawn display's id (a mirror group's primary).
        let id: UInt32
        /// In view points, inside the layout size inset by its margin.
        let rect: CGRect
        let kind: Kind
        /// Displays drawn in this tile: 1 is no mirroring, more is a mirror group.
        let mirrorCount: Int
        let isMain: Bool
    }

    /// The tiles for `model`, in its reading order (also the accessibility order); a mirror
    /// group is drawn once. Empty for an empty model or an unusable size. `margin` (view
    /// points) is kept free on every side, never more than a quarter of the shorter side.
    static func tiles(for model: DisplayOverviewModel, in size: CGSize, margin: CGFloat = 8) -> [Tile] {
        let drawn = model.drawnDisplays
        guard !drawn.isEmpty, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return [] }
        let inset = effectiveMargin(margin, in: size)
        let inner = CGSize(width: size.width - 2 * inset, height: size.height - 2 * inset)
        let camera = OverviewCamera.fitAll(bounds: model.arrangementBounds, viewport: inner, margin: 0)
        let groups = Dictionary(uniqueKeysWithValues: model.mirrorGroups.map { ($0.primaryID, $0) })

        return drawn.map { display in
            let local = camera.viewRect(world: display.frame, viewport: inner)
            let members = groups[display.id]?.memberIDs.compactMap { model.display(withID: $0) } ?? []
            let kind: Tile.Kind = display.isOwn ? .thisDevice : (display.isMeow ? .otherMeow : .display)
            return Tile(id: display.id, rect: local.offsetBy(dx: inset, dy: inset), kind: kind,
                        mirrorCount: 1 + members.count, isMain: display.isMain || members.contains { $0.isMain })
        }
    }

    /// The height of a map `width` wide: the arrangement's aspect ratio (inside `margin`),
    /// clamped to `minimum...maximum`. `minimum` for an empty model.
    static func height(forWidth width: CGFloat, model: DisplayOverviewModel, minimum: CGFloat = 120,
                       maximum: CGFloat = 260, margin: CGFloat = 8) -> CGFloat {
        let bounds = model.arrangementBounds
        guard width.isFinite, width > 0, bounds.width > 0, bounds.height > 0 else { return minimum }
        let inset = max(margin.isFinite ? margin : 0, 0)
        let content = max(width - 2 * inset, 1)
        let natural = content * bounds.height / bounds.width + 2 * inset
        return Swift.min(Swift.max(natural, minimum), Swift.max(maximum, minimum))
    }

    private static func effectiveMargin(_ margin: CGFloat, in size: CGSize) -> CGFloat {
        guard margin.isFinite, margin > 0 else { return 0 }
        return Swift.min(margin, Swift.min(size.width, size.height) / 4)
    }
}
