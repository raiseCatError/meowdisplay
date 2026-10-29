import SwiftUI
import UIKit

// Stage Peek's floating pieces: the search pill, the Dock-like app carousel,
// the expanded window gallery (two columns at most) and Launchpad. Each is its
// own floating glass element over the unchanged Mac picture: no container
// panel behind them. Browsing here only reads; the Mac changes only through
// an explicit window tap (show it) or "Open on Mac" (needs control).

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
    let onLaunchpad: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .accessibilityValue(inTile ? String(localized: "Showing in a tile") : (window.minimized ? String(localized: "Minimized") : ""))
        .accessibilityAddTraits(.isButton)
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
            if window.minimized { badge(String(localized: "Minimized"), "minus.square") }
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
    @State private var visible: [UInt32] = []

    /// Two columns at most; one when two would make cards too small.
    static func columns(for width: CGFloat) -> Int { width - 40 >= 2 * 176 + 14 ? 2 : 1 }

    private var allWindows: [CatalogWindowItem] { model.catalog?.windows ?? [] }
    private var tiled: Set<UInt32> { Set(model.layout.tiles.values.compactMap { $0.source?.windowID }) }

    var body: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: Self.columns(for: width))
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
                } else if let app = appFilter {
                    let windows = allWindows.filter { $0.bundleID == app.bundleID }
                    appHeader(app, count: windows.count)
                    if windows.isEmpty { emptyApp(app) } else { grid(windows, cols) }
                } else {
                    if let displays = model.catalog?.displays, !displays.isEmpty {
                        sectionTitle(String(localized: "Displays"))
                        LazyVGrid(columns: cols, spacing: 16) {
                            ForEach(displays) { d in
                                Button { onDisplay(d) } label: { StagePeekDisplayCard(model: model, display: d, current: !model.windowMode && d.isMain) }
                                    .buttonStyle(.plain)
                            }
                        }
                    }
                    sectionTitle(String(localized: "Windows"))
                    if allWindows.isEmpty {
                        emptyText(model.catalog?.unavailable == true ? String(localized: "The Mac can't list its windows right now.")
                                  : (model.catalog == nil ? String(localized: "Loading windows…") : String(localized: "No windows are open on the Mac.")))
                    } else {
                        grid(allWindows, cols)
                    }
                }
                Color.clear.frame(height: 40)
            }
            .padding(.horizontal, 20)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollDisabled(model.drag != nil)
        .onChange(of: visible) { model.thumbnailPriority = $0 }
    }

    private func grid(_ windows: [CatalogWindowItem], _ cols: [GridItem]) -> some View {
        LazyVGrid(columns: cols, spacing: 16) {
            ForEach(windows) { w in
                StagePeekWindowCard(model: model, window: w, inTile: tiled.contains(w.id), current: model.currentWindowID == w.id && model.windowMode)
                    .onTapGesture { if model.drag == nil { onWindow(w) } }
                    // Hold, then drag onto a pane: middle replaces, its labels add a tab, an edge splits.
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.35)
                            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                            .onChanged { value in
                                guard case .second(true, let drag) = value else { return }
                                if model.drag == nil {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    model.beginDrag(.window(w), at: drag?.location ?? .zero)
                                } else if let drag {
                                    model.moveDrag(to: drag.location)
                                }
                            }
                            .onEnded { _ in
                                guard model.drag != nil else { return }
                                let dropped = model.endDrag()
                                if dropped { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7) }
                                onDragEnded(dropped)
                            })
                    .accessibilityAction(named: "Show in Pane") { onWindow(w) }
                    .accessibilityAction(named: "Add as New Pane") { if model.canAddTile, !tiled.contains(w.id) { onAddTile(w) } }
                    .onAppear { if !visible.contains(w.id) { visible.append(w.id) } }
                    .onDisappear { visible.removeAll { $0 == w.id } }
            }
        }
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
                    Text("Opening apps needs control of the Mac. Use Request Control first.")
                        .font(.caption).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
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
                    .accessibilityValue(app.running ? String(localized: "Running") : String(localized: "Not running"))
                }
            }
        }
    }
}
