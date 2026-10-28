import CoreGraphics
import Foundation
import ImageIO

// Window workspaces on Apple receivers (iPhone, iPad, Mac Receiver): what the
// Mac sends, what this device asks for, and the model the views draw. Same
// rules as the Android client (AndroidReceiver/.../workspace); the Mac stays
// authoritative for what's listed, accepted and focused.

// MARK: - Messages from the Mac (parsed on the network queue, Sendable)

struct CatalogWindowItem: Equatable, Sendable, Identifiable {
    var id: UInt32
    var generation: UInt64
    var bundleID: String
    var app: String
    var title: String
    var width: Int
    var height: Int
    var minimized: Bool
    var active: Bool
}

struct CatalogAppItem: Equatable, Sendable { var bundleID: String; var name: String; var hasWindows: Bool }
struct InstalledAppItem: Equatable, Sendable { var bundleID: String; var name: String }

struct WorkspaceCatalogMessage: Equatable, Sendable {
    var host: String?
    var windows: [CatalogWindowItem]
    var apps: [CatalogAppItem]
    var installed: [InstalledAppItem]
    var unavailable: Bool

    func search(_ query: String) -> [CatalogWindowItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return windows }
        return windows.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.app.localizedCaseInsensitiveContains(q) }
    }
}

enum RemoteTileStatus: String, Sendable { case live, waiting, offscreen, closed, failed, limit }

enum RemoteHostFocus: String, Sendable {
    case deliver, noActiveTile, hostFocusElsewhere, otherWindowFocused
    var isMismatch: Bool { self == .hostFocusElsewhere || self == .otherWindowFocused }
}

struct RemoteTileItem: Equatable, Sendable {
    var id: String
    var windowID: UInt32
    var generation: UInt64
    var status: RemoteTileStatus
    var app: String
    var bundleID: String
    var title: String
}

struct WorkspaceStateMessage: Equatable, Sendable {
    var host: String?
    var tiles: [RemoteTileItem]
    var active: String?
    var hostFocus: RemoteHostFocus
    var rejected: [String: String]
}

enum WorkspaceEvent: Sendable {
    case features(Set<String>)
    case mode(window: Bool)
    case catalog(WorkspaceCatalogMessage)
    case state(WorkspaceStateMessage)
    case thumbnail(windowID: UInt32, generation: UInt64, data: Data?)
    case icon(bundleID: String, data: Data)
    case connected(peerID: String)
    case disconnected

    static let maxBase64 = 96 * 1024

