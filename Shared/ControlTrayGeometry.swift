import CoreGraphics

struct ControlSafeInsets: Equatable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    static let zero = ControlSafeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)

    /// UIKit's live report is authoritative once the probe has published;
    /// GeometryProxy is only the startup fallback. Treating the runtime
    /// value as one complete snapshot matters on rotation, when the old
    /// notch-side inset must become zero as the opposite side gains it.
    static func resolved(proxy: ControlSafeInsets,
                         runtime: ControlSafeInsets?) -> ControlSafeInsets {
        runtime ?? proxy
    }
}

/// Mirrors only the two landscape cases of UIKit's `UIInterfaceOrientation`
/// — kept UIKit-free so the mapping to a physical notch side is testable
/// from the hostless Mac test target (`Shared/` compiles there too).
enum LandscapeInterfaceOrientation {
    case landscapeLeft
    case landscapeRight
}

/// The ONLY reliable signal for which landscape edge holds the physical
/// notch/Dynamic Island. A prior implementation compared leading vs.
/// trailing safe-area depth and treated a "meaningfully deeper" side as the
/// notch — but real devices can report equal depths on both edges (e.g.
/// leading=59, trailing=59) despite a real, single-sided physical notch, so
/// that comparison is fundamentally unreliable.
///
/// `UIInterfaceOrientation` is unambiguous, but its naming is a well-known
/// trap: `UIInterfaceOrientation` describes how the CONTENT is rotated to
/// compensate for the device, which is the OPPOSITE of the device's own
/// physical rotation (`UIDeviceOrientation`) — confirmed against real
/// devices (a prior mapping using the "content" reading, `.landscapeLeft`
/// -> `.leading`, was verified backwards on-device: rotating the phone so
/// the physical notch ends up on the device's own left required
/// `.landscapeRight`). `.landscapeLeft` rotating the device LEFT (physical
/// top swings toward the screen's own RIGHT edge) puts the notch on the
/// TRAILING edge; `.landscapeRight` puts it on the LEADING edge.
enum PhysicalNotchSide {
    static func forLandscape(_ orientation: LandscapeInterfaceOrientation?) -> LandscapeTraySide? {
        switch orientation {
        case .landscapeLeft: return .trailing
        case .landscapeRight: return .leading
        case nil: return nil
        }
    }
}

enum ControlTrayAxis: Equatable {
    case horizontal
    case vertical
}

struct ControlTrayLayout: Equatable {
    var trayFrame: CGRect
    var paletteFrame: CGRect
    var axis: ControlTrayAxis
}

