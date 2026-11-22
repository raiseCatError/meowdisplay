// Full-screen, interactive Multi-Display Overview: every display of the Mac in its real
// arrangement, seen through an `OverviewCamera`. One finger pans (never clamped), a pinch
// zooms about the fingers, a double-tap zooms to a display (or fits everything again on empty
// space). The gesture-to-camera rules live in `OverviewInteraction` (Shared, unit-tested); this
// file only forwards touches, draws and offers the pane actions.
//
// Presented with `.fullScreenCover` from the Stage Peek gallery's Displays section.

import SwiftUI
import UIKit

/// Presents `DisplayOverviewScreen` over the gallery. A modifier of its own keeps the gallery's
/// already large `body` cheap to type-check.
struct DisplayOverviewPresentation: ViewModifier {
    @Binding var isPresented: Bool
    let model: WorkspaceModel
    let onShowInPane: (CatalogDisplayItem) -> Void
    let onAddAsNewPane: (CatalogDisplayItem) -> Void
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented) {
            DisplayOverviewScreen(model: model, displayScale: displayScale,
                                  onShowInPane: onShowInPane, onAddAsNewPane: onAddAsNewPane)
        }
    }
}

struct DisplayOverviewScreen: View {
    @ObservedObject var model: WorkspaceModel
    /// The gallery's own "Show in Pane" for a display (`onDisplay`).
    let onShowInPane: (CatalogDisplayItem) -> Void
    /// The gallery's "Add as New Pane" for a display source.
    let onAddAsNewPane: (CatalogDisplayItem) -> Void

    @State private var interaction: OverviewInteraction
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSize
    @Environment(\.displayScale) private var environmentDisplayScale

    /// How far past the canvas a tile is still drawn, so the corners and border that the
    /// canvas clips are never the visible edge of a tile that is cut off by the screen.
    private static let overscan: CGFloat = 12

    /// The scale comes from the presenting view's environment, never `UIScreen.main`: on
    /// iPhone Duo the window can be on either display, and the main screen is not necessarily
    /// the one showing this view.
    init(model: WorkspaceModel, displayScale: CGFloat, onShowInPane: @escaping (CatalogDisplayItem) -> Void,
         onAddAsNewPane: @escaping (CatalogDisplayItem) -> Void) {
        self.model = model
        self.onShowInPane = onShowInPane
        self.onAddAsNewPane = onAddAsNewPane
        _interaction = State(initialValue: OverviewInteraction(
            model: DisplayOverviewModel(catalog: model.catalog?.displays ?? []),
            viewDisplayScale: Double(displayScale)))
    }