    /// Bounded, defensive parsing of one control message; nil for anything else.
    static func parse(type: String, _ obj: [String: Any]) -> WorkspaceEvent? {
        func str(_ o: [String: Any], _ k: String, _ limit: Int = 160) -> String? { (o[k] as? String).map { String($0.prefix(limit)) } }
        func u32(_ o: [String: Any], _ k: String) -> UInt32? { (o[k] as? Int).flatMap { UInt32(exactly: $0) } }
        func u64(_ o: [String: Any], _ k: String) -> UInt64? { (o[k] as? Int).flatMap { UInt64(exactly: $0) } }
        switch type {
        case WireMessage.windowCatalog:
            let windows = (obj["windows"] as? [[String: Any]] ?? []).prefix(120).compactMap { w -> CatalogWindowItem? in
                guard let id = u32(w, "id"), let bundle = str(w, "bundle") else { return nil }
                return CatalogWindowItem(id: id, generation: u64(w, "gen") ?? 0, bundleID: bundle, app: str(w, "app", 80) ?? "",
                                         title: str(w, "title") ?? "", width: w["w"] as? Int ?? 0, height: w["h"] as? Int ?? 0,
                                         minimized: (w["state"] as? String) == "offscreen", active: w["active"] as? Bool ?? false)
            }
            let apps = (obj["apps"] as? [[String: Any]] ?? []).prefix(60).compactMap { a -> CatalogAppItem? in
                guard let b = str(a, "bundle") else { return nil }
                return CatalogAppItem(bundleID: b, name: str(a, "name", 80) ?? "", hasWindows: a["windows"] as? Bool ?? false)
            }
            let installed = (obj["installed"] as? [[String: Any]] ?? []).prefix(150).compactMap { a -> InstalledAppItem? in
                guard let b = str(a, "bundle") else { return nil }
                return InstalledAppItem(bundleID: b, name: str(a, "name", 80) ?? "")
            }
            return .catalog(WorkspaceCatalogMessage(host: str(obj, "host"), windows: Array(windows), apps: Array(apps),
                                                   installed: Array(installed), unavailable: obj["error"] != nil))
        case WireMessage.workspaceState:
            let tiles = (obj["tiles"] as? [[String: Any]] ?? []).prefix(WorkspaceLayout.maximumTiles).compactMap { t -> RemoteTileItem? in
                guard let id = str(t, "id", 32) else { return nil }
                return RemoteTileItem(id: id, windowID: u32(t, "window") ?? 0, generation: u64(t, "gen") ?? 0,
                                      status: (t["state"] as? String).flatMap(RemoteTileStatus.init(rawValue:)) ?? .waiting,
                                      app: str(t, "app", 80) ?? "", bundleID: str(t, "bundle") ?? "", title: str(t, "title", 120) ?? "")
            }
            let rejected = (obj["rejected"] as? [String: Any] ?? [:]).prefix(32).reduce(into: [String: String]()) { r, e in
                if let v = e.value as? String { r[e.key] = v }
            }
            return .state(WorkspaceStateMessage(host: str(obj, "host"), tiles: Array(tiles), active: str(obj, "active", 32),
                                                hostFocus: (obj["hostFocus"] as? String).flatMap(RemoteHostFocus.init(rawValue:)) ?? .noActiveTile,
                                                rejected: rejected))
        case WireMessage.windowThumbnail:
            guard let id = u32(obj, "id") else { return nil }
            let data = (obj["jpeg"] as? String).flatMap { $0.count <= maxBase64 ? Data(base64Encoded: $0) : nil }
            return .thumbnail(windowID: id, generation: u64(obj, "gen") ?? 0, data: data)
        case WireMessage.appIcon:
            guard let bundle = str(obj, "bundle"), let png = obj["png"] as? String, png.count <= maxBase64,
                  let data = Data(base64Encoded: png) else { return nil }
            return .icon(bundleID: bundle, data: data)
        default:
            return nil
        }
    }
}

/// Hands workspace events from the network queue to the main actor.
final class WorkspaceEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@MainActor @Sendable (WorkspaceEvent) -> Void)?

    func set(_ handler: (@MainActor @Sendable (WorkspaceEvent) -> Void)?) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    func emit(_ event: WorkspaceEvent) {
        lock.lock(); let handler = self.handler; lock.unlock()
        guard let handler else { return }
        Task { @MainActor in handler(event) }
    }
}

extension Notification.Name {
    /// Settings asks the receiver screen to open the window overview.
    static let meowOpenWindowOverview = Notification.Name("MeowDisplay.openWindowOverview")
}

// MARK: - Requests to the Mac

enum WorkspaceRequests {
    static func catalog(installed: Bool) -> [String: Any] {
        var m: [String: Any] = ["type": WireMessage.windowCatalogRequest]
        if installed { m["installed"] = true }
        return m
    }

    static func thumbnails(_ ids: [UInt32], maxWidth: Int, icons: [String]) -> [String: Any] {
        var m: [String: Any] = ["type": WireMessage.windowThumbnailRequest, "ids": ids.prefix(24).map { Int($0) }, "max": maxWidth]
        if !icons.isEmpty { m["icons"] = Array(icons.prefix(32)) }
        return m
    }

    /// Only this host's tiles, at their normalized frames.
    static func workspace(_ layout: WorkspaceLayout, frames: WorkspaceFrames, host: String, focus: String?,
                          generation: (WorkspaceSource) -> UInt64?) -> [String: Any] {
        var tiles: [[String: Any]] = []
        for id in layout.orderedTileIDs {
            guard let tile = layout.tiles[id], let source = tile.source, source.host == host,
                  let r = frames.tiles[id], r.width > 0, r.height > 0 else { continue }
            var t: [String: Any] = ["id": id, "host": host, "x": r.x, "y": r.y, "w": r.width, "h": r.height,
                                    "window": Int(source.windowID), "follow": source.follow.rawValue,
                                    "rotation": tile.rotation.rawValue, "fit": tile.fit.rawValue]
            if let gen = generation(source) { t["gen"] = Int(gen) }
            tiles.append(t)
        }
        var m: [String: Any] = ["type": WireMessage.workspaceRequest, "tiles": tiles]
        if let focus { m["focus"] = focus }
        return m
    }

