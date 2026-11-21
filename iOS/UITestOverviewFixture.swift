// UI-test seam (DEBUG builds only; none of this exists in Release).
//
// Inert unless a UI test sets its launch environment variable:
//
// - `MEOW_UITEST_OVERVIEW=1`: the app opens straight into the Multi-Display Overview with a fixed
//   sample of three displays, with no Mac, no session and no network. The overview otherwise needs
//   a live Mac's display catalog.

#if DEBUG
import SwiftUI
import UIKit

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
        // Combined QA only until #283 and #286 both land: the fold band (iOS/UITestFoldSeam.swift)
        // inside the overview, for testOverviewChromeSplitsAroundAVerticalFold.
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
