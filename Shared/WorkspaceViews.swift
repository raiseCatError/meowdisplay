import SwiftUI

// Window mode's views for the Apple receivers (iPhone, iPad, Mac Receiver),
// drawn over the live picture. Same design and wording as Android
// (AndroidReceiver/.../workspace/WorkspaceOverlay.kt). Only pills, menus and
// (in Arrange) divider grips take touches; the rest of a tile goes to the Mac.

private let workspaceAccent = Color(red: 0.50, green: 0.70, blue: 1.0)
private let workspaceChip = Color(white: 0.11, opacity: 0.8)

private extension WorkspaceRect {
    func onScreen(_ picture: CGRect) -> CGRect {
        CGRect(x: picture.minX + x * picture.width, y: picture.minY + y * picture.height,
               width: width * picture.width, height: height * picture.height)
    }
}

/// Tile borders, state badges, title pills with the tile menu, drag-to-move
/// with a drop preview, and divider grips while arranging. `picture` is where
/// the Mac's picture is drawn, in this view's coordinates.
struct WorkspaceChromeView: View {
    @ObservedObject var model: WorkspaceModel
    let picture: CGRect
    let inputAllowed: Bool
    /// Separating folds/hinges in this view's coordinates: nothing interactive is placed inside them.
    var divisions: [CGRect] = []
    @State private var dragging: String?
    @State private var dragPoint: CGPoint?
    @State private var confirmClose: String?
    @State private var lastDividerTranslation: CGSize = .zero

    private var size: WorkspaceSize { WorkspaceSize(width: picture.width, height: picture.height) }

    private func normalized(_ p: CGPoint) -> WorkspacePoint {
        WorkspacePoint(x: (p.x - picture.minX) / max(picture.width, 1), y: (p.y - picture.minY) / max(picture.height, 1))
    }

    /// The first division that crosses the picture, as a hinge in canvas coordinates.
    private var hinge: WorkspaceHinge? {
        guard picture.width > 0, picture.height > 0, let d = divisions.first?.intersection(picture), !d.isNull else { return nil }
        let r = WorkspaceRect(x: (d.minX - picture.minX) / picture.width, y: (d.minY - picture.minY) / picture.height,
                              width: d.width / picture.width, height: d.height / picture.height)
        let vertical = d.height >= d.width
        if vertical, r.x <= 0.05 || r.maxX >= 0.95 { return nil }
        if !vertical, r.y <= 0.05 || r.maxY >= 0.95 { return nil }
        return vertical ? WorkspaceHinge(rect: WorkspaceRect(x: r.x, y: 0, width: r.width, height: 1), orientation: .vertical)
                        : WorkspaceHinge(rect: WorkspaceRect(x: 0, y: r.y, width: 1, height: r.height), orientation: .horizontal)
    }