    static func focus(_ tile: String?) -> [String: Any] {
        var m: [String: Any] = ["type": WireMessage.workspaceFocus]
        if let tile { m["tile"] = tile }
        return m
    }

    static func launch(_ bundle: String) -> [String: Any] { ["type": WireMessage.windowAction, "action": "launch", "bundle": bundle] }

    /// Closes the real Mac window: only from its own explicit confirm.
    static func closeWindow(_ id: UInt32, generation: UInt64) -> [String: Any] {
        ["type": WireMessage.windowAction, "action": "close", "window": Int(id), "gen": Int(generation)]
    }
}

// MARK: - Images (bounded before decoding)

enum WorkspaceImageDecoder {
    /// A small file can declare a huge image: read the header first, refuse
    /// anything over 16 MP, and decode a thumbnail no larger than `maxSide`.
    static func image(_ data: Data, maxSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, Int64(w) * Int64(h) <= 4096 * 4096 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxSide,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

// MARK: - The model the views draw

enum WorkspaceRailEdge: String, CaseIterable, Sendable { case top, bottom, left, right }

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var windowMode = false
    @Published private(set) var layout = WorkspaceLayout()
    @Published private(set) var stacked: [String] = []
    @Published private(set) var capacity = 1
    @Published private(set) var remote: WorkspaceStateMessage?
    @Published private(set) var catalog: WorkspaceCatalogMessage?
    @Published private(set) var missing: Set<String> = []
    @Published var overviewOpen = false
    @Published private(set) var replacingTile: String?
    @Published var railExpanded = false { didSet { if railExpanded { startRefreshing() } } }
    @Published var railEdge: WorkspaceRailEdge { didSet { defaults.set(railEdge.rawValue, forKey: Self.railKey) } }
    @Published var arranging = false
    @Published private(set) var hovered: String?
    @Published private(set) var thumbnails: [UInt32: CGImage] = [:]
    @Published private(set) var icons: [String: CGImage] = [:]
    @Published private(set) var canUndo = false

    /// Sends one workspace message on the current, admitted connection.
    var send: ([String: Any]) -> Bool = { _ in false }
    /// Asks the Mac for Window mode (displayModeRequest "window").
    var requestWindowMode: () -> Void = {}
    /// Whether this session may change the Mac (launch apps, close windows).
    var inputAllowed: () -> Bool = { false }

    private let defaults: UserDefaults
    private var saved = WorkspaceLayout()
    private var host: String?
    private var size = WorkspaceSize(width: 400, height: 800)
    private var hinge: WorkspaceHinge?
    private var history = WorkspaceHistory()
    private var nextTile = 1
    private var awaitingCatalogToSend = false
    private var sendTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var thumbAge: [UInt32: Date] = [:]
    /// Window generations from the latest catalog, by host and window id. The layout
    /// keeps host + id so it survives sessions; the Mac still rejects a reused id.
    private var generations: [String: UInt64] = [:]
    private func generation(_ s: WorkspaceSource) -> UInt64? { generations["\(s.host)#\(s.windowID)"] }
    private func setGeneration(_ s: WorkspaceSource, _ g: UInt64) { generations["\(s.host)#\(s.windowID)"] = g }
    private static let railKey = "workspace.railEdge"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        railEdge = defaults.string(forKey: Self.railKey).flatMap(WorkspaceRailEdge.init(rawValue:)) ?? .top
    }

    var active: String? { remote?.active }
    /// The connected Mac's name as paired (never a name the network claims).
    var hostName: String {
        host.flatMap { id in TrustStore.receiverRole.pinnedPeers().first { $0.peerID == id }?.displayName } ?? "your Mac"
    }
    var frames: WorkspaceFrames { WorkspaceGeometry.frames(for: layout, in: size, hinge: hinge) }
    func tileState(_ id: String) -> RemoteTileItem? { remote?.tiles.first { $0.id == id } }

    // MARK: Events

