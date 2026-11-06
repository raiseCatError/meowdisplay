import CoreGraphics
import Foundation
import ImageIO
import QuartzCore

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
    /// In Stage Manager's side strip: macOS pauses its picture there (PROTOCOL.md §6.10).
    var inStageStrip = false

    /// A short card badge for a window that can't show a current picture, or nil.
    var pausedBadge: String? {
        minimized ? String(localized: "Minimized") : inStageStrip ? String(localized: "In Strip") : nil
    }
    /// The same for VoiceOver.
    var pausedSpoken: String? {
        minimized ? String(localized: "Minimized") : inStageStrip ? String(localized: "In Stage Manager’s side strip, picture paused") : nil
    }
}

/// The outcome of one Close Window, worded for the person who asked.
struct WindowCloseNotice: Equatable, Sendable {
    var windowID: UInt32
    var name: String
    /// nil: no answer from the Mac (or it can't close windows from here).
    var result: WindowCloseResult?
    var unsupported = false

    var isError: Bool { result != .closed && result != .stale }

    var message: String {
        if unsupported { return String(localized: "Update MeowDisplay on the Mac to close windows from here.") }
        switch result {
        case .closed: return String(localized: "Closed “\(name)”.")
        case .saveDialog: return String(localized: "“\(name)” has unsaved changes. Choose Save or Don’t Save on the Mac.")
        case .stillOpen: return String(localized: "“\(name)” stayed open. Its app may be busy or asking something on the Mac.")
        case .stale: return String(localized: "“\(name)” was already closed.")
        case .control: return String(localized: "Closing windows needs control of the Mac. Use Request Control first.")
        case .accessibility: return String(localized: "The Mac needs Accessibility permission for MeowDisplay to close windows.")
        case .noButton: return String(localized: "“\(name)” can’t be closed: it has no close button.")
        case .ambiguous: return String(localized: "The Mac couldn’t tell which window to close, so nothing was closed.")
        case nil: return String(localized: "The Mac didn’t confirm closing “\(name)”.")
        }
    }
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

/// A pane's capture on the Mac. `paused`: macOS paused it (Stage Manager's side strip, a hidden
/// window); `retrying`: it stalled and the Mac is restarting it; `failed`: gave up (Retry).
enum RemoteTileStatus: String, Sendable { case live, waiting, offscreen, closed, failed, limit, paused, retrying }

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
    /// Restarts so far while `retrying`.
    var attempt = 0
    /// The window sits in Stage Manager's side strip (macOS pauses its picture there).
    var inStageStrip = false
    /// The Mac accepted it as a floating pane (`layer: "float"`).
    var isFloat = false
}

struct WorkspaceStateMessage: Equatable, Sendable {
    var host: String?
    var tiles: [RemoteTileItem]
    var active: String?
    var hostFocus: RemoteHostFocus
    var rejected: [String: String]
    /// Stage Manager is on on the Mac (its strip pauses windows).
    var stageManager = false
    /// Whether Stage Manager is on (true) or off (false); nil: an older Mac that only says when it is on.
    var stageManagerOn: Bool?
    /// Whether the Mac can switch it: "ready", "setup" (the owner hasn't made the two shortcuts on
    /// the Mac yet) or "failed" (macOS didn't apply the last change). nil: an older Mac, never offered.
    var stageManagerControl: String?
    /// The last Add to Current Stage (for 8 s): the window and "added", "notInStrip", "ambiguous",
    /// "accessibility" or "failed".
    var stageAdd: StageAddReply?
    /// The Mac can add a strip window to the current stage (off until it is shown to work).
    var stageAddAvailable = false
    /// Mission Control is open on the Mac: macOS pauses window pictures until it closes.
    var missionControlOpen = false
}

struct StageAddReply: Equatable, Sendable { let window: UInt32; let result: String }

enum WorkspaceEvent: Sendable {
    case features(Set<String>)
    /// The Mac's Privacy Shield covers its own screens while this device is connected (welcome).
    case privacyShield(Bool)
    case mode(window: Bool)
    case catalog(WorkspaceCatalogMessage)
    case state(WorkspaceStateMessage)
    case thumbnail(windowID: UInt32, generation: UInt64, data: Data?, stale: Bool = false)
    case icon(bundleID: String, data: Data)
    case displayThumbnail(displayID: UInt32, data: Data)
    /// `apps` nil: the receiver's revision is current.
    case appCatalog(revision: Int, apps: [MacAppItem]?)
    case launchResult(bundleID: String, ok: Bool)
    /// Close Window from Stage Peek (PROTOCOL.md 6.10).
    case closeResult(windowID: UInt32, result: WindowCloseResult)
    /// Lock This Mac (PROTOCOL.md 6.16).
    case lockResult(LockMacResult)
    /// Remote Finder (PROTOCOL.md 6.12).
    case files(RemoteFilesReply)
    /// Unified Clipboard (PROTOCOL.md 6.15).
    case clip(ClipboardMessage)
    /// Pane menus (PROTOCOL.md 6.13).
    case menu(AppMenuReply)
    case menuResult(ok: Bool, error: String?)
    /// Panes whose latest view (epoch) the Mac has composed and sent.
    case view([String: Int])
    /// A pane's whole source as a still, for the instant local zoom.
    case backdrop(tile: String, windowID: UInt32, data: Data, stale: Bool)
    case connected(peerID: String)
    case disconnected

    static let maxBase64 = 256 * 1024   // a sharp 640-wide Stage Peek still
    static let maxBackdropBase64 = WorkspaceBackdrop.maxBase64   // a pane's whole source, up to 1600 wide

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
                                         minimized: (w["state"] as? String) == "offscreen", active: w["active"] as? Bool ?? false,
                                         inStageStrip: w["strip"] as? Bool ?? false)
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
                                      app: str(t, "app", 80) ?? "", bundleID: str(t, "bundle") ?? "", title: str(t, "title", 120) ?? "",
                                      attempt: min(max(t["attempt"] as? Int ?? 0, 0), 99), inStageStrip: t["strip"] as? Bool ?? false,
                                      isFloat: t["layer"] as? String == "float")
            }
            let rejected = (obj["rejected"] as? [String: Any] ?? [:]).prefix(32).reduce(into: [String: String]()) { r, e in
                if let v = e.value as? String { r[e.key] = v }
            }
            return .state(WorkspaceStateMessage(host: str(obj, "host"), tiles: Array(tiles), active: str(obj, "active", 32),
                                                hostFocus: (obj["hostFocus"] as? String).flatMap(RemoteHostFocus.init(rawValue:)) ?? .noActiveTile,
                                                rejected: rejected, stageManager: obj["stageManager"] as? Bool ?? false,
                                                stageManagerOn: (obj["stageManagerState"] as? String).flatMap { $0 == "on" ? true : $0 == "off" ? false : nil },
                                                stageManagerControl: str(obj, "stageManagerControl", 16),
                                                stageAdd: (obj["stageAdd"] as? [String: Any]).flatMap { a in
                                                    u32(a, "window").flatMap { w in str(a, "result", 16).map { StageAddReply(window: w, result: $0) } }
                                                },
                                                stageAddAvailable: obj["stageAddAvailable"] as? Bool ?? false,
                                                missionControlOpen: obj["missionControl"] as? String == "open"))
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
        case WireMessage.windowCloseResult:
            guard let id = u32(obj, "window"), let r = str(obj, "result", 32).flatMap(WindowCloseResult.init(rawValue:)) else { return nil }
            return .closeResult(windowID: id, result: r)
        case LockMacWire.result:
            return str(obj, "result", 32).flatMap(LockMacResult.init(rawValue:)).map { .lockResult($0) }
        case WireMessage.files:
            return RemoteFilesReply.parse(obj).map { .files($0) }
        case ClipboardWire.type:
            return .clip(ClipboardMessage(obj: obj))
        case WireMessage.menu:
            return AppMenuReply.parse(obj).map { .menu($0) }
        case WireMessage.menuResult:
            return .menuResult(ok: obj["ok"] as? Bool ?? false, error: (obj["error"] as? String).map { String($0.prefix(32)) })
        case WireMessage.workspaceView:
            let tiles = (obj["tiles"] as? [String: Any] ?? [:]).prefix(WorkspaceLayout.maximumTiles * 2).reduce(into: [String: Int]()) { r, e in
                if e.key.count <= 32, let v = e.value as? Int { r[e.key] = v }
            }
            return .view(tiles)
        case WireMessage.workspaceBackdrop:
            guard let tile = str(obj, "tile", 32), let jpeg = obj["jpeg"] as? String, jpeg.count <= maxBackdropBase64,
                  let data = Data(base64Encoded: jpeg) else { return nil }
            return .backdrop(tile: tile, windowID: u32(obj, "window") ?? 0, data: data, stale: obj["stale"] as? Bool ?? false)
        case WireMessage.appIcon:
            guard let bundle = str(obj, "bundle"), let png = obj["png"] as? String, png.count <= maxBase64,
                  let data = Data(base64Encoded: png) else { return nil }
            return .icon(bundleID: bundle, data: data)
        default:
            return nil
        }
    }
}

