import SwiftUI

/// Demo Mode's Window view: the real `WorkspaceModel` and Window view chrome (panes, floating
/// windows, tucking, docking, menus), with a sample Mac that answers on this device. Nothing is
/// sent anywhere: the sample Mac takes the arrangement the model would send, draws sample
/// windows in the order a Mac composites them (tiled panes, then floats back to front) and
/// reports which window a touch would reach, the same way the Mac decides.
@MainActor
final class DemoWindowWorkspace: ObservableObject {
    struct SampleWindow {
        let id: UInt32
        let app: String
        let bundle: String
        let title: String
        let width: Int
        let height: Int
        let tint: Color
        let symbol: String
    }

    /// One window as the sample Mac draws it.
    struct Drawn: Identifiable, Equatable {
        var id: String { tile }
        let tile: String
        let window: UInt32
        let rect: WorkspaceRect
        let isFloat: Bool
    }

    static let host = "demo.review-mac"
    static let windows: [SampleWindow] = [
        SampleWindow(id: 101, app: "Notes", bundle: "com.apple.Notes", title: "Trip Packing List", width: 1200, height: 820,
                     tint: Color(red: 0.98, green: 0.82, blue: 0.3), symbol: "note.text"),
        SampleWindow(id: 102, app: "Safari", bundle: "com.apple.Safari", title: "MeowDisplay — Help", width: 1440, height: 900,
                     tint: Color(red: 0.25, green: 0.55, blue: 0.95), symbol: "safari"),
        SampleWindow(id: 103, app: "Terminal", bundle: "com.apple.Terminal", title: "zsh — 80×24", width: 900, height: 600,
                     tint: Color(white: 0.2), symbol: "terminal"),
        SampleWindow(id: 104, app: "Music", bundle: "com.apple.Music", title: "Now Playing", width: 700, height: 700,
                     tint: Color(red: 0.95, green: 0.3, blue: 0.4), symbol: "music.note"),
        SampleWindow(id: 105, app: "Calendar", bundle: "com.apple.iCal", title: "November", width: 1100, height: 760,
                     tint: Color(red: 0.95, green: 0.45, blue: 0.2), symbol: "calendar"),
    ]

    let model: WorkspaceModel
    @Published private(set) var drawn: [Drawn] = []
    /// The window the last touch on the picture reached (the sample Mac's own hit test).
    @Published private(set) var lastTouched = ""
    private var active: String?

    init(defaults: UserDefaults) {
        model = WorkspaceModel(defaults: defaults)
        model.send = { [weak self] message in
            // Answered after the model finishes what it is doing, as a reply from a Mac would be.
            DispatchQueue.main.async { self?.receive(message) }
            return true
        }
        model.inputAllowed = { true }
        model.apply(.connected(peerID: Self.host))
        model.apply(.features([WindowWorkspaceWire.welcomeFeature, WindowWorkspaceWire.floatFeature]))
        model.apply(.mode(window: true))
        sendCatalog()
    }

    /// Two panes to start with (an arrangement already saved in the demo's own defaults is kept).
    func start() {
        guard model.layout.tiles.isEmpty, let catalog = model.catalog, catalog.windows.count > 1 else { return }
        model.choose(catalog.windows[0], asNewTile: false)
        model.choose(catalog.windows[1], asNewTile: true)
    }

    /// The next sample window not on screen yet.
    var nextWindow: CatalogWindowItem? {
        let shown = Set(model.layout.tiles.values.flatMap(\.windows).map(\.windowID))
        return model.catalog?.windows.first { !shown.contains($0.id) }
    }

    func sample(_ id: UInt32) -> SampleWindow? { Self.windows.first { $0.id == id } }

    /// A touch on the picture: the frontmost window under it, as the Mac decides.
    func touch(at p: WorkspacePoint) {
        if let d = drawn.last(where: { $0.rect.contains(p) }), let w = sample(d.window) {
            lastTouched = w.app
        } else {
            lastTouched = ""
        }
    }