    func apply(_ event: WorkspaceEvent) {
        switch event {
        case .connected(let peer):
            if peer != host { load(for: peer) }
        case .features(let f):
            available = f.contains(WindowWorkspaceWire.welcomeFeature)
        case .mode(let window):
            windowMode = window
            if !window { remote = nil }
            if window { awaitingCatalogToSend = true; requestCatalog() }
        case .catalog(let c):
            onCatalog(c)
        case .state(let s):
            remote = s
        case .thumbnail(let id, _, let data):
            guard let data, let image = WorkspaceImageDecoder.image(data, maxSide: 320) else { return }
            thumbAge[id] = Date()
            thumbnails[id] = image
            if thumbnails.count > 48, let oldest = thumbAge.min(by: { $0.value < $1.value })?.key {
                thumbnails[oldest] = nil; thumbAge[oldest] = nil
            }
        case .icon(let bundle, let data):
            guard icons.count < 64, let image = WorkspaceImageDecoder.image(data, maxSide: 128) else { return }
            icons[bundle] = image
        case .disconnected:
            sendTask?.cancel()
            windowMode = false; remote = nil; available = false; arranging = false
        }
    }

    private func load(for peer: String) {
        host = peer
        saved = defaults.data(forKey: "workspace.layout.\(peer)").flatMap(WorkspaceLayoutRecord.decode) ?? WorkspaceLayout()
        nextTile = (saved.tiles.keys.compactMap { Int($0.dropFirst()) }.max() ?? 0) + 1
        history = WorkspaceHistory()
        thumbnails = [:]; icons = [:]; thumbAge = [:]
        generations = [:]
        publish()
    }