/// Hands workspace events from the network queue to the main actor, in the order they came
/// (Remote Finder's file data arrives in ordered parts).
final class WorkspaceEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@MainActor @Sendable (WorkspaceEvent) -> Void)?

    func set(_ handler: (@MainActor @Sendable (WorkspaceEvent) -> Void)?) {
        lock.lock(); self.handler = handler; lock.unlock()
    }

    func emit(_ event: WorkspaceEvent) {
        lock.lock(); let handler = self.handler; lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(event) } }
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

    /// Only this host's tiles, at their normalized frames. `floats`: the Mac draws floating panes
    /// (`windowFloat`): the shown floats follow the tiled panes as `layer: "float"`, back to
    /// front by `z`. Without it no float is sent (they wait tucked), and a layout without floats
    /// is sent exactly as before.
    static func workspace(_ layout: WorkspaceLayout, frames: WorkspaceFrames, host: String, focus: String?,
                          generation: (WorkspaceSource) -> UInt64?,
                          displayID: (WorkspaceSource) -> UInt32? = { _ in nil },
                          viewEpoch: (String) -> Int? = { _ in nil },
                          floats: Bool = false) -> [String: Any] {
        var tiles: [[String: Any]] = []
        let floating = floats ? layout.floatIDs.filter { frames.tiles[$0] != nil } : []
        for id in layout.orderedTileIDs + floating {
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
            if let z = tile.zoom { t["zoom"] = z.wire }
            if let e = viewEpoch(id) { t["view"] = e }
            if let z = floating.firstIndex(of: id) { t["layer"] = "float"; t["z"] = z }
            tiles.append(t)
        }
        var m: [String: Any] = ["type": WireMessage.workspaceRequest, "tiles": tiles]
        if let focus { m["focus"] = focus }
        return m
    }

    /// Start a pane's capture again now (it stalled or failed).
    static func retry(_ tile: String) -> [String: Any] { ["type": WireMessage.workspaceRetry, "tile": tile] }

    /// A pane's whole source as a still (`max` pixels wide at most).
    static func backdrop(_ tile: String, max: Int, req: Int) -> [String: Any] {
        ["type": WireMessage.workspaceBackdropRequest, "tile": tile, "max": max, "req": req]
    }

    /// Brings the real Mac window forward (needs control): the only way to show a window
    /// Stage Manager keeps in its side strip.
    /// Owner-confirmed on the device, control only: turn Stage Manager off for Window mode
    /// (the Mac turns it back on when Window mode ends), or undo that.
    /// Exit Mission Control: the Mac checks it is open, then presses Escape (control only).
    static var exitMissionControl: [String: Any] {
        ["type": WireMessage.windowAction, "action": "missionControl", "exit": true]
    }

    static func stageManager(on: Bool) -> [String: Any] {
        ["type": WireMessage.windowAction, "action": "stageManager", "on": on]
    }

    static func activateWindow(_ id: UInt32, generation: UInt64) -> [String: Any] {
        ["type": WireMessage.windowAction, "action": "activate", "window": Int(id), "gen": Int(generation)]
    }

    /// `raise` false: the tile was chosen by arranging this device's view, so the Mac keeps its
    /// window where it is until a key or a press for it needs it in front (older Macs ignore it).
    static func focus(_ tile: String?, raise: Bool = true) -> [String: Any] {
        var m: [String: Any] = ["type": WireMessage.workspaceFocus]
        if let tile { m["tile"] = tile }
        if !raise { m["raise"] = false }
        return m
    }

    static func launch(_ bundle: String) -> [String: Any] { ["type": WireMessage.windowAction, "action": "launch", "bundle": bundle] }

    /// Close Window from Stage Peek: presses that window's close button (any mode, needs control).
    static func windowClose(_ id: UInt32, generation: UInt64, req: Int) -> [String: Any] {
        ["type": WireMessage.windowClose, "window": Int(id), "gen": Int(generation), "req": req]
    }

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
        /// An app from Stage Peek's carousel, search or Launchpad: its window when it has one;
        /// several → the person picks; none → offered to open it (never just because a drag began).
        case app(MacAppItem)
        /// A floating pane, shaken (or switched) into Pane placement: it docks where it's dropped.
        case float(String)
    }
    var item: Item
    /// Global (screen) coordinates.
    var location: CGPoint
    /// Where a drop goes: into the panes (tab, split, swap) or floating at the finger. Switched
    /// with a shake while holding, or the drag's Float/Dock control; Cancel keeps everything.
    var placement: WorkspacePlacement = .pane
}

/// The two ways a dragged window lands in one workspace (never a global mode).
enum WorkspacePlacement: String, CaseIterable, Sendable {
    /// Into the panes: the pane, tab and split targets.
    case pane
    /// Floating, where it is dropped.
    case float
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var available = false
    @Published private(set) var windowMode = false
    @Published private(set) var layout = WorkspaceLayout()
    @Published private(set) var stacked: [String] = []
    @Published private(set) var capacity = 1
    @Published private(set) var remote: WorkspaceStateMessage? {
        // Folded Mission Control notices last only while it stays open.
        didSet { if remote?.missionControlOpen != true, !missionControlFolded.isEmpty { missionControlFolded = [] } }
    }
    /// Shown for a few seconds after each connection: whether the Mac's Privacy Shield is on.
    @Published private(set) var privacyShieldNotice: Bool?
    private var privacyNoticeClear: DispatchWorkItem?
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
    /// The Mac can close a listed window from Stage Peek (`windowClose`).
    @Published private(set) var canCloseWindows = false
    /// The Mac draws floating panes (`windowFloat`). Without it floats are kept, tucked, unsent.
    @Published private(set) var canFloat = false
    /// This receiver has floating-pane chrome (iPhone and iPad). The Mac Receiver doesn't yet:
    /// it says `ws` 1 and never floats a pane.
    nonisolated static let floatsDrawnHere: Bool = {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }()
    /// Per model, so tests on the Mac can exercise floats.
    var floatsDrawnHere = WorkspaceModel.floatsDrawnHere
    /// The Mac offers Lock This Mac (any mode); the last request's outcome.
    @Published private(set) var canLockMac = false
    @Published private(set) var lockMacStatus: LockMacStatus?
    enum LockMacStatus: Equatable { case locking, done(LockMacResult) }
    private var lockRequest = 0
    /// Windows asked to close that the Mac hasn't answered for yet.
    @Published private(set) var closingWindows: Set<UInt32> = []
    /// What happened to the last Close Window (shown briefly over Stage Peek).
    @Published var closeNotice: WindowCloseNotice?
    private var closeRequest = 0
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
    /// Each pane's tab labels on screen (global), by tab index: where a dragged tab is put back.
    var tabLabelFrames: [String: [Int: CGRect]] = [:]
    /// The "Cancel" drop zone shown during a drag (global). Dropping there changes nothing.
    var cancelZoneGlobal: CGRect = .zero
    /// The "Remove from Layout" drop zone (global), shown only while `canDropToRemove`.
    var removeZoneGlobal: CGRect = .zero
    /// While dragging in Pane placement: the Float zone beside Cancel (global). Releasing there
    /// floats the window instead (the way that needs no shake).
    var floatZoneGlobal: CGRect = .zero
    /// Tucked floats' edge handles (global), so Stage Peek's edge strip keeps clear of them.
    @Published var floatHandlesGlobal: [CGRect] = []
    /// The first-use tip about shaking a drag (shown once, ever, on this device).
    @Published private(set) var shakeTipVisible = false

    /// Sends one workspace message on the current, admitted connection.
    var send: ([String: Any]) -> Bool = { _ in false }
    /// Asks the Mac for Window mode (displayModeRequest "window").
    var requestWindowMode: () -> Void = {}
    /// Whether this session may change the Mac (launch apps, close windows).
    var inputAllowed: () -> Bool = { false }
    /// Whether this device shows the Mac in Mirror now (outside Window view), as the Mac confirmed.
    var mirroring: () -> Bool = { false }
    /// The Mac's manual Mirror display choice (nil: Automatic), so a float opened over the
    /// mirrored desktop keeps that same desktop behind it.
    var mirrorChoice: () -> MirrorDisplayEntry? = { nil }
    /// Whether this device extends the Mac now (outside Window view), as the Mac confirmed.
    var extending: () -> Bool = { false }

    /// A step that would start Window view from Extend, waiting for the person to confirm it.
    struct LeaveExtendRequest: Identifiable {
        let id = UUID()
        let perform: () -> Void
    }
    /// Leaving Extend removes this device's extended display, and macOS moves the windows on it to
    /// the Mac's other displays, so a tap, a pick or a drop never does it by itself: it waits here
    /// until the person confirms (`confirmLeavingExtend`). Mirror and Window view never wait.
    @Published private(set) var leaveExtendRequest: LeaveExtendRequest?
    private var leavingExtendConfirmed = false

    /// True when `step` has to wait for confirmation (it is kept until then); false: go ahead.
    private func holdForLeavingExtend(_ step: @escaping () -> Void) -> Bool {
        guard !windowMode, extending(), !leavingExtendConfirmed else { return false }
        leaveExtendRequest = LeaveExtendRequest(perform: step)
        return true
    }

    /// The person chose to leave Extend for Window view: the step they took runs now.
    func confirmLeavingExtend() {
        guard let request = leaveExtendRequest else { return }
        leaveExtendRequest = nil
        leavingExtendConfirmed = true
        defer { leavingExtendConfirmed = false }
        request.perform()
    }