    var body: some View {
        GeometryReader { root in
            // An iPhone Duo held like a book: the chrome splits around the fold (canvas does not).
            let fold = OverviewChromeFold.split(
                containerWidth: root.size.width,
                divisions: ControlReservedRegion.frames(of: .division, in: ControlReservedRegion.active(in: root)))
            VStack(spacing: 0) {
                toolbar(fold: fold)
                canvas
                actionBar(fold: fold)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        // Display stills keep refreshing while the overview is open, whatever Stage Peek does underneath.
        .onAppear { model.displayOverviewOpen = true }
        .onDisappear { model.displayOverviewOpen = false }
        .onChange(of: model.catalog?.displays) { displays in refreshModel(displays) }
        .onChange(of: environmentDisplayScale) { scale in interaction.setViewDisplayScale(Double(scale)) }
    }

    // MARK: Toolbar

    /// Two halves: navigation (leading) and tools (trailing); on one line, or split around a fold.
    private func toolbar(fold: OverviewChromeFold.Split?) -> some View {
        FoldAwareBar(fold: fold, horizontalPadding: 16) {
            HStack(spacing: 8) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("displayOverviewDone")
                Spacer(minLength: 4)
                stepButton(.previous, symbol: "chevron.left", label: String(localized: "Previous Display"))
                Text("\(selectionTitle) (Beta)")
                    .accessibilityIdentifier("displayOverviewSelectionTitle")
                    .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityAddTraits(.isHeader)
                stepButton(.next, symbol: "chevron.right", label: String(localized: "Next Display"))
                Spacer(minLength: 4)
            }
        } trailing: {
            toolbarTools
        }
        .foregroundStyle(.white)
        .padding(.vertical, 10)
    }

    private var toolbarTools: some View {
        HStack(spacing: 8) {
            if model.canUseDisplayActions {
                // Labels on the Mac's own screens, to match these tiles with the desk.
                Button { model.identifyDisplays() } label: {
                    Image(systemName: "number.square").padding(8)
                }
                .accessibilityLabel("Identify Displays")
                .accessibilityIdentifier("displayOverviewIdentify")
            }
            fitAllButton
        }
    }

    private func stepButton(_ step: DisplayOverviewModel.SelectionStep, symbol: String, label: String) -> some View {
        Button { animateCamera { interaction.select(step) } } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).padding(8)
        }
        .disabled(interaction.model.drawnDisplays.count < 2)
        .accessibilityLabel(label)
    }

    /// Always visible, unlike the recovery button.
    @ViewBuilder private var fitAllButton: some View {
        if horizontalSize == .compact {
            Button { animateCamera { interaction.fitAll() } } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass").padding(8)
            }
            .accessibilityLabel("Fit All")
            .accessibilityIdentifier("displayOverviewFitAll")
        } else {
            Button { animateCamera { interaction.fitAll() } } label: {
                Label("Fit All", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .accessibilityIdentifier("displayOverviewFitAll")
        }
    }

    private var selectionTitle: String {
        guard let display = interaction.selectedDisplay else { return String(localized: "Displays") }
        let name = title(for: display)
        guard let cursor = model.overviewCursor, cursor.display == display.id else { return name }
        return name + String(localized: ", cursor here")
    }

    private func title(for display: OverviewDisplay) -> String {
        if display.isOwn {
            return UIDevice.current.userInterfaceIdiom == .pad ? String(localized: "This iPad") : String(localized: "This iPhone")
        }
        if display.isMeow { return String(localized: "MeowDisplay") }
        let name = display.name.isEmpty ? String(localized: "Display") : display.name
        return display.isMain ? String(localized: "\(name) (Main)") : name
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            ZStack {
                if interaction.viewport.width > 0 { tilesLayer }
                if interaction.viewport.width > 0 { cursorLayer }
                OverviewGestureSurface(
                    onPan: { delta in interaction.pan(byView: delta) },
                    onPinch: { factor, focal, translation in
                        interaction.pinch(factor: factor, focal: focal, focalTranslation: translation)
                    },
                    onTap: { point in _ = interaction.tap(atView: point) },
                    onDoubleTap: { point in animateCamera { _ = interaction.doubleTap(atView: point) } })
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(alignment: .top) { recoveryOverlay }
            .onAppear { interaction.updateLayout(viewport: geo.size) }
            .onChange(of: geo.size) { size in interaction.updateLayout(viewport: size) }
        }
    }

    /// Offered only while the arrangement is out of view; Fit All is in the toolbar regardless.
    private var recoveryOverlay: some View {
        ZStack {
            if interaction.showsRecovery {
                Button { animateCamera { interaction.fitAll() } } label: {
                    Label("Show All Displays", systemImage: "viewfinder").font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent).tint(meowAccent)
                .padding(.top, 12)
                .transition(reduceMotion ? .identity : .opacity)
                .accessibilityIdentifier("displayOverviewShowAll")
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: interaction.showsRecovery)
    }

    // MARK: Tiles

    /// Touches never reach the tiles: the gesture surface above them resolves every touch through
    /// the camera, so a placeholder absorbs a tap rather than letting it count as empty space.
    private var tilesLayer: some View {
        ZStack {
            ForEach(interaction.model.drawnDisplays) { display in tile(display) }
        }
        .allowsHitTesting(false)
    }

    /// The Mac cursor at its real position, at a fixed on-screen size whatever the zoom. Drawn
    /// even over this device's own display (it is the real position). Off screen it is not drawn.
    @ViewBuilder private var cursorLayer: some View {
        if let cursor = model.overviewCursor,
           let tip = OverviewCursorGlyph.viewPoint(world: cursor.point, camera: interaction.camera,
                                                   viewport: interaction.viewport) {
            let half = CGFloat(OverviewCursorGlyph.pointSize) / 2
            OverviewCursorGlyphView()
                .position(x: tip.x + half, y: tip.y + half)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func tile(_ display: OverviewDisplay) -> some View {
        let rect = interaction.viewRect(of: display)
        if rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 {
            if display.isOwn || display.isMeow {
                placeholderTile(display, rect)
            } else {
                displayTile(display, rect)
            }
        }
    }

    /// The part of `rect` worth drawing: what is on screen plus the overscan. A display zoomed far
    /// past the screen is drawn only where it is seen, never as one enormous layer.
    private func drawnRect(for rect: CGRect) -> CGRect {
        let bounds = CGRect(origin: .zero, size: interaction.viewport).insetBy(dx: -Self.overscan, dy: -Self.overscan)
        let clipped = rect.intersection(bounds)
        return clipped.isNull ? CGRect(x: rect.midX, y: rect.midY, width: 0, height: 0) : clipped
    }

    private func displayTile(_ display: OverviewDisplay, _ rect: CGRect) -> some View {
        let isSelected = interaction.model.selected == display.id
        let drawn = drawnRect(for: rect)
        let traits: AccessibilityTraits = isSelected ? [.isButton, .isSelected] : [.isButton]
        return ZStack {
            OverviewDisplayTile(thumbnail: model.displayThumbnails[display.id], fullSize: rect.size,
                                origin: CGPoint(x: rect.minX - drawn.minX, y: rect.minY - drawn.minY),
                                isMain: display.isMain, isSelected: isSelected)
                .frame(width: drawn.width, height: drawn.height)
                // Before `position`, which would make the element as big as the whole canvas.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(for: display))
                .accessibilityIdentifier("displayOverviewTile")
                .accessibilityAddTraits(traits)
                .accessibilityAdjustableAction { direction in adjustSelection(direction) }
                .accessibilityAction { interaction.select(id: display.id) }
                .accessibilityAction(named: "Show in Pane") { interaction.select(id: display.id); showSelected() }
                .position(x: drawn.midX, y: drawn.midY)
            labels(for: display, rect)
        }
    }

    /// A MeowDisplay screen, drawn as in the gallery's map: dashed, never captured.
    private func placeholderTile(_ display: OverviewDisplay, _ rect: CGRect) -> some View {
        let drawn = drawnRect(for: rect)
        return StagePeekArrangementPlaceholderTile(kind: display.isOwn ? .thisDevice : .otherMeow, size: rect.size)
            .frame(width: drawn.width, height: drawn.height)
            .position(x: drawn.midX, y: drawn.midY)
    }

    /// The name (and Mirrored badge) sit in the part of the tile that is on screen, at a size that
    /// grows with the tile, so a display zoomed past the screen still says what it is.
    @ViewBuilder private func labels(for display: OverviewDisplay, _ rect: CGRect) -> some View {
        let visible = interaction.visibleRect(of: rect)
        if visible.width >= 60, visible.height >= 28 {
            OverviewTileLabels(name: display.name.isEmpty ? String(localized: "Display") : display.name,
                               isMirrored: isMirrored(display),
                               fontSize: OverviewInteraction.labelPointSize(forTileHeight: rect.height))
                .frame(width: visible.width, height: visible.height)
                .position(x: visible.midX, y: visible.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func isMirrored(_ display: OverviewDisplay) -> Bool {
        interaction.model.mirrorGroups.contains { $0.primaryID == display.id }
    }

    private func accessibilityLabel(for display: OverviewDisplay) -> String {
        var parts = [display.name.isEmpty ? String(localized: "Display") : display.name]
        if display.isMain { parts.append(String(localized: "main display")) }
        if isMirrored(display) { parts.append(String(localized: "mirrored")) }
        return parts.joined(separator: ", ")
    }

    private func adjustSelection(_ direction: AccessibilityAdjustmentDirection) {
        switch direction {
        case .increment: animateCamera { interaction.select(.next) }
        case .decrement: animateCamera { interaction.select(.previous) }
        @unknown default: break
        }
    }

    // MARK: Actions

    private var selectedItem: CatalogDisplayItem? {
        interaction.model.selected.flatMap { id in model.catalog?.displays.first { $0.id == id } }
    }

    private var tiledSources: Set<UInt32> {
        Set(model.layout.tiles.values.compactMap { $0.source?.windowID })
    }

    /// Choosing a pane's source from the picker replaces that pane; otherwise the display goes in the
    /// pane the gallery would use.
    private var showTitle: String {
        model.replacingTile != nil ? String(localized: "Use Display") : String(localized: "Show in Pane")
    }

    private func canAddPane(_ item: CatalogDisplayItem) -> Bool {
        model.canAddTile && model.replacingTile == nil && !tiledSources.contains(WorkspaceSource.displayKey(item.id))
    }

    /// A display source cannot float on iOS, so there is no float action here.
    private func actionBar(fold: OverviewChromeFold.Split?) -> some View {
        Group {
            if let item = selectedItem, interaction.selectionCanBeShown {
                if let fold {
                    FoldAwareBar(fold: fold, horizontalPadding: 16) {
                        actionPrimary
                    } trailing: {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { secondaryActions(item) }.fixedSize(horizontal: true, vertical: false)
                            VStack(spacing: 4) { secondaryActions(item) }
                        }
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            actionPrimary
                            secondaryActions(item)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        VStack(spacing: 4) {
                            actionPrimary
                            secondaryActions(item)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else {
                Text("A MeowDisplay screen can’t be shown in a pane.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .accessibilityIdentifier("displayOverviewUnavailable")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.vertical, 4)
    }

    private var actionPrimary: some View {
        Button(action: showSelected) {
            Text(showTitle)
                .multilineTextAlignment(.center)
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent).tint(meowAccent)
        .accessibilityHint(model.replacingTile == nil ? Text("Opens the selected display.") : Text("Replaces the display in this pane."))
        .accessibilityIdentifier("displayOverviewShowInPane")
    }

    @ViewBuilder private func secondaryActions(_ item: CatalogDisplayItem) -> some View {
        if canAddPane(item) {
            Button { dismiss(); onAddAsNewPane(item) } label: {
                Text("New Pane").frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Add as New Pane")
            .accessibilityIdentifier("displayOverviewAddPane")
        }
        if model.canUseDisplayActions, model.canControlMac {
            Button { model.moveCursor(to: item) } label: {
                Text("Move Cursor").frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Move Cursor Here")
            .accessibilityIdentifier("displayOverviewMoveCursor")
        }
    }

    private func showSelected() {
        guard let item = selectedItem, interaction.selectionCanBeShown else { return }
        dismiss()
        onShowInPane(item)
    }

    // MARK: Updates

    private func refreshModel(_ displays: [CatalogDisplayItem]?) {
        let next = DisplayOverviewModel(catalog: displays ?? [])
        // The Mac went away (or locked): nothing of it is kept or shown here.
        if next.drawnDisplays.isEmpty {
            dismiss()
            return
        }
        interaction.update(model: next)
    }

    /// Reduce Motion: the camera jumps instead of gliding. Pan and pinch follow the finger either way.
    private func animateCamera(_ change: () -> Void) {
        if reduceMotion {
            change()
        } else {
            withAnimation(.easeInOut(duration: 0.3), change)
        }
    }
}

// MARK: - Tile views

/// One real display: its still filling the tile (aspect-fill), the main display's menu-bar strip
/// and a border that is the accent colour while selected. Only the part of the tile that is on
/// screen is laid out (`origin` places the tile's own top-left inside that part), so deep zoom
/// never builds a layer as large as the zoomed display.
private struct OverviewDisplayTile: View {
    let thumbnail: CGImage?
    /// The whole tile's size, view points.
    let fullSize: CGSize
    /// The tile's top-left relative to this view's top-left (zero or negative when cut off).
    let origin: CGPoint
    let isMain: Bool
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        shape.fill(Color(white: 0.08))
            .overlay { picture }
            // The menu bar's cue: the main display.
            .overlay(alignment: .top) { strip }
            .clipShape(shape)
            .overlay(shape.strokeBorder(isSelected ? meowAccent : Color.white.opacity(0.18),
                                        lineWidth: isSelected ? 3 : 0.75))
    }

    @ViewBuilder private var picture: some View {
        if let thumbnail, thumbnail.width > 0, thumbnail.height > 0 {
            let size = fillSize(for: thumbnail)
            Image(decorative: thumbnail, scale: 1).resizable().interpolation(.medium)
                .frame(width: size.width, height: size.height)
                .position(x: origin.x + fullSize.width / 2, y: origin.y + fullSize.height / 2)
        }
    }

    @ViewBuilder private var strip: some View {
        if isMain, origin.y > -3 {
            Rectangle().fill(Color.white.opacity(0.55)).frame(height: 3).offset(y: origin.y)
        }
    }

    /// The still scaled to cover `fullSize` without distortion (the overflow is clipped).
    private func fillSize(for image: CGImage) -> CGSize {
        let aspect = CGFloat(image.width) / CGFloat(image.height)
        guard fullSize.height > 0 else { return .zero }
        if fullSize.width / fullSize.height > aspect {
            return CGSize(width: fullSize.width, height: fullSize.width / aspect)
        }
        return CGSize(width: fullSize.height * aspect, height: fullSize.height)
    }
}

/// The name caption (bottom-left) and Mirrored badge (top-right) over the visible part of a tile.
/// The Mac cursor: a white arrow with a dark outline (four dark copies one point away), so it
/// reads over both light and dark pictures. The frame's top-left is the arrow's tip.
private struct OverviewCursorGlyphView: View {
    private static let outline: [CGSize] = [
        CGSize(width: 1, height: 0), CGSize(width: -1, height: 0),
        CGSize(width: 0, height: 1), CGSize(width: 0, height: -1),
    ]

    var body: some View {
        let side = CGFloat(OverviewCursorGlyph.pointSize)
        ZStack {
            ForEach(0..<Self.outline.count, id: \.self) { index in
                arrow(.black).offset(Self.outline[index])
            }
            arrow(.white)
        }
        .frame(width: side, height: side)
    }

    private func arrow(_ color: Color) -> some View {
        let side = CGFloat(OverviewCursorGlyph.pointSize)
        return Image(systemName: "cursorarrow")
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            .frame(width: side, height: side)
    }
}

private struct OverviewTileLabels: View {
    let name: String
    let isMirrored: Bool
    let fontSize: CGFloat

    var body: some View {
        Color.clear
            .overlay(alignment: .bottomLeading) { caption }
            .overlay(alignment: .topTrailing) { if isMirrored { badge } }
    }

    private var caption: some View {
        Text(name).font(.system(size: fontSize, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.5))
    }

    private var badge: some View {
        Text("Mirrored").font(.system(size: Swift.max(fontSize - 1, 9), weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.black.opacity(0.6), in: Capsule())
            .padding(6)
    }
}

// MARK: - Gestures

/// The touch surface over the canvas. SwiftUI's pinch (before iOS 17) reports no focal point, which
/// zooming about the fingers needs, so the recognizers are UIKit's; they report deltas for the
/// reducer to apply. Single and double taps both fire on a double-tap: the first only selects, so
/// the pair never fights and a single tap needs no delay.
private struct OverviewGestureSurface: UIViewRepresentable {
    let onPan: (CGVector) -> Void
    /// This step's scale factor, the fingers' midpoint, and how far the midpoint moved since the last step.
    let onPinch: (Double, CGPoint, CGVector) -> Void
    let onTap: (CGPoint) -> Void
    let onDoubleTap: (CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator
        coordinator.parent = self

        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        let doubleTap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        for recognizer in [pan, pinch, tap, doubleTap] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
            view.addGestureRecognizer(recognizer)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: OverviewGestureSurface?
        private var lastFocal: CGPoint = .zero

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view, recognizer.state == .began || recognizer.state == .changed else { return }
            let translation = recognizer.translation(in: view)
            recognizer.setTranslation(.zero, in: view)
            parent?.onPan(CGVector(dx: translation.x, dy: translation.y))
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view, recognizer.state == .began || recognizer.state == .changed else { return }
            let focal = recognizer.location(in: view)
            if recognizer.state == .began { lastFocal = focal }
            let translation = CGVector(dx: focal.x - lastFocal.x, dy: focal.y - lastFocal.y)
            lastFocal = focal
            let factor = Double(recognizer.scale)
            recognizer.scale = 1
            parent?.onPinch(factor, focal, translation)
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent?.onTap(recognizer.location(in: view))
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            parent?.onDoubleTap(recognizer.location(in: view))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// A bar of two groups. Without a fold they sit on one centred line, as before. With a vertical
/// fold the leading group fills the part before it and the trailing group the part after it, so
/// nothing is drawn or tapped on the crease.
private struct FoldAwareBar<Leading: View, Trailing: View>: View {
    let fold: OverviewChromeFold.Split?
    let horizontalPadding: CGFloat
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        if let fold {
            HStack(spacing: 0) {
                leading
                    .frame(width: max(0, fold.leading - horizontalPadding))
                Color.clear.frame(width: fold.gap)
                    .accessibilityHidden(true)
                trailing
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, horizontalPadding)
        } else {
            HStack(spacing: 12) {
                leading
                trailing
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalPadding)
        }
    }
}