enum ControlTrayGeometry {
    /// Base placement always uses the raw/full container. `avoidNotch`
    /// affects only the final per-frame obstacle pass below; it never turns
    /// the safe-area rectangle into a global layout margin.
    static func layout(container: CGRect, safeInsets: ControlSafeInsets,
                       keyboardVisibleRect: CGRect?, portrait: Bool,
                       side: LandscapeTraySide, traySize: CGSize,
                       paletteSize: CGSize, avoidNotch: Bool,
                       notchSide: LandscapeTraySide? = nil, spacing: CGFloat = 10) -> ControlTrayLayout {
        var visible = container
        if let keyboardVisibleRect {
            visible = visible.intersection(keyboardVisibleRect)
        }
        guard !visible.isNull, !visible.isEmpty else {
            return ControlTrayLayout(trayFrame: .zero, paletteFrame: .zero,
                                     axis: portrait ? .horizontal : .vertical)
        }

        let margin: CGFloat = 12
        let axis: ControlTrayAxis = portrait ? .horizontal : .vertical
        let requestedTraySize = traySize
        let tray = CGSize(width: min(requestedTraySize.width, max(0, visible.width - margin * 2)),
                          height: min(requestedTraySize.height, max(0, visible.height - margin * 2)))
        // Portrait: bottom-centered. Landscape: hugging the chosen side and
        // vertically centered, so the tray sits under the thumb on whichever
        // hand holds the device.
        let trailing = side == .trailing
        let trayOrigin: CGPoint
        if portrait {
            trayOrigin = CGPoint(x: visible.midX - tray.width / 2,
                                 y: visible.maxY - margin - tray.height)
        } else {
            trayOrigin = CGPoint(x: trailing ? visible.maxX - margin - tray.width : visible.minX + margin,
                                 y: clamp(visible.midY - tray.height / 2,
                                          min: visible.minY + margin,
                                          max: visible.maxY - margin - tray.height))
        }
        var trayFrame = CGRect(origin: trayOrigin, size: tray)

        var palette = CGSize(width: min(paletteSize.width, visible.width - margin * 2),
                             height: min(paletteSize.height, visible.height - margin * 2))
        palette.width = max(0, palette.width)
        palette.height = max(0, palette.height)
        var paletteOrigin: CGPoint
        if portrait {
            paletteOrigin = CGPoint(x: min(max(visible.minX + margin, visible.midX - palette.width / 2),
                                           visible.maxX - margin - palette.width),
                                    y: trayFrame.minY - spacing - palette.height)
        } else {
            let proposedX = trailing
                ? trayFrame.minX - spacing - palette.width
                : trayFrame.maxX + spacing
            paletteOrigin = CGPoint(x: proposedX,
                                    y: min(max(visible.minY + margin, trayFrame.midY - palette.height / 2),
                                           visible.maxY - margin - palette.height))
            if proposedX < visible.minX + margin || proposedX + palette.width > visible.maxX - margin {
                paletteOrigin.x = min(max(visible.minX + margin, trayFrame.midX - palette.width / 2),
                                      visible.maxX - margin - palette.width)
                paletteOrigin.y = trayFrame.minY - spacing - palette.height
            }
        }
        paletteOrigin.y = min(max(visible.minY + margin, paletteOrigin.y),
                              visible.maxY - margin - palette.height)
        var paletteFrame = CGRect(origin: paletteOrigin, size: palette)

        // Obstacle avoidance is deliberately after normal placement. A
        // non-intersecting frame must remain bit-for-bit unchanged.
        trayFrame = avoidingUnsafeRegion(trayFrame, in: container, safeInsets: safeInsets, enabled: avoidNotch,
                                         portrait: portrait, notchSide: notchSide)
        paletteFrame = avoidingUnsafeRegion(paletteFrame, in: container, safeInsets: safeInsets, enabled: avoidNotch,
                                            portrait: portrait, notchSide: notchSide)
        return ControlTrayLayout(trayFrame: trayFrame, paletteFrame: paletteFrame, axis: axis)
    }
}

private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
    // `upper` can fall below `lower` when the visible area is tiny; the
    // lower bound wins so the tray never leaves the safe area.
    Swift.max(lower, Swift.min(value, Swift.max(lower, upper)))
}

extension ControlTrayGeometry {
    /// `notchSide` is the physical notch edge, as determined by
    /// `PhysicalNotchSide.forLandscape` from `UIInterfaceOrientation` — NOT
    /// derived here from safe-area depth comparison (see that type's doc for
    /// why). `nil` means "no known/applicable physical notch side": portrait
    /// (the notch there is the top inset, handled below independent of this
    /// parameter), a flat/unknown orientation, or a non-notched device.
    static func unsafeRegions(in container: CGRect,
                              safeInsets: ControlSafeInsets,
                              portrait: Bool = false,
                              notchSide: LandscapeTraySide? = nil) -> [CGRect] {
        var regions: [CGRect] = []
        if !portrait, notchSide == .leading, safeInsets.leading > 0 {
            let span = min(container.height, safeInsets.leading * 3)
            regions.append(CGRect(x: container.minX, y: container.midY - span / 2,
                                  width: safeInsets.leading, height: span))
        }
        if !portrait, notchSide == .trailing, safeInsets.trailing > 0 {
            let span = min(container.height, safeInsets.trailing * 3)
            regions.append(CGRect(x: container.maxX - safeInsets.trailing,
                                  y: container.midY - span / 2,
                                  width: safeInsets.trailing, height: span))
        }
        if safeInsets.top > 0 {
            let span = min(container.width, safeInsets.top * 3)
            regions.append(CGRect(x: container.midX - span / 2, y: container.minY,
                                  width: span, height: safeInsets.top))
        }
        if safeInsets.bottom > 0 {
            let span = min(container.width, safeInsets.bottom * 3)
            regions.append(CGRect(x: container.midX - span / 2,
                                  y: container.maxY - safeInsets.bottom,
                                  width: span, height: safeInsets.bottom))
        }
        return regions
    }

