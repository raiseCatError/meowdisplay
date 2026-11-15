// UI-test seams (DEBUG builds only; none of this exists in Release).
//
// Both are inert unless a UI test sets their launch environment variable:
//
// - `MEOW_UITEST_FOLD=vertical|horizontal` (optional `MEOW_UITEST_FOLD_WIDTH`, points, default 24):
//   a synthetic fold. `ControlReservedRegion.active(in:)` adds one `.division` region where an
//   iPhone Duo's hinge would be: a full-height band at the window's horizontal centre (held like a
//   book) or a full-width band at its vertical centre (tabletop). The simulator reports no fold and
//   cannot fold, so without this the fold avoidance never runs on CI. The band is also exposed as an
//   accessibility element, `uitestFoldBand`, so XCUITest can read where it is.
// - `MEOW_UITEST_OVERVIEW=1`: the app opens straight into the Multi-Display Overview with a fixed
//   sample of three displays, with no Mac, no session and no network. The overview otherwise needs
//   a live Mac's display catalog.

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

enum UITestOverviewFixture {
    static let isEnabled = ProcessInfo.processInfo.environment["MEOW_UITEST_OVERVIEW"] == "1"

    /// Three displays as a desk might have them: a 1512x982 built-in main display, a 1920x1080
    /// display to its right and a 1080x1920 portrait display above and to the left.
    static let displays: [CatalogDisplayItem] = [
        item(1, "Built-in Display", CGRect(x: 0, y: 0, width: 1512, height: 982), scale: 2, isMain: true),
        item(2, "Wide Display", CGRect(x: 1512, y: 0, width: 1920, height: 1080), scale: 1),
        item(3, "Portrait Display", CGRect(x: -1080, y: -1500, width: 1080, height: 1920), scale: 1),
    ]

    private static func item(_ id: UInt32, _ name: String, _ frame: CGRect, scale: Double,
                             isMain: Bool = false) -> CatalogDisplayItem {
        CatalogDisplayItem(id: id, name: name, width: Int(frame.width), height: Int(frame.height),
                           isMain: isMain, isVirtual: false,
                           overview: OverviewDisplay(id: id, name: name, frame: frame, scale: scale, hz: 60,
                                                     isMain: isMain))
    }

    /// An offline workspace model holding only the sample catalog. Its `send` stays the default,
    /// which sends nothing; its settings live in a suite of their own, emptied first.
    @MainActor static func makeModel() -> WorkspaceModel {
        let suite = "uitest.overviewFixture"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let model = WorkspaceModel(defaults: UserDefaults(suiteName: suite) ?? .standard)
        // Identify Displays shows (it sends nothing here); Move Cursor needs control, never held.
        model.apply(.features([DisplayArrangeWire.welcomeFeature]))
        model.apply(.catalog(WorkspaceCatalogMessage(host: nil, windows: [], apps: [], installed: [],
                                                     unavailable: false, displays: displays)))
        return model
    }
}

/// Stands in for `ReceiverScreen` while `MEOW_UITEST_OVERVIEW=1`: presents the overview at launch
/// the way the gallery does (`fullScreenCover`). Show in Pane and Add as New Pane do nothing here
/// beyond closing it; Done closes it. A button opens it again.
struct UITestOverviewFixtureHost: View {
    @StateObject private var model = UITestOverviewFixture.makeModel()
    @State private var presented = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        VStack(spacing: 16) {
            Text(verbatim: "Overview fixture")
            Button { presented = true } label: { Text(verbatim: "Open Overview") }
                .accessibilityIdentifier("uitestOpenOverview")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .uiTestFoldBandMarker()
        .onAppear { presented = true }
        .fullScreenCover(isPresented: $presented) {
            DisplayOverviewScreen(model: model, displayScale: displayScale,
                                  onShowInPane: { _ in }, onAddAsNewPane: { _ in })
                .uiTestFoldBandMarker()
        }
    }
}
#endif