    private func receive(_ message: [String: Any]) {
        switch message["type"] as? String {
        case WireMessage.workspaceRequest:
            let tiles = message["tiles"] as? [[String: Any]] ?? []
            var base: [Drawn] = []
            var floats: [(z: Int, order: Int, drawn: Drawn)] = []
            for (i, t) in tiles.enumerated() {
                guard let id = t["id"] as? String, let window = (t["window"] as? Int).flatMap(UInt32.init(exactly:)),
                      let x = t["x"] as? Double, let y = t["y"] as? Double, let w = t["w"] as? Double, let h = t["h"] as? Double
                else { continue }
                let float = t["layer"] as? String == "float"
                let d = Drawn(tile: id, window: window, rect: WorkspaceRect(x: x, y: y, width: w, height: h), isFloat: float)
                if float { floats.append((t["z"] as? Int ?? 0, i, d)) } else { base.append(d) }
            }
            drawn = base + floats.sorted { ($0.z, $0.order) < ($1.z, $1.order) }.map(\.drawn)
            if let focus = message["focus"] as? String { active = focus }
            if active.map({ a in !drawn.contains { $0.tile == a } }) ?? true { active = drawn.first?.tile }
            sendState()
        case WireMessage.workspaceFocus:
            active = message["tile"] as? String
            sendState()
        case WireMessage.windowCatalogRequest:
            sendCatalog()
        default:
            break   // stills, backdrops, menus: the sample Mac has none
        }
    }

    private func sendState() {
        let tiles: [[String: Any]] = drawn.compactMap { d in
            guard let w = sample(d.window) else { return nil }
            var t: [String: Any] = ["id": d.tile, "window": Int(d.window), "gen": 1, "state": "live", "app": w.app,
                                    "bundle": w.bundle, "title": w.title, "follow": "window", "rotation": 0, "fit": "fit"]
            if d.isFloat { t["layer"] = "float"; t["z"] = drawn.filter(\.isFloat).firstIndex(of: d) ?? 0 }
            return t
        }
        var state: [String: Any] = ["type": WireMessage.workspaceState, "host": Self.host, "tiles": tiles,
                                    "hostFocus": active == nil ? "noActiveTile" : "deliver", "rejected": [String: String]()]
        if let active { state["active"] = active }
        if let event = WorkspaceEvent.parse(type: WireMessage.workspaceState, state) { model.apply(event) }
    }

    private func sendCatalog() {
        let catalog: [String: Any] = [
            "type": WireMessage.windowCatalog, "host": Self.host,
            "windows": Self.windows.map { w in
                ["id": Int(w.id), "gen": 1, "bundle": w.bundle, "app": w.app, "title": w.title,
                 "w": w.width, "h": w.height, "state": "visible"] as [String: Any]
            },
            "apps": [[String: Any]](),
        ]
        if let event = WorkspaceEvent.parse(type: WireMessage.windowCatalog, catalog) { model.apply(event) }
    }
}

/// The sample picture with the real Window view chrome over it.
struct DemoWindowModeView: View {
    @ObservedObject var workspace: DemoWindowWorkspace
    @ObservedObject var model: WorkspaceModel
    /// Where the picture is, in this view's coordinates.
    let area: CGRect
    let inputAllowed: Bool
    /// The screen's safe area (this view's coordinates); nil: the whole picture.
    var safeArea: CGRect?
    /// The screen and the receiver's controls (global): tucked floats' strips keep clear of them
    /// and of this view's toolbar, as in a live session.
    var reservations = WorkspaceEdgeReservations()
    var onShowDesktop: () -> Void = {}
    /// The toolbar (global).
    @State private var toolbarFrame: CGRect = .zero
    @State private var toolbarHeight: CGFloat = 40

    private var safe: CGRect {
        guard let s = safeArea, !s.isNull, !s.isEmpty else { return area }
        return s
    }

