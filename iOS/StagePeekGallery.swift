import SwiftUI
import UIKit

// Stage Peek's floating pieces: the search pill, the Dock-like app carousel,
// the expanded window gallery (as many columns as fit) and Launchpad. Each is its
// own floating glass element over the unchanged Mac picture: no container
// panel behind them. Browsing here only reads; the Mac changes only through
// an explicit window tap (show it), "Open on Mac" or Close Window (both need control).

/// MeowDisplay blue.
let meowAccent = Color(red: 0.33, green: 0.60, blue: 1.0)

/// Translucent, softly bordered glass. Reduce Transparency: a dense, legible
/// dark surface instead of blur (still not pitch black).
struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                shape.fill(Color(white: 0.13).opacity(0.95))
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.16))
            }
            shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.30), radius: 14, x: 0, y: 6)
    }
}

extension View {
    func glass<S: InsettableShape>(_ shape: S) -> some View { background(GlassSurface(shape: shape)) }
}

// MARK: - Icons

struct MacAppIcon: View {
    @ObservedObject var model: WorkspaceModel
    let bundleID: String
    let name: String
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let cg = model.icons[bundleID] {
                Image(decorative: cg, scale: 1).resizable().interpolation(.high)
            } else if bundleID == MacAppItem.finderBundle {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.72, blue: 1), Color(red: 0.13, green: 0.45, blue: 0.95)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "face.smiling").font(.system(size: size * 0.55)).foregroundStyle(.white))
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .fill(Color.white.opacity(0.16))
                    .overlay(Text(String(name.prefix(1))).font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Search pill

struct StagePeekSearchPill: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var placeholder: String = String(localized: "Search apps and windows")

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.75))
            TextField(placeholder, text: $query)
                .focused(focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundStyle(.white)
                .tint(meowAccent)
                .accessibilityIdentifier("stagePeekSearch")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.7)) }
                    .accessibilityLabel("Clear Search")
            }
        }
        .font(.system(size: 16))
        .padding(.horizontal, 14)
        .frame(height: 42)
        .glass(Capsule())
        .contentShape(Capsule())
    }
}

// MARK: - Dock carousel