    /// Shifts `frame` inward just enough to clear localized physical edge
    /// obstacles. UIKit exposes each obstruction's edge depth through safe
    /// area insets, but not its outline; the cross-edge extent is therefore
    /// conservatively represented as a centered band three times that
    /// depth. Crucially, these are obstacles rather than full-edge strips:
    /// a top/bottom Function group that does not touch the side sensor area
    /// stays at its exact raw position.
    static func avoidingUnsafeRegion(_ frame: CGRect, in container: CGRect,
                                     safeInsets: ControlSafeInsets, enabled: Bool,
                                     portrait: Bool = false, notchSide: LandscapeTraySide? = nil) -> CGRect {
        guard enabled else { return frame }
        var result = frame
        if !portrait, notchSide == .leading, safeInsets.leading > 0 {
            let span = min(container.height, safeInsets.leading * 3)
            let unsafe = CGRect(x: container.minX, y: container.midY - span / 2,
                                width: safeInsets.leading, height: span)
            if result.intersects(unsafe) { result.origin.x = unsafe.maxX }
        }
        if !portrait, notchSide == .trailing, safeInsets.trailing > 0 {
            let span = min(container.height, safeInsets.trailing * 3)
            let unsafe = CGRect(x: container.maxX - safeInsets.trailing,
                                y: container.midY - span / 2,
                                width: safeInsets.trailing, height: span)
            if result.intersects(unsafe) { result.origin.x = unsafe.minX - result.width }
        }
        if safeInsets.top > 0 {
            let span = min(container.width, safeInsets.top * 3)
            let unsafe = CGRect(x: container.midX - span / 2, y: container.minY,
                                width: span, height: safeInsets.top)
            if result.intersects(unsafe) { result.origin.y = unsafe.maxY }
        }
        if safeInsets.bottom > 0 {
            let span = min(container.width, safeInsets.bottom * 3)
            let unsafe = CGRect(x: container.midX - span / 2,
                                y: container.maxY - safeInsets.bottom,
                                width: span, height: safeInsets.bottom)
            if result.intersects(unsafe) { result.origin.y = unsafe.minY - result.height }
        }
        return result
    }