    /// Above the band at the picture's bottom where tucked floats' strips take touches, so a
    /// float thrown at the bottom edge waits there at full length, as it would in a session.
    private var toolbarCentreY: CGFloat {
        let bottom = min(area.maxY, safe.maxY, reservations.screen.height > 0
                         ? reservations.screen.height - CGFloat(WorkspaceFloatGeometry.systemEdgeClearance) : area.maxY)
        let y = bottom - CGFloat(WorkspaceFloatGeometry.touchDepth + WorkspaceFloatGeometry.tabSpacing) - 4 - toolbarHeight / 2
        return max(y, area.minY + toolbarHeight / 2)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            picture
                .frame(width: area.width, height: area.height)
                .clipped()
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    let n = WorkspacePoint(x: p.x / max(area.width, 1), y: p.y / max(area.height, 1))
                    workspace.touch(at: n)
                    _ = model.selectTile(at: n)
                }
                .position(x: area.midX, y: area.midY)
                .accessibilityElement()
                .accessibilityLabel(Text("Sample Mac windows"))
                .accessibilityValue(Text("\(workspace.drawn.count) windows drawn"))
                .accessibilityIdentifier("demoWindowPicture")
            WorkspaceChromeView(model: model, picture: area, inputAllowed: inputAllowed, safeArea: safe)
            toolbar
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { toolbarFrame = g.frame(in: .global); toolbarHeight = g.size.height }
                        .onChange(of: g.frame(in: .global)) { toolbarFrame = $0; toolbarHeight = $0.height }
                })
                .position(x: area.midX, y: toolbarCentreY)
        }
        .onAppear { workspace.start(); publishReservations() }
        .onChange(of: reservations) { _ in publishReservations() }
        .onChange(of: toolbarFrame) { _ in publishReservations() }
    }

    private func publishReservations() {
        var r = reservations
        if !toolbarFrame.isEmpty { r.controls.append(toolbarFrame) }
        if model.edgeReservationsGlobal != r { model.edgeReservationsGlobal = r }
    }

    /// What the sample Mac draws, in its paint order.
    private var picture: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.36), Color(red: 0.36, green: 0.22, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach(workspace.drawn) { d in
                if let w = workspace.sample(d.window) {
                    let tile = CGRect(x: d.rect.x * area.width, y: d.rect.y * area.height,
                                      width: d.rect.width * area.width, height: d.rect.height * area.height)
                    let fitted = Self.fit(CGSize(width: w.width, height: w.height), in: tile)
                    ZStack {
                        if !d.isFloat { Color.black.opacity(0.35) }   // the pane's letterbox
                        sampleWindow(w)
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: fitted.midX - tile.minX, y: fitted.midY - tile.minY)
                    }
                    .frame(width: tile.width, height: tile.height)
                    .position(x: tile.midX, y: tile.midY)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func sampleWindow(_ w: DemoWindowWorkspace.SampleWindow) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach([Color.red, .yellow, .green], id: \.self) { c in Circle().fill(c.opacity(0.85)).frame(width: 9, height: 9) }
                Spacer(minLength: 4)
                Text(w.title).font(.caption2.weight(.semibold)).foregroundStyle(.black.opacity(0.7)).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(white: 0.92))
            ZStack {
                w.tint
                VStack(spacing: 8) {
                    Image(systemName: w.symbol).font(.system(size: 28, weight: .semibold))
                    Text(w.app).font(.headline)
                }
                .foregroundStyle(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: onShowDesktop) { Label("Show Desktop", systemImage: "display") }
                .accessibilityIdentifier("demoShowDesktop")
            Button {
                if let w = workspace.nextWindow { model.openFloating(w) }
            } label: { Label("Open Floating Window", systemImage: "macwindow.on.rectangle") }
                .disabled(workspace.nextWindow == nil || !model.canFloatPanes)
                .accessibilityIdentifier("demoOpenFloating")
            Button {
                if let w = workspace.nextWindow { model.choose(w, asNewTile: true) }
            } label: { Label("Add Pane", systemImage: "rectangle.split.2x1") }
                .disabled(workspace.nextWindow == nil || !model.canAddTile)
                .accessibilityIdentifier("demoAddPane")
            if !workspace.lastTouched.isEmpty {
                Text("Touched: \(workspace.lastTouched)").font(.caption).foregroundStyle(.white.opacity(0.8))
                    .accessibilityIdentifier("demoLastTouched")
            }
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.bordered)
        .tint(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .environment(\.colorScheme, .dark)
    }

    static func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}
