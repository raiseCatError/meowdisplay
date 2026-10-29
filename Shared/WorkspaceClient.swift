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
    /// Window mode is still starting on the Mac: not a listing failure. The picker keeps asking.
    var starting = false
    /// The Mac's displays (Full Desktop sources), main first.
    var displays: [CatalogDisplayItem] = []

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
    case thumbnail(windowID: UInt32, generation: UInt64, data: Data?, stale: Bool = false)
    case icon(bundleID: String, data: Data)
    case displayThumbnail(displayID: UInt32, data: Data)
    /// `apps` nil: the receiver's revision is current.
    case appCatalog(revision: Int, apps: [MacAppItem]?)
    case launchResult(bundleID: String, ok: Bool)
    case connected(peerID: String)
    case disconnected

    static let maxBase64 = 256 * 1024   // a sharp 640-wide Stage Peek still

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
            let displays = (obj["displays"] as? [[String: Any]] ?? []).prefix(8).compactMap { d -> CatalogDisplayItem? in
                guard let id = u32(d, "id") else { return nil }
                return CatalogDisplayItem(id: id, name: str(d, "name", 80) ?? "Display", width: d["w"] as? Int ?? 0,
                                          height: d["h"] as? Int ?? 0, isMain: d["main"] as? Bool ?? false,
                                          isVirtual: d["virtual"] as? Bool ?? false)
            }
            return .catalog(WorkspaceCatalogMessage(host: str(obj, "host"), windows: Array(windows), apps: Array(apps),
                                                   installed: Array(installed),
                                                   unavailable: obj["error"] != nil && obj["error"] as? String != "starting",
                                                   starting: obj["error"] as? String == "starting", displays: Array(displays)))
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
            return .thumbnail(windowID: id, generation: u64(obj, "gen") ?? 0, data: data, stale: obj["stale"] as? Bool ?? false)
        case WireMessage.displayThumbnail:
            guard let id = u32(obj, "id"), let jpeg = obj["jpeg"] as? String, jpeg.count <= maxBase64,
                  let data = Data(base64Encoded: jpeg) else { return nil }
            return .displayThumbnail(displayID: id, data: data)
        case WireMessage.appCatalog:
            guard let rev = obj["rev"] as? Int else { return nil }
            if obj["same"] as? Bool == true { return .appCatalog(revision: rev, apps: nil) }
            let apps = (obj["apps"] as? [[String: Any]] ?? []).prefix(900).compactMap { a -> MacAppItem? in
                guard let b = str(a, "bundle"), !b.isEmpty else { return nil }
                return MacAppItem(bundleID: b, name: str(a, "name", 80) ?? b, running: a["running"] as? Bool ?? false,
                                  windowCount: a["windows"] as? Int ?? 0,
                                  lastUsed: (a["used"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) })
            }
            return .appCatalog(revision: rev, apps: Array(apps))
        case WireMessage.appLaunchResult:
            guard let b = str(obj, "bundle") else { return nil }
            return .launchResult(bundleID: b, ok: obj["ok"] as? Bool ?? false)
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

    static func thumbnails(_ ids: [UInt32], maxWidth: Int, icons: [String], displays: [UInt32] = []) -> [String: Any] {
        var m: [String: Any] = ["type": WireMessage.windowThumbnailRequest, "ids": ids.prefix(24).map { Int($0) }, "max": maxWidth]
        if !icons.isEmpty { m["icons"] = Array(icons.prefix(48)) }
        if !displays.isEmpty { m["displays"] = displays.prefix(8).map { Int($0) } }
        return m
    }

    static func appCatalog(revision: Int?) -> [String: Any] {
        var m: [String: Any] = ["type": WireMessage.appCatalogRequest]
        if let revision { m["rev"] = revision }
        return m
    }

    /// Opens an app on the Mac without activating it (needs control).
    static func appLaunch(_ bundle: String) -> [String: Any] { ["type": WireMessage.appLaunch, "bundle": bundle] }

    /// Minimizes the real Mac window: only from its own explicit action.
    static func minimizeWindow(_ id: UInt32, generation: UInt64) -> [String: Any] {
        ["type": WireMessage.windowAction, "action": "minimize", "window": Int(id), "gen": Int(generation)]
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
            if let c = tile.crop { t["crop"] = [c.x, c.y, c.width, c.height] }
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
    /// Stage Peek is warming (finger holding the edge) or open: keeps the
    /// catalog and thumbnails fresh. Read-only requests; never a layout,
    /// capture or focus change.
    @Published var stagePeekOpen = false { didSet { if stagePeekOpen, !oldValue { startRefreshing() } } }
    @Published var railEdge: WorkspaceRailEdge { didSet { defaults.set(railEdge.rawValue, forKey: Self.railKey) } }
    @Published var arranging = false
    @Published private(set) var hovered: String?
    @Published private(set) var thumbnails: [UInt32: CGImage] = [:]
    /// Stills the Mac could only answer with an older capture (minimized now, say).
    @Published private(set) var staleThumbnails: Set<UInt32> = []
    /// No still possible yet (minimized with nothing cached, or capture failed): show the app icon.
    @Published private(set) var unavailableThumbnails: Set<UInt32> = []
    @Published private(set) var displayThumbnails: [UInt32: CGImage] = [:]
    @Published private(set) var icons: [String: CGImage] = [:]
    /// Every launchable Mac app (Finder first), from `appCatalog`.
    @Published private(set) var apps: [MacAppItem] = []
    /// Apps opened from this device that haven't shown a window yet.
    @Published private(set) var launching: Set<String> = []
    @Published private(set) var launchFailed: String?
    /// Launchpad (full app grid) is open: keeps catalogs fresh like Stage Peek.
    @Published var launchpadOpen = false { didSet { if launchpadOpen, !oldValue { startRefreshing() } } }
    /// Cards on screen now, most important first: their stills are asked for first.
    var thumbnailPriority: [UInt32] = [] { didSet { if thumbnailPriority != oldValue { requestThumbnails() } } }
    private var planner = ThumbnailRequestPlanner()
    private var appRevision: Int?
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
            // The Mac refused a tile because its window already shows in another one
            // (e.g. a layout saved before that rule): empty the tile instead of leaving
            // it labelled with a window it will never show.
            let duplicates = s.rejected.filter { $0.value == "duplicateWindow" }.map(\.key).filter { layout.tiles[$0]?.source != nil }
            if !duplicates.isEmpty {
                edit { l in duplicates.reduce(l) { $0.replacingSource(of: $1, with: nil) } }
            }
        case .thumbnail(let id, _, let data, let stale):
            let now = Date().timeIntervalSinceReferenceDate
            guard let data, let image = WorkspaceImageDecoder.image(data, maxSide: 560) else {
                planner.failed(id, now: now)
                if thumbnails[id] == nil { unavailableThumbnails.insert(id) }
                return
            }
            planner.received(id, now: now)
            thumbAge[id] = Date()
            thumbnails[id] = image
            unavailableThumbnails.remove(id)
            if stale { staleThumbnails.insert(id) } else { staleThumbnails.remove(id) }
            // Bounded: ~70 stills; the least recently refreshed that isn't on screen goes first.
            if thumbnails.count > 72, let oldest = thumbAge.filter({ !thumbnailPriority.contains($0.key) }).min(by: { $0.value < $1.value })?.key {
                thumbnails[oldest] = nil; thumbAge[oldest] = nil; planner.forget(oldest)
            }
        case .icon(let bundle, let data):
            guard icons.count < 400, let image = WorkspaceImageDecoder.image(data, maxSide: 96) else { return }
            icons[bundle] = image
        case .displayThumbnail(let id, let data):
            guard let image = WorkspaceImageDecoder.image(data, maxSide: 560) else { return }
            displayThumbnails[id] = image
        case .appCatalog(let rev, let list):
            appRevision = rev
            if let list { apps = WorkspaceSearch.carouselOrder(list) }
            requestIcons()
        case .launchResult(let bundle, let ok):
            if !ok { launching.remove(bundle); launchFailed = bundle }
            requestCatalog()
        case .disconnected:
            sendTask?.cancel()
            windowMode = false; remote = nil; available = false; arranging = false; stagePeekOpen = false
            launchpadOpen = false; launching = []; planner.reset()
        }
    }

    private func load(for peer: String) {
        host = peer
        saved = defaults.data(forKey: "workspace.layout.\(peer)").flatMap(WorkspaceLayoutRecord.decode) ?? WorkspaceLayout()
        nextTile = (saved.tiles.keys.compactMap { Int($0.dropFirst()) }.max() ?? 0) + 1
        history = WorkspaceHistory()
        thumbnails = [:]; icons = [:]; thumbAge = [:]; displayThumbnails = [:]
        staleThumbnails = []; unavailableThumbnails = []; planner.reset()
        apps = []; appRevision = nil; launching = []
        generations = [:]
        publish()
    }

    private func onCatalog(_ c: WorkspaceCatalogMessage) {
        Log.info("workspace: catalog received decoded=\(c.windows.count) apps=\(c.apps.count) unavailable=\(c.unavailable) starting=\(c.starting)")
        if c.starting { return }
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
        // An app opened from here showed a window: it's no longer "opening".
        if !launching.isEmpty { launching.subtract(c.windows.map(\.bundleID)) }
        publish()
        if awaitingCatalogToSend { awaitingCatalogToSend = false; scheduleSend(immediately: true) }
        requestThumbnails()
    }

    private var browsing: Bool { overviewOpen || railExpanded || stagePeekOpen || launchpadOpen }

    /// Visible cards first; nothing asked twice within a few seconds; failures back off.
    private func requestThumbnails() {
        guard browsing, let c = catalog else { return }
        let ids = planner.plan(priority: thumbnailPriority, all: c.windows.map(\.id), now: Date().timeIntervalSinceReferenceDate)
        let wantedIcons = Array(Set(c.windows.map(\.bundleID) + c.apps.map(\.bundleID)).filter { icons[$0] == nil }.prefix(48))
        let displays = (stagePeekOpen || overviewOpen) ? c.displays.map(\.id) : []
        guard !ids.isEmpty || !wantedIcons.isEmpty || !displays.isEmpty else { return }
        // Stage Peek's gallery shows large cards: sharp stills.
        _ = send(WorkspaceRequests.thumbnails(ids, maxWidth: stagePeekOpen ? 560 : 320, icons: wantedIcons, displays: displays))
    }

    /// Icons for the app carousel and Launchpad, a page at a time.
    func requestIcons(_ bundles: [String]? = nil) {
        let wanted = (bundles ?? apps.prefix(64).map(\.bundleID)).filter { icons[$0] == nil }
        guard browsing, !wanted.isEmpty else { return }
        _ = send(WorkspaceRequests.thumbnails([], maxWidth: 320, icons: Array(wanted.prefix(48))))
    }

    func requestApps() { _ = send(WorkspaceRequests.appCatalog(revision: apps.isEmpty ? nil : appRevision)) }

    func requestCatalog() { _ = send(WorkspaceRequests.catalog(installed: false)) }

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

    // MARK: Per-tile zoom

    private var zoomGesture: (tile: String, crop: WorkspaceRect?, anchor: WorkspacePoint, rect: WorkspaceRect)?

    /// Two-finger pinch/pan in Window mode. Points are normalized to the picture.
    /// Only the tile under the fingers where the gesture began changes.
    /// A pinch zooms that tile; a two-finger pan (not a pinch) only pans a tile that is already
    /// zoomed in, otherwise it stays a scroll on the Mac. Returns whether the tile took it.
    @discardableResult
    func pinch(began: Bool, ended: Bool, isPinch: Bool, initial: WorkspacePoint, current: WorkspacePoint, scale: Double) -> Bool {
        if began || zoomGesture == nil {
            guard let (id, rect) = frames.tiles.first(where: { $0.value.contains(initial) }).map({ ($0.key, $0.value) }),
                  let tile = layout.tiles[id], tile.source != nil, isPinch || tile.crop != nil else { zoomGesture = nil; return false }
            let content = contentRect(of: id, in: rect)
            let anchor = WorkspacePoint(x: min(max((initial.x - content.x) / max(content.width, 1e-6), 0), 1),
                                        y: min(max((initial.y - content.y) / max(content.height, 1e-6), 0), 1))
            zoomGesture = (id, tile.crop, anchor, content)
            if active != id { focus(id) }
        }
        guard let g = zoomGesture else { return false }
        let pan = WorkspacePoint(x: (current.x - initial.x) / max(g.rect.width, 1e-6),
                                 y: (current.y - initial.y) / max(g.rect.height, 1e-6))
        let crop = WorkspaceZoom.apply(g.crop, scale: scale, anchor: g.anchor, pan: pan)
        let next = saved.zooming(g.tile, to: crop)
        if next != saved {
            saved = next
            publish(); scheduleThrottledSend()
        }
        if ended {
            zoomGesture = nil
            persist()
        }
        return true
    }

    func resetZoom(_ id: String) { edit { $0.zooming(id, to: nil) } }

    /// The first touch in a tile selects it, so typing and zoom go there (also in View Only).
    func selectTile(at p: WorkspacePoint) {
        guard let id = frames.tiles.first(where: { $0.value.contains(p) })?.key,
              layout.tiles[id]?.source != nil, active != id else { return }
        focus(id)
    }

    /// Where the window's picture sits inside a tile (normalized to the canvas), for a fitted window.
    private func contentRect(of id: String, in tile: WorkspaceRect) -> WorkspaceRect {
        guard let tileItem = layout.tiles[id], tileItem.fit == .fit, !tileItem.rotation.isQuarterTurn,
              let source = tileItem.source, let w = catalog?.windows.first(where: { $0.id == source.windowID }),
              w.width > 0, w.height > 0, size.width > 0, size.height > 0 else { return tile }
        let c = tileItem.crop ?? WorkspaceRect(x: 0, y: 0, width: 1, height: 1)
        let srcW = Double(w.width) * c.width, srcH = Double(w.height) * c.height
        let tw = tile.width * size.width, th = tile.height * size.height
        let s = min(tw / srcW, th / srcH)
        let cw = srcW * s / size.width, ch = srcH * s / size.height
        return WorkspaceRect(x: tile.midX - cw / 2, y: tile.midY - ch / 2, width: cw, height: ch)
    }

    private func edit(_ change: (WorkspaceLayout) -> WorkspaceLayout) {
        let next = change(layout)
        guard next != layout else { return }
        history.record(saved)
        var updated = next
        for id in stacked { if let t = saved.tiles[id] { updated = updated.adding(t, landscape: size.width >= size.height) } }
        saved = stacked.isEmpty ? next : updated
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    func undo() {
        guard let previous = history.undo() else { return }
        saved = previous
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    /// After an edit: a tile is missing only while its window is unlisted, so
    /// choosing another window for it (or removing it) clears the mark.
    private func refreshMissing() {
        guard let c = catalog else { return }
        missing = Set(saved.tiles.compactMap { id, tile in
            guard let source = tile.source else { return nil }
            let listed = c.windows.contains { $0.id == source.windowID && (source.bundleID == nil || source.bundleID == $0.bundleID) }
            return listed ? nil : id
        })
    }

    func apply(_ preset: WorkspacePreset) {
        edit { l in
            let ordered = l.orderedTileIDs.compactMap { l.tiles[$0] }
            return ordered.count > preset.slotCount ? l.applying(preset).layout : WorkspaceLayout(preset: preset, tiles: ordered)
        }
    }
    func move(_ tile: String, to target: WorkspaceDropTarget) { edit { $0.materializing(hinge: hinge).moving(tile, to: target) } }
    /// A divider drag: every step resizes, the whole drag is one undo step. Call `endResize()` when it ends.
    func resize(_ divider: WorkspaceDivider, delta: Double) {
        history.beginGroup()
        edit { WorkspaceGeometry.resizing($0, divider: divider, delta: delta, in: size) }
    }

    func endResize() { history.endGroup() }
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
        // One window, one tile: choosing a window that's already showing selects its tile,
        // or swaps the two tiles when replacing another one.
        if let existing = layout.orderedTileIDs.first(where: { layout.tiles[$0]?.source?.host == host && layout.tiles[$0]?.source?.windowID == w.id }) {
            let target = replacing ?? (asNewTile ? nil : active)
            if let target, target != existing, let other = layout.tiles[target]?.source, layout.tiles[existing] != nil {
                edit { l in l.replacingSource(of: target, with: source).replacingSource(of: existing, with: other) }
            }
            focus(target ?? existing)
            return
        }
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

    /// Opens an app on the Mac (explicit action; the Mac refuses it without control and never activates it).
    func launch(_ bundle: String) {
        guard inputAllowed() else { return }
        launchFailed = nil
        launching.insert(bundle)
        _ = send(WorkspaceRequests.appLaunch(bundle))
    }

    func minimizeRemoteWindow(_ tile: String) {
        guard inputAllowed(), let source = layout.tiles[tile]?.source, let gen = generation(source) else { return }
        _ = send(WorkspaceRequests.minimizeWindow(source.windowID, generation: gen))
    }
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

    /// The tile a switcher (Stage Peek) replaces: the active tile, the only
    /// one, else the first tile still waiting for a window, else the last.
    var switchTarget: String? {
        let order = layout.orderedTileIDs
        if let active, layout.tiles[active] != nil { return active }
        if order.count == 1 { return order.first }
        return order.first { missing.contains($0) || layout.tiles[$0]?.source == nil } ?? order.last
    }

    /// The window shown in the tile a switcher would replace.
    var currentWindowID: UInt32? {
        switchTarget.flatMap { layout.tiles[$0]?.source?.windowID }
    }

    /// Stage Peek's tap: shows `w` in `switchTarget`; never adds a tile.
    func switchTo(_ w: CatalogWindowItem) {
        replacingTile = switchTarget
        choose(w, asNewTile: false)
    }

    /// Whether another tile can be added (Stage Peek's "Add as Tile").
    var canAddTile: Bool { layout.tiles.count < capacity }

    /// While any browser is open (in every display mode): catalog every few seconds,
    /// stills as cards appear, the app list once (then only when it changed).
    private func startRefreshing() {
        refreshTask?.cancel()
        requestCatalog()
        requestApps()
        refreshTask = Task { [weak self] in
            var tick = 0
            while let self, self.browsing {
                try? await Task.sleep(nanoseconds: self.overviewOpen || self.stagePeekOpen || self.launchpadOpen ? 3_000_000_000 : 5_000_000_000)
                guard !Task.isCancelled, self.browsing else { break }
                self.requestCatalog()
                tick += 1
                if tick % 5 == 0 { self.requestApps() }
            }
        }
    }

    // MARK: Sending

    private var throttledSendPending = false

    /// Continuous changes (a pinch): send at a steady ~30/s while they keep coming,
    /// instead of waiting for them to stop.
    private func scheduleThrottledSend() {
        guard !throttledSendPending else { return }
        throttledSendPending = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard let self else { return }
            self.throttledSendPending = false
            self.sendNow()
        }
    }

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