    var body: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)
                .onAppear { model.updateSpace(size, hinge: hinge) }
                .onChange(of: picture) { _ in model.updateSpace(size, hinge: hinge) }
                .onChange(of: divisions) { _ in model.updateSpace(size, hinge: hinge) }
            chrome
        }
    }

    @ViewBuilder
    private var chrome: some View {
        if model.windowMode, picture.width > 0 {
            let frames = model.frames
            let multi = model.layout.tiles.count > 1
            ZStack(alignment: .topLeading) {
                ForEach(Array(frames.tiles.keys).sorted(), id: \.self) { id in
                    if let rect = frames.tiles[id], let tile = model.layout.tiles[id] {
                        tileView(id: id, tile: tile, rect: rect.onScreen(picture), multi: multi, frames: frames)
                    }
                }
                if let d = dragging, let p = dragPoint,
                   let target = WorkspaceGeometry.dropTarget(at: normalized(p), frames: frames, size: size, canSplit: true) {
                    let r = target.previewRect.onScreen(picture)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(workspaceAccent.opacity(target.isSlot ? 0.18 : 0.28))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(workspaceAccent, lineWidth: 2))
                        .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .id(d)
                }
                if model.arranging { arrangeControls(frames) }
            }
            .coordinateSpace(name: "workspace")
            .alert(closeTitle, isPresented: Binding(get: { confirmClose != nil }, set: { if !$0 { confirmClose = nil } })) {
                Button("Close Window", role: .destructive) { if let id = confirmClose { model.closeRemoteWindow(id) }; confirmClose = nil }
                Button("Cancel", role: .cancel) { confirmClose = nil }
            } message: {
                Text("The window closes on the Mac itself, as if you clicked its close button. Unsaved work may ask to be saved there.")
            }
        }
    }

    private var closeTitle: String {
        let name = confirmClose.flatMap { model.tileState($0)?.app }.flatMap { $0.isEmpty ? nil : $0 } ?? "this window"
        return "Close \(name) on the Mac?"
    }

    private func status(for id: String, tile: WorkspaceTile) -> String? {
        if model.missing.contains(id) || tile.source == nil { return "Choose a window for this tile" }
        guard let remote = model.tileState(id) else { return nil }
        let app = remote.app.isEmpty ? "This window" : remote.app
        switch remote.status {
        case .live: return nil
        case .waiting: return "Waiting for \(remote.app.isEmpty ? "the window" : remote.app)…"
        case .offscreen: return "\(app) is minimized or hidden on the Mac"
        case .closed: return "This window was closed. Tap to choose another."
        case .failed: return "Can't show this window right now"
        case .limit: return "Paused: too many windows at once"
        }
    }

    @ViewBuilder
    private func tileView(id: String, tile: WorkspaceTile, rect: CGRect, multi: Bool, frames: WorkspaceFrames) -> some View {
        let active = model.active == id
        let hovered = model.hovered == id && !active
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(active && multi ? workspaceAccent : Color.white.opacity(hovered ? 0.35 : (multi ? 0.12 : 0)),
                              lineWidth: active && multi ? 2 : (hovered ? 1 : 0.5))
                .allowsHitTesting(false)
            if let text = status(for: id, tile: tile) {
                Button { model.openOverview(replacing: id) } label: {
                    Text(text).font(.callout).foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(workspaceChip, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if multi || model.arranging { pill(id: id, tile: tile, active: active, rect: rect) }
            if active, model.remote?.hostFocus.isMismatch == true {
                Button { model.focus(id) } label: {
                    Text(model.remote?.hostFocus == .otherWindowFocused
                         ? "Typing paused: another window is in front on the Mac. Tap to resume."
                         : "Typing paused: another app is in front on the Mac. Tap to resume.")
                        .font(.caption).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(workspaceChip, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(8)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }

    private func pill(id: String, tile: WorkspaceTile, active: Bool, rect: CGRect) -> some View {
        let remoteName = model.tileState(id)?.app ?? ""
        let name = !remoteName.isEmpty ? remoteName : (model.catalog?.windows.first { $0.id == tile.source?.windowID }?.app ?? "Window")
        return Menu {
            Button("Type Here") { model.focus(id) }
            Button("Change Window…") { model.openOverview(replacing: id) }
            Button("Rotate") { model.rotate(id) }
            Button(tile.fit == .fill ? "Show Whole Window" : "Fill Tile") { model.toggleFit(id) }
            Button(model.layout.maximized == id ? "Restore Layout" : "Maximize") { model.toggleMaximize(id) }
            Button("Arrange Tiles") { model.arranging = true }
            Button("Remove Tile") { model.removeTile(id) }
            Button("Close Window on Mac…", role: .destructive) { confirmClose = id }.disabled(!inputAllowed)
        } label: {
            HStack(spacing: 6) {
                if let bundle = tile.source?.bundleID, let icon = model.icons[bundle] {
                    Image(decorative: icon, scale: 1).resizable().frame(width: 16, height: 16)
                }
                Text(name).font(.caption.weight(.medium)).lineLimit(1).frame(maxWidth: 160, alignment: .leading)
            }
            .foregroundStyle(active ? Color.black : Color.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(active ? workspaceAccent.opacity(0.9) : workspaceChip, in: Capsule())
        }
        .padding(6)
        .accessibilityLabel("\(name) tile options" + (active ? ", typing goes here" : ""))
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).sequenced(before: DragGesture(coordinateSpace: .named("workspace")))
                .onChanged { value in
                    if case .second(true, let drag?) = value { dragging = id; dragPoint = drag.location }
                }
                .onEnded { _ in
                    if let d = dragging, let p = dragPoint,
                       let target = WorkspaceGeometry.dropTarget(at: normalized(p), frames: model.frames, size: size, canSplit: true) {
                        model.move(d, to: target)
                    }
                    dragging = nil; dragPoint = nil
                })
    }

    @ViewBuilder
    private func arrangeControls(_ frames: WorkspaceFrames) -> some View {
        ForEach(Array(frames.dividers.enumerated()), id: \.offset) { _, divider in
            let r = divider.hitRect.onScreen(picture)
            let horizontal = divider.axis == .horizontal
            Capsule().fill(Color.white.opacity(0.85))
                .frame(width: horizontal ? 6 : 44, height: horizontal ? 44 : 6)
                .frame(width: r.width, height: r.height)
                .contentShape(Rectangle())
                .position(x: r.midX, y: r.midY)
                // Measured in the workspace, not the grip: the grip moves with each step.
                .gesture(DragGesture(coordinateSpace: .named("workspace"))
                    .onChanged { v in
                        // The change since the last event, as a share of the picture.
                        let dx = v.translation.width - lastDividerTranslation.width
                        let dy = v.translation.height - lastDividerTranslation.height
                        lastDividerTranslation = v.translation
                        model.resize(divider, delta: horizontal ? dx / max(picture.width, 1) : dy / max(picture.height, 1))
                    }
                    .onEnded { _ in
                        lastDividerTranslation = .zero
                        model.endResize()
                    })
                .accessibilityLabel("Resize tiles")
        }
        HStack {
            if model.canUndo { Button("Undo") { model.undo() } }
            Button { model.arranging = false } label: { Text("Done").fontWeight(.semibold) }
        }
        .padding(8)
        .background(workspaceChip, in: Capsule())
        .position(x: picture.midX, y: picture.maxY - 44)
    }
}

private extension WorkspaceDropTarget {
    var previewRect: WorkspaceRect {
        switch self {
        case .slot(_, let p): return p
        case .split(_, _, let p): return p
        }
    }
    var isSlot: Bool { if case .slot = self { return true }; return false }
}

/// The collapsible rail: a thin handle at rest, a strip of windows when open.
struct WindowRailView: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        if model.available {
            let vertical = model.railEdge == .left || model.railEdge == .right
            let alignment: Alignment = switch model.railEdge {
            case .top: .top
            case .bottom: .bottom
            case .left: .leading
            case .right: .trailing
            }
            ZStack(alignment: alignment) {
                Color.clear.allowsHitTesting(false)
                if model.railExpanded { expanded(vertical: vertical) } else { handle(vertical: vertical) }
            }
        }
    }

    private func handle(vertical: Bool) -> some View {
        let current = model.active.flatMap { model.tileState($0)?.app }.flatMap { $0.isEmpty ? nil : $0 }
        return Button { model.railExpanded = true } label: {
            Group {
                if let current, !vertical {
                    Text(current).font(.caption2).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 3)
                        .background(workspaceChip, in: Capsule())
                } else {
                    Capsule().fill(Color.white.opacity(0.7)).frame(width: vertical ? 5 : 36, height: vertical ? 36 : 5)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show windows" + (current.map { ", now \($0)" } ?? ""))
    }

    private func expanded(vertical: Bool) -> some View {
        let windows = model.catalog?.windows ?? []
        let controls = Group {
            Button("All Windows") { model.openOverview() }
            Button("Arrange") { model.arranging = true; model.railExpanded = false }
            Menu("Move Rail") { ForEach(WorkspaceRailEdge.allCases, id: \.self) { e in Button(e.rawValue.capitalized) { model.railEdge = e } } }
            Button("Hide") { model.railExpanded = false }
        }
        let cards = ForEach(windows.prefix(30)) { w in
            RailCard(window: w, thumbnail: model.thumbnails[w.id],
                     current: model.layout.tiles.values.contains { $0.source?.windowID == w.id },
                     onPick: { model.choose(w, asNewTile: false) },
                     onAdd: model.layout.tiles.count < model.capacity ? { model.choose(w, asNewTile: true) } : nil)
        }
        return Group {
            if vertical {
                ScrollView { VStack(alignment: .leading, spacing: 6) { controls; cards } .padding(6) }
                    .frame(width: 168)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) { HStack { controls } }
                    ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) { cards } }
                    if windows.isEmpty { Text("Looking for windows…").font(.footnote).foregroundStyle(.secondary) }
                }
                .padding(6)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(white: 0.11, opacity: 0.95), in: RoundedRectangle(cornerRadius: 16))
        .padding(6)
    }
}

private struct RailCard: View {
    let window: CatalogWindowItem
    let thumbnail: CGImage?
    let current: Bool
    let onPick: () -> Void
    let onAdd: (() -> Void)?

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 2) {
                ZStack(alignment: .topTrailing) {
                    Rectangle().fill(Color(white: 0.18))
                    if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFit() }
                    if let onAdd {
                        Button(action: onAdd) { Text("+").padding(.horizontal, 8).padding(.vertical, 2).background(workspaceChip, in: Circle()) }
                            .buttonStyle(.plain).foregroundStyle(.white)
                            .accessibilityLabel("Add \(window.app) as a new tile")
                    }
                }
                .frame(width: 132, height: 64)
                Text(window.app).font(.caption2).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(current ? workspaceAccent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(window.app): \(window.title.isEmpty ? "window" : window.title)")
        .accessibilityValue(current ? "Showing" : "")
    }
}