    /// Stay in Extend: nothing changes.
    func cancelLeavingExtend() { leaveExtendRequest = nil }

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
        files = RemoteFilesModel(defaults: defaults)
        menus = AppMenuModel(defaults: defaults)
        clipboard = ClipboardModel(defaults: defaults)
        clipboard.send = { [weak self] m in self?.send(m) ?? false }
        files.send = { [weak self] m in self?.send(m) ?? false }
        files.inputAllowed = { [weak self] in self?.inputAllowed() ?? false }
        files.macKey = { [weak self] in self?.host }
        menus.send = { [weak self] m in self?.send(m) ?? false }
    }

    /// The focused pane's app menus (a bar under its label).
    let menus: AppMenuModel

    /// Remote Finder: the Mac's approved folders, browsed here (Finder in the carousel opens it).
    let files: RemoteFilesModel

    /// Unified Clipboard with the connected Mac (off until turned on here and allowed there).
    let clipboard: ClipboardModel

    var active: String? { remote?.active }
    /// The connected Mac's name as paired (never a name the network claims).
    var hostName: String {
        host.flatMap { id in TrustStore.receiverRole.pinnedPeers().first { $0.peerID == id }?.displayName } ?? "your Mac"
    }
    var frames: WorkspaceFrames { WorkspaceGeometry.frames(for: layout, in: size, hinge: hinge) }
    /// The workspace's size in points (what float sizes and flings are measured in).
    var space: WorkspaceSize { size }
    func tileState(_ id: String) -> RemoteTileItem? { remote?.tiles.first { $0.id == id } }

    // MARK: Events

    func apply(_ event: WorkspaceEvent) {
        switch event {
        case .connected(let peer):
            if peer != host { load(for: peer) }
        case .privacyShield(let on):
            privacyShieldNotice = on
            privacyNoticeClear?.cancel()
            let clear = DispatchWorkItem { [weak self] in self?.privacyShieldNotice = nil }
            privacyNoticeClear = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: clear)
        case .features(let f):
            available = f.contains(WindowWorkspaceWire.welcomeFeature)
            files.setAvailable(f.contains(RemoteFilesWire.welcomeFeature))
            menus.setAvailable(f.contains(AppMenuWire.welcomeFeature))
            canCloseWindows = f.contains(WindowCloseWire.welcomeFeature)
            canFloat = floatsDrawnHere && f.contains(WindowWorkspaceWire.floatFeature)
            publish()
            canLockMac = f.contains(LockMacWire.welcomeFeature)
            clipboard.setAvailable(f.contains(ClipboardWire.welcomeFeature))
        case .files(let reply):
            files.apply(reply)
        case .clip(let m):
            clipboard.handle(m)
        case .menu(let reply):
            menus.apply(reply)
        case .menuResult(let ok, let error):
            menus.applyResult(ok: ok, error: error)
        case .view(let tiles):
            composedViewEpochs.merge(tiles) { old, new in max(old, new) }
        case .backdrop(let tile, let window, let data, let stale):
            guard layout.tiles[tile]?.source?.windowID == window || window == 0,
                  let image = WorkspaceImageDecoder.image(data, maxSide: 1600) else { return }
            if let asked = backdropAskedAt[tile] {
                Log.info("workspace: backdrop \(tile) \(image.width)x\(image.height) after \(Int(Date().timeIntervalSince(asked) * 1000)) ms\(zoomGesture?.tile == tile ? " (mid-gesture)" : "")")
            }
            backdrops[tile] = WorkspaceBackdrop(windowID: window, image: image, stale: stale)
        case .mode(let window):
            windowMode = window
            leaveExtendRequest = nil   // the mode changed underneath: the question no longer applies
            if !window { remote = nil }
            if window { awaitingCatalogToSend = true; requestCatalog() }
        case .catalog(let c):
            onCatalog(c)
        case .state(let s):
            remote = s
            if let r = requestedFocus, s.active == r || layout.tiles[r] == nil { requestedFocus = nil }
            // A live pane gets its whole-source still before the first pinch, so zooming out or
            // panning never shows an empty area while the fingers move (bounded: once a second).
            for item in s.tiles where item.status == .live && backdrop(item.id) == nil && zoomGesture == nil {
                requestBackdrop(item.id)
            }
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
        case .closeResult(let id, let result):
            finishClose(id, result: result)
        case .lockResult(let result):
            lockMacStatus = .done(result)
        case .disconnected:
            sendTask?.cancel()
            leaveExtendRequest = nil
            windowMode = false; remote = nil; available = false; arranging = false; stagePeekOpen = false
            launchpadOpen = false; launching = []; planner.reset()
            canCloseWindows = false; closingWindows = []; closeNotice = nil
            canFloat = false; floatGesture = nil
            canLockMac = false; lockMacStatus = nil
            files.setAvailable(false)
            menus.setAvailable(false)
            clipboard.setAvailable(false)
            // A new session's frames carry no echo of this one's views; stills are re-asked.
            composedViewEpochs = [:]; viewEpochs = [:]; viewSignatures = [:]; backdrops = [:]; backdropAskedAt = [:]
            zoomGesture = nil; zoomPreview = nil
            requestedFocus = nil; floatGestureStart = nil; drag = nil
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
        defer { placePendingAppWindow() }
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
        let adapted = WorkspaceAdaptation.adapt(saved, to: size, hinge: hinge, active: remote?.active, floatsShown: canFloat || !windowMode)
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

    private var zoomGesture: (tile: String, start: WorkspacePaneZoom?, rect: WorkspaceRect, drawn: WorkspaceRect?,
                              rotation: WorkspaceRotation, turnFrom: Double?)?

    /// A twist this large (degrees) starts turning the pane, so a pinch's natural wobble never
    /// turns it; the turn then follows the fingers from there, without a jump.
    static let turnDeadZone = 8.0

    /// The instant local zoom of the pane under the fingers (nil when there is none): the receiver
    /// moves the picture it already has (and the pane's whole-source still where that doesn't
    /// reach) until a Mac frame with the same view arrives. Kept after the gesture ends until then.
    private(set) var zoomPreview: WorkspaceZoomPreview?

    /// Each pane's view counter: bumped when its zoom, fit, rotation or frame changes, sent with
    /// the request, echoed by the Mac once a frame with that view went out (`workspaceView`).
    private var viewEpochs: [String: Int] = [:]
    private var viewSignatures: [String: String] = [:]
    private var nextViewEpoch = 1
    private(set) var composedViewEpochs: [String: Int] = [:]

    /// Each pane's whole source as a still (from the Mac), for zooming out and panning instantly.
    private(set) var backdrops: [String: WorkspaceBackdrop] = [:]
    private var backdropReq = 0
    private var backdropAskedAt: [String: Date] = [:]

    /// The instant zoom to draw now (after a gesture: until the Mac's frame with its view is out).
    func liveZoom() -> WorkspaceLiveZoom? {
        guard let p = zoomPreview else { return nil }
        return WorkspaceLiveZoom(preview: p, backdrop: backdrop(p.tile)?.image, composed: zoomGesture == nil && viewComposed(p.tile))
    }

    /// The pane's newest view has reached the screen (or there is nothing to wait for).
    func viewComposed(_ tile: String) -> Bool {
        guard let want = viewEpochs[tile] else { return true }
        return (composedViewEpochs[tile] ?? 0) >= want
    }

    /// Two-finger pinch/pan in Window mode. Points are normalized to the picture.
    /// Only the pane under the fingers where the gesture began changes. A pinch zooms it from
    /// 0.7x to 8x of its Fit (or Fill) size around the fingers; a two-finger pan moves a pane
    /// that is zoomed or filled (otherwise it stays a scroll on the Mac).
    /// `turn`: how far the fingers have twisted since they came down (degrees, clockwise); a pinch
    /// also turns the pane freely, any angle, once past `turnDeadZone`. `snapTurn`: a turn ending
    /// near a right angle lands on it (the Snap Rotation setting).
    @discardableResult
    func pinch(began: Bool, ended: Bool, isPinch: Bool, initial: WorkspacePoint, current: WorkspacePoint, scale: Double,
               turn: Double = 0, snapTurn: Bool = true) -> Bool {
        if began || zoomGesture == nil {
            let f = frames
            guard let id = f.hitTest(initial), let rect = f.tiles[id],
                  let tile = layout.tiles[id], tile.source != nil,
                  isPinch || tile.zoom != nil || effectiveFit(id) == .fill,
                  windowSize(tile) != nil else { zoomGesture = nil; zoomPreview = nil; return false }
            zoomGesture = (id, tile.zoom, rect, drawnSourceRect(tile, in: rect), tile.rotation, nil)
            zoomPreview = nil
            if active != id { focus(id, raise: false) }   // zooming is this device's view only
            requestBackdrop(id)
        }
        guard var g = zoomGesture, let tile = layout.tiles[g.tile], let source = windowSize(tile) else { return false }
        let pane = WorkspaceSize(width: g.rect.width * size.width, height: g.rect.height * size.height)
        func inPane(_ p: WorkspacePoint) -> WorkspacePoint {
            WorkspacePoint(x: (p.x - g.rect.x) / max(g.rect.width, 1e-6), y: (p.y - g.rect.y) / max(g.rect.height, 1e-6))
        }
        if isPinch, g.turnFrom == nil, turn.isFinite, abs(turn) >= Self.turnDeadZone {
            g.turnFrom = turn
            zoomGesture = g
        }
        let degrees = g.turnFrom.map { turn - $0 } ?? 0
        let view = WorkspaceZoom.turned(g.start, rotation: g.rotation, by: degrees, snap: snapTurn,
                                        tile: pane, source: source, fit: effectiveFit(g.tile),
                                        ratio: scale, from: inPane(initial), to: inPane(current))
        let next = saved.viewing(g.tile, rotation: view.rotation, zoom: view.zoom)
        if next != saved {
            saved = next
            publish(); scheduleThrottledSend()
        }
        if size.width > 0, size.height > 0, let now = next.tiles[g.tile] {
            let px = WorkspaceRect(x: g.rect.x * size.width, y: g.rect.y * size.height, width: pane.width, height: pane.height)
            let t0 = TileContentTransform(tile: px, source: source, rotation: g.rotation, fit: effectiveFit(g.tile), zoom: g.start ?? .identity)
            let t1 = TileContentTransform(tile: px, source: source, rotation: now.rotation, fit: effectiveFit(g.tile), zoom: now.zoom ?? .identity)
            zoomPreview = WorkspaceZoomPreview(tile: g.tile, pane: g.rect, start: t0, now: t1, canvas: size,
                                               sourceKey: tile.source?.windowID ?? 0)
        } else {
            zoomPreview = nil
        }
        if ended {
            zoomGesture = nil
            persist()
            // The final view goes now (its epoch is what the preview waits for), not on the next tick.
            sendNow()
            if view.zoom != nil || view.rotation != .none { requestBackdrop(g.tile, refresh: true) }   // fresh for the next gesture
        }
        return true
    }

    /// Where the pane draws its whole source (picture-normalized; larger than the pane when
    /// filled or zoomed in, smaller when zoomed out), as the Mac composes it.
    private func drawnSourceRect(_ tile: WorkspaceTile, in rect: WorkspaceRect) -> WorkspaceRect? {
        guard let w = windowSize(tile), size.width > 0, size.height > 0 else { return nil }
        let c = TileContentTransform(tile: WorkspaceRect(x: rect.x * size.width, y: rect.y * size.height,
                                                         width: rect.width * size.width, height: rect.height * size.height),
                                     source: w, rotation: tile.rotation, fit: tile.fit, zoom: tile.zoom ?? .identity).contentRect
        return WorkspaceRect(x: c.x / size.width, y: c.y / size.height, width: c.width / size.width, height: c.height / size.height)
    }

    private func windowSize(_ tile: WorkspaceTile) -> WorkspaceSize? {
        guard let source = tile.source, let w = windowItem(source), w.width > 0, w.height > 0 else { return nil }
        return WorkspaceSize(width: Double(w.width), height: Double(w.height))
    }

    /// Fit (default) or Fill, as drawn.
    func effectiveFit(_ id: String) -> WorkspaceFit {
        layout.tiles[id]?.fit == .fill ? .fill : .fit
    }

    /// Asks the Mac for the pane's whole source (bounded: once a second unless refreshing after a gesture).
    func requestBackdrop(_ id: String, refresh: Bool = false) {
        guard windowMode, let tile = layout.tiles[id], tile.source != nil else { return }
        let now = Date()
        if !refresh, let at = backdropAskedAt[id], now.timeIntervalSince(at) < 1 { return }
        backdropAskedAt[id] = now
        backdropReq = backdropReq >= 1_000_000 ? 1 : backdropReq + 1
        _ = send(WorkspaceRequests.backdrop(id, max: 1280, req: backdropReq))
    }

    /// The pane's whole-source still, when it is of the window the pane shows now.
    func backdrop(_ id: String) -> WorkspaceBackdrop? {
        guard let b = backdrops[id], b.windowID == layout.tiles[id]?.source?.windowID else { return nil }
        return b
    }

    /// Bumps a pane's view epoch when what the Mac must draw for it changed.
    private func noteViews(_ layout: WorkspaceLayout, frames: WorkspaceFrames) {
        for (id, tile) in layout.tiles {
            let r = frames.tiles[id]
            let z = tile.zoom ?? .identity
            let sig = "\(tile.source?.windowID ?? 0)|\(tile.fit.rawValue)|\(tile.rotation.rawValue)|\(z.scale)|\(z.centerX)|\(z.centerY)|\(r?.x ?? 0)|\(r?.y ?? 0)|\(r?.width ?? 0)|\(r?.height ?? 0)"
            if viewSignatures[id] != sig {
                viewSignatures[id] = sig
                viewEpochs[id] = nextViewEpoch
                nextViewEpoch = nextViewEpoch >= Int(Int32.max) ? 1 : nextViewEpoch + 1
            }
        }
        for id in Array(viewEpochs.keys) where layout.tiles[id] == nil { viewEpochs[id] = nil; viewSignatures[id] = nil }
    }

    func resetZoom(_ id: String) { edit { $0.zooming(id, to: nil) } }

    /// Two-finger double-tap: this pane back to 1x Fit, centred, no rotation. Other panes untouched.
    func resetView(_ id: String) {
        edit { l in
            guard var tile = l.tiles[id] else { return l }
            tile.zoom = nil; tile.rotation = .none; tile.fit = .fit
            var copy = l
            copy.tiles[id] = tile
            return copy
        }
    }

    /// Two-finger double-tap: the pane under the fingers back to its default view.
    func resetView(at p: WorkspacePoint) {
        guard let id = frames.hitTest(p), layout.tiles[id]?.source != nil else { return }
        resetView(id)
    }

    /// A pane whose capture failed (or stalled): ask the Mac to start it again now.
    func retryTile(_ id: String) { _ = send(WorkspaceRequests.retry(id)) }

    /// Turn Stage Manager off on the Mac while Window mode is used (confirmed here; control).
    func turnOffStageManager() {
        guard inputAllowed() else { return }
        _ = send(WorkspaceRequests.stageManager(on: false))
    }

    /// Mission Control is open on the Mac (Window mode).
    var missionControlOpen: Bool { remote?.missionControlOpen == true }

    /// Mission Control holds this pane's or float's picture: a window (never a display: Full
    /// Desktop keeps showing the Mac's screen, Mission Control and all) that the Mac reports
    /// paused, waiting or retrying while it is open. Only these show its notice.
    func missionControlPaused(_ id: String) -> Bool {
        guard missionControlOpen, let source = layout.tiles[id]?.source, !source.isDisplay,
              let status = tileState(id)?.status else { return false }
        return [.paused, .waiting, .retrying].contains(status)
    }

    /// A paused tile's notice: in full, or folded by its × to a small status that brings it back.
    enum MissionControlNotice: Equatable, Sendable { case full, folded }

    func missionControlNotice(_ id: String) -> MissionControlNotice? {
        guard missionControlPaused(id) else { return nil }
        return missionControlFolded.contains(id) ? .folded : .full
    }

    /// Notices folded by their ×, until Mission Control closes (see `remote`).
    @Published private(set) var missionControlFolded: Set<String> = []

    /// The notice's ×: folds it on this device only. Nothing is sent; Mission Control stays open.
    func foldMissionControlNotice(_ id: String) {
        if missionControlPaused(id) { missionControlFolded.insert(id) }
    }

    /// The folded status tapped: the notice again.
    func unfoldMissionControlNotice(_ id: String) { missionControlFolded.remove(id) }

    /// Where a float's notice goes (screen points): centred on the float's visible part, about the
    /// notice's size (compact; folded, just the status). nil when a float in front covers that spot:
    /// it hides the notice as it hides the window.
    nonisolated static func missionControlNoticeSpot(on float: CGRect, folded: Bool, within bounds: CGRect,
                                                     inFront: [CGRect]) -> CGRect? {
        let seen = float.intersection(bounds)
        let visible = seen.isNull || seen.isEmpty ? float : seen
        let size = folded ? CGSize(width: min(float.width, 190), height: 30)
                          : CGSize(width: max(min(float.width - 12, 300), 140), height: 96)
        let spot = CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
        return inFront.contains { $0.intersects(spot) } ? nil : spot
    }

    /// Exit Mission Control on the Mac (needs the Mac's grant; the Mac re-checks before Escape).
    func exitMissionControl() {
        guard canControlMac, missionControlOpen else { return }
        _ = send(WorkspaceRequests.exitMissionControl)
    }

    /// What a paused tile's notice (and its pane's menu and accessibility action) offers while
    /// Mission Control is open on the Mac (nil when it isn't).
    enum MissionControlAction: Equatable, Sendable {
        /// This device has control: Exit Mission Control (the Mac re-checks before it presses Escape).
        case exit
        /// No control yet: the normal Request Control flow, then Exit.
        case requestControl
        /// Asked; the Mac's owner hasn't answered.
        case awaitingApproval
        /// The Mac takes no control requests from this device: say how to close it there.
        case closeOnMac
    }

    var missionControlAction: MissionControlAction? {
        guard missionControlOpen else { return nil }
        if canControlMac { return .exit }
        switch controlState() {
        case .requesting: return .awaitingApproval
        case .requestsDisabled: return .closeOnMac
        case .off, .notAllowed, .allowed: return .requestControl
        }
    }

    /// The notice's button: Exit with control, else ask for control (never a blind Escape).
    func performMissionControlAction() {
        switch missionControlAction {
        case .exit?: exitMissionControl()
        case .requestControl?: requestControl()
        case .awaitingApproval?, .closeOnMac?, nil: break
        }
    }

    /// Turn Stage Manager on on the Mac (Settings; control).
    func turnOnStageManager() {
        guard inputAllowed() else { return }
        _ = send(WorkspaceRequests.stageManager(on: true))
    }

    /// Stage Manager on the Mac as Settings shows it: on, off, or nil when the Mac doesn't say
    /// (not in Window mode, or an older Mac).
    var stageManagerIsOn: Bool? {
        guard let r = remote else { return nil }
        return r.stageManagerOn ?? (r.stageManager ? true : nil)
    }

    /// Whether this device may switch Stage Manager now (it has control).
    /// The Mac's confirmed decision on control for this session (Request Control). `inputAllowed`
    /// only says the session is live: in View Only it's true too, and the Mac drops actions such
    /// as Stage Manager on/off (found 2026-10-30 21:3x: the button looked enabled and did nothing).
    /// Receivers without Request Control keep `.allowed`.
    var controlState: () -> SessionInputWireState = { .allowed }
    /// Asks the Mac for control: the same request as Settings ▸ Input.
    var requestControl: () -> Void = {}
    var canControlMac: Bool { inputAllowed() && controlState() == .allowed }

    /// A window macOS keeps paused (Stage Manager's strip): bring it forward on the Mac (control).
    /// Add to Current Stage: Stage Manager's own action on the strip item holding this pane's
    /// window (needs control; the Mac answers in its state).
    func addToStage(_ id: String) {
        guard let source = layout.tiles[id]?.source, !source.isDisplay, let gen = generation(source) else { return }
        _ = send(["type": WireMessage.windowAction, "action": "addToStage", "window": Int(source.windowID), "gen": Int(gen)])
    }

    /// What the Mac said about the last Add to Current Stage for this pane's window, if it failed.
    func stageAddProblem(_ id: String) -> String? {
        guard let source = layout.tiles[id]?.source, let add = remote?.stageAdd, add.window == source.windowID else { return nil }
        switch add.result {
        case "added": return nil
        case "accessibility": return String(localized: "The Mac can't do that: turn on MeowDisplay in System Settings ▸ Privacy & Security ▸ Accessibility on the Mac.")
        case "notInStrip": return String(localized: "That window isn't in Stage Manager's side strip any more.")
        case "ambiguous": return String(localized: "Stage Manager lists that window twice; add it on the Mac.")
        default: return String(localized: "macOS didn't add it to the stage. Try again, or add it on the Mac.")
        }
    }

    func showOnMac(_ id: String) {
        guard let source = layout.tiles[id]?.source, !source.isDisplay, let gen = generation(source) else { return }
        _ = send(WorkspaceRequests.activateWindow(source.windowID, generation: gen))
    }

    /// The first touch in a tile selects it, so typing and zoom go there (also in View Only).
    /// True when the touch chose another pane (selection only; nothing goes to the Mac).
    /// A float touched in its content comes to the front first (sent at once, so the Mac hits
    /// the same window), and that same touch goes on to it, as a click on a pane does.
    @discardableResult
    func selectTile(at p: WorkspacePoint) -> Bool {
        guard let id = frames.hitTest(p), layout.tiles[id]?.source != nil else { return false }
        if layout.isFloat(id) { raiseFloat(id) }
        guard active != id else { return false }
        focus(id)
        return true
    }

    /// The selected pane's frame (0–1 of the picture), for prompts shown inside it.
    var activePaneRect: WorkspaceRect? { active.flatMap { frames.tiles[$0] } }

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
        if holdForLeavingExtend({ [weak self] in self?.drop(w, on: target) }) { return }
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
            if l.paneCount < capacity { return (l.insertingSplit(WorkspaceTile(id: id, source: source), at: index, edge: edge), id) }
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

    /// The desktop the picture shows outside Window view: in Mirror, the Mac's manual Mirror
    /// choice when exactly one listed display matches it; otherwise the main display.
    var desktopDisplay: CatalogDisplayItem? {
        if mirroring(), let d = Self.mirroredDisplay(in: catalog?.displays ?? [], choice: mirrorChoice()) { return d }
        return mainDisplay
    }

    /// The listed display a manual Mirror choice names (the two lists share names and point
    /// sizes, not ids). Nil for Automatic, or when no single display matches.
    nonisolated static func mirroredDisplay(in displays: [CatalogDisplayItem], choice: MirrorDisplayEntry?) -> CatalogDisplayItem? {
        guard let choice else { return nil }
        let matches = displays.filter { $0.name == choice.name && $0.width == choice.logicalWidth && $0.height == choice.logicalHeight }
        if matches.count == 1 { return matches[0] }
        let main = matches.filter { $0.isMain == choice.isMain }
        return main.count == 1 ? main[0] : nil
    }

    /// Mirror/Extend: the picture is one pane showing the desktop, so a window dragged onto it
    /// replaces it, joins it as a tab, or splits it (Window mode then starts with both).
    private func desktopLayout() -> WorkspaceLayout? {
        guard let host, let d = desktopDisplay else { return nil }
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
                if tab != nil, let s = windows.first, l.paneCount < capacity {
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

    /// Where a dragged window or label would land (normalized picture point). Over a floating
    /// pane: that float (replace it, or swap with a dragged pane); a float being docked never
    /// lands on a float. Splits count the tree's panes only.
    func windowDrop(at p: WorkspacePoint, labelHeight: Double) -> WorkspaceWindowDrop? {
        let f = frames
        if let hit = f.hitTest(p), f.isFloat(hit) {
            if case .float? = drag?.item { return nil }
            if case .pane(let id, _)? = drag?.item, id == hit { return nil }
            return f.tiles[hit].map { .replace(tile: hit, preview: $0) }
        }
        let drop = WorkspaceGeometry.windowDrop(at: p, layout: layout, frames: f, size: size, labelHeight: labelHeight,
                                                canSplit: layout.paneCount < capacity)
        // Docking never replaces a window: the middle of a pane adds it as a tab there.
        if case .float? = drag?.item, case .replace(let t, let r)? = drop { return .tab(tile: t, preview: r) }
        return drop
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
            return l.replacingTree(with: ordered.count > preset.slotCount ? l.applying(preset).layout : WorkspaceLayout(preset: preset, tiles: ordered))
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

    /// Settings ▸ Controls, off by default: choosing a window that sits in Stage Manager's side
    /// strip also brings it forward on the Mac (it changes the Mac's stage), so it streams live.
    /// Needs control; the Mac refuses it otherwise.
    static let bringStripWindowsForwardKey = "workspace.bringStripWindowsForward"
    var bringStripWindowsForward: Bool {
        get { UserDefaults.standard.bool(forKey: Self.bringStripWindowsForwardKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.bringStripWindowsForwardKey); objectWillChange.send() }
    }

    func choose(_ w: CatalogWindowItem, asNewTile: Bool) {
        guard let host, let source = source(for: w) else { return }
        if holdForLeavingExtend({ [weak self] in self?.choose(w, asNewTile: asNewTile) }) { return }
        if w.inStageStrip, bringStripWindowsForward, inputAllowed() {
            _ = send(WorkspaceRequests.activateWindow(w.id, generation: w.generation))   // the person chose it, and opted in
        }
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
            if l.paneCount < capacity, l.tiles.count < WorkspaceLayout.maximumTiles {
                let tile = WorkspaceTile(id: "w\(nextTile)", source: source)
                nextTile += 1
                if l.paneCount == 0 { return l.replacingTree(with: WorkspaceLayout(preset: .single, tiles: [tile])) }
                let added = l.adding(tile, landscape: landscape)
                return added.replacingTree(with: WorkspaceLayout(preset: .natural(for: added.paneCount, landscape: landscape),
                                                         tiles: added.orderedTileIDs.compactMap { added.tiles[$0] }))
            }
            return l.orderedTileIDs.last.map { l.replacingSource(of: $0, with: source) } ?? l
        }
    }

    // MARK: Close Window (Stage Peek)

    /// Closes one Mac window as its close button would: never Quit, never the app's other windows.
    /// View Only can't: the Mac refuses without control, and this says so before asking.
    func closeWindow(_ w: CatalogWindowItem) {
        let name = w.title.isEmpty ? w.app : w.title
        guard canCloseWindows else { closeNotice = WindowCloseNotice(windowID: w.id, name: name, result: nil, unsupported: true); return }
        guard inputAllowed() else { closeNotice = WindowCloseNotice(windowID: w.id, name: name, result: .control); return }
        guard !closingWindows.contains(w.id) else { return }
        closeRequest += 1
        closingWindows.insert(w.id)
        closeNotice = nil
        closeNames[w.id] = name
        _ = send(WorkspaceRequests.windowClose(w.id, generation: w.generation, req: closeRequest))
        let id = w.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.closingWindows.contains(id) else { return }
            self.closingWindows.remove(id)
            self.closeNotice = WindowCloseNotice(windowID: id, name: self.closeNames.removeValue(forKey: id) ?? name, result: nil)
        }
    }

    private var closeNames: [UInt32: String] = [:]

    /// Lock This Mac: the Mac shows macOS's lock screen (needs control; the Mac says what happened).
    func lockMac() {
        guard canLockMac, lockMacStatus != .locking else { return }
        lockRequest += 1
        let req = lockRequest
        guard send(["type": LockMacWire.request, "req": req]) else { lockMacStatus = .done(.failed); return }
        lockMacStatus = .locking
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.lockRequest == req, self.lockMacStatus == .locking else { return }
            self.lockMacStatus = .done(.failed)
        }
    }

    func clearLockMacStatus() { if lockMacStatus != .locking { lockMacStatus = nil } }

    private func finishClose(_ id: UInt32, result: WindowCloseResult) {
        closingWindows.remove(id)
        let name = closeNames.removeValue(forKey: id) ?? catalog?.windows.first { $0.id == id }.map { $0.title.isEmpty ? $0.app : $0.title } ?? ""
        if result.removesCard, var c = catalog {
            c.windows.removeAll { $0.id == id }
            catalog = c
        }
        closeNotice = WindowCloseNotice(windowID: id, name: name, result: result)
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
        focus(tile, raise: false)   // fullscreen on this device only: nothing changes on the Mac
    }

    func exitLocalFullscreen() {
        guard localFullscreen != nil else { return }
        localFullscreen = nil
        publish(); scheduleSend(immediately: true)
    }

    /// A double tap on a pane's label: that pane fills this device, or (already) the layout comes back.
    /// Presentation only, like the menu's Fullscreen on This Device: the saved arrangement is untouched.
    func toggleLocalFullscreen(_ tile: String) {
        localFullscreen == tile ? exitLocalFullscreen() : enterLocalFullscreen(tile)
    }

    // MARK: Dragging windows and labels onto panes

    func beginDrag(_ item: WorkspaceDrag.Item, at global: CGPoint, placement: WorkspacePlacement? = nil) {
        var d = WorkspaceDrag(item: item, location: global)
        d.placement = placement ?? initialPlacement(for: item)
        if d.placement == .float, !canPlace(item, .float) { d.placement = .pane }
        drag = d
        shake.reset()
        if canPlace(item, .float), !defaults.bool(forKey: Self.shakeTipKey) {
            defaults.set(true, forKey: Self.shakeTipKey)   // never repeated, even if dismissed unseen
            shakeTipVisible = true
        }
    }

    static let shakeTipKey = "workspace.shakeTipShown"
    func dismissShakeTip() { shakeTipVisible = false }

    /// The Float zone is offered while dragging in Pane placement something that can float, in Window view.
    var canDropToFloat: Bool {
        guard windowMode, let d = drag, d.placement == .pane else { return false }
        if case .float = d.item { return false }
        return canPlace(d.item, .float)
    }

    func overFloatZone(_ p: CGPoint) -> Bool {
        canDropToFloat && floatZoneGlobal.width > 0 && floatZoneGlobal.insetBy(dx: -8, dy: -8).contains(p)
    }

    /// Moves the drag; a shake while holding switches its placement (true when it switched).
    @discardableResult
    func moveDrag(to global: CGPoint, at time: TimeInterval = CACurrentMediaTime()) -> Bool {
        guard drag != nil else { return false }
        drag?.location = global
        guard shake.add(x: Double(global.x), y: Double(global.y), at: time) else { return false }
        return toggleDragPlacement()
    }
    func cancelDrag() { drag = nil }

    /// The drop under the finger, in picture terms. Nil outside the picture and over the Cancel zone.
    /// In Mirror/Extend the desktop counts as one pane (a window can land beside it).
    func dropTarget(forGlobal p: CGPoint, labelHeight: CGFloat = 30) -> WorkspaceWindowDrop? {
        if overCancelZone(p) || overRemoveZone(p) || overFloatZone(p) { return nil }
        if drag?.placement == .float { return nil }   // Floating placement: no pane targets
        if !windowMode {
            switch drag?.item { case .window?, .app?: break; default: return nil }
            guard desktopPictureGlobal.width > 0, desktopPictureGlobal.contains(p) else { return nil }
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

    /// Remove from Layout is offered only while repositioning a whole pane that is already in the
    /// layout (its label, not one of its tabs), with another pane left: never for a window or app
    /// from Stage Peek, a new pane or a tab. It removes the pane here only; the Mac window is untouched.
    var canDropToRemove: Bool {
        guard windowMode, case .pane(let id, nil)? = drag?.item else { return false }
        return canRemoveFromLayout(id)
    }

    /// Whether a pane may come off this device's layout (its menu and the drop
    /// zone agree). Never the last one: that would leave an empty canvas, and
    /// the pane's menu offers Change Window… instead (#120).
    func canRemoveFromLayout(_ tile: String) -> Bool {
        arranged.tiles[tile] != nil && (arranged.isFloat(tile) || arranged.paneCount > 1)
    }

    /// Cancel wins where the two zones' touch margins meet (they sit 12 pt
    /// apart with 8 pt of slop each), so the highlight, the haptic and the
    /// drop always agree, and the uncertain case removes nothing.
    func overRemoveZone(_ p: CGPoint) -> Bool {
        canDropToRemove && removeZoneGlobal.width > 0 && removeZoneGlobal.insetBy(dx: -8, dy: -8).contains(p)
            && !overCancelZone(p)
    }

    /// Ends a drag: drops onto the pane under the finger. Dropped on Cancel or outside the
    /// picture: nothing changes. Returns whether anything changed.
    @discardableResult
    func endDrag() -> Bool {
        guard let d = drag else { return false }
        if d.placement == .float {
            drag = nil
            return dropFloating(d)
        }
        if overFloatZone(d.location), canPlace(d.item, .float) {
            drag = nil
            return floatItem(d.item, at: nil)
        }
        let target = dropTarget(forGlobal: d.location)
        let remove = overRemoveZone(d.location)
        drag = nil
        if remove, case .pane(let id, nil) = d.item {
            removeTile(id)   // one undo step; never a request to close the window on the Mac
            return true
        }
        guard let target else { return false }
        switch d.item {
        case .window(let w):
            return place(w, on: target)
        case .pane(let id, let tab):
            if let tab, case .tab(let t, _) = target, t == id { return reorderTab(id, from: tab, at: d.location) }
            dropTile(id, tab: tab, on: target)
            return true
        case .app(let app):
            let windows = (catalog?.windows ?? []).filter { $0.bundleID == app.bundleID }
            if windows.count == 1 { return place(windows[0], on: target) }
            // Several: which one. None: offer to open it, then place its first window there.
            appDrop = AppDrop(app: app, windows: windows, target: target)
            return windows.isEmpty ? false : true
        case .float(let id):
            dockFloat(id, to: target)
            return true
        }
    }

    /// A tab dropped back on its own pane's labels: it goes between the labels either side.
    private func reorderTab(_ id: String, from: Int, at p: CGPoint) -> Bool {
        guard let frames = tabLabelFrames[id], let count = layout.tiles[id]?.tabs.count, count > 1 else { return false }
        let mids: [Double] = (0..<count).compactMap { i in frames[i].map { Double($0.midX) } }
        guard mids.count == count else { return false }
        let to = WorkspaceTabOrder.index(from: from, dropX: Double(p.x), labelMidXs: mids)
        guard to != from else { return false }
        edit { $0.movingTab(of: id, from: from, to: to) }
        return true
    }

    /// An app dropped on a pane, waiting for the person: pick one of its windows, or open it.
    struct AppDrop: Identifiable, Equatable {
        let id = UUID()
        var app: MacAppItem
        var windows: [CatalogWindowItem]
        var target: WorkspaceWindowDrop
        /// Dropped in Floating placement: the window floats here instead (picture-normalized).
        var floatAt: WorkspacePoint? = nil
    }
    @Published var appDrop: AppDrop?
    /// Opened from a drop: its first new window goes where it was dropped (for up to 20 s).
    private var pendingAppPlacement: (bundle: String, target: WorkspaceWindowDrop, known: Set<UInt32>, until: Date)?

    /// The window picked for an app drop.
    func completeAppDrop(_ d: AppDrop, with w: CatalogWindowItem) {
        appDrop = nil
        if let at = d.floatAt { openFloating(w, at: at); return }
        _ = place(w, on: d.target)
    }

    /// Open the dropped app on the Mac (explicit; needs control), then place its first window.
    func launchForAppDrop(_ d: AppDrop) {
        appDrop = nil
        guard inputAllowed() else { return }
        pendingAppPlacement = (d.app.bundleID, d.target, Set((catalog?.windows ?? []).filter { $0.bundleID == d.app.bundleID }.map(\.id)),
                               Date().addingTimeInterval(20))
        launch(d.app.bundleID)
    }

    func cancelAppDrop() { appDrop = nil }

    private func placePendingAppWindow() {
        guard let p = pendingAppPlacement else { return }
        if Date() > p.until { pendingAppPlacement = nil; return }
        guard let w = catalog?.windows.first(where: { $0.bundleID == p.bundle && !p.known.contains($0.id) }) else { return }
        pendingAppPlacement = nil
        _ = place(w, on: p.target)
    }

    /// A window dropped on a pane (or, outside Window mode, beside the desktop).
    private func place(_ w: CatalogWindowItem, on target: WorkspaceWindowDrop) -> Bool {
        if !windowMode {
            // From Extend, only once the person confirms (it removes the extended display).
            if holdForLeavingExtend({ [weak self] in _ = self?.place(w, on: target) }) { return false }
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
    }

    func minimizeRemoteWindow(_ tile: String) {
        guard inputAllowed(), let source = layout.tiles[tile]?.source, let gen = generation(source) else { return }
        _ = send(WorkspaceRequests.minimizeWindow(source.windowID, generation: gen))
    }
    /// Makes `tile` the one typing goes to. `raise` false for anything that only arranges this
    /// device's view (moving, resizing, tucking, docking or zooming a window, fullscreen on this
    /// device): the Mac window then stays where it is, and comes forward only when a key or a
    /// press for it needs it to (never typing into another window meanwhile).
    func focus(_ tile: String, raise: Bool = true) {
        if layout.tiles[tile] != nil, !layout.isFloat(tile) { lastFocusedPane = tile }
        requestedFocus = tile
        _ = send(WorkspaceRequests.focus(tile, raise: raise))
    }

    /// The tree's pane focused last: where typing goes back to when a focused float is tucked or removed.
    private var lastFocusedPane: String?
    /// The pane this device asked to focus, until the Mac's state says so: the next layout request
    /// carries it, so a request in flight never puts the old focus back.
    private var requestedFocus: String?
    /// The floating pane being moved or resized by a finger now (its chrome draws the local preview).
    @Published private(set) var floatGesture: String?
    /// The layout before the current float gesture, recorded as one undo step once it changes something.
    private var floatGestureStart: WorkspaceLayout?
    /// Shake while dragging (pane label, Stage Peek window, float title).
    var shake = WorkspaceShakeDetector()

    /// The hardware pointer at a normalized canvas point: hover only, never focus.
    func hover(at p: CGPoint?) {
        let id = p.flatMap { p in frames.hitTest(WorkspacePoint(x: p.x, y: p.y)) }
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
        if windowMode, let host, let holder = layout.tile(holding: host, windowID: w.id), layout.isFloat(holder) {
            untuckFloat(holder)   // a float already shows it: bring that one back, never a second copy
            return
        }
        // Default Window Placement applies to windows not in the layout yet (in Mirror, any window:
        // it floats over the mirrored desktop).
        if canOpenFloats, defaultPlacement == .float, !WorkspaceSource.isDisplayKey(w.id),
           let host, !windowMode || layout.tile(holding: host, windowID: w.id) == nil {
            openFloating(w)
            return
        }
        replacingTile = switchTarget
        choose(w, asNewTile: false)
    }

    /// Whether another tile can be added (Stage Peek's "Add as Tile").
    var canAddTile: Bool { layout.paneCount < capacity && layout.tiles.count < WorkspaceLayout.maximumTiles }

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
        let sendFrames = WorkspaceGeometry.frames(for: sendable, in: size, hinge: hinge)
        noteViews(sendable, frames: sendFrames)
        let focusNow = requestedFocus.flatMap { sendFrames.tiles[$0] != nil ? $0 : nil } ?? active
        _ = send(WorkspaceRequests.workspace(sendable, frames: sendFrames,
                                             host: host, focus: focusNow, generation: generation,
                                             displayID: { [weak self] in self?.display(for: $0)?.id },
                                             viewEpoch: { [weak self] in self?.viewEpochs[$0] },
                                             floats: canFloat))
    }

    private func persist() {
        guard let host, let data = WorkspaceLayoutRecord(saved).encoded() else { return }
        defaults.set(data, forKey: "workspace.layout.\(host)")
    }
}

// MARK: - Floating panes (receiver-local; WorkspaceFloats.swift)
//
// Every action here changes only this device's workspace and the rectangles it asks the Mac
// to composite. None of them sends pointer input, `windowAction` or `windowClose`: the Mac
// window is never moved, resized, minimized, closed or activated by floating, moving,
// resizing, flinging, tucking, docking or local fullscreen.

extension WorkspaceModel {
    /// Settings ▸ Window View: where windows newly brought in (mostly from Stage Peek) land.
    /// Existing windows are never rearranged by it.
    static let defaultPlacementKey = "workspace.defaultPlacement"
    var defaultPlacement: WorkspacePlacement {
        get { defaults.string(forKey: Self.defaultPlacementKey).flatMap(WorkspacePlacement.init(rawValue:)) ?? .pane }
        set { defaults.set(newValue.rawValue, forKey: Self.defaultPlacementKey); objectWillChange.send() }
    }

    /// Floating panes can be shown now (the Mac draws them).
    var canFloatPanes: Bool { canFloat }

    /// The pane's window can float: the Mac draws floats, and the tree keeps at least one pane
    /// (a tab of a pane always can, its pane stays).
    func canFloat(pane id: String, tab: Int? = nil) -> Bool {
        guard canFloat, layout.tiles[id] != nil, !layout.isFloat(id), layout.tiles.count < WorkspaceLayout.maximumTiles || tab == nil else { return false }
        if let tab { return layout.tiles[id]?.tabs.indices.contains(tab) == true }
        return layout.tiles[id]?.source != nil && (layout.paneCount > 1 || (layout.tiles[id]?.tabs.count ?? 0) > 1)
    }

    /// The window's width / height as the pane draws it (turned a quarter: swapped).
    func windowAspect(_ id: String) -> Double? {
        guard let tile = layout.tiles[id], let s = tile.source, let w = windowItem(s), w.width > 0, w.height > 0 else { return nil }
        let a = Double(w.width) / Double(w.height)
        return tile.rotation.isQuarterTurn ? 1 / a : a
    }

    private func newFloatFrame(aspect: Double?, at center: WorkspacePoint?, in space: WorkspaceSize? = nil) -> WorkspaceRect {
        WorkspaceFloatGeometry.defaultFrame(aspect: aspect, in: space ?? size, index: center == nil ? layout.visibleFloatIDs.count : 0, center: center)
    }

    /// A window can open floating from here: in Window view, or over the mirrored desktop (Window
    /// view then starts with that desktop as the pane underneath, as when a window is dropped
    /// onto it; the person isn't asked). Never from Extend: leaving Extend removes this device's
    /// extended display, and macOS moves the windows on it, which a float must never cause.
    var canOpenFloats: Bool { canFloat && (windowMode || (mirroring() && desktopDisplay != nil)) }

    // MARK: Opening, floating, docking

    /// Open as Floating Window (Stage Peek): a window already in the workspace floats from where
    /// it is (a float comes back to the front); a new one opens floating. In Mirror the mirrored
    /// desktop becomes the pane underneath and Window mode starts with both, without asking. Never
    /// from Extend (see `canOpenFloats`).
    func openFloating(_ w: CatalogWindowItem, at center: WorkspacePoint? = nil) {
        guard canOpenFloats, let host, let source = source(for: w) else { return }
        let aspect = w.width > 0 && w.height > 0 ? Double(w.width) / Double(w.height) : nil
        if !windowMode {
            guard let desk = desktopLayout() else { return }
            nextTile += 1   // the desktop pane's id
            let id = "w\(nextTile)"; nextTile += 1
            history.record(saved)
            // Sized in the picture shown now: Window view's own space isn't measured yet.
            let shown = desktopPictureGlobal.width > 0 && desktopPictureGlobal.height > 0
                ? WorkspaceSize(width: desktopPictureGlobal.width, height: desktopPictureGlobal.height) : nil
            saved = desk.addingFloat(WorkspaceTile(id: id, source: source), frame: newFloatFrame(aspect: aspect, at: center, in: shown)).compacted()
            localFullscreen = nil
            refreshMissing(); persist(); publish()
            requestWindowMode()
            focus(id, raise: false)
            return
        }
        if let holder = layout.tile(holding: host, windowID: w.id) {
            if layout.isFloat(holder) {
                untuckFloat(holder)
                return
            }
            let tab = layout.tiles[holder]?.tabs.firstIndex { $0.windowID == w.id }
            if canFloat(pane: holder, tab: tab.flatMap { (layout.tiles[holder]?.tabs.count ?? 0) > 1 ? $0 : nil }) {
                floatPane(holder, tab: tab.flatMap { (layout.tiles[holder]?.tabs.count ?? 0) > 1 ? $0 : nil }, at: center)
            } else {
                focus(holder, raise: false)   // the only pane: it stays a pane
            }
            return
        }
        guard layout.tiles.count < WorkspaceLayout.maximumTiles else { return }
        let id = "w\(nextTile)"; nextTile += 1
        let frame = newFloatFrame(aspect: aspect, at: center)
        edit { $0.addingFloat(WorkspaceTile(id: id, source: source), frame: frame) }
        if compactSpace { tuckOthers(than: id) }
        focus(id, raise: false)
    }

    /// Float This Pane / Float This Tab, or a pane title dropped in Floating placement. The
    /// pane's window keeps its tile (and its capture); the layout closes up around it.
    func floatPane(_ id: String, tab: Int? = nil, at center: WorkspacePoint? = nil) {
        guard canFloat(pane: id, tab: tab), let tile = layout.tiles[id] else { return }
        let aspect: Double? = {
            guard let tab, tile.tabs.indices.contains(tab), let w = windowItem(tile.tabs[tab]), w.width > 0, w.height > 0 else { return windowAspect(id) }
            return Double(w.width) / Double(w.height)
        }()
        let frame = newFloatFrame(aspect: aspect, at: center)
        var floated = id
        if let tab, tile.tabs.count > 1 {
            let newID = "w\(nextTile)"; nextTile += 1
            if tile.tabs[tab] != tile.source { floated = newID }
            edit { $0.floatingTab(of: id, at: tab, frame: frame, newID: newID) }
        } else {
            if localFullscreen == id { localFullscreen = nil }
            edit { $0.floatingPane(id, frame: frame) }
        }
        if compactSpace { tuckOthers(than: floated) }
        focus(floated, raise: false)
    }

    /// A float docked where it was dropped in Pane placement: a tab, a new pane beside one, or an
    /// empty slot. Never replaces or drops another window.
    func dockFloat(_ id: String, to target: WorkspaceWindowDrop) {
        guard layout.isFloat(id) else { return }
        var drop = target
        if case .split(let index, _, _) = target, layout.paneCount >= capacity,
           let holder = WorkspaceLayout.slotID(layout.root, at: index).flatMap({ $0 }) {
            drop = .tab(tile: holder, preview: target.preview)   // no room for another pane: a tab of that one
        }
        if localFullscreen == id { localFullscreen = nil }
        edit { $0.docking(id, to: drop) }
        focus(id, raise: false)
    }

    /// Add to Layout: a new pane when there's room, else a tab of the focused (or last) pane.
    func addFloatToLayout(_ id: String) {
        guard layout.isFloat(id) else { return }
        if localFullscreen == id { localFullscreen = nil }
        if layout.paneCount < capacity {
            let landscape = size.width >= size.height
            edit { $0.dockingAsPane(id, landscape: landscape) }
        } else if let target = lastFocusedPane.flatMap({ layout.orderedTileIDs.contains($0) ? $0 : nil }) ?? layout.orderedTileIDs.last {
            edit { $0.dockingAsTab(id, into: target) }
        }
        focus(id, raise: false)
    }

    // MARK: Moving and resizing (one undo step per gesture)

    /// A finger took the float's title, grabber or resize grip: it comes to the front.
    func beginFloatGesture(_ id: String) {
        guard layout.isFloat(id) else { return }
        floatGesture = id
        floatGestureStart = saved
        raiseFloat(id)
        if active != id { focus(id, raise: false) }   // arranging only: the Mac window stays put
        requestBackdrop(id)
    }

    /// The float's frame while the finger moves (kept usable; the Mac follows at most ~30 times a second).
    func updateFloatFrame(_ id: String, _ frame: WorkspaceRect) {
        let next = saved.settingFloatFrame(id, WorkspaceFloatGeometry.clamped(frame, in: size))
        guard next != saved else { return }
        if let start = floatGestureStart { history.record(start); floatGestureStart = nil }
        saved = next
        publish(); scheduleThrottledSend()
    }

    /// The gesture ended (the float settled where `frame` says, if given).
    func endFloatGesture(_ id: String, frame: WorkspaceRect? = nil) {
        if let frame { updateFloatFrame(id, frame) }
        floatGesture = nil
        floatGestureStart = nil
        persist(); publish(); sendNow()
    }

    /// In front of the other floats. Presentation only (not an undo step); sent at once so the
    /// Mac hits the same window the finger sees.
    func raiseFloat(_ id: String) {
        let next = saved.raisingFloat(id)
        guard next != saved else { return }
        saved = next
        persist(); publish(); sendNow()
    }

    /// Size presets and accessibility Make Larger / Smaller: about its centre, keeping its shape.
    func scaleFloat(_ id: String, by factor: Double) {
        guard let f = layout.float(id) else { return }
        edit { $0.settingFloatFrame(id, WorkspaceFloatGeometry.scaled(f.frame, by: factor, in: size)) }
    }

    /// Small / Medium / Large: a share of the picture's width at the window's shape.
    func sizeFloat(_ id: String, widthShare: Double) {
        guard let f = layout.float(id), size.width > 0 else { return }
        let aspect = windowAspect(id) ?? (f.frame.width * size.width) / max(f.frame.height * size.height, 1)
        let w = size.width * widthShare, h = w / aspect
        let r = WorkspaceRect(x: f.frame.midX - w / size.width / 2, y: f.frame.midY - h / size.height / 2,
                              width: w / size.width, height: h / size.height)
        edit { $0.settingFloatFrame(id, WorkspaceFloatGeometry.clamped(r, in: size)) }
    }

    /// Accessibility Move Left / Right / Up / Down: a tenth of the picture per step.
    func nudgeFloat(_ id: String, dx: Double, dy: Double) {
        guard let f = layout.float(id) else { return }
        var r = f.frame
        r.x += dx; r.y += dy
        edit { $0.settingFloatFrame(id, WorkspaceFloatGeometry.clamped(r, in: size)) }
    }

    // MARK: Tucking

    /// Hidden at an edge. Its capture stops while hidden; the Mac window is untouched.
    func tuckFloat(_ id: String, edge: WorkspaceEdge, offset: Double) {
        guard layout.isFloat(id) else { return }
        edit { $0.tuckingFloat(id, edge: edge, offset: offset) }
        refocus(after: id)
    }

    /// Back where it was, in front and focused. On a compact screen the float shown before
    /// tucks in its place (one shows at a time there).
    func untuckFloat(_ id: String) {
        guard layout.isFloat(id) || saved.isFloat(id) else { return }
        edit { $0.untuckingFloat(id) }
        if compactSpace { tuckOthers(than: id) }
        focus(id, raise: false)
    }

    /// A tab dragged along its edge (no undo step; tucked floats aren't sent).
    func moveTuckTab(_ id: String, offset: Double) {
        guard let i = saved.floats.firstIndex(where: { $0.tile == id }), saved.floats[i].tuck != nil else { return }
        saved.floats[i].tuck?.offset = min(max(offset.isFinite ? offset : 0.5, 0), 1)
        persist(); publish()
    }

    /// Removes a float from this device (Undo brings it back). The Mac window stays open.
    func removeFloat(_ id: String) {
        guard layout.isFloat(id) else { return }
        if localFullscreen == id { localFullscreen = nil }
        edit { $0.removing(id) }
        refocus(after: id)
    }

    private var compactSpace: Bool { WorkspaceFloatGeometry.visibleLimit(for: size) <= 1 }

    private func tuckOthers(than id: String) {
        let others = saved.visibleFloatIDs.filter { $0 != id }
        guard !others.isEmpty else { return }
        var next = saved
        for (i, o) in others.enumerated() { next = next.tuckingFloat(o, edge: .right, offset: min(0.3 + Double(i) * 0.12, 0.85)) }
        saved = next
        persist(); publish(); scheduleSend()
    }

    /// The focused float went away (tucked, removed): typing goes to the frontmost shown float,
    /// else the pane focused before it. Nothing is sent to the Mac but the focus.
    private func refocus(after id: String) {
        guard active == id || requestedFocus == id else { return }
        let next = layout.visibleFloatIDs.last { $0 != id }
            ?? lastFocusedPane.flatMap { layout.orderedTileIDs.contains($0) ? $0 : nil }
            ?? layout.orderedTileIDs.first
        if let next { focus(next, raise: false) }
    }

    // MARK: Drag placement (Pane | Floating)

    private func initialPlacement(for item: WorkspaceDrag.Item) -> WorkspacePlacement {
        switch item {
        case .window, .app: return defaultPlacement
        case .pane: return .pane
        case .float: return .pane
        }
    }

    /// Whether `item` may land with `placement`.
    func canPlace(_ item: WorkspaceDrag.Item, _ placement: WorkspacePlacement) -> Bool {
        guard placement == .float else { return true }
        guard canOpenFloats else { return false }   // never from Extend
        switch item {
        case .window(let w): return !WorkspaceSource.isDisplayKey(w.id)
        case .app: return true
        case .pane(let id, let tab): return canFloat(pane: id, tab: tab)
        case .float: return false
        }
    }

    /// Switches the drag between Pane and Floating placement (a shake, or the drag's control).
    /// True when it switched.
    @discardableResult
    func toggleDragPlacement() -> Bool {
        guard let d = drag else { return false }
        let next: WorkspacePlacement = d.placement == .pane ? .float : .pane
        guard canPlace(d.item, next) else { return false }
        drag?.placement = next
        return true
    }

    /// Where a Floating-placement drop would put the window (picture-normalized), for its preview.
    func floatDropPreview(forGlobal p: CGPoint) -> WorkspaceRect? {
        drag.flatMap { floatDropFrame($0, at: p) }
    }

    private func floatDropFrame(_ d: WorkspaceDrag, at p: CGPoint) -> WorkspaceRect? {
        guard d.placement == .float, !overCancelZone(p) else { return nil }
        let picture = windowMode ? pictureGlobal : desktopPictureGlobal
        guard picture.width > 0, picture.height > 0, picture.contains(p) else { return nil }
        let center = WorkspacePoint(x: (p.x - picture.minX) / picture.width, y: (p.y - picture.minY) / picture.height)
        let aspect: Double? = {
            switch d.item {
            case .window(let w): return w.width > 0 && w.height > 0 ? Double(w.width) / Double(w.height) : nil
            case .pane(let id, let tab):
                if let tab, let s = layout.tiles[id]?.tabs[safe: tab], let w = windowItem(s), w.width > 0, w.height > 0 { return Double(w.width) / Double(w.height) }
                return windowAspect(id)
            default: return nil
            }
        }()
        let space = windowMode ? size : WorkspaceSize(width: picture.width, height: picture.height)
        return WorkspaceFloatGeometry.defaultFrame(aspect: aspect, in: space, center: center)
    }

    /// A drop in Floating placement: the window floats where it was let go.
    fileprivate func dropFloating(_ d: WorkspaceDrag) -> Bool {
        guard let frame = floatDropFrame(d, at: d.location) else { return false }
        return floatItem(d.item, at: WorkspacePoint(x: frame.midX, y: frame.midY))
    }

    /// Floats a dragged item, centred at `center` (nil: where a new float opens).
    fileprivate func floatItem(_ item: WorkspaceDrag.Item, at center: WorkspacePoint?) -> Bool {
        switch item {
        case .window(let w):
            openFloating(w, at: center)
            return true
        case .app(let app):
            let windows = (catalog?.windows ?? []).filter { $0.bundleID == app.bundleID }
            if windows.count == 1 { openFloating(windows[0], at: center); return true }
            appDrop = AppDrop(app: app, windows: windows, target: .replace(tile: Self.noDesktop, preview: .unit),
                              floatAt: center ?? WorkspacePoint(x: 0.5, y: 0.5))
            return !windows.isEmpty
        case .pane(let id, let tab):
            floatPane(id, tab: tab, at: center)
            return true
        case .float:
            return false
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
