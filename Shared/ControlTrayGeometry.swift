import CoreGraphics

struct ControlSafeInsets: Equatable {
    var top: CGFloat
    var leading: CGFloat
    var bottom: CGFloat
    var trailing: CGFloat

    static let zero = ControlSafeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
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
    static func layout(container: CGRect, safeInsets: ControlSafeInsets,
                       keyboardVisibleRect: CGRect?, portrait: Bool,
                       side: LandscapeTraySide, traySize: CGSize,
                       paletteSize: CGSize, spacing: CGFloat = 10) -> ControlTrayLayout {
        var visible = container.inset(by: safeInsets)
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
        let trayFrame = CGRect(origin: trayOrigin, size: tray)

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
        let paletteFrame = CGRect(origin: paletteOrigin, size: palette)
        return ControlTrayLayout(trayFrame: trayFrame, paletteFrame: paletteFrame, axis: axis)
    }
}

private func clamp(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
    // `upper` can fall below `lower` when the visible area is tiny; the
    // lower bound wins so the tray never leaves the safe area.
    Swift.max(lower, Swift.min(value, Swift.max(lower, upper)))
}

private extension CGRect {
    func inset(by insets: ControlSafeInsets) -> CGRect {
        CGRect(x: minX + insets.leading, y: minY + insets.top,
               width: max(0, width - insets.leading - insets.trailing),
               height: max(0, height - insets.top - insets.bottom))
    }
}
