// UI-test seam (DEBUG builds only; none of this exists in Release).
//
// Inert unless a UI test sets its launch environment variable:
//
// - `MEOW_UITEST_STAGE_PEEK=1`: the app hosts the real `StagePeekOverlay` over an offline workspace
//   model with three sample displays (the same ones as `MEOW_UITEST_OVERVIEW`), with no Mac, no
//   session and no network. The host stands in for a Split View / Stage Manager resize: about a
//   second after the Display Overview or the arrangement editor opens it narrows the canvas it
//   gives the overlay, and a fixture-only button does the same on demand. A label counts the
//   resizes.
// - With `MEOW_UITEST_STAGE_PEEK_PANES=1` as well: the model is in Window view on a stand-in Mac
//   that also offers the Overview pane (`overviewPane`), with the main display already in a pane,
//   and the host draws the real pane chrome (titles and their menus) under the overlay. No video.

#if DEBUG
import SwiftUI
import UIKit

enum UITestStagePeekFixture {
    static let isEnabled = ProcessInfo.processInfo.environment["MEOW_UITEST_STAGE_PEEK"] == "1"
    static let showsPanes = ProcessInfo.processInfo.environment["MEOW_UITEST_STAGE_PEEK_PANES"] == "1"

    /// The overview fixture's offline model, also marked as a Mac that offers the window workspace
    /// (the overlay only opens then). Its `send` stays the default, which sends nothing.
    @MainActor static func makeModel() -> WorkspaceModel {
        let model = UITestOverviewFixture.makeModel()
        guard showsPanes else {
            model.apply(.features([WindowWorkspaceWire.welcomeFeature, DisplayArrangeWire.welcomeFeature]))
            return model
        }
        model.apply(.connected(peerID: "uitest-mac"))
        model.apply(.features([WindowWorkspaceWire.welcomeFeature, DisplayArrangeWire.welcomeFeature,
                               WindowWorkspaceWire.overviewPaneFeature]))
        model.apply(.mode(window: true))
        if let main = UITestOverviewFixture.displays.first(where: \.isMain) {
            model.choose(model.displayWindow(main), asNewTile: false)
        }
        return model
    }
}

/// Stands in for `ReceiverScreen` while `MEOW_UITEST_STAGE_PEEK=1`: the real Stage Peek overlay on
/// a plain backdrop. Every odd resize narrows the canvas to 70% of the width and every even one
/// restores it, as a window resize would.
struct UITestStagePeekFixtureHost: View {
    @StateObject private var model = UITestStagePeekFixture.makeModel()
    @State private var resizes = 0

    private static let narrowFraction: CGFloat = 0.7

    var body: some View {
        GeometryReader { geo in
            let canvas = canvasFrame(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color(white: 0.12)
                if UITestStagePeekFixture.showsPanes {
                    WorkspaceChromeView(model: model, picture: canvas, inputAllowed: true, safeArea: safeFrame(canvas))
                }
                StagePeekOverlay(model: model, edge: .left, frame: canvas, safe: safeFrame(canvas),
                                 avoiding: [], hapticsEnabled: false, inputAllowed: true, onDisplay: { _ in })
                resizeControls
            }
        }
        .ignoresSafeArea()
        .onChange(of: model.displayOverviewOpen) { open in if open { resizeSoon() } }
        .onChange(of: model.displayArrangementEditorOpen) { open in if open { resizeSoon() } }
    }

    private func canvasFrame(in size: CGSize) -> CGRect {
        let narrow = resizes % 2 == 1
        return CGRect(x: 0, y: 0, width: narrow ? size.width * Self.narrowFraction : size.width, height: size.height)
    }

    /// A fixed margin stands in for the system's safe area, in the canvas's own coordinates.
    private func safeFrame(_ canvas: CGRect) -> CGRect {
        CGRect(x: 0, y: 24, width: canvas.width, height: canvas.height - 24 - 16)
    }

    private func resizeSoon() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            resizes += 1
        }
    }

    /// Bottom-left, clear of Stage Peek's toolbar (centre) and its top controls.
    private var resizeControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Button { resizes += 1 } label: { Text(verbatim: "Resize") }
                    .accessibilityIdentifier("uitestStagePeekResize")
                Text(verbatim: "Resizes: \(resizes)")
                    .accessibilityIdentifier("uitestStagePeekResizes")
                Spacer()
            }
            .font(.caption2)
            .padding(.leading, 12)
            .padding(.bottom, 4)
        }
    }
}
#endif
