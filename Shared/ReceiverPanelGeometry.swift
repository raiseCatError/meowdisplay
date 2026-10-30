import CoreGraphics
import Foundation

/// The panel a receiver announces to the Mac (hello `pixelsWide`/`pixelsHigh`): the size of the
/// receiver's own window in pixels, not of the screen it is on. On a full-screen iPhone the two
/// are the same; on iPhone Duo (folded or unfolded), an iPad in Stage Manager or Split View,
/// and a resizable iPhone Mirroring window they are not, and the Mac's Extend display should
/// take the shape the person actually sees. Safe areas are part of the window (the picture is
/// drawn edge to edge), so showing or hiding the status bar never changes the panel.
enum ReceiverPanelGeometry {
    /// How long a new size must stay put before it is announced to a connected Mac: a window
    /// being dragged or a device mid-fold doesn't make the Mac rebuild its display at every step.
    static let settleDelay: TimeInterval = 0.35

    /// Pixels for a window of `points` at `scale` (rounded to the nearest pixel, so a
    /// full-screen window gives exactly the screen's native size); nil for an empty or
    /// unusable size.
    static func pixels(windowPoints points: CGSize, scale: CGFloat) -> (wide: Int, high: Int)? {
        guard points.width.isFinite, points.height.isFinite, scale.isFinite, scale > 0,
              points.width >= 1, points.height >= 1 else { return nil }
        return (Int((points.width * scale).rounded()), Int((points.height * scale).rounded()))
    }
}

/// Announces window-size changes to the Mac. The first size, and any size while no Mac is
/// connected, applies at once (it only shapes the next hello); while connected, a change waits
/// until the size has been stable for `delay`, and only the last one is sent.
@MainActor
final class ReceiverPanelSettler {
    typealias Panel = (wide: Int, high: Int, scale: Double)

    private let delay: TimeInterval
    private let isConnected: () -> Bool
    private let apply: (Panel) -> Void
    private var pending: DispatchWorkItem?
    private var last: (wide: Int, high: Int)?

    init(delay: TimeInterval = ReceiverPanelGeometry.settleDelay,
         isConnected: @escaping () -> Bool,
         apply: @escaping (Panel) -> Void) {
        self.delay = delay
        self.isConnected = isConnected
        self.apply = apply
    }

    func windowChanged(points: CGSize, scale: CGFloat) {
        guard let px = ReceiverPanelGeometry.pixels(windowPoints: points, scale: scale) else { return }
        let panel: Panel = (px.wide, px.high, Double(scale))
        pending?.cancel()
        pending = nil
        if let last, last == px { return }
        if last == nil || !isConnected() {
            last = px
            apply(panel)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.last = px
            self.apply(panel)
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
}