struct StagePeekDock: View {
    @ObservedObject var model: WorkspaceModel
    let apps: [MacAppItem]
    let selected: String?
    let onApp: (MacAppItem) -> Void
    var onDragEnded: (Bool) -> Void = { _ in }
    let onLaunchpad: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heldAt: CGPoint = .zero

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(apps) { app in
                    let isSelected = selected == app.bundleID
                    Button { onApp(app) } label: {
                        VStack(spacing: 3) {
                            MacAppIcon(model: model, bundleID: app.bundleID, name: app.name, size: 42)
                                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(meowAccent, lineWidth: isSelected ? 2.5 : 0).padding(-3))
                                .scaleEffect(isSelected && !reduceMotion ? 1.1 : 1)
                            Circle().fill(Color.white.opacity(app.running ? 0.85 : 0)).frame(width: 4, height: 4)
                        }
                    }
                    .buttonStyle(.plain)
                    // Tap picks it; press, hold and move drags the app onto a pane.
                    .overlay(GeometryReader { g in
                        StagePeekCardGestures.app(app, model: model, heldAt: $heldAt, origin: g.frame(in: .global).origin,
                                                  onTap: { onApp(app) }, onDragEnded: onDragEnded)
                    })
                    .onAppear { model.requestIcons([app.bundleID]) }
                    .accessibilityLabel(app.name)
                    .accessibilityValue(app.running ? (app.windowCount == 1 ? String(localized: "Running, 1 window")
                                                       : String(localized: "Running, \(app.windowCount) windows"))
                                                    : String(localized: "Not running"))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                Button(action: onLaunchpad) {
                    Image(systemName: "square.grid.3x3.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(Circle().fill(Color.white.opacity(0.16)))
                        .padding(.bottom, 7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("All Apps")
                .accessibilityIdentifier("stagePeekLaunchpad")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: selected)
        }
        .frame(height: 64)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

// MARK: - Cards

struct StagePeekWindowCard: View {
    @ObservedObject var model: WorkspaceModel
    let window: CatalogWindowItem
    let inTile: Bool
    let current: Bool
    var closing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07))
                preview
                    .padding(6)
                MacAppIcon(model: model, bundleID: window.bundleID, name: window.app, size: 28)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: -4, y: 6)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(alignment: .topTrailing) { badges.padding(6) }
            .overlay {
                if closing {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.55))
                        VStack(spacing: 6) {
                            ProgressView().tint(.white)
                            Text("Closing…").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(current ? meowAccent : Color.white.opacity(0.14), lineWidth: current ? 2.5 : 0.6))
            Text(window.title.isEmpty ? window.app : window.title)
                .font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.leading, 26)
            Text(window.app).font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                .padding(.leading, 26)
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title.isEmpty ? window.app : window.title), \(window.app)")
        .accessibilityValue(closing ? String(localized: "Closing")
                            : inTile ? String(localized: "Showing in a tile") : (window.pausedSpoken ?? ""))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("galleryWindowCard")
    }

    @ViewBuilder private var preview: some View {
        if let cg = model.thumbnails[window.id] {
            Image(decorative: cg, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(model.staleThumbnails.contains(window.id) ? 0.75 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 6) {
                MacAppIcon(model: model, bundleID: window.bundleID, name: window.app, size: 40)
                if !model.unavailableThumbnails.contains(window.id) { ProgressView().controlSize(.small).tint(.white) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 4) {
            if let paused = window.pausedBadge { badge(paused, window.minimized ? "minus.square" : "sidebar.left") }
            if inTile { badge(String(localized: "In Tile"), "rectangle.split.2x1") }
        }
    }

    private func badge(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

struct StagePeekDisplayCard: View {
    @ObservedObject var model: WorkspaceModel
    let display: CatalogDisplayItem
    let current: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07))
                if let cg = model.displayThumbnails[display.id] {
                    Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).padding(6)
                } else {
                    Image(systemName: "display").font(.system(size: 34)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(current ? meowAccent : Color.white.opacity(0.14), lineWidth: current ? 2.5 : 0.6))
            Label(display.isMain ? String(localized: "Full Desktop") : display.name, systemImage: "display")
                .font(.footnote.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
            Text(display.isMain ? display.name : (display.isVirtual ? String(localized: "Extended display") : String(localized: "Display")))
                .font(.caption2).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.isMain ? String(localized: "Full Desktop, \(display.name)") : display.name)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Expanded gallery

struct StagePeekGallery: View {
    @ObservedObject var model: WorkspaceModel
    let query: String
    let appFilter: MacAppItem?
    let inputAllowed: Bool
    let width: CGFloat
    let topInset: CGFloat
    let onWindow: (CatalogWindowItem) -> Void
    let onDisplay: (CatalogDisplayItem) -> Void
    let onApp: (MacAppItem) -> Void
    let onAddTile: (CatalogWindowItem) -> Void
    /// A card was dropped (or the drag ended): the peek decides whether to close.
    var onDragEnded: (Bool) -> Void = { _ in }
    /// Search the Mac's approved folders for the query (Remote Finder), when the Mac offers it.
    var onSearchFiles: ((String) -> Void)?
    /// The peek's edge: a sideways flick toward it (off the cards) compacts the gallery.
    var edge: StagePeekEdge = .left
    var onCompact: () -> Void = {}
    /// The gallery's visible height (Spatial Overview pages fill it).
    var height: CGFloat = 600
    @AppStorage(StagePeekExpandedLayout.storageKey) private var expandedLayout = StagePeekExpandedLayout.gallery.rawValue
    @State private var spatialPage = 0
    @State private var visible: [UInt32] = []
    @Environment(\.controlRequest) private var controlRequest
    /// The card showing its Close Window button (swiped left), and a swipe in progress.
    @State private var revealed: UInt32?
    @State private var swipe: (id: UInt32, dx: CGFloat)?
    /// The card lifted by a hold, and the point the hold began (window coordinates).
    @State private var held: UInt32?
    @State private var heldAt: CGPoint = .zero
    @State private var menuWindow: CatalogWindowItem?
    @State private var confirmClose: CatalogWindowItem?
    @State private var cardGestureClock = CardGestureClock()
    @Environment(\.horizontalSizeClass) private var horizontalSize
    @Environment(\.verticalSizeClass) private var verticalSize
    @ScaledMetric(relativeTo: .footnote) private var textScale: CGFloat = 1

    static let revealWidth: CGFloat = 96

    /// As many columns as fit at a readable size; phones and narrow split views two at most.
    private var columnCount: Int {
        StagePeekGalleryLayout.columns(width: width, compactSize: horizontalSize == .compact || verticalSize == .compact,
                                       textScale: textScale)
    }

    private var allWindows: [CatalogWindowItem] { model.catalog?.windows ?? [] }
    private var tiled: Set<UInt32> { Set(model.layout.tiles.values.compactMap { $0.source?.windowID }) }

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: StagePeekGalleryLayout.spacing, alignment: .top), count: columnCount)
        let results = WorkspaceSearch.search(query, apps: model.apps, windows: allWindows)
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                Color.clear.frame(height: topInset)
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    if !results.apps.isEmpty {
                        sectionTitle(String(localized: "Applications"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) { ForEach(results.apps.prefix(30)) { appChip($0) } }.padding(.horizontal, 2)
                        }
                    }
                    sectionTitle(String(localized: "Windows"))
                    if results.windows.isEmpty {
                        emptyText(results.apps.isEmpty ? String(localized: "No apps or windows match “\(query)”.") : String(localized: "No open windows match."))
                    } else {
                        grid(results.windows, cols)
                    }
                    if let onSearchFiles {
                        sectionTitle(String(localized: "Files"))
                        Button { onSearchFiles(query) } label: {
                            HStack(spacing: 10) {
                                kindIcon(.folder, size: 26)
                                Text("Search files on \(model.hostName) for “\(query)”").lineLimit(2)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .glass(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                } else if let app = appFilter {
                    let windows = allWindows.filter { $0.bundleID == app.bundleID }
                    appHeader(app, count: windows.count)
                    if windows.isEmpty { emptyApp(app) } else { windowsView(windows, cols) }
                } else {
                    if let displays = model.catalog?.displays, !displays.isEmpty {
                        sectionTitle(String(localized: "Displays"))
                        LazyVGrid(columns: cols, spacing: 16) {
                            ForEach(displays) { d in
                                let source = model.displayWindow(d)
                                StagePeekDisplayCard(model: model, display: d,
                                                     current: model.windowMode ? tiled.contains(WorkspaceSource.displayKey(d.id)) : d.isMain)
                                    .scaleEffect(held == source.id ? 1.04 : 1)
                                    // The desktop is a pane source too: hold and drag it onto a pane.
                                    .overlay(cardGestures(source, onTap: { onDisplay(d) }, swipe: false))
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction { onDisplay(d) }
                                    .accessibilityAction(named: "Show in Pane") { onDisplay(d) }
                            }
                        }
                    }
                    sectionTitle(String(localized: "Windows"))
                    if allWindows.isEmpty {
                        emptyText(model.catalog?.unavailable == true ? String(localized: "The Mac can't list its windows right now.")
                                  : (model.catalog == nil ? String(localized: "Loading windows…") : String(localized: "No windows are open on the Mac.")))
                    } else {
                        windowsView(allWindows, cols)
                    }
                }
                Color.clear.frame(height: 16)
            }
            .padding(.horizontal, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollDisabled(model.drag != nil)
        // A sideways flick toward the peek's edge compacts the gallery: not one that swiped
        // or held a card (those are the card's).
        .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { v in
            guard !cardGestureClock.recent, model.drag == nil else { return }
            let toward = edge == .left ? -v.translation.width : v.translation.width
            if toward > 90, toward > abs(v.translation.height) * 1.5 { onCompact() }
        })
        .onChange(of: visible) { model.thumbnailPriority = $0 }
        .onChange(of: model.closingWindows) { closing in if let r = revealed, closing.contains(r) { revealed = nil } }
        .confirmationDialog(menuWindow.map { $0.title.isEmpty ? $0.app : $0.title } ?? "",
                            isPresented: Binding(get: { menuWindow != nil }, set: { if !$0 { menuWindow = nil } }),
                            titleVisibility: .visible, presenting: menuWindow) { w in
            Button("Show in Pane") { onWindow(w) }
            if model.canAddTile, !tiled.contains(w.id) { Button("Add as New Pane") { onAddTile(w) } }
            if model.canCloseWindows { Button("Close Window on Mac", role: .destructive) { model.closeWindow(w) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(confirmClose.map { String(localized: "Close “\($0.title.isEmpty ? $0.app : $0.title)” on the Mac?") } ?? "",
                            isPresented: Binding(get: { confirmClose != nil }, set: { if !$0 { confirmClose = nil } }),
                            titleVisibility: .visible, presenting: confirmClose) { w in
            Button("Close Window", role: .destructive) { model.closeWindow(w) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Only this window closes; its app keeps running. If it has unsaved changes, the app asks on the Mac.")
        }
    }

    /// The window list in the chosen expanded layout (search results always use the grid).
    @ViewBuilder private func windowsView(_ windows: [CatalogWindowItem], _ cols: [GridItem]) -> some View {
        if expandedLayout == StagePeekExpandedLayout.spatial.rawValue { spatial(windows) } else { grid(windows, cols) }
    }

    /// Spatial Overview: each window at its shape and relative size, packed in rows; pages when
    /// they can't all be comfortably tappable. Same gestures as the grid's cards.
    private func spatial(_ windows: [CatalogWindowItem]) -> some View {
        let size = CGSize(width: max(width - 40, 200), height: max(height - 110, 220))
        let placements = SpatialOverviewLayout.layout(windows.map { .init(width: Double($0.width), height: Double($0.height)) }, in: size)
        let pages = (placements.map(\.page).max() ?? 0) + 1
        return TabView(selection: $spatialPage) {
            ForEach(0..<pages, id: \.self) { page in
                ZStack(alignment: .topLeading) {
                    Color.clear
                    ForEach(Array(zip(windows, placements)).filter { $0.1.page == page }, id: \.0.id) { w, p in
                        spatialCard(w).frame(width: p.rect.width, height: p.rect.height).offset(x: p.rect.minX, y: p.rect.minY)
                    }
                }
                .frame(width: size.width, height: size.height)
                .tag(page)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: pages > 1 ? .always : .never))
        .frame(width: size.width, height: size.height + (pages > 1 ? 24 : 0))
        .onChange(of: windows.count) { _ in spatialPage = min(spatialPage, max(pages - 1, 0)) }
    }

    private func spatialCard(_ w: CatalogWindowItem) -> some View {
        let closing = model.closingWindows.contains(w.id)
        let current = model.currentWindowID == w.id && model.windowMode
        return ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08))
            if let cg = model.thumbnails[w.id] {
                Image(decorative: cg, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .opacity(model.staleThumbnails.contains(w.id) || closing ? 0.6 : 1)
            } else {
                MacAppIcon(model: model, bundleID: w.bundleID, name: w.app, size: 32).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(w.title.isEmpty ? w.app : w.title).font(.caption2.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.black.opacity(0.55), in: Capsule()).padding(5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(current ? meowAccent : (tiled.contains(w.id) ? Color.white.opacity(0.6) : Color.white.opacity(0.18)), lineWidth: current ? 2.5 : 1))
        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
        .scaleEffect(held == w.id ? 1.04 : 1)
        .overlay(cardGestures(w, onTap: { onWindow(w) }, swipe: false))
        .overlay(alignment: .topLeading) {
            if model.canCloseWindows, inputAllowed, !closing {
                Button { confirmClose = w } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(Color.black.opacity(0.6)))
                        .frame(width: 36, height: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain).offset(x: -8, y: -8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(w.title.isEmpty ? w.app : w.title), \(w.app)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onWindow(w) }
        .accessibilityAction(named: "Add as New Pane") { if model.canAddTile, !tiled.contains(w.id) { onAddTile(w) } }
        .accessibilityAction(named: "Close Window") { if model.canCloseWindows { confirmClose = w } }
        .accessibilityIdentifier("spatialWindowCard")
    }

    private func grid(_ windows: [CatalogWindowItem], _ cols: [GridItem]) -> some View {
        LazyVGrid(columns: cols, spacing: 16) {
            ForEach(windows) { w in windowCell(w) }
        }
    }

    /// One window card: tap shows it, hold lifts it (drag to a pane, or lift in place for its
    /// menu), a swipe left reveals Close Window, and the X asks before closing.
    private func windowCell(_ w: CatalogWindowItem) -> some View {
        let closable = model.canCloseWindows
        let dx = swipe?.id == w.id ? swipe!.dx : (revealed == w.id ? -Self.revealWidth : 0)
        let closing = model.closingWindows.contains(w.id)
        let name = w.title.isEmpty ? w.app : w.title
        return ZStack(alignment: .trailing) {
            if dx < -1 {
                closeAction(w, width: min(-dx, Self.revealWidth + 40))
            }
            StagePeekWindowCard(model: model, window: w, inTile: tiled.contains(w.id),
                                current: model.currentWindowID == w.id && model.windowMode, closing: closing)
                .accessibilityAction { onWindow(w) }
                .accessibilityAction(named: "Show in Pane") { onWindow(w) }
                .accessibilityAction(named: "Add as New Pane") { if model.canAddTile, !tiled.contains(w.id) { onAddTile(w) } }
                .accessibilityAction(named: "Close Window") { if closable { confirmClose = w } }
                .scaleEffect(held == w.id ? 1.04 : 1)
                .overlay(cardGestures(w, onTap: { onWindow(w) }, swipe: closable && !closing))
                .overlay(alignment: .topLeading) {
                    if closable, inputAllowed, !closing, dx == 0 {
                        Button { confirmClose = w } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.6))
                                .frame(width: 40, height: 40)   // a comfortable target, drawn small
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: -6, y: -6)
                        .accessibilityLabel("Close Window \(name)")
                    }
                }
                .offset(x: dx)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: revealed)
        .onAppear { if !visible.contains(w.id) { visible.append(w.id) } }
        .onDisappear { visible.removeAll { $0 == w.id }; if revealed == w.id { revealed = nil } }
    }

    /// The red Close Window button a swipe left reveals. Without control it explains instead.
    private func closeAction(_ w: CatalogWindowItem, width: CGFloat) -> some View {
        Button {
            revealed = nil
            if inputAllowed { model.closeWindow(w) } else { controlRequest?.request() }   // never closes after a grant by itself
        } label: {
            VStack(spacing: 4) {
                Image(systemName: inputAllowed ? "xmark.square" : "lock").font(.system(size: 18, weight: .semibold))
                Text(inputAllowed ? String(localized: "Close Window") : (controlRequest?.gatedLabel ?? String(localized: "Needs Control")))
                    .font(.caption2.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
            }
            .foregroundStyle(.white)
            .frame(width: max(width - 8, 0))
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(inputAllowed ? Color.red : Color.gray))
        }
        .buttonStyle(.plain)
        .opacity(min(1, width / 60))
        .accessibilityLabel(inputAllowed ? String(localized: "Close Window") : String(localized: "Close Window needs control. Request Control"))
    }

    /// The UIKit gestures for one card (they share each touch with the scroll view).
    private func cardGestures(_ w: CatalogWindowItem, onTap: @escaping () -> Void, swipe swipeEnabled: Bool) -> some View {
        GeometryReader { g in cardGestures(w, onTap: onTap, swipe: swipeEnabled, origin: g.frame(in: .global).origin) }
    }

    private func cardGestures(_ w: CatalogWindowItem, onTap: @escaping () -> Void, swipe swipeEnabled: Bool, origin: CGPoint) -> StagePeekCardGestures {
        StagePeekCardGestures(
            onTap: {
                guard model.drag == nil else { return }
                // A tap while a Close Window button shows only puts the card back.
                if revealed != nil { revealed = nil; return }
                onTap()
            },
            onHold: { p in
                cardGestureClock.mark()
                revealed = nil
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { held = w.id }
                heldAt = p
            },
            onHoldMove: { p in
                cardGestureClock.mark()
                if model.drag == nil {
                    // Moving after the hold drags the card: over a pane, an edge splits, the
                    // middle replaces, its labels add a tab. Cancel (or nowhere) changes nothing.
                    guard hypot(p.x - heldAt.x, p.y - heldAt.y) > StagePeekCardGestures.Coordinator.moveSlop else { return }
                    model.beginDrag(.window(w), at: p)
                } else {
                    model.moveDrag(to: p)
                }
            },
            onHoldEnd: { p, moved in
                cardGestureClock.mark()
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { held = nil }
                if model.drag != nil {
                    model.moveDrag(to: p)
                    let dropped = model.endDrag()
                    if dropped { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7) }
                    onDragEnded(dropped)
                } else if !moved, allWindows.contains(where: { $0.id == w.id }) {
                    menuWindow = w   // held in place: the window's actions
                }
            },
            onHoldCancel: {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { held = nil }
                if model.drag != nil { model.cancelDrag() }
            },
            swipeEnabled: swipeEnabled,
            onSwipe: { dx in
                cardGestureClock.mark()
                if let r = revealed, r != w.id { revealed = nil }
                let base: CGFloat = revealed == w.id ? -Self.revealWidth : 0
                var x = base + dx
                if x > 0 { x *= 0.25 }
                if x < -Self.revealWidth { x = -Self.revealWidth + (x + Self.revealWidth) * 0.3 }
                swipe = (w.id, x)
            },
            onSwipeEnd: { _, velocity in
                cardGestureClock.mark()
                let x = swipe?.id == w.id ? swipe!.dx : 0
                let open = velocity < -400 || (x < -Self.revealWidth / 2 && velocity < 300)
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    revealed = open ? w.id : (revealed == w.id ? nil : revealed)
                    swipe = nil
                }
                if open { UISelectionFeedbackGenerator().selectionChanged() }
            },
            globalOrigin: origin)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
            .shadow(color: .black.opacity(0.5), radius: 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    private func appChip(_ app: MacAppItem) -> some View {
        Button { onApp(app) } label: {
            VStack(spacing: 4) {
                MacAppIcon(model: model, bundleID: app.bundleID, name: app.name, size: 48)
                Text(app.name).font(.caption2).foregroundStyle(.white).lineLimit(1).frame(width: 72)
                Text(app.running ? (app.windowCount > 0 ? String(localized: "\(app.windowCount) open") : String(localized: "Running"))
                                 : String(localized: "Not running"))
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.65))
            }
        }
        .buttonStyle(.plain)
        .overlay(GeometryReader { g in
            StagePeekCardGestures.app(app, model: model, heldAt: $heldAt, clock: cardGestureClock, origin: g.frame(in: .global).origin,
                                      onTap: { onApp(app) }, onDragEnded: onDragEnded)
        })
        .onAppear { model.requestIcons([app.bundleID]) }
        .accessibilityLabel(app.name)
    }

    private func appHeader(_ app: MacAppItem, count: Int) -> some View {
        HStack(spacing: 12) {
            MacAppIcon(model: model, bundleID: app.bundleID, name: app.name, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.headline).foregroundStyle(.white)
                Text(count > 0 ? (count == 1 ? String(localized: "1 window") : String(localized: "\(count) windows"))
                     : (app.running ? String(localized: "Running, no open windows") : String(localized: "Not running")))
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
            }
            Spacer()
        }
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    private func emptyApp(_ app: MacAppItem) -> some View {
        VStack(spacing: 12) {
            MacAppIcon(model: model, bundleID: app.bundleID, name: app.name, size: 72)
            Text(app.running ? String(localized: "\(app.name) has no windows you can show.") : String(localized: "\(app.name) isn't open on the Mac."))
                .font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
            if model.launching.contains(app.bundleID) {
                ProgressView(String(localized: "Opening on the Mac…")).tint(.white).foregroundStyle(.white)
            } else {
                Button { model.launch(app.bundleID) } label: {
                    Label("Open on Mac", systemImage: "arrow.up.forward.app").font(.body.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                }
                .buttonStyle(.plain).foregroundStyle(.white)
                .glass(Capsule())
                .disabled(!inputAllowed)
                .opacity(inputAllowed ? 1 : 0.5)
                .accessibilityIdentifier("stagePeekOpenOnMac")
                if !inputAllowed {
                    Text("Opening apps needs control of the Mac.")
                        .font(.caption).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                    RequestControlInline(compact: true)
                }
                if model.launchFailed == app.bundleID {
                    Text("The Mac couldn't open \(app.name).").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// When a card last swiped or was held, so the gallery's own flick ignores that touch.
final class CardGestureClock {
    private var last: TimeInterval = 0
    func mark() { last = CACurrentMediaTime() }
    var recent: Bool { CACurrentMediaTime() - last < 0.8 }
}

// MARK: - Launchpad

/// Every Mac app as a searchable grid: Favorites, Recents, Running, All.
/// Picking an app shows its windows (or its empty state); nothing launches by itself.
struct StagePeekLaunchpad: View {
    @ObservedObject var model: WorkspaceModel
    let inputAllowed: Bool
    let onPick: (MacAppItem) -> Void
    let onClose: () -> Void
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("stagePeek.favorites") private var favoritesRaw = ""

    private var favorites: [String] { favoritesRaw.split(separator: "\n").map(String.init) }

    private func toggleFavorite(_ bundle: String) {
        var f = favorites
        if let i = f.firstIndex(of: bundle) { f.remove(at: i) } else { f.append(bundle) }
        favoritesRaw = f.joined(separator: "\n")
    }

    var body: some View {
        let apps = model.apps
        let filtered = query.isEmpty ? apps : WorkspaceSearch.search(query, apps: apps, windows: []).apps
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                StagePeekSearchPill(query: $query, focused: $searchFocused, placeholder: String(localized: "Search all apps"))
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 42, height: 42).glass(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close All Apps")
            }
            .frame(maxWidth: 560)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if apps.isEmpty {
                        ProgressView(String(localized: "Loading apps…")).tint(.white).foregroundStyle(.white).frame(maxWidth: .infinity).padding(40)
                    } else if query.isEmpty {
                        let favs = favorites.compactMap { b in apps.first { $0.bundleID == b } }
                        if !favs.isEmpty { section(String(localized: "Favorites"), favs) }
                        let recents = WorkspaceSearch.recents(apps)
                        if !recents.isEmpty { section(String(localized: "Recent"), recents) }
                        let running = apps.filter(\.running)
                        if !running.isEmpty { section(String(localized: "Running"), running) }
                        section(String(localized: "All Apps"), apps)
                    } else if filtered.isEmpty {
                        Text("No apps match “\(query)”.").foregroundStyle(.white.opacity(0.8)).frame(maxWidth: .infinity).padding(30)
                    } else {
                        section(String(localized: "Results"), filtered)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .padding(.top, 12)
    }

    private func section(_ title: String, _ list: [MacAppItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85)).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 14) {
                ForEach(list) { app in
                    Button { onPick(app) } label: {
                        VStack(spacing: 4) {
                            MacAppIcon(model: model, bundleID: app.bundleID, name: app.name, size: 54)
                                .overlay(alignment: .topTrailing) {
                                    if favorites.contains(app.bundleID) {
                                        Image(systemName: "star.fill").font(.system(size: 11)).foregroundStyle(.yellow).offset(x: 4, y: -4)
                                    }
                                }
                            Text(app.name).font(.caption2).foregroundStyle(.white).lineLimit(1)
                            Circle().fill(Color.white.opacity(app.running ? 0.85 : 0)).frame(width: 4, height: 4)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .onAppear { model.requestIcons([app.bundleID]) }
                    .contextMenu {
                        Button { toggleFavorite(app.bundleID) } label: {
                            favorites.contains(app.bundleID) ? Label("Remove from Favorites", systemImage: "star.slash")
                                : Label("Add to Favorites", systemImage: "star")
                        }
                        Button { onPick(app) } label: { Label("Show Windows", systemImage: "macwindow.on.rectangle") }
                        if inputAllowed {
                            Button { model.launch(app.bundleID) } label: { Label("Open on Mac", systemImage: "arrow.up.forward.app") }
                        }
                    }
                    .accessibilityLabel(app.name)
                    .accessibilityValue((app.running ? String(localized: "Running") : String(localized: "Not running"))
                                        + (favorites.contains(app.bundleID) ? ", " + String(localized: "Favorite") : ""))
                }
            }
        }
    }
}