    /// One frame per Function Tray group (see `FunctionTrayProfile.visibleGroups`)
    /// — never a single combined frame, so groups can anchor independently
    /// (the default Zoom group toward the top of its side, the Edit group
    /// toward the bottom). Portrait lays every group out in one horizontal
    /// row, side by side with a visible gap, stacked above the Main Tray.
    /// Landscape splits the groups in half: the first half anchor toward
    /// the top of the tray's side, the second half toward the bottom —
    /// "Same Side" additionally keeps both halves clear of the Main Tray
    /// itself (first half above it, second half below, neither overlapping
    /// it); "Opposite Side" anchors independently against the opposite
    /// edge, ignoring the Main Tray's own position entirely.
    static func functionTrayLayout(container: CGRect, safeInsets: ControlSafeInsets,
                                   keyboardVisibleRect: CGRect?, portrait: Bool,
                                   mainSide: LandscapeTraySide, position: FunctionTrayPosition,
                                   mainTrayFrame: CGRect, groupSizes: [CGSize],
                                   avoiding collisionFrame: CGRect?, avoidNotch: Bool,
                                   notchSide: LandscapeTraySide? = nil,
                                   spacing: CGFloat = 10, groupGap: CGFloat = 14) -> [CGRect] {
        guard !groupSizes.isEmpty else { return [] }
        var visible = container
        if let keyboardVisibleRect {
            visible = visible.intersection(keyboardVisibleRect)
        }
        guard !visible.isNull, !visible.isEmpty else { return Array(repeating: .zero, count: groupSizes.count) }

        let margin: CGFloat = 12
        func bounded(_ size: CGSize) -> CGSize {
            CGSize(width: min(size.width, max(0, visible.width - margin * 2)),
                  height: min(size.height, max(0, visible.height - margin * 2)))
        }

        var frames: [CGRect]
        if portrait {
            let sizes = groupSizes.map(bounded)
            let totalWidth = sizes.reduce(0) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * groupGap
            var x = visible.midX - totalWidth / 2
            let rowHeight = sizes.map(\.height).max() ?? 0
            let y = mainTrayFrame.minY - spacing - rowHeight
            frames = sizes.map { size in
                let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
                x += size.width + groupGap
                return frame
            }
        } else {
            let side = position == .sameSide ? mainSide : mainSide.opposite
            func originX(_ width: CGFloat) -> CGFloat {
                side == .trailing ? visible.maxX - margin - width : visible.minX + margin
            }
            // Only constrains the halves against the Main Tray when they
            // share its edge — an opposite-side Function Tray has nothing
            // to keep clear of.
            let topBound = position == .sameSide ? mainTrayFrame.minY - spacing : visible.maxY - margin
            let bottomBound = position == .sameSide ? mainTrayFrame.maxY + spacing : visible.minY + margin
            let topCount = (groupSizes.count + 1) / 2
            frames = Array(repeating: CGRect.zero, count: groupSizes.count)

            // Top half: anchored at the corner (`visible.minY + margin`)
            // unless that would run into the Main Tray, in which case it's
            // pulled up only as much as needed to stay clear.
            var y = visible.minY + margin
            for index in 0..<topCount {
                let size = bounded(groupSizes[index])
                let originY = min(y, topBound - size.height)
                frames[index] = CGRect(x: originX(size.width), y: max(visible.minY + margin, originY),
                                       width: size.width, height: size.height)
                y = frames[index].maxY + spacing
            }
            // Bottom half: same idea from the opposite corner.
            var yBottom = visible.maxY - margin
            for index in stride(from: groupSizes.count - 1, through: topCount, by: -1) {
                let size = bounded(groupSizes[index])
                let originY = max(yBottom - size.height, bottomBound)
                frames[index] = CGRect(x: originX(size.width), y: min(originY, visible.maxY - margin - size.height),
                                       width: size.width, height: size.height)
                yBottom = frames[index].minY - spacing
            }
        }

        // The top/bottom anchors normally clear the Main Tray already. If
        // the rendered tray is taller than the available middle region,
        // however, vertical clearance is mathematically impossible. Move
        // only the colliding Function group inward along the horizontal
        // axis; this final collision pass makes overlap impossible without
        // trusting a clamped SwiftUI frame to describe overflowing content.
        if !portrait, position == .sameSide {
            frames = frames.map {
                displaced($0, avoiding: mainTrayFrame,
                          within: visible.insetBy(dx: margin, dy: margin),
                          axis: .vertical, spacing: spacing)
            }
        }
        // The temporary palette has priority over both trays. Resolve it
        // after the Same Side Main Tray fallback, while retaining the Main
        // Tray as a protected obstacle so this displacement cannot move a
        // group back onto the tray it just cleared. Each frame is processed
        // independently, therefore only an actually-colliding group moves.
        let protectedFrames = !portrait && position == .sameSide ? [mainTrayFrame] : []
        frames = frames.map {
            displaced($0, avoiding: collisionFrame,
                      alsoAvoiding: protectedFrames,
                      within: visible.insetBy(dx: margin, dy: margin),
                      axis: portrait ? .horizontal : .vertical, spacing: spacing)
        }
        frames = frames.map {
            avoidingUnsafeRegion($0, in: container, safeInsets: safeInsets, enabled: avoidNotch,
                                portrait: portrait, notchSide: notchSide)
        }
        return frames.map { frame in
            var result = frame
            result.origin.x = clamp(result.origin.x, min: visible.minX + margin, max: visible.maxX - margin - result.width)
            result.origin.y = clamp(result.origin.y, min: visible.minY + margin, max: visible.maxY - margin - result.height)
            return result
        }
    }

    /// Nudges `frame` clear of `avoid` along `axis` — up/down in portrait
    /// (`.horizontal` axis, matching the tray's own row direction), left/
    /// right in landscape — preferring whichever direction actually stays
    /// inside `visible`. A no-op when there's nothing to avoid or they
    /// don't overlap.
    static func displaced(_ frame: CGRect, avoiding avoid: CGRect?,
                          alsoAvoiding protectedFrames: [CGRect] = [],
                          within visible: CGRect, axis: ControlTrayAxis,
                          spacing: CGFloat) -> CGRect {
        guard let avoid, frame.intersects(avoid) else { return frame }
        func isAvailable(_ candidate: CGRect) -> Bool {
            visible.contains(candidate)
                && protectedFrames.allSatisfy { !candidate.intersects($0) }
        }
        if axis == .horizontal {
            let above = CGRect(x: frame.minX, y: avoid.minY - spacing - frame.height,
                               width: frame.width, height: frame.height)
            let below = CGRect(x: frame.minX, y: avoid.maxY + spacing,
                               width: frame.width, height: frame.height)
            if isAvailable(above) { return above }
            if isAvailable(below) { return below }
            return frame
        } else {
            let before = CGRect(x: avoid.minX - spacing - frame.width, y: frame.minY,
                                width: frame.width, height: frame.height)
            let after = CGRect(x: avoid.maxX + spacing, y: frame.minY,
                               width: frame.width, height: frame.height)
            if isAvailable(before) { return before }
            if isAvailable(after) { return after }
            return frame
        }
    }
}
