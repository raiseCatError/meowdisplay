// UI-test seam (DEBUG builds only; none of this exists in Release).
//
// Inert unless a UI test sets its launch environment variable:
//
// - `MEOW_UITEST_FOLD=vertical|horizontal` (optional `MEOW_UITEST_FOLD_WIDTH`, points, default 24):
//   a synthetic fold. `ControlReservedRegion.active(in:)` adds one `.division` region where an
//   iPhone Duo's hinge would be: a full-height band at the window's horizontal centre (held like a
//   book) or a full-width band at its vertical centre (tabletop). The simulator reports no fold and
//   cannot fold, so without this the fold avoidance never runs on CI. The band is also exposed as an
//   accessibility element, `uitestFoldBand`, so XCUITest can read where it is.

#if DEBUG
import SwiftUI
import UIKit

enum UITestFoldSeam {
    enum Axis: String { case vertical, horizontal }

    /// Read once: a launch environment never changes while the app runs.
    static let axis: Axis? = ProcessInfo.processInfo.environment["MEOW_UITEST_FOLD"].flatMap(Axis.init(rawValue:))

    static let width: CGFloat = {
        guard let raw = ProcessInfo.processInfo.environment["MEOW_UITEST_FOLD_WIDTH"],
              let value = Double(raw), value.isFinite, value > 0 else { return 24 }
        return CGFloat(value)
    }()

    /// The band in window coordinates, for a window of `size`; nil while the seam is off.
    static func band(inWindowOfSize size: CGSize) -> CGRect? {
        guard let axis, size.width > 0, size.height > 0 else { return nil }
        switch axis {
        case .vertical:
            return CGRect(x: size.width / 2 - width / 2, y: 0, width: width, height: size.height)
        case .horizontal:
            return CGRect(x: 0, y: size.height / 2 - width / 2, width: size.width, height: width)
        }
    }

    /// The band as a reserved region of `proxy`'s view, in that view's coordinate space (the same
    /// space as the system's regions), clipped to the view; nil when the seam is off or the band
    /// misses the view.
    static func region(in proxy: GeometryProxy) -> ControlReservedRegion? {
        guard axis != nil else { return nil }
        let global = proxy.frame(in: .global)
        let windowSize = MainActor.assumeIsolated { ActiveScene.window?.bounds.size }
        // Before a window exists the view stands in for it.
        let origin = windowSize == nil ? .zero : global.origin
        guard let band = band(inWindowOfSize: windowSize ?? proxy.size) else { return nil }
        let local = band.offsetBy(dx: -origin.x, dy: -origin.y)
            .intersection(CGRect(origin: .zero, size: proxy.size))
        guard !local.isNull, !local.isEmpty else { return nil }
        return ControlReservedRegion(kind: .division, frame: local)
    }
}

/// Marks the synthetic fold on a full-window view: a faint stripe for screenshots (hidden from
/// accessibility and touches) and, behind everything so it never takes an accessibility hit test
/// from a control, an element `uitestFoldBand` whose frame is the band.
private struct UITestFoldBandMarker: ViewModifier {
    func body(content: Content) -> some View {
        if UITestFoldSeam.axis == nil {
            content
        } else {
            content
                .background(band { rect in
                    // Not `Color.clear`, so it is never left out of the tree as empty.
                    Color.orange.opacity(0.05)
                        .frame(width: rect.width, height: rect.height)
                        .accessibilityElement()
                        .accessibilityLabel(Text(verbatim: "Test fold"))
                        .accessibilityIdentifier("uitestFoldBand")
                })
                .overlay(band { rect in
                    Color.orange.opacity(0.2)
                        .frame(width: rect.width, height: rect.height)
                        .accessibilityHidden(true)
                })
        }
    }

    private func band<Marker: View>(@ViewBuilder _ marker: @escaping (CGRect) -> Marker) -> some View {
        GeometryReader { window in
            if let rect = UITestFoldSeam.band(inWindowOfSize: window.size) {
                marker(rect).position(x: rect.midX, y: rect.midY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

extension View {
    /// See `UITestFoldBandMarker`. Does nothing unless `MEOW_UITEST_FOLD` is set.
    func uiTestFoldBandMarker() -> some View { modifier(UITestFoldBandMarker()) }
}

#if targetEnvironment(simulator)
/// Read the window that actually contains the receiver or its presented Settings.
struct UITestOrientationReader: UIViewRepresentable {
    final class Reader: UIView {
        override var accessibilityValue: String? {
            get {
                guard let window, let scene = window.windowScene, let root = window.rootViewController else {
                    return "no-window"
                }
                var presented = root
                while let next = presented.presentedViewController { presented = next }
                let appMask = UIApplication.shared.supportedInterfaceOrientations(for: window)
                var fields = [
                    "orientation=\(scene.effectiveGeometry.interfaceOrientation.rawValue)",
                    "app=\(appMask.rawValue)",
                    "root=\(root.supportedInterfaceOrientations.rawValue)",
                    "presented=\(presented.supportedInterfaceOrientations.rawValue)",
                    "rootClass=\(type(of: root))", "presentedClass=\(type(of: presented))",
                    "traits=\(traitCollection.horizontalSizeClass.rawValue)/\(traitCollection.verticalSizeClass.rawValue)",
                    "screen=\(scene.screen.bounds.size)", "window=\(window.bounds.size)"
                ]
                if #available(iOS 27.0, *) {
                    let delegate = scene.delegate as? UIWindowSceneDelegate
                    let mask = delegate?.supportedInterfaceOrientations?(for: scene)
                    fields.append("sceneDelegate=\(mask.map { String($0.rawValue) } ?? "plist")")
                }
                if #available(iOS 26.0, *) {
                    fields.append("geometryLocked=\(scene.effectiveGeometry.isInterfaceOrientationLocked)")
                }
                return fields.joined(separator: " ")
            }
            set {}
        }
    }

    let surface: String

    func makeUIView(context: Context) -> Reader {
        let reader = Reader()
        reader.isAccessibilityElement = true
        reader.accessibilityIdentifier = "orientationAudit-" + surface
        reader.accessibilityLabel = "Orientation audit"
        reader.isUserInteractionEnabled = false
        return reader
    }

    func updateUIView(_ reader: Reader, context: Context) {}
}
#endif
#endif