/// Mission Control-style overview: every shareable window grouped by app, plus layouts and whole-display modes.
struct WindowOverviewView: View {
    @ObservedObject var model: WorkspaceModel
    let macName: String
    let inputAllowed: Bool
    let onMirror: () -> Void
    let onExtend: () -> Void
    @State private var query = ""

    var body: some View {
        if model.overviewOpen {
            let catalog = model.catalog
            let windows = catalog?.search(query) ?? []
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(model.replacingTile != nil ? "Choose a window for this tile" : "Windows on \(macName)")
                        .font(.title2.weight(.semibold)).foregroundStyle(.white)
                    Spacer()
                    Button("Done") { model.closeOverview() }.keyboardShortcut(.cancelAction)
                }
                TextField("Search windows and apps", text: $query).textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Text("Whole display:").foregroundStyle(.white.opacity(0.7))
                    Button("Mirror") { model.closeOverview(); onMirror() }.buttonStyle(.bordered)
                    Button("Extend") { model.closeOverview(); onExtend() }.buttonStyle(.bordered)
                }
                if model.windowMode { WorkspacePresetsView(capacity: model.capacity, tileCount: model.layout.tiles.count) { model.apply($0) } }
                if !model.stacked.isEmpty {
                    Text("Hidden on this screen").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                    ScrollView(.horizontal) {
                        HStack { ForEach(model.stacked, id: \.self) { id in
                            Button(model.tileState(id)?.app.isEmpty == false ? model.tileState(id)!.app : "Window") { model.bringBack(id); model.closeOverview() }
                                .buttonStyle(.bordered)
                        } }
                    }
                }
                if catalog == nil {
                    Text("Asking \(macName) for its windows…").foregroundStyle(.white.opacity(0.7))
                } else if catalog?.unavailable == true {
                    Text("\(macName) can't list its windows right now. Check that MeowDisplay has Screen Recording permission on the Mac.")
                        .foregroundStyle(.white.opacity(0.8))
                } else if windows.isEmpty, !query.isEmpty {
                    Text("No windows match \"\(query)\".").foregroundStyle(.white.opacity(0.7))
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                        ForEach(windows) { w in
                            OverviewCard(window: w, thumbnail: model.thumbnails[w.id], icon: model.icons[w.bundleID],
                                         current: model.layout.tiles.values.contains { $0.source?.windowID == w.id },
                                         onPick: { model.choose(w, asNewTile: false) },
                                         onAdd: model.replacingTile == nil && (1..<max(model.capacity, 1)).contains(model.layout.tiles.count)
                                             ? { model.choose(w, asNewTile: true) } : nil)
                        }
                    }
                    appSections(catalog)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(white: 0.06, opacity: 0.97).ignoresSafeArea())
        }
    }

    @ViewBuilder
    private func appSections(_ catalog: WorkspaceCatalogMessage?) -> some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let noWindow = (catalog?.apps ?? []).filter { !$0.hasWindows && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q)) }
        let installed = (catalog?.installed ?? []).filter { q.isEmpty || $0.name.localizedCaseInsensitiveContains(q) }
        VStack(alignment: .leading, spacing: 6) {
            if !noWindow.isEmpty {
                Text("Running, no open window").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7)).padding(.top, 8)
                ForEach(noWindow, id: \.bundleID) { app in appRow(app.name, bundle: app.bundleID, action: "Bring Forward") }
            }
            if !installed.isEmpty {
                Text(inputAllowed ? "Open an app" : "Open an app (needs control of the Mac)")
                    .font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.7)).padding(.top, 8)
                ForEach(installed, id: \.bundleID) { app in appRow(app.name, bundle: app.bundleID, action: "Open") }
            }
        }
    }

    private func appRow(_ name: String, bundle: String, action: String) -> some View {
        HStack {
            if let icon = model.icons[bundle] { Image(decorative: icon, scale: 1).resizable().frame(width: 22, height: 22) }
            Text(name).foregroundStyle(.white).lineLimit(1)
            Spacer()
            Button(action) { model.launch(bundle) }.disabled(!inputAllowed)
        }
        .padding(8)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct OverviewCard: View {
    let window: CatalogWindowItem
    let thumbnail: CGImage?
    let icon: CGImage?
    let current: Bool
    let onPick: () -> Void
    let onAdd: (() -> Void)?

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Rectangle().fill(Color(white: 0.17))
                    if let thumbnail { Image(decorative: thumbnail, scale: 1).resizable().scaledToFit() }
                    else if let icon { Image(decorative: icon, scale: 1).resizable().frame(width: 40, height: 40) }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if window.minimized {
                        Text("Minimized").font(.caption2).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(workspaceChip, in: RoundedRectangle(cornerRadius: 6)).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let onAdd {
                        Button("Add", action: onAdd).font(.caption).buttonStyle(.borderedProminent).padding(6)
                            .accessibilityLabel("Add \(window.app) as a new tile")
                    }
                }
                HStack(spacing: 6) {
                    if let icon { Image(decorative: icon, scale: 1).resizable().frame(width: 18, height: 18) }
                    VStack(alignment: .leading) {
                        Text(window.title.isEmpty ? window.app : window.title).font(.callout).foregroundStyle(.white).lineLimit(1)
                        if !window.title.isEmpty { Text(window.app).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1) }
                    }
                }
                .padding(8)
            }
            .background(Color(white: 0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(current ? workspaceAccent : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(window.app): \(window.title.isEmpty ? "untitled window" : window.title)" + (window.minimized ? ", minimized" : ""))
        .accessibilityValue(current ? "Showing" : "")
    }
}

/// Layout choices that fit this screen, drawn as their shapes.
struct WorkspacePresetsView: View {
    let capacity: Int
    let tileCount: Int
    let onPick: (WorkspacePreset) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(WorkspacePreset.available(capacity: capacity), id: \.self) { preset in
                    let ids = (0..<preset.slotCount).map { "s\($0)" }
                    let layout = WorkspaceLayout(root: preset.node(tiles: ids), tiles: Dictionary(uniqueKeysWithValues: ids.map { ($0, WorkspaceTile(id: $0)) }))
                    let slots = WorkspaceGeometry.frames(for: layout, in: WorkspaceSize(width: 160, height: 100)).slots
                    Button { onPick(preset) } label: {
                        Canvas { ctx, size in
                            for r in slots {
                                let rect = CGRect(x: r.x * size.width + 2, y: r.y * size.height + 2, width: r.width * size.width - 4, height: r.height * size.height - 4)
                                ctx.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(preset.slotCount == tileCount ? workspaceAccent : .white.opacity(0.75)), lineWidth: 1.5)
                            }
                        }
                        .frame(width: 52, height: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Layout: \(preset.title)")
                }
            }
        }
    }
}