    private func onCatalog(_ c: WorkspaceCatalogMessage) {
        catalog = c
        let byID = Dictionary(c.windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var missing = Set<String>()
        var rebased = saved
        for (id, tile) in saved.tiles {
            guard let source = tile.source else { continue }
            // A new Mac session: keep a saved tile only for the same window id of the same app.
            guard let w = byID[source.windowID], source.bundleID == nil || source.bundleID == w.bundleID else { missing.insert(id); continue }
            setGeneration(source, w.generation)
            if source.bundleID == nil { rebased = rebased.replacingSource(of: id, with: WorkspaceSource(host: source.host, windowID: source.windowID, bundleID: w.bundleID, follow: source.follow)) }
        }
        if rebased != saved { saved = rebased; persist() }
        self.missing = missing
        publish()
        if awaitingCatalogToSend { awaitingCatalogToSend = false; scheduleSend(immediately: true) }
        requestThumbnails()
    }

    private func requestThumbnails() {
        guard overviewOpen || railExpanded, let c = catalog else { return }
        let now = Date()
        let ids = c.windows.filter { now.timeIntervalSince(thumbAge[$0.id] ?? .distantPast) > 8 }.map(\.id)
        let wantedIcons = c.apps.map(\.bundleID).filter { icons[$0] == nil }
        guard !ids.isEmpty || !wantedIcons.isEmpty else { return }
        _ = send(WorkspaceRequests.thumbnails(Array(ids.prefix(24)), maxWidth: 240, icons: wantedIcons))
    }

    func requestCatalog() { _ = send(WorkspaceRequests.catalog(installed: inputAllowed())) }

    // MARK: Space

    func updateSpace(_ newSize: WorkspaceSize, hinge newHinge: WorkspaceHinge?) {
        guard newSize != size || newHinge != hinge else { return }
        size = newSize; hinge = newHinge
        publish(); scheduleSend()
    }

    private func publish() {
        let adapted = WorkspaceAdaptation.adapt(saved, to: size, hinge: hinge, active: remote?.active)
        layout = adapted.visible
        stacked = adapted.stacked
        capacity = WorkspaceGeometry.capacity(for: size, hinge: hinge)
        canUndo = history.canUndo
    }

    // MARK: Editing

    private func edit(_ change: (WorkspaceLayout) -> WorkspaceLayout) {
        let next = change(layout)
        guard next != layout else { return }
        history.record(saved)
        var updated = next
        for id in stacked { if let t = saved.tiles[id] { updated = updated.adding(t, landscape: size.width >= size.height) } }
        saved = stacked.isEmpty ? next : updated
        persist(); publish(); scheduleSend()
    }

    func undo() {
        guard let previous = history.undo() else { return }
        saved = previous
        persist(); publish(); scheduleSend()
    }

    func apply(_ preset: WorkspacePreset) {
        edit { l in
            let ordered = l.orderedTileIDs.compactMap { l.tiles[$0] }
            return ordered.count > preset.slotCount ? l.applying(preset).layout : WorkspaceLayout(preset: preset, tiles: ordered)
        }
    }
    func move(_ tile: String, to target: WorkspaceDropTarget) { edit { $0.materializing(hinge: hinge).moving(tile, to: target) } }
    func resize(_ divider: WorkspaceDivider, delta: Double) { edit { WorkspaceGeometry.resizing($0, divider: divider, delta: delta, in: size) } }
    func rotate(_ tile: String) { edit { $0.rotating(tile) } }
    func toggleFit(_ tile: String) { edit { l in l.settingFit(l.tiles[tile]?.fit == .fill ? .fit : .fill, for: tile) } }
    func toggleMaximize(_ tile: String) { edit { l in l.maximized == tile ? l.restoringMaximized() : l.maximizing(tile) } }
    /// Removes the tile only; the Mac window stays open.
    func removeTile(_ tile: String) { edit { $0.removing(tile) } }

    func closeRemoteWindow(_ tile: String) {
        guard let source = layout.tiles[tile]?.source, let gen = generation(source) else { return }
        _ = send(WorkspaceRequests.closeWindow(source.windowID, generation: gen))
    }

    func bringBack(_ tile: String) {
        guard saved.tiles[tile] != nil, let target = active.flatMap({ layout.tiles[$0] != nil ? $0 : nil }) ?? layout.orderedTileIDs.last else { return }
        history.record(saved)
        saved = saved.swapping(tile, target)
        persist(); publish(); scheduleSend()
    }

    func choose(_ w: CatalogWindowItem, asNewTile: Bool) {
        guard let host else { return }
        let source = WorkspaceSource(host: host, windowID: w.id, bundleID: w.bundleID)
        setGeneration(source, w.generation)
        let replacing = replacingTile
        closeOverview()
        if !windowMode { requestWindowMode() }
        let landscape = size.width >= size.height
        edit { l in
            let target = replacing ?? (asNewTile ? nil : (active ?? (l.orderedTileIDs.count == 1 ? l.orderedTileIDs.first : nil)))
            if let target, l.tiles[target] != nil { return l.replacingSource(of: target, with: source) }
            if l.tiles.count < capacity {
                let tile = WorkspaceTile(id: "w\(nextTile)", source: source)
                nextTile += 1
                if l.tiles.isEmpty { return WorkspaceLayout(preset: .single, tiles: [tile]) }
                let added = l.adding(tile, landscape: landscape)
                return WorkspaceLayout(preset: .natural(for: added.tiles.count, landscape: landscape), tiles: added.orderedTileIDs.compactMap { added.tiles[$0] })
            }
            return l.orderedTileIDs.last.map { l.replacingSource(of: $0, with: source) } ?? l
        }
    }

    func launch(_ bundle: String) { _ = send(WorkspaceRequests.launch(bundle)) }
    func focus(_ tile: String) { _ = send(WorkspaceRequests.focus(tile)) }

    /// The hardware pointer at a normalized canvas point: hover only, never focus.
    func hover(at p: CGPoint?) {
        let id = p.flatMap { p in frames.tiles.first { $0.value.contains(WorkspacePoint(x: p.x, y: p.y)) }?.key }
        if hovered != id { hovered = id }
    }

    // MARK: Overview, rail

    func openOverview(replacing tile: String? = nil) {
        replacingTile = tile
        overviewOpen = true
        startRefreshing()
    }

    func closeOverview() { overviewOpen = false; replacingTile = nil }

    private func startRefreshing() {
        refreshTask?.cancel()
        requestCatalog()
        refreshTask = Task { [weak self] in
            while let self, self.overviewOpen || self.railExpanded {
                try? await Task.sleep(nanoseconds: self.overviewOpen ? 3_000_000_000 : 5_000_000_000)
                guard !Task.isCancelled, self.overviewOpen || self.railExpanded else { break }
                self.requestCatalog()
            }
        }
    }

    // MARK: Sending

    private func scheduleSend(immediately: Bool = false) {
        sendTask?.cancel()
        sendTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 60_000_000) }
            guard !Task.isCancelled else { return }
            self?.sendNow()
        }
    }

    private func sendNow() {
        guard let host, windowMode else { return }
        guard catalog != nil else { awaitingCatalogToSend = true; requestCatalog(); return }
        var sendable = layout
        for id in missing { sendable = sendable.replacingSource(of: id, with: nil) }
        _ = send(WorkspaceRequests.workspace(sendable, frames: WorkspaceGeometry.frames(for: sendable, in: size, hinge: hinge),
                                             host: host, focus: active, generation: generation))
    }

    private func persist() {
        guard let host, let data = WorkspaceLayoutRecord(saved).encoded() else { return }
        defaults.set(data, forKey: "workspace.layout.\(host)")
    }
}
