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
                          generation: (WorkspaceSource) -> UInt64?,
                          displayID: (WorkspaceSource) -> UInt32? = { _ in nil }) -> [String: Any] {
        var tiles: [[String: Any]] = []
        for id in layout.orderedTileIDs {
            guard let tile = layout.tiles[id], let source = tile.source, source.host == host,
                  let r = frames.tiles[id], r.width > 0, r.height > 0 else { continue }
            var t: [String: Any] = ["id": id, "host": host, "x": r.x, "y": r.y, "w": r.width, "h": r.height,
                                    "follow": source.follow.rawValue,
                                    "rotation": tile.rotation.rawValue, "fit": tile.fit.rawValue]
            if source.isDisplay {
                // A whole Mac display (Full Desktop in a pane), by its real display id.
                guard let d = displayID(source) else { continue }
                t["display"] = Int(d)
            } else {
                t["window"] = Int(source.windowID)
                if let gen = generation(source) { t["gen"] = Int(gen) }
            }
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

/// Something being dragged over the panes.
struct WorkspaceDrag: Equatable {
    enum Item: Equatable {
        /// A Mac window from Stage Peek.
        case window(CatalogWindowItem)
        /// A pane's label (all its windows), or one of its tabs.
        case pane(String, tab: Int?)
    }
    var item: Item
    /// Global (screen) coordinates.
    var location: CGPoint
}

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
    @Published private(set) var canRedo = false
    /// Layouts saved by name for this Mac, newest first.
    @Published private(set) var savedLayouts: [WorkspaceSavedLayout] = []
    /// A window (from Stage Peek) or a pane label being dragged over the panes.
    @Published private(set) var drag: WorkspaceDrag?
    /// "Fullscreen on This Device": this pane fills the screen locally. The saved arrangement,
    /// dividers and every pane's view are kept and come back unchanged on exit. Not a Mac fullscreen.
    @Published private(set) var localFullscreen: String?
    /// Bumped by the video surface on any touch: reveals the fullscreen strip without taking the touch.
    @Published private(set) var touchPulse = 0
    func noteSurfaceTouch() { if localFullscreen != nil { touchPulse &+= 1 } }
    /// The picture's frame in global (screen) coordinates, reported by the pane chrome, so drags
    /// that start in Stage Peek can find the panes under the finger.
    var pictureGlobal: CGRect = .zero
    /// Mirror/Extend: the desktop picture's global frame (reported by Stage Peek's overlay), so a
    /// window dragged onto the desktop can land beside it.
    var desktopPictureGlobal: CGRect = .zero
    /// The "Cancel" drop zone shown during a drag (global). Dropping there changes nothing.
    var cancelZoneGlobal: CGRect = .zero

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
        saved = (defaults.data(forKey: "workspace.layout.\(peer)").flatMap(WorkspaceLayoutRecord.decode) ?? WorkspaceLayout()).compacted()
        nextTile = (saved.tiles.keys.compactMap { Int($0.dropFirst()) }.max() ?? 0) + 1
        history = WorkspaceHistory()
        savedLayouts = defaults.data(forKey: "workspace.saved.\(peer)").map(WorkspaceSavedLayout.decodeList) ?? []
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
            if source.isDisplay {
                if !c.displays.contains(where: { WorkspaceSource.displayKey($0.id) == source.windowID }) { missing.insert(id) }
                continue
            }
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
        if let full = localFullscreen, adapted.visible.tiles[full] == nil { localFullscreen = nil }
        // Local fullscreen is presentation only: the saved tree is untouched.
        arranged = adapted.visible
        layout = localFullscreen.map { adapted.visible.maximizing($0) } ?? adapted.visible
        stacked = adapted.stacked
        capacity = WorkspaceGeometry.capacity(for: size, hinge: hinge)
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    // MARK: Editing

    // MARK: Per-tile zoom

    private var zoomGesture: (tile: String, crop: WorkspaceRect?, base: WorkspaceRect, anchor: WorkspacePoint, rect: WorkspaceRect,
                              start: WorkspaceRect?)?

    /// The instant local zoom of the pane under the fingers (nil when there is none): the receiver
    /// scales the picture it already has until the Mac's sharp frame arrives. Kept after the
    /// gesture ends so the view can hold it until then.
    private(set) var zoomPreview: WorkspaceZoomPreview?

    /// Two-finger pinch/pan in Window mode. Points are normalized to the picture.
    /// Only the tile under the fingers where the gesture began changes. A pinch zooms that
    /// tile; a two-finger pan moves a tile that is zoomed or filled (otherwise it stays a
    /// scroll on the Mac). The tile keeps its shape: zoom and pan never add bars.
    @discardableResult
    func pinch(began: Bool, ended: Bool, isPinch: Bool, initial: WorkspacePoint, current: WorkspacePoint, scale: Double) -> Bool {
        if began || zoomGesture == nil {
            guard let (id, rect) = frames.tiles.first(where: { $0.value.contains(initial) }).map({ ($0.key, $0.value) }),
                  let tile = layout.tiles[id], tile.source != nil,
                  isPinch || tile.crop != nil || effectiveFit(id) == .fill,
                  let base = fillBase(id, rect: rect) else { zoomGesture = nil; zoomPreview = nil; return false }
            let anchor = WorkspacePoint(x: min(max((initial.x - rect.x) / max(rect.width, 1e-6), 0), 1),
                                        y: min(max((initial.y - rect.y) / max(rect.height, 1e-6), 0), 1))
            zoomGesture = (id, tile.crop, base, Self.unrotate(anchor, tile.rotation), rect, drawnWindowRect(tile, in: rect))
            zoomPreview = nil
            if active != id { focus(id) }
        }
        guard let g = zoomGesture, let tile = layout.tiles[g.tile] else { return false }
        let pan = Self.unrotate(vector: WorkspacePoint(x: (current.x - initial.x) / max(g.rect.width, 1e-6),
                                                       y: (current.y - initial.y) / max(g.rect.height, 1e-6)), tile.rotation)
        let crop = WorkspaceZoom.apply(g.crop, base: g.base, scale: scale, anchor: g.anchor, pan: pan)
        let next = saved.zooming(g.tile, to: crop)
        if next != saved {
            saved = next
            publish(); scheduleThrottledSend()
        }
        if let start = g.start, let now = next.tiles[g.tile].flatMap({ drawnWindowRect($0, in: g.rect) }) {
            zoomPreview = WorkspaceZoomPreview(tile: g.tile, pane: g.rect, from: start, to: now)
        } else {
            zoomPreview = nil
        }
        if ended {
            zoomGesture = nil
            persist()
        }
        return true
    }

    /// Where the pane draws its whole window (picture-normalized; larger than the pane when
    /// filled or zoomed), as the Mac composes it. Nil for a turned pane or without the window's size.
    private func drawnWindowRect(_ tile: WorkspaceTile, in rect: WorkspaceRect) -> WorkspaceRect? {
        guard tile.rotation == .none, let w = windowSize(tile), size.width > 0, size.height > 0 else { return nil }
        if let crop = tile.crop { return WorkspaceZoomPreview.windowRect(crop: crop, content: rect) }
        let c = TileContentTransform(tile: WorkspaceRect(x: rect.x * size.width, y: rect.y * size.height,
                                                         width: rect.width * size.width, height: rect.height * size.height),
                                     source: w, rotation: .none, fit: tile.fit).contentRect
        return WorkspaceRect(x: c.x / size.width, y: c.y / size.height, width: c.width / size.width, height: c.height / size.height)
    }

    /// The pane's fill region in its window (the zoom's 1x), or nil without the window's size.
    private func fillBase(_ id: String, rect: WorkspaceRect) -> WorkspaceRect? {
        guard let tile = layout.tiles[id], let w = windowSize(tile) else { return nil }
        return WorkspaceZoom.fillCrop(window: w, tile: WorkspaceSize(width: rect.width * size.width, height: rect.height * size.height),
                                      rotation: tile.rotation)
    }

    private func windowSize(_ tile: WorkspaceTile) -> WorkspaceSize? {
        guard let source = tile.source, let w = windowItem(source), w.width > 0, w.height > 0 else { return nil }
        return WorkspaceSize(width: Double(w.width), height: Double(w.height))
    }

    /// Fit or fill as actually drawn (`.auto` resolved), for menus and gestures.
    func effectiveFit(_ id: String) -> WorkspaceFit {
        guard let tile = layout.tiles[id] else { return .fit }
        if tile.crop != nil { return .fill }
        guard let rect = frames.tiles[id], let w = windowSize(tile) else { return tile.fit == .auto ? .fit : tile.fit }
        let tilePx = WorkspaceSize(width: rect.width * size.width, height: rect.height * size.height)
        let src = tile.rotation.isQuarterTurn ? WorkspaceSize(width: w.height, height: w.width) : w
        return WorkspaceFit.resolved(tile.fit, tile: tilePx, source: src)
    }

    /// A point in the (rotated) tile, 0..1, as the same point of the unrotated picture.
    private static func unrotate(_ p: WorkspacePoint, _ r: WorkspaceRotation) -> WorkspacePoint {
        switch r {
        case .none: return p
        case .quarter: return WorkspacePoint(x: p.y, y: 1 - p.x)
        case .half: return WorkspacePoint(x: 1 - p.x, y: 1 - p.y)
        case .threeQuarter: return WorkspacePoint(x: 1 - p.y, y: p.x)
        }
    }

    private static func unrotate(vector v: WorkspacePoint, _ r: WorkspaceRotation) -> WorkspacePoint {
        switch r {
        case .none: return v
        case .quarter: return WorkspacePoint(x: v.y, y: -v.x)
        case .half: return WorkspacePoint(x: -v.x, y: -v.y)
        case .threeQuarter: return WorkspacePoint(x: -v.y, y: v.x)
        }
    }

    func resetZoom(_ id: String) { edit { $0.zooming(id, to: nil) } }

    /// Two-finger double-tap: this pane's whole view back to default (zoom, pan, rotation, fit). Other panes untouched.
    func resetView(_ id: String) {
        edit { l in
            guard var tile = l.tiles[id] else { return l }
            tile.crop = nil; tile.rotation = .none; tile.fit = .auto
            var copy = l
            copy.tiles[id] = tile
            return copy
        }
    }

    /// Two-finger double-tap: the pane under the fingers back to its default view.
    func resetView(at p: WorkspacePoint) {
        guard let id = frames.tiles.first(where: { $0.value.contains(p) })?.key, layout.tiles[id]?.source != nil else { return }
        resetView(id)
    }

    /// The first touch in a tile selects it, so typing and zoom go there (also in View Only).
    func selectTile(at p: WorkspacePoint) {
        guard let id = frames.tiles.first(where: { $0.value.contains(p) })?.key,
              layout.tiles[id]?.source != nil, active != id else { return }
        focus(id)
    }

    // MARK: Tabs and drops

    func switchTab(_ id: String, to index: Int) {
        edit { $0.switchingTab(of: id, to: index) }
        focus(id)
    }

    func removeTab(_ id: String, at index: Int) { edit { $0.removingTab(of: id, at: index) } }

    /// A window dropped from Stage Peek: replace a pane's window, add it as a tab, split a pane, or fill an empty slot.
    /// One window shows in one pane only: it leaves the pane (or tab) it was in.
    func drop(_ w: CatalogWindowItem, on target: WorkspaceWindowDrop) {
        guard let source = source(for: w) else { return }
        if !windowMode { requestWindowMode() }
        var focusTile: String?
        edit { l in
            let (next, focus) = dropping(source, on: target, in: l)
            focusTile = focus
            return next
        }
        if let focusTile { focus(focusTile) }
    }

    private func dropping(_ source: WorkspaceSource, on target: WorkspaceWindowDrop, in start: WorkspaceLayout) -> (WorkspaceLayout, String?) {
        var l = start
        if let holder = l.tile(holding: source.host, windowID: source.windowID) {
            if case .replace(let t, _) = target, t == holder { return (l, holder) }
            if case .tab(let t, _) = target, t == holder {
                if let i = l.tiles[holder]?.tabs.firstIndex(where: { $0.windowID == source.windowID }) { l = l.switchingTab(of: holder, to: i) }
                return (l, holder)
            }
            l = Self.detach(source, from: holder, in: l)
        }
        switch target {
        case .replace(let t, _):
            return (l.replacingSource(of: t, with: source), t)
        case .tab(let t, _):
            return (l.addingTab(source, to: t), t)
        case .split(let index, let edge, _):
            let id = "w\(nextTile)"; nextTile += 1
            if l.tiles.count < capacity { return (l.insertingSplit(WorkspaceTile(id: id, source: source), at: index, edge: edge), id) }
            let holder = WorkspaceLayout.slotID(l.root, at: index).flatMap { $0 }
            return (holder.map { l.addingTab(source, to: $0) } ?? l, holder)
        case .emptySlot(let index, _):
            let id = "w\(nextTile)"; nextTile += 1
            return (l.filling(slot: index, with: WorkspaceTile(id: id, source: source)), id)
        }
    }

    /// The pane source for a catalog window (or a display's pseudo-window), remembering its generation.
    private func source(for w: CatalogWindowItem) -> WorkspaceSource? {
        guard let host else { return nil }
        let display = WorkspaceSource.isDisplayKey(w.id)
        let source = WorkspaceSource(host: host, windowID: w.id, bundleID: display ? nil : w.bundleID)
        if !display { setGeneration(source, w.generation) }
        return source
    }

    // MARK: Displays as pane sources (Full Desktop in a tile)

    /// A Mac display as a pane source: a pseudo-window Stage Peek, drops and pickers can use.
    func displayWindow(_ d: CatalogDisplayItem) -> CatalogWindowItem {
        CatalogWindowItem(id: WorkspaceSource.displayKey(d.id), generation: 0, bundleID: "", app: String(localized: "Desktop"),
                          title: d.isMain ? String(localized: "Full Desktop") : d.name,
                          width: d.width, height: d.height, minimized: false, active: false)
    }

    /// The display a display source shows (nil when it isn't one, or the display is gone).
    func display(for source: WorkspaceSource) -> CatalogDisplayItem? {
        guard source.isDisplay else { return nil }
        return catalog?.displays.first { WorkspaceSource.displayKey($0.id) == source.windowID }
    }

    /// The Mac's main real display: what Mirror shows as "the desktop".
    var mainDisplay: CatalogDisplayItem? {
        let all = catalog?.displays ?? []
        return all.first { $0.isMain && !$0.isVirtual } ?? all.first { !$0.isVirtual } ?? all.first
    }

    /// A card's picture: the window's still, or the display's.
    func still(for w: CatalogWindowItem) -> CGImage? {
        guard WorkspaceSource.isDisplayKey(w.id) else { return thumbnails[w.id] }
        return catalog?.displays.first { WorkspaceSource.displayKey($0.id) == w.id }.flatMap { displayThumbnails[$0.id] }
    }

    /// The catalog entry a pane source shows (a display's pseudo-window for displays).
    func windowItem(_ source: WorkspaceSource) -> CatalogWindowItem? {
        if source.isDisplay { return display(for: source).map(displayWindow) }
        return catalog?.windows.first { $0.id == source.windowID }
    }

    /// Mirror/Extend: the picture is one pane showing the desktop, so a window dragged onto it
    /// replaces it, joins it as a tab, or splits it (Window mode then starts with both).
    private func desktopLayout() -> WorkspaceLayout? {
        guard let host, let d = mainDisplay else { return nil }
        let tile = WorkspaceTile(id: "w\(nextTile)", source: WorkspaceSource(host: host, windowID: WorkspaceSource.displayKey(d.id)))
        return WorkspaceLayout(preset: .single, tiles: [tile])
    }

    /// A pane's label dragged elsewhere: onto another pane's labels = merge as tabs, onto an
    /// edge = move the pane there, onto a pane's middle = swap. `tab` moves just that tab.
    func dropTile(_ id: String, tab: Int? = nil, on target: WorkspaceWindowDrop) {
        guard let moving = layout.tiles[id] else { return }
        let windows = tab.map { i in moving.tabs.indices.contains(i) ? [moving.tabs[i]] : [] } ?? moving.windows
        guard !windows.isEmpty else { return }
        edit { l in
            var l = l
            switch target {
            case .tab(let t, _) where t != id:
                for s in windows { l = Self.detach(s, from: id, in: l); l = l.addingTab(s, to: t) }
                return l
            case .replace(let t, _) where t != id:
                if tab != nil, let s = windows.first {
                    l = Self.detach(s, from: id, in: l)
                    return l.addingTab(s, to: t)
                }
                return l.swapping(id, t)
            case .split(let index, let edge, let preview):
                if tab != nil, let s = windows.first, l.tiles.count < capacity {
                    l = Self.detach(s, from: id, in: l)
                    let newID = "w\(nextTile)"; nextTile += 1
                    return l.insertingSplit(WorkspaceTile(id: newID, source: s), at: index, edge: edge)
                }
                return l.materializing(hinge: hinge).moving(id, to: .split(index: index, edge: edge, preview: preview))
            case .emptySlot(let index, let preview):
                return l.materializing(hinge: hinge).moving(id, to: .slot(index: index, preview: preview))
            default:
                return l
            }
        }
    }

    /// Takes a window out of a pane (a tab leaves; a single-window pane is removed).
    private static func detach(_ s: WorkspaceSource, from id: String, in l: WorkspaceLayout) -> WorkspaceLayout {
        guard let tile = l.tiles[id] else { return l }
        if let i = tile.tabs.firstIndex(where: { $0.host == s.host && $0.windowID == s.windowID }) { return l.removingTab(of: id, at: i) }
        return tile.source?.windowID == s.windowID ? l.removing(id) : l
    }

    /// Where a dragged window or label would land (normalized picture point).
    func windowDrop(at p: WorkspacePoint, labelHeight: Double) -> WorkspaceWindowDrop? {
        WorkspaceGeometry.windowDrop(at: p, layout: layout, frames: frames, size: size, labelHeight: labelHeight,
                                     canSplit: layout.tiles.count < capacity)
    }

    /// The arrangement without local fullscreen: what edits apply to.
    private var arranged = WorkspaceLayout()

    private func edit(_ change: (WorkspaceLayout) -> WorkspaceLayout) {
        // Never an empty pane: a window that leaves a pane closes it up and the rest grow.
        let next = change(arranged).compacted()
        guard next != arranged else { return }
        history.record(saved)
        var updated = next
        for id in stacked { if let t = saved.tiles[id] { updated = updated.adding(t, landscape: size.width >= size.height) } }
        saved = stacked.isEmpty ? next : updated
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    func undo() {
        guard let previous = history.undo(current: saved) else { return }
        saved = previous
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    func redo() {
        guard let next = history.redo(current: saved) else { return }
        saved = next
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    // MARK: Saved layouts

    /// Keeps this arrangement under `name` for this Mac (a saved layout with the same name is replaced).
    func saveLayout(named name: String) {
        guard let host else { return }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        var n = savedLayouts.count + 1
        while trimmed.isEmpty, savedLayouts.contains(where: { $0.name == "Layout \(n)" }) { n += 1 }
        let title = trimmed.isEmpty ? "Layout \(n)" : trimmed
        var list = savedLayouts.filter { $0.name != title }
        list.insert(WorkspaceSavedLayout(id: UUID().uuidString, name: title, record: WorkspaceLayoutRecord(saved)), at: 0)
        savedLayouts = Array(list.prefix(WorkspaceSavedLayout.maximum))
        defaults.set(WorkspaceSavedLayout.encodeList(savedLayouts), forKey: "workspace.saved.\(host)")
    }

    /// Puts a saved layout back, on the windows open now (one undo step).
    func applySaved(_ id: String) {
        guard let s = savedLayouts.first(where: { $0.id == id }) else { return }
        var layout = s.record.layout
        if let c = catalog { layout = layout.rebinding(to: c.windows.map { ($0.id, $0.bundleID) }) }
        layout = layout.compacted()
        guard layout != saved else { return }
        history.record(saved)
        saved = layout
        nextTile = max(nextTile, (saved.tiles.keys.compactMap { Int($0.dropFirst()) }.max() ?? 0) + 1)
        refreshMissing()
        persist(); publish(); scheduleSend()
    }

    func deleteSavedLayout(_ id: String) {
        guard let host else { return }
        savedLayouts.removeAll { $0.id == id }
        defaults.set(WorkspaceSavedLayout.encodeList(savedLayouts), forKey: "workspace.saved.\(host)")
    }

    /// After an edit: a tile is missing only while its window is unlisted, so
    /// choosing another window for it (or removing it) clears the mark.
    private func refreshMissing() {
        guard let c = catalog else { return }
        missing = Set(saved.tiles.compactMap { id, tile in
            guard let source = tile.source else { return nil }
            if source.isDisplay { return c.displays.contains { WorkspaceSource.displayKey($0.id) == source.windowID } ? nil : id }
            let listed = c.windows.contains { $0.id == source.windowID && (source.bundleID == nil || source.bundleID == $0.bundleID) }
            return listed ? nil : id
        })
    }

    func apply(_ preset: WorkspacePreset) {
        edit { l in
            var ordered = l.orderedTileIDs.compactMap { l.tiles[$0] }
            // 2x2 or 3x3 with fewer windows showing: the Mac's other open windows (front to back)
            // fill the rest, so the grid has no empty panes. Fewer windows than panes: it closes up.
            if ordered.count < preset.slotCount, let c = catalog {
                let shown = Set(l.tiles.values.flatMap(\.windows).map(\.windowID))
                for w in c.windows where !w.minimized && !shown.contains(w.id) && ordered.count < preset.slotCount {
                    guard let source = source(for: w) else { break }
                    ordered.append(WorkspaceTile(id: "w\(nextTile)", source: source))
                    nextTile += 1
                }
            }
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
    /// Fill Tile / Show Whole Window, from what the tile shows now (`.auto` resolved). Clears zoom.
    func toggleFit(_ tile: String) {
        let next: WorkspaceFit = effectiveFit(tile) == .fill ? .fit : .fill
        edit { l in l.zooming(tile, to: nil).settingFit(next, for: tile) }
    }
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
        guard let host, let source = source(for: w) else { return }
        let replacing = replacingTile
        closeOverview()
        if !windowMode { requestWindowMode() }
        let landscape = size.width >= size.height
        // One window, one tile: choosing a window that's already showing selects its tile,
        // or swaps the two tiles when replacing another one.
        if let holder = layout.tile(holding: host, windowID: w.id), layout.tiles[holder]?.source?.windowID != w.id,
           let i = layout.tiles[holder]?.tabs.firstIndex(where: { $0.windowID == w.id }) {
            // It's a background tab: show that tab.
            edit { $0.switchingTab(of: holder, to: i) }
            focus(holder)
            return
        }
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

    // MARK: Local fullscreen (receiver only)

    func enterLocalFullscreen(_ tile: String) {
        guard layout.tiles[tile] != nil else { return }
        localFullscreen = tile
        publish(); scheduleSend(immediately: true)
        focus(tile)
    }

    func exitLocalFullscreen() {
        guard localFullscreen != nil else { return }
        localFullscreen = nil
        publish(); scheduleSend(immediately: true)
    }

    // MARK: Dragging windows and labels onto panes

    func beginDrag(_ item: WorkspaceDrag.Item, at global: CGPoint) { drag = WorkspaceDrag(item: item, location: global) }
    func moveDrag(to global: CGPoint) { if drag != nil { drag?.location = global } }
    func cancelDrag() { drag = nil }

    /// The drop under the finger, in picture terms. Nil outside the picture and over the Cancel zone.
    /// In Mirror/Extend the desktop counts as one pane (a window can land beside it).
    func dropTarget(forGlobal p: CGPoint, labelHeight: CGFloat = 30) -> WorkspaceWindowDrop? {
        if overCancelZone(p) { return nil }
        if !windowMode {
            guard case .window = drag?.item, desktopPictureGlobal.width > 0, desktopPictureGlobal.contains(p) else { return nil }
            // No display listed (an older Mac): the window simply shows in Window mode.
            guard let desk = desktopLayout() else { return .replace(tile: Self.noDesktop, preview: WorkspaceRect(x: 0, y: 0, width: 1, height: 1)) }
            let g = desktopPictureGlobal
            let s = WorkspaceSize(width: g.width, height: g.height)
            let n = WorkspacePoint(x: (p.x - g.minX) / g.width, y: (p.y - g.minY) / g.height)
            return WorkspaceGeometry.windowDrop(at: n, layout: desk, frames: WorkspaceGeometry.frames(for: desk, in: s, hinge: nil),
                                                size: s, labelHeight: Double(labelHeight / g.height), canSplit: true)
        }
        guard pictureGlobal.width > 0, pictureGlobal.contains(p) else { return nil }
        let n = WorkspacePoint(x: (p.x - pictureGlobal.minX) / pictureGlobal.width, y: (p.y - pictureGlobal.minY) / pictureGlobal.height)
        return windowDrop(at: n, labelHeight: Double(labelHeight / pictureGlobal.height))
    }

    /// The drop target when no display can join the window (it then shows alone).
    static let noDesktop = "\u{0}desktop"

    func overCancelZone(_ p: CGPoint) -> Bool { cancelZoneGlobal.width > 0 && cancelZoneGlobal.insetBy(dx: -8, dy: -8).contains(p) }

    /// Ends a drag: drops onto the pane under the finger. Dropped on Cancel or outside the
    /// picture: nothing changes. Returns whether anything changed.
    @discardableResult
    func endDrag() -> Bool {
        guard let d = drag else { return false }
        let target = dropTarget(forGlobal: d.location)
        drag = nil
        guard let target else { return false }
        switch d.item {
        case .window(let w):
            if !windowMode {
                // Mirror/Extend: Window mode starts with the desktop and the window as dropped.
                guard let desk = desktopLayout() else { switchTo(w); return true }
                guard let source = source(for: w) else { return false }
                nextTile += 1   // the desktop pane's id
                let (next, focusTile) = dropping(source, on: target, in: desk)
                history.record(saved)
                saved = next.compacted()
                localFullscreen = nil
                refreshMissing(); persist(); publish()
                requestWindowMode()
                if let focusTile { focus(focusTile) }
                return true
            }
            drop(w, on: target)
            return true
        case .pane(let id, let tab):
            dropTile(id, tab: tab, on: target)
            return true
        }
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
                                             host: host, focus: active, generation: generation,
                                             displayID: { [weak self] in self?.display(for: $0)?.id }))
    }

    private func persist() {
        guard let host, let data = WorkspaceLayoutRecord(saved).encoded() else { return }
        defaults.set(data, forKey: "workspace.layout.\(host)")
    }
}
